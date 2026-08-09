#!/usr/bin/env python3
"""Fail-closed host validator for the P2.1e1b additive A/B evidence pair."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import stat
import struct
import sys
import tempfile
from typing import Any, Callable, Sequence


HEADER_BYTES = 64
RECORD_BYTES = 256
CONSTANTS_BYTES = 160
ADDITIVE_RECORDS = 183
MAX_BASE_RECORDS = 100000
MAX_RECORDS = 100183
MAX_PAYLOAD_BYTES = 25646848
MAX_EVIDENCE_BYTES = 1024 * 1024 * 1024
MAGIC = b"RIOSA09\0"
SHA40_RE = re.compile(r"[0-9a-f]{40}\Z")
SHA64_RE = re.compile(r"[0-9a-f]{64}\Z")
SAFE_LEAF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}\Z")
TEXTURE_RE = re.compile(r"@tex[1-9][0-9]*\Z")
ALLOCATION_RE = re.compile(r"[1-9][0-9]*\Z")
RESOURCE_INDEX_RE = re.compile(r"0x[0-9a-f]+\Z")
TEAM_RE = re.compile(r"[A-Z0-9]{1,32}\Z")
BUNDLE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,254}\Z")
RESULT_PREFIX = "RendererIOS additive causal: v=1 "
DEFAULT_SPEC = pathlib.Path(__file__).with_name("specs") / \
    "p21e1b-static-additive-v1.json"


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) +
            "\n").encode("utf-8")


def _object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def decode_json(raw: bytes, label: str) -> Any:
    require(not raw.startswith(b"\xef\xbb\xbf"), f"{label} has a BOM")
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_object_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"{label} is not strict UTF-8 JSON: {error}") from error


def exact_keys(value: Any, keys: Sequence[str], label: str) -> dict[str, Any]:
    require(type(value) is dict, f"{label} is not an object")
    require(tuple(value.keys()) == tuple(keys), f"{label} keys/order are not exact")
    return value


def regular_bytes(path: pathlib.Path, label: str,
                  maximum: int = MAX_EVIDENCE_BYTES) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode), f"{label} is not regular")
        require(0 <= metadata.st_size <= maximum, f"{label} size is invalid")
        chunks: list[bytes] = []
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            require(chunk != b"", f"{label} was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        require(os.read(descriptor, 1) == b"", f"{label} grew while reading")
        after = os.fstat(descriptor)
        require((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) ==
                (metadata.st_dev, metadata.st_ino, metadata.st_size,
                 metadata.st_mtime_ns), f"{label} changed while reading")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def run_bounded_tool(command: Sequence[str], label: str) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(command, check=False, capture_output=True,
                                timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValidationError(f"{label} could not run: {error}") from error
    require(len(result.stdout) <= 16 * 1024 * 1024 and
            len(result.stderr) <= 16 * 1024 * 1024,
            f"{label} output is unbounded")
    return result


def _tool_input(raw: bytes, leaf: str) -> tuple[tempfile.TemporaryDirectory[str],
                                                      pathlib.Path]:
    directory = tempfile.TemporaryDirectory(prefix="rios-additive-tool-")
    path = pathlib.Path(directory.name) / leaf
    try:
        with path.open("xb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        path.chmod(0o700)
    except BaseException:
        directory.cleanup()
        raise
    return directory, path


def verify_codesign(raw: bytes, identity: dict[str, Any]) -> None:
    directory, path = _tool_input(raw, "Gothic2Notr")
    try:
        verified = run_bounded_tool(
            ("/usr/bin/codesign", "--verify", "--strict", "--verbose=2",
             str(path)), "codesign verification")
        require(verified.returncode == 0,
                "signed Mach-O fails codesign --verify --strict")
        described = run_bounded_tool(
            ("/usr/bin/codesign", "-d", "--verbose=4", str(path)),
            "codesign identity inspection")
        require(described.returncode == 0,
                "signed Mach-O identity cannot be inspected")
        try:
            description = (described.stdout + described.stderr).decode(
                "utf-8", errors="strict").splitlines()
        except UnicodeDecodeError as error:
            raise ValidationError("codesign output is not UTF-8") from error
    finally:
        directory.cleanup()
    identifiers = [line.removeprefix("Identifier=") for line in description
                   if line.startswith("Identifier=")]
    teams = [line.removeprefix("TeamIdentifier=") for line in description
             if line.startswith("TeamIdentifier=")]
    require(identifiers == [identity["bundleId"]],
            "codesign Identifier differs from the expected bundle ID")
    require(teams == [identity["teamId"]],
            "codesign TeamIdentifier differs from the expected team ID")


def verify_metallib(raw: bytes, expected_exports: Sequence[str]) -> None:
    directory, path = _tool_input(raw, "RendererIOS.metallib")
    try:
        result = run_bounded_tool(
            ("/usr/bin/xcrun", "--sdk", "iphoneos", "metal-nm", str(path)),
            "metal-nm verification")
        require(result.returncode == 0,
                "RendererIOS.metallib is not accepted by metal-nm")
        try:
            lines = result.stdout.decode("utf-8").splitlines()
        except UnicodeDecodeError as error:
            raise ValidationError("metal-nm output is not UTF-8") from error
    finally:
        directory.cleanup()
    exports: list[str] = []
    for line in lines:
        fields = line.split()
        if len(fields) >= 3 and fields[1] == "T":
            exports.append(fields[2])
    require(sorted(exports) == list(expected_exports) and
            len(exports) == len(set(exports)),
            "RendererIOS.metallib exports are not the exact export19 set")


def checked_meta(value: Any, root: pathlib.Path, label: str,
                 extra_keys: Sequence[str] = ()) -> tuple[dict[str, Any], bytes]:
    keys = ("file", "bytes", "sha256", *extra_keys)
    metadata = exact_keys(value, keys, label)
    leaf = metadata["file"]
    require(type(leaf) is str and SAFE_LEAF_RE.fullmatch(leaf) is not None,
            f"{label}.file is not a safe leaf")
    require(type(metadata["bytes"]) is int and metadata["bytes"] >= 0,
            f"{label}.bytes is invalid")
    require(type(metadata["sha256"]) is str and
            SHA64_RE.fullmatch(metadata["sha256"]) is not None,
            f"{label}.sha256 is invalid")
    raw = regular_bytes(root / leaf, label)
    require(len(raw) == metadata["bytes"], f"{label} byte count differs")
    require(sha256(raw) == metadata["sha256"], f"{label} hash differs")
    return metadata, raw


def validate_spec(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    raw = regular_bytes(path, "additive pair spec", 1024 * 1024)
    spec = exact_keys(decode_json(raw, "additive pair spec"), (
        "schemaVersion", "evidenceClass", "runnerContract", "artifact",
        "profiles", "tempestSha", "metallib", "capture", "losslessRG11B10",
    ), "additive pair spec")
    require(spec["schemaVersion"] == 1 and type(spec["schemaVersion"]) is int,
            "spec schemaVersion is not integer 1")
    require(spec["evidenceClass"] == "renderer-ios-static-additive-gpu-pair",
            "spec evidenceClass is not exact")
    runner = exact_keys(spec["runnerContract"],
                        ("adapter", "saveSlot"), "runnerContract")
    require(type(runner["saveSlot"]) is int and
            runner == {"adapter": "plain-save4-linear-hdr-proof-v1",
                       "saveSlot": 4},
            "runner contract is not the frozen branch-free save4 adapter")
    artifact = exact_keys(spec["artifact"], (
        "magicHex", "version", "endian", "headerBytes", "recordBytes",
        "constantsBytes", "minimumBaseRecords", "maximumBaseRecords",
        "additiveRecords", "maximumRecords", "maximumPayloadBytes",
        "filenamePattern"), "artifact spec")
    require(artifact == {
        "magicHex": "52494f5341303900", "version": 1, "endian": 0x4C45,
        "headerBytes": 64, "recordBytes": 256, "constantsBytes": 160,
        "minimumBaseRecords": 1, "maximumBaseRecords": 100000,
        "additiveRecords": 183, "maximumRecords": 100183,
        "maximumPayloadBytes": 25646848,
        "filenamePattern":
            "RendererIOS-additive-input-v1-<a|b>-g<generation>-s<sequence>.bin",
    }, "artifact spec differs from frozen D-084 schema")
    require(all(type(artifact[key]) is int for key in (
        "version", "endian", "headerBytes", "recordBytes", "constantsBytes",
        "minimumBaseRecords", "maximumBaseRecords", "additiveRecords",
        "maximumRecords", "maximumPayloadBytes")),
        "artifact spec numeric fields are not strict integers")
    require(bytes.fromhex(artifact["magicHex"]) == MAGIC and
            len(bytes.fromhex(artifact["magicHex"])) == 8,
            "artifact spec magic is not exact 8-byte RIOSA09 NUL")
    profiles = exact_keys(spec["profiles"], ("a", "b"), "profiles")
    for label in ("a", "b"):
        profile = exact_keys(profiles[label], (
            "mode", "launchArgument", "binaryMarker", "terminalPrefix"),
            f"profile {label}")
        mode = f"additive-{label}-hdr"
        require(profile == {
            "mode": mode,
            "launchArgument": f"-renderer-ios-additive-causal-mode={mode}",
            "binaryMarker": f"RIOS_ADDITIVE_CAUSAL_MODE={mode}",
            "terminalPrefix":
                f"RendererIOS additive causal: v=1 mode={mode}",
        }, f"profile {label} is not exact")
    require(type(spec["tempestSha"]) is str and
            SHA40_RE.fullmatch(spec["tempestSha"]) is not None,
            "spec Tempest SHA is invalid")
    metallib = exact_keys(spec["metallib"], ("abi", "exportCount", "exports"),
                          "metallib spec")
    exports = metallib["exports"]
    require(type(metallib["abi"]) is int and
            type(metallib["exportCount"]) is int and
            metallib["abi"] == 9 and metallib["exportCount"] == 19 and
            type(exports) is list and len(exports) == 19 and
            all(type(item) is str for item in exports) and
            exports == sorted(set(exports)) and
            "riosLandscapeAdditiveFragment" in exports,
            "metallib ABI9 exact export19 set is invalid")
    capture = exact_keys(spec["capture"],
                         ("resourceRoles", "compareNativeIdsAcrossRuns"),
                         "capture spec")
    require(capture == {
        "resourceRoles": ["attachment", "proof-blit-source",
                          "tone-resolve-texture0"],
        "compareNativeIdsAcrossRuns": False,
    }, "capture resource identity contract is not exact")
    lossless = exact_keys(spec["losslessRG11B10"], (
        "channelwiseAGreaterOrEqualB", "requirePositiveDelta",
        "requireSamePixelDeltaAndAAboveOne"), "lossless spec")
    require(all(value is True for value in lossless.values()),
            "lossless RG11B10 predicates must all be true")
    return spec, raw


def parse_record(raw: bytes, offset: int, phase: str) -> tuple[int, bytes]:
    values = struct.unpack_from("<9Q5I4B", raw, offset)
    (source, mesh, material, texture, index_offset, index_count,
     vertex_bytes, index_bytes, flags, stride, width, height, mips,
     texture_format, kind, category, animation, reserved) = values
    require(reserved == 0, "input record reserved byte is nonzero")
    require(kind in (1, 2, 3), "input record kind is unknown")
    require(category in (0, 1, 3), "input record category is unknown")
    require(animation in (0, 1, 2, 3), "input record animation is unknown")
    require(texture_format in (1, 2, 3, 4), "input texture format is unknown")
    require(flags & ~1 == 0, "input material flags contain an unknown bit")
    if phase == "base":
        require(category in (0, 1) and flags == 0,
                "base record phase/category/flags are invalid")
    else:
        require((kind, category, animation, flags) == (2, 3, 0, 1),
                "additive record is not exact Static/Additive/None/bit0")
    require(all(value > 0 for value in (source, mesh, material, texture)),
            "input stable ID is zero")
    require(stride == 36 and vertex_bytes >= stride and
            vertex_bytes % stride == 0, "input vertex metadata is invalid")
    require(index_bytes >= 4 and index_bytes % 4 == 0 and
            index_offset % 4 == 0 and index_count > 0 and
            index_count % 3 == 0 and
            index_offset + index_count * 4 <= index_bytes,
            "input index metadata is invalid")
    require(width > 0 and height > 0 and mips > 0,
            "input texture dimensions/mips are zero")
    maximum_mips = max(width, height).bit_length()
    require(mips <= maximum_mips, "input texture mip count is invalid")
    constants = raw[offset + 96:offset + RECORD_BYTES]
    require(len(constants) == CONSTANTS_BYTES, "input constants are truncated")
    return source, constants


def parse_input_artifact(raw: bytes) -> dict[str, Any]:
    require(len(raw) >= HEADER_BYTES, "input artifact is shorter than 64 B")
    require(raw[:8] == MAGIC, "input artifact magic is not exact RIOSA09 NUL")
    version, endian, header_bytes = struct.unpack_from("<HHI", raw, 8)
    base_count, additive_count = struct.unpack_from("<QQ", raw, 16)
    record_bytes, constants_bytes = struct.unpack_from("<II", raw, 32)
    generation, sequence = struct.unpack_from("<QQ", raw, 40)
    flags, reserved = struct.unpack_from("<II", raw, 56)
    require((version, endian, header_bytes) == (1, 0x4C45, 64),
            "input schema/endian/header tuple is not exact")
    require((record_bytes, constants_bytes) == (256, 160),
            "input record/constants sizes are not exact")
    require(1 <= base_count <= MAX_BASE_RECORDS and
            additive_count == ADDITIVE_RECORDS,
            "input base/additive counts are invalid")
    total = base_count + additive_count
    payload_bytes = total * RECORD_BYTES
    require(total <= MAX_RECORDS and payload_bytes <= MAX_PAYLOAD_BYTES,
            "input record/payload limit exceeded")
    require(len(raw) == HEADER_BYTES + payload_bytes,
            "input artifact is truncated or has trailing bytes")
    require(generation > 0 and sequence > 0,
            "input generation/sequence identity is zero")
    require(flags == 0 and reserved == 0,
            "input header flags/reserved are nonzero")
    base_end = HEADER_BYTES + base_count * RECORD_BYTES
    phase_ranges = (("base", HEADER_BYTES, base_end),
                    ("additive", base_end, len(raw)))
    ids: dict[str, list[int]] = {"base": [], "additive": []}
    for phase, begin, end in phase_ranges:
        for offset in range(begin, end, RECORD_BYTES):
            source, _ = parse_record(raw, offset, phase)
            ids[phase].append(source)
        require(all(lhs < rhs for lhs, rhs in zip(ids[phase], ids[phase][1:])),
                f"{phase} input records are not strict source-ordered")
    require(set(ids["base"]).isdisjoint(ids["additive"]),
            "source ID is duplicated across base/additive phases")
    return {
        "baseCount": base_count, "additiveCount": additive_count,
        "generation": generation, "sequence": sequence,
        "basePayload": raw[HEADER_BYTES:base_end],
        "additivePayload": raw[base_end:],
    }


_HDR_VALIDATOR: Any | None = None


def hdr_validator() -> Any:
    global _HDR_VALIDATOR
    if _HDR_VALIDATOR is None:
        path = pathlib.Path(__file__).with_name(
            "validate-linear-hdr-proof-artifact.py")
        specification = importlib.util.spec_from_file_location(
            "rios_linear_hdr_proof_validator", path)
        require(specification is not None and specification.loader is not None,
                "cannot load linear-HDR proof validator")
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        _HDR_VALIDATOR = module
    return _HDR_VALIDATOR


def parse_hdr_proof(raw: bytes) -> dict[str, Any]:
    module = hdr_validator()
    try:
        parsed = module.parse_artifact(raw)
        pixels: list[tuple[float, float, float]] = []
        for offset in range(module.HEADER_BYTES, len(raw), 4):
            word = struct.unpack_from("<I", raw, offset)[0]
            pixels.append((
                module.decode_component(word & 0x7FF, 6),
                module.decode_component((word >> 11) & 0x7FF, 6),
                module.decode_component((word >> 22) & 0x3FF, 5),
            ))
    except Exception as error:
        raise ValidationError(f"linear-HDR proof is invalid: {error}") from error
    parsed["pixels"] = pixels
    return parsed


def validate_macho(raw: bytes, marker: str, opposite: str,
                   identity: dict[str, Any]) -> None:
    require(len(raw) >= 32 and raw[:4] == b"\xcf\xfa\xed\xfe",
            "signed Mach-O is not thin little-endian 64-bit")
    (_, _, _, file_type, command_count, command_bytes, _, _) = (
        struct.unpack_from("<8I", raw, 0))
    require(file_type == 2 and 0 < command_count <= 65535,
            "Mach-O is not a bounded executable")
    require(32 + command_bytes <= len(raw), "Mach-O commands are truncated")
    offset = 32
    signatures = 0
    for _ in range(command_count):
        require(offset + 8 <= 32 + command_bytes,
                "Mach-O load command header is truncated")
        command, size = struct.unpack_from("<II", raw, offset)
        require(size >= 8 and offset + size <= 32 + command_bytes,
                "Mach-O load command size is invalid")
        if command == 0x1D:
            require(size == 16, "LC_CODE_SIGNATURE size is invalid")
            data_offset, data_size = struct.unpack_from("<II", raw, offset + 8)
            require(data_size > 0 and data_offset + data_size <= len(raw),
                    "LC_CODE_SIGNATURE payload is invalid")
            require(data_size >= 12, "embedded signature superblob is truncated")
            magic, blob_length, blob_count = struct.unpack_from(
                ">III", raw, data_offset)
            require(magic == 0xFADE0CC0 and 12 <= blob_length <= data_size and
                    blob_count <= 65535 and 12 + blob_count * 8 <= blob_length,
                    "embedded signature superblob header is invalid")
            signatures += 1
        offset += size
    require(offset == 32 + command_bytes and signatures == 1,
            "Mach-O commands/signature are not exact")
    encoded = marker.encode("ascii")
    require(raw.count(encoded) == 1,
            "Mach-O lacks exactly one expected additive mode marker")
    require(raw.count(opposite.encode("ascii")) == 0,
            "Mach-O contains the opposite additive mode marker")
    require(raw.count(identity["parentSha"].encode("ascii")) == 1,
            "Mach-O lacks exactly one parent SHA marker")
    require(raw.count(identity["bundleId"].encode("ascii")) >= 1 and
            raw.count(identity["teamId"].encode("ascii")) >= 1,
            "signed Mach-O does not bind bundle/team strings")


def validate_runtime_log(raw: bytes, profile: dict[str, Any], parent_sha: str,
                         artifact: dict[str, Any], artifact_sha: str) -> None:
    require(len(raw) <= 64 * 1024 * 1024, "runtime log is unbounded")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValidationError("runtime log is not UTF-8") from error
    marker_lines = [line for line in lines if RESULT_PREFIX in line]
    require(marker_lines, "runtime log lacks an additive causal terminal")
    successes: list[re.Match[str]] = []
    failure_re = re.compile(
        rf"^{re.escape(profile['terminalPrefix'])} terminal=F "
        r"class=(contract|gpu|io) reason=[a-z0-9-]+$")
    success_re = re.compile(
        rf"^{re.escape(profile['terminalPrefix'])} "
        r"b=([0-9a-f]{40}) g=([1-9][0-9]*) s=([1-9][0-9]*) "
        r"base=([1-9][0-9]*) additive=([1-9][0-9]*) "
        r"input=([0-9a-f]{64}) terminal=C$")
    for line in marker_lines:
        require(line.startswith(RESULT_PREFIX) and line.isascii() and
                len(line.encode("ascii")) < 255,
                "additive causal terminal has foreign prefix/encoding/length")
        success = success_re.fullmatch(line)
        failure = failure_re.fullmatch(line)
        require(success is not None or failure is not None,
                "additive causal terminal is malformed or for another mode")
        require(failure is None, "runtime log contains additive terminal=F")
        assert success is not None
        successes.append(success)
    require(len(successes) == 1,
            "runtime log does not contain exactly one terminal=C")
    build, generation, sequence, base, additive, digest = successes[0].groups()
    require((build, int(generation), int(sequence), int(base), int(additive),
             digest) ==
            (parent_sha, artifact["generation"], artifact["sequence"],
             artifact["baseCount"], artifact["additiveCount"], artifact_sha),
            "runtime terminal does not join accepted input artifact")


def validate_capture(raw: bytes, proof: dict[str, Any],
                     roles: list[str]) -> None:
    document = decode_json(raw, "capture identity")
    require(raw == canonical_json(document), "capture identity is not canonical JSON")
    capture = exact_keys(document, (
        "schemaVersion", "acceptedSnapshot", "sceneResource", "commands"),
        "capture identity")
    require(capture["schemaVersion"] == 1 and
            type(capture["schemaVersion"]) is int,
            "capture identity schemaVersion is not integer 1")
    snapshot = exact_keys(capture["acceptedSnapshot"],
                          ("targetGeneration", "snapshotSequence"),
                          "accepted snapshot")
    require(all(type(snapshot[key]) is int for key in snapshot) and
            snapshot == {"targetGeneration": proof["generation"],
                         "snapshotSequence": proof["sequence"]},
            "capture accepted snapshot differs from proof")
    resource = exact_keys(capture["sceneResource"],
                          ("label", "textureRef", "allocationID", "resourceIndex"),
                          "scene resource")
    require(resource["label"] == "RendererIOS.SceneHDR." + proof["id"],
            "capture SceneHDR label differs from proof ID")
    require(type(resource["textureRef"]) is str and
            TEXTURE_RE.fullmatch(resource["textureRef"]) is not None and
            type(resource["allocationID"]) is str and
            ALLOCATION_RE.fullmatch(resource["allocationID"]) is not None and
            type(resource["resourceIndex"]) is str and
            RESOURCE_INDEX_RE.fullmatch(resource["resourceIndex"]) is not None,
            "capture native resource identity is malformed")
    commands = capture["commands"]
    require(type(commands) is list and len(commands) == len(roles),
            "capture command identity count is invalid")
    for command, role in zip(commands, roles):
        entry = exact_keys(command,
                           ("role", "textureRef", "allocationID", "resourceIndex"),
                           f"capture command {role}")
        require(entry["role"] == role and
                all(entry[key] == resource[key] for key in
                    ("textureRef", "allocationID", "resourceIndex")),
                f"capture {role} does not use the per-run SceneHDR identity")


def validate_pair(spec_path: pathlib.Path, attestation_path: pathlib.Path,
                  evidence_root: pathlib.Path, expected_parent_sha: str,
                  expected_bundle_id: str, expected_team_id: str,
                  *, verify_external_tools: bool = True) -> dict[str, Any]:
    require(SHA40_RE.fullmatch(expected_parent_sha) is not None,
            "expected parent SHA is invalid")
    require(BUNDLE_RE.fullmatch(expected_bundle_id) is not None,
            "expected bundle ID is invalid")
    require(TEAM_RE.fullmatch(expected_team_id) is not None,
            "expected team ID is invalid")
    root_metadata = evidence_root.lstat()
    require(stat.S_ISDIR(root_metadata.st_mode),
            "evidence root is not an lstat-directory")
    spec, spec_raw = validate_spec(spec_path)
    raw = regular_bytes(attestation_path, "pair attestation", 16 * 1024 * 1024)
    document = decode_json(raw, "pair attestation")
    require(raw == canonical_json(document), "pair attestation is not canonical JSON")
    root = exact_keys(document, ("schemaVersion", "evidenceClass", "specSha256",
                                 "runs"), "pair attestation")
    require(root["schemaVersion"] == 1 and type(root["schemaVersion"]) is int,
            "attestation schemaVersion is not integer 1")
    require(root["evidenceClass"] == spec["evidenceClass"],
            "attestation evidenceClass differs from spec")
    require(root["specSha256"] == sha256(spec_raw),
            "attestation spec hash differs")
    runs = root["runs"]
    require(type(runs) is list and len(runs) == 2,
            "attestation must contain exact A/B runs")

    authenticated: list[dict[str, Any]] = []
    for index, label in enumerate(("a", "b")):
        run = exact_keys(runs[index], (
            "label", "mode", "launchArgument", "identity", "signedMachO",
            "metallib", "inputArtifact", "runtimeLog", "hdrProof", "capture"),
            f"run {label}")
        profile = spec["profiles"][label]
        require((run["label"], run["mode"], run["launchArgument"]) ==
                (label, profile["mode"], profile["launchArgument"]),
                f"run {label} label/mode/argument is not exact")
        identity = exact_keys(run["identity"],
                              ("parentSha", "tempestSha", "bundleId", "teamId"),
                              f"run {label} identity")
        require(type(identity["parentSha"]) is str and
                SHA40_RE.fullmatch(identity["parentSha"]) is not None,
                f"run {label} parent SHA is invalid")
        require(identity["tempestSha"] == spec["tempestSha"],
                f"run {label} Tempest SHA differs from spec")
        require(type(identity["bundleId"]) is str and
                BUNDLE_RE.fullmatch(identity["bundleId"]) is not None,
                f"run {label} bundle ID is invalid")
        require(type(identity["teamId"]) is str and
                TEAM_RE.fullmatch(identity["teamId"]) is not None,
                f"run {label} team ID is invalid")
        require(identity == {
            "parentSha": expected_parent_sha,
            "tempestSha": spec["tempestSha"],
            "bundleId": expected_bundle_id,
            "teamId": expected_team_id,
        }, f"run {label} identity differs from the frozen candidate")

        macho_meta, macho_raw = checked_meta(
            run["signedMachO"], evidence_root, f"run {label} signed Mach-O",
            ("modeMarker",))
        require(macho_meta["modeMarker"] == profile["binaryMarker"],
                f"run {label} attested binary marker is not exact")
        opposite = spec["profiles"]["b" if label == "a" else "a"]["binaryMarker"]
        validate_macho(macho_raw, profile["binaryMarker"], opposite, identity)
        if verify_external_tools:
            verify_codesign(macho_raw, identity)

        metallib_meta, metallib_raw = checked_meta(
            run["metallib"], evidence_root, f"run {label} metallib", (
                "exportManifestFile", "exportManifestBytes",
                "exportManifestSha256", "abi", "exportCount"))
        require(metallib_meta["abi"] == 9 and
                metallib_meta["exportCount"] == 19,
                f"run {label} metallib ABI/export count is not 9/19")
        manifest_leaf = metallib_meta["exportManifestFile"]
        require(type(manifest_leaf) is str and
                SAFE_LEAF_RE.fullmatch(manifest_leaf) is not None,
                f"run {label} export manifest leaf is unsafe")
        manifest_raw = regular_bytes(evidence_root / manifest_leaf,
                                     f"run {label} export manifest", 1024 * 1024)
        require(len(manifest_raw) == metallib_meta["exportManifestBytes"] and
                sha256(manifest_raw) == metallib_meta["exportManifestSha256"],
                f"run {label} export manifest metadata differs")
        expected_manifest = ("\n".join(spec["metallib"]["exports"]) +
                             "\n").encode("ascii")
        require(manifest_raw == expected_manifest,
                f"run {label} export manifest is not exact export19")
        require(all(name.encode("ascii") in metallib_raw
                    for name in spec["metallib"]["exports"]),
                f"run {label} metallib lacks an export19 symbol")
        if verify_external_tools:
            verify_metallib(metallib_raw, spec["metallib"]["exports"])

        input_meta, input_raw = checked_meta(
            run["inputArtifact"], evidence_root, f"run {label} input artifact",
            ("baseSha256", "additiveSha256", "targetGeneration",
             "snapshotSequence"))
        artifact = parse_input_artifact(input_raw)
        expected_name = (f"RendererIOS-additive-input-v1-{label}-"
                         f"g{artifact['generation']}-s{artifact['sequence']}.bin")
        require(input_meta["file"] == expected_name,
                f"run {label} input artifact filename is not exclusive/canonical")
        require(input_meta["baseSha256"] == sha256(artifact["basePayload"]) and
                input_meta["additiveSha256"] == sha256(artifact["additivePayload"]),
                f"run {label} input phase digest differs")
        require(type(input_meta["targetGeneration"]) is int and
                type(input_meta["snapshotSequence"]) is int and
                (input_meta["targetGeneration"], input_meta["snapshotSequence"]) ==
                (artifact["generation"], artifact["sequence"]),
                f"run {label} input attested snapshot differs")

        log_meta, log_raw = checked_meta(
            run["runtimeLog"], evidence_root, f"run {label} runtime log")
        validate_runtime_log(log_raw, profile, identity["parentSha"], artifact,
                             input_meta["sha256"])

        proof_meta, proof_raw = checked_meta(
            run["hdrProof"], evidence_root, f"run {label} HDR proof",
            ("targetGeneration", "snapshotSequence", "proofId"))
        proof = parse_hdr_proof(proof_raw)
        require(proof["build"] == identity["parentSha"],
                f"run {label} HDR proof build differs from parent")
        require(type(proof_meta["targetGeneration"]) is int and
                type(proof_meta["snapshotSequence"]) is int and
                (proof_meta["targetGeneration"], proof_meta["snapshotSequence"],
                 proof_meta["proofId"]) ==
                (proof["generation"], proof["sequence"], proof["id"]),
                f"run {label} HDR proof attested identity differs")
        require((proof["generation"], proof["sequence"]) ==
                (artifact["generation"], artifact["sequence"]),
                f"run {label} accepted artifact/HDR snapshot differs")

        _, capture_raw = checked_meta(
            run["capture"], evidence_root, f"run {label} capture identity")
        validate_capture(capture_raw, proof, spec["capture"]["resourceRoles"])
        authenticated.append({
            "identity": identity, "macho": macho_meta,
            "metallib": metallib_meta, "input": artifact, "proof": proof,
        })

    a, b = authenticated
    require(a["identity"] == b["identity"],
            "A/B parent/Tempest/bundle/team identities differ")
    require(a["macho"]["sha256"] != b["macho"]["sha256"],
            "A/B signed Mach-O hashes are not different")
    require((a["metallib"]["sha256"], a["metallib"]["abi"],
             a["metallib"]["exportCount"],
             a["metallib"]["exportManifestSha256"]) ==
            (b["metallib"]["sha256"], b["metallib"]["abi"],
             b["metallib"]["exportCount"],
             b["metallib"]["exportManifestSha256"]),
            "A/B ABI9 metallib/export19 identity differs")
    require(a["input"]["basePayload"] == b["input"]["basePayload"],
            "A/B base input record bytes differ")
    require(a["input"]["additivePayload"] == b["input"]["additivePayload"],
            "A/B additive input record bytes differ")

    proof_a, proof_b = a["proof"], b["proof"]
    require((proof_a["width"], proof_a["height"], proof_a["row"],
             proof_a["bytes"]) ==
            (proof_b["width"], proof_b["height"], proof_b["row"],
             proof_b["bytes"]), "A/B RG11B10 extents/layout differ")
    positive = False
    joined_pixel = False
    for pixel_a, pixel_b in zip(proof_a["pixels"], proof_b["pixels"]):
        require(all(channel_a >= channel_b
                    for channel_a, channel_b in zip(pixel_a, pixel_b)),
                "lossless RG11B10 has a channel where A is below B")
        changed = any(channel_a > channel_b
                      for channel_a, channel_b in zip(pixel_a, pixel_b))
        positive = positive or changed
        joined_pixel = joined_pixel or (changed and any(value > 1.0 for value in pixel_a))
    require(positive, "lossless RG11B10 has no positive A-B delta")
    require(joined_pixel,
            "no pixel simultaneously has any(A>B) and any(A>1)")
    return {"parentSha": a["identity"]["parentSha"],
            "baseCount": a["input"]["baseCount"],
            "additiveCount": a["input"]["additiveCount"]}


def _record(source: int, additive: bool) -> bytes:
    constants = bytes((source + index) & 0xFF for index in range(160))
    return struct.pack(
        "<9Q5I4B", source, source + 10000, source + 20000, source + 30000,
        0, 30, 360, 120, 1 if additive else 0, 36, 4, 4, 3, 1,
        2 if additive else 1, 3 if additive else 0, 0, 0) + constants


def _input_artifact(generation: int, sequence: int) -> bytes:
    payload = _record(2, False) + b"".join(
        _record(1000 + index, True) for index in range(ADDITIVE_RECORDS))
    header = struct.pack("<8sHHIQQIIQQII", MAGIC, 1, 0x4C45, 64, 1,
                         ADDITIVE_RECORDS, 256, 160, generation, sequence, 0, 0)
    return header + payload


def _word(red_exponent: int, green_exponent: int, blue_exponent: int) -> int:
    return ((red_exponent << 6) | ((green_exponent << 6) << 11) |
            ((blue_exponent << 5) << 22))


def _proof(parent: str, proof_id: bytes, generation: int, sequence: int,
           words: Sequence[int]) -> bytes:
    payload = b"".join(struct.pack("<I", word) for word in words)
    data = bytearray(160 + len(payload))
    struct.pack_into("<8sHHIIIIIQQQII", data, 0, b"RIOSR11\0", 1, 160,
                     1, 1, len(words), 1, len(words) * 4, len(payload),
                     generation, sequence, 0, 0)
    data[64:80] = proof_id
    data[80:100] = bytes.fromhex(parent)
    data[104:157] = ("RendererIOS.SceneHDR." + proof_id.hex()).encode("ascii")
    data[160:] = payload
    return bytes(data)


def _macho(marker: str, identity: dict[str, str]) -> bytes:
    marker_raw = marker.encode("ascii") + b"\0"
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0)
    signature = struct.pack(">III", 0xFADE0CC0, 12, 0)
    command = struct.pack("<4I", 0x1D, 16, 48, len(signature))
    identity_raw = b"\0".join(identity[key].encode("ascii") for key in
                              ("parentSha", "bundleId", "teamId"))
    return header + command + signature + marker_raw + b"\0" + identity_raw


def _meta(path: pathlib.Path) -> dict[str, Any]:
    raw = path.read_bytes()
    return {"file": path.name, "bytes": len(raw), "sha256": sha256(raw)}


def _write(path: pathlib.Path, raw: bytes) -> None:
    path.write_bytes(raw)


def _capture(proof_id: bytes, generation: int, sequence: int,
             texture: str, allocation: str, resource_index: str) -> bytes:
    identity = {"textureRef": texture, "allocationID": allocation,
                "resourceIndex": resource_index}
    return canonical_json({
        "schemaVersion": 1,
        "acceptedSnapshot": {"targetGeneration": generation,
                             "snapshotSequence": sequence},
        "sceneResource": {"label": "RendererIOS.SceneHDR." + proof_id.hex(),
                          **identity},
        "commands": [{"role": role, **identity} for role in
                     ("attachment", "proof-blit-source",
                      "tone-resolve-texture0")],
    })


def _build_fixture(root: pathlib.Path, spec_path: pathlib.Path) -> pathlib.Path:
    spec, spec_raw = validate_spec(spec_path)
    parent = "0123456789abcdef0123456789abcdef01234567"
    identity = {"parentSha": parent, "tempestSha": spec["tempestSha"],
                "bundleId": "io.github.tryk016.opengothic",
                "teamId": "RMJWWPF379"}
    export_raw = ("\n".join(spec["metallib"]["exports"]) + "\n").encode("ascii")
    metallib_raw = b"MTLB\0" + b"\0".join(
        item.encode("ascii") for item in spec["metallib"]["exports"])
    runs: list[dict[str, Any]] = []
    words = {
        "a": [_word(16, 14, 14), _word(15, 15, 15)],
        "b": [_word(14, 14, 14), _word(15, 15, 15)],
    }
    for index, label in enumerate(("a", "b")):
        profile = spec["profiles"][label]
        generation, sequence = (7 + index, 9 + index)
        proof_id = bytes(range(1 + index * 16, 17 + index * 16))
        artifact_path = root / (
            f"RendererIOS-additive-input-v1-{label}-g{generation}-s{sequence}.bin")
        _write(artifact_path, _input_artifact(generation, sequence))
        artifact = parse_input_artifact(artifact_path.read_bytes())
        input_meta = {**_meta(artifact_path),
                      "baseSha256": sha256(artifact["basePayload"]),
                      "additiveSha256": sha256(artifact["additivePayload"]),
                      "targetGeneration": generation,
                      "snapshotSequence": sequence}
        log_path = root / f"runtime-{label}.log"
        terminal = (f"{profile['terminalPrefix']} b={parent} g={generation} "
                    f"s={sequence} base=1 additive=183 "
                    f"input={input_meta['sha256']} terminal=C\n")
        _write(log_path, terminal.encode("ascii"))
        proof_path = root / f"linear-hdr-{label}.bin"
        _write(proof_path, _proof(parent, proof_id, generation, sequence,
                                  words[label]))
        proof_meta = {**_meta(proof_path), "targetGeneration": generation,
                      "snapshotSequence": sequence, "proofId": proof_id.hex()}
        capture_path = root / f"capture-identity-{label}.json"
        _write(capture_path, _capture(proof_id, generation, sequence,
                                     f"@tex{index + 1}", str(100 + index),
                                     f"0x{10 + index:x}"))
        macho_path = root / f"Gothic2Notr-{label}"
        _write(macho_path, _macho(profile["binaryMarker"], identity))
        metallib_path = root / f"RendererIOS-{label}.metallib"
        export_path = root / f"RendererIOS-{label}.exports"
        _write(metallib_path, metallib_raw)
        _write(export_path, export_raw)
        metallib_meta = {**_meta(metallib_path),
                          "exportManifestFile": export_path.name,
                          "exportManifestBytes": len(export_raw),
                          "exportManifestSha256": sha256(export_raw),
                          "abi": 9, "exportCount": 19}
        runs.append({
            "label": label, "mode": profile["mode"],
            "launchArgument": profile["launchArgument"],
            "identity": copy.deepcopy(identity),
            "signedMachO": {**_meta(macho_path),
                             "modeMarker": profile["binaryMarker"]},
            "metallib": metallib_meta,
            "inputArtifact": input_meta,
            "runtimeLog": _meta(log_path),
            "hdrProof": proof_meta,
            "capture": _meta(capture_path),
        })
    document = {"schemaVersion": 1, "evidenceClass": spec["evidenceClass"],
                "specSha256": sha256(spec_raw), "runs": runs}
    path = root / "additive-gpu-pair-attestation-v1.json"
    _write(path, canonical_json(document))
    return path


def _load_attestation(path: pathlib.Path) -> dict[str, Any]:
    value = decode_json(path.read_bytes(), "self-test attestation")
    assert type(value) is dict
    return value


def _store_attestation(path: pathlib.Path, document: dict[str, Any]) -> None:
    _write(path, canonical_json(document))


def _refresh_meta(document: dict[str, Any], root: pathlib.Path,
                  run_index: int, field: str) -> None:
    metadata = document["runs"][run_index][field]
    raw = (root / metadata["file"]).read_bytes()
    metadata["bytes"] = len(raw)
    metadata["sha256"] = sha256(raw)


def _refresh_input_and_log(document: dict[str, Any], root: pathlib.Path,
                           run_index: int) -> None:
    run = document["runs"][run_index]
    path = root / run["inputArtifact"]["file"]
    raw = path.read_bytes()
    parsed = parse_input_artifact(raw)
    run["inputArtifact"].update({
        "bytes": len(raw), "sha256": sha256(raw),
        "baseSha256": sha256(parsed["basePayload"]),
        "additiveSha256": sha256(parsed["additivePayload"]),
    })
    log_path = root / run["runtimeLog"]["file"]
    log = log_path.read_text(encoding="ascii")
    log = re.sub(r"input=[0-9a-f]{64}",
                 "input=" + run["inputArtifact"]["sha256"], log)
    log_path.write_text(log, encoding="ascii")
    _refresh_meta(document, root, run_index, "runtimeLog")


def self_test(spec_path: pathlib.Path) -> int:
    validate_spec(spec_path)
    expected_parent = "0123456789abcdef0123456789abcdef01234567"
    expected_bundle = "io.github.tryk016.opengothic"
    expected_team = "RMJWWPF379"
    mutations: list[tuple[str, Callable[[pathlib.Path, pathlib.Path,
                                         dict[str, Any]], None]]] = []

    def document_mutation(name: str, change: Callable[[dict[str, Any]], None]) -> None:
        def apply(root: pathlib.Path, _: pathlib.Path, document: dict[str, Any]) -> None:
            del root
            change(document)
        mutations.append((name, apply))

    document_mutation("parent-sha", lambda doc:
                      doc["runs"][1]["identity"].update(parentSha="f" * 40))
    document_mutation("tempest-sha", lambda doc:
                      doc["runs"][1]["identity"].update(tempestSha="f" * 40))
    document_mutation("bundle-id", lambda doc:
                      doc["runs"][1]["identity"].update(bundleId="wrong.bundle"))
    document_mutation("team-id", lambda doc:
                      doc["runs"][1]["identity"].update(teamId="WRONGTEAM"))
    document_mutation("both-parent-sha", lambda doc:
                      [run["identity"].update(parentSha="f" * 40)
                       for run in doc["runs"]])
    document_mutation("both-bundle-id", lambda doc:
                      [run["identity"].update(bundleId="com.example.wrong")
                       for run in doc["runs"]])
    document_mutation("both-team-id", lambda doc:
                      [run["identity"].update(teamId="WRONGTEAM")
                       for run in doc["runs"]])
    document_mutation("launch-argument", lambda doc:
                      doc["runs"][1].update(launchArgument="--wrong"))

    def binary_mode(root: pathlib.Path, _: pathlib.Path,
                    document: dict[str, Any]) -> None:
        run = document["runs"][1]
        path = root / run["signedMachO"]["file"]
        raw = path.read_bytes().replace(b"additive-b-hdr", b"additive-a-hdr")
        _write(path, raw)
        _refresh_meta(document, root, 1, "signedMachO")
    mutations.append(("binary-mode", binary_mode))

    def metallib_change(root: pathlib.Path, _: pathlib.Path,
                        document: dict[str, Any]) -> None:
        path = root / document["runs"][1]["metallib"]["file"]
        _write(path, path.read_bytes() + b"X")
        _refresh_meta(document, root, 1, "metallib")
    mutations.append(("metallib", metallib_change))

    def artifact_mutation(name: str, change: Callable[[bytearray], None],
                          refresh: bool) -> None:
        def apply(root: pathlib.Path, _: pathlib.Path,
                  document: dict[str, Any]) -> None:
            path = root / document["runs"][1]["inputArtifact"]["file"]
            raw = bytearray(path.read_bytes())
            change(raw)
            _write(path, bytes(raw))
            if refresh:
                _refresh_input_and_log(document, root, 1)
            else:
                _refresh_meta(document, root, 1, "inputArtifact")
        mutations.append((name, apply))

    artifact_mutation("missing-additive", lambda raw:
                      (struct.pack_into("<Q", raw, 24, 182),
                       raw.__delitem__(slice(-RECORD_BYTES, None))), False)
    artifact_mutation("reordered-additive", lambda raw:
                      raw.__setitem__(slice(320, 832),
                                      raw[576:832] + raw[320:576]), False)
    artifact_mutation("changed-additive-constants", lambda raw:
                      raw.__setitem__(64 + 256 + 96,
                                      raw[64 + 256 + 96] ^ 1), True)
    artifact_mutation("changed-base-digest", lambda raw:
                      raw.__setitem__(64 + 96, raw[64 + 96] ^ 1), True)

    def cross_run_false_join(root: pathlib.Path, _: pathlib.Path,
                             document: dict[str, Any]) -> None:
        a_path = root / document["runs"][0]["capture"]["file"]
        b_path = root / document["runs"][1]["capture"]["file"]
        capture_a = decode_json(a_path.read_bytes(), "capture A")
        capture_b = decode_json(b_path.read_bytes(), "capture B")
        capture_b["sceneResource"].update({
            key: capture_a["sceneResource"][key]
            for key in ("textureRef", "allocationID", "resourceIndex")})
        _write(b_path, canonical_json(capture_b))
        _refresh_meta(document, root, 1, "capture")
    mutations.append(("cross-run-native-id-false-join", cross_run_false_join))

    def proof_payload(name: str, run_index: int,
                      words: Sequence[int]) -> None:
        def apply(root: pathlib.Path, _: pathlib.Path,
                  document: dict[str, Any]) -> None:
            path = root / document["runs"][run_index]["hdrProof"]["file"]
            raw = bytearray(path.read_bytes())
            raw[160:] = b"".join(struct.pack("<I", word) for word in words)
            _write(path, bytes(raw))
            _refresh_meta(document, root, run_index, "hdrProof")
        mutations.append((name, apply))

    proof_payload("malformed-rg11", 1, [31 << 6, _word(15, 15, 15)])
    proof_payload("equal-delta", 1, [_word(16, 14, 14), _word(15, 15, 15)])
    proof_payload("negative-only", 0, [_word(14, 14, 14), _word(14, 14, 14)])

    def split_pixel_predicate(root: pathlib.Path, _: pathlib.Path,
                              document: dict[str, Any]) -> None:
        for run_index, words in enumerate((
                [_word(15, 15, 15), _word(16, 16, 16)],
                [_word(14, 14, 14), _word(16, 16, 16)])):
            path = root / document["runs"][run_index]["hdrProof"]["file"]
            raw = bytearray(path.read_bytes())
            raw[160:] = b"".join(struct.pack("<I", word) for word in words)
            _write(path, bytes(raw))
            _refresh_meta(document, root, run_index, "hdrProof")
    mutations.append(("delta-and-above-one-different-pixels", split_pixel_predicate))

    def export_manifest(root: pathlib.Path, _: pathlib.Path,
                        document: dict[str, Any]) -> None:
        run = document["runs"][1]
        path = root / run["metallib"]["exportManifestFile"]
        _write(path, path.read_bytes() + b"unexpectedExport\n")
        raw = path.read_bytes()
        run["metallib"]["exportManifestBytes"] = len(raw)
        run["metallib"]["exportManifestSha256"] = sha256(raw)
    mutations.append(("unexpected-export", export_manifest))

    killed = 0
    with tempfile.TemporaryDirectory(prefix="rios-additive-pair-") as directory:
        root = pathlib.Path(directory)
        baseline = root / "baseline"
        baseline.mkdir()
        attestation = _build_fixture(baseline, spec_path)
        baseline_document = _load_attestation(attestation)
        try:
            verify_codesign(
                (baseline / baseline_document["runs"][0]["signedMachO"]["file"]
                 ).read_bytes(),
                baseline_document["runs"][0]["identity"])
        except ValidationError:
            pass
        else:
            raise ValidationError("unsigned synthetic Mach-O passed codesign")
        spec, _ = validate_spec(spec_path)
        try:
            verify_metallib(
                (baseline / baseline_document["runs"][0]["metallib"]["file"]
                 ).read_bytes(),
                spec["metallib"]["exports"])
        except ValidationError:
            pass
        else:
            raise ValidationError("synthetic metallib passed metal-nm")
        validate_pair(spec_path, attestation, baseline, expected_parent,
                      expected_bundle, expected_team,
                      verify_external_tools=False)
        # A/B native IDs differ in the baseline and are intentionally not joined
        # across launches; only each capture's internal triple is compared.
        for index, (name, mutation) in enumerate(mutations):
            case = root / f"mutation-{index}"
            case.mkdir()
            attestation = _build_fixture(case, spec_path)
            document = _load_attestation(attestation)
            mutation(case, attestation, document)
            _store_attestation(attestation, document)
            try:
                validate_pair(spec_path, attestation, case, expected_parent,
                              expected_bundle, expected_team,
                              verify_external_tools=False)
            except (OSError, ValidationError):
                killed += 1
            else:
                raise ValidationError(f"mutation survived: {name}")
    require(killed == len(mutations), "mutation oracle count drifted")
    print(f"paired validator self-test: PASS ({killed} mutations killed)")
    return 0


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    self_parser = subparsers.add_parser("self-test")
    self_parser.add_argument("--spec", type=pathlib.Path, default=DEFAULT_SPEC)
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--spec", required=True, type=pathlib.Path)
    validate_parser.add_argument("--attestation", required=True,
                                 type=pathlib.Path)
    validate_parser.add_argument("--evidence-dir", required=True,
                                 type=pathlib.Path)
    validate_parser.add_argument("--expected-parent-sha", required=True)
    validate_parser.add_argument("--expected-bundle-id", required=True)
    validate_parser.add_argument("--expected-team-id", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.mode == "self-test":
            return self_test(arguments.spec)
        result = validate_pair(
            arguments.spec, arguments.attestation, arguments.evidence_dir,
            arguments.expected_parent_sha, arguments.expected_bundle_id,
            arguments.expected_team_id)
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("ADDITIVE A/B EVIDENCE PAIR VALID")
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
