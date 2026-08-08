#!/usr/bin/env python3
"""Focused source/mutation contract for guarded HDR capture cleanup."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "ios/device-test/run-linear-hdr-proof-test.sh"

CAPTURE_DELETE_CLI = (
    '  "$UVX" --python python3.11 pymobiledevice3 apps rm \\\n'
    '    --udid "$DEVICE_UDID" --documents "$BUNDLE_ID" "Documents/$leaf" \\\n'
    '    >>"$WORK/device-owned-delete.log" 2>&1\n'
)
TEMP_DELETE_CLI = (
    '    "$UVX" --python python3.11 pymobiledevice3 apps rm \\\n'
    '      --udid "$DEVICE_UDID" --documents "$BUNDLE_ID" "Documents/$leaf" \\\n'
    '      >>"$WORK/temp-cleanup-$label.log" 2>&1 || return 1\n'
)
TEMP_POSTDELETE = '  [[ -z "$remaining" ]] || return 1\n'
CAPTURE_POSTDELETE = (
    '  capture_leaf_absent "$CAPTURE_LEAF" ||\n'
    '    fail "could not prove fixed device capture absence after exact delete"\n'
)
CAPTURE_LISTING_GUARD = \
    '  capture_documents_listing "$output" || return 1\n'
CAPTURE_ZERO_MATCH_GUARD = (
    '    if entry["name"] == leaf:\n'
    '        raise SystemExit("capture leaf remains after exact delete")\n'
)
CAPTURE_FILES_PARSE = 'files = payload["result"].get("files")\n'


def require_once(source: str, literal: str) -> int:
    if source.count(literal) != 1:
        raise ValueError(f"capture cleanup contract is not exact: {literal}")
    return source.index(literal)


def validate(candidate: str) -> None:
    syntax = subprocess.run(
        ["bash", "-n"], input=candidate, text=True,
        capture_output=True, check=False,
    )
    if syntax.returncode != 0:
        raise ValueError(f"runner shell grammar is invalid: {syntax.stderr}")
    if candidate.count('"Documents/$leaf"') != 2 or \
            '--documents "$BUNDLE_ID" "$leaf"' in candidate:
        raise ValueError("owned delete paths are not exact Documents leaves")
    for contract in (
        CAPTURE_DELETE_CLI,
        TEMP_DELETE_CLI,
        TEMP_POSTDELETE,
        CAPTURE_POSTDELETE,
        CAPTURE_LISTING_GUARD,
        CAPTURE_ZERO_MATCH_GUARD,
        CAPTURE_FILES_PARSE,
        '  require_afc_capture_leaf "$leaf" || return 1\n',
        '    require_afc_regular_leaf "$leaf" || return 1\n',
        'if type(payload) is not dict or type(payload.get("result")) is not dict:',
        'if type(entry) is not dict or type(entry.get("name")) is not str:',
        'SELF_TEST_CAPTURE_LISTING_MODE=absent',
        'fail "exit-zero capture delete with a remaining leaf survived: $candidate"',
        'fail "capture absence provider failure survived: $candidate"',
    ):
        require_once(candidate, contract)
    if 'if require_afc_capture_leaf "$CAPTURE_LEAF"' in candidate:
        raise ValueError("AFC/provider failure is still treated as absence")
    ordered = (
        'python3 "$GPU_VALIDATOR" --commit-capture-copy',
        '[[ -f "$CAPTURE_SUMMARY" && ! -L "$CAPTURE_SUMMARY" ]]',
        'delete_exact_device_leaf "$CAPTURE_LEAF"',
        'capture_leaf_absent "$CAPTURE_LEAF"',
        'python3 "$GPU_VALIDATOR" --collect',
    )
    positions = [require_once(candidate, literal) for literal in ordered]
    if positions != sorted(positions):
        raise ValueError("evidenceCommitted/delete/absence/collect order changed")
    with tempfile.TemporaryDirectory(prefix="capture-cleanup-contract-") as work:
        candidate_path = Path(work) / "run-linear-hdr-proof-test.sh"
        candidate_path.write_text(candidate, encoding="utf-8")
        completed = subprocess.run(
            ["bash", str(candidate_path), "--self-test"],
            text=True, capture_output=True, check=False,
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": os.environ["HOME"],
                "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
                "RUNNER_TEMP": work,
            },
        )
    if completed.returncode != 0 or completed.stdout != "SELF-TEST PASS\n" or \
            completed.stderr:
        raise ValueError(
            "capture cleanup host self-test failed: " + completed.stderr[-400:]
        )


source = RUNNER.read_text(encoding="utf-8")
validate(source)
mutations = (
    source.replace(
        CAPTURE_DELETE_CLI,
        CAPTURE_DELETE_CLI.replace('"Documents/$leaf"', '"$leaf"', 1),
        1),
    source.replace(
        TEMP_DELETE_CLI,
        TEMP_DELETE_CLI.replace('"Documents/$leaf"', '"$leaf"', 1),
        1),
    source.replace(CAPTURE_DELETE_CLI, '  true # capture delete CLI\n', 1),
    source.replace(TEMP_DELETE_CLI, '    true # temp delete CLI\n', 1),
    source.replace(
        TEMP_POSTDELETE,
        '  true # [[ -z "$remaining" ]] || return 1\n',
        1),
    source.replace(CAPTURE_POSTDELETE, '  true\n', 1),
    source.replace(
        CAPTURE_POSTDELETE,
        '  true # capture absence postcheck\n',
        1),
    source.replace(
        CAPTURE_LISTING_GUARD,
        '  true # capture Documents provider call\n',
        1),
    source.replace(
        CAPTURE_ZERO_MATCH_GUARD,
        '    if False:\n'
        '        raise SystemExit("capture leaf remains after exact delete")\n',
        1),
    source.replace(
        CAPTURE_FILES_PARSE,
        'files = payload.get("result", {}).get("files", [])\n',
        1),
)
for index, mutation in enumerate(mutations, 1):
    if mutation == source:
        raise SystemExit(f"capture cleanup mutation is a no-op: {index}")
    try:
        validate(mutation)
    except ValueError:
        pass
    else:
        raise SystemExit(f"capture cleanup mutation survived: {index}")
print(f"linear HDR capture cleanup contracts: PASS mutations={len(mutations)}")
