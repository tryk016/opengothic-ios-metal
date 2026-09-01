#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${GITHUB_SHA:?GITHUB_SHA must be set}"

export CLEAR_ONLY_PASS_SELF_TEST=OFF
export TILE_SELF_TEST=OFF
export FORWARD_SELF_TEST=OFF
export REQUESTED_FAULT=none
export REQUESTED_BINK_SELF_TEST=OFF
export REQUESTED_RESOURCE_ALLOCATOR_SELF_TEST=OFF
export REQUESTED_CLEAR_ONLY_PASS_SELF_TEST=OFF
export REQUESTED_SHADING_PROTOTYPE_TILE_SELF_TEST=OFF
export REQUESTED_SHADING_PROTOTYPE_FORWARD_SELF_TEST=OFF

bash ios/patches/apply-patches.sh

printf '\n### CI contract: Verify P2.5a shading prototype plan contract\n'
set -euo pipefail

prototype_files=(
  game/graphics/iosshadingprototypeplan.h
  game/graphics/iosshadingprototypeplan.cpp
  ios/tests/iosshadingprototypeplan.cpp
)
for file in "${prototype_files[@]}"; do
  test -f "$file"
done

python3 - <<'PY'
from pathlib import Path

source = Path(
    "game/graphics/iosshadingprototypeplan.cpp"
).read_text()
include = '#include "iosshadingprototypeshaderabi.h"'
byte_size = (
    "RendererIOSShadingPrototypeShader::"
    "ForwardLightListByteSize"
)
if source.count(include) != 1:
    raise SystemExit(
        "P2.5c1a shader ABI include is not exact"
    )
if source.count(byte_size) != 1:
    raise SystemExit(
        "P2.5c1a light-list byte-size use is not exact"
    )
residual = source.replace(include, "").replace(byte_size, "")
if (
    "iosshadingprototypeshaderabi" in residual
    or "RendererIOS" in residual
):
    raise SystemExit(
        "P2.5c1a plan escaped its exact shader ABI allowlist"
    )
PY

if grep -nEi \
    '#import|<Metal/|Objective-C|Tempest|IOSMetalContext|RendererIOS|MTL[A-Z]|CAMetalLayer|newCommandQueue|newCommandBuffer|nextDrawable|presentDrawable|waitIdle|MetalFX|runtime[ -]shader|supportsFamily|supportsTextureSampleCount|MTLHeap|newHeap|sizeAndAlign|makeAliasable|NativeHandle|void[[:space:]]*\*' \
    game/graphics/iosshadingprototypeplan.h \
    ios/tests/iosshadingprototypeplan.cpp; then
  echo 'P2.5a host-neutral contract leaks runtime or native policy'
  exit 1
fi
if sed \
    -e '/^#include "iosshadingprototypeshaderabi.h"$/d' \
    -e 's/RendererIOSShadingPrototypeShader::ForwardLightListByteSize//g' \
    game/graphics/iosshadingprototypeplan.cpp |
    grep -nEi \
      '#import|<Metal/|Objective-C|Tempest|IOSMetalContext|RendererIOS|MTL[A-Z]|CAMetalLayer|newCommandQueue|newCommandBuffer|nextDrawable|presentDrawable|waitIdle|MetalFX|runtime[ -]shader|supportsFamily|supportsTextureSampleCount|MTLHeap|newHeap|sizeAndAlign|makeAliasable|NativeHandle|void[[:space:]]*\*'; then
  echo 'P2.5c1a plan escaped its exact neutral ABI allowlist'
  exit 1
fi
if grep -nE \
    '(^|[^[:alnum:]_])((char|short|int|long|float|double|bool|auto|uint(8|16|32|64)_t|IOS[A-Za-z0-9_:<>]+)[[:space:]]*\*|nullptr|reinterpret_cast)' \
    "${prototype_files[@]}"; then
  echo 'P2.5a host-neutral contract contains a pointer'
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
import re
import runpy

frame = Path("game/graphics/iosframeplan.h").read_text()
header = Path(
    "game/graphics/iosshadingprototypeplan.h"
).read_text()
source = Path(
    "game/graphics/iosshadingprototypeplan.cpp"
).read_text()
shader_abi = Path(
    "game/graphics/iosshadingprototypeshaderabi.h"
).read_text()
test = Path(
    "ios/tests/iosshadingprototypeplan.cpp"
).read_text()
cmake = Path("CMakeLists.txt").read_text()

frozen = (
    (frame, r"\bIOSFramePlanABIVersion\s*=\s*4u\s*;", 1),
    (header, r"\bIOSShadingPrototypePlanABIVersion\s*=\s*1u\s*;", 1),
    (header, r"\bIOSShadingPrototypeNoPass\s*=\s*0xffffffffu\s*;", 1),
    (header, r"\bTileDeferred\s*=\s*0\s*,", 1),
    (header, r"\bForwardPlus\s*=\s*1\s*,", 1),
    (header, r"\bBuildLightList\s*=\s*0\s*,", 1),
    (header, r"\bDrawOpaque\s*=\s*1\s*,", 1),
    (header, r"\bDrawAlphaTest\s*=\s*2\s*,", 1),
    (header, r"\bDispatchTileLighting\s*=\s*3\s*,", 1),
    (header, r"\bUnsupportedKind\s*=\s*1\s*,", 1),
    (header, r"\bInvalidFramePlan\s*=\s*2\s*,", 1),
    (header, r"\bCommonContractMismatch\s*=\s*3\s*,", 1),
    (header, r"\bRuntimeContractMismatch\s*=\s*4\s*,", 1),
    (header, r"\bTopologyMismatch\s*=\s*5\s*,", 1),
    (header, r"\bFramePlanMismatch\s*=\s*6\s*,", 1),
    (header, r"\bSupported\s*=\s*0\s*,", 1),
    (header, r"\bInvalid\s*=\s*1\s*,", 1),
    (header, r"\bUnsupported\s*=\s*2\s*,", 1),
    (
        source,
        r"\bRendererIOSShadingPrototypeShader::"
        r"ForwardLightListByteSize\b",
        1,
    ),
    (
        shader_abi,
        r"\bForwardLightListWordBytes\s*=\s*4u\s*;",
        1,
    ),
    (
        shader_abi,
        r"\bForwardLightListWordCount\s*=\s*64u\s*;",
        1,
    ),
    (
        shader_abi,
        r"\bForwardLightListSentinel\s*=\s*0xA5A5A5A5u\s*;",
        1,
    ),
    (test, r"\bmutationCount\s*!=\s*214u", 1),
)
for contents, pattern, expected in frozen:
    count = len(re.findall(pattern, contents))
    if count != expected:
        raise SystemExit(
            f"P2.5a frozen numeric oracle mismatch: {pattern}: {count}"
        )

exclusion = (
    '"${CMAKE_CURRENT_SOURCE_DIR}/game/graphics/'
    'iosshadingprototypeplan.cpp"'
)
remove_block = cmake.split(
    "list(REMOVE_ITEM OPENGOTHIC_SOURCES", 1
)[1].split(")", 1)[0]
if remove_block.count(exclusion) != 1:
    raise SystemExit(
        "P2.5a source is not excluded exactly once from the target"
    )
if remove_block.index(
    '"${CMAKE_CURRENT_SOURCE_DIR}/game/graphics/renderer.cpp"'
) > remove_block.index(exclusion):
    raise SystemExit("P2.5a source exclusion moved before renderer.cpp")

common_defaults = (
    "opaqueGeometryInputs = 1u;",
    "alphaTestGeometryInputs = 1u;",
    "lightInputs = 1u;",
    "presentFormat = IOSPixelFormat::Bgra8Unorm;",
    "outputFormat = IOSPixelFormat::Rgba8Unorm;",
    "outputExtent = {4u,4u};",
    "outputMipLevels = 1u;",
    "outputSampleCount = 1u;",
)
for declaration in common_defaults:
    if header.count(declaration) != 1:
        raise SystemExit(
            f"P2.5a common IO oracle is missing: {declaration}"
        )

runtime_defaults = (
    "borrowedExistingDevice = 1u;",
    "borrowedExistingQueue = 1u;",
    "borrowedVirginCommandBuffer = 1u;",
    "contextOwnsFence = 1u;",
    "createsDevice = 0u;",
    "createsQueue = 0u;",
    "createsCommandBuffer = 0u;",
    "commits = 0u;",
    "waits = 0u;",
    "drawableAcquisitions = 0u;",
    "presents = 0u;",
)
runtime_header = header.split(
    "struct IOSShadingPrototypeRuntimeContract final {", 1
)[1].split("enum class IOSShadingPrototypeOperation", 1)[0]
for declaration in runtime_defaults:
    if runtime_header.count(declaration) != 1:
        raise SystemExit(
            f"P2.5a runtime ownership oracle is missing: {declaration}"
        )

def topology_numbers(function, following):
    body = source.split(function, 1)[1].split(following, 1)[0]
    return [int(value) for value in re.findall(r"\b(\d+)u\b", body)]

if topology_numbers(
    "IOSShadingPrototypeTopology tileTopology() noexcept {",
    "IOSShadingPrototypeTopology forwardTopology() noexcept {",
) != [1, 1, 1, 2, 1, 0, 0, 0, 3]:
    raise SystemExit("P2.5a TileDeferred topology changed")
if topology_numbers(
    "IOSShadingPrototypeTopology forwardTopology() noexcept {",
    "IOSFramePlan tileFramePlan() {",
) != [1, 1, 1, 2, 0, 1, 0, 0, 3]:
    raise SystemExit("P2.5a ForwardPlus topology changed")

schedules = (
    (
        source.split(
            "IOSShadingPrototypeTopology tileTopology() noexcept {",
            1,
        )[1].split(
            "IOSShadingPrototypeTopology forwardTopology() noexcept {",
            1,
        )[0],
        (
            "IOSShadingPrototypeOperation::DrawOpaque",
            "IOSShadingPrototypeOperation::DrawAlphaTest",
            "IOSShadingPrototypeOperation::DispatchTileLighting",
        ),
    ),
    (
        source.split(
            "IOSShadingPrototypeTopology forwardTopology() noexcept {",
            1,
        )[1].split("IOSFramePlan tileFramePlan() {", 1)[0],
        (
            "IOSShadingPrototypeOperation::BuildLightList",
            "IOSShadingPrototypeOperation::DrawOpaque",
            "IOSShadingPrototypeOperation::DrawAlphaTest",
        ),
    ),
)
for body, expected in schedules:
    positions = [body.index(operation) for operation in expected]
    if positions != sorted(positions):
        raise SystemExit("P2.5a operation schedule changed order")
    if any(body.count(operation) != 1 for operation in expected):
        raise SystemExit("P2.5a operation schedule is not exact")

layout_asserts = (
    "sizeof(IOSShadingPrototypeOperation)==1u",
    "sizeof(IOSShadingPrototypeCommonContract)==32u",
    "sizeof(IOSShadingPrototypeRuntimeContract)==44u",
    "sizeof(IOSShadingPrototypeTopology)==40u",
    "sizeof(IOSShadingPrototypePlanValidation)==16u",
    "sizeof(IOSShadingPrototypePlanSelection)==28u",
)
for assertion in layout_asserts:
    if test.count(assertion) != 1:
        raise SystemExit(
            f"P2.5a frozen layout oracle is missing: {assertion}"
        )

compact_test = re.sub(r"\s+", "", test)
runtime_offsets = (
    ("borrowedExistingDevice", 0),
    ("borrowedExistingQueue", 4),
    ("borrowedVirginCommandBuffer", 8),
    ("contextOwnsFence", 12),
    ("createsDevice", 16),
    ("createsQueue", 20),
    ("createsCommandBuffer", 24),
    ("commits", 28),
    ("waits", 32),
    ("drawableAcquisitions", 36),
    ("presents", 40),
)
for field, offset in runtime_offsets:
    assertion = (
        "offsetof(IOSShadingPrototypeRuntimeContract,"
        f"{field})=={offset}u"
    )
    if compact_test.count(assertion) != 1:
        raise SystemExit(
            f"P2.5a runtime layout oracle is missing: {assertion}"
        )

topology_oracles = (
    "topology.commandBuffers==1u",
    "topology.submits==1u",
    "topology.renderEncoders==1u",
    "topology.draws==2u",
    "topology.tileDispatches==tileDispatches",
    "topology.computeEncoders==computeEncoders",
    "topology.drawableAcquisitions==0u",
    "topology.presents==0u",
    "topology.operationCount==3u",
    "topology.operations==operations",
)
for oracle in topology_oracles:
    if test.count(oracle) != 1:
        raise SystemExit(
            f"P2.5a topology oracle is missing: {oracle}"
        )
PY

printf '#include "graphics/iosshadingprototypeplan.h"\nint main() { return 0; }\n' |
  clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
clang++ -x c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -fsyntax-only game/graphics/iosshadingprototypeplan.cpp
clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeplan.cpp \
  game/graphics/iosshadingprototypeplan.cpp \
  game/graphics/iosframeplan.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeplan"
"$RUNNER_TEMP/iosshadingprototypeplan"
clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypeplan.cpp \
  game/graphics/iosshadingprototypeplan.cpp \
  game/graphics/iosframeplan.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeplan-sanitized"
"$RUNNER_TEMP/iosshadingprototypeplan-sanitized"

MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx clang++ -std=c++20 \
  -isysroot "$MACOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeplan.cpp \
  game/graphics/iosshadingprototypeplan.cpp \
  game/graphics/iosframeplan.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeplan-appleclang"
"$RUNNER_TEMP/iosshadingprototypeplan-appleclang"

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
printf '#include "graphics/iosshadingprototypeplan.h"\nint main() { return 0; }\n' |
  xcrun --sdk iphoneos clang++ -x c++ -std=c++20 \
    -target arm64-apple-ios16.4 \
    -isysroot "$IOS_SDK" \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun --sdk iphoneos clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -fsyntax-only \
  game/graphics/iosshadingprototypeplan.cpp \
  ios/tests/iosshadingprototypeplan.cpp

P25A_CMAKE_BUILD="$RUNNER_TEMP/iosshadingprototypeplan-cmake"
rm -rf "$P25A_CMAKE_BUILD"
cmake --preset renderer-ios-off -B "$P25A_CMAKE_BUILD"
P25A_PROJECT="$P25A_CMAKE_BUILD/Gothic2Notr.xcodeproj/project.pbxproj"
test -f "$P25A_PROJECT"
if grep -Fq 'iosshadingprototypeplan.cpp' "$P25A_PROJECT"; then
  echo 'P2.5a diagnostic-only source entered the Xcode target'
  exit 1
fi

printf '\n### CI contract: Verify P2.5b2a1 shading prototype Tile self-test profile\n'
set -euo pipefail

test -x ios/device-test/validate-shading-prototype-tile-self-test-log.py
PYTHONDONTWRITEBYTECODE=1 \
  python3 ios/device-test/validate-shading-prototype-tile-self-test-log.py \
    --self-test
/bin/bash -n ios/device-test/run-smoke-test.sh
PYTHONDONTWRITEBYTECODE=1 /bin/bash \
  ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test --self-test

if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test \
    --require-bink-self-test --self-test; then
  echo 'shading prototype Tile/Bink harness conflict survived'
  exit 1
fi
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test \
    --require-resource-allocator-self-test --self-test; then
  echo 'shading prototype Tile/resource allocator harness conflict survived'
  exit 1
fi
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test \
    --require-clear-only-pass-self-test --self-test; then
  echo 'shading prototype Tile/clear-only pass harness conflict survived'
  exit 1
fi
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test \
    --pipeline-archive-test-mode cold --self-test; then
  echo 'shading prototype Tile/pipeline archive harness conflict survived'
  exit 1
fi
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test \
    --expected-fault post-submit-suboptimal --self-test; then
  echo 'shading prototype Tile/fault harness conflict survived'
  exit 1
fi
if OPENGOTHIC_IOS_EXPECTED_FAULT=post-submit-suboptimal \
    /bin/bash ios/device-test/run-smoke-test.sh \
      --require-shading-prototype-tile-self-test --self-test; then
  echo 'shading prototype Tile host profile accepted an injected fault'
  exit 1
fi
if [ "$TILE_SELF_TEST" = ON ] && {
    [ "$REQUESTED_FAULT" != none ] ||
    [ "$REQUESTED_BINK_SELF_TEST" = ON ] ||
    [ "$REQUESTED_RESOURCE_ALLOCATOR_SELF_TEST" = ON ] ||
    [ "$REQUESTED_CLEAR_ONLY_PASS_SELF_TEST" = ON ] ||
    [ "$REQUESTED_SHADING_PROTOTYPE_FORWARD_SELF_TEST" = ON ];
}; then
  echo 'shading prototype Tile workflow input conflicts with fault/other self-test'
  exit 1
fi

PYTHONPYCACHEPREFIX="$RUNNER_TEMP/renderer-ios-python-cache" \
  python3 -m py_compile \
    ios/device-test/validate-shading-prototype-tile-self-test-log.py
grep -Fq -- '--require-shading-prototype-tile-self-test' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'validate_shading_prototype_tile_binary_profile()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'build/device-self-test/%s/shading-prototype-tile\n' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'self_test_profile=shading-prototype-tile' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'processes-shading-prototype-tile-window-start.json' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_shading_prototype_tile_artifact()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'ensure_durable_zero || fail "durable final application cleanup failed"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_crash_state final' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST' \
  CMakeLists.txt
grep -Fq 'IOS AND OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST' \
  CMakeLists.txt
grep -Fq 'game/graphics/iosshadingprototypeplan.cpp' \
  CMakeLists.txt
grep -Fq \
  'static_assert(sizeof(RendererIOSShadingPrototypeTileSelfTestEncoded)-2u==245u);' \
  game/graphics/iosmetalcontext.cpp

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
tile_objc_sources=(
  game/graphics/iosmetalcapturesession.mm
  game/graphics/iosmetalresourceallocator.mm
  game/graphics/iosmetalresourceclearpassprobe.mm
  game/graphics/iosshadingprototypepipeline.mm
  game/graphics/iosshadingprototypetileprobe.mm
)
for source in "${tile_objc_sources[@]}"; do
  object="$RUNNER_TEMP/$(basename "${source%.mm}")-tile.o"
  xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 -isysroot "$IOS_SDK" \
    -fno-objc-arc \
    -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST=1 \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -isystem lib/Tempest/Engine/include \
    -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
    -c "$source" -o "$object"
  test -s "$object"
done

python3 - <<'PY'
from pathlib import Path
import re
import runpy

context = Path("game/graphics/iosmetalcontext.cpp").read_text()
harness = Path("ios/device-test/run-smoke-test.sh").read_text()
validator = Path(
    "ios/device-test/validate-shading-prototype-tile-self-test-log.py"
).read_text()
validator_module = runpy.run_path(
    "ios/device-test/validate-shading-prototype-tile-self-test-log.py"
)
profile = Path("scripts/ci_build_profile.command").read_text()
cmake = Path("CMakeLists.txt").read_text()
markers = (
    "RendererIOS shading prototype tile self-test: ARMED "
    "case=tile-prototype-v1 contract=1 metallib-abi=9 "
    "minimum-apple=4 output=4x4 rgba8-private=1",
    "RendererIOS shading prototype tile self-test: FACTORY READY "
    "case=tile-prototype-v1 pipelines=3 forward=0 runtime-delta=0 "
    "builtin-delta=0 archive-delta=0",
    "RendererIOS shading prototype tile self-test: ENCODED "
    "case=tile-prototype-v1 pass=1 encoder=1 draws=2 opaque=1 "
    "alpha=1 tdispatch=1 vb=168 output=1 mat=0 ib=4 clear-a=0 "
    "tgmem=0 size=16 dispatch=16x16x1 order=opaque,alpha,tile "
    "drawable=0 present=0",
    "RendererIOS shading prototype tile self-test: SUBMITTED "
    "case=tile-prototype-v1 command-buffers=1 submits=1",
    "RendererIOS shading prototype tile self-test: PASS "
    "case=tile-prototype-v1 terminal=completed created=1 live=0 "
    "released=1 wait-idle=0 runtime-delta=0 builtin-delta=0 "
    "archive-delta=0",
    "RendererIOS shading prototype tile self-test: UNSUPPORTED "
    "case=tile-prototype-v1 reason=apple4-required side-effects=0",
)
if tuple(len(marker.encode("utf-8")) for marker in markers) != (
    143, 152, 245, 106, 180, 118,
):
    raise SystemExit("shading prototype Tile marker byte budget changed")
marker_scope = context.split(
    "constexpr char RendererIOSShadingPrototypeTileSelfTestArmed[]", 1
)[1].split("\n#endif", 1)[0]
validator_names = (
    "ARMED",
    "FACTORY_READY",
    "ENCODED",
    "SUBMITTED",
    "PASS",
    "UNSUPPORTED",
)
for marker, validator_name in zip(markers, validator_names):
    if marker_scope.count(marker) != 1:
        raise SystemExit(
            f"shading prototype Tile production marker is not exact: {marker}"
        )
    if validator_module[validator_name] != marker:
        raise SystemExit(
            f"shading prototype Tile validator marker is not exact: {marker}"
        )
if context.count(
    '"\\x01RendererIOS shading prototype tile capture: ACQUIRED"'
) != 1:
    raise SystemExit("shading prototype Tile capture binary marker is not exact")
if "not ordinary" not in validator:
    raise SystemExit("Tile validator does not require zero ordinary frames")
for forbidden in ("riosForward", "ForwardPlus", "Forward+"):
    if forbidden not in validator:
        raise SystemExit(f"Tile validator omits Forward denylist: {forbidden}")
fail_reasons = (
    "plan-contract-mismatch",
    "snapshot-unavailable",
    "factory-contract-mismatch",
    "factory-counter-mismatch",
    "unsupported-side-effect-mismatch",
    "output-allocation-or-lifetime-mismatch",
    "capture-start-failed",
    "capture-start-ambiguous",
    "command-buffer-creation-failed",
    "native-encode-rejected",
    "encoded-contract-mismatch",
    "submit-exception-ambiguous",
    "capture-acquisition-failed",
    "terminal-fence-error",
    "terminal-lifetime-or-counter-mismatch",
    "fence-nonterminal-after-wait-idle",
    "wait-idle-used",
)
for reason in fail_reasons:
    if reason not in context or reason not in validator:
        raise SystemExit(f"Tile failure reason is not end-to-end: {reason}")
if (
    cmake.count(
        "target_sources(${PROJECT_NAME} PRIVATE\n"
        '    "${CMAKE_CURRENT_SOURCE_DIR}/game/graphics/'
        'iosshadingprototypeplan.cpp")'
    )
    != 1
):
    raise SystemExit("P2.5a plan source does not have one Tile-only target gate")
evidence_root = harness.split(
    "smoke_evidence_root() {", 1
)[1].split("\nsmoke_evidence_path() {", 1)[0]
evidence_leaf = harness.split(
    "smoke_evidence_path() {", 1
)[1].split("\npublish_evidence_path() {", 1)[0]
if evidence_root.count(
    "build/device-self-test/%s/shading-prototype-tile\\n"
) != 1:
    raise SystemExit("Tile evidence namespace is not exact")
if evidence_leaf.count("printf '%s/%s-%s-%s\\n'") != 1:
    raise SystemExit("shared immutable evidence leaf is not exact")
cleanup = harness.split("\ncleanup() {", 1)[1].split(
    "\ntrap cleanup EXIT", 1
)[0]
if cleanup.index("ensure_durable_zero") > cleanup.index(
    "preserve_failure_evidence"
):
    raise SystemExit("Tile failure evidence precedes durable-zero cleanup")
if cleanup.index("capture_shading_prototype_tile_artifact") > cleanup.index(
    "preserve_failure_evidence"
):
    raise SystemExit("Tile capture recovery follows failure preservation")
configure_start = "# CI_PROFILE_CONFIGURE_BEGIN"
configure_end = "# CI_PROFILE_CONFIGURE_END"
if profile.count(configure_start) != 1 or profile.count(configure_end) != 1:
    raise SystemExit("profile configure boundaries are not exact")
configure = profile.split(configure_start, 1)[1].split(configure_end, 1)[0]
if configure.count(
    "-DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST="
) != 1:
    raise SystemExit("build profile Tile mode is not configured exactly once")
PY

configure_profile() {
  local name="$1"
  local tile="$2"
  local build="$RUNNER_TEMP/renderer-ios-tile-pbx-$name"
  rm -rf "$build"
  cmake --preset "renderer-ios-$name" -B "$build"
  local project="$build/Gothic2Notr.xcodeproj/project.pbxproj"
  test -f "$project"
  python3 - "$project" "$tile" <<'PY'
from pathlib import Path
import re
import sys

project = Path(sys.argv[1]).read_text()
tile = sys.argv[2]
targets = re.findall(
    r"\b([A-F0-9]{24}) /\* [^*]+ \*/ = \{\n"
    r"\s*isa = PBXNativeTarget;(.*?)\n\s*\};",
    project,
    re.S,
)
gothic = [
    body for _, body in targets
    if re.search(r"^\s*name = Gothic2Notr;$", body, re.M)
]
if len(gothic) != 1:
    raise SystemExit("could not identify exact Gothic2Notr target")
source_phase = re.search(
    r"([A-F0-9]{24}) /\* Sources \*/", gothic[0]
)
if source_phase is None:
    raise SystemExit("Gothic2Notr target has no Sources phase")
phase = re.search(
    rf"\b{source_phase.group(1)} /\* Sources \*/ = \{{\n"
    r"\s*isa = PBXSourcesBuildPhase;(.*?)\n\s*\};",
    project,
    re.S,
)
if phase is None:
    raise SystemExit("could not read Gothic2Notr Sources phase")
build_files = project.split(
    "/* Begin PBXBuildFile section */", 1
)[1].split("/* End PBXBuildFile section */", 1)[0]
sources = (
    "iosshadingprototypepipeline.cpp",
    "iosshadingprototypepipeline.mm",
    "iosshadingprototypeforwardprobe.cpp",
    "iosshadingprototypeforwardprobe.mm",
    "iosshadingprototypetileprobe.cpp",
    "iosshadingprototypetileprobe.mm",
    "iosmetalcapturesession.mm",
)
for source in sources:
    if phase.group(1).count(source) != 1:
        raise SystemExit(
            f"{source} is not exactly once in Gothic2Notr Sources"
        )
    if build_files.count(source) != 2:
        raise SystemExit(
            f"{source} does not have one exact PBXBuildFile entry"
        )
plan = "iosshadingprototypeplan.cpp"
expected_plan = 1 if tile == "ON" else 0
if phase.group(1).count(plan) != expected_plan:
    raise SystemExit("Tile plan Gothic2Notr Sources gate is not exact")
if build_files.count(plan) != expected_plan * 2:
    raise SystemExit("Tile plan PBXBuildFile gate is not exact")
PY
}
configure_profile off OFF
configure_profile on OFF
configure_profile tile ON

expect_configure_failure() {
  local name="$1"
  shift
  local build="$RUNNER_TEMP/renderer-ios-tile-invalid-$name"
  rm -rf "$build"
  if cmake --preset renderer-ios-tile -B "$build" \
      "$@" >/dev/null 2>&1; then
    echo "invalid shading prototype Tile CMake profile survived: $name"
    exit 1
  fi
}
expect_configure_failure diagnostics-off \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=OFF
expect_configure_failure fault \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_FAULT_MODE=post-submit-suboptimal
expect_configure_failure bink \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST=ON
expect_configure_failure allocator \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST=ON
expect_configure_failure clear \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=ON

printf '\n### CI contract: Verify P2.5c1b1 shading prototype Forward self-test profile\n'
set -euo pipefail

test -x ios/device-test/validate-shading-prototype-forward-self-test-log.py
test -x ios/device-test/validate-shading-prototype-forward-gpudebug-trace.py
PYTHONDONTWRITEBYTECODE=1 python3 \
  ios/device-test/validate-shading-prototype-forward-self-test-log.py \
  --self-test
PYTHONDONTWRITEBYTECODE=1 python3 \
  ios/device-test/validate-shading-prototype-forward-gpudebug-trace.py \
  --self-test
/bin/bash -n ios/device-test/run-smoke-test.sh
PYTHONDONTWRITEBYTECODE=1 /bin/bash \
  ios/device-test/run-smoke-test.sh \
  --require-shading-prototype-forward-self-test --self-test

for conflict in \
    --require-bink-self-test \
    --require-resource-allocator-self-test \
    --require-clear-only-pass-self-test \
    --require-shading-prototype-tile-self-test; do
  if /bin/bash ios/device-test/run-smoke-test.sh \
      --require-shading-prototype-forward-self-test \
      "$conflict" --self-test; then
    echo "shading prototype Forward harness conflict survived: $conflict"
    exit 1
  fi
done
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-forward-self-test \
    --pipeline-archive-test-mode cold --self-test; then
  echo 'shading prototype Forward/pipeline archive conflict survived'
  exit 1
fi
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-forward-self-test \
    --expected-fault post-submit-suboptimal --self-test; then
  echo 'shading prototype Forward/fault conflict survived'
  exit 1
fi
if OPENGOTHIC_IOS_EXPECTED_FAULT=post-submit-suboptimal \
    /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-forward-self-test --self-test; then
  echo 'shading prototype Forward host profile accepted an injected fault'
  exit 1
fi
if [ "$FORWARD_SELF_TEST" = ON ] && {
    [ "$REQUESTED_FAULT" != none ] ||
    [ "$REQUESTED_BINK_SELF_TEST" = ON ] ||
    [ "$REQUESTED_RESOURCE_ALLOCATOR_SELF_TEST" = ON ] ||
    [ "$REQUESTED_CLEAR_ONLY_PASS_SELF_TEST" = ON ] ||
    [ "$REQUESTED_SHADING_PROTOTYPE_TILE_SELF_TEST" = ON ];
}; then
  echo 'shading prototype Forward workflow input conflicts with fault/other self-test'
  exit 1
fi

PYTHONPYCACHEPREFIX="$RUNNER_TEMP/renderer-ios-python-cache" \
  python3 -m py_compile \
    ios/device-test/validate-shading-prototype-forward-self-test-log.py \
    ios/device-test/validate-shading-prototype-forward-gpudebug-trace.py
grep -Fq -- '--require-shading-prototype-forward-self-test' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'select_bundle_id_from_apps()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'bundle.endswith(".xctrunner")' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'generate_shading_prototype_forward_nonce()' \
  ios/device-test/run-smoke-test.sh
grep -Fq -- '-renderer-ios-forward-self-test-nonce=' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'wait_for_shading_prototype_forward_terminal()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'verify_shading_prototype_forward_same_pid_stability()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_shading_prototype_forward_saves before' \
  ios/device-test/run-smoke-test.sh
grep -Fq '"save_slot_20.sav",' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'verify_shading_prototype_forward_save_integrity' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'verify_game_container_resources postinstall' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'verify_game_container_resources postruntime' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_shading_prototype_forward_artifact()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'ensure_durable_zero || fail "durable final application cleanup failed"' \
  ios/device-test/run-smoke-test.sh

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
forward_objc_sources=(
  game/graphics/iosmetalcapturesession.mm
  game/graphics/iosmetalresourceallocator.mm
  game/graphics/iosshadingprototypeforwardpipeline.mm
  game/graphics/iosshadingprototypeforwardprobe.mm
)
for source in "${forward_objc_sources[@]}"; do
  object="$RUNNER_TEMP/$(basename "${source%.mm}")-forward.o"
  xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 -isysroot "$IOS_SDK" \
    -fno-objc-arc \
    -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1 \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -isystem lib/Tempest/Engine/include \
    -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
    -c "$source" -o "$object"
  test -s "$object"
done

FORWARD_BUILD="$RUNNER_TEMP/renderer-ios-forward-pbx"
rm -rf "$FORWARD_BUILD"
cmake --preset renderer-ios-forward -B "$FORWARD_BUILD"
FORWARD_PROJECT="$FORWARD_BUILD/Gothic2Notr.xcodeproj/project.pbxproj"
test -f "$FORWARD_PROJECT"
test "$(grep -Fc \
  'game/graphics/iosshadingprototypeplan.cpp */ = {isa = PBXBuildFile; fileRef =' \
  "$FORWARD_PROJECT" || true)" -eq 1
awk '
  /Begin PBXSourcesBuildPhase section/ { in_sources=1 }
  /End PBXSourcesBuildPhase section/ { in_sources=0 }
  in_sources && /game\/graphics\/iosshadingprototypeplan\.cpp \*\// {
    found++
  }
  END { exit found == 1 ? 0 : 1 }
' "$FORWARD_PROJECT"

expect_forward_configure_failure() {
  local name="$1"
  shift
  local build="$RUNNER_TEMP/renderer-ios-forward-invalid-$name"
  rm -rf "$build"
  if cmake --preset renderer-ios-forward -B "$build" \
      "$@" >/dev/null 2>&1; then
    echo "invalid shading prototype Forward CMake profile survived: $name"
    exit 1
  fi
}
expect_forward_configure_failure diagnostics-off \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=OFF
expect_forward_configure_failure fault \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_FAULT_MODE=post-submit-suboptimal
expect_forward_configure_failure bink \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST=ON
expect_forward_configure_failure allocator \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST=ON
expect_forward_configure_failure clear \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=ON
expect_forward_configure_failure tile \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST=ON

printf '\nRendererIOS shading contracts passed exactly once\n'
