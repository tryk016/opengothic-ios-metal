#!/usr/bin/env python3
"""Fail-closed validator for normalized P2.1e0 linear-HDR GPU evidence."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import pathlib
import re
import stat
import sys
from typing import Any, Iterable, NoReturn, Sequence


MAX_EVIDENCE_BYTES = 1024 * 1024
MAX_LOG_BYTES = 16 * 1024 * 1024
MAX_CAPTURE_FILES = 100000
MAX_TEXTURE_EXTENT = 16384
MAX_SAMPLE_COUNT = 4096
UINT64_MAX = (1 << 64) - 1
SCHEMA_VERSION = 1
PRODUCER = "opengothic-linear-hdr-gpu-adapter/1"
SCENE_RESOURCE = "scene-color"
DRAWABLE_RESOURCE = "drawable"
DEVICE_EVIDENCE = "device-gpudebug"
SYNTHETIC_EVIDENCE = "synthetic-fixture"
REQUIRED_CAPTURE_MEMBERS = ("capture", "index", "metadata", "store0")
MISSING_LOSSLESS_SCENE_SAMPLE_PROOF = (
    "BLOCKED: missing lossless capture-derived scene-sample proof"
)


class EvidenceError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def reject_constant(value: str) -> None:
    raise EvidenceError(f"non-finite JSON number is forbidden: {value}")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def exact_object(value: Any, keys: Iterable[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    expected = set(keys)
    actual = set(value)
    require(actual == expected, f"{label} keys differ: expected {sorted(expected)}, got {sorted(actual)}")
    return value


def exact_string(value: Any, expected: str, label: str) -> None:
    require(isinstance(value, str) and value == expected, f"{label} must be {expected!r}")


def bounded_string(value: Any, label: str, maximum: int = 128) -> str:
    require(isinstance(value, str), f"{label} must be a string")
    require(0 < len(value) <= maximum, f"{label} length is invalid")
    require(value.strip() == value, f"{label} must not have surrounding whitespace")
    require(all(32 <= ord(character) < 127 for character in value), f"{label} must be printable ASCII")
    return value


def positive_int(value: Any, label: str, maximum: int) -> int:
    require(isinstance(value, int) and not isinstance(value, bool), f"{label} must be an integer")
    require(0 < value <= maximum, f"{label} is out of range")
    return value


def non_negative_int(value: Any, label: str, maximum: int) -> int:
    require(isinstance(value, int) and not isinstance(value, bool), f"{label} must be an integer")
    require(0 <= value <= maximum, f"{label} is out of range")
    return value


def exact_int(value: Any, expected: int, label: str) -> None:
    require(
        isinstance(value, int) and not isinstance(value, bool) and value == expected,
        f"{label} must be integer {expected}",
    )


def finite_number(value: Any, label: str) -> float:
    require(isinstance(value, (int, float)) and not isinstance(value, bool), f"{label} must be a number")
    number = float(value)
    require(math.isfinite(number), f"{label} must be finite")
    return number


def update_file_hash(digest: Any, path: pathlib.Path) -> None:
    try:
        before = path.lstat()
        require(stat.S_ISREG(before.st_mode), f"capture member is not a regular file: {path.name}")
        with path.open("rb") as source:
            while True:
                block = source.read(1024 * 1024)
                if not block:
                    break
                digest.update(block)
        after = path.lstat()
    except OSError as error:
        raise EvidenceError(f"cannot hash capture member {path.name}: {error}") from error
    require(
        (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
        f"capture member changed while hashing: {path.name}",
    )


def capture_sha256(path: pathlib.Path) -> str:
    require(path.name.endswith(".gputrace"), "capture path must have a .gputrace directory name")
    try:
        before = path.lstat()
    except OSError as error:
        raise EvidenceError(f"cannot inspect capture directory: {error}") from error
    require(stat.S_ISDIR(before.st_mode), "capture must be a real .gputrace directory, not a file or symlink")
    try:
        members = sorted(path.iterdir(), key=lambda member: member.name)
    except OSError as error:
        raise EvidenceError(f"cannot enumerate capture directory: {error}") from error
    require(0 < len(members) <= MAX_CAPTURE_FILES, "capture directory member count is invalid")

    member_names: list[str] = []
    for member in members:
        try:
            metadata = member.lstat()
        except OSError as error:
            raise EvidenceError(f"cannot inspect capture member {member.name}: {error}") from error
        require(stat.S_ISREG(metadata.st_mode), f"capture member must be a regular file: {member.name}")
        require(metadata.st_size > 0, f"capture member must be non-empty: {member.name}")
        member_names.append(member.name)

    for required_name in REQUIRED_CAPTURE_MEMBERS:
        require(required_name in member_names, f"capture is missing regular member {required_name}")
    require(
        any(name.startswith("MTLTexture-") for name in member_names),
        "capture does not contain an MTLTexture-* payload",
    )

    digest = hashlib.sha256(b"opengothic-gputrace-tree-v1\0")
    for member in members:
        metadata = member.lstat()
        name = member.name.encode("utf-8")
        digest.update(b"F\0" + name + b"\0")
        digest.update(str(metadata.st_size).encode("ascii") + b"\0")
        update_file_hash(digest, member)
        digest.update(b"\0")

    try:
        after = path.lstat()
        after_names = sorted(member.name for member in path.iterdir())
    except OSError as error:
        raise EvidenceError(f"cannot re-inspect capture directory: {error}") from error
    require(
        (before.st_dev, before.st_ino, before.st_mtime_ns)
        == (after.st_dev, after.st_ino, after.st_mtime_ns)
        and member_names == after_names,
        "capture directory changed while hashing",
    )
    return digest.hexdigest()


def validate_extent(value: Any) -> tuple[int, int]:
    extent = exact_object(value, ("width", "height"), "extent")
    width = positive_int(extent["width"], "extent.width", MAX_TEXTURE_EXTENT)
    height = positive_int(extent["height"], "extent.height", MAX_TEXTURE_EXTENT)
    return width, height


def validate_resources(value: Any, width: int, height: int, logical_bytes: int) -> None:
    resources = exact_object(value, ("scene", "drawable"), "resources")
    scene = exact_object(
        resources["scene"],
        (
            "resource",
            "pixelFormat",
            "textureType",
            "storageMode",
            "usage",
            "width",
            "height",
            "bytesPerPixel",
            "allocatedBytes",
        ),
        "resources.scene",
    )
    exact_string(scene["resource"], SCENE_RESOURCE, "resources.scene.resource")
    exact_string(scene["pixelFormat"], "RG11B10Float", "resources.scene.pixelFormat")
    exact_string(scene["textureType"], "2D", "resources.scene.textureType")
    exact_string(scene["storageMode"], "Private", "resources.scene.storageMode")
    require(
        scene["usage"] == ["RenderTarget", "ShaderRead"],
        "resources.scene.usage must be exactly RenderTarget then ShaderRead",
    )
    scene_width = positive_int(scene["width"], "resources.scene.width", MAX_TEXTURE_EXTENT)
    scene_height = positive_int(scene["height"], "resources.scene.height", MAX_TEXTURE_EXTENT)
    require(scene_width == width and scene_height == height, "scene texture extent differs from frame extent")
    exact_int(scene["bytesPerPixel"], 4, "resources.scene.bytesPerPixel")
    allocated_bytes = positive_int(
        scene["allocatedBytes"],
        "resources.scene.allocatedBytes",
        UINT64_MAX,
    )
    require(
        allocated_bytes >= logical_bytes,
        "scene allocatedBytes must be at least logicalBytes",
    )

    drawable = exact_object(
        resources["drawable"],
        ("resource", "pixelFormat", "width", "height"),
        "resources.drawable",
    )
    exact_string(drawable["resource"], DRAWABLE_RESOURCE, "resources.drawable.resource")
    exact_string(drawable["pixelFormat"], "BGRA8Unorm", "resources.drawable.pixelFormat")
    drawable_width = positive_int(drawable["width"], "resources.drawable.width", MAX_TEXTURE_EXTENT)
    drawable_height = positive_int(drawable["height"], "resources.drawable.height", MAX_TEXTURE_EXTENT)
    require(drawable_width == width and drawable_height == height, "drawable extent differs from frame extent")


def validate_scene_draws(value: Any) -> None:
    require(isinstance(value, list) and value, "scene.draws must be a non-empty array")
    require(len(value) <= 128, "scene.draws is unreasonably large")
    fragments: list[str] = []
    allowed_fragments = {"riosLandscapeFragment", "riosLandscapeAlphaTestFragment"}
    for index, raw_draw in enumerate(value):
        draw = exact_object(raw_draw, ("vertexFunction", "fragmentFunction"), f"scene.draws[{index}]")
        exact_string(draw["vertexFunction"], "riosLandscapeVertex", f"scene.draws[{index}].vertexFunction")
        fragment = bounded_string(draw["fragmentFunction"], f"scene.draws[{index}].fragmentFunction")
        require(fragment in allowed_fragments, f"scene.draws[{index}] is not a Landscape fragment")
        fragments.append(fragment)
    require("riosLandscapeFragment" in fragments, "scene does not contain the opaque Landscape pipeline")


def validate_events(value: Any) -> None:
    require(isinstance(value, list) and len(value) == 4, "events must contain exactly scene, tone-resolve, overlay, present")

    scene = exact_object(
        value[0],
        ("index", "kind", "colorResource", "pixelFormat", "loadAction", "storeAction", "draws"),
        "events[0]",
    )
    exact_int(scene["index"], 0, "events[0].index")
    exact_string(scene["kind"], "scene", "events[0].kind")
    exact_string(scene["colorResource"], SCENE_RESOURCE, "events[0].colorResource")
    exact_string(scene["pixelFormat"], "RG11B10Float", "events[0].pixelFormat")
    exact_string(scene["loadAction"], "Clear", "events[0].loadAction")
    exact_string(scene["storeAction"], "Store", "events[0].storeAction")
    validate_scene_draws(scene["draws"])

    tone = exact_object(
        value[1],
        (
            "index",
            "kind",
            "colorResource",
            "pixelFormat",
            "loadAction",
            "storeAction",
            "vertexFunction",
            "fragmentFunction",
            "fragmentTextures",
            "fragmentSamplers",
        ),
        "events[1]",
    )
    exact_int(tone["index"], 1, "events[1].index")
    exact_string(tone["kind"], "tone-resolve", "events[1].kind")
    exact_string(tone["colorResource"], DRAWABLE_RESOURCE, "events[1].colorResource")
    exact_string(tone["pixelFormat"], "BGRA8Unorm", "events[1].pixelFormat")
    exact_string(tone["loadAction"], "DontCare", "events[1].loadAction")
    exact_string(tone["storeAction"], "Store", "events[1].storeAction")
    exact_string(tone["vertexFunction"], "riosToneResolveVertex", "events[1].vertexFunction")
    exact_string(tone["fragmentFunction"], "riosToneResolveFragment", "events[1].fragmentFunction")
    require(
        isinstance(tone["fragmentTextures"], list) and len(tone["fragmentTextures"]) == 1,
        "tone-resolve must expose exactly one fragment texture",
    )
    binding = exact_object(
        tone["fragmentTextures"][0],
        ("index", "resource", "access"),
        "events[1].fragmentTextures[0]",
    )
    exact_int(binding["index"], 0, "events[1].fragmentTextures[0].index")
    exact_string(binding["resource"], SCENE_RESOURCE, "events[1].fragmentTextures[0].resource")
    exact_string(binding["access"], "ReadOnly", "events[1].fragmentTextures[0].access")
    require(tone["fragmentSamplers"] == [], "tone-resolve must not bind a fragment sampler")

    overlay = exact_object(
        value[2],
        ("index", "kind", "colorResource", "pixelFormat", "loadAction", "storeAction"),
        "events[2]",
    )
    exact_int(overlay["index"], 2, "events[2].index")
    exact_string(overlay["kind"], "overlay", "events[2].kind")
    exact_string(overlay["colorResource"], DRAWABLE_RESOURCE, "events[2].colorResource")
    exact_string(overlay["pixelFormat"], "BGRA8Unorm", "events[2].pixelFormat")
    exact_string(overlay["loadAction"], "Load", "events[2].loadAction")
    exact_string(overlay["storeAction"], "Store", "events[2].storeAction")

    present = exact_object(value[3], ("index", "kind", "resource"), "events[3]")
    exact_int(present["index"], 3, "events[3].index")
    exact_string(present["kind"], "present", "events[3].kind")
    exact_string(present["resource"], DRAWABLE_RESOURCE, "events[3].resource")


def validate_samples(value: Any, width: int, height: int) -> None:
    evidence = exact_object(
        value,
        ("encoding", "samples", "observedMaximumComponent"),
        "sceneSamples",
    )
    exact_string(evidence["encoding"], "linear-rgb", "sceneSamples.encoding")
    samples = evidence["samples"]
    require(isinstance(samples, list) and samples, "sceneSamples.samples must be a non-empty array")
    require(len(samples) <= MAX_SAMPLE_COUNT, "sceneSamples.samples is unreasonably large")

    sample_maximum = -math.inf
    for index, raw_sample in enumerate(samples):
        sample = exact_object(raw_sample, ("x", "y", "rgb"), f"sceneSamples.samples[{index}]")
        x = non_negative_int(sample["x"], f"sceneSamples.samples[{index}].x", width - 1)
        y = non_negative_int(sample["y"], f"sceneSamples.samples[{index}].y", height - 1)
        require(x < width and y < height, f"sceneSamples.samples[{index}] is outside the frame")
        require(isinstance(sample["rgb"], list) and len(sample["rgb"]) == 3, f"sceneSamples.samples[{index}].rgb must contain three components")
        for component_index, raw_component in enumerate(sample["rgb"]):
            component = finite_number(raw_component, f"sceneSamples.samples[{index}].rgb[{component_index}]")
            require(component >= 0.0, f"sceneSamples.samples[{index}] contains a negative unsigned HDR component")
            sample_maximum = max(sample_maximum, component)

    observed_maximum = finite_number(evidence["observedMaximumComponent"], "sceneSamples.observedMaximumComponent")
    require(sample_maximum > 1.0, "captured scene sample does not prove an HDR component above 1.0")
    require(observed_maximum > 1.0, "captured scene maximum does not prove HDR content above 1.0")
    require(
        observed_maximum >= sample_maximum,
        "observed scene maximum is smaller than a listed scene sample",
    )


def validate_document(document: Any) -> None:
    root = exact_object(
        document,
        (
            "schemaVersion",
            "evidenceClass",
            "producer",
            "source",
            "runIdentity",
            "extent",
            "logicalBytes",
            "resources",
            "events",
            "sceneSamples",
        ),
        "root",
    )
    exact_int(root["schemaVersion"], SCHEMA_VERSION, "schemaVersion")
    require(
        root["evidenceClass"] in (SYNTHETIC_EVIDENCE, DEVICE_EVIDENCE),
        "evidenceClass must be synthetic-fixture or device-gpudebug",
    )
    exact_string(root["producer"], PRODUCER, "producer")

    source = exact_object(root["source"], ("tool", "toolVersion", "captureSha256"), "source")
    exact_string(source["tool"], "gpudebug", "source.tool")
    version = bounded_string(source["toolVersion"], "source.toolVersion", 32)
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version) is not None, "source.toolVersion has an unknown grammar")
    digest = bounded_string(source["captureSha256"], "source.captureSha256", 64)
    require(re.fullmatch(r"[0-9a-f]{64}", digest) is not None, "source.captureSha256 must be a lowercase SHA-256")

    identity = exact_object(
        root["runIdentity"],
        ("buildSha", "targetGeneration", "snapshotSequence"),
        "runIdentity",
    )
    build_sha = bounded_string(identity["buildSha"], "runIdentity.buildSha", 40)
    require(re.fullmatch(r"[0-9a-f]{40}", build_sha) is not None, "runIdentity.buildSha must be lowercase 40-hex")
    positive_int(identity["targetGeneration"], "runIdentity.targetGeneration", UINT64_MAX)
    positive_int(identity["snapshotSequence"], "runIdentity.snapshotSequence", UINT64_MAX)

    width, height = validate_extent(root["extent"])
    logical_bytes = positive_int(root["logicalBytes"], "logicalBytes", UINT64_MAX)
    require(logical_bytes == width * height * 4, "logicalBytes must equal width * height * 4")
    validate_resources(root["resources"], width, height, logical_bytes)
    validate_events(root["events"])
    validate_samples(root["sceneSamples"], width, height)


def load_document(path: pathlib.Path) -> Any:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise EvidenceError(f"cannot inspect evidence file: {error}") from error
    require(stat.S_ISREG(metadata.st_mode), "evidence path must be a regular file, not a symlink or special file")
    require(0 < metadata.st_size <= MAX_EVIDENCE_BYTES, "evidence file size is invalid")
    try:
        raw = path.read_bytes()
        require(len(raw) == metadata.st_size, "evidence file changed while it was read")
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except UnicodeDecodeError as error:
        raise EvidenceError(f"evidence is not UTF-8: {error}") from error
    except json.JSONDecodeError as error:
        raise EvidenceError(f"evidence is not valid JSON: {error}") from error
    except OSError as error:
        raise EvidenceError(f"cannot read evidence file: {error}") from error


def read_log(path: pathlib.Path) -> str:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise EvidenceError(f"cannot inspect linear-HDR log: {error}") from error
    require(stat.S_ISREG(metadata.st_mode), "linear-HDR log must be a regular file, not a symlink")
    require(0 < metadata.st_size <= MAX_LOG_BYTES, "linear-HDR log size is invalid")
    try:
        raw = path.read_bytes()
        require(len(raw) == metadata.st_size, "linear-HDR log changed while it was read")
        return raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise EvidenceError(f"cannot read linear-HDR log: {error}") from error


def load_log_validator() -> Any:
    path = pathlib.Path(__file__).resolve().with_name("validate-linear-hdr-log.py")
    try:
        metadata = path.lstat()
    except OSError as error:
        raise EvidenceError(f"cannot inspect linear-HDR log validator: {error}") from error
    require(stat.S_ISREG(metadata.st_mode), "linear-HDR log validator must be a regular file")
    name = "validate_linear_hdr_log_for_gpu_join"
    specification = importlib.util.spec_from_file_location(name, path)
    require(specification is not None and specification.loader is not None, "cannot load linear-HDR log validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    try:
        specification.loader.exec_module(module)
    except Exception as error:
        raise EvidenceError(f"cannot import linear-HDR log validator: {error}") from error
    require(callable(getattr(module, "validate", None)), "linear-HDR log validator has no validate function")
    return module


def validate_device_join(
    document: Any,
    capture: pathlib.Path,
    log: pathlib.Path,
    expected_sha: str,
    require_attempt: str,
    require_ui: bool = False,
) -> NoReturn:
    validate_document(document)
    exact_string(document["evidenceClass"], DEVICE_EVIDENCE, "evidenceClass")

    digest = capture_sha256(capture)
    require(digest == document["source"]["captureSha256"], "capture digest differs from GPU evidence JSON")

    validator = load_log_validator()
    try:
        values = validator.validate(
            read_log(log),
            expected_sha,
            require_attempt,
            require_ui,
        )
    except Exception as error:
        raise EvidenceError(f"linear-HDR log validation failed: {error}") from error
    require(isinstance(values, dict), "linear-HDR log validator returned an invalid result")

    identity = document["runIdentity"]
    extent = document["extent"]
    require(identity["buildSha"] == expected_sha == values.get("build"), "build SHA does not join GPU evidence and log")
    require(identity["targetGeneration"] == values.get("generation"), "target generation does not join GPU evidence and log")
    require(identity["snapshotSequence"] == values.get("snapshot_sequence"), "snapshot sequence does not join GPU evidence and log")
    require(extent["width"] == values.get("width"), "width does not join GPU evidence and log")
    require(extent["height"] == values.get("height"), "height does not join GPU evidence and log")
    require(document["logicalBytes"] == values.get("bytes"), "logical byte size does not join GPU evidence and log")
    raise EvidenceError(MISSING_LOSSLESS_SCENE_SAMPLE_PROOF)


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=pathlib.Path)
    parser.add_argument("--capture", type=pathlib.Path)
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--expected-sha")
    parser.add_argument("--require-attempt", choices=("startup", "recreate"))
    parser.add_argument("--require-ui", action="store_true")
    parser.add_argument("--allow-synthetic-fixture", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        document = load_document(arguments.evidence)
        validate_document(document)
        if document["evidenceClass"] == SYNTHETIC_EVIDENCE:
            require(
                arguments.allow_synthetic_fixture,
                "synthetic fixture requires explicit --allow-synthetic-fixture",
            )
            require(
                arguments.capture is None
                and arguments.log is None
                and arguments.expected_sha is None
                and arguments.require_attempt is None
                and not arguments.require_ui,
                "synthetic fixture cannot be joined to device capture or log arguments",
            )
        else:
            require(not arguments.allow_synthetic_fixture, "device evidence must not use --allow-synthetic-fixture")
            require(arguments.capture is not None, "device evidence requires --capture")
            require(arguments.log is not None, "device evidence requires --log")
            require(arguments.expected_sha is not None, "device evidence requires --expected-sha")
            require(arguments.require_attempt is not None, "device evidence requires --require-attempt")
            validate_device_join(
                document,
                arguments.capture,
                arguments.log,
                arguments.expected_sha,
                arguments.require_attempt,
                arguments.require_ui,
            )
    except EvidenceError as error:
        print(f"linear HDR GPU evidence validation failed: {error}", file=sys.stderr)
        return 1
    print(f"linear HDR GPU evidence validation passed: class={document['evidenceClass']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
