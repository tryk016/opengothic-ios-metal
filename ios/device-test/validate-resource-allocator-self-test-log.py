#!/usr/bin/env python3
"""Validate the allocation-only RendererIOS resource allocator device gate."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


CASE = "private-memoryless-4x4-rgba8-v1"
ARMED = f"RendererIOS resource allocator self-test: ARMED case={CASE}"
PASS = (
    f"RendererIOS resource allocator self-test: PASS case={CASE} "
    "allocation-only=1 encoded=0 render-pass=0 submitted=0 "
    "created=2 live=0 released=2"
)
PREFIX = "RendererIOS resource allocator self-test:"
FAIL_PREFIX = f"RendererIOS resource allocator self-test: FAIL case={CASE}"
SHELL_RE = re.compile(
    r"^RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*$",
    re.MULTILINE,
)
CONFIGURED_RE = re.compile(
    r"^RendererIOS configured fault mode=([^\s]+)$",
    re.MULTILINE,
)
DIAGNOSTICS = (
    "RendererIOS diagnostics: ON frames-in-flight="
)
DENY_RE = re.compile(
    r"RendererIOS (?:fatal|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed|"
    r"resource allocator self-test: FAIL)|"
    r"libc\+\+abi: terminating|SIGABRT|EXC_BAD_ACCESS|AddressSanitizer|"
    r"ThreadSanitizer|UndefinedBehaviorSanitizer|uncaught exception|"
    r"terminate called|std::terminate|jetsam",
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


def validate(log: str, stderr: str, expected_build: str) -> dict[str, int | str]:
    require(
        re.fullmatch(r"[0-9a-f]{40}(?:-local)?", expected_build) is not None,
        "expected build must be a lowercase SHA, optionally suffixed -local",
    )

    shell = only_match(SHELL_RE, log, "RendererIOS shell marker")
    require(shell.group(1) == expected_build, "RendererIOS shell build is not exact")
    configured = only_match(CONFIGURED_RE, log, "configured fault marker")
    require(configured.group(1) == "none", "resource allocator self-test requires fault none")

    diagnostic_lines = [
        line for line in log.splitlines() if line.startswith("RendererIOS diagnostics:")
    ]
    require(len(diagnostic_lines) == 1, "expected exactly one diagnostics marker")
    require(
        diagnostic_lines[0].startswith(DIAGNOSTICS)
        and diagnostic_lines[0].endswith(" context=IOSMetalContext transport=Tempest"),
        "resource allocator self-test requires diagnostics ON",
    )

    self_test_lines = [line for line in log.splitlines() if line.startswith(PREFIX)]
    require(
        self_test_lines == [ARMED, PASS],
        "resource allocator self-test markers are missing, malformed, duplicated, or out of order",
    )
    require(log.count(FAIL_PREFIX) == 0, "resource allocator self-test reported FAIL")
    require(
        "RendererIOS Bink self-test:" not in log,
        "resource allocator and Bink self-tests ran in the same build",
    )
    require(
        "RendererIOS fault injection armed:" not in log
        and "RendererIOS fault injection fired:" not in log,
        "resource allocator self-test ran with a fault profile",
    )

    denied = DENY_RE.search(log + "\n" + stderr)
    require(
        denied is None,
        "fatal/crash signature in resource allocator self-test evidence"
        if denied is None
        else f"fatal/crash signature in resource allocator self-test evidence: {denied.group(0)!r}",
    )

    return {
        "resource_allocator_self_test_expected_build": expected_build,
        "resource_allocator_self_test_armed_count": 1,
        "resource_allocator_self_test_pass_count": 1,
        "resource_allocator_self_test_fail_count": 0,
        "resource_allocator_self_test_created": 2,
        "resource_allocator_self_test_live": 0,
        "resource_allocator_self_test_released": 2,
        "resource_allocator_self_test_allocation_only": 1,
    }


def validate_absent(log: str) -> None:
    markers = [line for line in log.splitlines() if line.startswith(PREFIX)]
    require(
        not markers,
        f"unrequested resource allocator self-test marker(s): {markers!r}",
    )


def write_summary(path: pathlib.Path, values: dict[str, int | str]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
    )


def fixture(build: str) -> str:
    return "\n".join(
        (
            "RendererIOS configured fault mode=none",
            "RendererIOS shell: version=1 profile=Safe features=native-landscape-textured,ui "
            f"build={build} gpu=Apple deviceFamily=iPhone16,2 iOS=26.4 "
            "faultMode=none savePreviewRoute=cpu-placeholder",
            "RendererIOS diagnostics: ON frames-in-flight=3 "
            "context=IOSMetalContext transport=Tempest",
            ARMED,
            PASS,
        )
    ) + "\n"


def self_test() -> None:
    build = "0123456789abcdef0123456789abcdef01234567-local"
    valid = fixture(build)
    values = validate(valid, "", build)
    require(values["resource_allocator_self_test_released"] == 2, "valid fixture failed")
    validate_absent("plain RendererIOS smoke log\n")

    mutations = {
        "missing-armed": valid.replace(ARMED + "\n", ""),
        "duplicate-pass": valid + PASS + "\n",
        "wrong-created": valid.replace("created=2", "created=1"),
        "live-owner": valid.replace("live=0 released=2", "live=1 released=1"),
        "encoded": valid.replace("encoded=0", "encoded=1"),
        "reordered": valid.replace(ARMED + "\n" + PASS, PASS + "\n" + ARMED),
        "fail-marker": valid + FAIL_PREFIX + " detail=allocation-returned-nil\n",
        "bink-conflict": valid + "RendererIOS Bink self-test: ARMED case=x\n",
        "fault-conflict": valid + "RendererIOS fault injection armed: mode=x build=x\n",
        "fatal": valid + "RendererIOS fatal: resource allocation failed\n",
    }
    for name, mutated in mutations.items():
        try:
            validate(mutated, "", build)
        except ValidationError:
            continue
        raise ValidationError(f"mutation survived: {name}")

    absent_mutations = {
        "armed": ARMED + "\n",
        "pass": PASS + "\n",
        "fail": FAIL_PREFIX + " reason=test\n",
        "unknown": PREFIX + " UNKNOWN case=test\n",
    }
    for name, mutated in absent_mutations.items():
        try:
            validate_absent("plain RendererIOS smoke log\n" + mutated)
        except ValidationError:
            continue
        raise ValidationError(f"unrequested marker mutation survived: {name}")

    try:
        validate(valid, "SIGABRT", build)
    except ValidationError:
        pass
    else:
        raise ValidationError("stderr crash mutation survived")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--expected-build")
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
            and args.summary is None
            and not args.expect_absent,
            "--self-test accepts no evidence arguments",
        )
        self_test()
        print("resource allocator self-test validator passed")
        return 0

    require(args.log is not None, "--log is required")
    if args.expect_absent:
        require(args.stderr is None, "--expect-absent does not accept --stderr")
        require(
            args.expected_build is None,
            "--expect-absent does not accept --expected-build",
        )
        require(args.summary is None, "--expect-absent does not accept --summary")
        validate_absent(args.log.read_text(encoding="utf-8", errors="replace"))
        print("resource allocator self-test markers absent")
        return 0
    require(args.expected_build is not None, "--expected-build is required")
    log = args.log.read_text(encoding="utf-8", errors="replace")
    stderr = ""
    if args.stderr is not None:
        stderr = args.stderr.read_text(encoding="utf-8", errors="replace")
    values = validate(log, stderr, args.expected_build)
    if args.summary is not None:
        write_summary(args.summary, values)
    print("resource allocator self-test log passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
