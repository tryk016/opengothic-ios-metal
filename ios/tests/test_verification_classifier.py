#!/usr/bin/env python3
"""Contract and mutation tests for the RendererIOS verification classifier."""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "classify_verification.py"
POLICY = ROOT / "verification-policy.json"
SPEC = importlib.util.spec_from_file_location("classify_verification", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load verification classifier")
CLASSIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLASSIFIER)


class VerificationClassifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.policy = CLASSIFIER.load_policy(POLICY)

    def classify(self, *paths: str) -> dict[str, object]:
        return CLASSIFIER.classify_paths(self.policy, list(paths))

    def test_device_facts_selects_exact_shared_runtime_gates(self) -> None:
        result = self.classify("game/graphics/iosdevicefactscollector.mm")
        self.assertEqual(result["risk"], "device-facts")
        self.assertEqual(
            result["gates"],
            ["device-facts", "strict-compile", "build-off", "build-on"],
        )
        self.assertFalse(result["full"])

    def test_tile_selects_tile_and_production_baseline(self) -> None:
        for path in (
            "game/graphics/iosshadingprototypetileprobe.mm",
            "game/graphics/iosshadingprototypepipelinenative.h",
        ):
            with self.subTest(path=path):
                result = self.classify(path)
                self.assertEqual(result["risk"], "tile")
                self.assertEqual(
                    result["gates"],
                    ["tile-contracts", "build-off", "build-tile"],
                )

    def test_forward_selects_forward_and_production_baseline(self) -> None:
        for path in (
            "game/graphics/iosshadingprototypeforwardprobe.cpp",
            "game/graphics/iosshadingprototypeforwardpipelinenative.h",
        ):
            with self.subTest(path=path):
                result = self.classify(path)
                self.assertEqual(result["risk"], "forward")
                self.assertEqual(
                    result["gates"],
                    ["forward-contracts", "build-off", "build-forward"],
                )

    def test_remaining_material_census_routes_exact_diagnostics_gates(self) -> None:
        paths = (
            "game/graphics/iosremainingmaterialcensus.h",
            "ios/device-test/validate-remaining-material-device-attestation.py",
            "ios/simulator-test/run-remaining-material-census.sh",
        )
        for path in paths:
            with self.subTest(path=path):
                result = self.classify(path)
                self.assertEqual(result["risk"], "diagnostics")
                self.assertEqual(
                    result["gates"],
                    ["contracts", "strict-compile", "build-off", "build-on"],
                )
                self.assertIn(
                    "remaining-material-source-census",
                    result["matches"][0]["rules"],
                )

    def test_union_preserves_global_gate_order(self) -> None:
        result = self.classify(
            "game/graphics/iosdevicefactscollector.cpp",
            "game/graphics/iosshadingprototypeforwardprobe.mm",
        )
        self.assertEqual(result["risk"], "forward")
        self.assertEqual(
            result["gates"],
            [
                "device-facts",
                "forward-contracts",
                "strict-compile",
                "build-off",
                "build-on",
                "build-forward",
            ],
        )

    def test_cmake_tempest_shader_and_policy_are_full(self) -> None:
        for path in (
            "CMakeLists.txt",
            "lib/Tempest",
            "lib/Tempest/Engine/CMakeLists.txt",
            "shader/ios-metal/shading-prototypes.metal",
            "verification-policy.json",
            "scripts/verify.command",
            "scripts/execute_verification_gates.py",
            "scripts/verify-local-build.command",
            "ios/tests/test_verification_router.py",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.classify(path)["gates"], ["full"])

    def test_unknown_path_is_fail_closed_full(self) -> None:
        result = self.classify("unexpected/new-system.xyz")
        self.assertEqual(result["risk"], "unknown")
        self.assertEqual(result["gates"], ["full"])
        self.assertEqual(result["matches"][0]["rules"], ["fallback"])

    def test_documentation_is_lightweight(self) -> None:
        result = self.classify("README.md")
        self.assertEqual(result["risk"], "documentation")
        self.assertEqual(result["gates"], ["policy-contracts"])

    def test_rename_and_delete_keep_every_affected_path(self) -> None:
        data = (
            b"R100\0docs/old.md\0game/graphics/iosdevicefactscollector.mm\0"
            b"D\0game/graphics/iosdevicefactscollector.cpp\0"
        )
        changes = CLASSIFIER.parse_name_status(data)
        self.assertEqual(changes[0]["status"], "R100")
        self.assertEqual(len(changes[0]["paths"]), 2)
        paths = CLASSIFIER.flatten_changed_paths(changes)
        self.assertEqual(
            paths,
            [
                "docs/old.md",
                "game/graphics/iosdevicefactscollector.mm",
                "game/graphics/iosdevicefactscollector.cpp",
            ],
        )
        self.assertEqual(
            self.classify(*paths)["gates"],
            [
                "policy-contracts",
                "device-facts",
                "strict-compile",
                "build-off",
                "build-on",
            ],
        )

    def test_truncated_rename_fails_closed(self) -> None:
        with self.assertRaises(CLASSIFIER.DiffError):
            CLASSIFIER.parse_name_status(b"R100\0old.cpp\0")

    def test_malformed_status_fails_closed(self) -> None:
        for payload in (
            b"R\0old.cpp\0new.cpp\0",
            b"R101\0old.cpp\0new.cpp\0",
            b"M50\0file.cpp\0",
            b"Z\0file.cpp\0",
        ):
            with self.subTest(payload=payload):
                with self.assertRaises(CLASSIFIER.DiffError):
                    CLASSIFIER.parse_name_status(payload)

    def test_empty_diff_fails_closed(self) -> None:
        with self.assertRaises(CLASSIFIER.DiffError):
            CLASSIFIER.parse_name_status(b"")
        with self.assertRaises(CLASSIFIER.DiffError):
            CLASSIFIER.classify_paths(self.policy, [])

    def test_unsafe_or_non_normalized_paths_are_rejected(self) -> None:
        for path in ("/absolute", "../escape", "a//b", "a\\b", "./local"):
            with self.subTest(path=path):
                with self.assertRaises(CLASSIFIER.PolicyError):
                    self.classify(path)

    def test_policy_requires_unique_rules(self) -> None:
        mutation = copy.deepcopy(json.loads(POLICY.read_text(encoding="utf-8")))
        mutation["rules"][1]["id"] = mutation["rules"][0]["id"]
        with self.assertRaises(CLASSIFIER.PolicyError):
            CLASSIFIER.validate_policy(mutation)

    def test_policy_rejects_unknown_keys(self) -> None:
        root_mutation = copy.deepcopy(
            json.loads(POLICY.read_text(encoding="utf-8"))
        )
        root_mutation["gateOdrer"] = root_mutation["gateOrder"]
        with self.assertRaises(CLASSIFIER.PolicyError):
            CLASSIFIER.validate_policy(root_mutation)

        rule_mutation = copy.deepcopy(
            json.loads(POLICY.read_text(encoding="utf-8"))
        )
        rule_mutation["rules"][0]["excludePath"] = []
        with self.assertRaises(CLASSIFIER.PolicyError):
            CLASSIFIER.validate_policy(rule_mutation)

    def test_overlapping_rules_union_and_ignore_rule_order(self) -> None:
        payload = copy.deepcopy(json.loads(POLICY.read_text(encoding="utf-8")))
        payload["rules"][-1]["paths"].append(
            "game/graphics/iosdevicefactscollector.*"
        )
        forward = CLASSIFIER.validate_policy(payload)
        payload["rules"].reverse()
        reversed_policy = CLASSIFIER.validate_policy(payload)

        path = "game/graphics/iosdevicefactscollector.mm"
        forward_result = CLASSIFIER.classify_paths(forward, [path])
        reversed_result = CLASSIFIER.classify_paths(reversed_policy, [path])
        self.assertEqual(forward_result, reversed_result)
        self.assertEqual(
            forward_result["gates"],
            [
                "policy-contracts",
                "device-facts",
                "strict-compile",
                "build-off",
                "build-on",
            ],
        )
        self.assertEqual(
            forward_result["matches"][0]["rules"],
            ["device-facts", "documentation"],
        )

    def test_policy_rejects_unknown_gate_and_risk(self) -> None:
        gate_mutation = copy.deepcopy(
            json.loads(POLICY.read_text(encoding="utf-8"))
        )
        gate_mutation["rules"][0]["gates"] = ["does-not-exist"]
        with self.assertRaises(CLASSIFIER.PolicyError):
            CLASSIFIER.validate_policy(gate_mutation)

        risk_mutation = copy.deepcopy(
            json.loads(POLICY.read_text(encoding="utf-8"))
        )
        risk_mutation["fallback"]["risk"] = "maybe"
        with self.assertRaises(CLASSIFIER.PolicyError):
            CLASSIFIER.validate_policy(risk_mutation)

    def test_policy_fallback_must_be_full(self) -> None:
        mutation = copy.deepcopy(json.loads(POLICY.read_text(encoding="utf-8")))
        mutation["fallback"]["gates"] = ["build-off"]
        with self.assertRaises(CLASSIFIER.PolicyError):
            CLASSIFIER.validate_policy(mutation)

    def test_required_infrastructure_cannot_be_downgraded(self) -> None:
        mutation = copy.deepcopy(json.loads(POLICY.read_text(encoding="utf-8")))
        mutation["rules"][0]["gates"] = ["policy-contracts"]
        with self.assertRaises(CLASSIFIER.PolicyError):
            CLASSIFIER.validate_policy(mutation)

        unclassified = copy.deepcopy(
            json.loads(POLICY.read_text(encoding="utf-8"))
        )
        unclassified["rules"][0]["paths"].remove("verification-policy.json")
        with self.assertRaises(CLASSIFIER.PolicyError):
            CLASSIFIER.validate_policy(unclassified)

    def test_cli_requires_explicit_change_source(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("choose exactly one change source", completed.stderr)

    def test_cli_rejects_head_without_base(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--path",
                "README.md",
                "--head",
                "HEAD~1",
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("--head requires --base", completed.stderr)

    def test_cli_name_status_fixture_emits_machine_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = pathlib.Path(temporary) / "changes.bin"
            fixture.write_bytes(
                b"M\0game/graphics/iosdevicefactscollector.cpp\0"
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--name-status-file",
                    str(fixture),
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["risk"], "device-facts")
        self.assertEqual(
            payload["changedPaths"],
            ["game/graphics/iosdevicefactscollector.cpp"],
        )
        self.assertFalse(payload["fallback"])
        self.assertEqual(len(payload["policySha256"]), 64)

    def test_cli_output_is_canonical_for_the_same_path_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = pathlib.Path(temporary) / "changes.bin"
            fixture.write_bytes(
                b"M\0README.md\0"
                b"M\0game/graphics/iosdevicefactscollector.cpp\0"
            )
            from_fixture = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--name-status-file",
                    str(fixture),
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            from_paths = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--path",
                    "game/graphics/iosdevicefactscollector.cpp",
                    "--path",
                    "README.md",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertEqual(from_fixture.returncode, 0, from_fixture.stderr)
        self.assertEqual(from_paths.returncode, 0, from_paths.stderr)
        self.assertEqual(from_fixture.stdout, from_paths.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
