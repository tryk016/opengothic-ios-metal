#!/usr/bin/env python3
"""Fail-closed transport and semantic audit for a private RendererIOS GPU trace."""

from __future__ import annotations

import argparse
import hashlib
import io
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import NoReturn


CAPTURE_NAME = "RendererIOS-pm-clear-v1.gputrace"
SUMMARY_NAME = "capture-summary.txt"
ASSET_NAME = "RendererIOS-pm-clear-v1.tar.gz.gpg"
ENVELOPE_SECRET = "GPUDEBUG_TRACE_ENVELOPE"
TAG_RE = re.compile(r"gpudebug-[A-Za-z0-9._-]{1,100}\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
POSITIVE_INTEGER_RE = re.compile(r"[1-9][0-9]*\Z")
MAX_CAPTURE_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_BYTES = 640 * 1024 * 1024
MAX_SUMMARY_BYTES = 4096
MAX_ARCHIVE_MEMBERS = 65536
MAX_MEMBER_PATH_BYTES = 4096
SUMMARY_KEYS = (
    "capture_name",
    "capture_kind",
    "capture_bytes",
    "capture_manifest_sha256",
)
ENVELOPE_FILES = (
    "passphrase",
    "plain-sha256",
    "cipher-sha256",
    "capture-manifest-sha256",
    "capture-bytes",
    "expected-tag",
    "expected-asset",
)


class ValidationError(RuntimeError):
    pass


class SemanticError(RuntimeError):
    def __init__(self, classification: str, reason: str):
        super().__init__(f"{classification}:{reason}")
        self.classification = classification
        self.reason = reason


@dataclass(frozen=True)
class TarEntry:
    member: tarfile.TarInfo
    parts: tuple[str, ...]


@dataclass(frozen=True)
class APICall:
    index: int
    result: str | None
    receiver: str
    text: str
    method: str


@dataclass(frozen=True)
class AuditTranscripts:
    root: str
    commands: str
    command_buffer: str
    private_encoder: str
    memoryless_encoder: str
    api_calls: str
    private_attachment: str
    memoryless_attachment: str


def _fail(message: str) -> NoReturn:
    raise ValidationError(message)


def _semantic_fail(reason: str) -> NoReturn:
    raise SemanticError("FAIL", reason)


def _semantic_block(reason: str) -> NoReturn:
    raise SemanticError("BLOCKED", reason)


def _require_private_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        _fail("destination directory is missing")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        _fail("destination must be a real directory")
    if info.st_mode & 0o077:
        _fail("destination directory must not be group/world accessible")


def _write_exclusive_private(path: Path, payload: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            descriptor = -1
            stream.write(payload)
            stream.write("\n")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _parse_sha256(value: str, label: str) -> str:
    if SHA256_RE.fullmatch(value) is None:
        _fail(f"{label} is not a lowercase SHA-256")
    return value


def _parse_positive_integer(value: str, label: str, maximum: int) -> int:
    if POSITIVE_INTEGER_RE.fullmatch(value) is None:
        _fail(f"{label} is not a canonical positive integer")
    parsed = int(value)
    if parsed > maximum:
        _fail(f"{label} exceeds the configured limit")
    return parsed


def split_envelope(
    value_environment_name: str,
    directory: Path,
    expected_tag: str,
    expected_asset: str,
) -> None:
    if value_environment_name != ENVELOPE_SECRET:
        _fail("unexpected envelope environment variable")
    if TAG_RE.fullmatch(expected_tag) is None:
        _fail("expected tag has invalid syntax")
    if expected_asset != ASSET_NAME:
        _fail("expected asset name is invalid")
    _require_private_directory(directory)

    raw = os.environ.get(value_environment_name)
    if raw is None or raw == "":
        _fail("envelope environment variable is missing")
    if "\r" in raw or "\x00" in raw:
        _fail("envelope contains forbidden characters")
    lines = raw.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) != len(ENVELOPE_FILES):
        _fail("envelope must contain exactly seven lines")

    passphrase, plain_sha, cipher_sha, manifest_sha, capture_bytes, tag, asset = lines
    if not 24 <= len(passphrase) <= 1024:
        _fail("passphrase length is outside the accepted range")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in passphrase):
        _fail("passphrase contains a control character")
    _parse_sha256(plain_sha, "plain archive digest")
    _parse_sha256(cipher_sha, "cipher digest")
    _parse_sha256(manifest_sha, "capture manifest digest")
    _parse_positive_integer(capture_bytes, "capture byte count", MAX_CAPTURE_BYTES)
    if tag != expected_tag:
        _fail("envelope tag does not match the requested tag")
    if asset != expected_asset:
        _fail("envelope asset does not match the requested asset")

    for filename in ENVELOPE_FILES:
        if (directory / filename).exists() or (directory / filename).is_symlink():
            _fail("envelope destination already exists")
    for filename, value in zip(ENVELOPE_FILES, lines, strict=True):
        _write_exclusive_private(directory / filename, value)


def _safe_member_parts(name: str) -> tuple[str, ...]:
    if not name or name.startswith("/") or "\\" in name:
        _fail("archive member path is not a relative POSIX path")
    try:
        encoded_name = name.encode("utf-8", errors="strict")
    except UnicodeEncodeError as exc:
        raise ValidationError("archive member path is not valid UTF-8") from exc
    if len(encoded_name) > MAX_MEMBER_PATH_BYTES:
        _fail("archive member path is too long")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in name):
        _fail("archive member path contains a control character")
    path = PurePosixPath(name)
    parts = path.parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        _fail("archive member path contains an unsafe component")
    return parts


def _validated_tar_entries(
    archive: tarfile.TarFile,
    expected_capture_bytes: int,
    *,
    max_members: int = MAX_ARCHIVE_MEMBERS,
) -> list[TarEntry]:
    members = archive.getmembers()
    if not members or len(members) > max_members:
        _fail("archive member count is outside the accepted range")

    entries: list[TarEntry] = []
    names: set[str] = set()
    capture_root_seen = False
    summary_seen = False
    capture_regular_files = 0
    capture_bytes = 0
    summary_bytes = 0

    for member in members:
        parts = _safe_member_parts(member.name)
        canonical_name = "/".join(parts)
        if canonical_name in names:
            _fail("archive contains a duplicate path")
        names.add(canonical_name)
        if member.issym() or member.islnk():
            _fail("archive contains a symbolic or hard link")
        if not (member.isdir() or member.isfile()):
            _fail("archive contains a special node")
        if member.size < 0:
            _fail("archive member has a negative size")

        top = parts[0]
        if top not in (CAPTURE_NAME, SUMMARY_NAME):
            _fail("archive contains an unexpected top-level entry")
        if top == SUMMARY_NAME:
            if len(parts) != 1 or not member.isfile():
                _fail("capture summary must be one top-level regular file")
            summary_seen = True
            summary_bytes = member.size
            if summary_bytes <= 0 or summary_bytes > MAX_SUMMARY_BYTES:
                _fail("capture summary size is outside the accepted range")
        else:
            if len(parts) == 1:
                capture_root_seen = True
            if member.isfile():
                capture_regular_files += 1
                capture_bytes += member.size
                if capture_bytes > expected_capture_bytes:
                    _fail("archive capture content exceeds the envelope byte count")
        entries.append(TarEntry(member, parts))

    if not capture_root_seen or not summary_seen:
        _fail("archive does not contain both exact top-level entries")
    capture_root = next(entry.member for entry in entries if entry.parts == (CAPTURE_NAME,))
    if capture_root.isfile() and (
        capture_regular_files != 1
        or any(len(entry.parts) > 1 for entry in entries if entry.parts[0] == CAPTURE_NAME)
    ):
        _fail("flat capture file has unexpected nested content")
    if capture_root.isdir() and capture_regular_files == 0:
        _fail("capture package has no regular-file content")
    if capture_bytes != expected_capture_bytes:
        _fail("archive capture byte count does not match the envelope")
    if capture_bytes <= 0:
        _fail("archive capture content is empty")
    if capture_bytes + summary_bytes > expected_capture_bytes + MAX_SUMMARY_BYTES:
        _fail("archive expanded size exceeds the configured limit")
    return entries


def _make_directory(path: Path) -> None:
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            _fail("archive extraction path collides with a non-directory")


def safe_extract(archive_path: Path, destination: Path, expected_capture_bytes_raw: str) -> None:
    expected_capture_bytes = _parse_positive_integer(
        expected_capture_bytes_raw, "capture byte count", MAX_CAPTURE_BYTES
    )
    try:
        archive_info = archive_path.lstat()
    except FileNotFoundError:
        _fail("plain archive is missing")
    if stat.S_ISLNK(archive_info.st_mode) or not stat.S_ISREG(archive_info.st_mode):
        _fail("plain archive must be a regular non-symlink file")
    if archive_info.st_size <= 0 or archive_info.st_size > MAX_ARCHIVE_BYTES:
        _fail("plain archive size is outside the accepted range")
    if destination.exists() or destination.is_symlink():
        _fail("extraction destination must not already exist")
    _require_private_directory(destination.parent)

    temporary = destination.parent / f".{destination.name}.extracting-{os.getpid()}"
    if temporary.exists() or temporary.is_symlink():
        _fail("temporary extraction destination already exists")
    temporary.mkdir(mode=0o700)
    try:
        with tarfile.open(archive_path, mode="r:gz") as archive:
            entries = _validated_tar_entries(archive, expected_capture_bytes)
            directories = sorted(
                (entry for entry in entries if entry.member.isdir()),
                key=lambda entry: (len(entry.parts), entry.parts),
            )
            for entry in directories:
                _make_directory(temporary.joinpath(*entry.parts))

            for entry in entries:
                if not entry.member.isfile():
                    continue
                target = temporary.joinpath(*entry.parts)
                _make_directory(target.parent)
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(target, flags, 0o600)
                extracted = archive.extractfile(entry.member)
                if extracted is None:
                    os.close(descriptor)
                    _fail("archive regular file has no readable content")
                written = 0
                try:
                    with os.fdopen(descriptor, "wb") as output:
                        descriptor = -1
                        while written < entry.member.size:
                            chunk = extracted.read(min(1024 * 1024, entry.member.size - written))
                            if not chunk:
                                _fail("archive member ended before its declared size")
                            output.write(chunk)
                            written += len(chunk)
                        if extracted.read(1):
                            _fail("archive member exceeds its declared size")
                finally:
                    extracted.close()
                    if descriptor >= 0:
                        os.close(descriptor)
                if written != entry.member.size:
                    _fail("archive member size changed during extraction")
        temporary.rename(destination)
    except (tarfile.TarError, OSError) as exc:
        raise ValidationError("archive could not be safely extracted") from exc
    finally:
        if temporary.exists() or temporary.is_symlink():
            shutil.rmtree(temporary, ignore_errors=True)


def _parse_summary(path: Path) -> dict[str, str]:
    try:
        info = path.lstat()
    except (FileNotFoundError, OSError) as exc:
        raise ValidationError("capture summary is unavailable") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        _fail("capture summary must be a regular non-symlink file")
    if info.st_size <= 0 or info.st_size > MAX_SUMMARY_BYTES:
        _fail("capture summary size is invalid")
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise ValidationError("capture summary is unavailable") from exc
    if len(payload) != info.st_size or b"\r" in payload or b"\x00" in payload:
        _fail("capture summary encoding or size is invalid")
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError("capture summary is not UTF-8") from exc
    if not text.endswith("\n"):
        _fail("capture summary must end with one LF")
    lines = text.splitlines()
    if len(lines) != len(SUMMARY_KEYS):
        _fail("capture summary must contain exactly four fields")
    parsed: dict[str, str] = {}
    for expected_key, line in zip(SUMMARY_KEYS, lines, strict=True):
        if "=" not in line:
            _fail("capture summary line has no separator")
        key, value = line.split("=", 1)
        if key != expected_key or key in parsed or value == "":
            _fail("capture summary schema is not exact")
        parsed[key] = value
    if parsed["capture_name"] != CAPTURE_NAME:
        _fail("capture summary name is invalid")
    if parsed["capture_kind"] not in ("file", "directory"):
        _fail("capture summary kind is invalid")
    _parse_positive_integer(parsed["capture_bytes"], "summary capture bytes", MAX_CAPTURE_BYTES)
    _parse_sha256(parsed["capture_manifest_sha256"], "summary manifest digest")
    return parsed


def verify_manifest(
    transport_summary_path: Path,
    recomputed_summary_path: Path,
    expected_manifest: str,
) -> None:
    expected_manifest = _parse_sha256(expected_manifest, "expected manifest digest")
    transport = _parse_summary(transport_summary_path)
    recomputed = _parse_summary(recomputed_summary_path)
    if transport != recomputed:
        _fail("transport and recomputed capture summaries differ")
    if transport["capture_manifest_sha256"] != expected_manifest:
        _fail("capture manifest does not match the envelope")


SUMMARY_COUNT_RE = re.compile(
    r"^Summary:\s+(\d+) command buffers?,\s+(\d+) encoders?,\s+(\d+) draw calls?\s*$",
    re.MULTILINE,
)
EXPECTED_SUMMARY_RE = re.compile(
    r"^Summary:\s+1 command buffer,\s+2 encoders,\s+0 draw calls\s*$",
    re.MULTILINE,
)
SESSION_RE = re.compile(r"^Session ([1-9][0-9]*) created\.\s*$", re.MULTILINE)
FOOTER_RE = re.compile(r"^\s*\(([0-9]+) items?\)\s*$", re.MULTILINE)
API_ROW_RE = re.compile(
    r"^\s*api([0-9]+)\s+(?:(\S+)\s+)?(\[[^\n]*\])\s+info\s*$",
    re.MULTILINE,
)


def _require_summary(text: str) -> None:
    matches = SUMMARY_COUNT_RE.findall(text)
    if not matches:
        _semantic_block("summary_schema")
    values = {tuple(int(field) for field in match) for match in matches}
    if len(values) != 1:
        _semantic_block("summary_ambiguous")
    if values.pop() != (1, 2, 0):
        _semantic_fail("summary_counts")
    if len(EXPECTED_SUMMARY_RE.findall(text)) != len(matches):
        _semantic_block("summary_exact_schema")


def _table_rows(text: str, pattern: re.Pattern[str]) -> dict[str, str]:
    rows: dict[str, str] = {}
    for match in pattern.finditer(text):
        name = match.group(1)
        row = match.group(0).strip()
        if name in rows:
            _semantic_block("table_duplicate_row")
        rows[name] = row
    return rows


def _require_complete_table(text: str, expected_count: int, reason: str) -> None:
    footer_counts = [int(value) for value in FOOTER_RE.findall(text)]
    if len(footer_counts) != 1:
        _semantic_block(f"{reason}_completeness")
    if footer_counts[0] != expected_count:
        _semantic_fail(f"{reason}_count")


def _require_exact_structure(transcripts: AuditTranscripts) -> None:
    cb_rows = _table_rows(
        transcripts.commands,
        re.compile(r"^\s*([a-z]+[0-9]+)\s+.*$", re.MULTILINE),
    )
    if not cb_rows:
        _semantic_block("command_buffer_table_schema")
    if set(cb_rows) != {"cb0"}:
        _semantic_fail("command_buffer_count")
    _require_complete_table(transcripts.commands, 1, "command_buffer_table")
    if '"RIOS pm-clear CB"' not in cb_rows["cb0"]:
        _semantic_fail("command_buffer_label")

    encoder_rows = _table_rows(
        transcripts.command_buffer,
        re.compile(r"^\s*([a-z]+[0-9]+)\s+.*$", re.MULTILINE),
    )
    if not encoder_rows:
        _semantic_block("encoder_table_schema")
    if set(encoder_rows) != {"re0", "re1"}:
        _semantic_fail("encoder_tree")
    _require_complete_table(transcripts.command_buffer, 2, "encoder_table")
    if '"RIOS private clear"' not in encoder_rows["re0"]:
        _semantic_fail("private_encoder_label")
    if '"RIOS memoryless clear"' not in encoder_rows["re1"]:
        _semantic_fail("memoryless_encoder_label")

    for text, expected_label, expected_object, reason in (
        (
            transcripts.private_encoder,
            '"RIOS private 4x4"',
            "@tex0",
            "private_attachment_tree",
        ),
        (
            transcripts.memoryless_encoder,
            '"RIOS memoryless 4x4"',
            "@tex1",
            "memoryless_attachment_tree",
        ),
    ):
        attachment_rows = _table_rows(
            text,
            re.compile(r"^\s*((?:color[0-9]+)|depth|stencil)\s+.*$", re.MULTILINE),
        )
        if not attachment_rows:
            _semantic_block(f"{reason}_schema")
        if set(attachment_rows) != {"color0"}:
            _semantic_fail(reason)
        _require_complete_table(text, 1, reason)
        if expected_label not in attachment_rows["color0"]:
            _semantic_fail(f"{reason}_label")
        object_ids = re.findall(
            r"(?<![A-Za-z0-9_])@[A-Za-z][A-Za-z0-9_]*",
            attachment_rows["color0"],
        )
        if object_ids != [expected_object]:
            _semantic_fail(f"{reason}_object")


def _method_from_call(call: str) -> str:
    match = re.match(r"^\[[^\s\]]+\s+([^\s\]]+)", call)
    if match is None:
        _semantic_block("api_call_schema")
    return match.group(1).split(":", 1)[0]


def _receiver_from_call(call: str) -> str:
    match = re.match(r"^\[(@[A-Za-z][A-Za-z0-9_]*)\s+", call)
    if match is None:
        _semantic_block("api_receiver_schema")
    return match.group(1)


def _parse_api_calls(text: str) -> list[APICall]:
    rows: dict[int, tuple[str | None, str]] = {}
    matches = list(API_ROW_RE.finditer(text))
    raw_api_rows = re.findall(r"^\s*api[0-9]+(?:\s|$).*$", text, re.MULTILINE)
    if len(matches) != len(raw_api_rows):
        _semantic_block("api_row_schema")
    for match in matches:
        index = int(match.group(1))
        result = match.group(2)
        call = match.group(3)
        if index in rows:
            _semantic_block("api_duplicate_row")
        if result is not None and re.fullmatch(
            r"@[A-Za-z][A-Za-z0-9_]*", result
        ) is None:
            _semantic_block("api_result_schema")
        rows[index] = (result, call)
    if not rows:
        _semantic_block("api_table_schema")
    indexes = sorted(rows)
    if indexes != list(range(len(indexes))):
        _semantic_block("api_table_not_contiguous")
    footer_counts = [int(value) for value in FOOTER_RE.findall(text)]
    if len(footer_counts) != 1:
        _semantic_block("api_footer_schema")
    if footer_counts[0] != len(indexes):
        _semantic_block("api_table_not_proven_complete")
    return [
        APICall(
            index,
            rows[index][0],
            _receiver_from_call(rows[index][1]),
            rows[index][1],
            _method_from_call(rows[index][1]),
        )
        for index in indexes
    ]


def _indices(calls: list[APICall], method: str) -> list[int]:
    return [call.index for call in calls if call.method == method]


def _label_call(calls: list[APICall], label: str) -> APICall:
    needle = f'setLabel:"{label}"'
    matches = [call for call in calls if needle in call.text]
    if len(matches) > 1:
        _semantic_fail("api_label_count")
    if not matches:
        parsed_labels: list[tuple[APICall, str]] = []
        for call in calls:
            if call.method != "setLabel":
                continue
            match = re.search(r'setLabel:(?:@)?"([^"]+)"', call.text)
            if match is None:
                _semantic_block("api_label_schema")
            parsed_labels.append((call, match.group(1)))
        expected = [call for call, value in parsed_labels if value == label]
        if len(expected) != 1:
            _semantic_fail("api_label_value")
        return expected[0]
    return matches[0]


def _require_call_object(
    call: APICall,
    *,
    receiver: str,
    result: str | None,
    reason: str,
) -> None:
    if call.receiver != receiver:
        _semantic_fail(f"{reason}_receiver")
    if call.result != result:
        _semantic_fail(f"{reason}_result")


def _require_api_semantics(text: str) -> dict[str, int]:
    calls = _parse_api_calls(text)
    if len(calls) != 17:
        _semantic_fail("api_call_count")
    forbidden = re.compile(
        r"nextDrawable|present|newLibraryWithSource|newRenderPipelineState|"
        r"newComputePipelineState|setRenderPipelineState|setComputePipelineState|"
        r"draw|dispatch|computeCommandEncoder|blitCommandEncoder|"
        r"parallelRenderCommandEncoder|executeCommands|newCommandQueue",
        re.IGNORECASE,
    )
    if any(forbidden.search(call.method) for call in calls):
        _semantic_fail("forbidden_api_call")

    allowed = {
        "newTextureWithDescriptor",
        "setLabel",
        "commandBufferWithDescriptor",
        "renderCommandEncoderWithDescriptor",
        "endEncoding",
        "status",
        "addCompletedHandler",
        "error",
        "commit",
    }
    unknown = sorted({call.method for call in calls if call.method not in allowed})
    if unknown:
        _semantic_block("unknown_api_schema")

    textures = _indices(calls, "newTextureWithDescriptor")
    command_buffers = _indices(calls, "commandBufferWithDescriptor")
    render_encoders = _indices(calls, "renderCommandEncoderWithDescriptor")
    ends = _indices(calls, "endEncoding")
    statuses = _indices(calls, "status")
    completed_handlers = _indices(calls, "addCompletedHandler")
    errors = _indices(calls, "error")
    commits = _indices(calls, "commit")
    labels = _indices(calls, "setLabel")
    if len(textures) != 2:
        _semantic_fail("texture_allocation_count")
    if len(command_buffers) != 1:
        _semantic_fail("api_command_buffer_count")
    if len(render_encoders) != 2:
        _semantic_fail("render_encoder_count")
    if len(ends) != 2:
        _semantic_fail("end_encoding_count")
    if len(statuses) != 2:
        _semantic_fail("status_count")
    if len(completed_handlers) != 1:
        _semantic_fail("completed_handler_count")
    if len(errors) != 1:
        _semantic_fail("error_count")
    if len(commits) != 1:
        _semantic_fail("commit_count")
    if len(labels) != 5:
        _semantic_fail("set_label_count")

    private_texture_label = _label_call(calls, "RIOS private 4x4")
    memoryless_texture_label = _label_call(calls, "RIOS memoryless 4x4")
    command_buffer_label = _label_call(calls, "RIOS pm-clear CB")
    private_encoder_label = _label_call(calls, "RIOS private clear")
    memoryless_encoder_label = _label_call(calls, "RIOS memoryless clear")

    texture_calls = [calls[index] for index in textures]
    command_buffer_call = calls[command_buffers[0]]
    render_encoder_calls = [calls[index] for index in render_encoders]
    end_calls = [calls[index] for index in ends]
    status_calls = [calls[index] for index in statuses]
    completed_handler_call = calls[completed_handlers[0]]
    error_calls = [calls[index] for index in errors]
    commit_call = calls[commits[0]]
    object_schema: list[tuple[APICall, str, str | None, str, str]] = [
        (
            texture_calls[0],
            "@dev",
            "@tex0",
            "[@dev newTextureWithDescriptor:<descriptor>]",
            "private_factory",
        ),
        (
            texture_calls[1],
            "@dev",
            "@tex1",
            "[@dev newTextureWithDescriptor:<descriptor>]",
            "memoryless_factory",
        ),
        (
            command_buffer_call,
            "@cq",
            "@cb0",
            "[@cq commandBufferWithDescriptor:<descriptor>]",
            "command_buffer_factory",
        ),
        (
            command_buffer_label,
            "@cb0",
            None,
            '[@cb0 setLabel:"RIOS pm-clear CB"]',
            "command_buffer_label",
        ),
        (
            private_texture_label,
            "@tex0",
            None,
            '[@tex0 setLabel:"RIOS private 4x4"]',
            "private_texture_label",
        ),
        (
            memoryless_texture_label,
            "@tex1",
            None,
            '[@tex1 setLabel:"RIOS memoryless 4x4"]',
            "memoryless_texture_label",
        ),
        (
            render_encoder_calls[0],
            "@cb0",
            "@re0",
            "[@cb0 renderCommandEncoderWithDescriptor:<descriptor>]",
            "private_encoder_factory",
        ),
        (
            private_encoder_label,
            "@re0",
            None,
            '[@re0 setLabel:"RIOS private clear"]',
            "private_encoder_label",
        ),
        (
            end_calls[0],
            "@re0",
            None,
            "[@re0 endEncoding]",
            "private_end_encoding",
        ),
        (
            render_encoder_calls[1],
            "@cb0",
            "@re1",
            "[@cb0 renderCommandEncoderWithDescriptor:<descriptor>]",
            "memoryless_encoder_factory",
        ),
        (
            memoryless_encoder_label,
            "@re1",
            None,
            '[@re1 setLabel:"RIOS memoryless clear"]',
            "memoryless_encoder_label",
        ),
        (
            end_calls[1],
            "@re1",
            None,
            "[@re1 endEncoding]",
            "memoryless_end_encoding",
        ),
        (
            status_calls[0],
            "@cb0",
            None,
            "[@cb0 status]",
            "initial_status",
        ),
        (
            completed_handler_call,
            "@cb0",
            None,
            "[@cb0 addCompletedHandler:<handler>]",
            "completed_handler",
        ),
        (commit_call, "@cb0", None, "[@cb0 commit]", "commit"),
        (
            status_calls[1],
            "@cb0",
            None,
            "[@cb0 status]",
            "completion_status",
        ),
        (
            error_calls[0],
            "@cb0",
            None,
            "[@cb0 error]",
            "completion_error",
        ),
    ]
    if [call.index for call, _, _, _, _ in object_schema] != list(range(17)):
        _semantic_fail("api_object_schema_order")
    for call, receiver, result, grammar, reason in object_schema:
        _require_call_object(
            call,
            receiver=receiver,
            result=result,
            reason=reason,
        )
        if call.text != grammar:
            _semantic_block(f"{reason}_grammar")
    ordered = (
        textures[0],
        textures[1],
        command_buffers[0],
        command_buffer_label.index,
        private_texture_label.index,
        memoryless_texture_label.index,
        render_encoders[0],
        private_encoder_label.index,
        ends[0],
        render_encoders[1],
        memoryless_encoder_label.index,
        ends[1],
        statuses[0],
        completed_handlers[0],
        commits[0],
    )
    if list(ordered) != sorted(ordered) or len(set(ordered)) != len(ordered):
        _semantic_fail("api_partial_order")
    if len(statuses) == 2 and statuses[1] <= commits[0]:
        _semantic_fail("completion_status_order")
    if errors:
        if len(statuses) != 2 or errors[0] <= statuses[1]:
            _semantic_fail("completion_error_order")
    return {
        "api_calls": len(calls),
        "texture_allocations": len(textures),
        "command_buffers": len(command_buffers),
        "render_encoders": len(render_encoders),
        "end_encoding": len(ends),
        "status_calls": len(statuses),
        "completed_handlers": len(completed_handlers),
        "error_calls": len(errors),
        "commits": len(commits),
    }


def _field_value(text: str, field_pattern: str, values: tuple[str, ...], reason: str) -> str:
    matching_lines = [
        line
        for line in text.splitlines()
        if re.search(field_pattern, line, flags=re.IGNORECASE)
    ]
    if not matching_lines:
        _semantic_block(f"{reason}_missing")
    found: set[str] = set()
    for line in matching_lines:
        if ":" in line:
            value_region = line.split(":", 1)[1]
        elif "=" in line:
            value_region = line.split("=", 1)[1]
        else:
            value_region = re.sub(
                field_pattern, "", line, count=1, flags=re.IGNORECASE
            )
        for value in values:
            if re.search(
                rf"(?<![A-Za-z])(?:MTL(?:StorageMode|LoadAction|StoreAction))?"
                rf"{re.escape(value)}(?![A-Za-z])",
                value_region,
                re.IGNORECASE,
            ):
                found.add(value)
    if len(found) != 1:
        _semantic_block(f"{reason}_schema")
    return found.pop()


def _require_attachment_info(
    text: str,
    expected_label: str,
    expected_storage: str,
    expected_store: str,
    prefix: str,
) -> dict[str, str]:
    known_labels = ("RIOS private 4x4", "RIOS memoryless 4x4")
    present_labels = {label for label in known_labels if label in text}
    if not present_labels:
        _semantic_block(f"{prefix}_texture_label_missing")
    if present_labels != {expected_label}:
        _semantic_fail(f"{prefix}_texture_label")
    storage = _field_value(
        text,
        r"storage\s*mode|storageMode",
        ("Private", "Memoryless", "Shared", "Managed"),
        f"{prefix}_storage",
    )
    load = _field_value(
        text,
        r"load\s*action|loadAction",
        ("Clear", "Load", "DontCare"),
        f"{prefix}_load",
    )
    store = _field_value(
        text,
        r"store\s*action|storeAction",
        ("StoreAndMultisampleResolve", "MultisampleResolve", "DontCare", "Store"),
        f"{prefix}_store",
    )
    if storage.lower() != expected_storage.lower():
        _semantic_fail(f"{prefix}_storage")
    if load.lower() != "clear":
        _semantic_fail(f"{prefix}_load")
    if store.lower() != expected_store.lower():
        _semantic_fail(f"{prefix}_store")
    return {"storage": storage, "load": load, "store": store}


def analyze_transcripts(transcripts: AuditTranscripts) -> dict[str, str]:
    _require_summary(transcripts.root)
    for text in (
        transcripts.commands,
        transcripts.command_buffer,
        transcripts.private_encoder,
        transcripts.memoryless_encoder,
        transcripts.api_calls,
        transcripts.private_attachment,
        transcripts.memoryless_attachment,
    ):
        if re.search(r"^Summary:", text, flags=re.MULTILINE):
            _require_summary(text)
    _require_exact_structure(transcripts)
    counts = _require_api_semantics(transcripts.api_calls)
    private = _require_attachment_info(
        transcripts.private_attachment,
        "RIOS private 4x4",
        "Private",
        "Store",
        "private",
    )
    memoryless = _require_attachment_info(
        transcripts.memoryless_attachment,
        "RIOS memoryless 4x4",
        "Memoryless",
        "DontCare",
        "memoryless",
    )
    return {
        **{key: str(value) for key, value in counts.items()},
        "private_storage": private["storage"],
        "private_load": private["load"],
        "private_store": private["store"],
        "memoryless_storage": memoryless["storage"],
        "memoryless_load": memoryless["load"],
        "memoryless_store": memoryless["store"],
    }


def _scrubbed_environment() -> dict[str, str]:
    environment: dict[str, str] = {}
    for name in ("HOME", "PATH", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    environment.setdefault("LANG", "C")
    environment["NO_COLOR"] = "1"
    return environment


def _run_gpudebug(
    arguments: list[str], timeout: int, deadline: float
) -> str:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        _semantic_block("gpudebug_global_deadline")
    effective_timeout = min(float(timeout), remaining)
    with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        try:
            process = subprocess.Popen(
                arguments,
                stdin=subprocess.DEVNULL,
                stdout=stdout_file,
                stderr=stderr_file,
                env=_scrubbed_environment(),
                start_new_session=True,
            )
            try:
                return_code = process.wait(timeout=effective_timeout)
            except subprocess.TimeoutExpired as exc:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise SemanticError("BLOCKED", "gpudebug_timeout") from exc
        except OSError as exc:
            raise SemanticError("BLOCKED", "gpudebug_exec") from exc
        if return_code != 0:
            _semantic_block("gpudebug_command")
        stdout_file.seek(0, os.SEEK_END)
        if stdout_file.tell() > 16 * 1024 * 1024:
            _semantic_block("gpudebug_output_limit")
        stdout_file.seek(0)
        return stdout_file.read().decode("utf-8", errors="replace")


def collect_transcripts(
    gpudebug: Path,
    trace: Path,
    timeout: int,
    global_timeout: int,
) -> AuditTranscripts:
    try:
        tool_info = gpudebug.lstat()
        trace_info = trace.lstat()
    except FileNotFoundError as exc:
        raise SemanticError("BLOCKED", "audit_input_missing") from exc
    if stat.S_ISLNK(tool_info.st_mode) or not stat.S_ISREG(tool_info.st_mode):
        _semantic_block("gpudebug_path")
    if tool_info.st_mode & stat.S_IXUSR == 0:
        _semantic_block("gpudebug_not_executable")
    if stat.S_ISLNK(trace_info.st_mode) or not (
        stat.S_ISREG(trace_info.st_mode) or stat.S_ISDIR(trace_info.st_mode)
    ):
        _semantic_block("trace_path")
    if timeout < 1 or timeout > 90:
        _semantic_block("timeout_range")
    if global_timeout < timeout or global_timeout > 720:
        _semantic_block("global_timeout_range")
    deadline = time.monotonic() + float(global_timeout)

    root = _run_gpudebug(
        [str(gpudebug), "-t", str(trace), "-c", "list"], timeout, deadline
    )
    session_matches = SESSION_RE.findall(root)
    if len(session_matches) != 1:
        _semantic_block("session_schema")
    session = session_matches[0]

    def session_command(*commands: str) -> str:
        for command in commands:
            if not command.startswith("go "):
                continue
            target = command.removeprefix("go ")
            if target.split("/", 1)[0] not in ("commands", "api_calls"):
                _semantic_block("non_root_qualified_go_command")
        arguments = [str(gpudebug), "-s", session]
        for command in commands:
            arguments.extend(("-c", command))
        return _run_gpudebug(arguments, timeout, deadline)

    try:
        commands = session_command("go commands")
        command_buffer = session_command("go commands/cb0")
        private_encoder = session_command("go commands/cb0/re0")
        memoryless_encoder = session_command("go commands/cb0/re1")
        session_command("go api_calls")
        api_calls = session_command("list --all")
        private_attachment = session_command(
            "go commands/cb0/re0", "info color0"
        )
        memoryless_attachment = session_command(
            "go commands/cb0/re1", "info color0"
        )
        transcripts = AuditTranscripts(
            root=root,
            commands=commands,
            command_buffer=command_buffer,
            private_encoder=private_encoder,
            memoryless_encoder=memoryless_encoder,
            api_calls=api_calls,
            private_attachment=private_attachment,
            memoryless_attachment=memoryless_attachment,
        )
    finally:
        _run_gpudebug(
            [str(gpudebug), "--terminate", session],
            min(timeout, 30),
            max(deadline, time.monotonic()) + 30.0,
        )
    return transcripts


def _append_audit(path: Path, fields: dict[str, str]) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise ValidationError("audit destination is missing") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        _fail("audit destination must be a regular non-symlink file")
    if info.st_mode & 0o077:
        _fail("audit destination must not be group/world accessible")
    with path.open("a", encoding="utf-8", newline="\n") as stream:
        for key, value in fields.items():
            if re.fullmatch(r"[a-z0-9_]+", key) is None:
                _fail("audit key is unsafe")
            if re.fullmatch(r"[A-Za-z0-9_.:-]+", value) is None:
                _fail("audit value is unsafe")
            stream.write(f"{key}={value}\n")


def run_audit(
    gpudebug: Path,
    trace: Path,
    audit: Path,
    timeout: int,
    global_timeout: int,
) -> None:
    try:
        result = analyze_transcripts(
            collect_transcripts(gpudebug, trace, timeout, global_timeout)
        )
    except SemanticError as exc:
        _append_audit(
            audit,
            {"gpudebug_result": exc.classification, "gpudebug_reason": exc.reason},
        )
        raise
    _append_audit(
        audit,
        {
            "gpudebug_summary": "1cb-2encoders-0draws",
            **result,
            "gpudebug_result": "PASS",
            "gpudebug_reason": "complete_schema_and_semantics",
        },
    )


def _summary_payload(kind: str, size: int, digest: str) -> bytes:
    return (
        f"capture_name={CAPTURE_NAME}\n"
        f"capture_kind={kind}\n"
        f"capture_bytes={size}\n"
        f"capture_manifest_sha256={digest}\n"
    ).encode()


def _make_tar(path: Path, members: list[tuple[tarfile.TarInfo, bytes]]) -> None:
    with tarfile.open(path, "w:gz") as archive:
        for info, payload in members:
            archive.addfile(info, io.BytesIO(payload) if info.isfile() else None)


def _tar_file(name: str, payload: bytes) -> tuple[tarfile.TarInfo, bytes]:
    info = tarfile.TarInfo(name)
    info.type = tarfile.REGTYPE
    info.size = len(payload)
    info.mode = 0o600
    return info, payload


def _tar_directory(name: str) -> tuple[tarfile.TarInfo, bytes]:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.size = 0
    info.mode = 0o700
    return info, b""


def _expect_validation_failure(callback) -> None:  # type: ignore[no-untyped-def]
    try:
        callback()
    except ValidationError:
        return
    raise AssertionError("invalid fixture unexpectedly passed")


def _expect_semantic(classification: str, callback) -> None:  # type: ignore[no-untyped-def]
    try:
        callback()
    except SemanticError as exc:
        if exc.classification != classification:
            raise AssertionError(
                f"expected {classification}, received {exc.classification}"
            ) from exc
        return
    raise AssertionError("invalid semantic fixture unexpectedly passed")


def _synthetic_transcripts() -> AuditTranscripts:
    banner = "Summary:  1 command buffer, 2 encoders, 0 draw calls\n"
    api_rows = [
        'api0  @tex0  [@dev newTextureWithDescriptor:<descriptor>]  info',
        'api1  @tex1  [@dev newTextureWithDescriptor:<descriptor>]  info',
        'api2  @cb0   [@cq commandBufferWithDescriptor:<descriptor>]  info',
        'api3         [@cb0 setLabel:"RIOS pm-clear CB"]  info',
        'api4         [@tex0 setLabel:"RIOS private 4x4"]  info',
        'api5         [@tex1 setLabel:"RIOS memoryless 4x4"]  info',
        'api6  @re0   [@cb0 renderCommandEncoderWithDescriptor:<descriptor>]  info',
        'api7         [@re0 setLabel:"RIOS private clear"]  info',
        'api8         [@re0 endEncoding]  info',
        'api9  @re1   [@cb0 renderCommandEncoderWithDescriptor:<descriptor>]  info',
        'api10        [@re1 setLabel:"RIOS memoryless clear"]  info',
        'api11        [@re1 endEncoding]  info',
        'api12        [@cb0 status]  info',
        'api13        [@cb0 addCompletedHandler:<handler>]  info',
        'api14        [@cb0 commit]  info',
        'api15        [@cb0 status]  info',
        'api16        [@cb0 error]  info',
    ]
    private_info = (
        banner
        + 'Label: "RIOS private 4x4"\nStorage Mode: MTLStorageModePrivate\n'
        + "Load Action: MTLLoadActionClear\nStore Action: MTLStoreActionStore\n"
    )
    memoryless_info = (
        banner
        + 'Label: "RIOS memoryless 4x4"\nStorage Mode: MTLStorageModeMemoryless\n'
        + "Load Action: MTLLoadActionClear\nStore Action: MTLStoreActionDontCare\n"
    )
    return AuditTranscripts(
        root="Session 7 created.\n" + banner,
        commands=banner + 'cb0  "RIOS pm-clear CB"  2 encoders  info\n(1 item)\n',
        command_buffer=(
            banner
            + 're0  "RIOS private clear"  render  info\n'
            + 're1  "RIOS memoryless clear"  render  info\n(2 items)\n'
        ),
        private_encoder=banner + 'color0  "RIOS private 4x4"  @tex0  info\n(1 item)\n',
        memoryless_encoder=banner + 'color0  "RIOS memoryless 4x4"  @tex1  info\n(1 item)\n',
        api_calls=banner + "\n".join(api_rows) + "\n(17 items)\n",
        private_attachment=private_info,
        memoryless_attachment=memoryless_info,
    )


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="rendererios-gpudebug-validator-") as raw:
        root = Path(raw)
        private = root / "private"
        private.mkdir(mode=0o700)

        passphrase = "self-test-passphrase-with-sufficient-length"
        envelope = "\n".join(
            (
                passphrase,
                "1" * 64,
                "2" * 64,
                "3" * 64,
                "17",
                "gpudebug-self-test",
                ASSET_NAME,
            )
        )
        old_value = os.environ.get(ENVELOPE_SECRET)
        os.environ[ENVELOPE_SECRET] = envelope
        try:
            simulated_argv = (
                "split-envelope",
                "--value-env",
                ENVELOPE_SECRET,
                "--directory",
                str(private),
            )
            assert passphrase not in simulated_argv
            split_envelope(
                ENVELOPE_SECRET, private, "gpudebug-self-test", ASSET_NAME
            )
        finally:
            if old_value is None:
                os.environ.pop(ENVELOPE_SECRET, None)
            else:
                os.environ[ENVELOPE_SECRET] = old_value
        assert (private / "passphrase").read_text().strip() == passphrase
        assert stat.S_IMODE((private / "passphrase").stat().st_mode) == 0o600

        cli_private = root / "cli-private"
        cli_private.mkdir(mode=0o700)
        cli_environment = os.environ.copy()
        cli_environment[ENVELOPE_SECRET] = envelope
        cli_arguments = [
            sys.executable,
            str(Path(__file__).resolve()),
            "split-envelope",
            "--value-env",
            ENVELOPE_SECRET,
            "--directory",
            str(cli_private),
            "--expected-tag",
            "gpudebug-self-test",
            "--expected-asset",
            ASSET_NAME,
        ]
        assert passphrase not in cli_arguments
        cli_result = subprocess.run(
            cli_arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=cli_environment,
            check=False,
        )
        assert cli_result.returncode == 0
        assert (cli_private / "passphrase").read_text().strip() == passphrase

        capture_payload = b"capture-self-test"
        digest = hashlib.sha256(capture_payload).hexdigest()
        summary_payload = _summary_payload("file", len(capture_payload), digest)
        valid_archive = root / "valid.tar.gz"
        _make_tar(
            valid_archive,
            [
                _tar_file(CAPTURE_NAME, capture_payload),
                _tar_file(SUMMARY_NAME, summary_payload),
            ],
        )
        extracted = root / "extracted"
        safe_extract(valid_archive, extracted, str(len(capture_payload)))
        assert (extracted / CAPTURE_NAME).read_bytes() == capture_payload

        recomputed = root / "recomputed-summary.txt"
        recomputed.write_bytes(summary_payload)
        verify_manifest(extracted / SUMMARY_NAME, recomputed, digest)

        package_payload = b"package-content"
        package_digest = hashlib.sha256(
            (hashlib.sha256(package_payload).hexdigest() + "  data.bin\n").encode()
        ).hexdigest()
        package_summary = _summary_payload(
            "directory", len(package_payload), package_digest
        )
        package_archive = root / "package.tar.gz"
        _make_tar(
            package_archive,
            [
                _tar_directory(CAPTURE_NAME),
                _tar_file(f"{CAPTURE_NAME}/data.bin", package_payload),
                _tar_file(SUMMARY_NAME, package_summary),
            ],
        )
        safe_extract(
            package_archive, root / "package-extracted", str(len(package_payload))
        )

        invalid_members: list[list[tuple[tarfile.TarInfo, bytes]]] = []
        invalid_members.append(
            [_tar_file("../escape", b"x"), _tar_file(SUMMARY_NAME, summary_payload)]
        )
        invalid_members.append(
            [_tar_file("/absolute", b"x"), _tar_file(SUMMARY_NAME, summary_payload)]
        )
        invalid_members.append(
            [
                _tar_file(CAPTURE_NAME, capture_payload),
                _tar_file(CAPTURE_NAME, capture_payload),
                _tar_file(SUMMARY_NAME, summary_payload),
            ]
        )
        invalid_members.append(
            [
                _tar_file(CAPTURE_NAME, capture_payload),
                _tar_file(SUMMARY_NAME, summary_payload),
                _tar_file("extra", b"x"),
            ]
        )
        invalid_members.append([_tar_file(CAPTURE_NAME, capture_payload)])
        invalid_members.append([_tar_file(SUMMARY_NAME, summary_payload)])
        symlink = tarfile.TarInfo(CAPTURE_NAME)
        symlink.type = tarfile.SYMTYPE
        symlink.linkname = "target"
        invalid_members.append([(symlink, b""), _tar_file(SUMMARY_NAME, summary_payload)])
        hardlink = tarfile.TarInfo(CAPTURE_NAME)
        hardlink.type = tarfile.LNKTYPE
        hardlink.linkname = "target"
        invalid_members.append([(hardlink, b""), _tar_file(SUMMARY_NAME, summary_payload)])
        fifo = tarfile.TarInfo(CAPTURE_NAME)
        fifo.type = tarfile.FIFOTYPE
        invalid_members.append([(fifo, b""), _tar_file(SUMMARY_NAME, summary_payload)])

        for index, members in enumerate(invalid_members):
            archive_path = root / f"invalid-{index}.tar.gz"
            _make_tar(archive_path, members)
            _expect_validation_failure(
                lambda path=archive_path, target=root / f"bad-{index}": safe_extract(
                    path, target, str(len(capture_payload))
                )
            )

        with tarfile.open(valid_archive, "r:gz") as archive:
            _expect_validation_failure(
                lambda: _validated_tar_entries(
                    archive, len(capture_payload), max_members=1
                )
            )
        _expect_validation_failure(
            lambda: safe_extract(valid_archive, root / "wrong-size", "1")
        )

        extra_summary = root / "extra-summary.txt"
        extra_summary.write_bytes(summary_payload + b"extra=value\n")
        _expect_validation_failure(
            lambda: verify_manifest(extra_summary, recomputed, digest)
        )
        duplicate_summary = root / "duplicate-summary.txt"
        duplicate_summary.write_bytes(
            summary_payload.replace(
                b"capture_kind=file\n",
                b"capture_kind=file\ncapture_kind=file\n",
            )
        )
        _expect_validation_failure(
            lambda: verify_manifest(duplicate_summary, recomputed, digest)
        )
        _expect_validation_failure(
            lambda: verify_manifest(extracted / SUMMARY_NAME, recomputed, digest.upper())
        )
        _expect_validation_failure(
            lambda: verify_manifest(extracted / SUMMARY_NAME, recomputed, "4" * 64)
        )

        good = _synthetic_transcripts()
        analyzed = analyze_transcripts(good)
        assert analyzed["command_buffers"] == "1"
        assert analyzed["memoryless_store"] == "DontCare"
        for field, original, replacement in (
            ("private_encoder", "@tex0", "@tex1"),
            ("private_encoder", "@tex0", "@tex9"),
            ("memoryless_encoder", "@tex1", "@tex0"),
            ("memoryless_encoder", "@tex1", "@tex9"),
        ):
            mutated_tree = good.__dict__[field].replace(original, replacement)
            _expect_semantic(
                "FAIL",
                lambda name=field, payload=mutated_tree: analyze_transcripts(
                    AuditTranscripts(
                        **{**good.__dict__, name: payload}
                    )
                ),
            )
        wrong_object_replacements = (
            ("api0  @tex0", "api0  @tex9"),
            ("[@dev newTextureWithDescriptor", "[@dev9 newTextureWithDescriptor"),
            ("api1  @tex1", "api1  @tex9"),
            ("api2  @cb0", "api2  @cb9"),
            ("[@cq commandBufferWithDescriptor", "[@cq9 commandBufferWithDescriptor"),
            ("api3         [@cb0 setLabel", "api3         [@cb9 setLabel"),
            ("api4         [@tex0 setLabel", "api4         [@tex9 setLabel"),
            ("api5         [@tex1 setLabel", "api5         [@tex9 setLabel"),
            ("api6  @re0", "api6  @re9"),
            ("api6  @re0   [@cb0", "api6  @re0   [@cb9"),
            ("api7         [@re0 setLabel", "api7         [@re9 setLabel"),
            ("api8         [@re0 endEncoding", "api8         [@re9 endEncoding"),
            ("api9  @re1", "api9  @re9"),
            ("api9  @re1   [@cb0", "api9  @re1   [@cb9"),
            ("api10        [@re1 setLabel", "api10        [@re9 setLabel"),
            ("api11        [@re1 endEncoding", "api11        [@re9 endEncoding"),
            ("api12        [@cb0 status", "api12        [@cb9 status"),
            (
                "api13        [@cb0 addCompletedHandler",
                "api13        [@cb9 addCompletedHandler",
            ),
            ("api14        [@cb0 commit", "api14        [@cb9 commit"),
            ("api15        [@cb0 status", "api15        [@cb9 status"),
            ("api16        [@cb0 error", "api16        [@cb9 error"),
        )
        for original, replacement in wrong_object_replacements:
            mutated = good.api_calls.replace(original, replacement)
            assert mutated != good.api_calls
            _expect_semantic(
                "FAIL",
                lambda payload=mutated: analyze_transcripts(
                    AuditTranscripts(
                        **{**good.__dict__, "api_calls": payload}
                    )
                ),
            )

        grammar_drifts = (
            good.api_calls.replace("[@cb0 commit]", "[@cb0 commit:unexpected]"),
            good.api_calls.replace("[@cb0 commit]", "[@cb0 commit unexpected]"),
            good.api_calls.replace("[@cb0 status]", "[@cb0 status:unexpected]"),
            good.api_calls.replace("[@cb0 error]", "[@cb0 error:unexpected]"),
            good.api_calls.replace(
                "[@re0 endEncoding]", "[@re0 endEncoding:unexpected]"
            ),
            good.api_calls.replace(
                "[@cq commandBufferWithDescriptor:<descriptor>]",
                "[@cq commandBuffer]",
            ),
            good.api_calls.replace(
                "[@cq commandBufferWithDescriptor:<descriptor>]",
                "[@cq commandBufferWithUnretainedReferences]",
            ),
        )
        for grammar_drift in grammar_drifts:
            assert grammar_drift != good.api_calls
            _expect_semantic(
                "BLOCKED",
                lambda payload=grammar_drift: analyze_transcripts(
                    AuditTranscripts(
                        **{**good.__dict__, "api_calls": payload}
                    )
                ),
            )

        factory_indices = (0, 1, 2, 6, 9)
        for factory_index in factory_indices:
            missing_result = re.sub(
                rf"(^[ \t]*api{factory_index}[ \t]+)"
                r"@[A-Za-z][A-Za-z0-9_]*([ \t]+\[)",
                r"\1\2",
                good.api_calls,
                count=1,
                flags=re.MULTILINE,
            )
            assert missing_result != good.api_calls
            _expect_semantic(
                "FAIL",
                lambda payload=missing_result: analyze_transcripts(
                    AuditTranscripts(
                        **{**good.__dict__, "api_calls": payload}
                    )
                ),
            )

        nonfactory_indices = (3, 4, 5, 7, 8, 10, 11, 12, 13, 14, 15, 16)
        for nonfactory_index in nonfactory_indices:
            artificial_result = re.sub(
                rf"(^[ \t]*api{nonfactory_index}[ \t]+)(\[)",
                r"\1@fake \2",
                good.api_calls,
                count=1,
                flags=re.MULTILINE,
            )
            assert artificial_result != good.api_calls
            _expect_semantic(
                "FAIL",
                lambda payload=artificial_result: analyze_transcripts(
                    AuditTranscripts(
                        **{**good.__dict__, "api_calls": payload}
                    )
                ),
            )

        for api_index in range(17):
            missing_receiver = re.sub(
                rf"(^[ \t]*api{api_index}[ \t]+.*?\[)"
                r"@[A-Za-z][A-Za-z0-9_]*[ \t]+",
                r"\1",
                good.api_calls,
                count=1,
                flags=re.MULTILINE,
            )
            assert missing_receiver != good.api_calls
            _expect_semantic(
                "BLOCKED",
                lambda payload=missing_receiver: analyze_transcripts(
                    AuditTranscripts(
                        **{**good.__dict__, "api_calls": payload}
                    )
                ),
            )

        api0_row = (
            'api0  @tex0  [@dev newTextureWithDescriptor:<descriptor>]  info\n'
        )
        duplicate_api_fixtures = (
            good.api_calls.replace(api0_row, api0_row + api0_row),
            good.api_calls.replace(api0_row, api0_row + "api0 malformed\n"),
            good.api_calls.replace(
                api0_row,
                api0_row
                + 'api0  @tex9  [@dev newTextureWithDescriptor:<other>]  info\n',
            ),
            good.api_calls + "(17 items)\n",
            good.api_calls + "(16 items)\n",
            good.api_calls.replace("(17 items)", "(16 items)"),
        )
        for duplicate_fixture in duplicate_api_fixtures:
            _expect_semantic(
                "BLOCKED",
                lambda payload=duplicate_fixture: analyze_transcripts(
                    AuditTranscripts(
                        **{**good.__dict__, "api_calls": payload}
                    )
                ),
            )
        _expect_semantic(
            "BLOCKED",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "commands": good.commands.replace(
                            'cb0  "RIOS pm-clear CB"  2 encoders  info\n',
                            'cb0  "RIOS pm-clear CB"  2 encoders  info\n'
                            'cb0  "RIOS pm-clear CB"  2 encoders  info\n',
                        ),
                    }
                )
            ),
        )
        _expect_semantic(
            "BLOCKED",
            lambda: analyze_transcripts(
                AuditTranscripts(**{**good.__dict__, "root": "schema changed\n"})
            ),
        )
        _expect_semantic(
            "FAIL",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "root": good.root.replace(
                            "1 command buffer", "2 command buffers"
                        ),
                    }
                )
            ),
        )
        _expect_semantic(
            "BLOCKED",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "api_calls": good.api_calls.replace("(17 items)", ""),
                    }
                )
            ),
        )
        _expect_semantic(
            "FAIL",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "api_calls": good.api_calls.replace(
                            "addCompletedHandler:<handler>",
                            'setLabel:"unexpected-submit-schema"',
                        ),
                    }
                )
            ),
        )
        _expect_semantic(
            "FAIL",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "api_calls": good.api_calls.replace(
                            "[@cb0 commit]", "[@cb0 presentDrawable:@drawable]"
                        ),
                    }
                )
            ),
        )
        without_error = good.api_calls.replace(
            'api16        [@cb0 error]  info\n(17 items)',
            '(16 items)',
        )
        without_completion = good.api_calls.replace(
            'api15        [@cb0 status]  info\n'
            'api16        [@cb0 error]  info\n'
            '(17 items)',
            '(15 items)',
        )
        for incomplete_callback in (without_error, without_completion):
            _expect_semantic(
                "FAIL",
                lambda payload=incomplete_callback: analyze_transcripts(
                    AuditTranscripts(
                        **{**good.__dict__, "api_calls": payload}
                    )
                ),
            )
        _expect_semantic(
            "BLOCKED",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "api_calls": good.api_calls.replace(
                            "addCompletedHandler:<handler>", "waitUntilCompleted"
                        ),
                    }
                )
            ),
        )
        _expect_semantic(
            "FAIL",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "api_calls": good.api_calls.replace(
                            "api1  @tex1", "api99 @tex1"
                        ).replace("api2  @cb0", "api1  @cb0").replace(
                            "api99 @tex1", "api2  @tex1"
                        ),
                    }
                )
            ),
        )
        _expect_semantic(
            "BLOCKED",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "private_attachment": good.private_attachment.replace(
                            "Storage Mode: MTLStorageModePrivate\n", ""
                        ),
                    }
                )
            ),
        )
        _expect_semantic(
            "FAIL",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "private_attachment": good.private_attachment.replace(
                            "MTLStorageModePrivate", "MTLStorageModeShared"
                        ),
                    }
                )
            ),
        )

        fake_tool = root / "fake-gpudebug"
        fake_trace = root / CAPTURE_NAME
        fake_trace.write_bytes(b"private raw trace fixture")
        fake_audit = root / "audit.txt"
        fake_audit.write_text("schema=self-test\n", encoding="utf-8")
        fake_audit.chmod(0o600)
        fake_state = root / "fake-gpudebug-state"

        def without_banner(value: str) -> str:
            return value.replace(
                "Summary:  1 command buffer, 2 encoders, 0 draw calls\n", "", 1
            )

        fake_outputs = {
            "go commands": without_banner(good.commands),
            "go commands/cb0": without_banner(good.command_buffer),
            "go commands/cb0/re0": without_banner(good.private_encoder),
            "go commands/cb0/re1": without_banner(good.memoryless_encoder),
            "go api_calls": "api0  @ignored  [@ignored ignored]  info\n",
            "list --all": without_banner(good.api_calls),
            "go commands/cb0/re0|info color0": without_banner(
                good.private_attachment
            ),
            "go commands/cb0/re1|info color0": without_banner(
                good.memoryless_attachment
            ),
        }
        fake_tool.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, subprocess, sys, time\n"
            f"outputs = {fake_outputs!r}\n"
            f"state_path = pathlib.Path({str(fake_state)!r})\n"
            "if os.environ.get('GH_TOKEN') or "
            "os.environ.get('GPUDEBUG_TRACE_ENVELOPE'):\n"
            "    raise SystemExit(44)\n"
            "args = sys.argv[1:]\n"
            "if '--hang' in args:\n"
            "    subprocess.Popen([sys.executable, '-c', "
            "'import time; time.sleep(30)'])\n"
            "    time.sleep(30)\n"
            "if '--terminate' in args:\n"
            "    state_path.unlink(missing_ok=True)\n"
            "    raise SystemExit(0)\n"
            "commands = [args[index + 1] for index, value in enumerate(args) "
            "if value == '-c']\n"
            "if '-t' in args:\n"
            "    if commands != ['list']:\n"
            "        raise SystemExit(46)\n"
            "    state_path.write_text('/', encoding='utf-8')\n"
            "    print('Session 7 created.')\n"
            "    print('Summary:  1 command buffer, 2 encoders, 0 draw calls')\n"
            "    print('Trace: RAW-TRACE-MUST-NOT-LEAK')\n"
            "elif '-s' in args and state_path.is_file():\n"
            "    current = state_path.read_text(encoding='utf-8')\n"
            "    for command in commands:\n"
            "        if command.startswith('go '):\n"
            "            target = command.removeprefix('go ')\n"
            "            if target.split('/', 1)[0] not in "
            "('commands', 'api_calls'):\n"
            "                raise SystemExit(47)\n"
            "            current = target\n"
            "        elif command == 'list --all':\n"
            "            if current != 'api_calls':\n"
            "                raise SystemExit(48)\n"
            "        elif command == 'info color0':\n"
            "            if current not in "
            "('commands/cb0/re0', 'commands/cb0/re1'):\n"
            "                raise SystemExit(49)\n"
            "        else:\n"
            "            raise SystemExit(50)\n"
            "    key = '|'.join(commands)\n"
            "    if key not in outputs:\n"
            "        raise SystemExit(51)\n"
            "    state_path.write_text(current, encoding='utf-8')\n"
            "    print(outputs[key], end='')\n"
            "else:\n"
            "    raise SystemExit(45)\n",
            encoding="utf-8",
        )
        fake_tool.chmod(0o700)
        saved_gh_token = os.environ.get("GH_TOKEN")
        saved_trace_envelope = os.environ.get(ENVELOPE_SECRET)
        os.environ["GH_TOKEN"] = "must-not-reach-gpudebug"
        os.environ[ENVELOPE_SECRET] = "must-not-reach-gpudebug"
        try:
            run_audit(fake_tool, fake_trace, fake_audit, 5, 30)
        finally:
            if saved_gh_token is None:
                os.environ.pop("GH_TOKEN", None)
            else:
                os.environ["GH_TOKEN"] = saved_gh_token
            if saved_trace_envelope is None:
                os.environ.pop(ENVELOPE_SECRET, None)
            else:
                os.environ[ENVELOPE_SECRET] = saved_trace_envelope
        audit_payload = fake_audit.read_text(encoding="utf-8")
        assert "gpudebug_result=PASS\n" in audit_payload
        assert "RAW-TRACE-MUST-NOT-LEAK" not in audit_payload
        assert not fake_state.exists()
        _expect_semantic(
            "BLOCKED",
            lambda: _run_gpudebug(
                [str(fake_tool), "--hang"], 1, time.monotonic() + 2.0
            ),
        )
        _expect_semantic(
            "BLOCKED",
            lambda: _run_gpudebug(
                [str(fake_tool), "--terminate", "7"],
                1,
                time.monotonic() - 1.0,
            ),
        )

    print("gpudebug trace validator self-test: PASS")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    split_parser = subparsers.add_parser("split-envelope")
    split_parser.add_argument("--value-env", required=True)
    split_parser.add_argument("--directory", type=Path, required=True)
    split_parser.add_argument("--expected-tag", required=True)
    split_parser.add_argument("--expected-asset", required=True)

    extract_parser = subparsers.add_parser("safe-extract")
    extract_parser.add_argument("--archive", type=Path, required=True)
    extract_parser.add_argument("--directory", type=Path, required=True)
    extract_parser.add_argument("--expected-capture-bytes", required=True)

    manifest_parser = subparsers.add_parser("verify-manifest")
    manifest_parser.add_argument("--transport-summary", type=Path, required=True)
    manifest_parser.add_argument("--recomputed-summary", type=Path, required=True)
    manifest_parser.add_argument("--expected-manifest", required=True)

    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("--gpudebug", type=Path, required=True)
    audit_parser.add_argument("--trace", type=Path, required=True)
    audit_parser.add_argument("--audit", type=Path, required=True)
    audit_parser.add_argument("--command-timeout", type=int, default=60)
    audit_parser.add_argument("--global-timeout", type=int, default=720)

    subparsers.add_parser("self-test")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "split-envelope":
            split_envelope(
                args.value_env,
                args.directory,
                args.expected_tag,
                args.expected_asset,
            )
        elif args.command == "safe-extract":
            safe_extract(args.archive, args.directory, args.expected_capture_bytes)
        elif args.command == "verify-manifest":
            verify_manifest(
                args.transport_summary,
                args.recomputed_summary,
                args.expected_manifest,
            )
        elif args.command == "audit":
            run_audit(
                args.gpudebug,
                args.trace,
                args.audit,
                args.command_timeout,
                args.global_timeout,
            )
        elif args.command == "self-test":
            self_test()
        else:
            raise AssertionError("unreachable command")
    except SemanticError as exc:
        print(
            f"gpudebug semantic audit {exc.classification}: {exc.reason}",
            file=sys.stderr,
        )
        return 1
    except (ValidationError, OSError, AssertionError) as exc:
        print(f"gpudebug trace validation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
