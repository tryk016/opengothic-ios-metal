#!/usr/bin/env python3
"""Fail-closed GitHub Actions routing and required-gate aggregation."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
from typing import Mapping, Optional, Sequence


SCHEMA_VERSION = 1
REPO = pathlib.Path(__file__).resolve().parents[1]
CLASSIFIER = REPO / "scripts" / "classify_verification.py"
POLICY = REPO / "verification-policy.json"
PROFILE_OUTPUTS = {
    "build_off": "build-off",
    "build_on": "build-on",
    "build_tile": "build-tile",
    "build_forward": "build-forward",
}
RESULTS = frozenset({"success", "failure", "cancelled", "skipped"})


class CIVerificationError(RuntimeError):
    """CI state cannot be interpreted without risking a false PASS."""


def is_sha(value: str, *, zero_allowed: bool = False) -> bool:
    return (
        len(value) == 40
        and all(character in "0123456789abcdef" for character in value)
        and (zero_allowed or set(value) != {"0"})
    )


def full_result(selection: str, reason: str, error: Optional[str] = None) -> dict:
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "selection": selection,
        "risk": "infrastructure",
        "gates": ["full"],
        "reason": [reason],
        "full": True,
        "fallback": error is not None,
    }
    if error is not None:
        result["contextError"] = error
    return result


def declared_gates() -> set[str]:
    try:
        payload = json.loads(POLICY.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CIVerificationError(f"verification policy is unreadable: {error}") from error
    gate_order = payload.get("gateOrder")
    if (
        not isinstance(gate_order, list)
        or not gate_order
        or any(not isinstance(gate, str) or not gate for gate in gate_order)
        or len(set(gate_order)) != len(gate_order)
        or "full" not in gate_order
    ):
        raise CIVerificationError("verification policy gateOrder is invalid")
    return set(gate_order)


def classify_push(
    repository: pathlib.Path,
    before: str,
    head: str,
) -> dict:
    if not is_sha(before, zero_allowed=True):
        return full_result(
            "fail-closed",
            "push before SHA unavailable; full required",
            "before-sha-unavailable",
        )
    if not is_sha(head):
        return full_result(
            "fail-closed",
            "push head SHA unavailable; full required",
            "head-sha-unavailable",
        )
    try:
        completed = subprocess.run(
            [
                sys.executable,
                str(CLASSIFIER),
                "--repo",
                str(repository),
                "--base",
                before,
                "--head",
                head,
            ],
            cwd=repository,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError:
        return full_result(
            "fail-closed",
            "classifier could not execute; full required",
            "classifier-unavailable",
        )
    if completed.returncode != 0:
        return full_result(
            "fail-closed",
            "push diff or policy classification failed; full required",
            "classifier-failed",
        )
    try:
        result = json.loads(completed.stdout)
    except (UnicodeError, json.JSONDecodeError):
        return full_result(
            "fail-closed",
            "classifier output invalid; full required",
            "classifier-output-invalid",
        )
    gates = result.get("gates")
    if (
        result.get("schemaVersion") != SCHEMA_VERSION
        or not isinstance(gates, list)
        or not gates
        or any(not isinstance(gate, str) or not gate for gate in gates)
        or any(gate not in declared_gates() for gate in gates)
    ):
        return full_result(
            "fail-closed",
            "classifier output incomplete; full required",
            "classifier-output-invalid",
        )
    result["selection"] = "push-before-to-sha"
    result["eventBaseSha"] = before
    result["eventHeadSha"] = head
    return result


def classify_event(
    event_name: str,
    repository: pathlib.Path,
    before: str,
    head: str,
) -> dict:
    if event_name == "workflow_dispatch":
        return full_result(
            "workflow-dispatch",
            "workflow_dispatch always requires the full gate",
        )
    if event_name == "push":
        return classify_push(repository, before, head)
    return full_result(
        "fail-closed",
        "unsupported event requires the full gate",
        "unsupported-event",
    )


def required_jobs(classification: Mapping[str, object]) -> dict[str, bool]:
    gates = classification.get("gates")
    if not isinstance(gates, list) or not gates:
        raise CIVerificationError("classification has no non-empty gate list")
    if any(not isinstance(gate, str) or not gate for gate in gates):
        raise CIVerificationError("classification contains an invalid gate")
    unknown = sorted(set(gates).difference(declared_gates()))
    if unknown:
        raise CIVerificationError(f"classification contains unknown gates: {unknown}")
    full = gates == ["full"]
    if "full" in gates and not full:
        raise CIVerificationError("full is combined with narrower gates")
    requested = set(gates)
    return {
        "contracts": gates != ["policy-contracts"],
        **{
            output: full or gate in requested
            for output, gate in PROFILE_OUTPUTS.items()
        },
    }


def append_outputs(path: pathlib.Path, values: Mapping[str, str]) -> None:
    try:
        with path.open("a", encoding="utf-8", newline="\n") as output:
            for key, value in values.items():
                if "\n" in key or "\n" in value:
                    raise CIVerificationError(
                        "GitHub output contains an unsafe newline"
                    )
                output.write(f"{key}={value}\n")
    except OSError as error:
        raise CIVerificationError(f"could not write GitHub outputs: {error}") from error


def emit_classification(classification: Mapping[str, object]) -> None:
    required = required_jobs(classification)
    compact = json.dumps(
        classification,
        sort_keys=True,
        separators=(",", ":"),
    )
    values = {
        "classification": compact,
        **{
            name: "true" if needed else "false"
            for name, needed in required.items()
        },
    }
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        append_outputs(pathlib.Path(output_path), values)
    print(compact)
    print(
        "required-jobs: "
        + " ".join(f"{name}={value}" for name, value in values.items() if name != "classification"),
        file=sys.stderr,
    )


def parse_bool(value: str, label: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise CIVerificationError(f"{label} must be true or false")


def validate_result(value: str, label: str) -> str:
    if value not in RESULTS:
        raise CIVerificationError(f"{label} has unknown result {value!r}")
    return value


def aggregate(
    classifier_result: str,
    expected: Mapping[str, bool],
    actual: Mapping[str, str],
) -> None:
    if validate_result(classifier_result, "classifier") != "success":
        raise CIVerificationError(
            f"classifier did not succeed: {classifier_result}"
        )
    if set(expected) != set(actual):
        raise CIVerificationError("expected and actual job sets differ")
    failures: list[str] = []
    for name in sorted(expected):
        result = validate_result(actual[name], name)
        if expected[name] and result != "success":
            failures.append(f"{name}: required but {result}")
        elif not expected[name] and result != "skipped":
            failures.append(f"{name}: not required but {result}")
    if failures:
        raise CIVerificationError("; ".join(failures))


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify = subparsers.add_parser("classify")
    classify.add_argument("--event-name", required=True)
    classify.add_argument("--before", default="")
    classify.add_argument("--sha", required=True)
    classify.add_argument("--repo", type=pathlib.Path, default=REPO)

    aggregate_parser = subparsers.add_parser("aggregate")
    aggregate_parser.add_argument("--classifier-result", required=True)
    for name in ("contracts", *PROFILE_OUTPUTS):
        aggregate_parser.add_argument(f"--expected-{name.replace('_', '-')}", required=True)
        aggregate_parser.add_argument(f"--result-{name.replace('_', '-')}", required=True)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        arguments = parse_arguments(argv)
        if arguments.command == "classify":
            classification = classify_event(
                arguments.event_name,
                arguments.repo.resolve(),
                arguments.before,
                arguments.sha,
            )
            emit_classification(classification)
        else:
            names = ("contracts", *PROFILE_OUTPUTS)
            expected = {
                name: parse_bool(
                    getattr(arguments, f"expected_{name}"),
                    f"expected {name}",
                )
                for name in names
            }
            actual = {
                name: getattr(arguments, f"result_{name}")
                for name in names
            }
            aggregate(arguments.classifier_result, expected, actual)
            print("RendererIOS required CI gates passed")
        return 0
    except (CIVerificationError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
