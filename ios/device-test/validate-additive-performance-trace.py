#!/usr/bin/env python3
"""Fail-closed Xcode 27 performance trace validator for P2.1e1b."""

from __future__ import annotations

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
import os
import pathlib
import re
import stat
import struct
import subprocess
import sys
import unicodedata
import xml.etree.ElementTree as ET
from typing import Any, Iterable, Mapping, Sequence


TEMPLATE = "Game Performance Overview"
METRIC_SCHEMA = "metal-perf-overview-layer-duration-metric"
THERMAL_SCHEMA = "device-thermal-state-intervals"
METRIC_NAME_COLUMN = "name"
METRIC_VARIANT_COLUMN = "metric-variant"
FRAME_COUNT_COLUMN = "number-of-frames"
PROCESS_ID_COLUMN = "process"
FRAME_INTERVAL_NAME = "0.Frame Interval"
GPU_ACTIVE_NAME = "4.GPU Active Time"
VALUE_COLUMN = "value-in-ms"
THERMAL_COLUMN = "thermal-state"
TRACE_DOMAIN = b"opengothic-performance-trace-v1\0"
EVIDENCE_SET_DOMAIN = b"opengothic-performance-evidence-set-v1\0"
MODELER_BOUNDARY_TOLERANCE_NS = 50
TOC_DURATION_TOLERANCE_NS = 1000
MAX_TRACE_FILES = 100_000
MAX_TRACE_BYTES = 16 * 1024 * 1024 * 1024
MAX_XML_BYTES = 1024 * 1024 * 1024
SHA40_RE = re.compile(r"[0-9a-f]{40}\Z")
SHA64_RE = re.compile(r"[0-9a-f]{64}\Z")
RUN_RE = re.compile(r"[0-9a-f]{32}\Z")
DEVICE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
SAFE_LEAF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}\Z")
BUNDLE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,254}\Z")
TEAM_RE = re.compile(r"[A-Z0-9]{1,32}\Z")
TOOL_VERSION_RE = re.compile(r"27\.[0-9]+(?:\.[0-9]+)?\Z")
TOOL_BUILD_RE = re.compile(r"[0-9]+[A-Za-z][A-Za-z0-9]+\Z")
THERMAL_STATES = ("Nominal", "Fair", "Serious", "Critical")
SUMMARY_ROOT_KEYS = (
    "schemaVersion", "evidenceClass", "role", "identity", "settings",
    "source", "metrics", "terminal",
)
IDENTITY_KEYS = (
    "runId", "parentSha", "tempestSha", "bundleId", "teamId",
    "deviceUdid", "processId",
)
SETTINGS_KEYS = (
    "saveSlot", "fpsLimit", "settleSeconds", "traceSeconds",
    "modelerBoundaryToleranceNanoseconds",
)
SOURCE_KEYS = (
    "tool", "toolVersion", "toolBuild", "template", "evidenceDirectory",
    "traceLeaf", "traceKind", "traceFiles", "traceBytes",
    "traceManifestSha256", "tocFile", "tocBytes", "tocSha256",
    "metricsExportFile", "metricsExportBytes", "metricsExportSha256",
    "thermalExportFile", "thermalExportBytes", "thermalExportSha256",
    "commitFile", "metricTableSchema", "metricNameColumn",
    "metricVariantColumn", "frameCountColumn", "processIdColumn",
    "frameIntervalMetricName", "gpuActiveMetricName",
    "valueMillisecondsColumn", "thermalTableSchema", "thermalStateColumn",
)
METRICS_KEYS = (
    "fpsSampleCount", "gpuActiveSampleCount", "tocDurationSeconds",
    "metricWindowSeconds", "thermalWindowSeconds",
    "maximumMetricBoundaryGapNanoseconds",
    "maximumThermalBoundaryGapNanoseconds", "meanFps",
    "meanGpuActiveMilliseconds", "thermalStates",
)
COMMIT_ROOT_KEYS = (
    "schemaVersion", "evidenceClass", "runId", "role", "members",
    "setSha256", "terminal",
)
COMMIT_MEMBER_KEYS = ("leaf", "kind", "files", "bytes", "sha256")


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":"),
                       allow_nan=False) + "\n").encode("utf-8")


def canonical_json_value(raw: bytes, label: str) -> dict[str, Any]:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in items:
            require(key not in value, f"{label} has duplicate JSON keys")
            value[key] = item
        return value

    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                           parse_constant=lambda token: (_ for _ in ()).throw(
                               ValueError(token)))
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ValidationError(f"{label} is invalid JSON: {error}") from error
    require(type(value) is dict and canonical_json(value) == raw,
            f"{label} is not canonical LF JSON")
    return value


def exact_keys(value: Any, keys: tuple[str, ...], label: str) -> None:
    require(type(value) is dict and tuple(value) == keys,
            f"{label} keys/order differ")


def _stat_identity(value: os.stat_result) -> tuple[int, int, int, int, int]:
    return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
            value.st_mtime_ns)


def regular_bytes(path: pathlib.Path, label: str,
                  maximum: int = MAX_XML_BYTES) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode), f"{label} is not regular")
        require(0 < before.st_size <= maximum, f"{label} size is invalid")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            require(chunk != b"", f"{label} was truncated")
            chunks.append(chunk)
            remaining -= len(chunk)
        require(os.read(descriptor, 1) == b"", f"{label} grew while read")
        require(_stat_identity(before) == _stat_identity(os.fstat(descriptor)),
                f"{label} changed while read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _checked_relative(path: pathlib.PurePath) -> bytes:
    text = path.as_posix()
    require(text != "" and not text.startswith("/"),
            "trace member path is not relative")
    require("\\" not in text and unicodedata.normalize("NFC", text) == text,
            "trace member path is not canonical NFC")
    require(all(part not in ("", ".", "..") for part in path.parts),
            "trace member path contains a dot component")
    require(all(ord(char) >= 32 and ord(char) != 127 for char in text),
            "trace member path contains a control character")
    encoded = text.encode("utf-8", "strict")
    require(len(encoded) <= 0xFFFFFFFF, "trace member path is too long")
    return encoded


def trace_manifest(path: pathlib.Path) -> tuple[int, int, str]:
    root_before = path.lstat()
    require(stat.S_ISDIR(root_before.st_mode) and
            not stat.S_ISLNK(root_before.st_mode),
            "trace root is not a non-symlink directory")
    entries: list[tuple[bytes, int, bytes]] = []
    directories: list[tuple[pathlib.Path, tuple[int, int, int, int, int]]] = []
    seen: set[bytes] = set()
    for directory, names, files in os.walk(path, topdown=True,
                                            followlinks=False):
        directory_path = pathlib.Path(directory)
        directories.append((directory_path,
                            _stat_identity(directory_path.lstat())))
        for name in tuple(names):
            child = directory_path / name
            metadata = child.lstat()
            require(stat.S_ISDIR(metadata.st_mode) and
                    not stat.S_ISLNK(metadata.st_mode),
                    "trace contains a symlink or special directory")
            _checked_relative(child.relative_to(path))
        for name in files:
            child = directory_path / name
            relative = _checked_relative(child.relative_to(path))
            require(relative not in seen, "trace contains duplicate paths")
            seen.add(relative)
            descriptor = os.open(child, os.O_RDONLY | os.O_CLOEXEC |
                                  os.O_NOFOLLOW)
            try:
                before = os.fstat(descriptor)
                require(stat.S_ISREG(before.st_mode),
                        "trace contains a symlink or special file")
                digest = hashlib.sha256()
                total = 0
                while True:
                    block = os.read(descriptor, 1024 * 1024)
                    if not block:
                        break
                    total += len(block)
                    require(total <= before.st_size,
                            "trace member grew while hashing")
                    digest.update(block)
                require(total == before.st_size,
                        "trace member was truncated while hashing")
                require(_stat_identity(before) ==
                        _stat_identity(os.fstat(descriptor)),
                        "trace member changed while hashing")
            finally:
                os.close(descriptor)
            after = child.lstat()
            require(_stat_identity(before) == _stat_identity(after),
                    "trace member changed after hashing")
            entries.append((relative, before.st_size, digest.digest()))
            require(len(entries) <= MAX_TRACE_FILES,
                    "trace contains too many files")
    require(entries, "trace bundle is empty")
    entries.sort(key=lambda entry: entry[0])
    stream = bytearray(TRACE_DOMAIN)
    total_bytes = 0
    for relative, file_bytes, digest in entries:
        require(total_bytes <= MAX_TRACE_BYTES - file_bytes,
                "trace bundle is too large")
        total_bytes += file_bytes
        stream += struct.pack("<I", len(relative))
        stream += relative
        stream += struct.pack("<Q", file_bytes)
        stream += digest
    require(total_bytes > 0, "trace bundle has no payload bytes")
    for directory_path, identity in directories:
        require(identity == _stat_identity(directory_path.lstat()),
                "trace directory changed while hashing")
    require(_stat_identity(root_before) == _stat_identity(path.lstat()),
            "trace root changed while hashing")
    return len(entries), total_bytes, sha256(bytes(stream))


def parse_xml(raw: bytes, label: str) -> ET.Element:
    require(not raw.startswith(b"\xef\xbb\xbf"), f"{label} has a BOM")
    lowered = raw.lower()
    require(b"<!doctype" not in lowered and b"<!entity" not in lowered,
            f"{label} contains a forbidden declaration")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise ValidationError(f"{label} is invalid XML: {error}") from error
    require(all("}" not in element.tag for element in root.iter()),
            f"{label} uses XML namespaces")
    return root


def _one(parent: ET.Element, path: str, label: str) -> ET.Element:
    matches = parent.findall(path)
    require(len(matches) == 1, f"{label} count is not exactly one")
    return matches[0]


def _text(parent: ET.Element, path: str, label: str) -> str:
    element = _one(parent, path, label)
    require(element.text is not None and element.text != "",
            f"{label} is empty")
    return element.text


def validate_toc(raw: bytes, device: str, process_id: int,
                 trace_seconds: int) -> Decimal:
    root = parse_xml(raw, "TOC")
    require(root.tag == "trace-toc", "TOC root is not trace-toc")
    run = _one(root, "./run", "TOC run")
    require(run.attrib == {"number": "1"}, "TOC run identity is not exact")
    target = _one(run, "./info/target", "TOC target")
    devices = target.findall("./device")
    require(len(devices) == 1 and devices[0].get("uuid") == device,
            "TOC device identity differs")
    processes = target.findall("./process")
    require(len(processes) == 1 and processes[0].get("type") == "attached" and
            processes[0].get("pid") == str(process_id),
            "TOC attached process identity differs")
    summary = _one(run, "./info/summary", "TOC summary")
    require(_text(summary, "./template-name", "TOC template") == TEMPLATE,
            "TOC template differs")
    require(_text(summary, "./end-reason", "TOC end reason") ==
            "Time limit reached", "TOC did not reach the time limit")
    require(_text(summary, "./time-limit", "TOC time limit") ==
            f"{trace_seconds} seconds", "TOC time limit differs")
    instruments = summary.findall("./intruments-recording-settings/instrument")
    require(len(instruments) == 1 and
            instruments[0].get("name") == "Metal Performance Overview",
            "TOC recording instrument differs")
    options = instruments[0].findall("./options/option")
    require([(option.get("key"), option.get("value")) for option in options] == [
        ("Game Performance Overview Per-Frame Metrics", "Enabled"),
        ("Game Performance Overview Shader Compilation Metrics", "Disabled"),
    ], "TOC recording options differ")
    try:
        duration = Decimal(_text(summary, "./duration", "TOC duration"))
    except InvalidOperation as error:
        raise ValidationError("TOC duration is not decimal") from error
    require(duration.is_finite() and duration >= Decimal(trace_seconds),
            "TOC duration is shorter than requested")
    tables = run.findall("./data/table")
    require(sum(table.get("schema") == METRIC_SCHEMA for table in tables) == 1,
            "TOC metric table count is not exactly one")
    require(sum(table.get("schema") == THERMAL_SCHEMA for table in tables) == 1,
            "TOC thermal table count is not exactly one")
    return duration


class ExportTable:
    def __init__(self, raw: bytes, expected_schema: str, label: str) -> None:
        root = parse_xml(raw, label)
        require(root.tag == "trace-query-result",
                f"{label} root is not trace-query-result")
        node = _one(root, "./node", f"{label} node")
        schema = _one(node, "./schema", f"{label} schema")
        require(schema.get("name") == expected_schema,
                f"{label} schema differs")
        self.columns: list[str] = []
        self.types: dict[str, str] = {}
        for column in schema.findall("./col"):
            mnemonic = _text(column, "./mnemonic", f"{label} mnemonic")
            engineering = _text(column, "./engineering-type",
                                f"{label} engineering type")
            require(mnemonic not in self.columns,
                    f"{label} has duplicate columns")
            self.columns.append(mnemonic)
            self.types[mnemonic] = engineering
        require(self.columns, f"{label} has no columns")
        self.rows = node.findall("./row")
        require(self.rows, f"{label} has no rows")
        self.ids: dict[str, ET.Element] = {}
        for element in root.iter():
            identifier = element.get("id")
            if identifier is not None:
                require(identifier.isdigit() and identifier not in self.ids,
                        f"{label} has an invalid or duplicate XML id")
                self.ids[identifier] = element
        for row in self.rows:
            require(len(row) == len(self.columns),
                    f"{label} row width differs from schema")

    def index(self, column: str, engineering: str) -> int:
        require(column in self.columns, f"export lacks column {column}")
        require(self.types[column] == engineering,
                f"export column {column} has wrong engineering type")
        return self.columns.index(column)

    def resolved(self, element: ET.Element) -> ET.Element:
        seen: set[str] = set()
        current = element
        while current.get("ref") is not None:
            reference = current.get("ref")
            require(reference is not None and reference in self.ids and
                    reference not in seen, "XML reference is invalid or cyclic")
            seen.add(reference)
            current = self.ids[reference]
        return current

    def scalar(self, row: ET.Element, index: int, label: str) -> str:
        element = self.resolved(row[index])
        require(element.text is not None and element.text != "",
                f"{label} is empty")
        return element.text

    def process_id(self, row: ET.Element, index: int) -> int:
        process = self.resolved(row[index])
        pids = process.findall("./pid")
        require(len(pids) == 1, "metric process has no exact PID")
        value = self.resolved(pids[0]).text
        require(value is not None and value.isdigit() and int(value) > 0,
                "metric process PID is invalid")
        return int(value)


def _integer(text: str, label: str, minimum: int = 0) -> int:
    require(text.isdigit(), f"{label} is not an unsigned integer")
    value = int(text)
    require(value >= minimum, f"{label} is below its minimum")
    return value


def _decimal(text: str, label: str, minimum: Decimal,
             strict: bool = False) -> Decimal:
    try:
        value = Decimal(text)
    except InvalidOperation as error:
        raise ValidationError(f"{label} is not decimal") from error
    require(value.is_finite() and (value > minimum if strict else value >= minimum),
            f"{label} is non-finite or out of range")
    return value


def _continuous_window_extent(windows: Iterable[tuple[int, int]], label: str,
                              toc_duration_ns: Decimal) -> tuple[int, int]:
    sequence = tuple(windows)
    ordered = sorted(sequence)
    require(sequence == tuple(ordered), f"{label} rows are not chronological")
    require(ordered and ordered[0][0] == 0,
            f"{label} does not start at trace zero")
    previous_end = 0
    maximum_gap = 0
    for start, duration in ordered:
        require(duration > 0, f"{label} has invalid duration")
        gap = start - previous_end
        require(0 <= gap <= MODELER_BOUNDARY_TOLERANCE_NS,
                f"{label} has a gap or overlap beyond tolerance")
        maximum_gap = max(maximum_gap, gap)
        previous_end = start + duration
        require(Decimal(previous_end) <=
                toc_duration_ns + TOC_DURATION_TOLERANCE_NS,
                f"{label} exceeds TOC duration")
    return previous_end, maximum_gap


def validate_metrics(raw: bytes, process_id: int, minimum_seconds: int,
                     toc_duration: Decimal) -> tuple[int, int, Decimal, int,
                                                           Decimal, Decimal]:
    table = ExportTable(raw, METRIC_SCHEMA, "metrics export")
    indices = {
        "start": table.index("start", "start-time"),
        "duration": table.index("duration", "duration"),
        "value": table.index(VALUE_COLUMN, "fixed-decimal"),
        "frames": table.index(FRAME_COUNT_COLUMN, "uint64"),
        "metric": table.index("metric", "uint32"),
        "variant": table.index(METRIC_VARIANT_COLUMN, "uint32"),
        "name": table.index(METRIC_NAME_COLUMN,
                            "metal-performance-overview-layer-duration-metric-name"),
        "process": table.index(PROCESS_ID_COLUMN, "process"),
        "layer": table.index("layer-id", "uint64"),
    }
    domains: dict[str, dict[tuple[int, int], tuple[int, Decimal]]] = {
        FRAME_INTERVAL_NAME: {}, GPU_ACTIVE_NAME: {}}
    variants: dict[tuple[str, int, int], set[int]] = {}
    layers: set[str] = set()
    metric_numbers = {FRAME_INTERVAL_NAME: 0, GPU_ACTIVE_NAME: 4}
    for row in table.rows:
        name = table.scalar(row, indices["name"], "metric name")
        if name not in domains:
            continue
        require(table.process_id(row, indices["process"]) == process_id,
                "target metric row belongs to another PID")
        start = _integer(table.scalar(row, indices["start"], "metric start"),
                         "metric start")
        duration = _integer(table.scalar(row, indices["duration"],
                                         "metric duration"),
                            "metric duration", 1)
        metric = _integer(table.scalar(row, indices["metric"], "metric id"),
                          "metric id")
        require(metric == metric_numbers[name], "metric discriminator differs")
        variant = _integer(table.scalar(row, indices["variant"],
                                        "metric variant"), "metric variant")
        require(variant in (0, 1, 2, 3), "metric variant is unknown")
        key = (name, start, duration)
        variants.setdefault(key, set())
        require(variant not in variants[key], "metric variant is duplicated")
        variants[key].add(variant)
        layer = table.scalar(row, indices["layer"], "metric layer")
        _integer(layer, "metric layer")
        layers.add(layer)
        if variant != 0:
            continue
        frames = _integer(table.scalar(row, indices["frames"], "frame count"),
                          "frame count", 1)
        minimum = Decimal(0)
        value = _decimal(table.scalar(row, indices["value"], "metric value"),
                         "metric value", minimum, name == FRAME_INTERVAL_NAME)
        window = (start, duration)
        require(window not in domains[name], "mean metric window is duplicated")
        domains[name][window] = (frames, value)
    require(len(layers) == 1, "metrics do not identify exactly one layer")
    require(domains[FRAME_INTERVAL_NAME] and domains[GPU_ACTIVE_NAME],
            "required metric domain is empty")
    require(all(value == {0, 1, 2, 3} for value in variants.values()),
            "metric window lacks the exact variant domain")
    require(domains[FRAME_INTERVAL_NAME].keys() ==
            domains[GPU_ACTIVE_NAME].keys(),
            "frame and GPU metric windows differ")
    windows = tuple(domains[FRAME_INTERVAL_NAME].keys())
    extent_ns, maximum_gap = _continuous_window_extent(
        windows, "metric window", toc_duration * Decimal(1_000_000_000))
    require(extent_ns >= minimum_seconds * 1_000_000_000,
            "metric window coverage is too short")
    frame_count = 0
    gpu_count = 0
    weighted_frame = Decimal(0)
    weighted_gpu = Decimal(0)
    for window in windows:
        frames, frame_value = domains[FRAME_INTERVAL_NAME][window]
        gpu_frames, gpu_value = domains[GPU_ACTIVE_NAME][window]
        require(frames == gpu_frames, "metric window frame counts differ")
        frame_count += frames
        gpu_count += gpu_frames
        weighted_frame += frame_value * frames
        weighted_gpu += gpu_value * gpu_frames
    require(frame_count > 0 and frame_count == gpu_count,
            "metric sample counts differ")
    mean_frame = weighted_frame / frame_count
    mean_fps = Decimal(1000) / mean_frame
    mean_gpu = weighted_gpu / gpu_count
    return frame_count, gpu_count, Decimal(extent_ns) / Decimal(1_000_000_000), \
        maximum_gap, mean_fps, mean_gpu


def validate_thermal(raw: bytes, minimum_window: Decimal,
                     toc_duration: Decimal) -> tuple[Decimal, int, list[str]]:
    table = ExportTable(raw, THERMAL_SCHEMA, "thermal export")
    start_index = table.index("start", "start-time")
    duration_index = table.index("duration", "duration")
    state_index = table.index(THERMAL_COLUMN, "thermal-state")
    track_index = table.index("track-label", "string")
    induced_index = table.index("is-induced", "boolean")
    windows: list[tuple[int, int]] = []
    states: list[str] = []
    for row in table.rows:
        require(table.scalar(row, track_index, "thermal track") == "Current",
                "thermal row is not the Current track")
        require(table.scalar(row, induced_index, "thermal induction") == "0",
                "thermal state is induced")
        start = _integer(table.scalar(row, start_index, "thermal start"),
                         "thermal start")
        duration = _integer(table.scalar(row, duration_index,
                                         "thermal duration"),
                            "thermal duration", 1)
        state = table.scalar(row, state_index, "thermal state")
        require(state in THERMAL_STATES, "thermal state is unknown")
        windows.append((start, duration))
        if state not in states:
            states.append(state)
    extent_ns, maximum_gap = _continuous_window_extent(
        windows, "thermal window", toc_duration * Decimal(1_000_000_000))
    coverage = Decimal(extent_ns) / Decimal(1_000_000_000)
    require(coverage + Decimal(MODELER_BOUNDARY_TOLERANCE_NS) /
            Decimal(1_000_000_000) >= minimum_window,
            "thermal coverage is shorter than metric coverage")
    return coverage, maximum_gap, states


def atomic_no_clobber(path: pathlib.Path, raw: bytes) -> None:
    require(path.is_absolute() and SAFE_LEAF_RE.fullmatch(path.name) is not None,
            "summary output must be an absolute safe leaf")
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
            require(written > 0, "summary write made no progress")
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
        raise ValidationError("summary output already exists") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if not linked:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
        os.close(directory)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    exact_options = (
        "--trace", "--toc", "--metrics-export", "--thermal-export",
        "--output", "--commit-output", "--role", "--run-id", "--parent-sha", "--tempest-sha",
        "--bundle-id", "--team-id", "--device-udid", "--process-id",
        "--save-slot", "--fps-limit", "--settle-seconds", "--trace-seconds",
        "--tool-version", "--tool-build",
    )
    require(all(argv.count(option) == 1 for option in exact_options),
            "validator options are not present exactly once")
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True, type=pathlib.Path)
    parser.add_argument("--toc", required=True, type=pathlib.Path)
    parser.add_argument("--metrics-export", required=True, type=pathlib.Path)
    parser.add_argument("--thermal-export", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--commit-output", required=True, type=pathlib.Path)
    parser.add_argument("--role", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--parent-sha", required=True)
    parser.add_argument("--tempest-sha", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--device-udid", required=True)
    parser.add_argument("--process-id", required=True, type=int)
    parser.add_argument("--save-slot", required=True, type=int)
    parser.add_argument("--fps-limit", required=True, type=int)
    parser.add_argument("--settle-seconds", required=True, type=int)
    parser.add_argument("--trace-seconds", required=True, type=int)
    parser.add_argument("--tool-version", required=True)
    parser.add_argument("--tool-build", required=True)
    return parser.parse_args(argv)


def validate_arguments(args: argparse.Namespace) -> None:
    require(type(args.role) is str and
            args.role in ("base-off-performance", "candidate-off-performance"),
            "role is not a performance role")
    require(RUN_RE.fullmatch(args.run_id) is not None, "run ID is invalid")
    require(SHA40_RE.fullmatch(args.parent_sha) is not None,
            "parent SHA is invalid")
    require(SHA40_RE.fullmatch(args.tempest_sha) is not None,
            "Tempest SHA is invalid")
    require(BUNDLE_RE.fullmatch(args.bundle_id) is not None,
            "bundle ID is invalid")
    require(TEAM_RE.fullmatch(args.team_id) is not None, "team ID is invalid")
    require(DEVICE_RE.fullmatch(args.device_udid) is not None,
            "device UDID is invalid")
    require(type(args.process_id) is int and args.process_id > 0,
            "process ID is invalid")
    require(type(args.tool_version) is str and
            type(args.tool_build) is str and
            TOOL_VERSION_RE.fullmatch(args.tool_version) is not None and
            TOOL_BUILD_RE.fullmatch(args.tool_build) is not None,
            "xctrace version/build identity is invalid")
    require(all(type(value) is int for value in
                (args.save_slot, args.fps_limit, args.settle_seconds,
                 args.trace_seconds)) and
            args.save_slot == 4 and args.fps_limit == 30 and
            args.settle_seconds == 12 and 30 <= args.trace_seconds <= 600,
            "performance settings differ from the frozen contract")
    for path in (args.trace, args.toc, args.metrics_export,
                 args.thermal_export, args.output, args.commit_output):
        require(path.is_absolute() and SAFE_LEAF_RE.fullmatch(path.name) is not None,
                "evidence path is not an absolute safe leaf")
    require(args.output.name == "performance-trace-summary-v1.json",
            "summary output leaf differs")
    require(args.commit_output.name == "performance-evidence-commit-v1.json",
            "commit output leaf differs")
    require(len({path.parent for path in (args.trace, args.toc,
                args.metrics_export, args.thermal_export, args.output,
                args.commit_output)}) == 1,
            "evidence members do not share one staging directory")
    prefix = f"performance-{args.role}-{args.run_id}"
    require((args.trace.name, args.toc.name, args.metrics_export.name,
             args.thermal_export.name) ==
            (f"{prefix}.trace", f"{prefix}-toc.xml",
             f"{prefix}-metrics.xml", f"{prefix}-thermal.xml"),
            "run evidence leaves differ from canonical identity")


def verify_tool_identity(version: str, build: str) -> None:
    try:
        result = subprocess.run(("/usr/bin/xctrace", "version"),
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=10,
                                check=False)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValidationError(f"xctrace identity query failed: {error}") from error
    require(result.returncode == 0 and result.stderr == b"" and
            result.stdout == f"xctrace version {version} ({build})\n".encode(),
            "xctrace runtime identity differs from summary provenance")


def build_summary(args: argparse.Namespace) -> dict[str, Any]:
    validate_arguments(args)
    verify_tool_identity(args.tool_version, args.tool_build)
    trace_files, trace_bytes, trace_sha = trace_manifest(args.trace)
    toc_raw = regular_bytes(args.toc, "TOC")
    metrics_raw = regular_bytes(args.metrics_export, "metrics export")
    thermal_raw = regular_bytes(args.thermal_export, "thermal export")
    toc_duration = validate_toc(toc_raw, args.device_udid, args.process_id,
                                args.trace_seconds)
    fps_count, gpu_count, metric_window, metric_gap, mean_fps, mean_gpu = \
        validate_metrics(metrics_raw, args.process_id, args.trace_seconds,
                         toc_duration)
    thermal_window, thermal_gap, thermal_states = validate_thermal(
        thermal_raw, metric_window, toc_duration)
    summary = {
        "schemaVersion": 1,
        "evidenceClass": "renderer-ios-performance-trace-summary",
        "role": args.role,
        "identity": {
            "runId": args.run_id,
            "parentSha": args.parent_sha,
            "tempestSha": args.tempest_sha,
            "bundleId": args.bundle_id,
            "teamId": args.team_id,
            "deviceUdid": args.device_udid,
            "processId": args.process_id,
        },
        "settings": {
            "saveSlot": args.save_slot,
            "fpsLimit": args.fps_limit,
            "settleSeconds": args.settle_seconds,
            "traceSeconds": args.trace_seconds,
            "modelerBoundaryToleranceNanoseconds": MODELER_BOUNDARY_TOLERANCE_NS,
        },
        "source": {
            "tool": "/usr/bin/xctrace",
            "toolVersion": args.tool_version,
            "toolBuild": args.tool_build,
            "template": TEMPLATE,
            "evidenceDirectory": f"performance-evidence-{args.role}-{args.run_id}",
            "traceLeaf": args.trace.name,
            "traceKind": "directory",
            "traceFiles": trace_files,
            "traceBytes": trace_bytes,
            "traceManifestSha256": trace_sha,
            "tocFile": args.toc.name,
            "tocBytes": len(toc_raw),
            "tocSha256": sha256(toc_raw),
            "metricsExportFile": args.metrics_export.name,
            "metricsExportBytes": len(metrics_raw),
            "metricsExportSha256": sha256(metrics_raw),
            "thermalExportFile": args.thermal_export.name,
            "thermalExportBytes": len(thermal_raw),
            "thermalExportSha256": sha256(thermal_raw),
            "commitFile": args.commit_output.name,
            "metricTableSchema": METRIC_SCHEMA,
            "metricNameColumn": METRIC_NAME_COLUMN,
            "metricVariantColumn": METRIC_VARIANT_COLUMN,
            "frameCountColumn": FRAME_COUNT_COLUMN,
            "processIdColumn": PROCESS_ID_COLUMN,
            "frameIntervalMetricName": FRAME_INTERVAL_NAME,
            "gpuActiveMetricName": GPU_ACTIVE_NAME,
            "valueMillisecondsColumn": VALUE_COLUMN,
            "thermalTableSchema": THERMAL_SCHEMA,
            "thermalStateColumn": THERMAL_COLUMN,
        },
        "metrics": {
            "fpsSampleCount": fps_count,
            "gpuActiveSampleCount": gpu_count,
            "tocDurationSeconds": float(toc_duration),
            "metricWindowSeconds": float(metric_window),
            "thermalWindowSeconds": float(thermal_window),
            "maximumMetricBoundaryGapNanoseconds": metric_gap,
            "maximumThermalBoundaryGapNanoseconds": thermal_gap,
            "meanFps": float(mean_fps),
            "meanGpuActiveMilliseconds": float(mean_gpu),
            "thermalStates": thermal_states,
        },
        "terminal": "PERFORMANCE PASS",
    }
    for value in (summary["metrics"]["tocDurationSeconds"],
                  summary["metrics"]["metricWindowSeconds"],
                  summary["metrics"]["thermalWindowSeconds"],
                  summary["metrics"]["meanFps"],
                  summary["metrics"]["meanGpuActiveMilliseconds"]):
        require(math.isfinite(value), "summary contains a non-finite metric")
    return summary


def build_commit(summary: dict[str, Any], summary_raw: bytes) -> dict[str, Any]:
    source = summary["source"]
    members = [
        {
            "leaf": source["traceLeaf"], "kind": "directory",
            "files": source["traceFiles"], "bytes": source["traceBytes"],
            "sha256": source["traceManifestSha256"],
        },
        {
            "leaf": source["tocFile"], "kind": "file", "files": 1,
            "bytes": source["tocBytes"], "sha256": source["tocSha256"],
        },
        {
            "leaf": source["metricsExportFile"], "kind": "file", "files": 1,
            "bytes": source["metricsExportBytes"],
            "sha256": source["metricsExportSha256"],
        },
        {
            "leaf": source["thermalExportFile"], "kind": "file", "files": 1,
            "bytes": source["thermalExportBytes"],
            "sha256": source["thermalExportSha256"],
        },
        {
            "leaf": "performance-trace-summary-v1.json", "kind": "file",
            "files": 1, "bytes": len(summary_raw), "sha256": sha256(summary_raw),
        },
    ]
    stream = bytearray(EVIDENCE_SET_DOMAIN)
    for member in members:
        leaf = member["leaf"].encode("utf-8", "strict")
        require(SAFE_LEAF_RE.fullmatch(member["leaf"]) is not None and
                member["kind"] in ("directory", "file") and
                type(member["files"]) is int and member["files"] > 0 and
                type(member["bytes"]) is int and member["bytes"] > 0 and
                SHA64_RE.fullmatch(member["sha256"]) is not None,
                "commit member metadata is invalid")
        stream += struct.pack("<I", len(leaf)) + leaf
        stream += b"D" if member["kind"] == "directory" else b"F"
        stream += struct.pack("<Q", member["files"])
        stream += struct.pack("<Q", member["bytes"])
        stream += bytes.fromhex(member["sha256"])
    return {
        "schemaVersion": 1,
        "evidenceClass": "renderer-ios-performance-evidence-commit",
        "runId": summary["identity"]["runId"],
        "role": summary["role"],
        "members": members,
        "setSha256": sha256(bytes(stream)),
        "terminal": "PERFORMANCE EVIDENCE COMMIT",
    }


def exact_staging_members(args: argparse.Namespace, include_commit: bool) -> None:
    expected = {
        args.trace.name, args.toc.name, args.metrics_export.name,
        args.thermal_export.name, args.output.name,
    }
    if include_commit:
        expected.add(args.commit_output.name)
    try:
        actual = set(os.listdir(args.output.parent))
    except OSError as error:
        raise ValidationError(f"cannot enumerate staging set: {error}") from error
    require(actual == expected, "staging evidence member set is not exact")


def validate_evidence_directory(
        path: pathlib.Path | str, expected_role: str,
        expected_identity: Mapping[str, Any],
        expected_settings: Mapping[str, Any]) -> dict[str, Any]:
    """Revalidate one atomically published performance evidence directory."""
    directory = pathlib.Path(path)
    require(directory.is_absolute(), "evidence directory path is not absolute")
    before = directory.lstat()
    require(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode),
            "evidence directory is not a non-symlink directory")
    exact_keys(expected_identity, IDENTITY_KEYS, "expected identity")
    exact_keys(expected_settings, SETTINGS_KEYS, "expected settings")
    require(expected_settings["modelerBoundaryToleranceNanoseconds"] ==
            MODELER_BOUNDARY_TOLERANCE_NS,
            "expected modeler tolerance differs")
    run_id = expected_identity["runId"]
    require(type(expected_role) is str and type(run_id) is str,
            "expected evidence identity types differ")
    require(directory.name ==
            f"performance-evidence-{expected_role}-{run_id}",
            "evidence directory leaf differs")
    prefix = f"performance-{expected_role}-{run_id}"
    leaves = (
        f"{prefix}.trace", f"{prefix}-toc.xml",
        f"{prefix}-metrics.xml", f"{prefix}-thermal.xml",
        "performance-trace-summary-v1.json",
        "performance-evidence-commit-v1.json",
    )
    require(tuple(sorted(os.listdir(directory))) == tuple(sorted(leaves)),
            "published evidence member set is not exact")
    summary_path = directory / leaves[4]
    commit_path = directory / leaves[5]
    summary_raw = regular_bytes(summary_path, "summary", 1024 * 1024)
    summary = canonical_json_value(summary_raw, "summary")
    exact_keys(summary, SUMMARY_ROOT_KEYS, "summary root")
    exact_keys(summary.get("identity"), IDENTITY_KEYS, "summary identity")
    exact_keys(summary.get("settings"), SETTINGS_KEYS, "summary settings")
    exact_keys(summary.get("source"), SOURCE_KEYS, "summary source")
    exact_keys(summary.get("metrics"), METRICS_KEYS, "summary metrics")
    require(summary["role"] == expected_role and
            summary["identity"] == dict(expected_identity) and
            summary["settings"] == dict(expected_settings),
            "summary expected identity/settings differ")
    source = summary["source"]
    args = argparse.Namespace(
        trace=directory / leaves[0], toc=directory / leaves[1],
        metrics_export=directory / leaves[2],
        thermal_export=directory / leaves[3], output=summary_path,
        commit_output=commit_path, role=expected_role, run_id=run_id,
        parent_sha=expected_identity["parentSha"],
        tempest_sha=expected_identity["tempestSha"],
        bundle_id=expected_identity["bundleId"],
        team_id=expected_identity["teamId"],
        device_udid=expected_identity["deviceUdid"],
        process_id=expected_identity["processId"],
        save_slot=expected_settings["saveSlot"],
        fps_limit=expected_settings["fpsLimit"],
        settle_seconds=expected_settings["settleSeconds"],
        trace_seconds=expected_settings["traceSeconds"],
        tool_version=source["toolVersion"], tool_build=source["toolBuild"],
    )
    recomputed = build_summary(args)
    require(summary == recomputed and canonical_json(recomputed) == summary_raw,
            "summary does not match recomputed evidence")
    commit_raw = regular_bytes(commit_path, "commit", 1024 * 1024)
    commit = canonical_json_value(commit_raw, "commit")
    exact_keys(commit, COMMIT_ROOT_KEYS, "commit root")
    require(type(commit.get("members")) is list and
            all(type(member) is dict for member in commit["members"]),
            "commit members are not objects")
    for member in commit["members"]:
        exact_keys(member, COMMIT_MEMBER_KEYS, "commit member")
    require(commit == build_commit(recomputed, summary_raw),
            "commit does not match recomputed evidence set")
    require(_stat_identity(before) == _stat_identity(directory.lstat()),
            "evidence directory changed while validated")
    return recomputed


def main(argv: Sequence[str]) -> int:
    try:
        args = parse_args(argv)
        summary = build_summary(args)
        summary_raw = canonical_json(summary)
        atomic_no_clobber(args.output, summary_raw)
        exact_staging_members(args, False)
        commit_raw = canonical_json(build_commit(summary, summary_raw))
        atomic_no_clobber(args.commit_output, commit_raw)
        exact_staging_members(args, True)
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PERFORMANCE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
