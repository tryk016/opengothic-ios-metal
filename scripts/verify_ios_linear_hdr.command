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

cd "$REPO"

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
bash -n ios/device-test/run-linear-hdr-proof-test.sh
[[ "$(ios/device-test/run-linear-hdr-proof-test.sh --self-test)" == \
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
    'require_afc_regular_leaf "$FINAL_LEAF" ||',
    '"$UVX" --python python3.11 pymobiledevice3 apps rm',
    '--udid "$DEVICE_UDID" --documents "$BUNDLE_ID" "$leaf"',
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
    for forbidden in ("--remove-existing-content", "GPU PASS"):
        if forbidden in candidate:
            raise ValueError(f"guarded producer runner contains forbidden text: {forbidden}")
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
