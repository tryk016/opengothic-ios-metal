#!/usr/bin/env python3
"""Supervise a detached devicectl console stream and probe nonce-scoped markers."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
from typing import Sequence


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_status(path: pathlib.Path, payload: dict[str, object]) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True) + "\n")
    os.replace(temporary, path)


def supervise(raw_path: pathlib.Path, status_path: pathlib.Path,
              stop_request_path: pathlib.Path, instance_token: str,
              command: Sequence[str]) -> int:
    if not command:
        raise ValueError("missing supervised command")
    for caught in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(caught, signal.SIG_IGN)

    started = utc_now()
    base: dict[str, object] = {
        "supervisor_pid": os.getpid(),
        "instance_token": instance_token,
        "child_pid": None,
        "state": "starting",
        "returncode": None,
        "forced_kill": False,
        "started_at_utc": started,
        "finished_at_utc": None,
    }
    write_status(status_path, base)
    with raw_path.open("xb", buffering=0) as raw:
        child: subprocess.Popen[bytes] | None = None
        try:
            child = subprocess.Popen(
                list(command),
                stdin=subprocess.DEVNULL,
                stdout=raw,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            base.update(child_pid=child.pid, state="running")
            write_status(status_path, base)
            while True:
                polled = child.poll()
                if polled is not None:
                    returncode = polled
                    break
                try:
                    requested_token = stop_request_path.read_text().strip()
                except FileNotFoundError:
                    requested_token = ""
                if requested_token == instance_token:
                    child.kill()
                    returncode = child.wait()
                    base["forced_kill"] = True
                    break
                time.sleep(0.1)
            base.update(
                state="exited",
                returncode=returncode,
                finished_at_utc=utc_now(),
            )
            write_status(status_path, base)
        except BaseException as error:
            if child is None:
                returncode = 127
            else:
                if child.poll() is None:
                    try:
                        child.kill()
                        base["forced_kill"] = True
                    except ProcessLookupError:
                        pass
                returncode = child.wait()
            base.update(
                state="exited",
                returncode=returncode,
                finished_at_utc=utc_now(),
                supervisor_error=type(error).__name__,
            )
            try:
                write_status(status_path, base)
            except Exception:
                pass
            try:
                raw.write(f"console supervisor failure: {error}\n".encode())
            except Exception:
                pass
            return 127 if child is None else 125
        return returncode if 0 <= returncode <= 255 else 128 + (-returncode)


def complete_lines(payload: bytes) -> list[str]:
    lines = []
    for raw_line in payload.split(b"\n")[:-1]:
        if raw_line.endswith(b"\r"):
            raw_line = raw_line[:-1]
        lines.append(raw_line.decode("utf-8", errors="replace"))
    return lines


def probe_payload(payload: bytes, marker: str, mode: str, nonce: str) -> str:
    lines = complete_lines(payload)
    failure_prefix = (
        f"RendererIOS semantic script: SCRIPT FAIL mode={mode} nonce={nonce} "
    )
    if any(line.startswith(failure_prefix) for line in lines):
        return "script-fail"
    hits = sum(line == marker for line in lines)
    if hits > 1:
        return "duplicate"
    if hits == 1:
        return "marker"
    return "pending"


def probe(raw_path: pathlib.Path, marker: str, mode: str, nonce: str) -> int:
    print(probe_payload(raw_path.read_bytes(), marker, mode, nonce))
    return 0


def print_status(status_path: pathlib.Path) -> int:
    payload = json.loads(status_path.read_text())
    fields = (
        payload.get("state", ""),
        payload.get("child_pid", ""),
        payload.get("returncode", ""),
        payload.get("supervisor_pid", ""),
        payload.get("instance_token", ""),
        int(bool(payload.get("forced_kill", False))),
        payload.get("started_at_utc", ""),
        payload.get("finished_at_utc", ""),
    )
    print("|".join("" if value is None else str(value) for value in fields))
    return 0


def self_test() -> None:
    global write_status
    nonce = "0123456789abcdef0123456789abcdef"
    other = "fedcba9876543210fedcba9876543210"
    mode = "save-ui-lifecycle-v1"
    marker = f"RendererIOS semantic script: state=READY_FOR_LIFECYCLE nonce={nonce}"
    wrong = f"RendererIOS semantic script: state=READY_FOR_LIFECYCLE nonce={other}"
    failure = (
        f"RendererIOS semantic script: SCRIPT FAIL mode={mode} nonce={nonce} "
        "state=WAIT_WORLD reason=watchdog-timeout"
    )
    cases = {
        "lf": ((marker + "\n").encode(), "marker"),
        "crlf": ((marker + "\r\n").encode(), "marker"),
        "partial": (marker.encode(), "pending"),
        "bare-cr": ((marker + "\r").encode(), "pending"),
        "crcrlf": ((marker + "\r\r\n").encode(), "pending"),
        "wrong-nonce": ((wrong + "\n").encode(), "pending"),
        "current-fail": ((failure + "\n").encode(), "script-fail"),
        "duplicate": ((marker + "\n" + marker + "\n").encode(), "duplicate"),
    }
    for name, (payload, expected) in cases.items():
        actual = probe_payload(payload, marker, mode, nonce)
        if actual != expected:
            raise AssertionError(f"{name}: expected {expected}, got {actual}")

    with tempfile.TemporaryDirectory() as directory:
        raw = pathlib.Path(directory) / "raw.log"
        status = pathlib.Path(directory) / "status.json"
        returncode = supervise(
            raw,
            status,
            pathlib.Path(directory) / "early-stop-request",
            "early-exit-token",
            (sys.executable, "-c", "print('early-exit'); raise SystemExit(23)"),
        )
        if returncode != 23:
            raise AssertionError(f"early exit returned {returncode}, expected 23")
        loaded = json.loads(status.read_text())
        if loaded.get("state") != "exited" or loaded.get("returncode") != 23:
            raise AssertionError(f"early exit status is incomplete: {loaded}")
        if raw.read_text() != "early-exit\n":
            raise AssertionError("early exit raw console evidence is incomplete")

        wrong_stop = pathlib.Path(directory) / "wrong-stop-request"
        wrong_stop.write_text("wrong-instance-token\n")
        wrong_stop_raw = pathlib.Path(directory) / "wrong-stop-raw.log"
        wrong_stop_status = pathlib.Path(directory) / "wrong-stop-status.json"
        wrong_stop_returncode = supervise(
            wrong_stop_raw,
            wrong_stop_status,
            wrong_stop,
            "right-instance-token",
            (sys.executable, "-c", "print('wrong-stop-token-survived')"),
        )
        wrong_stop_payload = json.loads(wrong_stop_status.read_text())
        if wrong_stop_returncode != 0 or wrong_stop_payload.get("forced_kill"):
            raise AssertionError("wrong stop token killed the supervised child")

        authenticated_stop = pathlib.Path(directory) / "authenticated-stop-request"
        authenticated_stop.write_text("authenticated-instance-token\n")
        authenticated_raw = pathlib.Path(directory) / "authenticated-stop-raw.log"
        authenticated_status = pathlib.Path(directory) / "authenticated-stop-status.json"
        authenticated_returncode = supervise(
            authenticated_raw,
            authenticated_status,
            authenticated_stop,
            "authenticated-instance-token",
            (sys.executable, "-c", "import time; time.sleep(60)"),
        )
        authenticated_payload = json.loads(authenticated_status.read_text())
        if authenticated_returncode != 137:
            raise AssertionError(
                f"authenticated stop returned {authenticated_returncode}, expected 137"
            )
        if (authenticated_payload.get("state") != "exited" or
                authenticated_payload.get("returncode") != -signal.SIGKILL or
                not authenticated_payload.get("forced_kill")):
            raise AssertionError(
                f"authenticated stop status is incomplete: {authenticated_payload}"
            )

        publish_raw = pathlib.Path(directory) / "publish-failure.log"
        publish_status = pathlib.Path(directory) / "publish-failure.json"
        original_write_status = write_status
        published_child_pid: int | None = None

        def fail_running_publish(path: pathlib.Path,
                                 payload: dict[str, object]) -> None:
            nonlocal published_child_pid
            if payload.get("state") == "running":
                published_child_pid = int(payload["child_pid"])
                raise OSError("injected running-status publish failure")
            original_write_status(path, payload)

        write_status = fail_running_publish
        try:
            publish_returncode = supervise(
                publish_raw,
                publish_status,
                pathlib.Path(directory) / "publish-stop-request",
                "publish-failure-token",
                (sys.executable, "-c", "import time; time.sleep(60)"),
            )
        finally:
            write_status = original_write_status
        if publish_returncode != 125 or published_child_pid is None:
            raise AssertionError("post-spawn publish failure was not contained")
        try:
            os.kill(published_child_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("child_live_after_supervisor_failure")
        publish_payload = json.loads(publish_status.read_text())
        if (publish_payload.get("state") != "exited" or
                publish_payload.get("returncode") != -signal.SIGKILL or
                not publish_payload.get("forced_kill")):
            raise AssertionError(
                f"publish-failure terminal status is incomplete: {publish_payload}"
            )
    print("PASS — semantic console supervisor self-test")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    supervise_parser = subparsers.add_parser("supervise")
    supervise_parser.add_argument("--raw", type=pathlib.Path, required=True)
    supervise_parser.add_argument("--status", type=pathlib.Path, required=True)
    supervise_parser.add_argument("--stop-request", type=pathlib.Path, required=True)
    supervise_parser.add_argument("--instance-token", required=True)
    supervise_parser.add_argument("remainder", nargs=argparse.REMAINDER)

    probe_parser = subparsers.add_parser("probe")
    probe_parser.add_argument("--raw", type=pathlib.Path, required=True)
    probe_parser.add_argument("--marker", required=True)
    probe_parser.add_argument("--mode", required=True)
    probe_parser.add_argument("--nonce", required=True)

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--status", type=pathlib.Path, required=True)
    subparsers.add_parser("self-test")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "supervise":
        command = args.remainder
        if command[:1] == ["--"]:
            command = command[1:]
        return supervise(
            args.raw,
            args.status,
            args.stop_request,
            args.instance_token,
            command,
        )
    if args.command == "probe":
        return probe(args.raw, args.marker, args.mode, args.nonce)
    if args.command == "status":
        return print_status(args.status)
    self_test()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
