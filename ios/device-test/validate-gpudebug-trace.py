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


class GPUDebugCommandError(SemanticError):
    def __init__(self, reason: str, stdout: str):
        super().__init__("BLOCKED", reason)
        self.stdout = stdout


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
    tool_version: str
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


SESSION_RE = re.compile(r"^Session ([1-9][0-9]*) created\.\s*$", re.MULTILINE)
SESSION_HELPER_RE = re.compile(
    r"^gpudebug -s ([1-9][0-9]*) -c <command> to send commands\.\s*$",
    re.MULTILINE,
)
FOOTER_RE = re.compile(r"^\s*\(([0-9]+) items?\)\s*$", re.MULTILINE)
API_ROW_RE = re.compile(
    r"^\s*api([0-9]+)\s+(?:(\S+)\s+)?(\[[^\n]*\])\s+info\s*$",
    re.MULTILINE,
)


def _require_root_schema(tool_version: str, text: str) -> int:
    if tool_version != "gpudebug 1.0\n":
        _semantic_block("gpudebug_version")
    session_matches = SESSION_RE.findall(text)
    if len(session_matches) != 1:
        _semantic_block("session_schema")
    session = session_matches[0]
    helper_matches = SESSION_HELPER_RE.findall(text)
    if helper_matches != [session]:
        _semantic_block("session_helper_schema")
    other_session_lines = re.findall(
        r"^[^\n]*other sessions? active\.\s*$", text, re.MULTILINE
    )
    if len(other_session_lines) > 1:
        _semantic_block("other_session_schema")
    if other_session_lines and re.fullmatch(
        r"[1-9][0-9]* other sessions? active\.",
        other_session_lines[0].strip(),
    ) is None:
        _semantic_block("other_session_schema")
    root_line_patterns = (
        r"Session [1-9][0-9]* created\.",
        r"[1-9][0-9]* other sessions? active\.",
        r"gpudebug -s [1-9][0-9]* -c <command> to send commands\.",
        r"Name\s+Summary\s+Actions",
        r"[─\s]+",
        r"commands\s+.*",
        r"performance\s+.*",
        r"api_calls\s+.*",
        r"resources\s+.*",
        r"\(4 items\)",
    )
    for line in text.splitlines():
        if not any(re.fullmatch(pattern, line) for pattern in root_line_patterns):
            _semantic_block("root_line_schema")

    commands = re.findall(
        r"^commands\s+([1-9][0-9]*) command buffers?\s+go\s*$",
        text,
        re.MULTILINE,
    )
    api_calls = re.findall(
        r"^api_calls\s+([1-9][0-9]*) API calls\s+go\s*$",
        text,
        re.MULTILINE,
    )
    resources = re.findall(
        r"^resources\s+([1-9][0-9]*) objects\s+go\s*$",
        text,
        re.MULTILINE,
    )
    performance = re.findall(
        r"^performance\s+see 'profile \?'\s*$", text, re.MULTILINE
    )
    if len(commands) != 1:
        _semantic_block("root_commands_schema")
    if len(api_calls) != 1:
        _semantic_block("root_api_calls_schema")
    if len(resources) != 1:
        _semantic_block("root_resources_schema")
    if len(performance) != 1:
        _semantic_block("root_performance_schema")
    root_rows = re.findall(
        r"^(commands|performance|api_calls|resources)\s+.*$", text, re.MULTILINE
    )
    expected_rows = ("commands", "performance", "api_calls", "resources")
    if sorted(root_rows) != sorted(expected_rows):
        _semantic_block("root_table_schema")
    _require_complete_table(text, 4, "root_table")
    if int(commands[0]) != 1:
        _semantic_fail("root_command_buffer_count")
    if int(api_calls[0]) != 14:
        _semantic_fail("root_api_call_count")
    return int(resources[0])


def _table_rows(text: str, pattern: re.Pattern[str]) -> dict[str, str]:
    rows: dict[str, str] = {}
    for match in pattern.finditer(text):
        name = match.group(1)
        row = match.group(0).strip()
        if name in rows:
            _semantic_block("table_duplicate_row")
        rows[name] = row
    return rows


def _require_table_lines(
    text: str,
    patterns: tuple[str, ...],
    reason: str,
) -> None:
    common = (r"[─\s]+", r"\([1-9][0-9]* items?\)")
    for line in text.splitlines():
        if not any(
            re.fullmatch(pattern, line) for pattern in (*patterns, *common)
        ):
            _semantic_block(f"{reason}_line_schema")


def _require_complete_table(text: str, expected_count: int, reason: str) -> None:
    footer_counts = [int(value) for value in FOOTER_RE.findall(text)]
    if len(footer_counts) != 1:
        _semantic_block(f"{reason}_completeness")
    if footer_counts[0] != expected_count:
        _semantic_fail(f"{reason}_count")


def _require_exact_structure(transcripts: AuditTranscripts) -> tuple[str, str]:
    _require_table_lines(
        transcripts.commands,
        (
            r"Name\s+Summary\s+Label\s+Actions",
            r'cb[0-9]+\s+.*',
        ),
        "command_buffer_table",
    )
    cb_rows = _table_rows(
        transcripts.commands,
        re.compile(r"^\s*([a-z]+[0-9]+)\s+.*$", re.MULTILINE),
    )
    if not cb_rows:
        _semantic_block("command_buffer_table_schema")
    if set(cb_rows) != {"cb0"}:
        _semantic_fail("command_buffer_count")
    _require_complete_table(transcripts.commands, 1, "command_buffer_table")
    command_row_match = re.fullmatch(
        r'cb0\s+([1-9][0-9]*) encoders?\s+"([^"]+)"\s+go',
        cb_rows["cb0"],
    )
    if command_row_match is None:
        _semantic_block("command_buffer_row_schema")
    if int(command_row_match.group(1)) != 2:
        _semantic_fail("command_buffer_encoder_count")
    if re.fullmatch(
        r"MTLCommandQueue [1-9][0-9]*", command_row_match.group(2)
    ) is None:
        _semantic_block("command_buffer_generated_label_schema")

    encoder_rows = _table_rows(
        transcripts.command_buffer,
        re.compile(r"^\s*([a-z]+[0-9]+)\s+.*$", re.MULTILINE),
    )
    _require_table_lines(
        transcripts.command_buffer,
        (
            r"Name\s+Label\s+Summary\s+Actions",
            r'[a-z]+[0-9]+\s+.*',
        ),
        "encoder_table",
    )
    if not encoder_rows:
        _semantic_block("encoder_table_schema")
    if set(encoder_rows) != {"re0", "re1"}:
        _semantic_fail("encoder_tree")
    _require_complete_table(transcripts.command_buffer, 2, "encoder_table")
    expected_encoder_labels = {
        "re0": "RIOS private clear",
        "re1": "RIOS memoryless clear",
    }
    for name, expected_label in expected_encoder_labels.items():
        match = re.fullmatch(rf'{name}\s+"([^"]+)"\s+go', encoder_rows[name])
        if match is None:
            _semantic_block(f"{name}_row_schema")
        if match.group(1) != expected_label:
            _semantic_fail(f"{name}_label")

    attachment_objects: list[str] = []
    for text, expected_label, reason in (
        (
            transcripts.private_encoder,
            '"RIOS private 4x4"',
            "private_attachment_tree",
        ),
        (
            transcripts.memoryless_encoder,
            '"RIOS memoryless 4x4"',
            "memoryless_attachment_tree",
        ),
    ):
        _require_table_lines(
            text,
            (
                r"Name\s+Label\s+Summary\s+Actions",
                r"(?:color[0-9]+|depth|stencil)\s+.*",
            ),
            reason,
        )
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
            r"(?<![A-Za-z0-9_])@tex[0-9]+",
            attachment_rows["color0"],
        )
        if len(object_ids) != 1:
            _semantic_block(f"{reason}_object_schema")
        expected_row = (
            rf"color0\s+{re.escape(expected_label)}\s+"
            rf"{re.escape(object_ids[0])}\s+4x4 RGBA8Unorm\s+info, fetch"
        )
        if re.fullmatch(expected_row, attachment_rows["color0"]) is None:
            _semantic_block(f"{reason}_row_schema")
        attachment_objects.append(object_ids[0])
    if attachment_objects[0] == attachment_objects[1]:
        _semantic_fail("attachment_object_alias")
    return attachment_objects[0], attachment_objects[1]


def _method_from_call(call: str) -> str:
    match = re.match(r"^\[[^\s\]]+\s+([^\s\]]+)", call)
    if match is None:
        _semantic_block("api_call_schema")
    return match.group(1).split(":", 1)[0]


def _receiver_from_call(call: str) -> str:
    match = re.match(r"^\[([@A-Za-z][A-Za-z0-9_]*)\s+", call)
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


def _require_api_semantics(
    text: str,
    private_attachment_object: str,
    memoryless_attachment_object: str,
) -> dict[str, int]:
    calls = _parse_api_calls(text)
    if len(calls) != 14:
        _semantic_fail("api_call_count")
    forbidden = re.compile(
        r"nextDrawable|present|newLibraryWithSource|newRenderPipelineState|"
        r"newComputePipelineState|setRenderPipelineState|setComputePipelineState|"
        r"draw|dispatch|computeCommandEncoder|blitCommandEncoder|"
        r"parallelRenderCommandEncoder|executeCommands|newCommandQueue|"
        r"waitUntilCompleted|waitUntilScheduled",
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
    if statuses:
        _semantic_fail("status_count")
    if len(completed_handlers) != 1:
        _semantic_fail("completed_handler_count")
    if errors:
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
    completed_handler_call = calls[completed_handlers[0]]
    commit_call = calls[commits[0]]
    if private_texture_label.receiver != private_attachment_object:
        _semantic_fail("private_factory_label_attachment_relation")
    if memoryless_texture_label.receiver != memoryless_attachment_object:
        _semantic_fail("memoryless_factory_label_attachment_relation")
    if texture_calls[0].result != private_attachment_object:
        _semantic_fail("private_factory_attachment_relation")
    if texture_calls[1].result != memoryless_attachment_object:
        _semantic_fail("memoryless_factory_attachment_relation")
    if private_attachment_object == memoryless_attachment_object:
        _semantic_fail("texture_object_alias")

    object_schema: list[
        tuple[APICall, str | re.Pattern[str], str | None, str, str]
    ] = [
        (
            texture_calls[0],
            "MTLDevice",
            private_attachment_object,
            "[MTLDevice newTextureWithDescriptor:<descriptor>]",
            "private_factory",
        ),
        (
            texture_calls[1],
            "MTLDevice",
            memoryless_attachment_object,
            "[MTLDevice newTextureWithDescriptor:<descriptor>]",
            "memoryless_factory",
        ),
        (
            private_texture_label,
            private_attachment_object,
            None,
            f'[{private_attachment_object} setLabel:"RIOS private 4x4"]',
            "private_texture_label",
        ),
        (
            memoryless_texture_label,
            memoryless_attachment_object,
            None,
            f'[{memoryless_attachment_object} setLabel:"RIOS memoryless 4x4"]',
            "memoryless_texture_label",
        ),
        (
            command_buffer_call,
            re.compile(r"@cq[0-9]+\Z"),
            None,
            "",
            "command_buffer_factory",
        ),
        (
            command_buffer_label,
            "MTLCommandBuffer",
            None,
            '[MTLCommandBuffer setLabel:"RIOS pm-clear CB"]',
            "command_buffer_label",
        ),
        (
            render_encoder_calls[0],
            "MTLCommandBuffer",
            None,
            "[MTLCommandBuffer renderCommandEncoderWithDescriptor:<descriptor>]",
            "private_encoder_factory",
        ),
        (
            private_encoder_label,
            "MTLRenderCommandEncoder",
            None,
            '[MTLRenderCommandEncoder setLabel:"RIOS private clear"]',
            "private_encoder_label",
        ),
        (
            end_calls[0],
            "MTLRenderCommandEncoder",
            None,
            "[MTLRenderCommandEncoder endEncoding]",
            "private_end_encoding",
        ),
        (
            render_encoder_calls[1],
            "MTLCommandBuffer",
            None,
            "[MTLCommandBuffer renderCommandEncoderWithDescriptor:<descriptor>]",
            "memoryless_encoder_factory",
        ),
        (
            memoryless_encoder_label,
            "MTLRenderCommandEncoder",
            None,
            '[MTLRenderCommandEncoder setLabel:"RIOS memoryless clear"]',
            "memoryless_encoder_label",
        ),
        (
            end_calls[1],
            "MTLRenderCommandEncoder",
            None,
            "[MTLRenderCommandEncoder endEncoding]",
            "memoryless_end_encoding",
        ),
        (
            completed_handler_call,
            "MTLCommandBuffer",
            None,
            "[MTLCommandBuffer addCompletedHandler:]",
            "completed_handler",
        ),
        (commit_call, "MTLCommandBuffer", None, "[MTLCommandBuffer commit]", "commit"),
    ]
    if [call.index for call, _, _, _, _ in object_schema] != list(range(14)):
        _semantic_fail("api_object_schema_order")
    for call, receiver, result, grammar, reason in object_schema:
        expected_receiver = (
            receiver.fullmatch(call.receiver) is not None
            if isinstance(receiver, re.Pattern)
            else call.receiver == receiver
        )
        if not expected_receiver:
            _semantic_fail(f"{reason}_receiver")
        _require_call_object(
            call,
            receiver=call.receiver,
            result=result,
            reason=reason,
        )
        expected_grammar = (
            f"[{call.receiver} commandBufferWithDescriptor:<descriptor>]"
            if reason == "command_buffer_factory"
            else grammar
        )
        if call.text != expected_grammar:
            _semantic_block(f"{reason}_grammar")
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
    if len(matching_lines) != 1:
        _semantic_block(f"{reason}_schema")
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


def _literal_field_value(text: str, field_name: str, reason: str) -> str:
    matches = re.findall(
        rf"^{re.escape(field_name)}:\s+(\S+)\s*$",
        text,
        re.MULTILINE | re.IGNORECASE,
    )
    if len(matches) != 1:
        _semantic_block(f"{reason}_schema")
    return matches[0]


def _text_field_value(text: str, field_name: str, reason: str) -> str:
    matches = re.findall(
        rf"^{re.escape(field_name)}:\s+(\S(?:.*\S)?)\s*$",
        text,
        re.MULTILINE,
    )
    if len(matches) != 1:
        _semantic_block(f"{reason}_schema")
    return matches[0]


def _require_attachment_info(
    text: str,
    expected_label: str,
    expected_storage: str,
    expected_store: str,
    expected_allocated_size: str,
    prefix: str,
) -> dict[str, str]:
    label = _text_field_value(text, "label", f"{prefix}_texture_label")
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
    dimensions = _literal_field_value(
        text, "dimensions", f"{prefix}_dimensions"
    )
    pixel_format = _literal_field_value(
        text, "pixelFormat", f"{prefix}_pixel_format"
    )
    texture_type = _literal_field_value(
        text, "textureType", f"{prefix}_texture_type"
    )
    allocated_size = _text_field_value(
        text, "allocatedSize", f"{prefix}_allocated_size"
    )
    usage = _literal_field_value(text, "usage", f"{prefix}_usage")
    if label != expected_label:
        _semantic_fail(f"{prefix}_texture_label")
    if storage.lower() != expected_storage.lower():
        _semantic_fail(f"{prefix}_storage")
    if load.lower() != "clear":
        _semantic_fail(f"{prefix}_load")
    if store.lower() != expected_store.lower():
        _semantic_fail(f"{prefix}_store")
    if dimensions != "4x4":
        _semantic_fail(f"{prefix}_dimensions")
    if pixel_format != "RGBA8Unorm":
        _semantic_fail(f"{prefix}_pixel_format")
    if texture_type != "2D":
        _semantic_fail(f"{prefix}_texture_type")
    if allocated_size != expected_allocated_size:
        _semantic_fail(f"{prefix}_allocated_size")
    if usage != "RenderTarget":
        _semantic_fail(f"{prefix}_usage")
    return {
        "label": label,
        "storage": storage,
        "load": load,
        "store": store,
        "dimensions": dimensions,
        "pixel_format": pixel_format,
        "texture_type": texture_type,
        "allocated_bytes": allocated_size.removesuffix(" bytes"),
        "usage": usage,
    }


def analyze_transcripts(transcripts: AuditTranscripts) -> dict[str, str]:
    resources = _require_root_schema(transcripts.tool_version, transcripts.root)
    private_object, memoryless_object = _require_exact_structure(transcripts)
    counts = _require_api_semantics(
        transcripts.api_calls,
        private_object,
        memoryless_object,
    )
    private = _require_attachment_info(
        transcripts.private_attachment,
        "RIOS private 4x4",
        "Private",
        "Store",
        "128 bytes",
        "private",
    )
    memoryless = _require_attachment_info(
        transcripts.memoryless_attachment,
        "RIOS memoryless 4x4",
        "Memoryless",
        "DontCare",
        "0 bytes",
        "memoryless",
    )
    return {
        **{key: str(value) for key, value in counts.items()},
        "resources": str(resources),
        "private_storage": private["storage"],
        "private_load": private["load"],
        "private_store": private["store"],
        "private_dimensions": private["dimensions"],
        "private_pixel_format": private["pixel_format"],
        "private_texture_type": private["texture_type"],
        "private_allocated_bytes": private["allocated_bytes"],
        "private_usage": private["usage"],
        "memoryless_storage": memoryless["storage"],
        "memoryless_load": memoryless["load"],
        "memoryless_store": memoryless["store"],
        "memoryless_dimensions": memoryless["dimensions"],
        "memoryless_pixel_format": memoryless["pixel_format"],
        "memoryless_texture_type": memoryless["texture_type"],
        "memoryless_allocated_bytes": memoryless["allocated_bytes"],
        "memoryless_usage": memoryless["usage"],
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
        failure_reason: str | None = None
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
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                return_code = process.returncode
                failure_reason = "gpudebug_timeout"
        except OSError as exc:
            raise SemanticError("BLOCKED", "gpudebug_exec") from exc
        stdout_file.seek(0, os.SEEK_END)
        if stdout_file.tell() > 16 * 1024 * 1024:
            raise GPUDebugCommandError("gpudebug_output_limit", "")
        stdout_file.seek(0)
        stdout = stdout_file.read().decode("utf-8", errors="replace")
        if failure_reason is not None:
            raise GPUDebugCommandError(failure_reason, stdout)
        if return_code != 0:
            raise GPUDebugCommandError("gpudebug_command", stdout)
        return stdout


def _owned_session_from_output(text: str) -> str | None:
    candidates = set(SESSION_RE.findall(text))
    candidates.update(SESSION_HELPER_RE.findall(text))
    if len(candidates) != 1:
        return None
    return candidates.pop()


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

    tool_version = _run_gpudebug(
        [str(gpudebug), "--version"], timeout, deadline
    )
    session: str | None = None
    try:
        try:
            root = _run_gpudebug(
                [
                    str(gpudebug),
                    "-t",
                    str(trace),
                    "--timeout",
                    str(min(timeout + 30, 120)),
                    "-c",
                    "list",
                ],
                timeout,
                deadline,
            )
        except GPUDebugCommandError as exc:
            session = _owned_session_from_output(exc.stdout)
            raise
        session = _owned_session_from_output(root)
        session_matches = SESSION_RE.findall(root)
        if len(session_matches) != 1 or session != session_matches[0]:
            _semantic_block("session_schema")

        def session_command(*commands: str) -> str:
            assert session is not None
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
            tool_version=tool_version,
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
        if session is not None:
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
            "gpudebug_reason": "exact_trace_schema_and_submission_semantics",
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
    api_rows = [
        'api0   @tex30  [MTLDevice newTextureWithDescriptor:<descriptor>]  info',
        'api1   @tex31  [MTLDevice newTextureWithDescriptor:<descriptor>]  info',
        'api2           [@tex30 setLabel:"RIOS private 4x4"]  info',
        'api3           [@tex31 setLabel:"RIOS memoryless 4x4"]  info',
        'api4           [@cq0 commandBufferWithDescriptor:<descriptor>]  info',
        'api5           [MTLCommandBuffer setLabel:"RIOS pm-clear CB"]  info',
        'api6           [MTLCommandBuffer renderCommandEncoderWithDescriptor:<descriptor>]  info',
        'api7           [MTLRenderCommandEncoder setLabel:"RIOS private clear"]  info',
        'api8           [MTLRenderCommandEncoder endEncoding]  info',
        'api9           [MTLCommandBuffer renderCommandEncoderWithDescriptor:<descriptor>]  info',
        'api10          [MTLRenderCommandEncoder setLabel:"RIOS memoryless clear"]  info',
        'api11          [MTLRenderCommandEncoder endEncoding]  info',
        'api12          [MTLCommandBuffer addCompletedHandler:]  info',
        'api13          [MTLCommandBuffer commit]  info',
    ]
    private_info = (
        "loadAction: Clear\nstoreAction: Store\nlabel: RIOS private 4x4\n"
        "dimensions: 4x4\npixelFormat: RGBA8Unorm\ntextureType: 2D\n"
        "storageMode: Private\nallocatedSize: 128 bytes\n"
        "usage: RenderTarget\ncompressionType: Lossless\n"
        "allowGPUOptimizedContents: yes\n"
        "  Use --all for more details.\n"
    )
    memoryless_info = (
        "loadAction: Clear\nstoreAction: DontCare\nlabel: RIOS memoryless 4x4\n"
        "dimensions: 4x4\npixelFormat: RGBA8Unorm\ntextureType: 2D\n"
        "storageMode: Memoryless\nallocatedSize: 0 bytes\n"
        "usage: RenderTarget\ncompressionType: Lossless\n"
        "allowGPUOptimizedContents: yes\n"
        "  Use --all for more details.\n"
    )
    return AuditTranscripts(
        tool_version="gpudebug 1.0\n",
        root=(
            "Session 7 created.\n"
            "1 other session active.\n"
            "gpudebug -s 7 -c <command> to send commands.\n"
            "Name         Summary           Actions\n"
            "commands     1 command buffer       go\n"
            "performance  see 'profile ?'\n"
            "api_calls    14 API calls           go\n"
            "resources    59 objects             go\n"
            "(4 items)\n"
        ),
        commands=(
            "Name  Summary     Label                Actions\n"
            "────  ──────────  ───────────────────  ───────\n"
            'cb0   2 encoders  "MTLCommandQueue 1"       go\n'
            "(1 items)\n"
        ),
        command_buffer=(
            "Name  Label                    Summary  Actions\n"
            "────  ───────────────────────  ───────  ───────\n"
            're0   "RIOS private clear"                   go\n'
            're1   "RIOS memoryless clear"                go\n'
            "(2 items)\n"
        ),
        private_encoder=(
            "Name    Label               Summary                Actions\n"
            "──────  ──────────────────  ─────────────────────  ───────────\n"
            'color0  "RIOS private 4x4"  @tex30 4x4 RGBA8Unorm  info, fetch\n'
            "(1 items)\n"
        ),
        memoryless_encoder=(
            "Name    Label                  Summary                Actions\n"
            "──────  ─────────────────────  ─────────────────────  ───────────\n"
            'color0  "RIOS memoryless 4x4"  @tex31 4x4 RGBA8Unorm  info, fetch\n'
            "(1 items)\n"
        ),
        api_calls="\n".join(api_rows) + "\n(14 items)\n",
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
        assert analyzed["api_calls"] == "14"
        assert analyzed["status_calls"] == "0"
        assert analyzed["error_calls"] == "0"
        assert analyzed["resources"] == "59"
        assert analyzed["memoryless_store"] == "DontCare"
        assert analyzed["private_dimensions"] == "4x4"
        assert analyzed["memoryless_pixel_format"] == "RGBA8Unorm"
        assert analyzed["private_texture_type"] == "2D"
        assert analyzed["private_allocated_bytes"] == "128"
        assert analyzed["memoryless_allocated_bytes"] == "0"
        assert analyzed["memoryless_usage"] == "RenderTarget"
        dynamic_ids = AuditTranscripts(
            **{
                **good.__dict__,
                "root": good.root.replace(
                    "1 other session active.", "3 other sessions active."
                ).replace("59 objects", "73 objects"),
                "commands": good.commands.replace(
                    '"MTLCommandQueue 1"', '"MTLCommandQueue 12"'
                ),
                "private_encoder": good.private_encoder.replace("@tex30", "@tex4"),
                "memoryless_encoder": good.memoryless_encoder.replace(
                    "@tex31", "@tex105"
                ),
                "api_calls": good.api_calls.replace("@tex30", "@tex4")
                .replace("@tex31", "@tex105")
                .replace("@cq0", "@cq27"),
            }
        )
        assert analyze_transcripts(dynamic_ids)["resources"] == "73"
        for field, original, replacement in (
            ("private_encoder", "@tex30", "@tex31"),
            ("private_encoder", "@tex30", "@tex9"),
            ("memoryless_encoder", "@tex31", "@tex30"),
            ("memoryless_encoder", "@tex31", "@tex9"),
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
            ("api0   @tex30", "api0   @tex9"),
            ("api1   @tex31", "api1   @tex9"),
            ("[@tex30 setLabel", "[@tex9 setLabel"),
            ("[@tex31 setLabel", "[@tex9 setLabel"),
            ("[MTLDevice newTextureWithDescriptor", "[@dev newTextureWithDescriptor"),
            ("[@cq0 commandBufferWithDescriptor", "[@queue commandBufferWithDescriptor"),
            ("[MTLCommandBuffer setLabel", "[@cb0 setLabel"),
            (
                "[MTLCommandBuffer renderCommandEncoderWithDescriptor",
                "[@cb0 renderCommandEncoderWithDescriptor",
            ),
            ("[MTLRenderCommandEncoder setLabel", "[@re0 setLabel"),
            ("[MTLRenderCommandEncoder endEncoding", "[@re0 endEncoding"),
            ("[MTLCommandBuffer addCompletedHandler:]", "[@cb0 addCompletedHandler:]"),
            ("[MTLCommandBuffer commit]", "[@cb0 commit]"),
        )
        for original, replacement in wrong_object_replacements:
            mutated = good.api_calls.replace(original, replacement, 1)
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
            good.api_calls.replace(
                "[MTLCommandBuffer commit]",
                "[MTLCommandBuffer commit:unexpected]",
            ),
            good.api_calls.replace(
                "[MTLCommandBuffer commit]",
                "[MTLCommandBuffer commit unexpected]",
            ),
            good.api_calls.replace(
                "[MTLRenderCommandEncoder endEncoding]",
                "[MTLRenderCommandEncoder endEncoding:unexpected]",
                1,
            ),
            good.api_calls.replace(
                "[@cq0 commandBufferWithDescriptor:<descriptor>]",
                "[@cq0 commandBuffer]",
            ),
            good.api_calls.replace(
                "[@cq0 commandBufferWithDescriptor:<descriptor>]",
                "[@cq0 commandBufferWithUnretainedReferences]",
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

        factory_indices = (0, 1)
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

        nonfactory_indices = tuple(range(2, 14))
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

        for api_index in range(14):
            missing_receiver = re.sub(
                rf"(^[ \t]*api{api_index}[ \t]+.*?\[)"
                r"[@A-Za-z][A-Za-z0-9_]*[ \t]+",
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
            'api0   @tex30  [MTLDevice newTextureWithDescriptor:<descriptor>]  info\n'
        )
        duplicate_api_fixtures = (
            good.api_calls.replace(api0_row, api0_row + api0_row),
            good.api_calls.replace(api0_row, api0_row + "api0 malformed\n"),
            good.api_calls.replace(
                api0_row,
                api0_row
                + 'api0   @tex9  [MTLDevice newTextureWithDescriptor:<other>]  info\n',
            ),
            good.api_calls + "(14 items)\n",
            good.api_calls + "(13 items)\n",
            good.api_calls.replace("(14 items)", "(13 items)"),
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
                            'cb0   2 encoders  "MTLCommandQueue 1"       go\n',
                            'cb0   2 encoders  "MTLCommandQueue 1"       go\n'
                            'cb0   2 encoders  "MTLCommandQueue 1"       go\n',
                        ),
                    }
                )
            ),
        )
        _expect_semantic(
            "BLOCKED",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{**good.__dict__, "tool_version": "gpudebug 2.0\n"}
                )
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
            "FAIL",
            lambda: analyze_transcripts(
                AuditTranscripts(
                    **{
                        **good.__dict__,
                        "root": good.root.replace("14 API calls", "15 API calls"),
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
                        "api_calls": good.api_calls.replace("(14 items)", ""),
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
                            "addCompletedHandler:",
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
                            "[MTLCommandBuffer commit]",
                            "[MTLCommandBuffer presentDrawable:@drawable]",
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
                            "addCompletedHandler:", "waitUntilCompleted"
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
                            "api1   @tex31", "api99  @tex31"
                        ).replace("api2          ", "api1          ").replace(
                            "api99  @tex31", "api2   @tex31"
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
                            "storageMode: Private\n", ""
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
                            "storageMode: Private", "storageMode: Shared"
                        ),
                    }
                )
            ),
        )
        for field, old, new in (
            ("private_attachment", "dimensions: 4x4", "dimensions: 8x8"),
            (
                "memoryless_attachment",
                "pixelFormat: RGBA8Unorm",
                "pixelFormat: BGRA8Unorm",
            ),
        ):
            _expect_semantic(
                "FAIL",
                lambda name=field, before=old, after=new: analyze_transcripts(
                    AuditTranscripts(
                        **{
                            **good.__dict__,
                            name: good.__dict__[name].replace(before, after),
                        }
                    )
                ),
            )

        attachment_singletons = (
            (
                "private_attachment",
                "label: RIOS private 4x4",
                "label: wrong private label",
            ),
            (
                "private_attachment",
                "usage: RenderTarget",
                "usage: ShaderRead",
            ),
            (
                "private_attachment",
                "allocatedSize: 128 bytes",
                "allocatedSize: 64 bytes",
            ),
            (
                "private_attachment",
                "textureType: 2D",
                "textureType: 2DArray",
            ),
            (
                "memoryless_attachment",
                "label: RIOS memoryless 4x4",
                "label: wrong memoryless label",
            ),
            (
                "memoryless_attachment",
                "usage: RenderTarget",
                "usage: ShaderRead",
            ),
            (
                "memoryless_attachment",
                "allocatedSize: 0 bytes",
                "allocatedSize: 128 bytes",
            ),
            (
                "memoryless_attachment",
                "textureType: 2D",
                "textureType: Cube",
            ),
        )
        for field, exact_line, wrong_line in attachment_singletons:
            source = good.__dict__[field]
            missing = source.replace(f"{exact_line}\n", "", 1)
            wrong = source.replace(exact_line, wrong_line, 1)
            duplicate = source.replace(
                f"{exact_line}\n",
                f"{exact_line}\n{exact_line}\n",
                1,
            )
            assert missing != source and wrong != source and duplicate != source
            _expect_semantic(
                "BLOCKED",
                lambda name=field, payload=missing: analyze_transcripts(
                    AuditTranscripts(**{**good.__dict__, name: payload})
                ),
            )
            _expect_semantic(
                "FAIL",
                lambda name=field, payload=wrong: analyze_transcripts(
                    AuditTranscripts(**{**good.__dict__, name: payload})
                ),
            )
            _expect_semantic(
                "BLOCKED",
                lambda name=field, payload=duplicate: analyze_transcripts(
                    AuditTranscripts(**{**good.__dict__, name: payload})
                ),
            )

        fake_tool = root / "fake-gpudebug"
        fake_trace = root / CAPTURE_NAME
        fake_trace.write_bytes(b"private raw trace fixture")
        fake_audit = root / "audit.txt"
        fake_audit.write_text("schema=self-test\n", encoding="utf-8")
        fake_audit.chmod(0o600)
        fake_state = root / "fake-gpudebug-state"

        fake_outputs = {
            "go commands": good.commands,
            "go commands/cb0": good.command_buffer,
            "go commands/cb0/re0": good.private_encoder,
            "go commands/cb0/re1": good.memoryless_encoder,
            "go api_calls": "RAW-TRACE-MUST-NOT-LEAK\n",
            "list --all": good.api_calls,
            "go commands/cb0/re0|info color0": good.private_attachment,
            "go commands/cb0/re1|info color0": good.memoryless_attachment,
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
            "if args == ['--version']:\n"
            "    print('gpudebug 1.0')\n"
            "    raise SystemExit(0)\n"
            "if '--terminate' in args:\n"
            "    state_path.unlink(missing_ok=True)\n"
            "    raise SystemExit(0)\n"
            "commands = [args[index + 1] for index, value in enumerate(args) "
            "if value == '-c']\n"
            "if '-t' in args:\n"
            "    if commands != ['list']:\n"
            "        raise SystemExit(46)\n"
            "    state_path.write_text('/', encoding='utf-8')\n"
            "    trace_name = pathlib.Path(args[args.index('-t') + 1]).name\n"
            "    if trace_name == 'fail-after-create-timeout.gputrace':\n"
            "        print('Session 7 created.')\n"
            "        print('gpudebug -s 7 -c <command> to send commands.', flush=True)\n"
            "        time.sleep(30)\n"
            "    if trace_name == 'fail-after-create-nonzero.gputrace':\n"
            "        print('Session 7 created.')\n"
            "        print('gpudebug -s 7 -c <command> to send commands.', flush=True)\n"
            "        raise SystemExit(52)\n"
            "    if trace_name == 'fail-session-banner-drift.gputrace':\n"
            f"        print({good.root.replace('Session 7 created.', 'Session seven created.')!r}, end='')\n"
            "        raise SystemExit(0)\n"
            f"    print({good.root!r}, end='')\n"
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
        assert _owned_session_from_output(
            "Session 7 created.\n"
            "gpudebug -s 8 -c <command> to send commands.\n"
        ) is None
        for failure_name in (
            "fail-after-create-timeout.gputrace",
            "fail-after-create-nonzero.gputrace",
            "fail-session-banner-drift.gputrace",
        ):
            failure_trace = root / failure_name
            failure_trace.write_bytes(b"private raw trace failure fixture")
            _expect_semantic(
                "BLOCKED",
                lambda path=failure_trace: collect_transcripts(
                    fake_tool, path, 1, 5
                ),
            )
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
