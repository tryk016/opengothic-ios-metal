#!/usr/bin/env python3
"""Join one lossless RendererIOS HDR artifact to its runtime terminal log."""

from __future__ import annotations

import argparse
import pathlib
import re
import stat
import struct
import sys


HEADER_BYTES = 160
MAX_EXTENT = 16384
MAX_PAYLOAD_BYTES = 256 * 1024 * 1024
SUCCESS_PREFIX = "RendererIOS HDR proof:"
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
SUCCESS_RE = re.compile(
    r"^RendererIOS HDR proof: v=1 id=([0-9a-f]{32}) "
    r"b=([0-9a-f]{40}) g=([1-9][0-9]*) s=([1-9][0-9]*) "
    r"w=([1-9][0-9]*) h=([1-9][0-9]*) "
    r"row=([1-9][0-9]*) bytes=([1-9][0-9]*) "
    r"f=r11 m=0 a=0 terminal=C$"
)
FAIL_RE = re.compile(
    r"^RendererIOS HDR proof: v=1 id=([0-9a-f]{32}|none) "
    r"terminal=F class=(contract|gpu|io) "
    r"reason=(rng|rng-zero|sha|layout|state|target|label|buffer-alloc|"
    r"buffer-map|copy-encode|submit-ambiguous|fence|idle|present|stale|"
    r"parse|open|write|file-fsync|close|rename|dir-fsync|cleanup)$"
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def regular_file(path: pathlib.Path, label: str) -> bytes:
    status = path.lstat()
    require(stat.S_ISREG(status.st_mode), f"{label} is not an lstat-regular file")
    return path.read_bytes()


def canonical_positive(raw: str, label: str, maximum: int) -> int:
    require(re.fullmatch(r"[1-9][0-9]*", raw) is not None,
            f"{label} is not canonical positive decimal")
    value = int(raw, 10)
    require(value <= maximum, f"{label} exceeds its unsigned range")
    return value


def decode_component(encoded: int, mantissa_bits: int) -> float:
    exponent = encoded >> mantissa_bits
    mantissa = encoded & ((1 << mantissa_bits) - 1)
    require(exponent != 31, "artifact contains an Inf/NaN packed component")
    if exponent == 0:
        return mantissa * (2.0 ** (-14 - mantissa_bits))
    return (1.0 + mantissa / float(1 << mantissa_bits)) * (2.0 ** (exponent - 15))


def parse_artifact(data: bytes) -> dict[str, int | str | float]:
    require(len(data) >= HEADER_BYTES, "artifact is shorter than its v1 header")
    require(data[:8] == b"RIOSR11\0", "artifact magic is not exact")
    schema, header_bytes = struct.unpack_from("<HH", data, 8)
    producer, pixel_format = struct.unpack_from("<II", data, 12)
    require((schema, header_bytes, producer, pixel_format) == (1, 160, 1, 1),
            "artifact schema/producer/format tuple is not v1")
    width, height, row = struct.unpack_from("<III", data, 20)
    logical, generation, sequence = struct.unpack_from("<QQQ", data, 32)
    mip, array_slice = struct.unpack_from("<II", data, 56)
    proof = data[64:80]
    build = data[80:100]
    require(0 < width <= MAX_EXTENT and 0 < height <= MAX_EXTENT,
            "artifact extent is invalid")
    require(row == width * 4, "artifact row pitch is not tight RG11B10")
    require(logical == row * height and logical <= MAX_PAYLOAD_BYTES,
            "artifact logical byte count is invalid")
    require(len(data) == HEADER_BYTES + logical,
            "artifact has truncation or trailing bytes")
    require(generation > 0 and sequence > 0,
            "artifact generation/sequence identity is zero")
    require(mip == 0 and array_slice == 0,
            "artifact subresource is not mip0/slice0")
    require(any(proof) and any(build), "artifact proof/build identity is zero")
    require(data[100:104] == b"\0" * 4, "artifact reserved word is nonzero")
    proof_hex = proof.hex()
    build_hex = build.hex()
    expected_label = ("RendererIOS.SceneHDR." + proof_hex).encode("ascii")
    require(data[104:157] == expected_label and data[157:160] == b"\0" * 3,
            "artifact resource label is not exact")

    maximum = -1.0
    payload = memoryview(data)[HEADER_BYTES:]
    for offset in range(0, len(payload), 4):
        word = struct.unpack_from("<I", payload, offset)[0]
        values = (
            decode_component(word & 0x7FF, 6),
            decode_component((word >> 11) & 0x7FF, 6),
            decode_component((word >> 22) & 0x3FF, 5),
        )
        maximum = max(maximum, *values)
    require(maximum >= 0.0, "artifact payload has no decodable pixel")
    return {
        "id": proof_hex,
        "build": build_hex,
        "generation": generation,
        "sequence": sequence,
        "width": width,
        "height": height,
        "row": row,
        "bytes": logical,
        "maximum": maximum,
    }


def parse_log(log: str, artifact: dict[str, int | str | float],
              expected_sha: str) -> None:
    require(SHA_RE.fullmatch(expected_sha) is not None,
            "expected SHA is not exact lowercase 40-hex")
    require(artifact["build"] == expected_sha,
            "artifact build SHA does not match expected exact SHA")
    successes: list[tuple[str, ...]] = []
    failures: list[tuple[str, ...]] = []
    for line in log.splitlines():
        if SUCCESS_PREFIX not in line:
            continue
        require(line.startswith(SUCCESS_PREFIX),
                "HDR proof marker has a foreign line prefix")
        require(line.isascii() and len(line.encode("ascii")) < 255,
                "HDR proof marker is non-ASCII or too long")
        success = SUCCESS_RE.fullmatch(line)
        failure = FAIL_RE.fullmatch(line)
        require(success is not None or failure is not None,
                "HDR proof marker is not an exact success/failure line")
        if success is not None:
            successes.append(success.groups())
        else:
            assert failure is not None
            failures.append(failure.groups())

    proof_id = str(artifact["id"])
    require(not any(values[0] == proof_id for values in failures),
            "matching proof ID has a terminal failure")
    matching = [values for values in successes if values[0] == proof_id]
    require(len(matching) == 1,
            f"expected exactly one matching terminal=C, found {len(matching)}")
    values = matching[0]
    build, generation, sequence, width, height, row, logical = values[1:]
    joined = {
        "build": build,
        "generation": canonical_positive(generation, "log generation", (1 << 64) - 1),
        "sequence": canonical_positive(sequence, "log sequence", (1 << 64) - 1),
        "width": canonical_positive(width, "log width", (1 << 32) - 1),
        "height": canonical_positive(height, "log height", (1 << 32) - 1),
        "row": canonical_positive(row, "log row", (1 << 32) - 1),
        "bytes": canonical_positive(logical, "log bytes", (1 << 64) - 1),
    }
    for key, value in joined.items():
        require(value == artifact[key], f"artifact/log {key} join mismatch")


def validate(artifact_path: pathlib.Path, log_path: pathlib.Path,
             expected_sha: str) -> dict[str, int | str | float]:
    artifact = parse_artifact(regular_file(artifact_path, "artifact"))
    log_bytes = regular_file(log_path, "runtime log")
    require(len(log_bytes) <= 64 * 1024 * 1024, "runtime log is unbounded")
    try:
        log = log_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationError("runtime log is not UTF-8") from error
    parse_log(log, artifact, expected_sha)
    return artifact


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", required=True, type=pathlib.Path)
    parser.add_argument("--runtime-log", required=True, type=pathlib.Path)
    parser.add_argument("--expected-sha", required=True)
    args = parser.parse_args()
    try:
        validate(args.artifact, args.runtime_log, args.expected_sha)
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PRODUCER PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
