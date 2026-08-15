#!/usr/bin/env python3
"""Collect one truthful, capture-derived Multiply2 draw-evidence document."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import struct
import sys
import tempfile
import time
from typing import Any, Sequence


GPUDEBUG = "/usr/bin/gpudebug"
MAX_FETCH_BYTES = 64 * 1024 * 1024
MAX_DOCUMENT_BYTES = 4 * 1024 * 1024
MAX_TRANSCRIPT_BYTES = 4 * 1024 * 1024
DRAW_RE = re.compile(
    r"commands/(cb(?:0|[1-9][0-9]*))/(re(?:0|[1-9][0-9]*))/"
    r"grp(?:0|[1-9][0-9]*)/draw(?:0|[1-9][0-9]*)\Z")
COMMAND_RE = re.compile(
    r"commands/(cb(?:0|[1-9][0-9]*))/(?:re|be)(?:0|[1-9][0-9]*)/"
    r"grp(?:0|[1-9][0-9]*)/(?:draw|blit)(?:0|[1-9][0-9]*)\Z")
API_RE = re.compile(r"api_calls/api(?:0|[1-9][0-9]*)\Z")
TEXTURE_RE = re.compile(r"@tex(?:0|[1-9][0-9]*)\Z")
BUFFER_RE = re.compile(r"@buf(?:0|[1-9][0-9]*)\Z")
DSS_RE = re.compile(r"@dss(?:0|[1-9][0-9]*)\Z")
PIPELINE_RE = re.compile(r"@rps(?:0|[1-9][0-9]*)\Z")
RESOURCE_INDEX_RE = re.compile(r"0x[0-9a-f]+\Z")
POSITIVE_RE = re.compile(r"[1-9][0-9]*\Z")
SHA_RE = re.compile(r"[0-9a-f]{64}\Z")
SAFE_LEAF_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}\Z")
INPUT_LEAF_RE = re.compile(
    r"RendererIOS-multiply2-input-v1-([ab])-g([1-9][0-9]*)-"
    r"s([1-9][0-9]*)\.bin\Z")
OUTPUT_LEAF_RE = re.compile(
    r"RendererIOS-multiply2-draw-evidence-v1-([ab])-g([1-9][0-9]*)-"
    r"s([1-9][0-9]*)\.json\Z")
TRANSCRIPT_MANIFEST_LEAF = "multiply2-draw-transcript-manifest-v1.json"


class EvidenceError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) +
            "\n").encode("utf-8")


def load_public_gpu_module() -> Any:
    path = pathlib.Path(__file__).with_name("validate-linear-hdr-gpu-evidence.py")
    spec = importlib.util.spec_from_file_location("multiply2_draw_gpu_validator", path)
    require(spec is not None and spec.loader is not None,
            "could not load the public gpudebug validator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_coverage_module() -> Any:
    path = pathlib.Path(__file__).with_name("validate-multiply2-coverage-proof.py")
    spec = importlib.util.spec_from_file_location("multiply2_draw_coverage_validator", path)
    require(spec is not None and spec.loader is not None,
            "could not load the public coverage validator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def regular_bytes(path: pathlib.Path, label: str, maximum: int) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum,
                f"{label} is not one bounded regular file")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            require(chunk != b"", f"{label} was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        require(os.read(descriptor, 1) == b"", f"{label} grew while reading")
        after = os.fstat(descriptor)
        require((before.st_dev, before.st_ino, before.st_size,
                 before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_dev, after.st_ino, after.st_size,
                 after.st_mtime_ns, after.st_ctime_ns),
                f"{label} changed while reading")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def exact_keys(value: Any, keys: tuple[str, ...], label: str) -> dict[str, Any]:
    require(type(value) is dict and tuple(value.keys()) == keys,
            f"{label} keys/order are not exact")
    return value


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_input_artifact(raw: bytes) -> dict[str, Any]:
    require(len(raw) >= 320 and raw[:8] == b"RIOSM29\0",
            "Multiply2 input artifact header/magic is invalid")
    schema, endian, header = struct.unpack_from("<HHI", raw, 8)
    base_count, multiply_count = struct.unpack_from("<QQ", raw, 16)
    record_bytes, constants_bytes = struct.unpack_from("<II", raw, 32)
    generation, sequence = struct.unpack_from("<QQ", raw, 40)
    flags, reserved = struct.unpack_from("<II", raw, 56)
    require((schema, endian, header, record_bytes, constants_bytes,
             multiply_count, flags, reserved) ==
            (1, 0x4C45, 64, 256, 160, 1, 0, 0),
            "Multiply2 input artifact schema tuple is invalid")
    require(1 <= base_count <= 100000 and generation > 0 and sequence > 0 and
            len(raw) == 64 + (base_count + 1) * 256,
            "Multiply2 input artifact counts/identity/size are invalid")
    offset = 64 + base_count * 256
    record_raw = raw[offset:offset + 256]
    values = struct.unpack_from("<9Q5I4B", record_raw)
    (source, mesh, material, texture, index_offset, index_count,
     vertex_bytes, index_bytes, material_flags, vertex_stride,
     texture_width, texture_height, texture_mips, texture_format,
     kind, category, animation, phase) = values
    require(source > 0 and mesh > 0 and material > 0 and texture > 0 and
            index_count > 0 and vertex_bytes > 0 and index_bytes > 0 and
            index_offset <= index_bytes and index_count <= (1 << 64) // 4 and
            index_count * 4 <= index_bytes - index_offset and
            material_flags == 2 and vertex_stride == 36 and
            texture_width > 0 and texture_height > 0 and texture_mips > 0 and
            texture_format in (1, 2, 3, 4) and
            (kind, category, animation, phase) == (2, 5, 0, 1),
            "sole Multiply2 record is invalid")
    return {
        "generation": generation, "sequence": sequence,
        "baseCount": base_count, "multiply2Payload": record_raw,
        "record": {
            "sourceId": source, "meshId": mesh, "materialId": material,
            "textureId": texture, "indexByteOffset": index_offset,
            "indexCount": index_count, "vertexBufferBytes": vertex_bytes,
            "indexBufferBytes": index_bytes, "materialFlags": material_flags,
            "textureWidth": texture_width, "textureHeight": texture_height,
            "textureMipCount": texture_mips, "textureFormat": texture_format,
            "recordOffset": offset, "constants": record_raw[96:256],
        },
    }


def parse_ref(value: Any, pattern: re.Pattern[str], label: str) -> str:
    require(type(value) is str, f"{label} is not a string")
    match = re.match(r"(@(?:tex|buf|dss|rps)(?:0|[1-9][0-9]*))(?:\s|\Z)", value)
    require(match is not None and pattern.fullmatch(match.group(1)) is not None,
            f"{label} has no exact native reference")
    return match.group(1)


def uint_field(value: Any, label: str, maximum: int = (1 << 64) - 1) -> int:
    require(type(value) is str and re.fullmatch(r"(?:0|[1-9][0-9]*)", value),
            f"{label} is not canonical unsigned decimal")
    result = int(value)
    require(result <= maximum, f"{label} exceeds its bound")
    return result


def find_api(raw: bytes, expected_text: str, gpu: Any, label: str) -> tuple[str, int]:
    document = gpu._direct_info_json(raw, label)
    result = exact_keys(document, ("matches", "totalMatches"), label)
    matches = result["matches"]
    require(type(matches) is list and type(result["totalMatches"]) is int and
            result["totalMatches"] == len(matches) and len(matches) <= 16,
            f"{label} find result is malformed or unbounded")
    api_matches = []
    for index, candidate in enumerate(matches):
        match = exact_keys(candidate, ("label", "summary", "url"),
                           f"{label} match {index}")
        if (match["label"] == "" and type(match["summary"]) is str and
                "insertDebugSignpost" in match["summary"] and
                expected_text in match["summary"] and
                type(match["url"]) is str and
                API_RE.fullmatch(match["url"]) is not None):
            api_matches.append(match)
    require(len(api_matches) == 1,
            f"{label} does not identify the expected API signpost")
    match = api_matches[0]
    index = int(match["url"].rsplit("api", 1)[1])
    return match["url"], index


def linked_command(raw: bytes, expected_api: str, gpu: Any,
                   label: str, pattern: re.Pattern[str]) -> str:
    document = gpu._navigable_json(raw, label)
    children = document.get("children")
    links = document.get("links")
    require(children == [] and type(links) is dict and tuple(links.keys()) == ("d",) and
            type(links["d"]) is str and pattern.fullmatch(links["d"]) is not None,
            f"{label} has no exact command-tree link")
    require(expected_api.startswith("api_calls/api"), f"{label} API path is invalid")
    return links["d"]


def listed_binding(document: Any, name: str, ref_pattern: re.Pattern[str],
                   gpu: Any, label: str) -> str:
    children = gpu._listing_children(document, label)
    matches = [child for child in children if child["name"] == name]
    require(len(matches) == 1, f"{label} lacks one {name} binding")
    values = gpu._child_strings(matches[0])
    refs = [token for value in values for token in value.split()
            if ref_pattern.fullmatch(token)]
    require(len(refs) == 1, f"{label} {name} lacks one native ref")
    return refs[0]


def native_texture(info: dict[str, Any], ref: str, label: str) -> dict[str, str]:
    required = ("allocationID", "dimensions", "pixelFormat", "resourceIndex")
    require(all(key in info and type(info[key]) is str for key in required),
            f"{label} texture info is incomplete")
    require(POSITIVE_RE.fullmatch(info["allocationID"]) is not None and
            RESOURCE_INDEX_RE.fullmatch(info["resourceIndex"]) is not None and
            re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*", info["dimensions"]),
            f"{label} texture native identity is malformed")
    return {"allocationID": info["allocationID"],
            "resourceIndex": info["resourceIndex"], "textureRef": ref}


def transcript_manifest(entries: list[dict[str, Any]], directory: pathlib.Path) -> str:
    stream = bytearray(b"opengothic-multiply2-draw-transcripts-v1\0")
    for index, raw_entry in enumerate(entries):
        entry = exact_keys(raw_entry, (
            "argv", "bytes", "file", "kind", "role", "sha256"),
            f"draw transcript entry {index}")
        require(type(entry["argv"]) is list and entry["argv"] and
                all(type(argument) is str and argument.isascii() and argument
                    for argument in entry["argv"]),
                f"draw transcript entry {index} argv is invalid")
        require(type(entry["bytes"]) is int and entry["bytes"] > 0 and
                type(entry["file"]) is str and
                SAFE_LEAF_RE.fullmatch(entry["file"]) is not None and
                entry["kind"] in ("resource", "transcript") and
                type(entry["role"]) is str and
                SAFE_LEAF_RE.fullmatch(entry["role"]) is not None and
                type(entry["sha256"]) is str and
                SHA_RE.fullmatch(entry["sha256"]) is not None,
                f"draw transcript entry {index} fields are invalid")
        raw = regular_bytes(directory / entry["file"],
                            f"draw transcript {entry['role']}",
                            MAX_FETCH_BYTES if entry["kind"] == "resource"
                            else MAX_TRANSCRIPT_BYTES)
        require(len(raw) == entry["bytes"] and sha256(raw) == entry["sha256"],
                f"draw transcript {entry['role']} changed")
        for value in (entry["role"], entry["file"], entry["kind"]):
            encoded = value.encode("ascii")
            stream += struct.pack("<I", len(encoded)) + encoded
        stream += struct.pack("<I", len(entry["argv"]))
        for argument in entry["argv"]:
            encoded = argument.encode("ascii")
            stream += struct.pack("<I", len(encoded)) + encoded
        stream += struct.pack("<Q", len(raw)) + raw
    return sha256(bytes(stream))


def transcript_manifest_bytes(entries: list[dict[str, Any]],
                              directory: pathlib.Path) -> bytes:
    return canonical_json({
        "contentSha256": transcript_manifest(entries, directory),
        "entries": entries,
        "schemaVersion": 1,
    })


def validate_transcript_directory(root: dict[str, Any],
                                  directory: pathlib.Path) -> None:
    require(directory.is_dir() and not directory.is_symlink(),
            "draw transcript directory is invalid")
    manifest_raw = regular_bytes(
        directory / TRANSCRIPT_MANIFEST_LEAF, "draw transcript manifest",
        MAX_DOCUMENT_BYTES)
    require(sha256(manifest_raw) ==
            root["source"]["drawTranscriptManifestSha256"],
            "draw transcript manifest hash differs from evidence")
    try:
        manifest = json.loads(manifest_raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"draw transcript manifest is invalid: {error}") from error
    require(manifest_raw == canonical_json(manifest),
            "draw transcript manifest is not canonical")
    exact_keys(manifest, ("contentSha256", "entries", "schemaVersion"),
               "draw transcript manifest")
    require(manifest["schemaVersion"] == 1 and
            type(manifest["entries"]) is list and manifest["entries"] and
            transcript_manifest(manifest["entries"], directory) ==
                manifest["contentSha256"],
            "draw transcript manifest content differs")
    expected = {TRANSCRIPT_MANIFEST_LEAF}
    for entry in manifest["entries"]:
        expected.add(entry["file"])
    require({path.name for path in directory.iterdir()} == expected,
            "draw transcript directory contains missing or extra leaves")


def validate_document(document: Any) -> dict[str, Any]:
    root = exact_keys(document, (
        "artifact", "attachment", "coverage", "draw", "schemaVersion",
        "signposts", "snapshot", "source", "stages"), "draw evidence")
    require(root["schemaVersion"] == 1 and type(root["schemaVersion"]) is int,
            "draw evidence schemaVersion is not integer 1")
    artifact = exact_keys(root["artifact"], (
        "constantsSha256", "indexByteOffset", "indexBufferBytes", "indexCount",
        "inputArtifactSha256", "materialFlags", "multiply2PayloadSha256",
        "recordBytes", "recordOffset", "sourceId", "textureId",
        "vertexBufferBytes"), "artifact binding")
    attachment = exact_keys(root["attachment"], (
        "allocationID", "colorIndex", "pixelFormat", "resourceIndex",
        "textureRef"), "attachment binding")
    require(attachment["colorIndex"] == 0 and
            attachment["pixelFormat"] == "RG11B10Float" and
            type(attachment["allocationID"]) is str and
            POSITIVE_RE.fullmatch(attachment["allocationID"]) is not None and
            type(attachment["resourceIndex"]) is str and
            RESOURCE_INDEX_RE.fullmatch(attachment["resourceIndex"]) is not None and
            type(attachment["textureRef"]) is str and
            TEXTURE_RE.fullmatch(attachment["textureRef"]) is not None,
            "attachment native identity is invalid")
    coverage = exact_keys(root["coverage"], (
        "artifactPayloadSha256", "artifactSha256", "blitOption",
        "copyCommandPath", "destinationAllocationID", "destinationBufferOffset",
        "destinationBufferRef", "destinationBytesPerImage",
        "destinationBytesPerRow", "destinationResourceIndex",
        "fetchedPaddedBytes", "fetchedPaddedSha256", "gpuProduced",
        "sourceAllocationID", "sourcePixelFormat", "sourceResourceIndex",
        "sourceTextureRef", "strippedPayloadEqual", "strippedPayloadSha256"),
        "coverage binding")
    require(coverage["gpuProduced"] is True and
            coverage["strippedPayloadEqual"] is True and
            coverage["blitOption"] == "StencilFromDepthStencil" and
            coverage["sourcePixelFormat"] == "Depth32Float_Stencil8",
            "coverage GPU/stencil truth fields are invalid")
    require(type(coverage["copyCommandPath"]) is str and
            COMMAND_RE.fullmatch(coverage["copyCommandPath"]) is not None and
            type(coverage["sourceTextureRef"]) is str and
            TEXTURE_RE.fullmatch(coverage["sourceTextureRef"]) is not None and
            type(coverage["destinationBufferRef"]) is str and
            BUFFER_RE.fullmatch(coverage["destinationBufferRef"]) is not None and
            type(coverage["sourceAllocationID"]) is str and
            POSITIVE_RE.fullmatch(coverage["sourceAllocationID"]) is not None and
            type(coverage["destinationAllocationID"]) is str and
            POSITIVE_RE.fullmatch(coverage["destinationAllocationID"]) is not None and
            type(coverage["sourceResourceIndex"]) is str and
            RESOURCE_INDEX_RE.fullmatch(coverage["sourceResourceIndex"]) is not None and
            type(coverage["destinationResourceIndex"]) is str and
            RESOURCE_INDEX_RE.fullmatch(coverage["destinationResourceIndex"]) is not None and
            all(type(coverage[name]) is int and coverage[name] >= 0 for name in (
                "destinationBufferOffset", "destinationBytesPerImage",
                "destinationBytesPerRow", "fetchedPaddedBytes")) and
            coverage["destinationBufferOffset"] == 0 and
            coverage["destinationBytesPerImage"] == coverage["fetchedPaddedBytes"] and
            coverage["destinationBytesPerRow"] > 0,
            "coverage copy/resource layout is invalid")
    draw = exact_keys(root["draw"], (
        "commandPath", "constantsBufferIndex", "constantsBytes",
        "constantsSha256", "constantsStorage", "depthStencilAllocationID",
        "depthStencilBindings", "depthStencilResourceIndex", "depthStencilRef",
        "fragmentFunction", "indexBufferBytes", "indexBufferOffset",
        "indexBufferRef", "indexBufferSha256", "indexCount", "indexType",
        "pipelineLabel", "primitiveType", "scissor", "sourceId",
        "sourceIdProvenance", "stencilState", "textureAllocationID",
        "textureFragmentIndex", "textureId", "textureIdProvenance",
        "textureRef", "textureResourceIndex", "vertexBufferBytes",
        "vertexBufferRef", "vertexBufferSha256", "vertexFunction", "viewport",
        "sourceRGBBlendFactor", "textureHeight", "textureMipCount",
        "texturePixelFormat", "textureWidth"),
        "target draw")
    require(draw["constantsBufferIndex"] == 1 and
            draw["constantsStorage"] == "inline" and
            draw["constantsBytes"] == 160 and
            draw["depthStencilBindings"] == ["depth", "stencil"] and
            draw["fragmentFunction"] == "riosLandscapeAdditiveFragment" and
            draw["vertexFunction"] == "riosLandscapeVertex" and
            draw["pipelineLabel"] == "RendererIOS.Static.Multiply2" and
            draw["primitiveType"] == "triangle" and draw["indexType"] == "uint32" and
            draw["sourceRGBBlendFactor"] in ("DestinationColor", "Zero") and
            type(draw["texturePixelFormat"]) is str and
            draw["texturePixelFormat"] in (
                "RGBA8Unorm", "BC1_RGBA", "BC2_RGBA", "BC3_RGBA") and
            draw["sourceIdProvenance"] == "draw-id+draw-bind-signposts" and
            draw["textureIdProvenance"] == "draw-bind-signpost+fragment-tex0",
            "target draw fixed contract fields are invalid")
    require(type(draw["commandPath"]) is str and
            DRAW_RE.fullmatch(draw["commandPath"]) is not None and
            type(draw["depthStencilRef"]) is str and
            TEXTURE_RE.fullmatch(draw["depthStencilRef"]) is not None and
            type(draw["textureRef"]) is str and
            TEXTURE_RE.fullmatch(draw["textureRef"]) is not None and
            type(draw["vertexBufferRef"]) is str and
            BUFFER_RE.fullmatch(draw["vertexBufferRef"]) is not None and
            type(draw["indexBufferRef"]) is str and
            BUFFER_RE.fullmatch(draw["indexBufferRef"]) is not None and
            type(draw["depthStencilAllocationID"]) is str and
            POSITIVE_RE.fullmatch(draw["depthStencilAllocationID"]) is not None and
            type(draw["textureAllocationID"]) is str and
            POSITIVE_RE.fullmatch(draw["textureAllocationID"]) is not None and
            type(draw["depthStencilResourceIndex"]) is str and
            RESOURCE_INDEX_RE.fullmatch(draw["depthStencilResourceIndex"]) is not None and
            type(draw["textureResourceIndex"]) is str and
            RESOURCE_INDEX_RE.fullmatch(draw["textureResourceIndex"]) is not None and
            all(type(draw[name]) is int and draw[name] >= 0 for name in (
                "indexBufferBytes", "indexBufferOffset", "indexCount", "sourceId",
                "textureFragmentIndex", "textureId", "vertexBufferBytes")) and
            all(type(draw[name]) is int and draw[name] > 0 for name in (
                "textureHeight", "textureMipCount", "textureWidth")) and
            draw["indexCount"] > 0 and draw["sourceId"] > 0 and
            draw["textureId"] > 0 and draw["textureFragmentIndex"] == 0 and
            draw["constantsSha256"] == artifact["constantsSha256"] and
            draw["indexBufferBytes"] == artifact["indexBufferBytes"] and
            draw["indexBufferOffset"] == artifact["indexByteOffset"] and
            draw["indexCount"] == artifact["indexCount"] and
            draw["sourceId"] == artifact["sourceId"] and
            draw["textureId"] == artifact["textureId"] and
            draw["vertexBufferBytes"] == artifact["vertexBufferBytes"] and
            (draw["depthStencilAllocationID"],
             draw["depthStencilResourceIndex"], draw["depthStencilRef"]) ==
            (coverage["sourceAllocationID"], coverage["sourceResourceIndex"],
             coverage["sourceTextureRef"]),
            "target draw resource/artifact joins are invalid")
    for name in ("viewport", "scissor"):
        rect = exact_keys(draw[name], ("height", "provenance", "width", "x", "y"),
                          f"target draw {name}")
        require(rect["provenance"] == "coverage-artifact+code-contract",
                f"target draw {name} claims capture provenance")
        require(all(type(rect[key]) is int and rect[key] >= 0
                    for key in ("height", "width", "x", "y")) and
                rect["x"] == 0 and rect["y"] == 0 and
                rect["width"] > 0 and rect["height"] > 0,
                f"target draw {name} rectangle is invalid")
    require(draw["viewport"] == draw["scissor"],
            "target viewport/scissor differ")
    stencil = exact_keys(draw["stencilState"], (
        "depthCompare", "depthWriteEnabled", "provenance", "stencilCompare",
        "stencilDepthFail", "stencilFail", "stencilPass", "stencilReadMask",
        "stencilReference", "stencilWriteMask"), "stencil state")
    require(stencil == {
        "depthCompare": "LessEqual", "depthWriteEnabled": False,
        "provenance": {
            "compareAndOperations": "capture-observed",
            "masksAndReference": "code-contract"},
        "stencilCompare": "Always", "stencilDepthFail": "Keep",
        "stencilFail": "Keep", "stencilPass": "Replace",
        "stencilReadMask": 255, "stencilReference": 1,
        "stencilWriteMask": 255}, "stencil state/provenance is invalid")
    signposts = exact_keys(root["signposts"], (
        "bindApiIndex", "bindText", "drawApiIndex", "drawText", "idApiIndex",
        "idText"), "signposts")
    require(all(type(signposts[name]) is int and signposts[name] >= 0 for name in (
                "bindApiIndex", "drawApiIndex", "idApiIndex")) and
            signposts["bindApiIndex"] == signposts["idApiIndex"] + 1 and
            signposts["drawApiIndex"] == signposts["bindApiIndex"] + 1 and
            signposts["drawText"] == draw["commandPath"] and
            type(signposts["idText"]) is str and
            signposts["idText"].startswith(
                "RendererIOS multiply2 causal draw-id: v=1 ") and
            type(signposts["bindText"]) is str and
            signposts["bindText"].startswith(
                "RendererIOS multiply2 causal draw-bind: "),
            "draw signpost adjacency/text is invalid")
    snapshot = exact_keys(root["snapshot"],
                          ("snapshotSequence", "targetGeneration"), "snapshot")
    require(all(type(snapshot[name]) is int and snapshot[name] > 0 for name in (
                "snapshotSequence", "targetGeneration")),
            "draw snapshot identity is invalid")
    source = exact_keys(root["source"], (
        "captureManifestSha256", "collector", "drawTranscriptManifestSha256",
        "gpudebugEvidenceSha256", "transcriptManifestSha256"), "source")
    require(source["collector"] == "public-gpudebug-multiply2-draw-v1",
            "draw evidence collector identity is invalid")
    stages = exact_keys(root["stages"], ("proofCopy", "toneResolve"), "stages")
    proof = exact_keys(stages["proofCopy"], (
        "commandPath", "sourceAllocationID", "sourceResourceIndex",
        "sourceTextureRef"), "proof-copy stage")
    tone = exact_keys(stages["toneResolve"], (
        "drawPath", "fragmentTextureIndex", "textureRef"),
        "tone-resolve stage")
    require(type(proof["commandPath"]) is str and
            COMMAND_RE.fullmatch(proof["commandPath"]) is not None and
            (proof["sourceAllocationID"], proof["sourceResourceIndex"],
             proof["sourceTextureRef"]) ==
            (attachment["allocationID"], attachment["resourceIndex"],
             attachment["textureRef"]) and
            type(tone["drawPath"]) is str and
            DRAW_RE.fullmatch(tone["drawPath"]) is not None and
            tone["fragmentTextureIndex"] == 0 and
            tone["textureRef"] == attachment["textureRef"],
            "proof/tone stage joins are invalid")
    for digest in (
            root["artifact"]["constantsSha256"], root["artifact"]["inputArtifactSha256"],
            root["artifact"]["multiply2PayloadSha256"], coverage["artifactPayloadSha256"],
            coverage["artifactSha256"], coverage["fetchedPaddedSha256"],
            coverage["strippedPayloadSha256"], draw["constantsSha256"],
            draw["indexBufferSha256"], draw["vertexBufferSha256"],
            source["captureManifestSha256"], source["drawTranscriptManifestSha256"],
            source["gpudebugEvidenceSha256"], source["transcriptManifestSha256"]):
        require(type(digest) is str and SHA_RE.fullmatch(digest) is not None,
                "draw evidence contains a malformed SHA-256")
    return root


def native_buffer(info: dict[str, Any], ref: str, label: str) -> dict[str, str]:
    require(type(info.get("allocationID")) is str and
            POSITIVE_RE.fullmatch(info["allocationID"]) is not None and
            type(info.get("resourceIndex")) is str and
            RESOURCE_INDEX_RE.fullmatch(info["resourceIndex"]) is not None,
            f"{label} buffer native identity is malformed")
    return {"allocationID": info["allocationID"],
            "resourceIndex": info["resourceIndex"], "bufferRef": ref}


def build_document(gpu_root: dict[str, Any], gpu_raw: bytes,
                   artifact: dict[str, Any], artifact_raw: bytes,
                   coverage: dict[str, Any], coverage_raw: bytes,
                   observed: dict[str, Any], entries: list[dict[str, Any]],
                   transcript_dir: pathlib.Path, label: str) -> dict[str, Any]:
    require(label in ("a", "b"), "Multiply2 label is invalid")
    require(observed["sourceRGBBlendFactor"] ==
            ("DestinationColor" if label == "a" else "Zero"),
            "captured Multiply2 sourceRGB differs from the A/B contract")
    record = artifact["record"]
    require((artifact["generation"], artifact["sequence"]) ==
            (coverage["generation"], coverage["sequence"]),
            "input/coverage snapshot identity differs")
    require((record["sourceId"], record["indexByteOffset"], record["indexCount"]) ==
            (coverage["source"], coverage["indexOffset"], coverage["indexCount"]),
            "input/coverage draw identity differs")
    identity = gpu_root["runIdentity"]
    extent = gpu_root["extent"]
    require((identity["targetGeneration"], identity["snapshotSequence"],
             identity["proofId"], identity["buildSha"],
             extent["width"], extent["height"]) ==
            (artifact["generation"], artifact["sequence"],
             bytes(coverage["proofId"]).hex(), bytes(coverage["buildSha"]).hex(),
             coverage["width"], coverage["height"]),
            "GPU/HDR/coverage/input identity differs")
    require(observed["drawPath"].startswith(
                gpu_root["command"]["scene"]["encoderPath"] + "/") and
            observed["proofCopyPath"] ==
                gpu_root["command"]["proofBlit"]["commandPath"] and
            observed["proofSource"] == gpu_root["sceneResource"] and
            observed["toneDrawPath"] ==
                gpu_root["command"]["toneResolve"]["drawPath"],
            "draw stages escaped the authenticated HDR chain")
    require(observed["color0"] == gpu_root["sceneResource"],
            "target draw color0 differs from authenticated SceneHDR")
    require(observed["depth"] == observed["stencil"] ==
            observed["coverageSource"],
            "draw depth/stencil and coverage source native triples differ")
    require(observed["constantsRaw"] == record["constants"] and
            len(observed["constantsRaw"]) == 160,
            "captured inline constants differ from input artifact")
    require(len(observed["vertexRaw"]) == record["vertexBufferBytes"] and
            len(observed["indexRaw"]) == record["indexBufferBytes"],
            "fetched vertex/index buffer bytes differ from input artifact")
    expected_texture_format = {
        1: "RGBA8Unorm", 2: "BC1_RGBA", 3: "BC2_RGBA", 4: "BC3_RGBA",
    }[record["textureFormat"]]
    require((observed["textureWidth"], observed["textureHeight"],
             observed["textureMipCount"], observed["texturePixelFormat"]) ==
            (record["textureWidth"], record["textureHeight"],
             record["textureMipCount"], expected_texture_format),
            "captured material texture layout differs from input artifact")
    expected_padded = observed["coverageRow"] * coverage["height"]
    require(len(observed["coveragePaddedRaw"]) == expected_padded and
            observed["coverageOffset"] == 0 and
            observed["coverageBytesPerImage"] == expected_padded,
            "fetched coverage destination layout is invalid")
    stripped = b"".join(
        observed["coveragePaddedRaw"][
            y * observed["coverageRow"]:y * observed["coverageRow"] +
            coverage["width"]]
        for y in range(coverage["height"]))
    payload = coverage_raw[160:]
    require(stripped == payload,
            "fetched GPU stencil bytes differ from coverage artifact payload")
    rect = {"height": coverage["height"],
            "provenance": "coverage-artifact+code-contract",
            "width": coverage["width"], "x": 0, "y": 0}
    artifact_binding = {
        "constantsSha256": sha256(record["constants"]),
        "indexByteOffset": record["indexByteOffset"],
        "indexBufferBytes": record["indexBufferBytes"],
        "indexCount": record["indexCount"],
        "inputArtifactSha256": sha256(artifact_raw),
        "materialFlags": record["materialFlags"],
        "multiply2PayloadSha256": sha256(artifact["multiply2Payload"]),
        "recordBytes": 256, "recordOffset": record["recordOffset"],
        "sourceId": record["sourceId"], "textureId": record["textureId"],
        "vertexBufferBytes": record["vertexBufferBytes"],
    }
    resource = gpu_root["sceneResource"]
    document = {
        "artifact": artifact_binding,
        "attachment": {
            "allocationID": resource["allocationID"], "colorIndex": 0,
            "pixelFormat": "RG11B10Float",
            "resourceIndex": resource["resourceIndex"],
            "textureRef": resource["textureRef"]},
        "coverage": {
            "artifactPayloadSha256": sha256(payload),
            "artifactSha256": sha256(coverage_raw),
            "blitOption": "StencilFromDepthStencil",
            "copyCommandPath": observed["coverageCopyPath"],
            "destinationAllocationID": observed["coverageDestination"]["allocationID"],
            "destinationBufferOffset": observed["coverageOffset"],
            "destinationBufferRef": observed["coverageDestination"]["bufferRef"],
            "destinationBytesPerImage": observed["coverageBytesPerImage"],
            "destinationBytesPerRow": observed["coverageRow"],
            "destinationResourceIndex": observed["coverageDestination"]["resourceIndex"],
            "fetchedPaddedBytes": len(observed["coveragePaddedRaw"]),
            "fetchedPaddedSha256": sha256(observed["coveragePaddedRaw"]),
            "gpuProduced": True,
            "sourceAllocationID": observed["coverageSource"]["allocationID"],
            "sourcePixelFormat": "Depth32Float_Stencil8",
            "sourceResourceIndex": observed["coverageSource"]["resourceIndex"],
            "sourceTextureRef": observed["coverageSource"]["textureRef"],
            "strippedPayloadEqual": True,
            "strippedPayloadSha256": sha256(stripped)},
        "draw": {
            "commandPath": observed["drawPath"], "constantsBufferIndex": 1,
            "constantsBytes": 160,
            "constantsSha256": sha256(observed["constantsRaw"]),
            "constantsStorage": "inline",
            "depthStencilAllocationID": observed["depth"]["allocationID"],
            "depthStencilBindings": ["depth", "stencil"],
            "depthStencilResourceIndex": observed["depth"]["resourceIndex"],
            "depthStencilRef": observed["depth"]["textureRef"],
            "fragmentFunction": observed["fragmentFunction"],
            "indexBufferBytes": len(observed["indexRaw"]),
            "indexBufferOffset": observed["indexBufferOffset"],
            "indexBufferRef": observed["indexBuffer"]["bufferRef"],
            "indexBufferSha256": sha256(observed["indexRaw"]),
            "indexCount": observed["indexCount"], "indexType": "uint32",
            "pipelineLabel": observed["pipelineLabel"],
            "primitiveType": "triangle", "scissor": rect,
            "sourceId": record["sourceId"],
            "sourceIdProvenance": "draw-id+draw-bind-signposts",
            "stencilState": observed["stencilState"],
            "textureAllocationID": observed["texture"]["allocationID"],
            "textureFragmentIndex": 0, "textureId": record["textureId"],
            "textureIdProvenance": "draw-bind-signpost+fragment-tex0",
            "textureRef": observed["texture"]["textureRef"],
            "textureResourceIndex": observed["texture"]["resourceIndex"],
            "vertexBufferBytes": len(observed["vertexRaw"]),
            "vertexBufferRef": observed["vertexBuffer"]["bufferRef"],
            "vertexBufferSha256": sha256(observed["vertexRaw"]),
            "vertexFunction": observed["vertexFunction"], "viewport": rect,
            "sourceRGBBlendFactor": observed["sourceRGBBlendFactor"],
            "textureHeight": observed["textureHeight"],
            "textureMipCount": observed["textureMipCount"],
            "texturePixelFormat": observed["texturePixelFormat"],
            "textureWidth": observed["textureWidth"]},
        "schemaVersion": 1,
        "signposts": {
            "bindApiIndex": observed["bindApiIndex"],
            "bindText": observed["bindText"],
            "drawApiIndex": observed["drawApiIndex"],
            "drawText": observed["drawPath"],
            "idApiIndex": observed["idApiIndex"],
            "idText": observed["idText"]},
        "snapshot": {"snapshotSequence": artifact["sequence"],
                     "targetGeneration": artifact["generation"]},
        "source": {
            "captureManifestSha256": gpu_root["source"]["captureManifestSha256"],
            "collector": "public-gpudebug-multiply2-draw-v1",
            "drawTranscriptManifestSha256":
                observed["drawTranscriptManifestSha256"],
            "gpudebugEvidenceSha256": sha256(gpu_raw),
            "transcriptManifestSha256":
                gpu_root["source"]["transcriptManifestSha256"]},
        "stages": {
            "proofCopy": {
                "commandPath": observed["proofCopyPath"],
                "sourceAllocationID": resource["allocationID"],
                "sourceResourceIndex": resource["resourceIndex"],
                "sourceTextureRef": resource["textureRef"]},
            "toneResolve": {
                "drawPath": observed["toneDrawPath"],
                "fragmentTextureIndex": 0,
                "textureRef": resource["textureRef"]}},
    }
    validate_document(document)
    return document


def document_field(document: Any, key: str, gpu: Any, label: str) -> str:
    value = gpu._document_one_field(document, key, label)
    require(type(value) is str, f"{label}.{key} is not a string")
    return value


def function_binding(document: Any, name: str, expected: str,
                     gpu: Any, label: str) -> str:
    children = gpu._listing_children(document, label)
    matches = [child for child in children if child["name"] == name]
    require(len(matches) == 1, f"{label} lacks one {name} function")
    values = gpu._child_strings(matches[0])
    require(values and values[0] == f'"{expected}"',
            f"{label} {name} function differs")
    return expected


def texture_identity(info: dict[str, Any], ref: str, label: str,
                     *, pixel_format: str, width: int, height: int,
                     storage: str | None = None) -> dict[str, str]:
    identity = native_texture(info, ref, label)
    require(info["pixelFormat"] == pixel_format and
            info["dimensions"] == f"{width}x{height}" and
            type(info.get("textureType")) is str and
            info["textureType"] == "2D",
            f"{label} texture format/extent/type differs")
    if storage is not None:
        require(info.get("storageMode") == storage,
                f"{label} texture storage mode differs")
    return identity


def scene_resource_from_info(info: dict[str, Any], ref: str,
                             gpu_root: dict[str, Any]) -> dict[str, Any]:
    resource = gpu_root["sceneResource"]
    expected = {
        "allocationID": info.get("allocationID"),
        "resourceIndex": info.get("resourceIndex"),
        "label": info.get("label"),
        "pixelFormat": info.get("pixelFormat"),
        "textureType": info.get("textureType"),
        "storageMode": info.get("storageMode"),
        "mipLevel": 0, "arraySlice": 0, "textureRef": ref,
    }
    require(resource == expected,
            "target draw color0 differs from canonical SceneHDR identity")
    return resource


def parse_fetch(raw: bytes, expected_listing: Any | None, destination: pathlib.Path,
                expected_size: int, gpu: Any, label: str) -> None:
    documents, _ = gpu._json_documents(raw, label, 2)
    if expected_listing is None:
        gpu._listing_children(documents[0], f"{label} resource scope")
    else:
        require(documents[0] == expected_listing,
                f"{label} navigated binding changed before fetch")
    result = documents[1]
    require(type(result) is dict and
            set(result) == {"filename", "files", "path", "size"} and
            type(result["filename"]) is str and
            type(result["files"]) is list and len(result["files"]) == 1 and
            result["path"] == str(destination) and
            result["size"] == expected_size and type(result["size"]) is int,
            f"{label} fetch result is malformed")
    item = result["files"][0]
    require(type(item) is dict and set(item) == {"filename", "path", "size"} and
            item["path"] == str(destination) and item["size"] == expected_size,
            f"{label} fetched-file result is malformed")


def add_entry(entries: list[dict[str, Any]], directory: pathlib.Path,
              role: str, filename: str, kind: str, argv: list[str],
              raw: bytes, gpu: Any, *, already_written: bool = False) -> None:
    require(SAFE_LEAF_RE.fullmatch(role) is not None and
            SAFE_LEAF_RE.fullmatch(filename) is not None and
            kind in ("resource", "transcript") and raw,
            "draw transcript entry request is invalid")
    require(not any(entry["role"] == role or entry["file"] == filename
                    for entry in entries),
            "draw transcript role or filename repeats")
    destination = directory / filename
    if already_written:
        require(regular_bytes(destination, f"draw {role}",
                              MAX_FETCH_BYTES if kind == "resource"
                              else MAX_TRANSCRIPT_BYTES) == raw,
                f"draw {role} changed before manifesting")
    else:
        gpu.atomic_no_clobber(destination, raw)
    entries.append({
        "argv": argv, "bytes": len(raw), "file": filename, "kind": kind,
        "role": role, "sha256": sha256(raw),
    })


def collect(capture: pathlib.Path, gpu_path: pathlib.Path,
            input_path: pathlib.Path, coverage_path: pathlib.Path,
            transcript_dir: pathlib.Path, output: pathlib.Path,
            label: str) -> dict[str, Any]:
    gpu = load_public_gpu_module()
    coverage_module = load_coverage_module()
    require(label in ("a", "b"), "Multiply2 label is invalid")
    input_match = INPUT_LEAF_RE.fullmatch(input_path.name)
    require(input_match is not None and input_match.group(1) == label,
            "Multiply2 input artifact leaf/label is invalid")
    artifact_raw = regular_bytes(input_path, "Multiply2 input artifact",
                                 32 * 1024 * 1024)
    artifact = parse_input_artifact(artifact_raw)
    require((int(input_match.group(2)), int(input_match.group(3))) ==
            (artifact["generation"], artifact["sequence"]),
            "Multiply2 input leaf identity differs from its header")
    expected_output = (
        f"RendererIOS-multiply2-draw-evidence-v1-{label}-"
        f"g{artifact['generation']}-s{artifact['sequence']}.json")
    output_match = OUTPUT_LEAF_RE.fullmatch(output.name)
    require(output.name == expected_output and output_match is not None,
            "draw evidence output leaf is not canonical")
    require(coverage_path.name == "RendererIOS-multiply2-coverage-v1.bin",
            "coverage artifact leaf is not canonical")
    coverage_raw = regular_bytes(
        coverage_path, "Multiply2 coverage artifact",
        160 + 4096 * 4096)
    coverage = coverage_module.parse_coverage(coverage_raw)

    gpu_raw = regular_bytes(gpu_path, "canonical gpudebug evidence",
                            MAX_DOCUMENT_BYTES)
    require(stat.S_IMODE(gpu_path.lstat().st_mode) == 0o600,
            "canonical gpudebug evidence mode is not 0600")
    try:
        gpu_root = json.loads(
            gpu_raw.decode("utf-8"), object_pairs_hook=gpu.unique_object,
            parse_constant=gpu.reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"canonical gpudebug evidence is invalid: {error}") from error
    require(gpu_raw == gpu.canonical_json_bytes(gpu_root),
            "canonical gpudebug evidence is not canonical JSON")
    gpu.validate_document(gpu_root)
    capture_kind, capture_bytes, capture_sha = gpu.stable_capture_manifest(capture)
    require((capture_kind, capture_bytes, capture_sha) ==
            (gpu_root["source"]["captureKind"],
             gpu_root["source"]["captureBytes"],
             gpu_root["source"]["captureManifestSha256"]),
            "capture tree differs from canonical gpudebug evidence")

    directory_status = transcript_dir.lstat()
    require(stat.S_ISDIR(directory_status.st_mode) and
            not transcript_dir.is_symlink() and
            stat.S_IMODE(directory_status.st_mode) == 0o700 and
            not any(transcript_dir.iterdir()),
            "draw transcript directory is not empty private 0700")
    binary = pathlib.Path(GPUDEBUG)
    binary_status = binary.lstat()
    require(stat.S_ISREG(binary_status.st_mode) and
            not binary.is_symlink() and os.access(binary, os.X_OK),
            "owned /usr/bin/gpudebug is not a regular executable")

    started = time.monotonic()
    main_deadline = started + 600.0
    overall_deadline = started + 720.0
    entries: list[dict[str, Any]] = []
    session: str | None = None
    cleanup_error: Exception | None = None

    def invoke(role: str, filename: str, commands: list[str],
               *, direct_argv: list[str] | None = None) -> bytes:
        require(session is not None or direct_argv is not None,
                "gpudebug session is unavailable")
        argv = direct_argv if direct_argv is not None else [
            GPUDEBUG, "--json", "-s", str(session),
            *[part for command in commands for part in ("-c", command)],
        ]
        raw = gpu.run_collector_command(argv, main_deadline)
        add_entry(entries, transcript_dir, role, filename, "transcript",
                  argv, raw, gpu)
        return raw

    def direct_info(role: str, filename: str, path: str) -> dict[str, Any]:
        raw = invoke(role, filename, [f"info {path}"])
        document = gpu._direct_info_json(raw, role)
        require(type(document) is dict, f"{role} info is not an object")
        return document

    def navigate(role: str, filename: str, path: str) -> dict[str, Any]:
        raw = invoke(role, filename, [f"go {path}", "list --all"])
        document = gpu._navigable_json(raw, role)
        gpu._listing_children(document, role)
        return document

    def find_marker(role: str, filename: str,
                    marker: str) -> tuple[str, int]:
        raw = invoke(role, filename, [f"find {marker}"])
        return find_api(raw, marker, gpu, role)

    def fetch_binding(role: str, filename: str, resource_filename: str,
                      context_path: str, binding: str,
                      listing: dict[str, Any] | None,
                      expected_size: int) -> bytes:
        require(0 < expected_size <= MAX_FETCH_BYTES,
                f"{role} requested an unbounded resource")
        staging = transcript_dir / f".{resource_filename}.fetch"
        destination = transcript_dir / resource_filename
        require(not staging.exists() and not destination.exists(),
                f"{role} fetch destination already exists")
        argv = [GPUDEBUG, "--json", "-s", str(session),
                "-c", f"go {context_path}",
                "-c", f"fetch {binding} --out {staging}"]
        raw = gpu.run_collector_command(argv, main_deadline)
        try:
            parse_fetch(raw, listing, staging, expected_size, gpu, role)
            status = staging.lstat()
            require(stat.S_ISREG(status.st_mode) and not staging.is_symlink() and
                    status.st_size == expected_size,
                    f"{role} fetch did not create one bounded regular file")
            os.chmod(staging, 0o600)
            descriptor = os.open(staging, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            resource_raw = regular_bytes(staging, role, MAX_FETCH_BYTES)
            gpu.rename_no_clobber(staging, destination, role)
            gpu.fsync_directory(transcript_dir)
        except Exception:
            try:
                staging.unlink()
            except OSError:
                pass
            raise
        add_entry(entries, transcript_dir, role, resource_filename, "resource",
                  argv, resource_raw, gpu, already_written=True)
        add_entry(entries, transcript_dir, role + "-fetch", filename,
                  "transcript", argv, raw, gpu)
        return resource_raw

    observed: dict[str, Any] = {}
    try:
        version_argv = [GPUDEBUG, "--version"]
        version = invoke("version", "gpudebug-version.txt", [],
                         direct_argv=version_argv)
        require(version == gpu.GPUDEBUG_VERSION,
                "gpudebug version is not exact 1.0")
        open_argv = [GPUDEBUG, "--json", "-t", str(capture),
                     "--timeout", "120", "-c", "list"]
        opened = gpu.run_collector_command(open_argv, main_deadline)
        session = gpu.parse_session(opened)
        add_entry(entries, transcript_dir, "open", "gpudebug-open.json",
                  "transcript", open_argv, opened, gpu)

        record = artifact["record"]
        id_text = (
            "RendererIOS multiply2 causal draw-id: v=1 "
            f"mode={label} generation={artifact['generation']} "
            f"sequence={artifact['sequence']} source={record['sourceId']}")
        bind_text = (
            "RendererIOS multiply2 causal draw-bind: "
            f"src={record['sourceId']} sel=multiply2 kind=static "
            f"tex={record['textureId']} mesh={record['meshId']} "
            f"mat={record['materialId']} off={record['indexByteOffset']} "
            f"count={record['indexCount']} pso=multiply2 depth=ro "
            "target=SceneHDR")
        id_path, id_api = find_marker(
            "draw-id-find", "draw-id-find.json", id_text)
        bind_path, bind_api = find_marker(
            "draw-bind-find", "draw-bind-find.json", bind_text)
        require(bind_api == id_api + 1 and bind_path == f"api_calls/api{bind_api}",
                "draw id/bind signposts are not immediately adjacent")
        draw_api = bind_api + 1
        draw_api_path = f"api_calls/api{draw_api}"
        draw_link_raw = invoke(
            "draw-api-link", "draw-api-link.json",
            [f"go {draw_api_path}", "list --all"])
        draw_path = linked_command(
            draw_link_raw, draw_api_path, gpu, "draw API link", DRAW_RE)
        require(draw_path.startswith(
                    gpu_root["command"]["scene"]["encoderPath"] + "/"),
                "target draw is not in authenticated SceneHDR encoder")
        draw_info = direct_info(
            "draw-info", "draw-info.json", draw_path)
        draw_listing = navigate(
            "draw-list", "draw-list.json", draw_path)
        vertex_path = draw_path + "/vertex"
        fragment_path = draw_path + "/fragment"
        vertex_listing = navigate(
            "draw-vertex", "draw-vertex.json", vertex_path)
        fragment_listing = navigate(
            "draw-fragment", "draw-fragment.json", fragment_path)

        pipeline_ref = listed_binding(
            draw_listing, "pipeline", PIPELINE_RE, gpu, "target draw")
        depth_ref = listed_binding(
            draw_listing, "depth", TEXTURE_RE, gpu, "target draw")
        stencil_ref = listed_binding(
            draw_listing, "stencil", TEXTURE_RE, gpu, "target draw")
        color_ref = listed_binding(
            draw_listing, "color0", TEXTURE_RE, gpu, "target draw")
        index_ref = listed_binding(
            draw_listing, "indexBuffer", BUFFER_RE, gpu, "target draw")
        vertex_ref = listed_binding(
            vertex_listing, "buf[0]", BUFFER_RE, gpu, "target vertex")
        texture_ref = listed_binding(
            fragment_listing, "tex[0]", TEXTURE_RE, gpu, "target fragment")
        function_binding(draw_listing, "vertex", "riosLandscapeVertex",
                         gpu, "target draw")
        function_binding(draw_listing, "fragment",
                         "riosLandscapeAdditiveFragment", gpu, "target draw")
        constants_children = [child for child in
                              gpu._listing_children(vertex_listing,
                                                    "target vertex")
                              if child["name"] == "buf[1]"]
        require(len(constants_children) == 1 and
                "160 bytes (inline)" in
                    gpu._child_strings(constants_children[0]),
                "target constants are not 160 inline bytes at vertex index 1")

        pipeline = direct_info(
            "draw-pipeline", "draw-pipeline.json", pipeline_ref)
        dss_ref = parse_ref(document_field(
            draw_info, "Depth stencil state", gpu, "target draw"),
            DSS_RE, "target draw depth-stencil state")
        dss = direct_info("draw-dss", "draw-dss.json", dss_ref)
        depth_info = direct_info(
            "draw-depth", "draw-depth.json", draw_path + "/depth")
        stencil_info = direct_info(
            "draw-stencil", "draw-stencil.json", draw_path + "/stencil")
        color_info = direct_info(
            "draw-color0", "draw-color0.json", draw_path + "/color0")
        vertex_info = direct_info(
            "vertex-buffer-info", "vertex-buffer-info.json", vertex_ref)
        index_info = direct_info(
            "index-buffer-info", "index-buffer-info.json", index_ref)
        texture_info = direct_info(
            "material-texture-info", "material-texture-info.json", texture_ref)

        require(document_field(draw_info, "primitiveType", gpu,
                               "target draw") == "Triangle" and
                document_field(draw_info, "indexType", gpu,
                               "target draw") == "UInt32",
                "target draw primitive/index type differs")
        index_count = uint_field(document_field(
            draw_info, "indexCount", gpu, "target draw"), "draw indexCount")
        index_offset = uint_field(document_field(
            draw_info, "indexBufferOffset", gpu, "target draw"),
            "draw indexBufferOffset")
        require((index_count, index_offset) ==
                (record["indexCount"], record["indexByteOffset"]) and
                parse_ref(document_field(draw_info, "indexBuffer", gpu,
                                         "target draw"), BUFFER_RE,
                          "draw index buffer") == index_ref,
                "target draw index range differs from input artifact")
        require(document_field(pipeline, "label", gpu, "target pipeline") ==
                    "RendererIOS.Static.Multiply2" and
                document_field(pipeline, "depth", gpu, "target pipeline") ==
                    "Depth32Float_Stencil8" and
                document_field(pipeline, "stencil", gpu, "target pipeline") ==
                    "Depth32Float_Stencil8" and
                document_field(pipeline, "sampleCount", gpu,
                               "target pipeline") == "1" and
                document_field(pipeline, "vertex", gpu,
                               "target pipeline").startswith(
                    "riosLandscapeVertex (") and
                document_field(pipeline, "fragment", gpu,
                               "target pipeline").startswith(
                    "riosLandscapeAdditiveFragment ("),
                "target Multiply2 pipeline identity differs")
        color_attachments = document_field(
            pipeline, "colorAttachments", gpu, "target pipeline")
        require("format:       RG11B10Float" in color_attachments and
                "blendEnabled: yes" in color_attachments and
                "dstRGB:       SourceColor" in color_attachments and
                "opRGB:        Add" in color_attachments,
                "target Multiply2 blend contract differs")
        source_rgb_matches = re.findall(
            r"^    srcRGB:       (DestinationColor|Zero)$",
            color_attachments, re.MULTILINE)
        require(len(source_rgb_matches) == 1,
                "target Multiply2 sourceRGB is ambiguous")
        source_rgb = source_rgb_matches[0]
        require(source_rgb == ("DestinationColor" if label == "a" else "Zero"),
                "target Multiply2 A/B sourceRGB differs")
        stencil_operations = "Always, fail=Keep, zFail=Keep, pass=Replace"
        require(document_field(dss, "depthCompareFunction", gpu,
                               "target dss") == "LessEqual" and
                document_field(dss, "depthWriteEnabled", gpu,
                               "target dss") == "no" and
                document_field(dss, "frontFaceStencil", gpu,
                               "target dss") == stencil_operations and
                document_field(dss, "backFaceStencil", gpu,
                               "target dss") == stencil_operations,
                "target depth/stencil compare or operations differ")

        width = coverage["width"]
        height = coverage["height"]
        depth_identity = texture_identity(
            depth_info, depth_ref, "draw depth", pixel_format=
            "Depth32Float_Stencil8", width=width, height=height,
            storage="Private")
        stencil_identity = texture_identity(
            stencil_info, stencil_ref, "draw stencil", pixel_format=
            "Depth32Float_Stencil8", width=width, height=height,
            storage="Private")
        require(depth_info.get("label") ==
                    "RendererIOS.Multiply2.CausalStencil.v1" and
                stencil_info.get("label") ==
                    "RendererIOS.Multiply2.CausalStencil.v1",
                "draw depth/stencil label differs from causal DS contract")
        scene_resource_from_info(color_info, color_ref, gpu_root)
        vertex_identity = native_buffer(vertex_info, vertex_ref,
                                        "target vertex buffer")
        index_identity = native_buffer(index_info, index_ref,
                                       "target index buffer")
        material_dimensions = document_field(
            texture_info, "dimensions", gpu, "target material texture")
        material_dimension_match = re.fullmatch(
            r"([1-9][0-9]*)x([1-9][0-9]*)", material_dimensions)
        require(material_dimension_match is not None,
                "target material texture dimensions are invalid")
        material_width = int(material_dimension_match.group(1))
        material_height = int(material_dimension_match.group(2))
        material_format = document_field(
            texture_info, "pixelFormat", gpu, "target material texture")
        material_mips = uint_field(document_field(
            texture_info, "mipmapLevelCount", gpu, "target material texture"),
            "target material texture mip count", (1 << 32) - 1)
        texture_identity_value = texture_identity(
            texture_info, texture_ref, "target material texture",
            pixel_format=material_format, width=material_width,
            height=material_height)
        constants_raw = fetch_binding(
            "constants", "constants-fetch.json", "constants.bin",
            vertex_path, "buf[1]", vertex_listing, 160)
        vertex_raw = fetch_binding(
            "vertex-buffer", "vertex-buffer-fetch.json", "vertex-buffer.bin",
            vertex_path, "buf[0]", vertex_listing,
            record["vertexBufferBytes"])
        index_raw = fetch_binding(
            "index-buffer", "index-buffer-fetch.json", "index-buffer.bin",
            draw_path, "indexBuffer", draw_listing,
            record["indexBufferBytes"])

        coverage_marker = "RendererIOS.Multiply2.CoverageStencilCopy.v1"
        coverage_signpost_path, coverage_api = find_marker(
            "coverage-find", "coverage-find.json", coverage_marker)
        require(coverage_signpost_path == f"api_calls/api{coverage_api}",
                "coverage signpost API path differs")
        coverage_copy_api = f"api_calls/api{coverage_api + 1}"
        coverage_link_raw = invoke(
            "coverage-api-link", "coverage-api-link.json",
            [f"go {coverage_copy_api}", "list --all"])
        coverage_copy_path = linked_command(
            coverage_link_raw, coverage_copy_api, gpu,
            "coverage copy API link", COMMAND_RE)
        require("/be" in coverage_copy_path and "/blit" in coverage_copy_path,
                "coverage API does not link to one blit command")
        coverage_copy = direct_info(
            "coverage-copy", "coverage-copy.json", coverage_copy_path)
        coverage_source_ref = parse_ref(document_field(
            coverage_copy, "sourceTexture", gpu, "coverage copy"),
            TEXTURE_RE, "coverage source texture")
        coverage_destination_ref = parse_ref(document_field(
            coverage_copy, "destinationBuffer", gpu, "coverage copy"),
            BUFFER_RE, "coverage destination buffer")
        coverage_source_info = direct_info(
            "coverage-source", "coverage-source.json", coverage_source_ref)
        coverage_destination_info = direct_info(
            "coverage-destination", "coverage-destination.json",
            coverage_destination_ref)
        coverage_source_identity = texture_identity(
            coverage_source_info, coverage_source_ref, "coverage source",
            pixel_format="Depth32Float_Stencil8", width=width, height=height,
            storage="Private")
        require(coverage_source_info.get("label") ==
                    "RendererIOS.Multiply2.CausalStencil.v1",
                "coverage source label differs from causal DS contract")
        coverage_destination_identity = native_buffer(
            coverage_destination_info, coverage_destination_ref,
            "coverage destination")
        require(coverage_destination_info.get("storageMode") == "Shared" and
                coverage_destination_info.get("label") ==
                    "RendererIOS.Multiply2.CoverageReadback.v1",
                "coverage destination buffer storage/label differs")
        require(document_field(coverage_copy, "options", gpu,
                               "coverage copy") ==
                    "StencilFromDepthStencil" and
                document_field(coverage_copy, "sourceLevel", gpu,
                               "coverage copy") == "0" and
                document_field(coverage_copy, "sourceSlice", gpu,
                               "coverage copy") == "0" and
                document_field(coverage_copy, "sourceOrigin", gpu,
                               "coverage copy") == "0, 0, 0" and
                document_field(coverage_copy, "sourceSize", gpu,
                               "coverage copy") == f"{width}x{height}x1",
                "coverage stencil blit option/source region differs")
        coverage_offset = uint_field(document_field(
            coverage_copy, "destinationOffset", gpu, "coverage copy"),
            "coverage destinationOffset")
        coverage_row = uint_field(document_field(
            coverage_copy, "destinationBytesPerRow", gpu, "coverage copy"),
            "coverage destinationBytesPerRow", (1 << 32) - 1)
        coverage_image = uint_field(document_field(
            coverage_copy, "destinationBytesPerImage", gpu, "coverage copy"),
            "coverage destinationBytesPerImage")
        require(coverage_row >= width and coverage_row % 256 == 0 and
                coverage_image == coverage_row * height,
                "coverage padded destination layout differs")
        coverage_padded_raw = fetch_binding(
            "coverage-buffer", "coverage-buffer-fetch.json",
            "coverage-buffer-padded.bin", "resources/buffers",
            coverage_destination_ref[1:], None, coverage_image)

        scene_encoder_index = int(
            gpu_root["command"]["scene"]["encoderPath"].rsplit("/re", 1)[1])
        proof_encoder_index = int(
            gpu_root["command"]["proofBlit"]["encoderPath"].rsplit("/be", 1)[1])
        tone_encoder_index = int(
            gpu_root["command"]["toneResolve"]["encoderPath"].rsplit("/re", 1)[1])
        coverage_encoder_path = coverage_copy_path.split("/grp", 1)[0]
        require(coverage_encoder_path.startswith(
                    "commands/" + gpu_root["command"]["commandBuffer"] + "/be"),
                "coverage copy escaped authenticated command buffer")
        coverage_encoder_index = int(coverage_encoder_path.rsplit("/be", 1)[1])
        require(scene_encoder_index < proof_encoder_index <
                coverage_encoder_index < tone_encoder_index,
                "scene/proof/coverage/tone encoder ordering differs")

        observed = {
            "bindApiIndex": bind_api, "bindText": bind_text,
            "color0": gpu_root["sceneResource"],
            "constantsRaw": constants_raw,
            "coverageBytesPerImage": coverage_image,
            "coverageCopyPath": coverage_copy_path,
            "coverageDestination": coverage_destination_identity,
            "coverageOffset": coverage_offset,
            "coveragePaddedRaw": coverage_padded_raw,
            "coverageRow": coverage_row,
            "coverageSource": coverage_source_identity,
            "depth": depth_identity, "drawApiIndex": draw_api,
            "drawPath": draw_path, "fragmentFunction":
                "riosLandscapeAdditiveFragment",
            "idApiIndex": id_api, "idText": id_text,
            "indexBuffer": index_identity, "indexBufferOffset": index_offset,
            "indexCount": index_count, "indexRaw": index_raw,
            "pipelineLabel": "RendererIOS.Static.Multiply2",
            "proofCopyPath": gpu_root["command"]["proofBlit"]["commandPath"],
            "proofSource": gpu_root["sceneResource"],
            "sourceRGBBlendFactor": source_rgb,
            "stencil": stencil_identity,
            "stencilState": {
                "depthCompare": "LessEqual", "depthWriteEnabled": False,
                "provenance": {
                    "compareAndOperations": "capture-observed",
                    "masksAndReference": "code-contract"},
                "stencilCompare": "Always", "stencilDepthFail": "Keep",
                "stencilFail": "Keep", "stencilPass": "Replace",
                "stencilReadMask": 255, "stencilReference": 1,
                "stencilWriteMask": 255},
            "texture": texture_identity_value,
            "textureHeight": material_height,
            "textureMipCount": material_mips,
            "texturePixelFormat": material_format,
            "textureWidth": material_width,
            "toneDrawPath": gpu_root["command"]["toneResolve"]["drawPath"],
            "vertexBuffer": vertex_identity, "vertexFunction":
                "riosLandscapeVertex", "vertexRaw": vertex_raw,
        }
    finally:
        if session is not None:
            try:
                terminate_argv = [GPUDEBUG, "--terminate", session]
                terminate_raw = gpu.run_collector_command(
                    terminate_argv, overall_deadline)
                gpu.validate_terminate(terminate_raw, session)
                add_entry(entries, transcript_dir, "terminate",
                          "gpudebug-terminate.txt", "transcript",
                          terminate_argv, terminate_raw, gpu)
                sessions_argv = [GPUDEBUG, "--list-sessions"]
                sessions_raw = gpu.wait_for_owned_session_absence(
                    session, sessions_argv, overall_deadline)
                add_entry(entries, transcript_dir, "sessions-after",
                          "gpudebug-sessions-after.txt", "transcript",
                          sessions_argv, sessions_raw, gpu)
            except Exception as error:
                cleanup_error = error
        if cleanup_error is not None:
            raise EvidenceError(
                "BLOCKED: owned gpudebug session cleanup was not proven: "
                f"{cleanup_error}") from cleanup_error

    manifest_raw = transcript_manifest_bytes(entries, transcript_dir)
    gpu.atomic_no_clobber(transcript_dir / TRANSCRIPT_MANIFEST_LEAF,
                          manifest_raw)
    observed["drawTranscriptManifestSha256"] = sha256(manifest_raw)
    document = build_document(
        gpu_root, gpu_raw, artifact, artifact_raw, coverage, coverage_raw,
        observed, entries, transcript_dir, label)
    validate_transcript_directory(document, transcript_dir)
    gpu.atomic_no_clobber(output, canonical_json(document))
    return document


def load_draw_document(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    raw = regular_bytes(path, "draw evidence", MAX_DOCUMENT_BYTES)
    require(stat.S_IMODE(path.lstat().st_mode) == 0o600,
            "draw evidence mode is not 0600")
    try:
        document = json.loads(raw.decode("utf-8"),
                              object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"draw evidence is invalid JSON: {error}") from error
    require(raw == canonical_json(document),
            "draw evidence is not canonical JSON")
    return validate_document(document), raw


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--collect", action="store_true")
    mode.add_argument("--validate", action="store_true")
    parser.add_argument("--capture", type=pathlib.Path)
    parser.add_argument("--gpu-evidence", type=pathlib.Path)
    parser.add_argument("--input-artifact", type=pathlib.Path)
    parser.add_argument("--coverage", type=pathlib.Path)
    parser.add_argument("--transcript-dir", type=pathlib.Path)
    parser.add_argument("--evidence", type=pathlib.Path)
    parser.add_argument("--label", choices=("a", "b"))
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        require(arguments.evidence is not None,
                "draw evidence path is required")
        if arguments.collect:
            require(all(value is not None for value in (
                arguments.capture, arguments.gpu_evidence,
                arguments.input_artifact, arguments.coverage,
                arguments.transcript_dir, arguments.label)),
                "draw collector arguments are incomplete")
            collect(arguments.capture, arguments.gpu_evidence,
                    arguments.input_artifact, arguments.coverage,
                    arguments.transcript_dir, arguments.evidence,
                    arguments.label)
        else:
            require(arguments.capture is None and
                    arguments.gpu_evidence is None and
                    arguments.input_artifact is None and
                    arguments.coverage is None and arguments.label is None,
                    "collection-only arguments were supplied to validation")
            document, _ = load_draw_document(arguments.evidence)
            if arguments.transcript_dir is not None:
                validate_transcript_directory(document,
                                              arguments.transcript_dir)
    except (EvidenceError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("MULTIPLY2 DRAW EVIDENCE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
