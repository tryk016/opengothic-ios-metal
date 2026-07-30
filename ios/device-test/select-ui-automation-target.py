#!/usr/bin/env python3
"""Pure host-side selection for the RendererIOS UI automation harness."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Any


IPHONEOS_PLATFORM = "com.apple.platform.iphoneos"
IOS_PLATFORM = "iOS"
PHYSICAL_REALITY = "physical"
TRANSPORTS = ("usb", "network")


class SelectionError(ValueError):
    """The supplied inventory does not identify one safe target."""


@dataclass(frozen=True)
class DeviceTarget:
    udid: str
    transport: str


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _xcdevice_records(payload: Any) -> list[Any]:
    if not isinstance(payload, list):
        raise SelectionError("xcdevice payload must be a list")
    return payload


def _coredevice_records(payload: Any) -> list[Any]:
    if not isinstance(payload, dict):
        raise SelectionError("CoreDevice payload must be an object")
    result = payload.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("devices"), list):
        raise SelectionError("CoreDevice payload has no result.devices list")
    return result["devices"]


def _core_device_is_connected(record: dict[str, Any]) -> bool:
    witnesses = 0
    if "properties" in record:
        properties = record["properties"]
        if not isinstance(properties, dict):
            return False
        if "connection" in properties:
            connection = properties["connection"]
            if not isinstance(connection, dict):
                return False
            if connection.get("state") != "connected":
                return False
            witnesses += 1
    if "connectionProperties" in record:
        connection = record["connectionProperties"]
        if not isinstance(connection, dict):
            return False
        if connection.get("tunnelState") != "connected":
            return False
        witnesses += 1
    return witnesses > 0


def _core_udid(record: Any) -> str | None:
    if not isinstance(record, dict):
        return None
    hardware = record.get("hardwareProperties")
    if not isinstance(hardware, dict):
        return None
    udid = hardware.get("udid")
    return udid if _nonempty_string(udid) else None


def _validate_pair(
    xc_record: Any,
    core_records: list[Any],
) -> tuple[DeviceTarget | None, str | None]:
    if not isinstance(xc_record, dict):
        return None, "xcdevice witness is not an object"
    transport = xc_record.get("interface")
    if transport not in TRANSPORTS:
        return None, "xcdevice witness has an unsupported transport"
    identifier = xc_record.get("identifier")
    if not _nonempty_string(identifier):
        return None, f"{transport} xcdevice witness has an empty identifier"
    if xc_record.get("available") is not True:
        return None, f"{transport} xcdevice witness is unavailable"
    if xc_record.get("simulator") is not False:
        return None, f"{transport} xcdevice witness is not physical"
    if xc_record.get("platform") != IPHONEOS_PLATFORM:
        return None, f"{transport} xcdevice witness is not iPhoneOS"

    matches = [
        record
        for record in core_records
        if _core_udid(record) == identifier
    ]
    if len(matches) != 1:
        return (
            None,
            f"{transport} xcdevice witness has {len(matches)} CoreDevice matches",
        )
    core_record = matches[0]
    hardware = core_record.get("hardwareProperties")
    core_identifier = core_record.get("identifier")
    core_udid = hardware.get("udid")
    if not _nonempty_string(core_identifier) or not _nonempty_string(core_udid):
        return None, "CoreDevice match has an empty identifier or UDID"
    if hardware.get("platform") != IOS_PLATFORM:
        return None, "CoreDevice match is not iOS"
    if hardware.get("reality") != PHYSICAL_REALITY:
        return None, "CoreDevice match is not physical"
    if not _core_device_is_connected(core_record):
        return None, "CoreDevice match is disconnected"
    if identifier != core_udid:
        return None, "xcdevice/CoreDevice UDID cross-match failed"
    return DeviceTarget(identifier, transport), None


def _transport_witnesses(
    xc_records: list[Any],
    transport: str,
) -> list[Any]:
    return [
        record
        for record in xc_records
        if isinstance(record, dict) and record.get("interface") == transport
    ]


def _iphone_witness_records(xc_records: list[Any]) -> list[Any]:
    witnesses: list[Any] = []
    for record in xc_records:
        if not isinstance(record, dict):
            continue
        platform = record.get("platform")
        if _nonempty_string(platform) and platform != IPHONEOS_PLATFORM:
            continue
        witnesses.append(record)
    return witnesses


def _select_requested(
    xc_records: list[Any],
    core_records: list[Any],
    requested: str,
) -> DeviceTarget:
    requested_xc = [
        record
        for record in xc_records
        if isinstance(record, dict)
        and record.get("interface") in TRANSPORTS
        and record.get("identifier") == requested
    ]
    requested_core = [
        record
        for record in core_records
        if isinstance(record, dict)
        and (
            record.get("identifier") == requested
            or _core_udid(record) == requested
        )
    ]
    target_udids = sorted(
        {
            *(
                record["identifier"]
                for record in requested_xc
                if _nonempty_string(record.get("identifier"))
            ),
            *(
                udid
                for record in requested_core
                if (udid := _core_udid(record)) is not None
            ),
        }
    )
    if len(target_udids) != 1:
        raise SelectionError(
            "requested identity does not resolve to exactly one device UDID"
        )
    target_udid = target_udids[0]
    xc_matches = [
        record
        for record in xc_records
        if isinstance(record, dict)
        and record.get("interface") in TRANSPORTS
        and record.get("identifier") == target_udid
    ]
    core_matches = [
        record for record in core_records if _core_udid(record) == target_udid
    ]
    if len(xc_matches) != 1:
        raise SelectionError(
            "requested identity does not have exactly one xcdevice record"
        )
    if len(core_matches) != 1:
        raise SelectionError(
            "requested identity does not have exactly one CoreDevice record"
        )
    selected, error = _validate_pair(xc_matches[0], core_records)
    if selected is None:
        raise SelectionError(error or "requested identity pair is invalid")
    if requested not in (
        selected.udid,
        core_matches[0].get("identifier"),
    ):
        raise SelectionError("requested identity was not preserved")
    return selected


def select_device_target(
    xcdevice_payload: Any,
    coredevice_payload: Any,
    requested: str = "",
) -> DeviceTarget:
    xc_records = _xcdevice_records(xcdevice_payload)
    core_records = _coredevice_records(coredevice_payload)
    iphone_witnesses = _iphone_witness_records(xc_records)
    if requested:
        return _select_requested(iphone_witnesses, core_records, requested)

    usb_witnesses = _transport_witnesses(iphone_witnesses, "usb")
    valid_usb: list[DeviceTarget] = []
    invalid_usb: list[str] = []
    for witness in usb_witnesses:
        candidate, error = _validate_pair(witness, core_records)
        if candidate is None:
            invalid_usb.append(error or "invalid USB witness")
        else:
            valid_usb.append(candidate)
    if valid_usb:
        if invalid_usb or len(valid_usb) != 1:
            raise SelectionError("USB selection is malformed or ambiguous")
        return valid_usb[0]
    if usb_witnesses:
        raise SelectionError("malformed USB witness blocks network fallback")

    network_witnesses = _transport_witnesses(iphone_witnesses, "network")
    valid_network: list[DeviceTarget] = []
    invalid_network: list[str] = []
    for witness in network_witnesses:
        candidate, error = _validate_pair(witness, core_records)
        if candidate is None:
            invalid_network.append(error or "invalid network witness")
        else:
            valid_network.append(candidate)
    if invalid_network or len(valid_network) != 1:
        raise SelectionError("network selection is malformed or ambiguous")
    return valid_network[0]


def select_product_bundle(
    apps_payload: Any,
    base_bundle_id: str,
    requested: str = "",
) -> str:
    if base_bundle_id != "opengothic.gothic2":
        raise SelectionError("unexpected base bundle identifier")
    if not isinstance(apps_payload, dict):
        raise SelectionError("apps payload must be an object")
    result = apps_payload.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("apps"), list):
        raise SelectionError("apps payload has no result.apps list")

    product_pattern = re.compile(
        r"^opengothic\.gothic2\.[A-Z0-9]{10}$"
    )
    runner_pattern = re.compile(
        r"^opengothic\.gothic2\.[A-Z0-9]{10}\..+$"
    )
    products: list[str] = []
    malformed: list[str] = []
    for app in result["apps"]:
        if not isinstance(app, dict):
            continue
        bundle = app.get("bundleIdentifier")
        if not isinstance(bundle, str) or not bundle.startswith(
            base_bundle_id + "."
        ):
            continue
        if product_pattern.fullmatch(bundle):
            products.append(bundle)
        elif runner_pattern.fullmatch(bundle):
            continue
        else:
            malformed.append(bundle)
    if malformed:
        raise SelectionError("malformed OpenGothic bundle suffix")
    if requested:
        if product_pattern.fullmatch(requested) is None:
            raise SelectionError("requested bundle is not an exact product")
        products = [bundle for bundle in products if bundle == requested]
    if len(products) != 1:
        raise SelectionError(
            f"expected one installed product bundle, found {len(products)}"
        )
    return products[0]


def _xc(udid: str, transport: str = "usb", **changes: Any) -> dict[str, Any]:
    record: dict[str, Any] = {
        "identifier": udid,
        "interface": transport,
        "available": True,
        "simulator": False,
        "platform": IPHONEOS_PLATFORM,
    }
    record.update(changes)
    return record


def _core(
    udid: str,
    identifier: str,
    **hardware_changes: Any,
) -> dict[str, Any]:
    hardware: dict[str, Any] = {
        "udid": udid,
        "platform": IOS_PLATFORM,
        "reality": PHYSICAL_REALITY,
    }
    hardware.update(hardware_changes)
    return {
        "identifier": identifier,
        "hardwareProperties": hardware,
        "properties": {"connection": {"state": "connected"}},
    }


def _core_payload(*records: Any) -> dict[str, Any]:
    return {"result": {"devices": list(records)}}


def _apps_payload(*bundles: str) -> dict[str, Any]:
    return {
        "result": {
            "apps": [{"bundleIdentifier": bundle} for bundle in bundles]
        }
    }


def _expect_selection_error(callback: Any, label: str) -> None:
    try:
        callback()
    except SelectionError:
        return
    raise AssertionError(f"self-test unexpectedly accepted {label}")


def run_self_test() -> None:
    usb_udid = "00008101-USB"
    network_udid = "00008101-NETWORK"
    usb_core = _core(usb_udid, "core-usb")
    network_core = _core(network_udid, "core-network")

    selected = select_device_target(
        [_xc(usb_udid), _xc(network_udid, "network")],
        _core_payload(usb_core, network_core),
    )
    assert selected == DeviceTarget(usb_udid, "usb")
    selected = select_device_target(
        [_xc(network_udid, "network")],
        _core_payload(network_core),
    )
    assert selected == DeviceTarget(network_udid, "network")

    malformed_usb_cases = (
        ("unmatched", _xc("unmatched")),
        (
            "disconnected",
            _xc(usb_udid),
            _core(
                usb_udid,
                "core-usb",
            )
            | {"properties": {"connection": {"state": "disconnected"}}},
        ),
        (
            "nonphysical",
            _xc(usb_udid),
            _core(usb_udid, "core-usb", reality="simulator"),
        ),
        ("unavailable", _xc(usb_udid, available=False), usb_core),
        ("simulator", _xc(usb_udid, simulator=True), usb_core),
        ("missing-platform", _xc(usb_udid, platform=None), usb_core),
        (
            "wrong-core-platform",
            _xc(usb_udid),
            _core(usb_udid, "core-usb", platform="macOS"),
        ),
        ("malformed", _xc("", transport="usb"), usb_core),
    )
    for case in malformed_usb_cases:
        label, usb_witness, *core_override = case
        usb_record = core_override[0] if core_override else usb_core
        _expect_selection_error(
            lambda usb_witness=usb_witness, usb_record=usb_record:
                select_device_target(
                    [usb_witness, _xc(network_udid, "network")],
                    _core_payload(usb_record, network_core),
                ),
            f"{label} USB witness with valid network fallback",
        )
    selected = select_device_target(
        [
            _xc(
                "A1B2C3D4-MY-MAC",
                platform="com.apple.platform.macosx",
            ),
            _xc(network_udid, "network"),
        ],
        _core_payload(network_core),
    )
    assert selected == DeviceTarget(network_udid, "network")
    _expect_selection_error(
        lambda: select_device_target(
            [_xc(usb_udid), _xc("00008101-USB2"), _xc(network_udid, "network")],
            _core_payload(
                usb_core,
                _core("00008101-USB2", "core-usb-2"),
                network_core,
            ),
        ),
        "two USB candidates with valid network",
    )
    _expect_selection_error(
        lambda: select_device_target(
            [_xc(network_udid, "network"), _xc("00008101-NET2", "network")],
            _core_payload(
                network_core,
                _core("00008101-NET2", "core-network-2"),
            ),
        ),
        "two network candidates",
    )

    for transport, udid, core_identifier in (
        ("usb", usb_udid, "core-usb"),
        ("network", network_udid, "core-network"),
    ):
        xc_record = _xc(udid, transport)
        core_record = _core(udid, core_identifier)
        payload = _core_payload(core_record)
        assert select_device_target(
            [xc_record], payload, udid
        ) == DeviceTarget(udid, transport)
        assert select_device_target(
            [xc_record], payload, core_identifier
        ) == DeviceTarget(udid, transport)
    _expect_selection_error(
        lambda: select_device_target(
            [_xc(usb_udid)], _core_payload(usb_core), "unknown"
        ),
        "unknown requested identity",
    )
    _expect_selection_error(
        lambda: select_device_target(
            [_xc(usb_udid), _xc(network_udid, "network")],
            _core_payload(
                usb_core,
                _core(network_udid, usb_udid),
            ),
            usb_udid,
        ),
        "requested identity mismatch",
    )
    _expect_selection_error(
        lambda: select_device_target(
            [_xc(usb_udid), _xc(usb_udid)],
            _core_payload(usb_core),
            usb_udid,
        ),
        "duplicate requested xcdevice records",
    )
    _expect_selection_error(
        lambda: select_device_target(
            [_xc(usb_udid)],
            _core_payload(usb_core, usb_core.copy()),
            usb_udid,
        ),
        "duplicate requested CoreDevice records",
    )

    product = "opengothic.gothic2.ABCDE12345"
    runner = product + ".RendererIOSUITests.xctrunner"
    assert select_product_bundle(
        _apps_payload(product, runner), "opengothic.gothic2"
    ) == product
    for label, payload, requested in (
        ("runner-only", _apps_payload(runner), ""),
        (
            "two-products",
            _apps_payload(product, "opengothic.gothic2.ZYXWVU9876"),
            "",
        ),
        ("malformed-suffix", _apps_payload("opengothic.gothic2.BAD"), ""),
        ("requested-mismatch", _apps_payload(product),
         "opengothic.gothic2.ZYXWVU9876"),
    ):
        _expect_selection_error(
            lambda payload=payload, requested=requested:
                select_product_bundle(
                    payload, "opengothic.gothic2", requested
                ),
            label,
        )
    print(
        "UI automation target selector self-test passed: "
        "USB-first/fail-closed fallback, explicit identity, exact product"
    )


def _load_json(path: str) -> Any:
    return json.loads(pathlib.Path(path).read_text())


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    device = subparsers.add_parser("device")
    device.add_argument("--xcdevice-json", required=True)
    device.add_argument("--coredevice-json", required=True)
    device.add_argument("--requested", default="")
    bundle = subparsers.add_parser("bundle")
    bundle.add_argument("--apps-json", required=True)
    bundle.add_argument("--base-bundle-id", required=True)
    bundle.add_argument("--requested", default="")
    subparsers.add_parser("self-test")
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "self-test":
            run_self_test()
            return 0
        if args.command == "device":
            selected = select_device_target(
                _load_json(args.xcdevice_json),
                _load_json(args.coredevice_json),
                args.requested,
            )
            print(f"{selected.udid}\t{selected.transport}")
            return 0
        selected_bundle = select_product_bundle(
            _load_json(args.apps_json),
            args.base_bundle_id,
            args.requested,
        )
        print(selected_bundle)
        return 0
    except (OSError, json.JSONDecodeError, SelectionError) as error:
        print(f"selection failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
