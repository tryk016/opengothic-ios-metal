#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pymobiledevice3==11.2.4"]
# ///
"""Fast read-only admission for the physical-device USB/AFC transport."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import posixpath
import subprocess
import sys
import tempfile
from typing import Any


COMMAND_TIMEOUT_SECONDS = 10
AFC_TIMEOUT_SECONDS = 10


def hardware(device: dict[str, Any]) -> dict[str, Any]:
    current = device.get("properties", {}).get("hardware")
    if isinstance(current, dict) and current:
        return current
    legacy = device.get("hardwareProperties", {})
    return legacy if isinstance(legacy, dict) else {}


def select_device(
    core_devices: list[dict[str, Any]],
    xcdevices: list[dict[str, Any]],
    requested: str,
) -> tuple[str, str]:
    usb_udids = {
        item.get("identifier")
        for item in xcdevices
        if item.get("simulator") is False
        and item.get("available") is True
        and item.get("interface") == "usb"
        and item.get("platform") == "com.apple.platform.iphoneos"
    }
    matches = []
    for device in core_devices:
        values = hardware(device)
        identifier = device.get("identifier")
        udid = values.get("udid")
        if (
            values.get("platform") == "iOS"
            and values.get("reality") == "physical"
            and isinstance(identifier, str)
            and isinstance(udid, str)
            and udid in usb_udids
            and (not requested or requested in (identifier, udid))
        ):
            matches.append((identifier, udid))
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one physical iOS USB device, found {len(matches)}"
        )
    return matches[0]


def select_bundle(apps: list[dict[str, Any]], expected: str, *, exact: bool) -> str:
    matches = []
    for app in apps:
        bundle = app.get("bundleIdentifier")
        if (
            isinstance(bundle, str)
            and (bundle == expected if exact else bundle.startswith(expected))
            and not bundle.endswith(".xctrunner")
        ):
            matches.append(bundle)
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one installed non-xctrunner {expected} app, "
            f"found {len(matches)}"
        )
    return matches[0]


def run_json(command: list[str], output: pathlib.Path) -> dict[str, Any]:
    if output.exists() or output.is_symlink():
        raise RuntimeError("temporary JSON output already exists")
    completed = subprocess.run(
        command + ["--json-output", str(output)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        timeout=COMMAND_TIMEOUT_SECONDS + 2,
        check=False,
    )
    if completed.returncode != 0:
        excerpt = completed.stderr.strip().splitlines()[-1:] or ["no stderr"]
        raise RuntimeError(f"command failed: {command[1:4]}: {excerpt[0]}")
    try:
        payload = json.loads(output.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("command returned malformed JSON") from error
    if not isinstance(payload, dict):
        raise RuntimeError("command JSON root is not an object")
    return payload


def run_xcdevice() -> list[dict[str, Any]]:
    completed = subprocess.run(
        ["/usr/bin/xcrun", "xcdevice", "list"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=COMMAND_TIMEOUT_SECONDS,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError("xcdevice USB enumeration failed")
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("xcdevice returned malformed JSON") from error
    if not isinstance(payload, list) or any(not isinstance(item, dict) for item in payload):
        raise RuntimeError("xcdevice JSON is malformed")
    return payload


def result_list(payload: dict[str, Any], key: str) -> list[dict[str, Any]]:
    result = payload.get("result")
    values = result.get(key) if isinstance(result, dict) else None
    if not isinstance(values, list) or any(not isinstance(item, dict) for item in values):
        raise RuntimeError(f"CoreDevice returned no valid {key} array")
    return values


async def exact_entry(
    service: Any, directory: str, expected: str, file_type: str
) -> tuple[str, dict[str, Any]]:
    names = await service.listdir(directory)
    matches = [name for name in names if name.casefold() == expected.casefold()]
    if len(matches) != 1:
        raise RuntimeError(f"missing or duplicate resource: {directory}/{expected}")
    path = posixpath.join(directory, matches[0])
    metadata = await service.stat(path)
    if metadata.get("st_ifmt") != file_type:
        raise RuntimeError(f"resource has wrong type: {path}")
    return path, metadata


async def verify_afc(udid: str, bundle: str, work: pathlib.Path) -> dict[str, Any]:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    from pymobiledevice3.usbmux import list_devices

    async with asyncio.timeout(AFC_TIMEOUT_SECONDS):
        mux_matches = [
            device
            for device in await list_devices()
            if device.serial == udid and device.connection_type == "USB"
        ]
        if len(mux_matches) != 1:
            raise RuntimeError(
                f"usbmux expected one exact USB UDID, found {len(mux_matches)}"
            )
        async with await create_using_usbmux(
            serial=udid, autopair=False, connection_type="USB"
        ) as lockdown:
            async with await HouseArrestService.create(
                lockdown=lockdown, bundle_id=bundle, documents_only=False
            ) as service:
                for name in ("Data", "_work", "system"):
                    await exact_entry(service, "Documents", name, "S_IFDIR")
                gothic_path, gothic = await exact_entry(
                    service,
                    "Documents/_work/Data/Scripts/_compiled",
                    "Gothic.dat",
                    "S_IFREG",
                )
                ini_path, ini = await exact_entry(
                    service, "Documents/system", "Gothic.ini", "S_IFREG"
                )
                destination = work / "Gothic.ini"
                await service.pull(ini_path, str(destination), progress_bar=False)
                if (
                    not destination.is_file()
                    or destination.is_symlink()
                    or destination.stat().st_size != ini.get("st_size")
                    or destination.stat().st_size <= 0
                ):
                    raise RuntimeError("AFC pull byte count does not match stat")
    return {
        "usbmuxConnectionType": "USB",
        "gothicDatPath": gothic_path,
        "gothicDatBytes": gothic.get("st_size"),
        "gothicIniPath": ini_path,
        "gothicIniBytes": ini.get("st_size"),
        "pulledGothicIniBytes": destination.stat().st_size,
    }


def write_atomic(path: pathlib.Path, payload: dict[str, Any]) -> None:
    if not path.is_absolute() or path != pathlib.Path(os.path.abspath(path)):
        raise ValueError("JSON output path must be absolute and canonical")
    if (
        not path.parent.is_dir()
        or path.parent.is_symlink()
        or path.exists()
        or path.is_symlink()
    ):
        raise RuntimeError("JSON output parent/path is unsafe")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(payload, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.link(temporary, path)
        temporary.unlink()
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary.exists():
            temporary.unlink()


async def live(args: argparse.Namespace) -> None:
    with tempfile.TemporaryDirectory(prefix="opengothic-usb-afc-preflight.") as name:
        work = pathlib.Path(name)
        devices_payload = run_json(
            [
                "/usr/bin/xcrun",
                "devicectl",
                "list",
                "devices",
                "--timeout",
                str(COMMAND_TIMEOUT_SECONDS),
            ],
            work / "devices.json",
        )
        core_identifier, udid = select_device(
            result_list(devices_payload, "devices"),
            run_xcdevice(),
            args.requested_device,
        )
        apps_payload = run_json(
            [
                "/usr/bin/xcrun",
                "devicectl",
                "device",
                "info",
                "apps",
                "--device",
                core_identifier,
                "--timeout",
                str(COMMAND_TIMEOUT_SECONDS),
            ],
            work / "apps.json",
        )
        bundle = select_bundle(
            result_list(apps_payload, "apps"),
            args.expected_bundle_id or args.expected_base_bundle_id,
            exact=bool(args.expected_bundle_id),
        )
        afc = await verify_afc(udid, bundle, work)
        write_atomic(
            args.json_output,
            {
                "schemaVersion": 1,
                "coreDeviceIdentifier": core_identifier,
                "deviceUdid": udid,
                "bundleIdentifier": bundle,
                **afc,
                "terminal": "USB AFC PREFLIGHT PASS",
            },
        )
    print("USB AFC PREFLIGHT PASS")


def self_test() -> None:
    xcdevices = [
        {
            "simulator": False,
            "available": True,
            "interface": "usb",
            "platform": "com.apple.platform.iphoneos",
            "identifier": "hardware-udid",
        }
    ]
    current = {
        "identifier": "core-uuid",
        "properties": {
            "hardware": {
                "platform": "iOS",
                "reality": "physical",
                "udid": "hardware-udid",
            }
        },
    }
    legacy = {
        "identifier": "legacy-core-uuid",
        "hardwareProperties": {
            "platform": "iOS",
            "reality": "physical",
            "udid": "hardware-udid",
        },
    }
    if select_device([current], xcdevices, "") != ("core-uuid", "hardware-udid"):
        raise RuntimeError("current CoreDevice schema self-test failed")
    if select_device([legacy], xcdevices, "hardware-udid") != (
        "legacy-core-uuid",
        "hardware-udid",
    ):
        raise RuntimeError("legacy CoreDevice schema self-test failed")
    empty_current = {**legacy, "properties": {"hardware": {}}}
    if select_device([empty_current], xcdevices, "hardware-udid") != (
        "legacy-core-uuid",
        "hardware-udid",
    ):
        raise RuntimeError("empty current CoreDevice schema did not use legacy fallback")
    if select_bundle(
        [
            {"bundleIdentifier": "opengothic.gothic2.TEAM"},
            {"bundleIdentifier": "opengothic.gothic2.TEAM.xctrunner"},
        ],
        "opengothic.gothic2",
        exact=False,
    ) != "opengothic.gothic2.TEAM":
        raise RuntimeError("bundle selection self-test failed")
    if select_bundle(
        [{"bundleIdentifier": "opengothic.gothic2.TEAM"}],
        "opengothic.gothic2.TEAM",
        exact=True,
    ) != "opengothic.gothic2.TEAM":
        raise RuntimeError("exact bundle selection self-test failed")
    with tempfile.TemporaryDirectory() as temporary:
        output = pathlib.Path(temporary) / "result.json"
        output.write_text("sentinel", encoding="utf-8")
        try:
            write_atomic(output, {"terminal": "must-not-overwrite"})
        except RuntimeError:
            pass
        else:
            raise RuntimeError("preflight output no-clobber self-test failed")
        if output.read_text(encoding="utf-8") != "sentinel":
            raise RuntimeError("preflight output sentinel changed")
    for mutation in (
        [{**xcdevices[0], "interface": "network"}],
        [{**xcdevices[0], "available": False}],
    ):
        try:
            select_device([current], mutation, "")
        except RuntimeError:
            continue
        raise RuntimeError("non-USB/unavailable mutation survived")
    print("USB AFC preflight self-test: PASS")


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    bundle = value.add_mutually_exclusive_group(required=True)
    bundle.add_argument("--expected-base-bundle-id")
    bundle.add_argument("--expected-bundle-id")
    value.add_argument("--requested-device", default="")
    value.add_argument("--json-output", type=pathlib.Path, required=True)
    return value


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    try:
        asyncio.run(live(parser().parse_args()))
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        print(f"USB AFC PREFLIGHT FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
