#!/usr/bin/env python3
"""Fixture and mutation tests for normalized P2.1e0 GPU evidence."""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
from typing import Any, Callable, Union


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ios" / "device-test" / "validate-linear-hdr-gpu-evidence.py"
FIXTURE = ROOT / "ios" / "tests" / "fixtures" / "linear-hdr-gpu-evidence-v1.json"

SPEC = importlib.util.spec_from_file_location("linear_hdr_gpu_evidence", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load linear-HDR GPU evidence validator")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)

BUILD = "0123456789abcdef0123456789abcdef01234567"


PathPart = Union[str, int]
Mutation = Callable[[dict[str, Any]], None]


def make_capture(parent: pathlib.Path) -> pathlib.Path:
    capture = parent / "RendererIOS-linear-hdr.gputrace"
    capture.mkdir()
    for name, payload in (
        ("capture", b"capture-v1"),
        ("index", b"index-v1"),
        ("metadata", b"metadata-v1"),
        ("store0", b"store-v1"),
        ("MTLTexture-7-0-mipmap0-slice0", b"linear-hdr-pixels"),
    ):
        (capture / name).write_bytes(payload)
    return capture


def device_document(base: dict[str, Any], capture: pathlib.Path) -> dict[str, Any]:
    document = copy.deepcopy(base)
    document["evidenceClass"] = "device-gpudebug"
    document["source"]["captureSha256"] = VALIDATOR.capture_sha256(capture)
    document["runIdentity"] = {
        "buildSha": BUILD,
        "targetGeneration": 7,
        "snapshotSequence": 41,
    }
    document["extent"] = {"width": 4, "height": 3}
    document["logicalBytes"] = 48
    document["resources"]["scene"]["width"] = 4
    document["resources"]["scene"]["height"] = 3
    document["resources"]["scene"]["allocatedBytes"] = 64
    document["resources"]["drawable"]["width"] = 4
    document["resources"]["drawable"]["height"] = 3
    document["sceneSamples"]["samples"] = [
        {"x": 1, "y": 2, "rgb": [1.375, 0.625, 0.25]}
    ]
    document["sceneSamples"]["observedMaximumComponent"] = 1.625
    return document


def linear_hdr_log(
    *,
    build: str = BUILD,
    generation: int = 7,
    sequence: int = 41,
    width: int = 4,
    height: int = 3,
    ui: int = 1,
) -> str:
    byte_size = width * height * 4
    return (
        "RendererIOS linear HDR activation: "
        f"attempt=startup probe=1 target=1 scene=1 resolve=1 ready=1 safe=0 "
        f"bytes={byte_size} generation={generation}\n"
        "RendererIOS linear HDR: "
        f"v=1 b={build} g={generation} s={sequence} w={width} h={height} "
        f"fmt=rg11b10f probe=1 target=1 scene=1 resolve=1 ui={ui} "
        "present=1 terminal=C\n"
    )


def assign(path: tuple[PathPart, ...], value: Any) -> Mutation:
    def apply(document: dict[str, Any]) -> None:
        target: Any = document
        for part in path[:-1]:
            target = target[part]
        target[path[-1]] = value

    return apply


def remove(path: tuple[PathPart, ...]) -> Mutation:
    def apply(document: dict[str, Any]) -> None:
        target: Any = document
        for part in path[:-1]:
            target = target[part]
        del target[path[-1]]

    return apply


def append(path: tuple[PathPart, ...], value: Any) -> Mutation:
    def apply(document: dict[str, Any]) -> None:
        target: Any = document
        for part in path:
            target = target[part]
        target.append(value)

    return apply


class LinearHDRGPUEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def assert_rejected(self, mutation: Mutation, label: str) -> None:
        document = copy.deepcopy(self.document)
        mutation(document)
        with self.subTest(mutation=label):
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.validate_document(document)

    def test_valid_fixture_passes_library_and_cli(self) -> None:
        VALIDATOR.validate_document(copy.deepcopy(self.document))
        denied = subprocess.run(
            [sys.executable, str(SCRIPT), "--evidence", str(FIXTURE)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(denied.returncode, 1)
        self.assertIn("synthetic fixture requires explicit", denied.stderr)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--evidence",
                str(FIXTURE),
                "--allow-synthetic-fixture",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "linear HDR GPU evidence validation passed: class=synthetic-fixture\n",
        )
        self.assertEqual(result.stderr, "")

    def test_allocated_bytes_may_include_padding(self) -> None:
        document = copy.deepcopy(self.document)
        document["resources"]["scene"]["allocatedBytes"] += 4096
        VALIDATOR.validate_document(document)

    def test_dummy_texture_and_manual_hdr_values_are_blocked_after_device_join(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            capture = make_capture(directory)
            document = device_document(self.document, capture)
            self.assertEqual(
                (capture / "MTLTexture-7-0-mipmap0-slice0").read_bytes(),
                b"linear-hdr-pixels",
            )
            self.assertEqual(document["sceneSamples"]["samples"][0]["rgb"][0], 1.375)
            self.assertEqual(document["sceneSamples"]["observedMaximumComponent"], 1.625)
            log = directory / "linear-hdr.log"
            log.write_text(linear_hdr_log(), encoding="utf-8")
            evidence = directory / "evidence.json"
            evidence.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(
                VALIDATOR.EvidenceError,
                rf"^{VALIDATOR.MISSING_LOSSLESS_SCENE_SAMPLE_PROOF}$",
            ):
                VALIDATOR.validate_device_join(
                    document,
                    capture,
                    log,
                    BUILD,
                    "startup",
                    True,
                )

            incomplete = subprocess.run(
                [sys.executable, str(SCRIPT), "--evidence", str(evidence)],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertEqual(incomplete.returncode, 1)
            self.assertIn("device evidence requires --capture", incomplete.stderr)

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--evidence",
                    str(evidence),
                    "--capture",
                    str(capture),
                    "--log",
                    str(log),
                    "--expected-sha",
                    BUILD,
                    "--require-attempt",
                    "startup",
                    "--require-ui",
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertEqual(
                result.stderr,
                "linear HDR GPU evidence validation failed: "
                f"{VALIDATOR.MISSING_LOSSLESS_SCENE_SAMPLE_PROOF}\n",
            )

    def test_device_join_rejects_foreign_identity_extent_and_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            capture = make_capture(directory)
            document = device_document(self.document, capture)
            log = directory / "linear-hdr.log"
            log.write_text(linear_hdr_log(), encoding="utf-8")

            mutations = (
                (
                    "digest",
                    assign(("source", "captureSha256"), "0" * 64),
                    "capture digest differs from GPU evidence JSON",
                ),
                (
                    "build",
                    assign(("runIdentity", "buildSha"), "1" * 40),
                    "build SHA does not join GPU evidence and log",
                ),
                (
                    "generation",
                    assign(("runIdentity", "targetGeneration"), 8),
                    "target generation does not join GPU evidence and log",
                ),
                (
                    "sequence",
                    assign(("runIdentity", "snapshotSequence"), 42),
                    "snapshot sequence does not join GPU evidence and log",
                ),
            )
            for label, mutation, expected_error in mutations:
                candidate = copy.deepcopy(document)
                mutation(candidate)
                with self.subTest(join=label):
                    with self.assertRaisesRegex(
                        VALIDATOR.EvidenceError,
                        rf"^{re.escape(expected_error)}$",
                    ):
                        VALIDATOR.validate_device_join(
                            candidate,
                            capture,
                            log,
                            BUILD,
                            "startup",
                            True,
                        )

            foreign_extent_log = directory / "foreign-extent.log"
            foreign_extent_log.write_text(
                linear_hdr_log(width=5, height=3),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                VALIDATOR.EvidenceError,
                r"^width does not join GPU evidence and log$",
            ):
                VALIDATOR.validate_device_join(
                    document,
                    capture,
                    foreign_extent_log,
                    BUILD,
                    "startup",
                    True,
                )

    def test_capture_bundle_shape_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)

            regular_file = directory / "file.gputrace"
            regular_file.write_bytes(b"not-a-directory")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.capture_sha256(regular_file)

            missing = directory / "missing.gputrace"
            missing.mkdir()
            for name in ("capture", "index", "metadata", "MTLTexture-0"):
                (missing / name).write_bytes(b"x")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.capture_sha256(missing)

            no_texture = directory / "no-texture.gputrace"
            no_texture.mkdir()
            for name in ("capture", "index", "metadata", "store0"):
                (no_texture / name).write_bytes(b"x")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.capture_sha256(no_texture)

            symlinked = directory / "symlinked.gputrace"
            symlinked.mkdir()
            for name in ("capture", "index", "metadata", "store0"):
                (symlinked / name).write_bytes(b"x")
            (symlinked / "MTLTexture-0").symlink_to(symlinked / "capture")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.capture_sha256(symlinked)

    def test_semantic_mutations_fail_closed(self) -> None:
        mutations: tuple[tuple[str, Mutation], ...] = (
            ("schema version", assign(("schemaVersion",), 2)),
            ("boolean schema version", assign(("schemaVersion",), True)),
            ("evidence class", assign(("evidenceClass",), "device-log")),
            ("producer", assign(("producer",), "local-tool/1")),
            ("unknown root key", assign(("unexpected",), True)),
            ("missing source", remove(("source",))),
            ("source tool", assign(("source", "tool"), "metal-system-trace")),
            ("source version grammar", assign(("source", "toolVersion"), "unknown")),
            ("capture digest case", assign(("source", "captureSha256"), "A" * 64)),
            ("unknown source key", assign(("source", "capturePath"), "/tmp/capture")),
            ("run build", assign(("runIdentity", "buildSha"), "a" * 39)),
            ("run generation zero", assign(("runIdentity", "targetGeneration"), 0)),
            ("run generation boolean", assign(("runIdentity", "targetGeneration"), True)),
            ("run sequence zero", assign(("runIdentity", "snapshotSequence"), 0)),
            ("unknown run identity key", assign(("runIdentity", "attempt"), "startup")),
            ("zero width", assign(("extent", "width"), 0)),
            ("boolean height", assign(("extent", "height"), True)),
            ("unknown extent key", assign(("extent", "depth"), 1)),
            ("logical bytes", assign(("logicalBytes",), 12054095)),
            ("logical bytes float", assign(("logicalBytes",), 12054096.0)),
            ("scene resource identity", assign(("resources", "scene", "resource"), "drawable")),
            ("scene format", assign(("resources", "scene", "pixelFormat"), "BGRA8Unorm")),
            ("scene texture type", assign(("resources", "scene", "textureType"), "2DArray")),
            ("scene storage", assign(("resources", "scene", "storageMode"), "Shared")),
            ("scene usage missing shader read", assign(("resources", "scene", "usage"), ["RenderTarget"])),
            ("scene usage order", assign(("resources", "scene", "usage"), ["ShaderRead", "RenderTarget"])),
            ("scene width", assign(("resources", "scene", "width"), 1178)),
            ("scene width float", assign(("resources", "scene", "width"), 1179.0)),
            ("scene height", assign(("resources", "scene", "height"), 2555)),
            ("scene bytes per pixel", assign(("resources", "scene", "bytesPerPixel"), 8)),
            ("scene allocation", assign(("resources", "scene", "allocatedBytes"), 12054095)),
            ("unknown scene resource key", assign(("resources", "scene", "sampleCount"), 1)),
            ("drawable identity", assign(("resources", "drawable", "resource"), "scene-color")),
            ("drawable format", assign(("resources", "drawable", "pixelFormat"), "RGBA8Unorm")),
            ("drawable width", assign(("resources", "drawable", "width"), 1178)),
            ("drawable width float", assign(("resources", "drawable", "width"), 1179.0)),
            ("drawable height", assign(("resources", "drawable", "height"), 2555)),
            ("missing event", remove(("events", 3))),
            ("extra event", append(("events",), {"index": 4, "kind": "present", "resource": "drawable"})),
            ("scene index", assign(("events", 0, "index"), 1)),
            ("scene index boolean", assign(("events", 0, "index"), False)),
            ("scene kind", assign(("events", 0, "kind"), "overlay")),
            ("scene label", assign(("events", 0, "label"), "Scene")),
            ("scene target", assign(("events", 0, "colorResource"), "drawable")),
            ("scene pass format", assign(("events", 0, "pixelFormat"), "BGRA8Unorm")),
            ("scene load", assign(("events", 0, "loadAction"), "Load")),
            ("scene store", assign(("events", 0, "storeAction"), "DontCare")),
            ("scene has no draws", assign(("events", 0, "draws"), [])),
            ("scene vertex", assign(("events", 0, "draws", 0, "vertexFunction"), "otherVertex")),
            ("scene fragment", assign(("events", 0, "draws", 0, "fragmentFunction"), "riosUiFragment")),
            ("scene lacks opaque Landscape", remove(("events", 0, "draws", 0))),
            ("unknown scene pass key", assign(("events", 0, "depthResource"), "depth")),
            ("tone index", assign(("events", 1, "index"), 2)),
            ("tone index boolean", assign(("events", 1, "index"), True)),
            ("tone kind", assign(("events", 1, "kind"), "scene")),
            ("tone target", assign(("events", 1, "colorResource"), "scene-color")),
            ("tone format", assign(("events", 1, "pixelFormat"), "RG11B10Float")),
            ("tone load", assign(("events", 1, "loadAction"), "Load")),
            ("tone store", assign(("events", 1, "storeAction"), "DontCare")),
            ("tone vertex", assign(("events", 1, "vertexFunction"), "riosLandscapeVertex")),
            ("tone fragment", assign(("events", 1, "fragmentFunction"), "riosUiFragment")),
            ("tone texture missing", assign(("events", 1, "fragmentTextures"), [])),
            ("tone texture index", assign(("events", 1, "fragmentTextures", 0, "index"), 1)),
            ("tone texture index boolean", assign(("events", 1, "fragmentTextures", 0, "index"), False)),
            ("tone texture resource", assign(("events", 1, "fragmentTextures", 0, "resource"), "drawable")),
            ("tone texture access", assign(("events", 1, "fragmentTextures", 0, "access"), "ReadWrite")),
            ("tone sampler field", assign(("events", 1, "fragmentTextures", 0, "sampler"), "linear")),
            ("tone sampler binding", assign(("events", 1, "fragmentSamplers"), [{"index": 0}])),
            ("overlay index", assign(("events", 2, "index"), 3)),
            ("overlay kind", assign(("events", 2, "kind"), "present")),
            ("overlay target", assign(("events", 2, "colorResource"), "scene-color")),
            ("overlay format", assign(("events", 2, "pixelFormat"), "RG11B10Float")),
            ("overlay load", assign(("events", 2, "loadAction"), "DontCare")),
            ("overlay store", assign(("events", 2, "storeAction"), "DontCare")),
            ("present index", assign(("events", 3, "index"), 2)),
            ("present kind", assign(("events", 3, "kind"), "overlay")),
            ("present resource", assign(("events", 3, "resource"), "scene-color")),
            ("sample encoding", assign(("sceneSamples", "encoding"), "srgb")),
            ("empty samples", assign(("sceneSamples", "samples"), [])),
            ("sample x negative", assign(("sceneSamples", "samples", 0, "x"), -1)),
            ("sample x outside", assign(("sceneSamples", "samples", 0, "x"), 1179)),
            ("sample y outside", assign(("sceneSamples", "samples", 0, "y"), 2556)),
            ("sample rgb arity", assign(("sceneSamples", "samples", 0, "rgb"), [1.5, 0.5])),
            ("sample negative", assign(("sceneSamples", "samples", 0, "rgb", 2), -0.1)),
            ("sample boolean", assign(("sceneSamples", "samples", 0, "rgb", 2), True)),
            ("no sampled HDR", assign(("sceneSamples", "samples", 0, "rgb", 0), 1.0)),
            ("maximum not HDR", assign(("sceneSamples", "observedMaximumComponent"), 1.0)),
            ("maximum below sample", assign(("sceneSamples", "observedMaximumComponent"), 1.25)),
            ("unknown sample key", assign(("sceneSamples", "samples", 0, "alpha"), 1.0)),
            ("unknown samples key", assign(("sceneSamples", "method"), "screen")),
        )
        for label, mutation in mutations:
            self.assert_rejected(mutation, label)

    def test_event_reordering_is_rejected(self) -> None:
        def reorder(document: dict[str, Any]) -> None:
            document["events"][1], document["events"][2] = document["events"][2], document["events"][1]

        self.assert_rejected(reorder, "tone and overlay order")

    def test_parser_rejects_duplicate_keys_nonfinite_json_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            duplicate = directory / "duplicate.json"
            duplicate.write_text('{"schemaVersion":1,"schemaVersion":1}\n', encoding="utf-8")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.load_document(duplicate)

            nonfinite = directory / "nonfinite.json"
            nonfinite.write_text('{"value":NaN}\n', encoding="utf-8")
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.load_document(nonfinite)

            symlink = directory / "evidence-link.json"
            symlink.symlink_to(FIXTURE)
            with self.assertRaises(VALIDATOR.EvidenceError):
                VALIDATOR.load_document(symlink)


if __name__ == "__main__":
    unittest.main()
