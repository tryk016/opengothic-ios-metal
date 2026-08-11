#!/usr/bin/env python3
"""Build and validate P2.1e2a physical-device census attestations."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import struct
import sys
import tempfile
import unicodedata
from typing import Any

sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent
CORE_PATH = HERE / "validate-remaining-material-census-log.py"
MODULE_SPEC = importlib.util.spec_from_file_location("remaining_census_core", CORE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("remaining-material core validator is unavailable")
CORE = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(CORE)

SHA40 = re.compile(r"[0-9a-f]{40}\Z")
SHA64 = re.compile(r"[0-9a-f]{64}\Z")
CORE_DEVICE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\Z")
HARDWARE = re.compile(r"(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})\Z")
CONTAINER = re.compile(
    r"/private/var/mobile/Containers/Data/Application/"
    r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\Z"
)
BUNDLE_CONTAINER = re.compile(
    r"/private/var/containers/Bundle/Application/"
    r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\Z"
)
BUNDLE_ID = "opengothic.gothic2.RMJWWPF379"
TEAM_ID = "RMJWWPF379"
ATTESTATION = "remaining-material-census-device-attestation-v1.json"
ARTIFACT = "remaining-material-census-v1.bin"
SEAL = "phone-ready-seal-v1.json"
MACHO = "signed-Gothic2Notr.macho"
CONTINUITY_FILES = (
    "pre-apps-v1.json", "post-apps-v1.json",
    "pre-protected-save-metadata-v1.json",
    "post-protected-save-metadata-v1.json",
    "pre-resource-manifest-v1.jsonl", "post-resource-manifest-v1.jsonl",
)
INVENTORY = frozenset((SEAL, "result.txt", "log.txt", ARTIFACT,
                       ATTESTATION, MACHO, *CONTINUITY_FILES))
RESULT_KEYS = frozenset((
    "result", "source_sha", "expected_build", "scenario", "save_slot",
    "log_sha256", "expected_fault", "device_process_stopped",
    "device_foreground_parked", "durable_zero_scans_per_cycle",
    "durable_zero_required_stable_seconds", "durable_zero_scans_completed",
    "durable_zero_stable", "durable_zero_stable_seconds",
    "durable_zero_final_zero", "signed_executable_sha256",
))
SEAL_ROLES = (
    "runner", "entrypoint", "architecture-contract",
    "build-for-testing-manifest", "system-bash", "system-python3",
    "system-ps", "system-codesign", "system-security", "system-xcrun",
    "device-guard", "xcodebuild", "devicectl", "xcresulttool", "spec",
    "signed-executable", "metallib", "signed-app", "test-products",
)


class AttestationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AttestationError(message)


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def canonical(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                       separators=(",", ":"), allow_nan=False) + "\n").encode()


def duplicate_reject(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    raise AttestationError(f"nonfinite JSON constant: {value}")


def read(path: pathlib.Path, label: str, maximum: int,
         *, mode: int | None = None, exact: int | None = None) -> bytes:
    require(path.is_absolute() and path == path.resolve(),
            f"{label} path is not canonical absolute")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
                f"{label} is not a single-link regular file")
        require(0 < before.st_size <= maximum, f"{label} size is out of bounds")
        if exact is not None:
            require(before.st_size == exact, f"{label} size differs")
        if mode is not None:
            require(stat.S_IMODE(before.st_mode) == mode,
                    f"{label} mode differs")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            require(bool(chunk), f"{label} ended early")
            chunks.append(chunk)
            remaining -= len(chunk)
        require(os.read(descriptor, 1) == b"", f"{label} grew during read")
        after = os.fstat(descriptor)
        marker = lambda item: (item.st_dev, item.st_ino, item.st_mode,
                               item.st_nlink, item.st_size, item.st_mtime_ns,
                               item.st_ctime_ns)
        require(marker(before) == marker(after), f"{label} changed during read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def load_json(path: pathlib.Path, label: str, *, mode: int = 0o600,
              maximum: int = 4 * 1024 * 1024) -> tuple[Any, bytes]:
    raw = read(path, label, maximum, mode=mode)
    try:
        value = json.loads(raw.decode("utf-8", errors="strict"),
                           object_pairs_hook=duplicate_reject,
                           parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise AttestationError(f"{label} is not strict JSON") from error
    require(raw == canonical(value), f"{label} is not canonical JSON")
    return value, raw


def exact(value: Any, keys: set[str] | frozenset[str], label: str) -> dict[str, Any]:
    require(type(value) is dict and set(value) == set(keys),
            f"{label} key set differs")
    return value


def h40(value: Any, label: str) -> str:
    require(type(value) is str and SHA40.fullmatch(value) is not None,
            f"{label} is not h40")
    return value


def h64(value: Any, label: str) -> str:
    require(type(value) is str and SHA64.fullmatch(value) is not None,
            f"{label} is not h64")
    return value


def positive(value: Any, label: str) -> int:
    require(type(value) is int and value > 0, f"{label} is not positive int")
    return value


def meta(path: pathlib.Path, label: str, *, mode: int = 0o600,
         maximum: int = 64 * 1024 * 1024) -> tuple[dict[str, Any], bytes]:
    raw = read(path, label, maximum, mode=mode)
    return {"file": path.name, "bytes": len(raw), "sha256": sha256(raw)}, raw


def parse_result(path: pathlib.Path, expected_sha: str,
                 expected_log_hash: str) -> tuple[dict[str, str], bytes]:
    raw = read(path, "result", 64 * 1024, mode=0o600)
    try:
        lines = raw.decode("ascii", errors="strict").splitlines()
    except UnicodeError as error:
        raise AttestationError("result is not ASCII") from error
    values: dict[str, str] = {}
    for line in lines:
        require(line.count("=") == 1, "result line is malformed")
        key, value = line.split("=", 1)
        require(re.fullmatch(r"[a-z][a-z0-9_]*", key) is not None and
                key not in values, "result key is invalid or duplicated")
        values[key] = value
    require(set(values) == RESULT_KEYS, "result key set differs")
    expected = {
        "result": "PASS", "source_sha": expected_sha,
        "expected_build": expected_sha, "scenario": "save", "save_slot": "4",
        "log_sha256": expected_log_hash, "expected_fault": "none",
        "device_process_stopped": "1", "device_foreground_parked": "1",
        "durable_zero_scans_per_cycle": "10",
        "durable_zero_required_stable_seconds": "90",
        "durable_zero_stable": "1", "durable_zero_final_zero": "1",
    }
    for key, value in expected.items():
        require(values[key] == value, f"result {key} differs")
    for key, minimum in (("durable_zero_scans_completed", 10),
                         ("durable_zero_stable_seconds", 90)):
        require(re.fullmatch(r"0|[1-9][0-9]*", values[key]) is not None and
                int(values[key]) >= minimum, f"result {key} is below bound")
    h64(values["signed_executable_sha256"], "result executable hash")
    return values, raw


def parse_macho(raw: bytes, build: str) -> None:
    require(len(raw) >= 32, "Mach-O is truncated")
    magics = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}
    require(raw[:4] in magics, "Mach-O is not exact 64-bit thin executable")
    endian = magics[raw[:4]]
    file_type = struct.unpack_from(endian + "I", raw, 12)[0]
    commands, command_bytes = struct.unpack_from(endian + "II", raw, 16)
    require(file_type == 2 and 0 < commands <= 65535 and
            32 + command_bytes <= len(raw), "Mach-O header differs")
    offset = 32
    for _ in range(commands):
        require(offset <= 32 + command_bytes - 8, "Mach-O command truncated")
        size = struct.unpack_from(endian + "I", raw, offset + 4)[0]
        require(size >= 8 and size % 4 == 0 and
                offset + size <= 32 + command_bytes, "Mach-O command differs")
        offset += size
    require(offset == 32 + command_bytes, "Mach-O commands do not conserve")
    require(raw.count(build.encode()) == 1, "Mach-O build marker differs")
    for marker in (CORE.GROUP_PREFIX, CORE.MATERIAL_PREFIX, CORE.ROW_PREFIX):
        require(raw.count(marker.encode()) == 1,
                "Mach-O census marker differs")


def current_file_item(path: pathlib.Path, role: str) -> dict[str, Any]:
    raw = read(path, f"sealed {role}", 512 * 1024 * 1024)
    value = path.lstat()
    return {"role": role, "path": str(path), "kind": "file",
            "mode": stat.S_IMODE(value.st_mode), "bytes": len(raw),
            "sha256": sha256(raw), "device": value.st_dev,
            "inode": value.st_ino, "mtimeNs": value.st_mtime_ns,
            "ctimeNs": value.st_ctime_ns}


def current_system_item(path: pathlib.Path, role: str) -> dict[str, Any]:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == 0 and
                before.st_nlink >= 1 and not stat.S_IMODE(before.st_mode) & 0o022
                and 0 < before.st_size <= 16 * 1024 * 1024,
                "sealed system tool metadata differs")
        raw = b""
        while len(raw) < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024,
                                            before.st_size - len(raw)))
            require(bool(chunk), "sealed system tool short read")
            raw += chunk
        require(os.read(descriptor, 1) == b"", "sealed system tool grew")
        after = os.fstat(descriptor)
        require((before.st_dev, before.st_ino, before.st_mode, before.st_uid,
                 before.st_gid, before.st_nlink, before.st_size,
                 before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_dev, after.st_ino, after.st_mode, after.st_uid,
                 after.st_gid, after.st_nlink, after.st_size,
                 after.st_mtime_ns, after.st_ctime_ns),
                "sealed system tool changed")
        return {"role": role, "path": str(path), "kind": "system-file",
                "mode": stat.S_IMODE(before.st_mode), "uid": before.st_uid,
                "gid": before.st_gid, "links": before.st_nlink,
                "bytes": len(raw), "sha256": sha256(raw),
                "device": before.st_dev, "inode": before.st_ino,
                "mtimeNs": before.st_mtime_ns, "ctimeNs": before.st_ctime_ns}
    finally:
        os.close(descriptor)


def current_tree_item(path: pathlib.Path, role: str) -> dict[str, Any]:
    require(path.is_absolute() and path == path.resolve() and path.is_dir() and
            not path.is_symlink(), "sealed tree root differs")
    members: list[dict[str, Any]] = []
    total = 0
    for candidate in sorted(path.rglob("*"),
                            key=lambda item: item.relative_to(path).as_posix().encode()):
        relative = candidate.relative_to(path).as_posix()
        value = candidate.lstat()
        require(not stat.S_ISLNK(value.st_mode), "sealed tree has symlink")
        if stat.S_ISDIR(value.st_mode):
            members.append({"path": relative, "kind": "directory",
                            "mode": stat.S_IMODE(value.st_mode)})
        else:
            require(stat.S_ISREG(value.st_mode) and value.st_nlink == 1,
                    "sealed tree has special/multilink member")
            descriptor = os.open(candidate, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                raw = b""
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    raw += chunk
            finally:
                os.close(descriptor)
            total += len(raw)
            members.append({"path": relative, "kind": "file",
                            "mode": stat.S_IMODE(value.st_mode),
                            "bytes": len(raw), "sha256": sha256(raw)})
    root = path.lstat()
    manifest = (json.dumps(members, sort_keys=True,
                           separators=(",", ":")) + "\n").encode()
    return {"role": role, "path": str(path), "kind": "tree",
            "mode": stat.S_IMODE(root.st_mode), "members": len(members),
            "bytes": total, "manifestSha256": sha256(manifest),
            "device": root.st_dev, "inode": root.st_ino,
            "mtimeNs": root.st_mtime_ns, "ctimeNs": root.st_ctime_ns}


def validate_seal(path: pathlib.Path, expected_sha: str) -> tuple[dict[str, Any], bytes, dict[str, Any]]:
    envelope, raw = load_json(path, "phone-ready seal")
    wrapper = exact(envelope, frozenset((
        "schemaVersion", "evidenceClass", "baseSeal", "approval",
        "deviceSpec", "sealId",
    )), "phone-ready seal envelope")
    require(type(wrapper["schemaVersion"]) is int and
            wrapper["schemaVersion"] == 1 and
            wrapper["evidenceClass"] ==
            "remaining-material-census-phone-ready-seal-v1",
            "phone-ready seal envelope identity differs")
    h64(wrapper["sealId"], "phone-ready seal envelope id")
    wrapper_payload = {key: value for key, value in wrapper.items()
                       if key != "sealId"}
    require(sha256(canonical(wrapper_payload)) == wrapper["sealId"],
            "phone-ready seal envelope payload hash differs")
    require(type(wrapper["deviceSpec"]) is dict,
            "phone-ready sealed device spec differs")

    root = exact(wrapper["baseSeal"], frozenset((
        "schemaVersion", "evidenceClass", "specId", "device", "test",
        "items", "signing", "appProvisioning", "appIdentity",
        "testProductIdentity", "testSigning", "testProvisioning",
        "toolchain", "xctestrun", "xctestrunPolicy", "createdAtEpoch",
        "sealId",
    )), "seal")
    require(type(root["schemaVersion"]) is int and root["schemaVersion"] == 1 and
            root["evidenceClass"] == "renderer-ios-device-harness-v2-seal",
            "seal identity differs")
    h64(root["sealId"], "seal id")
    payload = {key: value for key, value in root.items() if key != "sealId"}
    require(sha256(canonical(payload)) == root["sealId"],
            "seal payload hash differs")
    require(type(root["items"]) is list and
            tuple(item.get("role") for item in root["items"]) == SEAL_ROLES,
            "seal item inventory differs")
    for item in root["items"]:
        require(type(item) is dict and type(item.get("path")) is str,
                "seal item differs")
        item_path = pathlib.Path(item["path"])
        if item.get("kind") == "file":
            current = current_file_item(item_path, item["role"])
        elif item.get("kind") == "system-file":
            current = current_system_item(item_path, item["role"])
        elif item.get("kind") == "tree":
            current = current_tree_item(item_path, item["role"])
        else:
            raise AttestationError("seal item kind differs")
        require(current == item, f"sealed item changed: {item['role']}")
    spec_item = next(item for item in root["items"] if item["role"] == "spec")
    spec_value, _ = load_json(pathlib.Path(spec_item["path"]), "sealed spec")
    runner_item = next(item for item in root["items"] if item["role"] == "runner")
    runner_path = pathlib.Path(runner_item["path"])
    module_name = f"sealed_device_harness_{root['sealId']}"
    verifier_spec = importlib.util.spec_from_file_location(module_name, runner_path)
    require(verifier_spec is not None and verifier_spec.loader is not None,
            "sealed runner cannot be loaded")
    verifier = importlib.util.module_from_spec(verifier_spec)
    sys.modules[module_name] = verifier
    try:
        verifier_spec.loader.exec_module(verifier)
        verify = getattr(verifier, "verify_seal")
    except (AttributeError, ImportError, RuntimeError) as error:
        raise AttestationError("sealed runner has no full seal verifier") from error
    require(callable(verify), "sealed runner verifier is not callable")
    approval = exact(wrapper["approval"], frozenset((
        "schemaVersion", "evidenceClass", "sealId", "runnerSha256",
        "specSha256", "hostComposition", "reviews", "runRootBase",
        "terminal", "approvalId",
    )), "phone-ready approval")
    h64(approval["approvalId"], "phone-ready approval id")
    with tempfile.TemporaryDirectory(prefix="remaining-seal-verify-") as name:
        temporary = pathlib.Path(name).resolve()
        temporary.chmod(0o700)
        base_path = temporary / "base-seal-v1.json"
        approval_path = temporary / "approval-v1.json"
        device_spec_path = temporary / "device-spec-v1.json"
        base_path.write_bytes(canonical(root))
        approval_path.write_bytes(canonical(approval))
        device_spec_path.write_bytes(CORE.canonical_json(wrapper["deviceSpec"]))
        base_path.chmod(0o600)
        approval_path.chmod(0o600)
        device_spec_path.chmod(0o600)
        try:
            verified_seal, verified_spec = verify(
                base_path, verify_signing=True, expected_seal_id=root["sealId"]
            )
            verify_approval = getattr(verifier, "verify_approval")
            verified_approval = verify_approval(
                approval_path, verified_seal, approval["approvalId"]
            )
            verified_device_spec, _ = CORE.validate_device_spec(device_spec_path)
        except Exception as error:
            raise AttestationError(
                "sealed runner rejected phone-ready seal or approval"
            ) from error
    require(verified_seal == root and verified_spec == spec_value,
            "sealed runner verification result differs")
    require(verified_approval == approval,
            "sealed runner approval verification result differs")
    require(verified_device_spec == wrapper["deviceSpec"],
            "sealed public device spec verification differs")
    device = exact(root["device"], frozenset((
        "coreDeviceIdentifier", "hardwareUdid", "bundleId", "executableName",
    )), "seal device")
    require(CORE_DEVICE.fullmatch(str(device["coreDeviceIdentifier"])) is not None and
            HARDWARE.fullmatch(str(device["hardwareUdid"])) is not None and
            device["bundleId"] == BUNDLE_ID and
            device["executableName"] == "Gothic2Notr",
            "seal device differs")
    require(type(root["test"]) is dict and
            root["test"].get("saveSlot") == "4" and
            root["test"].get("scenario") == "save" and
            type(root["test"].get("onlyTesting")) is str and
            root["test"]["onlyTesting"].startswith("RendererIOSUITests/"),
            "seal test differs")
    require(type(root["signing"]) is dict and
            root["signing"].get("bundleId") == BUNDLE_ID and
            root["signing"].get("teamId") == TEAM_ID,
            "seal signing differs")
    require(type(root["appIdentity"]) is dict and
            root["appIdentity"].get("bundleId") == BUNDLE_ID and
            type(root["appIdentity"].get("shortVersion")) is str and
            type(root["appIdentity"].get("bundleVersion")) is str,
            "seal app identity differs")
    require(type(spec_value) is dict and
            spec_value.get("id") == root["specId"] and
            spec_value.get("device") == root["device"] and
            spec_value.get("test") == root["test"] and
            type(spec_value.get("artifacts")) is dict and
            spec_value["artifacts"].get("runtimeBuildSha") == expected_sha,
            "seal/spec/source join differs")
    signed = next(item for item in root["items"]
                  if item["role"] == "signed-executable")
    require(signed["sha256"] == h64(signed["sha256"], "sealed executable hash") and
            signed["mode"] == 0o755 and signed["bytes"] > 0,
            "sealed executable identity differs")
    # Downstream joins use the base seal contents, but bind the portable
    # envelope identity (which also covers approval/composition/reviews).
    validated = dict(root)
    validated["sealId"] = wrapper["sealId"]
    return validated, raw, verified_device_spec


def validate_apps(path: pathlib.Path, continuity: dict[str, Any], seal: dict[str, Any],
                  *, post: bool) -> tuple[dict[str, Any], bytes]:
    value, raw = load_json(path, "apps evidence")
    root = exact(value, frozenset(("schemaVersion", "coreSelector",
                                   "hardwareSelector")), "apps evidence")
    require(type(root["schemaVersion"]) is int and root["schemaVersion"] == 1,
            "apps schema differs")
    expected_selectors = (continuity["deviceIdentifier"],
                          continuity["hardwareUdid"])
    normalized: list[dict[str, Any]] = []
    for key, selector in zip(("coreSelector", "hardwareSelector"),
                             expected_selectors):
        record = exact(root[key], frozenset(("selector", "result")),
                       f"apps {key}")
        require(record["selector"] == selector, f"apps {key} selector differs")
        result = exact(record["result"], frozenset((
            "deviceIdentifier", "matchingBundleIdentifier", "app",
        )), f"apps {key} result")
        app = exact(result["app"], frozenset((
            "bundleIdentifier", "containerAccessible", "dataContainerPath",
            "bundleContainerPath", "version", "bundleVersion",
            "builtByDeveloper", "teamIdentifier",
        )), f"apps {key} app")
        expected_path = continuity["containerPath" if post else
                                   "previousContainerPath"]
        require(result["deviceIdentifier"] == continuity["deviceIdentifier"] and
                result["matchingBundleIdentifier"] == BUNDLE_ID and
                app["bundleIdentifier"] == BUNDLE_ID and
                app["containerAccessible"] is True and
                app["dataContainerPath"] == expected_path and
                BUNDLE_CONTAINER.fullmatch(str(app["bundleContainerPath"])) is not None and
                app["builtByDeveloper"] is True and
                app["teamIdentifier"] == TEAM_ID and
                app["version"] == seal["appIdentity"].get("shortVersion") and
                app["bundleVersion"] == seal["appIdentity"].get("bundleVersion"),
                f"apps {key} identity differs")
        normalized.append(result)
    require(normalized[0] == normalized[1], "dual-selector apps results differ")
    return root, raw


def validate_protected(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    value, raw = load_json(path, "protected metadata")
    root = exact(value, frozenset(("schemaVersion", "files")),
                 "protected metadata")
    require(type(root["schemaVersion"]) is int and root["schemaVersion"] == 1 and
            type(root["files"]) is list, "protected metadata schema differs")
    names: list[str] = []
    for row in root["files"]:
        item = exact(row, frozenset(("name", "size", "mtime", "mode", "uid",
                                     "gid", "xattrs", "resources")),
                     "protected metadata row")
        require(type(item["name"]) is str and
                re.fullmatch(r"save_slot_(?:[1-4]|20)\.sav", item["name"]) is not None,
                "protected save name differs")
        for key in ("size", "mtime", "mode", "uid", "gid"):
            require(type(item[key]) is int and item[key] >= 0,
                    f"protected {key} differs")
        require(type(item["xattrs"]) is list and type(item["resources"]) is dict,
                "protected metadata detail differs")
        names.append(item["name"])
    require(names == sorted(names) and len(names) == len(set(names)) and
            set((f"save_slot_{index}.sav" for index in range(1, 5))).issubset(names),
            "protected save inventory differs")
    return root, raw


def validate_resource_manifest(path: pathlib.Path) -> bytes:
    raw = read(path, "resource manifest", 64 * 1024 * 1024, mode=0o600)
    require(raw.endswith(b"\n") and b"\r" not in raw and not raw.startswith(b"\xef\xbb\xbf"),
            "resource manifest framing differs")
    lines = raw[:-1].split(b"\n")
    require(bool(lines) and all(lines), "resource manifest has empty line")
    values: list[Any] = []
    for encoded in lines:
        try:
            value = json.loads(encoded.decode("utf-8", errors="strict"),
                               object_pairs_hook=duplicate_reject,
                               parse_constant=reject_constant)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise AttestationError("resource manifest JSONL differs") from error
        require(encoded == json.dumps(value, ensure_ascii=False,
                                      separators=(",", ":"),
                                      allow_nan=False).encode(),
                "resource manifest line is not compact canonical")
        values.append(value)
    header = values[0]
    require(type(header) is dict and tuple(header) ==
            ("schemaVersion", "roots", "excluded", "fileCount", "totalBytes") and
            type(header["schemaVersion"]) is int and
            header["schemaVersion"] == 1 and
            header["roots"] == ["Data", "_work/Data", "system"] and
            header["excluded"] == ["system/Gothic.ini"] and
            type(header["fileCount"]) is int and
            header["fileCount"] == len(values) - 1 <= 100000 and
            type(header["totalBytes"]) is int and 0 <= header["totalBytes"] <= 16 << 30,
            "resource manifest header differs")
    names: list[str] = []
    total = 0
    for row in values[1:]:
        require(type(row) is dict and tuple(row) ==
                ("relativePath", "byteSize", "sha256"),
                "resource manifest row keys/order differ")
        name = row["relativePath"]
        require(type(name) is str and name == unicodedata.normalize("NFC", name) and
                name and not name.startswith("/") and "\\" not in name and
                all(component not in ("", ".", "..")
                    for component in name.split("/")) and
                not any(ord(character) < 32 or ord(character) == 127
                        for character in name) and
                (name.startswith("Data/") or name.startswith("_work/Data/") or
                 name.startswith("system/")) and name != "system/Gothic.ini",
                "resource manifest relative path differs")
        require(type(row["byteSize"]) is int and 0 <= row["byteSize"] <= 8 << 30,
                "resource manifest byte size differs")
        h64(row["sha256"], "resource manifest hash")
        names.append(name)
        total += row["byteSize"]
    require(names == sorted(names, key=lambda value: value.encode("utf-8")) and
            len(names) == len(set(names)) and total == header["totalBytes"],
            "resource manifest records do not conserve")
    return raw


def normalize_smoke(result: dict[str, str], result_raw: bytes,
                    evidence: pathlib.Path) -> dict[str, Any]:
    return {
        "result": "PASS", "sourceSha": result["source_sha"],
        "buildSha": result["expected_build"], "scenario": "save",
        "saveSlot": 4, "expectedFault": "none",
        "logSha256": result["log_sha256"], "deviceProcessStopped": True,
        "deviceForegroundParked": True, "durableZeroStable": True,
        "durableZeroFinalZero": True, "requiredScans": 10,
        "completedScans": int(result["durable_zero_scans_completed"]),
        "requiredStableSeconds": 90,
        "stableSeconds": int(result["durable_zero_stable_seconds"]),
        "evidencePath": str(evidence),
        "evidencePathSha256": sha256(str(evidence).encode()),
        "resultFile": "result.txt", "resultBytes": len(result_raw),
        "resultSha256": sha256(result_raw),
    }


def snapshot(evidence: pathlib.Path, spec_path: pathlib.Path,
             expected_sha: str) -> tuple[dict[str, Any], bytes]:
    require(evidence.is_absolute() and evidence == evidence.resolve() and
            evidence.is_dir() and not evidence.is_symlink() and
            stat.S_IMODE(evidence.lstat().st_mode) == 0o700,
            "evidence directory differs")
    h40(expected_sha, "expected source SHA")
    spec, spec_raw = CORE.validate_device_spec(spec_path)
    seal, seal_raw, sealed_device_spec = validate_seal(
        evidence / SEAL, expected_sha
    )
    require(sealed_device_spec == spec,
            "phone-ready seal/public device spec join differs")
    log_meta, log_raw = meta(evidence / "log.txt", "source log")
    block = CORE.validate_log(log_raw, expected_sha, 1, 1)
    artifact_meta, artifact_raw = meta(evidence / ARTIFACT, "artifact",
                                       maximum=CORE.ARTIFACT_BYTES)
    require(len(artifact_raw) == CORE.ARTIFACT_BYTES and
            CORE.parse_artifact(artifact_raw) == block,
            "artifact/log join differs")
    result, result_raw = parse_result(evidence / "result.txt", expected_sha,
                                      sha256(log_raw))
    macho_meta, macho_raw = meta(evidence / MACHO, "signed executable",
                                 mode=0o755, maximum=1024 * 1024 * 1024)
    macho_meta = {"file": macho_meta["file"], "mode": 0o755,
                  "bytes": macho_meta["bytes"],
                  "sha256": macho_meta["sha256"]}
    parse_macho(macho_raw, expected_sha)
    require(macho_meta["sha256"] == result["signed_executable_sha256"],
            "result/Mach-O hash differs")
    sealed_executable = next(item for item in seal["items"]
                             if item["role"] == "signed-executable")
    require((macho_meta["bytes"], macho_meta["sha256"]) ==
            (sealed_executable["bytes"], sealed_executable["sha256"]),
            "Mach-O/seal identity differs")

    continuity_metas: dict[str, dict[str, Any]] = {}
    continuity_raw: dict[str, bytes] = {}
    for name in CONTINUITY_FILES:
        item_meta, item_raw = meta(evidence / name, name)
        continuity_metas[name] = item_meta
        continuity_raw[name] = item_raw
    continuity = {
        "deviceIdentifier": seal["device"]["coreDeviceIdentifier"],
        "hardwareUdid": seal["device"]["hardwareUdid"],
        "bundleIdentifier": BUNDLE_ID,
        "previousContainerPath": "",
        "containerPath": "",
        "containerRelocated": False,
        "protectedMetadataSha256": "",
        "preApps": continuity_metas[CONTINUITY_FILES[0]],
        "postApps": continuity_metas[CONTINUITY_FILES[1]],
        "preProtected": continuity_metas[CONTINUITY_FILES[2]],
        "postProtected": continuity_metas[CONTINUITY_FILES[3]],
        "preResourceManifest": continuity_metas[CONTINUITY_FILES[4]],
        "postResourceManifest": continuity_metas[CONTINUITY_FILES[5]],
    }
    pre_apps, _ = load_json(evidence / CONTINUITY_FILES[0], "pre apps")
    post_apps, _ = load_json(evidence / CONTINUITY_FILES[1], "post apps")
    for value, key in ((pre_apps, "previousContainerPath"),
                       (post_apps, "containerPath")):
        app = value.get("coreSelector", {}).get("result", {}).get("app", {})
        continuity[key] = app.get("dataContainerPath")
    require(CONTAINER.fullmatch(str(continuity["previousContainerPath"])) is not None and
            CONTAINER.fullmatch(str(continuity["containerPath"])) is not None,
            "continuity container path differs")
    continuity["containerRelocated"] = (
        continuity["previousContainerPath"] != continuity["containerPath"]
    )
    validate_apps(evidence / CONTINUITY_FILES[0], continuity, seal, post=False)
    validate_apps(evidence / CONTINUITY_FILES[1], continuity, seal, post=True)
    _, pre_protected = validate_protected(evidence / CONTINUITY_FILES[2])
    _, post_protected = validate_protected(evidence / CONTINUITY_FILES[3])
    require(pre_protected == post_protected, "protected save metadata changed")
    continuity["protectedMetadataSha256"] = sha256(pre_protected)
    pre_resources = validate_resource_manifest(evidence / CONTINUITY_FILES[4])
    post_resources = validate_resource_manifest(evidence / CONTINUITY_FILES[5])
    require(pre_resources == post_resources, "resource manifests changed")

    document = {
        "schemaVersion": 1,
        "evidenceClass": "device-remaining-material-source-census",
        "saveSlot": 4,
        "specSha256": sha256(spec_raw),
        "seal": {"file": SEAL, "bytes": len(seal_raw),
                 "sha256": sha256(seal_raw), "sealId": seal["sealId"]},
        "sourceLog": log_meta,
        "smoke": normalize_smoke(result, result_raw, evidence),
        "sourceSha": expected_sha,
        "buildSha": expected_sha,
        "targetGeneration": block["generation"],
        "snapshotSequence": block["sequence"],
        "signedExecutable": macho_meta,
        "continuity": continuity,
        "artifact": artifact_meta,
    }
    require(spec["sequence"] == document["snapshotSequence"] == 1,
            "spec/log/artifact sequence differs")
    return document, canonical(document)


def atomic(path: pathlib.Path, raw: bytes) -> None:
    require(path.is_absolute() and not os.path.lexists(path),
            "attestation output must be absent absolute")
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = f".{path.name}.{os.getpid()}.{os.urandom(8).hex()}.tmp"
    descriptor = -1
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             os.O_NOFOLLOW, 0o600, dir_fd=parent)
        offset = 0
        while offset < len(raw):
            written = os.write(descriptor, raw[offset:])
            require(written > 0, "attestation short write")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.link(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent,
                follow_symlinks=False)
        os.unlink(temporary, dir_fd=parent)
        os.fsync(parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def validate_attestation(path: pathlib.Path, spec: pathlib.Path,
                         expected_sha: str) -> dict[str, Any]:
    document, raw = load_json(path, "device attestation")
    expected, expected_raw = snapshot(path.parent, spec, expected_sha)
    require(raw == expected_raw and document == expected,
            "device attestation reconstruction differs")
    actual = frozenset(item.name for item in path.parent.iterdir())
    require(actual == INVENTORY, "device evidence flat inventory differs")
    # Reread the entire snapshot once more after inventory validation.
    repeated, repeated_raw = snapshot(path.parent, spec, expected_sha)
    require((repeated, repeated_raw) == (document, raw),
            "device evidence changed after publication")
    final_document, final_raw = load_json(path, "device attestation final reread")
    require((final_document, final_raw) == (document, raw),
            "device attestation changed after validation")
    cells = expected["artifact"]
    return {"status": "DEVICE GO", "attestationSha256": sha256(raw),
            "artifactSha256": cells["sha256"],
            "sealId": expected["seal"]["sealId"],
            "boundedCohort": "Static+Movable"}


def build_phone_ready_envelope(base_path: pathlib.Path,
                               approval_path: pathlib.Path,
                               device_spec_path: pathlib.Path,
                               output: pathlib.Path,
                               expected_sha: str) -> dict[str, Any]:
    base, _ = load_json(base_path, "base phone-ready seal")
    approval, _ = load_json(approval_path, "phone-ready approval")
    device_spec, _ = CORE.validate_device_spec(device_spec_path)
    payload = {
        "schemaVersion": 1,
        "evidenceClass": "remaining-material-census-phone-ready-seal-v1",
        "baseSeal": base,
        "approval": approval,
        "deviceSpec": device_spec,
    }
    envelope = dict(payload)
    envelope["sealId"] = sha256(canonical(payload))
    atomic(output, canonical(envelope))
    validated, _, sealed_spec = validate_seal(output, expected_sha)
    require(validated["sealId"] == envelope["sealId"] and
            sealed_spec == device_spec,
            "published phone-ready envelope differs")
    return envelope


def self_test() -> None:
    # Structural negative oracles independent of a private seal fixture.
    require(len(INVENTORY) == 12, "device inventory cardinality differs")
    require(CONTAINER.fullmatch(
        "/private/var/mobile/Containers/Data/Application/"
        "01234567-89AB-CDEF-0123-456789ABCDEF") is not None,
        "container grammar baseline differs")
    for value in (
        "/private/var/mobile/Containers/Data/Application/lowercase00-89AB-CDEF-0123-456789ABCDEF",
        "/private/var/mobile/Containers/Data/Application/01234567-89AB-CDEF-0123-456789ABCDE",
        "/tmp/01234567-89AB-CDEF-0123-456789ABCDEF",
    ):
        require(CONTAINER.fullmatch(value) is None,
                "container grammar mutation survived")
    with tempfile.TemporaryDirectory(prefix="remaining-attestation-selftest-") as name:
        root = pathlib.Path(name).resolve()
        root.chmod(0o700)
        output = root / "proof.json"
        atomic(output, canonical({"status": "fixture"}))
        require(load_json(output, "publication fixture")[0] ==
                {"status": "fixture"}, "atomic publication differs")
        alias = root / "proof-alias.json"
        alias.symlink_to(output)
        try:
            load_json(alias, "publication symlink fixture")
        except AttestationError:
            pass
        else:
            raise AttestationError("symlink attestation input survived")
        try:
            atomic(output, b"replacement")
        except AttestationError:
            pass
        else:
            raise AttestationError("no-clobber mutation survived")

        evidence = root / "evidence"
        evidence.mkdir(mode=0o700)
        build = "0123456789abcdef0123456789abcdef01234567"
        data_path = ("/private/var/mobile/Containers/Data/Application/"
                     "01234567-89AB-CDEF-0123-456789ABCDEF")
        bundle_path = ("/private/var/containers/Bundle/Application/"
                       "89ABCDEF-0123-4567-89AB-CDEF01234567")
        macho_header = (b"\xcf\xfa\xed\xfe" +
                        struct.pack("<iiIIIII", 0x0100000c, 0, 2, 1, 8, 0, 0) +
                        struct.pack("<II", 1, 8))
        macho_raw = (macho_header + build.encode() + b"\0" +
                     CORE.GROUP_PREFIX.encode() + b"\0" +
                     CORE.MATERIAL_PREFIX.encode() + b"\0" +
                     CORE.ROW_PREFIX.encode() + b"\0")
        macho = evidence / MACHO
        macho.write_bytes(macho_raw)
        macho.chmod(0o755)

        spec_path = root / "harness-spec.json"
        harness_spec = {
            "schemaVersion": 1,
            "evidenceClass": "renderer-ios-device-harness-v2-spec",
            "id": "remaining-census-fixture",
            "device": {"coreDeviceIdentifier": "COREDEVICE-FIXTURE-0001",
                       "hardwareUdid": "00008130-000564403E12001C",
                       "bundleId": BUNDLE_ID, "executableName": "Gothic2Notr"},
            "artifacts": {"app": str(root / "app"),
                          "executableRelative": "Gothic2Notr",
                          "metallibRelative": "RendererIOS.metallib",
                          "runtimeBuildSha": build,
                          "testDerivedData": str(root / "test-derived"),
                          "testProject": str(root / "test.xcodeproj"),
                          "testScheme": "RendererIOSUITests"},
            "test": {"onlyTesting":
                     "RendererIOSUITests/RendererIOSUITests/testFixture",
                     "saveSlot": "4", "scenario": "save"},
            "graph": [
                {"always": False, "id": "doctor", "kind": "doctor",
                 "mutating": False, "timeoutSeconds": 60},
                {"always": False, "id": "install", "kind": "installApp",
                 "mutating": True, "timeoutSeconds": 60},
                {"always": False, "id": "test", "kind": "xctestWithoutBuilding",
                 "mutating": True, "timeoutSeconds": 240},
                {"always": True, "id": "cleanup", "kind": "terminateAndZero",
                 "mutating": True, "timeoutSeconds": 120},
            ],
        }
        spec_path.write_bytes(canonical(harness_spec))
        spec_path.chmod(0o600)
        app_tree = root / "app"
        test_tree = root / "test-derived"
        app_tree.mkdir(mode=0o700)
        test_tree.mkdir(mode=0o700)
        (app_tree / "fixture").write_bytes(b"app")
        (test_tree / "fixture").write_bytes(b"test")

        ordinary = CORE_PATH
        system_paths = {
            "system-bash": pathlib.Path("/bin/bash"),
            "system-python3": pathlib.Path("/usr/bin/python3"),
            "system-ps": pathlib.Path("/bin/ps"),
            "system-codesign": pathlib.Path("/usr/bin/codesign"),
            "system-security": pathlib.Path("/usr/bin/security"),
            "system-xcrun": pathlib.Path("/usr/bin/xcrun"),
        }
        items: list[dict[str, Any]] = []
        for role in SEAL_ROLES:
            if role in system_paths:
                items.append(current_system_item(system_paths[role], role))
            elif role == "spec":
                items.append(current_file_item(spec_path, role))
            elif role == "signed-executable":
                items.append(current_file_item(macho, role))
            elif role == "signed-app":
                items.append(current_tree_item(app_tree, role))
            elif role == "test-products":
                items.append(current_tree_item(test_tree, role))
            else:
                items.append(current_file_item(ordinary, role))
        seal_payload = {
            "schemaVersion": 1,
            "evidenceClass": "renderer-ios-device-harness-v2-seal",
            "specId": harness_spec["id"], "device": harness_spec["device"],
            "test": harness_spec["test"], "items": items,
            "signing": {"bundleId": BUNDLE_ID, "teamId": TEAM_ID,
                        "cdHash": "0" * 40, "entitlementsSha256": "0" * 64},
            "appProvisioning": {"fixture": True},
            "appIdentity": {"bundleId": BUNDLE_ID, "shortVersion": "1.0",
                            "bundleVersion": "1", "xcode": "2700",
                            "xcodeBuild": "27A5228h", "sha256": "1" * 64},
            "testProductIdentity": {"fixture": True},
            "testSigning": {"fixture": True},
            "testProvisioning": {"fixture": True},
            "toolchain": {"fixture": True}, "xctestrun": "/fixture.xctestrun",
            "xctestrunPolicy": {"fixture": True}, "createdAtEpoch": 1,
        }
        seal_value = dict(seal_payload)
        seal_value["sealId"] = sha256(canonical(seal_payload))
        approval_payload = {
            "schemaVersion": 1,
            "evidenceClass":
            "renderer-ios-device-harness-v2-phone-ready-approval",
            "sealId": seal_value["sealId"],
            "runnerSha256": items[0]["sha256"],
            "specSha256": next(item["sha256"] for item in items
                                if item["role"] == "spec"),
            "hostComposition": {
                "path": str(root / "composition.log"), "bytes": 5,
                "sha256": sha256(b"PASS\n"),
            },
            "reviews": [],
            "runRootBase": str(root / "runs"),
            "terminal": "DEVICE HARNESS V2 PHONE READY",
        }
        approval_value = dict(approval_payload)
        approval_value["approvalId"] = sha256(canonical(approval_payload))
        device_spec_value = {
            "schemaVersion": 1, "saveSlot": 4, "sequence": 1,
            "materials": list(CORE.MATERIALS), "kinds": list(CORE.KINDS),
            "modes": list(CORE.MODES), "boundedKinds": ["Static", "Movable"],
            "requiredDurableScans": 10, "requiredStableSeconds": 90,
        }
        wrapper_payload = {
            "schemaVersion": 1,
            "evidenceClass":
            "remaining-material-census-phone-ready-seal-v1",
            "baseSeal": seal_value,
            "approval": approval_value,
            "deviceSpec": device_spec_value,
        }
        wrapper_value = dict(wrapper_payload)
        wrapper_value["sealId"] = sha256(canonical(wrapper_payload))
        (evidence / SEAL).write_bytes(canonical(wrapper_value))
        (evidence / SEAL).chmod(0o600)

        lines = CORE.sample_lines(build, 1, 1, [1] * CORE.CELL_COUNT)
        log_raw = ("\n".join(lines) + "\n").encode()
        (evidence / "log.txt").write_bytes(log_raw)
        block = CORE.validate_log(log_raw, build, 1, 1)
        artifact_raw = CORE.encode_artifact(block)
        (evidence / ARTIFACT).write_bytes(artifact_raw)
        result_values = {
            "result": "PASS", "source_sha": build, "expected_build": build,
            "scenario": "save", "save_slot": "4",
            "log_sha256": sha256(log_raw), "expected_fault": "none",
            "device_process_stopped": "1", "device_foreground_parked": "1",
            "durable_zero_scans_per_cycle": "10",
            "durable_zero_required_stable_seconds": "90",
            "durable_zero_scans_completed": "10", "durable_zero_stable": "1",
            "durable_zero_stable_seconds": "90", "durable_zero_final_zero": "1",
            "signed_executable_sha256": sha256(macho_raw),
        }
        (evidence / "result.txt").write_text(
            "".join(f"{key}={result_values[key]}\n" for key in sorted(RESULT_KEYS)),
            encoding="ascii")

        def apps() -> bytes:
            app = {"bundleIdentifier": BUNDLE_ID, "containerAccessible": True,
                   "dataContainerPath": data_path,
                   "bundleContainerPath": bundle_path, "version": "1.0",
                   "bundleVersion": "1", "builtByDeveloper": True,
                   "teamIdentifier": TEAM_ID}
            result = {"deviceIdentifier": harness_spec["device"]["coreDeviceIdentifier"],
                      "matchingBundleIdentifier": BUNDLE_ID, "app": app}
            return canonical({"schemaVersion": 1,
                              "coreSelector": {
                                  "selector": harness_spec["device"]["coreDeviceIdentifier"],
                                  "result": result},
                              "hardwareSelector": {
                                  "selector": harness_spec["device"]["hardwareUdid"],
                                  "result": result}})

        protected_rows = [
            {"name": f"save_slot_{index}.sav", "size": index,
             "mtime": 100 + index, "mode": 0o600, "uid": 501, "gid": 501,
             "xattrs": [], "resources": {}}
            for index in range(1, 5)
        ]
        protected_raw = canonical({"schemaVersion": 1, "files": protected_rows})
        resource_header = {"schemaVersion": 1,
                           "roots": ["Data", "_work/Data", "system"],
                           "excluded": ["system/Gothic.ini"],
                           "fileCount": 0, "totalBytes": 0}
        resource_raw = (json.dumps(resource_header, ensure_ascii=False,
                                   separators=(",", ":")) + "\n").encode()
        for leaf in CONTINUITY_FILES[:2]:
            (evidence / leaf).write_bytes(apps())
        for leaf in CONTINUITY_FILES[2:4]:
            (evidence / leaf).write_bytes(protected_raw)
        for leaf in CONTINUITY_FILES[4:]:
            (evidence / leaf).write_bytes(resource_raw)
        for leaf in INVENTORY - {ATTESTATION, MACHO}:
            (evidence / leaf).chmod(0o600)

        device_spec = root / "device-spec.json"
        device_spec.write_bytes(CORE.canonical_json(device_spec_value))
        continuity = {
            "deviceIdentifier": harness_spec["device"]["coreDeviceIdentifier"],
            "hardwareUdid": harness_spec["device"]["hardwareUdid"],
            "bundleIdentifier": BUNDLE_ID,
            "previousContainerPath": data_path, "containerPath": data_path,
            "containerRelocated": False,
        }
        validate_apps(evidence / CONTINUITY_FILES[0], continuity,
                      seal_value, post=False)
        validate_apps(evidence / CONTINUITY_FILES[1], continuity,
                      seal_value, post=True)
        validate_protected(evidence / CONTINUITY_FILES[2])
        validate_resource_manifest(evidence / CONTINUITY_FILES[4])
        resource_mutant = root / "resource-mutant.jsonl"
        for mutated in (
            (json.dumps({**resource_header, "schemaVersion": True},
                        ensure_ascii=False, separators=(",", ":")) +
             "\n").encode(),
            ((json.dumps({**resource_header, "fileCount": 1},
                         ensure_ascii=False, separators=(",", ":")) + "\n" +
              json.dumps({"relativePath": "Data/e\u0301", "byteSize": 0,
                          "sha256": "0" * 64}, ensure_ascii=False,
                         separators=(",", ":")) + "\n").encode()),
        ):
            resource_mutant.write_bytes(mutated)
            resource_mutant.chmod(0o600)
            try:
                validate_resource_manifest(resource_mutant)
            except AttestationError:
                pass
            else:
                raise AttestationError("resource manifest mutation survived")
        try:
            snapshot(evidence, device_spec, build)
        except (AttestationError, CORE.ValidationError):
            pass
        else:
            raise AttestationError("synthetic seal reached DEVICE GO snapshot")
    print("remaining-material device attestation self-test: PASS mutations=9 synthetic-device-go=0")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    envelope = sub.add_parser("build-phone-ready-envelope")
    envelope.add_argument("--base-seal", type=pathlib.Path, required=True)
    envelope.add_argument("--approval", type=pathlib.Path, required=True)
    envelope.add_argument("--device-spec", type=pathlib.Path, required=True)
    envelope.add_argument("--output", type=pathlib.Path, required=True)
    envelope.add_argument("--expected-sha", required=True)
    build = sub.add_parser("build")
    check = sub.add_parser("validate")
    for item in (build, check):
        item.add_argument("--evidence-dir", type=pathlib.Path, required=True)
        item.add_argument("--spec", type=pathlib.Path, required=True)
        item.add_argument("--expected-sha", required=True)
    arguments = parser.parse_args()
    if arguments.command == "self-test":
        self_test()
        return 0
    if arguments.command == "build-phone-ready-envelope":
        value = build_phone_ready_envelope(
            arguments.base_seal, arguments.approval,
            arguments.device_spec, arguments.output, arguments.expected_sha
        )
        print(json.dumps({"status": "PHONE-READY ENVELOPE GO",
                          "sealId": value["sealId"]},
                         sort_keys=True, separators=(",", ":")))
        return 0
    evidence = arguments.evidence_dir
    attestation = evidence / ATTESTATION
    if arguments.command == "build":
        document, raw = snapshot(evidence, arguments.spec,
                                 arguments.expected_sha)
        require(not attestation.exists(), "attestation already exists")
        atomic(attestation, raw)
        require(load_json(attestation, "device attestation")[0] == document,
                "published attestation differs")
    result = validate_attestation(attestation, arguments.spec,
                                  arguments.expected_sha)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AttestationError, CORE.ValidationError, OSError, ValueError,
            struct.error) as error:
        print(f"remaining-material-device-attestation: FAIL: {error}",
              file=sys.stderr)
        raise SystemExit(1)
