#!/usr/bin/env python3
"""Validate one RendererIOS linear-HDR terminal evidence log."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import pathlib
import re
import sys


PASS_PREFIX = "RendererIOS linear HDR:"
ACTIVATION_PREFIX = "RendererIOS linear HDR activation:"
UINT32_MAX = (1 << 32) - 1
UINT64_MAX = (1 << 64) - 1
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
PASS_RE = re.compile(
    r"^RendererIOS linear HDR: v=1 b=([0-9a-f]{40}) "
    r"g=([1-9][0-9]*) s=([1-9][0-9]*) "
    r"w=([1-9][0-9]*) h=([1-9][0-9]*) "
    r"fmt=rg11b10f probe=1 target=1 scene=1 resolve=1 "
    r"ui=([01]) present=1 terminal=C$"
)
ACTIVATION_RE = re.compile(
    r"^RendererIOS linear HDR activation: attempt=(startup|recreate) "
    r"probe=([01]) target=([01]) scene=([01]) resolve=([01]) "
    r"ready=([01]) safe=([01]) bytes=(0|[1-9][0-9]*) "
    r"generation=(0|[1-9][0-9]*)$"
)
DENY_RE = re.compile(
    r"RendererIOS linear HDR terminal[^\r\n]*failed|"
    r"RendererIOS (?:fatal|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed|"
    r"native Landscape encode failed|IOSGPUScene metallib loading failed)|"
    r"(?:^|\b)fatal(?:\s+error)?\s*:|\bEXC_CRASH\b|"
    r"Exception Type:\s*EXC_RESOURCE\b|\bTerminated due to signal\b|"
    r"\bSegmentation fault\b|\bAbort trap\b|\bSIG(?:ABRT|SEGV|KILL)\b|"
    r"\bEXC_BAD_ACCESS\b|libc\+\+abi:|AddressSanitizer|ThreadSanitizer|"
    r"UndefinedBehaviorSanitizer|uncaught exception|terminate called|"
    r"std::terminate|jetsam",
    re.IGNORECASE,
)


class ValidationError(RuntimeError):
    pass


@dataclass(frozen=True)
class LinearHDRPass:
    line_index: int
    build: str
    generation: int
    snapshot_sequence: int
    width: int
    height: int
    ui: int

    @property
    def byte_size(self) -> int:
        return self.width * self.height * 4


@dataclass(frozen=True)
class LinearHDRActivation:
    line_index: int
    attempt: str
    probe: int
    target: int
    scene: int
    resolve: int
    ready: int
    safe: int
    byte_size: int
    generation: int

    @property
    def successful(self) -> bool:
        return (
            self.probe,
            self.target,
            self.scene,
            self.resolve,
            self.ready,
            self.safe,
        ) == (1, 1, 1, 1, 1, 0)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def parse_uint(raw: str, label: str, maximum: int, *, positive: bool) -> int:
    pattern = r"[1-9][0-9]*\Z" if positive else r"(?:0|[1-9][0-9]*)\Z"
    require(
        re.fullmatch(pattern, raw) is not None,
        f"{label} is not canonical decimal",
    )
    value = int(raw, 10)
    require(value <= maximum, f"{label} exceeds its unsigned range")
    return value


def marker_lines(log: str, prefix: str, label: str) -> list[tuple[int, str]]:
    markers: list[tuple[int, str]] = []
    for index, line in enumerate(log.splitlines()):
        if prefix not in line:
            continue
        require(line.startswith(prefix), f"{label} prefix is not at line start")
        require(line.isascii(), f"{label} is not ASCII")
        require(
            len(line.encode("ascii")) < 255,
            f"{label} exceeds the strict 254-byte marker limit",
        )
        markers.append((index, line))
    return markers


def parse_pass(index: int, line: str, expected_sha: str) -> LinearHDRPass:
    match = PASS_RE.fullmatch(line)
    require(match is not None, "linear-HDR terminal marker is not exact")
    build, generation, sequence, width, height, ui = match.groups()
    require(build == expected_sha, "linear-HDR terminal marker has foreign build SHA")
    parsed = LinearHDRPass(
        line_index=index,
        build=build,
        generation=parse_uint(
            generation, "linear-HDR generation", UINT64_MAX, positive=True
        ),
        snapshot_sequence=parse_uint(
            sequence, "linear-HDR snapshot sequence", UINT64_MAX, positive=True
        ),
        width=parse_uint(width, "linear-HDR width", UINT32_MAX, positive=True),
        height=parse_uint(height, "linear-HDR height", UINT32_MAX, positive=True),
        ui=int(ui, 10),
    )
    require(
        parsed.byte_size <= UINT64_MAX,
        "linear-HDR target byte size overflows uint64",
    )
    return parsed


def parse_activation(index: int, line: str) -> LinearHDRActivation:
    match = ACTIVATION_RE.fullmatch(line)
    require(match is not None, "linear-HDR activation marker is not exact")
    (
        attempt,
        probe,
        target,
        scene,
        resolve,
        ready,
        safe,
        byte_size,
        generation,
    ) = match.groups()
    return LinearHDRActivation(
        line_index=index,
        attempt=attempt,
        probe=int(probe, 10),
        target=int(target, 10),
        scene=int(scene, 10),
        resolve=int(resolve, 10),
        ready=int(ready, 10),
        safe=int(safe, 10),
        byte_size=parse_uint(
            byte_size, "linear-HDR activation bytes", UINT64_MAX, positive=False
        ),
        generation=parse_uint(
            generation,
            "linear-HDR activation generation",
            UINT64_MAX,
            positive=False,
        ),
    )


def validate(
    log: str,
    expected_sha: str,
    require_attempt: str,
    require_ui: bool = False,
) -> dict[str, int | str]:
    require(
        SHA_RE.fullmatch(expected_sha) is not None,
        "expected SHA must be exact lowercase 40-hex",
    )
    require(
        require_attempt in ("startup", "recreate"),
        "required attempt must be startup or recreate",
    )
    denied = DENY_RE.search(log)
    require(
        denied is None,
        "terminal failure or crash signature appeared"
        if denied is None
        else f"terminal failure or crash signature appeared: {denied.group(0)!r}",
    )

    raw_passes = marker_lines(log, PASS_PREFIX, "linear-HDR terminal marker")
    require(
        len(raw_passes) == 1,
        f"expected exactly one linear-HDR terminal PASS, found {len(raw_passes)}",
    )
    terminal = parse_pass(*raw_passes[0], expected_sha)
    if require_ui:
        require(terminal.ui == 1, "linear-HDR terminal PASS does not prove UI")

    activations = [
        parse_activation(index, line)
        for index, line in marker_lines(
            log, ACTIVATION_PREFIX, "linear-HDR activation marker"
        )
    ]
    correlated = [
        activation
        for activation in activations
        if activation.successful
        and activation.attempt == require_attempt
        and activation.generation == terminal.generation
        and activation.byte_size == terminal.byte_size
    ]
    require(
        len(correlated) == 1,
        "expected exactly one successful required activation for terminal generation "
        f"and byte size, found {len(correlated)}",
    )
    require(
        correlated[0].line_index < terminal.line_index,
        "successful linear-HDR activation does not precede terminal PASS",
    )

    return {
        "result": "PASS",
        "build": terminal.build,
        "attempt": correlated[0].attempt,
        "generation": terminal.generation,
        "snapshot_sequence": terminal.snapshot_sequence,
        "width": terminal.width,
        "height": terminal.height,
        "bytes": terminal.byte_size,
        "ui": terminal.ui,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate RendererIOS linear-HDR terminal evidence"
    )
    parser.add_argument("log", type=pathlib.Path)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument(
        "--require-attempt", required=True, choices=("startup", "recreate")
    )
    parser.add_argument("--require-ui", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    values = validate(
        args.log.read_text(encoding="utf-8"),
        args.expected_sha,
        args.require_attempt,
        args.require_ui,
    )
    print(
        "linear-HDR log passed: "
        f"build={values['build']} attempt={values['attempt']} "
        f"g={values['generation']} s={values['snapshot_sequence']} "
        f"w={values['width']} h={values['height']} "
        f"bytes={values['bytes']} ui={values['ui']}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
