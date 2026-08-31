#!/usr/bin/env python3

import hashlib
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "simulator-test/run-full-game-smoke.py"
SPEC = importlib.util.spec_from_file_location("full_game_simulator_runner", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNNER
SPEC.loader.exec_module(RUNNER)


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FullGameSimulatorRunnerTests(unittest.TestCase):
    def fixture(self, root: pathlib.Path) -> pathlib.Path:
        documents = root / "Documents"
        for directory in ("Data", "_work", "system"):
            (documents / directory).mkdir(parents=True, exist_ok=True)
        leaves = {
            "Data/game.vdf": b"game",
            "_work/scripts.dat": b"scripts",
            "system/Gothic.dat": b"system",
            "Gothic.ini": b"ini",
            "save_slot_4.sav": b"save4",
        }
        inventory_lines = []
        total = 0
        for name, contents in sorted(leaves.items()):
            leaf = documents / name
            leaf.write_bytes(contents)
            total += len(contents)
            inventory_lines.append(f"{digest(leaf)}  ./{name}\n")
            os.chmod(leaf, 0o400)
        inventory = root / "Documents.sha256"
        inventory.write_text("".join(inventory_lines), encoding="ascii")
        snapshot = root / "SNAPSHOT.txt"
        snapshot.write_text(
            "source_device_udid=device\n"
            "bundle_id=bundle\n"
            "source=Documents\n"
            "captured_utc=20260830T000000Z\n"
            "parent_sha=" + "1" * 40 + "\n"
            "fixture_scope=Data,_work,system,Gothic.ini,saves\n"
            "excluded=.Trash,logs\n"
            f"file_count={len(leaves)}\n"
            f"byte_count={total}\n",
            encoding="utf-8",
        )
        manifest = root / "MANIFEST.sha256"
        manifest.write_text(
            f"{digest(inventory)}  Documents.sha256\n"
            f"{digest(snapshot)}  SNAPSHOT.txt\n",
            encoding="ascii",
        )
        for directory, names, _ in os.walk(documents, topdown=False):
            for name in names:
                os.chmod(pathlib.Path(directory) / name, 0o500)
            os.chmod(directory, 0o500)
        os.chmod(inventory, 0o400)
        os.chmod(snapshot, 0o400)
        os.chmod(manifest, 0o400)
        os.chmod(root, 0o500)
        return root

    def test_fixture_contract_and_mutations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "fixture"
            root.mkdir()
            fixture = self.fixture(root)
            identity = RUNNER.validate_fixture(fixture)
            self.assertEqual(identity.file_count, 5)
            os.chmod(fixture, 0o700)
            os.chmod(fixture / "SNAPSHOT.txt", 0o600)
            (fixture / "SNAPSHOT.txt").write_text("source=Documents\n")
            os.chmod(fixture / "SNAPSHOT.txt", 0o400)
            os.chmod(fixture, 0o500)
            with self.assertRaises(RUNNER.GateError):
                RUNNER.validate_fixture(fixture)

    def test_symlink_and_writable_leaf_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "fixture"
            root.mkdir()
            fixture = self.fixture(root)
            os.chmod(fixture / "Documents/Data/game.vdf", 0o600)
            with self.assertRaises(RUNNER.GateError):
                RUNNER.validate_fixture(fixture)
            root_link = pathlib.Path(temporary) / "fixture-link"
            root_link.symlink_to(fixture, target_is_directory=True)
            with self.assertRaises(RUNNER.GateError):
                RUNNER.validate_fixture(root_link)

    def test_app_root_symlink_rejected_before_bundle_inspection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            app = root / "Gothic2Notr.app"
            app.mkdir()
            app_link = root / "linked.app"
            app_link.symlink_to(app, target_is_directory=True)
            with self.assertRaises(RUNNER.GateError):
                RUNNER.validate_app(app_link)

    def test_cleanup_exceptions_are_recorded_without_stopping_later_steps(self) -> None:
        errors: list[str] = []
        completed: list[str] = []

        def failing() -> None:
            raise TimeoutError("copy timed out")

        RUNNER.attempt_cleanup(errors, "preserve log", failing)
        RUNNER.attempt_cleanup(errors, "terminate", lambda: completed.append("terminate"))
        self.assertEqual(errors, ["preserve log: copy timed out"])
        self.assertEqual(completed, ["terminate"])

    def test_dedicated_cleanup_erases_after_shutdown_failure(self) -> None:
        errors: list[str] = []
        actions: list[str] = []

        def runner(argv: list[str], **_: object) -> subprocess.CompletedProcess[bytes]:
            action = argv[2]
            actions.append(action)
            return subprocess.CompletedProcess(argv, 1 if action == "shutdown" else 0, b"", b"")

        RUNNER.cleanup_dedicated_simulator(errors, "SIMULATOR", command_runner=runner)
        self.assertEqual(actions, ["shutdown", "erase"])
        self.assertEqual(errors, ["shutdown failed"])

    def test_required_terminate_nonzero_is_cleanup_failure(self) -> None:
        errors: list[str] = []

        def runner(argv: tuple[str, ...], **_: object) -> subprocess.CompletedProcess[bytes]:
            return subprocess.CompletedProcess(argv, 1, b"", b"")

        RUNNER.terminate_simulator_app(
            errors, "SIMULATOR", "bundle", required=True, command_runner=runner
        )
        self.assertEqual(errors, ["terminate failed"])

    def test_full_content_is_read_again_on_every_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "fixture"
            root.mkdir()
            fixture = self.fixture(root)
            identity = RUNNER.validate_fixture(fixture)
            first_evidence = pathlib.Path(temporary) / "evidence-1"
            first_evidence.mkdir()
            record = RUNNER.verify_fixture_content(identity, first_evidence)
            self.assertTrue(record.is_file())

            leaf = fixture / "Documents/Data/game.vdf"
            os.chmod(leaf, 0o600)
            leaf.write_bytes(b"mutation")
            os.chmod(leaf, 0o400)
            second_evidence = pathlib.Path(temporary) / "evidence-2"
            second_evidence.mkdir()
            with self.assertRaises(RUNNER.GateError):
                RUNNER.verify_fixture_content(identity, second_evidence)

    def test_launch_pid_parser(self) -> None:
        self.assertEqual(RUNNER.parse_launch_pid(b"example.bundle: 123\n", "example.bundle"), 123)
        for value in (b"example.bundle: 0\n", b"other: 123\n", b"example.bundle: 1 extra\n"):
            with self.assertRaises(RUNNER.GateError):
                RUNNER.parse_launch_pid(value, "example.bundle")

    def test_runtime_log_contract(self) -> None:
        valid = "\n".join(RUNNER.REQUIRED_LOG_MARKERS)
        RUNNER.validate_runtime_log(valid)
        with self.assertRaises(RUNNER.GateError):
            RUNNER.validate_runtime_log(valid.replace(RUNNER.REQUIRED_LOG_MARKERS[-1], ""))
        for forbidden in RUNNER.FORBIDDEN_LOG_MARKERS:
            with self.subTest(forbidden=forbidden), self.assertRaises(RUNNER.GateError):
                RUNNER.validate_runtime_log(valid + "\n" + forbidden)

    def test_world_finalize_invalidates_loading_ui(self) -> None:
        source = (SCRIPT.parents[2] / "game/mainwindow.cpp").read_text(encoding="utf-8")
        tick = source.split("uint64_t MainWindow::tick()", 1)[1].split(
            "bool MainWindow::rendererOperational()", 1
        )[0]
        finalize = tick.split(
            "auto st = Gothic::inst().checkLoading();", 1
        )[1].split("else if(st!=Gothic::LoadState::Idle)", 1)[0]
        contract = (
            "const bool loadingFinished = Gothic::inst().finishLoading();",
            "if(loadingFinished)\n      update();",
            "return 0;",
        )
        positions = [finalize.index(literal) for literal in contract]
        self.assertEqual(positions, sorted(positions))

    def test_simulator_terminals_are_flushed_while_app_is_alive(self) -> None:
        source = (SCRIPT.parents[2] / "game/main.cpp").read_text(encoding="utf-8")
        policy = source.split(
            "constexpr bool shouldFlushLogText", 1
        )[1].split("#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)", 1)[0]
        for marker in (
            "RendererIOS simulator smoke budget:",
            "RendererIOS native scene ready:",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, policy)


if __name__ == "__main__":
    unittest.main()
