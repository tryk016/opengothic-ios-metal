#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pymobiledevice3==11.2.4"]
# ///
"""Bounded, fail-closed app-container transport over usbmux/House Arrest/AFC."""

from __future__ import annotations

import argparse
import asyncio
import ctypes
import json
import os
import pathlib
import posixpath
import shutil
import sys
import tempfile
from typing import Any, Protocol


ALLOWED_TYPES = frozenset(("S_IFDIR", "S_IFLNK", "S_IFREG"))


class AfcLike(Protocol):
    async def listdir(self, filename: str) -> list[str]: ...

    async def stat(self, filename: str) -> dict[str, Any]: ...

    async def pull(
        self, relative_src: str, dst: str, *, progress_bar: bool
    ) -> None: ...

    async def push(
        self, local_path: str, remote_path: str, *, progress_bar: bool
    ) -> None: ...


def remote_path(value: str) -> str:
    if not value or value.startswith("/") or "\x00" in value:
        raise ValueError("remote path must be a non-empty relative path")
    normalized = posixpath.normpath(value)
    if normalized == "Documents" or normalized.startswith("Documents/"):
        if normalized == value:
            return normalized
    raise ValueError("remote path must be canonical and remain under Documents")


def local_path(value: str) -> pathlib.Path:
    path = pathlib.Path(value)
    if not path.is_absolute() or path != pathlib.Path(os.path.abspath(value)):
        raise ValueError("local path must be absolute and canonical")
    return path


def validate_common(args: argparse.Namespace) -> None:
    if args.domain_type != "appDataContainer":
        raise ValueError("only appDataContainer is supported")
    if not args.device or not args.domain_identifier:
        raise ValueError("device and app bundle identifier are required")
    if args.user != "mobile":
        raise ValueError("only the mobile container user is supported")


def fsync_directory(path: pathlib.Path) -> None:
    directory_fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def rename_exclusive(source: pathlib.Path, destination: pathlib.Path) -> None:
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


async def listing_payload(service: AfcLike, directory: str) -> dict[str, Any]:
    directory = remote_path(directory)
    names = await service.listdir(directory)
    if any(not isinstance(name, str) or not name for name in names):
        raise RuntimeError("AFC returned a malformed directory entry")
    if len(names) != len(set(names)):
        raise RuntimeError("AFC returned duplicate directory entries")

    files = []
    for name in names:
        if name in (".", "..") or "/" in name or "\x00" in name:
            raise RuntimeError("AFC returned an unsafe directory entry")
        metadata = await service.stat(posixpath.join(directory, name))
        file_type = metadata.get("st_ifmt")
        if file_type not in ALLOWED_TYPES:
            raise RuntimeError(f"AFC returned unsupported file type for {name}")
        files.append(
            {
                "name": name,
                "resources": {
                    "isDirectory": file_type == "S_IFDIR",
                    "isSymbolicLink": file_type == "S_IFLNK",
                },
            }
        )
    return {"result": {"files": files}}


def write_json_atomic(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=False, exist_ok=True)
    if path.exists() or path.is_symlink():
        raise RuntimeError("JSON destination already exists")
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
        fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


async def pull(service: AfcLike, source_arg: str, destination_arg: str) -> None:
    source = remote_path(source_arg)
    destination = local_path(destination_arg)
    destination.parent.mkdir(parents=False, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("pull destination already exists")
    metadata = await service.stat(source)
    file_type = metadata.get("st_ifmt")
    if file_type not in ("S_IFREG", "S_IFDIR"):
        raise RuntimeError("pull source must be a regular file or directory")

    if file_type == "S_IFREG":
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
        )
        os.close(descriptor)
        temporary = pathlib.Path(temporary_name)
        temporary.unlink()
        try:
            await service.pull(source, str(temporary), progress_bar=False)
            if not temporary.is_file() or temporary.is_symlink():
                raise RuntimeError("AFC pull did not produce a regular file")
            with temporary.open("rb") as copied:
                os.fsync(copied.fileno())
            os.link(temporary, destination)
            temporary.unlink()
            fsync_directory(destination.parent)
        finally:
            if temporary.exists():
                temporary.unlink()
    else:
        if destination.exists():
            raise RuntimeError("directory pull destination already exists")
        staging = pathlib.Path(
            tempfile.mkdtemp(prefix=f".{destination.name}.", dir=destination.parent)
        )
        try:
            await service.pull(source, str(staging), progress_bar=False)
            received = staging / posixpath.basename(source)
            if not received.is_dir() or received.is_symlink():
                raise RuntimeError("AFC pull did not produce a directory")
            rename_exclusive(received, destination)
            fsync_directory(destination.parent)
        finally:
            shutil.rmtree(staging, ignore_errors=True)


async def push(service: AfcLike, source_arg: str, destination_arg: str) -> None:
    source = local_path(source_arg)
    destination = remote_path(destination_arg)
    if not source.is_file() or source.is_symlink():
        raise RuntimeError("push source must be a regular non-symlink file")
    existing = await service.stat(destination)
    if existing.get("st_ifmt") != "S_IFREG":
        raise RuntimeError("push destination must already be a regular file")
    await service.push(str(source), destination, progress_bar=False)
    written = await service.stat(destination)
    if written.get("st_ifmt") != "S_IFREG":
        raise RuntimeError("push destination changed type")
    if written.get("st_size") != source.stat().st_size:
        raise RuntimeError("push destination size mismatch")


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    value.add_argument("operation", choices=("list", "pull", "push"))
    value.add_argument("--device", required=True)
    value.add_argument("--domain-type", required=True)
    value.add_argument("--domain-identifier", required=True)
    value.add_argument("--user", "--username", dest="user", required=True)
    value.add_argument("--subdirectory")
    value.add_argument("--source")
    value.add_argument("--destination")
    value.add_argument("--json-output")
    value.add_argument("--no-recurse", action="store_true")
    return value


async def run(args: argparse.Namespace) -> None:
    validate_common(args)
    from pymobiledevice3.exceptions import ConnectionTerminatedError, DeviceNotFoundError
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService

    attempts = 2 if args.operation in ("list", "pull") else 1
    for attempt in range(1, attempts + 1):
        try:
            async with await create_using_usbmux(
                serial=args.device, autopair=False, connection_type="USB"
            ) as lockdown:
                async with await HouseArrestService.create(
                    lockdown=lockdown,
                    bundle_id=args.domain_identifier,
                    documents_only=False,
                ) as service:
                    if args.operation == "list":
                        if (
                            not args.no_recurse
                            or not args.subdirectory
                            or not args.json_output
                        ):
                            raise ValueError("list requires bounded flat output arguments")
                        if args.source or args.destination:
                            raise ValueError("list rejects transfer arguments")
                        payload = await listing_payload(service, args.subdirectory)
                        write_json_atomic(local_path(args.json_output), payload)
                    elif args.operation == "pull":
                        if not args.source or not args.destination:
                            raise ValueError("pull requires source and destination")
                        if args.subdirectory or args.json_output or args.no_recurse:
                            raise ValueError("pull rejects listing arguments")
                        await pull(service, args.source, args.destination)
                    else:
                        if not args.source or not args.destination:
                            raise ValueError("push requires source and destination")
                        if args.subdirectory or args.json_output or args.no_recurse:
                            raise ValueError("push rejects listing arguments")
                        await push(service, args.source, args.destination)
            return
        except (ConnectionTerminatedError, DeviceNotFoundError):
            if attempt >= attempts:
                raise
            print(
                f"AFC connection terminated; retrying safe {args.operation} once",
                file=sys.stderr,
            )
            await asyncio.sleep(0.25)


class FakeAfc:
    def __init__(self) -> None:
        self.types = {
            "Documents/Data": "S_IFDIR",
            "Documents/_work": "S_IFDIR",
            "Documents/system": "S_IFDIR",
            "Documents/log.txt": "S_IFREG",
            "Documents/save_slot_20.sav": "S_IFREG",
            "Documents/link": "S_IFLNK",
        }
        self.sizes = {"Documents/save_slot_20.sav": 3}
        self.pushed: tuple[str, str] | None = None

    async def listdir(self, filename: str) -> list[str]:
        if filename != "Documents":
            raise AssertionError(filename)
        return ["Data", "_work", "system"]

    async def stat(self, filename: str) -> dict[str, Any]:
        return {
            "st_ifmt": self.types[filename],
            "st_size": self.sizes.get(filename, 4),
        }

    async def pull(
        self, relative_src: str, dst: str, *, progress_bar: bool
    ) -> None:
        if relative_src != "Documents/log.txt" or progress_bar:
            raise AssertionError((relative_src, progress_bar))
        pathlib.Path(dst).write_bytes(b"test")

    async def push(
        self, local_path: str, remote_path: str, *, progress_bar: bool
    ) -> None:
        if progress_bar:
            raise AssertionError("fake push enabled progress")
        self.pushed = (local_path, remote_path)
        self.sizes[remote_path] = pathlib.Path(local_path).stat().st_size


async def self_test() -> None:
    fake = FakeAfc()
    payload = await listing_payload(fake, "Documents")
    files = payload.get("result", {}).get("files")
    if not isinstance(files, list) or len(files) != 3:
        raise RuntimeError("self-test listing shape mismatch")
    if any(
        entry.get("resources")
        != {"isDirectory": True, "isSymbolicLink": False}
        for entry in files
    ):
        raise RuntimeError("self-test directory metadata mismatch")
    for rejected in ("", "/Documents", "Documents/../Library", "Documents//Data"):
        try:
            remote_path(rejected)
        except ValueError:
            continue
        raise RuntimeError(f"unsafe remote path survived: {rejected!r}")
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        pulled = root / "log.txt"
        await pull(fake, "Documents/log.txt", str(pulled))
        if pulled.read_bytes() != b"test":
            raise RuntimeError("self-test pull content mismatch")
        for collision in (root / "pull-collision", root / "json-collision"):
            collision.write_bytes(b"sentinel")
        try:
            await pull(fake, "Documents/log.txt", str(root / "pull-collision"))
        except RuntimeError:
            pass
        else:
            raise RuntimeError("self-test pull collision was accepted")
        try:
            write_json_atomic(root / "json-collision", payload)
        except RuntimeError:
            pass
        else:
            raise RuntimeError("self-test JSON collision was accepted")
        if (root / "pull-collision").read_bytes() != b"sentinel" or (
            root / "json-collision"
        ).read_bytes() != b"sentinel":
            raise RuntimeError("self-test collision sentinel changed")
        source_directory = root / "directory-source"
        destination_directory = root / "directory-destination"
        source_directory.mkdir()
        destination_directory.mkdir()
        (destination_directory / "sentinel").write_bytes(b"sentinel")
        try:
            rename_exclusive(source_directory, destination_directory)
        except OSError:
            pass
        else:
            raise RuntimeError("self-test directory collision was accepted")
        if not source_directory.is_dir() or (
            destination_directory / "sentinel"
        ).read_bytes() != b"sentinel":
            raise RuntimeError("self-test directory collision changed either tree")
        source = root / "save.sav"
        source.write_bytes(b"new-save")
        await push(fake, str(source), "Documents/save_slot_20.sav")
        if fake.pushed != (str(source), "Documents/save_slot_20.sav"):
            raise RuntimeError("self-test push routing mismatch")
        try:
            await pull(fake, "Documents/link", str(root / "link"))
        except RuntimeError:
            pass
        else:
            raise RuntimeError("self-test symlink pull was accepted")
    print("AFC app-container transport self-test: PASS")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        asyncio.run(self_test())
        return 0
    asyncio.run(run(parser().parse_args()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
