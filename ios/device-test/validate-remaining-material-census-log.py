#!/usr/bin/env python3
"""Validate P2.1e2a remaining-material census logs and binary artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import struct
import sys
import tempfile
from typing import Any


UINT64_MAX = (1 << 64) - 1
MAX_LOG_BYTES = 64 * 1024 * 1024
MAX_LINE_BYTES = 254
MATERIALS = ("Water", "Ghost", "Multiply", "Multiply2", "Transparent")
KINDS = ("Landscape", "Static", "Movable", "Animated", "Particle", "Morph",
         "Unsupported")
MODES = ("None", "FrameOnly", "UvOnly", "FrameAndUv")
CELL_COUNT = len(MATERIALS) * len(KINDS) * len(MODES)
ARTIFACT_NAME = "remaining-material-census-v1.bin"
ARTIFACT_BYTES = 1312
MAGIC = b"RIOSREM\0"
GROUP_PREFIX = "RendererIOS remaining material census:"
MATERIAL_PREFIX = "RendererIOS remaining material census material:"
ROW_PREFIX = "RendererIOS remaining material census row:"
PREFIXES = (GROUP_PREFIX, MATERIAL_PREFIX, ROW_PREFIX)
SHA40 = r"[0-9a-f]{40}"
SHA64 = r"[0-9a-f]{64}"
U64 = r"(?:0|[1-9][0-9]*)"
GROUP_RE = re.compile(
    rf"{re.escape(GROUP_PREFIX)} v=1 b=({SHA40}) g=({U64}) s=({U64}) "
    rf"n=5,7,4 r=({U64}) t=({U64})\Z"
)
MATERIAL_RE = re.compile(
    rf"{re.escape(MATERIAL_PREFIX)} v=1 b=({SHA40}) g=({U64}) s=({U64}) "
    rf"m=({'|'.join(MATERIALS)}) r=({U64}) t=({U64})\Z"
)
ROW_RE = re.compile(
    rf"{re.escape(ROW_PREFIX)} v=1 b=({SHA40}) g=({U64}) s=({U64}) "
    rf"m=({'|'.join(MATERIALS)}) k=({'|'.join(KINDS)}) "
    rf"c=({U64}),({U64}),({U64}),({U64})\Z"
)


class ValidationError(RuntimeError):
    pass


DEVICE_SPEC_KEYS = {
    "schemaVersion", "saveSlot", "sequence", "materials", "kinds", "modes",
    "boundedKinds", "requiredDurableScans", "requiredStableSeconds",
}
SIMULATOR_SPEC_KEYS = (
    "schemaVersion", "fixture", "scope", "generation", "sequence",
    "orderedMaterials", "orderedKinds", "orderedModes", "expectedCells",
    "expectedTotals", "expectedGlobalTotal", "expectedIgnored",
    "expectedInvalid", "expectedOverflow",
)


def require(value: bool, message: str) -> None:
    if not value:
        raise ValidationError(message)


def parse_u64(value: str, label: str, *, positive: bool = False) -> int:
    require(re.fullmatch(U64, value) is not None,
            f"{label} is not canonical uint64")
    parsed = int(value, 10)
    require(parsed <= UINT64_MAX, f"{label} exceeds uint64")
    if positive:
        require(parsed > 0, f"{label} is not positive")
    return parsed


def checked_sum(values: list[int] | tuple[int, ...], label: str) -> int:
    total = 0
    for value in values:
        require(type(value) is int and 0 <= value <= UINT64_MAX,
                f"{label} contains a non-uint64")
        require(value <= UINT64_MAX - total, f"{label} overflows uint64")
        total += value
    return total


def stable_read(path: pathlib.Path, label: str, maximum: int,
                *, exact: int | None = None) -> bytes:
    require(path.is_absolute() and path == path.resolve(),
            f"{label} path is not canonical absolute")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
                f"{label} is not a single-link regular file")
        require(0 < before.st_size <= maximum, f"{label} size is out of bounds")
        if exact is not None:
            require(before.st_size == exact, f"{label} size is not exact")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            require(bool(chunk), f"{label} ended early")
            chunks.append(chunk)
            remaining -= len(chunk)
        require(os.read(descriptor, 1) == b"", f"{label} grew during read")
        after = os.fstat(descriptor)
        require((before.st_dev, before.st_ino, before.st_mode, before.st_nlink,
                 before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_dev, after.st_ino, after.st_mode, after.st_nlink,
                 after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                f"{label} changed during read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def reject_constant(value: str) -> None:
    raise ValidationError(f"JSON nonfinite constant is forbidden: {value}")


def reject_duplicate(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"JSON duplicate key: {key}")
        result[key] = value
    return result


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                       separators=(",", ":"), allow_nan=False) + "\n").encode()


def validate_device_spec(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    raw = stable_read(path, "device spec", 64 * 1024)
    try:
        value = json.loads(raw.decode("utf-8", errors="strict"),
                           object_pairs_hook=reject_duplicate,
                           parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError("device spec is not strict JSON") from error
    require(type(value) is dict and set(value) == DEVICE_SPEC_KEYS,
            "device spec key set differs")
    require(raw == canonical_json(value), "device spec is not canonical")
    for key, expected in (("schemaVersion", 1), ("saveSlot", 4),
                          ("sequence", 1), ("requiredDurableScans", 10),
                          ("requiredStableSeconds", 90)):
        require(type(value[key]) is int and value[key] == expected,
                f"device spec {key} differs")
    require(value["materials"] == list(MATERIALS),
            "device spec material order differs")
    require(value["kinds"] == list(KINDS), "device spec kind order differs")
    require(value["modes"] == list(MODES), "device spec mode order differs")
    require(value["boundedKinds"] == ["Static", "Movable"],
            "device spec boundedKinds differs")
    return value, raw


def validate_simulator_spec(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    raw = stable_read(path, "simulator spec", 64 * 1024)
    try:
        value = json.loads(raw.decode("utf-8", errors="strict"),
                           object_pairs_hook=reject_duplicate,
                           parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError("simulator spec is not strict JSON") from error
    require(type(value) is dict and tuple(value) == SIMULATOR_SPEC_KEYS,
            "simulator spec key/order differs")
    require(raw == (json.dumps(value, ensure_ascii=False,
                               separators=(",", ":"), allow_nan=False) +
                    "\n").encode(),
            "simulator spec is not exact compact JSON")
    for key, expected in (("schemaVersion", 1), ("generation", 1),
                          ("sequence", 1), ("expectedGlobalTotal", 140),
                          ("expectedIgnored", 4), ("expectedInvalid", 4),
                          ("expectedOverflow", 3)):
        require(type(value[key]) is int and value[key] == expected,
                f"simulator spec {key} differs")
    require(value["fixture"] ==
            "p21e2a-remaining-material-census-v1.json",
            "simulator fixture name differs")
    require(value["scope"] ==
            "host-neutral-adapter,no-product-save-runtime",
            "simulator scope differs")
    require(value["orderedMaterials"] ==
            [name.lower() for name in MATERIALS],
            "simulator material order differs")
    require(value["orderedKinds"] ==
            [name.lower() for name in KINDS],
            "simulator kind order differs")
    require(value["orderedModes"] ==
            ["none", "frame-only", "uv-only", "frame-and-uv"],
            "simulator mode order differs")
    require(value["expectedCells"] == [1] * CELL_COUNT,
            "simulator cells differ")
    require(value["expectedTotals"] == [28] * len(MATERIALS),
            "simulator totals differ")
    return value, raw


def _identity(match: re.Match[str]) -> tuple[str, int, int]:
    return (match.group(1), parse_u64(match.group(2), "generation", positive=True),
            parse_u64(match.group(3), "sequence", positive=True))


def parse_block(lines: list[str], offset: int) -> tuple[dict[str, Any], int]:
    require(offset < len(lines), "missing group header")
    group = GROUP_RE.fullmatch(lines[offset])
    require(group is not None, "remaining-material block does not start with header")
    identity = _identity(group)
    global_raw = parse_u64(group.group(4), "global raw")
    global_table = parse_u64(group.group(5), "global table")
    cells: list[int] = []
    raw_totals: list[int] = []
    table_totals: list[int] = []
    cursor = offset + 1
    for material in MATERIALS:
        require(cursor < len(lines), "missing material header")
        meta = MATERIAL_RE.fullmatch(lines[cursor])
        require(meta is not None and _identity(meta) == identity and
                meta.group(4) == material,
                f"material header differs at {material}")
        raw = parse_u64(meta.group(5), f"{material} raw")
        table = parse_u64(meta.group(6), f"{material} table")
        raw_totals.append(raw)
        table_totals.append(table)
        cursor += 1
        material_cells: list[int] = []
        for kind in KINDS:
            require(cursor < len(lines), "missing material row")
            row = ROW_RE.fullmatch(lines[cursor])
            require(row is not None and _identity(row) == identity and
                    row.group(4) == material and row.group(5) == kind,
                    f"row identity/order differs at {material}/{kind}")
            values = [parse_u64(row.group(index), f"{material}/{kind} cell")
                      for index in range(6, 10)]
            material_cells.extend(values)
            cells.extend(values)
            cursor += 1
        require(checked_sum(material_cells, f"{material} cells") == table,
                f"{material} cells/table total differ")
        require(raw == table, f"{material} raw/table total differ")
    require(len(cells) == CELL_COUNT, "cell count differs")
    require(checked_sum(raw_totals, "raw totals") == global_raw,
            "global raw total differs")
    require(checked_sum(table_totals, "table totals") == global_table,
            "global table total differs")
    require(global_raw == global_table, "global raw/table totals differ")
    return ({"build": identity[0], "generation": identity[1],
             "sequence": identity[2], "cells": cells,
             "rawTotals": raw_totals, "tableTotals": table_totals,
             "globalRaw": global_raw, "globalTable": global_table}, cursor)


def validate_log(raw: bytes, expected_build: str, expected_generation: int,
                 expected_sequence: int) -> dict[str, Any]:
    require(re.fullmatch(SHA40, expected_build) is not None,
            "expected build is not h40")
    require(b"\r" not in raw and b"\0" not in raw,
            "log contains forbidden framing bytes")
    try:
        text = raw.decode("ascii", errors="strict")
    except UnicodeError as error:
        raise ValidationError("log is not strict ASCII") from error
    family: list[str] = []
    for line in text.split("\n"):
        encoded = line.encode("ascii")
        if any(line.startswith(prefix) for prefix in PREFIXES):
            require(0 < len(encoded) <= MAX_LINE_BYTES,
                    "remaining-material line exceeds bound")
            family.append(line)
    require(bool(family), "log has no remaining-material census")
    blocks: list[dict[str, Any]] = []
    cursor = 0
    while cursor < len(family):
        block, cursor = parse_block(family, cursor)
        blocks.append(block)
    matches = [block for block in blocks
               if (block["build"], block["generation"], block["sequence"]) ==
                  (expected_build, expected_generation, expected_sequence)]
    require(len(matches) == 1, "expected census block is missing or duplicated")
    return matches[0]


def encode_artifact(block: dict[str, Any]) -> bytes:
    require(re.fullmatch(SHA40, block["build"]) is not None,
            "artifact build is not h40")
    header = bytearray(96)
    header[0:8] = MAGIC
    struct.pack_into("<HHI", header, 8, 1, 96, 1)
    header[16:36] = bytes.fromhex(block["build"])
    struct.pack_into("<IIIII", header, 36, 5, 7, 4, 8, 0)
    struct.pack_into("<QQQ", header, 56, block["generation"],
                     block["sequence"], CELL_COUNT)
    payload = bytearray(header)
    for domain in (block["cells"], block["rawTotals"], block["tableTotals"],
                   [block["globalRaw"], block["globalTable"]]):
        for value in domain:
            payload += struct.pack("<Q", value)
    require(len(payload) == ARTIFACT_BYTES, "encoded artifact size differs")
    return bytes(payload)


def write_no_clobber(path: pathlib.Path, payload: bytes) -> None:
    require(path.is_absolute() and path == path.resolve() and
            not os.path.lexists(path),
            "artifact output must be absent canonical absolute path")
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY |
                     os.O_NOFOLLOW | os.O_CLOEXEC)
    temporary = f".{path.name}.{os.getpid()}.{os.urandom(8).hex()}.tmp"
    descriptor = -1
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             os.O_NOFOLLOW | os.O_CLOEXEC, 0o600,
                             dir_fd=parent)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            require(written > 0, "artifact output write ended early")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.link(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent,
                follow_symlinks=False)
        os.unlink(temporary, dir_fd=parent)
        os.fsync(parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def parse_artifact(raw: bytes) -> dict[str, Any]:
    require(len(raw) == ARTIFACT_BYTES, "artifact size is not 1312")
    require(raw[:8] == MAGIC, "artifact magic differs")
    require(struct.unpack_from("<HHI", raw, 8) == (1, 96, 1),
            "artifact schema/header/producer differs")
    require(struct.unpack_from("<IIIII", raw, 36) == (5, 7, 4, 8, 0),
            "artifact dimensions/counter/reserved differs")
    generation, sequence, count = struct.unpack_from("<QQQ", raw, 56)
    require(generation > 0 and sequence > 0 and count == CELL_COUNT,
            "artifact identity/count differs")
    require(raw[80:96] == bytes(16), "artifact reserved bytes differ")
    build = raw[16:36].hex()
    offset = 96
    def values(amount: int) -> list[int]:
        nonlocal offset
        result = list(struct.unpack_from(f"<{amount}Q", raw, offset))
        offset += amount * 8
        return result
    cells = values(CELL_COUNT)
    raw_totals = values(5)
    table_totals = values(5)
    global_raw, global_table = values(2)
    require(offset == len(raw), "artifact trailing bytes differ")
    block = {"build": build, "generation": generation, "sequence": sequence,
             "cells": cells, "rawTotals": raw_totals,
             "tableTotals": table_totals, "globalRaw": global_raw,
             "globalTable": global_table}
    for material in range(5):
        first = material * 28
        require(checked_sum(cells[first:first + 28], "artifact cells") ==
                table_totals[material] == raw_totals[material],
                "artifact material conservation differs")
    require(checked_sum(raw_totals, "artifact raw") == global_raw ==
            global_table == checked_sum(table_totals, "artifact table"),
            "artifact global conservation differs")
    return block


def sample_lines(build: str, generation: int, sequence: int,
                 cells: list[int]) -> list[str]:
    raw_totals = [sum(cells[index * 28:(index + 1) * 28]) for index in range(5)]
    total = sum(raw_totals)
    lines = [f"{GROUP_PREFIX} v=1 b={build} g={generation} s={sequence} "
             f"n=5,7,4 r={total} t={total}"]
    for material_index, material in enumerate(MATERIALS):
        lines.append(
            f"{MATERIAL_PREFIX} v=1 b={build} g={generation} s={sequence} "
            f"m={material} r={raw_totals[material_index]} "
            f"t={raw_totals[material_index]}")
        for kind_index, kind in enumerate(KINDS):
            first = (material_index * 7 + kind_index) * 4
            values = ",".join(str(value) for value in cells[first:first + 4])
            lines.append(
                f"{ROW_PREFIX} v=1 b={build} g={generation} s={sequence} "
                f"m={material} k={kind} c={values}")
    return lines


def self_test() -> None:
    build = "a" * 40
    cells = [1] * CELL_COUNT
    lines = sample_lines(build, 7, 1, cells)
    require(len(lines) == 41, "fixture block line count differs")
    maximum = sample_lines(build, UINT64_MAX, UINT64_MAX,
                           [UINT64_MAX] + [0] * (CELL_COUNT - 1))[-1]
    # The frozen worst-case row uses all six numeric fields at UINT64_MAX.
    worst = (f"{ROW_PREFIX} v=1 b={build} g={UINT64_MAX} s={UINT64_MAX} "
             f"m=Transparent k=Unsupported "
             f"c={UINT64_MAX},{UINT64_MAX},{UINT64_MAX},{UINT64_MAX}")
    require(len(worst.encode("ascii")) == 249, "worst row is not exact 249 B")
    require(len(maximum) <= MAX_LINE_BYTES, "fixture row exceeds bound")
    raw = ("unrelated\n" + "\n".join(lines) + "\n").encode("ascii")
    block = validate_log(raw, build, 7, 1)
    artifact = encode_artifact(block)
    require(parse_artifact(artifact) == block, "artifact roundtrip differs")

    # Frozen external-layout oracle: ordered, unequal cells ensure that an
    # encode+parse order/endian change cannot remain self-consistent.
    oracle_cells = list(range(1, CELL_COUNT + 1))
    oracle_raw = ("\n".join(sample_lines(build, 7, 1, oracle_cells)) +
                  "\n").encode("ascii")
    oracle_block = validate_log(oracle_raw, build, 7, 1)
    oracle_artifact = encode_artifact(oracle_block)
    require(hashlib.sha256(oracle_artifact).hexdigest() ==
            "07904c7b0242d1f795fbbf3ec836af53096b55f9d14fae18d30c22300e4fdc9f",
            "frozen artifact layout hash differs")
    require(oracle_artifact[:96].hex() ==
            "52494f5352454d000100600001000000" + "aa" * 20 +
            "0500000007000000040000000800000000000000" +
            "070000000000000001000000000000008c00000000000000" +
            "00000000000000000000000000000000",
            "frozen artifact header bytes differ")
    require(struct.unpack_from("<140Q", oracle_artifact, 96) ==
            tuple(oracle_cells), "frozen artifact cell order differs")
    require(struct.unpack_from("<5Q", oracle_artifact, 1216) ==
            (406, 1190, 1974, 2758, 3542) and
            struct.unpack_from("<5Q", oracle_artifact, 1256) ==
            (406, 1190, 1974, 2758, 3542) and
            struct.unpack_from("<2Q", oracle_artifact, 1296) == (9870, 9870),
            "frozen artifact totals/offsets differ")
    reordered = bytearray(oracle_artifact)
    reordered[96:104], reordered[104:112] = \
        reordered[104:112], reordered[96:104]
    require(parse_artifact(bytes(reordered)) != oracle_block,
            "artifact/log order mutation survived")

    mutations: list[bytes] = []
    mutations.append(("\n".join(lines[:-1]) + "\n").encode())
    swapped = lines.copy()
    swapped[2], swapped[3] = swapped[3], swapped[2]
    mutations.append(("\n".join(swapped) + "\n").encode())
    mutations.append(("\n".join(lines + lines) + "\n").encode())
    forged = lines.copy()
    forged[1] = forged[1].replace(" r=28 t=28", " r=29 t=28")
    mutations.append(("\n".join(forged) + "\n").encode())
    trailing = lines.copy()
    trailing[0] += " extra=1"
    mutations.append(("\n".join(trailing) + "\n").encode())
    mutations.append(("\r\n".join(lines) + "\r\n").encode())
    mutations.append(("\n".join(lines) + "\0\n").encode())
    for mutated in mutations:
        try:
            validate_log(mutated, build, 7, 1)
        except ValidationError:
            pass
        else:
            raise ValidationError("log mutation survived")
    for mutated in (artifact[:-1], artifact + b"\0",
                    b"X" + artifact[1:],
                    artifact[:80] + b"\1" + artifact[81:]):
        try:
            parse_artifact(mutated)
        except ValidationError:
            pass
        else:
            raise ValidationError("artifact mutation survived")
    with tempfile.TemporaryDirectory(prefix="remaining-census-selftest-") as name:
        root = pathlib.Path(name).resolve()
        source = root / "source.log"
        source.write_bytes(raw)
        alias = root / "alias.log"
        alias.symlink_to(source)
        try:
            stable_read(alias, "symlink fixture", MAX_LOG_BYTES)
        except ValidationError:
            pass
        else:
            raise ValidationError("symlink input mutation survived")
        output = root / "artifact.bin"
        write_no_clobber(output, artifact)
        require(stable_read(output, "published artifact", ARTIFACT_BYTES,
                            exact=ARTIFACT_BYTES) == artifact,
                "published artifact bytes differ")
        require(stat.S_IMODE(output.stat().st_mode) == 0o600,
                "published artifact mode differs")
        try:
            write_no_clobber(output, artifact)
        except ValidationError:
            pass
        else:
            raise ValidationError("artifact collision mutation survived")
        require(not tuple(root.glob(".artifact.bin.*.tmp")),
                "artifact publication left a temporary file")
    print("remaining-material-census self-test: PASS blocks=1 mutations=16 oracle=1")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    spec = sub.add_parser("validate-device-spec")
    spec.add_argument("--spec", type=pathlib.Path, required=True)
    simulator_spec = sub.add_parser("validate-simulator-spec")
    simulator_spec.add_argument("--spec", type=pathlib.Path, required=True)
    log = sub.add_parser("validate-log")
    log.add_argument("--log", type=pathlib.Path, required=True)
    log.add_argument("--build", required=True)
    log.add_argument("--generation", type=int, required=True)
    log.add_argument("--sequence", type=int, required=True)
    build = sub.add_parser("build-artifact")
    build.add_argument("--log", type=pathlib.Path, required=True)
    build.add_argument("--build", required=True)
    build.add_argument("--generation", type=int, required=True)
    build.add_argument("--sequence", type=int, required=True)
    build.add_argument("--output", type=pathlib.Path, required=True)
    artifact = sub.add_parser("validate-artifact")
    artifact.add_argument("--artifact", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.command == "self-test":
        self_test()
        return 0
    if args.command == "validate-device-spec":
        validate_device_spec(args.spec)
        print("remaining-material-census device spec: PASS")
        return 0
    if args.command == "validate-simulator-spec":
        validate_simulator_spec(args.spec)
        print("remaining-material-census simulator spec: PASS")
        return 0
    if args.command in ("validate-log", "build-artifact"):
        raw = stable_read(args.log, "log", MAX_LOG_BYTES)
        block = validate_log(raw, args.build, args.generation, args.sequence)
        if args.command == "validate-log":
            print("remaining-material-census log: PASS")
            return 0
        payload = encode_artifact(block)
        write_no_clobber(args.output, payload)
        print(hashlib.sha256(payload).hexdigest())
        return 0
    raw = stable_read(args.artifact, "artifact", ARTIFACT_BYTES,
                      exact=ARTIFACT_BYTES)
    parse_artifact(raw)
    print("remaining-material-census artifact: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError, ValueError) as error:
        print(f"remaining-material-census: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
