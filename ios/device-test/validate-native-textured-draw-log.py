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
    r"alpha=(0|[1-9][0-9]*) additive=(0|[1-9][0-9]*) "
    r"multiply2=(0|[1-9][0-9]*) trans=(0|[1-9][0-9]*) "
    r"textured=(0|[1-9][0-9]*)$"
)
KIND_PREFIX = "RendererIOS native scene kind-drawn:"
KIND_RE = re.compile(
    r"^RendererIOS native scene kind-drawn: mode=(\S+) "
    r"total=(0|[1-9][0-9]*) landscape=(0|[1-9][0-9]*) "
    r"static=(0|[1-9][0-9]*) movable=(0|[1-9][0-9]*) "
    r"animated=(0|[1-9][0-9]*) morph=(0|[1-9][0-9]*)$"
)


class ValidationError(RuntimeError):
    """Raised when native draw evidence is absent or inconsistent."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def validate(log: str) -> dict[str, Any]:
    blocks = 0
    maximum_total = 0
    pending_total = None
    for line in log.splitlines():
        if line.startswith("RendererIOS native scene identity:"):
            require(pending_total is None, "native draw block lacks kind counts")
        if line.startswith(KIND_PREFIX) and pending_total is not None:
            match = KIND_RE.fullmatch(line)
            require(match is not None, "malformed native kind-drawn marker")
            mode, *values = match.groups()
            total, *kinds = map(int, values)
            require(mode == "production" and total == pending_total,
                    "native material/kind draw identity differs")
            require(sum(kinds) == total, "native draw kind conservation failed")
            blocks += 1
            maximum_total = max(maximum_total, total)
            pending_total = None
            continue
        if not line.startswith(PREFIX):
            continue
        require(pending_total is None, "native draw block lacks kind counts")
        match = LINE_RE.fullmatch(line)
        require(match is not None, "malformed native material-drawn marker")
        (mode, total_text, opaque_text, alpha_text, additive_text,
         multiply2_text, transparent_text, textured_text) = match.groups()
        if mode != "production":
            continue
        total = int(total_text)
        opaque = int(opaque_text)
        alpha = int(alpha_text)
        additive = int(additive_text)
        multiply2 = int(multiply2_text)
        transparent = int(transparent_text)
        textured = int(textured_text)
        require(total > 0, "production native draw total is zero")
        # This marker omits water/ghost/blend counters. The paired kind marker
        # covers every draw and supplies the complete conservation check.
        require(opaque + alpha + additive + multiply2 + transparent <= total,
                "production native material counters exceed total")
        require(textured == total,
                "production native draw texture coverage is incomplete")
        pending_total = total
    require(pending_total is None, "native draw block lacks kind counts")
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
        "total=6 opaque=1 alpha=2 additive=2 multiply2=1 trans=0 textured=6\n"
        "RendererIOS native scene kind-drawn: mode=production "
        "total=6 landscape=1 static=2 movable=1 animated=1 morph=1\n"
    )
    result = validate(valid)
    # Actual iPhone frame includes four water draws absent from material fields.
    validate(
        "RendererIOS native scene material-drawn: mode=production "
        "total=5473 opaque=3719 alpha=1706 additive=19 multiply2=0 trans=25 textured=5473\n"
        "RendererIOS native scene kind-drawn: mode=production "
        "total=5473 landscape=198 static=2144 movable=431 animated=1563 morph=1137\n"
    )
    mutations = {
        "missing-current": "ordinary output\n",
        "old-marker-only": (
            "RendererIOS native Landscape: draws=3 textured=3\n"
        ),
        "foreign-mode": valid.replace("mode=production", "mode=self-test"),
        "zero-total": valid.replace(
            "total=6 opaque=1 alpha=2 additive=2 multiply2=1 trans=0 textured=6",
            "total=0 opaque=0 alpha=0 additive=0 multiply2=0 trans=0 textured=0",
        ),
        "texture-coverage": valid.replace("textured=6", "textured=5"),
        "category-conservation": valid.replace("opaque=1", "opaque=2"),
        "missing-additive": valid.replace(" additive=2", ""),
        "missing-multiply2": valid.replace(" multiply2=1", ""),
        "missing-transparent": valid.replace(" trans=0", ""),
        "transparent-overflow": valid.replace("trans=0", "trans=7"),
        "missing-kind": valid[:valid.index(KIND_PREFIX)],
        "kind-total": valid.replace("total=6 landscape", "total=7 landscape"),
        "kind-conservation": valid.replace("morph=1", "morph=2"),
        "cross-frame-kind": valid.replace(
            KIND_PREFIX, "RendererIOS native scene identity: mode=production generation=3 sequence=2\n" + KIND_PREFIX),
        "legacy-schema": (
            "RendererIOS native scene material-drawn: mode=production "
            "total=3 opaque=1 alpha=2 textured=3\n"
        ),
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
