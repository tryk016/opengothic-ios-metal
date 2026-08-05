#!/usr/bin/env python3
"""Fail-closed source contract for Tempest Metal 2D texture readback."""

from __future__ import annotations

import os
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
TEMPEST_ROOT = Path(os.environ.get("TEMPEST_ROOT", ROOT / "lib/Tempest"))
SOURCE = TEMPEST_ROOT / "Engine/gapi/metal/mtcommandbuffer.cpp"


def strip_cpp_comments(source: str) -> str:
    out: list[str] = []
    index = 0
    state = "code"
    while index < len(source):
        char = source[index]
        pair = source[index : index + 2]
        if state == "code":
            if pair == "//":
                state = "line-comment"
                index += 2
                continue
            if pair == "/*":
                state = "block-comment"
                index += 2
                continue
            if char == '"':
                state = "string"
            elif char == "'":
                state = "character"
            out.append(char)
        elif state == "line-comment":
            if char == "\n":
                state = "code"
                out.append(char)
        elif state == "block-comment":
            if pair == "*/":
                state = "code"
                index += 2
                continue
            if char == "\n":
                out.append(char)
        else:
            out.append(char)
            if char == "\\" and index + 1 < len(source):
                index += 1
                out.append(source[index])
            elif (state == "string" and char == '"') or (
                state == "character" and char == "'"
            ):
                state = "code"
        index += 1
    if state == "block-comment":
        raise ValueError("unterminated block comment")
    return "".join(out)


def copy_scope(source: str) -> str:
    clean = strip_cpp_comments(source)
    signature = re.compile(
        r"void\s+MtCommandBuffer::copy\s*\(\s*"
        r"AbstractGraphicsApi::Buffer\s*&\s*dest\s*,\s*size_t\s+offset\s*,\s*"
        r"AbstractGraphicsApi::Texture\s*&\s*src\s*,\s*uint32_t\s+width\s*,\s*"
        r"uint32_t\s+height\s*,\s*uint32_t\s+mip\s*\)"
    )
    matches = list(signature.finditer(clean))
    if len(matches) != 1:
        raise ValueError("expected exactly one Metal texture-to-buffer copy overload")
    opening = clean.find("{", matches[0].end())
    if opening < 0:
        raise ValueError("copy overload body is missing")
    depth = 0
    for index in range(opening, len(clean)):
        if clean[index] == "{":
            depth += 1
        elif clean[index] == "}":
            depth -= 1
            if depth == 0:
                return clean[opening : index + 1]
    raise ValueError("copy overload body is unterminated")


def validate(source: str) -> None:
    scope = re.sub(r"\s+", "", copy_scope(source))
    call = (
        "encBlit->copyFromTexture(s.impl.get(),0,mip,"
        "MTL::Origin(0,0,0),MTL::Size(width,height,1),"
        "d.impl.get(),offset,bpp*width,0);"
    )
    if scope.count("encBlit->copyFromTexture(") != 1:
        raise ValueError("copy overload must encode exactly one texture-to-buffer blit")
    if call not in scope:
        raise ValueError("2D Metal blit must use tight rows and bytesPerImage=0")
    if "bpp*width*height" in scope:
        raise ValueError("2D Metal blit retains the obsolete nonzero bytesPerImage")


def expect_rejected(source: str, label: str) -> None:
    try:
        validate(source)
    except ValueError:
        return
    raise AssertionError(f"mutation survived: {label}")


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    validate(source)

    old_tail = "offset, bpp*width,0);"
    if source.count(old_tail) != 1:
        raise AssertionError("exact 2D copy tail is not unique")
    nonzero = source.replace(old_tail, "offset, bpp*width,bpp*width*height);", 1)
    expect_rejected(nonzero, "nonzero bytesPerImage")
    expect_rejected(
        nonzero
        + "\n// encBlit->copyFromTexture(s.impl.get(),0,mip,"
        + "MTL::Origin(0,0,0),MTL::Size(width,height,1),"
        + "d.impl.get(),offset,bpp*width,0);\n",
        "comment-only false repair",
    )
    expect_rejected(source.replace("MTL::Size(width,height,1)",
                                   "MTL::Size(width,height,0)", 1),
                    "non-2D source depth")
    print("Tempest Metal 2D copy contract: PASS mutations-killed=3")


if __name__ == "__main__":
    main()
