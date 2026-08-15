#!/usr/bin/env python3

from __future__ import annotations

import copy
import importlib.util
import os
import pathlib
import struct
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
COLLECTOR = ROOT / "ios/device-test/collect-multiply2-draw-evidence.py"


def load_collector():
    spec = importlib.util.spec_from_file_location(
        "multiply2_draw_evidence_test_module", COLLECTOR)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


collector = load_collector()


def input_artifact() -> bytes:
    raw = bytearray(64 + 2 * 256)
    raw[:8] = b"RIOSM29\0"
    struct.pack_into("<HHI", raw, 8, 1, 0x4C45, 64)
    struct.pack_into("<QQ", raw, 16, 1, 1)
    struct.pack_into("<II", raw, 32, 256, 160)
    struct.pack_into("<QQ", raw, 40, 3, 5)
    struct.pack_into("<II", raw, 56, 0, 0)
    offset = 64 + 256
    struct.pack_into("<9Q5I4B", raw, offset,
                     7, 8, 9, 10, 4, 3, 36, 16, 2,
                     36, 4, 4, 3, 1, 2, 5, 0, 1)
    raw[offset + 96:offset + 256] = bytes(range(160))
    return bytes(raw)


def coverage_artifact() -> bytes:
    raw = bytearray(164)
    raw[:8] = b"RIOSMC9\0"
    struct.pack_into("<HHI", raw, 8, 1, 0x4C45, 160)
    struct.pack_into("<IIII", raw, 16, 2, 2, 2, 1)
    struct.pack_into("<QQQQQQ", raw, 32, 4, 3, 5, 7, 4, 3)
    struct.pack_into("<IIII", raw, 80, 0, 0, 2, 2)
    struct.pack_into("<IIII", raw, 96, 0, 0, 2, 2)
    raw[112:128] = bytes.fromhex("00112233445566778899aabbccddeeff")
    raw[128:148] = bytes.fromhex("11" * 20)
    struct.pack_into("<IQ", raw, 148, 0, 0)
    raw[160:] = b"\x01\x00\x00\x01"
    return bytes(raw)


def fixture(directory: pathlib.Path, label: str = "a"):
    artifact_raw = input_artifact()
    artifact = collector.parse_input_artifact(artifact_raw)
    coverage_raw = coverage_artifact()
    coverage_module = collector.load_coverage_module()
    coverage = coverage_module.parse_coverage(coverage_raw)
    resource = {
        "label": "RendererIOS.SceneHDR.00112233445566778899aabbccddeeff",
        "textureRef": "@tex1", "allocationID": "41",
        "resourceIndex": "0x20", "pixelFormat": "RG11B10Float",
        "textureType": "2D", "storageMode": "Private",
        "mipLevel": 0, "arraySlice": 0,
    }
    gpu = {
        "source": {"captureManifestSha256": "21" * 32,
                   "transcriptManifestSha256": "22" * 32},
        "runIdentity": {
            "targetGeneration": 3, "snapshotSequence": 5,
            "proofId": "00112233445566778899aabbccddeeff",
            "buildSha": "11" * 20},
        "extent": {"width": 2, "height": 2},
        "sceneResource": resource,
        "command": {
            "commandBuffer": "cb4",
            "scene": {"encoderPath": "commands/cb4/re0"},
            "proofBlit": {
                "encoderPath": "commands/cb4/be1",
                "commandPath": "commands/cb4/be1/grp0/blit0"},
            "toneResolve": {
                "encoderPath": "commands/cb4/re4",
                "drawPath": "commands/cb4/re4/grp0/draw0"},
        },
    }
    constants = artifact["record"]["constants"]
    padded = b"\x01\x00" + bytes(254) + b"\x00\x01" + bytes(254)
    transcript_raw = b"bounded transcript\n"
    transcript_path = directory / "draw-info.json"
    transcript_path.write_bytes(transcript_raw)
    os.chmod(transcript_path, 0o600)
    entries = [{
        "argv": ["/usr/bin/gpudebug", "--json"],
        "bytes": len(transcript_raw), "file": "draw-info.json",
        "kind": "transcript", "role": "draw-info",
        "sha256": collector.sha256(transcript_raw),
    }]
    observed = {
        "bindApiIndex": 11,
        "bindText": ("RendererIOS multiply2 causal draw-bind: src=7 "
                     "sel=multiply2 kind=static tex=10 mesh=8 mat=9 off=4 "
                     "count=3 pso=multiply2 depth=ro target=SceneHDR"),
        "color0": resource, "constantsRaw": constants,
        "coverageBytesPerImage": 512,
        "coverageCopyPath": "commands/cb4/be2/grp0/blit0",
        "coverageDestination": {"allocationID": "44",
                                "resourceIndex": "0x23",
                                "bufferRef": "@buf4"},
        "coverageOffset": 0, "coveragePaddedRaw": padded,
        "coverageRow": 256,
        "coverageSource": {"allocationID": "42",
                           "resourceIndex": "0x21",
                           "textureRef": "@tex2"},
        "depth": {"allocationID": "42", "resourceIndex": "0x21",
                  "textureRef": "@tex2"},
        "drawApiIndex": 12,
        "drawPath": "commands/cb4/re0/grp0/draw3",
        "drawTranscriptManifestSha256": "23" * 32,
        "fragmentFunction": "riosLandscapeAdditiveFragment",
        "idApiIndex": 10,
        "idText": ("RendererIOS multiply2 causal draw-id: v=1 mode="
                   f"{label} generation=3 sequence=5 source=7"),
        "indexBuffer": {"allocationID": "46", "resourceIndex": "0x25",
                        "bufferRef": "@buf6"},
        "indexBufferOffset": 4, "indexCount": 3,
        "indexRaw": bytes(range(16)),
        "pipelineLabel": "RendererIOS.Static.Multiply2",
        "proofCopyPath": "commands/cb4/be1/grp0/blit0",
        "proofSource": resource,
        "sourceRGBBlendFactor": "DestinationColor" if label == "a" else "Zero",
        "stencil": {"allocationID": "42", "resourceIndex": "0x21",
                    "textureRef": "@tex2"},
        "stencilState": {
            "depthCompare": "LessEqual", "depthWriteEnabled": False,
            "provenance": {
                "compareAndOperations": "capture-observed",
                "masksAndReference": "code-contract"},
            "stencilCompare": "Always", "stencilDepthFail": "Keep",
            "stencilFail": "Keep", "stencilPass": "Replace",
            "stencilReadMask": 255, "stencilReference": 1,
            "stencilWriteMask": 255},
        "texture": {"allocationID": "43", "resourceIndex": "0x22",
                    "textureRef": "@tex3"},
        "textureHeight": 4, "textureMipCount": 3,
        "texturePixelFormat": "RGBA8Unorm", "textureWidth": 4,
        "toneDrawPath": "commands/cb4/re4/grp0/draw0",
        "vertexBuffer": {"allocationID": "45", "resourceIndex": "0x24",
                         "bufferRef": "@buf5"},
        "vertexFunction": "riosLandscapeVertex",
        "vertexRaw": bytes(range(36)),
    }
    document = collector.build_document(
        gpu, b"{}\n", artifact, artifact_raw, coverage, coverage_raw,
        observed, entries, directory, label)
    return document, gpu, artifact, artifact_raw, coverage, coverage_raw, observed, entries


class DrawEvidenceTests(unittest.TestCase):
    def test_build_and_validate_both_labels(self):
        for label in ("a", "b"):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as raw:
                document, *_ = fixture(pathlib.Path(raw), label)
                self.assertIs(collector.validate_document(document), document)
                self.assertEqual(document["draw"]["sourceRGBBlendFactor"],
                                 "DestinationColor" if label == "a" else "Zero")

    def test_structural_mutations_fail_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            document, *_ = fixture(pathlib.Path(raw))
            mutations = []
            changed = copy.deepcopy(document)
            changed["draw"]["constantsBufferIndex"] = 2
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["draw"]["depthStencilAllocationID"] = "99"
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["draw"]["viewport"]["provenance"] = "capture-observed"
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["draw"]["sourceRGBBlendFactor"] = "SourceAlpha"
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["draw"]["stencilState"]["stencilWriteMask"] = 0
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["signposts"]["drawApiIndex"] += 1
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["coverage"]["blitOption"] = "None"
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["draw"]["vertexBufferSha256"] = "0" * 63
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["stages"]["toneResolve"]["textureRef"] = "@tex9"
            mutations.append(changed)
            changed = copy.deepcopy(document)
            changed["extra"] = True
            mutations.append(changed)
            for index, mutation in enumerate(mutations):
                with self.subTest(index=index), self.assertRaises(collector.EvidenceError):
                    collector.validate_document(mutation)

    def test_observed_resource_mutations_fail_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            (_, gpu, artifact, artifact_raw, coverage, coverage_raw,
             observed, entries) = fixture(directory)
            mutations = []
            changed = copy.deepcopy(observed)
            changed["constantsRaw"] = bytes(160)
            mutations.append(changed)
            changed = copy.deepcopy(observed)
            changed["vertexRaw"] = bytes(35)
            mutations.append(changed)
            changed = copy.deepcopy(observed)
            changed["coveragePaddedRaw"] = bytes(512)
            mutations.append(changed)
            changed = copy.deepcopy(observed)
            changed["coverageSource"]["allocationID"] = "99"
            mutations.append(changed)
            changed = copy.deepcopy(observed)
            changed["sourceRGBBlendFactor"] = "Zero"
            mutations.append(changed)
            for index, mutation in enumerate(mutations):
                with self.subTest(index=index), self.assertRaises(collector.EvidenceError):
                    collector.build_document(
                        gpu, b"{}\n", artifact, artifact_raw, coverage,
                        coverage_raw, mutation, entries, directory, "a")

    def test_transcript_manifest_and_cli_validation(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            document, *_ = fixture(directory)
            entries = [{
                "argv": ["/usr/bin/gpudebug", "--json"],
                "bytes": len(b"bounded transcript\n"),
                "file": "draw-info.json", "kind": "transcript",
                "role": "draw-info",
                "sha256": collector.sha256(b"bounded transcript\n"),
            }]
            manifest = collector.transcript_manifest_bytes(entries, directory)
            manifest_path = directory / collector.TRANSCRIPT_MANIFEST_LEAF
            manifest_path.write_bytes(manifest)
            os.chmod(manifest_path, 0o600)
            document["source"]["drawTranscriptManifestSha256"] = \
                collector.sha256(manifest)
            evidence = directory.parent / "draw-evidence.json"
            evidence.write_bytes(collector.canonical_json(document))
            os.chmod(evidence, 0o600)
            self.assertEqual(collector.main([
                "--validate", "--evidence", str(evidence),
                "--transcript-dir", str(directory)]), 0)
            (directory / "draw-info.json").write_bytes(b"changed\n")
            with self.assertRaises(collector.EvidenceError):
                collector.validate_transcript_directory(document, directory)


if __name__ == "__main__":
    unittest.main()
