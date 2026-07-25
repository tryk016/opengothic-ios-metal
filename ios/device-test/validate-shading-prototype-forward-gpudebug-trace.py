#!/usr/bin/env python3
"""Owned-session, fail-closed gpudebug audit for the Forward+ prototype."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, replace


EXPECTED_LABELS = (
    "RendererIOS Forward Prototype CB",
    "RendererIOS Forward Compute Encoder",
    "RendererIOS Forward Render Encoder",
    "RendererIOS Forward BuildLightList",
    "RendererIOS Forward Opaque",
    "RendererIOS Forward AlphaTest",
    "RendererIOS Forward LightList 256B",
)
FOOTER_RE = re.compile(r"^\s*\(([0-9]+) items?\)\s*$", re.MULTILINE)
API_ROW_RE = re.compile(
    r"^\s*api([0-9]+)[ \t]+(?:(\S+)[ \t]+)?(\[[^\n]*\])[ \t]+"
    r"(go,[ \t]+info|info)[ \t]*$",
    re.MULTILINE,
)
SESSION_RE = re.compile(r"^Session ([1-9][0-9]*) created\.$", re.MULTILINE)
SESSION_HELPER_RE = re.compile(
    r"^gpudebug -s ([1-9][0-9]*) -c <command> to send commands\.$",
    re.MULTILINE,
)
MAX_OUTPUT_BYTES = 16 * 1024 * 1024


class ValidationError(RuntimeError):
    pass


class GPUDebugCommandError(ValidationError):
    def __init__(self, message: str, stdout: str) -> None:
        super().__init__(message)
        self.stdout = stdout


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


@dataclass(frozen=True)
class APICall:
    index: int
    result: str | None
    receiver: str
    method: str
    text: str
    actions: str


@dataclass(frozen=True)
class Transcripts:
    tool_version: str
    root: str
    commands: str
    command_buffer: str
    compute_encoder: str
    render_encoder: str
    api_calls: str
    output_texture: str
    light_list_buffer: str
    compute_pipeline: str
    opaque_pipeline: str
    alpha_pipeline: str
    collector_commands: tuple[str, ...]


def receiver(call: str) -> str:
    match = re.match(r"^\[([@A-Za-z][A-Za-z0-9_]*)\s+", call)
    require(match is not None, "API receiver schema is unknown")
    return match.group(1)


def method(call: str) -> str:
    match = re.match(r"^\[[^\s\]]+\s+([^\s\]]+)", call)
    require(match is not None, "API method schema is unknown")
    return match.group(1).split(":", 1)[0]


def parse_api(text: str) -> list[APICall]:
    matches = list(API_ROW_RE.finditer(text))
    raw_rows = re.findall(r"^\s*api[0-9]+(?:\s|$).*$", text, re.MULTILINE)
    require(len(matches) == len(raw_rows), "API table has an unparsed row")
    require(matches, "API table is empty")
    rows: dict[int, APICall] = {}
    for match in matches:
        index = int(match.group(1))
        require(index not in rows, "API table has a duplicate index")
        result = match.group(2)
        require(
            result is None or re.fullmatch(r"@[A-Za-z][A-Za-z0-9_]*", result) is not None,
            "API result schema is unknown",
        )
        text_call = match.group(3)
        rows[index] = APICall(
            index,
            result,
            receiver(text_call),
            method(text_call),
            text_call,
            re.sub(r"[ \t]+", " ", match.group(4)),
        )
    indexes = sorted(rows)
    require(indexes == list(range(len(rows))), "API rows are not contiguous")
    require(
        FOOTER_RE.findall(text) == [str(len(rows))],
        "API footer does not prove completeness",
    )
    return [rows[index] for index in indexes]


def table_rows(text: str, prefix: str) -> dict[str, str]:
    rows: dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(rf"^\s*({prefix}[0-9]+)\s+(.*\S)\s*$", line)
        if match is None:
            continue
        require(match.group(1) not in rows, "table has a duplicate row")
        rows[match.group(1)] = match.group(2)
    return rows


def encoder_ids(text: str) -> tuple[str, str]:
    order = re.findall(r"^\s*((?:ce|re)[0-9]+)\s+", text, re.MULTILINE)
    require(
        len(order) == 2
        and order[0].startswith("ce")
        and order[1].startswith("re")
        and order[0] != order[1],
        "encoder tree is not exactly compute then render",
    )
    return order[0], order[1]


def field(text: str, name: str) -> str:
    matches = re.findall(
        rf"^{re.escape(name)}:\s+(\S(?:.*\S)?)\s*$", text, re.MULTILINE
    )
    require(len(matches) == 1, f"{name} field is missing or duplicated")
    return matches[0]


def _one_resource(text: str, prefix: str, role: str) -> str:
    matches = re.findall(rf"(?<![A-Za-z0-9_])@{prefix}[0-9]+", text)
    require(len(matches) == 1, f"{role} does not expose exactly one @{prefix} resource")
    return matches[0]


def _buffer_binding(call: APICall, role: str) -> str:
    resource = _one_resource(call.text, "buf", role)
    require(
        re.search(r"(?:atIndex|index):0(?:\D|$)", call.text) is not None,
        f"{role} is not buffer index 0",
    )
    require(
        re.search(r"offset:0(?:\D|$)", call.text) is not None,
        f"{role} offset is not zero",
    )
    return resource


def _pipeline_binding(call: APICall, prefix: str, role: str) -> str:
    return _one_resource(call.text, prefix, role)


def _vertex_binding(call: APICall, role: str) -> None:
    require(
        re.fullmatch(
            r"\[MTLRenderCommandEncoder setVertexBytes:<data> "
            r"length:168 atIndex:0\]",
            call.text,
        )
        is not None,
        f"{role} vertex bind grammar is not exact",
    )


def _triangle(call: APICall, start: int, role: str) -> None:
    require(
        re.fullmatch(
            rf"\[MTLRenderCommandEncoder drawPrimitives:Triangle "
            rf"vertexStart:{start} vertexCount:3\]",
            call.text,
        )
        is not None,
        f"{role} is not the exact triangle draw",
    )


def validate_api(calls: list[APICall]) -> dict[str, int | str]:
    require(len(calls) == 19, "API call count is not exact 19")
    allowed = {
        "commandBufferWithDescriptor",
        "setLabel",
        "computeCommandEncoder",
        "setComputePipelineState",
        "setBuffer",
        "dispatchThreads",
        "endEncoding",
        "renderCommandEncoderWithDescriptor",
        "setRenderPipelineState",
        "setVertexBytes",
        "setFragmentBuffer",
        "drawPrimitives",
        "addCompletedHandler",
        "commit",
    }
    unknown = sorted({call.method for call in calls if call.method not in allowed})
    require(not unknown, f"unknown API method(s): {unknown}")

    cq = calls[0].receiver
    require(re.fullmatch(r"@cq[0-9]+", cq) is not None, "command queue ID is invalid")
    exact: list[tuple[str, str, str | None, str]] = [
        ("commandBufferWithDescriptor", rf"\[{re.escape(cq)} commandBufferWithDescriptor:<descriptor>\]", None, "info"),
        ("setLabel", r'\[MTLCommandBuffer setLabel:"RendererIOS Forward Prototype CB"\]', None, "info"),
        ("computeCommandEncoder", r"\[MTLCommandBuffer computeCommandEncoder\]", None, "info"),
        ("setLabel", r'\[MTLComputeCommandEncoder setLabel:"RendererIOS Forward Compute Encoder"\]', None, "info"),
        ("setComputePipelineState", r"\[MTLComputeCommandEncoder setComputePipelineState:@cps[0-9]+\]", None, "info"),
        ("setBuffer", r"\[MTLComputeCommandEncoder setBuffer:@buf[0-9]+ offset:0 atIndex:0\]", None, "info"),
        ("dispatchThreads", r"\[MTLComputeCommandEncoder dispatchThreads:1x1x1 threadsPerThreadgroup:1x1x1\]", None, "go, info"),
        ("endEncoding", r"\[MTLComputeCommandEncoder endEncoding\]", None, "info"),
        ("renderCommandEncoderWithDescriptor", r"\[MTLCommandBuffer renderCommandEncoderWithDescriptor:<descriptor>\]", None, "info"),
        ("setLabel", r'\[MTLRenderCommandEncoder setLabel:"RendererIOS Forward Render Encoder"\]', None, "info"),
        ("setVertexBytes", r"\[MTLRenderCommandEncoder setVertexBytes:<data> length:168 atIndex:0\]", None, "info"),
        ("setFragmentBuffer", r"\[MTLRenderCommandEncoder setFragmentBuffer:@buf[0-9]+ offset:0 atIndex:0\]", None, "info"),
        ("setRenderPipelineState", r"\[MTLRenderCommandEncoder setRenderPipelineState:@rps[0-9]+\]", None, "info"),
        ("drawPrimitives", r"\[MTLRenderCommandEncoder drawPrimitives:Triangle vertexStart:0 vertexCount:3\]", None, "go, info"),
        ("setRenderPipelineState", r"\[MTLRenderCommandEncoder setRenderPipelineState:@rps[0-9]+\]", None, "info"),
        ("drawPrimitives", r"\[MTLRenderCommandEncoder drawPrimitives:Triangle vertexStart:3 vertexCount:3\]", None, "go, info"),
        ("endEncoding", r"\[MTLRenderCommandEncoder endEncoding\]", None, "info"),
        ("addCompletedHandler", r"\[MTLCommandBuffer addCompletedHandler:\]", None, "info"),
        ("commit", r"\[MTLCommandBuffer commit\]", None, "info"),
    ]
    for call, (expected_method, grammar, expected_result, expected_actions) in zip(calls, exact):
        require(call.method == expected_method, f"API order mismatch at api{call.index}")
        require(call.result == expected_result, f"API result mismatch at api{call.index}")
        require(call.actions == expected_actions, f"API actions mismatch at api{call.index}")
        require(
            re.fullmatch(grammar, call.text) is not None,
            f"API receiver/grammar mismatch at api{call.index}",
        )

    compute_buffer = _buffer_binding(calls[5], "compute light-list")
    require(
        _buffer_binding(calls[11], "shared fragment light-list") == compute_buffer,
        "compute and fragment stages do not share the light-list buffer",
    )
    _vertex_binding(calls[10], "shared render")
    _triangle(calls[13], 0, "opaque")
    _triangle(calls[15], 3, "alpha")

    compute_pipeline = _pipeline_binding(calls[4], "cps", "compute pipeline")
    opaque_pipeline = _pipeline_binding(calls[12], "rps", "opaque pipeline")
    alpha_pipeline = _pipeline_binding(calls[14], "rps", "alpha pipeline")
    require(opaque_pipeline != alpha_pipeline, "opaque and alpha alias one pipeline")
    return {
        "api_rows_observed": len(calls),
        "command_buffers": 1,
        "compute_encoders": 1,
        "render_encoders": 1,
        "dispatches": 1,
        "draws": 2,
        "completed_handlers": 1,
        "commits": 1,
        "light_list_object": compute_buffer,
        "compute_pipeline_object": compute_pipeline,
        "opaque_pipeline_object": opaque_pipeline,
        "alpha_pipeline_object": alpha_pipeline,
    }


def _validate_root(root: str) -> str:
    sessions = SESSION_RE.findall(root)
    helpers = SESSION_HELPER_RE.findall(root)
    require(len(sessions) == 1 and helpers == sessions, "owned gpudebug session schema is invalid")
    return sessions[0]


def _validate_labels(transcripts: Transcripts) -> None:
    combined = "\n".join(
        (
            transcripts.commands,
            transcripts.command_buffer,
            transcripts.compute_encoder,
            transcripts.render_encoder,
            transcripts.api_calls,
            transcripts.output_texture,
            transcripts.light_list_buffer,
            transcripts.compute_pipeline,
            transcripts.opaque_pipeline,
            transcripts.alpha_pipeline,
        )
    )
    for label in EXPECTED_LABELS:
        require(label in combined, f"missing exact label: {label}")
    observed = set(
        re.findall(
            r"RendererIOS Forward (?:Prototype CB|Compute Encoder|Render Encoder|"
            r"BuildLightList|Opaque|AlphaTest|LightList 256B|[^\r\n\"]+)",
            combined,
        )
    )
    require(
        observed <= set(EXPECTED_LABELS),
        f"unknown RendererIOS Forward label(s): {sorted(observed - set(EXPECTED_LABELS))}",
    )


def _validate_attachment_tree(text: str) -> str:
    rows = table_rows(text, "color")
    require(set(rows) == {"color0"}, "render attachment tree is not exact color0")
    draw_rows = table_rows(text, "draw")
    require(set(draw_rows) == {"draw0", "draw1"}, "render draw tree is not exact draw0/draw1")
    draw_schema = re.compile(
        r'"riosShadingPrototypeVertex / riosFor\.\.\.\s+'
        r"1 triangles\s+go, info"
    )
    require(
        all(draw_schema.fullmatch(row) is not None for row in draw_rows.values()),
        "render draw tree row schema is invalid",
    )
    require(FOOTER_RE.findall(text) == ["3"], "render attachment/draw tree is not complete")
    resource = _one_resource(rows["color0"], "tex", "render color0")
    require(
        re.fullmatch(
            rf'"MTLTexture [1-9][0-9]*"\s+{re.escape(resource)}\s+'
            r"4x4 RGBA8Unorm\s+info, fetch",
            rows["color0"],
        )
        is not None,
        "render color0 row schema is not exact",
    )
    return resource


def _validate_provenance(
    commands: tuple[str, ...],
    values: dict[str, int | str],
    compute_encoder: str,
    render_encoder: str,
) -> None:
    expected = (
        "go commands",
        "go commands/cb0",
        f"go commands/cb0/{compute_encoder}",
        f"go commands/cb0/{render_encoder}",
        "go api_calls",
        "list --all",
        f"go commands/cb0/{render_encoder}|info color0",
        f"go api_calls|info {values['light_list_object']}",
        f"go api_calls|info {values['compute_pipeline_object']}",
        f"go api_calls|info {values['opaque_pipeline_object']}",
        f"go api_calls|info {values['alpha_pipeline_object']}",
    )
    require(commands == expected, "collector command provenance is not exact")


def validate(transcripts: Transcripts) -> dict[str, int | str]:
    require(transcripts.tool_version == "gpudebug 1.0\n", "gpudebug version is not exact 1.0")
    session = _validate_root(transcripts.root)
    command_rows = table_rows(transcripts.commands, "cb")
    require(set(command_rows) == {"cb0"}, "command-buffer tree is not exact one CB")
    require(
        re.fullmatch(
            r'2 encoders?\s+"MTLCommandQueue [1-9][0-9]*"\s+go',
            command_rows["cb0"],
        )
        is not None,
        "command-buffer row/tool-owned queue label is not exact",
    )
    require(FOOTER_RE.findall(transcripts.commands) == ["1"], "command-buffer tree is not complete")

    encoder_rows = {
        **table_rows(transcripts.command_buffer, "ce"),
        **table_rows(transcripts.command_buffer, "re"),
    }
    compute_encoder, render_encoder = encoder_ids(transcripts.command_buffer)
    require(
        set(encoder_rows) == {compute_encoder, render_encoder},
        "encoder set is not exact",
    )
    require(
        re.fullmatch(
            r'"RendererIOS Forward Compute Encoder"\s+1 dispatch\s+go',
            encoder_rows[compute_encoder],
        )
        is not None
        and re.fullmatch(
            r'"RendererIOS Forward Render Encoder"\s+2 draws\s+go',
            encoder_rows[render_encoder],
        )
        is not None,
        "encoder labels/summaries are not exact",
    )
    require(FOOTER_RE.findall(transcripts.command_buffer) == ["2"], "encoder tree is not complete")
    dispatch_rows = table_rows(transcripts.compute_encoder, "disp")
    require(
        set(dispatch_rows) == {"disp0"}
        and re.fullmatch(
            r'"riosForwardPlusBuildLightList"(?:\s+\S(?:.*\S)?)?\s+go, info',
            dispatch_rows["disp0"],
        )
        is not None,
        "compute dispatch tree is not exact disp0",
    )
    require(
        FOOTER_RE.findall(transcripts.compute_encoder) == ["1"],
        "compute dispatch tree is not complete",
    )

    output_object = _validate_attachment_tree(transcripts.render_encoder)
    calls = parse_api(transcripts.api_calls)
    values = validate_api(calls)
    _validate_provenance(
        transcripts.collector_commands, values, compute_encoder, render_encoder
    )
    _validate_labels(transcripts)

    require(
        _one_resource(transcripts.output_texture, "tex", "output info")
        == output_object,
        "output info is not the render encoder color0",
    )
    require(field(transcripts.output_texture, "label") == "(none)", "output label mismatch")
    require(field(transcripts.output_texture, "dimensions") == "4x4", "output dimensions mismatch")
    require(field(transcripts.output_texture, "pixelFormat") == "RGBA8Unorm", "output format mismatch")
    require(field(transcripts.output_texture, "textureType") == "2D", "output texture type mismatch")
    require(field(transcripts.output_texture, "storageMode") == "Private", "output storage mismatch")
    require(field(transcripts.output_texture, "loadAction") == "Clear", "output load mismatch")
    require(field(transcripts.output_texture, "storeAction") == "Store", "output store mismatch")
    require(field(transcripts.output_texture, "usage") == "RenderTarget", "output usage mismatch")

    require(field(transcripts.light_list_buffer, "label") == "RendererIOS Forward LightList 256B", "light-list label mismatch")
    require(field(transcripts.light_list_buffer, "length") == "256 bytes", "light-list length mismatch")
    require(field(transcripts.light_list_buffer, "storageMode") == "Shared", "light-list storage mismatch")

    pipeline_fields = (
        (transcripts.compute_pipeline, "compute_pipeline_object", "RendererIOS Forward BuildLightList"),
        (transcripts.opaque_pipeline, "opaque_pipeline_object", "RendererIOS Forward Opaque"),
        (transcripts.alpha_pipeline, "alpha_pipeline_object", "RendererIOS Forward AlphaTest"),
    )
    for text, _object_key, label in pipeline_fields:
        require(field(text, "label") == label, f"{label} info label mismatch")
    return {"session": session, **values, "output_texture_object": output_object}


def _scrubbed_environment() -> dict[str, str]:
    allowed = ("HOME", "PATH", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL")
    result = {key: os.environ[key] for key in allowed if key in os.environ}
    result["NO_COLOR"] = "1"
    return result


def _run_gpudebug(arguments: list[str], timeout: int, deadline: float) -> str:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise GPUDebugCommandError("gpudebug global timeout", "")
    effective_timeout = min(float(timeout), remaining)
    with tempfile.TemporaryFile() as output:
        try:
            process = subprocess.Popen(
                arguments,
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                env=_scrubbed_environment(),
                start_new_session=True,
            )
        except OSError as exc:
            raise ValidationError("gpudebug execution failed") from exc
        timed_out = False
        try:
            process.wait(timeout=effective_timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        output.seek(0, os.SEEK_END)
        output_size = output.tell()
        output.seek(0)
        stdout = output.read(min(output_size, MAX_OUTPUT_BYTES)).decode(
            "utf-8", errors="replace"
        )
    if output_size > MAX_OUTPUT_BYTES:
        raise GPUDebugCommandError("gpudebug output exceeds 16 MiB", stdout)
    if timed_out:
        raise GPUDebugCommandError("gpudebug command timed out", stdout)
    if process.returncode != 0:
        raise GPUDebugCommandError("gpudebug command failed", stdout)
    return stdout


def _owned_session_from_output(text: str) -> str | None:
    values = set(SESSION_RE.findall(text))
    values.update(SESSION_HELPER_RE.findall(text))
    return values.pop() if len(values) == 1 else None


def collect_transcripts(
    gpudebug: pathlib.Path,
    trace: pathlib.Path,
    timeout: int,
    global_timeout: int,
) -> Transcripts:
    try:
        tool_info = gpudebug.lstat()
        trace_info = trace.lstat()
    except FileNotFoundError as exc:
        raise ValidationError("audit input is missing") from exc
    require(stat.S_ISREG(tool_info.st_mode) and not stat.S_ISLNK(tool_info.st_mode), "gpudebug path is not a regular file")
    require(tool_info.st_mode & stat.S_IXUSR != 0, "gpudebug is not executable")
    require(
        not stat.S_ISLNK(trace_info.st_mode)
        and (stat.S_ISREG(trace_info.st_mode) or stat.S_ISDIR(trace_info.st_mode)),
        "trace path is invalid",
    )
    require(1 <= timeout <= 90, "command timeout is outside 1..90")
    require(timeout <= global_timeout <= 720, "global timeout is outside allowed range")
    deadline = time.monotonic() + float(global_timeout)
    tool_version = _run_gpudebug([str(gpudebug), "--version"], timeout, deadline)
    session: str | None = None
    provenance: list[str] = []
    try:
        try:
            root = _run_gpudebug(
                [
                    str(gpudebug),
                    "-t",
                    str(trace),
                    "--timeout",
                    str(min(timeout + 30, 120)),
                    "-c",
                    "list",
                ],
                timeout,
                deadline,
            )
        except GPUDebugCommandError as exc:
            session = _owned_session_from_output(exc.stdout)
            raise
        session = _owned_session_from_output(root)
        require(session is not None, "owned session cannot be identified")
        require(SESSION_RE.findall(root) == [session] and SESSION_HELPER_RE.findall(root) == [session], "session banner/helper schema is invalid")

        def command(*commands: str) -> str:
            assert session is not None
            for item in commands:
                if item.startswith("go "):
                    target = item.removeprefix("go ")
                    require(
                        target == "api_calls"
                        or target == "commands"
                        or target.startswith("commands/"),
                        "collector attempted a non-root-qualified go",
                    )
            provenance.append("|".join(commands))
            arguments = [str(gpudebug), "-s", session]
            for item in commands:
                arguments.extend(("-c", item))
            return _run_gpudebug(arguments, timeout, deadline)

        commands = command("go commands")
        command_buffer = command("go commands/cb0")
        compute_encoder_id, render_encoder_id = encoder_ids(command_buffer)
        compute_encoder = command(f"go commands/cb0/{compute_encoder_id}")
        render_encoder = command(f"go commands/cb0/{render_encoder_id}")
        command("go api_calls")
        api_calls = command("list --all")
        api_values = validate_api(parse_api(api_calls))
        output_texture = command(
            f"go commands/cb0/{render_encoder_id}", "info color0"
        )
        light_list_buffer = command("go api_calls", f"info {api_values['light_list_object']}")
        compute_pipeline = command("go api_calls", f"info {api_values['compute_pipeline_object']}")
        opaque_pipeline = command("go api_calls", f"info {api_values['opaque_pipeline_object']}")
        alpha_pipeline = command("go api_calls", f"info {api_values['alpha_pipeline_object']}")
        result = Transcripts(
            tool_version,
            root,
            commands,
            command_buffer,
            compute_encoder,
            render_encoder,
            api_calls,
            output_texture,
            light_list_buffer,
            compute_pipeline,
            opaque_pipeline,
            alpha_pipeline,
            tuple(provenance),
        )
    finally:
        if session is not None:
            _run_gpudebug(
                [str(gpudebug), "--terminate", session],
                min(timeout, 30),
                max(deadline, time.monotonic()) + 30.0,
            )
    return result


def write_summary(path: pathlib.Path | None, values: dict[str, int | str]) -> None:
    payload = "".join(f"{key}={value}\n" for key, value in values.items())
    if path is None:
        sys.stdout.write(payload)
        return
    path.write_text(payload, encoding="utf-8")


def fixture() -> Transcripts:
    api = "\n".join(
        (
            "api0 [@cq0 commandBufferWithDescriptor:<descriptor>] info",
            'api1 [MTLCommandBuffer setLabel:"RendererIOS Forward Prototype CB"] info',
            "api2 [MTLCommandBuffer computeCommandEncoder] info",
            'api3 [MTLComputeCommandEncoder setLabel:"RendererIOS Forward Compute Encoder"] info',
            "api4 [MTLComputeCommandEncoder setComputePipelineState:@cps0] info",
            "api5 [MTLComputeCommandEncoder setBuffer:@buf0 offset:0 atIndex:0] info",
            "api6 [MTLComputeCommandEncoder dispatchThreads:1x1x1 threadsPerThreadgroup:1x1x1] go, info",
            "api7 [MTLComputeCommandEncoder endEncoding] info",
            "api8 [MTLCommandBuffer renderCommandEncoderWithDescriptor:<descriptor>] info",
            'api9 [MTLRenderCommandEncoder setLabel:"RendererIOS Forward Render Encoder"] info',
            "api10 [MTLRenderCommandEncoder setVertexBytes:<data> length:168 atIndex:0] info",
            "api11 [MTLRenderCommandEncoder setFragmentBuffer:@buf0 offset:0 atIndex:0] info",
            "api12 [MTLRenderCommandEncoder setRenderPipelineState:@rps0] info",
            "api13 [MTLRenderCommandEncoder drawPrimitives:Triangle vertexStart:0 vertexCount:3] go, info",
            "api14 [MTLRenderCommandEncoder setRenderPipelineState:@rps1] info",
            "api15 [MTLRenderCommandEncoder drawPrimitives:Triangle vertexStart:3 vertexCount:3] go, info",
            "api16 [MTLRenderCommandEncoder endEncoding] info",
            "api17 [MTLCommandBuffer addCompletedHandler:] info",
            "api18 [MTLCommandBuffer commit] info",
            "(19 items)",
            "",
        )
    )
    provenance = (
        "go commands",
        "go commands/cb0",
        "go commands/cb0/ce0",
        "go commands/cb0/re1",
        "go api_calls",
        "list --all",
        "go commands/cb0/re1|info color0",
        "go api_calls|info @buf0",
        "go api_calls|info @cps0",
        "go api_calls|info @rps0",
        "go api_calls|info @rps1",
    )
    return Transcripts(
        "gpudebug 1.0\n",
        "Session 7 created.\ngpudebug -s 7 -c <command> to send commands.\n",
        'Name Summary Label Actions\ncb0 2 encoders "MTLCommandQueue 1" go\n(1 item)\n',
        'Name Label Summary Actions\nce0 "RendererIOS Forward Compute Encoder" 1 dispatch go\nre1 "RendererIOS Forward Render Encoder" 2 draws go\n(2 items)\n',
        'Name Label Summary Actions\ndisp0 "riosForwardPlusBuildLightList" 1x1x1 go, info\n(1 item)\n',
        'Name Label Summary Actions\ncolor0 "MTLTexture 1" @tex0 4x4 RGBA8Unorm info, fetch\ndraw0 "riosShadingPrototypeVertex / riosFor... 1 triangles go, info\ndraw1 "riosShadingPrototypeVertex / riosFor... 1 triangles go, info\n(3 items)\n',
        api,
        'color0 "MTLTexture 1" @tex0 4x4 RGBA8Unorm info, fetch\nlabel: (none)\ndimensions: 4x4\npixelFormat: RGBA8Unorm\ntextureType: 2D\nstorageMode: Private\nloadAction: Clear\nstoreAction: Store\nusage: RenderTarget\n',
        "label: RendererIOS Forward LightList 256B\nlength: 256 bytes\nstorageMode: Shared\n",
        "name: cps0\nlabel: RendererIOS Forward BuildLightList\n",
        "name: rps0\nlabel: RendererIOS Forward Opaque\n",
        "name: rps1\nlabel: RendererIOS Forward AlphaTest\n",
        provenance,
    )


def _mutate(text: str, old: str, new: str, name: str) -> str:
    require(old in text, f"invalid mutation fixture: {name}")
    return text.replace(old, new, 1)


def _fake_collector_self_test(root: pathlib.Path, good: Transcripts) -> int:
    tool = root / "fake-gpudebug"
    trace = root / "valid.gputrace"
    state = root / "state"
    trace.write_bytes(b"trace")
    outputs = {
        "go commands": good.commands,
        "go commands/cb0": good.command_buffer,
        "go commands/cb0/ce0": good.compute_encoder,
        "go commands/cb0/re1": good.render_encoder,
        "go api_calls": "",
        "list --all": good.api_calls,
        "go commands/cb0/re1|info color0": good.output_texture,
        "go api_calls|info @buf0": good.light_list_buffer,
        "go api_calls|info @cps0": good.compute_pipeline,
        "go api_calls|info @rps0": good.opaque_pipeline,
        "go api_calls|info @rps1": good.alpha_pipeline,
    }
    tool.write_text(
        "#!/usr/bin/env python3\n"
        "import os, pathlib, sys, time\n"
        f"outputs={outputs!r}\nstate=pathlib.Path({str(state)!r})\n"
        "args=sys.argv[1:]\n"
        "if os.environ.get('GH_TOKEN'): raise SystemExit(70)\n"
        "if args==['--version']: print('gpudebug 1.0'); raise SystemExit(0)\n"
        "if '--terminate' in args: state.unlink(missing_ok=True); raise SystemExit(0)\n"
        "commands=[args[i+1] for i,v in enumerate(args) if v=='-c']\n"
        "if '-t' in args:\n"
        " state.write_text('active')\n"
        " name=pathlib.Path(args[args.index('-t')+1]).name\n"
        " if name=='parse.gputrace':\n"
        "  print('Session seven created.', flush=True)\n"
        "  print('gpudebug -s 7 -c <command> to send commands.', flush=True)\n"
        "  raise SystemExit(0)\n"
        " print('Session 7 created.', flush=True)\n"
        " print('gpudebug -s 7 -c <command> to send commands.', flush=True)\n"
        " if name=='timeout.gputrace': time.sleep(30)\n"
        " if name=='nonzero.gputrace': raise SystemExit(71)\n"
        f" if name=='output-limit.gputrace': print('x'*{MAX_OUTPUT_BYTES}, flush=True)\n"
        " raise SystemExit(0)\n"
        "if '-s' not in args or not state.exists(): raise SystemExit(72)\n"
        "key='|'.join(commands)\n"
        "if key=='go commands/cb0' and state.read_text()=='nonzero-command': raise SystemExit(73)\n"
        "if key not in outputs: raise SystemExit(74)\n"
        "print(outputs[key], end='')\n",
        encoding="utf-8",
    )
    tool.chmod(0o700)
    saved = os.environ.get("GH_TOKEN")
    os.environ["GH_TOKEN"] = "must-not-leak"
    try:
        collected = collect_transcripts(tool, trace, 3, 20)
    finally:
        if saved is None:
            os.environ.pop("GH_TOKEN", None)
        else:
            os.environ["GH_TOKEN"] = saved
    validate(collected)
    require(not state.exists(), "success did not terminate owned session")
    count = 1
    for name in (
        "timeout.gputrace",
        "nonzero.gputrace",
        "parse.gputrace",
        "output-limit.gputrace",
    ):
        candidate = root / name
        candidate.write_bytes(b"trace")
        try:
            collect_transcripts(tool, candidate, 1, 5)
        except ValidationError:
            pass
        else:
            raise ValidationError(f"collector mutation survived: {name}")
        require(not state.exists(), f"{name} did not terminate owned session")
        count += 1
    return count


def self_test() -> None:
    good = fixture()
    values = validate(good)
    require(values["draws"] == 2 and values["commits"] == 1, "valid fixture failed")
    cases: dict[str, Transcripts] = {
        "version": replace(good, tool_version="gpudebug 2.0\n"),
        "extra-cb": replace(good, commands=_mutate(good.commands, "(1 item)", 'cb1 0 encoders "extra" go\n(2 items)', "extra-cb")),
        "encoder-order": replace(good, command_buffer=_mutate(good.command_buffer, 'ce0 "RendererIOS Forward Compute Encoder" 1 dispatch go\nre1 "RendererIOS Forward Render Encoder" 2 draws go', 're1 "RendererIOS Forward Render Encoder" 2 draws go\nce0 "RendererIOS Forward Compute Encoder" 1 dispatch go', "encoder-order")),
        "pso-label-swap": replace(good, compute_pipeline=good.opaque_pipeline, opaque_pipeline=good.compute_pipeline),
        "opaque-alpha-label-swap": replace(good, opaque_pipeline=good.alpha_pipeline, alpha_pipeline=good.opaque_pipeline),
        "dispatch-grid": replace(good, api_calls=_mutate(good.api_calls, "dispatchThreads:1x1x1", "dispatchThreads:1x2x1", "dispatch-grid")),
        "dispatch-actions": replace(
            good,
            api_calls=_mutate(
                good.api_calls,
                "threadsPerThreadgroup:1x1x1] go, info",
                "threadsPerThreadgroup:1x1x1] info",
                "dispatch-actions",
            ),
        ),
        "multiline-actions": replace(
            good,
            api_calls=_mutate(
                good.api_calls,
                "threadsPerThreadgroup:1x1x1] go, info",
                "threadsPerThreadgroup:1x1x1] go,\n info",
                "multiline-actions",
            ),
        ),
        "non-actionable-api-actions": replace(
            good,
            api_calls=_mutate(
                good.api_calls,
                "setComputePipelineState:@cps0] info",
                "setComputePipelineState:@cps0] go, info",
                "non-actionable-api-actions",
            ),
        ),
        "primitive": replace(good, api_calls=good.api_calls.replace("drawPrimitives:Triangle", "drawPrimitives:Line")),
        "stale-bind-order": replace(good, api_calls=_mutate(good.api_calls, "api11 [MTLRenderCommandEncoder setFragmentBuffer:@buf0 offset:0 atIndex:0] info\napi12 [MTLRenderCommandEncoder setRenderPipelineState:@rps0] info", "api11 [MTLRenderCommandEncoder setRenderPipelineState:@rps0] info\napi12 [MTLRenderCommandEncoder setFragmentBuffer:@buf0 offset:0 atIndex:0] info", "stale-bind-order")),
        "buffer-alias": replace(good, api_calls=_mutate(good.api_calls, "api11 [MTLRenderCommandEncoder setFragmentBuffer:@buf0", "api11 [MTLRenderCommandEncoder setFragmentBuffer:@buf1", "buffer-alias")),
        "unknown-api": replace(good, api_calls=_mutate(good.api_calls, "api18 [MTLCommandBuffer commit]", "api18 [MTLCommandBuffer mysteryWork]", "unknown-api")),
        "output-unbound": replace(good, collector_commands=tuple(command.replace("go commands/cb0/re1|info color0", "go commands/cb0/ce0|info color0") for command in good.collector_commands)),
        "output-object": replace(good, output_texture=_mutate(good.output_texture, "@tex0", "@tex1", "output-object")),
        "transcript-splice": replace(good, collector_commands=good.collector_commands[:-1]),
        "buffer-size": replace(good, light_list_buffer=_mutate(good.light_list_buffer, "256 bytes", "252 bytes", "buffer-size")),
        "output-storage": replace(good, output_texture=_mutate(good.output_texture, "Private", "Shared", "output-storage")),
        "session-drift": replace(good, root=_mutate(good.root, "Session 7", "Session 8", "session-drift")),
        "extra-dispatch-node": replace(
            good,
            compute_encoder=_mutate(
                good.compute_encoder,
                "(1 item)",
                'disp1 "spoof disp0" 1x1x1 go, info\n(2 items)',
                "extra-dispatch-node",
            ),
        ),
        "dispatch-substring-spoof": replace(
            good,
            compute_encoder=_mutate(
                good.compute_encoder,
                'disp0 "riosForwardPlusBuildLightList" 1x1x1 go, info',
                'disp1 "spoof disp0 riosForwardPlusBuildLightList" 1x1x1 go, info',
                "dispatch-substring-spoof",
            ),
        ),
    }
    survived: list[str] = []
    for name, candidate in cases.items():
        try:
            validate(candidate)
        except ValidationError:
            continue
        survived.append(name)
    require(not survived, f"gpudebug mutation survivors: {survived}")
    with tempfile.TemporaryDirectory(prefix="forward-gpudebug-collector-") as raw:
        collector_cases = _fake_collector_self_test(pathlib.Path(raw), good)
    total = len(cases) + collector_cases
    print(f"Forward gpudebug validator self-test passed: {total} mutations/collector paths killed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gpudebug", type=pathlib.Path)
    parser.add_argument("--trace", type=pathlib.Path)
    parser.add_argument("--summary", type=pathlib.Path)
    parser.add_argument("--command-timeout", type=int, default=60)
    parser.add_argument("--global-timeout", type=int, default=720)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        require(
            args.gpudebug is None
            and args.trace is None
            and args.summary is None
            and args.command_timeout == 60
            and args.global_timeout == 720,
            "--self-test accepts no audit inputs",
        )
        self_test()
        return 0
    require(args.gpudebug is not None and args.trace is not None, "--gpudebug and --trace are required")
    values = validate(
        collect_transcripts(
            args.gpudebug, args.trace, args.command_timeout, args.global_timeout
        )
    )
    write_summary(args.summary, values)
    print("Forward gpudebug owned-session semantic audit passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
