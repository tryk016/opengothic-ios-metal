#!/usr/bin/env python3
"""Validate and fingerprint the RendererIOS programmatic Metal capture."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
import tempfile
from pathlib import Path


CAPTURE_NAME = "RendererIOS-pm-clear-v1.gputrace"
MAX_CAPTURE_BYTES = 512 * 1024 * 1024


class CaptureValidationError(RuntimeError):
    pass


def _sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def validate_capture(path: Path) -> dict[str, str]:
    try:
        root_stat = path.lstat()
    except FileNotFoundError as exc:
        raise CaptureValidationError("capture artifact is missing") from exc

    if path.name != CAPTURE_NAME:
        raise CaptureValidationError("capture artifact has the wrong flat name")
    if stat.S_ISLNK(root_stat.st_mode):
        raise CaptureValidationError("capture artifact must not be a symlink")

    if stat.S_ISREG(root_stat.st_mode):
        digest, size = _sha256_file(path)
        if size <= 0:
            raise CaptureValidationError("capture file is empty")
        if size > MAX_CAPTURE_BYTES:
            raise CaptureValidationError("capture file exceeds the accepted byte limit")
        return {
            "capture_name": CAPTURE_NAME,
            "capture_kind": "file",
            "capture_bytes": str(size),
            "capture_manifest_sha256": digest,
        }

    if not stat.S_ISDIR(root_stat.st_mode):
        raise CaptureValidationError("capture artifact is neither a file nor a directory")

    def walk_error(error: OSError) -> None:
        raise error

    entries: list[tuple[bytes, str, str, int]] = []
    for current, directory_names, file_names in os.walk(
        path, followlinks=False, onerror=walk_error
    ):
        current_path = Path(current)
        for name in directory_names + file_names:
            candidate = current_path / name
            candidate_stat = candidate.lstat()
            if stat.S_ISLNK(candidate_stat.st_mode):
                raise CaptureValidationError("capture package contains a symlink")
            if stat.S_ISDIR(candidate_stat.st_mode):
                continue
            if not stat.S_ISREG(candidate_stat.st_mode):
                raise CaptureValidationError("capture package contains a special node")
            relative = candidate.relative_to(path).as_posix()
            if "\n" in relative or "\r" in relative:
                raise CaptureValidationError("capture package path contains a line break")
            digest, size = _sha256_file(candidate)
            entries.append((os.fsencode(relative), relative, digest, size))

    if not entries:
        raise CaptureValidationError("capture package has no regular-file content")
    entries.sort(key=lambda item: item[0])
    total_bytes = sum(item[3] for item in entries)
    if total_bytes <= 0:
        raise CaptureValidationError("capture package regular-file content is empty")
    if total_bytes > MAX_CAPTURE_BYTES:
        raise CaptureValidationError("capture package exceeds the accepted byte limit")

    manifest = "".join(
        f"{digest}  {relative}\n" for _, relative, digest, _ in entries
    ).encode("utf-8", errors="surrogateescape")
    return {
        "capture_name": CAPTURE_NAME,
        "capture_kind": "directory",
        "capture_bytes": str(total_bytes),
        "capture_manifest_sha256": hashlib.sha256(manifest).hexdigest(),
    }


def write_summary(summary: dict[str, str], destination: Path | None) -> None:
    payload = "".join(f"{key}={summary[key]}\n" for key in (
        "capture_name",
        "capture_kind",
        "capture_bytes",
        "capture_manifest_sha256",
    ))
    if destination is None:
        sys.stdout.write(payload)
    else:
        destination.write_text(payload, encoding="utf-8")


def expect_rejected(path: Path) -> None:
    try:
        validate_capture(path)
    except CaptureValidationError:
        return
    raise AssertionError(f"invalid fixture unexpectedly accepted: {path}")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="rendererios-capture-validator-") as root_raw:
        root = Path(root_raw)

        capture_file = root / "file" / CAPTURE_NAME
        capture_file.parent.mkdir()
        capture_file.write_bytes(b"metal-capture-file\0")
        file_summary = validate_capture(capture_file)
        assert file_summary["capture_kind"] == "file"
        assert file_summary["capture_bytes"] == str(capture_file.stat().st_size)

        capture_directory = root / "directory" / CAPTURE_NAME
        (capture_directory / "nested").mkdir(parents=True)
        (capture_directory / "z.bin").write_bytes(b"z")
        (capture_directory / "nested" / "a.bin").write_bytes(b"alpha")
        (capture_directory / "empty.bin").write_bytes(b"")
        directory_summary = validate_capture(capture_directory)
        assert directory_summary["capture_kind"] == "directory"
        assert directory_summary["capture_bytes"] == "6"
        assert directory_summary == validate_capture(capture_directory)

        normalized_directory = root / "normalized-apple" / CAPTURE_NAME
        normalized_directory.mkdir(parents=True)
        apple_payload = b"apple-shared-resource"
        for name in (
            "MTLTexture-26-0-mipmap0-slice0",
            "MTLTexture-27-0-mipmap0-slice0",
            "MTLTexture-28-0-mipmap0-slice0",
        ):
            (normalized_directory / name).write_bytes(apple_payload)
        (normalized_directory / "capture").write_bytes(b"meta")
        normalized_summary = validate_capture(normalized_directory)
        assert normalized_summary["capture_kind"] == "directory"
        assert normalized_summary["capture_bytes"] == str(len(apple_payload) * 3 + 4)
        original_manifest = directory_summary["capture_manifest_sha256"]
        (capture_directory / "nested" / "a.bin").write_bytes(b"alphb")
        changed_summary = validate_capture(capture_directory)
        assert changed_summary["capture_bytes"] == "6"
        assert changed_summary["capture_manifest_sha256"] != original_manifest

        empty_file = root / "empty-file" / CAPTURE_NAME
        empty_file.parent.mkdir()
        empty_file.touch()
        expect_rejected(empty_file)

        oversized_file = root / "oversized-file" / CAPTURE_NAME
        oversized_file.parent.mkdir()
        with oversized_file.open("wb") as stream:
            stream.truncate(MAX_CAPTURE_BYTES + 1)
        expect_rejected(oversized_file)

        empty_directory = root / "empty-directory" / CAPTURE_NAME
        empty_directory.mkdir(parents=True)
        expect_rejected(empty_directory)

        zero_byte_directory = root / "zero-byte-directory" / CAPTURE_NAME
        zero_byte_directory.mkdir(parents=True)
        (zero_byte_directory / "empty-a.bin").touch()
        (zero_byte_directory / "empty-b.bin").touch()
        expect_rejected(zero_byte_directory)

        symlink_capture = root / "symlink" / CAPTURE_NAME
        symlink_capture.parent.mkdir()
        symlink_capture.symlink_to(capture_file)
        expect_rejected(symlink_capture)

        nested_symlink = root / "nested-symlink" / CAPTURE_NAME
        nested_symlink.mkdir(parents=True)
        (nested_symlink / "data.bin").write_bytes(b"data")
        (nested_symlink / "alias.bin").symlink_to(nested_symlink / "data.bin")
        expect_rejected(nested_symlink)

        if hasattr(os, "mkfifo"):
            special = root / "special" / CAPTURE_NAME
            special.mkdir(parents=True)
            (special / "data.bin").write_bytes(b"data")
            os.mkfifo(special / "pipe")
            expect_rejected(special)

        wrong_name = root / "wrong.gputrace"
        wrong_name.write_bytes(b"data")
        expect_rejected(wrong_name)

    print("Metal capture artifact validator self-test: PASS")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        if args.artifact is not None or args.summary is not None:
            parser.error("--self-test cannot be combined with artifact arguments")
    elif args.artifact is None:
        parser.error("--artifact is required unless --self-test is used")
    return args


def main() -> int:
    args = parse_args()
    try:
        if args.self_test:
            self_test()
        else:
            write_summary(validate_capture(args.artifact), args.summary)
    except (CaptureValidationError, OSError, AssertionError) as exc:
        print(f"Metal capture artifact validation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
