#!/usr/bin/env python3
"""Contract tests for the local RendererIOS verification router."""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from typing import Optional, Sequence


SOURCE_REPO = pathlib.Path(__file__).resolve().parents[2]


def run(
    command: Sequence[str],
    *,
    cwd: pathlib.Path,
    environment: Optional[dict[str, str]] = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        raise AssertionError(
            f"command failed ({completed.returncode}): {command}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def make_executable(path: pathlib.Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RouterRepository:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="opengothic-verification-router-"
        )
        self.root = pathlib.Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "ios" / "tests").mkdir(parents=True)
        shutil.copy2(
            SOURCE_REPO / "scripts" / "verify.command",
            self.root / "scripts" / "verify.command",
        )
        shutil.copy2(
            SOURCE_REPO / "scripts" / "classify_verification.py",
            self.root / "scripts" / "classify_verification.py",
        )
        shutil.copy2(
            SOURCE_REPO / "scripts" / "execute_verification_gates.py",
            self.root / "scripts" / "execute_verification_gates.py",
        )
        shutil.copy2(
            SOURCE_REPO / "ios" / "tests" / "test_verification_classifier.py",
            self.root / "ios" / "tests" / "test_verification_classifier.py",
        )
        shutil.copy2(
            SOURCE_REPO / "verification-policy.json",
            self.root / "verification-policy.json",
        )
        self.executor_log = self.root / "executor-log.json"
        self.fake_executor = self.root / "fake-executor.py"
        self.fake_executor.write_text(
            """#!/usr/bin/env python3
import json
import os
import pathlib
import sys

pathlib.Path(os.environ["ROUTER_EXECUTOR_LOG"]).write_text(
    json.dumps(
        {
            "argv": sys.argv[1:],
            "mode": os.environ.get("OPENGOTHIC_VERIFY_MODE"),
            "allowDirty": os.environ.get("OPENGOTHIC_VERIFY_ALLOW_DIRTY"),
        },
        sort_keys=True,
    ),
    encoding="utf-8",
)
sys.exit(int(os.environ.get("ROUTER_EXECUTOR_EXIT", "0")))
""",
            encoding="utf-8",
        )
        make_executable(self.fake_executor)
        make_executable(self.root / "scripts" / "verify.command")
        make_executable(self.root / "scripts" / "execute_verification_gates.py")

        run(["git", "init", "-q"], cwd=self.root)
        run(["git", "config", "user.email", "router@example.invalid"], cwd=self.root)
        run(["git", "config", "user.name", "Router Test"], cwd=self.root)
        (self.root / "game").mkdir()
        (self.root / "game" / "base.cpp").write_text("int base = 0;\n", encoding="utf-8")
        (self.root / "docs").mkdir()
        (self.root / "docs" / "base.md").write_text("base\n", encoding="utf-8")
        run(["git", "add", "."], cwd=self.root)
        run(["git", "commit", "-qm", "baseline"], cwd=self.root)
        self.baseline = run(
            ["git", "rev-parse", "HEAD"], cwd=self.root
        ).stdout.strip()
        run(
            ["git", "update-ref", "refs/remotes/origin/main", self.baseline],
            cwd=self.root,
        )

    def close(self) -> None:
        self.temporary.cleanup()

    def environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["OPENGOTHIC_VERIFY_GATE_EXECUTOR"] = str(self.fake_executor)
        environment["ROUTER_EXECUTOR_LOG"] = str(self.executor_log)
        return environment

    def invoke(
        self, mode: str, *arguments: str
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        completed = run(
            [str(self.root / "scripts" / "verify.command"), mode, *arguments],
            cwd=self.root,
            environment=self.environment(),
            check=False,
        )
        payload = json.loads(completed.stdout)
        return completed, payload

    def executor_payload(self) -> dict[str, object]:
        return json.loads(self.executor_log.read_text(encoding="utf-8"))


class VerificationRouterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repository = RouterRepository()

    def tearDown(self) -> None:
        self.repository.close()

    def test_slice_unions_staged_unstaged_and_nul_safe_untracked(self) -> None:
        staged = self.repository.root / "docs" / "staged file.md"
        staged.write_text("staged\n", encoding="utf-8")
        run(["git", "add", str(staged.relative_to(self.repository.root))], cwd=self.repository.root)
        (self.repository.root / "game" / "base.cpp").write_text(
            "int base = 1;\n", encoding="utf-8"
        )
        unusual = self.repository.root / "docs" / "untracked\tline\nfile.md"
        unusual.write_text("untracked\n", encoding="utf-8")

        completed, payload = self.repository.invoke("slice")

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["selection"], "classified")
        self.assertEqual(payload["mode"], "slice")
        self.assertEqual(
            payload["changedPaths"],
            [
                "docs/staged file.md",
                "docs/untracked\tline\nfile.md",
                "game/base.cpp",
            ],
        )
        self.assertEqual(
            payload["gates"],
            ["policy-contracts", "contracts", "strict-compile", "build-off", "build-on"],
        )
        self.assertEqual(
            self.repository.executor_payload(),
            {
                "allowDirty": "1",
                "argv": payload["gates"],
                "mode": "slice",
            },
        )

    def test_slice_with_no_changes_is_not_a_fake_pass(self) -> None:
        completed, payload = self.repository.invoke("slice")

        self.assertEqual(completed.returncode, 3)
        self.assertEqual(payload["selection"], "no-changes")
        self.assertEqual(payload["status"], "no-changes")
        self.assertIn("NO CHANGES", completed.stderr)
        self.assertFalse(self.repository.executor_log.exists())

    def test_prepush_unions_commits_worktree_and_untracked(self) -> None:
        committed = self.repository.root / "game" / "committed.cpp"
        committed.write_text("int committed = 1;\n", encoding="utf-8")
        run(["git", "add", "game/committed.cpp"], cwd=self.repository.root)
        run(["git", "commit", "-qm", "local commit"], cwd=self.repository.root)
        (self.repository.root / "docs" / "base.md").write_text(
            "dirty\n", encoding="utf-8"
        )
        (self.repository.root / "docs" / "new file.md").write_text(
            "new\n", encoding="utf-8"
        )

        completed, payload = self.repository.invoke(
            "prepush", "--upstream", "origin/main"
        )

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["baseSha"], self.repository.baseline)
        self.assertEqual(payload["upstream"], "origin/main")
        self.assertEqual(
            payload["changedPaths"],
            ["docs/base.md", "docs/new file.md", "game/committed.cpp"],
        )
        self.assertEqual(self.repository.executor_payload()["allowDirty"], "1")

    def test_missing_prepush_upstream_fails_closed_to_full(self) -> None:
        completed, payload = self.repository.invoke(
            "prepush", "--upstream", "missing/upstream"
        )

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["selection"], "fail-closed")
        self.assertEqual(payload["gates"], ["full"])
        self.assertTrue(payload["fallback"])
        self.assertIn("contextError", payload)
        self.assertEqual(self.repository.executor_payload()["argv"], ["full"])

    def test_unknown_path_falls_back_to_full(self) -> None:
        (self.repository.root / "unknown.bin").write_bytes(b"unknown")

        completed, payload = self.repository.invoke("slice")

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["selection"], "classified")
        self.assertEqual(payload["gates"], ["full"])
        self.assertTrue(payload["fallback"])
        self.assertEqual(self.repository.executor_payload()["argv"], ["full"])

    def test_phase_always_runs_full_without_dirty_override(self) -> None:
        (self.repository.root / "docs" / "ignored.md").write_text(
            "dirty\n", encoding="utf-8"
        )

        completed, payload = self.repository.invoke("phase")

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["selection"], "phase")
        self.assertEqual(payload["gates"], ["full"])
        self.assertEqual(
            self.repository.executor_payload(),
            {"allowDirty": None, "argv": ["full"], "mode": "phase"},
        )

    def test_executor_failure_is_propagated(self) -> None:
        (self.repository.root / "docs" / "changed.md").write_text(
            "dirty\n", encoding="utf-8"
        )
        environment = self.repository.environment()
        environment["ROUTER_EXECUTOR_EXIT"] = "19"

        completed = run(
            [str(self.repository.root / "scripts" / "verify.command"), "slice"],
            cwd=self.repository.root,
            environment=environment,
            check=False,
        )

        self.assertEqual(completed.returncode, 19)
        self.assertEqual(json.loads(completed.stdout)["gates"], ["policy-contracts"])


class GateExecutorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repository = RouterRepository()
        self.verifier_log = self.repository.root / "verifier-log.json"
        self.fake_verifier = self.repository.root / "fake-verifier.py"
        self.fake_verifier.write_text(
            """#!/usr/bin/env python3
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(sys.argv[2:]),
    encoding="utf-8",
)
""",
            encoding="utf-8",
        )
        make_executable(self.fake_verifier)
        self.wrapper = self.repository.root / "fake-verifier-wrapper.py"
        self.wrapper.write_text(
            f"""#!/usr/bin/env python3
import subprocess
import sys
sys.exit(subprocess.run(
    [{str(self.fake_verifier)!r}, {str(self.verifier_log)!r}, *sys.argv[1:]],
    check=False,
).returncode)
""",
            encoding="utf-8",
        )
        make_executable(self.wrapper)

    def tearDown(self) -> None:
        self.repository.close()

    def execute(self, *gates: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["OPENGOTHIC_VERIFY_LOCAL_VERIFIER"] = str(self.wrapper)
        return run(
            [
                str(
                    self.repository.root
                    / "scripts"
                    / "execute_verification_gates.py"
                ),
                *gates,
            ],
            cwd=self.repository.root,
            environment=environment,
            check=False,
        )

    def verifier_arguments(self) -> list[str]:
        return json.loads(self.verifier_log.read_text(encoding="utf-8"))

    def test_device_facts_maps_to_off_and_on_only(self) -> None:
        completed = self.execute(
            "device-facts", "strict-compile", "build-off", "build-on"
        )

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(self.verifier_arguments(), ["profiles", "off", "on"])

    def test_tile_maps_to_off_and_tile_only(self) -> None:
        completed = self.execute("tile-contracts", "build-off", "build-tile")

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(self.verifier_arguments(), ["profiles", "off", "tile"])

    def test_forward_maps_to_off_and_forward_only(self) -> None:
        completed = self.execute(
            "forward-contracts", "build-off", "build-forward"
        )

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(
            self.verifier_arguments(), ["profiles", "off", "forward"]
        )

    def test_union_maps_to_canonical_profile_order(self) -> None:
        completed = self.execute(
            "device-facts",
            "tile-contracts",
            "strict-compile",
            "build-off",
            "build-on",
            "build-tile",
        )

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(
            self.verifier_arguments(), ["profiles", "off", "on", "tile"]
        )

    def test_all_profiles_collapse_to_full(self) -> None:
        completed = self.execute("full")

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(self.verifier_arguments(), ["full"])

    def test_contracts_without_build_use_contract_mode(self) -> None:
        completed = self.execute("contracts", "strict-compile")

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(self.verifier_arguments(), ["contracts"])

    def test_policy_contracts_do_not_invoke_build_verifier(self) -> None:
        completed = self.execute("policy-contracts")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(self.verifier_log.exists())

    def test_noncanonical_or_duplicate_gates_are_rejected(self) -> None:
        reversed_result = self.execute("build-off", "contracts")
        duplicate_result = self.execute("contracts", "contracts")

        self.assertEqual(reversed_result.returncode, 2)
        self.assertEqual(duplicate_result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
