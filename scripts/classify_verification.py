#!/usr/bin/env python3
"""Classify a Git diff into the fail-closed RendererIOS verification gates."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import pathlib
import subprocess
import sys
from typing import Any, Iterable, Optional, Sequence


SCHEMA_VERSION = 1
RENAME_OR_COPY = frozenset({"R", "C"})
VALID_STATUS_PREFIXES = frozenset({"A", "B", "C", "D", "M", "R", "T", "U", "X"})


class PolicyError(RuntimeError):
    """The policy cannot safely classify changes."""


class DiffError(RuntimeError):
    """The requested diff cannot safely be resolved."""


def require_string_list(value: Any, label: str, *, nonempty: bool = True) -> list[str]:
    if not isinstance(value, list) or any(
        not isinstance(item, str) or not item for item in value
    ):
        raise PolicyError(f"{label} must be a list of non-empty strings")
    if nonempty and not value:
        raise PolicyError(f"{label} must not be empty")
    if len(set(value)) != len(value):
        raise PolicyError(f"{label} contains duplicates")
    return list(value)


def require_object_keys(
    value: dict[str, Any],
    label: str,
    *,
    required: set[str],
    optional: set[str] = frozenset(),
) -> None:
    missing = sorted(required.difference(value))
    unknown = sorted(set(value).difference(required).difference(optional))
    if missing:
        raise PolicyError(f"{label} is missing keys: {missing}")
    if unknown:
        raise PolicyError(f"{label} contains unknown keys: {unknown}")


def validate_repo_path(path: str, label: str, *, allow_glob: bool) -> str:
    if (
        not path
        or "\0" in path
        or "\\" in path
        or path.startswith("/")
        or path.startswith("./")
        or path.endswith("/")
        or "//" in path
    ):
        raise PolicyError(f"{label} is not a normalized repository path: {path!r}")
    parts = path.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise PolicyError(f"{label} is not a normalized repository path: {path!r}")
    if not allow_glob and any(character in path for character in "*?["):
        raise PolicyError(f"{label} must be a literal repository path: {path!r}")
    return path


def validate_gate_list(
    value: Any, label: str, known_gates: set[str]
) -> list[str]:
    gates = require_string_list(value, label)
    unknown = [gate for gate in gates if gate not in known_gates]
    if unknown:
        raise PolicyError(f"{label} contains unknown gates: {unknown}")
    if "full" in gates and gates != ["full"]:
        raise PolicyError(f"{label} must not combine full with narrower gates")
    return gates


def validate_policy(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise PolicyError("policy root must be an object")
    require_object_keys(
        payload,
        "policy",
        required={
            "schemaVersion",
            "gateOrder",
            "riskOrder",
            "requiredFullPaths",
            "rules",
            "fallback",
        },
        optional={"description"},
    )
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        raise PolicyError(f"policy schemaVersion must be {SCHEMA_VERSION}")

    gate_order = require_string_list(payload.get("gateOrder"), "gateOrder")
    if "full" not in gate_order:
        raise PolicyError("gateOrder must contain full")
    known_gates = set(gate_order)
    risk_order = require_string_list(payload.get("riskOrder"), "riskOrder")
    known_risks = set(risk_order)

    rules = payload.get("rules")
    if not isinstance(rules, list) or not rules:
        raise PolicyError("rules must be a non-empty list")
    rule_ids: set[str] = set()
    validated_rules: list[dict[str, Any]] = []
    for index, rule in enumerate(rules):
        label = f"rules[{index}]"
        if not isinstance(rule, dict):
            raise PolicyError(f"{label} must be an object")
        require_object_keys(
            rule,
            label,
            required={"id", "risk", "reason", "paths", "gates"},
            optional={"excludePaths"},
        )
        rule_id = rule.get("id")
        if not isinstance(rule_id, str) or not rule_id:
            raise PolicyError(f"{label}.id must be a non-empty string")
        if rule_id in rule_ids:
            raise PolicyError(f"duplicate rule id: {rule_id}")
        rule_ids.add(rule_id)
        risk = rule.get("risk")
        if risk not in known_risks:
            raise PolicyError(f"{label}.risk is unknown: {risk!r}")
        reason = rule.get("reason")
        if not isinstance(reason, str) or not reason:
            raise PolicyError(f"{label}.reason must be a non-empty string")
        paths = require_string_list(rule.get("paths"), f"{label}.paths")
        paths = [
            validate_repo_path(path, f"{label}.paths", allow_glob=True)
            for path in paths
        ]
        exclude_paths = require_string_list(
            rule.get("excludePaths", []),
            f"{label}.excludePaths",
            nonempty=False,
        )
        exclude_paths = [
            validate_repo_path(path, f"{label}.excludePaths", allow_glob=True)
            for path in exclude_paths
        ]
        gates = validate_gate_list(rule.get("gates"), f"{label}.gates", known_gates)
        validated_rules.append(
            {
                "id": rule_id,
                "risk": risk,
                "reason": reason,
                "paths": paths,
                "excludePaths": exclude_paths,
                "gates": gates,
            }
        )

    fallback = payload.get("fallback")
    if not isinstance(fallback, dict):
        raise PolicyError("fallback must be an object")
    require_object_keys(
        fallback,
        "fallback",
        required={"risk", "gates", "reason"},
    )
    fallback_risk = fallback.get("risk")
    if fallback_risk not in known_risks:
        raise PolicyError(f"fallback.risk is unknown: {fallback_risk!r}")
    fallback_reason = fallback.get("reason")
    if not isinstance(fallback_reason, str) or not fallback_reason:
        raise PolicyError("fallback.reason must be a non-empty string")
    fallback_gates = validate_gate_list(
        fallback.get("gates"), "fallback.gates", known_gates
    )
    if fallback_gates != ["full"]:
        raise PolicyError("fallback.gates must be exactly [\"full\"]")

    required_full_paths = require_string_list(
        payload.get("requiredFullPaths"), "requiredFullPaths"
    )
    required_full_paths = [
        validate_repo_path(path, "requiredFullPaths", allow_glob=False)
        for path in required_full_paths
    ]

    validated = {
        "schemaVersion": SCHEMA_VERSION,
        "gateOrder": gate_order,
        "riskOrder": risk_order,
        "requiredFullPaths": required_full_paths,
        "rules": validated_rules,
        "fallback": {
            "risk": fallback_risk,
            "gates": fallback_gates,
            "reason": fallback_reason,
        },
    }
    for path in required_full_paths:
        result = classify_paths(validated, [path], validate=False)
        if result["gates"] != ["full"]:
            raise PolicyError(f"requiredFullPaths entry is not full: {path}")
        if result["matches"][0]["rules"] == ["fallback"]:
            raise PolicyError(f"requiredFullPaths entry is unclassified: {path}")
    return validated


def load_policy(path: pathlib.Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise PolicyError(f"policy does not exist: {path}") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PolicyError(f"could not read policy {path}: {error}") from error
    return validate_policy(payload)


def policy_sha256(path: pathlib.Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise PolicyError(f"could not hash policy {path}: {error}") from error


def unique_in_order(values: Iterable[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value not in seen:
            seen.add(value)
            result.append(value)
    return result


def rule_matches(path: str, patterns: Sequence[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def classify_paths(
    policy: dict[str, Any], paths: Sequence[str], *, validate: bool = True
) -> dict[str, Any]:
    if not paths:
        raise DiffError("diff contains no paths")
    normalized = unique_in_order(
        validate_repo_path(path, "changed path", allow_glob=False) for path in paths
    )
    if not normalized:
        raise DiffError("diff contains no paths")

    matched_gate_names: list[str] = []
    matched_risks: list[str] = []
    reasons: list[str] = []
    matches: list[dict[str, Any]] = []
    used_fallback = False
    for path in sorted(normalized):
        path_rules = sorted(
            (
                rule
                for rule in policy["rules"]
                if rule_matches(path, rule["paths"])
                and not rule_matches(path, rule["excludePaths"])
            ),
            key=lambda rule: rule["id"],
        )
        for rule in path_rules:
            matched_gate_names.extend(rule["gates"])
            matched_risks.append(rule["risk"])
            reasons.append(rule["reason"])
        if not path_rules:
            used_fallback = True
            fallback = policy["fallback"]
            matched_gate_names.extend(fallback["gates"])
            matched_risks.append(fallback["risk"])
            reasons.append(fallback["reason"])
        matches.append(
            {
                "path": path,
                "rules": [rule["id"] for rule in path_rules] or ["fallback"],
            }
        )

    if "full" in matched_gate_names:
        gates = ["full"]
    else:
        requested = set(matched_gate_names)
        gates = [gate for gate in policy["gateOrder"] if gate in requested]
    if not gates:
        raise PolicyError("classification produced no gates")

    risk_rank = {risk: index for index, risk in enumerate(policy["riskOrder"])}
    risk = max(matched_risks, key=lambda item: risk_rank[item])
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "risk": risk,
        "gates": gates,
        "reason": unique_in_order(reasons),
        "changedPaths": sorted(normalized),
        "matches": matches,
        "full": gates == ["full"],
        "fallback": used_fallback,
    }
    if validate and result["full"] and "full" not in policy["gateOrder"]:
        raise PolicyError("full classification is not declared by gateOrder")
    return result


def decode_field(field: bytes, label: str) -> str:
    try:
        value = field.decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise DiffError(f"{label} is not valid UTF-8") from error
    if not value:
        raise DiffError(f"{label} is empty")
    return value


def parse_name_status(data: bytes) -> list[dict[str, Any]]:
    fields = data.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    changes: list[dict[str, Any]] = []
    index = 0
    while index < len(fields):
        status = decode_field(fields[index], "diff status")
        index += 1
        prefix = status[0]
        if prefix not in VALID_STATUS_PREFIXES:
            raise DiffError(f"unsupported diff status: {status!r}")
        if prefix in RENAME_OR_COPY:
            if (
                len(status) == 1
                or not status[1:].isdigit()
                or int(status[1:]) > 100
            ):
                raise DiffError(f"unsupported diff status: {status!r}")
        elif len(status) != 1:
            raise DiffError(f"unsupported diff status: {status!r}")
        path_count = 2 if prefix in RENAME_OR_COPY else 1
        if index + path_count > len(fields):
            raise DiffError(f"truncated name-status record for {status}")
        paths = [
            validate_repo_path(
                decode_field(fields[index + offset], "diff path"),
                "diff path",
                allow_glob=False,
            )
            for offset in range(path_count)
        ]
        index += path_count
        changes.append({"status": status, "paths": paths})
    if not changes:
        raise DiffError("diff contains no paths")
    return changes


def run_git(
    repository: pathlib.Path,
    arguments: Sequence[str],
    *,
    input_data: Optional[bytes] = None,
) -> bytes:
    try:
        completed = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            input=input_data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise DiffError(f"could not execute git: {error}") from error
    if completed.returncode != 0:
        message = completed.stderr.decode("utf-8", "replace").strip()
        raise DiffError(f"git {' '.join(arguments)} failed: {message}")
    return completed.stdout


def resolve_commit(repository: pathlib.Path, revision: str, label: str) -> str:
    if not revision or revision.startswith("-"):
        raise DiffError(f"{label} is not a safe revision")
    output = run_git(
        repository,
        ["rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}"],
    )
    sha = output.decode("ascii", "strict").strip()
    if not sha or any(character not in "0123456789abcdef" for character in sha):
        raise DiffError(f"{label} did not resolve to an object id")
    return sha


def empty_tree(repository: pathlib.Path) -> str:
    output = run_git(repository, ["hash-object", "-t", "tree", "--stdin"], input_data=b"")
    sha = output.decode("ascii", "strict").strip()
    if not sha:
        raise DiffError("could not resolve the empty Git tree")
    return sha


def git_diff_changes(
    repository: pathlib.Path, base: str, head: str
) -> tuple[list[dict[str, Any]], str, str]:
    base_sha = (
        empty_tree(repository)
        if len(base) >= 40 and set(base) == {"0"}
        else resolve_commit(repository, base, "base")
    )
    head_sha = resolve_commit(repository, head, "head")
    output = run_git(
        repository,
        [
            "diff",
            "--name-status",
            "-z",
            "--find-renames",
            "--find-copies",
            base_sha,
            head_sha,
            "--",
        ],
    )
    return parse_name_status(output), base_sha, head_sha


def flatten_changed_paths(changes: Sequence[dict[str, Any]]) -> list[str]:
    return unique_in_order(
        path for change in changes for path in change.get("paths", [])
    )


def default_policy_path() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1] / "verification-policy.json"


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Classify a RendererIOS diff into verification gates"
    )
    parser.add_argument("--policy", type=pathlib.Path, default=default_policy_path())
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--validate-policy", action="store_true")
    parser.add_argument("--pretty", action="store_true")
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--base")
    sources.add_argument("--name-status-file", type=pathlib.Path)
    sources.add_argument("--path", action="append")
    parser.add_argument("--head", default="HEAD")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_arguments(argv)
    try:
        policy_path = arguments.policy.resolve()
        policy = load_policy(policy_path)
        if arguments.head != "HEAD" and not arguments.base:
            raise DiffError("--head requires --base")
        if arguments.validate_policy and not (
            arguments.base or arguments.name_status_file or arguments.path
        ):
            print("verification policy passed")
            return 0
        source_count = sum(
            bool(value)
            for value in (
                arguments.base,
                arguments.name_status_file,
                arguments.path,
            )
        )
        if source_count != 1:
            raise DiffError(
                "choose exactly one change source: --base, --name-status-file, or --path"
            )
        if arguments.base:
            changes, _base_sha, _head_sha = git_diff_changes(
                arguments.repo.resolve(), arguments.base, arguments.head
            )
        elif arguments.name_status_file:
            try:
                data = arguments.name_status_file.read_bytes()
            except OSError as error:
                raise DiffError(
                    f"could not read name-status file: {error}"
                ) from error
            changes = parse_name_status(data)
        else:
            assert arguments.path is not None
            changes = [{"status": "M", "paths": [path]} for path in arguments.path]

        result = classify_paths(policy, flatten_changed_paths(changes))
        result["policySha256"] = policy_sha256(policy_path)
        print(
            json.dumps(
                result,
                indent=2 if arguments.pretty else None,
                sort_keys=True,
                separators=None if arguments.pretty else (",", ":"),
            )
        )
        return 0
    except (PolicyError, DiffError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
