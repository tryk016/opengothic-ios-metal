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
COLLECTOR_SESSION_SETTLE_SECONDS = 1.0
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
    "scene-color0", "proof-encoder", "proof-group", "proof-blit",
    "tone-encoder", "tone-group", "tone-draw", "tone-fragment",
    "tone-tex0", "scene-resource", "terminate", "sessions-after",
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
BLIT_COMMAND_RE = re.compile(
    r"commands/(cb(?:0|[1-9][0-9]*))/(be(?:0|[1-9][0-9]*))/"
    r"grp(?:0|[1-9][0-9]*)/(blit(?:0|[1-9][0-9]*))\Z"
)
DRAW_PATH_RE = re.compile(
    r"commands/(cb(?:0|[1-9][0-9]*))/(re(?:0|[1-9][0-9]*))/"
    r"grp(?:0|[1-9][0-9]*)/draw(?:0|[1-9][0-9]*)\Z"
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
SESSION_RE = re.compile(r"Session ([1-9][0-9]*) created\.\Z")
OTHER_SESSIONS_RE = re.compile(
    r"([1-9][0-9]*) other (session|sessions) active\.\Z"
)
SESSION_LIST_HEADER_RE = re.compile(
    r"ID {2,}Trace {2,}Device {2,}Replayer {2,}Lifetime\Z"
)
SESSION_LIST_ROW_RE = re.compile(
    r"([1-9][0-9]*) {2,}(\S(?:.*?\S)?) {2,}"
    r"(\S(?:.*?\S)?) {2,}([A-Za-z][A-Za-z0-9._-]*) {2,}"
    r"(\S(?:.*\S)?)\Z"
)
SESSION_LIST_FOOTER_RE = re.compile(r"\(([1-9][0-9]*) (session|sessions)\)\Z")


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
    proof_group = command["proofBlit"]["commandPath"].rsplit("/", 2)[-2]
    tone_group, tone_draw = command["toneResolve"]["drawPath"].rsplit("/", 1)
    tone_group = tone_group.rsplit("/", 1)[1]
    return {
        "version": "gpudebug-version.txt", "open": "gpudebug-open.json",
        "commands": "commands.json", "command-buffer": f"cb-{cb}.json",
        "scene-encoder": f"scene-re-{scene_re.group(2)[2:]}.json",
        "scene-color0": "scene-color0.json",
        "proof-encoder": f"proof-be-{proof_be.group(2)[2:]}.json",
        "proof-group": f"proof-grp-{proof_group[3:]}.json",
        "proof-blit": f"proof-blit-{proof_blit.group(3)[4:]}.json",
        "tone-encoder": f"tone-re-{tone_re.group(2)[2:]}.json",
        "tone-group": f"tone-grp-{tone_group[3:]}.json",
        "tone-draw": f"tone-draw-{tone_draw[4:]}.json",
        "tone-fragment": "tone-fragment.json", "tone-tex0": "tone-tex0.json",
        "scene-resource": "scene-resource.json",
        "terminate": "gpudebug-terminate.txt",
        "sessions-after": "gpudebug-sessions-after.txt",
    }


def _canonical_count_value(value: Any, singular: str, plural: str,
                           label: str) -> int:
    text = printable(value, label)
    match = re.fullmatch(
        rf"([1-9][0-9]*) ({re.escape(singular)}|{re.escape(plural)})", text)
    require(match is not None, f"{label} has invalid count grammar")
    count = int(match.group(1))
    noun = match.group(2)
    require((count == 1 and noun == singular) or
            (count > 1 and noun == plural),
            f"{label} has noncanonical singular/plural grammar")
    return count


def _validate_open_root(document: Any) -> None:
    root = exact_object(document, ("children", "totalCount"),
                        "gpudebug open root")
    children = root["children"]
    require(isinstance(children, list),
            "gpudebug open root children are not an array")
    exact_int(root["totalCount"], len(children),
              "gpudebug open root.totalCount")
    expected = (
        ("commands", "go"),
        ("performance", ""),
        ("api_calls", "go"),
        ("resources", "go"),
    )
    require(len(children) == len(expected),
            "gpudebug open root does not expose the exact canonical children")
    values: dict[str, str] = {}
    for index, ((name, actions), child_value) in enumerate(zip(expected, children)):
        child = exact_object(child_value, ("actions", "name", "values"),
                             f"gpudebug open root child {index}")
        exact_string(child["name"], name,
                     f"gpudebug open root child {index}.name")
        exact_string(child["actions"], actions,
                     f"gpudebug open root child {index}.actions")
        child_values = child["values"]
        require(isinstance(child_values, list) and len(child_values) == 1,
                f"gpudebug open root child {index}.values is not exact")
        item = exact_object(child_values[0], ("type", "value"),
                            f"gpudebug open root child {index}.values[0]")
        exact_string(item["type"], "string",
                     f"gpudebug open root child {index}.values[0].type")
        values[name] = printable(
            item["value"], f"gpudebug open root child {index}.values[0].value")
    _canonical_count_value(values["commands"], "command buffer",
                           "command buffers", "gpudebug open commands value")
    exact_string(values["performance"], "see 'profile ?'",
                 "gpudebug open performance value")
    _canonical_count_value(values["api_calls"], "API call", "API calls",
                           "gpudebug open api_calls value")
    _canonical_count_value(values["resources"], "object", "objects",
                           "gpudebug open resources value")


def parse_session(raw: bytes) -> str:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError("gpudebug open transcript is not UTF-8") from error
    require(text.endswith("\n") and "\r" not in text,
            "gpudebug open transcript does not use exact LF lines")
    lines = text.splitlines(keepends=True)
    require(len(lines) >= 3,
            "gpudebug startup transcript is incomplete")
    match = SESSION_RE.fullmatch(lines[0][:-1])
    require(match is not None,
            "gpudebug startup did not publish one canonical session ID")
    session = match.group(1)
    index = 1
    other = OTHER_SESSIONS_RE.fullmatch(lines[index][:-1])
    if other is not None:
        count = int(other.group(1))
        noun = other.group(2)
        require((count == 1 and noun == "session") or
                (count > 1 and noun == "sessions"),
                "gpudebug startup other-session count is noncanonical")
        index += 1
    require(index < len(lines) and
            lines[index] ==
            f"gpudebug -s {session} -c <command> to send commands.\n",
            "gpudebug startup command hint is invalid")
    payload = "".join(lines[index + 1:]).encode("utf-8")
    documents, _ = _json_documents(payload, "gpudebug open payload", 1)
    _validate_open_root(documents[0])
    return session


def validate_terminate(raw: bytes, session: str) -> None:
    expected = f"Session {session} terminated.\n".encode("ascii")
    require(raw == expected, "gpudebug terminate transcript is not byte-exact")


def listed_session_ids(raw: bytes) -> set[str]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError("gpudebug session listing is not UTF-8") from error
    require(text.endswith("\n") and "\r" not in text,
            "gpudebug session listing does not use exact LF lines")
    if text == "No active sessions.\n":
        return set()
    lines = text[:-1].split("\n")
    require(len(lines) >= 3 and SESSION_LIST_HEADER_RE.fullmatch(lines[0]) is not None,
            "gpudebug session listing header is invalid")
    footer = SESSION_LIST_FOOTER_RE.fullmatch(lines[-1])
    require(footer is not None, "gpudebug session listing footer is invalid")
    rows = lines[1:-1]
    count = int(footer.group(1))
    noun = footer.group(2)
    require(count == len(rows) and
            ((count == 1 and noun == "session") or
             (count > 1 and noun == "sessions")),
            "gpudebug session listing count is invalid")
    sessions: set[str] = set()
    for row in rows:
        match = SESSION_LIST_ROW_RE.fullmatch(row)
        require(match is not None, "gpudebug session listing row is invalid")
        require(all(32 <= ord(character) <= 126 for character in row),
                "gpudebug session listing row is not printable ASCII")
        session = match.group(1)
        require(session not in sessions, "gpudebug session listing repeats an ID")
        sessions.add(session)
    return sessions


def expected_argv(role: str, command: dict[str, Any], capture: pathlib.Path,
                  session: str, resource: dict[str, Any]) -> list[str]:
    scene = command["scene"]["encoderPath"]
    proof_encoder = command["proofBlit"]["encoderPath"]
    proof_blit = command["proofBlit"]["commandPath"]
    tone_encoder = command["toneResolve"]["encoderPath"]
    tone_draw = command["toneResolve"]["drawPath"]
    proof_group = proof_blit.rsplit("/", 1)[0]
    tone_group = tone_draw.rsplit("/", 1)[0]
    values = {
        "version": [GPUDEBUG, "--version"],
        "open": [GPUDEBUG, "--json", "-t", str(capture), "--timeout", "120", "-c", "list"],
        "commands": [GPUDEBUG, "--json", "-s", session, "-c", "go commands", "-c", "list --all"],
        "command-buffer": [GPUDEBUG, "--json", "-s", session, "-c", f"go commands/{command['commandBuffer']}", "-c", "list --all"],
        "scene-encoder": [GPUDEBUG, "--json", "-s", session, "-c", f"go {scene}", "-c", "list --all"],
        "scene-color0": [GPUDEBUG, "--json", "-s", session, "-c", f"info {scene}/color0"],
        "proof-encoder": [GPUDEBUG, "--json", "-s", session, "-c", f"go {proof_encoder}", "-c", "list --all"],
        "proof-group": [GPUDEBUG, "--json", "-s", session, "-c",
                        f"go {proof_group}", "-c", "list --all"],
        "proof-blit": [GPUDEBUG, "--json", "-s", session, "-c", f"info {proof_blit}"],
        "tone-encoder": [GPUDEBUG, "--json", "-s", session, "-c", f"go {tone_encoder}", "-c", "list --all"],
        "tone-group": [GPUDEBUG, "--json", "-s", session, "-c",
                       f"go {tone_group}", "-c", "list --all"],
        "tone-draw": [GPUDEBUG, "--json", "-s", session, "-c",
                      f"go {tone_draw}", "-c", "list --all"],
        "tone-fragment": [GPUDEBUG, "--json", "-s", session, "-c",
                          f"go {tone_draw}/fragment", "-c", "list --all"],
        "tone-tex0": [GPUDEBUG, "--json", "-s", session, "-c",
                      f"info {tone_draw}/fragment/tex[0]"],
        "scene-resource": [GPUDEBUG, "--json", "-s", session, "-c", f"info {resource['textureRef']}"],
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
            "transcripts must contain exact 17 entries")
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
    validate_terminate(raws["terminate"], session)
    for entry in entries:
        require(entry["argv"] == expected_argv(entry["role"], command, capture,
                                                session, resource),
                f"transcript argv differs for role {entry['role']}")
    require(session not in listed_session_ids(raws["sessions-after"]),
            "owned gpudebug session remains after terminate")
    cb_path = _command_buffer_path(raws["commands"])
    require(cb_path == "commands/" + command["commandBuffer"],
            "commands transcript selected a different command buffer")
    scene_path, proof_path, tone_path = _encoder_paths(
        raws["command-buffer"], cb_path, command["scene"]["marker"],
        command["proofBlit"]["marker"], command["toneResolve"]["marker"])
    require((scene_path, proof_path, tone_path) ==
            (command["scene"]["encoderPath"], command["proofBlit"]["encoderPath"],
             command["toneResolve"]["encoderPath"]),
            "command-buffer transcript paths differ from evidence")

    scene_listing = _navigable_json(raws["scene-encoder"], "scene encoder")
    scene_ref, scene_width, scene_height, scene_format = _texture_binding(
        scene_listing, "color0", resource["label"], "scene color0 binding")
    require((scene_ref, scene_width, scene_height, scene_format) ==
            (resource["textureRef"], width, height, resource["pixelFormat"]),
            "scene color0 binding differs from resource/extent")
    expected_info = {
        "label": resource["label"], "allocationID": resource["allocationID"],
        "resourceIndex": resource["resourceIndex"],
        "pixelFormat": resource["pixelFormat"],
        "textureType": resource["textureType"],
        "storageMode": resource["storageMode"], "width": width, "height": height,
    }
    require(_resource_info(_direct_info_json(raws["scene-color0"], "scene color0"),
                           "scene color0") == expected_info,
            "scene color0 info differs from canonical resource")

    proof_group = _one_group_path(
        raws["proof-encoder"], proof_path, command["proofBlit"]["marker"],
        "proof encoder")
    blit_path = _proof_group_command_path(raws["proof-group"], proof_group)
    proof_ref, proof_info = _proof_blit_result(
        raws["proof-blit"], resource["label"])
    require(blit_path == command["proofBlit"]["commandPath"] and
            proof_ref == resource["textureRef"],
            "proof blit transcript differs from evidence resource/path")
    for field, expected in (("sourceLevel", command["proofBlit"]["sourceLevel"]),
                            ("sourceSlice", command["proofBlit"]["sourceSlice"])):
        observed = str(_document_one_field(proof_info, field, "proof blit"))
        require(UINT_RE.fullmatch(observed) is not None and int(observed) == expected,
                f"proof blit {field} differs from evidence")
    require(str(_document_one_field(proof_info, "sourceSize", "proof blit")) ==
            f"{width}x{height}x1", "proof blit source extent differs")

    tone_group = _one_group_path(
        raws["tone-encoder"], tone_path, command["toneResolve"]["marker"],
        "tone encoder")
    draw_path = _tone_group_draw_path(raws["tone-group"], tone_group)
    fragment_path = _tone_draw_fragment_path(raws["tone-draw"], draw_path)
    require(fragment_path == draw_path + "/fragment",
            "tone draw fragment path is invalid")
    tone_ref, texture_index, tone_width, tone_height = _tone_fragment_result(
        raws["tone-fragment"], resource["label"])
    require((draw_path, tone_ref, texture_index, tone_width, tone_height) ==
            (command["toneResolve"]["drawPath"], resource["textureRef"],
             command["toneResolve"]["fragmentTextureIndex"], width, height),
            "tone fragment transcript differs from evidence resource/path/extent")
    for role in ("tone-tex0", "scene-resource"):
        require(_resource_info(_direct_info_json(raws[role], role), role) == expected_info,
                f"{role} info differs from canonical resource")
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


def _json_documents(raw: bytes, label: str,
                    expected_count: int) -> tuple[list[Any], list[str]]:
    try:
        text = raw.decode("utf-8")
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} is not exact gpudebug JSON: {error}") from error
    require("\r" not in text, f"{label} gpudebug JSON does not use exact LF lines")
    decoder = json.JSONDecoder(object_pairs_hook=unique_object,
                               parse_constant=reject_constant)
    documents: list[Any] = []
    fragments: list[str] = []
    offset = 0
    try:
        for _ in range(expected_count):
            document, end = decoder.raw_decode(text, offset)
            require(isinstance(document, dict),
                    f"{label} gpudebug JSON document is not an object")
            documents.append(document)
            fragments.append(text[offset:end])
            require(end < len(text) and text[end] == "\n",
                    f"{label} gpudebug JSON document lacks exact LF terminator")
            offset = end + 1
    except json.JSONDecodeError as error:
        raise EvidenceError(f"{label} is not exact gpudebug JSON: {error}") from error
    require(offset == len(text),
            f"{label} does not contain exactly {expected_count} gpudebug JSON documents")
    return documents, fragments


def _navigable_json(raw: bytes, label: str) -> Any:
    documents, fragments = _json_documents(raw, label, 2)
    require(fragments[0] == fragments[1] and documents[0] == documents[1],
            f"{label} go/list gpudebug JSON documents differ")
    return documents[1]


def _direct_info_json(raw: bytes, label: str) -> Any:
    documents, _ = _json_documents(raw, label, 1)
    return documents[0]


def _document_one_field(document: Any, key: str, label: str) -> Any:
    values = _scalar_values(document, key)
    require(len(values) == 1, f"{label} does not expose exactly one {key}")
    return values[0]


def _listing_children(document: Any, label: str) -> list[dict[str, Any]]:
    require(isinstance(document, dict), f"{label} listing is not an object")
    require(set(document) in ({"children", "totalCount"},
                              {"children", "links", "totalCount"}),
            f"{label} listing keys are invalid")
    children = document["children"]
    require(isinstance(children, list), f"{label} children are not an array")
    exact_int(document["totalCount"], len(children), f"{label}.totalCount")
    if "links" in document:
        links = document["links"]
        require(isinstance(links, dict) and
                all(isinstance(key, str) and isinstance(value, str)
                    for key, value in links.items()),
                f"{label} links are invalid")
    result: list[dict[str, Any]] = []
    for index, child in enumerate(children):
        require(isinstance(child, dict) and
                set(child) in ({"actions", "name"},
                               {"actions", "name", "values"}),
                f"{label} child {index} keys are invalid")
        printable(child["actions"], f"{label} child {index} actions")
        printable(child["name"], f"{label} child {index} name")
        values = child.get("values", [])
        require(isinstance(values, list), f"{label} child {index} values are invalid")
        for value_index, value in enumerate(values):
            if value is None:
                continue
            exact_object(value, ("type", "value"),
                         f"{label} child {index} value {value_index}")
            exact_string(value["type"], "string",
                         f"{label} child {index} value {value_index}.type")
            require(isinstance(value["value"], str),
                    f"{label} child {index} value {value_index}.value is invalid")
        result.append(child)
    return result


def _child_strings(child: dict[str, Any]) -> list[str]:
    return [value["value"] for value in child.get("values", [])
            if isinstance(value, dict)]


def _child_actions(child: dict[str, Any]) -> set[str]:
    actions = child["actions"].split(", ")
    require(actions and all(re.fullmatch(r"[a-z]+", action) is not None
                            for action in actions) and len(set(actions)) == len(actions),
            "gpudebug child actions are noncanonical")
    return set(actions)


def _marker_value_matches(value: str, marker: str,
                          scene_display: bool = False) -> bool:
    expected = f'"{marker} (2)"' if scene_display else f'"{marker}"'
    return value == expected


def _one_matching_child(
        children: list[dict[str, Any]], predicate: Any,
        label: str) -> tuple[int, dict[str, Any]]:
    matches = [(index, child) for index, child in enumerate(children)
               if predicate(child)]
    require(len(matches) == 1, f"{label} does not expose exactly one matching child")
    return matches[0]


def _command_buffer_path(raw: bytes) -> str:
    children = _listing_children(_navigable_json(raw, "commands"), "commands")
    _, child = _one_matching_child(
        children,
        lambda item: "go" in _child_actions(item) and
        re.fullmatch(r"cb(?:0|[1-9][0-9]*)", item["name"]) is not None,
        "commands")
    require(len(children) == 1, "commands exposes more than one command buffer")
    return "commands/" + child["name"]


def _encoder_paths(raw: bytes, cb_path: str, scene_marker: str,
                   proof_marker: str, tone_marker: str) -> tuple[str, str, str]:
    children = _listing_children(
        _navigable_json(raw, "command buffer"), "command buffer")

    def marker_child(marker: str, prefix: str,
                     scene_display: bool = False) -> tuple[int, dict[str, Any]]:
        return _one_matching_child(
            children,
            lambda item: "go" in _child_actions(item) and
            re.fullmatch(prefix + r"(?:0|[1-9][0-9]*)", item["name"]) is not None and
            sum(_marker_value_matches(value, marker, scene_display)
                for value in _child_strings(item)) == 1,
            f"command buffer marker {marker}")

    scene_index, scene = marker_child(scene_marker, "re", True)
    proof_index, proof = marker_child(proof_marker, "be")
    tone_index, tone = marker_child(tone_marker, "re")
    require(scene_index < proof_index < tone_index,
            "command buffer encoder markers are not ordered scene/proof/tone")
    return (f"{cb_path}/{scene['name']}", f"{cb_path}/{proof['name']}",
            f"{cb_path}/{tone['name']}")


def _one_group_path(raw: bytes, encoder_path: str, marker: str,
                    label: str) -> str:
    children = _listing_children(_navigable_json(raw, label), label)
    _, child = _one_matching_child(
        children,
        lambda item: "go" in _child_actions(item) and
        re.fullmatch(r"grp(?:0|[1-9][0-9]*)", item["name"]) is not None and
        sum(_marker_value_matches(value, marker)
            for value in _child_strings(item)) == 1,
        f"{label} marker {marker}")
    return f"{encoder_path}/{child['name']}"


def _texture_binding(document: Any, child_name: str, marker: str,
                     label: str) -> tuple[str, int, int, str]:
    children = _listing_children(document, label)
    _, child = _one_matching_child(
        children, lambda item: item["name"] == child_name and
        "info" in _child_actions(item), label)
    values = _child_strings(child)
    require(len(values) == 2 and values[0] == f'"{marker}"',
            f"{label} texture label is invalid")
    binding = re.fullmatch(
        r"(@tex(?:0|[1-9][0-9]*)) ([1-9][0-9]*)x([1-9][0-9]*) "
        r"([A-Za-z0-9]+)", values[1])
    require(binding is not None, f"{label} texture binding is invalid")
    return (binding.group(1), int(binding.group(2)), int(binding.group(3)),
            binding.group(4))


def _proof_group_command_path(raw: bytes, group_path: str) -> str:
    children = _listing_children(
        _navigable_json(raw, "proof group"), "proof group")
    _, child = _one_matching_child(
        children,
        lambda item: {"go", "info"}.issubset(_child_actions(item)) and
        re.fullmatch(r"blit(?:0|[1-9][0-9]*)", item["name"]) is not None,
        "proof group")
    require(len(children) == 1, "proof group exposes more than one command")
    return f"{group_path}/{child['name']}"


def _proof_blit_result(raw: bytes, scene_marker: str) -> tuple[str, Any]:
    document = _direct_info_json(raw, "proof blit")
    source = str(_document_one_field(document, "sourceTexture", "proof blit"))
    source_match = re.fullmatch(
        rf'(@tex(?:0|[1-9][0-9]*)) "{re.escape(scene_marker)}"', source)
    require(source_match is not None, "proof blit source texture identity is invalid")
    return source_match.group(1), document


def _tone_group_draw_path(raw: bytes, group_path: str) -> str:
    group_children = _listing_children(
        _navigable_json(raw, "tone group"), "tone group")
    _, draw = _one_matching_child(
        group_children,
        lambda item: "go" in _child_actions(item) and
        re.fullmatch(r"draw(?:0|[1-9][0-9]*)", item["name"]) is not None,
        "tone group")
    require(len(group_children) == 1, "tone group exposes more than one draw")
    return f"{group_path}/{draw['name']}"


def _tone_draw_fragment_path(raw: bytes, draw_path: str) -> str:
    draw_children = _listing_children(
        _navigable_json(raw, "tone draw"), "tone draw")
    fragments = [child for child in draw_children
                 if child["name"] == "fragment"]
    require(len(fragments) == 1 and "go" in _child_actions(fragments[0]),
            "tone draw does not expose exactly one navigable fragment")
    return draw_path + "/fragment"


def _tone_fragment_result(raw: bytes,
                          scene_marker: str) -> tuple[str, int, int, int]:
    document = _navigable_json(raw, "tone fragment")
    fragment_children = _listing_children(
        document, "tone fragment")
    texture_names = [child["name"] for child in fragment_children
                     if re.fullmatch(r"tex\[(?:0|[1-9][0-9]*)\]",
                                     child["name"]) is not None]
    require(texture_names == ["tex[0]"],
            "tone fragment does not expose exactly one texture at tex[0]")
    texture_ref, width, height, pixel_format = _texture_binding(
        document, "tex[0]", scene_marker, "tone fragment")
    require(pixel_format == "RG11B10Float",
            "tone fragment texture format is not RG11B10Float")
    return texture_ref, 0, width, height


def _resource_info(document: Any, label: str) -> dict[str, Any]:
    dimensions = str(_document_one_field(document, "dimensions", label))
    match = re.fullmatch(r"([1-9][0-9]*)x([1-9][0-9]*)", dimensions)
    require(match is not None, f"{label} dimensions are invalid")
    return {
        "label": str(_document_one_field(document, "label", label)),
        "allocationID": str(_document_one_field(document, "allocationID", label)),
        "resourceIndex": str(_document_one_field(document, "resourceIndex", label)),
        "pixelFormat": str(_document_one_field(document, "pixelFormat", label)),
        "textureType": str(_document_one_field(document, "textureType", label)),
        "storageMode": str(_document_one_field(document, "storageMode", label)),
        "width": int(match.group(1)), "height": int(match.group(2)),
    }


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


def wait_for_owned_session_absence(
        session: str, argv: list[str], overall_deadline: float) -> bytes:
    while True:
        raw = run_collector_command(argv, overall_deadline)
        if session not in listed_session_ids(raw):
            return raw
        remaining = overall_deadline - time.monotonic()
        require(remaining >= (COLLECTOR_SESSION_SETTLE_SECONDS +
                              COLLECTOR_MINIMUM_TIMEOUT_SECONDS),
                "owned gpudebug session did not settle before cleanup deadline")
        time.sleep(COLLECTOR_SESSION_SETTLE_SECONDS)


def cleanup_owned_collector_session(
        session: str, transcript_dir: pathlib.Path,
        entries: list[dict[str, Any]], raws: dict[str, bytes],
        overall_deadline: float) -> None:
    """Use only the reserved remainder of the one overall collector budget."""
    failures: list[str] = []
    terminate_argv = [GPUDEBUG, "--terminate", session]
    try:
        raw = run_collector_command(terminate_argv, overall_deadline)
        validate_terminate(raw, session)
        entries.append(_transcript_entry(
            "terminate", "gpudebug-terminate.txt", terminate_argv, raw,
            transcript_dir))
        raws["terminate"] = raw
    except (EvidenceError, OSError, subprocess.TimeoutExpired) as error:
        failures.append(f"terminate: {error}")

    sessions_argv = [GPUDEBUG, "--list-sessions"]
    try:
        raw = wait_for_owned_session_absence(
            session, sessions_argv, overall_deadline)
        entries.append(_transcript_entry(
            "sessions-after", "gpudebug-sessions-after.txt", sessions_argv,
            raw, transcript_dir))
        raws["sessions-after"] = raw
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
        cb_path = _command_buffer_path(commands)
        cb = cb_path.rsplit("/", 1)[1]
        command_buffer = invoke("command-buffer", f"cb-{cb[2:]}.json",
                                [GPUDEBUG, "--json", "-s", session, "-c", f"go {cb_path}", "-c", "list --all"])
        scene_path, proof_path, tone_path = _encoder_paths(
            command_buffer, cb_path, scene_marker, proof_marker, tone_marker)
        scene_re = scene_path.rsplit("/", 1)[1]
        proof_be = proof_path.rsplit("/", 1)[1]
        tone_re = tone_path.rsplit("/", 1)[1]
        scene_encoder = invoke("scene-encoder", f"scene-re-{scene_re[2:]}.json",
                               [GPUDEBUG, "--json", "-s", session, "-c", f"go {scene_path}", "-c", "list --all"])
        texture_ref, binding_width, binding_height, binding_format = _texture_binding(
            _navigable_json(scene_encoder, "scene encoder"), "color0",
            scene_marker, "scene color0 binding")
        scene_color = invoke("scene-color0", "scene-color0.json",
                             [GPUDEBUG, "--json", "-s", session, "-c", f"info {scene_path}/color0"])
        proof_encoder = invoke("proof-encoder", f"proof-be-{proof_be[2:]}.json",
                               [GPUDEBUG, "--json", "-s", session, "-c", f"go {proof_path}", "-c", "list --all"])
        proof_group = _one_group_path(
            proof_encoder, proof_path, proof_marker, "proof encoder")
        proof_group_name = proof_group.rsplit("/", 1)[1]
        proof_group_raw = invoke(
            "proof-group", f"proof-grp-{proof_group_name[3:]}.json",
            [GPUDEBUG, "--json", "-s", session, "-c", f"go {proof_group}",
             "-c", "list --all"])
        blit_path = _proof_group_command_path(proof_group_raw, proof_group)
        blit_name = blit_path.rsplit("/", 1)[1]
        proof_blit = invoke(
            "proof-blit", f"proof-blit-{blit_name[4:]}.json",
            [GPUDEBUG, "--json", "-s", session, "-c", f"info {blit_path}"])
        proof_texture_ref, proof_blit_info = _proof_blit_result(
            proof_blit, scene_marker)
        tone_encoder = invoke("tone-encoder", f"tone-re-{tone_re[2:]}.json",
                              [GPUDEBUG, "--json", "-s", session, "-c", f"go {tone_path}", "-c", "list --all"])
        tone_group = _one_group_path(
            tone_encoder, tone_path, tone_marker, "tone encoder")
        tone_group_name = tone_group.rsplit("/", 1)[1]
        tone_group_raw = invoke(
            "tone-group", f"tone-grp-{tone_group_name[3:]}.json",
            [GPUDEBUG, "--json", "-s", session, "-c", f"go {tone_group}",
             "-c", "list --all"])
        draw_path = _tone_group_draw_path(tone_group_raw, tone_group)
        draw_name = draw_path.rsplit("/", 1)[1]
        tone_draw = invoke(
            "tone-draw", f"tone-draw-{draw_name[4:]}.json",
            [GPUDEBUG, "--json", "-s", session, "-c", f"go {draw_path}",
             "-c", "list --all"])
        fragment_path = _tone_draw_fragment_path(tone_draw, draw_path)
        tone_fragment = invoke(
            "tone-fragment", "tone-fragment.json",
            [GPUDEBUG, "--json", "-s", session, "-c", f"go {fragment_path}",
             "-c", "list --all"])
        tone_texture_ref, fragment_texture_index, tone_width, tone_height = (
            _tone_fragment_result(tone_fragment, scene_marker)
        )
        tone_tex0 = invoke("tone-tex0", "tone-tex0.json",
                           [GPUDEBUG, "--json", "-s", session, "-c",
                            f"info {fragment_path}/tex[0]"])
        scene_resource = invoke("scene-resource", "scene-resource.json",
                                [GPUDEBUG, "--json", "-s", session, "-c", f"info {texture_ref}"])
    finally:
        if session is not None:
            try:
                cleanup_owned_collector_session(
                    session, transcript_dir, entries, raws, overall_deadline)
            except EvidenceError as error:
                cleanup_error = error
        if cleanup_error is not None:
            raise cleanup_error

    scene_info = _resource_info(_direct_info_json(scene_color, "scene color0"),
                                "scene color0")
    allocation_id = scene_info["allocationID"]
    resource_index = scene_info["resourceIndex"]
    scene_identity = {
        "allocationID": allocation_id, "resourceIndex": resource_index,
        "label": scene_marker, "pixelFormat": binding_format,
        "textureType": scene_info["textureType"],
        "storageMode": scene_info["storageMode"],
        "width": binding_width, "height": binding_height,
    }
    require(scene_info == scene_identity,
            "scene color0 info differs from listing identity/extent")
    require((binding_width, binding_height) == (artifact["width"], artifact["height"]),
            "scene color0 extent differs from numeric artifact")
    for role_raw, label in ((tone_tex0, "tone tex0"),
                            (scene_resource, "scene resource")):
        require(_resource_info(_direct_info_json(role_raw, label), label) == scene_identity,
                f"{label} differs from scene color0")
    require(proof_texture_ref == texture_ref,
            "proof blit source differs from scene resource")
    require((tone_texture_ref, fragment_texture_index, tone_width, tone_height) ==
            (texture_ref, 0, binding_width, binding_height),
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
                      "sourceLevel": int(_document_one_field(
                          proof_blit_info, "sourceLevel", "proof blit")),
                      "sourceSlice": int(_document_one_field(
                          proof_blit_info, "sourceSlice", "proof blit"))},
        "toneResolve": {"childIndex": int(tone_re[2:]), "encoderPath": tone_path,
                        "marker": tone_marker, "drawPath": draw_path,
                        "fragmentTextureIndex": fragment_texture_index,
                        "textureRef": texture_ref},
    }
    resource = {
        "label": scene_marker, "textureRef": texture_ref,
        "allocationID": allocation_id, "resourceIndex": resource_index,
        "pixelFormat": scene_info["pixelFormat"],
        "textureType": scene_info["textureType"],
        "storageMode": scene_info["storageMode"],
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
