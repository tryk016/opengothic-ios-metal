#!/usr/bin/env python3
"""Validate the P2.6b1 RendererIOS device-facts app marker."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


PREFIX = "RendererIOS device facts:"
FIELD_KEYS = (
    "d",
    "v",
    "fail",
    "rt",
    "sdk",
    "fam",
    "probes",
    "fmt",
    "mask",
    "limits",
)
REFERENCE_A17_VALUES = (
    "1",
    "1",
    "0/0/255/0",
    "26.6.0",
    "27.0.0",
    "9/4",
    "1/1,1/1,1/U,1/1,1/1",
    "0/0",
    "0x170",
    "1024/1024/1024/32768",
)
REFERENCE_A17_MARKER = PREFIX + " " + " ".join(
    f"{key}={value}"
    for key, value in zip(FIELD_KEYS, REFERENCE_A17_VALUES)
)
SHELL_RE = re.compile(
    r"^RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*$",
    re.MULTILINE,
)
UINT_RE = re.compile(r"[0-9]+")
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
STAGE_RE = re.compile(r"[U01]/[U01]")
MASK_RE = re.compile(r"0x[0-9a-f]+")
DIRECT_LIMIT_BITS = (1 << 4, 1 << 5, 1 << 6, 1 << 8)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def parse_uint(value: str, name: str, maximum: int = 0xFFFFFFFF) -> int:
    require(UINT_RE.fullmatch(value) is not None, f"{name} is not decimal")
    parsed = int(value, 10)
    require(parsed <= maximum, f"{name} is out of range")
    return parsed


def parse_version(value: str, name: str) -> tuple[int, int, int]:
    require(VERSION_RE.fullmatch(value) is not None, f"{name} is malformed")
    components = tuple(int(component, 10) for component in value.split("."))
    require(
        len(components) == 3
        and all(component <= 0xFFFF for component in components)
        and (components[0] > 0 or components == (0, 0, 0)),
        f"{name} is outside the frozen triplet domain",
    )
    return components  # type: ignore[return-value]


def parse_marker(line: str) -> dict[str, str]:
    require(line.startswith(PREFIX + " "), "device-facts prefix is malformed")
    tokens = line[len(PREFIX) + 1 :].split(" ")
    require(
        len(tokens) == len(FIELD_KEYS) and all(tokens),
        "device-facts field count changed",
    )
    pairs: list[tuple[str, str]] = []
    for token in tokens:
        require(token.count("=") == 1, "device-facts token is malformed")
        key, value = token.split("=", 1)
        pairs.append((key, value))
    require(
        tuple(key for key, _ in pairs) == FIELD_KEYS,
        "device-facts fields are missing, extra, duplicated, or reordered",
    )
    values = dict(pairs)

    device = parse_uint(values["d"], "d", 1)
    valid = parse_uint(values["v"], "v", 1)
    failure_parts = values["fail"].split("/")
    require(len(failure_parts) == 4, "fail is malformed")
    error = parse_uint(failure_parts[0], "fail.error", 22)
    section = parse_uint(failure_parts[1], "fail.section", 9)
    index = parse_uint(failure_parts[2], "fail.index", 0xFF)
    raw = parse_uint(failure_parts[3], "fail.raw")
    if valid == 1:
        require(
            (error, section, index, raw) == (0, 0, 0xFF, 0),
            "valid facts do not carry the exact success failure tuple",
        )
    else:
        require(error != 0 and section != 0, "invalid facts lack a failure tuple")

    parse_version(values["rt"], "rt")
    parse_version(values["sdk"], "sdk")
    family_parts = values["fam"].split("/")
    require(len(family_parts) == 2, "fam is malformed")
    apple = parse_uint(family_parts[0], "fam.apple", 10)
    metal = parse_uint(family_parts[1], "fam.metal", 4)
    require(metal in (0, 3, 4), "fam.metal is not a queried b1 family")

    probes = values["probes"].split(",")
    require(len(probes) == 5, "probes cardinality changed")
    for position, probe in enumerate(probes):
        require(STAGE_RE.fullmatch(probe) is not None, "probe stage is malformed")
        availability, support = probe.split("/")
        require(
            availability == "1" or support == "U",
            "probe reports support without positive availability",
        )
        if position == 2:
            require(support == "U", "Mesh support must remain Unknown in b1")

    format_parts = values["fmt"].split("/")
    require(len(format_parts) == 2, "fmt is malformed")
    known_formats = parse_uint(format_parts[0], "fmt.known", 0xF)
    supported_formats = parse_uint(format_parts[1], "fmt.supported", 0xF)
    require(
        supported_formats & ~known_formats == 0,
        "fmt supported mask is outside its known mask",
    )
    require(
        (known_formats, supported_formats) == (0, 0),
        "format facts must remain Unknown in b1",
    )

    require(MASK_RE.fullmatch(values["mask"]) is not None, "mask is malformed")
    known_limit_mask = int(values["mask"], 16)
    require(
        known_limit_mask & ~0x170 == 0,
        "mask contains a non-b1 direct limit",
    )
    limits = values["limits"].split("/")
    require(len(limits) == 4, "limits cardinality changed")
    for bit, index, value in zip(DIRECT_LIMIT_BITS, (4, 5, 6, 8), limits):
        parsed = parse_uint(value, f"limits.{index}")
        if not known_limit_mask & bit:
            require(parsed == 0, "unknown direct limit is not stored as zero")

    require(device in (0, 1), "d is outside the boolean domain")
    return values


def validate(
    log: str, expected_build: str, require_reference_a17: bool
) -> dict[str, str | int]:
    require(
        re.fullmatch(r"[0-9a-f]{40}(?:-local)?", expected_build) is not None,
        "expected build must be a lowercase SHA, optionally suffixed -local",
    )
    shell_matches = SHELL_RE.findall(log)
    shell_lines = [
        line
        for line in log.splitlines()
        if line.startswith("RendererIOS shell: version=")
    ]
    require(
        len(shell_lines) == 1 and shell_matches == [expected_build],
        "expected exactly one RendererIOS shell marker with the exact build",
    )
    marker_lines = [
        line for line in log.splitlines() if line.startswith(PREFIX)
    ]
    require(
        len(marker_lines) == 1,
        "expected exactly one dedicated RendererIOS device-facts app marker, "
        f"found {len(marker_lines)}",
    )
    values = parse_marker(marker_lines[0])
    require(
        values["d"] == "1",
        "device-facts gate requires known device-derived facts",
    )
    require(values["v"] == "1", "device-facts gate requires valid facts")
    require(
        values["rt"].split(".", 1)[0] != "0",
        "device-facts gate requires a runtime version",
    )
    require(
        values["sdk"].split(".", 1)[0] != "0",
        "device-facts gate requires an SDK version",
    )
    require(
        parse_uint(values["fam"].split("/")[0], "fam.apple", 10) > 0,
        "device-facts gate requires a positive Apple family",
    )
    require(
        values["mask"] == "0x170",
        "device-facts gate requires all four direct b1 limits",
    )
    require(
        all(
            parse_uint(value, "direct limit") > 0
            for value in values["limits"].split("/")
        ),
        "device-facts gate requires positive direct b1 limits",
    )
    if require_reference_a17:
        require(
            marker_lines[0] == REFERENCE_A17_MARKER,
            "device-facts marker does not equal the canonical A17 reference",
        )
    return {
        "device_facts_expected_build": expected_build,
        "device_facts_marker_count": 1,
        **{
            "device_facts_" + key: value
            for key, value in values.items()
        },
    }


def write_summary(path: pathlib.Path, values: dict[str, str | int]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
    )


def replace_field(marker: str, key: str, replacement: str) -> str:
    anchor = re.search(rf"(?<![A-Za-z0-9]){re.escape(key)}=[^ ]+", marker)
    require(anchor is not None, f"self-test anchor is missing: {key}")
    return marker[: anchor.start()] + f"{key}={replacement}" + marker[anchor.end() :]


def self_test() -> None:
    build = "0123456789abcdef0123456789abcdef01234567-local"
    shell = (
        "RendererIOS shell: version=1 profile=Safe "
        "features=native-landscape-textured,ui "
        f"build={build} gpu=Apple deviceFamily=iPhone16,2 iOS=26.6 "
        "faultMode=none savePreviewRoute=cpu-placeholder"
    )
    portable_marker = REFERENCE_A17_MARKER
    portable_marker = replace_field(portable_marker, "rt", "18.2.0")
    portable_marker = replace_field(portable_marker, "sdk", "26.4.0")
    portable_marker = replace_field(portable_marker, "fam", "8/3")
    portable_marker = replace_field(
        portable_marker, "probes", "1/U,0/U,1/U,U/U,0/U"
    )
    portable_marker = replace_field(
        portable_marker, "limits", "512/512/512/16384"
    )
    portable = shell + "\nordinary app output\n" + portable_marker + "\n"
    reference = shell + "\n" + REFERENCE_A17_MARKER + "\n"
    unknown_marker = (
        "RendererIOS device facts: d=0 v=1 fail=0/0/255/0 "
        "rt=0.0.0 sdk=0.0.0 fam=0/0 probes=U/U,U/U,U/U,U/U,U/U "
        "fmt=0/0 mask=0x0 limits=0/0/0/0"
    )
    unknown = shell + "\n" + unknown_marker + "\n"

    values = validate(portable, build, False)
    require(values["device_facts_marker_count"] == 1, "portable fixture failed")
    parse_marker(unknown_marker)
    try:
        validate(unknown, build, False)
    except ValidationError:
        pass
    else:
        raise ValidationError("all-Unknown fixture survived the device gate")
    validate(reference, build, True)
    try:
        validate(portable, build, True)
    except ValidationError:
        pass
    else:
        raise ValidationError("non-A17 fixture survived the exact reference gate")

    mutations = {
        "missing": shell + "\nordinary app output\n",
        "duplicate": portable + portable_marker + "\n",
        "extra-field": portable.replace(
            portable_marker, portable_marker + " model=iPhone16,2"
        ),
        "missing-shell": portable.replace(shell + "\n", ""),
        "duplicate-shell": shell + "\n" + portable,
        "wrong-build": portable.replace(build, "f" * 40 + "-local"),
        "wrong-prefix-case": portable.replace(
            PREFIX, "RendererIOS Device facts:", 1
        ),
        "reordered": portable.replace(" d=1 v=1", " v=1 d=1", 1),
        "d-domain": replace_field(portable, "d", "2"),
        "v-domain": replace_field(portable, "v", "2"),
        "invalid-facts": replace_field(
            replace_field(portable, "v", "0"), "fail", "1/1/0/1"
        ),
        "fail-cardinality": replace_field(portable, "fail", "0/0/255"),
        "fail-success": replace_field(portable, "fail", "1/1/0/1"),
        "rt-grammar": replace_field(portable, "rt", "18.2"),
        "rt-unknown": replace_field(portable, "rt", "0.1.0"),
        "rt-missing": replace_field(portable, "rt", "0.0.0"),
        "sdk-overflow": replace_field(portable, "sdk", "27.65536.0"),
        "sdk-missing": replace_field(portable, "sdk", "0.0.0"),
        "fam-cardinality": replace_field(portable, "fam", "8"),
        "fam-apple": replace_field(portable, "fam", "11/3"),
        "fam-apple-zero": replace_field(portable, "fam", "0/3"),
        "fam-metal": replace_field(portable, "fam", "8/5"),
        "fam-metal-unqueried": replace_field(portable, "fam", "8/2"),
        "probes-cardinality": replace_field(portable, "probes", "1/U,0/U"),
        "probes-grammar": replace_field(
            portable, "probes", "Y/U,0/U,1/U,U/U,0/U"
        ),
        "probes-dependency": replace_field(
            portable, "probes", "0/1,0/U,1/U,U/U,0/U"
        ),
        "mesh-known": replace_field(
            portable, "probes", "1/U,0/U,1/0,U/U,0/U"
        ),
        "fmt-cardinality": replace_field(portable, "fmt", "0"),
        "fmt-known": replace_field(portable, "fmt", "1/0"),
        "fmt-subset": replace_field(portable, "fmt", "1/2"),
        "mask-grammar": replace_field(portable, "mask", "170"),
        "mask-domain": replace_field(portable, "mask", "0x171"),
        "mask-incomplete": replace_field(
            replace_field(portable, "mask", "0x170"),
            "limits",
            "512/512/512/16384",
        ).replace("mask=0x170", "mask=0x70", 1),
        "limits-cardinality": replace_field(portable, "limits", "512/0/0"),
        "limits-unknown": replace_field(portable, "limits", "512/U/512/16384"),
        "limits-zero": replace_field(portable, "limits", "512/0/512/16384"),
        "limits-overflow": replace_field(
            portable, "limits", "4294967296/512/512/16384"
        ),
        "known-without-device": replace_field(portable, "d", "0"),
    }
    mutations_killed = 0
    for name, mutated in mutations.items():
        try:
            validate(mutated, build, False)
        except ValidationError:
            mutations_killed += 1
        else:
            raise ValidationError(f"mutation survived: {name}")
    require(
        mutations_killed == len(mutations),
        "device-facts marker mutation count drifted",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--summary", type=pathlib.Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--require-reference-a17", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        require(
            args.log is None
            and args.summary is None
            and args.expected_build is None
            and not args.require_reference_a17,
            "--self-test accepts no evidence arguments",
        )
        self_test()
        print("device-facts app marker validator passed")
        return 0

    require(args.log is not None, "--log is required")
    require(args.expected_build is not None, "--expected-build is required")
    values = validate(
        args.log.read_text(encoding="utf-8", errors="replace"),
        args.expected_build,
        args.require_reference_a17,
    )
    if args.summary is not None:
        write_summary(args.summary, values)
    print("device-facts app marker passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
