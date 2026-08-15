#!/usr/bin/env python3
"""Validate and join one canonical Multiply2 stencil-coverage proof."""

from __future__ import annotations

import argparse
import pathlib
import re
import stat
import struct
import sys


HEADER_BYTES = 160
HDR_HEADER_BYTES = 160
MAX_EXTENT = 4096
MAX_PAYLOAD_BYTES = MAX_EXTENT * MAX_EXTENT
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
SUCCESS_PREFIX = "RendererIOS multiply2 coverage:"
SUCCESS_RE = re.compile(
    r"^RendererIOS multiply2 coverage: v=1 "
    r"g=([1-9][0-9]*) s=([1-9][0-9]*) "
    r"source=([1-9][0-9]*) width=([1-9][0-9]*) "
    r"height=([1-9][0-9]*) terminal=C$"
)
FAIL_RE = re.compile(
    r"^RendererIOS multiply2 coverage: v=1 terminal=F "
    r"reason=([a-z][a-z0-9-]*)$"
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def regular_file(path: pathlib.Path, label: str,
                 maximum: int) -> bytes:
    status = path.lstat()
    require(stat.S_ISREG(status.st_mode),
            f"{label} is not an lstat-regular file")
    require(0 < status.st_size <= maximum,
            f"{label} size is outside its bound")
    data = path.read_bytes()
    require(len(data) == status.st_size,
            f"{label} changed while it was read")
    return data


def positive(raw: str, label: str, maximum: int) -> int:
    require(re.fullmatch(r"[1-9][0-9]*", raw) is not None,
            f"{label} is not canonical positive decimal")
    value = int(raw, 10)
    require(value <= maximum, f"{label} exceeds its unsigned range")
    return value


def parse_coverage(data: bytes) -> dict[str, int | bytes]:
    require(len(data) >= HEADER_BYTES,
            "coverage artifact is shorter than its v1 header")
    require(data[:8] == b"RIOSMC9\0", "coverage magic is not exact")
    schema, endian, header = struct.unpack_from("<HHI", data, 8)
    require((schema, endian, header) == (1, 0x4C45, HEADER_BYTES),
            "coverage schema/endian/header tuple is not exact v1")
    width, height, row, samples = struct.unpack_from("<IIII", data, 16)
    payload, generation, sequence, source, index_offset, index_count = \
        struct.unpack_from("<QQQQQQ", data, 32)
    viewport = struct.unpack_from("<IIII", data, 80)
    scissor = struct.unpack_from("<IIII", data, 96)
    proof_id = data[112:128]
    build_sha = data[128:148]
    flags = struct.unpack_from("<I", data, 148)[0]
    reserved = struct.unpack_from("<Q", data, 152)[0]

    require(0 < width <= MAX_EXTENT and 0 < height <= MAX_EXTENT,
            "coverage extent is invalid")
    require(row == width, "coverage row pitch is not tight R8")
    require(samples == 1, "coverage sample count is not one")
    require(payload == width * height and payload <= MAX_PAYLOAD_BYTES,
            "coverage payload byte count is invalid")
    require(len(data) == HEADER_BYTES + payload,
            "coverage artifact has truncation or trailing bytes")
    require(generation > 0 and sequence > 0 and source > 0 and index_count > 0,
            "coverage draw identity contains zero")
    exact_rect = (0, 0, width, height)
    require(viewport == exact_rect and scissor == exact_rect,
            "coverage viewport/scissor is not the full exact target")
    require(any(proof_id) and any(build_sha),
            "coverage proof/build identity is zero")
    require(flags == 0 and reserved == 0,
            "coverage reserved fields are nonzero")
    mask = data[HEADER_BYTES:]
    require(all(value in (0, 1) for value in mask),
            "coverage payload contains a value other than 0 or 1")
    require(1 in mask, "coverage payload contains no covered sample")
    return {
        "width": width, "height": height, "row": row, "samples": samples,
        "payload": payload, "generation": generation, "sequence": sequence,
        "source": source, "indexOffset": index_offset,
        "indexCount": index_count, "proofId": proof_id,
        "buildSha": build_sha,
    }


def parse_hdr_identity(data: bytes) -> dict[str, int | bytes]:
    require(len(data) >= HDR_HEADER_BYTES,
            "HDR artifact is shorter than its v1 header")
    require(data[:8] == b"RIOSR11\0", "HDR artifact magic is not exact")
    schema, header, producer, pixel_format = struct.unpack_from("<HHII", data, 8)
    require((schema, header, producer, pixel_format) == (1, 160, 1, 1),
            "HDR artifact schema/producer/format tuple is not v1")
    width, height, row = struct.unpack_from("<III", data, 20)
    logical, generation, sequence = struct.unpack_from("<QQQ", data, 32)
    proof_id = data[64:80]
    build_sha = data[80:100]
    require(width > 0 and height > 0 and row == width * 4 and
            logical == row * height and len(data) == HDR_HEADER_BYTES + logical,
            "HDR artifact extent/size identity is invalid")
    require(generation > 0 and sequence > 0 and any(proof_id) and any(build_sha),
            "HDR artifact identity contains zero")
    return {
        "width": width, "height": height, "generation": generation,
        "sequence": sequence, "proofId": proof_id, "buildSha": build_sha,
    }


def parse_runtime_log(data: bytes, coverage: dict[str, int | bytes]) -> None:
    require(len(data) <= 64 * 1024 * 1024, "runtime log is unbounded")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationError("runtime log is not UTF-8") from error
    successes: list[tuple[str, ...]] = []
    failures = 0
    for line in text.splitlines():
        if SUCCESS_PREFIX not in line:
            continue
        require(line.startswith(SUCCESS_PREFIX),
                "coverage marker has a foreign line prefix")
        require(line.isascii() and len(line.encode("ascii")) < 255,
                "coverage marker is non-ASCII or too long")
        success = SUCCESS_RE.fullmatch(line)
        failure = FAIL_RE.fullmatch(line)
        require(success is not None or failure is not None,
                "coverage marker is not an exact success/failure line")
        if success is not None:
            successes.append(success.groups())
        else:
            failures += 1
    require(failures == 0, "runtime log contains a coverage terminal failure")
    expected = (
        int(coverage["generation"]), int(coverage["sequence"]),
        int(coverage["source"]), int(coverage["width"]),
        int(coverage["height"]),
    )
    matching: list[tuple[int, ...]] = []
    for raw in successes:
        parsed = tuple(positive(value, "coverage log value", (1 << 64) - 1)
                       for value in raw)
        if parsed == expected:
            matching.append(parsed)
    require(len(matching) == 1,
            f"expected exactly one matching coverage terminal=C, found {len(matching)}")


def validate(coverage_path: pathlib.Path, hdr_path: pathlib.Path,
             log_path: pathlib.Path, expected_sha: str) -> dict[str, int | bytes]:
    require(SHA_RE.fullmatch(expected_sha) is not None,
            "expected SHA is not exact lowercase 40-hex")
    coverage = parse_coverage(regular_file(
        coverage_path, "coverage artifact", HEADER_BYTES + MAX_PAYLOAD_BYTES))
    hdr = parse_hdr_identity(regular_file(
        hdr_path, "HDR artifact", HDR_HEADER_BYTES + 256 * 1024 * 1024))
    expected_build = bytes.fromhex(expected_sha)
    require(coverage["buildSha"] == expected_build,
            "coverage build SHA does not match expected exact SHA")
    for key in ("width", "height", "generation", "sequence", "proofId", "buildSha"):
        require(coverage[key] == hdr[key], f"coverage/HDR {key} join mismatch")
    parse_runtime_log(regular_file(log_path, "runtime log", 64 * 1024 * 1024),
                      coverage)
    return coverage


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--coverage", required=True, type=pathlib.Path)
    parser.add_argument("--hdr-artifact", required=True, type=pathlib.Path)
    parser.add_argument("--runtime-log", required=True, type=pathlib.Path)
    parser.add_argument("--expected-sha", required=True)
    args = parser.parse_args()
    try:
        validate(args.coverage, args.hdr_artifact, args.runtime_log,
                 args.expected_sha)
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("COVERAGE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
