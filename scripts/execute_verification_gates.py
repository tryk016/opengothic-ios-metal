#!/usr/bin/env python3
"""Execute classified RendererIOS gates without duplicating path policy."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
from typing import Sequence


REPO = pathlib.Path(__file__).resolve().parents[1]
POLICY = REPO / "verification-policy.json"
CLASSIFIER = REPO / "scripts" / "classify_verification.py"
CLASSIFIER_TEST = REPO / "ios" / "tests" / "test_verification_classifier.py"
DEFAULT_VERIFIER = REPO / "scripts" / "verify-local-build.command"
PROFILE_GATES = {
    "build-off": "off",
    "build-on": "on",
    "build-tile": "tile",
    "build-forward": "forward",
}
PROFILE_ORDER = ("off", "on", "tile", "forward")


class GateError(RuntimeError):
    """The classified gate set cannot be executed safely."""


def load_gate_order() -> list[str]:
    try:
        payload = json.loads(POLICY.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GateError(f"could not read verification policy: {error}") from error
    gate_order = payload.get("gateOrder")
    if (
        not isinstance(gate_order, list)
        or not gate_order
        or any(not isinstance(gate, str) or not gate for gate in gate_order)
        or len(set(gate_order)) != len(gate_order)
        or "full" not in gate_order
    ):
        raise GateError("verification policy has an invalid gateOrder")
    return gate_order


def validate_gates(arguments: Sequence[str], gate_order: Sequence[str]) -> list[str]:
    if not arguments:
        raise GateError("no verification gates were provided")
    if len(set(arguments)) != len(arguments):
        raise GateError("verification gate set contains duplicates")
    known = set(gate_order)
    unknown = sorted(set(arguments).difference(known))
    if unknown:
        raise GateError(f"unknown verification gates: {unknown}")
    canonical = [gate for gate in gate_order if gate in arguments]
    if list(arguments) != canonical:
        raise GateError("verification gates are not in canonical policy order")
    if "full" in arguments and list(arguments) != ["full"]:
        raise GateError("full must not be combined with narrower gates")
    return canonical


def run(command: Sequence[str]) -> int:
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        completed = subprocess.run(
            command,
            cwd=REPO,
            env=environment,
            check=False,
        )
    except OSError as error:
        raise GateError(f"could not execute {command[0]}: {error}") from error
    return completed.returncode


def verifier_command(profiles: Sequence[str]) -> list[str]:
    verifier = pathlib.Path(
        os.environ.get("OPENGOTHIC_VERIFY_LOCAL_VERIFIER", str(DEFAULT_VERIFIER))
    )
    if not verifier.is_file() or not os.access(verifier, os.X_OK):
        raise GateError(f"local verifier is missing or not executable: {verifier}")
    if tuple(profiles) == PROFILE_ORDER:
        return [str(verifier), "full"]
    if profiles:
        return [str(verifier), "profiles", *profiles]
    return [str(verifier), "contracts"]


def main(argv: Sequence[str]) -> int:
    try:
        gates = validate_gates(argv, load_gate_order())
        if gates == ["policy-contracts"]:
            commands = (
                [sys.executable, str(CLASSIFIER), "--validate-policy"],
                [sys.executable, str(CLASSIFIER_TEST)],
            )
            print(
                "verification-executor: gates=policy-contracts profiles=none",
                file=sys.stderr,
            )
            for command in commands:
                result = run(command)
                if result != 0:
                    return result
            return 0
        if gates == ["full"]:
            command = verifier_command(PROFILE_ORDER)
            print(
                "verification-executor: gates=full profiles=off,on,tile,forward",
                file=sys.stderr,
            )
            return run(command)

        requested_profiles = {
            profile
            for gate, profile in PROFILE_GATES.items()
            if gate in gates
        }
        profiles = [
            profile for profile in PROFILE_ORDER if profile in requested_profiles
        ]
        command = verifier_command(profiles)
        print(
            "verification-executor: "
            f"gates={','.join(gates)} "
            f"profiles={','.join(profiles) if profiles else 'none'}",
            file=sys.stderr,
        )
        return run(command)
    except GateError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
