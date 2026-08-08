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
LIVE_TRANSIENT_SESSION_13 = (
    b"ID  Trace                                     Device             Replayer  Lifetime\n"
    b"13  RendererIOS-linear-hdr-proof-v1.gputrace  Apple A17 Pro GPU  error     "
    b"anchored to PID 72527 (zsh)\n"
    b"(1 session)\n"
)


def session_listing(*sessions: str) -> bytes:
    if not sessions:
        return b"No active sessions.\n"
    rows = b"".join(
        f"{session}  trace-{session}.gputrace  Device  idle  persistent\n".encode()
        for session in sessions
    )
    noun = "session" if len(sessions) == 1 else "sessions"
    return (
        b"ID  Trace  Device  Replayer  Lifetime\n" + rows +
        f"({len(sessions)} {noun})\n".encode()
    )


def navigable_json(value: Any) -> bytes:
    document = (json.dumps(value, separators=(",", ":")) + "\n").encode()
    return document + document


def direct_info_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2) + "\n").encode()


def gpudebug_child(actions: str, name: str, *values: str) -> dict[str, Any]:
    child: dict[str, Any] = {"actions": actions, "name": name}
    if values:
        child["values"] = [{"type": "string", "value": value} for value in values]
    return child


def gpudebug_listing(*children: dict[str, Any]) -> dict[str, Any]:
    return {"children": list(children), "totalCount": len(children)}


def gpudebug_open_root(command_buffers: int = 1, api_calls: int = 148764,
                       objects: int = 3991) -> dict[str, Any]:
    command_noun = "command buffer" if command_buffers == 1 else "command buffers"
    api_noun = "API call" if api_calls == 1 else "API calls"
    object_noun = "object" if objects == 1 else "objects"
    return gpudebug_listing(
        gpudebug_child("go", "commands", f"{command_buffers} {command_noun}"),
        gpudebug_child("", "performance", "see 'profile ?'"),
        gpudebug_child("go", "api_calls", f"{api_calls} {api_noun}"),
        gpudebug_child("go", "resources", f"{objects} {object_noun}"),
    )


def compact_json(value: Any) -> bytes:
    return (json.dumps(value, separators=(",", ":")) + "\n").encode()


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
    cb = command["commandBuffer"]
    scene_name = scene["encoderPath"].rsplit("/", 1)[1]
    proof_name = proof["encoderPath"].rsplit("/", 1)[1]
    tone_name = tone["encoderPath"].rsplit("/", 1)[1]
    proof_group, blit_name = proof["commandPath"].rsplit("/", 1)
    proof_group_name = proof_group.rsplit("/", 1)[1]
    tone_group, draw_name = tone["drawPath"].rsplit("/", 1)
    tone_group_name = tone_group.rsplit("/", 1)[1]
    binding = f'{resource["textureRef"]} 4x3 RG11B10Float'
    resource_info = {
        "allocationID": resource["allocationID"], "dimensions": "4x3",
        "label": resource["label"], "pixelFormat": resource["pixelFormat"],
        "resourceIndex": resource["resourceIndex"],
        "storageMode": resource["storageMode"],
        "textureType": resource["textureType"],
    }
    return {
        "version": b"gpudebug 1.0\n",
        "open": (
            b"Session 10 created.\n"
            b"1 other session active.\n"
            b"gpudebug -s 10 -c <command> to send commands.\n"
            + compact_json(gpudebug_open_root())
        ),
        "commands": navigable_json(gpudebug_listing(
            gpudebug_child("go", cb, "4 encoders", '"MTLCommandQueue 1"'))),
        "command-buffer": navigable_json(gpudebug_listing(
            gpudebug_child("go", scene_name, f'"{scene["marker"]} (2)"', "1 draw"),
            gpudebug_child("go", proof_name, f'"{proof["marker"]}"', "1 blit"),
            gpudebug_child("go", tone_name, f'"{tone["marker"]}"', "1 draw"))),
        "scene-encoder": navigable_json(gpudebug_listing(
            gpudebug_child("info, fetch", "color0", f'"{resource["label"]}"',
                           binding))),
        "scene-color0": direct_info_json(resource_info),
        "proof-encoder": navigable_json(gpudebug_listing(
            gpudebug_child("go", proof_group_name, f'"{proof["marker"]}"',
                           "1 blit"))),
        "proof-group": navigable_json(gpudebug_listing(
            gpudebug_child("go, info", blit_name))),
        "proof-blit": direct_info_json({
            "sourceLevel": "0", "sourceSize": "4x3x1", "sourceSlice": "0",
            "sourceTexture": f'{resource["textureRef"]} "{resource["label"]}"',
        }),
        "tone-encoder": navigable_json(gpudebug_listing(
            gpudebug_child("go", tone_group_name, f'"{tone["marker"]}"',
                           "1 draw"))),
        "tone-group": navigable_json(gpudebug_listing(
            gpudebug_child("go, info", draw_name, '"vertex / fragment"'))),
        "tone-draw": navigable_json(gpudebug_listing(
            gpudebug_child("info", "pipeline", '"pipeline"', "@rps0"),
            gpudebug_child("go", "vertex", '"vertex"'),
            gpudebug_child("go", "fragment", '"fragment"'),
            gpudebug_child("info, fetch", "color0", '"output"',
                           "@tex0 4x3 BGRA8Unorm"))),
        "tone-fragment": navigable_json(gpudebug_listing(
            gpudebug_child("fetch", "buf[0]", "16 bytes (inline)"),
            gpudebug_child("info, fetch", "tex[0]",
                           f'"{resource["label"]}"', binding))),
        "tone-tex0": direct_info_json(resource_info),
        "scene-resource": direct_info_json(resource_info),
        "terminate": b"Session 10 terminated.\n",
        "sessions-after": b"No active sessions.\n",
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
    session = "10"
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

    def test_parse_session_accepts_exact_startup_banner_with_other_session_count(self) -> None:
        root = compact_json(gpudebug_open_root())
        with_other = (
            b"Session 10 created.\n"
            b"1 other session active.\n"
            b"gpudebug -s 10 -c <command> to send commands.\n"
            + root
        )
        without_other = (
            b"Session 10 created.\n"
            b"gpudebug -s 10 -c <command> to send commands.\n"
            + root
        )
        plural_other = (
            b"Session 10 created.\n"
            b"2 other sessions active.\n"
            b"gpudebug -s 10 -c <command> to send commands.\n"
            + compact_json(gpudebug_open_root(2, 1, 1))
        )
        for raw in (with_other, without_other, plural_other):
            self.assertEqual(VALIDATOR.parse_session(raw), "10")

    def test_parse_session_rejects_noncanonical_open_root_listings(self) -> None:
        prefix = (
            b"Session 10 created.\n"
            b"gpudebug -s 10 -c <command> to send commands.\n"
        )
        valid = gpudebug_open_root()
        missing_commands = copy.deepcopy(valid)
        missing_commands["children"] = missing_commands["children"][1:]
        missing_commands["totalCount"] -= 1
        duplicate_commands = copy.deepcopy(valid)
        duplicate_commands["children"][1] = copy.deepcopy(
            duplicate_commands["children"][0])
        foreign_child = copy.deepcopy(valid)
        foreign_child["children"][3]["name"] = "foreign"
        count_drift = copy.deepcopy(valid)
        count_drift["totalCount"] += 1
        wrong_action = copy.deepcopy(valid)
        wrong_action["children"][0]["actions"] = "info"
        unknown_key = copy.deepcopy(valid)
        unknown_key["children"][0]["path"] = "commands"
        wrong_values = copy.deepcopy(valid)
        wrong_values["children"][0]["values"] = []
        noun_drift = copy.deepcopy(valid)
        noun_drift["children"][0]["values"][0]["value"] = "2 command buffer"
        performance_action = copy.deepcopy(valid)
        performance_action["children"][1]["actions"] = "go"
        performance_value = copy.deepcopy(valid)
        performance_value["children"][1]["values"][0]["value"] = "profile"
        api_value = copy.deepcopy(valid)
        api_value["children"][2]["values"][0]["value"] = "many API calls"
        resource_type = copy.deepcopy(valid)
        resource_type["children"][3]["values"][0]["type"] = "number"
        cases = (
            ("empty object", {}),
            ("error object", {"error": "replay failed"}),
            ("legacy path object", {"path": "commands"}),
            ("missing commands", missing_commands),
            ("duplicate commands", duplicate_commands),
            ("foreign child", foreign_child),
            ("totalCount drift", count_drift),
            ("commands wrong action", wrong_action),
            ("child unknown key", unknown_key),
            ("missing values", wrong_values),
            ("count noun drift", noun_drift),
            ("performance action", performance_action),
            ("performance value", performance_value),
            ("api_calls value", api_value),
            ("resources value type", resource_type),
        )
        for label, payload in cases:
            with self.subTest(label=label):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.parse_session(prefix + compact_json(payload))

    def test_parse_session_rejects_noncanonical_or_ambiguous_banners(self) -> None:
        valid_root = compact_json(gpudebug_open_root())
        valid_prefix = (
            b"Session 10 created.\n"
            b"gpudebug -s 10 -c <command> to send commands.\n"
        )
        cases = (
            ("missing", b"1 other session active.\n{}\n"),
            ("multiple", b"Session 10 created.\nSession 11 created.\n{}\n"),
            ("canonical plus leading zero",
             b"Session 10 created.\nSession 011 created.\n{}\n"),
            ("zero", b"Session 0 created.\n{}\n"),
            ("leading zero", b"Session 010 created.\n{}\n"),
            ("plus sign", b"Session +10 created.\n{}\n"),
            ("minus sign", b"Session -10 created.\n{}\n"),
            ("foreign prefix", b"notice: Session 10 created.\n{}\n"),
            ("foreign suffix", b"Session 10 created. unexpectedly\n{}\n"),
            ("legacy json", b'{"sessionId":"10"}\n'),
            ("not first line", b"notice\nSession 10 created.\n{}\n"),
            ("non utf8", b"Session 10 created.\n\xff\n"),
            ("wrong hint session",
             b"Session 10 created.\ngpudebug -s 11 -c <command> to send commands.\n{}\n"),
            ("singular mismatch",
             b"Session 10 created.\n2 other session active.\n"
             b"gpudebug -s 10 -c <command> to send commands.\n{}\n"),
            ("plural mismatch",
             b"Session 10 created.\n1 other sessions active.\n"
             b"gpudebug -s 10 -c <command> to send commands.\n{}\n"),
            ("extra error after payload", valid_prefix + valid_root +
             b"ERROR: replay failed\n"),
            ("multiple payloads", valid_prefix + valid_root + valid_root),
            ("missing payload",
             b"Session 10 created.\ngpudebug -s 10 -c <command> to send commands.\n"),
            ("missing final lf", valid_prefix + valid_root[:-1]),
        )
        for label, raw in cases:
            with self.subTest(label=label):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.parse_session(raw)

    def test_session_listing_parser_is_exact_and_id_aware(self) -> None:
        self.assertEqual(VALIDATOR.listed_session_ids(b"No active sessions.\n"), set())
        self.assertEqual(
            VALIDATOR.listed_session_ids(LIVE_TRANSIENT_SESSION_13), {"13"})
        self.assertEqual(
            VALIDATOR.listed_session_ids(session_listing("1", "13")), {"1", "13"})
        self.assertNotIn("1", VALIDATOR.listed_session_ids(session_listing("13")))
        cases = (
            ("legacy json", b'{"sessions":[]}\n'),
            ("wrong zero sentinel", b"No active sessions.\nextra\n"),
            ("count drift", session_listing("13").replace(b"(1 session)",
                                                            b"(2 sessions)")),
            ("leading zero row", session_listing("13").replace(b"13  trace",
                                                                  b"013  trace")),
            ("truncated row",
             b"ID  Trace  Device  Replayer  Lifetime\n13  garbage\n(1 session)\n"),
            ("missing lifetime",
             b"ID  Trace  Device  Replayer  Lifetime\n"
             b"13  trace.gputrace  Device  idle\n(1 session)\n"),
            ("duplicate id", session_listing("13", "13")),
            ("crlf", b"No active sessions.\r\n"),
            ("non utf8", b"No active sessions.\n\xff"),
        )
        for label, raw in cases:
            with self.subTest(label=label):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.listed_session_ids(raw)

    def test_gpudebug_json_document_boundaries_are_strict(self) -> None:
        first = (json.dumps({"children": [], "totalCount": 0},
                            separators=(",", ":")) + "\n").encode()
        second = (json.dumps({"children": [
            {"actions": "go", "name": "cb0"}], "totalCount": 1},
            separators=(",", ":")) + "\n").encode()
        valid_navigation = first + first
        self.assertEqual(
            VALIDATOR._navigable_json(valid_navigation, "navigation"),
            {"children": [], "totalCount": 0})
        navigation_cases = (
            ("missing", first),
            ("extra", valid_navigation + first),
            ("different", first + second),
            ("malformed", first + b"{bad}\n"),
            ("trailing", valid_navigation + b"trailing\n"),
            ("missing final lf", valid_navigation[:-1]),
        )
        for label, raw in navigation_cases:
            with self.subTest(shape="navigation", label=label):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR._navigable_json(raw, "navigation")

        valid_info = direct_info_json({"allocationID": "91"})
        self.assertEqual(VALIDATOR._direct_info_json(valid_info, "info"),
                         {"allocationID": "91"})
        info_cases = (
            ("missing", b""),
            ("extra", valid_info + valid_info),
            ("malformed", b"{bad}\n"),
            ("array shape", b"[]\n"),
            ("trailing", valid_info + b"trailing\n"),
            ("exit-zero error text",
             b"color0 is not navigable\nempty object has no info\n"),
        )
        for label, raw in info_cases:
            with self.subTest(shape="direct-info", label=label):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR._direct_info_json(raw, "info")

    def test_discovery_roles_drive_nonzero_blit_and_draw_argv(self) -> None:
        command = copy.deepcopy(self.fixture["command"])
        command["proofBlit"]["commandPath"] = "commands/cb4/be3/grp7/blit9"
        command["toneResolve"]["drawPath"] = "commands/cb4/re4/grp6/draw8"
        capture = pathlib.Path("/private/RendererIOS-linear-hdr-proof-v1.gputrace")
        resource = self.fixture["sceneResource"]
        names = VALIDATOR.expected_filenames(command)
        self.assertEqual(names["proof-group"], "proof-grp-7.json")
        self.assertEqual(names["proof-blit"], "proof-blit-9.json")
        self.assertEqual(names["tone-group"], "tone-grp-6.json")
        self.assertEqual(names["tone-draw"], "tone-draw-8.json")
        self.assertEqual(
            VALIDATOR.expected_argv("proof-blit", command, capture, "10", resource),
            [VALIDATOR.GPUDEBUG, "--json", "-s", "10", "-c",
             "info commands/cb4/be3/grp7/blit9"])
        self.assertEqual(
            VALIDATOR.expected_argv("tone-fragment", command, capture, "10", resource),
            [VALIDATOR.GPUDEBUG, "--json", "-s", "10", "-c",
             "go commands/cb4/re4/grp6/draw8/fragment", "-c", "list --all"])
        self.assertEqual(
            VALIDATOR._proof_group_command_path(
                navigable_json(gpudebug_listing(
                    gpudebug_child("go, info", "blit9"))),
                "commands/cb4/be3/grp7"),
            "commands/cb4/be3/grp7/blit9")
        self.assertEqual(
            VALIDATOR._tone_group_draw_path(
                navigable_json(gpudebug_listing(
                    gpudebug_child("go, info", "draw8"))),
                "commands/cb4/re4/grp6"),
            "commands/cb4/re4/grp6/draw8")

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
            ("nested proof group", lambda d: d["command"]["proofBlit"].__setitem__(
                "commandPath", "commands/cb4/be3/grp0/grp1/blit0")),
            ("proof slice", lambda d: d["command"]["proofBlit"].__setitem__("sourceSlice", 1)),
            ("tone tex1", lambda d: d["command"]["toneResolve"].__setitem__("fragmentTextureIndex", 1)),
            ("nested tone group", lambda d: d["command"]["toneResolve"].__setitem__(
                "drawPath", "commands/cb4/re4/grp0/grp1/draw1")),
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

            sessions_path = paths["transcripts"] / "gpudebug-sessions-after.txt"
            original_sessions = sessions_path.read_bytes()
            for label, raw in (
                ("owned session still listed", session_listing("10")),
                ("malformed sessions listing", b'{"sessions":[]}\n'),
            ):
                write_0600(sessions_path, raw)
                candidate = copy.deepcopy(document)
                sessions_entry = candidate["transcripts"][-1]
                sessions_entry["bytes"] = len(raw)
                sessions_entry["sha256"] = VALIDATOR.sha256(raw)
                candidate["source"]["transcriptManifestSha256"] = (
                    VALIDATOR.transcript_manifest(
                        candidate["transcripts"], paths["transcripts"])
                )
                with self.subTest(label=label):
                    with self.assertRaises(VALIDATOR.EvidenceError):
                        VALIDATOR.validate_join(
                            candidate, paths["capture"], paths["summary"],
                            paths["artifact"], paths["log"],
                            paths["transcripts"], SHA)
            write_0600(sessions_path, original_sessions)

            def transcript_rejected(role: str, raw: bytes, label: str) -> None:
                entry_index = next(
                    index for index, entry in enumerate(document["transcripts"])
                    if entry["role"] == role)
                path = paths["transcripts"] / document["transcripts"][entry_index]["file"]
                original = path.read_bytes()
                try:
                    write_0600(path, raw)
                    candidate = copy.deepcopy(document)
                    entry = candidate["transcripts"][entry_index]
                    entry["bytes"] = len(raw)
                    entry["sha256"] = VALIDATOR.sha256(raw)
                    candidate["source"]["transcriptManifestSha256"] = (
                        VALIDATOR.transcript_manifest(
                            candidate["transcripts"], paths["transcripts"])
                    )
                    with self.subTest(label=label):
                        with self.assertRaises(VALIDATOR.EvidenceError):
                            VALIDATOR.validate_join(
                                candidate, paths["capture"], paths["summary"],
                                paths["artifact"], paths["log"],
                                paths["transcripts"], SHA)
                finally:
                    write_0600(path, original)

            raw_fixture = transcript_raws(document, paths["capture"])
            commands_raw = raw_fixture["commands"]
            commands_one = commands_raw[:len(commands_raw) // 2]
            different = (json.dumps(
                gpudebug_listing(gpudebug_child("go", "cb9")),
                separators=(",", ":")) + "\n").encode()
            transcript_rejected("commands", commands_one, "commands missing document")
            transcript_rejected("commands", commands_raw + commands_one,
                                "commands extra document")
            transcript_rejected("commands", commands_one + different,
                                "commands different documents")
            transcript_rejected("commands", commands_one + b"{bad}\n",
                                "commands malformed document")
            transcript_rejected("commands", commands_raw + b"trailing\n",
                                "commands trailing content")
            transcript_rejected(
                "scene-color0",
                b"color0 is not navigable\nempty object has no info\n",
                "scene color exit-zero error text")
            transcript_rejected(
                "scene-color0", raw_fixture["scene-color0"] * 2,
                "scene color extra info document")
            transcript_rejected(
                "open", raw_fixture["open"] + b"ERROR: replay failed\n",
                "open transcript has error after JSON payload")
            open_prefix = (
                b"Session 10 created.\n"
                b"1 other session active.\n"
                b"gpudebug -s 10 -c <command> to send commands.\n"
            )
            open_root = gpudebug_open_root()
            missing_commands = copy.deepcopy(open_root)
            missing_commands["children"] = missing_commands["children"][1:]
            missing_commands["totalCount"] -= 1
            duplicate_commands = copy.deepcopy(open_root)
            duplicate_commands["children"][1] = copy.deepcopy(
                duplicate_commands["children"][0])
            foreign_commands = copy.deepcopy(open_root)
            foreign_commands["children"][0]["name"] = "command"
            open_count_drift = copy.deepcopy(open_root)
            open_count_drift["totalCount"] += 1
            for label, payload in (
                ("open empty object", {}),
                ("open error object", {"error": "replay failed"}),
                ("open legacy path object", {"path": "commands"}),
                ("open missing commands", missing_commands),
                ("open duplicate commands", duplicate_commands),
                ("open foreign commands", foreign_commands),
                ("open totalCount drift", open_count_drift),
            ):
                transcript_rejected(
                    "open", open_prefix + compact_json(payload), label)
            transcript_rejected(
                "terminate", raw_fixture["terminate"] + b"ERROR: stale session\n",
                "terminate transcript has trailing error")
            transcript_rejected(
                "proof-group", raw_fixture["proof-group"][:
                               len(raw_fixture["proof-group"]) // 2],
                "proof group missing list document")
            transcript_rejected(
                "proof-blit", raw_fixture["proof-blit"] * 2,
                "proof blit extra info document")
            transcript_rejected(
                "tone-fragment",
                raw_fixture["tone-fragment"] +
                raw_fixture["tone-fragment"][:len(raw_fixture["tone-fragment"]) // 2],
                "tone fragment extra document")
            foreign_tone_texture = copy.deepcopy(VALIDATOR._navigable_json(
                raw_fixture["tone-fragment"], "tone fragment"))
            foreign_tone_texture["children"].append(
                gpudebug_child("info, fetch", "tex[1]",
                               f'"{document["sceneResource"]["label"]}"',
                               "@tex8 4x3 RG11B10Float"))
            foreign_tone_texture["totalCount"] += 1
            transcript_rejected(
                "tone-fragment",
                navigable_json(foreign_tone_texture),
                "tone fragment exposes foreign tex1")
            tone_draw = copy.deepcopy(VALIDATOR._navigable_json(
                raw_fixture["tone-draw"], "tone draw"))
            tone_draw["children"] = [child for child in tone_draw["children"]
                                     if child["name"] != "fragment"]
            tone_draw["totalCount"] -= 1
            transcript_rejected(
                "tone-draw", navigable_json(tone_draw),
                "tone draw omits fragment discovery")
            duplicate_tone_draw = copy.deepcopy(VALIDATOR._navigable_json(
                raw_fixture["tone-draw"], "tone draw"))
            duplicate_tone_draw["children"].append(
                gpudebug_child("info", "fragment", '"foreign fragment"'))
            duplicate_tone_draw["totalCount"] += 1
            transcript_rejected(
                "tone-draw", navigable_json(duplicate_tone_draw),
                "tone draw duplicates fragment name")

            command_buffer_document = VALIDATOR._navigable_json(
                raw_fixture["command-buffer"], "command buffer")
            missing_scene_suffix = copy.deepcopy(command_buffer_document)
            missing_scene_suffix["children"][0]["values"][0]["value"] = (
                f'"{document["command"]["scene"]["marker"]}"'
            )
            transcript_rejected(
                "command-buffer", navigable_json(missing_scene_suffix),
                "scene marker missing exact display suffix")
            foreign_proof_suffix = copy.deepcopy(command_buffer_document)
            foreign_proof_suffix["children"][1]["values"][0]["value"] = (
                f'"{document["command"]["proofBlit"]["marker"]} (2)"'
            )
            transcript_rejected(
                "command-buffer", navigable_json(foreign_proof_suffix),
                "proof marker has foreign display suffix")

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
                return (b"Session 13 terminated.\n" if "--terminate" in argv else
                        b"No active sessions.\n")

            with mock.patch.object(VALIDATOR, "run_collector_command",
                                   side_effect=completed):
                VALIDATOR.cleanup_owned_collector_session(
                    "13", transcript_dir, entries, raws, 1050.0)
            self.assertEqual([entry[0] for entry in calls], [
                [VALIDATOR.GPUDEBUG, "--terminate", "13"],
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
                return b"No active sessions.\n"

            with mock.patch.object(VALIDATOR, "run_collector_command",
                                   side_effect=terminate_fails):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.cleanup_owned_collector_session(
                        "13", pathlib.Path(temporary), [], {}, 1050.0)
            self.assertEqual(len(attempted), 2)

        with tempfile.TemporaryDirectory() as temporary:
            responses = iter((b"Session 13 terminated.\nERROR: stale session\n",
                              b"No active sessions.\n"))
            entries = []
            with mock.patch.object(VALIDATOR, "run_collector_command",
                                   side_effect=lambda argv, deadline: next(responses)):
                with self.assertRaises(VALIDATOR.EvidenceError):
                    VALIDATOR.cleanup_owned_collector_session(
                        "13", pathlib.Path(temporary), entries, {}, 1050.0)
            self.assertEqual([entry["role"] for entry in entries], ["sessions-after"])

        self.assertEqual(VALIDATOR.COLLECTOR_MAIN_TIMEOUT_SECONDS, 600.0)
        self.assertEqual(VALIDATOR.COLLECTOR_GLOBAL_TIMEOUT_SECONDS, 720.0)
        self.assertEqual(
            VALIDATOR.COLLECTOR_GLOBAL_TIMEOUT_SECONDS -
            VALIDATOR.COLLECTOR_MAIN_TIMEOUT_SECONDS, 120.0)

    def test_cleanup_repolls_transient_owned_session_and_records_final_absence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            transcript_dir = pathlib.Path(temporary)
            entries: list[dict[str, Any]] = []
            raws: dict[str, bytes] = {}
            calls: list[tuple[list[str], float]] = []
            responses = iter((b"Session 13 terminated.\n",
                              LIVE_TRANSIENT_SESSION_13,
                              b"No active sessions.\n"))

            def settling(argv: list[str], deadline: float) -> bytes:
                calls.append((argv, deadline))
                return next(responses)

            with mock.patch.object(VALIDATOR, "run_collector_command",
                                   side_effect=settling), \
                 mock.patch.object(VALIDATOR.time, "monotonic", return_value=1000.0), \
                 mock.patch.object(VALIDATOR.time, "sleep") as sleep:
                VALIDATOR.cleanup_owned_collector_session(
                    "13", transcript_dir, entries, raws, 1050.0)
            self.assertEqual([argv for argv, _ in calls], [
                [VALIDATOR.GPUDEBUG, "--terminate", "13"],
                [VALIDATOR.GPUDEBUG, "--list-sessions"],
                [VALIDATOR.GPUDEBUG, "--list-sessions"],
            ])
            self.assertTrue(all(deadline == 1050.0 for _, deadline in calls))
            sleep.assert_called_once_with(VALIDATOR.COLLECTOR_SESSION_SETTLE_SECONDS)
            self.assertEqual([entry["role"] for entry in entries],
                             ["terminate", "sessions-after"])
            self.assertEqual(raws["sessions-after"], b"No active sessions.\n")
            self.assertEqual(
                (transcript_dir / "gpudebug-sessions-after.txt").read_bytes(),
                b"No active sessions.\n")

        with mock.patch.object(VALIDATOR, "run_collector_command",
                               return_value=LIVE_TRANSIENT_SESSION_13), \
             mock.patch.object(VALIDATOR.time, "monotonic", return_value=1048.5), \
             mock.patch.object(VALIDATOR.time, "sleep") as sleep:
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.wait_for_owned_session_absence(
                    "13", [VALIDATOR.GPUDEBUG, "--list-sessions"], 1050.0)
            sleep.assert_not_called()

        with mock.patch.object(VALIDATOR, "run_collector_command",
                               return_value=session_listing("13")):
            self.assertEqual(
                VALIDATOR.wait_for_owned_session_absence(
                    "1", [VALIDATOR.GPUDEBUG, "--list-sessions"], 1050.0),
                session_listing("13"))

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
