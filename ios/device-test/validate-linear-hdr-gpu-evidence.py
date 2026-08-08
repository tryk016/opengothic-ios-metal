#!/usr/bin/env python3
"""Collect and validate the exact RendererIOS gpudebug/numeric evidence join."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import re
import secrets
import selectors
import signal
import stat
import struct
import subprocess
import sys
import time
from typing import Any, Iterable, Sequence


MAX_EVIDENCE_BYTES = 1024 * 1024
MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024
MAX_CAPTURE_BYTES = 512 * 1024 * 1024
COLLECTOR_GLOBAL_TIMEOUT_SECONDS = 720.0
COLLECTOR_MAIN_TIMEOUT_SECONDS = 600.0
COLLECTOR_COMMAND_TIMEOUT_SECONDS = 90.0
COLLECTOR_MINIMUM_TIMEOUT_SECONDS = 1.0
MAX_TEXTURE_EXTENT = 16384
UINT32_MAX = (1 << 32) - 1
UINT64_MAX = (1 << 64) - 1
SCHEMA_VERSION = 2
EVIDENCE_CLASS = "device-gpudebug-lossless"
PRODUCER = "opengothic-linear-hdr-gpu-adapter/2"
GPUDEBUG = "/usr/bin/gpudebug"
GPUDEBUG_VERSION = b"gpudebug 1.0\n"
CAPTURE_LEAF = "RendererIOS-linear-hdr-proof-v1.gputrace"
SUMMARY_LEAF = "capture-copy-summary-v1.json"
ROLE_ORDER = (
    "version", "open", "commands", "command-buffer", "scene-encoder",
    "scene-color0", "proof-encoder", "proof-blit", "tone-encoder",
    "tone-fragment", "tone-tex0", "scene-resource", "terminate",
    "sessions-after",
)
SAFE_BASENAME_RE = re.compile(r"[a-z0-9][a-z0-9.-]{0,95}\Z")
H32_RE = re.compile(r"[0-9a-f]{32}\Z")
H40_RE = re.compile(r"[0-9a-f]{40}\Z")
H64_RE = re.compile(r"[0-9a-f]{64}\Z")
UINT_RE = re.compile(r"0|[1-9][0-9]*\Z")
POSITIVE_RE = re.compile(r"[1-9][0-9]*\Z")
LOWER_HEX_RE = re.compile(r"[0-9a-f]+\Z")
FLOAT_HEX_RE = re.compile(r"0x[01]\.[0-9a-f]{13}p[+-][0-9]+\Z")
RENDER_PATH_RE = re.compile(r"commands/(cb(?:0|[1-9][0-9]*))/(re(?:0|[1-9][0-9]*))\Z")
BLIT_PATH_RE = re.compile(r"commands/(cb(?:0|[1-9][0-9]*))/(be(?:0|[1-9][0-9]*))\Z")
BLIT_COMMAND_RE = re.compile(r"commands/(cb(?:0|[1-9][0-9]*))/(be(?:0|[1-9][0-9]*))/(blit(?:0|[1-9][0-9]*))\Z")
DRAW_PATH_RE = re.compile(
    r"commands/(cb(?:0|[1-9][0-9]*))/(re(?:0|[1-9][0-9]*))/(?:grp(?:0|[1-9][0-9]*)/)*draw(?:0|[1-9][0-9]*)\Z"
)
CAPTURE_SUCCESS_RE = re.compile(
    r"^RendererIOS HDR capture: v=1 id=([0-9a-f]{32}) "
    r"file=RendererIOS-linear-hdr-proof-v1\.gputrace "
    r"kind=(file|directory) bytes=([1-9][0-9]*) terminal=C$"
)
CAPTURE_FAILURE_RE = re.compile(
    r"^RendererIOS HDR capture: v=1 id=(?:[0-9a-f]{32}|none) "
    r"terminal=F reason=(?:start|start-ambiguous|stop|pre-submit|"
    r"submit-ambiguous|idle|state)$"
)
SESSION_RE = re.compile(
    r"(?:sessionId|session ID|session id)[\"' :=]+([A-Za-z0-9._-]+)"
)


class EvidenceError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def reject_constant(value: str) -> None:
    raise EvidenceError(f"non-finite JSON number is forbidden: {value}")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def exact_object(value: Any, keys: Iterable[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    expected = set(keys)
    require(set(value) == expected,
            f"{label} keys differ: expected {sorted(expected)}, got {sorted(value)}")
    return value


def exact_int(value: Any, expected: int, label: str) -> None:
    require(isinstance(value, int) and not isinstance(value, bool) and value == expected,
            f"{label} must be integer {expected}")


def bounded_int(value: Any, label: str, minimum: int, maximum: int) -> int:
    require(isinstance(value, int) and not isinstance(value, bool),
            f"{label} must be an integer")
    require(minimum <= value <= maximum, f"{label} is out of range")
    return value


def exact_string(value: Any, expected: str, label: str) -> str:
    require(isinstance(value, str) and value == expected,
            f"{label} must be {expected!r}")
    return value


def matching_string(value: Any, pattern: re.Pattern[str], label: str) -> str:
    require(isinstance(value, str) and pattern.fullmatch(value) is not None,
            f"{label} has invalid grammar")
    return value


def printable(value: Any, label: str) -> str:
    require(isinstance(value, str) and value and value.isascii(),
            f"{label} must be nonempty printable ASCII")
    require(all(32 <= ord(character) < 127 for character in value),
            f"{label} must be nonempty printable ASCII")
    return value


def canonical_json_bytes(value: Any) -> bytes:
    try:
        return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=True, allow_nan=False) + "\n").encode("ascii")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise EvidenceError(f"value cannot be encoded as canonical JSON: {error}") from error


def regular_bytes(path: pathlib.Path, label: str, maximum: int,
                  require_mode_0600: bool = False) -> bytes:
    try:
        before = path.lstat()
        require(stat.S_ISREG(before.st_mode), f"{label} is not lstat-regular")
        require(0 < before.st_size <= maximum, f"{label} size is invalid")
        if require_mode_0600:
            require(stat.S_IMODE(before.st_mode) == 0o600,
                    f"{label} mode is not 0600")
        raw = path.read_bytes()
        after = path.lstat()
    except OSError as error:
        raise EvidenceError(f"cannot read {label}: {error}") from error
    require(len(raw) == before.st_size, f"{label} changed while reading")
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
            f"{label} changed while reading")
    return raw


def load_document(path: pathlib.Path, canonical: bool = True) -> Any:
    raw = regular_bytes(path, "evidence", MAX_EVIDENCE_BYTES, canonical)
    try:
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                              parse_constant=reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"evidence is not exact UTF-8 JSON: {error}") from error
    if canonical:
        require(raw == canonical_json_bytes(document), "evidence JSON is not canonical")
    return document


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def fsync_directory(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC |
                         os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def rename_no_clobber(source: pathlib.Path, destination: pathlib.Path,
                      label: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    rename_excl = getattr(libc, "renameatx_np", None)
    require(rename_excl is not None, "renameatx_np is unavailable")
    rename_excl.argtypes = [ctypes.c_int, ctypes.c_char_p,
                            ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename_excl.restype = ctypes.c_int
    require(source.name not in ("", ".", "..") and
            destination.name not in ("", ".", ".."),
            f"atomic no-clobber {label} leaf is unsafe")
    source_directory = os.open(
        source.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC |
        os.O_NOFOLLOW)
    destination_directory = os.open(
        destination.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC |
        os.O_NOFOLLOW)
    try:
        ctypes.set_errno(0)
        result = rename_excl(
            source_directory, os.fsencode(source.name),
            destination_directory, os.fsencode(destination.name), 0x00000004)
        require(result == 0,
                f"atomic no-clobber {label} rename failed: "
                f"errno={ctypes.get_errno()}")
    finally:
        os.close(destination_directory)
        os.close(source_directory)


def atomic_no_clobber(path: pathlib.Path, raw: bytes) -> None:
    require(not path.exists() and not path.is_symlink(),
            f"destination already exists: {path.name}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                         os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        offset = 0
        while offset < len(raw):
            offset += os.write(descriptor, raw[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        rename_no_clobber(temporary, path, path.name)
        fsync_directory(path.parent)
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def _stat_identity(value: os.stat_result) -> tuple[int, int, int, int, int]:
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns,
            stat.S_IFMT(value.st_mode))


def _require_same_stat(before: os.stat_result, after: os.stat_result,
                       label: str) -> None:
    require(_stat_identity(before) == _stat_identity(after),
            f"capture member changed while {label}")


def _file_digest_fd(descriptor: int, expected: os.stat_result,
                    label: str) -> bytes:
    opened = os.fstat(descriptor)
    _require_same_stat(expected, opened, f"opening {label}")
    require(stat.S_ISREG(opened.st_mode), f"capture member is not regular: {label}")
    digest = hashlib.sha256()
    while True:
        block = os.read(descriptor, 1024 * 1024)
        if not block:
            break
        digest.update(block)
    _require_same_stat(opened, os.fstat(descriptor), f"hashing {label}")
    return digest.digest()


def _capture_directory_entries(descriptor: int, relative: bytes = b"") -> list[
        tuple[bytes, str, os.stat_result, bytes]]:
    before = os.fstat(descriptor)
    require(stat.S_ISDIR(before.st_mode), "capture directory descriptor is invalid")
    try:
        names = os.listdir(descriptor)
    except OSError as error:
        raise EvidenceError(f"cannot enumerate capture directory: {error}") from error
    encoded_names: list[tuple[bytes, str]] = []
    for name in names:
        try:
            encoded = name.encode("utf-8", "strict")
        except UnicodeError as error:
            raise EvidenceError(f"capture member name is not UTF-8: {error}") from error
        require(encoded not in (b"", b".", b"..") and b"/" not in encoded and
                b"\0" not in encoded, "capture member path is unsafe")
        encoded_names.append((encoded, name))
    encoded_names.sort()
    require(len({encoded for encoded, _ in encoded_names}) == len(encoded_names),
            "capture directory names are ambiguous")

    entries: list[tuple[bytes, str, os.stat_result, bytes]] = []
    for encoded_name, name in encoded_names:
        encoded = encoded_name if not relative else relative + b"/" + encoded_name
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        require(not stat.S_ISLNK(metadata.st_mode),
                f"capture member is a symlink: {encoded.decode('utf-8')}")
        if stat.S_ISDIR(metadata.st_mode):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC |
                            os.O_NOFOLLOW, dir_fd=descriptor)
            try:
                _require_same_stat(metadata, os.fstat(child),
                                   f"opening {encoded.decode('utf-8')}")
                entries.append((encoded, "D", metadata, b""))
                entries.extend(_capture_directory_entries(child, encoded))
                _require_same_stat(metadata, os.fstat(child),
                                   f"walking {encoded.decode('utf-8')}")
            finally:
                os.close(child)
        elif stat.S_ISREG(metadata.st_mode):
            require(metadata.st_size >= 0, "capture member has invalid size")
            child = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            try:
                digest = _file_digest_fd(child, metadata, encoded.decode("utf-8"))
            finally:
                os.close(child)
            current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            _require_same_stat(metadata, current,
                               f"hashing {encoded.decode('utf-8')}")
            entries.append((encoded, "F", metadata, digest))
        else:
            raise EvidenceError(
                f"capture member is special: {encoded.decode('utf-8')}")
    try:
        after_names = sorted(name.encode("utf-8", "strict")
                             for name in os.listdir(descriptor))
    except (OSError, UnicodeError) as error:
        raise EvidenceError(f"cannot recheck capture directory: {error}") from error
    require(after_names == [encoded for encoded, _ in encoded_names],
            "capture directory changed while walking")
    _require_same_stat(before, os.fstat(descriptor), "walking directory")
    return entries


def capture_manifest(path: pathlib.Path) -> tuple[str, int, str, tuple[Any, ...]]:
    try:
        root = path.lstat()
    except OSError as error:
        raise EvidenceError(f"cannot inspect capture: {error}") from error
    require(not stat.S_ISLNK(root.st_mode), "capture root is a symlink")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        _require_same_stat(root, opened, "opening root")
        require(stat.S_ISREG(opened.st_mode) or stat.S_ISDIR(opened.st_mode),
                "capture root is not file or directory")
        prefix = bytearray(b"opengothic-gputrace-manifest-v1\0")
        root_identity = _stat_identity(opened)
        if stat.S_ISREG(opened.st_mode):
            require(0 < opened.st_size <= MAX_CAPTURE_BYTES,
                    "capture file size is invalid")
            digest = _file_digest_fd(descriptor, opened, path.name)
            prefix += b"F" + struct.pack("<Q", opened.st_size) + digest
            current = path.lstat()
            _require_same_stat(opened, current, "hashing root")
            return ("file", opened.st_size, sha256(bytes(prefix)),
                    (root_identity,))

        prefix += b"D"
        entries = _capture_directory_entries(descriptor)
        require(entries, "capture directory is empty")
        total = 0
        identities: list[Any] = [root_identity]
        for encoded, kind, metadata, digest in entries:
            require(len(encoded) <= UINT32_MAX, "capture member path is too long")
            prefix += kind.encode("ascii") + struct.pack("<I", len(encoded)) + encoded
            identities.append((encoded, kind, metadata.st_dev, metadata.st_ino,
                               metadata.st_size, metadata.st_mtime_ns))
            if kind == "F":
                require(total <= MAX_CAPTURE_BYTES - metadata.st_size,
                        "capture tree is too large")
                total += metadata.st_size
                prefix += struct.pack("<Q", metadata.st_size) + digest
        require(0 < total <= MAX_CAPTURE_BYTES,
                "capture tree byte count is invalid")
        _require_same_stat(opened, os.fstat(descriptor), "hashing root")
        current = path.lstat()
        _require_same_stat(opened, current, "hashing root")
        return "directory", total, sha256(bytes(prefix)), tuple(identities)
    finally:
        os.close(descriptor)


def stable_capture_manifest(path: pathlib.Path) -> tuple[str, int, str]:
    first = capture_manifest(path)
    second = capture_manifest(path)
    require(first == second, "capture tree changed between checked walks")
    return first[:3]


def _copy_regular_capture(source: int, destination: int,
                          expected: os.stat_result, label: str) -> None:
    _require_same_stat(expected, os.fstat(source), f"opening {label}")
    total = 0
    while True:
        block = os.read(source, 1024 * 1024)
        if not block:
            break
        require(total <= MAX_CAPTURE_BYTES - len(block),
                "capture tree is too large")
        total += len(block)
        offset = 0
        while offset < len(block):
            offset += os.write(destination, block[offset:])
    _require_same_stat(expected, os.fstat(source), f"copying {label}")
    os.fchmod(destination, 0o600)
    os.fsync(destination)


def _copy_capture_directory(source: int, destination: int,
                            relative: bytes = b"") -> None:
    before = os.fstat(source)
    encoded_names: list[tuple[bytes, str]] = []
    for name in os.listdir(source):
        encoded = name.encode("utf-8", "strict")
        require(encoded not in (b"", b".", b"..") and b"/" not in encoded and
                b"\0" not in encoded, "capture member path is unsafe")
        encoded_names.append((encoded, name))
    encoded_names.sort()
    for encoded_name, name in encoded_names:
        encoded = encoded_name if not relative else relative + b"/" + encoded_name
        label = encoded.decode("utf-8")
        metadata = os.stat(name, dir_fd=source, follow_symlinks=False)
        require(not stat.S_ISLNK(metadata.st_mode),
                f"capture member is a symlink: {label}")
        if stat.S_ISDIR(metadata.st_mode):
            child_source = os.open(
                name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=source)
            os.mkdir(name, 0o700, dir_fd=destination)
            child_destination = os.open(
                name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=destination)
            try:
                _require_same_stat(metadata, os.fstat(child_source), f"opening {label}")
                _copy_capture_directory(child_source, child_destination, encoded)
                _require_same_stat(metadata, os.fstat(child_source), f"copying {label}")
                os.fchmod(child_destination, 0o700)
                os.fsync(child_destination)
            finally:
                os.close(child_destination)
                os.close(child_source)
        elif stat.S_ISREG(metadata.st_mode):
            child_source = os.open(
                name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=source)
            child_destination = os.open(
                name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC |
                os.O_NOFOLLOW, 0o600, dir_fd=destination)
            try:
                _copy_regular_capture(child_source, child_destination, metadata, label)
            finally:
                os.close(child_destination)
                os.close(child_source)
            current = os.stat(name, dir_fd=source, follow_symlinks=False)
            _require_same_stat(metadata, current, f"copying {label}")
        else:
            raise EvidenceError(f"capture member is special: {label}")
    after_names = sorted(name.encode("utf-8", "strict")
                         for name in os.listdir(source))
    require(after_names == [encoded for encoded, _ in encoded_names],
            "capture directory changed while copying")
    _require_same_stat(before, os.fstat(source), "copying directory")


def clone_capture_no_follow(source: pathlib.Path,
                            destination_parent: pathlib.Path) -> pathlib.Path:
    """Copy a capture into a private sibling without following source links."""
    source_parent = os.open(source.parent, os.O_RDONLY | os.O_DIRECTORY |
                            os.O_CLOEXEC | os.O_NOFOLLOW)
    destination_directory = os.open(
        destination_parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC |
        os.O_NOFOLLOW)
    private_name = f".{CAPTURE_LEAF}.{os.getpid()}.{secrets.token_hex(16)}.commit"
    private_path = destination_parent / private_name
    try:
        metadata = os.stat(source.name, dir_fd=source_parent,
                           follow_symlinks=False)
        require(not stat.S_ISLNK(metadata.st_mode), "capture root is a symlink")
        if stat.S_ISREG(metadata.st_mode):
            source_descriptor = os.open(
                source.name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=source_parent)
            destination_descriptor = os.open(
                private_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                os.O_CLOEXEC | os.O_NOFOLLOW, 0o600,
                dir_fd=destination_directory)
            try:
                _copy_regular_capture(source_descriptor, destination_descriptor,
                                      metadata, source.name)
            finally:
                os.close(destination_descriptor)
                os.close(source_descriptor)
        else:
            require(stat.S_ISDIR(metadata.st_mode),
                    "capture root is not file or directory")
            source_descriptor = os.open(
                source.name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC |
                os.O_NOFOLLOW, dir_fd=source_parent)
            os.mkdir(private_name, 0o700, dir_fd=destination_directory)
            destination_descriptor = os.open(
                private_name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC |
                os.O_NOFOLLOW, dir_fd=destination_directory)
            try:
                _require_same_stat(metadata, os.fstat(source_descriptor),
                                   "opening root")
                _copy_capture_directory(source_descriptor, destination_descriptor)
                _require_same_stat(metadata, os.fstat(source_descriptor),
                                   "copying root")
                os.fchmod(destination_descriptor, 0o700)
                os.fsync(destination_descriptor)
            finally:
                os.close(destination_descriptor)
                os.close(source_descriptor)
        os.fsync(destination_directory)
        current = os.stat(source.name, dir_fd=source_parent,
                          follow_symlinks=False)
        _require_same_stat(metadata, current, "copying root")
        return private_path
    finally:
        os.close(destination_directory)
        os.close(source_parent)


def validate_scene_resource(value: Any, proof_id: str, width: int,
                            height: int) -> dict[str, Any]:
    resource = exact_object(value, (
        "label", "textureRef", "allocationID", "resourceIndex",
        "pixelFormat", "textureType", "storageMode", "mipLevel",
        "arraySlice",
    ), "sceneResource")
    exact_string(resource["label"], "RendererIOS.SceneHDR." + proof_id,
                 "sceneResource.label")
    matching_string(resource["textureRef"], re.compile(r"@tex(?:0|[1-9][0-9]*)\Z"),
                    "sceneResource.textureRef")
    matching_string(resource["allocationID"], POSITIVE_RE,
                    "sceneResource.allocationID")
    matching_string(resource["resourceIndex"], re.compile(r"0x[0-9a-f]+\Z"),
                    "sceneResource.resourceIndex")
    exact_string(resource["pixelFormat"], "RG11B10Float", "sceneResource.pixelFormat")
    exact_string(resource["textureType"], "2D", "sceneResource.textureType")
    exact_string(resource["storageMode"], "Private", "sceneResource.storageMode")
    exact_int(resource["mipLevel"], 0, "sceneResource.mipLevel")
    exact_int(resource["arraySlice"], 0, "sceneResource.arraySlice")
    require(0 < width <= MAX_TEXTURE_EXTENT and 0 < height <= MAX_TEXTURE_EXTENT,
            "scene resource extent is invalid")
    return resource


def validate_command(value: Any, proof_id: str,
                     resource: dict[str, Any]) -> dict[str, Any]:
    command = exact_object(value, ("commandBuffer", "scene", "proofBlit", "toneResolve"),
                           "command")
    cb = matching_string(command["commandBuffer"], re.compile(r"cb(?:0|[1-9][0-9]*)\Z"),
                         "command.commandBuffer")
    scene = exact_object(command["scene"],
                         ("childIndex", "encoderPath", "marker", "attachment"),
                         "command.scene")
    proof = exact_object(command["proofBlit"],
                         ("childIndex", "encoderPath", "marker", "commandPath",
                          "sourceTextureRef", "sourceLevel", "sourceSlice"),
                         "command.proofBlit")
    tone = exact_object(command["toneResolve"],
                        ("childIndex", "encoderPath", "marker", "drawPath",
                         "fragmentTextureIndex", "textureRef"),
                        "command.toneResolve")
    indices = [bounded_int(item["childIndex"], f"command child index {index}",
                           0, UINT32_MAX)
               for index, item in enumerate((scene, proof, tone))]
    require(indices[0] < indices[1] < indices[2],
            "command child indices are not strictly increasing")
    scene_match = RENDER_PATH_RE.fullmatch(printable(scene["encoderPath"], "scene encoder path"))
    proof_match = BLIT_PATH_RE.fullmatch(printable(proof["encoderPath"], "proof encoder path"))
    tone_match = RENDER_PATH_RE.fullmatch(printable(tone["encoderPath"], "tone encoder path"))
    blit_match = BLIT_COMMAND_RE.fullmatch(printable(proof["commandPath"], "proof command path"))
    draw_match = DRAW_PATH_RE.fullmatch(printable(tone["drawPath"], "tone draw path"))
    require(all(match is not None for match in
                (scene_match, proof_match, tone_match, blit_match, draw_match)),
            "command path grammar is invalid")
    assert scene_match and proof_match and tone_match and blit_match and draw_match
    require({scene_match.group(1), proof_match.group(1), tone_match.group(1),
             blit_match.group(1), draw_match.group(1)} == {cb},
            "command paths do not share one command buffer")
    require(blit_match.group(2) == proof_match.group(2),
            "proof blit command escaped its encoder")
    require(draw_match.group(2) == tone_match.group(2),
            "tone draw escaped its encoder")
    exact_string(scene["marker"], "RendererIOS.SceneHDR." + proof_id,
                 "command.scene.marker")
    exact_string(scene["attachment"], "color0", "command.scene.attachment")
    exact_string(proof["marker"], "RendererIOS.HDRProofCopy." + proof_id,
                 "command.proofBlit.marker")
    exact_string(proof["sourceTextureRef"], resource["textureRef"],
                 "command.proofBlit.sourceTextureRef")
    exact_int(proof["sourceLevel"], 0, "command.proofBlit.sourceLevel")
    exact_int(proof["sourceSlice"], 0, "command.proofBlit.sourceSlice")
    exact_string(tone["marker"], "RendererIOS.ToneResolve." + proof_id,
                 "command.toneResolve.marker")
    exact_int(tone["fragmentTextureIndex"], 0,
              "command.toneResolve.fragmentTextureIndex")
    exact_string(tone["textureRef"], resource["textureRef"],
                 "command.toneResolve.textureRef")
    return command


def validate_numeric(value: Any, width: int, height: int) -> dict[str, Any]:
    numeric = exact_object(value, (
        "encoding", "maximumX", "maximumY", "maximumChannel",
        "packedWord", "valueHex", "aboveOne",
    ), "numeric")
    exact_string(numeric["encoding"], "packed-rg11b10float-le", "numeric.encoding")
    bounded_int(numeric["maximumX"], "numeric.maximumX", 0, width - 1)
    bounded_int(numeric["maximumY"], "numeric.maximumY", 0, height - 1)
    require(numeric["maximumChannel"] in ("r", "g", "b"),
            "numeric.maximumChannel is invalid")
    matching_string(numeric["packedWord"], re.compile(r"0x[0-9a-f]{8}\Z"),
                    "numeric.packedWord")
    raw_hex = matching_string(numeric["valueHex"], FLOAT_HEX_RE,
                              "numeric.valueHex")
    try:
        maximum = float.fromhex(raw_hex)
    except ValueError as error:
        raise EvidenceError("numeric.valueHex cannot be parsed") from error
    require(math.isfinite(maximum) and maximum > 1.0,
            "numeric maximum does not prove finite HDR above one")
    require(numeric["aboveOne"] is True, "numeric.aboveOne must be true")
    return numeric


def expected_filenames(command: dict[str, Any]) -> dict[str, str]:
    cb = command["commandBuffer"][2:]
    scene_re = RENDER_PATH_RE.fullmatch(command["scene"]["encoderPath"])
    proof_be = BLIT_PATH_RE.fullmatch(command["proofBlit"]["encoderPath"])
    proof_blit = BLIT_COMMAND_RE.fullmatch(command["proofBlit"]["commandPath"])
    tone_re = RENDER_PATH_RE.fullmatch(command["toneResolve"]["encoderPath"])
    assert scene_re and proof_be and proof_blit and tone_re
    return {
        "version": "gpudebug-version.txt", "open": "gpudebug-open.json",
        "commands": "commands.json", "command-buffer": f"cb-{cb}.json",
        "scene-encoder": f"scene-re-{scene_re.group(2)[2:]}.json",
        "scene-color0": "scene-color0.json",
        "proof-encoder": f"proof-be-{proof_be.group(2)[2:]}.json",
        "proof-blit": f"proof-blit-{proof_blit.group(3)[4:]}.json",
        "tone-encoder": f"tone-re-{tone_re.group(2)[2:]}.json",
        "tone-fragment": "tone-fragment.json", "tone-tex0": "tone-tex0.json",
        "scene-resource": "scene-resource.json",
        "terminate": "gpudebug-terminate.txt",
        "sessions-after": "gpudebug-sessions-after.txt",
    }


def parse_session(raw: bytes) -> str:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError("gpudebug open transcript is not UTF-8") from error
    matches = SESSION_RE.findall(text)
    require(len(matches) == 1, "gpudebug startup did not publish exactly one session ID")
    return matches[0]


def expected_argv(role: str, command: dict[str, Any], capture: pathlib.Path,
                  session: str, resource: dict[str, Any]) -> list[str]:
    scene = command["scene"]["encoderPath"]
    proof_encoder = command["proofBlit"]["encoderPath"]
    proof_blit = command["proofBlit"]["commandPath"]
    tone_encoder = command["toneResolve"]["encoderPath"]
    tone_draw = command["toneResolve"]["drawPath"]
    values = {
        "version": [GPUDEBUG, "--version"],
        "open": [GPUDEBUG, "--json", "-t", str(capture), "--timeout", "120", "-c", "list"],
        "commands": [GPUDEBUG, "--json", "-s", session, "-c", "go commands", "-c", "list --all"],
        "command-buffer": [GPUDEBUG, "--json", "-s", session, "-c", f"go commands/{command['commandBuffer']}", "-c", "list --all"],
        "scene-encoder": [GPUDEBUG, "--json", "-s", session, "-c", f"go {scene}", "-c", "list --all"],
        "scene-color0": [GPUDEBUG, "--json", "-s", session, "-c", f"go {scene}/color0", "-c", "info"],
        "proof-encoder": [GPUDEBUG, "--json", "-s", session, "-c", f"go {proof_encoder}", "-c", "list --all"],
        "proof-blit": [GPUDEBUG, "--json", "-s", session, "-c", f"go {proof_blit}", "-c", "info"],
        "tone-encoder": [GPUDEBUG, "--json", "-s", session, "-c", f"go {tone_encoder}", "-c", "list --all"],
        "tone-fragment": [GPUDEBUG, "--json", "-s", session, "-c", f"go {tone_draw}/fragment", "-c", "info"],
        "tone-tex0": [GPUDEBUG, "--json", "-s", session, "-c", f"go {tone_draw}/fragment/tex0", "-c", "info"],
        "scene-resource": [GPUDEBUG, "--json", "-s", session, "-c", f"go {resource['textureRef']}", "-c", "info"],
        "terminate": [GPUDEBUG, "--terminate", session],
        "sessions-after": [GPUDEBUG, "--list-sessions"],
    }
    return values[role]


def transcript_manifest(entries: list[dict[str, Any]], directory: pathlib.Path) -> str:
    stream = bytearray(b"opengothic-gpudebug-transcripts-v1\0")
    for entry in entries:
        role = entry["role"].encode("ascii")
        name = entry["file"].encode("ascii")
        argv = [argument.encode("ascii") for argument in entry["argv"]]
        raw = regular_bytes(directory / entry["file"],
                            f"transcript {entry['role']}", MAX_TRANSCRIPT_BYTES, True)
        stream += struct.pack("<I", len(role)) + role
        stream += struct.pack("<I", len(name)) + name
        stream += struct.pack("<I", len(argv))
        for argument in argv:
            stream += struct.pack("<I", len(argument)) + argument
        stream += struct.pack("<Q", len(raw)) + raw
    return sha256(bytes(stream))


def validate_transcripts(value: Any, command: dict[str, Any], resource: dict[str, Any],
                         directory: pathlib.Path | None = None,
                         capture: pathlib.Path | None = None,
                         width: int | None = None,
                         height: int | None = None) -> list[dict[str, Any]]:
    require(isinstance(value, list) and len(value) == len(ROLE_ORDER),
            "transcripts must contain exact 14 entries")
    names = expected_filenames(command)
    entries: list[dict[str, Any]] = []
    raws: dict[str, bytes] = {}
    for index, raw_entry in enumerate(value):
        role = ROLE_ORDER[index]
        entry = exact_object(raw_entry, ("role", "file", "argv", "bytes", "sha256"),
                             f"transcripts[{index}]")
        exact_string(entry["role"], role, f"transcripts[{index}].role")
        matching_string(entry["file"], SAFE_BASENAME_RE, f"transcripts[{index}].file")
        exact_string(entry["file"], names[role], f"transcripts[{index}].file")
        require(isinstance(entry["argv"], list) and entry["argv"],
                f"transcripts[{index}].argv is empty")
        for argument_index, argument in enumerate(entry["argv"]):
            printable(argument, f"transcripts[{index}].argv[{argument_index}]")
        exact_string(entry["argv"][0], GPUDEBUG, f"transcripts[{index}].argv[0]")
        bounded_int(entry["bytes"], f"transcripts[{index}].bytes", 1,
                    MAX_TRANSCRIPT_BYTES)
        matching_string(entry["sha256"], H64_RE, f"transcripts[{index}].sha256")
        if directory is not None:
            raw = regular_bytes(directory / entry["file"], f"transcript {role}",
                                MAX_TRANSCRIPT_BYTES, True)
            require(len(raw) == entry["bytes"] and sha256(raw) == entry["sha256"],
                    f"transcript {role} bytes/hash mismatch")
            raws[role] = raw
        entries.append(entry)
    if directory is None:
        return entries
    assert capture is not None and width is not None and height is not None
    require(raws["version"] == GPUDEBUG_VERSION, "gpudebug version is not byte-exact 1.0")
    session = parse_session(raws["open"])
    for entry in entries:
        require(entry["argv"] == expected_argv(entry["role"], command, capture,
                                                session, resource),
                f"transcript argv differs for role {entry['role']}")
    require(session.encode("ascii") not in raws["sessions-after"],
            "owned gpudebug session remains after terminate")
    scene_color = raws["scene-color0"]
    exact_scene_color = {
        "label": resource["label"], "textureRef": resource["textureRef"],
        "allocationID": resource["allocationID"],
        "resourceIndex": resource["resourceIndex"],
        "pixelFormat": resource["pixelFormat"],
        "textureType": resource["textureType"],
        "storageMode": resource["storageMode"],
        "width": width, "height": height, "mipLevel": 0, "arraySlice": 0,
    }
    for field, expected in exact_scene_color.items():
        require(_one_field(scene_color, field, "scene color0") == expected,
                f"scene color0 {field} differs from exact resource/extent")
    for role in ("tone-tex0", "scene-resource"):
        for field in ("textureRef", "allocationID", "resourceIndex"):
            require(_one_field(raws[role], field, role) == resource[field],
                    f"{role} {field} differs from canonical resource")
    semantic = {
        "command-buffer": (
            command["scene"]["encoderPath"], command["scene"]["marker"],
            command["proofBlit"]["encoderPath"], command["proofBlit"]["marker"],
            command["toneResolve"]["encoderPath"], command["toneResolve"]["marker"],
        ),
        "scene-encoder": (command["scene"]["marker"], "color0", resource["textureRef"]),
        "scene-color0": (resource["textureRef"], resource["allocationID"],
                           resource["resourceIndex"], resource["pixelFormat"],
                           resource["textureType"], resource["storageMode"]),
        "proof-encoder": (command["proofBlit"]["marker"], command["proofBlit"]["commandPath"]),
        "proof-blit": (resource["textureRef"], "sourceLevel", "0", "sourceSlice"),
        "tone-encoder": (command["toneResolve"]["marker"], command["toneResolve"]["drawPath"]),
        "tone-fragment": ("fragmentTextureIndex", "0", resource["textureRef"]),
        "tone-tex0": (resource["textureRef"], resource["allocationID"], resource["resourceIndex"]),
        "scene-resource": (resource["textureRef"], resource["allocationID"], resource["resourceIndex"]),
    }
    for role, tokens in semantic.items():
        text = raws[role].decode("utf-8", "strict")
        for token in tokens:
            require(token in text, f"transcript {role} does not derive token {token!r}")
    ordered_text = raws["command-buffer"].decode("utf-8", "strict")
    positions = [ordered_text.find(command[key]["marker"])
                 for key in ("scene", "proofBlit", "toneResolve")]
    require(all(position >= 0 for position in positions) and positions == sorted(positions),
            "command-buffer transcript does not prove ordered render/blit/render triple")
    return entries


def validate_document(document: Any) -> dict[str, Any]:
    root = exact_object(document, (
        "schemaVersion", "evidenceClass", "producer", "source", "runIdentity",
        "extent", "sceneResource", "command", "numeric", "transcripts",
    ), "root")
    exact_int(root["schemaVersion"], SCHEMA_VERSION, "schemaVersion")
    exact_string(root["evidenceClass"], EVIDENCE_CLASS, "evidenceClass")
    exact_string(root["producer"], PRODUCER, "producer")
    source = exact_object(root["source"], (
        "tool", "toolVersion", "captureFile", "captureKind", "captureBytes",
        "captureManifestSha256", "captureCopySummarySha256",
        "captureEvidenceCommitted", "artifactBytes", "artifactSha256",
        "runtimeLogBytes", "runtimeLogSha256", "transcriptManifestSha256",
    ), "source")
    exact_string(source["tool"], GPUDEBUG, "source.tool")
    exact_string(source["toolVersion"], "1.0", "source.toolVersion")
    exact_string(source["captureFile"], CAPTURE_LEAF, "source.captureFile")
    require(source["captureKind"] in ("file", "directory"),
            "source.captureKind is invalid")
    bounded_int(source["captureBytes"], "source.captureBytes", 1, MAX_CAPTURE_BYTES)
    for key in ("captureManifestSha256", "captureCopySummarySha256",
                "artifactSha256", "runtimeLogSha256", "transcriptManifestSha256"):
        matching_string(source[key], H64_RE, f"source.{key}")
    require(source["captureEvidenceCommitted"] is True,
            "source.captureEvidenceCommitted must be true")
    bounded_int(source["artifactBytes"], "source.artifactBytes", 1, UINT64_MAX)
    bounded_int(source["runtimeLogBytes"], "source.runtimeLogBytes", 1, UINT64_MAX)

    identity = exact_object(root["runIdentity"],
                            ("proofId", "buildSha", "targetGeneration", "snapshotSequence"),
                            "runIdentity")
    proof_id = matching_string(identity["proofId"], H32_RE, "runIdentity.proofId")
    matching_string(identity["buildSha"], H40_RE, "runIdentity.buildSha")
    bounded_int(identity["targetGeneration"], "runIdentity.targetGeneration", 1, UINT64_MAX)
    bounded_int(identity["snapshotSequence"], "runIdentity.snapshotSequence", 1, UINT64_MAX)
    extent = exact_object(root["extent"],
                          ("width", "height", "rowBytes", "logicalBytes"), "extent")
    width = bounded_int(extent["width"], "extent.width", 1, MAX_TEXTURE_EXTENT)
    height = bounded_int(extent["height"], "extent.height", 1, MAX_TEXTURE_EXTENT)
    row = bounded_int(extent["rowBytes"], "extent.rowBytes", 1, UINT32_MAX)
    logical = bounded_int(extent["logicalBytes"], "extent.logicalBytes", 1, UINT64_MAX)
    require(row == width * 4 and logical == row * height,
            "extent row/logical byte layout is not exact packed RG11B10")
    resource = validate_scene_resource(root["sceneResource"], proof_id, width, height)
    command = validate_command(root["command"], proof_id, resource)
    validate_numeric(root["numeric"], width, height)
    validate_transcripts(root["transcripts"], command, resource)
    return root


def load_artifact_validator() -> Any:
    path = pathlib.Path(__file__).resolve().with_name("validate-linear-hdr-proof-artifact.py")
    specification = importlib.util.spec_from_file_location("linear_hdr_artifact_for_gpu", path)
    require(specification is not None and specification.loader is not None,
            "cannot load proof artifact validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


def matching_capture_marker(log_raw: bytes, proof_id: str) -> tuple[str, int, bytes]:
    try:
        lines = log_raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise EvidenceError("runtime log is not UTF-8") from error
    terminals = [line for line in lines
                 if line.startswith("RendererIOS HDR capture: v=1 ")]
    require(len(terminals) == 1, "runtime log lacks one sticky capture terminal")
    line = terminals[0]
    parsed = CAPTURE_SUCCESS_RE.fullmatch(line)
    require(parsed is not None or CAPTURE_FAILURE_RE.fullmatch(line) is not None,
            "runtime log contains malformed capture terminal")
    require(parsed is not None and parsed.group(1) == proof_id,
            "runtime log lacks exact matching capture terminal=C")
    return parsed.group(2), int(parsed.group(3)), (line + "\n").encode("ascii")


def validate_join(document: Any, capture: pathlib.Path, summary_path: pathlib.Path,
                  artifact_path: pathlib.Path, runtime_log_path: pathlib.Path,
                  transcript_dir: pathlib.Path, expected_sha: str) -> dict[str, Any]:
    root = validate_document(document)
    matching_string(expected_sha, H40_RE, "expected SHA")
    source = root["source"]
    identity = root["runIdentity"]
    require(identity["buildSha"] == expected_sha, "expected SHA does not join evidence")
    kind, capture_bytes, manifest_sha = stable_capture_manifest(capture)
    require((kind, capture_bytes, manifest_sha) ==
            (source["captureKind"], source["captureBytes"], source["captureManifestSha256"]),
            "capture manifest differs from evidence")

    artifact_raw = regular_bytes(artifact_path, "numeric artifact", 300 * 1024 * 1024)
    log_raw = regular_bytes(runtime_log_path, "runtime log", 64 * 1024 * 1024)
    require((len(artifact_raw), sha256(artifact_raw)) ==
            (source["artifactBytes"], source["artifactSha256"]),
            "artifact bytes/hash differs from evidence")
    require((len(log_raw), sha256(log_raw)) ==
            (source["runtimeLogBytes"], source["runtimeLogSha256"]),
            "runtime log bytes/hash differs from evidence")
    artifact = load_artifact_validator().validate(artifact_path, runtime_log_path,
                                                   expected_sha)
    extent = root["extent"]
    joins = {
        "id": identity["proofId"], "build": identity["buildSha"],
        "generation": identity["targetGeneration"], "sequence": identity["snapshotSequence"],
        "width": extent["width"], "height": extent["height"],
        "row": extent["rowBytes"], "bytes": extent["logicalBytes"],
    }
    for key, expected in joins.items():
        require(artifact[key] == expected, f"numeric artifact {key} does not join evidence")
    numeric = root["numeric"]
    for key in ("maximumX", "maximumY", "maximumChannel", "packedWord", "valueHex"):
        require(artifact[key] == numeric[key], f"numeric full scan {key} differs from evidence")
    require(artifact["maximum"] > 1.0, "numeric full scan maximum is not above one")

    marker_kind, marker_bytes, marker_raw = matching_capture_marker(log_raw, identity["proofId"])
    require((marker_kind, marker_bytes) == (kind, capture_bytes),
            "capture marker kind/bytes differs from copied capture")
    summary_raw = regular_bytes(summary_path, "capture copy summary", MAX_EVIDENCE_BYTES, True)
    try:
        summary = json.loads(summary_raw.decode("ascii"), object_pairs_hook=unique_object,
                             parse_constant=reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"capture copy summary is invalid: {error}") from error
    require(summary_raw == canonical_json_bytes(summary),
            "capture copy summary is not canonical")
    exact_object(summary, ("schemaVersion", "proofId", "file", "kind", "bytes",
                           "manifestSha256", "runtimeMarkerSha256", "evidenceCommitted"),
                 "capture copy summary")
    exact_int(summary["schemaVersion"], 1, "capture copy summary schemaVersion")
    require(summary == {
        "schemaVersion": 1, "proofId": identity["proofId"], "file": CAPTURE_LEAF,
        "kind": kind, "bytes": capture_bytes, "manifestSha256": manifest_sha,
        "runtimeMarkerSha256": sha256(marker_raw), "evidenceCommitted": True,
    }, "capture copy summary does not join capture/runtime marker")
    require(sha256(summary_raw) == source["captureCopySummarySha256"],
            "capture copy summary hash differs from evidence")

    entries = validate_transcripts(root["transcripts"], root["command"],
                                   root["sceneResource"], transcript_dir, capture,
                                   extent["width"], extent["height"])
    require(transcript_manifest(entries, transcript_dir) ==
            source["transcriptManifestSha256"],
            "transcript manifest differs from evidence")
    return root


def _scalar_values(value: Any, key: str) -> list[Any]:
    results: list[Any] = []
    if isinstance(value, dict):
        for name, child in value.items():
            if name == key and isinstance(child, (str, int)) and not isinstance(child, bool):
                results.append(child)
            results.extend(_scalar_values(child, key))
    elif isinstance(value, list):
        for child in value:
            results.extend(_scalar_values(child, key))
    return results


def _json(raw: bytes, label: str) -> Any:
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                          parse_constant=reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} is not exact gpudebug JSON: {error}") from error


def _one_field(raw: bytes, key: str, label: str) -> Any:
    values = _scalar_values(_json(raw, label), key)
    require(len(values) == 1, f"{label} does not expose exactly one {key}")
    return values[0]


def _one_path(raw: bytes, pattern: re.Pattern[str], marker: str, label: str) -> str:
    document = _json(raw, label)
    candidates: list[str] = []
    def visit(value: Any) -> None:
        if isinstance(value, dict):
            encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
            paths = [child for key, child in value.items()
                     if key in ("path", "encoderPath", "commandPath", "drawPath") and
                     isinstance(child, str) and pattern.fullmatch(child)]
            if marker in encoded:
                candidates.extend(paths)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(document)
    candidates = sorted(set(candidates))
    require(len(candidates) == 1, f"{label} does not expose one marker-bound path")
    return candidates[0]


def collector_command_timeout(deadline: float, now: float | None = None) -> float:
    current = time.monotonic() if now is None else now
    remaining = deadline - current
    require(remaining >= COLLECTOR_MINIMUM_TIMEOUT_SECONDS,
            "collector deadline has less than one second remaining")
    return min(COLLECTOR_COMMAND_TIMEOUT_SECONDS, remaining)


def _kill_owned_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        process.wait(timeout=2.0)


def run_collector_command(argv: list[str], deadline: float) -> bytes:
    require(argv and argv[0] == GPUDEBUG, "collector argv escaped owned gpudebug")
    timeout = collector_command_timeout(deadline)
    command_deadline = min(deadline, time.monotonic() + timeout)
    process = subprocess.Popen(
        argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
    )
    assert process.stdout is not None and process.stderr is not None
    output = {"stdout": bytearray(), "stderr": bytearray()}
    selector = selectors.DefaultSelector()
    try:
        for stream, role in ((process.stdout, "stdout"),
                             (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream.fileno(), selectors.EVENT_READ, role)
        while selector.get_map():
            remaining = command_deadline - time.monotonic()
            if remaining <= 0.0:
                _kill_owned_process_group(process)
                raise subprocess.TimeoutExpired(argv, timeout)
            events = selector.select(min(remaining, 0.25))
            for key, _ in events:
                role = str(key.data)
                room = MAX_TRANSCRIPT_BYTES - len(output[role])
                chunk = os.read(key.fd, min(64 * 1024, room + 1))
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                if len(chunk) > room:
                    _kill_owned_process_group(process)
                    raise EvidenceError(f"gpudebug {role} limit exceeded")
                output[role].extend(chunk)
        remaining = command_deadline - time.monotonic()
        if remaining <= 0.0:
            _kill_owned_process_group(process)
            raise subprocess.TimeoutExpired(argv, timeout)
        try:
            returncode = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            _kill_owned_process_group(process)
            raise
    except BaseException:
        if process.poll() is None:
            _kill_owned_process_group(process)
        raise
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()
    stdout = bytes(output["stdout"])
    stderr = bytes(output["stderr"])
    require(returncode == 0, f"gpudebug exited {returncode}")
    require(stderr == b"", "gpudebug emitted stderr")
    require(stdout != b"", "gpudebug emitted empty stdout")
    return stdout


def _transcript_entry(role: str, filename: str, argv: list[str], raw: bytes,
                      directory: pathlib.Path) -> dict[str, Any]:
    atomic_no_clobber(directory / filename, raw)
    return {"role": role, "file": filename, "argv": argv,
            "bytes": len(raw), "sha256": sha256(raw)}


def cleanup_owned_collector_session(
        session: str, transcript_dir: pathlib.Path,
        entries: list[dict[str, Any]], raws: dict[str, bytes],
        overall_deadline: float) -> None:
    """Use only the reserved remainder of the one overall collector budget."""
    failures: list[str] = []
    terminate_argv = [GPUDEBUG, "--terminate", session]
    try:
        raw = run_collector_command(terminate_argv, overall_deadline)
        entries.append(_transcript_entry(
            "terminate", "gpudebug-terminate.txt", terminate_argv, raw,
            transcript_dir))
        raws["terminate"] = raw
    except (EvidenceError, OSError, subprocess.TimeoutExpired) as error:
        failures.append(f"terminate: {error}")

    sessions_argv = [GPUDEBUG, "--list-sessions"]
    try:
        raw = run_collector_command(sessions_argv, overall_deadline)
        entries.append(_transcript_entry(
            "sessions-after", "gpudebug-sessions-after.txt", sessions_argv,
            raw, transcript_dir))
        raws["sessions-after"] = raw
        require(session.encode("ascii") not in raw,
                "owned gpudebug session remains after terminate")
    except (EvidenceError, OSError, subprocess.TimeoutExpired) as error:
        failures.append(f"sessions-after: {error}")
    require(not failures,
            "BLOCKED: owned gpudebug session termination was not confirmed: " +
            "; ".join(failures))


def collect(capture: pathlib.Path, summary_path: pathlib.Path,
            artifact_path: pathlib.Path, runtime_log_path: pathlib.Path,
            transcript_dir: pathlib.Path, output: pathlib.Path,
            expected_sha: str) -> dict[str, Any]:
    started = time.monotonic()
    main_deadline = started + COLLECTOR_MAIN_TIMEOUT_SECONDS
    overall_deadline = started + COLLECTOR_GLOBAL_TIMEOUT_SECONDS
    binary = pathlib.Path(GPUDEBUG)
    metadata = binary.lstat()
    require(stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode) and
            os.access(binary, os.X_OK), "owned /usr/bin/gpudebug is not regular executable")
    require(transcript_dir.is_dir() and not transcript_dir.is_symlink(),
            "transcript directory is invalid")
    require(not any(transcript_dir.iterdir()),
            "transcript directory is not empty")
    artifact = load_artifact_validator().validate(artifact_path, runtime_log_path,
                                                   expected_sha)
    proof_id = str(artifact["id"])
    scene_marker = "RendererIOS.SceneHDR." + proof_id
    proof_marker = "RendererIOS.HDRProofCopy." + proof_id
    tone_marker = "RendererIOS.ToneResolve." + proof_id
    entries: list[dict[str, Any]] = []
    raws: dict[str, bytes] = {}
    session: str | None = None
    cleanup_error: EvidenceError | None = None

    def invoke(role: str, filename: str, argv: list[str]) -> bytes:
        raw = run_collector_command(argv, main_deadline)
        entries.append(_transcript_entry(role, filename, argv, raw, transcript_dir))
        raws[role] = raw
        return raw

    try:
        version = invoke("version", "gpudebug-version.txt", [GPUDEBUG, "--version"])
        require(version == GPUDEBUG_VERSION, "gpudebug version is not byte-exact 1.0")
        open_argv = [GPUDEBUG, "--json", "-t", str(capture),
                     "--timeout", "120", "-c", "list"]
        opened = run_collector_command(open_argv, main_deadline)
        try:
            session = parse_session(opened)
        except EvidenceError as error:
            raise EvidenceError(
                f"BLOCKED: owned gpudebug session identity is ambiguous: {error}") from error
        entries.append(_transcript_entry(
            "open", "gpudebug-open.json", open_argv, opened, transcript_dir))
        raws["open"] = opened
        commands = invoke("commands", "commands.json",
                          [GPUDEBUG, "--json", "-s", session, "-c", "go commands", "-c", "list --all"])
        cb_path = _one_path(commands, re.compile(r"commands/cb(?:0|[1-9][0-9]*)\Z"),
                            scene_marker, "commands")
        cb = cb_path.rsplit("/", 1)[1]
        command_buffer = invoke("command-buffer", f"cb-{cb[2:]}.json",
                                [GPUDEBUG, "--json", "-s", session, "-c", f"go {cb_path}", "-c", "list --all"])
        scene_path = _one_path(command_buffer, RENDER_PATH_RE, scene_marker, "command buffer")
        proof_path = _one_path(command_buffer, BLIT_PATH_RE, proof_marker, "command buffer")
        tone_path = _one_path(command_buffer, RENDER_PATH_RE, tone_marker, "command buffer")
        scene_re = scene_path.rsplit("/", 1)[1]
        proof_be = proof_path.rsplit("/", 1)[1]
        tone_re = tone_path.rsplit("/", 1)[1]
        scene_encoder = invoke("scene-encoder", f"scene-re-{scene_re[2:]}.json",
                               [GPUDEBUG, "--json", "-s", session, "-c", f"go {scene_path}", "-c", "list --all"])
        scene_color = invoke("scene-color0", "scene-color0.json",
                             [GPUDEBUG, "--json", "-s", session, "-c", f"go {scene_path}/color0", "-c", "info"])
        proof_encoder = invoke("proof-encoder", f"proof-be-{proof_be[2:]}.json",
                               [GPUDEBUG, "--json", "-s", session, "-c", f"go {proof_path}", "-c", "list --all"])
        blit_path = _one_path(proof_encoder, BLIT_COMMAND_RE, proof_marker, "proof encoder")
        blit = blit_path.rsplit("/", 1)[1]
        proof_blit = invoke("proof-blit", f"proof-blit-{blit[4:]}.json",
                            [GPUDEBUG, "--json", "-s", session, "-c", f"go {blit_path}", "-c", "info"])
        tone_encoder = invoke("tone-encoder", f"tone-re-{tone_re[2:]}.json",
                              [GPUDEBUG, "--json", "-s", session, "-c", f"go {tone_path}", "-c", "list --all"])
        draw_path = _one_path(tone_encoder, DRAW_PATH_RE, tone_marker, "tone encoder")
        tone_fragment = invoke("tone-fragment", "tone-fragment.json",
                               [GPUDEBUG, "--json", "-s", session, "-c", f"go {draw_path}/fragment", "-c", "info"])
        tone_tex0 = invoke("tone-tex0", "tone-tex0.json",
                           [GPUDEBUG, "--json", "-s", session, "-c", f"go {draw_path}/fragment/tex0", "-c", "info"])
        texture_ref = str(_one_field(scene_color, "textureRef", "scene color0"))
        scene_resource = invoke("scene-resource", "scene-resource.json",
                                [GPUDEBUG, "--json", "-s", session, "-c", f"go {texture_ref}", "-c", "info"])
    finally:
        if session is not None:
            try:
                cleanup_owned_collector_session(
                    session,transcript_dir,entries,raws,overall_deadline)
            except EvidenceError as error:
                cleanup_error = error
        if cleanup_error is not None:
            raise cleanup_error

    allocation_id = str(_one_field(scene_color, "allocationID", "scene color0"))
    resource_index = str(_one_field(scene_color, "resourceIndex", "scene color0"))
    scene_identity = {
        "textureRef": texture_ref, "allocationID": allocation_id,
        "resourceIndex": resource_index,
    }
    require(str(_one_field(scene_color, "label", "scene color0")) == scene_marker,
            "scene color0 label differs from proof identity")
    require(int(_one_field(scene_color, "width", "scene color0")) == artifact["width"] and
            int(_one_field(scene_color, "height", "scene color0")) == artifact["height"],
            "scene color0 extent differs from numeric artifact")
    require(int(_one_field(scene_color, "mipLevel", "scene color0")) == 0 and
            int(_one_field(scene_color, "arraySlice", "scene color0")) == 0,
            "scene color0 subresource is not mip0/slice0")
    for role_raw, label in ((tone_tex0, "tone tex0"),
                            (scene_resource, "scene resource")):
        for field, expected in scene_identity.items():
            require(str(_one_field(role_raw, field, label)) == expected,
                    f"{label} {field} differs from scene color0")
    require(str(_one_field(proof_blit, "sourceTextureRef", "proof blit")) == texture_ref,
            "proof blit source differs from scene resource")
    require(str(_one_field(tone_fragment, "textureRef", "tone fragment")) == texture_ref,
            "tone fragment tex[0] differs from scene resource")
    kind, capture_bytes, manifest_sha = stable_capture_manifest(capture)
    summary_raw = regular_bytes(summary_path, "capture copy summary", MAX_EVIDENCE_BYTES, True)
    artifact_raw = regular_bytes(artifact_path, "numeric artifact", 300 * 1024 * 1024)
    log_raw = regular_bytes(runtime_log_path, "runtime log", 64 * 1024 * 1024)
    command = {
        "commandBuffer": cb,
        "scene": {"childIndex": int(scene_re[2:]), "encoderPath": scene_path,
                  "marker": scene_marker, "attachment": "color0"},
        "proofBlit": {"childIndex": int(proof_be[2:]), "encoderPath": proof_path,
                      "marker": proof_marker, "commandPath": blit_path,
                      "sourceTextureRef": texture_ref,
                      "sourceLevel": int(_one_field(proof_blit, "sourceLevel", "proof blit")),
                      "sourceSlice": int(_one_field(proof_blit, "sourceSlice", "proof blit"))},
        "toneResolve": {"childIndex": int(tone_re[2:]), "encoderPath": tone_path,
                        "marker": tone_marker, "drawPath": draw_path,
                        "fragmentTextureIndex": int(_one_field(tone_fragment, "fragmentTextureIndex", "tone fragment")),
                        "textureRef": texture_ref},
    }
    resource = {
        "label": scene_marker, "textureRef": texture_ref,
        "allocationID": allocation_id, "resourceIndex": resource_index,
        "pixelFormat": str(_one_field(scene_color, "pixelFormat", "scene color0")),
        "textureType": str(_one_field(scene_color, "textureType", "scene color0")),
        "storageMode": str(_one_field(scene_color, "storageMode", "scene color0")),
        "mipLevel": 0, "arraySlice": 0,
    }
    document = {
        "schemaVersion": 2, "evidenceClass": EVIDENCE_CLASS, "producer": PRODUCER,
        "source": {
            "tool": GPUDEBUG, "toolVersion": "1.0", "captureFile": CAPTURE_LEAF,
            "captureKind": kind, "captureBytes": capture_bytes,
            "captureManifestSha256": manifest_sha,
            "captureCopySummarySha256": sha256(summary_raw),
            "captureEvidenceCommitted": True,
            "artifactBytes": len(artifact_raw), "artifactSha256": sha256(artifact_raw),
            "runtimeLogBytes": len(log_raw), "runtimeLogSha256": sha256(log_raw),
            "transcriptManifestSha256": transcript_manifest(entries, transcript_dir),
        },
        "runIdentity": {"proofId": artifact["id"], "buildSha": artifact["build"],
                        "targetGeneration": artifact["generation"],
                        "snapshotSequence": artifact["sequence"]},
        "extent": {"width": artifact["width"], "height": artifact["height"],
                   "rowBytes": artifact["row"], "logicalBytes": artifact["bytes"]},
        "sceneResource": resource, "command": command,
        "numeric": {"encoding": "packed-rg11b10float-le",
                    "maximumX": artifact["maximumX"], "maximumY": artifact["maximumY"],
                    "maximumChannel": artifact["maximumChannel"],
                    "packedWord": artifact["packedWord"], "valueHex": artifact["valueHex"],
                    "aboveOne": True},
        "transcripts": entries,
    }
    validate_document(document)
    validate_join(document, capture, summary_path, artifact_path, runtime_log_path,
                  transcript_dir, expected_sha)
    atomic_no_clobber(output, canonical_json_bytes(document))
    return document


def commit_capture_copy(staging: pathlib.Path, destination: pathlib.Path,
                        summary_path: pathlib.Path, runtime_log_path: pathlib.Path,
                        expected_kind: str | None = None) -> dict[str, Any]:
    require(staging.name == CAPTURE_LEAF and destination.name == CAPTURE_LEAF,
            "capture copy uses a non-fixed leaf")
    kind, checked_bytes, manifest_sha = stable_capture_manifest(staging)
    if expected_kind is not None:
        require(expected_kind in ("file", "directory") and kind == expected_kind,
                "device/local capture root kind differs")
    log_raw = regular_bytes(runtime_log_path, "runtime log", 64 * 1024 * 1024)
    terminal_lines = [line for line in log_raw.decode("utf-8", "strict").splitlines()
                      if line.startswith("RendererIOS HDR capture: v=1 ")]
    require(len(terminal_lines) == 1,
            "capture copy lacks one sticky capture terminal")
    terminal_line = terminal_lines[0]
    parsed = CAPTURE_SUCCESS_RE.fullmatch(terminal_line)
    require(parsed is not None or CAPTURE_FAILURE_RE.fullmatch(terminal_line) is not None,
            "capture copy contains malformed capture terminal")
    require(parsed is not None, "capture copy lacks exact capture terminal=C")
    marker_raw = (terminal_line + "\n").encode("ascii")
    proof_id, marker_kind, marker_bytes = parsed.group(1), parsed.group(2), int(parsed.group(3))
    require((marker_kind, marker_bytes) == (kind, checked_bytes),
            "device marker kind/bytes differs from staged capture")
    require(not destination.exists() and not destination.is_symlink(),
            "capture destination already exists")
    private_copy = clone_capture_no_follow(staging, destination.parent)
    private_kind, private_bytes, private_manifest = stable_capture_manifest(private_copy)
    require((private_kind, private_bytes, private_manifest) ==
            (kind, checked_bytes, manifest_sha),
            "descriptor-copied capture differs from verified staging")
    rename_no_clobber(private_copy, destination, "capture")
    fsync_directory(destination.parent)
    committed_kind, committed_bytes, committed_manifest = stable_capture_manifest(destination)
    require((committed_kind, committed_bytes, committed_manifest) ==
            (kind, checked_bytes, manifest_sha), "committed capture changed")
    summary = {"schemaVersion": 1, "proofId": proof_id, "file": CAPTURE_LEAF,
               "kind": kind, "bytes": checked_bytes, "manifestSha256": manifest_sha,
               "runtimeMarkerSha256": sha256(marker_raw), "evidenceCommitted": True}
    atomic_no_clobber(summary_path, canonical_json_bytes(summary))
    return summary


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--validate", action="store_true")
    mode.add_argument("--collect", action="store_true")
    mode.add_argument("--commit-capture-copy", action="store_true")
    parser.add_argument("--evidence", type=pathlib.Path)
    parser.add_argument("--capture", type=pathlib.Path)
    parser.add_argument("--capture-staging", type=pathlib.Path)
    parser.add_argument("--capture-summary", type=pathlib.Path)
    parser.add_argument("--artifact", type=pathlib.Path)
    parser.add_argument("--runtime-log", type=pathlib.Path)
    parser.add_argument("--transcript-dir", type=pathlib.Path)
    parser.add_argument("--expected-sha")
    parser.add_argument("--expected-capture-kind", choices=("file", "directory"))
    parser.add_argument("--allow-synthetic-fixture", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        if arguments.commit_capture_copy:
            require(arguments.capture_staging is not None and arguments.capture is not None and
                    arguments.capture_summary is not None and arguments.runtime_log is not None and
                    arguments.expected_capture_kind is not None,
                    "capture copy commit arguments are incomplete")
            commit_capture_copy(arguments.capture_staging, arguments.capture,
                                arguments.capture_summary, arguments.runtime_log,
                                arguments.expected_capture_kind)
            return 0
        require(arguments.expected_capture_kind is None,
                "expected capture kind is valid only for capture-copy commit")
        require(arguments.evidence is not None, "evidence path is required")
        if arguments.collect:
            require(all(value is not None for value in
                        (arguments.capture, arguments.capture_summary, arguments.artifact,
                         arguments.runtime_log, arguments.transcript_dir,
                         arguments.expected_sha)), "collector arguments are incomplete")
            collect(arguments.capture, arguments.capture_summary, arguments.artifact,
                    arguments.runtime_log, arguments.transcript_dir,
                    arguments.evidence, arguments.expected_sha)
            print("GPU PASS")
            return 0
        document = load_document(arguments.evidence,
                                 canonical=not arguments.allow_synthetic_fixture)
        validate_document(document)
        if arguments.allow_synthetic_fixture:
            require(all(value is None for value in
                        (arguments.capture, arguments.capture_summary, arguments.artifact,
                         arguments.runtime_log, arguments.transcript_dir,
                         arguments.expected_sha)),
                    "synthetic fixture cannot be joined to device files")
            print("SYNTHETIC CONTRACT PASS")
            return 0
        require(all(value is not None for value in
                    (arguments.capture, arguments.capture_summary, arguments.artifact,
                     arguments.runtime_log, arguments.transcript_dir,
                     arguments.expected_sha)), "device join arguments are incomplete")
        validate_join(document, arguments.capture, arguments.capture_summary,
                      arguments.artifact, arguments.runtime_log,
                      arguments.transcript_dir, arguments.expected_sha)
        print("GPU PASS")
        return 0
    except (EvidenceError, OSError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
