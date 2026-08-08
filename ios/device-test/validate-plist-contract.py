#!/usr/bin/env python3
"""Validate exact boolean/absence contracts in an Apple property list."""

from __future__ import annotations

import argparse
import contextlib
import io
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import tempfile
import xml.etree.ElementTree as ET


KEY_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9]*$")
BOMS = (b"\xef\xbb\xbf", b"\xff\xfe", b"\xfe\xff", b"\x00\x00\xfe\xff")


class ContractError(ValueError):
    pass


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plist")
    parser.add_argument("--require-true", action="append", default=[])
    parser.add_argument("--require-absent", action="append", default=[])
    parser.add_argument("--self-test", action="store_true")
    return parser


def normalized_requirements(
    require_true: list[str], require_absent: list[str]
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    seen: dict[str, str] = {}
    for mode, keys in (("true", require_true), ("absent", require_absent)):
        for key in keys:
            if KEY_PATTERN.fullmatch(key) is None:
                raise ContractError(f"invalid plist key: {key!r}")
            previous = seen.get(key)
            if previous is not None:
                if previous == mode:
                    raise ContractError(f"duplicate plist requirement: {key}")
                raise ContractError(f"conflicting plist requirement: {key}")
            seen[key] = mode
    if not seen:
        raise ContractError("at least one plist requirement is required")
    return tuple(require_true), tuple(require_absent)


def reject_duplicate_xml_keys(raw: bytes) -> None:
    if not raw.lstrip().startswith(b"<"):
        return
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise ContractError("malformed XML plist") from error
    for dictionary in root.iter("dict"):
        keys: set[str] = set()
        for child in dictionary:
            if child.tag != "key":
                continue
            key = child.text or ""
            if key in keys:
                raise ContractError(f"duplicate plist dictionary key: {key}")
            keys.add(key)


def load_payload(path: Path) -> dict[str, object]:
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ContractError("plist is not an accessible regular file") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise ContractError("plist is not a regular non-symlink file")
    try:
        raw = path.read_bytes()
        if raw.startswith(BOMS):
            raise ContractError("plist byte-order marks are forbidden")
        reject_duplicate_xml_keys(raw)
        payload = plistlib.loads(raw)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ContractError("malformed plist") from error
    if type(payload) is not dict:
        raise ContractError("plist root is not a dictionary")
    return payload


def validate_contract(
    path: Path, require_true: list[str], require_absent: list[str]
) -> None:
    true_keys, absent_keys = normalized_requirements(
        require_true, require_absent
    )
    payload = load_payload(path)
    for key in true_keys:
        if payload.get(key) is not True:
            raise ContractError(f"plist key is not exact CFBoolean true: {key}")
    for key in absent_keys:
        if key in payload:
            raise ContractError(f"plist key must be absent: {key}")


def expect_error(action, label: str) -> None:
    try:
        action()
    except (ContractError, SystemExit):
        return
    raise ContractError(f"self-test false pass: {label}")


def run_self_test() -> None:
    hdr = "RendererIOSLinearHDRGPUTripleCapture"
    metal = "MetalCaptureEnabled"
    with tempfile.TemporaryDirectory(prefix="plist-contract-") as directory:
        root = Path(directory)

        def fixture(name: str, payload: object) -> Path:
            path = root / name
            path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_BINARY))
            return path

        exact = fixture("exact.plist", {hdr: True, metal: True})
        absent = fixture("absent.plist", {})
        hdr_string = fixture("hdr-string.plist", {hdr: "true", metal: True})
        metal_string = fixture("metal-string.plist", {hdr: True, metal: "true"})
        false_value = fixture("false.plist", {hdr: False, metal: True})
        malformed = root / "malformed.plist"
        malformed.write_bytes(b"not a plist")
        duplicate = root / "duplicate.plist"
        duplicate.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict><key>MetalCaptureEnabled</key>'
            '<true/><key>MetalCaptureEnabled</key><true/></dict></plist>\n',
            encoding="utf-8",
        )
        bom_duplicate = root / "bom-duplicate.plist"
        bom_duplicate.write_bytes(
            b"\xef\xbb\xbf"
            b'<?xml version="1.0" encoding="UTF-8"?>\n'
            b'<plist version="1.0"><dict><key>MetalCaptureEnabled</key>'
            b'<false/><key>MetalCaptureEnabled</key><true/></dict></plist>\n'
        )
        symlink = root / "symlink.plist"
        symlink.symlink_to(exact.name)

        validate_contract(exact, [hdr, metal], [])
        validate_contract(absent, [], [hdr, metal])
        for path in (absent, hdr_string, metal_string, false_value):
            expect_error(
                lambda path=path: validate_contract(path, [hdr, metal], []),
                f"non-true requirement {path.name}",
            )
        for path in (exact, hdr_string, metal_string, false_value):
            expect_error(
                lambda path=path: validate_contract(path, [], [hdr, metal]),
                f"absence requirement {path.name}",
            )
        expect_error(
            lambda: validate_contract(malformed, [metal], []), "malformed plist"
        )
        expect_error(
            lambda: validate_contract(duplicate, [metal], []), "duplicate key"
        )
        expect_error(
            lambda: validate_contract(bom_duplicate, [metal], []),
            "BOM duplicate key",
        )
        expect_error(
            lambda: validate_contract(symlink, [hdr, metal], []),
            "symlink plist",
        )
        expect_error(
            lambda: normalized_requirements([metal, metal], []),
            "duplicate requirement",
        )
        expect_error(
            lambda: normalized_requirements([metal], [metal]),
            "conflicting requirement",
        )
        expect_error(
            lambda: normalized_requirements(["bad/key"], []), "invalid key"
        )
        with contextlib.redirect_stderr(io.StringIO()):
            expect_error(
                lambda: argument_parser().parse_args(["--unknown"]),
                "unknown argument",
            )
    print("SELF-TEST PASS")


def main(argv: list[str]) -> int:
    arguments = argument_parser().parse_args(argv)
    try:
        if arguments.self_test:
            if arguments.plist or arguments.require_true or arguments.require_absent:
                raise ContractError("--self-test accepts no contract arguments")
            run_self_test()
            return 0
        if arguments.plist is None:
            raise ContractError("--plist is required")
        validate_contract(
            Path(arguments.plist),
            arguments.require_true,
            arguments.require_absent,
        )
    except ContractError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
