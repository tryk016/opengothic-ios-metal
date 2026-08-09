#!/usr/bin/env python3
"""Fail-closed validator for the grouped P2.1e1b physical-device gate."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import re
import shutil
import stat
import struct
import sys
import tempfile
import unicodedata
from typing import Any, Sequence


DEFAULT_SPEC = pathlib.Path(__file__).with_name("specs") / \
    "p21e1b-static-additive-group-v1.json"
PAIR_SPEC = pathlib.Path(__file__).with_name("specs") / \
    "p21e1b-static-additive-v1.json"
PAIR_VALIDATOR = pathlib.Path(__file__).with_name(
    "validate-additive-gpu-pair.py")
GPU_VALIDATOR = pathlib.Path(__file__).with_name(
    "validate-linear-hdr-gpu-evidence.py")
PERFORMANCE_VALIDATOR = pathlib.Path(__file__).with_name(
    "validate-additive-performance-trace.py")
SHA40_RE = re.compile(r"[0-9a-f]{40}\Z")
SHA64_RE = re.compile(r"[0-9a-f]{64}\Z")
RUN_ID_RE = re.compile(r"[0-9a-f]{32}\Z")
TEAM_RE = re.compile(r"[A-Z0-9]{10}\Z")
BUNDLE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,254}\Z")
UDID_RE = re.compile(r"[A-Fa-f0-9-]{8,64}\Z")
UUID_RE = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z")
SAFE_LEAF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}\Z")
MAX_EVIDENCE_BYTES = 1024 * 1024 * 1024
MAX_MANIFEST_BYTES = 256 * 1024 * 1024
TRACE_DOMAIN = b"opengothic-performance-trace-v1\0"
THERMAL_STATES = ("Nominal", "Fair", "Serious", "Critical")


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def canonical_json(value: Any) -> bytes:
    try:
        return (json.dumps(value, ensure_ascii=False, allow_nan=False,
                           separators=(",", ":")) + "\n").encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise ValidationError(f"value is not canonical JSON: {error}") from error


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        require(key not in value, f"duplicate JSON key: {key}")
        value[key] = child
    return value


def _constant(value: str) -> Any:
    raise ValidationError(f"non-finite JSON number: {value}")


def decode_json(raw: bytes, label: str) -> Any:
    require(not raw.startswith(b"\xef\xbb\xbf"), f"{label} has a BOM")
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs,
                          parse_constant=_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"{label} is not strict UTF-8 JSON: {error}") from error


def exact_keys(value: Any, keys: Sequence[str], label: str) -> dict[str, Any]:
    require(type(value) is dict and tuple(value.keys()) == tuple(keys),
            f"{label} keys/order are not exact")
    return value


def regular_bytes(path: pathlib.Path, label: str,
                  maximum: int = MAX_EVIDENCE_BYTES) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode), f"{label} is not regular")
        require(0 <= before.st_size <= maximum, f"{label} size is invalid")
        raw = bytearray()
        while len(raw) < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024,
                                            before.st_size - len(raw)))
            require(chunk != b"", f"{label} was truncated")
            raw.extend(chunk)
        require(os.read(descriptor, 1) == b"", f"{label} grew while reading")
        after = os.fstat(descriptor)
        require((before.st_dev, before.st_ino, before.st_size,
                 before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size,
                 after.st_mtime_ns), f"{label} changed while reading")
        after_path = path.lstat()
        require((before.st_dev, before.st_ino, before.st_mode, before.st_size,
                 before.st_mtime_ns) ==
                (after_path.st_dev, after_path.st_ino, after_path.st_mode,
                 after_path.st_size, after_path.st_mtime_ns),
                f"{label} path changed while reading")
        return bytes(raw)
    finally:
        os.close(descriptor)


def atomic_no_clobber(path: pathlib.Path, raw: bytes) -> None:
    require(path.is_absolute() and path.name not in ("", ".", ".."),
            "output path is not absolute/safe")
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY |
                        os.O_CLOEXEC | os.O_NOFOLLOW)
    temporary = f".{path.name}.{os.getpid()}.{os.urandom(8).hex()}.tmp"
    descriptor = -1
    linked = False
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             os.O_CLOEXEC | os.O_NOFOLLOW, 0o600,
                             dir_fd=directory)
        offset = 0
        while offset < len(raw):
            written = os.write(descriptor, raw[offset:])
            require(written > 0, "atomic write made no progress")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.link(temporary, path.name, src_dir_fd=directory,
                dst_dir_fd=directory, follow_symlinks=False)
        linked = True
        os.unlink(temporary, dir_fd=directory)
        os.fsync(directory)
    except FileExistsError as error:
        raise ValidationError(f"output already exists: {path.name}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if not linked:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
        os.close(directory)


def safe_leaf(value: Any, label: str) -> str:
    require(type(value) is str and SAFE_LEAF_RE.fullmatch(value) is not None,
            f"{label} is not a safe leaf")
    return value


def checked_meta(value: Any, root: pathlib.Path, label: str) -> tuple[dict[str, Any], bytes]:
    meta = exact_keys(value, ("file", "bytes", "sha256"), label)
    leaf = safe_leaf(meta["file"], f"{label}.file")
    require(type(meta["bytes"]) is int and 0 <= meta["bytes"] <= MAX_EVIDENCE_BYTES,
            f"{label}.bytes is invalid")
    require(type(meta["sha256"]) is str and
            SHA64_RE.fullmatch(meta["sha256"]) is not None,
            f"{label}.sha256 is invalid")
    raw = regular_bytes(root / leaf, label)
    require((len(raw), sha256(raw)) == (meta["bytes"], meta["sha256"]),
            f"{label} bytes/hash differs")
    return meta, raw


def load_module(path: pathlib.Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    require(specification is not None and specification.loader is not None,
            f"cannot load {path.name}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


def validate_spec(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    raw = regular_bytes(path, "group spec", 1024 * 1024)
    root = exact_keys(decode_json(raw, "group spec"), (
        "schemaVersion", "evidenceClass", "identities", "applications",
        "sequence", "performance", "integrity", "additivePair", "durableZero",
    ), "group spec")
    require(root["schemaVersion"] == 1 and type(root["schemaVersion"]) is int and
            root["evidenceClass"] == "renderer-ios-static-additive-device-group",
            "group spec root is not exact")
    identities = exact_keys(root["identities"], (
        "baseParentSha", "candidateParentSha", "tempestSha", "bundleId",
        "teamId"), "spec identities")
    require(identities == {
        "baseParentSha": "82c3d249dd15f15054a7e2feb3c3136c4d67a9c0",
        "candidateParentSha": "d90905ed7eca80130207825fee71910f11266911",
        "tempestSha": "308ec44c501c6ee86c153ba4acd63d44e39cf38d",
        "bundleId": "opengothic.gothic2.RMJWWPF379",
        "teamId": "RMJWWPF379",
    }, "group frozen identities differ")
    expected_apps = (
        ("base-off-performance", identities["baseParentSha"], "off", None),
        ("candidate-on", identities["candidateParentSha"], "on", None),
        ("candidate-off-performance", identities["candidateParentSha"], "off", None),
        ("additive-a", identities["candidateParentSha"], "additive-a-hdr",
         "-renderer-ios-additive-causal-mode=additive-a-hdr"),
        ("additive-b", identities["candidateParentSha"], "additive-b-hdr",
         "-renderer-ios-additive-causal-mode=additive-b-hdr"),
    )
    applications = root["applications"]
    require(type(applications) is list and len(applications) == 5,
            "group spec applications are not exact five")
    for value, expected in zip(applications, expected_apps):
        app = exact_keys(value, ("role", "parentSha", "profile", "launchArgument"),
                         "spec application")
        require(tuple(app.values()) == expected, "spec application differs")
    require(root["sequence"] == [item[0] for item in expected_apps],
            "group sequence is not exact")
    performance = exact_keys(root["performance"], (
        "summarySchema", "summaryLeaf", "commitLeaf",
        "evidenceDirectoryPattern", "template", "traceManifestDomain",
        "evidenceSetDomain", "xctraceMajorVersion",
        "modelerBoundaryToleranceNanoseconds",
        "tocDurationToleranceNanoseconds", "metricTableSchema",
        "metricNameColumn", "metricVariantColumn", "frameCountColumn",
        "processIdColumn", "frameIntervalMetricName", "gpuActiveMetricName",
        "valueMillisecondsColumn", "thermalTableSchema", "thermalStateColumn",
        "saveSlot", "fpsLimit", "settleSeconds", "minimumTraceSeconds",
        "minimumMeanFpsAbsolute", "minimumMeanFpsRatio",
        "maximumMeanGpuActiveMilliseconds", "maximumMeanGpuActiveRatio",
        "forbiddenThermalStates"), "performance spec")
    require(performance == {
        "summarySchema": "performance-trace-summary-v1",
        "summaryLeaf": "performance-trace-summary-v1.json",
        "commitLeaf": "performance-evidence-commit-v1.json",
        "evidenceDirectoryPattern": "performance-evidence-<role>-<runId>",
        "template": "Game Performance Overview",
        "traceManifestDomain": "opengothic-performance-trace-v1\0",
        "evidenceSetDomain": "opengothic-performance-evidence-set-v1\0",
        "xctraceMajorVersion": 27,
        "modelerBoundaryToleranceNanoseconds": 50,
        "tocDurationToleranceNanoseconds": 1000,
        "metricTableSchema": "metal-perf-overview-layer-duration-metric",
        "metricNameColumn": "name", "metricVariantColumn": "metric-variant",
        "frameCountColumn": "number-of-frames", "processIdColumn": "process",
        "frameIntervalMetricName": "0.Frame Interval",
        "gpuActiveMetricName": "4.GPU Active Time",
        "valueMillisecondsColumn": "value-in-ms",
        "thermalTableSchema": "device-thermal-state-intervals",
        "thermalStateColumn": "thermal-state", "saveSlot": 4, "fpsLimit": 30,
        "settleSeconds": 12, "minimumTraceSeconds": 30,
        "minimumMeanFpsAbsolute": 27.0, "minimumMeanFpsRatio": 0.9,
        "maximumMeanGpuActiveMilliseconds": 33.34,
        "maximumMeanGpuActiveRatio": 1.2,
        "forbiddenThermalStates": ["Serious", "Critical"],
    }, "performance contract differs from D-084/Xcode-27 freeze")
    integrity = exact_keys(root["integrity"], (
        "launchArgument", "terminal", "resourceManifestLeaf",
        "protectedSaveManifestLeaf", "recoveryJournalLeaf", "roots", "excluded",
        "protectedSlots", "maximumFiles", "maximumFileBytes",
        "maximumTotalBytes"), "integrity spec")
    require(integrity == {
        "launchArgument": "-renderer-ios-device-integrity-manifest-v1",
        "terminal": "RendererIOS device integrity manifest: schema=1 resources=resource-manifest-v1.jsonl saves=protected-save-manifest-v1.jsonl result=PASS terminal=C",
        "resourceManifestLeaf": "resource-manifest-v1.jsonl",
        "protectedSaveManifestLeaf": "protected-save-manifest-v1.jsonl",
        "recoveryJournalLeaf": "device-integrity-recovery-journal-v1.json",
        "roots": ["Data", "_work/Data", "system"],
        "excluded": ["system/Gothic.ini"], "protectedSlots": [1, 2, 3, 4],
        "maximumFiles": 100000, "maximumFileBytes": 8589934592,
        "maximumTotalBytes": 17179869184,
    }, "integrity contract differs from D-084")
    pair = exact_keys(root["additivePair"], (
        "specLeaf", "attestationLeaf", "captureIdentityPattern",
        "linearHdrAdapter", "saveSlot"), "additive pair spec")
    require(pair == {
        "specLeaf": "p21e1b-static-additive-v1.json",
        "attestationLeaf": "additive-gpu-pair-attestation-v1.json",
        "captureIdentityPattern": "capture-identity-<a|b>.json",
        "linearHdrAdapter": "run-linear-hdr-proof-test.sh", "saveSlot": 4,
    }, "additive pair grouped contract differs")
    zero = exact_keys(root["durableZero"], (
        "requiredAfterEveryRun", "minimumScans", "minimumStableSeconds",
        "maximumRespawns", "maximumQueryFailures", "requiredFinalZero",
        "guardState"), "durable ZERO spec")
    require(zero == {"requiredAfterEveryRun": True, "minimumScans": 10,
                     "minimumStableSeconds": 90, "maximumRespawns": 0,
                     "maximumQueryFailures": 0, "requiredFinalZero": 1,
                     "guardState": "ZERO"}, "durable ZERO contract differs")
    return root, raw


def _canonical_line(value: Any) -> bytes:
    return canonical_json(value)[:-1]


def validate_resource_manifest(raw: bytes, spec: dict[str, Any], label: str) -> None:
    require(0 < len(raw) <= MAX_MANIFEST_BYTES and raw.endswith(b"\n") and
            b"\r" not in raw and not raw.startswith(b"\xef\xbb\xbf"),
            f"{label} framing is invalid")
    lines = raw[:-1].split(b"\n")
    require(lines and lines[0] != b"", f"{label} is empty")
    values = [decode_json(line, f"{label} line {index + 1}")
              for index, line in enumerate(lines)]
    require(all(line == _canonical_line(value)
                for line, value in zip(lines, values)),
            f"{label} contains noncanonical JSONL")
    header = exact_keys(values[0],
                        ("schemaVersion", "roots", "excluded", "fileCount",
                         "totalBytes"), f"{label} header")
    records = values[1:]
    contract = spec["integrity"]
    require(header["schemaVersion"] == 1 and
            type(header["schemaVersion"]) is int and
            header["roots"] == contract["roots"] and
            header["excluded"] == contract["excluded"] and
            type(header["fileCount"]) is int and
            header["fileCount"] == len(records) <= contract["maximumFiles"] and
            type(header["totalBytes"]) is int and
            0 <= header["totalBytes"] <= contract["maximumTotalBytes"],
            f"{label} header differs")
    paths: list[bytes] = []
    total = 0
    for index, value in enumerate(records):
        record = exact_keys(value, ("relativePath", "byteSize", "sha256"),
                            f"{label} record {index}")
        path = record["relativePath"]
        require(type(path) is str and path == unicodedata.normalize("NFC", path) and
                path and not path.startswith("/") and "\\" not in path and
                all(component not in ("", ".", "..")
                    for component in path.split("/")) and
                not any(ord(character) < 32 or ord(character) == 127
                        for character in path), f"{label} path is invalid")
        require(any(path == root or path.startswith(root + "/")
                    for root in contract["roots"]) and
                path not in contract["excluded"],
                f"{label} path escapes roots/exclusion")
        encoded = path.encode("utf-8")
        require(not paths or paths[-1] < encoded,
                f"{label} paths are duplicate or not UTF-8 byte sorted")
        paths.append(encoded)
        size = record["byteSize"]
        require(type(size) is int and 0 <= size <= contract["maximumFileBytes"],
                f"{label} record size is invalid")
        require(type(record["sha256"]) is str and
                SHA64_RE.fullmatch(record["sha256"]) is not None,
                f"{label} record hash is invalid")
        total += size
        require(total <= contract["maximumTotalBytes"],
                f"{label} checked total overflow/limit")
    require(total == header["totalBytes"], f"{label} totalBytes differs")


def validate_save_manifest(raw: bytes, spec: dict[str, Any], label: str) -> None:
    require(raw.endswith(b"\n") and b"\r" not in raw and
            0 < len(raw) <= 1024 * 1024, f"{label} framing is invalid")
    lines = raw[:-1].split(b"\n")
    values = [decode_json(line, f"{label} line {index + 1}")
              for index, line in enumerate(lines)]
    require(all(line == _canonical_line(value)
                for line, value in zip(lines, values)),
            f"{label} contains noncanonical JSONL")
    header = exact_keys(values[0],
                        ("schemaVersion", "protectedSlots", "fileCount",
                         "totalBytes"), f"{label} header")
    slots = spec["integrity"]["protectedSlots"]
    require(header["schemaVersion"] == 1 and
            type(header["schemaVersion"]) is int and
            type(header["protectedSlots"]) is list and
            all(type(slot) is int for slot in header["protectedSlots"]) and
            header["protectedSlots"] == slots and
            header["fileCount"] == 4 and type(header["fileCount"]) is int and
            type(header["totalBytes"]) is int and header["totalBytes"] >= 0 and
            len(values) == 5, f"{label} header/count differs")
    total = 0
    for value, slot in zip(values[1:], slots):
        record = exact_keys(value, ("slot", "fileName", "byteSize", "sha256"),
                            f"{label} slot {slot}")
        require(record["slot"] == slot and type(record["slot"]) is int and
                record["fileName"] == f"save_slot_{slot}.sav" and
                type(record["byteSize"]) is int and record["byteSize"] >= 0 and
                type(record["sha256"]) is str and
                SHA64_RE.fullmatch(record["sha256"]) is not None,
                f"{label} slot {slot} differs")
        total += record["byteSize"]
        require(total <= spec["integrity"]["maximumTotalBytes"],
                f"{label} checked total exceeds limit")
    require(total == header["totalBytes"], f"{label} totalBytes differs")


def trace_manifest(path: pathlib.Path) -> tuple[int, int, str]:
    root = path.lstat()
    require(stat.S_ISDIR(root.st_mode) and not stat.S_ISLNK(root.st_mode),
            "performance trace is not an lstat-directory")
    entries: list[tuple[bytes, int, bytes]] = []
    for directory, names, files in os.walk(path, followlinks=False):
        for name in names:
            child = pathlib.Path(directory) / name
            metadata = child.lstat()
            require(stat.S_ISDIR(metadata.st_mode) and
                    not stat.S_ISLNK(metadata.st_mode),
                    "performance trace contains a symlink/special directory")
            relative_directory = child.relative_to(path).as_posix()
            require(relative_directory ==
                    unicodedata.normalize("NFC", relative_directory) and
                    "\\" not in relative_directory and
                    all(component not in ("", ".", "..")
                        for component in relative_directory.split("/")) and
                    not any(ord(character) < 32 or ord(character) == 127
                            for character in relative_directory),
                    "performance trace directory path is not canonical")
        for name in files:
            child = pathlib.Path(directory) / name
            relative = child.relative_to(path).as_posix()
            require(relative == unicodedata.normalize("NFC", relative) and
                    relative and "\\" not in relative and
                    all(component not in ("", ".", "..")
                        for component in relative.split("/")) and
                    not any(ord(character) < 32 or ord(character) == 127
                            for character in relative),
                    "performance trace relative path is not canonical")
            raw = regular_bytes(child, "performance trace member")
            entries.append((relative.encode("utf-8"), len(raw),
                            bytes.fromhex(sha256(raw))))
    entries.sort(key=lambda item: item[0])
    require(0 < len(entries) <= 100000 and
            len({item[0] for item in entries}) == len(entries),
            "performance trace is empty/duplicate/unbounded")
    total = 0
    digest = hashlib.sha256()
    digest.update(TRACE_DOMAIN)
    for relative, size, member_hash in entries:
        require(len(relative) <= 0xFFFFFFFF,
                "performance trace path is too long")
        total += size
        require(total <= 17179869184, "performance trace is larger than 16 GiB")
        digest.update(struct.pack("<I", len(relative)))
        digest.update(relative)
        digest.update(struct.pack("<Q", size))
        digest.update(member_hash)
    require(total > 0, "performance trace has no payload bytes")
    after_root = path.lstat()
    require((root.st_dev, root.st_ino, root.st_mode, root.st_size,
             root.st_mtime_ns) ==
            (after_root.st_dev, after_root.st_ino, after_root.st_mode,
             after_root.st_size, after_root.st_mtime_ns),
            "performance trace root changed while hashing")
    return len(entries), total, digest.hexdigest()


def validate_performance_evidence(directory: pathlib.Path,
                                  spec: dict[str, Any], expected_role: str,
                                  identity: dict[str, Any], *,
                                  verify_semantics: bool) -> dict[str, Any]:
    before = directory.lstat()
    require(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode),
            f"{expected_role} performance evidence is not a directory")
    contract = spec["performance"]
    raw = regular_bytes(directory / contract["summaryLeaf"],
                        f"{expected_role} performance summary")
    document = decode_json(raw, f"{expected_role} performance summary")
    require(raw == canonical_json(document),
            f"{expected_role} performance summary is not canonical")
    summary = exact_keys(document, (
        "schemaVersion", "evidenceClass", "role", "identity", "settings",
        "source", "metrics", "terminal"), "performance summary")
    require(summary["schemaVersion"] == 1 and
            type(summary["schemaVersion"]) is int and
            summary["evidenceClass"] == "renderer-ios-performance-trace-summary" and
            summary["role"] == expected_role and
            summary["terminal"] == "PERFORMANCE PASS",
            "performance summary root differs")
    run_identity = exact_keys(summary["identity"], (
        "runId", "parentSha", "tempestSha", "bundleId", "teamId",
        "deviceUdid", "processId"), "performance identity")
    require(type(run_identity["runId"]) is str and
            RUN_ID_RE.fullmatch(run_identity["runId"]) is not None and
            run_identity["parentSha"] == identity["parentSha"] and
            run_identity["tempestSha"] == identity["tempestSha"] and
            run_identity["bundleId"] == identity["bundleId"] and
            run_identity["teamId"] == identity["teamId"] and
            run_identity["deviceUdid"] == identity["deviceUdid"] and
            type(run_identity["processId"]) is int and
            run_identity["processId"] > 0,
            "performance identity differs")
    settings = exact_keys(summary["settings"],
                          ("saveSlot", "fpsLimit", "settleSeconds",
                           "traceSeconds",
                           "modelerBoundaryToleranceNanoseconds"),
                          "performance settings")
    require(settings["saveSlot"] == contract["saveSlot"] and
            type(settings["saveSlot"]) is int and
            settings["fpsLimit"] == contract["fpsLimit"] and
            type(settings["fpsLimit"]) is int and
            settings["settleSeconds"] == contract["settleSeconds"] and
            type(settings["settleSeconds"]) is int and
            type(settings["traceSeconds"]) in (int, float) and
            not isinstance(settings["traceSeconds"], bool) and
            math.isfinite(settings["traceSeconds"]) and
            settings["traceSeconds"] >= contract["minimumTraceSeconds"] and
            settings["modelerBoundaryToleranceNanoseconds"] ==
            contract["modelerBoundaryToleranceNanoseconds"] and
            type(settings["modelerBoundaryToleranceNanoseconds"]) is int,
            "performance settings/trace duration differ")
    source = exact_keys(summary["source"], (
        "tool", "toolVersion", "toolBuild", "template",
        "evidenceDirectory", "traceLeaf", "traceKind", "traceFiles",
        "traceBytes", "traceManifestSha256", "tocFile", "tocBytes",
        "tocSha256", "metricsExportFile", "metricsExportBytes",
        "metricsExportSha256", "thermalExportFile", "thermalExportBytes",
        "thermalExportSha256", "commitFile", "metricTableSchema", "metricNameColumn",
        "metricVariantColumn", "frameCountColumn", "processIdColumn",
        "frameIntervalMetricName", "gpuActiveMetricName",
        "valueMillisecondsColumn", "thermalTableSchema", "thermalStateColumn",
    ), "performance source")
    require(source["tool"] == "/usr/bin/xctrace" and
            type(source["toolVersion"]) is str and
            re.fullmatch(r"27\.[0-9]+(?:\.[0-9]+)?", source["toolVersion"]) is not None and
            type(source["toolBuild"]) is str and
            re.fullmatch(r"[0-9]+[A-Za-z][A-Za-z0-9]+", source["toolBuild"]) is not None and
            source["template"] == contract["template"] and
            source["evidenceDirectory"] == directory.name ==
            f"performance-evidence-{expected_role}-{run_identity['runId']}" and
            source["traceKind"] == "directory" and
            source["commitFile"] == contract["commitLeaf"] and
            source["metricTableSchema"] == contract["metricTableSchema"] and
            source["metricNameColumn"] == contract["metricNameColumn"] and
            source["metricVariantColumn"] == contract["metricVariantColumn"] and
            source["frameCountColumn"] == contract["frameCountColumn"] and
            source["processIdColumn"] == contract["processIdColumn"] and
            source["frameIntervalMetricName"] ==
            contract["frameIntervalMetricName"] and
            source["gpuActiveMetricName"] == contract["gpuActiveMetricName"] and
            source["valueMillisecondsColumn"] ==
            contract["valueMillisecondsColumn"] and
            source["thermalTableSchema"] == contract["thermalTableSchema"] and
            source["thermalStateColumn"] == contract["thermalStateColumn"],
            "performance Xcode-27 source contract differs")
    trace_leaf = safe_leaf(source["traceLeaf"], "performance trace leaf")
    require(trace_leaf.endswith(".trace"), "performance trace leaf lacks .trace")
    require(type(source["traceFiles"]) is int and source["traceFiles"] > 0 and
            type(source["traceBytes"]) is int and source["traceBytes"] > 0 and
            type(source["traceManifestSha256"]) is str and
            SHA64_RE.fullmatch(source["traceManifestSha256"]) is not None,
            "performance trace metadata is invalid")
    for prefix in ("toc", "metricsExport", "thermalExport"):
        leaf = safe_leaf(source[prefix + "File"], f"performance {prefix} file")
        expected_bytes = source[prefix + "Bytes"]
        expected_hash = source[prefix + "Sha256"]
        require(type(expected_bytes) is int and expected_bytes > 0 and
                type(expected_hash) is str and
                SHA64_RE.fullmatch(expected_hash) is not None,
                f"performance {prefix} metadata is invalid")
    metrics = exact_keys(summary["metrics"], (
        "fpsSampleCount", "gpuActiveSampleCount", "tocDurationSeconds",
        "metricWindowSeconds", "thermalWindowSeconds",
        "maximumMetricBoundaryGapNanoseconds",
        "maximumThermalBoundaryGapNanoseconds", "meanFps",
        "meanGpuActiveMilliseconds", "thermalStates"), "performance metrics")
    require(type(metrics["fpsSampleCount"]) is int and
            metrics["fpsSampleCount"] > 0 and
            type(metrics["gpuActiveSampleCount"]) is int and
            metrics["gpuActiveSampleCount"] == metrics["fpsSampleCount"],
            "performance metric sample domains differ")
    for key in ("tocDurationSeconds", "metricWindowSeconds",
                "thermalWindowSeconds", "meanFps", "meanGpuActiveMilliseconds"):
        require(type(metrics[key]) in (int, float) and
                not isinstance(metrics[key], bool) and math.isfinite(metrics[key]),
                f"performance {key} is not finite")
    for key in ("maximumMetricBoundaryGapNanoseconds",
                "maximumThermalBoundaryGapNanoseconds"):
        require(type(metrics[key]) is int and
                0 <= metrics[key] <= contract["modelerBoundaryToleranceNanoseconds"],
                f"performance {key} exceeds continuous-coverage tolerance")
    tolerance_seconds = contract["modelerBoundaryToleranceNanoseconds"] / 1e9
    toc_tolerance_seconds = contract["tocDurationToleranceNanoseconds"] / 1e9
    require(metrics["tocDurationSeconds"] >= contract["minimumTraceSeconds"] and
            metrics["metricWindowSeconds"] >= contract["minimumTraceSeconds"] and
            metrics["thermalWindowSeconds"] + tolerance_seconds >=
            metrics["metricWindowSeconds"] and
            metrics["metricWindowSeconds"] <=
            metrics["tocDurationSeconds"] + toc_tolerance_seconds and
            metrics["thermalWindowSeconds"] <=
            metrics["tocDurationSeconds"] + toc_tolerance_seconds and
            metrics["meanFps"] > 0 and
            metrics["meanGpuActiveMilliseconds"] > 0,
            "performance metric windows/units are invalid")
    thermal = metrics["thermalStates"]
    require(type(thermal) is list and thermal and
            all(type(value) is str and value in THERMAL_STATES
                for value in thermal) and len(thermal) == len(set(thermal)),
            "performance thermal states are invalid")
    require(not any(value in contract["forbiddenThermalStates"]
                    for value in thermal),
            "performance trace observed forbidden thermal state")

    expected_members = {
        trace_leaf, source["tocFile"], source["metricsExportFile"],
        source["thermalExportFile"], contract["summaryLeaf"],
        contract["commitLeaf"],
    }
    entries = list(os.scandir(directory))
    require(len(entries) == 6 and {entry.name for entry in entries} == expected_members,
            "performance evidence directory member set is not exact")
    for entry in entries:
        metadata = entry.stat(follow_symlinks=False)
        if entry.name == trace_leaf:
            require(stat.S_ISDIR(metadata.st_mode) and not entry.is_symlink(),
                    "performance trace member is not a real directory")
        else:
            require(stat.S_ISREG(metadata.st_mode) and not entry.is_symlink(),
                    "performance evidence member is not regular")

    performance_module = load_module(
        PERFORMANCE_VALIDATOR, "performance_for_additive_group")
    if verify_semantics:
        rebuilt = performance_module.validate_evidence_directory(
            directory, expected_role, run_identity, settings)
        require(performance_module.canonical_json(rebuilt) == raw,
                "performance summary differs from exact raw trace revalidation")
    else:
        trace_files, trace_bytes, trace_hash = trace_manifest(directory / trace_leaf)
        require((source["traceFiles"], source["traceBytes"],
                 source["traceManifestSha256"]) ==
                (trace_files, trace_bytes, trace_hash),
                "performance trace manifest identity differs")
        for prefix in ("toc", "metricsExport", "thermalExport"):
            payload = regular_bytes(directory / source[prefix + "File"],
                                    f"performance {prefix}")
            require((len(payload), sha256(payload)) ==
                    (source[prefix + "Bytes"], source[prefix + "Sha256"]),
                    f"performance {prefix} bytes/hash differs")
    commit_raw = regular_bytes(directory / contract["commitLeaf"],
                               f"{expected_role} performance commit",
                               1024 * 1024)
    expected_commit = performance_module.build_commit(summary, raw)
    require(commit_raw == performance_module.canonical_json(expected_commit),
            "performance evidence commit/set hash differs")
    after = directory.lstat()
    require((before.st_dev, before.st_ino, before.st_mode, before.st_size,
             before.st_mtime_ns, before.st_ctime_ns) ==
            (after.st_dev, after.st_ino, after.st_mode, after.st_size,
             after.st_mtime_ns, after.st_ctime_ns),
            "performance evidence directory changed during validation")
    return summary


def parse_result(raw: bytes, label: str) -> dict[str, str]:
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValidationError(f"{label} is not UTF-8") from error
    values: dict[str, str] = {}
    for line in lines:
        require(line.count("=") == 1, f"{label} contains malformed line")
        key, value = line.split("=", 1)
        require(key and key not in values, f"{label} has duplicate/empty key")
        values[key] = value
    return values


def validate_zero(value: Any, spec: dict[str, Any], label: str) -> None:
    zero = exact_keys(value, (
        "deviceProcessStopped", "scansCompleted", "stableSeconds",
        "respawnsDetected", "queryFailures", "finalZero", "guardState"), label)
    contract = spec["durableZero"]
    require(all(type(zero[key]) is int for key in (
                "deviceProcessStopped", "scansCompleted", "stableSeconds",
                "respawnsDetected", "queryFailures", "finalZero")) and
            zero["deviceProcessStopped"] == 1 and
            zero["scansCompleted"] >= contract["minimumScans"] and
            zero["stableSeconds"] >= contract["minimumStableSeconds"] and
            zero["respawnsDetected"] == contract["maximumRespawns"] and
            zero["queryFailures"] == contract["maximumQueryFailures"] and
            zero["finalZero"] == contract["requiredFinalZero"] and
            zero["guardState"] == contract["guardState"],
            f"{label} is not durable ZERO")


def validate_run_summary(raw: bytes, root: pathlib.Path, spec: dict[str, Any],
                         application: dict[str, Any], identity: dict[str, Any],
                         label: str) -> dict[str, Any]:
    document = decode_json(raw, label)
    require(raw == canonical_json(document), f"{label} is not canonical")
    summary = exact_keys(document, (
        "schemaVersion", "evidenceClass", "role", "parentSha", "profile",
        "launchArgument", "bundleId", "teamId", "signedExecutableSha256",
        "metallibSha256", "adapterResult", "runtimeLog", "crashFatal", "zero",
    ), label)
    require(summary["schemaVersion"] == 1 and
            type(summary["schemaVersion"]) is int and
            summary["evidenceClass"] == "renderer-ios-device-run-summary" and
            (summary["role"], summary["parentSha"], summary["profile"],
             summary["launchArgument"]) ==
            (application["role"], application["parentSha"],
             application["profile"], application["launchArgument"]) and
            summary["bundleId"] == identity["bundleId"] and
            summary["teamId"] == identity["teamId"] and
            type(summary["signedExecutableSha256"]) is str and
            SHA64_RE.fullmatch(summary["signedExecutableSha256"]) is not None and
            type(summary["metallibSha256"]) is str and
            SHA64_RE.fullmatch(summary["metallibSha256"]) is not None,
            f"{label} identity/profile differs")
    _, result_raw = checked_meta(summary["adapterResult"], root,
                                 f"{label} adapter result")
    _, log_raw = checked_meta(summary["runtimeLog"], root,
                              f"{label} runtime log")
    result = parse_result(result_raw, f"{label} adapter result")
    required = {
        "result": "PASS", "source_sha": application["parentSha"],
        "signed_executable_sha256": summary["signedExecutableSha256"],
        "bundle_id": identity["bundleId"], "save_slot": "4",
        "metallib_sha256": summary["metallibSha256"],
        "device_process_stopped": "1", "durable_zero_stable": "1",
        "durable_zero_final_zero": "1",
    }
    require(all(result.get(key) == expected for key, expected in required.items()),
            f"{label} adapter result differs")
    require(result.get("log_sha256") == sha256(log_raw),
            f"{label} runtime log does not join adapter result")
    crash = exact_keys(summary["crashFatal"],
                       ("beforeSha256", "afterSha256", "fatalCount"),
                       f"{label} crash/fatal")
    require(type(crash["beforeSha256"]) is str and
            SHA64_RE.fullmatch(crash["beforeSha256"]) is not None and
            crash["afterSha256"] == crash["beforeSha256"] and
            crash["fatalCount"] == 0 and type(crash["fatalCount"]) is int and
            result.get("pre_crash_sha256") == crash["beforeSha256"] and
            result.get("post_crash_sha256") == crash["afterSha256"] and
            b" terminal=F" not in log_raw,
            f"{label} crash/fatal evidence differs")
    validate_zero(summary["zero"], spec, f"{label} zero")
    zero = summary["zero"]
    require(result.get("durable_zero_scans_completed") == str(zero["scansCompleted"]) and
            result.get("durable_zero_stable_seconds") == str(zero["stableSeconds"]) and
            result.get("durable_zero_respawns_detected") == str(zero["respawnsDetected"]) and
            result.get("durable_zero_query_failures") == str(zero["queryFailures"]),
            f"{label} durable ZERO does not join adapter result")
    return summary


def _profile_markers(raw: bytes, profile: str, parent_sha: str, label: str) -> None:
    require(raw.count(parent_sha.encode("ascii")) == 1,
            f"{label} lacks exactly one parent SHA marker")
    on = b"RendererIOS diagnostics: ON frames-in-flight="
    off = b"RendererIOS diagnostics: OFF\0"
    if profile == "off":
        require(raw.count(off) == 1 and raw.count(on) == 0,
                f"{label} is not the exact OFF binary profile")
    else:
        require(raw.count(on) == 1 and raw.count(off) == 0,
                f"{label} is not an exact diagnostics-ON binary profile")
    for mode in ("additive-a-hdr", "additive-b-hdr"):
        marker = f"RIOS_ADDITIVE_CAUSAL_MODE={mode}\0".encode("ascii")
        expected = 1 if profile == mode else 0
        require(raw.count(marker) == expected,
                f"{label} additive causal marker differs")


def validate_integrity_boundary_summary(
        raw: bytes, root: pathlib.Path, spec: dict[str, Any], role: str,
        identity: dict[str, Any], candidate_app: dict[str, Any]) -> dict[str, Any]:
    application = {
        "role": role, "parentSha": identity["candidateParentSha"],
        "profile": "on", "launchArgument": spec["integrity"]["launchArgument"],
    }
    summary = validate_run_summary(raw, root, spec, application, identity,
                                   f"{role} summary")
    require(summary["signedExecutableSha256"] ==
            candidate_app["signedMachO"]["sha256"] and
            summary["metallibSha256"] == candidate_app["metallib"]["sha256"],
            f"{role} did not use the exact candidate ON app")
    _, log_raw = checked_meta(summary["runtimeLog"], root, f"{role} runtime log")
    terminal = spec["integrity"]["terminal"].encode("ascii")
    require(log_raw.splitlines().count(terminal) == 1,
            f"{role} lacks the exact integrity terminal")
    return summary


def _derived_capture(gpu_raw: bytes) -> tuple[dict[str, Any], dict[str, Any]]:
    module = load_module(GPU_VALIDATOR, "gpu_for_additive_group")
    try:
        document = json.loads(gpu_raw.decode("utf-8"),
                              object_pairs_hook=module.unique_object,
                              parse_constant=module.reject_constant)
        require(gpu_raw == module.canonical_json_bytes(document),
                "GPU evidence is not canonical")
        root = module.validate_document(document)
    except (UnicodeDecodeError, json.JSONDecodeError, OSError, RuntimeError,
            ValueError) as error:
        raise ValidationError(f"canonical GPU evidence is invalid: {error}") from error
    identity = root["runIdentity"]
    resource = root["sceneResource"]
    command = root["command"]
    require(command["scene"]["attachment"] == "color0" and
            command["proofBlit"]["sourceTextureRef"] == resource["textureRef"] and
            command["toneResolve"]["fragmentTextureIndex"] == 0 and
            command["toneResolve"]["textureRef"] == resource["textureRef"],
            "GPU evidence resource join differs")
    native = {key: resource[key]
              for key in ("textureRef", "allocationID", "resourceIndex")}
    capture = {
        "schemaVersion": 1,
        "acceptedSnapshot": {
            "targetGeneration": identity["targetGeneration"],
            "snapshotSequence": identity["snapshotSequence"],
        },
        "sceneResource": {"label": resource["label"], **native},
        "commands": [
            {"role": role, **native}
            for role in ("attachment", "proof-blit-source",
                         "tone-resolve-texture0")
        ],
    }
    return identity, capture


def validate_recovery_journal(raw: bytes, identity: dict[str, Any],
                              integrity: dict[str, Any]) -> None:
    document = decode_json(raw, "recovery journal evidence")
    require(raw == canonical_json(document), "recovery journal is not canonical")
    journal = exact_keys(document, (
        "schemaVersion", "deviceUdid", "bundleId", "teamId", "parentSha",
        "oldContainerUuid", "newContainerUuid", "masterResourceManifestSha256",
        "preResourceManifestSha256", "postResourceManifestSha256",
        "preProtectedSaveManifestSha256", "postProtectedSaveManifestSha256",
        "state"), "recovery journal")
    require(journal["schemaVersion"] == 1 and
            type(journal["schemaVersion"]) is int and
            journal["deviceUdid"] == identity["deviceUdid"] and
            journal["bundleId"] == identity["bundleId"] and
            journal["teamId"] == identity["teamId"] and
            journal["parentSha"] == identity["candidateParentSha"] and
            type(journal["oldContainerUuid"]) is str and
            UUID_RE.fullmatch(journal["oldContainerUuid"]) is not None and
            type(journal["newContainerUuid"]) is str and
            UUID_RE.fullmatch(journal["newContainerUuid"]) is not None and
            journal["masterResourceManifestSha256"] ==
            integrity["masterResourceManifest"]["sha256"] and
            journal["preResourceManifestSha256"] ==
            integrity["preResourceManifest"]["sha256"] and
            journal["postResourceManifestSha256"] ==
            integrity["postResourceManifest"]["sha256"] and
            journal["preProtectedSaveManifestSha256"] ==
            integrity["preProtectedSaveManifest"]["sha256"] and
            journal["postProtectedSaveManifestSha256"] ==
            integrity["postProtectedSaveManifest"]["sha256"] and
            journal["state"] == "released",
            "recovery journal identity/state differs")


def validate_group(spec_path: pathlib.Path, attestation_path: pathlib.Path,
                   evidence_root: pathlib.Path, *,
                   verify_external_tools: bool = True) -> dict[str, Any]:
    root_metadata = evidence_root.lstat()
    require(stat.S_ISDIR(root_metadata.st_mode) and
            not stat.S_ISLNK(root_metadata.st_mode),
            "group evidence root is not an lstat-directory")
    spec, spec_raw = validate_spec(spec_path)
    raw = regular_bytes(attestation_path, "group attestation", 16 * 1024 * 1024)
    document = decode_json(raw, "group attestation")
    require(raw == canonical_json(document), "group attestation is not canonical")
    attestation = exact_keys(document, (
        "schemaVersion", "evidenceClass", "specSha256", "identity", "integrity",
        "runs", "additivePair", "recoveryJournal"), "group attestation")
    require(attestation["schemaVersion"] == 1 and
            type(attestation["schemaVersion"]) is int and
            attestation["evidenceClass"] == spec["evidenceClass"] and
            attestation["specSha256"] == sha256(spec_raw),
            "group attestation root/spec differs")
    identity = exact_keys(attestation["identity"], (
        "deviceUdid", "bundleId", "teamId", "baseParentSha",
        "candidateParentSha", "tempestSha"), "group identity")
    frozen = spec["identities"]
    require(type(identity["deviceUdid"]) is str and
            UDID_RE.fullmatch(identity["deviceUdid"]) is not None and
            identity == {"deviceUdid": identity["deviceUdid"],
                         "bundleId": frozen["bundleId"],
                         "teamId": frozen["teamId"],
                         "baseParentSha": frozen["baseParentSha"],
                         "candidateParentSha": frozen["candidateParentSha"],
                         "tempestSha": frozen["tempestSha"]},
            "group identity differs from frozen identities")
    common_identity = {"bundleId": identity["bundleId"],
                       "teamId": identity["teamId"],
                       "tempestSha": identity["tempestSha"],
                       "deviceUdid": identity["deviceUdid"]}

    integrity = exact_keys(attestation["integrity"], (
        "masterResourceManifest", "preResourceManifest", "postResourceManifest",
        "preProtectedSaveManifest", "postProtectedSaveManifest",
        "preRunSummary", "postRunSummary"), "group integrity")
    _, master_resource = checked_meta(
        integrity["masterResourceManifest"], evidence_root,
        "master resource manifest")
    _, pre_resource = checked_meta(integrity["preResourceManifest"], evidence_root,
                                   "pre resource manifest")
    _, post_resource = checked_meta(integrity["postResourceManifest"], evidence_root,
                                    "post resource manifest")
    _, pre_saves = checked_meta(integrity["preProtectedSaveManifest"], evidence_root,
                                "pre protected save manifest")
    _, post_saves = checked_meta(integrity["postProtectedSaveManifest"], evidence_root,
                                 "post protected save manifest")
    for manifest_raw, label in ((master_resource, "master resource manifest"),
                                (pre_resource, "pre resource manifest"),
                                (post_resource, "post resource manifest")):
        validate_resource_manifest(manifest_raw, spec, label)
    for manifest_raw, label in ((pre_saves, "pre protected save manifest"),
                                (post_saves, "post protected save manifest")):
        validate_save_manifest(manifest_raw, spec, label)
    require(master_resource == pre_resource == post_resource,
            "master/pre/post resource manifests are not byte-identical")
    require(pre_saves == post_saves,
            "pre/post protected save manifests are not byte-identical")

    runs = attestation["runs"]
    require(type(runs) is list and len(runs) == 5, "group must contain exact five runs")
    authenticated_runs: list[dict[str, Any]] = []
    pair_module = load_module(PAIR_VALIDATOR, "pair_for_additive_group")
    for index, application in enumerate(spec["applications"]):
        run = exact_keys(runs[index], (
            "role", "summary", "app", "performanceEvidence", "gpuEvidence",
            "captureIdentity"), f"group run {index}")
        require(run["role"] == application["role"],
                "group run order/role differs")
        _, summary_raw = checked_meta(run["summary"], evidence_root,
                                      f"{run['role']} summary")
        summary = validate_run_summary(
            summary_raw, evidence_root, spec, application,
            {**common_identity, "parentSha": application["parentSha"]},
            f"{run['role']} summary")
        app = exact_keys(run["app"], ("signedMachO", "metallib"),
                         f"{run['role']} app")
        macho_meta, macho_raw = checked_meta(
            app["signedMachO"], evidence_root, f"{run['role']} signed Mach-O")
        metallib_meta, _ = checked_meta(
            app["metallib"], evidence_root, f"{run['role']} metallib")
        require(summary["signedExecutableSha256"] == macho_meta["sha256"] and
                summary["metallibSha256"] == metallib_meta["sha256"],
                f"{run['role']} app does not join run summary")
        _profile_markers(macho_raw, application["profile"],
                         application["parentSha"], run["role"])
        if verify_external_tools:
            pair_module.verify_codesign(macho_raw, {
                "bundleId": identity["bundleId"], "teamId": identity["teamId"]})
        performance = None
        if run["role"] in ("base-off-performance", "candidate-off-performance"):
            performance_reference = exact_keys(
                run["performanceEvidence"], ("directory",),
                f"{run['role']} performance evidence reference")
            performance_directory = safe_leaf(
                performance_reference["directory"],
                f"{run['role']} performance evidence directory")
            performance = validate_performance_evidence(
                evidence_root / performance_directory, spec, run["role"],
                {**common_identity, "parentSha": application["parentSha"]},
                verify_semantics=verify_external_tools)
            _, performance_log = checked_meta(
                summary["runtimeLog"], evidence_root,
                f"{run['role']} performance runtime log")
            perf_lines = [line for line in performance_log.splitlines()
                          if line.startswith(b"PERF v=1 ")]
            require(perf_lines and
                    all(b" fps_limit=30 " in line for line in perf_lines) and
                    all(line.count(b" fps_limit=") == 1 for line in perf_lines),
                    f"{run['role']} lacks exact runtime fps_limit=30 proof")
            require(run["gpuEvidence"] is None and run["captureIdentity"] is None,
                    f"{run['role']} has foreign GPU pair evidence")
        elif run["role"] in ("additive-a", "additive-b"):
            require(run["performanceEvidence"] is None,
                    f"{run['role']} has foreign performance evidence")
            gpu_meta, gpu_raw = checked_meta(run["gpuEvidence"], evidence_root,
                                             f"{run['role']} GPU evidence")
            capture_meta, capture_raw = checked_meta(
                run["captureIdentity"], evidence_root,
                f"{run['role']} capture identity")
            gpu_identity, derived = _derived_capture(gpu_raw)
            require(capture_raw == pair_module.canonical_json(derived) and
                    gpu_identity["buildSha"] == identity["candidateParentSha"],
                    f"{run['role']} capture identity is not derived from GPU evidence")
        else:
            require(run["performanceEvidence"] is None and
                    run["gpuEvidence"] is None and
                    run["captureIdentity"] is None,
                    f"{run['role']} has foreign performance/GPU evidence")
        authenticated_runs.append({"run": run, "summary": summary, "app": app,
                                   "performance": performance})

    candidate_metallib = authenticated_runs[1]["app"]["metallib"]["sha256"]
    require(all(authenticated_runs[index]["app"]["metallib"]["sha256"] ==
                candidate_metallib for index in (1, 2, 3, 4)),
            "candidate ON/OFF/A/B metallib hashes differ")
    require(len({authenticated_runs[index]["app"]["signedMachO"]["sha256"]
                 for index in (1, 2, 3, 4)}) == 4,
            "candidate ON/OFF/A/B signed Mach-O identities are not distinct")
    baseline = authenticated_runs[0]["performance"]["metrics"]
    candidate = authenticated_runs[2]["performance"]["metrics"]
    performance_contract = spec["performance"]
    require(candidate["meanFps"] >= max(
                performance_contract["minimumMeanFpsAbsolute"],
                performance_contract["minimumMeanFpsRatio"] * baseline["meanFps"]),
            "candidate mean FPS is below D-084 thresholds")
    require(candidate["meanGpuActiveMilliseconds"] <=
            performance_contract["maximumMeanGpuActiveMilliseconds"] and
            candidate["meanGpuActiveMilliseconds"] <=
            performance_contract["maximumMeanGpuActiveRatio"] *
            baseline["meanGpuActiveMilliseconds"],
            "candidate mean GPU-active exceeds D-084 thresholds")

    candidate_on_app = authenticated_runs[1]["app"]
    for key, role in (("preRunSummary", "integrity-pre"),
                      ("postRunSummary", "integrity-post")):
        _, boundary_raw = checked_meta(integrity[key], evidence_root, f"{role} summary")
        validate_integrity_boundary_summary(
            boundary_raw, evidence_root, spec, role,
            {**common_identity,
             "candidateParentSha": identity["candidateParentSha"]},
            candidate_on_app)

    pair_meta, _ = checked_meta(attestation["additivePair"], evidence_root,
                                "additive pair attestation")
    pair_result = pair_module.validate_pair(
        PAIR_SPEC, evidence_root / pair_meta["file"], evidence_root,
        identity["candidateParentSha"], identity["bundleId"], identity["teamId"],
        verify_external_tools=verify_external_tools)
    pair_document = pair_module.decode_json(
        regular_bytes(evidence_root / pair_meta["file"], "pair attestation"),
        "pair attestation")
    for group_index, pair_index in ((3, 0), (4, 1)):
        group_run = authenticated_runs[group_index]["run"]
        pair_run = pair_document["runs"][pair_index]
        require(all(group_run["app"]["signedMachO"][key] ==
                    pair_run["signedMachO"][key]
                    for key in ("file", "bytes", "sha256")) and
                group_run["app"]["metallib"]["file"] ==
                pair_run["metallib"]["file"] and
                group_run["app"]["metallib"]["bytes"] ==
                pair_run["metallib"]["bytes"] and
                group_run["app"]["metallib"]["sha256"] ==
                pair_run["metallib"]["sha256"] and
                group_run["captureIdentity"] == pair_run["capture"],
                "group A/B evidence does not join paired attestation")

    recovery = exact_keys(attestation["recoveryJournal"],
                          ("evidence", "activeJournalRemoved"),
                          "recovery journal attestation")
    require(recovery["activeJournalRemoved"] is True,
            "active recovery journal was not removed after success")
    _, recovery_raw = checked_meta(recovery["evidence"], evidence_root,
                                   "recovery journal evidence")
    validate_recovery_journal(recovery_raw, identity, integrity)
    after_root = evidence_root.lstat()
    require((root_metadata.st_dev, root_metadata.st_ino, root_metadata.st_mode,
             root_metadata.st_size, root_metadata.st_mtime_ns,
             root_metadata.st_ctime_ns) ==
            (after_root.st_dev, after_root.st_ino, after_root.st_mode,
             after_root.st_size, after_root.st_mtime_ns,
             after_root.st_ctime_ns),
            "group evidence root changed during validation")
    return {"deviceUdid": identity["deviceUdid"],
            "baseMeanFps": baseline["meanFps"],
            "candidateMeanFps": candidate["meanFps"],
            "baseMeanGpuActiveMilliseconds": baseline["meanGpuActiveMilliseconds"],
            "candidateMeanGpuActiveMilliseconds":
                candidate["meanGpuActiveMilliseconds"],
            "additiveRecords": pair_result["additiveCount"]}


def _write(path: pathlib.Path, raw: bytes) -> None:
    path.write_bytes(raw)
    path.chmod(0o600)


def _meta(path: pathlib.Path) -> dict[str, Any]:
    raw = regular_bytes(path, f"metadata source {path.name}")
    return {"file": path.name, "bytes": len(raw), "sha256": sha256(raw)}


def _resource_manifest() -> bytes:
    records = [
        {"relativePath": "Data/world.dat", "byteSize": 3,
         "sha256": sha256(b"abc")},
        {"relativePath": "_work/Data/cache.bin", "byteSize": 2,
         "sha256": sha256(b"de")},
        {"relativePath": "system/Gothic.dat", "byteSize": 1,
         "sha256": sha256(b"f")},
    ]
    header = {"schemaVersion": 1, "roots": ["Data", "_work/Data", "system"],
              "excluded": ["system/Gothic.ini"], "fileCount": len(records),
              "totalBytes": sum(record["byteSize"] for record in records)}
    return b"\n".join(_canonical_line(value)
                       for value in (header, *records)) + b"\n"


def _save_manifest() -> bytes:
    records = [
        {"slot": slot, "fileName": f"save_slot_{slot}.sav",
         "byteSize": slot, "sha256": sha256(bytes([slot]) * slot)}
        for slot in (1, 2, 3, 4)
    ]
    header = {"schemaVersion": 1, "protectedSlots": [1, 2, 3, 4],
              "fileCount": 4,
              "totalBytes": sum(record["byteSize"] for record in records)}
    return b"\n".join(_canonical_line(value)
                       for value in (header, *records)) + b"\n"


def _runtime_result(path: pathlib.Path, parent: str, bundle: str,
                    macho_hash: str, metallib_hash: str, log_path: pathlib.Path) -> None:
    crash = "c" * 64
    lines = {
        "result": "PASS", "source_sha": parent,
        "signed_executable_sha256": macho_hash, "bundle_id": bundle,
        "save_slot": "4", "metallib_sha256": metallib_hash,
        "log_sha256": sha256(log_path.read_bytes()),
        "pre_crash_sha256": crash, "post_crash_sha256": crash,
        "device_process_stopped": "1", "durable_zero_scans_completed": "10",
        "durable_zero_respawns_detected": "0",
        "durable_zero_query_failures": "0", "durable_zero_stable": "1",
        "durable_zero_stable_seconds": "90", "durable_zero_final_zero": "1",
    }
    _write(path, "".join(f"{key}={value}\n" for key, value in lines.items()).encode())


def _run_summary(root: pathlib.Path, role: str, parent: str, profile: str,
                 launch_argument: str | None, bundle: str, team: str,
                 macho: pathlib.Path, metallib: pathlib.Path, runtime: pathlib.Path,
                 result: pathlib.Path) -> pathlib.Path:
    value = {
        "schemaVersion": 1, "evidenceClass": "renderer-ios-device-run-summary",
        "role": role, "parentSha": parent, "profile": profile,
        "launchArgument": launch_argument, "bundleId": bundle, "teamId": team,
        "signedExecutableSha256": sha256(macho.read_bytes()),
        "metallibSha256": sha256(metallib.read_bytes()),
        "adapterResult": _meta(result), "runtimeLog": _meta(runtime),
        "crashFatal": {"beforeSha256": "c" * 64,
                       "afterSha256": "c" * 64, "fatalCount": 0},
        "zero": {"deviceProcessStopped": 1, "scansCompleted": 10,
                 "stableSeconds": 90, "respawnsDetected": 0,
                 "queryFailures": 0, "finalZero": 1, "guardState": "ZERO"},
    }
    path = root / f"run-summary-{role}.json"
    _write(path, canonical_json(value))
    return path


def _performance_summary(root: pathlib.Path, spec: dict[str, Any], role: str,
                         parent: str, identity: dict[str, str], mean_fps: float,
                         mean_gpu: float, suffix: str) -> pathlib.Path:
    run_id = ("a" if suffix == "base" else "b") * 32
    directory = root / f"performance-evidence-{role}-{run_id}"
    directory.mkdir()
    prefix = f"performance-{role}-{run_id}"
    trace = directory / f"{prefix}.trace"
    trace.mkdir()
    _write(trace / "core.data", ("trace-" + suffix).encode())
    trace_files, trace_bytes, trace_hash = trace_manifest(trace)
    toc = directory / f"{prefix}-toc.xml"
    metrics_export = directory / f"{prefix}-metrics.xml"
    thermal_export = directory / f"{prefix}-thermal.xml"
    _write(toc, b"<toc/>\n")
    _write(metrics_export, b"<metrics/>\n")
    _write(thermal_export, b"<thermal/>\n")
    contract = spec["performance"]
    source = {
        "tool": "/usr/bin/xctrace", "toolVersion": "27.0",
        "toolBuild": "17A123", "template": contract["template"],
        "evidenceDirectory": directory.name,
        "traceLeaf": trace.name, "traceKind": "directory",
        "traceFiles": trace_files, "traceBytes": trace_bytes,
        "traceManifestSha256": trace_hash, "tocFile": toc.name,
        "tocBytes": toc.stat().st_size, "tocSha256": sha256(toc.read_bytes()),
        "metricsExportFile": metrics_export.name,
        "metricsExportBytes": metrics_export.stat().st_size,
        "metricsExportSha256": sha256(metrics_export.read_bytes()),
        "thermalExportFile": thermal_export.name,
        "thermalExportBytes": thermal_export.stat().st_size,
        "thermalExportSha256": sha256(thermal_export.read_bytes()),
        "commitFile": contract["commitLeaf"],
        "metricTableSchema": contract["metricTableSchema"],
        "metricNameColumn": contract["metricNameColumn"],
        "metricVariantColumn": contract["metricVariantColumn"],
        "frameCountColumn": contract["frameCountColumn"],
        "processIdColumn": contract["processIdColumn"],
        "frameIntervalMetricName": contract["frameIntervalMetricName"],
        "gpuActiveMetricName": contract["gpuActiveMetricName"],
        "valueMillisecondsColumn": contract["valueMillisecondsColumn"],
        "thermalTableSchema": contract["thermalTableSchema"],
        "thermalStateColumn": contract["thermalStateColumn"],
    }
    value = {
        "schemaVersion": 1,
        "evidenceClass": "renderer-ios-performance-trace-summary", "role": role,
        "identity": {"runId": run_id,
                     "parentSha": parent, "tempestSha": identity["tempestSha"],
                     "bundleId": identity["bundleId"], "teamId": identity["teamId"],
                     "deviceUdid": identity["deviceUdid"],
                     "processId": 123 if suffix == "base" else 124},
        "settings": {"saveSlot": 4, "fpsLimit": 30, "settleSeconds": 12,
                     "traceSeconds": 30.0,
                     "modelerBoundaryToleranceNanoseconds": 50},
        "source": source,
        "metrics": {"fpsSampleCount": 900, "gpuActiveSampleCount": 900,
                    "tocDurationSeconds": 30.0,
                    "metricWindowSeconds": 30.0, "thermalWindowSeconds": 30.0,
                    "maximumMetricBoundaryGapNanoseconds": 42,
                    "maximumThermalBoundaryGapNanoseconds": 42,
                    "meanFps": mean_fps,
                    "meanGpuActiveMilliseconds": mean_gpu,
                    "thermalStates": ["Nominal", "Fair"]},
        "terminal": "PERFORMANCE PASS",
    }
    path = directory / contract["summaryLeaf"]
    summary_raw = canonical_json(value)
    _write(path, summary_raw)
    performance_module = load_module(
        PERFORMANCE_VALIDATOR, f"performance_fixture_{suffix}")
    _write(directory / contract["commitLeaf"],
           performance_module.canonical_json(
               performance_module.build_commit(value, summary_raw)))
    return directory


def _gpu_evidence(root: pathlib.Path, pair_module: Any, label: str,
                  pair_run: dict[str, Any], parent: str) -> pathlib.Path:
    gpu_module = load_module(GPU_VALIDATOR, f"gpu_fixture_{label}")
    fixture_path = pathlib.Path(__file__).resolve().parents[1] / \
        "tests/fixtures/linear-hdr-gpudebug-transcripts-v2.json"
    fixture = decode_json(regular_bytes(fixture_path, "GPU fixture", 1024 * 1024),
                          "GPU fixture")
    capture = decode_json(
        regular_bytes(root / pair_run["capture"]["file"], "pair capture"),
        "pair capture")
    accepted = capture["acceptedSnapshot"]
    resource = capture["sceneResource"]
    fixture["runIdentity"].update({
        "proofId": resource["label"].removeprefix("RendererIOS.SceneHDR."),
        "buildSha": parent,
        "targetGeneration": accepted["targetGeneration"],
        "snapshotSequence": accepted["snapshotSequence"],
    })
    fixture["sceneResource"].update(resource)
    proof_id = fixture["runIdentity"]["proofId"]
    fixture["command"]["scene"]["marker"] = "RendererIOS.SceneHDR." + proof_id
    fixture["command"]["proofBlit"]["marker"] = "RendererIOS.HDRProofCopy." + proof_id
    fixture["command"]["proofBlit"]["sourceTextureRef"] = resource["textureRef"]
    fixture["command"]["toneResolve"]["marker"] = "RendererIOS.ToneResolve." + proof_id
    fixture["command"]["toneResolve"]["textureRef"] = resource["textureRef"]
    for entry in fixture["transcripts"]:
        if entry["role"] == "scene-resource":
            entry["argv"][-1] = "info " + resource["textureRef"]
    path = root / f"linear-hdr-gpu-evidence-{label}.json"
    _write(path, gpu_module.canonical_json_bytes(fixture))
    return path


def _build_self_fixture(root: pathlib.Path, spec_path: pathlib.Path) -> pathlib.Path:
    spec, spec_raw = validate_spec(spec_path)
    identity = {"deviceUdid": "00008120-0011223344556677",
                **spec["identities"]}
    pair_module = load_module(PAIR_VALIDATOR, "pair_fixture_for_group")
    pair_path = pair_module._build_fixture(
        root, PAIR_SPEC, parent=identity["candidateParentSha"],
        bundle_id=identity["bundleId"], team_id=identity["teamId"])
    pair_document = pair_module.decode_json(pair_path.read_bytes(), "pair fixture")
    for pair_run in pair_document["runs"]:
        macho_path = root / pair_run["signedMachO"]["file"]
        _write(macho_path, macho_path.read_bytes() +
               b"RendererIOS diagnostics: ON frames-in-flight=3\0")
        pair_run["signedMachO"].update(_meta(macho_path))
    _write(pair_path, pair_module.canonical_json(pair_document))

    resource_raw = _resource_manifest()
    save_raw = _save_manifest()
    manifest_paths: dict[str, pathlib.Path] = {}
    for name, payload in (("resource-master.jsonl", resource_raw),
                          ("resource-pre.jsonl", resource_raw),
                          ("resource-post.jsonl", resource_raw),
                          ("saves-pre.jsonl", save_raw),
                          ("saves-post.jsonl", save_raw)):
        path = root / name
        _write(path, payload)
        manifest_paths[name] = path

    app_identity = {"parentSha": identity["candidateParentSha"],
                    "bundleId": identity["bundleId"], "teamId": identity["teamId"]}
    apps: dict[str, tuple[pathlib.Path, pathlib.Path]] = {}
    pair_by_role = {"additive-a": pair_document["runs"][0],
                    "additive-b": pair_document["runs"][1]}
    for application in spec["applications"]:
        role = application["role"]
        if role in pair_by_role:
            pair_run = pair_by_role[role]
            apps[role] = (root / pair_run["signedMachO"]["file"],
                          root / pair_run["metallib"]["file"])
            continue
        marker = "GROUP-" + role
        raw = pair_module._macho(marker, {
            "parentSha": application["parentSha"],
            "bundleId": identity["bundleId"], "teamId": identity["teamId"]})
        if application["profile"] == "off":
            raw += b"RendererIOS diagnostics: OFF\0"
        else:
            raw += b"RendererIOS diagnostics: ON frames-in-flight=3\0"
        macho = root / f"Gothic2Notr-{role}"
        _write(macho, raw)
        metallib = (root / pair_document["runs"][0]["metallib"]["file"]
                    if application["parentSha"] == identity["candidateParentSha"]
                    else root / "RendererIOS-base.metallib")
        if not metallib.exists():
            _write(metallib, b"MTLB-base-abi8")
        apps[role] = (macho, metallib)

    runs: list[dict[str, Any]] = []
    for application in spec["applications"]:
        role = application["role"]
        macho, metallib = apps[role]
        runtime = (root / pair_by_role[role]["runtimeLog"]["file"]
                   if role in pair_by_role else root / f"runtime-{role}.log")
        if not runtime.exists():
            payload = (b"PERF v=1 scene=save4 fps_limit=30 frame_pacer=display_link "
                       b"window_ms=30000 terminal=C\n"
                       if role in ("base-off-performance",
                                   "candidate-off-performance")
                       else b"runtime terminal=C\n")
            _write(runtime, payload)
        result = root / f"result-{role}.txt"
        _runtime_result(result, application["parentSha"], identity["bundleId"],
                        sha256(macho.read_bytes()), sha256(metallib.read_bytes()), runtime)
        summary = _run_summary(
            root, role, application["parentSha"], application["profile"],
            application["launchArgument"], identity["bundleId"], identity["teamId"],
            macho, metallib, runtime, result)
        performance: dict[str, Any] | None = None
        gpu: dict[str, Any] | None = None
        capture: dict[str, Any] | None = None
        if role == "base-off-performance":
            performance = {"directory": _performance_summary(
                root, spec, role, application["parentSha"], identity, 30.0,
                20.0, "base").name}
        elif role == "candidate-off-performance":
            performance = {"directory": _performance_summary(
                root, spec, role, application["parentSha"], identity, 29.0,
                21.0, "candidate").name}
        elif role in pair_by_role:
            label = "a" if role.endswith("a") else "b"
            gpu = _meta(_gpu_evidence(
                root, pair_module, label, pair_by_role[role],
                identity["candidateParentSha"]))
            capture = {key: pair_by_role[role]["capture"][key]
                       for key in ("file", "bytes", "sha256")}
        runs.append({"role": role, "summary": _meta(summary),
                     "app": {"signedMachO": _meta(macho),
                             "metallib": _meta(metallib)},
                     "performanceEvidence": performance, "gpuEvidence": gpu,
                     "captureIdentity": capture})

    candidate_on_macho, candidate_on_metallib = apps["candidate-on"]
    boundary_summaries: dict[str, pathlib.Path] = {}
    terminal = spec["integrity"]["terminal"].encode("ascii") + b"\n"
    for role in ("integrity-pre", "integrity-post"):
        runtime = root / f"runtime-{role}.log"
        _write(runtime, terminal)
        result = root / f"result-{role}.txt"
        _runtime_result(result, identity["candidateParentSha"], identity["bundleId"],
                        sha256(candidate_on_macho.read_bytes()),
                        sha256(candidate_on_metallib.read_bytes()), runtime)
        boundary_summaries[role] = _run_summary(
            root, role, identity["candidateParentSha"], "on",
            spec["integrity"]["launchArgument"], identity["bundleId"],
            identity["teamId"], candidate_on_macho, candidate_on_metallib,
            runtime, result)

    integrity = {
        "masterResourceManifest": _meta(manifest_paths["resource-master.jsonl"]),
        "preResourceManifest": _meta(manifest_paths["resource-pre.jsonl"]),
        "postResourceManifest": _meta(manifest_paths["resource-post.jsonl"]),
        "preProtectedSaveManifest": _meta(manifest_paths["saves-pre.jsonl"]),
        "postProtectedSaveManifest": _meta(manifest_paths["saves-post.jsonl"]),
        "preRunSummary": _meta(boundary_summaries["integrity-pre"]),
        "postRunSummary": _meta(boundary_summaries["integrity-post"]),
    }
    journal_value = {
        "schemaVersion": 1, "deviceUdid": identity["deviceUdid"],
        "bundleId": identity["bundleId"], "teamId": identity["teamId"],
        "parentSha": identity["candidateParentSha"],
        "oldContainerUuid": "11111111-1111-1111-1111-111111111111",
        "newContainerUuid": "22222222-2222-2222-2222-222222222222",
        "masterResourceManifestSha256": integrity["masterResourceManifest"]["sha256"],
        "preResourceManifestSha256": integrity["preResourceManifest"]["sha256"],
        "postResourceManifestSha256": integrity["postResourceManifest"]["sha256"],
        "preProtectedSaveManifestSha256":
            integrity["preProtectedSaveManifest"]["sha256"],
        "postProtectedSaveManifestSha256":
            integrity["postProtectedSaveManifest"]["sha256"],
        "state": "released",
    }
    journal = root / "recovery-journal-final.json"
    _write(journal, canonical_json(journal_value))
    attestation = {
        "schemaVersion": 1, "evidenceClass": spec["evidenceClass"],
        "specSha256": sha256(spec_raw),
        "identity": {"deviceUdid": identity["deviceUdid"],
                     "bundleId": identity["bundleId"], "teamId": identity["teamId"],
                     "baseParentSha": identity["baseParentSha"],
                     "candidateParentSha": identity["candidateParentSha"],
                     "tempestSha": identity["tempestSha"]},
        "integrity": integrity, "runs": runs, "additivePair": _meta(pair_path),
        "recoveryJournal": {"evidence": _meta(journal),
                            "activeJournalRemoved": True},
    }
    path = root / "additive-device-group-attestation-v1.json"
    _write(path, canonical_json(attestation))
    return path


def _load_attestation(path: pathlib.Path) -> dict[str, Any]:
    value = decode_json(path.read_bytes(), "self-test attestation")
    require(type(value) is dict, "self-test attestation is not an object")
    return value


def _same_root_leaf(path: pathlib.Path, root: pathlib.Path, label: str) -> str:
    require(path.is_absolute() and path.parent == root and
            SAFE_LEAF_RE.fullmatch(path.name) is not None,
            f"{label} must be a safe leaf in the evidence directory")
    return path.name


def build_run_summary(spec_path: pathlib.Path, role: str,
                      adapter_result_path: pathlib.Path,
                      runtime_log_path: pathlib.Path,
                      signed_macho_path: pathlib.Path,
                      metallib_path: pathlib.Path,
                      guard_status_path: pathlib.Path,
                      output_path: pathlib.Path) -> dict[str, Any]:
    spec, _ = validate_spec(spec_path)
    root = output_path.parent
    require(output_path.is_absolute(), "run summary output must be absolute")
    for path, label in ((adapter_result_path, "adapter result"),
                        (runtime_log_path, "runtime log"),
                        (signed_macho_path, "signed Mach-O"),
                        (metallib_path, "metallib")):
        _same_root_leaf(path, root, label)
    result_raw = regular_bytes(adapter_result_path, "adapter result", 64 * 1024 * 1024)
    log_raw = regular_bytes(runtime_log_path, "runtime log", 64 * 1024 * 1024)
    macho_raw = regular_bytes(signed_macho_path, "signed Mach-O")
    metallib_raw = regular_bytes(metallib_path, "metallib")
    result = parse_result(result_raw, "adapter result")
    applications = {value["role"]: value for value in spec["applications"]}
    if role in applications:
        application = applications[role]
    elif role in ("integrity-pre", "integrity-post"):
        application = {"role": role,
                       "parentSha": spec["identities"]["candidateParentSha"],
                       "profile": "on",
                       "launchArgument": spec["integrity"]["launchArgument"]}
    else:
        raise ValidationError("run summary role is not frozen")
    guard_raw = regular_bytes(guard_status_path, "device guard status", 1024 * 1024)
    guard = decode_json(guard_raw, "device guard status")
    exact_keys(guard, ("daemon", "device", "game", "last_update_utc", "lease",
                       "ready", "state"), "device guard status")
    require(guard["daemon"] == "RUNNING" and guard["device"] == "CONFIGURED" and
            guard["game"] == "ZERO" and guard["ready"] == "YES" and
            guard["state"] == "FRESH",
            "device guard does not report fresh game=ZERO")
    required_keys = (
        "signed_executable_sha256", "metallib_sha256", "pre_crash_sha256",
        "post_crash_sha256", "durable_zero_scans_completed",
        "durable_zero_stable_seconds", "durable_zero_respawns_detected",
        "durable_zero_query_failures", "device_process_stopped",
        "durable_zero_final_zero")
    require(all(key in result for key in required_keys),
            "adapter result lacks grouped fields")
    require(result["signed_executable_sha256"] == sha256(macho_raw) and
            result["metallib_sha256"] == sha256(metallib_raw),
            "preserved signed Mach-O/metallib differ from installed run hashes")
    def result_int(key: str) -> int:
        value = result[key]
        require(re.fullmatch(r"0|[1-9][0-9]*", value) is not None,
                f"adapter result {key} is not canonical uint")
        return int(value)
    value = {
        "schemaVersion": 1, "evidenceClass": "renderer-ios-device-run-summary",
        "role": role, "parentSha": application["parentSha"],
        "profile": application["profile"],
        "launchArgument": application["launchArgument"],
        "bundleId": spec["identities"]["bundleId"],
        "teamId": spec["identities"]["teamId"],
        "signedExecutableSha256": sha256(macho_raw),
        "metallibSha256": sha256(metallib_raw),
        "adapterResult": {"file": adapter_result_path.name,
                          "bytes": len(result_raw), "sha256": sha256(result_raw)},
        "runtimeLog": {"file": runtime_log_path.name, "bytes": len(log_raw),
                       "sha256": sha256(log_raw)},
        "crashFatal": {"beforeSha256": result["pre_crash_sha256"],
                       "afterSha256": result["post_crash_sha256"],
                       "fatalCount": 0},
        "zero": {"deviceProcessStopped": result_int("device_process_stopped"),
                 "scansCompleted": result_int("durable_zero_scans_completed"),
                 "stableSeconds": result_int("durable_zero_stable_seconds"),
                 "respawnsDetected": result_int("durable_zero_respawns_detected"),
                 "queryFailures": result_int("durable_zero_query_failures"),
                 "finalZero": result_int("durable_zero_final_zero"),
                 "guardState": "ZERO"},
    }
    raw = canonical_json(value)
    with tempfile.TemporaryDirectory(prefix="rios-group-summary-") as directory:
        candidate = pathlib.Path(directory) / output_path.name
        candidate.write_bytes(raw)
        identity = {"parentSha": application["parentSha"],
                    "tempestSha": spec["identities"]["tempestSha"],
                    "bundleId": spec["identities"]["bundleId"],
                    "teamId": spec["identities"]["teamId"]}
        validate_run_summary(raw, root, spec, application, identity,
                             f"{role} summary")
    atomic_no_clobber(output_path, raw)
    return value


def build_group_attestation(spec_path: pathlib.Path, builder_path: pathlib.Path,
                            evidence_root: pathlib.Path,
                            output_path: pathlib.Path, *,
                            verify_external_tools: bool = True) -> dict[str, Any]:
    spec, spec_raw = validate_spec(spec_path)
    raw = regular_bytes(builder_path, "group builder manifest", 1024 * 1024)
    document = decode_json(raw, "group builder manifest")
    require(raw == canonical_json(document),
            "group builder manifest is not canonical")
    builder = exact_keys(document, (
        "schemaVersion", "deviceUdid", "integrity", "runs", "additivePairFile",
        "recoveryJournalFile", "activeJournalRemoved"),
        "group builder manifest")
    require(builder["schemaVersion"] == 1 and
            type(builder["schemaVersion"]) is int and
            type(builder["deviceUdid"]) is str and
            UDID_RE.fullmatch(builder["deviceUdid"]) is not None and
            builder["activeJournalRemoved"] is True,
            "group builder root differs")
    integrity_source = exact_keys(builder["integrity"], (
        "masterResourceManifestFile", "preResourceManifestFile",
        "postResourceManifestFile", "preProtectedSaveManifestFile",
        "postProtectedSaveManifestFile", "preRunSummaryFile",
        "postRunSummaryFile"), "group builder integrity")
    integrity_names = (
        ("masterResourceManifest", "masterResourceManifestFile"),
        ("preResourceManifest", "preResourceManifestFile"),
        ("postResourceManifest", "postResourceManifestFile"),
        ("preProtectedSaveManifest", "preProtectedSaveManifestFile"),
        ("postProtectedSaveManifest", "postProtectedSaveManifestFile"),
        ("preRunSummary", "preRunSummaryFile"),
        ("postRunSummary", "postRunSummaryFile"),
    )
    integrity = {}
    for target, source in integrity_names:
        leaf = safe_leaf(integrity_source[source], f"group builder {source}")
        integrity[target] = _meta(evidence_root / leaf)
    source_runs = builder["runs"]
    require(type(source_runs) is list and len(source_runs) == 5,
            "group builder does not contain exact five runs")
    runs = []
    for source_run, application in zip(source_runs, spec["applications"]):
        run = exact_keys(source_run, (
            "role", "summaryFile", "signedMachOFile", "metallibFile",
            "performanceEvidenceDirectory", "gpuEvidenceFile",
            "captureIdentityFile"),
            "group builder run")
        require(run["role"] == application["role"],
                "group builder run order differs")
        def optional_meta(key: str) -> dict[str, Any] | None:
            leaf = run[key]
            if leaf is None:
                return None
            return _meta(evidence_root / safe_leaf(leaf, f"group builder {key}"))
        runs.append({
            "role": run["role"],
            "summary": _meta(evidence_root /
                             safe_leaf(run["summaryFile"], "summaryFile")),
            "app": {
                "signedMachO": _meta(evidence_root / safe_leaf(
                    run["signedMachOFile"], "signedMachOFile")),
                "metallib": _meta(evidence_root / safe_leaf(
                    run["metallibFile"], "metallibFile")),
            },
            "performanceEvidence": None if
                run["performanceEvidenceDirectory"] is None else {
                    "directory": safe_leaf(
                        run["performanceEvidenceDirectory"],
                        "group builder performanceEvidenceDirectory")},
            "gpuEvidence": optional_meta("gpuEvidenceFile"),
            "captureIdentity": optional_meta("captureIdentityFile"),
        })
    pair_leaf = safe_leaf(builder["additivePairFile"], "additivePairFile")
    journal_leaf = safe_leaf(builder["recoveryJournalFile"], "recoveryJournalFile")
    frozen = spec["identities"]
    attestation = {
        "schemaVersion": 1, "evidenceClass": spec["evidenceClass"],
        "specSha256": sha256(spec_raw),
        "identity": {"deviceUdid": builder["deviceUdid"],
                     "bundleId": frozen["bundleId"], "teamId": frozen["teamId"],
                     "baseParentSha": frozen["baseParentSha"],
                     "candidateParentSha": frozen["candidateParentSha"],
                     "tempestSha": frozen["tempestSha"]},
        "integrity": integrity, "runs": runs,
        "additivePair": _meta(evidence_root / pair_leaf),
        "recoveryJournal": {"evidence": _meta(evidence_root / journal_leaf),
                            "activeJournalRemoved": True},
    }
    attestation_raw = canonical_json(attestation)
    require(not output_path.exists() and not output_path.is_symlink(),
            "group attestation output already exists")
    with tempfile.TemporaryDirectory(prefix="rios-group-attestation-") as directory:
        candidate = pathlib.Path(directory) / output_path.name
        candidate.write_bytes(attestation_raw)
        validate_group(spec_path, candidate, evidence_root,
                       verify_external_tools=verify_external_tools)
    atomic_no_clobber(output_path, attestation_raw)
    return attestation


def _store_attestation(path: pathlib.Path, value: dict[str, Any]) -> None:
    _write(path, canonical_json(value))


def _refresh_attested_file(attestation: dict[str, Any], path: pathlib.Path,
                           metadata: dict[str, Any]) -> None:
    metadata.update(_meta(path))


def self_test(spec_path: pathlib.Path) -> int:
    validate_spec(spec_path)
    mutations: list[tuple[str, Any]] = []

    def document_mutation(name: str, change: Any) -> None:
        mutations.append((name, lambda root, path, doc: change(doc)))

    document_mutation("run-order", lambda doc:
                      doc["runs"].__setitem__(slice(0, 2),
                                              [doc["runs"][1], doc["runs"][0]]))
    document_mutation("active-journal-remains", lambda doc:
                      doc["recoveryJournal"].update(activeJournalRemoved=False))
    document_mutation("candidate-app-reused", lambda doc:
                      doc["runs"][2].update(app=copy.deepcopy(doc["runs"][1]["app"])))
    document_mutation("pair-capture-false-join", lambda doc:
                      doc["runs"][4].update(
                          captureIdentity=copy.deepcopy(doc["runs"][3]["captureIdentity"])))

    def summary_mutation(name: str, run_index: int, change: Any) -> None:
        def apply(root: pathlib.Path, _: pathlib.Path, document: dict[str, Any]) -> None:
            metadata = document["runs"][run_index]["summary"]
            path = root / metadata["file"]
            value = decode_json(path.read_bytes(), name)
            change(value)
            _write(path, canonical_json(value))
            _refresh_attested_file(document, path, metadata)
        mutations.append((name, apply))

    summary_mutation("short-zero", 1, lambda value:
                     value["zero"].update(stableSeconds=89))
    summary_mutation("fatal-count", 1, lambda value:
                     value["crashFatal"].update(fatalCount=1))

    def performance_mutation(name: str, run_index: int, change: Any) -> None:
        def apply(root: pathlib.Path, _: pathlib.Path, document: dict[str, Any]) -> None:
            performance_directory = root / document["runs"][run_index][
                "performanceEvidence"]["directory"]
            path = performance_directory / "performance-trace-summary-v1.json"
            value = decode_json(path.read_bytes(), name)
            change(value)
            summary_raw = canonical_json(value)
            _write(path, summary_raw)
            performance_module = load_module(
                PERFORMANCE_VALIDATOR, f"performance_mutation_{name}")
            _write(performance_directory / "performance-evidence-commit-v1.json",
                   performance_module.canonical_json(
                       performance_module.build_commit(value, summary_raw)))
        mutations.append((name, apply))

    performance_mutation("low-fps", 2, lambda value:
                         value["metrics"].update(meanFps=26.99))
    performance_mutation("high-gpu-active", 2, lambda value:
                         value["metrics"].update(meanGpuActiveMilliseconds=33.35))
    performance_mutation("thermal-serious", 2, lambda value:
                         value["metrics"].update(thermalStates=["Nominal", "Serious"]))
    performance_mutation("metric-window-short", 2, lambda value:
                         value["metrics"].update(metricWindowSeconds=29.99))
    performance_mutation("gpu-sample-domain", 2, lambda value:
                         value["metrics"].update(gpuActiveSampleCount=899))

    def runtime_fps_change(root: pathlib.Path, _: pathlib.Path,
                           document: dict[str, Any]) -> None:
        summary_meta = document["runs"][2]["summary"]
        summary_path = root / summary_meta["file"]
        summary = decode_json(summary_path.read_bytes(), "runtime FPS mutation")
        log_path = root / summary["runtimeLog"]["file"]
        _write(log_path, log_path.read_bytes().replace(b" fps_limit=30 ",
                                                       b" fps_limit=60 ", 1))
        summary["runtimeLog"].update(_meta(log_path))
        result_path = root / summary["adapterResult"]["file"]
        result = parse_result(result_path.read_bytes(), "runtime FPS result")
        result["log_sha256"] = sha256(log_path.read_bytes())
        _write(result_path, "".join(f"{key}={value}\n"
                                    for key, value in result.items()).encode())
        summary["adapterResult"].update(_meta(result_path))
        _write(summary_path, canonical_json(summary))
        _refresh_attested_file(document, summary_path, summary_meta)
    mutations.append(("runtime-fps-limit", runtime_fps_change))

    def manifest_change(root: pathlib.Path, _: pathlib.Path,
                        document: dict[str, Any]) -> None:
        metadata = document["integrity"]["postProtectedSaveManifest"]
        path = root / metadata["file"]
        _write(path, path.read_bytes().replace(b"save_slot_4.sav",
                                               b"save_slot_4.bad", 1))
        _refresh_attested_file(document, path, metadata)
    mutations.append(("protected-save-change", manifest_change))

    def trace_change(root: pathlib.Path, _: pathlib.Path,
                     document: dict[str, Any]) -> None:
        performance_directory = root / document["runs"][2][
            "performanceEvidence"]["directory"]
        summary_path = performance_directory / "performance-trace-summary-v1.json"
        summary = decode_json(summary_path.read_bytes(), "trace mutation")
        trace = performance_directory / summary["source"]["traceLeaf"] / "core.data"
        _write(trace, trace.read_bytes() + b"X")
    mutations.append(("trace-bundle-change", trace_change))

    def performance_set_mutation(name: str, change: Any) -> None:
        def apply(root: pathlib.Path, _: pathlib.Path,
                  document: dict[str, Any]) -> None:
            directory = root / document["runs"][2][
                "performanceEvidence"]["directory"]
            change(directory)
        mutations.append((name, apply))

    performance_set_mutation("performance-commit-missing", lambda directory:
                             (directory / "performance-evidence-commit-v1.json").unlink())
    performance_set_mutation("performance-extra-member", lambda directory:
                             _write(directory / "unexpected.bin", b"X"))

    def corrupt_commit(directory: pathlib.Path) -> None:
        path = directory / "performance-evidence-commit-v1.json"
        value = decode_json(path.read_bytes(), "commit mutation")
        value["terminal"] = "WRONG"
        _write(path, canonical_json(value))
    performance_set_mutation("performance-commit-terminal", corrupt_commit)

    def corrupt_commit_metadata(directory: pathlib.Path) -> None:
        path = directory / "performance-evidence-commit-v1.json"
        value = decode_json(path.read_bytes(), "commit metadata mutation")
        value["members"][0]["files"] += 1
        _write(path, canonical_json(value))
    performance_set_mutation("performance-commit-metadata",
                             corrupt_commit_metadata)

    killed = 0
    with tempfile.TemporaryDirectory(prefix="rios-additive-device-group-") as directory:
        root = pathlib.Path(directory)
        baseline = root / "baseline"
        baseline.mkdir()
        attestation = _build_self_fixture(baseline, spec_path)
        validate_group(spec_path, attestation, baseline,
                       verify_external_tools=False)
        baseline_document = _load_attestation(attestation)
        guard_status = baseline / "guard-status-builder.json"
        _write(guard_status, canonical_json({
            "daemon": "RUNNING", "device": "CONFIGURED", "game": "ZERO",
            "last_update_utc": "2026-08-09T00:00:00Z", "lease": "IDLE",
            "ready": "YES", "state": "FRESH"}))
        candidate_run = baseline_document["runs"][1]
        existing_summary = decode_json(
            (baseline / candidate_run["summary"]["file"]).read_bytes(),
            "existing candidate summary")
        built_summary = baseline / "built-candidate-summary.json"
        build_run_summary(
            spec_path, "candidate-on",
            baseline / existing_summary["adapterResult"]["file"],
            baseline / existing_summary["runtimeLog"]["file"],
            baseline / candidate_run["app"]["signedMachO"]["file"],
            baseline / candidate_run["app"]["metallib"]["file"],
            guard_status, built_summary)
        require(built_summary.read_bytes() == canonical_json(existing_summary),
                "run summary builder output differs")
        try:
            build_run_summary(
                spec_path, "candidate-on",
                baseline / existing_summary["adapterResult"]["file"],
                baseline / existing_summary["runtimeLog"]["file"],
                baseline / candidate_run["app"]["signedMachO"]["file"],
                baseline / candidate_run["app"]["metallib"]["file"],
                guard_status, built_summary)
        except ValidationError:
            pass
        else:
            raise ValidationError("run summary builder clobbered existing output")

        integrity = baseline_document["integrity"]
        builder_value = {
            "schemaVersion": 1,
            "deviceUdid": baseline_document["identity"]["deviceUdid"],
            "integrity": {
                "masterResourceManifestFile": integrity["masterResourceManifest"]["file"],
                "preResourceManifestFile": integrity["preResourceManifest"]["file"],
                "postResourceManifestFile": integrity["postResourceManifest"]["file"],
                "preProtectedSaveManifestFile":
                    integrity["preProtectedSaveManifest"]["file"],
                "postProtectedSaveManifestFile":
                    integrity["postProtectedSaveManifest"]["file"],
                "preRunSummaryFile": integrity["preRunSummary"]["file"],
                "postRunSummaryFile": integrity["postRunSummary"]["file"],
            },
            "runs": [{
                "role": run["role"], "summaryFile": run["summary"]["file"],
                "signedMachOFile": run["app"]["signedMachO"]["file"],
                "metallibFile": run["app"]["metallib"]["file"],
                "performanceEvidenceDirectory": None if
                    run["performanceEvidence"] is None else
                    run["performanceEvidence"]["directory"],
                "gpuEvidenceFile": None if run["gpuEvidence"] is None
                    else run["gpuEvidence"]["file"],
                "captureIdentityFile": None if run["captureIdentity"] is None
                    else run["captureIdentity"]["file"],
            } for run in baseline_document["runs"]],
            "additivePairFile": baseline_document["additivePair"]["file"],
            "recoveryJournalFile":
                baseline_document["recoveryJournal"]["evidence"]["file"],
            "activeJournalRemoved": True,
        }
        builder_path = baseline / "group-builder-self-test.json"
        _write(builder_path, canonical_json(builder_value))
        built_group = baseline / "built-group-attestation.json"
        build_group_attestation(spec_path, builder_path, baseline, built_group,
                                verify_external_tools=False)
        validate_group(spec_path, built_group, baseline,
                       verify_external_tools=False)
        try:
            build_group_attestation(spec_path, builder_path, baseline, built_group,
                                    verify_external_tools=False)
        except ValidationError:
            pass
        else:
            raise ValidationError("group builder clobbered existing output")
        for index, (name, mutation) in enumerate(mutations):
            case = root / f"mutation-{index}"
            shutil.copytree(baseline, case)
            path = case / attestation.name
            document = _load_attestation(path)
            mutation(case, path, document)
            _store_attestation(path, document)
            try:
                validate_group(spec_path, path, case,
                               verify_external_tools=False)
            except (OSError, ValidationError):
                killed += 1
            else:
                raise ValidationError(f"group mutation survived: {name}")
    require(killed == len(mutations), "group mutation count drifted")
    print(f"additive device group validator self-test: PASS "
          f"({killed} mutations killed)")
    return 0


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    self_parser = subparsers.add_parser("self-test")
    self_parser.add_argument("--spec", type=pathlib.Path, default=DEFAULT_SPEC)
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--spec", type=pathlib.Path, required=True)
    validate_parser.add_argument("--attestation", type=pathlib.Path, required=True)
    validate_parser.add_argument("--evidence-dir", type=pathlib.Path, required=True)
    run_parser = subparsers.add_parser("build-run-summary")
    run_parser.add_argument("--spec", type=pathlib.Path, required=True)
    run_parser.add_argument("--role", required=True)
    run_parser.add_argument("--adapter-result", type=pathlib.Path, required=True)
    run_parser.add_argument("--runtime-log", type=pathlib.Path, required=True)
    run_parser.add_argument("--signed-macho", type=pathlib.Path, required=True)
    run_parser.add_argument("--metallib", type=pathlib.Path, required=True)
    run_parser.add_argument("--guard-status", type=pathlib.Path, required=True)
    run_parser.add_argument("--output", type=pathlib.Path, required=True)
    build_parser = subparsers.add_parser("build-attestation")
    build_parser.add_argument("--spec", type=pathlib.Path, required=True)
    build_parser.add_argument("--builder", type=pathlib.Path, required=True)
    build_parser.add_argument("--evidence-dir", type=pathlib.Path, required=True)
    build_parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.mode == "self-test":
            return self_test(arguments.spec)
        if arguments.mode == "build-run-summary":
            build_run_summary(
                arguments.spec, arguments.role, arguments.adapter_result,
                arguments.runtime_log, arguments.signed_macho,
                arguments.metallib, arguments.guard_status, arguments.output)
            print("ADDITIVE DEVICE RUN SUMMARY BUILT")
            return 0
        if arguments.mode == "build-attestation":
            build_group_attestation(arguments.spec, arguments.builder,
                                    arguments.evidence_dir, arguments.output)
            print("ADDITIVE DEVICE GROUP ATTESTATION BUILT")
            return 0
        result = validate_group(arguments.spec, arguments.attestation,
                                arguments.evidence_dir)
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("ADDITIVE DEVICE GROUP VALID")
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
