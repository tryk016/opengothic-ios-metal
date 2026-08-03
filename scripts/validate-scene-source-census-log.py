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
SCHEMA_VERSIONS = (1, 2)
MAX_MARKER_BYTES = 254
UINT64_MAX = (1 << 64) - 1
SHA_RE = re.compile(r"[0-9a-f]{40}")
UINT_RE = re.compile(r"0|[1-9][0-9]*")
FIELD_ORDER = {
    1: ("v", "b", "g", "s", "k", "m", "a", "o"),
    2: ("v", "b", "g", "s", "k", "m", "a", "x", "o"),
}

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
TEXTURE_ANIMATION_OUTCOME_NAMES = (
    "skipped-texture-frame-only",
    "skipped-texture-uv-only",
    "skipped-texture-frame-and-uv",
)
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
    require(all(tokens), "census field count or spacing changed")

    pairs: list[tuple[str, str]] = []
    for token in tokens:
        require(token.count("=") == 1, "census token is malformed")
        key, value = token.split("=", 1)
        pairs.append((key, value))
    require(pairs and pairs[0][0] == "v", "census version field is missing")
    version = parse_uint64(pairs[0][1], "version")
    require(version in SCHEMA_VERSIONS, "census schema version is unsupported")
    require(
        tuple(key for key, _ in pairs) == FIELD_ORDER[version],
        "census fields are missing, extra, duplicated, or reordered",
    )
    raw = dict(pairs)

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
    if version == 2:
        values.update(
            parse_uint64_list(
                raw["x"],
                TEXTURE_ANIMATION_OUTCOME_NAMES,
                "texture animation outcome census",
            )
        )

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
    if version == 2:
        require(
            checked_sum(
                values,
                TEXTURE_ANIMATION_OUTCOME_NAMES,
                "texture animation outcome census",
            )
            == values["skipped-texture-animation"],
            "texture animation outcomes do not conserve their skip total",
        )
        require(
            checked_sum(
                values,
                ("skipped-texture-frame-only", "skipped-texture-frame-and-uv"),
                "eligible frame animation outcomes",
            )
            <= values["frame-animated"],
            "eligible frame animation outcomes exceed raw frame census",
        )
        require(
            checked_sum(
                values,
                ("skipped-texture-uv-only", "skipped-texture-frame-and-uv"),
                "eligible UV animation outcomes",
            )
            <= values["uv-animated"],
            "eligible UV animation outcomes exceed raw UV census",
        )
    require(values["invalid-source"] == 0, "successful census has invalidSource != 0")
    return {"version": version, "build": raw["b"], **values}


def validate(
    log: str,
    expected_build: str,
    expected_version: int,
    expected_sequence: int,
    expected_animation: tuple[int, int, int] | None = None,
) -> dict[str, int | str]:
    require(
        SHA_RE.fullmatch(expected_build) is not None,
        "expected build must be an exact lowercase 40-hex SHA",
    )
    require(
        type(expected_version) is int and expected_version in SCHEMA_VERSIONS,
        "expected version is unsupported",
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
    targets = [
        marker
        for marker in markers
        if marker["version"] == expected_version
        and marker["sequence"] == expected_sequence
    ]
    require(
        len(targets) == 1,
        "expected exactly one scene-source census marker for version/sequence "
        f"{expected_version}/{expected_sequence}, found {len(targets)}",
    )
    target = targets[0]
    if expected_animation is not None:
        require(expected_version == 2, "exact animation expectations require schema v2")
        require(
            len(expected_animation) == 3
            and all(type(value) is int and 0 <= value <= UINT64_MAX
                    for value in expected_animation),
            "exact animation expectations are invalid",
        )
        expected_frame, expected_uv, expected_skipped = expected_animation
        require(
            target["frame-animated"] == expected_frame,
            "raw frame animation count differs from the expected baseline",
        )
        require(
            target["uv-animated"] == expected_uv,
            "raw UV animation count differs from the expected baseline",
        )
        require(
            target["skipped-texture-animation"] == expected_skipped,
            "texture animation skip count differs from the expected baseline",
        )
    return target


def marker(build: str, version: int) -> str:
    require(version in SCHEMA_VERSIONS, "self-test marker version is unsupported")
    common = (
        f"{PREFIX} v={version} b={build} g=7 s=300 "
        "k=1,3,4,1,1,1,1,0 "
        "m=5,3,1,1,1,0,0,1,0,0 "
        "a=2,3"
    )
    if version == 1:
        return common + " o=12,7,2,2,1,0"
    return common + " x=0,0,1 o=12,7,2,2,1,0"


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
    historical = marker(build, 1)
    canonical = marker(build, 2)
    require(
        len(historical.encode("ascii")) <= MAX_MARKER_BYTES,
        "historical compact marker is not compact",
    )
    require(
        len(canonical.encode("ascii")) <= MAX_MARKER_BYTES,
        "canonical compact marker is not compact",
    )
    sequence_one = replace_field(canonical, "s", "1")
    valid_v2_log = (
        "ordinary output\n"
        + sequence_one
        + "\nintermediate output\n"
        + canonical
        + "\nmore output\n"
    )
    mixed_log = valid_v2_log + historical + "\n"
    require(
        validate(valid_v2_log, build, 2, 300, (2, 3, 1))["visited"] == 12,
        "canonical v2 target failed",
    )
    require(
        validate(valid_v2_log, build, 2, 1)["sequence"] == 1,
        "sequence-one v2 target failed",
    )
    require(
        validate(mixed_log, build, 1, 300)["version"] == 1,
        "historical v1 target failed",
    )
    require(
        validate(mixed_log, build, 2, 300)["version"] == 2,
        "version-scoped v2 target failed",
    )

    with_missing = replace_list_item(canonical, "m", 0, "4")
    with_missing = replace_list_item(with_missing, "m", 8, "1")
    require(
        validate(sequence_one + "\n" + with_missing + "\n", build, 2, 300)[
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
        "x",
        f"{UINT64_MAX},{UINT64_MAX},{UINT64_MAX}",
    )
    oversized = replace_field(
        oversized,
        "o",
        distributed(UINT64_MAX, 4) + ",0,0",
    )
    require(len(oversized.encode("ascii")) > MAX_MARKER_BYTES, "oversize fixture drifted")

    frame_bound = replace_field(canonical, "x", "2,0,1")
    frame_bound = replace_field(frame_bound, "o", "12,5,2,2,3,0")
    uv_bound = replace_field(canonical, "x", "0,3,1")
    uv_bound = replace_field(uv_bound, "o", "12,4,2,2,4,0")

    mutations = {
        "missing-marker": "ordinary output\n",
        "duplicate-target": valid_v2_log + canonical + "\n",
        "missing-target": "ordinary output\n" + sequence_one + "\n",
        "wrong-build": replace_field(valid_v2_log, "b", "f" * 40),
        "short-build": replace_field(valid_v2_log, "b", "a" * 39),
        "unsupported-schema": replace_field(valid_v2_log, "v", "3"),
        "v1-with-v2-fields": replace_field(valid_v2_log, "v", "1"),
        "generation-zero": replace_field(valid_v2_log, "g", "0"),
        "sequence-zero": replace_field(valid_v2_log, "s", "0"),
        "sequence-off-cadence": replace_field(valid_v2_log, "s", "299"),
        "sequence-overflow": replace_field(valid_v2_log, "s", str(UINT64_MAX + 1)),
        "leading-zero": replace_list_item(valid_v2_log, "o", 0, "012"),
        "negative": replace_list_item(valid_v2_log, "o", 1, "-1"),
        "kind-unknown": replace_list_item(valid_v2_log, "k", 7, "1"),
        "material-unknown": replace_list_item(valid_v2_log, "m", 9, "1"),
        "material-missing-breaks-sum": replace_list_item(valid_v2_log, "m", 8, "1"),
        "no-alpha-test": replace_list_item(valid_v2_log, "m", 1, "0"),
        "kind-sum": replace_list_item(valid_v2_log, "k", 1, "4"),
        "material-sum": replace_list_item(valid_v2_log, "m", 0, "6"),
        "outcome-sum": replace_list_item(valid_v2_log, "o", 1, "8"),
        "kind-sum-overflow": replace_list_item(valid_v2_log, "k", 0, str(UINT64_MAX)),
        "material-sum-overflow": replace_list_item(valid_v2_log, "m", 0, str(UINT64_MAX)),
        "outcome-sum-overflow": replace_list_item(valid_v2_log, "o", 1, str(UINT64_MAX)),
        "frame-exceeds-visited": replace_list_item(valid_v2_log, "a", 0, "13"),
        "uv-exceeds-visited": replace_list_item(valid_v2_log, "a", 1, "13"),
        "invalid-source": replace_list_item(valid_v2_log, "o", 5, "1"),
        "texture-outcome-sum": replace_field(valid_v2_log, "x", "1,0,1"),
        "frame-raw-bound": sequence_one + "\n" + frame_bound + "\n",
        "uv-raw-bound": sequence_one + "\n" + uv_bound + "\n",
        "kind-cardinality-low": replace_field(valid_v2_log, "k", "1,3,4,1,1,1,1"),
        "kind-cardinality-high": replace_field(valid_v2_log, "k", "1,3,4,1,1,1,1,0,0"),
        "material-cardinality": replace_field(valid_v2_log, "m", "5,3,1"),
        "animation-cardinality": replace_field(valid_v2_log, "a", "2"),
        "texture-outcome-cardinality": replace_field(valid_v2_log, "x", "0,1"),
        "outcome-cardinality": replace_field(valid_v2_log, "o", "12,7,2,2,1"),
        "missing-field": valid_v2_log.replace(" x=0,0,1", ""),
        "extra-field": valid_v2_log.replace(" o=12,7,2,2,1,0", " o=12,7,2,2,1,0 z=0"),
        "duplicate-field": valid_v2_log.replace(" x=0,0,1", " x=0,0,1 x=0,0,1"),
        "unknown-field": valid_v2_log.replace(" x=0,0,1", " z=0,0,1"),
        "reordered-fields": valid_v2_log.replace(" a=2,3 x=0,0,1", " x=0,0,1 a=2,3"),
        "double-space": valid_v2_log.replace(" g=7", "  g=7"),
        "multiple-equals": valid_v2_log.replace(" g=7", " g==7"),
        "non-ascii": valid_v2_log.replace("ordinary output", "ordinary output ł")
        .replace(canonical, canonical + "ł"),
        "oversized-valid-shape": sequence_one + "\n" + oversized + "\n",
    }
    killed = 0
    for name, mutated in mutations.items():
        try:
            validate(mutated, build, 2, 300)
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
            validate(valid_v2_log, expected, 2, 300)
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
            validate(valid_v2_log, build, 2, expected_sequence)
        except ValidationError:
            killed += 1
            continue
        raise ValidationError(f"expected-sequence mutation survived: {name}")
    for name, expected_version in (("zero", 0), ("three", 3)):
        try:
            validate(valid_v2_log, build, expected_version, 300)
        except ValidationError:
            killed += 1
            continue
        raise ValidationError(f"expected-version mutation survived: {name}")
    for name, expected_animation in (
        ("frame", (3, 3, 1)),
        ("uv", (2, 2, 1)),
        ("skip", (2, 3, 2)),
    ):
        try:
            validate(valid_v2_log, build, 2, 300, expected_animation)
        except ValidationError:
            killed += 1
            continue
        raise ValidationError(f"expected-animation mutation survived: {name}")
    try:
        validate(valid_v2_log, build, 1, 300, (2, 3, 1))
    except ValidationError:
        killed += 1
    else:
        raise ValidationError("v1 exact-animation mutation survived")
    return killed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-version", type=int, choices=SCHEMA_VERSIONS)
    parser.add_argument("--expected-sequence", type=int)
    parser.add_argument("--expected-frame-animated", type=int)
    parser.add_argument("--expected-uv-animated", type=int)
    parser.add_argument("--expected-skipped-texture-animation", type=int)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.self_test:
        require(
            arguments.log is None
            and arguments.expected_build is None
            and arguments.expected_version is None
            and arguments.expected_sequence is None
            and arguments.expected_frame_animated is None
            and arguments.expected_uv_animated is None
            and arguments.expected_skipped_texture_animation is None,
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
    require(arguments.expected_version is not None, "--expected-version is required")
    require(arguments.expected_sequence is not None, "--expected-sequence is required")
    animation_arguments = (
        arguments.expected_frame_animated,
        arguments.expected_uv_animated,
        arguments.expected_skipped_texture_animation,
    )
    require(
        all(value is None for value in animation_arguments)
        or all(value is not None for value in animation_arguments),
        "exact animation expectations must be provided together",
    )
    expected_animation = (
        None
        if animation_arguments[0] is None
        else (
            int(animation_arguments[0]),
            int(animation_arguments[1]),
            int(animation_arguments[2]),
        )
    )
    log = arguments.log.read_text(encoding="utf-8", errors="strict")
    result = validate(
        log,
        arguments.expected_build,
        arguments.expected_version,
        arguments.expected_sequence,
        expected_animation,
    )
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
