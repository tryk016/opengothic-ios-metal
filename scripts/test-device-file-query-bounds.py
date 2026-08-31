#!/usr/bin/env python3
"""Fail-closed contract for bounded AFC app-container operations."""

from __future__ import annotations

import pathlib
import subprocess
import sys


RAW_LIST = "xcrun devicectl device info files"
RAW_PULL = "xcrun devicectl device copy from"
RAW_PUSH = "xcrun devicectl device copy to"
LIST_CALL = 'run_bounded_afc_file_query --device "$DEVICE_UDID"'
PULL_CALL = 'run_bounded_afc_copy_from --device "$DEVICE_UDID"'
PUSH_CALL = 'run_bounded_afc_copy_to --device "$DEVICE_UDID"'
TIMEOUT = "readonly AFC_FILE_OPERATION_TIMEOUT_SECONDS=30"
SCRIPT = '"$ROOT/ios/device-test/afc-app-container.py"'
HELPERS = (
    (
        "run_bounded_afc_file_query",
        "list",
    ),
    (
        "run_bounded_afc_copy_from",
        "pull",
    ),
    (
        "run_bounded_afc_copy_to",
        "push",
    ),
)
SAFE_RETRY = 'attempts = 2 if args.operation in ("list", "pull") else 1'
PREFLIGHT_REQUIRED = (
    "COMMAND_TIMEOUT_SECONDS = 10",
    "AFC_TIMEOUT_SECONDS = 10",
    'device.connection_type == "USB"',
    'serial=udid, autopair=False, connection_type="USB"',
    "lockdown=lockdown, bundle_id=bundle, documents_only=False",
    'device.get("properties", {}).get("hardware")',
    'device.get("hardwareProperties", {})',
    'if isinstance(current, dict) and current:',
    'args.expected_bundle_id or args.expected_base_bundle_id',
    '"Documents/_work/Data/Scripts/_compiled"',
    'await service.pull(ini_path, str(destination), progress_bar=False)',
    'os.link(temporary, path)',
    '"terminal": "USB AFC PREFLIGHT PASS"',
)
SELECTION_REQUIRED = (
    'run_usb_afc_preflight "${PREFLIGHT_BUNDLE_ARGUMENTS[@]}"',
    '--json-output "$WORK/usb-afc-preflight.json"',
    'value.get("terminal") != "USB AFC PREFLIGHT PASS"',
    'IFS=$\'\\t\' read -r DEVICE DEVICE_UDID BUNDLE_ID <<<"$DEVICE_RECORD"',
    'copy_private_evidence_path "$WORK/usb-afc-preflight.json"',
)


def active_source(source: str) -> str:
    return "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("#")
    )


def validate(source: str) -> None:
    active = active_source(source)
    if active.count(TIMEOUT) != 1:
        raise ValueError("AFC operation timeout contract drifted")
    if active.count('DEVICE_UDID=""') != 1:
        raise ValueError("AFC usbmux UDID initialization drifted")
    for literal in SELECTION_REQUIRED:
        if active.count(literal) != 1:
            raise ValueError(f"physical USB selection contract drifted: {literal}")
    if 'd.get("connectionProperties", {}).get("tunnelState")' in active:
        raise ValueError("stale CoreDevice tunnel state can bypass USB admission")
    for helper, operation in HELPERS:
        expected = (
            f'{helper}() {{ run_bounded_command '
            f'"$AFC_FILE_OPERATION_TIMEOUT_SECONDS" '
            f'/opt/homebrew/bin/uv run --python python3.11 --script {SCRIPT} '
            f'{operation} "$@"; }}'
        )
        if active.count(expected) != 1:
            raise ValueError(f"bounded AFC {operation} helper drifted")
    for raw in (RAW_LIST, RAW_PULL, RAW_PUSH):
        if raw in active:
            raise ValueError("raw CoreDevice file-provider operation survived")
    expected_counts = ((LIST_CALL, 10), (PULL_CALL, 14), (PUSH_CALL, 1))
    for call, expected in expected_counts:
        if active.count(call) != expected:
            raise ValueError(f"not every AFC operation is bounded: {call}")


def validate_helper(source: str) -> None:
    required = (
        'serial=args.device, autopair=False, connection_type="USB"',
        'documents_only=False',
        SAFE_RETRY,
        'except (ConnectionTerminatedError, DeviceNotFoundError):',
        'file_type not in ("S_IFREG", "S_IFDIR")',
        'existing.get("st_ifmt") != "S_IFREG"',
        'if path.exists() or path.is_symlink():',
        'if destination.exists() or destination.is_symlink():',
        'os.link(temporary, path)',
        'os.link(temporary, destination)',
        'rename_exclusive(received, destination)',
    )
    for literal in required:
        if source.count(literal) != 1:
            raise ValueError(f"AFC helper contract drifted: {literal}")
    if "except Exception" in source:
        raise ValueError("AFC helper widened its retry/error contract")


def validate_preflight(source: str) -> None:
    for literal in PREFLIGHT_REQUIRED:
        if source.count(literal) != 1:
            raise ValueError(f"USB AFC preflight contract drifted: {literal}")
    for forbidden in (
        "device copy to",
        "device install",
        "device uninstall",
        "device process launch",
        "service.push(",
    ):
        if forbidden in source:
            raise ValueError(f"USB AFC preflight is not read-only: {forbidden}")


def expect_rejected(source: str, label: str) -> None:
    try:
        validate(source)
    except ValueError:
        return
    raise SystemExit(f"mutation survived: {label}")


def expect_helper_rejected(source: str, label: str) -> None:
    try:
        validate_helper(source)
    except ValueError:
        return
    raise SystemExit(f"helper mutation survived: {label}")


def expect_preflight_rejected(source: str, label: str) -> None:
    try:
        validate_preflight(source)
    except ValueError:
        return
    raise SystemExit(f"preflight mutation survived: {label}")


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    path = root / "ios/device-test/run-smoke-test.sh"
    helper_path = root / "ios/device-test/afc-app-container.py"
    preflight_path = root / "ios/device-test/preflight-usb-afc.py"
    source = path.read_text(encoding="utf-8")
    helper_source = helper_path.read_text(encoding="utf-8")
    preflight_source = preflight_path.read_text(encoding="utf-8")
    validate(source)
    validate_helper(helper_source)
    validate_preflight(preflight_source)
    validate(source + f"\n# benign decoy: {RAW_LIST}\n")

    result = subprocess.run(
        [sys.executable, str(helper_path), "--self-test"],
        check=True,
        capture_output=True,
        text=True,
    )
    if result.stdout.strip() != "AFC app-container transport self-test: PASS":
        raise SystemExit("AFC helper self-test terminal mismatch")
    preflight_result = subprocess.run(
        [sys.executable, str(preflight_path), "--self-test"],
        check=True,
        capture_output=True,
        text=True,
    )
    if preflight_result.stdout.strip() != "USB AFC preflight self-test: PASS":
        raise SystemExit("USB AFC preflight self-test terminal mismatch")

    mutations = [
        (source.replace(TIMEOUT, "", 1), "drop-timeout"),
        (source.replace('DEVICE_UDID=""', "", 1), "drop-usbmux-udid"),
        (source.replace('run_bounded_command "$AFC_FILE_OPERATION_TIMEOUT_SECONDS"',
                        "run_bounded_command 0", 1), "invalid-timeout"),
    ]
    for selection_literal in SELECTION_REQUIRED:
        mutations.append(
            (
                source.replace(selection_literal, "selection_contract_removed", 1),
                "drop-selection-" + str(len(mutations)),
            )
        )
    for helper, operation in HELPERS:
        anchor = f'{operation} "$@"; }}'
        mutations.append(
            (source.replace(anchor, f"{operation}; }}", 1), f"drop-{operation}-args")
        )
    for call, count, raw in (
        (LIST_CALL, 10, RAW_LIST),
        (PULL_CALL, 14, RAW_PULL),
        (PUSH_CALL, 1, RAW_PUSH),
    ):
        offset = 0
        for index in range(count):
            position = source.find(call, offset)
            if position < 0:
                raise SystemExit(f"fixture has fewer than {count} {call} sites")
            mutated = (
                source[:position]
                + raw
                + ' --device "$DEVICE"'
                + source[position + len(call):]
            )
            mutations.append((mutated, f"raw-{raw.rsplit(' ', 1)[-1]}-{index + 1}"))
            offset = position + len(call)

    for mutated, label in mutations:
        expect_rejected(mutated, label)
    helper_mutations = (
        (helper_source.replace(SAFE_RETRY, "attempts = 1", 1), "drop-safe-retry"),
        (
            helper_source.replace(SAFE_RETRY, SAFE_RETRY.replace("else 1", "else 2"), 1),
            "retry-push",
        ),
        (helper_source.replace("autopair=False", "autopair=True", 1), "enable-autopair"),
        (
            helper_source.replace(', connection_type="USB"', "", 1),
            "drop-usb-transport-filter",
        ),
        (
            helper_source.replace("documents_only=False", "documents_only=True", 1),
            "vend-documents",
        ),
        (
            helper_source.replace("os.link(temporary, path)", "os.replace(temporary, path)", 1),
            "overwrite-json-output",
        ),
        (
            helper_source.replace(
                "os.link(temporary, destination)",
                "os.replace(temporary, destination)",
                1,
            ),
            "overwrite-pull-output",
        ),
        (
            helper_source.replace(
                "rename_exclusive(received, destination)",
                "os.replace(received, destination)",
                1,
            ),
            "overwrite-directory-output",
        ),
    )
    for mutated, label in helper_mutations:
        expect_helper_rejected(mutated, label)
    preflight_mutations = (
        (
            preflight_source.replace('device.connection_type == "USB"', "True", 1),
            "accept-network-usbmux",
        ),
        (
            preflight_source.replace(', connection_type="USB"', "", 1),
            "drop-preflight-usb-filter",
        ),
        (
            preflight_source.replace("AFC_TIMEOUT_SECONDS = 10", "", 1),
            "drop-afc-timeout",
        ),
        (
            preflight_source.replace("documents_only=False", "documents_only=True", 1),
            "vend-documents-only",
        ),
        (
            preflight_source.replace(
                'device.get("properties", {}).get("hardware")',
                'device.get("hardwareProperties", {})',
                1,
            ),
            "drop-current-coredevice-schema",
        ),
        (
            preflight_source.replace("and current:", "", 1),
            "block-legacy-fallback-on-empty-current",
        ),
        (
            preflight_source.replace(
                "os.link(temporary, path)", "os.replace(temporary, path)", 1
            ),
            "overwrite-preflight-output",
        ),
    )
    for mutated, label in preflight_mutations:
        expect_preflight_rejected(mutated, label)
    total = len(mutations) + len(helper_mutations) + len(preflight_mutations)
    print(f"AFC file-operation bounds contract: PASS ({total} mutations killed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
