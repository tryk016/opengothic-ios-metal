#!/usr/bin/env python3
"""Build and run the complete RendererIOS app in an isolated iOS Simulator.

The game data is supplied as an external, read-only fixture.  A disposable
clone is installed into the Simulator app container and is removed with the
app after every run.  This lane is an early regression filter; it never emits
physical-device or GPU-proof claims.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterable


ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNTIME_ID = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEVICE_TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
DEVICE_NAME = "OpenGothic RendererIOS Tests"
DEFAULT_APP = (
    ROOT
    / "build/local-renderer-ios-simulator-fast/opengothic/Release/Gothic2Notr.app"
)
REQUIRED_LOG_MARKERS = (
    "OpenGothic v1.0 dev",
    "RendererIOS builtin shader library:",
    "RendererIOS linear HDR activation:",
    "RendererIOS shell: version=1 profile=Safe",
    "OpenGothic world ready",
    "RendererIOS simulator smoke budget:",
    "RendererIOS gameplay UI ready",
    "RendererIOS native scene ready:",
)
FORBIDDEN_LOG_MARKERS = (
    "fatal:",
    "Gothic II data not found",
    "unable to create Metal device",
    "pipeline-unavailable",
    "RendererIOS asynchronous Metal present failed",
    "RendererIOS Metal frame fence failed",
    "RendererIOS stopped the frame loop",
)


class GateError(RuntimeError):
    pass


@dataclass(frozen=True)
class FixtureIdentity:
    root: pathlib.Path
    documents: pathlib.Path
    file_count: int
    byte_count: int
    snapshot_sha256: str
    inventory_sha256: str
    snapshot: dict[str, str]
    source_stat: tuple[int, int, int]


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: pathlib.Path, value: Any) -> None:
    encoded = (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=True) as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
        temporary.unlink()
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def attempt_cleanup(
    errors: list[str], label: str, operation: Callable[[], Any]
) -> Any | None:
    try:
        return operation()
    except BaseException as error:
        errors.append(f"{label}: {error}")
        return None


def run(
    argv: Iterable[str],
    *,
    timeout: float,
    log: pathlib.Path | None = None,
    check: bool = True,
    cwd: pathlib.Path = ROOT,
) -> subprocess.CompletedProcess[bytes]:
    command = [str(value) for value in argv]
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=3)
        if log is not None:
            log.write_bytes(stdout + stderr)
            os.chmod(log, 0o600)
        raise GateError(f"command timed out after {timeout:.0f}s: {command!r}")
    if log is not None:
        header = (
            f"argv={json.dumps(command, ensure_ascii=False)}\n"
            f"returnCode={process.returncode}\n"
            f"durationSeconds={time.monotonic() - started:.3f}\n"
        ).encode("utf-8")
        log.write_bytes(header + stdout + stderr)
        os.chmod(log, 0o600)
    if check and process.returncode != 0:
        excerpt = stderr.decode("utf-8", "replace")[-1200:].strip()
        raise GateError(
            f"command failed with {process.returncode}: {command!r}: {excerpt}"
        )
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def terminate_simulator_app(
    errors: list[str],
    simulator_udid: str,
    bundle_id: str,
    *,
    required: bool,
    command_runner: Callable[..., subprocess.CompletedProcess[bytes]] = run,
) -> None:
    result = attempt_cleanup(
        errors,
        "terminate app",
        lambda: command_runner(
            ("/usr/bin/xcrun", "simctl", "terminate", simulator_udid, bundle_id),
            timeout=20,
            check=False,
        ),
    )
    if required and result is not None and result.returncode != 0:
        errors.append("terminate failed")


def cleanup_dedicated_simulator(
    errors: list[str],
    simulator_udid: str,
    *,
    command_runner: Callable[..., subprocess.CompletedProcess[bytes]] = run,
) -> None:
    for action, timeout in (("shutdown", 60), ("erase", 120)):
        result = attempt_cleanup(
            errors,
            f"{action} dedicated Simulator",
            lambda action=action, timeout=timeout: command_runner(
                ["/usr/bin/xcrun", "simctl", action, simulator_udid],
                timeout=timeout,
                check=False,
            ),
        )
        if result is not None and result.returncode != 0:
            errors.append(f"{action} failed")


def parse_key_values(path: pathlib.Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw or "=" not in raw:
            raise GateError(f"malformed fixture snapshot line: {raw!r}")
        key, value = raw.split("=", 1)
        if not key or key in result:
            raise GateError(f"duplicate or empty fixture snapshot key: {key!r}")
        result[key] = value
    return result


def parse_outer_manifest(path: pathlib.Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9.]+)", raw)
        if match is None or match.group(2) in result:
            raise GateError("fixture outer manifest is malformed")
        result[match.group(2)] = match.group(1)
    if set(result) != {"Documents.sha256", "SNAPSHOT.txt"}:
        raise GateError("fixture outer manifest has unexpected members")
    return result


def tree_stats(root: pathlib.Path, *, require_read_only: bool) -> tuple[int, int]:
    files = 0
    total = 0
    stack = [root]
    while stack:
        directory = stack.pop()
        directory_stat = directory.lstat()
        if not stat.S_ISDIR(directory_stat.st_mode) or directory.is_symlink():
            raise GateError(f"fixture contains a non-directory branch: {directory}")
        if require_read_only and directory_stat.st_mode & stat.S_IWUSR:
            raise GateError(f"fixture directory is owner-writable: {directory}")
        with os.scandir(directory) as members:
            for member in members:
                member_stat = member.stat(follow_symlinks=False)
                member_path = pathlib.Path(member.path)
                if stat.S_ISLNK(member_stat.st_mode):
                    raise GateError(f"fixture contains a symlink: {member_path}")
                if stat.S_ISDIR(member_stat.st_mode):
                    stack.append(member_path)
                    continue
                if not stat.S_ISREG(member_stat.st_mode):
                    raise GateError(f"fixture contains a non-regular leaf: {member_path}")
                if require_read_only and member_stat.st_mode & stat.S_IWUSR:
                    raise GateError(f"fixture leaf is owner-writable: {member_path}")
                files += 1
                total += member_stat.st_size
    return files, total


def validate_fixture(path: pathlib.Path) -> FixtureIdentity:
    candidate = path.expanduser()
    if candidate.is_symlink():
        raise GateError("fixture root must not be a symlink")
    root = candidate.resolve(strict=True)
    if not root.is_dir() or root.is_symlink():
        raise GateError("fixture root must be a direct directory")
    expected_members = {"Documents", "Documents.sha256", "MANIFEST.sha256", "SNAPSHOT.txt"}
    if {member.name for member in root.iterdir()} != expected_members:
        raise GateError("fixture root inventory differs")
    documents = root / "Documents"
    inventory = root / "Documents.sha256"
    snapshot_path = root / "SNAPSHOT.txt"
    outer = parse_outer_manifest(root / "MANIFEST.sha256")
    snapshot_sha = sha256_file(snapshot_path)
    inventory_sha = sha256_file(inventory)
    if outer["SNAPSHOT.txt"] != snapshot_sha or outer["Documents.sha256"] != inventory_sha:
        raise GateError("fixture outer manifest hash differs")
    snapshot = parse_key_values(snapshot_path)
    required_snapshot = {
        "source_device_udid",
        "bundle_id",
        "source",
        "captured_utc",
        "parent_sha",
        "fixture_scope",
        "excluded",
        "file_count",
        "byte_count",
    }
    if set(snapshot) != required_snapshot or snapshot["source"] != "Documents":
        raise GateError("fixture snapshot contract differs")
    try:
        expected_files = int(snapshot["file_count"])
        expected_bytes = int(snapshot["byte_count"])
    except ValueError as error:
        raise GateError("fixture count metadata is not numeric") from error
    actual_files, actual_bytes = tree_stats(documents, require_read_only=True)
    if (actual_files, actual_bytes) != (expected_files, expected_bytes):
        raise GateError("fixture metadata differs from the read-only tree")
    for leaf in ("Data", "_work", "system"):
        candidate = documents / leaf
        if not candidate.is_dir() or candidate.is_symlink():
            raise GateError(f"fixture is missing required directory: {leaf}")
    for leaf in ("Gothic.ini", "save_slot_4.sav"):
        candidate = documents / leaf
        if not candidate.is_file() or candidate.is_symlink():
            raise GateError(f"fixture is missing required file: {leaf}")
    source = documents.stat()
    return FixtureIdentity(
        root=root,
        documents=documents,
        file_count=actual_files,
        byte_count=actual_bytes,
        snapshot_sha256=snapshot_sha,
        inventory_sha256=inventory_sha,
        snapshot=snapshot,
        source_stat=(source.st_dev, source.st_ino, source.st_mtime_ns),
    )


def verify_fixture_content(
    fixture: FixtureIdentity, evidence: pathlib.Path
) -> pathlib.Path:
    """Read and verify every fixture leaf for every Simulator attempt."""
    entries = []
    for line in (fixture.root / "Documents.sha256").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"[0-9a-f]{64}  \./(.+)", line)
        if match is None:
            raise GateError("fixture inventory line is malformed")
        entries.append(match.group(1))
    actual = {
        path.relative_to(fixture.documents).as_posix()
        for path in fixture.documents.rglob("*") if path.is_file()
    }
    if len(entries) != len(set(entries)) or set(entries) != actual:
        raise GateError("fixture inventory does not cover each file exactly once")
    started = time.monotonic()
    verification_log = evidence / "fixture-full-sha.log"
    result = run(
        ["/usr/bin/shasum", "-a", "256", "-c", str(fixture.root / "Documents.sha256")],
        timeout=900,
        cwd=fixture.documents,
        log=verification_log,
    )
    if result.stdout.count(b"OK\n") != fixture.file_count:
        raise GateError("fixture full verification did not cover every leaf")
    record = evidence / "fixture-full-verification-v1.json"
    write_json(record, {
        "schemaVersion": 1,
        "fixture": str(fixture.root),
        "inventorySha256": fixture.inventory_sha256,
        "snapshotSha256": fixture.snapshot_sha256,
        "fileCount": fixture.file_count,
        "byteCount": fixture.byte_count,
        "sourceStat": list(fixture.source_stat),
        "verificationLog": verification_log.name,
        "verificationLogSha256": sha256_file(verification_log),
        "durationSeconds": round(time.monotonic() - started, 3),
    })
    return record


def select_or_create_simulator(requested: str | None) -> tuple[str, str]:
    listing = json.loads(
        run(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"], timeout=30).stdout
    )
    runtime_devices = listing.get("devices", {}).get(RUNTIME_ID, [])
    if requested:
        matches = [device for device in runtime_devices if device.get("udid") == requested]
        if len(matches) != 1 or matches[0].get("isAvailable", True) is not True:
            raise GateError("requested Simulator is not one available iOS 27 device")
        return requested, str(matches[0].get("state", "Unknown"))
    matches = [
        device
        for device in runtime_devices
        if device.get("name") == DEVICE_NAME and device.get("isAvailable", True) is True
    ]
    if len(matches) > 1:
        raise GateError("multiple dedicated OpenGothic Simulators exist")
    if matches:
        return str(matches[0]["udid"]), str(matches[0].get("state", "Unknown"))
    created = run(
        [
            "/usr/bin/xcrun",
            "simctl",
            "create",
            DEVICE_NAME,
            DEVICE_TYPE_ID,
            RUNTIME_ID,
        ],
        timeout=60,
    ).stdout.decode("ascii").strip()
    if re.fullmatch(r"[0-9A-F-]{36}", created) is None:
        raise GateError("simctl returned an invalid created-device identifier")
    return created, "Shutdown"


def validate_app(app: pathlib.Path) -> tuple[str, pathlib.Path, pathlib.Path]:
    candidate = app.expanduser()
    if candidate.is_symlink():
        raise GateError("Simulator app bundle must not be a symlink")
    app = candidate.resolve(strict=True)
    if not app.is_dir() or app.is_symlink():
        raise GateError("Simulator app bundle is not a direct directory")
    info_path = app / "Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    bundle = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(bundle, str) or not isinstance(executable_name, str):
        raise GateError("Simulator app identity is incomplete")
    executable = app / executable_name
    metallib = app / "RendererIOS.metallib"
    if not executable.is_file() or executable.is_symlink() or not metallib.is_file():
        raise GateError("Simulator app executable or RendererIOS metallib is missing")
    file_output = run(["/usr/bin/file", str(executable)], timeout=15).stdout.decode()
    if "Mach-O 64-bit executable arm64" not in file_output:
        raise GateError("Simulator executable is not arm64 Mach-O")
    build_output = run(["/usr/bin/vtool", "-show-build", str(executable)], timeout=15).stdout
    if b"platform IOSSIMULATOR" not in build_output:
        raise GateError("app executable is not built for iOS Simulator")
    return bundle, executable, metallib


def make_working_documents(source: pathlib.Path, destination: pathlib.Path) -> None:
    if not destination.is_dir() or destination.is_symlink():
        raise GateError("Simulator Documents destination is not a direct directory")
    if any(destination.iterdir()):
        raise GateError("fresh Simulator Documents destination is not empty")
    run(["/bin/cp", "-cR", str(source) + "/.", str(destination)], timeout=600)
    for directory, names, leaves in os.walk(destination, followlinks=False):
        directory_path = pathlib.Path(directory)
        if directory_path.is_symlink():
            raise GateError("working documents unexpectedly contain a symlink")
        os.chmod(directory_path, directory_path.stat().st_mode | stat.S_IWUSR)
        for name in names + leaves:
            member = directory_path / name
            if member.is_symlink():
                raise GateError("working documents unexpectedly contain a symlink")
            os.chmod(member, member.stat().st_mode | stat.S_IWUSR)


def parse_launch_pid(output: bytes, bundle_id: str) -> int:
    match = re.fullmatch(
        re.escape(bundle_id).encode("ascii") + rb": ([1-9][0-9]*)\n?", output
    )
    if match is None:
        raise GateError("simctl launch output is malformed")
    return int(match.group(1))


def validate_runtime_log(contents: str) -> None:
    missing = [marker for marker in REQUIRED_LOG_MARKERS if marker not in contents]
    forbidden = [marker for marker in FORBIDDEN_LOG_MARKERS if marker.lower() in contents.lower()]
    if missing:
        raise GateError(f"runtime log is missing markers: {missing!r}")
    if forbidden:
        raise GateError(f"runtime log contains forbidden markers: {forbidden!r}")


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def build_app(evidence: pathlib.Path) -> None:
    parent_sha = run(["/usr/bin/git", "rev-parse", "HEAD"], timeout=15).stdout.decode().strip()
    run(
        [
            "cmake",
            "--preset",
            "renderer-ios-simulator-fast",
            f"-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA={parent_sha}",
        ],
        timeout=180,
        log=evidence / "configure.log",
    )
    run(
        ["cmake", "--build", "--preset", "renderer-ios-simulator-fast"],
        timeout=1800,
        log=evidence / "build.log",
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    parser.add_argument("--app", type=pathlib.Path, default=DEFAULT_APP)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--simulator-udid")
    parser.add_argument("--duration", type=int, default=900)
    parser.add_argument("--save-slot", type=int, default=4)
    parser.add_argument("--output", type=pathlib.Path)
    arguments = parser.parse_args(argv)
    if not 15 <= arguments.duration <= 1200:
        raise GateError("duration must be between 15 and 1200 seconds")
    if not 1 <= arguments.save_slot <= 999:
        raise GateError("save slot must be between 1 and 999")

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    evidence = (
        arguments.output.expanduser()
        if arguments.output
        else ROOT / "build/simulator-test/full-game" / f"{stamp}-{os.getpid()}"
    )
    if not evidence.is_absolute():
        evidence = (pathlib.Path.cwd() / evidence).resolve()
    evidence.mkdir(mode=0o700, parents=True, exist_ok=False)

    fixture = validate_fixture(arguments.fixture)
    verification_record = verify_fixture_content(fixture, evidence)
    if not arguments.skip_build:
        build_app(evidence)
    bundle_id, executable, metallib = validate_app(arguments.app)

    simulator_udid = ""
    simulator_state = "Unknown"
    dedicated_simulator = arguments.simulator_udid is None
    booted_here = False
    installed = False
    started = time.monotonic()
    timings: dict[str, float] = {}
    container = pathlib.Path()
    documents: pathlib.Path | None = None
    pid = 0
    cleanup_errors: list[str] = []
    failure: BaseException | None = None
    try:
        simulator_udid, simulator_state = select_or_create_simulator(
            arguments.simulator_udid
        )
        if dedicated_simulator:
            if simulator_state == "Booted":
                run(
                    ["/usr/bin/xcrun", "simctl", "shutdown", simulator_udid],
                    timeout=60,
                )
            run(
                ["/usr/bin/xcrun", "simctl", "erase", simulator_udid],
                timeout=120,
                log=evidence / "erase-before.log",
            )
            simulator_state = "Shutdown"
        if simulator_state != "Booted":
            run(["/usr/bin/xcrun", "simctl", "boot", simulator_udid], timeout=60)
            booted_here = True
        run(
            ["/usr/bin/xcrun", "simctl", "bootstatus", simulator_udid, "-b"],
            timeout=180,
            log=evidence / "boot.log",
        )
        if not dedicated_simulator:
            run(
                ["/usr/bin/xcrun", "simctl", "terminate", simulator_udid, bundle_id],
                timeout=20,
                check=False,
            )
            run(
                ["/usr/bin/xcrun", "simctl", "uninstall", simulator_udid, bundle_id],
                timeout=120,
                check=False,
            )
        install_started = time.monotonic()
        run(
            ["/usr/bin/xcrun", "simctl", "install", simulator_udid, str(arguments.app)],
            timeout=120,
            log=evidence / "install.log",
        )
        timings["installSeconds"] = time.monotonic() - install_started
        installed = True
        raw_container = run(
            [
                "/usr/bin/xcrun",
                "simctl",
                "get_app_container",
                simulator_udid,
                bundle_id,
                "data",
            ],
            timeout=30,
        ).stdout.decode("utf-8").strip()
        container = pathlib.Path(raw_container).resolve(strict=True)
        simulator_root = (
            pathlib.Path.home() / "Library/Developer/CoreSimulator/Devices" / simulator_udid
        ).resolve(strict=True)
        if simulator_root not in container.parents:
            raise GateError("simctl returned a data container outside the selected Simulator")
        documents = container / "Documents"
        copy_started = time.monotonic()
        make_working_documents(fixture.documents, documents)
        copied_files, copied_bytes = tree_stats(documents, require_read_only=False)
        if (copied_files, copied_bytes) != (fixture.file_count, fixture.byte_count):
            raise GateError("working game-data clone metadata differs")
        timings["fixtureCloneSeconds"] = time.monotonic() - copy_started

        launch_started = time.monotonic()
        launch = run(
            [
                "/usr/bin/xcrun",
                "simctl",
                "launch",
                "--terminate-running-process",
                simulator_udid,
                bundle_id,
                "-save",
                str(arguments.save_slot),
            ],
            timeout=30,
            log=evidence / "launch.log",
        )
        pid = parse_launch_pid(launch.stdout, bundle_id)
        runtime_log = documents / "log.txt"
        deadline = time.monotonic() + arguments.duration
        last_contents = ""
        while time.monotonic() < deadline:
            if not process_alive(pid):
                raise GateError("full game exited before the Simulator gate passed")
            if runtime_log.is_file():
                last_contents = runtime_log.read_text(encoding="utf-8", errors="replace")
                try:
                    validate_runtime_log(last_contents)
                    break
                except GateError:
                    pass
            time.sleep(0.5)
        else:
            validate_runtime_log(last_contents)
        settle_deadline = min(deadline, time.monotonic() + 5.0)
        while time.monotonic() < settle_deadline:
            if not process_alive(pid):
                raise GateError("full game exited while settling after world load")
            time.sleep(0.25)
        if runtime_log.is_file():
            last_contents = runtime_log.read_text(encoding="utf-8", errors="replace")
        validate_runtime_log(last_contents)
        timings["launchToReadySeconds"] = time.monotonic() - launch_started

        screenshot = evidence / "screenshot.png"
        run(
            ["/usr/bin/xcrun", "simctl", "io", simulator_udid, "screenshot", str(screenshot)],
            timeout=30,
            log=evidence / "screenshot-command.log",
        )
        if not screenshot.is_file() or screenshot.stat().st_size == 0:
            raise GateError("Simulator screenshot was not published")
        shutil.copy2(runtime_log, evidence / "runtime.log")
        stderr_log = documents / "stderr.log"
        if stderr_log.is_file():
            shutil.copy2(stderr_log, evidence / "stderr.log")
        system_log = run(
            [
                "/usr/bin/xcrun",
                "simctl",
                "spawn",
                simulator_udid,
                "log",
                "show",
                "--last",
                "5m",
                "--style",
                "compact",
                "--predicate",
                'process == "Gothic2Notr"',
            ],
            timeout=60,
            check=False,
        )
        (evidence / "system.log").write_bytes(system_log.stdout + system_log.stderr)
        os.chmod(evidence / "system.log", 0o600)
    except BaseException as error:
        failure = error
    finally:
        if simulator_udid:
            if documents is not None and documents.is_dir():
                for source_name, destination_name in (
                    ("log.txt", "runtime.log"),
                    ("stderr.log", "stderr.log"),
                ):
                    source = documents / source_name
                    destination = evidence / destination_name
                    if source.is_file() and not destination.exists():
                        attempt_cleanup(
                            cleanup_errors,
                            f"preserve {source_name}",
                            lambda source=source, destination=destination: (
                                shutil.copy2(source, destination),
                                os.chmod(destination, 0o600),
                            ),
                        )
            if not (evidence / "system.log").exists():
                def preserve_system_log() -> None:
                    system_log = run(
                        [
                            "/usr/bin/xcrun", "simctl", "spawn", simulator_udid,
                            "log", "show", "--last", "5m", "--style", "compact",
                            "--predicate", 'process == "Gothic2Notr"',
                        ],
                        timeout=60,
                        check=False,
                    )
                    (evidence / "system.log").write_bytes(
                        system_log.stdout + system_log.stderr
                    )
                    os.chmod(evidence / "system.log", 0o600)

                attempt_cleanup(
                    cleanup_errors, "preserve system log", preserve_system_log
                )
            terminate_simulator_app(
                cleanup_errors,
                simulator_udid,
                bundle_id,
                required=pid > 0,
            )
            if dedicated_simulator:
                cleanup_dedicated_simulator(cleanup_errors, simulator_udid)
            else:
                result = attempt_cleanup(
                    cleanup_errors,
                    "uninstall app",
                    lambda: run(
                        ("/usr/bin/xcrun", "simctl", "uninstall", simulator_udid, bundle_id),
                        timeout=120,
                        check=False,
                    ),
                )
                if installed and result is not None and result.returncode != 0:
                    cleanup_errors.append("uninstall failed")
                if booted_here:
                    result = attempt_cleanup(
                        cleanup_errors,
                        "shutdown requested Simulator",
                        lambda: run(
                            ["/usr/bin/xcrun", "simctl", "shutdown", simulator_udid],
                            timeout=60,
                            check=False,
                        ),
                    )
                    if result is not None and result.returncode != 0:
                        cleanup_errors.append("shutdown failed")

    timings["totalSeconds"] = time.monotonic() - started
    summary = {
        "schemaVersion": 1,
        "evidenceClass": "renderer-ios-full-game-simulator-smoke",
        "result": "PASS" if failure is None and not cleanup_errors else "FAIL",
        "claim": (
            "SIMULATOR PASS / DEVICE PENDING"
            if failure is None and not cleanup_errors
            else "SIMULATOR FAIL / DEVICE PENDING"
        ),
        "simulator": {
            "udid": simulator_udid,
            "runtime": RUNTIME_ID,
            "deviceType": DEVICE_TYPE_ID,
        },
        "app": {
            "bundleId": bundle_id,
            "executableSha256": sha256_file(executable),
            "metallibSha256": sha256_file(metallib),
        },
        "fixture": {
            "inventorySha256": fixture.inventory_sha256,
            "snapshotSha256": fixture.snapshot_sha256,
            "fileCount": fixture.file_count,
            "byteCount": fixture.byte_count,
            "fullVerificationRecord": verification_record.name,
        },
        "saveSlot": arguments.save_slot,
        "pid": pid,
        "timings": {key: round(value, 3) for key, value in timings.items()},
        "cleanupErrors": cleanup_errors,
        "failure": None if failure is None else str(failure),
    }
    write_json(evidence / "summary.json", summary)
    if failure is not None:
        raise failure
    if cleanup_errors:
        raise GateError(", ".join(cleanup_errors))
    print(f"SIMULATOR PASS / DEVICE PENDING evidence={evidence}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except GateError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
