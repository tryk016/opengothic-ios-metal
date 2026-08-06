#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import struct
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR_PATH = ROOT / "ios/device-test/validate-linear-hdr-proof-artifact.py"
SPEC = importlib.util.spec_from_file_location("linear_hdr_proof_validator", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)

SHA = "0123456789abcdef0123456789abcdef01234567"
PROOF = bytes(range(1, 17))
PROOF_HEX = PROOF.hex()


def artifact(payload: bytes = b"\0" * 16) -> bytes:
    data = bytearray(160 + len(payload))
    data[:8] = b"RIOSR11\0"
    struct.pack_into("<HHIIIIIQQQII", data, 8,
                     1, 160, 1, 1, 2, 2, 8, 16, 7, 9, 0, 0)
    data[64:80] = PROOF
    data[80:100] = bytes.fromhex(SHA)
    data[104:157] = ("RendererIOS.SceneHDR." + PROOF_HEX).encode("ascii")
    data[160:] = payload
    return bytes(data)


def success(**changes: int | str) -> str:
    values: dict[str, int | str] = {
        "id": PROOF_HEX, "build": SHA, "generation": 7, "sequence": 9,
        "width": 2, "height": 2, "row": 8, "bytes": 16,
    }
    values.update(changes)
    return (
        "RendererIOS HDR proof: v=1 id={id} b={build} g={generation} "
        "s={sequence} w={width} h={height} row={row} bytes={bytes} "
        "f=r11 m=0 a=0 terminal=C"
    ).format(**values)


class LinearHDRProofArtifactTests(unittest.TestCase):
    def validate(self, data: bytes, log: str, expected_sha: str = SHA) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            artifact_path = root / "RendererIOS-linear-hdr-proof-v1.bin"
            log_path = root / "log.txt"
            artifact_path.write_bytes(data)
            log_path.write_text(log, encoding="utf-8")
            VALIDATOR.validate(artifact_path, log_path, expected_sha)

    def rejected(self, data: bytes, log: str, expected_sha: str = SHA) -> None:
        with self.assertRaises(VALIDATOR.ValidationError):
            self.validate(data, log, expected_sha)

    def test_exact_join_accepts_maximum_not_above_one(self) -> None:
        self.validate(artifact(), success() + "\n")

    def test_exact_join_accepts_lossless_hdr_payload(self) -> None:
        word = 0x882003C0
        payload = struct.pack("<IIII", word, 0, 0, 0)
        self.validate(artifact(payload), success())

    def test_rejects_missing_or_duplicate_success(self) -> None:
        self.rejected(artifact(), "")
        self.rejected(artifact(), success() + "\n" + success())

    def test_rejects_matching_failure(self) -> None:
        failure = (
            f"RendererIOS HDR proof: v=1 id={PROOF_HEX} terminal=F "
            "class=gpu reason=present"
        )
        self.rejected(artifact(), success() + "\n" + failure)

    def test_rejects_foreign_sha_or_join_field(self) -> None:
        self.rejected(artifact(), success(build="f" * 40))
        self.rejected(artifact(), success(row=4))
        self.rejected(artifact(), success(), "f" * 40)

    def test_rejects_malformed_artifact(self) -> None:
        self.rejected(artifact()[:-1], success())
        bad = bytearray(artifact())
        bad[104] = ord("X")
        self.rejected(bytes(bad), success())
        bad = bytearray(artifact())
        struct.pack_into("<I", bad, 160, 31 << 6)
        self.rejected(bytes(bad), success())

    def test_rejects_quarantined_parseable_final(self) -> None:
        failure = (
            f"RendererIOS HDR proof: v=1 id={PROOF_HEX} terminal=F "
            "class=io reason=dir-fsync"
        )
        self.rejected(artifact(), failure)

    def test_rejects_symlink_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            real = root / "real.bin"
            real.write_bytes(artifact())
            link = root / "artifact.bin"
            link.symlink_to(real)
            log = root / "log.txt"
            log.write_text(success(), encoding="utf-8")
            with self.assertRaises(VALIDATOR.ValidationError):
                VALIDATOR.validate(link, log, SHA)

    def test_cli_emits_only_producer_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            artifact_path = root / "RendererIOS-linear-hdr-proof-v1.bin"
            log_path = root / "log.txt"
            artifact_path.write_bytes(artifact())
            log_path.write_text(success() + "\n", encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(VALIDATOR_PATH),
                 "--artifact", str(artifact_path),
                 "--runtime-log", str(log_path),
                 "--expected-sha", SHA],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(completed.stdout, "PRODUCER PASS\n")
            self.assertEqual(completed.stderr, "")


if __name__ == "__main__":
    unittest.main()
