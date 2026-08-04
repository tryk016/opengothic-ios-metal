#!/usr/bin/env python3
"""Validate scenario-neutral native textured-draw evidence."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any


PREFIX = "RendererIOS native scene material-drawn:"
LINE_RE = re.compile(
    r"^RendererIOS native scene material-drawn: "
    r"mode=(\S+) total=(0|[1-9][0-9]*) opaque=(0|[1-9][0-9]*) "
    r"alpha=(0|[1-9][0-9]*) textured=(0|[1-9][0-9]*)$"
)


class ValidationError(RuntimeError):
    """Raised when native draw evidence is absent or inconsistent."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def validate(log: str) -> dict[str, Any]:
    blocks = 0
    maximum_total = 0
    for line in log.splitlines():
        if not line.startswith(PREFIX):
            continue
        match = LINE_RE.fullmatch(line)
        require(match is not None, "malformed native material-drawn marker")
        mode, total_text, opaque_text, alpha_text, textured_text = match.groups()
        if mode != "production":
            continue
        total = int(total_text)
        opaque = int(opaque_text)
        alpha = int(alpha_text)
        textured = int(textured_text)
        require(total > 0, "production native draw total is zero")
        require(opaque + alpha == total,
                "production native draw category conservation failed")
        require(textured == total,
                "production native draw texture coverage is incomplete")
        blocks += 1
        maximum_total = max(maximum_total, total)
    require(blocks > 0, "no production native textured-draw marker")
    return {
        "result": "PASS",
        "productionBlocks": blocks,
        "maximumTotal": maximum_total,
    }


def expect_invalid(log: str, name: str) -> None:
    try:
        validate(log)
    except ValidationError:
        return
    raise ValidationError(f"self-test mutation survived: {name}")


def run_self_test() -> dict[str, Any]:
    valid = (
        "ordinary output\n"
        "RendererIOS native scene material-drawn: mode=production "
        "total=3 opaque=1 alpha=2 textured=3\n"
    )
    result = validate(valid)
    mutations = {
        "missing-current": "ordinary output\n",
        "old-marker-only": (
            "RendererIOS native Landscape: draws=3 textured=3\n"
        ),
        "foreign-mode": valid.replace("mode=production", "mode=self-test"),
        "zero-total": valid.replace(
            "total=3 opaque=1 alpha=2 textured=3",
            "total=0 opaque=0 alpha=0 textured=0",
        ),
        "texture-coverage": valid.replace("textured=3", "textured=2"),
        "category-conservation": valid.replace("opaque=1", "opaque=2"),
    }
    for name, mutation in mutations.items():
        expect_invalid(mutation, name)

    runner = pathlib.Path(__file__).with_name("run-smoke-test.sh")
    source = runner.read_text(encoding="utf-8", errors="strict")
    require(source.count("validate-native-textured-draw-log.py") == 1,
            "smoke runner does not invoke the validator exactly once")
    require("RendererIOS native Landscape: .*draws=" not in source,
            "smoke runner still accepts the removed Landscape marker")
    return {"result": "PASS", "mutations": len(mutations), **result}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--log", type=pathlib.Path)
    group.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.self_test:
        result = run_self_test()
    else:
        result = validate(arguments.log.read_text(
            encoding="utf-8", errors="strict"))
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
