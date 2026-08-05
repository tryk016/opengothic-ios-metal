#!/usr/bin/env python3
"""Host-neutral tests for validate-linear-hdr-log.py."""

from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR_PATH = ROOT / "ios/device-test/validate-linear-hdr-log.py"
SPEC = importlib.util.spec_from_file_location("validate_linear_hdr_log", VALIDATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load linear-HDR validator")
validator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = validator
SPEC.loader.exec_module(validator)

BUILD = "0123456789abcdef0123456789abcdef01234567"
OTHER_BUILD = "1123456789abcdef0123456789abcdef01234567"
WIDTH = 852
HEIGHT = 393
BYTES = WIDTH * HEIGHT * 4


def activation(
    attempt: str = "startup",
    *,
    probe: int = 1,
    target: int = 1,
    scene: int = 1,
    resolve: int = 1,
    ready: int = 1,
    safe: int = 0,
    byte_size: int = BYTES,
    generation: int = 7,
) -> str:
    return (
        "RendererIOS linear HDR activation: "
        f"attempt={attempt} probe={probe} target={target} scene={scene} "
        f"resolve={resolve} ready={ready} safe={safe} bytes={byte_size} "
        f"generation={generation}"
    )


def terminal(
    *,
    build: str = BUILD,
    generation: int = 7,
    sequence: int = 41,
    width: int = WIDTH,
    height: int = HEIGHT,
    ui: int = 0,
) -> str:
    return (
        "RendererIOS linear HDR: "
        f"v=1 b={build} g={generation} s={sequence} w={width} h={height} "
        "fmt=rg11b10f probe=1 target=1 scene=1 resolve=1 "
        f"ui={ui} present=1 terminal=C"
    )


def fixture(
    *, attempt: str = "startup", ui: int = 0, include_failed_startup: bool = False
) -> str:
    lines = ["RendererIOS diagnostics: ON frames-in-flight=3"]
    if include_failed_startup:
        lines.append(
            activation(
                "startup",
                target=0,
                scene=0,
                resolve=0,
                ready=0,
                safe=1,
                byte_size=0,
                generation=0,
            )
        )
    lines.extend(
        (activation(attempt), terminal(ui=ui), "RendererIOS shutdown: clean")
    )
    return "\n".join(lines) + "\n"


class LinearHDRValidatorTests(unittest.TestCase):
    def assert_rejected(
        self,
        log: str,
        *,
        attempt: str = "startup",
        require_ui: bool = False,
        expected_sha: str = BUILD,
    ) -> None:
        with self.assertRaises(validator.ValidationError):
            validator.validate(log, expected_sha, attempt, require_ui)

    def test_accepts_startup_and_recreate_fixtures(self) -> None:
        startup = validator.validate(fixture(), BUILD, "startup")
        self.assertEqual(startup["result"], "PASS")
        self.assertEqual(startup["generation"], 7)
        self.assertEqual(startup["snapshot_sequence"], 41)
        self.assertEqual(startup["bytes"], BYTES)
        self.assertEqual(startup["ui"], 0)

        recreate_log = fixture(
            attempt="recreate", ui=1, include_failed_startup=True
        )
        recreate = validator.validate(recreate_log, BUILD, "recreate", True)
        self.assertEqual(recreate["attempt"], "recreate")
        self.assertEqual(recreate["ui"], 1)

    def test_rejects_terminal_marker_mutations(self) -> None:
        valid = fixture()
        marker = terminal()
        mutations = {
            "missing": valid.replace(marker + "\n", ""),
            "duplicate": valid + marker + "\n",
            "foreign-sha": valid.replace(f"b={BUILD}", f"b={OTHER_BUILD}"),
            "zero-generation": valid.replace(" g=7 ", " g=0 "),
            "zero-sequence": valid.replace(" s=41 ", " s=0 "),
            "zero-width": valid.replace(f" w={WIDTH} ", " w=0 "),
            "zero-height": valid.replace(f" h={HEIGHT} ", " h=0 "),
            "width-overflow": valid.replace(
                f" w={WIDTH} ", " w=4294967296 "
            ),
            "byte-size-overflow": valid.replace(
                f"w={WIDTH} h={HEIGHT}", "w=4294967295 h=4294967295"
            ),
            "dimensions-byte-mismatch": valid.replace(
                f"w={WIDTH} h={HEIGHT}", f"w={WIDTH + 1} h={HEIGHT}"
            ),
            "leading-zero": valid.replace(" g=7 ", " g=07 "),
            "wrong-version": valid.replace("HDR: v=1", "HDR: v=2"),
            "wrong-format": valid.replace("fmt=rg11b10f", "fmt=rgba16f"),
            "probe-zero": valid.replace(
                "fmt=rg11b10f probe=1", "fmt=rg11b10f probe=0"
            ),
            "target-zero": valid.replace(
                "target=1 scene=1 resolve=1 ui=0 present=1 terminal=C",
                "target=0 scene=1 resolve=1 ui=0 present=1 terminal=C",
            ),
            "scene-zero": valid.replace(
                "target=1 scene=1 resolve=1 ui=0 present=1 terminal=C",
                "target=1 scene=0 resolve=1 ui=0 present=1 terminal=C",
            ),
            "resolve-zero": valid.replace(
                "target=1 scene=1 resolve=1 ui=0 present=1 terminal=C",
                "target=1 scene=1 resolve=0 ui=0 present=1 terminal=C",
            ),
            "present-zero": valid.replace(
                "present=1 terminal=C", "present=0 terminal=C"
            ),
            "terminal-failed": valid.replace("terminal=C", "terminal=F"),
            "ui-invalid": valid.replace("ui=0 present=1", "ui=2 present=1"),
            "reordered": valid.replace(
                f"g=7 s=41 w={WIDTH} h={HEIGHT}",
                f"s=41 g=7 w={WIDTH} h={HEIGHT}",
            ),
            "extra-field": valid.replace(
                "present=1 terminal=C", "present=1 x=1 terminal=C"
            ),
            "double-space": valid.replace(
                "fmt=rg11b10f probe=1", "fmt=rg11b10f  probe=1"
            ),
            "prefixed": valid.replace(marker, "timestamp " + marker),
            "non-ascii": valid.replace(marker, marker + " ł"),
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assert_rejected(mutated)

    def test_rejects_activation_and_correlation_mutations(self) -> None:
        valid = fixture()
        ready = activation()
        mutations = {
            "missing": valid.replace(ready + "\n", ""),
            "duplicate": valid.replace(ready + "\n", ready + "\n" + ready + "\n"),
            "wrong-attempt": valid.replace("attempt=startup", "attempt=recreate"),
            "generation-mismatch": valid.replace(
                "bytes=1339344 generation=7", "bytes=1339344 generation=8"
            ),
            "bytes-mismatch": valid.replace("bytes=1339344", "bytes=1339348"),
            "probe-zero": valid.replace(
                ready, ready.replace("attempt=startup probe=1", "attempt=startup probe=0")
            ),
            "target-zero": valid.replace(
                ready, ready.replace("target=1 scene=1", "target=0 scene=1")
            ),
            "scene-zero": valid.replace(
                ready, ready.replace("scene=1 resolve=1", "scene=0 resolve=1")
            ),
            "resolve-zero": valid.replace("resolve=1 ready=1", "resolve=0 ready=1"),
            "not-ready": valid.replace("ready=1 safe=0", "ready=0 safe=0"),
            "safe": valid.replace("ready=1 safe=0", "ready=1 safe=1"),
            "after-pass": valid.replace(
                ready + "\n" + terminal(), terminal() + "\n" + ready
            ),
            "malformed-attempt": valid.replace("attempt=startup", "attempt=resume"),
            "extra-field": valid.replace("generation=7", "generation=7 x=1", 1),
            "leading-zero-bytes": valid.replace("bytes=1339344", "bytes=01339344"),
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assert_rejected(mutated)

    def test_rejects_ui_requirement_and_failure_signatures(self) -> None:
        valid = fixture()
        self.assert_rejected(valid, require_ui=True)
        for signature in (
            "RendererIOS linear HDR terminal sequence failed",
            "RendererIOS linear HDR terminal settle failed: injected",
            "RendererIOS fatal: injected",
            "SIGABRT",
            "EXC_BAD_ACCESS",
            "AddressSanitizer: heap-use-after-free",
        ):
            with self.subTest(signature=signature):
                self.assert_rejected(valid + signature + "\n")

    def test_rejects_invalid_api_arguments(self) -> None:
        self.assert_rejected(fixture(), expected_sha="not-a-sha")
        self.assert_rejected(fixture(), attempt="resume")

    def test_cli_accepts_valid_log_and_rejects_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log_path = pathlib.Path(directory) / "linear-hdr.log"
            log_path.write_text(fixture(ui=1), encoding="utf-8")
            command = [
                sys.executable,
                str(VALIDATOR_PATH),
                str(log_path),
                "--expected-sha",
                BUILD,
                "--require-attempt",
                "startup",
                "--require-ui",
            ]
            passed = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertIn("linear-HDR log passed", passed.stdout)

            log_path.write_text(fixture() + "SIGABRT\n", encoding="utf-8")
            failed = subprocess.run(command[:-1], text=True, capture_output=True, check=False)
            self.assertEqual(failed.returncode, 1)
            self.assertIn("FAIL:", failed.stderr)


if __name__ == "__main__":
    unittest.main()
