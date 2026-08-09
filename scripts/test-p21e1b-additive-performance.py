#!/usr/bin/env python3
"""Host and mutation tests for the P2.1e1b performance collector."""

from __future__ import annotations

import contextlib
import io
import json
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
from typing import Callable
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
COLLECTOR = ROOT / "ios/device-test/run-additive-performance-test.sh"
VALIDATOR = ROOT / "ios/device-test/validate-additive-performance-trace.py"
SHA = "1" * 40
TEMPEST = "2" * 40
RUN_ID = "3" * 32
DEVICE = "00008130-000564403E12001C"
PID = "35073"
TOOL_VERSION = "27.0"
TOOL_BUILD = "27A5228h"
SET_DOMAIN = b"opengothic-performance-evidence-set-v1\0"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def metric_export() -> str:
    columns = (
        ("start", "start-time"),
        ("duration", "duration"),
        ("value-in-ms", "fixed-decimal"),
        ("number-of-frames", "uint64"),
        ("metric", "uint32"),
        ("metric-variant", "uint32"),
        ("name", "metal-performance-overview-layer-duration-metric-name"),
        ("process", "process"),
        ("layer-id", "uint64"),
    )
    schema = "".join(
        f"<col><mnemonic>{name}</mnemonic><name>{name}</name>"
        f"<engineering-type>{kind}</engineering-type></col>"
        for name, kind in columns)
    rows: list[str] = []
    for start in (0, 15_000_000_000):
        for metric, name, value in (
            (0, "0.Frame Interval", "40"),
            (4, "4.GPU Active Time", "10"),
        ):
            for variant in range(4):
                rows.append(
                    "<row>"
                    f"<start-time>{start}</start-time>"
                    "<duration>15000000000</duration>"
                    f"<fixed-decimal>{value}</fixed-decimal>"
                    "<uint64>450</uint64>"
                    f"<uint32>{metric}</uint32>"
                    f"<uint32>{variant}</uint32>"
                    f"<metric-name>{name}</metric-name>"
                    f"<process><pid>{PID}</pid></process>"
                    "<uint64>99</uint64>"
                    "</row>")
    return ("<?xml version=\"1.0\"?><trace-query-result><node>"
            "<schema name=\"metal-perf-overview-layer-duration-metric\">" +
            schema + "</schema>" + "".join(rows) +
            "</node></trace-query-result>\n")


def thermal_export() -> str:
    return f"""<?xml version="1.0"?>
<trace-query-result><node>
<schema name="device-thermal-state-intervals">
<col><mnemonic>start</mnemonic><name>Start</name><engineering-type>start-time</engineering-type></col>
<col><mnemonic>duration</mnemonic><name>Duration</name><engineering-type>duration</engineering-type></col>
<col><mnemonic>thermal-state</mnemonic><name>State</name><engineering-type>thermal-state</engineering-type></col>
<col><mnemonic>track-label</mnemonic><name>Track</name><engineering-type>string</engineering-type></col>
<col><mnemonic>is-induced</mnemonic><name>Induced</name><engineering-type>boolean</engineering-type></col>
</schema>
<row><start-time>0</start-time><duration>30000000000</duration><thermal-state id="7">Nominal</thermal-state><string>Current</string><boolean>0</boolean></row>
</node></trace-query-result>
"""


def toc() -> str:
    return f"""<?xml version="1.0"?>
<trace-toc><run number="1"><info><target>
<device uuid="{DEVICE}"/><process type="attached" pid="{PID}"/>
</target><summary><duration>30.5</duration><end-reason>Time limit reached</end-reason>
<template-name>Game Performance Overview</template-name><time-limit>30 seconds</time-limit>
<intruments-recording-settings><instrument name="Metal Performance Overview"><options>
<option key="Game Performance Overview Per-Frame Metrics" value="Enabled"/>
<option key="Game Performance Overview Shader Compilation Metrics" value="Disabled"/>
</options></instrument></intruments-recording-settings>
</summary></info><data>
<table schema="metal-perf-overview-layer-duration-metric"/>
<table schema="device-thermal-state-intervals"/>
</data></run></trace-toc>
"""


def write_fixture(root: Path) -> tuple[Path, Path, Path, Path, Path, Path]:
    trace = root / "performance-base-off-performance-33333333333333333333333333333333.trace"
    trace.mkdir()
    (trace / "zero.bin").write_bytes(b"")
    nested = trace / "Data"
    nested.mkdir()
    (nested / "sample.bin").write_bytes(b"trace-payload")
    toc_path = root / "performance-base-off-performance-33333333333333333333333333333333-toc.xml"
    metric_path = root / "performance-base-off-performance-33333333333333333333333333333333-metrics.xml"
    thermal_path = root / "performance-base-off-performance-33333333333333333333333333333333-thermal.xml"
    output = root / "performance-trace-summary-v1.json"
    commit = root / "performance-evidence-commit-v1.json"
    toc_path.write_text(toc(), encoding="utf-8")
    metric_path.write_text(metric_export(), encoding="utf-8")
    thermal_path.write_text(thermal_export(), encoding="utf-8")
    return trace, toc_path, metric_path, thermal_path, output, commit


def command(paths: tuple[Path, Path, Path, Path, Path, Path]) -> list[str]:
    trace, toc_path, metric_path, thermal_path, output, commit = paths
    return [
        sys.executable, str(VALIDATOR),
        "--trace", str(trace), "--toc", str(toc_path),
        "--metrics-export", str(metric_path),
        "--thermal-export", str(thermal_path), "--output", str(output),
        "--commit-output", str(commit),
        "--role", "base-off-performance", "--run-id", RUN_ID,
        "--parent-sha", SHA, "--tempest-sha", TEMPEST,
        "--bundle-id", "opengothic.gothic2.RMJWWPF379",
        "--team-id", "RMJWWPF379", "--device-udid", DEVICE,
        "--process-id", PID, "--save-slot", "4", "--fps-limit", "30",
        "--settle-seconds", "12", "--trace-seconds", "30",
        "--tool-version", TOOL_VERSION, "--tool-build", TOOL_BUILD,
    ]


def load_validator(*, deterministic_tool_identity: bool = True):
    spec = importlib.util.spec_from_file_location(
        "p21e1b_performance_validator", VALIDATOR)
    require(spec is not None and spec.loader is not None,
            "validator import spec is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if deterministic_tool_identity:
        def verify_fixture_identity(version: str, build: str) -> None:
            if (version, build) != (TOOL_VERSION, TOOL_BUILD):
                raise module.ValidationError(
                    "xctrace runtime identity differs from host fixture")
        module.verify_tool_identity = verify_fixture_identity
    return module


def run_validator_argv(argv: list[str]) -> subprocess.CompletedProcess[str]:
    module = load_validator()
    stdout = io.StringIO()
    stderr = io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        try:
            returncode = module.main(argv)
        except SystemExit as error:
            returncode = error.code if isinstance(error.code, int) else 1
    return subprocess.CompletedProcess(
        [sys.executable, str(VALIDATOR), *argv], returncode,
        stdout.getvalue(), stderr.getvalue())


def run_validator(paths: tuple[Path, Path, Path, Path, Path, Path]) -> subprocess.CompletedProcess[str]:
    return run_validator_argv(command(paths)[2:])


def tool_identity_verifier_tests() -> int:
    module = load_validator(deterministic_tool_identity=False)
    argv = ("/usr/bin/xctrace", "version")
    kwargs = {
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
        "timeout": 10,
        "check": False,
    }
    valid_stdout = f"xctrace version {TOOL_VERSION} ({TOOL_BUILD})\n".encode()

    def invoke(result: subprocess.CompletedProcess[bytes], *, reject: bool) -> None:
        with mock.patch.object(module.subprocess, "run", return_value=result) as run:
            try:
                module.verify_tool_identity(TOOL_VERSION, TOOL_BUILD)
            except module.ValidationError:
                require(reject, "valid xctrace identity was rejected")
            else:
                require(not reject, "invalid xctrace identity was accepted")
            require(run.call_count == 1 and run.call_args.args == (argv,) and
                    run.call_args.kwargs == kwargs,
                    "xctrace identity query argv/options differ")

    invoke(subprocess.CompletedProcess(argv, 0, valid_stdout, b""),
           reject=False)
    mutants = (
        subprocess.CompletedProcess(argv, 1, valid_stdout, b""),
        subprocess.CompletedProcess(argv, 0, valid_stdout, b"warning\n"),
        subprocess.CompletedProcess(
            argv, 0, f"xctrace version 27.1 ({TOOL_BUILD})\n".encode(), b""),
        subprocess.CompletedProcess(
            argv, 0, f"xctrace version {TOOL_VERSION} (27A0000a)\n".encode(),
            b""),
    )
    for result in mutants:
        invoke(result, reject=True)
    return len(mutants)


def expected_identity() -> dict[str, object]:
    return {
        "runId": RUN_ID, "parentSha": SHA, "tempestSha": TEMPEST,
        "bundleId": "opengothic.gothic2.RMJWWPF379",
        "teamId": "RMJWWPF379", "deviceUdid": DEVICE,
        "processId": int(PID),
    }


def expected_settings() -> dict[str, object]:
    return {
        "saveSlot": 4, "fpsLimit": 30, "settleSeconds": 12,
        "traceSeconds": 30, "modelerBoundaryToleranceNanoseconds": 50,
    }


def validate_good_summary() -> None:
    with tempfile.TemporaryDirectory(prefix="p21e1b-performance-") as temporary:
        directory = (Path(temporary) /
                     f"performance-evidence-base-off-performance-{RUN_ID}")
        directory.mkdir()
        paths = write_fixture(directory)
        result = run_validator(paths)
        require(result.returncode == 0, result.stderr)
        require(result.stdout == "PERFORMANCE PASS\n", "validator terminal differs")
        raw = paths[4].read_bytes()
        value = json.loads(raw)
        require(raw == (json.dumps(value, ensure_ascii=False,
                                   separators=(",", ":")) + "\n").encode(),
                "summary is not canonical LF JSON")
        require(tuple(value) == ("schemaVersion", "evidenceClass", "role",
                                 "identity", "settings", "source", "metrics",
                                 "terminal"), "summary root order differs")
        require(tuple(value["identity"]) ==
                ("runId", "parentSha", "tempestSha", "bundleId", "teamId",
                 "deviceUdid", "processId"), "identity order differs")
        require(tuple(value["settings"]) ==
                ("saveSlot", "fpsLimit", "settleSeconds", "traceSeconds",
                 "modelerBoundaryToleranceNanoseconds"),
                "settings order differs")
        require(value["settings"] == {
            "saveSlot": 4,
            "fpsLimit": 30,
            "settleSeconds": 12,
            "traceSeconds": 30,
            "modelerBoundaryToleranceNanoseconds": 50,
        }, "settings differ")
        require(tuple(value["source"]) == (
            "tool", "toolVersion", "toolBuild", "template",
            "evidenceDirectory", "traceLeaf", "traceKind", "traceFiles",
            "traceBytes", "traceManifestSha256", "tocFile", "tocBytes",
            "tocSha256", "metricsExportFile", "metricsExportBytes",
            "metricsExportSha256", "thermalExportFile", "thermalExportBytes",
            "thermalExportSha256", "commitFile", "metricTableSchema",
            "metricNameColumn", "metricVariantColumn", "frameCountColumn",
            "processIdColumn", "frameIntervalMetricName",
            "gpuActiveMetricName", "valueMillisecondsColumn",
            "thermalTableSchema", "thermalStateColumn"),
                "source order differs")
        require(value["source"]["toolVersion"] == TOOL_VERSION and
                value["source"]["toolBuild"] == TOOL_BUILD and
                value["source"]["evidenceDirectory"] == directory.name,
                "source tool/directory identity differs")
        require(tuple(value["metrics"]) ==
                ("fpsSampleCount", "gpuActiveSampleCount",
                 "tocDurationSeconds", "metricWindowSeconds",
                 "thermalWindowSeconds", "maximumMetricBoundaryGapNanoseconds",
                 "maximumThermalBoundaryGapNanoseconds", "meanFps",
                 "meanGpuActiveMilliseconds", "thermalStates"),
                "metrics order differs")
        require(value["metrics"] == {
            "fpsSampleCount": 900,
            "gpuActiveSampleCount": 900,
            "tocDurationSeconds": 30.5,
            "metricWindowSeconds": 30.0,
            "thermalWindowSeconds": 30.0,
            "maximumMetricBoundaryGapNanoseconds": 0,
            "maximumThermalBoundaryGapNanoseconds": 0,
            "meanFps": 25.0,
            "meanGpuActiveMilliseconds": 10.0,
            "thermalStates": ["Nominal"],
        }, "weighted metrics differ")
        commit_raw = paths[5].read_bytes()
        commit = json.loads(commit_raw)
        require(commit_raw == (json.dumps(commit, separators=(",", ":")) +
                               "\n").encode(), "commit is not canonical")
        require(tuple(commit) == ("schemaVersion", "evidenceClass", "runId",
                                  "role", "members", "setSha256", "terminal"),
                "commit root order differs")
        require(len(commit["members"]) == 5 and
                commit["terminal"] == "PERFORMANCE EVIDENCE COMMIT",
                "commit member domain differs")
        require(all(tuple(member) ==
                    ("leaf", "kind", "files", "bytes", "sha256")
                    for member in commit["members"]),
                "commit member key order differs")
        stream = bytearray(SET_DOMAIN)
        for member in commit["members"]:
            leaf = member["leaf"].encode()
            stream += struct.pack("<I", len(leaf)) + leaf
            stream += b"D" if member["kind"] == "directory" else b"F"
            stream += struct.pack("<Q", member["files"])
            stream += struct.pack("<Q", member["bytes"])
            stream += bytes.fromhex(member["sha256"])
        require(commit["setSha256"] == hashlib.sha256(stream).hexdigest(),
                "commit set hash domain differs")
        module = load_validator()
        revalidated = module.validate_evidence_directory(
            directory, "base-off-performance", expected_identity(),
            expected_settings())
        require(revalidated == value, "directory validation API drifted")


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    require(text.count(old) >= 1, "mutation anchor drift: " + old)
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def replace_all(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    require(old in text, "mutation anchor drift: " + old)
    path.write_text(text.replace(old, new), encoding="utf-8")


def write_thermal_windows(path: Path, second_start: int) -> None:
    text = thermal_export()
    row = '<row><start-time>0</start-time><duration>30000000000</duration><thermal-state id="7">Nominal</thermal-state><string>Current</string><boolean>0</boolean></row>'
    replacement = (
        '<row><start-time>0</start-time><duration>15000000000</duration><thermal-state id="7">Nominal</thermal-state><string>Current</string><boolean>0</boolean></row>'
        f'<row><start-time>{second_start}</start-time><duration>15000000000</duration><thermal-state>Fair</thermal-state><string>Current</string><boolean>0</boolean></row>')
    require(row in text, "thermal mutation anchor drift")
    path.write_text(text.replace(row, replacement), encoding="utf-8")


def mutation_tests() -> int:
    mutations: list[Callable[[tuple[Path, Path, Path, Path, Path, Path]], None]] = [
        lambda p: replace_once(p[1], "Game Performance Overview", "Game Performance"),
        lambda p: replace_once(p[1], '<table schema="metal-perf-overview-layer-duration-metric"/>', ""),
        lambda p: replace_once(p[1], '<table schema="device-thermal-state-intervals"/>', '<table schema="device-thermal-state-intervals"/><table schema="device-thermal-state-intervals"/>'),
        lambda p: replace_once(p[1], f'pid="{PID}"', 'pid="7"'),
        lambda p: replace_once(p[1], "<duration>30.5</duration>", "<duration>29.9</duration>"),
        lambda p: replace_once(p[1], 'value="Enabled"', 'value="Disabled"'),
        lambda p: replace_once(p[2], 'name="metal-perf-overview-layer-duration-metric"', 'name="wrong"'),
        lambda p: replace_once(p[2], "<mnemonic>metric-variant</mnemonic>", "<mnemonic>variant</mnemonic>"),
        lambda p: replace_once(p[2], "0.Frame Interval", "0.Frame Interval Wrong"),
        lambda p: replace_once(p[2], "<fixed-decimal>40</fixed-decimal>", "<fixed-decimal>NaN</fixed-decimal>"),
        lambda p: replace_once(p[2], "<fixed-decimal>10</fixed-decimal>", "<fixed-decimal>-1</fixed-decimal>"),
        lambda p: replace_once(p[2], "<uint32>0</uint32><metric-name>0.Frame Interval", "<uint32>1</uint32><metric-name>0.Frame Interval"),
        lambda p: replace_once(p[3], "Nominal", "Unknown"),
        lambda p: replace_once(p[3], "30000000000", "29999999000"),
        lambda p: replace_all(p[2], "<start-time>15000000000</start-time>", "<start-time>45000000000</start-time>"),
        lambda p: replace_all(p[2], "<start-time>15000000000</start-time>", "<start-time>14999999900</start-time>"),
        lambda p: write_thermal_windows(p[3], 45_000_000_000),
        lambda p: write_thermal_windows(p[3], 14_999_999_900),
        lambda p: replace_once(p[3], "30000000000", "30500002000"),
        lambda p: (p[0].parent / "unexpected.txt").write_text("extra", encoding="utf-8"),
        lambda p: replace_once(p[3], "<?xml version=\"1.0\"?>", "<!DOCTYPE x [<!ENTITY y 'z'>]><x/>"),
        lambda p: p[4].write_text("summary collision", encoding="utf-8"),
        lambda p: p[5].write_text("commit collision", encoding="utf-8"),
    ]
    killed = 0
    for index, mutate in enumerate(mutations):
        with tempfile.TemporaryDirectory(prefix="p21e1b-performance-mutant-") as temporary:
            paths = write_fixture(Path(temporary))
            mutate(paths)
            result = run_validator(paths)
            if result.returncode != 0:
                killed += 1
            else:
                raise RuntimeError(f"fake export mutation survived: {index}")
    with tempfile.TemporaryDirectory(prefix="p21e1b-performance-symlink-") as temporary:
        root = Path(temporary)
        paths = write_fixture(root)
        (paths[0] / "link").symlink_to(root / "outside")
        result = run_validator(paths)
        require(result.returncode != 0, "trace symlink mutation survived")
        killed += 1
    with tempfile.TemporaryDirectory(prefix="p21e1b-performance-duplicate-") as temporary:
        paths = write_fixture(Path(temporary))
        result = run_validator_argv(
            command(paths)[2:] + ["--role", "base-off-performance"])
        require(result.returncode != 0, "duplicate validator option survived")
        killed += 1
    for option, wrong in (("--tool-version", "27.1"),
                          ("--tool-build", "27A0000a")):
        with tempfile.TemporaryDirectory(
                prefix="p21e1b-performance-tool-identity-") as temporary:
            paths = write_fixture(Path(temporary))
            mutant = command(paths)[2:]
            mutant[mutant.index(option) + 1] = wrong
            result = run_validator_argv(mutant)
            require(result.returncode != 0,
                    f"wrong xctrace identity survived: {option}")
            killed += 1
    return killed


def evidence_directory_mutations() -> int:
    module = load_validator()

    def validate(directory: Path) -> None:
        module.validate_evidence_directory(
            directory, "base-off-performance", expected_identity(),
            expected_settings())

    killed = 0
    mutations: tuple[Callable[[Path], None], ...] = (
        lambda directory: (directory / "performance-evidence-commit-v1.json").unlink(),
        lambda directory: (directory / "unexpected.txt").write_text(
            "partial", encoding="utf-8"),
        lambda directory: replace_once(
            directory / "performance-evidence-commit-v1.json",
            '"setSha256":"', '"setSha256":"0'),
        lambda directory: replace_once(
            directory / "performance-trace-summary-v1.json",
            '"tocDurationSeconds":30.5', '"tocDurationSeconds":30.25'),
    )
    for mutate in mutations:
        with tempfile.TemporaryDirectory(
                prefix="p21e1b-evidence-directory-mutant-") as temporary:
            directory = (Path(temporary) /
                         f"performance-evidence-base-off-performance-{RUN_ID}")
            directory.mkdir()
            paths = write_fixture(directory)
            result = run_validator(paths)
            require(result.returncode == 0, result.stderr)
            mutate(directory)
            try:
                validate(directory)
            except (OSError, module.ValidationError):
                killed += 1
            else:
                raise RuntimeError("published evidence directory mutation survived")
    with tempfile.TemporaryDirectory(
            prefix="p21e1b-evidence-directory-partial-") as temporary:
        directory = (Path(temporary) /
                     f"performance-evidence-base-off-performance-{RUN_ID}")
        directory.mkdir()
        write_fixture(directory)
        try:
            validate(directory)
        except (OSError, module.ValidationError):
            killed += 1
        else:
            raise RuntimeError("uncommitted partial evidence set survived")
    with tempfile.TemporaryDirectory(
            prefix="p21e1b-evidence-directory-symlink-") as temporary:
        root = Path(temporary)
        target = (root /
                  f"performance-evidence-base-off-performance-{RUN_ID}")
        target.mkdir()
        paths = write_fixture(target)
        result = run_validator(paths)
        require(result.returncode == 0, result.stderr)
        link = root / "link"
        link.symlink_to(target, target_is_directory=True)
        try:
            validate(link)
        except (OSError, module.ValidationError):
            killed += 1
        else:
            raise RuntimeError("symlink evidence directory survived")
    return killed


def ordered(text: str, tokens: tuple[str, ...]) -> bool:
    cursor = 0
    for token in tokens:
        index = text.find(token, cursor)
        if index < 0:
            return False
        cursor = index + len(token)
    return True


def validate_collector_source(source: str) -> None:
    once = (
        '"$(printf \'%s\' "$LIVE_PID_FILE" | LC_ALL=C tr -d \'[:cntrl:]\')" == "$LIVE_PID_FILE"',
        'XCTRACE_IDENTITY="$("$XCTRACE" version)"',
        'XCODE_IDENTITY="$(/usr/bin/xcodebuild -version)"',
        'LIVE_PID_VALUE="$(python3 - "$LIVE_PID_FILE"',
        'WORK="$EVIDENCE_DIR/.performance-$RUN_ID.tmp"',
        'PAYLOAD="$WORK/payload"',
        "run_bounded_tool() {",
        "except BaseException:",
        "require_exact_process before-settle",
        '/bin/sleep "$SETTLE_SECONDS"',
        "require_exact_process after-settle",
        'run_bounded_tool "$((TRACE_SECONDS + 120))" "$XCTRACE" record',
        "--template 'Game Performance Overview'",
        '--device "$DEVICE" --attach "$PID"',
        "require_exact_process after-record",
        'run_bounded_tool 120 "$XCTRACE" export --input "$TRACE_PATH" --toc',
        'table[@schema="metal-perf-overview-layer-duration-metric"]',
        'table[@schema="device-thermal-state-intervals"]',
        'VALIDATOR_TERMINAL="$(run_bounded_tool 300 python3 "$VALIDATOR"',
        '--output "$SUMMARY_PATH" --commit-output "$COMMIT_PATH"',
        'python3 - "$PAYLOAD" <<\'PY\' || fail "evidence durability flush failed"',
        'payload file changed before flush")\n            os.fsync(descriptor)',
        'directories.sort(key=lambda item: len(item[0].parts), reverse=True)',
        'payload directory changed before flush")\n        os.fsync(descriptor)',
        '[[ ! -e "$FINAL_PATH" && ! -L "$FINAL_PATH" ]]',
        'python3 - "$WORK" "$EVIDENCE_DIR" "$FINAL_LEAF"',
        "renameatx_np",
        'destination_leaf.encode("utf-8", "strict"), 0x4',
        '[[ ! -e "$PAYLOAD" && -d "$FINAL_PATH" && ! -L "$FINAL_PATH" ]]',
        "printf '%s\\n' 'PERFORMANCE PASS'",
    )
    for token in once:
        require(source.count(token) == 1, "collector required-once drift: " + token)
    require(ordered(source, once), "collector frozen operation order differs")
    require(source.count('run_bounded_tool 120 "$XCTRACE" export') == 3 and
            source.count('"$XCTRACE" export') == 3,
            "each xctrace export must have one bounded invocation")
    for forbidden in ("eval ", "--all-processes", "--launch --",
                      "Game Performance'", "publish_no_clobber", "/bin/mv -n"):
        require(forbidden not in source, "collector has forbidden behavior: " + forbidden)


def source_mutations(source: str) -> int:
    replacements = (
        ('XCTRACE_IDENTITY="$("$XCTRACE" version)"', 'XCTRACE_IDENTITY="xctrace version 27.0 (unknown)"'),
        ('XCODE_IDENTITY="$(/usr/bin/xcodebuild -version)"', 'XCODE_IDENTITY="Xcode 27.0"'),
        ('"$(printf \'%s\' "$LIVE_PID_FILE" | LC_ALL=C tr -d \'[:cntrl:]\')" == "$LIVE_PID_FILE"',
         '[[ -n "$LIVE_PID_FILE" ]] # controls accepted'),
        ("except BaseException:", "except Exception:"),
        ("require_exact_process before-settle", ": # removed before-settle"),
        ('/bin/sleep "$SETTLE_SECONDS"', ": # removed settle"),
        ('LIVE_PID_VALUE="$(python3 - "$LIVE_PID_FILE"', 'LIVE_PID_VALUE="$PID" #'),
        ("require_exact_process after-settle", ": # removed after-settle"),
        ('run_bounded_tool "$((TRACE_SECONDS + 120))" "$XCTRACE" record', '"$XCTRACE" record'),
        ("require_exact_process after-record", ": # removed after-record"),
        ("--template 'Game Performance Overview'", "--template 'Game Performance'"),
        ('--device "$DEVICE" --attach "$PID"', '--device "$DEVICE" --all-processes'),
        ('run_bounded_tool 120 "$XCTRACE" export --input "$TRACE_PATH" --toc', '"$XCTRACE" export --input "$TRACE_PATH" --toc'),
        ('table[@schema="metal-perf-overview-layer-duration-metric"]', 'table[@schema="guess"]'),
        ('table[@schema="device-thermal-state-intervals"]', 'table[@schema="guess"]'),
        ('VALIDATOR_TERMINAL="$(run_bounded_tool 300 python3 "$VALIDATOR"', 'VALIDATOR_TERMINAL="$(python3 "$VALIDATOR"'),
        ('--output "$SUMMARY_PATH" --commit-output "$COMMIT_PATH"', '--output "$SUMMARY_PATH"'),
        ('python3 - "$PAYLOAD" <<\'PY\' || fail "evidence durability flush failed"', 'true <<\'PY\' # removed durability gate'),
        ('payload file changed before flush")\n            os.fsync(descriptor)', 'payload file changed before flush")\n            pass'),
        ('directories.sort(key=lambda item: len(item[0].parts), reverse=True)', 'directories.sort(key=lambda item: len(item[0].parts))'),
        ('payload directory changed before flush")\n        os.fsync(descriptor)', 'payload directory changed before flush")\n        pass'),
        ('[[ ! -e "$FINAL_PATH" && ! -L "$FINAL_PATH" ]]', 'true # removed collision check'),
        ('python3 - "$WORK" "$EVIDENCE_DIR" "$FINAL_LEAF"', '/bin/mv "$PAYLOAD" "$FINAL_PATH" #'),
        ("renameatx_np", "renameat"),
        ('destination_leaf.encode("utf-8", "strict"), 0x4', 'destination_leaf.encode("utf-8", "strict"), 0'),
        ('[[ ! -e "$PAYLOAD" && -d "$FINAL_PATH" && ! -L "$FINAL_PATH" ]]', '[[ -d "$FINAL_PATH" ]]'),
        ("printf '%s\\n' 'PERFORMANCE PASS'", "printf 'PASS\\n'"),
    )
    killed = 0
    for old, new in replacements:
        require(source.count(old) == 1, "source mutation anchor drift")
        mutant = source.replace(old, new, 1)
        try:
            validate_collector_source(mutant)
        except RuntimeError:
            killed += 1
        else:
            raise RuntimeError("collector source mutation survived")
    return killed


def durability_flush_tests(source: str) -> int:
    marker = ('python3 - "$PAYLOAD" <<\'PY\' || '
              'fail "evidence durability flush failed"\n')
    require(source.count(marker) == 1, "durability flush start drifted")
    tail = source.split(marker, 1)[1]
    require("\nPY\n" in tail, "durability flush end drifted")
    flush_script = tail.split("\nPY\n", 1)[0] + "\n"

    def invoke(payload: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-", str(payload)], input=flush_script,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False)

    with tempfile.TemporaryDirectory(
            prefix="p21e1b-durability-flush-") as temporary:
        root = Path(temporary)
        payload = root / "payload-valid"
        nested = payload / "trace" / "Data"
        nested.mkdir(parents=True)
        (nested / "zero.bin").write_bytes(b"")
        (nested / "payload.bin").write_bytes(b"complete")
        (payload / "summary.json").write_bytes(b"{}\n")
        require(invoke(payload).returncode == 0,
                "durability flush rejected a regular tree")
        killed = 0

        file_link = root / "payload-file-link"
        file_link.mkdir()
        (file_link / "link").symlink_to(payload / "summary.json")
        require(invoke(file_link).returncode != 0,
                "durability flush accepted a file symlink")
        killed += 1

        directory_link = root / "payload-directory-link"
        directory_link.mkdir()
        (directory_link / "link").symlink_to(payload / "trace",
                                              target_is_directory=True)
        require(invoke(directory_link).returncode != 0,
                "durability flush accepted a directory symlink")
        killed += 1

        special = root / "payload-special"
        special.mkdir()
        os.mkfifo(special / "fifo")
        require(invoke(special).returncode != 0,
                "durability flush accepted a special file")
        killed += 1

        root_link = root / "payload-root-link"
        root_link.symlink_to(payload, target_is_directory=True)
        require(invoke(root_link).returncode != 0,
                "durability flush accepted a symlink root")
        return killed + 1


def exclusive_publisher_tests(source: str) -> int:
    marker = ('python3 - "$WORK" "$EVIDENCE_DIR" "$FINAL_LEAF" '
              '<<\'PY\' ||\n'
              '  fail "evidence directory exclusive publication failed"\n')
    require(source.count(marker) == 1, "exclusive publisher start drifted")
    tail = source.split(marker, 1)[1]
    require("\nPY\n" in tail, "exclusive publisher end drifted")
    publisher = tail.split("\nPY\n", 1)[0] + "\n"

    def invoke(work: Path, destination: Path,
               leaf: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-", str(work), str(destination), leaf],
            input=publisher, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False)

    with tempfile.TemporaryDirectory(
            prefix="p21e1b-exclusive-publisher-") as temporary:
        root = Path(temporary)
        destination = root / "destination"
        destination.mkdir()
        work = root / "work-success"
        payload = work / "payload"
        payload.mkdir(parents=True)
        (payload / "marker").write_text("complete", encoding="utf-8")
        leaf = "performance-evidence-base-off-performance-" + RUN_ID
        result = invoke(work, destination, leaf)
        require(result.returncode == 0 and not payload.exists() and
                (destination / leaf / "marker").read_text(encoding="utf-8") ==
                "complete", "exclusive publisher rejected complete set")
        killed = 0

        colliding_work = root / "work-collision"
        colliding_payload = colliding_work / "payload"
        colliding_payload.mkdir(parents=True)
        (colliding_payload / "marker").write_text("replacement",
                                                   encoding="utf-8")
        result = invoke(colliding_work, destination, leaf)
        require(result.returncode != 0 and colliding_payload.is_dir() and
                (destination / leaf / "marker").read_text(encoding="utf-8") ==
                "complete", "destination collision clobbered evidence")
        killed += 1

        symlink_work = root / "work-symlink-collision"
        symlink_payload = symlink_work / "payload"
        symlink_payload.mkdir(parents=True)
        symlink_leaf = "performance-evidence-base-off-performance-" + "4" * 32
        (destination / symlink_leaf).symlink_to(destination / leaf,
                                                target_is_directory=True)
        result = invoke(symlink_work, destination, symlink_leaf)
        require(result.returncode != 0 and symlink_payload.is_dir() and
                (destination / symlink_leaf).is_symlink(),
                "symlink destination collision survived")
        killed += 1

        parent_link = root / "destination-link"
        parent_link.symlink_to(destination, target_is_directory=True)
        parent_work = root / "work-parent-link"
        (parent_work / "payload").mkdir(parents=True)
        result = invoke(parent_work, parent_link,
                        "performance-evidence-base-off-performance-" +
                        "5" * 32)
        require(result.returncode != 0 and (parent_work / "payload").is_dir(),
                "symlink destination parent survived")
        killed += 1

        payload_link_work = root / "work-payload-link"
        payload_link_work.mkdir()
        (payload_link_work / "payload").symlink_to(destination / leaf,
                                                    target_is_directory=True)
        result = invoke(payload_link_work, destination,
                        "performance-evidence-base-off-performance-" +
                        "6" * 32)
        require(result.returncode != 0 and
                (payload_link_work / "payload").is_symlink(),
                "symlink payload source survived")
        return killed + 1


def collector_self_test() -> None:
    command_line = [
        str(COLLECTOR), "--self-test", "--device", DEVICE, "--pid", PID,
        "--role", "base-off-performance", "--expected-sha", SHA,
        "--tempest-sha", TEMPEST, "--bundle-id",
        "opengothic.gothic2.RMJWWPF379", "--team-id", "RMJWWPF379",
        "--save-slot", "4", "--fps-limit", "30", "--settle-seconds", "12",
        "--trace-seconds", "30", "--evidence-dir", "/tmp",
        "--live-pid-file", "/tmp/live-pid.json", "/tmp/App.app",
    ]
    result = subprocess.run(command_line, cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=False)
    require(result.returncode == 0 and result.stdout.startswith("SELF-TEST PASS "),
            "collector parser self-test failed")
    live_pid_index = command_line.index("--live-pid-file") + 1
    for value in ("/tmp/control\x01.json", "/tmp/delete\x7f.json"):
        mutant = list(command_line)
        mutant[live_pid_index] = value
        result = subprocess.run(mutant, cwd=ROOT, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, check=False)
        require(result.returncode != 0,
                "collector accepted a control byte in live PID path")
    for index, value in ((command_line.index("30", command_line.index("--trace-seconds")), "29"),
                         (command_line.index(PID), "0")):
        mutant = list(command_line)
        mutant[index] = value
        result = subprocess.run(mutant, cwd=ROOT, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, check=False)
        require(result.returncode != 0, "collector accepted invalid settings")
    duplicate = command_line + ["--device", DEVICE]
    result = subprocess.run(duplicate, cwd=ROOT, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, check=False)
    require(result.returncode != 0, "collector accepted a duplicate option")


def live_pid_reader_tests(source: str) -> int:
    marker = 'LIVE_PID_VALUE="$(python3 - "$LIVE_PID_FILE" "$DEVICE" "$BUNDLE_ID" "$APP_EXECUTABLE" "$PID" <<\'PY\'\n'
    require(source.count(marker) == 1, "live PID reader start drifted")
    tail = source.split(marker, 1)[1]
    require(tail.count("\nPY\n)\"") >= 1, "live PID reader end drifted")
    reader = tail.split("\nPY\n)\"", 1)[0] + "\n"
    bundle = "opengothic.gothic2.RMJWWPF379"
    value = {
        "schemaVersion": 1,
        "deviceUdid": DEVICE,
        "bundleId": bundle,
        "executable": "Gothic2Notr",
        "processId": int(PID),
    }
    with tempfile.TemporaryDirectory(prefix="p21e1b-live-pid-reader-") as temporary:
        root = Path(temporary)
        path = root / "live.json"

        def invoke(raw: bytes, *, target: Path = path,
                   expected_pid: str = PID) -> subprocess.CompletedProcess[str]:
            if target == path:
                path.write_bytes(raw)
            return subprocess.run(
                [sys.executable, "-", str(target), DEVICE, bundle,
                 "Gothic2Notr", expected_pid], input=reader, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )

        canonical = (json.dumps(value, separators=(",", ":")) + "\n").encode()
        result = invoke(canonical)
        require(result.returncode == 0 and result.stdout == PID + "\n",
                "production live PID reader rejected canonical identity")
        mutants = [
            canonical.replace(b'"schemaVersion":1', b'"schemaVersion":1,"schemaVersion":1'),
            canonical.replace(b'"processId":35073', b'"extra":1,"processId":35073'),
            json.dumps(value, indent=2).encode() + b"\n",
            canonical.replace(DEVICE.encode(), b"wrong-device"),
            canonical.replace(bundle.encode(), b"wrong.bundle"),
            canonical.replace(b"Gothic2Notr", b"Other"),
            canonical.replace(b'"processId":35073', b'"processId":0'),
            canonical.replace(b'"processId":35073', b'"processId":35074'),
        ]
        killed = 0
        for raw in mutants:
            if invoke(raw).returncode != 0:
                killed += 1
            else:
                raise RuntimeError("live PID JSON mutation survived")
        outside = root / "outside.json"
        outside.write_bytes(canonical)
        link = root / "link.json"
        link.symlink_to(outside)
        require(invoke(canonical, target=link).returncode != 0,
                "live PID symlink mutation survived")
        return killed + 1


def main() -> int:
    tool_identity_killed = tool_identity_verifier_tests()
    validate_good_summary()
    fake_killed = mutation_tests()
    directory_killed = evidence_directory_mutations()
    source = COLLECTOR.read_text(encoding="utf-8")
    validate_collector_source(source)
    source_killed = source_mutations(source)
    durability_killed = durability_flush_tests(source)
    publisher_killed = exclusive_publisher_tests(source)
    collector_self_test()
    live_pid_killed = live_pid_reader_tests(source)
    print("P2.1e1b additive performance host PASS "
          f"fake-mutations-killed={fake_killed} "
          f"directory-mutations-killed={directory_killed} "
          f"source-mutations-killed={source_killed} "
          f"durability-mutations-killed={durability_killed} "
          f"publisher-mutations-killed={publisher_killed} "
          f"live-pid-mutations-killed={live_pid_killed} "
          f"tool-identity-mutations-killed={tool_identity_killed} "
          "weighted=1 atomic=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
