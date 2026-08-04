#!/usr/bin/env python3
"""Fail-closed source contract for bounded CoreDevice file queries."""

from __future__ import annotations

import pathlib
import re
import sys


RAW = "xcrun devicectl device info files"
CALL = 'run_bounded_device_file_query --device "$DEVICE"'
TIMEOUT = "readonly DEVICECTL_FILE_QUERY_TIMEOUT_SECONDS=30"
HELPER = re.compile(
    r"run_bounded_device_file_query\(\) \{\n"
    r"\s+run_bounded_command \"\$DEVICECTL_FILE_QUERY_TIMEOUT_SECONDS\" \\\n"
    r"\s+xcrun devicectl device info files \"\$@\"\n"
    r"\}"
)


def active_source(source: str) -> str:
    return "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("#")
    )


def validate(source: str) -> None:
    active = active_source(source)
    if active.count(TIMEOUT) != 1:
        raise ValueError("file-query timeout contract drifted")
    if len(HELPER.findall(active)) != 1:
        raise ValueError("bounded file-query helper drifted")
    if active.count(RAW) != 1:
        raise ValueError("raw device file query escaped the helper")
    if active.count(CALL) != 10:
        raise ValueError("not every device file query uses the bounded helper")


def expect_rejected(source: str, label: str) -> None:
    try:
        validate(source)
    except ValueError:
        return
    raise SystemExit(f"mutation survived: {label}")


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    path = root / "ios/device-test/run-smoke-test.sh"
    source = path.read_text(encoding="utf-8")
    validate(source)
    validate(source + f"\n# benign decoy: {RAW}\n")

    mutations = [
        (source.replace(TIMEOUT, "", 1), "drop-timeout"),
        (
            source.replace(
                'run_bounded_command "$DEVICECTL_FILE_QUERY_TIMEOUT_SECONDS"',
                "run_bounded_command 0",
                1,
            ),
            "invalid-timeout",
        ),
        (source.replace('device info files "$@"', "device info files", 1), "drop-args"),
    ]
    offset = 0
    for index in range(10):
        position = source.find(CALL, offset)
        if position < 0:
            raise SystemExit("fixture has fewer than ten bounded call sites")
        mutated = source[:position] + RAW + ' --device "$DEVICE"' + source[position + len(CALL):]
        mutations.append((mutated, f"raw-call-{index + 1}"))
        offset = position + len(CALL)

    for mutated, label in mutations:
        expect_rejected(mutated, label)
    print(f"device file-query bounds contract: PASS ({len(mutations)} mutations killed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
