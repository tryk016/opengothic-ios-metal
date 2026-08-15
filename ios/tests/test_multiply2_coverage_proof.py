#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR_PATH = ROOT / "ios/device-test/validate-multiply2-coverage-proof.py"
SPEC = importlib.util.spec_from_file_location("multiply2_coverage_validator",
                                              VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)

SHA = "0123456789abcdef0123456789abcdef01234567"
PROOF = bytes.fromhex("00112233445566778899aabbccddeeff")


def coverage() -> bytes:
    header = bytearray(160)
    header[:8] = b"RIOSMC9\0"
    struct.pack_into("<HHI", header, 8, 1, 0x4C45, 160)
    struct.pack_into("<IIII", header, 16, 2, 2, 2, 1)
    struct.pack_into("<QQQQQQ", header, 32, 4, 7, 9, 11, 24, 6)
    struct.pack_into("<IIII", header, 80, 0, 0, 2, 2)
    struct.pack_into("<IIII", header, 96, 0, 0, 2, 2)
    header[112:128] = PROOF
    header[128:148] = bytes.fromhex(SHA)
    return bytes(header) + b"\0\1\1\0"


def hdr() -> bytes:
    header = bytearray(160)
    header[:8] = b"RIOSR11\0"
    struct.pack_into("<HHII", header, 8, 1, 160, 1, 1)
    struct.pack_into("<III", header, 20, 2, 2, 8)
    struct.pack_into("<QQQ", header, 32, 16, 7, 9)
    header[64:80] = PROOF
    header[80:100] = bytes.fromhex(SHA)
    return bytes(header) + bytes(16)


def success() -> bytes:
    return ("RendererIOS multiply2 coverage: v=1 g=7 s=9 source=11 "
            "width=2 height=2 terminal=C\n").encode("ascii")


class CoverageProofTest(unittest.TestCase):
    def write_fixture(self, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path,
                                                         pathlib.Path]:
        coverage_path = root / "RendererIOS-multiply2-coverage-v1.bin"
        hdr_path = root / "RendererIOS-linear-hdr-proof-v1.bin"
        log_path = root / "log.txt"
        coverage_path.write_bytes(coverage())
        hdr_path.write_bytes(hdr())
        log_path.write_bytes(success())
        return coverage_path, hdr_path, log_path

    def test_exact_join_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_fixture(pathlib.Path(directory))
            parsed = VALIDATOR.validate(*paths, SHA)
            self.assertEqual(parsed["source"], 11)
            self.assertEqual(parsed["indexOffset"], 24)
            self.assertEqual(parsed["indexCount"], 6)

    def test_header_and_payload_mutations_fail(self) -> None:
        mutations = {
            "magic": (0, ord("X")),
            "endian": (10, 0),
            "header": (12, 159),
            "sample": (28, 2),
            "viewport": (80, 1),
            "flags": (148, 1),
            "reserved": (152, 1),
            "invalid-payload": (161, 2),
        }
        for label, (offset, value) in mutations.items():
            with self.subTest(label=label):
                candidate = bytearray(coverage())
                candidate[offset] = value
                with self.assertRaises(VALIDATOR.ValidationError):
                    VALIDATOR.parse_coverage(bytes(candidate))
        with self.assertRaises(VALIDATOR.ValidationError):
            VALIDATOR.parse_coverage(coverage()[:160] + bytes(4))
        with self.assertRaises(VALIDATOR.ValidationError):
            VALIDATOR.parse_coverage(coverage() + b"\0")

    def test_join_and_terminal_mutations_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            coverage_path, hdr_path, log_path = self.write_fixture(root)
            for label, replacement in {
                "generation": b"g=8",
                "sequence": b"s=8",
                "source": b"source=12",
                "width": b"width=3",
            }.items():
                with self.subTest(label=label):
                    log_path.write_bytes(success().replace(
                        {"generation": b"g=7", "sequence": b"s=9",
                         "source": b"source=11", "width": b"width=2"}[label],
                        replacement))
                    with self.assertRaises(VALIDATOR.ValidationError):
                        VALIDATOR.validate(coverage_path, hdr_path, log_path, SHA)
            log_path.write_bytes(success())
            changed_hdr = bytearray(hdr())
            changed_hdr[64] ^= 1
            hdr_path.write_bytes(changed_hdr)
            with self.assertRaises(VALIDATOR.ValidationError):
                VALIDATOR.validate(coverage_path, hdr_path, log_path, SHA)

    def test_cli_emits_only_coverage_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_fixture(pathlib.Path(directory))
            completed = subprocess.run(
                [sys.executable, str(VALIDATOR_PATH), "--coverage", str(paths[0]),
                 "--hdr-artifact", str(paths[1]), "--runtime-log", str(paths[2]),
                 "--expected-sha", SHA], check=False, capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(completed.stdout, "COVERAGE PASS\n")
            self.assertEqual(completed.stderr, "")


if __name__ == "__main__":
    unittest.main()
