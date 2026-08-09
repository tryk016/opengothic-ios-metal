#!/usr/bin/env python3
"""Validate P2.1e1a additive census logs, artifacts, and device evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import secrets
import stat
import struct
import sys
import tempfile
from typing import Any, Iterable, Sequence


UINT64_MAX = (1 << 64) - 1
MAX_LOG_BYTES = 64 * 1024 * 1024
MAX_MARKER_BYTES = 254
ARTIFACT_BYTES = 304
ARTIFACT_NAME = "additive-source-census-v1.bin"
ATTESTATION_NAME = "additive-source-census-device-attestation-v1.json"
MAGIC = b"RIOSADD\0"
HEADER_PREFIX = "RendererIOS additive source census:"
ROW_PREFIX = "RendererIOS additive source census row:"
SOURCE_PREFIX = "RendererIOS source census:"
SHA40_RE = re.compile(r"[0-9a-f]{40}\Z")
SHA64_RE = re.compile(r"[0-9a-f]{64}\Z")
UINT_RE = re.compile(r"0|[1-9][0-9]*\Z")
POSITIVE_RE = re.compile(r"[1-9][0-9]*\Z")
RESULT_KEY_RE = re.compile(r"[a-z][a-z0-9_]*\Z")
SIGNED_EXECUTABLE_KEY = "signed_executable_sha256"
KINDS = (
    "Landscape", "Static", "Movable", "Animated", "Particle", "Morph",
    "Unsupported",
)
MODES = ("None", "FrameOnly", "UvOnly", "FrameAndUv")
BOUNDED_KINDS = ("Static", "Movable")
RESULT_KEYS = (
    "result", "source_sha", "expected_build", "scenario", "save_slot",
    "log_sha256", "expected_fault", "device_process_stopped",
    "device_foreground_parked", "durable_zero_scans_per_cycle",
    "durable_zero_required_stable_seconds", "durable_zero_scans_completed",
    "durable_zero_stable", "durable_zero_stable_seconds",
    "durable_zero_final_zero",
)
DEVICE_SPEC_KEYS = (
    "schemaVersion", "saveSlot", "sequence", "kinds", "modes",
    "boundedKinds", "requiredDurableScans", "requiredStableSeconds",
)
SIMULATOR_SPEC_KEYS = (
    "schemaVersion", "fixture", "scope", "generation", "sequence",
    "orderedKinds", "orderedModes", "expectedCells", "expectedTotal",
    "expectedIgnored", "expectedInvalid", "expectedOverflow",
)
SIMULATOR_KINDS = tuple(kind.lower() for kind in KINDS)
SIMULATOR_MODES = ("none", "frame-only", "uv-only", "frame-and-uv")


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def parse_uint64(value: str, label: str, positive: bool = False) -> int:
    pattern = POSITIVE_RE if positive else UINT_RE
    require(pattern.fullmatch(value) is not None,
            f"{label} is not canonical unsigned decimal")
    parsed = int(value, 10)
    require(parsed <= UINT64_MAX, f"{label} exceeds uint64")
    return parsed


def checked_sum(values: Iterable[int], label: str) -> int:
    total = 0
    for value in values:
        require(type(value) is int and 0 <= value <= UINT64_MAX,
                f"{label} contains a non-uint64 value")
        require(total <= UINT64_MAX - value, f"{label} overflows uint64")
        total += value
    return total


def exact_pairs(line: str, prefix: str, fields: Sequence[str]) -> dict[str, str]:
    require("\n" not in line and "\r" not in line,
            "marker is not exactly one LF-delimited line")
    try:
        encoded = line.encode("ascii", errors="strict")
    except UnicodeEncodeError as error:
        raise ValidationError("marker is not ASCII") from error
    require(len(encoded) <= MAX_MARKER_BYTES,
            "marker exceeds the unsplit Tempest Log budget")
    require(line.startswith(prefix + " "), "marker prefix or spacing is malformed")
    tokens = line[len(prefix) + 1:].split(" ")
    require(all(tokens), "marker spacing is noncanonical")
    pairs: list[tuple[str, str]] = []
    for token in tokens:
        require(token.count("=") == 1, "marker token is malformed")
        pairs.append(tuple(token.split("=", 1)))
    require(tuple(key for key, _ in pairs) == tuple(fields),
            "marker fields are missing, extra, duplicated, or reordered")
    return dict(pairs)


def cadence(sequence: int) -> bool:
    return sequence == 1 or (sequence > 0 and sequence % 300 == 0)


def parse_header(line: str) -> dict[str, Any]:
    raw = exact_pairs(line, HEADER_PREFIX, ("v", "b", "g", "s", "r", "t"))
    require(raw["v"] == "1", "additive header schema is not v1")
    require(SHA40_RE.fullmatch(raw["b"]) is not None,
            "additive header build is not exact lowercase SHA-1")
    generation = parse_uint64(raw["g"], "additive generation", positive=True)
    sequence = parse_uint64(raw["s"], "additive sequence", positive=True)
    require(cadence(sequence), "additive sequence is outside 1/300 cadence")
    return {
        "build": raw["b"], "generation": generation, "sequence": sequence,
        "raw": parse_uint64(raw["r"], "raw AdditiveLight"),
        "total": parse_uint64(raw["t"], "additive table total"),
    }


def parse_row(line: str, expected_kind: str) -> tuple[int, int, str, tuple[int, ...]]:
    raw = exact_pairs(line, ROW_PREFIX, ("v", "b", "g", "s", "k", "c"))
    require(raw["v"] == "1", "additive row schema is not v1")
    require(SHA40_RE.fullmatch(raw["b"]) is not None,
            "additive row build is not exact lowercase SHA-1")
    generation = parse_uint64(raw["g"], "additive row generation", positive=True)
    sequence = parse_uint64(raw["s"], "additive row sequence", positive=True)
    require(cadence(sequence), "additive row sequence is outside 1/300 cadence")
    require(raw["k"] == expected_kind, "additive row kind is reordered or unknown")
    parts = raw["c"].split(",")
    require(len(parts) == 4, "additive row mode cardinality is not four")
    cells = tuple(parse_uint64(value, f"{expected_kind} cell") for value in parts)
    return (generation, sequence, raw["b"], cells)


def parse_source_marker(line: str) -> dict[str, Any]:
    raw = exact_pairs(line, SOURCE_PREFIX, ("v", "b", "g", "s", "k", "m", "a", "x", "o"))
    require(raw["v"] == "2", "joined source census is not schema v2")
    require(SHA40_RE.fullmatch(raw["b"]) is not None,
            "source census build is not exact lowercase SHA-1")
    generation = parse_uint64(raw["g"], "source generation", positive=True)
    sequence = parse_uint64(raw["s"], "source sequence", positive=True)
    require(cadence(sequence), "source sequence is outside 1/300 cadence")
    kinds = tuple(parse_uint64(value, "source kind") for value in raw["k"].split(","))
    materials = tuple(parse_uint64(value, "source material") for value in raw["m"].split(","))
    animation = tuple(parse_uint64(value, "source animation") for value in raw["a"].split(","))
    texture_outcomes = tuple(parse_uint64(value, "source texture outcome") for value in raw["x"].split(","))
    outcomes = tuple(parse_uint64(value, "source outcome") for value in raw["o"].split(","))
    require((len(kinds), len(materials), len(animation), len(texture_outcomes), len(outcomes)) ==
            (8, 10, 2, 3, 6), "source census cardinality changed")
    require(kinds[7] == 0 and materials[9] == 0,
            "source census unknown category is not fail-closed")
    visited = outcomes[0]
    require(checked_sum(kinds, "source kind census") == visited,
            "source kind census does not conserve visited")
    require(checked_sum(materials, "source material census") == visited,
            "source material census does not conserve visited")
    require(checked_sum(outcomes[1:5], "source outcomes") == visited,
            "source outcomes do not conserve visited")
    require(checked_sum(texture_outcomes, "source texture outcomes") == outcomes[4],
            "source texture outcomes do not conserve their skip total")
    require(outcomes[5] == 0, "source census has invalid-source != 0")
    return {
        "build": raw["b"], "generation": generation, "sequence": sequence,
        "rawAdditiveLight": materials[7],
    }


def validate_log(log: str, expected_build: str, expected_generation: int,
                 expected_sequence: int) -> dict[str, Any]:
    require(SHA40_RE.fullmatch(expected_build) is not None,
            "expected build must be exact lowercase 40-hex")
    require(type(expected_generation) is int and 0 < expected_generation <= UINT64_MAX,
            "expected generation must be uint64 positive")
    require(type(expected_sequence) is int and 0 < expected_sequence <= UINT64_MAX
            and cadence(expected_sequence),
            "expected sequence must be uint64 positive on 1/300 cadence")
    lines = log.split("\n")
    additive_indices = [
        index for index, line in enumerate(lines)
        if HEADER_PREFIX in line or ROW_PREFIX in line
    ]
    require(additive_indices, "additive source census block is missing")
    consumed: set[int] = set()
    blocks: list[dict[str, Any]] = []
    for index in additive_indices:
        if index in consumed:
            continue
        line = lines[index]
        require(line.startswith(HEADER_PREFIX),
                "additive row is orphaned, interleaved, or has a foreign prefix")
        require(index + 7 < len(lines), "additive block is truncated")
        header = parse_header(line)
        cells: list[int] = []
        for offset, kind in enumerate(KINDS, start=1):
            row_index = index + offset
            require(row_index in additive_indices,
                    "additive block is missing, reordered, or interleaved")
            generation, sequence, build, row_cells = parse_row(lines[row_index], kind)
            require((build, generation, sequence) ==
                    (header["build"], header["generation"], header["sequence"]),
                    "additive row identity differs from its header")
            cells.extend(row_cells)
            consumed.add(row_index)
        consumed.add(index)
        total = checked_sum(cells, "additive cells")
        require(total == header["total"] == header["raw"],
                "additive header/table conservation failed")
        blocks.append({**header, "cells": tuple(cells)})
    require(consumed == set(additive_indices),
            "additive prefix line was not consumed by one exact block")
    targets = [
        block for block in blocks
        if (block["build"], block["generation"], block["sequence"]) ==
        (expected_build, expected_generation, expected_sequence)
    ]
    require(len(targets) == 1,
            f"expected exactly one additive block for b/g/s, found {len(targets)}")
    # No foreign build is admissible, even if it is on another cadence.
    require(all(block["build"] == expected_build for block in blocks),
            "additive log contains a foreign-build block")
    source_lines = [line for line in lines if SOURCE_PREFIX in line]
    require(source_lines, "source census v2 marker is missing")
    sources = [parse_source_marker(line) for line in source_lines]
    joined_sources = [
        source for source in sources
        if (source["build"], source["generation"], source["sequence"]) ==
        (expected_build, expected_generation, expected_sequence)
    ]
    require(len(joined_sources) == 1,
            f"expected exactly one source census v2 marker for b/g/s, found {len(joined_sources)}")
    target = targets[0]
    require(joined_sources[0]["rawAdditiveLight"] == target["raw"],
            "source census raw AdditiveLight does not join additive table")
    return target


def artifact_bytes(block: dict[str, Any]) -> bytes:
    cells = block["cells"]
    require(type(cells) is tuple and len(cells) == 28,
            "artifact source does not have 28 cells")
    build = bytes.fromhex(block["build"])
    data = bytearray(ARTIFACT_BYTES)
    data[:8] = MAGIC
    struct.pack_into("<HHI", data, 8, 1, 64, 1)
    data[16:36] = build
    struct.pack_into("<III", data, 36, 7, 4, 8)
    struct.pack_into("<QQ", data, 48, block["generation"], block["sequence"])
    for index, value in enumerate(cells):
        struct.pack_into("<Q", data, 64 + index * 8, value)
    struct.pack_into("<QQ", data, 288, block["raw"], block["total"])
    return bytes(data)


def parse_artifact(data: bytes, expected_build: str | None = None) -> dict[str, Any]:
    require(len(data) == ARTIFACT_BYTES,
            "artifact is truncated or has trailing bytes")
    require(data[:8] == MAGIC, "artifact magic is not exact")
    schema, header_bytes, producer = struct.unpack_from("<HHI", data, 8)
    require((schema, header_bytes, producer) == (1, 64, 1),
            "artifact schema/header/producer tuple is not v1")
    build = data[16:36].hex()
    require(SHA40_RE.fullmatch(build) is not None and any(data[16:36]),
            "artifact build SHA is invalid or zero")
    kind_count, mode_count, counter_bytes = struct.unpack_from("<III", data, 36)
    require((kind_count, mode_count, counter_bytes) == (7, 4, 8),
            "artifact dimensions/counter width changed")
    generation, sequence = struct.unpack_from("<QQ", data, 48)
    require(generation > 0 and sequence > 0 and cadence(sequence),
            "artifact generation/sequence identity is invalid")
    require(data[60:64] == b"\0" * 4,
            "artifact reserved header word is nonzero")
    cells = struct.unpack_from("<28Q", data, 64)
    raw, total = struct.unpack_from("<QQ", data, 288)
    summed = checked_sum(cells, "artifact cells")
    require(summed == total == raw, "artifact cell/raw/total conservation failed")
    if expected_build is not None:
        require(build == expected_build, "artifact build differs from expected SHA")
    return {
        "build": build, "generation": generation, "sequence": sequence,
        "cells": tuple(cells), "raw": raw, "total": total,
    }


def regular_bytes(path: pathlib.Path, label: str, maximum: int) -> bytes:
    require(type(maximum) is int and maximum >= 0,
            f"{label} has an invalid byte bound")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode), f"{label} is not a regular file")
        require(0 <= before.st_size <= maximum, f"{label} exceeds its byte bound")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining > 0:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            require(chunk != b"", f"{label} was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        require(os.read(descriptor, 1) == b"", f"{label} grew while reading")
        after = os.fstat(descriptor)
        identity = lambda status: (
            status.st_dev, status.st_ino, stat.S_IFMT(status.st_mode),
            status.st_size, status.st_mtime_ns, status.st_ctime_ns,
        )
        require(identity(before) == identity(after),
                f"{label} metadata changed while reading")
        path_status = os.stat(path, follow_symlinks=False)
        require(stat.S_ISREG(path_status.st_mode)
                and identity(after) == identity(path_status),
                f"{label} path identity changed while reading")
        data = b"".join(chunks)
        require(len(data) == before.st_size, f"{label} byte count changed while reading")
        return data
    finally:
        os.close(descriptor)


def write_no_clobber(path: pathlib.Path, data: bytes) -> None:
    require(path.is_absolute(), "output path must be absolute")
    require(path.name in (ARTIFACT_NAME, ATTESTATION_NAME),
            "output has a noncanonical flat name")
    path.parent.mkdir(parents=True, exist_ok=True)
    directory_flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                       | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    directory = os.open(path.parent, directory_flags)
    temporary = f".{path.name}.tmp.{os.getpid()}.{secrets.token_hex(8)}"
    descriptor = -1
    published = False
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory,
        )
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            descriptor = -1
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        temporary_status = os.stat(temporary, dir_fd=directory, follow_symlinks=False)
        require(stat.S_ISREG(temporary_status.st_mode)
                and temporary_status.st_size == len(data),
                "atomic publication temp is not the complete regular file")
        try:
            os.link(temporary, path.name, src_dir_fd=directory, dst_dir_fd=directory,
                    follow_symlinks=False)
            published = True
        except BaseException:
            # link(2) may have committed the directory entry before surfacing
            # an interruption. Accept that ambiguous outcome only when final
            # is the exact same inode as our complete temp. A pre-existing or
            # concurrently published foreign final is never removed/accepted.
            try:
                final_status = os.stat(path.name, dir_fd=directory,
                                       follow_symlinks=False)
            except OSError:
                raise
            if (stat.S_ISREG(final_status.st_mode)
                    and final_status.st_dev == temporary_status.st_dev
                    and final_status.st_ino == temporary_status.st_ino
                    and final_status.st_size == temporary_status.st_size):
                published = True
            else:
                raise
        os.unlink(temporary, dir_fd=directory)
        os.fsync(directory)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=directory)
        except OSError:
            pass
        # A failure after the exclusive link may leave a correct, complete
        # final file. Never remove that committed publication during cleanup.
        if published:
            os.fsync(directory)
        os.close(directory)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"JSON key is duplicated: {key}")
        result[key] = value
    return result


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False) + "\n").encode("utf-8")


def load_json(path: pathlib.Path, label: str, canonical: bool = False) -> tuple[Any, bytes]:
    raw = regular_bytes(path, label, 1024 * 1024)
    try:
        value = json.loads(raw.decode("utf-8", errors="strict"),
                           object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"{label} is not strict UTF-8 JSON: {error}") from error
    if canonical:
        require(raw == canonical_json(value), f"{label} JSON is not canonical")
    return value, raw


def exact_keys(value: Any, keys: Sequence[str], label: str) -> dict[str, Any]:
    require(type(value) is dict, f"{label} is not an object")
    require(set(value) == set(keys), f"{label} keys are missing or unknown")
    return value


def validate_device_spec(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    value, raw = load_json(path, "device spec")
    spec = exact_keys(value, DEVICE_SPEC_KEYS, "device spec")
    require(type(spec["schemaVersion"]) is int and spec["schemaVersion"] == 1,
            "device spec schemaVersion is not integer 1")
    require(type(spec["saveSlot"]) is int and spec["saveSlot"] == 4,
            "device spec saveSlot is not integer 4")
    require(type(spec["sequence"]) is int and spec["sequence"] == 1,
            "device spec sequence is not integer 1")
    require(spec["kinds"] == list(KINDS), "device spec kinds/order changed")
    require(spec["modes"] == list(MODES), "device spec modes/order changed")
    require(spec["boundedKinds"] == list(BOUNDED_KINDS),
            "device spec boundedKinds/order changed")
    require(type(spec["requiredDurableScans"]) is int
            and spec["requiredDurableScans"] == 10,
            "device spec requiredDurableScans is not integer 10")
    require(type(spec["requiredStableSeconds"]) is int
            and spec["requiredStableSeconds"] == 90,
            "device spec requiredStableSeconds is not integer 90")
    return spec, raw


def validate_mode_spec(path: pathlib.Path, mode: str) -> bytes:
    value, raw = load_json(path, f"{mode} spec")
    if mode == "simulator":
        spec = exact_keys(value, SIMULATOR_SPEC_KEYS, "simulator spec")
        require(type(spec["schemaVersion"]) is int and spec["schemaVersion"] == 1,
                "simulator spec schemaVersion is not integer 1")
        require(spec["fixture"] == "p21e1a-additive-census-v1.json",
                "simulator spec fixture is not exact")
        require(spec["scope"] == "host-neutral-adapter,no-product-save-runtime",
                "simulator spec scope is not exact")
        require(type(spec["generation"]) is int and spec["generation"] == 1
                and type(spec["sequence"]) is int and spec["sequence"] == 1,
                "simulator spec identity is not exact generation/sequence 1/1")
        require(spec["orderedKinds"] == list(SIMULATOR_KINDS),
                "simulator spec kind order changed")
        require(spec["orderedModes"] == list(SIMULATOR_MODES),
                "simulator spec mode order changed")
        require(type(spec["expectedCells"]) is list
                and len(spec["expectedCells"]) == 28
                and all(type(value) is int and value == 1
                        for value in spec["expectedCells"]),
                "simulator spec expectedCells is not exact 28 ones")
        for key, expected in (("expectedTotal", 28), ("expectedIgnored", 2),
                              ("expectedInvalid", 3), ("expectedOverflow", 2)):
            require(type(spec[key]) is int and spec[key] == expected,
                    f"simulator spec {key} is not integer {expected}")
    elif set(value) == set(DEVICE_SPEC_KEYS):
        validate_device_spec(path)
    else:
        raise ValidationError(f"{mode} spec schema is unknown")
    return raw


def parse_result(path: pathlib.Path, spec: dict[str, Any], expected_sha: str,
                 log_sha256: str) -> tuple[dict[str, str], bytes]:
    raw = regular_bytes(path, "smoke result", 64 * 1024)
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeError as error:
        raise ValidationError("smoke result is not UTF-8") from error
    values: dict[str, str] = {}
    for line in text.splitlines():
        if line == "":
            continue
        require(line.count("=") == 1, "smoke result line is malformed")
        key, value = line.split("=", 1)
        require(RESULT_KEY_RE.fullmatch(key) is not None,
                f"smoke result key is noncanonical: {key}")
        require(key not in values, f"smoke result key is duplicated: {key}")
        require(value != "" and value.strip() == value
                and all(character >= " " and character != "\x7f" for character in value),
                f"smoke result value is noncanonical: {key}")
        values[key] = value
    require(set(RESULT_KEYS).issubset(values),
            "smoke result is missing one or more required 15 keys")
    require(SIGNED_EXECUTABLE_KEY in values,
            "smoke result is missing signed executable SHA-256")
    require(SHA64_RE.fullmatch(values[SIGNED_EXECUTABLE_KEY]) is not None,
            "smoke signed executable SHA-256 is not canonical lowercase h64")
    require(values["result"] == "PASS", "smoke result is not PASS")
    require(values["source_sha"] == expected_sha
            and values["expected_build"] == expected_sha,
            "smoke source/build does not equal expected SHA")
    require(values["scenario"] == "save" and values["save_slot"] == "4",
            "smoke scenario is not exact save4")
    require(values["log_sha256"] == log_sha256,
            "smoke log hash does not match log.txt")
    require(values["expected_fault"] == "none",
            "smoke expected_fault is not none")
    for key in ("device_process_stopped", "device_foreground_parked",
                "durable_zero_stable", "durable_zero_final_zero"):
        require(values[key] == "1", f"smoke {key} is not canonical true")
    require(parse_uint64(values["durable_zero_scans_per_cycle"],
                         "smoke scans per cycle") == spec["requiredDurableScans"],
            "smoke scans per cycle differs from spec")
    require(parse_uint64(values["durable_zero_required_stable_seconds"],
                         "smoke required stable seconds") == spec["requiredStableSeconds"],
            "smoke required stable seconds differs from spec")
    require(parse_uint64(values["durable_zero_scans_completed"],
                         "smoke completed scans") >= spec["requiredDurableScans"],
            "smoke completed scans is below spec")
    require(parse_uint64(values["durable_zero_stable_seconds"],
                         "smoke stable seconds") >= spec["requiredStableSeconds"],
            "smoke stable seconds is below spec")
    return values, raw


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized_smoke(values: dict[str, str], result_raw: bytes,
                     evidence_dir: pathlib.Path, log_sha: str) -> dict[str, Any]:
    try:
        path_bytes = str(evidence_dir).encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise ValidationError("evidence path is not strict UTF-8") from error
    return {
        "result": "PASS", "sourceSha": values["source_sha"],
        "buildSha": values["expected_build"], "scenario": "save", "saveSlot": 4,
        "expectedFault": "none", "logSha256": log_sha,
        "deviceProcessStopped": True, "deviceForegroundParked": True,
        "durableZeroStable": True, "durableZeroFinalZero": True,
        "requiredScans": int(values["durable_zero_scans_per_cycle"]),
        "completedScans": int(values["durable_zero_scans_completed"]),
        "requiredStableSeconds": int(values["durable_zero_required_stable_seconds"]),
        "stableSeconds": int(values["durable_zero_stable_seconds"]),
        "evidencePath": str(evidence_dir), "evidencePathSha256": sha256(path_bytes),
        "resultFile": "result.txt", "resultBytes": len(result_raw),
        "resultSha256": sha256(result_raw),
    }


def validate_macho_container(raw: bytes) -> None:
    require(len(raw) >= 4, "Mach-O is shorter than its magic")
    magic = raw[:4]
    thin = {
        b"\xfe\xed\xfa\xce": (">", 28),
        b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xfe\xed\xfa\xcf": (">", 32),
        b"\xcf\xfa\xed\xfe": ("<", 32),
    }
    fat = {
        b"\xca\xfe\xba\xbe": (">", 20),
        b"\xbe\xba\xfe\xca": ("<", 20),
        b"\xca\xfe\xba\xbf": (">", 32),
        b"\xbf\xba\xfe\xca": ("<", 32),
    }
    if magic in thin:
        endian, header_bytes = thin[magic]
        require(len(raw) >= header_bytes, "thin Mach-O header is truncated")
        cpu_type = struct.unpack_from(endian + "i", raw, 4)[0]
        file_type = struct.unpack_from(endian + "I", raw, 12)[0]
        require(cpu_type != 0 and file_type == 2,
                "thin Mach-O is not a typed executable")
        ncmds, command_bytes = struct.unpack_from(endian + "II", raw, 16)
        require(0 < ncmds <= 65535, "thin Mach-O load-command count is invalid")
        require(command_bytes >= ncmds * 8
                and header_bytes + command_bytes <= len(raw),
                "thin Mach-O load commands are truncated or malformed")
        command_offset = header_bytes
        command_end = header_bytes + command_bytes
        for _ in range(ncmds):
            require(command_offset <= command_end - 8,
                    "thin Mach-O load-command header is truncated")
            command_size = struct.unpack_from(endian + "I", raw,
                                              command_offset + 4)[0]
            require(command_size >= 8 and command_size % 4 == 0
                    and command_offset <= command_end - command_size,
                    "thin Mach-O load-command size is invalid")
            command_offset += command_size
        require(command_offset == command_end,
                "thin Mach-O load-command sizes do not conserve sizeofcmds")
        return
    if magic in fat:
        endian, entry_bytes = fat[magic]
        require(len(raw) >= 8, "fat Mach-O header is truncated")
        architectures = struct.unpack_from(endian + "I", raw, 4)[0]
        require(0 < architectures <= 64, "fat Mach-O architecture count is invalid")
        table_bytes = 8 + architectures * entry_bytes
        require(table_bytes <= len(raw), "fat Mach-O architecture table is truncated")
        for index in range(architectures):
            base = 8 + index * entry_bytes
            if entry_bytes == 20:
                offset, size = struct.unpack_from(endian + "II", raw, base + 8)
            else:
                offset, size = struct.unpack_from(endian + "QQ", raw, base + 8)
            require(size > 0 and offset >= table_bytes and offset <= len(raw) - size,
                    "fat Mach-O architecture range is invalid")
            validate_macho_container(raw[offset:offset + size])
        return
    raise ValidationError("executable does not have a supported thin/fat Mach-O magic")


def require_macho_identity(path: pathlib.Path, expected_sha: str,
                           expected_hash: str) -> None:
    raw = regular_bytes(path, "Mach-O", 1024 * 1024 * 1024)
    require(SHA64_RE.fullmatch(expected_hash) is not None,
            "expected Mach-O hash is not canonical lowercase h64")
    require(sha256(raw) == expected_hash,
            "Mach-O SHA-256 differs from the original smoke result claim")
    validate_macho_container(raw)
    require(raw.count(expected_sha.encode("ascii")) == 1,
            "Mach-O does not contain exactly one exact expected SHA marker")
    require(raw.count(HEADER_PREFIX.encode("ascii")) == 1
            and raw.count(ROW_PREFIX.encode("ascii")) == 1,
            "Mach-O additive census marker literals are missing or duplicated")


def artifact_join(path: pathlib.Path, block: dict[str, Any], expected_sha: str) -> tuple[dict[str, Any], bytes]:
    raw = regular_bytes(path, "additive artifact", ARTIFACT_BYTES)
    require(len(raw) == ARTIFACT_BYTES, "additive artifact size is not exact 304 B")
    parsed = parse_artifact(raw, expected_sha)
    for key in ("build", "generation", "sequence", "cells", "raw", "total"):
        require(parsed[key] == block[key], f"artifact/log {key} join mismatch")
    return parsed, raw


def _build_attestation_snapshot(
    evidence_dir: pathlib.Path,
    spec_path: pathlib.Path,
    artifact_path: pathlib.Path,
    macho_path: pathlib.Path,
    expected_sha: str,
) -> tuple[dict[str, Any], bytes, dict[str, Any]]:
    require(evidence_dir.is_absolute() and evidence_dir == evidence_dir.resolve(),
            "evidence path must be canonical absolute")
    require(artifact_path.parent == evidence_dir and artifact_path.name == ARTIFACT_NAME,
            "artifact must have its canonical name inside evidence path")
    require(SHA40_RE.fullmatch(expected_sha) is not None,
            "expected SHA is not exact lowercase 40-hex")
    spec, spec_raw = validate_device_spec(spec_path)
    log_path = evidence_dir / "log.txt"
    result_path = evidence_dir / "result.txt"
    log_raw = regular_bytes(log_path, "source log", MAX_LOG_BYTES)
    try:
        log = log_raw.decode("utf-8", errors="strict")
    except UnicodeError as error:
        raise ValidationError("source log is not UTF-8") from error
    artifact_raw = regular_bytes(artifact_path, "additive artifact", ARTIFACT_BYTES)
    require(len(artifact_raw) == ARTIFACT_BYTES,
            "additive artifact size is not exact 304 B")
    artifact = parse_artifact(artifact_raw, expected_sha)
    require(artifact["sequence"] == spec["sequence"],
            "artifact sequence differs from device spec")
    block = validate_log(log, expected_sha, artifact["generation"], spec["sequence"])
    for key in ("build", "generation", "sequence", "cells", "raw", "total"):
        require(artifact[key] == block[key], f"artifact/log {key} join mismatch")
    result, result_raw = parse_result(result_path, spec, expected_sha, sha256(log_raw))
    require_macho_identity(macho_path, expected_sha,
                           result[SIGNED_EXECUTABLE_KEY])
    smoke = normalized_smoke(result, result_raw, evidence_dir, sha256(log_raw))
    document = {
        "schemaVersion": 1,
        "evidenceClass": "device-additive-source-census",
        "saveSlot": 4,
        "specSha256": sha256(spec_raw),
        "sourceLog": {"file": "log.txt", "bytes": len(log_raw),
                      "sha256": sha256(log_raw)},
        "smoke": smoke,
        "sourceSha": expected_sha,
        "buildSha": artifact["build"],
        "targetGeneration": artifact["generation"],
        "snapshotSequence": artifact["sequence"],
        "artifact": {"file": ARTIFACT_NAME, "bytes": ARTIFACT_BYTES,
                     "sha256": sha256(artifact_raw)},
    }
    return document, canonical_json(document), artifact


def build_attestation(evidence_dir: pathlib.Path, spec_path: pathlib.Path,
                      artifact_path: pathlib.Path, macho_path: pathlib.Path,
                      expected_sha: str) -> tuple[dict[str, Any], bytes]:
    document, raw, _ = _build_attestation_snapshot(
        evidence_dir, spec_path, artifact_path, macho_path, expected_sha,
    )
    return document, raw


def validate_attestation(path: pathlib.Path, spec_path: pathlib.Path,
                         macho_path: pathlib.Path, expected_sha: str) -> dict[str, Any]:
    document, raw = load_json(path, "device attestation", canonical=True)
    require(path.name == ATTESTATION_NAME,
            "device attestation has a noncanonical flat name")
    root = exact_keys(document, (
        "schemaVersion", "evidenceClass", "saveSlot", "specSha256", "sourceLog",
        "smoke", "sourceSha", "buildSha", "targetGeneration",
        "snapshotSequence", "artifact",
    ), "device attestation")
    require(root["schemaVersion"] == 1 and type(root["schemaVersion"]) is int,
            "attestation schema is not integer 1")
    require(root["evidenceClass"] == "device-additive-source-census",
            "synthetic/simulator evidence class cannot attest a device")
    require(root["saveSlot"] == 4 and type(root["saveSlot"]) is int,
            "attestation saveSlot is not integer 4")
    require(root["sourceSha"] == expected_sha and root["buildSha"] == expected_sha,
            "attestation source/build differs from expected SHA")
    require(type(root["targetGeneration"]) is int and root["targetGeneration"] > 0
            and type(root["snapshotSequence"]) is int
            and root["snapshotSequence"] == 1,
            "attestation generation/sequence is noncanonical")
    smoke = exact_keys(root["smoke"], (
        "result", "sourceSha", "buildSha", "scenario", "saveSlot",
        "expectedFault", "logSha256", "deviceProcessStopped",
        "deviceForegroundParked", "durableZeroStable", "durableZeroFinalZero",
        "requiredScans", "completedScans", "requiredStableSeconds",
        "stableSeconds", "evidencePath", "evidencePathSha256", "resultFile",
        "resultBytes", "resultSha256",
    ), "attestation smoke")
    evidence_dir = pathlib.Path(smoke["evidencePath"])
    require(evidence_dir.is_absolute() and evidence_dir == evidence_dir.resolve(),
            "attestation evidencePath is not canonical absolute")
    require(path.parent == evidence_dir,
            "attestation is not beside its artifact/evidence")
    artifact_meta = exact_keys(root["artifact"], ("file", "bytes", "sha256"),
                               "attestation artifact")
    source_meta = exact_keys(root["sourceLog"], ("file", "bytes", "sha256"),
                             "attestation sourceLog")
    require(artifact_meta["file"] == ARTIFACT_NAME
            and artifact_meta["bytes"] == ARTIFACT_BYTES
            and source_meta["file"] == "log.txt"
            and smoke["resultFile"] == "result.txt",
            "attestation file identities are noncanonical")
    rebuilt, rebuilt_raw, authenticated_artifact = _build_attestation_snapshot(
        evidence_dir, spec_path, evidence_dir / ARTIFACT_NAME, macho_path,
        expected_sha,
    )
    require(raw == rebuilt_raw and root == rebuilt,
            "attestation claims or rehashed evidence differ from canonical rebuild")
    # All semantic decisions use the same immutable bytes parsed above and
    # hashed into rebuilt.artifact.sha256. Never reopen the artifact here.
    cells = authenticated_artifact["cells"]
    bounded_cells = cells[4:12]
    bounded = checked_sum(bounded_cells, "bounded Static+Movable cohort")
    bounded_modes = {
        mode: checked_sum((cells[4 + index], cells[8 + index]),
                          f"bounded {mode} cohort")
        for index, mode in enumerate(MODES)
    }
    nonzero_modes = [mode for mode in MODES if bounded_modes[mode] > 0]
    return {
        "bounded": bounded, "boundedModes": bounded_modes,
        "nonzeroBoundedModes": nonzero_modes,
        "decision": "GO" if bounded > 0 else "NO-GO",
    }


def run_artifact_mode(arguments: argparse.Namespace, mode: str) -> dict[str, Any]:
    validate_mode_spec(arguments.spec, mode)
    spec_value, _ = load_json(arguments.spec, f"{mode} spec")
    raw = regular_bytes(arguments.log, "runtime log", MAX_LOG_BYTES)
    try:
        log = raw.decode("utf-8", errors="strict")
    except UnicodeError as error:
        raise ValidationError("runtime log is not UTF-8") from error
    block = validate_log(log, arguments.expected_build,
                         arguments.expected_generation, arguments.expected_sequence)
    if mode == "simulator":
        require(arguments.expected_generation == spec_value["generation"]
                and arguments.expected_sequence == spec_value["sequence"],
                "simulator CLI identity differs from strict spec")
        require(list(block["cells"]) == spec_value["expectedCells"]
                and block["total"] == spec_value["expectedTotal"],
                "simulator artifact census differs from strict spec")
    expected = artifact_bytes(block)
    if arguments.write:
        write_no_clobber(arguments.artifact, expected)
    actual = regular_bytes(arguments.artifact, "additive artifact", ARTIFACT_BYTES)
    require(actual == expected, "artifact bytes differ from canonical log derivative")
    parsed = parse_artifact(actual, arguments.expected_build)
    return {
        "status": "ARTIFACT PASS",
        "scope": mode,
        "deviceDecision": "NOT EVALUATED",
        "evidenceClass": f"{mode}-additive-source-census",
        "artifactBytes": len(actual), "artifactSha256": sha256(actual),
        "buildSha": parsed["build"], "targetGeneration": parsed["generation"],
        "snapshotSequence": parsed["sequence"], "tableTotal": parsed["total"],
    }


def fixture_log(build: str, cells: Sequence[int], generation: int = 7,
                sequence: int = 1) -> str:
    total = checked_sum(cells, "fixture cells")
    source = (
        f"{SOURCE_PREFIX} v=2 b={build} g={generation} s={sequence} "
        f"k={total},0,0,0,0,0,0,0 m=0,0,0,0,0,0,0,{total},0,0 "
        f"a=0,0 x=0,0,0 o={total},0,0,{total},0,0"
    )
    header = (f"{HEADER_PREFIX} v=1 b={build} g={generation} s={sequence} "
              f"r={total} t={total}")
    rows = [
        f"{ROW_PREFIX} v=1 b={build} g={generation} s={sequence} k={kind} "
        f"c={','.join(str(value) for value in cells[index * 4:index * 4 + 4])}"
        for index, kind in enumerate(KINDS)
    ]
    return "ordinary\n" + source + "\n" + header + "\n" + "\n".join(rows) + "\ntail\n"


def expect_invalid(action: Any, label: str) -> int:
    try:
        action()
    except (OSError, UnicodeError, ValidationError, struct.error, ValueError):
        return 1
    raise ValidationError(f"self-test mutation survived: {label}")


def self_test() -> int:
    build = "0123456789abcdef0123456789abcdef01234567"
    cells = tuple(range(1, 29))
    log = fixture_log(build, cells)
    block = validate_log(log, build, 7, 1)
    canonical = artifact_bytes(block)
    require(len(canonical) == ARTIFACT_BYTES, "self-test artifact size drifted")
    require(parse_artifact(canonical, build)["cells"] == cells,
            "self-test artifact round-trip failed")
    mutations: dict[str, Any] = {
        "missing-row": lambda: validate_log(log.replace(log.splitlines()[5] + "\n", "", 1), build, 7, 1),
        "duplicate-block": lambda: validate_log(log + "\n".join(log.splitlines()[2:10]) + "\n", build, 7, 1),
        "interleaved": lambda: validate_log(
            log.replace(log.splitlines()[4] + "\n",
                        log.splitlines()[4] + "\nnoise\n", 1), build, 7, 1),
        "foreign": lambda: validate_log(log.replace(build, "f" * 40, 1), build, 7, 1),
        "overflow-log": lambda: validate_log(log.replace("c=1,2,3,4", f"c={UINT64_MAX},2,3,4", 1), build, 7, 1),
        "raw-drift": lambda: validate_log(log.replace("r=406", "r=405", 1), build, 7, 1),
        "truncate-artifact": lambda: parse_artifact(canonical[:-1], build),
        "trailing-artifact": lambda: parse_artifact(canonical + b"\0", build),
        "endian-artifact": lambda: parse_artifact(canonical[:8] + canonical[8:16][::-1] + canonical[16:], build),
        "reserved-artifact": lambda: parse_artifact(
            canonical[:60] + b"\x01\0\0\0" + canonical[64:], build
        ),
        "rehash-artifact": lambda: parse_artifact(canonical[:64] + b"\xff" * 8 + canonical[72:], build),
    }
    killed = sum(expect_invalid(action, label) for label, action in mutations.items())
    with tempfile.TemporaryDirectory(prefix="rios-additive-validator-") as name:
        root = pathlib.Path(name).resolve()
        evidence = root / "device-evidence"
        evidence.mkdir()
        artifact = evidence / ARTIFACT_NAME
        write_no_clobber(artifact, canonical)
        killed += expect_invalid(
            lambda: write_no_clobber(artifact, canonical), "artifact-clobber"
        )
        require(artifact.read_bytes() == canonical,
                "no-clobber collision changed the published artifact")
        require(not list(evidence.glob(f".{ARTIFACT_NAME}.tmp.*")),
                "no-clobber collision leaked its same-directory temp")

        symlink_target = root / "regular-target.bin"
        symlink_target.write_bytes(b"regular")
        symlink_path = root / "symlink.bin"
        symlink_path.symlink_to(symlink_target)
        killed += expect_invalid(
            lambda: regular_bytes(symlink_path, "symlink mutation", 64),
            "no-follow-symlink",
        )

        raced_path = root / "raced.bin"
        raced_path.write_bytes(b"before-race")
        original_os_read = os.read
        race_fired = False

        def racing_read(descriptor: int, count: int) -> bytes:
            nonlocal race_fired
            data = original_os_read(descriptor, count)
            if not race_fired:
                race_fired = True
                raced_path.write_bytes(b"after--race")
            return data

        os.read = racing_read
        try:
            killed += expect_invalid(
                lambda: regular_bytes(raced_path, "read race mutation", 64),
                "single-fd-stability-race",
            )
        finally:
            os.read = original_os_read
        require(race_fired, "read race mutation hook did not execute")

        interrupted_output = evidence / ATTESTATION_NAME
        original_link = os.link

        def interrupted_link(*arguments: Any, **keywords: Any) -> None:
            del arguments, keywords
            raise InterruptedError("self-test publication interruption")

        os.link = interrupted_link
        try:
            killed += expect_invalid(
                lambda: write_no_clobber(interrupted_output, b"not-published"),
                "atomic-publication-interruption",
            )
        finally:
            os.link = original_link
        require(not interrupted_output.exists(),
                "interrupted publication exposed a final file")
        require(not list(evidence.glob(f".{ATTESTATION_NAME}.tmp.*")),
                "interrupted publication leaked its same-directory temp")

        directory_fsyncs = 0
        original_fsync = os.fsync

        def counting_fsync(descriptor: int) -> None:
            nonlocal directory_fsyncs
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                directory_fsyncs += 1
            original_fsync(descriptor)

        def linked_then_interrupted(*arguments: Any, **keywords: Any) -> None:
            original_link(*arguments, **keywords)
            raise InterruptedError("self-test post-link interruption")

        os.link = linked_then_interrupted
        os.fsync = counting_fsync
        try:
            write_no_clobber(interrupted_output, b"complete-publication")
        finally:
            os.link = original_link
            os.fsync = original_fsync
        require(interrupted_output.read_bytes() == b"complete-publication",
                "post-link interruption did not preserve the complete final inode")
        require(directory_fsyncs >= 1,
                "post-link interruption did not fsync the committed directory")
        require(not list(evidence.glob(f".{ATTESTATION_NAME}.tmp.*")),
                "post-link interruption leaked its same-directory temp")
        interrupted_output.unlink()

        spec_path = root / "device-spec.json"
        spec_value = {
            "schemaVersion": 1, "saveSlot": 4, "sequence": 1,
            "kinds": list(KINDS), "modes": list(MODES),
            "boundedKinds": list(BOUNDED_KINDS), "requiredDurableScans": 10,
            "requiredStableSeconds": 90,
        }
        spec_path.write_bytes(canonical_json(spec_value))
        log_path = evidence / "log.txt"
        log_path.write_text(log, encoding="utf-8")
        macho = root / "Gothic2Notr"
        macho_header = (
            b"\xcf\xfa\xed\xfe"
            + struct.pack("<iiIIIII", 0x0100000c, 0, 2, 1, 8, 0, 0)
            + struct.pack("<II", 1, 8)
        )
        macho_bytes = (macho_header + build.encode("ascii") + b"\0" +
                       HEADER_PREFIX.encode("ascii") + b"\0" +
                       ROW_PREFIX.encode("ascii") + b"\0")
        macho.write_bytes(macho_bytes)
        result_path = evidence / "result.txt"
        result_values = {
            "result": "PASS", "source_sha": build, "expected_build": build,
            "scenario": "save", "save_slot": "4",
            "log_sha256": sha256(log_path.read_bytes()), "expected_fault": "none",
            "device_process_stopped": "1", "device_foreground_parked": "1",
            "durable_zero_scans_per_cycle": "10",
            "durable_zero_required_stable_seconds": "90",
            "durable_zero_scans_completed": "10", "durable_zero_stable": "1",
            "durable_zero_stable_seconds": "90", "durable_zero_final_zero": "1",
        }
        result_text = (
            f"{SIGNED_EXECUTABLE_KEY}={sha256(macho_bytes)}\n"
            + "bundle_id=opengothic.gothic2.test\n"
            + "".join(f"{key}={result_values[key]}\n" for key in RESULT_KEYS)
            + "durable_zero_interval_seconds=10\n"
        )
        result_path.write_text(result_text, encoding="utf-8")
        document, attestation_raw = build_attestation(
            evidence, spec_path, artifact, macho, build,
        )
        require(document["evidenceClass"] == "device-additive-source-census",
                "self-test attestation class drifted")
        attestation = evidence / ATTESTATION_NAME
        attestation.write_bytes(attestation_raw)
        require(validate_attestation(attestation, spec_path, macho, build)["bounded"] > 0,
                "self-test device attestation did not produce bounded GO")

        original_result = result_path.read_bytes()
        original_artifact = artifact.read_bytes()
        original_spec = spec_path.read_bytes()
        original_macho = macho.read_bytes()
        original_attestation = attestation.read_bytes()

        def mutate_file(path: pathlib.Path, data: bytes, action: Any) -> int:
            path.write_bytes(data)
            try:
                return expect_invalid(action, f"mutated-{path.name}")
            finally:
                if path == result_path:
                    path.write_bytes(original_result)
                elif path == artifact:
                    path.write_bytes(original_artifact)
                elif path == spec_path:
                    path.write_bytes(original_spec)
                elif path == macho:
                    path.write_bytes(original_macho)
                elif path == attestation:
                    path.write_bytes(original_attestation)

        def result_claiming(executable: bytes) -> bytes:
            old = f"{SIGNED_EXECUTABLE_KEY}={sha256(original_macho)}".encode("ascii")
            new = f"{SIGNED_EXECUTABLE_KEY}={sha256(executable)}".encode("ascii")
            require(original_result.count(old) == 1,
                    "self-test executable hash claim anchor is not unique")
            return original_result.replace(old, new, 1)

        def mutate_macho_with_matching_claim(executable: bytes, label: str) -> int:
            macho.write_bytes(executable)
            result_path.write_bytes(result_claiming(executable))
            try:
                return expect_invalid(rebuild, label)
            finally:
                macho.write_bytes(original_macho)
                result_path.write_bytes(original_result)

        rebuild = lambda: build_attestation(evidence, spec_path, artifact, macho, build)
        killed += mutate_file(result_path, original_result + b"result=PASS\n", rebuild)
        killed += mutate_file(
            result_path, original_result + b"durable_zero_interval_seconds=10\n",
            rebuild,
        )
        killed += mutate_file(result_path, original_result + b"malformed-extra\n",
                              rebuild)
        killed += mutate_file(result_path,
                              original_result.replace(b"result=PASS", b"result=FAIL"),
                              rebuild)
        killed += mutate_file(result_path,
                              original_result.replace(b"save_slot=4", b"save_slot=04"),
                              rebuild)
        killed += mutate_file(
            result_path,
            original_result.replace(b"durable_zero_stable_seconds=90",
                                    b"durable_zero_stable_seconds=89"),
            rebuild,
        )
        reordered = bytearray(original_artifact)
        reordered[64:72], reordered[72:80] = reordered[72:80], reordered[64:72]
        killed += mutate_file(artifact, bytes(reordered), rebuild)
        mutated_spec = json.loads(original_spec)
        mutated_spec["requiredDurableScans"] = True
        killed += mutate_file(spec_path, canonical_json(mutated_spec), rebuild)
        killed += mutate_file(
            result_path,
            original_result.replace(sha256(original_macho).encode("ascii"), b"0" * 64, 1),
            rebuild,
        )
        fake_blob = (b"MACHO\0" + build.encode("ascii") + b"\0" +
                     HEADER_PREFIX.encode("ascii") + b"\0" +
                     ROW_PREFIX.encode("ascii") + b"\0")
        killed += mutate_macho_with_matching_claim(fake_blob, "fake-Mach-O-blob")
        malformed_magic = b"\0\0\0\0" + original_macho[4:]
        killed += mutate_macho_with_matching_claim(
            malformed_magic, "malformed-Mach-O-magic"
        )
        truncated_thin = b"\xcf\xfa\xed\xfe" + original_macho[4:12]
        killed += mutate_macho_with_matching_claim(
            truncated_thin, "truncated-thin-Mach-O"
        )
        truncated_fat = b"\xca\xfe\xba\xbe\0\0\0\1"
        killed += mutate_macho_with_matching_claim(
            truncated_fat, "truncated-fat-Mach-O"
        )
        killed += mutate_macho_with_matching_claim(
            original_macho + build.encode("ascii"), "duplicate-Mach-O-identity"
        )
        synthetic = json.loads(original_attestation)
        synthetic["evidenceClass"] = "simulator-additive-source-census"
        killed += mutate_file(
            attestation, canonical_json(synthetic),
            lambda: validate_attestation(attestation, spec_path, macho, build),
        )
        killed += mutate_file(
            attestation, original_attestation + b" ",
            lambda: validate_attestation(attestation, spec_path, macho, build),
        )
        duplicated_json = original_attestation.replace(
            b'{"artifact":', b'{"schemaVersion":1,"artifact":', 1
        )
        killed += mutate_file(
            attestation, duplicated_json,
            lambda: validate_attestation(attestation, spec_path, macho, build),
        )

        semantic_swap = bytearray(original_artifact)
        static_offset = 64 + 4 * 8
        animated_offset = 64 + 12 * 8
        semantic_swap[static_offset:static_offset + 8], semantic_swap[
            animated_offset:animated_offset + 8
        ] = (semantic_swap[animated_offset:animated_offset + 8],
             semantic_swap[static_offset:static_offset + 8])
        third_read_payload = bytes(semantic_swap)
        require(parse_artifact(third_read_payload, build)["cells"] != cells,
                "third-read swap mutation did not change semantic cells")
        original_regular_bytes = regular_bytes
        artifact_read_count = 0
        macho_read_count = 0

        def third_read_swap(path: pathlib.Path, label: str, maximum: int) -> bytes:
            nonlocal artifact_read_count, macho_read_count
            if path == artifact:
                artifact_read_count += 1
                if artifact_read_count >= 3:
                    return third_read_payload
            if path == macho:
                macho_read_count += 1
            return original_regular_bytes(path, label, maximum)

        globals()["regular_bytes"] = third_read_swap
        try:
            immutable = validate_attestation(attestation, spec_path, macho, build)
        finally:
            globals()["regular_bytes"] = original_regular_bytes
        require(artifact_read_count == 1,
                "attestation reopened artifact after authenticating its snapshot")
        require(macho_read_count == 1,
                "attestation reopened executable after authenticating its snapshot")
        require(immutable["bounded"] == checked_sum(cells[4:12], "expected bounded"),
                "attestation decision did not use its authenticated artifact snapshot")
    return killed


def add_artifact_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--log", required=True, type=pathlib.Path)
    parser.add_argument("--spec", required=True, type=pathlib.Path)
    parser.add_argument("--expected-build", required=True)
    parser.add_argument("--expected-generation", required=True, type=int)
    parser.add_argument("--expected-sequence", required=True, type=int)
    parser.add_argument("--artifact", required=True, type=pathlib.Path)
    parser.add_argument("--write", action="store_true")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    add_artifact_arguments(subparsers.add_parser("host-artifact"))
    add_artifact_arguments(subparsers.add_parser("simulator-artifact"))
    attest = subparsers.add_parser("attest-device")
    attest.add_argument("--evidence-dir", required=True, type=pathlib.Path)
    attest.add_argument("--spec", required=True, type=pathlib.Path)
    attest.add_argument("--expected-sha", required=True)
    attest.add_argument("--macho", required=True, type=pathlib.Path)
    attest.add_argument("--artifact", required=True, type=pathlib.Path)
    attest.add_argument("--attestation", required=True, type=pathlib.Path)
    validate_device = subparsers.add_parser("validate-device-attestation")
    validate_device.add_argument("--attestation", required=True, type=pathlib.Path)
    validate_device.add_argument("--spec", required=True, type=pathlib.Path)
    validate_device.add_argument("--expected-sha", required=True)
    validate_device.add_argument("--macho", required=True, type=pathlib.Path)
    subparsers.add_parser("self-test")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.mode in ("host-artifact", "simulator-artifact"):
        result = run_artifact_mode(arguments, arguments.mode.split("-", 1)[0])
    elif arguments.mode == "attest-device":
        require(arguments.attestation.parent == arguments.artifact.parent,
                "attestation must be beside artifact")
        document, raw = build_attestation(
            arguments.evidence_dir, arguments.spec, arguments.artifact,
            arguments.macho, arguments.expected_sha,
        )
        write_no_clobber(arguments.attestation, raw)
        checked = validate_attestation(arguments.attestation, arguments.spec,
                                       arguments.macho, arguments.expected_sha)
        result = {"status": f"DEVICE {checked['decision']}", **checked,
                  "attestationSha256": sha256(raw),
                  "evidenceClass": document["evidenceClass"]}
    elif arguments.mode == "validate-device-attestation":
        checked = validate_attestation(arguments.attestation, arguments.spec,
                                       arguments.macho, arguments.expected_sha)
        result = {"status": f"DEVICE {checked['decision']}", **checked}
    else:
        killed = self_test()
        result = {"status": "SELF-TEST PASS", "mutationsKilled": killed}
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValidationError, struct.error, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
