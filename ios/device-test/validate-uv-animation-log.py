#!/usr/bin/env python3
"""Validate the frozen P2.1d3 UV-animation v1 device-log contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Sequence


PRIMARY_PREFIX = "RendererIOS UV animation:"
DETAIL_PREFIX = "RendererIOS UV animation detail:"
SOURCE_PREFIX = "RendererIOS UV animation source:"
CENSUS_PREFIX = "RendererIOS source census:"
DIAGNOSTICS_PREFIX = "RendererIOS diagnostics:"
DIAGNOSTICS_ON = "RendererIOS diagnostics: ON frames-in-flight="
IDENTITY_PREFIX = "RendererIOS native scene identity:"
MAX_MARKER_BYTES = 254
UINT64_MAX = (1 << 64) - 1
EXPECTED_TOTAL = 2
EXPECTED_UV_ONLY = 0
EXPECTED_FRAME_AND_UV = 2
EXPECTED_PLANNED = 29726
EXPECTED_D1_SHA256 = (
    "03e0f24324fc15c22d048473bec30586f7867642db8bc2a7977b6843aed791a5"
)
EXPECTED_D1_BUILD = "3b22b0eb3772cde9e9d88cc28baeff43b5a7aedc"
SHA_RE = re.compile(r"[0-9a-f]{40}")
HEX32_RE = re.compile(r"[0-9a-f]{8}")
UINT_RE = re.compile(r"0|[1-9][0-9]*")

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
TEXTURE_OUTCOME_NAMES = (
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

EXPECTED_D1: dict[str, int | str] = {
    "build": EXPECTED_D1_BUILD,
    "frame-animated": 38,
    "generation": 3,
    "invalid-source": 0,
    "kind-animated": 1563,
    "kind-landscape": 338,
    "kind-morph": 1137,
    "kind-movable": 8463,
    "kind-particle": 0,
    "kind-static": 22075,
    "kind-unknown": 0,
    "kind-unsupported": 0,
    "material-additive-light": 183,
    "material-alpha-test": 11001,
    "material-ghost": 0,
    "material-missing": 0,
    "material-multiply": 0,
    "material-multiply2": 1,
    "material-solid": 21425,
    "material-transparent": 962,
    "material-unknown": 0,
    "material-water": 4,
    "planned": 29702,
    "sequence": 1,
    "skipped-kind": 2700,
    "skipped-material": 1150,
    "skipped-texture-animation": 24,
    "skipped-texture-frame-and-uv": 2,
    "skipped-texture-frame-only": 22,
    "skipped-texture-uv-only": 0,
    "uv-animated": 3,
    "version": 2,
    "visited": 33576,
}

EXPECTED_D3_BREAKDOWN = {
    **{name: int(EXPECTED_D1[name]) for name in KIND_NAMES},
    **{name: int(EXPECTED_D1[name]) for name in MATERIAL_NAMES},
    "frame-animated": 38,
    "uv-animated": 3,
    "skipped-texture-frame-only": 0,
    "skipped-texture-uv-only": 0,
    "skipped-texture-frame-and-uv": 0,
    "visited": 33576,
    "planned": EXPECTED_PLANNED,
    "skipped-kind": 2700,
    "skipped-material": 1150,
    "skipped-texture-animation": 0,
    "invalid-source": 0,
}

PRIMARY_RE = re.compile(
    rf"^{re.escape(PRIMARY_PREFIX)} v=1 p=([BT]) b=([0-9a-f]{{40}}) "
    r"g=(\S+) s=(\S+) a=(\S+) u=(\S+) c=(\S+) d=(\S+) "
    r"sd=([0-9a-f]{16})$"
)
DETAIL_RE = re.compile(
    rf"^{re.escape(DETAIL_PREFIX)} v=1 p=([BT]) g=(\S+) s=(\S+) "
    r"pt=([0-9a-f]{16}) et=([0-9a-f]{16}) "
    r"pu=([0-9a-f]{16}) eu=([0-9a-f]{16})$"
)
SOURCE_RE = re.compile(
    rf"^{re.escape(SOURCE_PREFIX)} v=1 p=([BT]) g=(\S+) s=(\S+) "
    r"i=(\S+) m=([UC]) o=(\S+) h=(\S+) "
    r"x=([0-9a-f]{8}) y=([0-9a-f]{8}) "
    r"ex=([0-9a-f]{8}) ey=([0-9a-f]{8})$"
)
IDENTITY_RE = re.compile(
    rf"^{re.escape(IDENTITY_PREFIX)} mode=production "
    r"generation=(\S+) sequence=(\S+)$"
)


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


def validate_marker_line(line: str, label: str) -> None:
    require("\r" not in line and "\n" not in line, f"{label} is not one line")
    try:
        encoded = line.encode("ascii", errors="strict")
    except UnicodeEncodeError as error:
        raise ValidationError(f"{label} is not ASCII") from error
    require(len(encoded) <= MAX_MARKER_BYTES, f"{label} exceeds 254 bytes")


def checked_sum(values: Sequence[int], label: str) -> int:
    result = 0
    for value in values:
        require(result <= UINT64_MAX - value, f"{label} overflows uint64")
        result += value
    return result


def parse_list(value: str, names: Sequence[str], label: str) -> dict[str, int]:
    fields = value.split(",")
    require(len(fields) == len(names), f"{label} cardinality changed")
    return {
        name: parse_uint64(field, name)
        for name, field in zip(names, fields)
    }


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"D1 JSON duplicates key {key!r}")
        result[key] = value
    return result


def load_d1_census(path: pathlib.Path) -> dict[str, int | str]:
    raw = path.read_bytes()
    require(
        hashlib.sha256(raw).hexdigest() == EXPECTED_D1_SHA256,
        "D1 census JSON SHA-256 does not match the frozen device artifact",
    )
    try:
        parsed = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValidationError(f"D1 JSON contains non-finite {value}")
            ),
        )
    except UnicodeDecodeError as error:
        raise ValidationError("D1 census JSON is not UTF-8") from error
    except json.JSONDecodeError as error:
        raise ValidationError("D1 census JSON is malformed") from error
    require(type(parsed) is dict, "D1 census JSON must be one object")
    require(parsed == EXPECTED_D1, "D1 census JSON full breakdown differs")
    return parsed


def fnv_append(digest: int, value: int, byte_count: int) -> int:
    for _ in range(byte_count):
        digest ^= value & 0xFF
        digest = (digest * 1099511628211) & UINT64_MAX
        value >>= 8
    return digest


def source_digest(source_ids: Sequence[int]) -> str:
    digest = 14695981039346656037
    for source_id in source_ids:
        digest = fnv_append(digest, source_id, 8)
    return f"{digest:016x}"


def texture_digest(sources: Sequence["Source"]) -> str:
    mode_values = {"U": 2, "C": 3}
    digest = 14695981039346656037
    for source in sources:
        digest = fnv_append(digest, source.source_id, 8)
        digest = fnv_append(digest, mode_values[source.mode], 4)
        digest = fnv_append(digest, source.ordinal, 8)
        digest = fnv_append(digest, source.generation, 8)
        digest = fnv_append(digest, source.handle, 8)
    return f"{digest:016x}"


def uv_digest(sources: Sequence["Source"]) -> str:
    digest = 14695981039346656037
    for source in sources:
        digest = fnv_append(digest, source.source_id, 8)
        digest = fnv_append(digest, source.x_bits, 4)
        digest = fnv_append(digest, source.y_bits, 4)
    return f"{digest:016x}"


def finite_canonical_float_bits(value: str, label: str) -> int:
    require(HEX32_RE.fullmatch(value) is not None, f"{label} is not 8-hex")
    bits = int(value, 16)
    exponent = bits & 0x7F800000
    require(exponent != 0x7F800000, f"{label} is non-finite")
    require(bits != 0x80000000, f"{label} is noncanonical negative zero")
    return bits


@dataclass(frozen=True)
class Primary:
    index: int
    phase: str
    build: str
    generation: int
    sequence: int
    total: int
    uv_only: int
    frame_and_uv: int
    drawn: int
    source_digest: str


@dataclass(frozen=True)
class Detail:
    index: int
    phase: str
    generation: int
    sequence: int
    planned_texture_digest: str
    encoded_texture_digest: str
    planned_uv_digest: str
    encoded_uv_digest: str


@dataclass(frozen=True)
class Source:
    index: int
    phase: str
    generation: int
    sequence: int
    source_id: int
    mode: str
    ordinal: int
    handle: int
    x_bits: int
    y_bits: int
    encoded_x_bits: int
    encoded_y_bits: int


def parse_primary(index: int, line: str, expected_sha: str) -> Primary:
    validate_marker_line(line, "UV-animation primary marker")
    match = PRIMARY_RE.fullmatch(line)
    require(match is not None, "UV-animation primary marker is malformed")
    phase, build, generation, sequence, total, uv_only, combined, drawn, digest = (
        match.groups()
    )
    require(build == expected_sha, "UV-animation marker has foreign build SHA")
    parsed = Primary(
        index=index,
        phase=phase,
        build=build,
        generation=parse_uint64(generation, f"{phase} generation"),
        sequence=parse_uint64(sequence, f"{phase} sequence"),
        total=parse_uint64(total, f"{phase} total"),
        uv_only=parse_uint64(uv_only, f"{phase} UvOnly"),
        frame_and_uv=parse_uint64(combined, f"{phase} FrameAndUv"),
        drawn=parse_uint64(drawn, f"{phase} drawn"),
        source_digest=digest,
    )
    require(parsed.generation > 0 and parsed.sequence > 0,
            f"{phase} identity must be positive")
    require(parsed.total == EXPECTED_TOTAL, f"{phase} total must be 2")
    require(parsed.uv_only == EXPECTED_UV_ONLY, f"{phase} UvOnly must be 0")
    require(parsed.frame_and_uv == EXPECTED_FRAME_AND_UV,
            f"{phase} FrameAndUv must be 2")
    require(parsed.total == parsed.uv_only + parsed.frame_and_uv,
            f"{phase} admitted modes do not conserve")
    require(parsed.drawn == parsed.total, f"{phase} both sources were not drawn")
    return parsed


def parse_detail(index: int, line: str) -> Detail:
    validate_marker_line(line, "UV-animation detail marker")
    match = DETAIL_RE.fullmatch(line)
    require(match is not None, "UV-animation detail marker is malformed")
    phase, generation, sequence, pt, et, pu, eu = match.groups()
    parsed = Detail(
        index=index,
        phase=phase,
        generation=parse_uint64(generation, f"{phase} detail generation"),
        sequence=parse_uint64(sequence, f"{phase} detail sequence"),
        planned_texture_digest=pt,
        encoded_texture_digest=et,
        planned_uv_digest=pu,
        encoded_uv_digest=eu,
    )
    require(parsed.generation > 0 and parsed.sequence > 0,
            f"{phase} detail identity must be positive")
    require(pt == et, f"{phase} planned/encoded texture digest differs")
    require(pu == eu, f"{phase} planned/encoded UV digest differs")
    return parsed


def parse_source(index: int, line: str) -> Source:
    validate_marker_line(line, "UV-animation source marker")
    match = SOURCE_RE.fullmatch(line)
    require(match is not None, "UV-animation source marker is malformed")
    phase, generation, sequence, source_id, mode, ordinal, handle, x, y, ex, ey = (
        match.groups()
    )
    parsed = Source(
        index=index,
        phase=phase,
        generation=parse_uint64(generation, f"{phase} source generation"),
        sequence=parse_uint64(sequence, f"{phase} source sequence"),
        source_id=parse_uint64(source_id, f"{phase} source ID"),
        mode=mode,
        ordinal=parse_uint64(ordinal, f"{phase} ordinal"),
        handle=parse_uint64(handle, f"{phase} encoded handle"),
        x_bits=finite_canonical_float_bits(x, f"{phase} planned x"),
        y_bits=finite_canonical_float_bits(y, f"{phase} planned y"),
        encoded_x_bits=finite_canonical_float_bits(ex, f"{phase} encoded x"),
        encoded_y_bits=finite_canonical_float_bits(ey, f"{phase} encoded y"),
    )
    require(parsed.generation > 0 and parsed.sequence > 0,
            f"{phase} source identity must be positive")
    require(parsed.source_id > 0, f"{phase} source ID must be positive")
    require(parsed.handle > 0, f"{phase} encoded handle must be positive")
    require(parsed.mode == "C", f"{phase} device source must be FrameAndUv")
    require(
        (parsed.x_bits, parsed.y_bits)
        == (parsed.encoded_x_bits, parsed.encoded_y_bits),
        f"{phase} source planned/encoded UV bits differ",
    )
    return parsed


def parse_animation_groups(
    lines: Sequence[str], expected_sha: str
) -> dict[str, tuple[Primary, Detail, tuple[Source, ...]]]:
    primaries = [
        parse_primary(index, line, expected_sha)
        for index, line in enumerate(lines)
        if line.startswith(PRIMARY_PREFIX)
    ]
    details = [
        parse_detail(index, line)
        for index, line in enumerate(lines)
        if line.startswith(DETAIL_PREFIX)
    ]
    sources = [
        parse_source(index, line)
        for index, line in enumerate(lines)
        if line.startswith(SOURCE_PREFIX)
    ]
    require(len(primaries) == 2, "expected exactly two UV primary markers")
    require(len(details) == 2, "expected exactly two UV detail markers")
    require(len(sources) == 4, "expected exactly four UV source markers")
    generations = {
        marker.generation for marker in [*primaries, *details, *sources]
    }
    require(len(generations) == 1, "UV markers do not select exactly one generation")

    groups: dict[str, tuple[Primary, Detail, tuple[Source, ...]]] = {}
    for phase in ("B", "T"):
        phase_primary = [marker for marker in primaries if marker.phase == phase]
        phase_detail = [marker for marker in details if marker.phase == phase]
        phase_sources = [marker for marker in sources if marker.phase == phase]
        require(len(phase_primary) == 1, f"expected exactly one {phase} primary")
        require(len(phase_detail) == 1, f"expected exactly one {phase} detail")
        primary = phase_primary[0]
        detail = phase_detail[0]
        require(len(phase_sources) == primary.total,
                f"{phase} source cardinality differs")
        require(
            (primary.generation, primary.sequence)
            == (detail.generation, detail.sequence),
            f"{phase} primary/detail g/s mismatch",
        )
        require(all(
            (source.generation, source.sequence)
            == (primary.generation, primary.sequence)
            for source in phase_sources
        ), f"{phase} source g/s mismatch")
        ordered_sources = tuple(sorted(phase_sources, key=lambda source: source.index))
        require(
            primary.index < detail.index
            and detail.index < ordered_sources[0].index
            and list(ordered_sources) == sorted(
                ordered_sources, key=lambda source: source.source_id
            ),
            f"{phase} group or source order is not canonical",
        )
        source_ids = [source.source_id for source in ordered_sources]
        require(len(set(source_ids)) == len(source_ids),
                f"{phase} duplicates a source ID")
        require(primary.source_digest == source_digest(source_ids),
                f"{phase} source digest does not match source lines")
        reconstructed_texture_digest = texture_digest(ordered_sources)
        require(
            detail.planned_texture_digest == reconstructed_texture_digest
            and detail.encoded_texture_digest == reconstructed_texture_digest,
            f"{phase} texture digest does not match source lines",
        )
        require(detail.planned_uv_digest == uv_digest(ordered_sources),
                f"{phase} planned UV digest does not match source lines")
        groups[phase] = (primary, detail, ordered_sources)

    baseline, baseline_detail, baseline_sources = groups["B"]
    transition, transition_detail, transition_sources = groups["T"]
    require(baseline.index < transition.index, "transition precedes baseline")
    require(transition.sequence > baseline.sequence, "transition is not later")
    require(baseline.source_digest == transition.source_digest,
            "B/T source cohort digest differs")
    require(
        [(source.source_id, source.mode) for source in baseline_sources]
        == [(source.source_id, source.mode) for source in transition_sources],
        "B/T source cohort differs",
    )
    require(
        baseline_detail.planned_uv_digest
        != transition_detail.planned_uv_digest,
        "transition changed only frame handle/ordinal, not UV",
    )
    require(any(
        source.x_bits != 0 or source.y_bits != 0
        for source in (*baseline_sources, *transition_sources)
    ), "B/T UV evidence is identity-only")
    return groups


NATIVE_PREFIXES = (
    "RendererIOS native scene material-planned:",
    "RendererIOS native scene material-drawn:",
    "RendererIOS native scene kind-planned:",
    "RendererIOS native scene kind-drawn:",
    "RendererIOS native scene alpha:",
    "RendererIOS native scene fail-contract:",
    "RendererIOS native scene fail-selector:",
    "RendererIOS native scene fail-execution:",
)
NATIVE_FIELDS = {
    NATIVE_PREFIXES[0]: ("total", "opaque", "alpha"),
    NATIVE_PREFIXES[1]: ("total", "opaque", "alpha", "textured"),
    NATIVE_PREFIXES[2]: ("total", "landscape", "static", "movable"),
    NATIVE_PREFIXES[3]: ("total", "landscape", "static", "movable"),
    NATIVE_PREFIXES[4]: (
        "opaque-pso", "alpha-pso", "control-alpha-to-opaque", "alpha-fallback"
    ),
    NATIVE_PREFIXES[5]: (
        "unknown-category", "unknown-kind", "invalid-cutoff", "missing-alpha-texture"
    ),
    NATIVE_PREFIXES[6]: ("selector-mismatch", "pso-unavailable"),
    NATIVE_PREFIXES[7]: ("overflow", "planned-drawn", "native-encode"),
}


def parse_native_fields(
    line: str, prefix: str, names: Sequence[str]
) -> dict[str, int]:
    validate_marker_line(line, prefix)
    expected_start = prefix + " mode=production "
    require(line.startswith(expected_start), f"{prefix} mode differs")
    tokens = line[len(expected_start):].split(" ")
    require(len(tokens) == len(names) and all(tokens), f"{prefix} fields differ")
    result: dict[str, int] = {}
    for token, expected_name in zip(tokens, names):
        require(token.count("=") == 1, f"{prefix} token is malformed")
        name, value = token.split("=", 1)
        require(name == expected_name, f"{prefix} fields are reordered")
        result[name] = parse_uint64(value, f"{prefix} {name}")
    return result


def parse_native_identities(lines: Sequence[str]) -> list[tuple[int, int, int]]:
    identities: list[tuple[int, int, int]] = []
    keys: set[tuple[int, int]] = set()
    for index, line in enumerate(lines):
        if not line.startswith(IDENTITY_PREFIX):
            continue
        validate_marker_line(line, "native identity marker")
        match = IDENTITY_RE.fullmatch(line)
        require(match is not None, "native identity marker is malformed")
        generation = parse_uint64(match.group(1), "native generation")
        sequence = parse_uint64(match.group(2), "native sequence")
        require(generation > 0 and sequence > 0, "native identity must be positive")
        require((generation, sequence) not in keys, "native identity is duplicated")
        keys.add((generation, sequence))
        identities.append((index, generation, sequence))
    return identities


def validate_native_frame(
    lines: Sequence[str],
    identities: Sequence[tuple[int, int, int]],
    group: tuple[Primary, Detail, tuple[Source, ...]],
) -> None:
    primary, detail, sources = group
    matches = [
        identity for identity in identities
        if identity[1:] == (primary.generation, primary.sequence)
    ]
    require(len(matches) == 1, f"native identity count differs for {primary.phase}")
    identity_index = matches[0][0]
    next_identity = min(
        (index for index, _, _ in identities if index > identity_index),
        default=len(lines),
    )
    require(
        identity_index < primary.index < detail.index
        < sources[0].index < sources[-1].index < next_identity,
        f"{primary.phase} UV group is outside its native frame block",
    )

    parsed: dict[str, dict[str, int]] = {}
    positions = [identity_index]
    for prefix in NATIVE_PREFIXES:
        found = [
            (index, line)
            for index, line in enumerate(
                lines[identity_index + 1:next_identity], start=identity_index + 1
            )
            if line.startswith(prefix)
        ]
        require(len(found) == 1, f"{prefix} count differs for {primary.phase}")
        index, line = found[0]
        parsed[prefix] = parse_native_fields(line, prefix, NATIVE_FIELDS[prefix])
        positions.append(index)
    positions.extend((primary.index, detail.index, *(source.index for source in sources)))
    require(positions == sorted(positions) and len(set(positions)) == len(positions),
            f"native/UV marker order differs for {primary.phase}")

    material_planned = parsed[NATIVE_PREFIXES[0]]
    material_drawn = parsed[NATIVE_PREFIXES[1]]
    kind_planned = parsed[NATIVE_PREFIXES[2]]
    kind_drawn = parsed[NATIVE_PREFIXES[3]]
    require(material_planned["total"] == EXPECTED_PLANNED,
            f"{primary.phase} native planned total is not 29726")
    require(material_planned["opaque"] + material_planned["alpha"]
            == material_planned["total"],
            f"{primary.phase} planned materials do not conserve")
    require(
        {name: material_drawn[name] for name in ("total", "opaque", "alpha")}
        == material_planned,
        f"{primary.phase} planned/drawn materials differ",
    )
    require(material_drawn["textured"] == material_drawn["total"],
            f"{primary.phase} textured draws do not conserve")
    require(kind_planned["total"] == EXPECTED_PLANNED,
            f"{primary.phase} native kind total is not 29726")
    require(checked_sum(
        [kind_planned[name] for name in ("landscape", "static", "movable")],
        "native planned kinds",
    ) == kind_planned["total"], f"{primary.phase} planned kinds do not conserve")
    require(kind_drawn == kind_planned,
            f"{primary.phase} planned/drawn kinds differ")
    require(parsed[NATIVE_PREFIXES[4]] == {
        "opaque-pso": material_drawn["opaque"],
        "alpha-pso": material_drawn["alpha"],
        "control-alpha-to-opaque": 0,
        "alpha-fallback": 0,
    }, f"{primary.phase} native alpha counts differ")
    for prefix in NATIVE_PREFIXES[5:]:
        require(all(value == 0 for value in parsed[prefix].values()),
                f"{primary.phase} native failure counters are nonzero")


def parse_census(index: int, line: str, expected_sha: str) -> dict[str, int | str]:
    validate_marker_line(line, "D3 census marker")
    require(line.startswith(CENSUS_PREFIX + " "), "D3 census prefix is malformed")
    tokens = line[len(CENSUS_PREFIX) + 1:].split(" ")
    expected_fields = ("v", "b", "g", "s", "k", "m", "a", "x", "o")
    require(len(tokens) == len(expected_fields) and all(tokens),
            "D3 census field count or spacing differs")
    raw: dict[str, str] = {}
    for token, expected_name in zip(tokens, expected_fields):
        require(token.count("=") == 1, "D3 census token is malformed")
        name, value = token.split("=", 1)
        require(name == expected_name, "D3 census fields are reordered")
        raw[name] = value
    require(raw["v"] == "2", "D3 census version must be 2")
    require(raw["b"] == expected_sha, "D3 census has foreign build SHA")
    values: dict[str, int | str] = {
        "index": index,
        "build": raw["b"],
        "generation": parse_uint64(raw["g"], "D3 census generation"),
        "sequence": parse_uint64(raw["s"], "D3 census sequence"),
        **parse_list(raw["k"], KIND_NAMES, "D3 kind census"),
        **parse_list(raw["m"], MATERIAL_NAMES, "D3 material census"),
        **parse_list(raw["a"], ANIMATION_NAMES, "D3 animation census"),
        **parse_list(raw["x"], TEXTURE_OUTCOME_NAMES, "D3 texture outcomes"),
        **parse_list(raw["o"], OUTCOME_NAMES, "D3 outcomes"),
    }
    require(int(values["generation"]) > 0 and int(values["sequence"]) > 0,
            "D3 census identity must be positive")
    require(checked_sum([int(values[name]) for name in KIND_NAMES], "D3 kinds")
            == values["visited"], "D3 kind census does not conserve")
    require(checked_sum([int(values[name]) for name in MATERIAL_NAMES], "D3 materials")
            == values["visited"], "D3 material census does not conserve")
    require(checked_sum(
        [int(values[name]) for name in OUTCOME_NAMES[1:5]], "D3 outcomes"
    ) == values["visited"], "D3 outcomes do not conserve")
    require(checked_sum(
        [int(values[name]) for name in TEXTURE_OUTCOME_NAMES], "D3 texture outcomes"
    ) == values["skipped-texture-animation"],
            "D3 texture outcomes do not match skip total")
    return values


def validate_expected_d3_breakdown(values: dict[str, int | str]) -> None:
    for name, expected in EXPECTED_D3_BREAKDOWN.items():
        require(values[name] == expected, f"D3 census {name} differs")


FATAL_RE = re.compile(
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


def validate(log: str, expected_sha: str, d1_path: pathlib.Path) -> dict[str, Any]:
    require(SHA_RE.fullmatch(expected_sha) is not None,
            "expected SHA must be exact lowercase 40-hex")
    load_d1_census(d1_path)
    require(FATAL_RE.search(log) is None, "fatal or crash signature appeared")
    lines = log.splitlines()
    diagnostics = [line for line in lines if line.startswith(DIAGNOSTICS_PREFIX)]
    require(len(diagnostics) == 1, "expected exactly one diagnostics ON marker")
    require(
        diagnostics[0].startswith(DIAGNOSTICS_ON)
        and diagnostics[0].endswith(" context=IOSMetalContext transport=Tempest"),
        "real diagnostics ON marker is missing",
    )
    frames = diagnostics[0][len(DIAGNOSTICS_ON):].split(" ", 1)[0]
    require(parse_uint64(frames, "frames-in-flight") > 0,
            "frames-in-flight must be positive")

    groups = parse_animation_groups(lines, expected_sha)
    identities = parse_native_identities(lines)
    for group in groups.values():
        validate_native_frame(lines, identities, group)

    census = [
        parse_census(index, line, expected_sha)
        for index, line in enumerate(lines)
        if line.startswith(CENSUS_PREFIX)
    ]
    require(census, "D3 census marker is missing")
    census_keys: set[tuple[int, int]] = set()
    for marker in census:
        key = (int(marker["generation"]), int(marker["sequence"]))
        require(key not in census_keys, "D3 census duplicates generation/sequence")
        census_keys.add(key)
    baseline = groups["B"][0]
    baseline_census = [
        marker for marker in census
        if marker["generation"] == baseline.generation
        and marker["sequence"] == baseline.sequence
    ]
    require(len(baseline_census) == 1,
            "baseline has no unique same-generation/sequence D3 census")
    validate_expected_d3_breakdown(baseline_census[0])
    baseline_identity = [
        index for index, generation, sequence in identities
        if (generation, sequence) == (baseline.generation, baseline.sequence)
    ][0]
    require(int(baseline_census[0]["index"]) < baseline_identity,
            "baseline D3 census does not precede native evidence")

    transition = groups["T"][0]
    return {
        "result": "PASS",
        "build": expected_sha,
        "generation": baseline.generation,
        "baselineSequence": baseline.sequence,
        "transitionSequence": transition.sequence,
        "planned": EXPECTED_PLANNED,
        "admittedUvOnly": EXPECTED_UV_ONLY,
        "admittedFrameAndUv": EXPECTED_FRAME_AND_UV,
        "drawn": EXPECTED_TOTAL,
        "sourceDigest": baseline.source_digest,
        "baselineUVDigest": groups["B"][1].planned_uv_digest,
        "transitionUVDigest": groups["T"][1].planned_uv_digest,
        "d1Sha256": EXPECTED_D1_SHA256,
    }


SELF_TEST_BUILD = "0123456789abcdef0123456789abcdef01234567"
SELF_TEST_D1 = (
    '{"build":"3b22b0eb3772cde9e9d88cc28baeff43b5a7aedc",'
    '"frame-animated":38,"generation":3,"invalid-source":0,'
    '"kind-animated":1563,"kind-landscape":338,"kind-morph":1137,'
    '"kind-movable":8463,"kind-particle":0,"kind-static":22075,'
    '"kind-unknown":0,"kind-unsupported":0,"material-additive-light":183,'
    '"material-alpha-test":11001,"material-ghost":0,"material-missing":0,'
    '"material-multiply":0,"material-multiply2":1,"material-solid":21425,'
    '"material-transparent":962,"material-unknown":0,"material-water":4,'
    '"planned":29702,"sequence":1,"skipped-kind":2700,'
    '"skipped-material":1150,"skipped-texture-animation":24,'
    '"skipped-texture-frame-and-uv":2,"skipped-texture-frame-only":22,'
    '"skipped-texture-uv-only":0,"uv-animated":3,"version":2,'
    '"visited":33576}\n'
)


def self_test_sources(phase: str) -> tuple[Source, Source]:
    if phase == "B":
        values = ((0, 41, 0x00000000, 0x00000000),
                  (1, 42, 0x3F000000, 0xBF000000))
        sequence = 1
    else:
        values = ((1, 43, 0x3E800000, 0x00000000),
                  (2, 44, 0x3F400000, 0xBE800000))
        sequence = 2
    return tuple(
        Source(
            index=0, phase=phase, generation=7, sequence=sequence,
            source_id=source_id, mode="C", ordinal=ordinal, handle=handle,
            x_bits=x, y_bits=y, encoded_x_bits=x, encoded_y_bits=y,
        )
        for source_id, (ordinal, handle, x, y) in zip((9001, 9002), values)
    )  # type: ignore[return-value]


def self_test_source_line(source: Source) -> str:
    return (
        "RendererIOS UV animation source: v=1 "
        f"p={source.phase} g={source.generation} s={source.sequence} "
        f"i={source.source_id} m={source.mode} o={source.ordinal} h={source.handle} "
        f"x={source.x_bits:08x} y={source.y_bits:08x} "
        f"ex={source.encoded_x_bits:08x} ey={source.encoded_y_bits:08x}"
    )


def self_test_group(phase: str) -> list[str]:
    sources = self_test_sources(phase)
    sequence = 1 if phase == "B" else 2
    sd = source_digest([source.source_id for source in sources])
    pu = uv_digest(sources)
    texture = texture_digest(sources)
    return [
        "RendererIOS UV animation: v=1 "
        f"p={phase} b={SELF_TEST_BUILD} g=7 s={sequence} "
        f"a=2 u=0 c=2 d=2 sd={sd}",
        "RendererIOS UV animation detail: v=1 "
        f"p={phase} g=7 s={sequence} pt={texture} et={texture} pu={pu} eu={pu}",
        *(self_test_source_line(source) for source in sources),
    ]


def self_test_native_block(sequence: int) -> list[str]:
    return [
        "RendererIOS native scene identity: mode=production "
        f"generation=7 sequence={sequence}",
        "RendererIOS native scene material-planned: mode=production "
        "total=29726 opaque=18725 alpha=11001",
        "RendererIOS native scene material-drawn: mode=production "
        "total=29726 opaque=18725 alpha=11001 textured=29726",
        "RendererIOS native scene kind-planned: mode=production "
        "total=29726 landscape=338 static=22075 movable=7313",
        "RendererIOS native scene kind-drawn: mode=production "
        "total=29726 landscape=338 static=22075 movable=7313",
        "RendererIOS native scene alpha: mode=production "
        "opaque-pso=18725 alpha-pso=11001 control-alpha-to-opaque=0 alpha-fallback=0",
        "RendererIOS native scene fail-contract: mode=production "
        "unknown-category=0 unknown-kind=0 invalid-cutoff=0 missing-alpha-texture=0",
        "RendererIOS native scene fail-selector: mode=production "
        "selector-mismatch=0 pso-unavailable=0",
        "RendererIOS native scene fail-execution: mode=production "
        "overflow=0 planned-drawn=0 native-encode=0",
    ]


def self_test_valid_log() -> str:
    census = (
        "RendererIOS source census: v=2 "
        f"b={SELF_TEST_BUILD} g=7 s=1 "
        "k=338,22075,8463,1563,0,1137,0,0 "
        "m=21425,11001,4,0,0,1,962,183,0,0 "
        "a=38,3 x=0,0,0 o=33576,29726,2700,1150,0,0"
    )
    lines = [
        "ordinary output",
        "RendererIOS diagnostics: ON frames-in-flight=3 "
        "context=IOSMetalContext transport=Tempest",
        census,
        *self_test_native_block(1),
        *self_test_group("B"),
        "intermediate output",
        *self_test_native_block(2),
        *self_test_group("T"),
        "ordinary tail",
    ]
    return "\n".join(lines) + "\n"


def replace_once(source: str, old: str, new: str) -> str:
    require(source.count(old) == 1, f"self-test anchor is not unique: {old!r}")
    return source.replace(old, new, 1)


def expect_invalid(log: str, d1_path: pathlib.Path, name: str) -> None:
    try:
        validate(log, SELF_TEST_BUILD, d1_path)
    except ValidationError:
        return
    raise ValidationError(f"self-test mutation survived: {name}")


def run_self_test() -> dict[str, Any]:
    require(hashlib.sha256(SELF_TEST_D1.encode()).hexdigest() == EXPECTED_D1_SHA256,
            "self-test D1 fixture is not the frozen artifact")
    require(
        texture_digest(self_test_sources("B")) == "906621937ec3fff0"
        and texture_digest(self_test_sources("T")) == "b0ed1dfda59e8832",
        "self-test texture digest differs from the frozen C++ algorithm",
    )
    with tempfile.TemporaryDirectory(prefix="rendererios-uv-parser-") as directory:
        d1_path = pathlib.Path(directory) / "d1.json"
        d1_path.write_text(SELF_TEST_D1, encoding="utf-8")
        valid = self_test_valid_log()
        result = validate(valid, SELF_TEST_BUILD, d1_path)
        baseline = self_test_group("B")
        transition = self_test_group("T")
        baseline_texture = texture_digest(self_test_sources("B"))
        mismatched_texture = (
            ("0" if baseline_texture[0] != "0" else "1")
            + baseline_texture[1:]
        )
        foreign = "f" * 40
        mutations = {
            "missing": replace_once(valid, transition[3] + "\n", ""),
            "duplicate": replace_once(valid, baseline[0] + "\n", baseline[0] + "\n" + baseline[0] + "\n"),
            "detail mismatch": replace_once(
                valid,
                f"pt={baseline_texture} et={baseline_texture}",
                f"pt={baseline_texture} et={mismatched_texture}",
            ),
            "source mismatch": replace_once(valid, "x=3f000000 y=bf000000 ex=3f000000 ey=bf000000", "x=3f000000 y=bf000000 ex=3f000001 ey=bf000000"),
            "ordinal digest mismatch": replace_once(
                valid,
                "p=B g=7 s=1 i=9001 m=C o=0 h=41",
                "p=B g=7 s=1 i=9001 m=C o=7 h=41",
            ),
            "handle digest mismatch": replace_once(
                valid,
                "p=T g=7 s=2 i=9002 m=C o=2 h=44",
                "p=T g=7 s=2 i=9002 m=C o=2 h=45",
            ),
            "handle-only false transition": replace_once(
                valid,
                f"pu={uv_digest(self_test_sources('T'))} eu={uv_digest(self_test_sources('T'))}",
                f"pu={uv_digest(self_test_sources('B'))} eu={uv_digest(self_test_sources('B'))}",
            ),
            "foreign SHA": replace_once(
                valid,
                f"p=T b={SELF_TEST_BUILD}",
                f"p=T b={foreign}",
            ),
            "noncanonical zero": replace_once(
                valid,
                "x=00000000 y=00000000 ex=00000000 ey=00000000",
                "x=80000000 y=00000000 ex=80000000 ey=00000000",
            ),
            "fatal": valid + "RendererIOS fatal: injected\n",
        }
        for name, mutation in mutations.items():
            expect_invalid(mutation, d1_path, name)
    return {"result": "PASS", "mutations": len(mutations), **result}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--expected-sha")
    parser.add_argument("--d1-census-json", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.self_test:
        require(arguments.log is None and arguments.expected_sha is None
                and arguments.d1_census_json is None,
                "--self-test accepts no evidence arguments")
        result = run_self_test()
    else:
        require(arguments.log is not None, "--log is required")
        require(arguments.expected_sha is not None, "--expected-sha is required")
        require(arguments.d1_census_json is not None,
                "--d1-census-json is required")
        log = arguments.log.read_text(encoding="utf-8", errors="strict")
        result = validate(log, arguments.expected_sha, arguments.d1_census_json)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
