#!/usr/bin/env python3
"""Validate P2.1d2 frame-animation evidence in an ordinary device log."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Any, Sequence


PRIMARY_PREFIX = "RendererIOS frame animation:"
DETAIL_PREFIX = "RendererIOS frame animation detail:"
CENSUS_PREFIX = "RendererIOS source census:"
DIAGNOSTICS_PREFIX = "RendererIOS diagnostics:"
DIAGNOSTICS_ON = "RendererIOS diagnostics: ON frames-in-flight="
MAX_MARKER_BYTES = 254
UINT64_MAX = (1 << 64) - 1
EXPECTED_ADMITTED = 22
EXPECTED_D1_SHA256 = (
    "03e0f24324fc15c22d048473bec30586f7867642db8bc2a7977b6843aed791a5"
)
EXPECTED_D1_BUILD = "3b22b0eb3772cde9e9d88cc28baeff43b5a7aedc"
SHA_RE = re.compile(r"[0-9a-f]{40}")
HEX64_RE = re.compile(r"[0-9a-f]{16}")
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

EXPECTED_D2_BREAKDOWN = {
    **{name: int(EXPECTED_D1[name]) for name in KIND_NAMES},
    **{name: int(EXPECTED_D1[name]) for name in MATERIAL_NAMES},
    "frame-animated": 38,
    "uv-animated": 3,
    "skipped-texture-frame-only": 0,
    "skipped-texture-uv-only": 0,
    "skipped-texture-frame-and-uv": 2,
    "visited": 33576,
    "planned": int(EXPECTED_D1["planned"]) + EXPECTED_ADMITTED,
    "skipped-kind": 2700,
    "skipped-material": 1150,
    "skipped-texture-animation": 2,
    "invalid-source": 0,
}

PRIMARY_RE = re.compile(
    rf"^{re.escape(PRIMARY_PREFIX)} v=1 p=([BT]) b=([0-9a-f]{{40}}) "
    r"g=(\S+) s=(\S+) a=(\S+) n=(\S+) "
    r"sd=([0-9a-f]{16}) pd=([0-9a-f]{16})$"
)
DETAIL_RE = re.compile(
    rf"^{re.escape(DETAIL_PREFIX)} v=1 p=([BT]) "
    r"g=(\S+) s=(\S+) d=(\S+) dd=([0-9a-f]{16}) "
    r"c=(\S+) f=(\S+) t=(\S+)$"
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


def parse_list(value: str, names: Sequence[str], label: str) -> dict[str, int]:
    fields = value.split(",")
    require(len(fields) == len(names), f"{label} cardinality changed")
    return {
        name: parse_uint64(field, name)
        for name, field in zip(names, fields)
    }


def checked_sum(values: Sequence[int], label: str) -> int:
    result = 0
    for value in values:
        require(result <= UINT64_MAX - value, f"{label} overflows uint64")
        result += value
    return result


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
        text = raw.decode("utf-8", errors="strict")
        parsed = json.loads(
            text,
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
    require(parsed["build"] == EXPECTED_D1_BUILD, "D1 build provenance differs")
    require(parsed["version"] == 2, "D1 schema version differs")
    return parsed


@dataclass(frozen=True)
class Primary:
    index: int
    phase: str
    build: str
    generation: int
    sequence: int
    admitted: int
    nonzero: int
    source_digest: str
    pair_digest: str


@dataclass(frozen=True)
class Detail:
    index: int
    phase: str
    generation: int
    sequence: int
    drawn: int
    drawn_digest: str
    changed_source: int
    from_ordinal: int
    to_ordinal: int


def parse_primary(index: int, line: str, expected_sha: str) -> Primary:
    validate_marker_line(line, "frame-animation primary marker")
    match = PRIMARY_RE.fullmatch(line)
    require(match is not None, "frame-animation primary marker is malformed")
    phase, build, generation, sequence, admitted, nonzero, source, pair = (
        match.groups()
    )
    require(build == expected_sha, "frame-animation marker has foreign build SHA")
    require(HEX64_RE.fullmatch(source) is not None, "source digest is malformed")
    require(HEX64_RE.fullmatch(pair) is not None, "pair digest is malformed")
    parsed = Primary(
        index=index,
        phase=phase,
        build=build,
        generation=parse_uint64(generation, f"{phase} generation"),
        sequence=parse_uint64(sequence, f"{phase} sequence"),
        admitted=parse_uint64(admitted, f"{phase} admitted"),
        nonzero=parse_uint64(nonzero, f"{phase} nonzero"),
        source_digest=source,
        pair_digest=pair,
    )
    require(parsed.generation > 0, f"{phase} generation must be positive")
    require(parsed.sequence > 0, f"{phase} sequence must be positive")
    require(parsed.admitted == EXPECTED_ADMITTED, f"{phase} admitted must be 22")
    require(parsed.nonzero <= parsed.admitted, f"{phase} nonzero exceeds admitted")
    return parsed


def parse_detail(index: int, line: str) -> Detail:
    validate_marker_line(line, "frame-animation detail marker")
    match = DETAIL_RE.fullmatch(line)
    require(match is not None, "frame-animation detail marker is malformed")
    phase, generation, sequence, drawn, digest, changed, before, after = (
        match.groups()
    )
    require(HEX64_RE.fullmatch(digest) is not None, "drawn digest is malformed")
    parsed = Detail(
        index=index,
        phase=phase,
        generation=parse_uint64(generation, f"{phase} detail generation"),
        sequence=parse_uint64(sequence, f"{phase} detail sequence"),
        drawn=parse_uint64(drawn, f"{phase} drawnAnimated"),
        drawn_digest=digest,
        changed_source=parse_uint64(changed, f"{phase} changed source"),
        from_ordinal=parse_uint64(before, f"{phase} from ordinal"),
        to_ordinal=parse_uint64(after, f"{phase} to ordinal"),
    )
    require(parsed.generation > 0, f"{phase} detail generation must be positive")
    require(parsed.sequence > 0, f"{phase} detail sequence must be positive")
    require(parsed.drawn == EXPECTED_ADMITTED, f"{phase} drawnAnimated must be 22")
    return parsed


def parse_animation_pairs(
    lines: Sequence[str], expected_sha: str
) -> dict[str, tuple[Primary, Detail]]:
    primary = [
        parse_primary(index, line, expected_sha)
        for index, line in enumerate(lines)
        if line.startswith(PRIMARY_PREFIX)
    ]
    detail = [
        parse_detail(index, line)
        for index, line in enumerate(lines)
        if line.startswith(DETAIL_PREFIX)
    ]
    require(len(primary) == 2, "expected exactly two frame-animation primary lines")
    require(len(detail) == 2, "expected exactly two frame-animation detail lines")
    pairs: dict[str, tuple[Primary, Detail]] = {}
    for phase in ("B", "T"):
        phase_primary = [marker for marker in primary if marker.phase == phase]
        phase_detail = [marker for marker in detail if marker.phase == phase]
        require(len(phase_primary) == 1, f"expected exactly one {phase} primary")
        require(len(phase_detail) == 1, f"expected exactly one {phase} detail")
        first = phase_primary[0]
        second = phase_detail[0]
        require(
            (first.phase, first.generation, first.sequence)
            == (second.phase, second.generation, second.sequence),
            f"{phase} primary/detail p/g/s mismatch",
        )
        require(first.index < second.index, f"{phase} detail precedes primary")
        pairs[phase] = (first, second)

    baseline, baseline_detail = pairs["B"]
    transition, transition_detail = pairs["T"]
    require(baseline.generation == transition.generation, "B/T generation differs")
    require(transition.sequence > baseline.sequence, "transition is not later")
    require(baseline.index < transition.index, "transition precedes baseline")
    require(
        baseline.source_digest == transition.source_digest,
        "B/T source cohort digest differs",
    )
    require(
        baseline.nonzero > 0 or transition.nonzero > 0,
        "B/T evidence has no nonzero selected ordinal",
    )
    require(
        baseline.pair_digest != transition.pair_digest,
        "B/T selected ordinal pair digest did not change",
    )
    require(
        baseline_detail.drawn_digest != transition_detail.drawn_digest,
        "B/T downstream drawn digest did not change",
    )
    require(
        (baseline_detail.changed_source,
         baseline_detail.from_ordinal,
         baseline_detail.to_ordinal) == (0, 0, 0),
        "baseline change tuple must be zero",
    )
    require(
        transition_detail.changed_source > 0
        and transition_detail.from_ordinal != transition_detail.to_ordinal,
        "transition must change ordinals for one nonzero source",
    )
    return pairs


IDENTITY_PREFIX = "RendererIOS native scene identity:"
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
IDENTITY_RE = re.compile(
    rf"^{re.escape(IDENTITY_PREFIX)} mode=production generation=(\S+) sequence=(\S+)$"
)


def parse_native_fields(
    line: str,
    prefix: str,
    ordered_names: Sequence[str],
) -> dict[str, int]:
    validate_marker_line(line, prefix)
    expected_start = prefix + " mode=production "
    require(line.startswith(expected_start), f"{prefix} marker mode or prefix differs")
    tokens = line[len(expected_start):].split(" ")
    require(len(tokens) == len(ordered_names) and all(tokens), f"{prefix} fields differ")
    result: dict[str, int] = {}
    for token, expected_name in zip(tokens, ordered_names):
        require(token.count("=") == 1, f"{prefix} token is malformed")
        name, value = token.split("=", 1)
        require(name == expected_name, f"{prefix} fields are reordered or renamed")
        result[name] = parse_uint64(value, f"{prefix} {name}")
    return result


NATIVE_FIELDS = {
    NATIVE_PREFIXES[0]: ("total", "opaque", "alpha"),
    NATIVE_PREFIXES[1]: ("total", "opaque", "alpha", "textured"),
    NATIVE_PREFIXES[2]: ("total", "landscape", "static", "movable"),
    NATIVE_PREFIXES[3]: ("total", "landscape", "static", "movable"),
    NATIVE_PREFIXES[4]: (
        "opaque-pso",
        "alpha-pso",
        "control-alpha-to-opaque",
        "alpha-fallback",
    ),
    NATIVE_PREFIXES[5]: (
        "unknown-category",
        "unknown-kind",
        "invalid-cutoff",
        "missing-alpha-texture",
    ),
    NATIVE_PREFIXES[6]: ("selector-mismatch", "pso-unavailable"),
    NATIVE_PREFIXES[7]: ("overflow", "planned-drawn", "native-encode"),
}


def validate_native_frame(
    lines: Sequence[str],
    identities: Sequence[tuple[int, int, int]],
    primary: Primary,
    detail: Detail,
) -> dict[str, dict[str, int]]:
    matches = [
        identity for identity in identities
        if identity[1:] == (primary.generation, primary.sequence)
    ]
    require(len(matches) == 1, f"native identity count differs for phase {primary.phase}")
    identity_index = matches[0][0]
    next_identity = min(
        (index for index, _, _ in identities if index > identity_index),
        default=len(lines),
    )
    require(identity_index < primary.index < detail.index < next_identity,
            f"phase {primary.phase} marker pair is outside its native frame block")

    parsed: dict[str, dict[str, int]] = {}
    positions: list[int] = [identity_index]
    for prefix in NATIVE_PREFIXES:
        found = [
            (index, line)
            for index, line in enumerate(lines[identity_index + 1:next_identity],
                                         start=identity_index + 1)
            if line.startswith(prefix)
        ]
        require(len(found) == 1, f"{prefix} count differs for phase {primary.phase}")
        index, line = found[0]
        parsed[prefix] = parse_native_fields(line, prefix, NATIVE_FIELDS[prefix])
        positions.append(index)
    positions.extend((primary.index, detail.index))
    require(positions == sorted(positions) and len(set(positions)) == len(positions),
            f"native marker order differs for phase {primary.phase}")

    material_planned = parsed[NATIVE_PREFIXES[0]]
    material_drawn = parsed[NATIVE_PREFIXES[1]]
    kind_planned = parsed[NATIVE_PREFIXES[2]]
    kind_drawn = parsed[NATIVE_PREFIXES[3]]
    expected_total = int(EXPECTED_D2_BREAKDOWN["planned"])
    require(material_planned["total"] == expected_total,
            f"phase {primary.phase} native planned total is not D1+22")
    require(
        material_planned["opaque"] + material_planned["alpha"]
        == material_planned["total"],
        f"phase {primary.phase} planned materials do not conserve",
    )
    require(
        {name: material_drawn[name] for name in ("total", "opaque", "alpha")}
        == material_planned,
        f"phase {primary.phase} planned/drawn materials differ",
    )
    require(material_drawn["textured"] == material_drawn["total"],
            f"phase {primary.phase} textured draws do not conserve")
    require(kind_planned["total"] == expected_total,
            f"phase {primary.phase} planned kind total is not D1+22")
    require(
        checked_sum(
            [kind_planned[name] for name in ("landscape", "static", "movable")],
            "native planned kinds",
        ) == kind_planned["total"],
        f"phase {primary.phase} planned kinds do not conserve",
    )
    require(kind_drawn == kind_planned,
            f"phase {primary.phase} planned/drawn kinds differ")

    alpha = parsed[NATIVE_PREFIXES[4]]
    require(alpha == {
        "opaque-pso": material_drawn["opaque"],
        "alpha-pso": material_drawn["alpha"],
        "control-alpha-to-opaque": 0,
        "alpha-fallback": 0,
    }, f"phase {primary.phase} native alpha counts differ")
    for prefix in NATIVE_PREFIXES[5:]:
        require(all(value == 0 for value in parsed[prefix].values()),
                f"phase {primary.phase} native failure counters are nonzero")
    return parsed


def parse_native_identities(lines: Sequence[str]) -> list[tuple[int, int, int]]:
    identities: list[tuple[int, int, int]] = []
    for index, line in enumerate(lines):
        if not line.startswith(IDENTITY_PREFIX):
            continue
        validate_marker_line(line, "native identity marker")
        match = IDENTITY_RE.fullmatch(line)
        require(match is not None, "native identity marker is malformed or non-production")
        generation = parse_uint64(match.group(1), "native generation")
        sequence = parse_uint64(match.group(2), "native sequence")
        require(generation > 0 and sequence > 0, "native identity must be positive")
        identities.append((index, generation, sequence))
    return identities


def parse_census(index: int, line: str, expected_sha: str) -> dict[str, int | str]:
    validate_marker_line(line, "D2 census marker")
    require(line.startswith(CENSUS_PREFIX + " "), "D2 census prefix is malformed")
    tokens = line[len(CENSUS_PREFIX) + 1:].split(" ")
    expected_fields = ("v", "b", "g", "s", "k", "m", "a", "x", "o")
    require(len(tokens) == len(expected_fields) and all(tokens),
            "D2 census field count or spacing differs")
    raw: dict[str, str] = {}
    for token, expected_name in zip(tokens, expected_fields):
        require(token.count("=") == 1, "D2 census token is malformed")
        name, value = token.split("=", 1)
        require(name == expected_name, "D2 census fields are reordered or renamed")
        raw[name] = value
    require(raw["v"] == "2", "D2 census version must be 2")
    require(raw["b"] == expected_sha, "D2 census has foreign build SHA")
    generation = parse_uint64(raw["g"], "D2 census generation")
    sequence = parse_uint64(raw["s"], "D2 census sequence")
    require(generation > 0, "D2 census generation must be positive")
    require(sequence == 1 or (sequence > 0 and sequence % 300 == 0),
            "D2 census sequence is outside diagnostics cadence")
    values: dict[str, int | str] = {
        "index": index,
        "build": raw["b"],
        "version": 2,
        "generation": generation,
        "sequence": sequence,
        **parse_list(raw["k"], KIND_NAMES, "D2 kind census"),
        **parse_list(raw["m"], MATERIAL_NAMES, "D2 material census"),
        **parse_list(raw["a"], ANIMATION_NAMES, "D2 animation census"),
        **parse_list(raw["x"], TEXTURE_OUTCOME_NAMES, "D2 texture outcomes"),
        **parse_list(raw["o"], OUTCOME_NAMES, "D2 outcomes"),
    }
    require(
        checked_sum([int(values[name]) for name in KIND_NAMES], "D2 kinds")
        == values["visited"],
        "D2 kind census does not conserve",
    )
    require(
        checked_sum([int(values[name]) for name in MATERIAL_NAMES], "D2 materials")
        == values["visited"],
        "D2 material census does not conserve",
    )
    require(
        checked_sum(
            [int(values[name]) for name in OUTCOME_NAMES[1:5]],
            "D2 outcomes",
        ) == values["visited"],
        "D2 outcomes do not conserve",
    )
    require(values["invalid-source"] == 0,
            "D2 census invalid-source must be zero")
    require(values["kind-unknown"] == 0,
            "D2 census unknown kind must be zero")
    require(values["material-unknown"] == 0,
            "D2 census unknown material must be zero")
    require(values["frame-animated"] <= values["visited"],
            "D2 frame animation count exceeds visited")
    require(values["uv-animated"] <= values["visited"],
            "D2 UV animation count exceeds visited")
    texture_outcomes = [
        int(values[name]) for name in TEXTURE_OUTCOME_NAMES
    ]
    require(
        checked_sum(texture_outcomes, "D2 texture outcomes")
        == values["skipped-texture-animation"],
        "D2 texture outcomes do not match the texture-animation skip total",
    )
    require(
        checked_sum(
            [texture_outcomes[0], texture_outcomes[2]],
            "D2 frame texture outcomes",
        ) <= values["frame-animated"],
        "D2 frame texture outcomes exceed the frame-animation census",
    )
    require(
        checked_sum(
            [texture_outcomes[1], texture_outcomes[2]],
            "D2 UV texture outcomes",
        ) <= values["uv-animated"],
        "D2 UV texture outcomes exceed the UV-animation census",
    )
    return values


def validate_expected_d2_breakdown(values: dict[str, int | str]) -> None:
    for name, expected in EXPECTED_D2_BREAKDOWN.items():
        require(values[name] == expected, f"D2 census {name} differs")


FATAL_RE = re.compile(
    r"RendererIOS (?:fatal|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed|"
    r"native Landscape encode failed|IOSGPUScene metallib loading failed)|"
    r"(?:^|\b)fatal(?:\s+error)?\s*:|"
    r"\bEXC_CRASH\b|Exception Type:\s*EXC_RESOURCE\b|"
    r"\bTerminated due to signal\b|\bSegmentation fault\b|"
    r"\bAbort trap\b|(?:^|\n)\s*Killed:\s*[0-9]+\s*(?=\n|$)|"
    r"\bSIG(?:ABRT|SEGV|KILL)\b|\bEXC_BAD_ACCESS\b|"
    r"libc\+\+abi:|AddressSanitizer|ThreadSanitizer|"
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
    diagnostic_lines = [
        line for line in lines if line.startswith(DIAGNOSTICS_PREFIX)
    ]
    require(len(diagnostic_lines) == 1,
            "expected exactly one diagnostics ON marker")
    require(
        diagnostic_lines[0].startswith(DIAGNOSTICS_ON)
        and diagnostic_lines[0].endswith(
            " context=IOSMetalContext transport=Tempest"
        ),
        "device evidence does not contain the real diagnostics ON marker",
    )
    frames_text = diagnostic_lines[0][len(DIAGNOSTICS_ON):].split(" ", 1)[0]
    require(parse_uint64(frames_text, "frames-in-flight") > 0,
            "frames-in-flight must be positive")

    pairs = parse_animation_pairs(lines, expected_sha)
    identities = parse_native_identities(lines)
    native = {
        phase: validate_native_frame(lines, identities, pair[0], pair[1])
        for phase, pair in pairs.items()
    }
    census = [
        parse_census(index, line, expected_sha)
        for index, line in enumerate(lines)
        if line.startswith(CENSUS_PREFIX)
    ]
    require(census, "D2 census marker is missing")
    census_keys: set[tuple[int, int]] = set()
    for marker in census:
        key = (int(marker["generation"]), int(marker["sequence"]))
        require(key not in census_keys,
                "D2 census duplicates generation/sequence")
        census_keys.add(key)
    baseline = pairs["B"][0]
    baseline_census = [
        marker for marker in census
        if marker["generation"] == baseline.generation
        and marker["sequence"] == baseline.sequence
    ]
    require(len(baseline_census) == 1,
            "baseline has no unique same-generation/sequence D2 census")
    validate_expected_d2_breakdown(baseline_census[0])
    baseline_identity = [
        index for index, generation, sequence in identities
        if (generation, sequence) == (baseline.generation, baseline.sequence)
    ][0]
    require(int(baseline_census[0]["index"]) < baseline_identity,
            "baseline D2 census does not precede native frame evidence")

    return {
        "result": "PASS",
        "build": expected_sha,
        "generation": baseline.generation,
        "baselineSequence": baseline.sequence,
        "transitionSequence": pairs["T"][0].sequence,
        "admitted": EXPECTED_ADMITTED,
        "drawnAnimated": EXPECTED_ADMITTED,
        "planned": int(EXPECTED_D2_BREAKDOWN["planned"]),
        "d1Sha256": EXPECTED_D1_SHA256,
        "sourceDigest": baseline.source_digest,
        "baselinePairDigest": baseline.pair_digest,
        "transitionPairDigest": pairs["T"][0].pair_digest,
        "baselineDrawnDigest": pairs["B"][1].drawn_digest,
        "transitionDrawnDigest": pairs["T"][1].drawn_digest,
        "nativeFrames": len(native),
    }


def validate_absent(log: str) -> dict[str, str]:
    lines = log.splitlines()
    offending = [
        line for line in lines
        if line.startswith(PRIMARY_PREFIX) or line.startswith(DETAIL_PREFIX)
    ]
    require(not offending, "frame-animation marker appeared in OFF log")
    return {"result": "PASS", "frameAnimation": "absent"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=pathlib.Path)
    parser.add_argument("--expected-sha")
    parser.add_argument("--d1-census-json", type=pathlib.Path)
    parser.add_argument("--expect-absent", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    log = arguments.log.read_text(encoding="utf-8", errors="strict")
    if arguments.expect_absent:
        require(arguments.expected_sha is None and arguments.d1_census_json is None,
                "--expect-absent accepts no ON evidence arguments")
        result = validate_absent(log)
    else:
        require(arguments.expected_sha is not None, "--expected-sha is required")
        require(arguments.d1_census_json is not None, "--d1-census-json is required")
        result = validate(log, arguments.expected_sha, arguments.d1_census_json)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
