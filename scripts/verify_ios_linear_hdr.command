#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CORE_SOURCES=(
  game/graphics/iosframeplan.cpp
  game/graphics/ioslinearhdr.cpp
  ios/tests/ioslinearhdr.cpp
)
PROOF_SOURCES=(
  game/graphics/ioslinearhdrproof.cpp
  ios/tests/ioslinearhdrproof.cpp
)
PRODUCER_SOURCES=(
  game/graphics/ioslinearhdrproof.cpp
  game/graphics/ioslinearhdrproofproducer.cpp
  ios/tests/ioslinearhdrproofproducer.cpp
)
GPU_TRIPLE_DEFINE=(
  -DOPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE
)

cd "$REPO"

PYTHONDONTWRITEBYTECODE=1 python3 \
  ios/tests/test_linear_hdr_capture_cleanup.py

printf '\n### P2.1e0 linear-HDR value/lifetime contracts\n'
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -Igame "${CORE_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdr"
"$RUNNER_TEMP/ioslinearhdr"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address -fno-omit-frame-pointer \
  -Igame "${CORE_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdr-asan"
ASAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/ioslinearhdr-asan"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -fsanitize=undefined -fno-sanitize-recover=undefined \
  -fno-omit-frame-pointer \
  -Igame "${CORE_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdr-ubsan"
UBSAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/ioslinearhdr-ubsan"

printf '\n### P2.1e0 RG11B10 decoder and binary schema v1\n'
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -Igame "${PROOF_SOURCES[@]}" -o "$RUNNER_TEMP/ioslinearhdrproof"
"$RUNNER_TEMP/ioslinearhdrproof"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address -fno-omit-frame-pointer \
  -Igame "${PROOF_SOURCES[@]}" -o "$RUNNER_TEMP/ioslinearhdrproof-asan"
ASAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/ioslinearhdrproof-asan"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -fsanitize=undefined -fno-sanitize-recover=undefined \
  -fno-omit-frame-pointer \
  -Igame "${PROOF_SOURCES[@]}" -o "$RUNNER_TEMP/ioslinearhdrproof-ubsan"
UBSAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/ioslinearhdrproof-ubsan"

printf '\n### P2.1e0 diagnostics GPU HDR producer model\n'
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -Igame "${PRODUCER_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdrproofproducer"
"$RUNNER_TEMP/ioslinearhdrproofproducer"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address -fno-omit-frame-pointer \
  -Igame "${PRODUCER_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdrproofproducer-asan"
ASAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/ioslinearhdrproofproducer-asan"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -fsanitize=undefined -fno-sanitize-recover=undefined \
  -fno-omit-frame-pointer \
  -Igame "${PRODUCER_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdrproofproducer-ubsan"
UBSAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/ioslinearhdrproofproducer-ubsan"

PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path


def sanitize_cpp(source: str) -> str:
    result = list(source)
    index = 0
    state = "code"
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if current == '"':
                state = "string"
            elif current == "'":
                state = "character"
            elif current == "/" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "line-comment"
            elif current == "/" and following == "*":
                result[index] = result[index + 1] = " "
                index += 1
                state = "block-comment"
        elif state == "string":
            if current == "\\":
                index += 1
            elif current == '"':
                state = "code"
        elif state == "character":
            if current == "\\":
                index += 1
            elif current == "'":
                state = "code"
        elif state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                result[index] = " "
        elif state == "block-comment":
            if current == "*" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "code"
            elif current != "\n":
                result[index] = " "
        index += 1
    if state == "block-comment":
        raise ValueError("unterminated block comment")
    return "".join(result)


def compact(source: str) -> str:
    return "".join(sanitize_cpp(source).split())


def function_scope(source: str, signature: str) -> str:
    sanitized = sanitize_cpp(source)
    start = sanitized.find(signature)
    if start < 0 or sanitized.find(signature, start + 1) >= 0:
        raise ValueError(f"function signature is not exact: {signature}")
    brace = sanitized.find("{", start + len(signature))
    if brace < 0:
        raise ValueError(f"function body missing: {signature}")
    depth = 0
    for index in range(brace, len(sanitized)):
        if sanitized[index] == "{":
            depth += 1
        elif sanitized[index] == "}":
            depth -= 1
            if depth == 0:
                return sanitized[start:index + 1]
    raise ValueError(f"function body unterminated: {signature}")


def validate(source: str, header: str) -> None:
    code = compact(source)
    header_code = compact(header)
    for required in (
        "constuint32_tred=word&0x7ffu;",
        "constuint32_tgreen=(word>>11u)&0x7ffu;",
        "constuint32_tblue=(word>>22u)&0x3ffu;",
        "if(exponent==31u)returnfalse;",
        "-14-static_cast<int>(mantissaBits)",
        "static_cast<int>(exponent)-15",
        "if(!validView(view))",
        "if(expectedInputSize!=input.size())",
    ):
        if required not in code:
            raise ValueError(f"RG11/schema contract missing: {required}")
    for required in (
        "std::span<conststd::byte>payload;",
        "IOSLinearHDRRGBmaximum;",
        "InvalidPackedValue=16u",
    ):
        if required not in header_code:
            raise ValueError(f"RG11/schema API changed: {required}")
    parser = function_scope(
        source,
        "IOSLinearHDRProofError iosParseLinearHDRProofV1(")
    if parser.count("view = candidate;") != 1:
        raise ValueError("parser publication count changed")
    publication = parser.index("view = candidate;")
    if "view." in sanitize_cpp(parser[:publication]):
        raise ValueError("parser mutates output before successful publication")


source = Path("game/graphics/ioslinearhdrproof.cpp").read_text()
header = Path("game/graphics/ioslinearhdrproof.h").read_text()
validate(source, header)

mutations = (
    source.replace(
        "  const uint32_t green = (word >> 11u)&0x7ffu;\n",
        "  const uint32_t green = (word >> 22u)&0x3ffu;\n", 1),
    source.replace("-14-static_cast<int>(mantissaBits)",
                   "-13-static_cast<int>(mantissaBits)", 1),
    source.replace("static_cast<int>(exponent)-15",
                   "static_cast<int>(exponent)-14", 1),
    source.replace("if(exponent==31u)\n    return false;",
                   "if(exponent==31u) {\n    if(mantissa==0u)\n      return false;\n    }", 1),
    source.replace(
        "  const uint64_t logicalBytes = loadLe64(input,32u);\n",
        "  const uint64_t logicalBytes = loadLe64(input,32u);\n"
        "  view.logicalBytes = logicalBytes;\n", 1),
    source.replace("  if(!validView(view))\n",
                   "  // if(!validView(view))\n", 1),
)
for mutated in mutations:
    try:
        validate(mutated, header)
    except ValueError:
        pass
    else:
        raise SystemExit("P2.1e0 RG11/schema mutation survived")

print(f"RG11B10/schema mutations killed: {len(mutations)}")
PY

printf '\n### P2.1e0 strict native tone-resolve bridge\n'
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/ioslinearhdrmetal.mm

xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=\"0123456789abcdef0123456789abcdef01234567\" \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/ioslinearhdrproofproducer.mm

printf '\n### P2.1e0 strict gpudebug exact-triple capture path\n'
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  "${GPU_TRIPLE_DEFINE[@]}" \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iosmetalcapturesession.mm

xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  "${GPU_TRIPLE_DEFINE[@]}" \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iosmetalresourceclearpassprobe.cpp

xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS \
  "${GPU_TRIPLE_DEFINE[@]}" \
  -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=\"0123456789abcdef0123456789abcdef01234567\" \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/ioslinearhdrproofproducer.mm

xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS \
  "${GPU_TRIPLE_DEFINE[@]}" \
  -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=\"0123456789abcdef0123456789abcdef01234567\" \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -isystem lib/TinySoundFont \
  -isystem lib/miniz \
  -isystem lib/bullet3/src \
  -fsyntax-only game/graphics/iosmetalcontext.cpp

xcrun clang++ -E -P -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=\"0123456789abcdef0123456789abcdef01234567\" \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -isystem lib/TinySoundFont \
  -isystem lib/miniz \
  -isystem lib/bullet3/src \
  game/graphics/iosmetalcontext.cpp \
  >"$RUNNER_TEMP/iosmetalcontext-linear-hdr-off.i"
if grep -Eq 'IOSLinearHDRCapture|RendererIOS HDR capture profile' \
     "$RUNNER_TEMP/iosmetalcontext-linear-hdr-off.i"; then
  echo "gpudebug capture leaked into diagnostics-OFF preprocessing" >&2
  exit 1
fi

printf '\n### P2.1e0 strict RendererIOS producer integration ON/OFF\n'
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS \
  -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=\"0123456789abcdef0123456789abcdef01234567\" \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -isystem lib/TinySoundFont \
  -isystem lib/miniz \
  -isystem lib/bullet3/src \
  -fsyntax-only game/graphics/iosmetalcontext.cpp

xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=\"0123456789abcdef0123456789abcdef01234567\" \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -isystem lib/TinySoundFont \
  -isystem lib/miniz \
  -isystem lib/bullet3/src \
  -fsyntax-only game/graphics/iosmetalcontext.cpp

printf '\n### P2.1e0 artifact/log join and guarded runner contracts\n'
PYTHONDONTWRITEBYTECODE=1 python3 ios/tests/test_linear_hdr_proof_artifact.py
PYTHONDONTWRITEBYTECODE=1 python3 ios/tests/test_linear_hdr_gpu_evidence.py
bash -n ios/device-test/run-linear-hdr-proof-test.sh
[[ "$(ios/device-test/run-linear-hdr-proof-test.sh --self-test)" == \
   "SELF-TEST PASS" ]]
bash -n ios/device-test/run-smoke-test.sh
ios/device-test/run-smoke-test.sh --self-test
[[ "$(python3 ios/device-test/validate-plist-contract.py --self-test)" == \
   "SELF-TEST PASS" ]]
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import ast
from pathlib import Path


source = Path("ios/device-test/run-linear-hdr-proof-test.sh").read_text()
required = (
    'pattern = re.compile(r"^\\.RendererIOS-linear-hdr-proof-v1\\.[0-9a-f]{32}\\.tmp$")',
    '"$UV" run --python python3.11 --with pymobiledevice3 python -',
    'documents_path = f"Documents/{leaf}"',
    'value = (await service.stat(documents_path)).get("st_ifmt")',
    '[[ "$file_type" == S_IFREG ]]',
    'require_afc_regular_leaf "$leaf" || return 1',
    'remaining="$(enumerate_owned_temps "$label-after")" || return 1',
    'capture_documents_listing "$output" || return 1',
    'if entry["name"] == leaf:',
    'capture_leaf_absent "$CAPTURE_LEAF" ||',
    'require_afc_regular_leaf "$FINAL_LEAF" ||',
    'require_game_zero pre',
    'require_game_zero post',
    'python3 "$GUARD" run --timeout',
    'python3 "$VALIDATOR"',
)

def afc_python_source(candidate: str) -> str:
    start = "afc_file_type() {\n  local leaf=\"$1\"\n"
    end = "\nPY\n}\n\nrequire_afc_regular_leaf() {"
    if candidate.count(start) != 1 or candidate.count(end) != 1:
        raise ValueError("AFC helper boundaries changed")
    scope = candidate[candidate.index(start) + len(start) : candidate.index(end)]
    heredoc = "<<'PY'\n"
    if scope.count(heredoc) != 1:
        raise ValueError("AFC helper Python heredoc changed")
    return scope.split(heredoc, 1)[1]


EXPECTED_AFC_PYTHON = '''\
import asyncio
import sys

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService


async def main() -> None:
    udid, bundle_id, leaf = sys.argv[1:]
    documents_path = f"Documents/{leaf}"
    async with await create_using_usbmux(
        serial=udid, autopair=False
    ) as lockdown:
        async with await HouseArrestService.create(
            lockdown=lockdown, bundle_id=bundle_id, documents_only=True
        ) as service:
            value = (await service.stat(documents_path)).get("st_ifmt")
    if not isinstance(value, str) or not value:
        raise RuntimeError("AFC stat returned no explicit st_ifmt")
    print(value)


asyncio.run(main())
'''
EXPECTED_AFC_AST = ast.dump(
    ast.parse(EXPECTED_AFC_PYTHON), include_attributes=False
)


def validate_afc_python_contract(candidate: str) -> None:
    try:
        tree = ast.parse(candidate)
    except SyntaxError as error:
        raise ValueError(f"AFC helper Python is invalid: {error}") from error
    if ast.dump(tree, include_attributes=False) != EXPECTED_AFC_AST:
        raise ValueError("AFC helper Python AST changed")


def validate_guarded_runner(candidate: str) -> None:
    for literal in required:
        if candidate.count(literal) != 1:
            raise ValueError(f"guarded producer runner contract changed: {literal}")
    for forbidden in ("--remove-existing-content",):
        if forbidden in candidate:
            raise ValueError(f"guarded producer runner contains forbidden text: {forbidden}")
    if 'if require_afc_capture_leaf "$CAPTURE_LEAF"' in candidate:
        raise ValueError("capture absence conflates AFC/provider failure with absence")
    for literal in (
        '"$UVX" --python python3.11 pymobiledevice3 apps rm',
        '--udid "$DEVICE_UDID" --documents "$BUNDLE_ID" "Documents/$leaf"',
    ):
        if candidate.count(literal) != 2:
            raise ValueError(
                f"guarded proof/capture exact-delete coverage changed: {literal}"
            )
    if '--documents "$BUNDLE_ID" "$leaf"' in candidate:
        raise ValueError("guarded runner retains a bare-leaf delete path")
    validate_afc_python_contract(afc_python_source(candidate))


validate_guarded_runner(source)
leaf_regression = source.replace(
    "service.stat(documents_path)",
    "service.stat(leaf)",
    1,
)
try:
    validate_afc_python_contract(afc_python_source(leaf_regression))
except ValueError:
    pass
else:
    raise SystemExit("AFC Documents path regression mutation survived")

comment_only_repair = source.replace(
    "service.stat(documents_path)",
    'service.stat("Documents/not-the-checked-leaf")'
    "  # service.stat(documents_path)",
    1,
)
try:
    validate_afc_python_contract(afc_python_source(comment_only_repair))
except ValueError:
    pass
else:
    raise SystemExit("AFC end-of-line comment-only repair mutation survived")

disconnected_value = source.replace(
    'value = (await service.stat(documents_path)).get("st_ifmt")',
    'await service.stat(documents_path)\n'
    '            value = "S_IFREG"\n'
    '            # value = (await service.stat(documents_path)).get("st_ifmt")',
    1,
)
try:
    validate_afc_python_contract(afc_python_source(disconnected_value))
except ValueError:
    pass
else:
    raise SystemExit("AFC disconnected value mutation survived")

dead_code_annassign = source.replace(
    'value = (await service.stat(documents_path)).get("st_ifmt")',
    'if False:\n'
    '                value = (await service.stat(documents_path)).get("st_ifmt")\n'
    '            value: str = "S_IFREG"',
    1,
)
try:
    validate_afc_python_contract(afc_python_source(dead_code_annassign))
except ValueError:
    pass
else:
    raise SystemExit("AFC dead-code AnnAssign mutation survived")

PY

printf '\n### P2.1e0 exact gpudebug triple source contracts\n'
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import ast
import json
import os
import subprocess
import tempfile
from pathlib import Path


def sanitize(source: str) -> str:
    result = list(source)
    index = 0
    state = "code"
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if current == '"':
                state = "string"
            elif current == "'":
                state = "character"
            elif current == "/" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "line-comment"
            elif current == "/" and following == "*":
                result[index] = result[index + 1] = " "
                index += 1
                state = "block-comment"
        elif state in ("string", "character"):
            terminator = '"' if state == "string" else "'"
            if current == "\\":
                index += 1
            elif current == terminator:
                state = "code"
        elif state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                result[index] = " "
        elif state == "block-comment":
            if current == "*" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "code"
            elif current != "\n":
                result[index] = " "
        index += 1
    if state == "block-comment":
        raise ValueError("unterminated block comment")
    return "".join(result)


def compact(source: str) -> str:
    return "".join(sanitize(source).split())


def scope(source: str, signature: str) -> str:
    clean = sanitize(source)
    if clean.count(signature) != 1:
        raise ValueError(f"scope signature changed: {signature}")
    start = clean.index(signature)
    brace = clean.index("{", start + len(signature))
    depth = 0
    for index in range(brace, len(clean)):
        if clean[index] == "{":
            depth += 1
        elif clean[index] == "}":
            depth -= 1
            if depth == 0:
                return clean[start:index + 1]
    raise ValueError(f"unterminated scope: {signature}")


def require_once(source: str, literal: str) -> int:
    if source.count(literal) != 1:
        raise ValueError(f"exact gpudebug literal count changed: {literal}")
    return source.index(literal)


def ordered(source: str, literals: tuple[str, ...]) -> None:
    positions = [require_once(source, literal) for literal in literals]
    if positions != sorted(positions):
        raise ValueError(f"exact gpudebug order changed: {literals}")


def active_cmake(source: str) -> str:
    active: list[str] = []
    for line in source.splitlines(keepends=True):
        newline = "\n" if line.endswith("\n") else ""
        content = line[:-1] if newline else line
        quoted = False
        escaped = False
        kept: list[str] = []
        for character in content:
            if escaped:
                kept.append(character)
                escaped = False
            elif quoted and character == "\\":
                kept.append(character)
                escaped = True
            elif character == '"':
                quoted = not quoted
                kept.append(character)
            elif character == "#" and not quoted:
                break
            else:
                kept.append(character)
        active.append("".join(kept) + newline)
    return "".join(active)


cmake = active_cmake(Path("CMakeLists.txt").read_text())
presets = json.loads(Path("CMakePresets.json").read_text())
base = next(item for item in presets["configurePresets"]
            if item["name"] == "renderer-ios-base")
triple = [item for item in presets["configurePresets"]
          if item["name"] == "renderer-ios-hdr-triple"]
if len(triple) != 1 or base["cacheVariables"].get(
        "OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE") != "OFF":
    raise SystemExit("hidden-base gpudebug default contract changed")
expected = {
    "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS": "ON",
    "OPENGOTHIC_RENDERER_IOS_FAULT_MODE": "none",
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE": "none",
    "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST": "OFF",
    "OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST": "OFF",
    "OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST": "OFF",
    "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": "OFF",
    "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": "OFF",
    "OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE": "ON",
}
if triple[0].get("inherits") != "renderer-ios-base" or \
        triple[0].get("cacheVariables") != expected:
    raise SystemExit("renderer-ios-hdr-triple is not the exact tuple")
builds = [item for item in presets["buildPresets"]
          if item["name"] == "renderer-ios-hdr-triple"]
if len(builds) != 1 or builds[0].get("configurePreset") != \
        "renderer-ios-hdr-triple" or builds[0].get("configuration") != "Release":
    raise SystemExit("renderer-ios-hdr-triple build preset changed")
for literal in (
    'option(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE',
    '<key>RendererIOSLinearHDRGPUTripleCapture</key>',
    '<key>MetalCaptureEnabled</key>',
    'OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE=1',
    'requires the exact diagnostics=ON, fault=none, causal=none, '
    'Bink/resource/clear/tile/forward=OFF tuple',
):
    if literal not in cmake:
        raise SystemExit(f"CMake exact-triple contract missing: {literal}")

capture = Path("game/graphics/iosmetalcapturesession.mm").read_text()
producer = Path("game/graphics/ioslinearhdrproofproducer.mm").read_text()
context = Path("game/graphics/iosmetalcontext.cpp").read_text()
header = compact(Path("game/graphics/iosmetalcapturesession.h").read_text())
capture_code = compact(capture)
producer_code = compact(producer)
context_code = compact(context)
for literal in (
    "Started,RejectedInactive,AmbiguousActive,",
    "RemoveExactOwned,RequireAbsent,",
    "boolstartReturn=false;boolactiveAfter=false;boolcomplete=false;",
):
    require_once(header, literal)
begin = compact(scope(capture, "IOSLinearHDRCaptureStartResult IOSMetalCaptureSession::beginCapture("))
ordered(begin, (
    "impl->observation={false,false,true};",
    "IOSMetalCaptureExistingArtifactPolicy::RequireAbsent",
    "[managerstartCaptureWithDescriptor:descriptor.get()error:&captureError]",
    "constBOOLactiveAfter=manager.isCapturing;",
    "impl->observation={started==YES,activeAfter==YES,true,};",
    "if(started==NO&&activeAfter==NO)",
    "if(started==YES&&activeAfter==YES)",
    'reason=started==NO?"capture-manager-start-ambiguous":',
))
if begin.count("returnIOSLinearHDRCaptureStartResult::AmbiguousActive;") != 2:
    raise SystemExit("capture ambiguity mapping coverage changed")
if begin.count("impl->observation=") != 3:
    raise SystemExit("capture start observation coverage changed")
if "removeItemAtURL" in begin[:begin.index(
        "IOSMetalCaptureExistingArtifactPolicy::RequireAbsent")]:
    raise SystemExit("RequireAbsent can reach stale-artifact deletion")

frame = compact(scope(context, "  struct FrameContext final"))
ordered(frame, (
    "IOSLinearHDRCaptureFramelinearHDRCapture;",
    "IOSLinearHDRProofFramelinearHDRProof;",
    "CommandBuffercommand;",
    "Fencefence;",
))
submit = compact(scope(
    context, "IOSMetalContext::SubmitResult IOSMetalContext::submitFrame("))
ordered(submit, (
    "linearHDRProof->beginCapture(frameContext.linearHDRCapture)",
    "command.startEncoding(impl->device)",
    "linearHDRProof->prepareFrame(",
    "impl->device.submit(command)",
    "linearHDRProof->markSubmitted(frameContext.linearHDRProof)",
    "markCaptureSubmittedAndStop(frameContext.linearHDRCapture)",
    "frameContext.fence=std::move(submittedFence)",
    "frameContext.discardCommandAfterIdle=true;",
    "captureOnlyFailure=true;",
))
if submit.count("impl->device.submit(command)") != 1:
    raise SystemExit("exact triple escaped the existing single submit")
require_once(context_code,
             compact('"RendererIOS HDR capture profile: v=1 mode=one-shot"'))
settle = compact(scope(context, "bool settleGpu(SettleReason reason, const char* operation,"))
ordered(settle, (
    "device.waitIdle()",
    "materializeLinearHDRProofAfterTerminal(frames[index],true)",
    "settleLinearHDRCapturesAfterConfirmedIdle()",
    "neutralizeFences()",
    "discardAmbiguousCommandsAfterConfirmedIdle()",
    "releaseLinearHDRProofFramesAfterTerminal()",
))
confirm = compact(scope(context, "bool confirmGpuIdle(SettleReason reason, const char* operation,"))
ordered(confirm, (
    "if(!idleConfirmed)",
    "if(hasLinearHDRCaptureOwners())",
    "terminateWithoutTeardown(",
    "continue;",
))
capture_failure = compact(scope(
    producer, "  void captureFailure(IOSLinearHDRCaptureFrame& frame,"))
if "IOSLinearHDRProofFailureReason" in capture_failure or \
        "IOSLinearHDRProofProducerEvent" in capture_failure:
    raise SystemExit("capture failure contaminates numeric proof state")
retain_capture = compact(scope(
    context, "  void retainLinearHDRCapturePreSubmitFailure("))
ordered(retain_capture, (
    "if(!frame.submitted&&linearHDRProof->hasOwners(frame.linearHDRProof))",
    "linearHDRProof->abortBeforeSubmit(frame.linearHDRProof)",
    "linearHDRProof->markCapturePreSubmitFailure(",
))
if submit.count("if(!captureOnlyFailure)") != 3:
    raise SystemExit("capture-only failure can contaminate numeric proof state")
search_from = 0
for _ in range(3):
    guard = submit.index("if(!captureOnlyFailure)", search_from)
    numeric_fail = submit.index(
        "impl->markLinearHDRProofPostSubmitFailure(frameContext)", guard)
    next_guard = submit.find("if(!captureOnlyFailure)", guard + 1)
    if next_guard >= 0 and next_guard < numeric_fail:
        raise SystemExit("capture-only numeric-failure guard is disconnected")
    search_from = numeric_fail + 1
for literal in (
    '"RendererIOS HDR capture: v=1 id=%s terminal=F reason=%s"',
    '"RendererIOS HDR capture: v=1 id=%s file=%s kind=%s bytes=%llu terminal=C"',
    "IOSMetalCaptureExistingArtifactPolicy::RequireAbsent",
):
    require_once(producer_code, compact(literal))

model = Path("game/graphics/ioslinearhdrproofproducer.cpp").read_text()
observation = compact(scope(
    model, "iosClassifyLinearHDRCaptureStartObservation("))
ordered(observation, (
    "if(!complete||(startReturn&&!activeAfter))",
    "IOSLinearHDRCaptureObservationDecision::PermanentNoTeardown",
    "if(startReturn&&activeAfter)",
    "IOSLinearHDRCaptureObservationDecision::Started",
    "if(!startReturn&&activeAfter)",
    "IOSLinearHDRCaptureObservationDecision::ActiveFailure",
    "IOSLinearHDRCaptureObservationDecision::RejectedInactive",
))
profile_model = compact(scope(
    model, "bool iosLinearHDRCaptureProfileAcceptsExactBoolean("))
require_once(profile_model, "returnexactCFBoolean&&booleanValue;")
profile_native = compact(scope(producer, "  void armCaptureProfile() noexcept"))
for literal in (
    "CFGetTypeID(static_cast<CFTypeRef>(value))==CFBooleanGetTypeID()",
    "CFBooleanGetValue(static_cast<CFBooleanRef>(value))",
    "iosLinearHDRCaptureProfileAcceptsExactBoolean(exactCFBoolean,booleanValue)",
):
    require_once(profile_native, literal)
for forbidden in ("isKindOfClass:[NSNumberclass]", "boolValue"):
    if forbidden in profile_native:
        raise SystemExit("capture profile accepts a non-CFBoolean value")
producer_begin = compact(scope(
    producer, "  IOSLinearHDRCaptureStartResult beginCapture("))
for literal in (
    "iosClassifyLinearHDRCaptureStartObservation(",
    "IOSLinearHDRCaptureObservationDecision::Started",
    "IOSLinearHDRCaptureObservationDecision::RejectedInactive",
    "IOSLinearHDRCaptureObservationDecision::ActiveFailure",
):
    require_once(producer_begin, literal)

model_mutation = model.replace(
    "  if(!complete || (startReturn && !activeAfter))\n",
    "  if(!complete)\n", 1)
try:
    mutated_observation = compact(scope(
        model_mutation, "iosClassifyLinearHDRCaptureStartObservation("))
    require_once(mutated_observation,
                 "if(!complete||(startReturn&&!activeAfter))")
except ValueError:
    pass
else:
    raise SystemExit("true,false permanent-no-teardown mutation survived")

profile_mutation = producer.replace(
    "        const bool exactCFBoolean = value!=nil &&\n"
    "            CFGetTypeID(static_cast<CFTypeRef>(value))==CFBooleanGetTypeID();\n",
    "        const bool exactCFBoolean = true; // CFGetTypeID(value)==CFBooleanGetTypeID()\n",
    1)
mutated_profile = compact(scope(
    profile_mutation, "  void armCaptureProfile() noexcept"))
if "CFGetTypeID(static_cast<CFTypeRef>(value))==CFBooleanGetTypeID()" in mutated_profile:
    raise SystemExit("comment-only exact-CFBoolean mutation survived")

validator = Path("ios/device-test/validate-linear-hdr-gpu-evidence.py").read_text()


def ast_name(node: ast.AST) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        prefix = ast_name(node.value)
        return f"{prefix}.{node.attr}" if prefix else node.attr
    return ""


def assigned_literal(tree: ast.Module, name: str):
    matches = [node for node in tree.body
               if isinstance(node, (ast.Assign, ast.AnnAssign)) and
               ((isinstance(node, ast.Assign) and len(node.targets) == 1 and
                 isinstance(node.targets[0], ast.Name) and
                 node.targets[0].id == name) or
                (isinstance(node, ast.AnnAssign) and
                 isinstance(node.target, ast.Name) and node.target.id == name))]
    if len(matches) != 1:
        raise ValueError(f"validator assignment changed: {name}")
    value = matches[0].value
    def evaluate(node: ast.AST):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Tuple):
            return tuple(evaluate(child) for child in node.elts)
        if isinstance(node, ast.BinOp):
            left, right = evaluate(node.left), evaluate(node.right)
            if isinstance(node.op, ast.Mult):
                return left * right
            if isinstance(node.op, ast.Add):
                return left + right
            if isinstance(node.op, ast.Sub):
                return left - right
            if isinstance(node.op, ast.LShift):
                return left << right
        raise ValueError(f"validator assignment is not literal: {name}")
    return evaluate(value)


def function_node(tree: ast.Module, name: str) -> ast.FunctionDef:
    matches = [node for node in tree.body
               if isinstance(node, ast.FunctionDef) and node.name == name]
    if len(matches) != 1:
        raise ValueError(f"validator function changed: {name}")
    return matches[0]


def calls(node: ast.AST, name: str) -> list[ast.Call]:
    return [child for child in ast.walk(node)
            if isinstance(child, ast.Call) and ast_name(child.func) == name]


def require_call(node: ast.AST, name: str, count: int = 1) -> list[ast.Call]:
    matches = calls(node, name)
    if len(matches) != count:
        raise ValueError(
            f"validator call count changed ({len(matches)}): {name}")
    return matches


def require_unparsed(node: ast.AST, fragments: tuple[str, ...], label: str) -> str:
    source = ast.unparse(node)
    for fragment in fragments:
        if fragment not in source:
            raise ValueError(f"{label} changed: {fragment}")
    return source


def validate_validator(candidate: str) -> None:
    try:
        tree = ast.parse(candidate)
    except SyntaxError as error:
        raise ValueError(f"validator Python is invalid: {error}") from error
    exact_assignments = {
        "GPUDEBUG": "/usr/bin/gpudebug",
        "GPUDEBUG_VERSION": b"gpudebug 1.0\n",
        "SCHEMA_VERSION": 2,
        "EVIDENCE_CLASS": "device-gpudebug-lossless",
        "PRODUCER": "opengothic-linear-hdr-gpu-adapter/2",
        "MAX_TRANSCRIPT_BYTES": 16 * 1024 * 1024,
        "COLLECTOR_GLOBAL_TIMEOUT_SECONDS": 720.0,
        "COLLECTOR_MAIN_TIMEOUT_SECONDS": 600.0,
        "COLLECTOR_COMMAND_TIMEOUT_SECONDS": 90.0,
        "COLLECTOR_MINIMUM_TIMEOUT_SECONDS": 1.0,
        "COLLECTOR_SESSION_SETTLE_SECONDS": 1.0,
    }
    for name, expected_value in exact_assignments.items():
        if assigned_literal(tree, name) != expected_value:
            raise ValueError(f"validator constant changed: {name}")
    role_values = assigned_literal(tree, "ROLE_ORDER")
    expected_roles = (
        "version", "open", "commands", "command-buffer", "scene-encoder",
        "scene-color0", "proof-encoder", "proof-group", "proof-blit",
        "tone-encoder", "tone-group", "tone-draw", "tone-fragment",
        "tone-tex0", "scene-resource", "terminate", "sessions-after",
    )
    if role_values != expected_roles:
        raise ValueError("gpudebug transcript roles differ from exact discovery flow")

    timeout = function_node(tree, "collector_command_timeout")
    minimums = calls(timeout, "min")
    if len(minimums) != 1 or len(minimums[0].args) != 2 or \
            {ast_name(argument) for argument in minimums[0].args} != {
                "COLLECTOR_COMMAND_TIMEOUT_SECONDS", "remaining"}:
        raise ValueError("collector timeout is not min(per-command, remaining global)")
    timeout_dump = ast.dump(timeout, include_attributes=False)
    if "COLLECTOR_MINIMUM_TIMEOUT_SECONDS" not in timeout_dump or \
            "GtE" not in timeout_dump:
        raise ValueError("collector can start with less than one second remaining")
    runner_node = function_node(tree, "run_collector_command")
    if calls(runner_node, "subprocess.run"):
        raise ValueError("collector uses allocation-unbounded subprocess.run")
    popen = require_call(runner_node, "subprocess.Popen")[0]
    keywords = {keyword.arg: keyword.value for keyword in popen.keywords}
    if not isinstance(keywords.get("start_new_session"), ast.Constant) or \
            keywords["start_new_session"].value is not True:
        raise ValueError("collector process group ownership changed")
    expected_env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
    if ast.literal_eval(keywords.get("env")) != expected_env:
        raise ValueError("collector scrubbed environment changed")
    if ast_name(keywords.get("stdout")) != "subprocess.PIPE" or \
            ast_name(keywords.get("stderr")) != "subprocess.PIPE":
        raise ValueError("collector bounded pipe capture changed")
    require_call(runner_node, "os.read")
    require_call(runner_node, "_kill_owned_process_group", 5)
    runner_dump = ast.dump(runner_node, include_attributes=False)
    for required in ("MAX_TRANSCRIPT_BYTES", "returncode", "gpudebug exited"):
        if required not in runner_dump:
            raise ValueError(f"collector runtime guard changed: {required}")

    killer = function_node(tree, "_kill_owned_process_group")
    require_call(killer, "os.killpg")
    if "SIGKILL" not in ast.dump(killer, include_attributes=False):
        raise ValueError("collector timeout/overflow no longer kills its process group")

    listing = function_node(tree, "listed_session_ids")
    listing_source = require_unparsed(listing, (
        "text.endswith('\\n') and '\\r' not in text",
        "text == 'No active sessions.\\n'",
        "SESSION_LIST_HEADER_RE.fullmatch(lines[0])",
        "SESSION_LIST_FOOTER_RE.fullmatch(lines[-1])",
        "count == len(rows)",
        "SESSION_LIST_ROW_RE.fullmatch(row)",
        "session not in sessions",
        "sessions.add(session)",
    ), "strict session-list parser")
    if "json.loads" in listing_source or "json.JSONDecoder" in listing_source:
        raise ValueError("session-list parser retains the legacy JSON contract")

    open_parser = function_node(tree, "parse_session")
    require_unparsed(open_parser, (
        "text.endswith('\\n') and '\\r' not in text",
        "text.splitlines(keepends=True)",
        "SESSION_RE.fullmatch(lines[0][:-1])",
        "OTHER_SESSIONS_RE.fullmatch(lines[index][:-1])",
        "count == 1 and noun == 'session' or (count > 1 and noun == 'sessions')",
        "lines[index] == f'gpudebug -s {session} -c <command> to send commands.\\n'",
        "documents, _ = _json_documents(payload, 'gpudebug open payload', 1)",
        "_validate_open_root(documents[0])",
        "return session",
    ), "strict open transcript parser")
    open_root = function_node(tree, "_validate_open_root")
    require_unparsed(open_root, (
        "exact_object(document, ('children', 'totalCount'), 'gpudebug open root')",
        "exact_int(root['totalCount'], len(children), 'gpudebug open root.totalCount')",
        "expected = (('commands', 'go'), ('performance', ''), ('api_calls', 'go'), ('resources', 'go'))",
        "len(children) == len(expected)",
        "zip(expected, children)",
        "exact_object(child_value, ('actions', 'name', 'values')",
        "len(child_values) == 1",
        "exact_object(child_values[0], ('type', 'value')",
        "exact_string(item['type'], 'string'",
        "_canonical_count_value(values['commands'], 'command buffer', 'command buffers'",
        "exact_string(values['performance'], \"see 'profile ?'\"",
        "_canonical_count_value(values['api_calls'], 'API call', 'API calls'",
        "_canonical_count_value(values['resources'], 'object', 'objects'",
    ), "exact open-root hierarchy")
    terminate_parser = function_node(tree, "validate_terminate")
    require_unparsed(terminate_parser, (
        "f'Session {session} terminated.\\n'.encode('ascii')",
        "raw == expected",
    ), "strict terminate transcript parser")

    waiter = function_node(tree, "wait_for_owned_session_absence")
    waiter_runner = require_call(waiter, "run_collector_command")[0]
    if [ast.unparse(argument) for argument in waiter_runner.args] != [
            "argv", "overall_deadline"]:
        raise ValueError("owned-session repoll escaped the overall deadline")
    listed = require_call(waiter, "listed_session_ids")[0]
    membership = [node for node in ast.walk(waiter)
                  if isinstance(node, ast.Compare) and
                  len(node.ops) == 1 and isinstance(node.ops[0], ast.NotIn) and
                  ast_name(node.left) == "session" and
                  ast.dump(node.comparators[0], include_attributes=False) ==
                  ast.dump(listed, include_attributes=False)]
    loops = [node for node in ast.walk(waiter)
             if isinstance(node, ast.While) and
             isinstance(node.test, ast.Constant) and node.test.value is True]
    sleeps = require_call(waiter, "time.sleep")
    if len(membership) != 1 or len(loops) != 1 or \
            [ast.unparse(argument) for argument in sleeps[0].args] != [
                "COLLECTOR_SESSION_SETTLE_SECONDS"]:
        raise ValueError("owned-session bounded exact-ID repoll changed")
    require_unparsed(waiter, (
        "remaining = overall_deadline - time.monotonic()",
        "remaining >= COLLECTOR_SESSION_SETTLE_SECONDS + COLLECTOR_MINIMUM_TIMEOUT_SECONDS",
        "return raw",
    ), "owned-session bounded exact-ID repoll")

    cleanup = function_node(tree, "cleanup_owned_collector_session")
    cleanup_source = ast.unparse(cleanup)
    cleanup_runner = require_call(cleanup, "run_collector_command")[0]
    cleanup_wait = require_call(cleanup, "wait_for_owned_session_absence")[0]
    cleanup_terminate = require_call(cleanup, "validate_terminate")[0]
    if [ast.unparse(argument) for argument in cleanup_runner.args] != [
            "terminate_argv", "overall_deadline"] or \
            [ast.unparse(argument) for argument in cleanup_wait.args] != [
                "session", "sessions_argv", "overall_deadline"] or \
            [ast.unparse(argument) for argument in cleanup_terminate.args] != [
                "raw", "session"] or \
            "--terminate-all" in cleanup_source:
        raise ValueError("owned session cleanup contract changed")
    if "'--terminate'" not in cleanup_source or \
            "'--list-sessions'" not in cleanup_source:
        raise ValueError("owned session cleanup commands changed")
    sessions_entries = [call for call in calls(cleanup, "_transcript_entry")
                        if call.args and isinstance(call.args[0], ast.Constant) and
                        call.args[0].value == "sessions-after"]
    terminate_entries = [call for call in calls(cleanup, "_transcript_entry")
                         if call.args and isinstance(call.args[0], ast.Constant) and
                         call.args[0].value == "terminate"]
    if len(terminate_entries) != 1 or \
            not (cleanup_runner.lineno < cleanup_terminate.lineno <
                 terminate_entries[0].lineno) or \
            len(sessions_entries) != 1 or \
            cleanup_wait.lineno >= sessions_entries[0].lineno or \
            "raws['sessions-after'] = raw" not in cleanup_source:
        raise ValueError("cleanup does not retain only the final absence transcript")
    if calls(cleanup, "time.monotonic") or cleanup_source.count(
            "overall_deadline") < 3:
        raise ValueError("cleanup created a fresh deadline")

    documents = function_node(tree, "_json_documents")
    documents_source = require_unparsed(documents, (
        "json.JSONDecoder(object_pairs_hook=unique_object, parse_constant=reject_constant)",
        "for _ in range(expected_count):",
        "decoder.raw_decode(text, offset)",
        "isinstance(document, dict)",
        "end < len(text) and text[end] == '\\n'",
        "offset = end + 1",
        "offset == len(text)",
    ), "strict multi-document JSON parser")
    if "json.loads" in documents_source:
        raise ValueError("gpudebug parser retains a single-json shortcut")
    navigable = function_node(tree, "_navigable_json")
    require_unparsed(navigable, (
        "documents, fragments = _json_documents(raw, label, 2)",
        "fragments[0] == fragments[1] and documents[0] == documents[1]",
        "return documents[1]",
    ), "go/list multi-document parser")
    direct_info = function_node(tree, "_direct_info_json")
    require_unparsed(direct_info, (
        "documents, _ = _json_documents(raw, label, 1)",
        "return documents[0]",
    ), "direct-info single-document parser")

    command_buffer_path = function_node(tree, "_command_buffer_path")
    require_unparsed(command_buffer_path, (
        "_navigable_json(raw, 'commands')",
        "len(children) == 1",
        "return 'commands/' + child['name']",
    ), "command-buffer hierarchy parser")
    encoder_paths = function_node(tree, "_encoder_paths")
    require_unparsed(encoder_paths, (
        "_navigable_json(raw, 'command buffer')",
        "scene_index < proof_index < tone_index",
        "f\"{cb_path}/{scene['name']}\"",
        "f\"{cb_path}/{proof['name']}\"",
        "f\"{cb_path}/{tone['name']}\"",
    ), "encoder hierarchy parser")
    group_path = function_node(tree, "_one_group_path")
    require_unparsed(group_path, (
        "_navigable_json(raw, label)",
        "re.fullmatch('grp(?:0|[1-9][0-9]*)', item['name'])",
        "_marker_value_matches(value, marker)",
        "f\"{encoder_path}/{child['name']}\"",
    ), "marker group hierarchy parser")
    proof_group_command = function_node(tree, "_proof_group_command_path")
    require_unparsed(proof_group_command, (
        "_navigable_json(raw, 'proof group')",
        "{'go', 'info'}.issubset(_child_actions(item))",
        "re.fullmatch('blit(?:0|[1-9][0-9]*)', item['name'])",
        "len(children) == 1",
        "f\"{group_path}/{child['name']}\"",
    ), "dynamic proof-group command discovery")
    proof_result = function_node(tree, "_proof_blit_result")
    require_unparsed(proof_result, (
        "document = _direct_info_json(raw, 'proof blit')",
        "_document_one_field(document, 'sourceTexture', 'proof blit')",
        "return (source_match.group(1), document)",
    ), "direct-info proof-blit parser")
    tone_group_draw = function_node(tree, "_tone_group_draw_path")
    require_unparsed(tone_group_draw, (
        "_navigable_json(raw, 'tone group')",
        "re.fullmatch('draw(?:0|[1-9][0-9]*)', item['name'])",
        "len(group_children) == 1",
        "f\"{group_path}/{draw['name']}\"",
    ), "dynamic tone-group draw discovery")
    tone_draw_fragment = function_node(tree, "_tone_draw_fragment_path")
    require_unparsed(tone_draw_fragment, (
        "_navigable_json(raw, 'tone draw')",
        "fragments = [child for child in draw_children if child['name'] == 'fragment']",
        "len(fragments) == 1 and 'go' in _child_actions(fragments[0])",
        "return draw_path + '/fragment'",
    ), "dynamic tone-draw fragment discovery")
    tone_result = function_node(tree, "_tone_fragment_result")
    require_unparsed(tone_result, (
        "document = _navigable_json(raw, 'tone fragment')",
        "_listing_children(document, 'tone fragment')",
        "texture_names == ['tex[0]']",
        "_texture_binding(document, 'tex[0]', scene_marker, 'tone fragment')",
    ), "tone fragment parser")

    filenames = function_node(tree, "expected_filenames")
    require_unparsed(filenames, (
        "proof_group = command['proofBlit']['commandPath'].rsplit('/', 2)[-2]",
        "tone_group, tone_draw = command['toneResolve']['drawPath'].rsplit('/', 1)",
        "tone_group = tone_group.rsplit('/', 1)[1]",
        "'proof-group': f'proof-grp-{proof_group[3:]}.json'",
        "'proof-blit': f'proof-blit-{proof_blit.group(3)[4:]}.json'",
        "'tone-group': f'tone-grp-{tone_group[3:]}.json'",
        "'tone-draw': f'tone-draw-{tone_draw[4:]}.json'",
    ), "dynamic discovery transcript filenames")
    expected_arguments = function_node(tree, "expected_argv")
    require_unparsed(expected_arguments, (
        "'commands': [GPUDEBUG, '--json', '-s', session, '-c', 'go commands', '-c', 'list --all']",
        "'command-buffer': [GPUDEBUG, '--json', '-s', session, '-c', f\"go commands/{command['commandBuffer']}\", '-c', 'list --all']",
        "'scene-encoder': [GPUDEBUG, '--json', '-s', session, '-c', f'go {scene}', '-c', 'list --all']",
        "'scene-color0': [GPUDEBUG, '--json', '-s', session, '-c', f'info {scene}/color0']",
        "'proof-encoder': [GPUDEBUG, '--json', '-s', session, '-c', f'go {proof_encoder}', '-c', 'list --all']",
        "'proof-group': [GPUDEBUG, '--json', '-s', session, '-c', f'go {proof_group}', '-c', 'list --all']",
        "'proof-blit': [GPUDEBUG, '--json', '-s', session, '-c', f'info {proof_blit}']",
        "'tone-encoder': [GPUDEBUG, '--json', '-s', session, '-c', f'go {tone_encoder}', '-c', 'list --all']",
        "'tone-group': [GPUDEBUG, '--json', '-s', session, '-c', f'go {tone_group}', '-c', 'list --all']",
        "'tone-draw': [GPUDEBUG, '--json', '-s', session, '-c', f'go {tone_draw}', '-c', 'list --all']",
        "'tone-fragment': [GPUDEBUG, '--json', '-s', session, '-c', f'go {tone_draw}/fragment', '-c', 'list --all']",
        "'tone-tex0': [GPUDEBUG, '--json', '-s', session, '-c', f'info {tone_draw}/fragment/tex[0]']",
        "'scene-resource': [GPUDEBUG, '--json', '-s', session, '-c', f\"info {resource['textureRef']}\"]",
    ), "real gpudebug transcript argv")

    collect_node = function_node(tree, "collect")
    finalizers = [part for part in ast.walk(collect_node)
                  if isinstance(part, ast.Try) and
                  calls(ast.Module(body=part.finalbody, type_ignores=[]),
                        "cleanup_owned_collector_session")]
    if len(finalizers) != 1:
        raise ValueError("collector cleanup escaped finally")
    collect_source = ast.unparse(collect_node)
    for required in (
        "started = time.monotonic()",
        "main_deadline = started + COLLECTOR_MAIN_TIMEOUT_SECONDS",
        "overall_deadline = started + COLLECTOR_GLOBAL_TIMEOUT_SECONDS",
        "commands = invoke('commands', 'commands.json', [GPUDEBUG, '--json', '-s', session, '-c', 'go commands', '-c', 'list --all'])",
        "command_buffer = invoke('command-buffer'",
        "'-c', f'go {cb_path}', '-c', 'list --all'",
        "scene_encoder = invoke('scene-encoder'",
        "'-c', f'go {scene_path}', '-c', 'list --all'",
        "scene_color = invoke('scene-color0', 'scene-color0.json', [GPUDEBUG, '--json', '-s', session, '-c', f'info {scene_path}/color0'])",
        "proof_encoder = invoke('proof-encoder'",
        "'-c', f'go {proof_path}', '-c', 'list --all'",
        "proof_group = _one_group_path(proof_encoder, proof_path, proof_marker, 'proof encoder')",
        "proof_group_name = proof_group.rsplit('/', 1)[1]",
        "proof_group_raw = invoke('proof-group', f'proof-grp-{proof_group_name[3:]}.json', [GPUDEBUG, '--json', '-s', session, '-c', f'go {proof_group}', '-c', 'list --all'])",
        "blit_path = _proof_group_command_path(proof_group_raw, proof_group)",
        "blit_name = blit_path.rsplit('/', 1)[1]",
        "proof_blit = invoke('proof-blit', f'proof-blit-{blit_name[4:]}.json', [GPUDEBUG, '--json', '-s', session, '-c', f'info {blit_path}'])",
        "_proof_blit_result(proof_blit, scene_marker)",
        "tone_group = _one_group_path(tone_encoder, tone_path, tone_marker, 'tone encoder')",
        "tone_group_name = tone_group.rsplit('/', 1)[1]",
        "tone_group_raw = invoke('tone-group', f'tone-grp-{tone_group_name[3:]}.json', [GPUDEBUG, '--json', '-s', session, '-c', f'go {tone_group}', '-c', 'list --all'])",
        "draw_path = _tone_group_draw_path(tone_group_raw, tone_group)",
        "draw_name = draw_path.rsplit('/', 1)[1]",
        "tone_draw = invoke('tone-draw', f'tone-draw-{draw_name[4:]}.json', [GPUDEBUG, '--json', '-s', session, '-c', f'go {draw_path}', '-c', 'list --all'])",
        "fragment_path = _tone_draw_fragment_path(tone_draw, draw_path)",
        "tone_fragment = invoke('tone-fragment', 'tone-fragment.json', [GPUDEBUG, '--json', '-s', session, '-c', f'go {fragment_path}', '-c', 'list --all'])",
        "tone_tex0 = invoke('tone-tex0', 'tone-tex0.json', [GPUDEBUG, '--json', '-s', session, '-c', f'info {fragment_path}/tex[0]'])",
        "scene_resource = invoke('scene-resource', 'scene-resource.json', [GPUDEBUG, '--json', '-s', session, '-c', f'info {texture_ref}'])",
    ):
        if required not in collect_source:
            raise ValueError(f"collector total budget changed: {required}")
    dynamic_nodes = (filenames, expected_arguments, proof_group_command,
                     tone_group_draw, tone_draw_fragment, collect_node)
    if any(isinstance(part, ast.Constant) and
           part.value in ("blit0", "draw0", "grp0")
           for node in dynamic_nodes for part in ast.walk(node)):
        raise ValueError("collector hardcodes a discovered group/blit/draw identity")
    main_commands = calls(collect_node, "run_collector_command")
    if len(main_commands) != 2 or any(
            not call.args or ast_name(call.args[-1]) != "main_deadline"
            for call in main_commands):
        raise ValueError("main collection escaped the 600-second deadline")
    cleanup_calls = calls(collect_node, "cleanup_owned_collector_session")
    if len(cleanup_calls) != 1 or not cleanup_calls[0].args or \
            ast_name(cleanup_calls[0].args[-1]) != "overall_deadline":
        raise ValueError("cleanup does not consume the reserved overall deadline")
    parse_calls = calls(collect_node, "parse_session")
    open_entries = [call for call in calls(collect_node, "_transcript_entry")
                    if call.args and isinstance(call.args[0], ast.Constant) and
                    call.args[0].value == "open"]
    if len(parse_calls) != 1 or len(open_entries) != 1 or \
            parse_calls[0].lineno >= open_entries[0].lineno:
        raise ValueError("session identity is not retained before transcript write")
    transcript_validation = function_node(tree, "validate_transcripts")
    transcript_validation_source = require_unparsed(transcript_validation, (
        "validate_terminate(raws['terminate'], session)",
        "session not in listed_session_ids(raws['sessions-after'])",
        "_navigable_json(raws['scene-encoder'], 'scene encoder')",
        "_direct_info_json(raws['scene-color0'], 'scene color0')",
        "_one_group_path(raws['proof-encoder'], proof_path",
        "_proof_group_command_path(raws['proof-group'], proof_group)",
        "_proof_blit_result(raws['proof-blit'], resource['label'])",
        "_one_group_path(raws['tone-encoder'], tone_path",
        "_tone_group_draw_path(raws['tone-group'], tone_group)",
        "_tone_draw_fragment_path(raws['tone-draw'], draw_path)",
        "_tone_fragment_result(raws['tone-fragment'], resource['label'])",
        "_direct_info_json(raws[role], role)",
    ), "final transcript parser")
    if "session.encode()" in transcript_validation_source:
        raise ValueError("final transcript retains substring session matching")

    clone = function_node(tree, "clone_capture_no_follow")
    clone_dump = ast.dump(clone, include_attributes=False)
    for required in ("O_NOFOLLOW", "dir_fd", "fchmod", "fsync"):
        if required not in clone_dump:
            raise ValueError(f"descriptor capture clone guard changed: {required}")
    digest = function_node(tree, "_file_digest_fd")
    require_call(digest, "os.read")
    if calls(digest, "open") or calls(digest, "pathlib.Path.open"):
        raise ValueError("capture hashing follows a path")
    rename = function_node(tree, "rename_no_clobber")
    rename_dump = ast.dump(rename, include_attributes=False)
    for required in ("source_directory", "destination_directory",
                     "O_NOFOLLOW", "rename_excl"):
        if required not in rename_dump:
            raise ValueError(f"directory-relative rename guard changed: {required}")
    if any(isinstance(node, ast.FunctionDef) and
           node.name in ("remove_capture_no_follow",
                         "_remove_capture_directory_no_follow")
           for node in tree.body):
        raise ValueError("validator must retain local capture staging")
    commit = function_node(tree, "commit_capture_copy")
    commit_calls = [(call.lineno, ast_name(call.func))
                    for call in ast.walk(commit) if isinstance(call, ast.Call)]
    interesting = [name for _, name in sorted(commit_calls)
                   if name in ("clone_capture_no_follow",
                               "stable_capture_manifest", "rename_no_clobber")]
    try:
        clone_index = interesting.index("clone_capture_no_follow")
    except ValueError as error:
        raise ValueError("capture descriptor clone is missing") from error
    if interesting[clone_index:clone_index + 3] != [
            "clone_capture_no_follow", "stable_capture_manifest",
            "rename_no_clobber"]:
        raise ValueError("capture clone/verify/commit order changed")
    if calls(commit, "os.chmod") or calls(commit, "os.fchmod"):
        raise ValueError("commit mutates caller-owned staging")
    if calls(commit, "remove_capture_no_follow") or calls(commit, "os.unlink") or \
            calls(commit, "os.rmdir"):
        raise ValueError("commit deletes retained local staging")
    summary_commits = calls(commit, "atomic_no_clobber")
    committed_walks = calls(commit, "stable_capture_manifest")
    if len(summary_commits) != 1 or not committed_walks or \
            summary_commits[0].lineno <= max(call.lineno for call in committed_walks):
        raise ValueError("evidenceCommitted summary precedes final capture verification")


validate_validator(validator)
validator_mutations = (
    validator.replace(
        "    return min(COLLECTOR_COMMAND_TIMEOUT_SECONDS, remaining)\n",
        "    return max(COLLECTOR_COMMAND_TIMEOUT_SECONDS, remaining)\n", 1),
    validator.replace(
        "    require(returncode == 0, f\"gpudebug exited {returncode}\")\n",
        "    if returncode != 0:\n        pass\n", 1),
    validator.replace(
        "                cleanup_owned_collector_session(\n"
        "                    session, transcript_dir, entries, raws, overall_deadline)\n",
        "                pass  # cleanup_owned_collector_session(session, transcript_dir, entries, raws)\n",
        1),
    validator.replace(
        "                    session, transcript_dir, entries, raws, overall_deadline)\n",
        "                    session, transcript_dir, entries, raws, time.monotonic()+120.0)\n",
        1),
    validator.replace(
        "    require(remaining >= COLLECTOR_MINIMUM_TIMEOUT_SECONDS,\n"
        "            \"collector deadline has less than one second remaining\")\n",
        "    require(remaining > 0.0,\n"
        "            \"collector deadline has less than one second remaining\")\n",
        1),
    validator.replace(
        '    "scene-color0", "proof-encoder", "proof-group", "proof-blit",\n',
        '    "scene-color0", "proof-encoder", "proof-blit",\n', 1),
    validator.replace(
        "        if session not in listed_session_ids(raw):\n",
        "        if session.encode() not in raw:\n", 1),
    validator.replace(
        "        raw = wait_for_owned_session_absence(\n"
        "            session, sessions_argv, overall_deadline)\n",
        "        raw = run_collector_command(sessions_argv, overall_deadline)\n",
        1),
    validator.replace(
        "    footer = SESSION_LIST_FOOTER_RE.fullmatch(lines[-1])\n",
        "    footer = SESSION_LIST_FOOTER_RE.search(lines[-1])\n", 1),
    validator.replace(
        "    match = SESSION_RE.fullmatch(lines[0][:-1])\n",
        "    match = SESSION_RE.search(text)  # fullmatch(lines[0][:-1])\n", 1),
    validator.replace(
        "    require(raw == expected, \"gpudebug terminate transcript is not byte-exact\")\n",
        "    require(True, \"gpudebug terminate transcript is not byte-exact\")\n",
        1),
    validator.replace(
        "    require(offset == len(text),\n",
        "    require(offset <= len(text),\n", 1),
    validator.replace(
        "    documents, fragments = _json_documents(raw, label, 2)\n",
        "    documents, fragments = _json_documents(raw, label, 1)\n", 1),
    validator.replace(
        "    require(fragments[0] == fragments[1] and documents[0] == documents[1],\n",
        "    require(True,\n", 1),
    validator.replace(
        "    documents, _ = _json_documents(raw, label, 1)\n",
        "    documents = [_navigable_json(raw, label)]\n", 1),
    validator.replace(
        '    return f"{group_path}/{child[\'name\']}"\n\n\n'
        "def _proof_blit_result",
        '    return f"{group_path}/blit0"\n\n\n'
        "def _proof_blit_result",
        1),
    validator.replace(
        '        "proof-blit": [GPUDEBUG, "--json", "-s", session, "-c", f"info {proof_blit}"],\n',
        '        "proof-blit": [GPUDEBUG, "--json", "-s", session, "-c", "info blit0"],\n',
        1),
    validator.replace(
        "        blit_path = _proof_group_command_path(proof_group_raw, proof_group)\n",
        '        blit_path = proof_group + "/blit0"\n', 1),
    validator.replace(
        '    return f"{group_path}/{draw[\'name\']}"\n',
        '    return f"{group_path}/draw0"\n', 1),
    validator.replace(
        '        "tone-fragment": [GPUDEBUG, "--json", "-s", session, "-c",\n'
        '                          f"go {tone_draw}/fragment", "-c", "list --all"],\n',
        '        "tone-fragment": [GPUDEBUG, "--json", "-s", session, "-c",\n'
        '                          "go draw0/fragment", "-c", "list --all"],\n',
        1),
    validator.replace(
        "        fragment_path = _tone_draw_fragment_path(tone_draw, draw_path)\n",
        '        fragment_path = tone_group + "/draw0/fragment"\n', 1),
    validator.replace(
        '    require(session not in listed_session_ids(raws["sessions-after"]),\n',
        '    require(session.encode() not in raws["sessions-after"],\n', 1),
    validator.replace(
        '    validate_terminate(raws["terminate"], session)\n',
        '    pass  # validate_terminate(raws["terminate"], session)\n', 1),
    validator.replace(
        "        require(session not in sessions, \"gpudebug session listing repeats an ID\")\n",
        "        require(True, \"gpudebug session listing repeats an ID\")\n",
        1),
    validator.replace(
        '    document = _direct_info_json(raw, "proof blit")\n',
        '    document = _navigable_json(raw, "proof blit")\n', 1),
    validator.replace(
        '    document = _navigable_json(raw, "tone fragment")\n',
        '    document = _direct_info_json(raw, "tone fragment")\n', 1),
    validator.replace(
        "    _validate_open_root(documents[0])\n",
        "    pass  # _validate_open_root(documents[0])\n", 1),
    validator.replace(
        '        ("commands", "go"),\n'
        '        ("performance", ""),\n'
        '        ("api_calls", "go"),\n'
        '        ("resources", "go"),\n',
        '        ("commands", "go"),\n'
        '        ("api_calls", "go"),\n'
        '        ("performance", ""),\n'
        '        ("resources", "go"),\n',
        1),
    validator.replace(
        '    exact_int(root["totalCount"], len(children),\n'
        '              "gpudebug open root.totalCount")\n',
        '    pass  # exact_int(root["totalCount"], len(children))\n',
        1),
    validator.replace(
        '    proof_group = command["proofBlit"]["commandPath"].rsplit("/", 2)[-2]\n',
        '    proof_group = "grp0"\n', 1),
    validator.replace(
        '        proof_group_name = proof_group.rsplit("/", 1)[1]\n',
        '        proof_group_name = "grp0"\n', 1),
    validator.replace(
        "        validate_terminate(raw, session)\n",
        "        pass  # validate_terminate(raw, session)\n", 1),
    validator.replace(
        "    other = OTHER_SESSIONS_RE.fullmatch(lines[index][:-1])\n",
        "    other = None  # OTHER_SESSIONS_RE.fullmatch(lines[index][:-1])\n",
        1),
)
for index, mutation in enumerate(validator_mutations, 1):
    if mutation == validator:
        raise SystemExit(f"collector mutation is a no-op: {index}")
    try:
        validate_validator(mutation)
    except ValueError:
        pass
    else:
        raise SystemExit(f"collector mutation survived: {index}")
print(f"real gpudebug collector source contracts: PASS mutations={len(validator_mutations)}")

runner = Path("ios/device-test/run-linear-hdr-proof-test.sh").read_text()
smoke = Path("ios/device-test/run-smoke-test.sh").read_text()
plist_validator = Path(
    "ios/device-test/validate-plist-contract.py"
).read_text()


def shell_without_comments(source: str) -> str:
    result: list[str] = []
    state = "code"
    escaped = False
    index = 0
    while index < len(source):
        character = source[index]
        if state == "comment":
            if character == "\n":
                state = "code"
                result.append(character)
            index += 1
            continue
        if escaped:
            result.append(character)
            escaped = False
            index += 1
            continue
        if state != "single" and character == "\\":
            result.append(character)
            escaped = True
        elif state == "code" and character == "'":
            state = "single"
            result.append(character)
        elif state == "single" and character == "'":
            state = "code"
            result.append(character)
        elif state == "code" and character == '"':
            state = "double"
            result.append(character)
        elif state == "double" and character == '"':
            state = "code"
            result.append(character)
        elif state == "code" and character == "#" and \
                (not result or result[-1].isspace() or result[-1] in ";|&()"):
            state = "comment"
        else:
            result.append(character)
        index += 1
    if state in ("single", "double"):
        raise ValueError("runner contains an unterminated quote")
    return "".join(result)


def runner_failure(candidate: str, arguments: list[str], expected: str) -> None:
    completed = subprocess.run(
        ["bash", "-s", "--", *arguments], input=candidate, text=True,
        capture_output=True, check=False,
        env={"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"],
             "TMPDIR": os.environ.get("TMPDIR", "/tmp")},
    )
    if completed.returncode == 0 or expected not in completed.stderr:
        raise ValueError(
            f"runner did not enforce {expected!r}: {completed.stderr[-400:]}")


def validate_plist_helper(candidate: str) -> None:
    try:
        compile(candidate, "validate-plist-contract.py", "exec")
    except SyntaxError as error:
        raise ValueError(f"plist helper grammar is invalid: {error}") from error
    code = compact(candidate)
    for literal in (
        "ifpayload.get(key)isnotTrue:",
        "ifkeyinpayload:",
        'raiseContractError(f"duplicateplistrequirement:{key}")',
        'raiseContractError(f"conflictingplistrequirement:{key}")',
        'raiseContractError(f"duplicateplistdictionarykey:{key}")',
        "ifraw.startswith(BOMS):",
        "metadata=os.lstat(path)",
        "ifnotstat.S_ISREG(metadata.st_mode):",
        '{hdr:"true",metal:True}',
        '{hdr:True,metal:"true"}',
        '"BOMduplicatekey"',
        '"symlinkplist"',
        'argument_parser().parse_args(["--unknown"])',
    ):
        if literal not in code:
            raise ValueError(f"universal plist helper contract missing: {literal}")
    completed = subprocess.run(
        ["python3", "-", "--self-test"], input=candidate, text=True,
        capture_output=True, check=False,
        env={"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"],
             "TMPDIR": os.environ.get("TMPDIR", "/tmp")},
    )
    if completed.returncode != 0 or completed.stdout != "SELF-TEST PASS\n" or \
            completed.stderr:
        raise ValueError(
            "universal plist helper self-test failed: "
            + completed.stderr[-400:]
        )


def validate_smoke_capture_hook(candidate: str) -> None:
    syntax = subprocess.run(
        ["bash", "-n"], input=candidate, text=True,
        capture_output=True, check=False)
    if syntax.returncode != 0:
        raise ValueError(f"smoke shell grammar is invalid: {syntax.stderr}")
    if len(candidate.splitlines()) > 5978:
        raise ValueError("smoke core exceeds the frozen 5978-line budget")
    active = shell_without_comments(candidate)
    active_code = "".join(active.split())
    declarations = "".join(active.split("\nfail() {", 1)[0].split())
    if "REQUIRE_PROGRAMMATIC_METAL_CAPTURE=0" not in declarations or \
            'PLIST_VALIDATOR="$ROOT/ios/device-test/validate-plist-contract.py"' \
            not in declarations:
        raise ValueError("smoke capture capability is not default OFF/universal")
    if "validate_programmatic_metal_capture_profile" in active_code or \
            "Print:MetalCaptureEnabled" in active_code:
        raise ValueError("smoke retains a scenario-local plist parser")
    for literal in (
        "--require-programmatic-metal-capture)",
        "REQUIRE_PROGRAMMATIC_METAL_CAPTURE=1",
    ):
        if literal not in active_code:
            raise ValueError(f"smoke capture hook missing: {literal}")
    mode_contract = (
        "CAPTURE_PLIST_REQUIREMENT=--require-absent"
        "if((REQUIRE_PROGRAMMATIC_METAL_CAPTURE!=0||"
        "REQUIRE_CLEAR_ONLY_PASS_SELF_TEST!=0||"
        "REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST!=0||"
        "REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST!=0));then"
        "CAPTURE_PLIST_REQUIREMENT=--require-true"
        "fi"
    )
    if active_code.count(mode_contract) != 1:
        raise ValueError("smoke capture requirement selection is not exact")
    helper_call = (
        'python3"$PLIST_VALIDATOR"--plist"$APP_INPUT/Info.plist"\\'
        '"$CAPTURE_PLIST_REQUIREMENT"MetalCaptureEnabled||fail\\'
        '"appprogrammaticMetalcaptureplistcontractfailed"'
    )
    if active_code.count(helper_call) != 1:
        raise ValueError("smoke universal plist helper call is not exact")


def validate_runner(candidate: str) -> None:
    syntax = subprocess.run(
        ["bash", "-n"], input=candidate, text=True,
        capture_output=True, check=False)
    if syntax.returncode != 0:
        raise ValueError(f"runner shell grammar is invalid: {syntax.stderr}")
    runner_code = "".join(shell_without_comments(candidate).split())
    for literal in (
        "--gpu-triple)",
        '[["$SAVE_SLOT"==4]]',
        'fail"--gpu-triplerejects--new-game"',
        "RendererIOSLinearHDRGPUTripleCapture",
        "RendererIOSHDRcaptureprofile:v=1mode=one-shot",
        'PLIST_VALIDATOR="$ROOT/ios/device-test/validate-plist-contract.py"',
        'python3"$GPU_VALIDATOR"--commit-capture-copy',
        '--expected-capture-kind"$DEVICE_CAPTURE_KIND"',
        'python3"$GPU_VALIDATOR"--collect',
        '[["$EVIDENCE_DIR"!="$WORK"&&"$EVIDENCE_DIR"!="$WORK/"*]]',
    ):
        if literal not in runner_code:
            raise ValueError(f"active runner contract missing: {literal}")
    if "PlistBuddy" in runner_code or "plistlib" in runner_code:
        raise ValueError("linear HDR runner retains a scenario-local plist parser")
    strict_gpu_plist = (
        'python3"$PLIST_VALIDATOR"--plist"$APP/Info.plist"\\'
        "--require-trueRendererIOSLinearHDRGPUTripleCapture\\"
        "--require-trueMetalCaptureEnabled||"
        'fail"--gpu-tripleapprequiresbothcapturekeysasexactCFBooleantrue"'
    )
    strict_producer_plist = (
        'python3"$PLIST_VALIDATOR"--plist"$APP/Info.plist"\\'
        "--require-absentRendererIOSLinearHDRGPUTripleCapture\\"
        "--require-absentMetalCaptureEnabled||"
        'fail"producer-onlyappcontainsacaptureplistkey"'
    )
    if runner_code.count(strict_gpu_plist) != 1 or \
            runner_code.count(strict_producer_plist) != 1:
        raise ValueError("linear HDR plist preflight is not exact")
    if runner_code.index(strict_gpu_plist) >= \
            runner_code.index('DEVICE_RECORD="$(select_device)"'):
        raise ValueError("strict capture plist validation follows device selection")
    smoke_capability = (
        "if((GPU_TRIPLE!=0));then"
        "SMOKE_ARGS+=(--require-programmatic-metal-capture)"
        "fi"
    )
    if runner_code.count(smoke_capability) != 1 or \
            runner_code.count("--require-programmatic-metal-capture") != 1:
        raise ValueError("gpu-triple smoke capture capability wiring is not exact")
    ordered(runner_code, (
        '[[-f"$CAPTURE_SUMMARY"&&!-L"$CAPTURE_SUMMARY"]]',
        'delete_exact_device_leaf"$CAPTURE_LEAF"',
        'capture_leaf_absent"$CAPTURE_LEAF"',
        'python3"$GPU_VALIDATOR"--collect',
        'cat"$GPU_RESULT"',
    ))
    for forbidden in (
        'rm-rf"$CAPTURE_STAGING"', 'rm-rf"$CAPTURE_STAGING_PARENT"',
        'unlink"$CAPTURE_STAGING"', 'rmdir"$CAPTURE_STAGING_PARENT"',
    ):
        if forbidden in runner_code:
            raise ValueError("runner deletes retained local capture staging")
    sha = "0123456789abcdef0123456789abcdef01234567"
    missing = "/definitely/not-an-opengothic-app"
    runner_failure(candidate,
                   ["--gpu-triple", "--save-slot", "5",
                    "--expected-sha", sha, missing],
                   "--gpu-triple requires exact save slot 4")
    runner_failure(candidate,
                   ["--gpu-triple", "--new-game",
                    "--expected-sha", sha, missing],
                   "--gpu-triple rejects --new-game")
    runner_failure(candidate,
                   ["--gpu-triple", "--gpu-triple",
                    "--expected-sha", sha, missing],
                   "duplicate --gpu-triple")


validate_plist_helper(plist_validator)
helper_mutations = (
    plist_validator.replace(
        "        if payload.get(key) is not True:\n",
        "        if not payload.get(key):\n", 1),
    plist_validator.replace(
        "        if key in payload:\n",
        "        if False:\n", 1),
    plist_validator.replace(
        "            if previous is not None:\n",
        "            if False:\n", 1),
    plist_validator.replace(
        "            if key in keys:\n",
        "            if False:\n", 1),
    plist_validator.replace(
        '                lambda: argument_parser().parse_args(["--unknown"]),\n',
        '                lambda: argument_parser().parse_args([]),\n', 1),
    plist_validator.replace(
        "        if raw.startswith(BOMS):\n",
        "        if False:\n", 1),
    plist_validator.replace(
        "        metadata = os.lstat(path)\n",
        "        metadata = os.stat(path)\n", 1),
    plist_validator.replace(
        "    if not stat.S_ISREG(metadata.st_mode):\n",
        "    if False:\n", 1),
)
for index, mutation in enumerate(helper_mutations, 1):
    if mutation == plist_validator:
        raise SystemExit(f"universal plist helper mutation is a no-op: {index}")
    try:
        validate_plist_helper(mutation)
    except ValueError:
        pass
    else:
        raise SystemExit(f"universal plist helper mutation survived: {index}")

validate_smoke_capture_hook(smoke)
smoke_helper_call = (
    'python3 "$PLIST_VALIDATOR" --plist "$APP_INPUT/Info.plist" \\\n'
    '  "$CAPTURE_PLIST_REQUIREMENT" MetalCaptureEnabled || fail \\\n'
    '  "app programmatic Metal capture plist contract failed"\n'
)
if smoke.count(smoke_helper_call) != 1:
    raise SystemExit("smoke universal plist helper active structure changed")
smoke_mutation = smoke.replace(
    smoke_helper_call,
    "true # universal plist helper call\n",
    1,
)
try:
    validate_smoke_capture_hook(smoke_mutation)
except ValueError:
    pass
else:
    raise SystemExit("comment-only smoke plist helper mutation survived")
smoke_default_mutation = smoke.replace(
    "CAPTURE_PLIST_REQUIREMENT=--require-absent\n",
    "CAPTURE_PLIST_REQUIREMENT=--require-true # default drift\n",
    1,
)
try:
    validate_smoke_capture_hook(smoke_default_mutation)
except ValueError:
    pass
else:
    raise SystemExit("smoke default capture mutation survived")

validate_runner(runner)
save_guard = '    [[ "$SAVE_SLOT" == 4 ]] || fail "--gpu-triple requires exact save slot 4"\n'
if runner.count(save_guard) != 1:
    raise SystemExit("save4 guard active structure changed")
runner_mutation = runner.replace(
    save_guard,
    '    true # [[ "$SAVE_SLOT" == 4 ]] || fail "--gpu-triple requires exact save slot 4"\n',
    1)
try:
    validate_runner(runner_mutation)
except ValueError:
    pass
else:
    raise SystemExit("comment-only save4 guard mutation survived")

smoke_capability_line = \
    '  SMOKE_ARGS+=(--require-programmatic-metal-capture)\n'
if runner.count(smoke_capability_line) != 1:
    raise SystemExit("gpu-triple smoke capability active structure changed")
gpu_plist_guard = (
    '    python3 "$PLIST_VALIDATOR" --plist "$APP/Info.plist" \\\n'
    '      --require-true RendererIOSLinearHDRGPUTripleCapture \\\n'
    '      --require-true MetalCaptureEnabled ||\n'
    '      fail "--gpu-triple app requires both capture keys as exact CFBoolean true"\n'
)
if runner.count(gpu_plist_guard) != 1:
    raise SystemExit("gpu-triple strict plist guard active structure changed")
runner_mutations = (
    runner.replace(
        gpu_plist_guard,
        gpu_plist_guard.replace(
            '      --require-true RendererIOSLinearHDRGPUTripleCapture \\\n'
            '      --require-true MetalCaptureEnabled ||\n',
            '      --require-true RendererIOSLinearHDRGPUTripleCapture ||\n',
            1,
        ),
        1),
    runner.replace(
        gpu_plist_guard,
        "    true # strict capture plist guard\n",
        1),
    runner.replace(
        smoke_capability_line,
        '  true # SMOKE_ARGS+=(--require-programmatic-metal-capture)\n',
        1),
    runner.replace(
        'if ((GPU_TRIPLE != 0)); then\n' + smoke_capability_line + 'fi\n',
        smoke_capability_line,
        1),
)
for index, mutation in enumerate(runner_mutations, 1):
    if mutation == runner:
        raise SystemExit(f"runner smoke capability mutation is a no-op: {index}")
    try:
        validate_runner(mutation)
    except ValueError:
        pass
    else:
        raise SystemExit(f"runner smoke capability mutation survived: {index}")

print("exact gpudebug triple source contracts: PASS mutations=15")
PY

printf '\n### P2.1e0 HDR producer source and mutation contracts\n'
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path
import re
import subprocess


IOS_SDK = subprocess.check_output(
    ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True
).strip()
PREPROCESS_CACHE: dict[tuple[str, str, bool], tuple[str, str]] = {}
EXPANDED_PREPROCESS_CACHE: dict[tuple[str, str, bool], str] = {}


def preprocess_active(
    source: str, language: str, diagnostics: bool
) -> tuple[str, str]:
    key = (source, language, diagnostics)
    cached = PREPROCESS_CACHE.get(key)
    if cached is not None:
        return cached
    command = [
        "xcrun", "clang++", "-E", "-fdirectives-only",
        "-x", language, "-std=c++20",
        "-target", "arm64-apple-ios16.4", "-isysroot", IOS_SDK,
        '-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="0123456789abcdef0123456789abcdef01234567"',
        "-Igame", "-Igame/graphics",
        "-isystem", "lib/Tempest/Engine/include",
        "-isystem", "lib/ZenKit/include",
        "-isystem", "lib/TinySoundFont",
        "-isystem", "lib/miniz",
        "-isystem", "lib/bullet3/src",
    ]
    if diagnostics:
        command.append("-DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS")
    command.append("-")
    completed = subprocess.run(
        command, input=source, text=True, capture_output=True, check=False
    )
    if completed.returncode != 0:
        raise ValueError(
            "AppleClang preprocessing failed: " + completed.stderr[-1000:]
        )
    active: list[str] = []
    current_file = ""
    for line in completed.stdout.splitlines():
        marker = re.match(r'^#\s+\d+\s+"([^"]+)"', line)
        if marker is not None:
            current_file = marker.group(1)
        elif current_file == "<stdin>":
            active.append(line)
    result = ("\n".join(active), completed.stdout)
    PREPROCESS_CACHE[key] = result
    return result


def preprocess_expanded(source: str, language: str, diagnostics: bool) -> str:
    key = (source, language, diagnostics)
    cached = EXPANDED_PREPROCESS_CACHE.get(key)
    if cached is not None:
        return cached
    command = [
        "xcrun", "clang++", "-E", "-P",
        "-x", language, "-std=c++20",
        "-target", "arm64-apple-ios16.4", "-isysroot", IOS_SDK,
        '-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="0123456789abcdef0123456789abcdef01234567"',
        "-Igame", "-Igame/graphics",
        "-isystem", "lib/Tempest/Engine/include",
        "-isystem", "lib/ZenKit/include",
        "-isystem", "lib/TinySoundFont",
        "-isystem", "lib/miniz",
        "-isystem", "lib/bullet3/src",
    ]
    if diagnostics:
        command.append("-DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS")
    command.append("-")
    completed = subprocess.run(
        command, input=source, text=True, capture_output=True, check=False
    )
    if completed.returncode != 0:
        raise ValueError(
            "AppleClang macro-expanded preprocessing failed: "
            + completed.stderr[-1000:]
        )
    EXPANDED_PREPROCESS_CACHE[key] = completed.stdout
    return completed.stdout


def sanitize_cpp(source: str) -> str:
    result = list(source)
    index = 0
    state = "code"
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if current == '"':
                state = "string"
            elif current == "'":
                state = "character"
            elif current == "/" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "line-comment"
            elif current == "/" and following == "*":
                result[index] = result[index + 1] = " "
                index += 1
                state = "block-comment"
        elif state == "string":
            if current == "\\":
                index += 1
            elif current == '"':
                state = "code"
        elif state == "character":
            if current == "\\":
                index += 1
            elif current == "'":
                state = "code"
        elif state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                result[index] = " "
        elif state == "block-comment":
            if current == "*" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "code"
            elif current != "\n":
                result[index] = " "
        index += 1
    if state == "block-comment":
        raise ValueError("unterminated block comment")
    return "".join(result)


def compact(source: str) -> str:
    return "".join(sanitize_cpp(source).split())


def function_scope(source: str, signature: str) -> str:
    sanitized = sanitize_cpp(source)
    start = sanitized.find(signature)
    if start < 0 or sanitized.find(signature, start + 1) >= 0:
        raise ValueError(f"function signature is not exact: {signature}")
    brace = sanitized.find("{", start + len(signature))
    if brace < 0:
        raise ValueError(f"function body missing: {signature}")
    depth = 0
    for index in range(brace, len(sanitized)):
        if sanitized[index] == "{":
            depth += 1
        elif sanitized[index] == "}":
            depth -= 1
            if depth == 0:
                return sanitized[start:index + 1]
    raise ValueError(f"function body unterminated: {signature}")


def require_once(source: str, literal: str) -> int:
    count = source.count(literal)
    if count != 1:
        raise ValueError(f"required literal count changed ({count}): {literal}")
    return source.index(literal)


def ordered(source: str, literals: tuple[str, ...]) -> None:
    positions = [require_once(source, literal) for literal in literals]
    if positions != sorted(positions):
        raise ValueError(f"required order changed: {literals}")


def validate(header: str, model: str, native: str, context: str) -> None:
    header_code = compact(header)
    model_code = compact(model)
    native_active, _ = preprocess_active(native, "objective-c++", True)
    context_active, context_on_full = preprocess_active(context, "c++", True)
    context_off_active, context_off_full = preprocess_active(
        context, "c++", False
    )
    native_expanded = preprocess_expanded(native, "objective-c++", True)
    context_on_expanded = preprocess_expanded(context, "c++", True)
    context_off_expanded = preprocess_expanded(context, "c++", False)
    native_code = compact(native_active)
    context_code = compact(context_active)
    context_off_code = compact(context_off_active)
    context_on_expanded_code = compact(context_on_expanded)
    context_off_expanded_code = compact(context_off_expanded)

    producer_header = "ioslinearhdrproofproducer.h"
    if producer_header not in context_on_full:
        raise ValueError("diagnostics ON preprocessing omitted producer header")
    if producer_header in context_off_full or "linearHDRProof" in context_off_code:
        raise ValueError("diagnostics OFF preprocessing retained producer code")
    require_once(
        context_on_expanded_code, "linearHDRProof->prepareFrame("
    )
    if "linearHDRProof" in context_off_expanded_code:
        raise ValueError(
            "diagnostics OFF macro-expanded preprocessing retained producer code"
        )

    expanded_arm = compact(function_scope(
        native_expanded, "  void arm() noexcept"))
    require_once(
        expanded_arm,
        "SecRandomCopyBytes(kSecRandomDefault,proofId.size(),proofId.data())",
    )

    for required in (
        "Disabled,Armed,Encoded,Submitted,Completed,Published,Failed,",
        "IOSLinearHDRProofFrame(constIOSLinearHDRProofFrame&)=delete;",
        "boolisSubmitted(constIOSLinearHDRProofFrame&frame)constnoexcept;",
    ):
        require_once(header_code, required)
    for required in (
        "if(state!=IOSLinearHDRProofProducerState::Disabled)returnfalse;",
        "if(state==IOSLinearHDRProofProducerState::Published||state==IOSLinearHDRProofProducerState::Failed)returnfalse;",
        "storeLe16(candidate,10u,static_cast<uint16_t>(IOSLinearHDRProofV1HeaderBytes));",
        "constexprcharLabelPrefix[]=\"RendererIOS.SceneHDR.\";",
    ):
        require_once(model_code, required)

    for required in (
        "SecRandomCopyBytes(kSecRandomDefault,proofId.size(),proofId.data())",
        "std::string(\"RendererIOS.SceneHDR.\")+identityText.data()",
        "std::string(\"RendererIOS.HDRProofCopy.\")+identityText.data()",
        "std::string(\"RendererIOS.ToneResolve.\")+identityText.data()",
        "tempLeaf.size()!=69u",
        "removeRegularIfPresent(directory,FinalLeaf)",
        "removeRegularIfPresent(directory,tempLeaf.c_str())",
        "owner.ssbo(Tempest::BufferHeap::Upload,Tempest::Uninitialized,static_cast<size_t>(logical))",
        "mapped=nativeBuffer.contents",
        "nativeBuffer.storageMode==MTLStorageModeShared",
        "mapped!=nullptr&&nativeBuffer.length>=NSUInteger(logical)",
        "(id<MTLTexture>)(void*)borrowed.get()!=frame.impl->source",
        "encoder.copy(source,0u,frame.impl->buffer,0u);",
        "O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC",
        "~Impl(){[sourcerelease];}",
    ):
        require_once(native_code, required)
    for forbidden in (
        "readBytes(", "withActiveCommandBuffer(", "arc4random",
        "random_device", "glob(",
    ):
        if forbidden in native_code:
            raise ValueError(f"forbidden producer operation: {forbidden}")
    if "[frame.impl->sourcerelease];" in native_code:
        raise ValueError("source lease is released before terminal owner release")
    if native_code.count("openat(directory,tempLeaf.c_str(),") != 1:
        raise ValueError("artifact open escaped terminal publication")
    if native_code.count(
            "std::span<conststd::byte>(frame.impl->mapped,") != 1:
        raise ValueError("mapped payload read escaped terminal completion")

    publication = compact(function_scope(
        native_active, "  void publish(const IOSLinearHDRProofMetadata& metadata,"))
    ordered(publication, (
        "iosParseLinearHDRProofV1(artifact,parsed)",
        "iosScanLinearHDRProofV1(parsed,scan)",
        "openat(directory,tempLeaf.c_str(),",
        "writeAll(file,artifact)",
        "fsync(file)",
        "constintcloseResult=close(file);",
        "renameatx_np(directory,tempLeaf.c_str(),directory,FinalLeaf,RENAME_EXCL)",
        "fsync(directory)",
        "IOSLinearHDRProofProducerEvent::Publish",
        "Tempest::Log::i(line.data())",
    ))
    terminal = compact(function_scope(
        native_active, "void IOSLinearHDRProofProducer::completeAfterTerminal("))
    ordered(terminal, (
        "frame.impl->presentFailure",
        "metadata.targetGeneration!=currentTargetGeneration",
        "IOSLinearHDRProofProducerEvent::Complete",
        "impl->publish(",
    ))

    submit = compact(function_scope(
        context_active,
        "IOSMetalContext::SubmitResult IOSMetalContext::submitFrame("))
    ordered(submit, (
        "linearHDRProof->prepareFrame(",
        "linearHDRProof->sceneMarker()",
        "impl->gpuScene->encode(",
        "advanceLinearHDR(IOSLinearHDRFrameEvent::SceneHDR);",
        "linearHDRProof->copyMarker()",
        "linearHDRProof->encodeCopy(",
        "linearHDRProof->toneResolveMarker()",
        "impl->linearHDRMetal->encodeToneResolve(",
        "impl->device.submit(command);",
        "impl->linearHDRProof->markSubmitted(frameContext.linearHDRProof);",
        "frameContext.fence=std::move(submittedFence);",
    ))
    frame = compact(function_scope(
        context_active, "  struct FrameContext final"))
    ordered(frame, (
        "IOSLinearHDRProofFramelinearHDRProof;",
        "CommandBuffercommand;",
        "Fencefence;",
    ))
    mailbox = compact(function_scope(
        context_active,
        "bool takePresentFailureAndLatchProof(const char* operation)"))
    require_once(mailbox, "device.takePresentFailure();")
    ordered(mailbox, (
        "device.takePresentFailure();",
        "linearHDRProof->latchPresentFailure(frame.linearHDRProof);",
        "if(failed)returnfalse;",
    ))
    if context_code.count("device.takePresentFailure()") != 1:
        raise ValueError("raw present mailbox consumer escaped wrapper")
    settle = compact(function_scope(
        context_active,
        "bool settleGpu(SettleReason reason, const char* operation,"))
    ordered(settle, (
        "frame.fence.wait(0)",
        "takePresentFailureAndLatchProof(",
        "materializeLinearHDRProofAfterTerminal(frames[index],true)",
        "neutralizeFences()",
        "releaseLinearHDRProofFramesAfterTerminal()",
        "releaseSceneFrames()",
    ))
    idle_failure = "markLinearHDRProofIdleFailure();"
    if settle.count(idle_failure) != 3:
        raise ValueError("idle-unconfirmed failure coverage changed")
    search_from = 0
    for _ in range(3):
        failure_at = settle.index(idle_failure, search_from)
        return_at = settle.index("returnfalse;", failure_at)
        failure_path = settle[failure_at:return_at]
        if "forcePreviewPlaceholder();" not in failure_path:
            raise ValueError("idle-unconfirmed path lost placeholder transition")
        if ("neutralizeFences()" in failure_path or
                "releaseLinearHDRProofFramesAfterTerminal()" in failure_path):
            raise ValueError("idle-unconfirmed path releases proof owners")
        search_from = failure_at + len(idle_failure)


paths = {
    "header": Path("game/graphics/ioslinearhdrproofproducer.h").read_text(),
    "model": Path("game/graphics/ioslinearhdrproofproducer.cpp").read_text(),
    "native": Path("game/graphics/ioslinearhdrproofproducer.mm").read_text(),
    "context": Path("game/graphics/iosmetalcontext.cpp").read_text(),
}
validate(paths["header"], paths["model"], paths["native"], paths["context"])


def mutated(key: str, old: str, new: str) -> dict[str, str]:
    if paths[key].count(old) != 1:
        raise SystemExit(f"mutation anchor count changed: {key}: {old!r}")
    result = dict(paths)
    result[key] = result[key].replace(old, new, 1)
    return result


copy_block = """          if(!impl->linearHDRProof->encodeCopy(
               frameContext.linearHDRProof,encoder,
               impl->linearHDRTargets.color))
            throw std::runtime_error(
              \"RendererIOS HDR proof copy encode failed\");
"""
resolve_block = """        const IOSLinearHDRMetalEncodeResult resolve =
            impl->linearHDRMetal->encodeToneResolve(
              encoder,impl->linearHDRTargets.color,constants);
"""
if paths["context"].count(copy_block) != 1 or \
   paths["context"].count(resolve_block) != 1:
    raise SystemExit("copy-after-resolve mutation anchors changed")
copy_after_resolve = dict(paths)
copy_after_resolve["context"] = paths["context"].replace(copy_block, "", 1)
copy_after_resolve["context"] = copy_after_resolve["context"].replace(
    resolve_block, resolve_block + copy_block, 1)


mutations = (
    mutated("context", '#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n#include "ioslinearhdrproofproducer.h"\n#endif', '#include "ioslinearhdrproofproducer.h"'),
    mutated("native", "SecRandomCopyBytes(\n        kSecRandomDefault,proofId.size(),proofId.data())", "std::memset(proofId.data(),1,proofId.size())"),
    mutated(
        "native",
        "    const int randomStatus = SecRandomCopyBytes(\n"
        "        kSecRandomDefault,proofId.size(),proofId.data());\n",
        "#if 0\n"
        "    const int randomStatus = SecRandomCopyBytes(\n"
        "        kSecRandomDefault,proofId.size(),proofId.data());\n"
        "#else\n"
        "    std::memset(proofId.data(),1,proofId.size());\n"
        "    const int randomStatus = errSecSuccess;\n"
        "#endif\n",
    ),
    mutated(
        "native",
        "    const int randomStatus = SecRandomCopyBytes(\n"
        "        kSecRandomDefault,proofId.size(),proofId.data());\n",
        "#define SecRandomCopyBytes(...) \\\n"
        "  (std::memset(proofId.data(),1,proofId.size()),errSecSuccess)\n"
        "    const int randomStatus = SecRandomCopyBytes(\n"
        "        kSecRandomDefault,proofId.size(),proofId.data());\n",
    ),
    mutated("native", "SecRandomCopyBytes(\n        kSecRandomDefault,proofId.size(),proofId.data())", "arc4random_buf(proofId.data(),proofId.size())"),
    mutated("native", "RendererIOS.SceneHDR.", "RendererIOS.SceneLDR."),
    mutated("model", "storeLe16(candidate,10u,\n              static_cast<uint16_t>(IOSLinearHDRProofV1HeaderBytes));", "storeLe16(candidate,10u,128u);"),
    copy_after_resolve,
    mutated("native", "encoder.copy(source,0u,frame.impl->buffer,0u);", "encoder.copy(source,1u,frame.impl->buffer,0u);"),
    mutated("native", "(id<MTLTexture>)(void*)borrowed.get()!=frame.impl->source", "false"),
    mutated("native", "Tempest::BufferHeap::Upload,Tempest::Uninitialized", "Tempest::BufferHeap::Device,Tempest::Uninitialized"),
    mutated("native", "    frame.impl->encoded = true;\n", "    frame.impl->encoded = true;\n    publish(frame.impl->metadata,std::span<const std::byte>(frame.impl->mapped,static_cast<size_t>(frame.impl->metadata.logicalBytes)));\n"),
    mutated("native", "    frame.impl->encoded = true;\n", "    frame.impl->encoded = true;\n    [frame.impl->source release];\n"),
    mutated("native", "    frame.impl->encoded = true;\n", "    frame.impl->encoded = true;\n    (void)openat(directory,tempLeaf.c_str(),O_WRONLY);\n"),
    mutated("native", "IOSLinearHDRProofProducerEvent::Complete", "IOSLinearHDRProofProducerEvent::Submit"),
    mutated("native", "if(fsync(file)!=0)", "if(false)"),
    mutated("native", "if(fsync(directory)!=0)", "if(false)"),
    mutated("native", "if(renameatx_np(directory,tempLeaf.c_str(),directory,FinalLeaf,\n                    RENAME_EXCL)!=0)", "if(false)"),
    mutated("context", "linearHDRProof->latchPresentFailure(frame.linearHDRProof);", "(void)frame;"),
    mutated("context", "IOSLinearHDRProofFrame     linearHDRProof;", "// IOSLinearHDRProofFrame linearHDRProof;"),
    mutated("model", "if(state!=IOSLinearHDRProofProducerState::Disabled)\n        return false;", "if(state==IOSLinearHDRProofProducerState::Armed)\n        return true;"),
)
for index, values in enumerate(mutations, start=1):
    try:
        validate(values["header"], values["model"], values["native"], values["context"])
    except ValueError:
        pass
    else:
        raise SystemExit(f"P2.1e0 HDR producer mutation survived: {index}")

# A comment cannot repair an active-code RNG contract.
comment_only = dict(paths)
comment_only["native"] = comment_only["native"].replace(
    "    const int randomStatus = SecRandomCopyBytes(\n",
    "    // const int randomStatus = SecRandomCopyBytes(\n",
    1,
)
try:
    validate(comment_only["header"], comment_only["model"],
             comment_only["native"], comment_only["context"])
except ValueError:
    pass
else:
    raise SystemExit("P2.1e0 HDR producer comment-only mutation survived")

print(f"HDR producer mutations killed: {len(mutations) + 1}")
PY

printf '\n### P2.1e0 production integration and mutation oracle\n'
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path


def sanitize_cpp(source: str) -> str:
    """Blank comments while preserving code, strings and source offsets."""
    result = list(source)
    index = 0
    state = "code"
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if current == '"':
                state = "string"
            elif current == "'":
                state = "character"
            elif current == "/" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "line-comment"
            elif current == "/" and following == "*":
                result[index] = result[index + 1] = " "
                index += 1
                state = "block-comment"
        elif state == "string":
            if current == "\\":
                index += 1
            elif current == '"':
                state = "code"
        elif state == "character":
            if current == "\\":
                index += 1
            elif current == "'":
                state = "code"
        elif state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                result[index] = " "
        elif state == "block-comment":
            if current == "*" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "code"
            elif current != "\n":
                result[index] = " "
        index += 1
    if state == "block-comment":
        raise ValueError("unterminated block comment")
    return "".join(result)


def compact(source: str) -> str:
    return "".join(sanitize_cpp(source).split())


def function_scope(source: str, signature: str) -> str:
    sanitized = sanitize_cpp(source)
    start = sanitized.find(signature)
    if start < 0 or sanitized.find(signature, start + 1) >= 0:
        raise ValueError(f"function signature is not exact: {signature}")
    brace = sanitized.find("{", start + len(signature))
    if brace < 0:
        raise ValueError(f"function body missing: {signature}")
    depth = 0
    for index in range(brace, len(sanitized)):
        if sanitized[index] == "{":
            depth += 1
        elif sanitized[index] == "}":
            depth -= 1
            if depth == 0:
                return sanitized[start:index + 1]
    raise ValueError(f"function body unterminated: {signature}")


def require_once(source: str, literal: str, label: str) -> int:
    count = source.count(literal)
    if count != 1:
        raise ValueError(f"{label} count changed: {count}")
    return source.index(literal)


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError(f"mutation anchor count changed: {old!r}")
    return source.replace(old, new, 1)


def validate(renderer: str, context: str, native: str) -> None:
    renderer_code = compact(renderer)
    context_code = compact(context)
    settings_call = (
        'context.updateLinearHDRSettings('
        'Gothic::settingsGetF("VIDEO","zVidBrightness"),'
        'Gothic::settingsGetF("VIDEO","zVidContrast"),'
        'Gothic::settingsGetF("VIDEO","zVidGamma"));'
    )
    constructor_order = (
        "Gothic::inst().onSettingsChanged.bind(this,&Impl::setupSettings);",
        "setupSettings();",
    )
    positions = [require_once(renderer_code, value, value)
                 for value in constructor_order]
    if positions != sorted(positions):
        raise ValueError("settings bind/initial refresh order changed")
    require_once(
        renderer_code,
        "Gothic::inst().onSettingsChanged.ubind(this,&Impl::setupSettings);",
        "settings unbind",
    )
    require_once(renderer_code, settings_call, "atomic settings triplet")

    submit = compact(function_scope(
        context,
        "IOSMetalContext::SubmitResult IOSMetalContext::submitFrame("))
    ordered = (
        "constboollinearHDRSceneActive=sceneVisible&&",
        "encoder.setFramebuffer({{impl->linearHDRTargets.color,"
        "Tempest::Vec4(0.f),Tempest::Preserve}},"
        "{impl->linearHDRTargets.depth,1.f,Tempest::Discard});",
        "impl->gpuScene->encode(",
        "constIOSToneResolveConstantsconstants={tone.brightness,"
        "tone.contrast,tone.gamma,tone.exposure,};",
        "encoder.setFramebuffer({});"
        "advanceLinearHDR(IOSLinearHDRFrameEvent::SceneHDR);",
        "encoder.setFramebuffer({{drawable,Tempest::Discard,"
        "Tempest::Preserve}});",
        "impl->linearHDRMetal->encodeToneResolve(",
        "encoder.setFramebuffer({});"
        "advanceLinearHDR(IOSLinearHDRFrameEvent::ToneResolve);",
        'encoder.setDebugMarker("RendererIOSUIovertoneresolve");'
        "encoder.setFramebuffer({{drawable,Tempest::Preserve,"
        "Tempest::Preserve}});",
        "advanceLinearHDR(IOSLinearHDRFrameEvent::LdrOverlay,true);",
        "frameContext.uiMesh.draw(encoder);",
        "impl->device.submit(command);",
        "impl->device.present(impl->swapchain);",
        "IOSLinearHDRFrameEvent::Present,",
    )
    positions = [require_once(submit, value, value) for value in ordered]
    if positions != sorted(positions):
        raise ValueError("scene/resolve/overlay/present order changed")
    if submit.count("impl->gpuScene->encode(") != 1:
        raise ValueError("native scene encode count changed")
    if submit.count("impl->linearHDRMetal->encodeToneResolve(") != 1:
        raise ValueError("tone resolve encode count changed")
    if submit.count("frameContext.uiMesh.draw(encoder);") != 1:
        raise ValueError("2D UI draw count changed")

    if context_code.count("iosLinearHDRCommitProvenEvidence(") != 2:
        raise ValueError("OFF/ON Proven commit coverage changed")
    if context_code.count("markLinearHDRTerminalFailed(frame);") != 2:
        raise ValueError("terminal failure publication coverage changed")
    begin_frame = compact(function_scope(
        context,
        "std::optional<IOSMetalContext::FrameLease> "
        "IOSMetalContext::beginFrame()"))
    begin_order = (
        "frameContext.fence.wait(0)",
        "impl->materializeLinearHDREvidenceAfterTerminal(frameContext)",
    )
    begin_positions = [require_once(begin_frame, value, value)
                       for value in begin_order]
    if begin_positions != sorted(begin_positions):
        raise ValueError("frame fence/evidence order changed")
    settle = compact(function_scope(
        context,
        "bool settleGpu(SettleReason reason, const char* operation,"))
    settle_order = (
        "frame.fence.wait(0)",
        "takePresentFailureAndLatchProof(",
        "materializeLinearHDRProofAfterTerminal(frames[index],true)",
        "materializeLinearHDREvidenceAfterTerminal(frame,true)",
        "neutralizeFences()",
    )
    settle_positions = [require_once(settle, value, value)
                        for value in settle_order]
    if settle_positions != sorted(settle_positions):
        raise ValueError("lifecycle fence/evidence/mailbox order changed")
    materialize = compact(function_scope(
        context,
        "bool materializeLinearHDREvidenceAfterTerminal("))
    diagnostic_wait = require_once(
        materialize,
        "if(!deviceAlreadyIdle){try{device.waitIdle();}",
        "diagnostic terminal waitIdle",
    )
    diagnostic_mailbox = require_once(
        materialize,
        'takePresentFailureAndLatchProof('
        '"RendererIOSlinearHDRterminalpresentfailed")',
        "diagnostic terminal mailbox",
    )
    diagnostic_commit = materialize.rfind(
        "iosLinearHDRCommitProvenEvidence(")
    marker = require_once(
        materialize,
        'Log::i("RendererIOSlinearHDR:v=1b=",',
        "diagnostic terminal marker",
    )
    if not (diagnostic_wait < diagnostic_mailbox < diagnostic_commit < marker):
        raise ValueError("diagnostic wait/mailbox/Proven/marker order changed")

    native_code = compact(native)
    if native_code.count("@try{") != 2 or \
       native_code.count("@catch(NSException*exception)") != 2:
        raise ValueError("probe and pipeline Objective-C exception scopes merged")
    native_order = (
        "descriptor.usage=MTLTextureUsageRenderTarget|"
        "MTLTextureUsageShaderRead;",
        "[devicenewTextureWithDescriptor:descriptor];",
        "probeResult=IOSLinearHDRProbeResult::success();",
        "[texturerelease];",
        "[devicenewLibraryWithURL:libraryUrlerror:&libraryError]",
    )
    native_positions = [require_once(native_code, value, value)
                        for value in native_order]
    if native_positions != sorted(native_positions):
        raise ValueError("one-shot probe lifetime/order changed")
    for required in (
        "for(id<MTLBinding>bindinginreflection.vertexBindings){"
        "if(binding.used)returnfalse;}",
        "if(binding.index!=NSUInteger(0u)||!binding.argument)returnfalse;",
        "descriptor.colorAttachments[0].pixelFormat="
        "MTLPixelFormatBGRA8Unorm;",
        "descriptor.colorAttachments[0].blendingEnabled=NO;",
        "descriptor.depthAttachmentPixelFormat=MTLPixelFormatInvalid;",
        "descriptor.rasterSampleCount=1u;",
        "Tempest::MetalApi::withActiveRenderEncoder(",
    ):
        require_once(native_code, required, required)
    for forbidden in (
        "newLibraryWithSource",
        "MTLCompileOptions",
        "newCommandQueue",
        "commandBufferWith",
        "presentDrawable",
    ):
        if forbidden in native_code:
            raise ValueError(f"native bridge owns forbidden operation: {forbidden}")


renderer_path = Path("game/graphics/rendererios.cpp")
context_path = Path("game/graphics/iosmetalcontext.cpp")
native_path = Path("game/graphics/ioslinearhdrmetal.mm")
renderer = renderer_path.read_text()
context = context_path.read_text()
native = native_path.read_text()
validate(renderer, context, native)

mutations = []
mutations.append((
    "missing-initial-settings-refresh",
    replace_once(renderer, "    setupSettings();\n", "    (void)0;\n"),
    context,
    native,
))
mutations.append((
    "partial-settings-triplet",
    replace_once(
        renderer,
        'Gothic::settingsGetF("VIDEO","zVidGamma")',
        'Gothic::settingsGetF("VIDEO","zVidContrast")'),
    context,
    native,
))
mutations.append((
    "missing-settings-unbind",
    replace_once(renderer, ".onSettingsChanged.ubind(",
                 ".onSettingsChanged.bind("),
    context,
    native,
))
mutations.append((
    "direct-drawable-scene",
    renderer,
    replace_once(
        context,
        "{{impl->linearHDRTargets.color,Tempest::Vec4(0.f),Tempest::Preserve}},",
        "{{drawable,Tempest::Vec4(0.f),Tempest::Preserve}},"),
    native,
))
ui_draw = "      frameContext.uiMesh.draw(encoder);\n"
tone_event = (
    "        advanceLinearHDR(IOSLinearHDRFrameEvent::ToneResolve);\n"
)
ui_before_resolve = replace_once(context, ui_draw, "")
ui_before_resolve = replace_once(
    ui_before_resolve, tone_event, ui_draw + tone_event)
mutations.append((
    "ui-before-resolve",
    renderer,
    ui_before_resolve,
    native,
))

killed = 0
for name, mutated_renderer, mutated_context, mutated_native in mutations:
    try:
        validate(mutated_renderer, mutated_context, mutated_native)
    except ValueError:
        killed += 1
    else:
        raise SystemExit(f"P2.1e0 mutation survived: {name}")
if killed != len(mutations):
    raise SystemExit("P2.1e0 mutation count changed")

# A comment must never satisfy an active-code source contract.
comment_only = renderer.replace(
    "    setupSettings();\n",
    "    // setupSettings();\n",
    1,
)
try:
    validate(comment_only, context, native)
except ValueError:
    pass
else:
    raise SystemExit("P2.1e0 comment-only settings mutation survived")

print(f"RendererIOS linear-HDR integration mutations killed: {killed + 1}")
PY
