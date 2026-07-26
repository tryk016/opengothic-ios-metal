#!/usr/bin/env python3
"""Route local RendererIOS verification from one fail-closed policy."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile
from typing import Optional, Sequence


SCHEMA_VERSION = 1
REPO = pathlib.Path(__file__).resolve().parents[1]
CLASSIFIER = REPO / "scripts" / "classify_verification.py"
DEFAULT_EXECUTOR = REPO / "scripts" / "execute_verification_gates.py"
DEFAULT_UPSTREAM = "origin/main"


class ContextError(RuntimeError):
    """The local change context cannot safely narrow verification."""

    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code


def run_git(arguments: Sequence[str]) -> bytes:
    try:
        completed = subprocess.run(
            ["git", "-C", str(REPO), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise ContextError("git-unavailable", str(error)) from error
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise ContextError("git-command-failed", detail)
    return completed.stdout


def resolve_commit(revision: str, label: str) -> str:
    if not revision or revision.startswith("-"):
        raise ContextError(f"{label}-unavailable", f"unsafe revision: {revision!r}")
    try:
        sha = run_git(
            ["rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}"]
        ).decode("ascii", "strict").strip()
    except UnicodeError as error:
        raise ContextError(f"{label}-unavailable", str(error)) from error
    if not sha or any(character not in "0123456789abcdef" for character in sha):
        raise ContextError(f"{label}-unavailable", "revision did not resolve to a SHA")
    return sha


def tracked_diff(base: str, head: Optional[str] = None) -> bytes:
    arguments = [
        "diff",
        "--name-status",
        "-z",
        "--find-renames",
        "--find-copies",
        base,
    ]
    if head is not None:
        arguments.append(head)
    arguments.append("--")
    return run_git(arguments)


def local_tracked_changes() -> bytes:
    staged = run_git(
        [
            "diff",
            "--cached",
            "--name-status",
            "-z",
            "--find-renames",
            "--find-copies",
            "HEAD",
            "--",
        ]
    )
    unstaged = run_git(
        [
            "diff",
            "--name-status",
            "-z",
            "--find-renames",
            "--find-copies",
            "--",
        ]
    )
    return staged + unstaged


def untracked_changes() -> bytes:
    raw = run_git(["ls-files", "--others", "--exclude-standard", "-z", "--"])
    if not raw:
        return b""
    fields = raw.split(b"\0")
    if fields[-1] != b"":
        raise ContextError(
            "untracked-status-invalid",
            "git ls-files did not emit a terminal NUL",
        )
    records = bytearray()
    for path in fields[:-1]:
        if not path:
            raise ContextError("untracked-status-invalid", "empty untracked path")
        records.extend(b"A\0")
        records.extend(path)
        records.extend(b"\0")
    return bytes(records)


def slice_records() -> bytes:
    resolve_commit("HEAD", "head")
    return local_tracked_changes() + untracked_changes()


def prepush_records(upstream: str) -> tuple[bytes, str]:
    head = resolve_commit("HEAD", "head")
    upstream_sha = resolve_commit(upstream, "upstream")
    try:
        base = run_git(["merge-base", head, upstream_sha]).decode(
            "ascii", "strict"
        ).strip()
    except UnicodeError as error:
        raise ContextError("merge-base-unavailable", str(error)) from error
    if not base or any(character not in "0123456789abcdef" for character in base):
        raise ContextError("merge-base-unavailable", "merge-base is not a SHA")
    records = (
        tracked_diff(base, head) + local_tracked_changes() + untracked_changes()
    )
    return records, base


def classify(records: bytes) -> dict[str, object]:
    temporary_name: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix="opengothic-verification-", suffix=".name-status", delete=False
        ) as temporary:
            temporary.write(records)
            temporary_name = temporary.name
        completed = subprocess.run(
            [
                sys.executable,
                str(CLASSIFIER),
                "--repo",
                str(REPO),
                "--name-status-file",
                temporary_name,
            ],
            cwd=REPO,
            env={
                **os.environ,
                "PYTHONDONTWRITEBYTECODE": "1",
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise ContextError("classifier-unavailable", str(error)) from error
    finally:
        if temporary_name is not None:
            try:
                pathlib.Path(temporary_name).unlink()
            except FileNotFoundError:
                pass
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise ContextError("classifier-failed", detail)
    try:
        payload = json.loads(completed.stdout)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ContextError("classifier-output-invalid", str(error)) from error
    gates = payload.get("gates")
    if (
        payload.get("schemaVersion") != SCHEMA_VERSION
        or not isinstance(gates, list)
        or not gates
        or any(not isinstance(gate, str) or not gate for gate in gates)
    ):
        raise ContextError(
            "classifier-output-invalid",
            "classifier result has no valid non-empty gate set",
        )
    return payload


def full_result(mode: str, selection: str, error_code: Optional[str]) -> dict[str, object]:
    result: dict[str, object] = {
        "schemaVersion": SCHEMA_VERSION,
        "mode": mode,
        "selection": selection,
        "risk": "infrastructure" if mode == "phase" else "unknown",
        "gates": ["full"],
        "reason": [
            "phase verification always requires the full gate"
            if mode == "phase"
            else "verification context unavailable; full required"
        ],
        "full": True,
        "fallback": mode != "phase",
    }
    if error_code is not None:
        result["contextError"] = error_code
    return result


def execute(gates: Sequence[str], mode: str) -> int:
    executor = pathlib.Path(
        os.environ.get("OPENGOTHIC_VERIFY_GATE_EXECUTOR", str(DEFAULT_EXECUTOR))
    )
    if not executor.is_file() or not os.access(executor, os.X_OK):
        print(
            f"FAIL: verification executor is missing or not executable: {executor}",
            file=sys.stderr,
        )
        return 2
    environment = os.environ.copy()
    environment["OPENGOTHIC_VERIFY_MODE"] = mode
    if mode in {"slice", "prepush"}:
        environment["OPENGOTHIC_VERIFY_ALLOW_DIRTY"] = "1"
    else:
        environment.pop("OPENGOTHIC_VERIFY_ALLOW_DIRTY", None)
    try:
        completed = subprocess.run(
            [str(executor), *gates],
            cwd=REPO,
            env=environment,
            check=False,
        )
    except OSError as error:
        print(f"FAIL: could not execute verification gates: {error}", file=sys.stderr)
        return 2
    return completed.returncode


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Route local RendererIOS verification"
    )
    parser.add_argument("mode", choices=("slice", "prepush", "phase"))
    parser.add_argument(
        "--upstream",
        default=os.environ.get("OPENGOTHIC_VERIFY_UPSTREAM", DEFAULT_UPSTREAM),
        help="explicit prepush upstream revision (default: origin/main)",
    )
    parser.add_argument("--pretty", action="store_true")
    return parser.parse_args(argv)


def emit(payload: dict[str, object], pretty: bool) -> None:
    print(
        json.dumps(
            payload,
            indent=2 if pretty else None,
            sort_keys=True,
            separators=None if pretty else (",", ":"),
        ),
        flush=True,
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_arguments(argv)
    mode = arguments.mode
    if mode == "phase":
        result = full_result(mode, "phase", None)
    else:
        try:
            if mode == "slice":
                records = slice_records()
                base = None
            else:
                records, base = prepush_records(arguments.upstream)
            if not records:
                emit(
                    {
                        "schemaVersion": SCHEMA_VERSION,
                        "mode": mode,
                        "selection": "no-changes",
                        "status": "no-changes",
                    },
                    arguments.pretty,
                )
                print("NO CHANGES: no verification gates were executed", file=sys.stderr)
                return 3
            result = classify(records)
            result["mode"] = mode
            result["selection"] = "classified"
            if base is not None:
                result["baseSha"] = base
                result["upstream"] = arguments.upstream
        except ContextError as error:
            print(
                f"verification context error ({error.code}); selecting full",
                file=sys.stderr,
            )
            result = full_result(mode, "fail-closed", error.code)

    emit(result, arguments.pretty)
    gates = result["gates"]
    assert isinstance(gates, list)
    return execute(gates, mode)


if __name__ == "__main__":
    sys.exit(main())
