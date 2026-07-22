#!/usr/bin/env python3
"""Validate the canonical RendererIOS ID5 post-submit recovery log."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


FAULT_MODE = "post-submit-suboptimal"
FAULT_POINT = "post-submit-pre-present"
MIN_CONTIGUOUS_PRESENTS = 300

SHELL_RE = re.compile(
    r"^RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*$",
    re.MULTILINE,
)
CONFIGURED_FAULT_RE = re.compile(
    r"^RendererIOS configured fault mode=([^\s]+)$",
    re.MULTILINE,
)
DIAGNOSTICS_RE = re.compile(
    r"^RendererIOS diagnostics: ON frames-in-flight=(\d+) "
    r"context=IOSMetalContext transport=Tempest$",
    re.MULTILINE,
)
ARMED_RE = re.compile(
    r"^RendererIOS fault injection armed: mode=([^\s]+) build=([^\s]+)$",
    re.MULTILINE,
)
FIRED_RE = re.compile(
    r"^RendererIOS fault injection fired: mode=([^\s]+) "
    r"point=([^\s]+) build=([^\s]+)$",
    re.MULTILINE,
)
RESET_RE = re.compile(
    r"^swapchain is outdated - reset renderer$",
    re.MULTILINE,
)
RESIZE_SETTLED_RE = re.compile(
    r"^RendererIOS lifecycle counters: transition=resize-settled "
    r"idle-confirmed=(\d+) submit-attempts=(\d+) submit-accepted=(\d+) "
    r"present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
PRESENT_RE = re.compile(
    r"^RendererIOS runtime compilation: point=frame presents=(\d+) "
    r"available=(\d+) source=(\d+) compute=(\d+) render=(\d+)$",
    re.MULTILINE,
)
LOG_DENY_RE = re.compile(
    r"RendererIOS (?:fatal|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed|"
    r"resume swapchain reset failed|native Landscape encode failed|"
    r"IOSGPUScene metallib loading failed)|swapchain reset failed|"
    r"reset renderer failed|"
    r"libc\+\+abi: terminating|SIGABRT|EXC_BAD_ACCESS|AddressSanitizer|"
    r"ThreadSanitizer|UndefinedBehaviorSanitizer|DeviceLostException|"
    r"DeviceHangException|device[- ]lost|out[- ]of[- ]memory|\bOOM\b|"
    r"\btimeout\b|timed out|unhandled (?:non-std/ObjC )?exception in render loop|"
    r"uncaught exception|terminate called|std::terminate|"
    r"jetsam",
    re.IGNORECASE,
)
STDERR_DENY_RE = re.compile(
    r"RendererIOS (?:fatal|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed|"
    r"resume swapchain reset failed|native Landscape encode failed|"
    r"IOSGPUScene metallib loading failed)|swapchain reset failed|"
    r"reset renderer failed|"
    r"libc\+\+abi: terminating|SIGABRT|EXC_BAD_ACCESS|AddressSanitizer|"
    r"ThreadSanitizer|UndefinedBehaviorSanitizer|DeviceLostException|"
    r"DeviceHangException|device[- ]lost|out[- ]of[- ]memory|\bOOM\b|"
    r"\btimeout\b|timed out|unhandled (?:non-std/ObjC )?exception in render loop|"
    r"uncaught exception|terminate called|std::terminate|"
    r"jetsam",
    re.IGNORECASE,
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def one_match(log: str, pattern: re.Pattern[str], name: str) -> re.Match[str]:
    matches = list(pattern.finditer(log))
    require(len(matches) == 1, f"expected exactly one {name}, found {len(matches)}")
    return matches[0]


def require_exact_marker_count(log: str, prefix: str, expected: int = 1) -> None:
    count = sum(line.startswith(prefix) for line in log.splitlines())
    require(count == expected, f"expected {expected} {prefix!r} marker(s), found {count}")


def validate(
    log: str,
    stderr: str,
    expected_build: str,
    expected_fault: str = FAULT_MODE,
) -> dict[str, int | str]:
    require(
        re.fullmatch(r"[0-9a-f]{40}(?:-local)?", expected_build) is not None,
        "expected build must be a 40-character lowercase SHA, optionally suffixed -local",
    )
    require(expected_fault == FAULT_MODE, f"unsupported fault oracle: {expected_fault}")

    require_exact_marker_count(log, "RendererIOS configured fault mode=")
    require_exact_marker_count(log, "RendererIOS shell: version=")
    require_exact_marker_count(log, "RendererIOS diagnostics:")
    require_exact_marker_count(log, "RendererIOS fault injection armed:")
    require_exact_marker_count(log, "RendererIOS fault injection fired:")
    require_exact_marker_count(log, "swapchain is outdated - reset renderer")
    require_exact_marker_count(
        log,
        "RendererIOS lifecycle counters: transition=resize-settled",
    )

    configured_fault = one_match(
        log,
        CONFIGURED_FAULT_RE,
        "configured fault mode marker",
    )
    require(
        configured_fault.group(1) == expected_fault,
        "configured fault mode is not exact",
    )

    shell = one_match(log, SHELL_RE, "RendererIOS shell marker")
    require(shell.group(1) == expected_build, "RendererIOS shell build is not exact")

    diagnostics = one_match(log, DIAGNOSTICS_RE, "diagnostics ON marker")
    require(int(diagnostics.group(1)) in (2, 3), "unexpected frames-in-flight value")

    armed = one_match(log, ARMED_RE, "fault armed marker")
    require(
        armed.groups() == (expected_fault, expected_build),
        "fault armed mode/build is not exact",
    )

    fired = one_match(log, FIRED_RE, "fault fired marker")
    require(
        fired.groups() == (expected_fault, FAULT_POINT, expected_build),
        "fault fired mode/point/build is not exact",
    )

    reset = one_match(log, RESET_RE, "recoverable reset attempt")
    settled = one_match(log, RESIZE_SETTLED_RE, "resize-settled marker")
    require(
        tuple(map(int, settled.groups())) == (1, 1, 1, 0, 0),
        "resize-settled counters do not prove one accepted submit and no present",
    )

    positions = (
        configured_fault.start(),
        shell.start(),
        diagnostics.start(),
        armed.start(),
        fired.start(),
        reset.start(),
        settled.start(),
    )
    require(positions == tuple(sorted(positions)), "ID5 recovery markers are out of order")
    require(len(set(positions)) == len(positions), "ID5 recovery markers overlap")

    presents = [
        (match.start(),) + tuple(map(int, match.groups()))
        for match in PRESENT_RE.finditer(log)
    ]
    require(
        len(presents)
        == sum(
            line.startswith("RendererIOS runtime compilation: point=frame ")
            for line in log.splitlines()
        ),
        "malformed runtime compilation present marker",
    )
    require(presents, "no runtime compilation present markers found")
    require(
        all(position > settled.start() for position, *_ in presents),
        "a presented frame precedes successful resize settlement",
    )
    present_numbers = [present for _, present, *_ in presents]
    require(present_numbers[0] == 1, "post-reset present sequence does not start at 1")
    require(
        present_numbers == list(range(1, present_numbers[-1] + 1)),
        "post-reset present sequence is not contiguous",
    )
    require(
        present_numbers[-1] >= MIN_CONTIGUOUS_PRESENTS,
        f"fewer than {MIN_CONTIGUOUS_PRESENTS} contiguous post-reset presents",
    )
    for _, present, available, source, compute, render in presents:
        require(available == 1, f"runtime counters unavailable at present {present}")
        require(source == 0 and compute == 0, f"runtime compilation grew at present {present}")
        require(render in (2, 3), f"unexpected render counter at present {present}")

    denied = LOG_DENY_RE.search(log)
    require(
        denied is None,
        "fatal/reset-failed signature in log"
        if denied is None
        else f"fatal/reset-failed signature in log: {denied.group(0)!r}",
    )

    # stderr is deliberately denylist-only. Tempest may mirror the expected
    # fired/reset lines there; those copies must not be counted as extra events.
    denied_stderr = STDERR_DENY_RE.search(stderr)
    require(
        denied_stderr is None,
        "fatal/reset-failed signature in stderr"
        if denied_stderr is None
        else f"fatal/reset-failed signature in stderr: {denied_stderr.group(0)!r}",
    )

    reset_counts = tuple(map(int, settled.groups()))
    baseline_present = reset_counts[4]
    max_present = present_numbers[-1]
    return {
        "id5_expected_build": expected_build,
        "id5_expected_fault": expected_fault,
        "id5_armed_count": 1,
        "id5_fired_count": 1,
        "id5_reset_attempt_count": 1,
        "id5_resize_settled_count": 1,
        "id5_reset_idle_confirmed": reset_counts[0],
        "id5_reset_submit_attempts": reset_counts[1],
        "id5_reset_submit_accepted": reset_counts[2],
        "id5_reset_present_attempts": reset_counts[3],
        "id5_reset_present_accepted": reset_counts[4],
        "id5_reset_present_baseline": baseline_present,
        "id5_post_reset_first_present": present_numbers[0],
        "id5_post_reset_max_present": max_present,
        "id5_post_reset_present_delta": max_present - baseline_present,
        "id5_post_reset_contiguous_presents": len(present_numbers),
    }


def write_summary(path: pathlib.Path, values: dict[str, int | str]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
    )


def fixture(build: str, presents: int = 305) -> str:
    lines = [
        f"RendererIOS configured fault mode={FAULT_MODE}",
        "RendererIOS shell: version=1 profile=Safe features=native-landscape-textured,ui "
        f"build={build} gpu=Apple deviceFamily=iPhone16,2 iOS=26.6 "
        f"faultMode={FAULT_MODE} savePreviewRoute=cpu-placeholder",
        "RendererIOS diagnostics: ON frames-in-flight=3 context=IOSMetalContext transport=Tempest",
        f"RendererIOS fault injection armed: mode={FAULT_MODE} build={build}",
        f"RendererIOS fault injection fired: mode={FAULT_MODE} point={FAULT_POINT} build={build}",
        "swapchain is outdated - reset renderer",
        "RendererIOS lifecycle counters: transition=resize-settled idle-confirmed=1 "
        "submit-attempts=1 submit-accepted=1 present-attempts=0 present-accepted=0",
    ]
    for present in range(1, presents + 1):
        lines.append(
            "RendererIOS runtime compilation: point=frame "
            f"presents={present} available=1 source=0 compute=0 render=2"
        )
        if present == 300:
            lines.append("RendererIOS shell: 300 present calls submitted")
    return "\n".join(lines) + "\n"


def self_test() -> None:
    build = "0123456789abcdef0123456789abcdef01234567"
    base = fixture(build)
    wrapped_shell = base.replace(
        f"faultMode={FAULT_MODE}",
        "faultMode=post-submi\nt-suboptimal",
        1,
    )
    mirrored_stderr = (
        f"RendererIOS fault injection fired: mode={FAULT_MODE} "
        f"point={FAULT_POINT} build={build}\n"
        "swapchain is outdated - reset renderer\n"
    )
    values = validate(base, mirrored_stderr, build)
    validate(wrapped_shell, mirrored_stderr, build)
    require(values["id5_armed_count"] == 1, "summary lost armed count")
    require(values["id5_fired_count"] == 1, "summary lost fired count")
    require(values["id5_reset_attempt_count"] == 1, "summary lost reset count")
    require(values["id5_resize_settled_count"] == 1, "summary lost settled count")
    require(values["id5_reset_present_baseline"] == 0, "summary baseline is not zero")
    require(values["id5_post_reset_max_present"] == 305, "summary max present is wrong")
    require(values["id5_post_reset_present_delta"] == 305, "summary delta is wrong")

    replacements = {
        "missing-shell": base.replace("RendererIOS shell:", "missing shell:", 1),
        "wrong-build": base.replace(f"build={build}", f"build={'f' * 40}", 1),
        "missing-configured": base.replace(
            f"RendererIOS configured fault mode={FAULT_MODE}\n", "", 1
        ),
        "duplicate-configured": base.replace(
            f"RendererIOS configured fault mode={FAULT_MODE}\n",
            f"RendererIOS configured fault mode={FAULT_MODE}\n" * 2,
            1,
        ),
        "wrong-configured": base.replace(
            f"RendererIOS configured fault mode={FAULT_MODE}",
            "RendererIOS configured fault mode=none",
            1,
        ),
        "missing-diagnostics": base.replace("RendererIOS diagnostics: ON", "RendererIOS diagnostics: OFF", 1),
        "bad-frame-count": base.replace("frames-in-flight=3", "frames-in-flight=4", 1),
        "missing-armed": base.replace(f"RendererIOS fault injection armed: mode={FAULT_MODE} build={build}\n", "", 1),
        "duplicate-armed": base.replace(f"RendererIOS fault injection armed: mode={FAULT_MODE} build={build}\n", f"RendererIOS fault injection armed: mode={FAULT_MODE} build={build}\n" * 2, 1),
        "wrong-fired-point": base.replace(f"point={FAULT_POINT}", "point=before-submit", 1),
        "duplicate-fired": base.replace(f"RendererIOS fault injection fired: mode={FAULT_MODE} point={FAULT_POINT} build={build}\n", f"RendererIOS fault injection fired: mode={FAULT_MODE} point={FAULT_POINT} build={build}\n" * 2, 1),
        "missing-reset": base.replace("swapchain is outdated - reset renderer\n", "", 1),
        "duplicate-reset": base.replace("swapchain is outdated - reset renderer\n", "swapchain is outdated - reset renderer\n" * 2, 1),
        "missing-settled": base.replace("transition=resize-settled", "transition=resize-missing", 1),
        "duplicate-settled": base.replace("RendererIOS lifecycle counters: transition=resize-settled idle-confirmed=1 submit-attempts=1 submit-accepted=1 present-attempts=0 present-accepted=0\n", "RendererIOS lifecycle counters: transition=resize-settled idle-confirmed=1 submit-attempts=1 submit-accepted=1 present-attempts=0 present-accepted=0\n" * 2, 1),
        "idle-unconfirmed": base.replace("idle-confirmed=1", "idle-confirmed=0", 1),
        "wrong-submit-attempts": base.replace("submit-attempts=1", "submit-attempts=2", 1),
        "wrong-submit-accepted": base.replace("submit-accepted=1", "submit-accepted=0", 1),
        "wrong-present-attempts": base.replace("present-attempts=0", "present-attempts=1", 1),
        "wrong-present-accepted": base.replace("present-accepted=0", "present-accepted=1", 1),
        "reset-before-fired": base.replace(
            f"RendererIOS fault injection fired: mode={FAULT_MODE} point={FAULT_POINT} build={build}\nswapchain is outdated - reset renderer",
            f"swapchain is outdated - reset renderer\nRendererIOS fault injection fired: mode={FAULT_MODE} point={FAULT_POINT} build={build}",
            1,
        ),
        "settled-before-reset": base.replace(
            "swapchain is outdated - reset renderer\nRendererIOS lifecycle counters: transition=resize-settled idle-confirmed=1 submit-attempts=1 submit-accepted=1 present-attempts=0 present-accepted=0",
            "RendererIOS lifecycle counters: transition=resize-settled idle-confirmed=1 submit-attempts=1 submit-accepted=1 present-attempts=0 present-accepted=0\nswapchain is outdated - reset renderer",
            1,
        ),
        "present-before-settled": base.replace(
            "swapchain is outdated - reset renderer\n",
            "RendererIOS runtime compilation: point=frame presents=1 available=1 source=0 compute=0 render=2\nswapchain is outdated - reset renderer\n",
            1,
        ),
        "present-gap": base.replace("point=frame presents=151 ", "point=frame presents=152 ", 1),
        "too-few-presents": fixture(build, MIN_CONTIGUOUS_PRESENTS - 1),
        "fatal": base + "RendererIOS fatal: unexpected\n",
        "reset-failed": base + "RendererIOS resize failed: injected\n",
        "swapchain-reset-failed": base + "swapchain reset failed: injected\n",
        "swapchain-reset-nonstd-failed": base + "swapchain reset failed with a non-std/ObjC exception: injected\n",
        "timeout": base + "Metal command buffer timeout\n",
        "oom": base + "GPU out of memory\n",
        "device-lost": base + "DeviceLostException\n",
        "exception-stop": base + "RendererIOS stopped the frame loop\n",
        "render-loop-exception": base + "unhandled exception in render loop\n",
        "render-loop-nonstd-exception": base + "unhandled non-std/ObjC exception in render loop\n",
    }
    stderr_mutations = {
        "stderr-fatal": "RendererIOS fatal: unexpected\n",
        "stderr-crash": "libc++abi: terminating due to uncaught exception\n",
        "stderr-reset-failed": "RendererIOS resize failed: injected\n",
        "stderr-swapchain-reset-failed": "swapchain reset failed: injected\n",
        "stderr-swapchain-reset-nonstd-failed": "swapchain reset failed with a non-std/ObjC exception: injected\n",
        "stderr-timeout": "Metal command buffer timeout\n",
        "stderr-oom": "GPU out of memory\n",
        "stderr-device-lost": "DeviceLostException\n",
        "stderr-exception-stop": "RendererIOS stopped the frame loop\n",
        "stderr-render-loop-exception": "unhandled exception in render loop\n",
        "stderr-render-loop-nonstd-exception": "unhandled non-std/ObjC exception in render loop\n",
    }

    killed = 0
    for name, mutated in replacements.items():
        try:
            validate(mutated, mirrored_stderr, build)
        except ValidationError:
            killed += 1
        else:
            raise AssertionError(f"self-test mutation survived: {name}")
    for name, mutated_stderr in stderr_mutations.items():
        try:
            validate(base, mutated_stderr, build)
        except ValidationError:
            killed += 1
        else:
            raise AssertionError(f"self-test stderr mutation survived: {name}")

    print(f"fault log self-test passed: mutations-killed={killed}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-fault", default=FAULT_MODE)
    parser.add_argument("--summary", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        if (
            args.log is not None
            or args.stderr is not None
            or args.expected_build is not None
            or args.summary is not None
        ):
            parser.error("--self-test does not accept log/build inputs")
        return args
    if args.log is None or args.expected_build is None or args.summary is None:
        parser.error("--log, --expected-build and --summary are required")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            self_test()
        else:
            log = args.log.read_text(errors="replace")
            stderr = ""
            if args.stderr is not None and args.stderr.exists():
                stderr = args.stderr.read_text(errors="replace")
            values = validate(log, stderr, args.expected_build, args.expected_fault)
            write_summary(args.summary, values)
    except (OSError, ValidationError, AssertionError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
