#!/usr/bin/env python3
"""Validate compact RendererIOS scene-source census markers."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Sequence


PREFIX = "RendererIOS source census:"
SCHEMA_VERSION = "1"
MAX_MARKER_BYTES = 254
UINT64_MAX = (1 << 64) - 1
SHA_RE = re.compile(r"[0-9a-f]{40}")
UINT_RE = re.compile(r"0|[1-9][0-9]*")
FIELD_ORDER = ("v", "b", "g", "s", "k", "m", "a", "o")

KIND_NAMES = (
    "kind-landscape",
    "kind-static",
    "kind-movable",
    "kind-animated",
    "kind-particle",
    "kind-morph",
    "kind-unsupported",
    "kind-unknown",
)
MATERIAL_NAMES = (
    "material-solid",
    "material-alpha-test",
    "material-water",
    "material-ghost",
    "material-multiply",
    "material-multiply2",
    "material-transparent",
    "material-additive-light",
    "material-missing",
    "material-unknown",
)
ANIMATION_NAMES = ("frame-animated", "uv-animated")
OUTCOME_NAMES = (
    "visited",
    "planned",
    "skipped-kind",
    "skipped-material",
    "skipped-texture-animation",
    "invalid-source",
)
CONSERVING_OUTCOMES = OUTCOME_NAMES[1:5]


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def parse_uint64(value: str, name: str) -> int:
    require(UINT_RE.fullmatch(value) is not None, f"{name} is not canonical decimal")
    parsed = int(value, 10)
    require(parsed <= UINT64_MAX, f"{name} exceeds uint64")
    return parsed


def parse_uint64_list(value: str, names: Sequence[str], label: str) -> dict[str, int]:
    parts = value.split(",")
    require(len(parts) == len(names), f"{label} cardinality changed")
    return {
        name: parse_uint64(part, name)
        for name, part in zip(names, parts)
    }


def checked_sum(values: dict[str, int], names: Sequence[str], label: str) -> int:
    total = 0
    for name in names:
        value = values[name]
        require(total <= UINT64_MAX - value, f"{label} overflows uint64")
        total += value
    return total


def parse_marker(line: str, expected_build: str) -> dict[str, int | str]:
    require("\n" not in line and "\r" not in line, "census marker is not one line")
    try:
        encoded = line.encode("ascii", errors="strict")
    except UnicodeEncodeError as error:
        raise ValidationError("census marker is not ASCII") from error
    require(
        len(encoded) <= MAX_MARKER_BYTES,
        "census marker exceeds the unsplit Tempest Log budget",
    )
    require(line.startswith(PREFIX + " "), "census marker prefix is malformed")
    tokens = line[len(PREFIX) + 1 :].split(" ")
    require(
        len(tokens) == len(FIELD_ORDER) and all(tokens),
        "census field count or spacing changed",
    )

    pairs: list[tuple[str, str]] = []
    for token in tokens:
        require(token.count("=") == 1, "census token is malformed")
        key, value = token.split("=", 1)
        pairs.append((key, value))
    require(
        tuple(key for key, _ in pairs) == FIELD_ORDER,
        "census fields are missing, extra, duplicated, or reordered",
    )
    raw = dict(pairs)

    require(raw["v"] == SCHEMA_VERSION, "census schema version changed")
    require(SHA_RE.fullmatch(raw["b"]) is not None, "marker build is not a full SHA")
    require(raw["b"] == expected_build, "marker build does not match expected build")
    generation = parse_uint64(raw["g"], "generation")
    sequence = parse_uint64(raw["s"], "sequence")
    require(generation > 0, "generation must be positive")
    require(
        sequence == 1 or (sequence > 0 and sequence % 300 == 0),
        "sequence is outside the exact 1/300 diagnostics cadence",
    )

    values: dict[str, int] = {
        "generation": generation,
        "sequence": sequence,
        **parse_uint64_list(raw["k"], KIND_NAMES, "raw kind census"),
        **parse_uint64_list(raw["m"], MATERIAL_NAMES, "raw material census"),
        **parse_uint64_list(raw["a"], ANIMATION_NAMES, "animation census"),
        **parse_uint64_list(raw["o"], OUTCOME_NAMES, "outcome census"),
    }

    require(values["kind-unknown"] == 0, "unknown raw kind is fail-closed")
    require(values["material-unknown"] == 0, "unknown raw material is fail-closed")
    require(values["material-alpha-test"] > 0, "device census requires AlphaTest input")
    visited = values["visited"]
    require(values["frame-animated"] <= visited, "frame animation count exceeds visited")
    require(values["uv-animated"] <= visited, "UV animation count exceeds visited")
    require(
        checked_sum(values, KIND_NAMES, "raw kind census") == visited,
        "raw kind census does not conserve visited",
    )
    require(
        checked_sum(values, MATERIAL_NAMES, "raw material census") == visited,
        "raw material census does not conserve visited",
    )
    require(
        checked_sum(values, CONSERVING_OUTCOMES, "outcome census") == visited,
        "outcomes do not conserve visited",
    )
    require(values["invalid-source"] == 0, "successful census has invalidSource != 0")
    return {"version": 1, "build": raw["b"], **values}


def validate(
    log: str, expected_build: str, expected_sequence: int
) -> dict[str, int | str]:
    require(
        SHA_RE.fullmatch(expected_build) is not None,
        "expected build must be an exact lowercase 40-hex SHA",
    )
    require(
        type(expected_sequence) is int
        and 0 < expected_sequence <= UINT64_MAX
        and (expected_sequence == 1 or expected_sequence % 300 == 0),
        "expected sequence is outside the exact 1/300 diagnostics cadence",
    )
    lines = [line for line in log.splitlines() if line.startswith(PREFIX)]
    require(lines, "scene-source census marker is missing")
    markers = [parse_marker(line, expected_build) for line in lines]
    targets = [marker for marker in markers if marker["sequence"] == expected_sequence]
    require(
        len(targets) == 1,
        "expected exactly one scene-source census marker for sequence "
        f"{expected_sequence}, found {len(targets)}",
    )
    return targets[0]


def marker(build: str) -> str:
    return (
        f"{PREFIX} v=1 b={build} g=7 s=300 "
        "k=1,3,4,1,1,1,1,0 "
        "m=5,3,1,1,1,0,0,1,0,0 "
        "a=2,3 o=12,7,2,2,1,0"
    )


def replace_field(line: str, field: str, replacement: str) -> str:
    match = re.search(rf"(?<!\S){re.escape(field)}=\S+", line)
    require(match is not None, f"self-test anchor missing: {field}")
    return line[: match.start()] + f"{field}={replacement}" + line[match.end() :]


def replace_list_item(line: str, field: str, index: int, replacement: str) -> str:
    match = re.search(rf"(?<!\S){re.escape(field)}=(\S+)", line)
    require(match is not None, f"self-test list anchor missing: {field}")
    parts = match.group(1).split(",")
    require(0 <= index < len(parts), f"self-test list index invalid: {field}[{index}]")
    parts[index] = replacement
    return line[: match.start()] + f"{field}={','.join(parts)}" + line[match.end() :]


def distributed(total: int, count: int) -> str:
    quotient, remainder = divmod(total, count)
    return ",".join(
        str(quotient + (1 if index < remainder else 0))
        for index in range(count)
    )


def self_test() -> int:
    build = "0123456789abcdef0123456789abcdef01234567"
    canonical = marker(build)
    require(len(canonical.encode("ascii")) < 255, "canonical compact marker is not compact")
    sequence_one = replace_field(canonical, "s", "1")
    valid_log = (
        "ordinary output\n"
        + sequence_one
        + "\nintermediate output\n"
        + canonical
        + "\nmore output\n"
    )
    require(validate(valid_log, build, 300)["visited"] == 12, "canonical target failed")
    require(validate(valid_log, build, 1)["sequence"] == 1, "sequence-one target failed")

    with_missing = replace_list_item(canonical, "m", 0, "4")
    with_missing = replace_list_item(with_missing, "m", 8, "1")
    require(
        validate(sequence_one + "\n" + with_missing + "\n", build, 300)[
            "material-missing"
        ]
        == 1,
        "raw Missing material must remain distinct from Unknown",
    )

    oversized = canonical
    oversized = replace_field(oversized, "k", distributed(UINT64_MAX, 8))
    oversized = replace_field(oversized, "m", distributed(UINT64_MAX, 10))
    oversized = replace_field(oversized, "a", f"{UINT64_MAX},{UINT64_MAX}")
    oversized = replace_field(
        oversized,
        "o",
        distributed(UINT64_MAX, 4) + ",0,0",
    )
    require(len(oversized.encode("ascii")) > MAX_MARKER_BYTES, "oversize fixture drifted")

    mutations = {
        "missing-marker": "ordinary output\n",
        "duplicate-target": valid_log + canonical + "\n",
        "missing-target": "ordinary output\n" + sequence_one + "\n",
        "wrong-build": replace_field(valid_log, "b", "f" * 40),
        "short-build": replace_field(valid_log, "b", "a" * 39),
        "schema": replace_field(valid_log, "v", "2"),
        "generation-zero": replace_field(valid_log, "g", "0"),
        "sequence-zero": replace_field(valid_log, "s", "0"),
        "sequence-off-cadence": replace_field(valid_log, "s", "299"),
        "sequence-overflow": replace_field(valid_log, "s", str(UINT64_MAX + 1)),
        "leading-zero": replace_list_item(valid_log, "o", 0, "012"),
        "negative": replace_list_item(valid_log, "o", 1, "-1"),
        "kind-unknown": replace_list_item(valid_log, "k", 7, "1"),
        "material-unknown": replace_list_item(valid_log, "m", 9, "1"),
        "material-missing-breaks-sum": replace_list_item(valid_log, "m", 8, "1"),
        "no-alpha-test": replace_list_item(valid_log, "m", 1, "0"),
        "kind-sum": replace_list_item(valid_log, "k", 1, "4"),
        "material-sum": replace_list_item(valid_log, "m", 0, "6"),
        "outcome-sum": replace_list_item(valid_log, "o", 1, "8"),
        "kind-sum-overflow": replace_list_item(valid_log, "k", 0, str(UINT64_MAX)),
        "material-sum-overflow": replace_list_item(valid_log, "m", 0, str(UINT64_MAX)),
        "outcome-sum-overflow": replace_list_item(valid_log, "o", 1, str(UINT64_MAX)),
        "frame-exceeds-visited": replace_list_item(valid_log, "a", 0, "13"),
        "uv-exceeds-visited": replace_list_item(valid_log, "a", 1, "13"),
        "invalid-source": replace_list_item(valid_log, "o", 5, "1"),
        "kind-cardinality-low": replace_field(valid_log, "k", "1,3,4,1,1,1,1"),
        "kind-cardinality-high": replace_field(valid_log, "k", "1,3,4,1,1,1,1,0,0"),
        "material-cardinality": replace_field(valid_log, "m", "5,3,1"),
        "animation-cardinality": replace_field(valid_log, "a", "2"),
        "outcome-cardinality": replace_field(valid_log, "o", "12,7,2,2,1"),
        "missing-field": valid_log.replace(" a=2,3", ""),
        "extra-field": valid_log.replace(" o=12,7,2,2,1,0", " o=12,7,2,2,1,0 x=0"),
        "duplicate-field": valid_log.replace(" a=2,3", " a=2,3 a=2,3"),
        "unknown-field": valid_log.replace(" a=2,3", " z=2,3"),
        "reordered-fields": valid_log.replace(" g=7 s=1", " s=1 g=7"),
        "double-space": valid_log.replace(" g=7", "  g=7"),
        "multiple-equals": valid_log.replace(" g=7", " g==7"),
        "non-ascii": valid_log.replace("ordinary output", "ordinary output ł")
        .replace(canonical, canonical + "ł"),
        "oversized-valid-shape": sequence_one + "\n" + oversized + "\n",
    }
    killed = 0
    for name, mutated in mutations.items():
        try:
            validate(mutated, build, 300)
        except ValidationError:
            killed += 1
            continue
        raise ValidationError(f"mutation survived: {name}")

    for name, expected in (
        ("uppercase", "A" * 40),
        ("local-suffix", build + "-local"),
        ("short", "a" * 39),
    ):
        try:
            validate(valid_log, expected, 300)
        except ValidationError:
            killed += 1
            continue
        raise ValidationError(f"expected-build mutation survived: {name}")
    for name, expected_sequence in (
        ("zero", 0),
        ("off-cadence", 2),
        ("overflow", UINT64_MAX + 1),
    ):
        try:
            validate(valid_log, build, expected_sequence)
        except ValidationError:
            killed += 1
            continue
        raise ValidationError(f"expected-sequence mutation survived: {name}")
    return killed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-sequence", type=int)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.self_test:
        require(
            arguments.log is None
            and arguments.expected_build is None
            and arguments.expected_sequence is None,
            "--self-test accepts no evidence arguments",
        )
        killed = self_test()
        print(
            "scene-source census log validator self-test PASS "
            f"({killed}/{killed} mutations killed)"
        )
        return 0

    require(arguments.log is not None, "--log is required")
    require(arguments.expected_build is not None, "--expected-build is required")
    require(arguments.expected_sequence is not None, "--expected-sequence is required")
    log = arguments.log.read_text(encoding="utf-8", errors="strict")
    result = validate(log, arguments.expected_build, arguments.expected_sequence)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
