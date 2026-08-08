#!/usr/bin/env python3

from __future__ import annotations

import copy
import importlib.util
import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from typing import Any, Callable


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ios/device-test/validate-linear-hdr-gpu-evidence.py"
FIXTURE = ROOT / "ios/tests/fixtures/linear-hdr-gpudebug-transcripts-v2.json"
SPEC = importlib.util.spec_from_file_location("linear_hdr_gpu_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)

SHA = "0123456789abcdef0123456789abcdef01234567"
PROOF = bytes(range(1, 17))
PROOF_ID = PROOF.hex()
Mutation = Callable[[dict[str, Any]], None]


def write_0600(path: pathlib.Path, raw: bytes) -> None:
    path.write_bytes(raw)
    path.chmod(0o600)


def artifact() -> bytes:
    word = 0x882003C0
    payload = struct.pack("<I", word) + b"\0" * 44
    data = bytearray(160 + len(payload))
    data[:8] = b"RIOSR11\0"
    struct.pack_into("<HHIIIIIQQQII", data, 8,
                     1, 160, 1, 1, 4, 3, 16, 48, 7, 41, 0, 0)
    data[64:80] = PROOF
    data[80:100] = bytes.fromhex(SHA)
    data[104:157] = ("RendererIOS.SceneHDR." + PROOF_ID).encode("ascii")
    data[160:] = payload
    return bytes(data)


def proof_success() -> str:
    return (
        f"RendererIOS HDR proof: v=1 id={PROOF_ID} b={SHA} g=7 s=41 "
        "w=4 h=3 row=16 bytes=48 f=r11 m=0 a=0 terminal=C"
    )


def transcript_raws(document: dict[str, Any], capture: pathlib.Path) -> dict[str, bytes]:
    command = document["command"]
    resource = document["sceneResource"]
    scene = command["scene"]
    proof = command["proofBlit"]
    tone = command["toneResolve"]
    return {
        "version": b"gpudebug 1.0\n",
        "open": b'{"sessionId":"session-1"}\n',
        "commands": (json.dumps({"path": "commands/cb4", "label": scene["marker"]}) + "\n").encode(),
        "command-buffer": (json.dumps([
            {"path": scene["encoderPath"], "label": scene["marker"]},
            {"path": proof["encoderPath"], "label": proof["marker"]},
            {"path": tone["encoderPath"], "label": tone["marker"]},
        ]) + "\n").encode(),
        "scene-encoder": (json.dumps({"label": scene["marker"], "attachment": "color0",
                                       "textureRef": resource["textureRef"]}) + "\n").encode(),
        "scene-color0": (json.dumps({**resource, "width": 4, "height": 3}) + "\n").encode(),
        "proof-encoder": (json.dumps({"label": proof["marker"],
                                       "commandPath": proof["commandPath"]}) + "\n").encode(),
        "proof-blit": (json.dumps({"sourceTextureRef": resource["textureRef"],
                                    "sourceLevel": 0, "sourceSlice": 0}) + "\n").encode(),
        "tone-encoder": (json.dumps({"label": tone["marker"],
                                      "drawPath": tone["drawPath"]}) + "\n").encode(),
        "tone-fragment": (json.dumps({"fragmentTextureIndex": 0,
                                       "textureRef": resource["textureRef"]}) + "\n").encode(),
        "tone-tex0": (json.dumps({"textureRef": resource["textureRef"],
                                   "allocationID": resource["allocationID"],
                                   "resourceIndex": resource["resourceIndex"]}) + "\n").encode(),
        "scene-resource": (json.dumps({"textureRef": resource["textureRef"],
                                        "allocationID": resource["allocationID"],
                                        "resourceIndex": resource["resourceIndex"]}) + "\n").encode(),
        "terminate": b'{"terminated":true}\n',
        "sessions-after": b'{"sessions":[]}\n',
    }


def make_join(root: pathlib.Path) -> tuple[dict[str, Any], dict[str, pathlib.Path]]:
    document = json.loads(FIXTURE.read_text(encoding="utf-8"))
    capture = root / VALIDATOR.CAPTURE_LEAF
    capture.mkdir()
    (capture / "capture").write_bytes(b"capture")
    (capture / "metadata").write_bytes(b"metadata")
    artifact_path = root / "RendererIOS-linear-hdr-proof-v1.bin"
    write_0600(artifact_path, artifact())
    artifact_values = VALIDATOR.load_artifact_validator().parse_artifact(artifact())
    document["numeric"] = {
        "encoding": "packed-rg11b10float-le",
        "maximumX": artifact_values["maximumX"],
        "maximumY": artifact_values["maximumY"],
        "maximumChannel": artifact_values["maximumChannel"],
        "packedWord": artifact_values["packedWord"],
        "valueHex": artifact_values["valueHex"],
        "aboveOne": True,
    }
    kind, capture_bytes, manifest = VALIDATOR.stable_capture_manifest(capture)
    log_path = root / "log.txt"
    capture_line = (
        f"RendererIOS HDR capture: v=1 id={PROOF_ID} "
        f"file={VALIDATOR.CAPTURE_LEAF} kind={kind} bytes={capture_bytes} terminal=C"
    )
    log_raw = (proof_success() + "\n" + capture_line + "\n").encode()
    write_0600(log_path, log_raw)
    summary = {
        "schemaVersion": 1, "proofId": PROOF_ID, "file": VALIDATOR.CAPTURE_LEAF,
        "kind": kind, "bytes": capture_bytes, "manifestSha256": manifest,
        "runtimeMarkerSha256": VALIDATOR.sha256((capture_line + "\n").encode()),
        "evidenceCommitted": True,
    }
    summary_path = root / VALIDATOR.SUMMARY_LEAF
    summary_raw = VALIDATOR.canonical_json_bytes(summary)
    write_0600(summary_path, summary_raw)
    transcript_dir = root / "transcripts"
    transcript_dir.mkdir()
    raws = transcript_raws(document, capture)
    entries = []
    session = "session-1"
    names = VALIDATOR.expected_filenames(document["command"])
    for role in VALIDATOR.ROLE_ORDER:
        raw = raws[role]
        filename = names[role]
        write_0600(transcript_dir / filename, raw)
        entries.append({
            "role": role, "file": filename,
            "argv": VALIDATOR.expected_argv(role, document["command"], capture,
                                              session, document["sceneResource"]),
            "bytes": len(raw), "sha256": VALIDATOR.sha256(raw),
        })
    document["transcripts"] = entries
    document["source"] = {
        "tool": VALIDATOR.GPUDEBUG, "toolVersion": "1.0",
        "captureFile": VALIDATOR.CAPTURE_LEAF, "captureKind": kind,
        "captureBytes": capture_bytes, "captureManifestSha256": manifest,
        "captureCopySummarySha256": VALIDATOR.sha256(summary_raw),
        "captureEvidenceCommitted": True,
        "artifactBytes": artifact_path.stat().st_size,
        "artifactSha256": VALIDATOR.sha256(artifact_path.read_bytes()),
        "runtimeLogBytes": len(log_raw), "runtimeLogSha256": VALIDATOR.sha256(log_raw),
        "transcriptManifestSha256": VALIDATOR.transcript_manifest(entries, transcript_dir),
    }
    evidence = root / "evidence.json"
    write_0600(evidence, VALIDATOR.canonical_json_bytes(document))
    return document, {
        "capture": capture, "summary": summary_path, "artifact": artifact_path,
        "log": log_path, "transcripts": transcript_dir, "evidence": evidence,
    }


class LinearHDRGPUEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def rejected(self, mutation: Mutation, label: str) -> None:
        candidate = copy.deepcopy(self.fixture)
        mutation(candidate)
        with self.subTest(label=label):
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.validate_document(candidate)

    def test_synthetic_fixture_requires_explicit_non_device_mode(self) -> None:
        VALIDATOR.validate_document(copy.deepcopy(self.fixture))
        denied = subprocess.run(
            [sys.executable, str(SCRIPT), "--validate", "--evidence", str(FIXTURE)],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(denied.returncode, 1)
        allowed = subprocess.run(
            [sys.executable, str(SCRIPT), "--validate", "--evidence", str(FIXTURE),
             "--allow-synthetic-fixture"],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(allowed.stdout, "SYNTHETIC CONTRACT PASS\n")

    def test_exact_v2_join_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            document, paths = make_join(pathlib.Path(temporary))
            VALIDATOR.validate_join(document, paths["capture"], paths["summary"],
                                    paths["artifact"], paths["log"],
                                    paths["transcripts"], SHA)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--validate", "--evidence", str(paths["evidence"]),
                 "--capture", str(paths["capture"]), "--capture-summary", str(paths["summary"]),
                 "--artifact", str(paths["artifact"]), "--runtime-log", str(paths["log"]),
                 "--transcript-dir", str(paths["transcripts"]), "--expected-sha", SHA],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "GPU PASS\n")

    def test_schema_and_semantic_mutations_are_rejected(self) -> None:
        mutations: tuple[tuple[str, Mutation], ...] = (
            ("schema", lambda d: d.__setitem__("schemaVersion", 1)),
            ("bool schema", lambda d: d.__setitem__("schemaVersion", True)),
            ("class", lambda d: d.__setitem__("evidenceClass", "synthetic-fixture")),
            ("producer", lambda d: d.__setitem__("producer", "adapter/1")),
            ("unknown root", lambda d: d.__setitem__("extra", 1)),
            ("tool path", lambda d: d["source"].__setitem__("tool", "gpudebug")),
            ("tool version", lambda d: d["source"].__setitem__("toolVersion", "1.1")),
            ("capture leaf", lambda d: d["source"].__setitem__("captureFile", "other.gputrace")),
            ("capture kind", lambda d: d["source"].__setitem__("captureKind", "package")),
            ("commit false", lambda d: d["source"].__setitem__("captureEvidenceCommitted", False)),
            ("proof id", lambda d: d["runIdentity"].__setitem__("proofId", "f" * 32)),
            ("build uppercase", lambda d: d["runIdentity"].__setitem__("buildSha", "A" * 40)),
            ("generation bool", lambda d: d["runIdentity"].__setitem__("targetGeneration", True)),
            ("row drift", lambda d: d["extent"].__setitem__("rowBytes", 17)),
            ("manual numeric", lambda d: d["numeric"].__setitem__("encoding", "manual-sample")),
            ("maximum <=1", lambda d: d["numeric"].__setitem__("valueHex", "0x1.0000000000000p+0")),
            ("numeric boolean", lambda d: d["numeric"].__setitem__("maximumX", False)),
            ("scene label", lambda d: d["sceneResource"].__setitem__("label", "foreign")),
            ("scene format", lambda d: d["sceneResource"].__setitem__("pixelFormat", "RGBA16Float")),
            ("scene mip", lambda d: d["sceneResource"].__setitem__("mipLevel", 1)),
            ("foreign texture", lambda d: d["command"]["proofBlit"].__setitem__("sourceTextureRef", "@tex8")),
            ("proof slice", lambda d: d["command"]["proofBlit"].__setitem__("sourceSlice", 1)),
            ("tone tex1", lambda d: d["command"]["toneResolve"].__setitem__("fragmentTextureIndex", 1)),
            ("reordered", lambda d: d["command"]["proofBlit"].__setitem__("childIndex", 5)),
            ("foreign cb", lambda d: d["command"]["toneResolve"].__setitem__("encoderPath", "commands/cb5/re4")),
            ("role order", lambda d: d["transcripts"].__setitem__(0, d["transcripts"][1])),
            ("argv path", lambda d: d["transcripts"][0]["argv"].__setitem__(0, "gpudebug")),
            ("unsafe name", lambda d: d["transcripts"][0].__setitem__("file", "../x")),
        )
        for label, mutation in mutations:
            self.rejected(mutation, label)

    def test_join_mutations_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            document, paths = make_join(root)
            cases = (
                ("capture hash", lambda d: d["source"].__setitem__("captureManifestSha256", "0" * 64)),
                ("artifact hash", lambda d: d["source"].__setitem__("artifactSha256", "0" * 64)),
                ("summary hash", lambda d: d["source"].__setitem__("captureCopySummarySha256", "0" * 64)),
                ("transcript hash", lambda d: d["transcripts"][3].__setitem__("sha256", "0" * 64)),
                ("numeric location", lambda d: d["numeric"].__setitem__("maximumX", 1)),
                ("foreign generation", lambda d: d["runIdentity"].__setitem__("targetGeneration", 8)),
            )
            for label, mutation in cases:
                candidate = copy.deepcopy(document)
                mutation(candidate)
                with self.subTest(label=label):
                    with self.assertRaises(VALIDATOR.EvidenceError):
                        VALIDATOR.validate_join(candidate, paths["capture"], paths["summary"],
                                                paths["artifact"], paths["log"],
                                                paths["transcripts"], SHA)
            original_log = paths["log"].read_bytes()
            for label, extra in (
                ("duplicate success", original_log.splitlines()[-1] + b"\n"),
                ("success plus failure",
                 f"RendererIOS HDR capture: v=1 id={PROOF_ID} terminal=F reason=stop\n".encode()),
                ("malformed terminal", b"RendererIOS HDR capture: v=1 invalid\n"),
            ):
                raw = original_log + extra
                write_0600(paths["log"], raw)
                candidate = copy.deepcopy(document)
                candidate["source"]["runtimeLogBytes"] = len(raw)
                candidate["source"]["runtimeLogSha256"] = VALIDATOR.sha256(raw)
                with self.subTest(label=label):
                    with self.assertRaises(VALIDATOR.EvidenceError):
                        VALIDATOR.validate_join(
                            candidate, paths["capture"], paths["summary"],
                            paths["artifact"], paths["log"],
                            paths["transcripts"], SHA)
            write_0600(paths["log"], original_log)

    def test_capture_manifest_rejects_symlink_special_and_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            capture = root / VALIDATOR.CAPTURE_LEAF
            capture.mkdir()
            (capture / "file").write_bytes(b"x")
            (capture / "link").symlink_to("file")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.stable_capture_manifest(capture)
            (capture / "link").unlink()
            os.mkfifo(capture / "fifo")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.stable_capture_manifest(capture)
            (capture / "fifo").unlink()

            original_manifest = VALIDATOR.capture_manifest
            calls = 0

            def drifting_manifest(path: pathlib.Path) -> tuple[Any, ...]:
                nonlocal calls
                result = original_manifest(path)
                calls += 1
                if calls == 1:
                    (path / "file").write_bytes(b"changed")
                return result

            with mock.patch.object(VALIDATOR, "capture_manifest",
                                   side_effect=drifting_manifest):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.stable_capture_manifest(capture)

            empty = root / "empty.gputrace"
            empty.touch()
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.stable_capture_manifest(empty)
            oversized = root / "oversized.gputrace"
            with oversized.open("wb") as output:
                output.truncate(VALIDATOR.MAX_CAPTURE_BYTES + 1)
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.stable_capture_manifest(oversized)

    def test_capture_commit_is_durable_exact_and_no_clobber(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            staging_parent = root / "staging"
            staging_parent.mkdir()
            staging = staging_parent / VALIDATOR.CAPTURE_LEAF
            staging.mkdir()
            (staging / "payload").write_bytes(b"capture")
            kind, size, _ = VALIDATOR.stable_capture_manifest(staging)
            line = (
                f"RendererIOS HDR capture: v=1 id={PROOF_ID} "
                f"file={VALIDATOR.CAPTURE_LEAF} kind={kind} bytes={size} terminal=C\n"
            ).encode()
            runtime_log = root / "log.txt"
            write_0600(runtime_log, line)
            destination = root / VALIDATOR.CAPTURE_LEAF
            summary = root / VALIDATOR.SUMMARY_LEAF
            committed = VALIDATOR.commit_capture_copy(
                staging, destination, summary, runtime_log, "directory")
            self.assertTrue(destination.is_dir())
            self.assertTrue(staging.is_dir())
            self.assertEqual(summary.stat().st_mode & 0o777, 0o600)
            self.assertTrue(committed["evidenceCommitted"])
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.atomic_no_clobber(summary, b"{}\n")

            staging_file_parent = root / "staging-file"
            staging_file_parent.mkdir()
            staging_file = staging_file_parent / VALIDATOR.CAPTURE_LEAF
            staging_file.write_bytes(b"capture")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.commit_capture_copy(
                    staging_file, root / "other" / VALIDATOR.CAPTURE_LEAF,
                    root / "other-summary.json", runtime_log, "directory")

    def test_capture_commit_rejects_verified_root_symlink_swap_without_touching_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            staging_parent = root / "staging"
            staging_parent.mkdir()
            staging = staging_parent / VALIDATOR.CAPTURE_LEAF
            staging.write_bytes(b"verified capture")
            kind, size, _ = VALIDATOR.stable_capture_manifest(staging)
            runtime_log = root / "log.txt"
            write_0600(runtime_log, (
                f"RendererIOS HDR capture: v=1 id={PROOF_ID} "
                f"file={VALIDATOR.CAPTURE_LEAF} kind={kind} bytes={size} terminal=C\n"
            ).encode())
            external = root / "external.txt"
            external.write_bytes(b"external must not change")
            external.chmod(0o644)
            external_before = (external.read_bytes(), external.stat().st_mode & 0o777)
            original_stable = VALIDATOR.stable_capture_manifest
            swapped = False

            def verified_then_swapped(path: pathlib.Path) -> tuple[str, int, str]:
                nonlocal swapped
                result = original_stable(path)
                if path == staging and not swapped:
                    swapped = True
                    staging.unlink()
                    staging.symlink_to(external)
                return result

            with mock.patch.object(VALIDATOR, "stable_capture_manifest",
                                   side_effect=verified_then_swapped):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.commit_capture_copy(
                        staging, root / VALIDATOR.CAPTURE_LEAF,
                        root / VALIDATOR.SUMMARY_LEAF, runtime_log, "file")
            self.assertTrue(staging.is_symlink())
            self.assertEqual(
                (external.read_bytes(), external.stat().st_mode & 0o777),
                external_before)
            self.assertFalse((root / VALIDATOR.SUMMARY_LEAF).exists())

    def test_capture_commit_never_deletes_swapped_real_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            staging_parent = root / "staging"
            staging_parent.mkdir()
            staging = staging_parent / VALIDATOR.CAPTURE_LEAF
            staging.mkdir()
            (staging / "verified").write_bytes(b"verified capture")
            kind, size, _ = VALIDATOR.stable_capture_manifest(staging)
            runtime_log = root / "log.txt"
            write_0600(runtime_log, (
                f"RendererIOS HDR capture: v=1 id={PROOF_ID} "
                f"file={VALIDATOR.CAPTURE_LEAF} kind={kind} bytes={size} terminal=C\n"
            ).encode())
            destination = root / VALIDATOR.CAPTURE_LEAF
            summary = root / VALIDATOR.SUMMARY_LEAF
            victim = root / "victim"
            victim.mkdir()
            (victim / "must-remain").write_bytes(b"victim unchanged")
            victim.chmod(0o750)
            victim_identity = (victim.stat().st_dev, victim.stat().st_ino)
            original_stable = VALIDATOR.stable_capture_manifest
            original_atomic = VALIDATOR.atomic_no_clobber
            swapped = False
            summary_observed = False

            def swap_after_final_walk(path: pathlib.Path) -> tuple[str, int, str]:
                nonlocal swapped
                result = original_stable(path)
                if path == destination and not swapped:
                    swapped = True
                    staging.rename(staging_parent / "verified-retained")
                    victim.rename(staging)
                return result

            def observe_summary(path: pathlib.Path, raw: bytes) -> None:
                nonlocal summary_observed
                if path == summary:
                    summary_observed = True
                    self.assertTrue(staging.is_dir())
                    self.assertEqual((staging.stat().st_dev, staging.stat().st_ino),
                                     victim_identity)
                    self.assertEqual((staging / "must-remain").read_bytes(),
                                     b"victim unchanged")
                    self.assertEqual(staging.stat().st_mode & 0o777, 0o750)
                original_atomic(path, raw)

            with mock.patch.object(VALIDATOR, "stable_capture_manifest",
                                   side_effect=swap_after_final_walk), \
                 mock.patch.object(VALIDATOR, "atomic_no_clobber",
                                   side_effect=observe_summary):
                VALIDATOR.commit_capture_copy(
                    staging, destination, summary, runtime_log, "directory")
            self.assertTrue(summary_observed)
            self.assertEqual((staging.stat().st_dev, staging.stat().st_ino),
                             victim_identity)
            self.assertEqual((staging / "must-remain").read_bytes(),
                             b"victim unchanged")
            self.assertTrue((staging_parent / "verified-retained").is_dir())

    def test_collector_deadline_timeout_nonzero_and_stream_limit(self) -> None:
        with self.assertRaises(VALIDATOR.EvidenceError):
            VALIDATOR.collector_command_timeout(100.0, 99.75)
        self.assertEqual(VALIDATOR.collector_command_timeout(100.0, 99.0), 1.0)
        self.assertEqual(
            VALIDATOR.collector_command_timeout(200.0, 0.0),
            VALIDATOR.COLLECTOR_COMMAND_TIMEOUT_SECONDS)
        with self.assertRaises(VALIDATOR.EvidenceError):
            VALIDATOR.collector_command_timeout(100.0, 100.0)

        with mock.patch.object(VALIDATOR, "GPUDEBUG", sys.executable):
            with mock.patch.object(VALIDATOR.subprocess, "Popen") as popen:
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.run_collector_command(
                        [sys.executable, "-c", "print('must not start')"],
                        time.monotonic() + 0.25)
                popen.assert_not_called()

            with self.assertRaises(VALIDATOR.EvidenceError) as nonzero:
                VALIDATOR.run_collector_command(
                    [sys.executable, "-c", "import sys;sys.exit(7)"],
                    time.monotonic() + 5.0)
            self.assertIn("exited 7", str(nonzero.exception))

            started = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                VALIDATOR.run_collector_command(
                    [sys.executable, "-c", "import time;time.sleep(30)"],
                    time.monotonic() + 1.2)
            self.assertLess(time.monotonic() - started, 5.0)

            started = time.monotonic()
            with mock.patch.object(VALIDATOR, "MAX_TRANSCRIPT_BYTES", 1024):
                with self.assertRaises(VALIDATOR.EvidenceError) as overflow:
                    VALIDATOR.run_collector_command(
                        [sys.executable, "-c",
                         "import os,time;os.write(1,b'x'*4096);time.sleep(30)"],
                        time.monotonic() + 5.0)
            self.assertIn("stdout limit exceeded", str(overflow.exception))
            self.assertLess(time.monotonic() - started, 5.0)

    def test_cleanup_uses_overall_budget_and_always_attempts_owned_termination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            transcript_dir = pathlib.Path(temporary)
            entries: list[dict[str, Any]] = []
            raws: dict[str, bytes] = {}
            calls: list[tuple[list[str], float]] = []

            def completed(argv: list[str], deadline: float) -> bytes:
                calls.append((argv, deadline))
                return b'{"ok":true}\n' if "--terminate" in argv else b'{"sessions":[]}\n'

            with mock.patch.object(VALIDATOR, "run_collector_command",
                                   side_effect=completed):
                VALIDATOR.cleanup_owned_collector_session(
                    "owned-session", transcript_dir, entries, raws, 1050.0)
            self.assertEqual([entry[0] for entry in calls], [
                [VALIDATOR.GPUDEBUG, "--terminate", "owned-session"],
                [VALIDATOR.GPUDEBUG, "--list-sessions"],
            ])
            self.assertNotIn("--terminate-all", sum((entry[0] for entry in calls), []))
            self.assertTrue(all(deadline == 1050.0 for _, deadline in calls))
            self.assertEqual([entry["role"] for entry in entries],
                             ["terminate", "sessions-after"])

        with tempfile.TemporaryDirectory() as temporary:
            attempted: list[list[str]] = []

            def terminate_fails(argv: list[str], deadline: float) -> bytes:
                del deadline
                attempted.append(argv)
                if "--terminate" in argv:
                    raise VALIDATOR.EvidenceError("forced terminate failure")
                return b'{"sessions":[]}\n'

            with mock.patch.object(VALIDATOR, "run_collector_command",
                                   side_effect=terminate_fails):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.cleanup_owned_collector_session(
                        "owned-session", pathlib.Path(temporary), [], {}, 1050.0)
            self.assertEqual(len(attempted), 2)

        self.assertEqual(VALIDATOR.COLLECTOR_MAIN_TIMEOUT_SECONDS, 600.0)
        self.assertEqual(VALIDATOR.COLLECTOR_GLOBAL_TIMEOUT_SECONDS, 720.0)
        self.assertEqual(
            VALIDATOR.COLLECTOR_GLOBAL_TIMEOUT_SECONDS -
            VALIDATOR.COLLECTOR_MAIN_TIMEOUT_SECONDS, 120.0)

    def test_duplicate_nonfinite_and_noncanonical_json_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for name, raw in (("duplicate.json", b'{"schemaVersion":2,"schemaVersion":2}\n'),
                              ("nan.json", b'{"value":NaN}\n'),
                              ("pretty.json", b'{"value": 1}\n')):
                path = root / name
                write_0600(path, raw)
                with self.subTest(name=name):
                    with self.assertRaises(VALIDATOR.EvidenceError):
                        VALIDATOR.load_document(path)


if __name__ == "__main__":
    unittest.main()
