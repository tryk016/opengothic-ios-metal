#!/usr/bin/env python3
"""Validate one complete RendererIOS scene-source census marker."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Sequence


PREFIX = "RendererIOS source census:"
UINT64_MAX = (1 << 64) - 1
SHA_RE = re.compile(r"[0-9a-f]{40}")
UINT_RE = re.compile(r"0|[1-9][0-9]*")

KIND_FIELDS = (
    "kind-landscape",
    "kind-static",
    "kind-movable",
    "kind-animated",
    "kind-particle",
    "kind-morph",
    "kind-unsupported",
    "kind-unknown",
)
MATERIAL_FIELDS = (
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
ANIMATION_FIELDS = (
    "frame-animated",
    "uv-animated",
)
OUTCOME_FIELDS = (
    "planned",
    "skipped-kind",
    "skipped-material",
    "skipped-texture-animation",
)
NUMERIC_FIELDS = (
    "generation",
    "sequence",
    *KIND_FIELDS,
    *MATERIAL_FIELDS,
    *ANIMATION_FIELDS,
    "visited",
    *OUTCOME_FIELDS,
    "invalid-source",
)
FIELD_ORDER = ("build", *NUMERIC_FIELDS)


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


def checked_sum(values: dict[str, int], fields: Sequence[str], name: str) -> int:
    total = 0
    for field in fields:
        value = values[field]
        require(total <= UINT64_MAX - value, f"{name} overflows uint64")
        total += value
    return total


def parse_marker(line: str, expected_build: str) -> dict[str, int | str]:
    require("\n" not in line and "\r" not in line, "census marker is not one line")
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
    require(SHA_RE.fullmatch(raw["build"]) is not None, "marker build is not a full SHA")
    require(raw["build"] == expected_build, "marker build does not match expected build")
    values = {field: parse_uint64(raw[field], field) for field in NUMERIC_FIELDS}

    require(values["generation"] > 0, "generation must be positive")
    sequence = values["sequence"]
    require(
        sequence == 1 or (sequence > 0 and sequence % 300 == 0),
        "sequence is outside the exact 1/300 diagnostics cadence",
    )
    require(values["kind-unknown"] == 0, "unknown raw kind is fail-closed")
    require(values["material-unknown"] == 0, "unknown raw material is fail-closed")
    require(values["material-alpha-test"] > 0, "device census requires AlphaTest input")

    visited = values["visited"]
    require(values["frame-animated"] <= visited, "frame animation count exceeds visited")
    require(values["uv-animated"] <= visited, "UV animation count exceeds visited")
    require(
        checked_sum(values, KIND_FIELDS, "raw kind census") == visited,
        "raw kind census does not conserve visited",
    )
    require(
        checked_sum(values, MATERIAL_FIELDS, "raw material census") == visited,
        "raw material census does not conserve visited",
    )
    require(
        checked_sum(values, OUTCOME_FIELDS, "outcome census") == visited,
        "outcomes do not conserve visited",
    )
    require(values["invalid-source"] == 0, "successful census has invalidSource != 0")

    return {"build": raw["build"], **values}


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
    markers = [line for line in log.splitlines() if line.startswith(PREFIX)]
    require(markers, "scene-source census marker is missing")
    parsed = [parse_marker(line, expected_build) for line in markers]
    targets = [
        marker_values
        for marker_values in parsed
        if marker_values["sequence"] == expected_sequence
    ]
    require(
        len(targets) == 1,
        "expected exactly one scene-source census marker for sequence "
        f"{expected_sequence}, found {len(targets)}",
    )
    return targets[0]


def marker(build: str) -> str:
    fixture: dict[str, int | str] = {
        "build": build,
        "generation": 7,
        "sequence": 300,
        "kind-landscape": 1,
        "kind-static": 3,
        "kind-movable": 4,
        "kind-animated": 1,
        "kind-particle": 1,
        "kind-morph": 1,
        "kind-unsupported": 1,
        "kind-unknown": 0,
        "material-solid": 5,
        "material-alpha-test": 3,
        "material-water": 1,
        "material-ghost": 1,
        "material-multiply": 1,
        "material-multiply2": 0,
        "material-transparent": 0,
        "material-additive-light": 1,
        "material-missing": 0,
        "material-unknown": 0,
        "frame-animated": 2,
        "uv-animated": 3,
        "visited": 12,
        "planned": 7,
        "skipped-kind": 2,
        "skipped-material": 2,
        "skipped-texture-animation": 1,
        "invalid-source": 0,
    }
    return PREFIX + " " + " ".join(f"{field}={fixture[field]}" for field in FIELD_ORDER)


def replace_field(line: str, field: str, replacement: str) -> str:
    match = re.search(rf"(?<![^ ]){re.escape(field)}=[^ ]+", line)
    require(match is not None, f"self-test anchor missing: {field}")
    return line[: match.start()] + f"{field}={replacement}" + line[match.end() :]


def self_test() -> int:
    build = "0123456789abcdef0123456789abcdef01234567"
    canonical = marker(build)
    sequence_one = replace_field(canonical, "sequence", "1")
    valid_log = (
        "ordinary output\n"
        + sequence_one
        + "\nintermediate output\n"
        + canonical
        + "\nmore output\n"
    )
    parsed = validate(valid_log, build, 300)
    require(parsed["visited"] == 12, "canonical fixture failed")
    require(validate(valid_log, build, 1)["sequence"] == 1, "sequence-one target failed")
    with_missing_marker = replace_field(canonical, "material-solid", "4")
    with_missing_marker = replace_field(
        with_missing_marker, "material-missing", "1"
    )
    with_missing = sequence_one + "\n" + with_missing_marker + "\n"
    require(
        validate(with_missing, build, 300)["material-missing"] == 1,
        "raw Missing material must remain distinct from Unknown",
    )

    first_kind = f"{KIND_FIELDS[0]}=1"
    second_kind = f"{KIND_FIELDS[1]}=3"
    mutations = {
        "missing-marker": "ordinary output\n",
        "duplicate-marker": valid_log + canonical + "\n",
        "missing-target": "ordinary output\n" + sequence_one + "\n",
        "wrong-build": replace_field(valid_log, "build", "f" * 40),
        "short-build": replace_field(valid_log, "build", "a" * 39),
        "generation-zero": replace_field(valid_log, "generation", "0"),
        "sequence-zero": replace_field(valid_log, "sequence", "0"),
        "sequence-off-cadence": replace_field(valid_log, "sequence", "299"),
        "sequence-overflow": replace_field(valid_log, "sequence", str(UINT64_MAX + 1)),
        "leading-zero": replace_field(valid_log, "visited", "012"),
        "negative": replace_field(valid_log, "planned", "-1"),
        "kind-unknown": replace_field(valid_log, "kind-unknown", "1"),
        "material-unknown": replace_field(valid_log, "material-unknown", "1"),
        "material-missing-breaks-sum": replace_field(valid_log, "material-missing", "1"),
        "no-alpha-test": replace_field(valid_log, "material-alpha-test", "0"),
        "kind-sum": replace_field(valid_log, "kind-static", "4"),
        "material-sum": replace_field(valid_log, "material-solid", "6"),
        "outcome-sum": replace_field(valid_log, "planned", "8"),
        "kind-sum-overflow": replace_field(valid_log, "kind-landscape", str(UINT64_MAX)),
        "material-sum-overflow": replace_field(valid_log, "material-solid", str(UINT64_MAX)),
        "outcome-sum-overflow": replace_field(valid_log, "planned", str(UINT64_MAX)),
        "frame-exceeds-visited": replace_field(valid_log, "frame-animated", "13"),
        "uv-exceeds-visited": replace_field(valid_log, "uv-animated", "13"),
        "invalid-source": replace_field(valid_log, "invalid-source", "1"),
        "missing-field": valid_log.replace(" kind-particle=1", ""),
        "extra-field": valid_log.replace(" invalid-source=0", " invalid-source=0 extra=0"),
        "duplicate-field": valid_log.replace(
            " kind-particle=1", " kind-particle=1 kind-particle=1"
        ),
        "unknown-field": valid_log.replace(" kind-particle=1", " kind-sprite=1"),
        "reordered-fields": valid_log.replace(
            first_kind + " " + second_kind, second_kind + " " + first_kind
        ),
        "double-space": valid_log.replace(" generation=7", "  generation=7"),
        "multiple-equals": valid_log.replace(" generation=7", " generation==7"),
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
        print(f"scene-source census log validator self-test PASS ({killed}/{killed} mutations killed)")
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
