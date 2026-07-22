#!/usr/bin/env python3
"""Validate the RendererIOS two-pass clear-only physical-device gate."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


CASE = "pm-clear-v1"
PREFIX = "RendererIOS clear-only pass self-test:"
CAPTURE_PREFIX = "RendererIOS clear-only capture:"
MAX_MARKER_BYTES = 250
ARMED = (
    f"{PREFIX} ARMED case={CASE} abi=4 resources=3 logical-passes=3 "
    "private=1 memoryless=1"
)
ENCODED = (
    f"{PREFIX} ENCODED case={CASE} physical-passes=2 command-buffers=1 "
    "render-encoders=2 private-load=clear private-store=store "
    "memoryless-load=clear memoryless-store=dont-care draws=0 pipelines=0 "
    "drawable=0 present=0"
)
SUBMITTED = (
    f"{PREFIX} SUBMITTED case={CASE} command-buffers=1 submits=1"
)
PASS = (
    f"{PREFIX} PASS case={CASE} terminal=completed created=2 live=0 "
    "released=2 wait-idle=0"
)
FAIL_PREFIX = f"{PREFIX} FAIL"
CAPTURE_RE = re.compile(
    rf"^{re.escape(CAPTURE_PREFIX)} ACQUIRED case={CASE} "
    r"file=RendererIOS-pm-clear-v1\.gputrace kind=(file|directory) "
    r"bytes=([1-9][0-9]*)$"
)
SHELL_RE = re.compile(
    r"^RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*$",
    re.MULTILINE,
)
CONFIGURED_RE = re.compile(
    r"^RendererIOS configured fault mode=([^\s]+)$",
    re.MULTILINE,
)
DIAGNOSTICS = "RendererIOS diagnostics: ON frames-in-flight="
ORDINARY_FRAME_PREFIXES = (
    "RendererIOS native Landscape:",
    "RendererIOS runtime compilation: point=frame presents=",
    "RendererIOS builtin runtime attribution: point=frame presents=",
    "RendererIOS functional evidence:",
    "RendererIOS shell: 300 present calls submitted",
    "RendererIOS lifecycle: presents=",
)
DENY_RE = re.compile(
    r"RendererIOS (?:fatal|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed|"
    r"clear-only pass self-test: FAIL)|"
    r"libc\+\+abi: terminating|SIGABRT|SIGSEGV|EXC_BAD_ACCESS|"
    r"AddressSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer|"
    r"uncaught exception|terminate called|std::terminate|jetsam|crash",
    re.IGNORECASE,
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def only_match(pattern: re.Pattern[str], text: str, name: str) -> re.Match[str]:
    matches = list(pattern.finditer(text))
    require(len(matches) == 1, f"expected exactly one {name}, found {len(matches)}")
    return matches[0]


def validate_marker_budget(markers: list[str] | tuple[str, ...]) -> None:
    require(len(markers) == 4, "clear-only pass marker set must contain four lines")
    for marker in markers:
        byte_count = len(marker.encode("utf-8"))
        require(
            byte_count <= MAX_MARKER_BYTES,
            "clear-only pass marker exceeds the device log line budget: "
            f"bytes={byte_count} limit={MAX_MARKER_BYTES}",
        )


def validate(
    log: str,
    stderr: str,
    expected_build: str,
    expected_capture_kind: str,
    expected_capture_bytes: int,
) -> dict[str, int | str]:
    require(
        re.fullmatch(r"[0-9a-f]{40}(?:-local)?", expected_build) is not None,
        "expected build must be a lowercase SHA, optionally suffixed -local",
    )

    shell = only_match(SHELL_RE, log, "RendererIOS shell marker")
    require(shell.group(1) == expected_build, "RendererIOS shell build is not exact")
    configured = only_match(CONFIGURED_RE, log, "configured fault marker")
    require(configured.group(1) == "none", "clear-only pass self-test requires fault none")

    diagnostic_lines = [
        line for line in log.splitlines() if line.startswith("RendererIOS diagnostics:")
    ]
    require(len(diagnostic_lines) == 1, "expected exactly one diagnostics marker")
    require(
        diagnostic_lines[0].startswith(DIAGNOSTICS)
        and diagnostic_lines[0].endswith(
            " context=IOSMetalContext transport=Tempest"
        ),
        "clear-only pass self-test requires diagnostics ON",
    )

    expected_markers = [ARMED, ENCODED, SUBMITTED, PASS]
    validate_marker_budget(expected_markers)
    self_test_lines = [line for line in log.splitlines() if line.startswith(PREFIX)]
    require(
        self_test_lines == expected_markers,
        "clear-only pass self-test markers are missing, malformed, duplicated, "
        "unknown, or out of order",
    )
    require(FAIL_PREFIX not in log, "clear-only pass self-test reported FAIL")

    log_lines = log.splitlines()
    capture_lines = [line for line in log_lines if line.startswith(CAPTURE_PREFIX)]
    require(len(capture_lines) == 1, "expected exactly one capture marker")
    capture = CAPTURE_RE.fullmatch(capture_lines[0])
    require(capture is not None, "capture marker is malformed")
    require(
        len(capture_lines[0].encode("utf-8")) <= MAX_MARKER_BYTES,
        "capture marker exceeds the device log line budget",
    )
    require(
        expected_capture_kind in ("file", "directory"),
        "expected capture kind is invalid",
    )
    require(expected_capture_bytes > 0, "expected capture byte count must be positive")
    require(capture.group(1) == expected_capture_kind, "capture kind does not match artifact")
    require(
        int(capture.group(2)) == expected_capture_bytes,
        "capture byte count does not match artifact",
    )
    require(
        log_lines.index(SUBMITTED) < log_lines.index(capture_lines[0]) < log_lines.index(PASS),
        "capture marker must follow SUBMITTED and precede PASS",
    )

    conflicts = {
        "Bink": "RendererIOS Bink self-test:",
        "resource allocator": "RendererIOS resource allocator self-test:",
        "fault arm": "RendererIOS fault injection armed:",
        "fault fire": "RendererIOS fault injection fired:",
        "pipeline archive": "RendererIOS pipeline archive test-mode:",
    }
    for name, marker in conflicts.items():
        require(marker not in log, f"clear-only pass self-test ran with {name} profile")

    ordinary_frame_lines = [
        line for line in log.splitlines()
        if line.startswith(ORDINARY_FRAME_PREFIXES)
    ]
    require(
        not ordinary_frame_lines,
        "clear-only pass self-test must not admit ordinary frame/present work: "
        f"{ordinary_frame_lines!r}",
    )

    denied = DENY_RE.search(log + "\n" + stderr)
    require(
        denied is None,
        "fatal/crash signature in clear-only pass self-test evidence"
        if denied is None
        else "fatal/crash signature in clear-only pass self-test evidence: "
        f"{denied.group(0)!r}",
    )

    return {
        "clear_only_pass_self_test_expected_build": expected_build,
        "clear_only_pass_self_test_armed_count": 1,
        "clear_only_pass_self_test_encoded_count": 1,
        "clear_only_pass_self_test_submitted_count": 1,
        "clear_only_pass_self_test_pass_count": 1,
        "clear_only_pass_self_test_fail_count": 0,
        "clear_only_pass_self_test_abi": 4,
        "clear_only_pass_self_test_resources": 3,
        "clear_only_pass_self_test_logical_passes": 3,
        "clear_only_pass_self_test_physical_passes": 2,
        "clear_only_pass_self_test_command_buffers": 1,
        "clear_only_pass_self_test_render_encoders": 2,
        "clear_only_pass_self_test_submits": 1,
        "clear_only_pass_self_test_private": "clear-store",
        "clear_only_pass_self_test_memoryless": "clear-dont-care",
        "clear_only_pass_self_test_draws": 0,
        "clear_only_pass_self_test_pipelines": 0,
        "clear_only_pass_self_test_drawable": 0,
        "clear_only_pass_self_test_present": 0,
        "clear_only_pass_self_test_terminal_completed": 1,
        "clear_only_pass_self_test_created": 2,
        "clear_only_pass_self_test_live": 0,
        "clear_only_pass_self_test_released": 2,
        "clear_only_pass_self_test_wait_idle": 0,
    }


def validate_absent(log: str) -> None:
    markers = [line for line in log.splitlines() if line.startswith(PREFIX)]
    require(not markers, f"unrequested clear-only pass self-test marker(s): {markers!r}")
    captures = [line for line in log.splitlines() if line.startswith(CAPTURE_PREFIX)]
    require(not captures, f"unrequested clear-only capture marker(s): {captures!r}")


def write_summary(path: pathlib.Path, values: dict[str, int | str]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
    )


def fixture(build: str, capture_kind: str = "directory", capture_bytes: int = 6) -> str:
    return "\n".join(
        (
            "RendererIOS configured fault mode=none",
            "RendererIOS shell: version=1 profile=Safe features=native-landscape-textured,ui "
            f"build={build} gpu=Apple deviceFamily=iPhone16,2 iOS=26.4 "
            "faultMode=none savePreviewRoute=cpu-placeholder",
            "RendererIOS diagnostics: ON frames-in-flight=3 "
            "context=IOSMetalContext transport=Tempest",
            ARMED,
            ENCODED,
            SUBMITTED,
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} "
            "file=RendererIOS-pm-clear-v1.gputrace "
            f"kind={capture_kind} bytes={capture_bytes}",
            PASS,
        )
    ) + "\n"


def self_test() -> None:
    build = "0123456789abcdef0123456789abcdef01234567-local"
    valid = fixture(build)
    values = validate(valid, "", build, "directory", 6)
    require(values["clear_only_pass_self_test_released"] == 2, "valid fixture failed")
    require(
        values["clear_only_pass_self_test_private"] == "clear-store",
        "private attachment summary failed",
    )
    require(
        values["clear_only_pass_self_test_memoryless"] == "clear-dont-care",
        "memoryless attachment summary failed",
    )
    validate_absent("plain RendererIOS smoke log\n")
    validate_marker_budget((ARMED, ENCODED, SUBMITTED, PASS))
    overlong = ENCODED + "x" * (
        MAX_MARKER_BYTES + 1 - len(ENCODED.encode("utf-8"))
    )
    try:
        validate_marker_budget((ARMED, overlong, SUBMITTED, PASS))
    except ValidationError:
        pass
    else:
        raise ValidationError("overlong marker mutation survived")

    ordinary_frame = (
        "RendererIOS runtime compilation: point=frame presents=1 available=1 "
        "source=0 compute=0 render=2"
    )
    mutations = {
        "missing-armed": valid.replace(ARMED + "\n", ""),
        "missing-encoded": valid.replace(ENCODED + "\n", ""),
        "missing-submitted": valid.replace(SUBMITTED + "\n", ""),
        "missing-pass": valid.replace(PASS + "\n", ""),
        "missing-capture": valid.replace(
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} "
            "file=RendererIOS-pm-clear-v1.gputrace kind=directory bytes=6\n",
            "",
        ),
        "duplicate-capture": valid + (
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} "
            "file=RendererIOS-pm-clear-v1.gputrace kind=directory bytes=6\n"
        ),
        "capture-after-pass": valid.replace(
            (
                f"{CAPTURE_PREFIX} ACQUIRED case={CASE} "
                "file=RendererIOS-pm-clear-v1.gputrace kind=directory bytes=6\n"
            ),
            "",
        ) + (
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} "
            "file=RendererIOS-pm-clear-v1.gputrace kind=directory bytes=6\n"
        ),
        "wrong-capture-name": valid.replace(
            "file=RendererIOS-pm-clear-v1.gputrace",
            "file=wrong.gputrace",
        ),
        "zero-capture-bytes": valid.replace("kind=directory bytes=6", "kind=directory bytes=0"),
        "duplicate-pass": valid + PASS + "\n",
        "reordered": valid.replace(ENCODED + "\n" + SUBMITTED, SUBMITTED + "\n" + ENCODED),
        "unknown": valid.replace(SUBMITTED, PREFIX + " UNKNOWN case=fixture"),
        "wrong-build": valid.replace(build, "f" * 40 + "-local"),
        "wrong-abi": valid.replace("abi=4", "abi=5"),
        "wrong-resources": valid.replace("resources=3", "resources=2"),
        "wrong-logical-passes": valid.replace("logical-passes=3", "logical-passes=2"),
        "wrong-physical-passes": valid.replace("physical-passes=2", "physical-passes=3"),
        "extra-command-buffer": valid.replace("command-buffers=1", "command-buffers=2", 1),
        "extra-render-encoder": valid.replace("render-encoders=2", "render-encoders=3"),
        "extra-submit": valid.replace("submits=1", "submits=2"),
        "private-store": valid.replace("private-store=store", "private-store=dont-care"),
        "memoryless-store": valid.replace("memoryless-store=dont-care", "memoryless-store=store"),
        "draw": valid.replace("draws=0", "draws=1"),
        "pipeline": valid.replace("pipelines=0", "pipelines=1"),
        "drawable": valid.replace("drawable=0", "drawable=1"),
        "present": valid.replace("present=0", "present=1"),
        "nonterminal": valid.replace("terminal=completed", "terminal=pending"),
        "wrong-created": valid.replace("created=2", "created=1"),
        "live-owner": valid.replace("live=0 released=2", "live=1 released=1"),
        "wait-idle": valid.replace("wait-idle=0", "wait-idle=1"),
        "ordinary-frame-after-pass": valid + ordinary_frame + "\n",
        "ordinary-frame-before-pass": valid.replace(
            PASS,
            ordinary_frame + "\n" + PASS,
        ),
        "fail-marker": valid + FAIL_PREFIX + " case=fixture detail=test\n",
        "bink-conflict": valid + "RendererIOS Bink self-test: ARMED case=x\n",
        "allocator-conflict": valid + "RendererIOS resource allocator self-test: ARMED case=x\n",
        "fault-conflict": valid + "RendererIOS fault injection armed: mode=x build=x\n",
        "archive-conflict": valid + "RendererIOS pipeline archive test-mode: mode=cold\n",
        "diagnostics-off": valid.replace("RendererIOS diagnostics: ON", "RendererIOS diagnostics: OFF"),
        "fatal": valid + "RendererIOS fatal: clear-only pass failed\n",
    }
    for name, mutated in mutations.items():
        try:
            validate(mutated, "", build, "directory", 6)
        except ValidationError:
            continue
        raise ValidationError(f"mutation survived: {name}")

    absent_mutations = {
        "armed": ARMED + "\n",
        "encoded": ENCODED + "\n",
        "submitted": SUBMITTED + "\n",
        "pass": PASS + "\n",
        "fail": FAIL_PREFIX + " case=fixture\n",
        "unknown": PREFIX + " UNKNOWN case=fixture\n",
        "capture": (
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} "
            "file=RendererIOS-pm-clear-v1.gputrace kind=file bytes=1\n"
        ),
    }
    for name, mutated in absent_mutations.items():
        try:
            validate_absent("plain RendererIOS smoke log\n" + mutated)
        except ValidationError:
            continue
        raise ValidationError(f"unrequested marker mutation survived: {name}")

    for signature in ("SIGABRT", "EXC_BAD_ACCESS", "jetsam", "crash"):
        try:
            validate(valid, signature, build, "directory", 6)
        except ValidationError:
            continue
        raise ValidationError(f"stderr crash mutation survived: {signature}")

    for kind, byte_count in (("file", 6), ("directory", 7)):
        try:
            validate(valid, "", build, kind, byte_count)
        except ValidationError:
            continue
        raise ValidationError("capture artifact mismatch mutation survived")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-capture-kind")
    parser.add_argument("--expected-capture-bytes", type=int)
    parser.add_argument("--summary", type=pathlib.Path)
    parser.add_argument("--expect-absent", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        require(
            args.log is None
            and args.stderr is None
            and args.expected_build is None
            and args.expected_capture_kind is None
            and args.expected_capture_bytes is None
            and args.summary is None
            and not args.expect_absent,
            "--self-test accepts no evidence arguments",
        )
        self_test()
        print("clear-only pass self-test validator passed")
        return 0

    require(args.log is not None, "--log is required")
    if args.expect_absent:
        require(args.stderr is None, "--expect-absent does not accept --stderr")
        require(
            args.expected_build is None,
            "--expect-absent does not accept --expected-build",
        )
        require(
            args.expected_capture_kind is None and args.expected_capture_bytes is None,
            "--expect-absent does not accept capture expectations",
        )
        require(args.summary is None, "--expect-absent does not accept --summary")
        validate_absent(args.log.read_text(encoding="utf-8", errors="replace"))
        print("clear-only pass self-test markers absent")
        return 0

    require(args.expected_build is not None, "--expected-build is required")
    require(
        args.expected_capture_kind is not None,
        "--expected-capture-kind is required",
    )
    require(
        args.expected_capture_bytes is not None,
        "--expected-capture-bytes is required",
    )
    log = args.log.read_text(encoding="utf-8", errors="replace")
    stderr = ""
    if args.stderr is not None:
        stderr = args.stderr.read_text(encoding="utf-8", errors="replace")
    values = validate(
        log,
        stderr,
        args.expected_build,
        args.expected_capture_kind,
        args.expected_capture_bytes,
    )
    if args.summary is not None:
        write_summary(args.summary, values)
    print("clear-only pass self-test log passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
