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

printf '\n### CI contract: Verify shared CMake presets\n'
cmake --list-presets
cmake --build --list-presets

printf '\n### CI contract: Verify pinned Tempest fork twice\n'
bash ios/patches/apply-patches.sh
bash ios/patches/apply-patches.sh

printf '\n### CI contract: Verify P2.1c3b3b causal build isolation\n'
set -euo pipefail

causal_contract_variants=(
  none
  causal-a
  causal-b
  host-test
)
for causal_variant in "${causal_contract_variants[@]}"; do
  set --
  case "$causal_variant" in
    none) ;;
    causal-a)
      set -- \
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1
      ;;
    causal-b)
      set -- \
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1
      ;;
    host-test)
      set -- \
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST=1
      ;;
  esac
  xcrun clang++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    "$@" \
    -Igame ios/tests/iosgpusceneplan.cpp \
    -o "$RUNNER_TEMP/iosgpusceneplan-$causal_variant"
  "$RUNNER_TEMP/iosgpusceneplan-$causal_variant"
  xcrun clang++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -fsanitize=address -fno-omit-frame-pointer \
    "$@" \
    -Igame ios/tests/iosgpusceneplan.cpp \
    -o "$RUNNER_TEMP/iosgpusceneplan-$causal_variant-asan"
  "$RUNNER_TEMP/iosgpusceneplan-$causal_variant-asan"
  xcrun clang++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -fsanitize=undefined -fno-sanitize-recover=undefined \
    -fno-omit-frame-pointer \
    "$@" \
    -Igame ios/tests/iosgpusceneplan.cpp \
    -o "$RUNNER_TEMP/iosgpusceneplan-$causal_variant-ubsan"
  "$RUNNER_TEMP/iosgpusceneplan-$causal_variant-ubsan"
done
for causal_conflict in a-b a-host b-host; do
  causal_conflict_definitions=()
  case "$causal_conflict" in
    a-b)
      causal_conflict_definitions=(
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1
      )
      ;;
    a-host)
      causal_conflict_definitions=(
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST=1
      )
      ;;
    b-host)
      causal_conflict_definitions=(
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST=1
      )
      ;;
  esac
  if xcrun clang++ -std=c++20 \
      -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
      "${causal_conflict_definitions[@]}" \
      -Igame -fsyntax-only ios/tests/iosgpusceneplan.cpp \
      >/dev/null 2>&1; then
    echo "causal macro conflict survived: $causal_conflict"
    exit 1
  fi
done

printf '\n### CI contract: Verify P2.1c3b3c causal runtime and native order\n'
CAUSAL_IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
for causal_variant in none causal-a causal-b; do
  set --
  case "$causal_variant" in
    none) ;;
    causal-a)
      set -- \
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1
      ;;
    causal-b)
      set -- \
        -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1
      ;;
  esac
  xcrun clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 \
    -isysroot "$CAUSAL_IOS_SDK" \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    "$@" \
    -Igame \
    -isystem lib/Tempest/Engine/include \
    -isystem lib/ZenKit/include \
    -fsyntax-only game/graphics/iosgpuscene.mm
done
python3 - <<'PY'
from pathlib import Path
import re

sources = {
    "header": Path("game/graphics/iosgpusceneplan.h").read_text(),
    "test": Path("ios/tests/iosgpusceneplan.cpp").read_text(),
    "native": Path("game/graphics/iosgpuscene.mm").read_text(),
}

required_once = {
    "header": (
        """inline constexpr IOSGPUSceneCausalFrameResult
    iosGPUScenePrepareCausalObservationForCompileMode(""",
        "sequence<=candidate.lastSequence",
        "reason!=IOSGPUSceneCausalFailureReason::TargetReused",
        """inline constexpr IOSGPUSceneDrawDispatchResult
    recordIOSGPUSceneDrawDispatchForRouteForCompileMode(""",
        """inline constexpr bool
    iosGPUSceneCausalPreparationIsValidForCompileMode(""",
        """inline constexpr bool
    iosGPUSceneCommitCausalPreparationForCompileMode(""",
        "RendererIOS native causal capture: FAIL mode=%s reason=parse-%s",
        "RendererIOS native causal capture: ARMED mode=%s nonce=%s ",
        "RendererIOS native causal capture: ENCODED mode=%s nonce=%s ",
        "RendererIOS native causal capture: FAIL mode=%s nonce=%s ",
    ),
    "test": (
        "state,7u,299u,\n      IOSGPUSceneCausalFrameResult::SequenceNotIncreasing",
        "state,8u,1u,route,prepared",
        "failed,IOSGPUSceneCausalFailureReason::TargetNotObserved));",
        "static_cast<IOSGPUSceneCausalFrameRoute>(255u)",
        "prepared,route,targetCounts,3u,3u,false,true,true",
    ),
    "native": (
        "const int* const processArgumentCountAddress = _NSGetArgc();",
        "char*** const processArgumentVectorAddress = _NSGetArgv();",
        """const int processArgumentCount =
        processArgumentCountAddress!=nullptr
          ? *processArgumentCountAddress
          : -1;""",
        """const char* const* processArgumentVector =
        processArgumentVectorAddress!=nullptr
          ? const_cast<const char* const*>(
                *processArgumentVectorAddress)
          : nullptr;""",
        """iosGPUSceneParseCausalArguments(
            processArgumentCount,processArgumentVector,
            causalArguments);""",
        "if(parseResult!=IOSGPUSceneCausalArgumentResult::Accepted)",
        "iosGPUSceneCausalParseFailMarker(",
        """if(parseResult!=IOSGPUSceneCausalArgumentResult::Accepted) {
      const IOSGPUSceneMarker marker =
          iosGPUSceneCausalParseFailMarker(
              iosGPUSceneCompiledMode(),parseResult);
      if(marker)
        Tempest::Log::e(marker.text.data());
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      return;
      }""",
        "iosGPUSceneTransitionCausalFailure(causalState,reason)",
        """if(!causalArgumentsAccepted ||
     !iosGPUSceneTransitionCausalFailure(causalState,reason))
    return;
  const IOSGPUSceneMarker marker =
      iosGPUSceneCausalFailMarker(
          causalState,generation,sequence,reason);
  if(marker)
    Tempest::Log::e(marker.text.data());""",
        """if(causalArgumentsAccepted &&
       causalState.phase==
           IOSGPUSceneCausalRuntimePhase::AwaitingTarget)
      failCausal(
          causalState.generation,causalState.lastSequence,
          IOSGPUSceneCausalFailureReason::TargetNotObserved);""",
        "targetDraws.emplace_back(std::move(draw));",
        """switch(dispatch.effective) {
          case IOSGPUScenePipelineSelector::Opaque:
            effectivePipeline =
                (id<MTLRenderPipelineState>)
                    impl->opaquePipelineState;
            break;
          case IOSGPUScenePipelineSelector::AlphaTest:
            effectivePipeline =
                (id<MTLRenderPipelineState>)
                    impl->alphaTestPipelineState;
            break;
          case IOSGPUScenePipelineSelector::Unsupported:
            break;
          }""",
        "draw.pipelineState = effectivePipeline;",
        """[encoder setRenderPipelineState:
            (id<MTLRenderPipelineState>)draw.pipelineState];""",
        "targetEncodedMarker = iosGPUSceneCausalEncodedMarker(",
        "const bool encoded = Tempest::MetalApi::withActiveRenderEncoder(",
        "Report failure = makeReport(Result::NativeEncodingFailed);",
        "recordFailure(failure.failures.nativeEncode,failure);",
        "IOSGPUSceneCausalFailureReason::MissingAlphaTestDraw",
    ),
}

expected_draw_operations = [
    "setVertexBuffer",
    "setVertexBytes",
    "setFragmentTexture",
    "insertDebugSignpost",
    "insertDebugSignpost",
    "setRenderPipelineState",
    "drawIndexedPrimitives",
]


def validate(candidate):
    for name, snippets in required_once.items():
        for snippet in snippets:
            if candidate[name].count(snippet) != 1:
                raise ValueError(name + " required-once drift: " + snippet)
    native = candidate["native"]
    header = candidate["header"]
    if native.count("_NSGetArgc()") != 1 or native.count("_NSGetArgv()") != 1:
        raise ValueError("process argv is not parsed exactly once")
    if native.count("Tempest::Log::e(marker.text.data());") != 2:
        raise ValueError("parse/runtime FAIL log sites drifted")
    parse_order = (
        native.index("_NSGetArgc()"),
        native.index("_NSGetArgv()"),
        native.index("iosGPUSceneParseCausalArguments("),
        native.index("causalArgumentsAccepted = true;"),
        native.index("Tempest::Log::i(armed.text.data());"),
    )
    if tuple(sorted(parse_order)) != parse_order:
        raise ValueError("causal argv/ARMED order drifted")
    bridge = native.index(
        "const bool encoded = Tempest::MetalApi::withActiveRenderEncoder("
    )
    for token in (
        "recordIOSGPUSceneDrawDispatchForRoute(",
        "makeIOSGPUSceneCausalDrawIdentity(",
        "iosGPUSceneCausalDrawIdSignpost(",
        "iosGPUSceneCausalDrawBindSignpost(",
        "iosGPUSceneCausalPreparationIsValid(",
        "targetEncodedMarker = iosGPUSceneCausalEncodedMarker(",
    ):
        if native.index(token) > bridge:
            raise ValueError("causal preflight occurs after native bridge: " + token)
    target_start = native.index(
        "if(context.route==IOSGPUSceneCausalFrameRoute::Target)"
    )
    target_end = native.index("#endif", target_start)
    target_native = native[target_start:target_end]
    loop_start = target_native.index("for(const auto& draw:")
    loop_end = target_native.index("restoreEncoderState();", loop_start)
    draw_loop = target_native[loop_start:loop_end]
    operations = re.findall(r"\[encoder ([A-Za-z]+)", draw_loop)
    if operations != expected_draw_operations:
        raise ValueError("target native draw operation order drifted")
    if draw_loop.index("draw.drawId.get()") > \
       draw_loop.index("draw.drawBind.get()"):
        raise ValueError("target draw-id/draw-bind order drifted")
    finish = native[native.index("if(context.targetNativeException)"):]
    finish_order = (
        finish.index("iosGPUSceneCommitCausalPreparation("),
        finish.index("impl->causalState = committed;"),
        finish.index("Tempest::Log::i(targetEncodedMarker.text.data());"),
    )
    if tuple(sorted(finish_order)) != finish_order:
        raise ValueError("target commit/ENCODED order drifted")
    if "causalState.phase==" not in native or \
       "IOSGPUSceneCausalFailureReason::TargetNotObserved" not in native:
        raise ValueError("destructor target-not-observed closure is absent")
    for forbidden in (
        "MetalCaptureEnabled",
        "MTLCaptureManager",
        "RendererIOS native causal capture: ACQUIRED",
        "RendererIOS native causal capture: SUBMITTED",
        "RendererIOS native causal capture: COMPLETED",
        "RendererIOS native causal capture: PASS",
    ):
        if forbidden in header or forbidden in native:
            raise ValueError("forbidden causal lifecycle token: " + forbidden)


validate(sources)
mutations = []
for name, snippets in required_once.items():
    for snippet in snippets:
        mutant = dict(sources)
        mutant[name] = sources[name].replace(snippet, "", 1)
        mutations.append(mutant)
native = sources["native"]
for operation in (
    "[encoder insertDebugSignpost:(NSString*)draw.drawId.get()];",
    "[encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];",
    """[encoder setRenderPipelineState:
            (id<MTLRenderPipelineState>)draw.pipelineState];""",
    "[encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle",
):
    mutant = dict(sources)
    mutant["native"] = native.replace(operation, "", 1)
    mutations.append(mutant)
    mutant = dict(sources)
    mutant["native"] = native.replace(operation, operation + "\n" + operation, 1)
    mutations.append(mutant)
mutant = dict(sources)
mutant["native"] = native.replace(
    """[encoder insertDebugSignpost:(NSString*)draw.drawId.get()];
        [encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];""",
    """[encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];
        [encoder insertDebugSignpost:(NSString*)draw.drawId.get()];""",
    1,
)
mutations.append(mutant)
for old, new in (
    ("processArgumentCount,processArgumentVector,", "0,processArgumentVector,"),
    ("processArgumentCount,processArgumentVector,", "processArgumentCount,nullptr,"),
    (
        """[encoder setRenderPipelineState:
            (id<MTLRenderPipelineState>)draw.pipelineState];""",
        """[encoder setRenderPipelineState:
            (id<MTLRenderPipelineState>)context.scene->opaquePipelineState];""",
    ),
    (
        """[encoder setRenderPipelineState:
            (id<MTLRenderPipelineState>)draw.pipelineState];""",
        """[encoder setRenderPipelineState:
            (id<MTLRenderPipelineState>)context.scene->alphaTestPipelineState];""",
    ),
):
    mutant = dict(sources)
    mutant["native"] = native.replace(old, new, 1)
    mutations.append(mutant)
mutant = dict(sources)
mutant["native"] = native.replace(
    "Tempest::Log::e(marker.text.data());", ""
)
mutations.append(mutant)
mutant = dict(sources)
mutant["native"] = native.replace(
    """impl->causalState = committed;
    Tempest::Log::i(targetEncodedMarker.text.data());""",
    """Tempest::Log::i(targetEncodedMarker.text.data());
    impl->causalState = committed;""",
    1,
)
mutations.append(mutant)
killed = 0
for mutation in mutations:
    try:
        validate(mutation)
    except ValueError:
        killed += 1
    else:
        raise SystemExit("P2.1c3b3c host/source mutation survived")
if killed != len(mutations):
    raise SystemExit("P2.1c3b3c mutation count drifted")
print(
    "RendererIOS P2.1c3b3c mutation oracle: mutations-killed="
    + str(killed)
)
PY

python3 - <<'PY'
from copy import deepcopy
import json
from pathlib import Path

cmake = Path("CMakeLists.txt").read_text()
presets = json.loads(Path("CMakePresets.json").read_text())
profile = Path("scripts/ci_build_profile.command").read_text()
local = Path("scripts/verify-local-build.command").read_text()

cmake_contract = (
    'set(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE "none"',
    """set(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE "none"
    CACHE STRING
    "RendererIOS native AlphaTest diagnostics-only causal build mode")""",
    "PROPERTY STRINGS ${_renderer_ios_native_alpha_test_causal_modes}",
    "_renderer_ios_native_alpha_test_causal_mode_index EQUAL -1",
    'STREQUAL "causal-a")',
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1",
    'STREQUAL "causal-b")',
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1",
    "RendererIOS native AlphaTest causal A/B builds require ",
    "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON",
    "OPENGOTHIC_RENDERER_IOS_FAULT_MODE=none",
    "exclusive with all other RendererIOS self-tests",
)


def validate_sources(
    candidate_cmake: str,
    candidate_presets: dict,
    candidate_profile: str,
    candidate_local: str,
) -> None:
    for literal in cmake_contract:
        if literal not in candidate_cmake:
            raise ValueError("causal CMake source contract drifted: " + literal)
    if (
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST"
        in candidate_cmake
    ):
        raise ValueError("HOST_TEST leaked into product CMake")
    configure = {
        item["name"]: item
        for item in candidate_presets["configurePresets"]
    }
    expected_names = {
        "renderer-ios-base",
        "renderer-ios-off",
        "renderer-ios-on",
        "renderer-ios-tile",
        "renderer-ios-forward",
        "renderer-ios-causal-none",
        "renderer-ios-causal-a",
        "renderer-ios-causal-b",
    }
    if set(configure) != expected_names:
        raise ValueError("causal configure preset set drifted")
    if configure["renderer-ios-base"]["cacheVariables"].get(
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE"
    ) != "none":
        raise ValueError("ordinary preset base is not explicit none")
    for suffix, mode in (
        ("causal-none", "none"),
        ("causal-a", "causal-a"),
        ("causal-b", "causal-b"),
    ):
        preset = configure["renderer-ios-" + suffix]
        if preset.get("inherits") != "renderer-ios-base":
            raise ValueError(suffix + " does not inherit base")
        if preset.get("binaryDir") != (
            "${sourceDir}/build/local-renderer-ios-" + suffix
        ):
            raise ValueError(suffix + " binaryDir drifted")
        if preset.get("environment") != {"PACKAGE_DEVICE_IPA": "0"}:
            raise ValueError(suffix + " package tuple drifted")
        expected_cache = {
            "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS": "ON",
            "OPENGOTHIC_RENDERER_IOS_FAULT_MODE": "none",
            "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE": mode,
            "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": "OFF",
        }
        if preset.get("cacheVariables") != expected_cache:
            raise ValueError(suffix + " cache tuple drifted")
    build_names = [item["name"] for item in candidate_presets["buildPresets"]]
    if build_names != [
        "renderer-ios-off",
        "renderer-ios-on",
        "renderer-ios-tile",
        "renderer-ios-forward",
        "renderer-ios-causal-none",
        "renderer-ios-causal-a",
        "renderer-ios-causal-b",
    ]:
        raise ValueError("causal build preset order drifted")
    for literal in (
        "RAW_ACTIVE_FAULT_MODE_SET",
        "reject_causal_raw_conflict",
        '-DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE="$CAUSAL_MODE"',
        "causal PBX global definitions drifted",
        "RendererIOS causal binary oracle:",
    ):
        if literal not in candidate_profile:
            raise ValueError("causal CI profile contract drifted: " + literal)
    for literal in (
        "causal-none|causal-a|causal-b",
        "RendererIOS causal PBX oracle:",
        "RendererIOS causal binary oracle:",
        "causal-invalid-non-ios",
    ):
        if literal not in candidate_local:
            raise ValueError("causal local profile contract drifted: " + literal)


validate_sources(cmake, presets, profile, local)
source_mutations = []
for literal in cmake_contract[:8]:
    source_mutations.append(
        (cmake.replace(literal, "C3B3B_MUTANT", 1), presets, profile, local)
    )
mutated = deepcopy(presets)
del mutated["configurePresets"][0]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE"
]
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][5]["binaryDir"] = (
    "${sourceDir}/build/local-renderer-ios-causal-a"
)
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][6]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE"
] = "none"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][7]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST"
] = "ON"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][5]["environment"]["PACKAGE_DEVICE_IPA"] = "1"
source_mutations.append((cmake, mutated, profile, local))
source_mutations.append(
    (
        cmake,
        presets,
        profile.replace(
            "reject_causal_raw_conflict",
            "accept_causal_raw_conflict",
        ),
        local,
    )
)
source_mutations.append(
    (
        cmake,
        presets,
        profile.replace(
            '-DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE="$CAUSAL_MODE"',
            "-DCAUSAL_MODE=none",
            1,
        ),
        local,
    )
)
source_mutations.append(
    (
        cmake,
        presets,
        profile,
        local.replace("causal-invalid-non-ios", "causal-non-ios-removed", 1),
    )
)
killed = 0
for mutation in source_mutations:
    try:
        validate_sources(*mutation)
    except ValueError:
        killed += 1
    else:
        raise SystemExit("causal source mutation survived")
if killed != 16:
    raise SystemExit("causal source mutation count drifted")
print("RendererIOS causal source oracle: mutations-killed=16")
PY

CAUSAL_CONTRACT_ROOT="$RUNNER_TEMP/renderer-ios-causal-contracts"
for causal_profile in causal-none causal-a causal-b; do
  cmake --preset "renderer-ios-$causal_profile" \
    -B "$CAUSAL_CONTRACT_ROOT/$causal_profile" \
    -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="$GITHUB_SHA-contract"
done

python3 - "$CAUSAL_CONTRACT_ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
macro_a = "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1"
macro_b = "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1"
macro_host = "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST"
causal_token = re.compile(
    r"(?<![A-Za-z0-9_])OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_"
    r"(?:A|B|HOST_TEST)(?:=[^'\",\s;)]+)?(?![A-Za-z0-9_])"
)
required_cache = {
    "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS": ("BOOL", "ON"),
    "OPENGOTHIC_RENDERER_IOS_FAULT_MODE": ("STRING", "none"),
    "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST": ("BOOL", "OFF"),
    "OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST": ("BOOL", "OFF"),
    "OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST": ("BOOL", "OFF"),
    "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": ("BOOL", "OFF"),
    "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": (
        "BOOL",
        "OFF",
    ),
}


def parse_cache(source: str) -> dict[str, tuple[str, str]]:
    result = {}
    for line in source.splitlines():
        match = re.fullmatch(r"([^/#][^:]*):([^=]+)=(.*)", line)
        if match is not None:
            result[match.group(1)] = (match.group(2), match.group(3))
    return result


def validate_cache(candidate: dict[str, tuple[str, str]], mode: str) -> None:
    expected = dict(required_cache)
    expected[
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE"
    ] = ("STRING", mode)
    for key, value in expected.items():
        if candidate.get(key) != value:
            raise ValueError("causal cache tuple drifted: " + key)


def target_configurations(project: str):
    target = re.search(
        r"\b([A-F0-9]{24}) /\* Gothic2Notr \*/ = \{\n"
        r"\s*isa = PBXNativeTarget;(.*?)\n\s*\};",
        project,
        re.S,
    )
    if target is None:
        raise ValueError("cannot identify Gothic2Notr target")
    list_id = re.search(
        r'buildConfigurationList = ([A-F0-9]{24}) /\* '
        r'Build configuration list for PBXNativeTarget "Gothic2Notr" \*/;',
        target.group(2),
    )
    if list_id is None:
        raise ValueError("cannot identify Gothic2Notr configuration list")
    configuration_list = re.search(
        rf"\b{list_id.group(1)} /\* Build configuration list for "
        r'PBXNativeTarget "Gothic2Notr" \*/ = \{\n'
        r"\s*isa = XCConfigurationList;(.*?)\n\s*\};",
        project,
        re.S,
    )
    if configuration_list is None:
        raise ValueError("cannot read Gothic2Notr configuration list")
    configurations = re.findall(
        r"([A-F0-9]{24}) /\* (Debug|MinSizeRel|Release|RelWithDebInfo) \*/,",
        configuration_list.group(1),
    )
    if [name for _, name in configurations] != [
        "Debug",
        "Release",
        "MinSizeRel",
        "RelWithDebInfo",
    ]:
        raise ValueError("Gothic2Notr configuration list entries drifted")
    return configurations


def validate_pbx(project: str, mode: str) -> None:
    expected = {
        "none": (),
        "causal-a": (macro_a,),
        "causal-b": (macro_b,),
    }[mode]
    global_entries = causal_token.findall(project)
    if global_entries != list(expected) * 4:
        raise ValueError(
            "causal PBX global entries drifted: " + ",".join(global_entries)
        )
    for identifier, name in target_configurations(project):
        configuration = re.search(
            rf"\b{identifier} /\* {name} \*/ = \{{\n"
            r"\s*isa = XCBuildConfiguration;\n"
            r"\s*buildSettings = \{(.*?)\n\s*\};\n"
            rf"\s*name = {name};\n\s*\}};",
            project,
            re.S,
        )
        if configuration is None:
            raise ValueError("cannot read Gothic2Notr " + name)
        definition_lists = re.findall(
            r"GCC_PREPROCESSOR_DEFINITIONS = \((.*?)\);",
            configuration.group(1),
            re.S,
        )
        if len(definition_lists) != 1:
            raise ValueError("Gothic2Notr definition list drifted: " + name)
        entries = causal_token.findall(definition_lists[0])
        if entries != list(expected):
            raise ValueError(
                "Gothic2Notr exact causal list drifted: "
                + name
                + ":"
                + ",".join(entries)
            )


total_cache_mutations = 0
total_pbx_mutations = 0
for profile, mode in (
    ("causal-none", "none"),
    ("causal-a", "causal-a"),
    ("causal-b", "causal-b"),
):
    build = root / profile
    cache = parse_cache((build / "CMakeCache.txt").read_text())
    validate_cache(cache, mode)
    cache_mutations = []
    for key, (_, value) in {
        **required_cache,
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE": (
            "STRING",
            mode,
        ),
    }.items():
        mutation = dict(cache)
        mutation[key] = ("STRING", value + "-mutant")
        cache_mutations.append(mutation)
    for mutation in cache_mutations:
        try:
            validate_cache(mutation, mode)
        except ValueError:
            total_cache_mutations += 1
        else:
            raise SystemExit("causal cache mutation survived")

    project = (
        build / "Gothic2Notr.xcodeproj" / "project.pbxproj"
    ).read_text()
    validate_pbx(project, mode)
    diagnostics = "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1"
    if project.count(diagnostics) != 4:
        raise SystemExit("causal PBX diagnostics anchor drifted")
    if mode == "none":
        pbx_mutations = [
            project.replace(diagnostics, diagnostics + " " + token, 1)
            for token in (macro_a, macro_b, macro_host)
        ]
    else:
        expected = macro_a if mode == "causal-a" else macro_b
        opposite = macro_b if mode == "causal-a" else macro_a
        quoted = "\"'" + expected + "'\""
        if project.count(quoted) != 4:
            raise SystemExit("causal PBX mutation entries drifted")
        pbx_mutations = [
            project.replace(quoted, "", 1),
            project.replace(quoted, quoted + "," + quoted, 1),
            project.replace(expected, expected[:-1] + "10", 1),
            project.replace(expected, "MUTANT_" + expected, 1),
            project.replace(
                quoted,
                quoted + ",\"'" + opposite + "'\"",
                1,
            ),
            project.replace(
                quoted,
                quoted + ",\"'" + macro_host + "=1'\"",
                1,
            ),
            project.replace(quoted, "", 1) + "\n" + quoted + "\n",
        ]
    for mutation in pbx_mutations:
        try:
            validate_pbx(mutation, mode)
        except ValueError:
            total_pbx_mutations += 1
        else:
            raise SystemExit("causal PBX mutation survived")

if total_cache_mutations != 24:
    raise SystemExit("causal cache mutation count drifted")
if total_pbx_mutations != 17:
    raise SystemExit("causal PBX mutation count drifted")
print("RendererIOS causal cache oracle: mutations-killed=24")
print("RendererIOS causal PBX oracle: profiles=3 mutations-killed=17")
PY

expect_causal_contract_configure_failure() {
  local mode="$1"
  local name="$2"
  shift 2
  local build="$CAUSAL_CONTRACT_ROOT/invalid-$mode-$name"
  if cmake --preset "renderer-ios-$mode" -B "$build" \
      -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
      -DOPENGOTHIC_RENDERER_IOS_FAULT_MODE=none \
      -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE="$mode" \
      -DOPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST=OFF \
      -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST=OFF \
      -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=OFF \
      -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST=OFF \
      -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=OFF \
      "$@" >/dev/null 2>&1; then
    echo "invalid causal configure survived: $mode/$name"
    exit 1
  fi
}

expect_causal_contract_configure_failure causal-a unknown-mode \
  -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE=unknown
for causal_mode_under_test in causal-a causal-b; do
  expect_causal_contract_configure_failure \
    "$causal_mode_under_test" diagnostics-off \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=OFF
  expect_causal_contract_configure_failure "$causal_mode_under_test" fault \
    -DOPENGOTHIC_RENDERER_IOS_FAULT_MODE=post-submit-suboptimal
  expect_causal_contract_configure_failure "$causal_mode_under_test" bink \
    -DOPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST=ON
  expect_causal_contract_configure_failure "$causal_mode_under_test" allocator \
    -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST=ON
  expect_causal_contract_configure_failure "$causal_mode_under_test" clear \
    -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=ON
  expect_causal_contract_configure_failure "$causal_mode_under_test" tile \
    -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST=ON
  expect_causal_contract_configure_failure "$causal_mode_under_test" forward \
    -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=ON
done
for causal_mode_under_test in causal-a causal-b; do
  if cmake -S "$PWD" \
      -B "$CAUSAL_CONTRACT_ROOT/invalid-non-ios-$causal_mode_under_test" \
      -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE="$causal_mode_under_test" \
      >/dev/null 2>&1; then
    echo "non-iOS causal configure survived: $causal_mode_under_test"
    exit 1
  fi
done

printf '\n### CI contract: Verify neutral P2.1 scene boundary\n'
set -euo pipefail

headers=(
  game/graphics/iosframeinput.h
  game/graphics/iosrenderworld.h
  game/graphics/iosscenesnapshot.h
)
sources=(
  game/graphics/iosframeinput.cpp
  game/graphics/iosrenderworld.cpp
  game/graphics/iosscenesnapshot.cpp
)

for file in "${headers[@]}" "${sources[@]}"; do
  test -f "$file" || {
    echo "missing P2.1 scene-boundary file: $file"
    exit 1
  }
done

obsolete="$(
  find game -type f \( -name '*.h' -o -name '*.cpp' \) \
    -exec grep -nHF 'RendererIOS::FrameInput' {} + || true
)"
if [ -n "$obsolete" ]; then
  printf '%s\n' "$obsolete"
  echo 'obsolete RendererIOS::FrameInput remains in product code'
  exit 1
fi

if grep -nE \
    'Tempest|WorldView|DrawCommands|Shaders|VectorImage|InventoryMenu|VideoWidget' \
    "${headers[@]}"; then
  echo 'neutral P2.1 headers leak legacy, transport, or UI types'
  exit 1
fi

for header in iosframeinput.h iosrenderworld.h iosscenesnapshot.h; do
  printf '#include "graphics/%s"\nint main() { return 0; }\n' "$header" |
    xcrun clang++ -x c++ -std=c++20 \
      -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
      -Igame -fsyntax-only -
done

for source in "${sources[@]}"; do
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only "$source"
done

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosscenecontract.cpp \
  game/graphics/iosframeinput.cpp \
  game/graphics/iosrenderworld.cpp \
  game/graphics/iosscenesnapshot.cpp \
  -o "$RUNNER_TEMP/iosscenecontract"
"$RUNNER_TEMP/iosscenecontract"

test -f game/graphics/iossceneconversion.h
test -f game/graphics/iossceneconversion.cpp
test -f ios/tests/iossceneconversion.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -Ilib/Tempest/Engine/include \
  ios/tests/iossceneconversion.cpp \
  game/graphics/iossceneconversion.cpp \
  -o "$RUNNER_TEMP/iossceneconversion"
"$RUNNER_TEMP/iossceneconversion"

test -f lib/Tempest/Tests/tests/metalapi_borrowed_handle_compile_test.cpp
xcrun clang++ -std=c++17 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Ilib/Tempest/Engine/include -fsyntax-only \
  lib/Tempest/Tests/tests/metalapi_borrowed_handle_compile_test.cpp

printf '\n### CI contract: Verify neutral P2.2d frame plan\n'
set -euo pipefail

test -f game/graphics/iosframeplan.h
test -f game/graphics/iosframeplan.cpp
test -f ios/tests/iosframeplan.cpp

if grep -nF '\' \
    game/graphics/iosframeplan.h \
    game/graphics/iosframeplan.cpp; then
  echo 'neutral P2.2d frame-plan contract uses forbidden line continuation'
  exit 1
fi
if grep -nE '/\*|\*/' \
    game/graphics/iosframeplan.h \
    game/graphics/iosframeplan.cpp; then
  echo 'neutral P2.2d frame-plan contract uses forbidden block comment'
  exit 1
fi
if LC_ALL=C grep -nE '[^[:blank:][:graph:]]' \
    game/graphics/iosframeplan.h \
    game/graphics/iosframeplan.cpp; then
  echo 'neutral P2.2d frame-plan contract is not printable ASCII'
  exit 1
fi

header_directives="$(
  grep -E '^[[:space:]]*(#|%:)' \
    game/graphics/iosframeplan.h || true
)"
source_directives="$(
  grep -E '^[[:space:]]*(#|%:)' \
    game/graphics/iosframeplan.cpp || true
)"
test "$header_directives" = \
  $'#pragma once\n#include <cstdint>\n#include <vector>'
test "$source_directives" = \
  $'#include "iosframeplan.h"\n#include <cstddef>'

if grep -nE \
    'Tempest|Objective-C|MTL|Metal|CAMetalLayer|IOSMetalContext|IOSFrameGraph|allocator|Drawable|Swapchain|CommandBuffer|Encoder|Fence|WorldView|DrawCommands|Shaders|InventoryMenu|VideoWidget|QuartzCore|Foundation|UIKit|CoreFoundation|void[[:space:]]*\*|NativeHandle' \
    game/graphics/iosframeplan.h \
    game/graphics/iosframeplan.cpp; then
  echo 'neutral P2.2d frame-plan contract leaks runtime or transport types'
  exit 1
fi

printf '#include "graphics/iosframeplan.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -x c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -fsyntax-only game/graphics/iosframeplan.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosframeplan.cpp \
  game/graphics/iosframeplan.cpp \
  -o "$RUNNER_TEMP/iosframeplan"
"$RUNNER_TEMP/iosframeplan"

printf '\n### CI contract: Verify P2.6c host-neutral feature policy\n'
set -euo pipefail

scripts/verify_ios_feature_policy.command

printf '\n### CI contract: Verify P2.6a host-neutral device facts contract\n'

capability_files=(
  game/graphics/iosdevicecapabilities.h
  game/graphics/iosdevicecapabilities.cpp
  ios/tests/iosdevicecapabilities.cpp
)
for file in "${capability_files[@]}"; do
  test -f "$file"
done
test "$(find game/graphics ios/tests -maxdepth 1 -type f \
    -name 'iosdevicecapabilities*' | LC_ALL=C sort)" = \
  $'game/graphics/iosdevicecapabilities.cpp\ngame/graphics/iosdevicecapabilities.h\nios/tests/iosdevicecapabilities.cpp'

expected_header_directives=$'#pragma once\n#include <cstddef>\n#include <cstdint>\n#include <optional>\n#include <type_traits>'
expected_source_directives=$'#include "iosdevicecapabilities.h"\n#include <utility>'
expected_test_directives=$'#include "graphics/iosdevicecapabilities.h"\n#include <cassert>\n#include <cstddef>\n#include <cstdint>\n#include <type_traits>\n#include <utility>'
p26a_directives() {
  grep -E '^[[:space:]]*(#|%:)' "$1"
}
p26a_directives_valid() {
  test "$1" = "$2"
}
p26a_directives_valid \
  "$(p26a_directives game/graphics/iosdevicecapabilities.h)" \
  "$expected_header_directives"
p26a_directives_valid \
  "$(p26a_directives game/graphics/iosdevicecapabilities.cpp)" \
  "$expected_source_directives"
p26a_directives_valid \
  "$(p26a_directives ios/tests/iosdevicecapabilities.cpp)" \
  "$expected_test_directives"
if p26a_directives_valid \
    "$expected_header_directives"$'\n#include <vector>' \
    "$expected_header_directives"; then
  echo 'P2.6a directive allowlist accepted a dynamic container include'
  exit 1
fi

P26A_HOST_DENY='#import|<Metal/|@interface|@protocol|__OBJC__|id[[:space:]]*<MTL|MTL[A-Z]|Tempest|IOSMetalContext|RendererIOS|Foundation|UIKit|QuartzCore|CAMetalLayer|hw\.machine|sysctlbyname|IOSFeaturePolicy|thermal|void[[:space:]]*\*|NativeHandle|newLibrary|newCommand|malloc|calloc|realloc|operator[[:space:]]+new'
if grep -Eni "$P26A_HOST_DENY" "${capability_files[@]}"; then
  echo 'P2.6a host-neutral contract leaks runtime, policy, or native transport'
  exit 1
fi
if printf '%s\n' \
    'MetalFxSpatial MetalFxTemporal Metal4Transport' |
    grep -Eq "$P26A_HOST_DENY"; then
  echo 'P2.6a host-neutral denylist rejects frozen Metal probe names'
  exit 1
fi
P26A_NEW_DENY='(^|[^[:alnum:]_])new([[:space:]]|\[)'
P26A_DYNAMIC_DENY='std::(vector|deque|list|forward_list|map|multimap|unordered_map|unordered_multimap|set|multiset|unordered_set|unordered_multiset|basic_string|string|wstring|u8string|u16string|u32string|unique_ptr|shared_ptr|weak_ptr|function|any)([^[:alnum:]_]|$)'
if grep -En "$P26A_NEW_DENY|$P26A_DYNAMIC_DENY" \
    "${capability_files[@]}"; then
  echo 'P2.6a host-neutral contract uses dynamic allocation or storage'
  exit 1
fi
if ! printf '%s\n' 'int* p = new int(7);' |
    grep -Eq "$P26A_NEW_DENY"; then
  echo 'P2.6a standalone new witness escaped the allocation gate'
  exit 1
fi
if ! printf '%s\n' 'std::vector<int> values;' |
    grep -Eq "$P26A_DYNAMIC_DENY"; then
  echo 'P2.6a dynamic container witness escaped the storage gate'
  exit 1
fi

printf '#include "graphics/iosdevicecapabilities.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosdevicecapabilities.cpp \
  game/graphics/iosdevicecapabilities.cpp \
  -o "$RUNNER_TEMP/iosdevicecapabilities"
"$RUNNER_TEMP/iosdevicecapabilities"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosdevicecapabilities.cpp \
  game/graphics/iosdevicecapabilities.cpp \
  -o "$RUNNER_TEMP/iosdevicecapabilities-sanitized"
"$RUNNER_TEMP/iosdevicecapabilities-sanitized"

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -fsyntax-only \
  game/graphics/iosdevicecapabilities.cpp \
  ios/tests/iosdevicecapabilities.cpp

python3 - <<'PY'
from pathlib import Path
import re

header = Path(
    "game/graphics/iosdevicecapabilities.h"
).read_text()
source = Path(
    "game/graphics/iosdevicecapabilities.cpp"
).read_text()
test = Path(
    "ios/tests/iosdevicecapabilities.cpp"
).read_text()

def compact(text):
    return "".join(text.split())

def enum_values(text, name):
    match = re.search(
        rf"enum class {name}\s*:\s*uint8_t\s*\{{(.*?)\}};",
        text,
        re.S,
    )
    if match is None:
        raise ValueError(f"missing enum {name}")
    return re.findall(r"(\w+)\s*=\s*(\d+)u", match.group(1))

def offsets(text, type_name):
    return [
        (field, int(value))
        for field, value in re.findall(
            rf"static_assert\(offsetof\({type_name},"
            rf"(\w+)\)==(\d+)u\);",
            text,
        )
    ]

def ordered(text, anchors, label):
    positions = [text.index(anchor) for anchor in anchors]
    if positions != sorted(positions):
        raise ValueError(f"{label} order changed")

def validate(candidate_header, candidate_source, candidate_test):
    expected_directives = (
        (
            "#pragma once",
            "#include <cstddef>",
            "#include <cstdint>",
            "#include <optional>",
            "#include <type_traits>",
        ),
        (
            '#include "iosdevicecapabilities.h"',
            "#include <utility>",
        ),
        (
            '#include "graphics/iosdevicecapabilities.h"',
            "#include <cassert>",
            "#include <cstddef>",
            "#include <cstdint>",
            "#include <type_traits>",
            "#include <utility>",
        ),
    )
    candidates = (
        candidate_header,
        candidate_source,
        candidate_test,
    )
    for candidate, expected in zip(candidates, expected_directives):
        directives = tuple(
            line.strip()
            for line in re.findall(
                r"^[ \t]*(?:#|%:).*$",
                candidate,
                re.M,
            )
        )
        if directives != expected:
            raise ValueError("preprocessor directive set changed")
    combined = "\n".join(candidates)
    if re.search(
        r"(^|[^A-Za-z0-9_])new(?:\s|\[)",
        combined,
        re.M,
    ):
        raise ValueError("standalone new entered host-neutral files")
    if re.search(
        r"std::(?:vector|deque|list|forward_list|map|multimap|"
        r"unordered_map|unordered_multimap|set|multiset|"
        r"unordered_set|unordered_multiset|basic_string|string|"
        r"wstring|u8string|u16string|u32string|unique_ptr|"
        r"shared_ptr|weak_ptr|function|any)(?:[^A-Za-z0-9_]|$)",
        combined,
    ):
        raise ValueError("dynamic storage entered host-neutral files")

    if enum_values(
        candidate_header, "IOSDeviceProbeId"
    ) != [
        ("MetalFxSpatial","0"),
        ("MetalFxTemporal","1"),
        ("MeshShading","2"),
        ("RayTracing","3"),
        ("Metal4Transport","4"),
        ("Count","5"),
    ]:
        raise ValueError("probe ordinals changed")
    if enum_values(
        candidate_header, "IOSDeviceFormatId"
    ) != [
        ("Rg11B10Float","0"),
        ("Rgba16Float","1"),
        ("Rg16Float","2"),
        ("Depth16Unorm","3"),
        ("Depth32Float","4"),
        ("Count","5"),
    ]:
        raise ValueError("format ordinals changed")
    if enum_values(
        candidate_header, "IOSDeviceLimitId"
    ) != [
        ("MaxTexture2DDimensionPixels","0"),
        ("ComputeMaxGroupsX","1"),
        ("ComputeMaxGroupsY","2"),
        ("ComputeMaxGroupsZ","3"),
        ("ComputeMaxGroupSizeX","4"),
        ("ComputeMaxGroupSizeY","5"),
        ("ComputeMaxGroupSizeZ","6"),
        ("ComputeMaxInvocations","7"),
        ("ComputeMaxSharedMemoryBytes","8"),
        ("MeshMaxGroupsX","9"),
        ("MeshMaxGroupsY","10"),
        ("MeshMaxGroupsZ","11"),
        ("MeshMaxGroupSizeX","12"),
        ("MeshMaxGroupSizeY","13"),
        ("MeshMaxGroupSizeZ","14"),
        ("Count","15"),
    ]:
        raise ValueError("limit ordinals changed")
    if enum_values(
        candidate_header, "IOSDeviceFactsError"
    ) != [
        ("None","0"),
        ("AbiVersionMismatch","1"),
        ("StructSizeMismatch","2"),
        ("ProbeContractVersionMismatch","3"),
        ("FlagsNonZero","4"),
        ("ProbeCountMismatch","5"),
        ("FormatCountMismatch","6"),
        ("LimitCountMismatch","7"),
        ("VersionUnknownTupleNonZero","8"),
        ("VersionReservedNonZero","9"),
        ("HighestKnownAppleFamilyOutOfRange","10"),
        ("HighestKnownMetalFamilyOutOfRange","11"),
        ("ReservedNonZero","12"),
        ("ProbeOrder","13"),
        ("ProbeRequiredStagesMismatch","14"),
        ("ProbeKnownStagesOutsideRequired","15"),
        ("ProbePassedStagesOutsideKnown","16"),
        ("ProbeDeviceSupportWithoutAvailability","17"),
        ("FormatRequiredUsagesMismatch","18"),
        ("FormatKnownUsagesOutsideRequired","19"),
        ("FormatSupportedUsagesOutsideKnown","20"),
        ("LimitKnownMaskOutOfRange","21"),
        ("UnknownLimitValueNonZero","22"),
    ]:
        raise ValueError("error ordinals changed")
    if enum_values(
        candidate_header, "IOSDeviceFactsSection"
    ) != [
        ("None","0"),
        ("Header","1"),
        ("RuntimeVersion","2"),
        ("SdkVersion","3"),
        ("Families","4"),
        ("ReservedHeader","5"),
        ("Probe","6"),
        ("Format","7"),
        ("Limit","8"),
        ("ReservedTail","9"),
    ]:
        raise ValueError("section ordinals changed")

    compact_header = compact(candidate_header)
    required_header = (
        "IOSDeviceFactsABIVersion=1u;",
        "IOSDeviceFactsStructSize=192u;",
        "IOSDeviceProbeContractVersion=1u;",
        "enumIOSDeviceProbeStage:uint8_t{"
        "Availability=1u<<0u,DeviceSupport=1u<<1u,};",
        "structProbeFactsfinal{uint8_trequiredStages;"
        "uint8_tknownStages;uint8_tpassedStages;"
        "uint8_tprobeId;};",
        "enumIOSDeviceFormatUsage:uint8_t{"
        "Sampled=1u<<0u,ColorAttachment=1u<<1u,"
        "DepthAttachment=1u<<2u,ShaderWrite=1u<<3u,};",
        "structFormatFactsfinal{uint8_trequiredUsages;"
        "uint8_tknownUsages;uint8_tsupportedUsages;"
        "uint8_treserved;};",
        "structIOSVersionTripletfinal{uint16_tmajor;"
        "uint16_tminor;uint16_tpatch;uint16_treserved;};",
        "uint8_treservedHeader[3];ProbeFactsprobes[5];"
        "FormatFactsformats[5];uint32_tknownLimitMask;"
        "uint32_tlimits[15];uint32_treserved[12];",
        "staticIOSDeviceFactsCreateResultcreate("
        "constIOSDeviceFactsData&data)noexcept;",
        "IOSDeviceFacts()=delete;",
        "constIOSDeviceFactsData&facts()constnoexcept;",
        "IOSDeviceFactsDatadata_;",
        "std::optional<IOSDeviceFacts>value;"
        "IOSDeviceFactsFailurefailure;",
    )
    for literal in required_header:
        if compact_header.count(literal) != 1:
            raise ValueError(
                "frozen header contract changed: " + literal
            )

    if offsets(
        candidate_header, "IOSDeviceFactsData"
    ) != [
        ("abiVersion",0),
        ("structSize",4),
        ("probeContractVersion",8),
        ("flags",12),
        ("runtimeVersion",16),
        ("sdkVersion",24),
        ("highestKnownAppleFamily",32),
        ("highestKnownMetalFamily",33),
        ("probeCount",34),
        ("formatCount",35),
        ("limitCount",36),
        ("reservedHeader",37),
        ("probes",40),
        ("formats",60),
        ("knownLimitMask",80),
        ("limits",84),
        ("reserved",144),
    ]:
        raise ValueError("data offsets changed")
    if offsets(
        candidate_header, "IOSDeviceFactsFailure"
    ) != [
        ("error",0),
        ("section",1),
        ("index",2),
        ("reserved",3),
        ("raw",4),
    ]:
        raise ValueError("failure offsets changed")

    required_traits = (
        "static_assert(std::is_final_v<IOSDeviceFacts>);",
        "static_assert(sizeof(IOSDeviceFacts)==192u);",
        "static_assert(alignof(IOSDeviceFacts)==4u);",
        "static_assert(std::is_standard_layout_v<IOSDeviceFacts>);",
        "static_assert(std::is_trivially_copyable_v<IOSDeviceFacts>);",
        "static_assert(std::is_trivially_destructible_v<IOSDeviceFacts>);",
        "static_assert(!std::is_copy_assignable_v<IOSDeviceFacts>);",
        "static_assert(!std::is_move_assignable_v<IOSDeviceFacts>);",
        "assert(mutations==155u);",
    )
    for literal in required_traits:
        if candidate_test.count(literal) != 1:
            raise ValueError(
                "test trait or mutation marker changed: " + literal
            )

    outer = (
        "if(data.abiVersion!=IOSDeviceFactsABIVersion)",
        "if(data.structSize!=IOSDeviceFactsStructSize)",
        "if(data.probeContractVersion!="
        "IOSDeviceProbeContractVersion)",
        "if(data.flags!=0u)",
        "if(data.probeCount!=ProbeCount)",
        "if(data.formatCount!=FormatCount)",
        "if(data.limitCount!=LimitCount)",
        "data.runtimeVersion,\n"
        "          IOSDeviceFactsSection::RuntimeVersion",
        "validateVersion(data.sdkVersion,"
        "IOSDeviceFactsSection::SdkVersion)",
        "if(data.highestKnownAppleFamily>10u)",
        "if(data.highestKnownMetalFamily>4u)",
        "for(uint8_t i=0u; i<3u; ++i)",
        "for(uint8_t i=0u; i<ProbeCount; ++i)",
        "for(uint8_t i=0u; i<FormatCount; ++i)",
        "if((data.knownLimitMask & ~KnownLimitMask)!=0u)",
        "for(uint8_t i=0u; i<LimitCount; ++i)",
        "for(uint8_t i=0u; i<12u; ++i)",
    )
    ordered(candidate_source,outer,"first-error traversal")
    ordered(
        candidate_source,
        (
            "IOSDeviceFactsError::ProbeOrder",
            "IOSDeviceFactsError::ProbeRequiredStagesMismatch",
            "IOSDeviceFactsError::ProbeKnownStagesOutsideRequired",
            "IOSDeviceFactsError::ProbePassedStagesOutsideKnown",
            "IOSDeviceFactsError::"
            "ProbeDeviceSupportWithoutAvailability",
        ),
        "probe first-error traversal",
    )
    ordered(
        candidate_source,
        (
            "IOSDeviceFactsError::FormatRequiredUsagesMismatch",
            "IOSDeviceFactsError::"
            "FormatKnownUsagesOutsideRequired",
            "IOSDeviceFactsError::"
            "FormatSupportedUsagesOutsideKnown",
            "IOSDeviceFactsSection::Format,i,format.reserved",
        ),
        "format first-error traversal",
    )
    ordered(
        candidate_source,
        (
            "IOSDeviceFactsError::LimitKnownMaskOutOfRange",
            "IOSDeviceFactsError::UnknownLimitValueNonZero",
        ),
        "limit first-error traversal",
    )
    if candidate_source.count(
        "IOSDeviceFactsCreateResult IOSDeviceFacts::create("
    ) != 1:
        raise ValueError("factory definition changed")
    if candidate_source.count(
        "return {std::nullopt,validation};"
    ) != 1:
        raise ValueError("failure gained a partial facts value")

validate(header,source,test)

def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError("mutation anchor is not unique: " + before)
    return text.replace(before,after,1)

def swap_once(text, first, second):
    token = "__P26A_IN_MEMORY_SWAP__"
    if token in text:
        raise ValueError("mutation token collision")
    text = replace_once(text,first,token)
    text = replace_once(text,second,first)
    return replace_once(text,token,second)

mutations = (
    ("abi",replace_once(
        header,
        "IOSDeviceFactsABIVersion = 1u",
        "IOSDeviceFactsABIVersion = 2u",
    ),source,test),
    ("size",replace_once(
        header,
        "IOSDeviceFactsStructSize = 192u",
        "IOSDeviceFactsStructSize = 191u",
    ),source,test),
    ("probe-ordinal",replace_once(
        header,
        "Metal4Transport = 4u",
        "Metal4Transport = 3u",
    ),source,test),
    ("format-ordinal",replace_once(
        header,
        "Depth32Float = 4u",
        "Depth32Float = 3u",
    ),source,test),
    ("limit-ordinal",replace_once(
        header,
        "Count = 15u",
        "Count = 14u",
    ),source,test),
    ("layout-field",replace_once(
        header,
        "ProbeFacts probes[5];",
        "ProbeFacts probes[6];",
    ),source,test),
    ("layout-offset",replace_once(
        header,
        "offsetof(IOSDeviceFactsData,probes)==40u",
        "offsetof(IOSDeviceFactsData,probes)==41u",
    ),source,test),
    ("error-ordinal",replace_once(
        header,
        "UnknownLimitValueNonZero = 22u",
        "UnknownLimitValueNonZero = 23u",
    ),source,test),
    ("section-ordinal",replace_once(
        header,
        "ReservedTail = 9u",
        "ReservedTail = 8u",
    ),source,test),
    ("factory-noexcept",replace_once(
        header,
        "const IOSDeviceFactsData& data) noexcept;",
        "const IOSDeviceFactsData& data);",
    ),source,test),
    ("mutation-marker",header,source,replace_once(
        test,"assert(mutations==155u);",
        "assert(mutations==154u);",
    )),
    ("header-order",header,swap_once(
        source,
        "if(data.abiVersion!=IOSDeviceFactsABIVersion)",
        "if(data.structSize!=IOSDeviceFactsStructSize)",
    ),test),
    ("probe-order",header,swap_once(
        source,
        "IOSDeviceFactsError::ProbeOrder",
        "IOSDeviceFactsError::ProbeRequiredStagesMismatch",
    ),test),
    ("format-order",header,swap_once(
        source,
        "IOSDeviceFactsError::FormatRequiredUsagesMismatch",
        "IOSDeviceFactsError::"
        "FormatKnownUsagesOutsideRequired",
    ),test),
    ("limit-order",header,swap_once(
        source,
        "IOSDeviceFactsError::LimitKnownMaskOutOfRange",
        "IOSDeviceFactsError::UnknownLimitValueNonZero",
    ),test),
    ("dynamic-include",header + "\n#include <vector>\n",source,test),
    ("standalone-new",header,source + (
        "\nint* p26aAllocate() { return new int(7); }\n"
    ),test),
)
mutations_killed = 0
for label, candidate_header, candidate_source, candidate_test in mutations:
    try:
        validate(candidate_header,candidate_source,candidate_test)
    except (ValueError,IndexError):
        mutations_killed += 1
    else:
        raise SystemExit(
            "P2.6a structural mutation survived: " + label
        )
if mutations_killed != 17:
    raise SystemExit("P2.6a structural mutation count drifted")
print("P2.6a structural oracle: mutations-killed=17")
PY

printf '\n### CI contract: Verify P2.6b1 native device facts collector\n'
set -euo pipefail

collector_files=(
  game/graphics/iosdevicefactscollector.h
  game/graphics/iosdevicefactscollector.cpp
  game/graphics/iosdevicefactscollector.mm
  ios/tests/iosdevicefactscollector.cpp
)
for file in "${collector_files[@]}"; do
  test -f "$file"
done
test "$(find game/graphics ios/tests -maxdepth 1 -type f \
    -name 'iosdevicefactscollector*' | LC_ALL=C sort)" = \
  $'game/graphics/iosdevicefactscollector.cpp\ngame/graphics/iosdevicefactscollector.h\ngame/graphics/iosdevicefactscollector.mm\nios/tests/iosdevicefactscollector.cpp'

printf '#include "graphics/iosdevicefactscollector.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosdevicefactscollector.cpp \
  game/graphics/iosdevicefactscollector.cpp \
  game/graphics/iosdevicecapabilities.cpp \
  -o "$RUNNER_TEMP/iosdevicefactscollector"
"$RUNNER_TEMP/iosdevicefactscollector"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosdevicefactscollector.cpp \
  game/graphics/iosdevicefactscollector.cpp \
  game/graphics/iosdevicecapabilities.cpp \
  -o "$RUNNER_TEMP/iosdevicefactscollector-sanitized"
"$RUNNER_TEMP/iosdevicefactscollector-sanitized"

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -fsyntax-only \
  game/graphics/iosdevicefactscollector.cpp \
  ios/tests/iosdevicefactscollector.cpp
xcrun clang++ -x objective-c++ -std=c++20 \
  -fno-objc-arc \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/iosdevicefactscollector.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -fno-objc-arc \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/iosdevicefactscollector.mm

test -x ios/device-test/validate-device-facts-log.py
PYTHONDONTWRITEBYTECODE=1 python3 \
  ios/device-test/validate-device-facts-log.py --self-test
ios/device-test/run-smoke-test.sh \
  --require-device-facts-reference-a17 --self-test

python3 - <<'PY'
from pathlib import Path
import re

header = Path(
    "game/graphics/iosdevicefactscollector.h"
).read_text()
mapper = Path(
    "game/graphics/iosdevicefactscollector.cpp"
).read_text()
native = Path(
    "game/graphics/iosdevicefactscollector.mm"
).read_text()
test = Path(
    "ios/tests/iosdevicefactscollector.cpp"
).read_text()
context = Path(
    "game/graphics/iosmetalcontext.cpp"
).read_text()
cmake = Path("CMakeLists.txt").read_text()
tempest_api = Path(
    "lib/Tempest/Engine/gapi/metalapi.cpp"
).read_text()
tempest_device = Path(
    "lib/Tempest/Engine/gapi/metal/mtdevice.mm"
).read_text()

def compact(text):
    return "".join(text.split())

def without_selectors(text):
    return re.sub(
        r"@selector\s*\([^)]*\)",
        "",
        text,
        flags=re.S,
    )

def function_span(text, name):
    matches = list(re.finditer(
        rf"(?m)^(?:void|IOSDeviceFactsCreateResult)\s+"
        rf"{re.escape(name)}\s*\(",
        text,
    ))
    if len(matches) != 1:
        raise ValueError(
            f"native function definition changed: {name}"
        )
    opening = text.find("{", matches[0].end())
    if opening < 0:
        raise ValueError(
            f"native function body is missing: {name}"
        )
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return opening + 1, index
    raise ValueError(
        f"native function body is unterminated: {name}"
    )

def function_body(text, name):
    start, end = function_span(text, name)
    return text[start:end]

def replace_in_function(text, name, before, after):
    start, end = function_span(text, name)
    body = text[start:end]
    if body.count(before) != 1:
        raise ValueError(
            f"mutation anchor is not unique in {name}: {before}"
        )
    return (
        text[:start]
        + body.replace(before, after, 1)
        + text[end:]
    )

def validate(
    candidate_header,
    candidate_mapper,
    candidate_native,
    candidate_context,
    candidate_cmake,
):
    neutral = "\n".join(
        (candidate_header, candidate_mapper, test)
    )
    if re.search(
        r"#import|<Metal/|<MetalFX/|@(?:try|catch|selector|"
        r"available)|\bid\s*<\s*MTL|\bMTL[A-Z]|"
        r"BorrowedMetalDevice|MetalApi::borrowDevice|"
        r"Device::properties|\.properties\s*\(",
        neutral,
    ):
        raise ValueError(
            "host-neutral snapshot/mapper leaks native collection"
        )
    if re.search(
        r"std::(?:vector|deque|list|forward_list|map|multimap|"
        r"unordered_map|unordered_multimap|set|multiset|"
        r"unordered_set|unordered_multiset|basic_string|string|"
        r"wstring|u8string|u16string|u32string|unique_ptr|"
        r"shared_ptr|weak_ptr|function|any)(?:[^A-Za-z0-9_]|$)"
        r"|(^|[^A-Za-z0-9_])new(?:\s|\[)|"
        r"\b(?:malloc|calloc|realloc)\s*\(",
        neutral,
        re.M,
    ):
        raise ValueError(
            "host-neutral snapshot/mapper uses dynamic storage"
        )
    if re.search(
        r"\biPhone[0-9,]|\biPad[0-9,]|hw\.machine|sysctl|"
        r"thermalState|IOSFeaturePolicy|device model|"
        r"performance policy",
        neutral,
        re.I,
    ):
        raise ValueError(
            "host-neutral snapshot/mapper gained model or policy"
        )
    compact_header = compact(candidate_header)
    compact_mapper = compact(candidate_mapper)
    compact_test = compact(test)
    if compact_header.count(
        "structIOSDeviceNativeSnapshotfinal{"
    ) != 1:
        raise ValueError("native snapshot seam changed")
    if compact_header.count(
        "structIOSDeviceNativeFormatfinal{"
        "uint8_tknownUsages=0u;"
        "uint8_tsupportedUsages=0u;};"
    ) != 1:
        raise ValueError("native format transport seam changed")
    if compact_header.count(
        "IOSDeviceNativeProbeprobes[5];"
        "IOSDeviceNativeFormatformats[5];"
        "uint32_tknownLimitMask=0u;"
    ) != 1:
        raise ValueError(
            "native format field order or cardinality changed"
        )
    if compact_header.count(
        "IOSDeviceFactsCreateResultiosCollectDeviceFacts("
        "constTempest::Device&device)noexcept;"
    ) != 1:
        raise ValueError("collector public API changed")
    if compact_mapper.count(
        "IOSDeviceFactsCreateResultiosMapDeviceNativeSnapshot("
        "constIOSDeviceNativeSnapshot&snapshot)noexcept{"
    ) != 1:
        raise ValueError("snapshot mapper definition changed")
    required_format_table = (
        "constexpruint8_tRequiredFormatUsages[FormatCount]="
        "{0x0Bu,0x0Bu,0x03u,0x05u,0x05u,};"
    )
    if compact_mapper.count(required_format_table) != 1:
        raise ValueError("native format required masks changed")
    format_assignments = (
        "result.formats[i].requiredUsages="
        "RequiredFormatUsages[i];",
        "result.formats[i].knownUsages="
        "snapshot.formats[i].knownUsages;",
        "result.formats[i].supportedUsages="
        "snapshot.formats[i].supportedUsages;",
    )
    for assignment in format_assignments:
        if compact_mapper.count(assignment) != 1:
            raise ValueError(
                "native format raw assignment changed: "
                + assignment
            )
    if (
        compact_mapper.count("result.formats[") != 3
        or compact_mapper.count("snapshot.formats[") != 2
    ):
        raise ValueError(
            "native format mapper gained normalization or another copy"
        )
    if compact_mapper.count(
        "returnIOSDeviceFacts::create(result);"
    ) != 1:
        raise ValueError(
            "existing facts factory is not the sole final validator"
        )
    required_test_contract = (
        "static_assert(sizeof(IOSDeviceNativeFormat)==2u);",
        "static_assert(alignof(IOSDeviceNativeFormat)==1u);",
        "static_assert(offsetof(IOSDeviceNativeFormat,"
        "knownUsages)==0u);",
        "static_assert(offsetof(IOSDeviceNativeFormat,"
        "supportedUsages)==1u);",
        "static_assert(std::is_standard_layout_v<"
        "IOSDeviceNativeFormat>);",
        "static_assert(std::is_trivially_copyable_v<"
        "IOSDeviceNativeFormat>);",
        "assert(requiredStateRecords==12u);",
        "assert(outsideRequiredPairs==8u);",
        "IOSDeviceNativeSnapshotfullFormats;",
        "IOSDeviceNativeSnapshotsubsetFormats;",
        "IOSDeviceNativeSnapshotrawKnown;",
        "IOSDeviceNativeSnapshotrawSupported;",
        "IOSDeviceNativeSnapshotknownBeforeSupported;",
        "IOSDeviceNativeSnapshotlowerSupportedBeforeKnown;",
        "IOSDeviceFactsDataprobeBeforeFormat=",
        "IOSDeviceFactsDataformatBeforeLimit=",
        "static_assert(std::is_standard_layout_v<"
        "IOSDeviceNativeSnapshot>);",
        "static_assert(std::is_trivially_copyable_v<"
        "IOSDeviceNativeSnapshot>);",
        "decltype(&iosCollectDeviceFacts),CollectorSignature>);",
        "decltype(&iosLogDeviceFacts),LoggerSignature>);",
    )
    for anchor in required_test_contract:
        if compact_test.count(anchor) != 1:
            raise ValueError(
                "collector seam test contract changed: " + anchor
            )

    if candidate_native.count(
        "Tempest::MetalApi::borrowDevice(owner)"
    ) != 1:
        raise ValueError(
            "collector does not have exactly one local device borrow"
        )
    if re.search(
        r"MTLCreateSystemDefaultDevice|"
        r"MTL::CreateSystemDefaultDevice|"
        r"Device::properties|\.properties\s*\(",
        candidate_native,
    ):
        raise ValueError(
            "collector creates or substitutes a native device"
        )
    if re.search(
        r"BorrowedMetalDevice\s+\w+\s*[;=]",
        candidate_header,
    ):
        raise ValueError("borrowed device escaped into stored state")
    if re.search(
        r"\b(?:retain|release|autorelease)\s*\]|"
        r"\bCFBridgingRetain\b|\b__bridge_retained\b",
        candidate_native,
    ):
        raise ValueError("collector changes native ownership")

    exception_scopes = {
        "queryAppleFamily": 1,
        "queryMetalFamily": 1,
        "collectRuntimeVersion": 1,
        "collectSdkVersion": 0,
        "collectAppleFamilies": 0,
        "collectMetalFamilies": 0,
        "collectSpatialProbe": 2,
        "collectTemporalProbe": 2,
        "collectMeshProbe": 1,
        "collectRayTracingProbe": 2,
        "collectMetal4Probe": 2,
        "collectLimit": 0,
        "collectLimits": 4,
        "iosCollectDeviceFacts": 0,
    }
    if (
        candidate_native.count("@try") != 16
        or candidate_native.count("@catch") != 16
    ):
        raise ValueError(
            "native exception-scope total changed"
        )
    for function, expected in exception_scopes.items():
        body = function_body(candidate_native, function)
        actual_try = body.count("@try")
        actual_catch = body.count("@catch")
        if (
            actual_try != expected
            or actual_catch != expected
        ):
            raise ValueError(
                "native exception-scope distribution changed: "
                f"{function}={actual_try}/{actual_catch}, "
                f"expected={expected}/{expected}"
            )

    selectors = [
        "".join(match.split())
        for match in re.findall(
            r"@selector\s*\(([^)]*)\)",
            candidate_native,
            re.S,
        )
    ]
    mesh_selector = (
        "newRenderPipelineStateWithMeshDescriptor:"
        "options:reflection:error:"
    )
    if selectors.count(mesh_selector) != 1:
        raise ValueError("exact Mesh selector changed")
    if selectors.count("newMTL4CommandQueue") != 1:
        raise ValueError("exact Metal4 selector changed")
    if selectors.count("supportsDevice:") != 2:
        raise ValueError("typed MetalFX availability selectors changed")
    if selectors.count("supportsRaytracing") != 1:
        raise ValueError("exact compute RT selector changed")
    if "supportsRaytracingFromRender" in candidate_native:
        raise ValueError("RT probe changed away from compute semantics")
    metalfx_anchors = (
        "[MTLFXSpatialScalerDescriptor class]",
        "[MTLFXSpatialScalerDescriptor supportsDevice:device]",
        "[MTLFXTemporalScalerDescriptor class]",
        "[MTLFXTemporalScalerDescriptor supportsDevice:device]",
    )
    for anchor in metalfx_anchors:
        if candidate_native.count(anchor) != 1:
            raise ValueError(
                "typed MetalFX query changed: " + anchor
            )
    if candidate_native.count(
        "[device supportsRaytracing]"
    ) != 1:
        raise ValueError("exact compute RT device query changed")
    for family in range(1, 11):
        if len(re.findall(
            rf"\bMTLGPUFamilyApple{family}\b",
            candidate_native,
        )) != 1:
            raise ValueError(
                f"Apple{family} family query changed"
            )
    if candidate_native.count("MTLGPUFamilyMetal3") != 1:
        raise ValueError("Metal3 family query changed")
    if candidate_native.count("MTLGPUFamilyMetal4") != 2:
        raise ValueError("Metal4 family/probe query changed")
    if candidate_native.count(
        "[device maxThreadsPerThreadgroup]"
    ) != 3:
        raise ValueError(
            "threadgroup X/Y/Z direct queries changed"
        )
    if candidate_native.count(
        "[device maxThreadgroupMemoryLength]"
    ) != 1:
        raise ValueError(
            "threadgroup-memory direct query changed"
        )
    mesh_body = candidate_native.split(
        "void collectMeshProbe(", 1
    )[1].split("void collectRayTracingProbe(", 1)[0]
    if "setSupport(" in mesh_body:
        raise ValueError("Mesh gained inferred DeviceSupport")
    if re.search(
        r"MTLPixelFormat|supportsTextureSampleCount|"
        r"minimumLinearTextureAlignment|"
        r"minimumTextureBufferAlignment",
        candidate_native,
    ):
        raise ValueError("b1 collector started mapping formats")

    executable_native = without_selectors(candidate_native)
    forbidden_calls = (
        r"\[[^\]]*\bnew(?:RenderPipelineState|"
        r"ComputePipelineState|MTL4CommandQueue|CommandQueue|"
        r"CommandBuffer|Library|Buffer|Texture|Heap|SamplerState|"
        r"ArgumentEncoder|AccelerationStructure|"
        r"IndirectCommandBuffer)[A-Za-z0-9_]*(?:\s*:|\s*\])"
    )
    if re.search(forbidden_calls, executable_native, re.S):
        raise ValueError(
            "selector availability check became a native factory call"
        )
    no_work_calls = (
        r"\[[^\]]+\s+(?:commit|enqueue|submit|presentDrawable|"
        r"addCompletedHandler|commandBuffer|renderCommandEncoder|"
        r"computeCommandEncoder|blitCommandEncoder|"
        r"resourceStateCommandEncoder|newSpatialScaler|"
        r"newTemporalScaler)[A-Za-z0-9_]*\b"
        r"|(?:\.|->)(?:commit|enqueue|submit|present|"
        r"startEncoding|commandBuffer)\s*\("
        r"|newLibraryWithSource|newLibraryWithURL|"
        r"newDefaultLibrary|MTLCompileOptions|MTLBinaryArchive"
    )
    if re.search(no_work_calls, executable_native, re.S):
        raise ValueError("collector creates or submits GPU work")
    if re.search(
        r"\bMTL(?:CommandQueue|CommandBuffer|RenderCommandEncoder|"
        r"ComputeCommandEncoder|RenderPipelineState|"
        r"ComputePipelineState|Texture|Buffer|Heap|Fence|Event|"
        r"SharedEvent|IndirectCommandBuffer|AccelerationStructure)\b",
        executable_native,
    ):
        raise ValueError(
            "collector owns GPU work or a created resource"
        )

    compact_context = compact(candidate_context)
    if compact_context.count(
        "constIOSDeviceFactsCreateResultdeviceFacts;"
    ) != 1:
        raise ValueError("stored const facts result changed")
    if compact_context.count(
        "deviceFacts(iosCollectDeviceFacts(device))"
    ) != 1:
        raise ValueError(
            "collector is not constructed exactly once in the "
            "initializer list"
        )
    if compact_context.count("iosCollectDeviceFacts(") != 1:
        raise ValueError("collector caller cardinality changed")
    if compact_context.count(
        "iosLogDeviceFacts(deviceFacts);"
    ) != 1:
        raise ValueError("stored result is not logged exactly once")
    declarations = (
        compact_context.index("Device&device;"),
        compact_context.index(
            "constIOSDeviceFactsCreateResultdeviceFacts;"
        ),
        compact_context.index(
            "IOSMetalResourceAllocatorresourceAllocator;"
        ),
    )
    if declarations != tuple(sorted(declarations)):
        raise ValueError(
            "device/facts/allocator ownership order changed"
        )
    constructor = (
        compact_context.index(":device(device),"),
        compact_context.index(
            "deviceFacts(iosCollectDeviceFacts(device))"
        ),
        compact_context.index("resourceAllocator(device)"),
    )
    if constructor != tuple(sorted(constructor)):
        raise ValueError(
            "device/facts/allocator construction order changed"
        )
    residual_context = compact_context.replace(
        "deviceFacts(iosCollectDeviceFacts(device))", ""
    )
    if re.search(r"\bdeviceFacts=", residual_context):
        raise ValueError("stored facts gained later assignment")

    weak_literal = '"-weak_frameworkMetalFX"'
    compact_cmake = compact(candidate_cmake)
    if compact_cmake.count(weak_literal) != 1:
        raise ValueError(
            "final iOS target does not weak-link MetalFX exactly once"
        )
    if '"-frameworkMetalFX"' in compact_cmake:
        raise ValueError("final iOS target strongly links MetalFX")

    if candidate_native.count(
        "RendererIOS device facts:"
    ) != 1:
        raise ValueError("device-facts marker source changed")
    if (
        "sizeof(MarkerPrefix)+sizeof(MaximumMarkerTail)-1u<250u"
        not in compact(candidate_native)
    ):
        raise ValueError("device-facts marker length gate changed")

    if tempest_api.count(
        "MTL::CreateSystemDefaultDevice()"
    ) != 1:
        raise ValueError("Tempest enumeration device baseline changed")
    if tempest_device.count(
        "MTL::CreateSystemDefaultDevice()"
    ) != 2:
        raise ValueError("Tempest startup device branch baseline changed")

validate(header, mapper, native, context, cmake)

def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(
            "mutation anchor is not unique: " + before
        )
    return text.replace(before, after, 1)

migrated_exception_scope = replace_in_function(
    native,
    "queryAppleFamily",
    "@try {",
    "{",
)
migrated_exception_scope = replace_in_function(
    migrated_exception_scope,
    "queryAppleFamily",
    "@catch(NSException*) {\n  }",
    "",
)
migrated_exception_scope = replace_in_function(
    migrated_exception_scope,
    "collectAppleFamilies",
    "#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE10",
    "@try {}\n"
    "@catch(NSException*) {}\n"
    "#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE10",
)

factory_witness = (
    "\nvoid p26b1FactoryWitness(id<MTLDevice> device) {\n"
    "  [device newRenderPipelineStateWithMeshDescriptor:nil "
    "options:0 reflection:nil error:nil];\n"
    "}\n"
)
required_table_source = (
    "constexpr uint8_t RequiredFormatUsages[FormatCount] = {\n"
    "  0x0Bu,0x0Bu,0x03u,0x05u,0x05u,\n"
    "  };"
)
required_table_mutations = (
    ("required-rg11b10", "0x01u,0x0Bu,0x03u,0x05u,0x05u"),
    ("required-rgba16", "0x0Bu,0x01u,0x03u,0x05u,0x05u"),
    ("required-rg16", "0x0Bu,0x0Bu,0x01u,0x05u,0x05u"),
    ("required-depth16", "0x0Bu,0x0Bu,0x03u,0x01u,0x05u"),
    ("required-depth32", "0x0Bu,0x0Bu,0x03u,0x05u,0x01u"),
)
format_mutations = [
    (
        label,
        header,
        mapper.replace(
            required_table_source,
            "constexpr uint8_t RequiredFormatUsages[FormatCount] = {\n"
            f"  {values},\n"
            "  };",
            1,
        ),
        native,
        context,
        cmake,
    )
    for label, values in required_table_mutations
]
format_mutations.extend((
    (
        "missing-format-known-copy",
        header,
        replace_once(
            mapper,
            "result.formats[i].knownUsages =\n"
            "        snapshot.formats[i].knownUsages;",
            "(void)snapshot.formats[i].knownUsages;",
        ),
        native,
        context,
        cmake,
    ),
    (
        "replaced-format-known-copy",
        header,
        replace_once(
            mapper,
            "snapshot.formats[i].knownUsages;",
            "snapshot.formats[i].supportedUsages;",
        ),
        native,
        context,
        cmake,
    ),
    (
        "masked-format-known-copy",
        header,
        replace_once(
            mapper,
            "snapshot.formats[i].knownUsages;",
            "snapshot.formats[i].knownUsages & "
            "RequiredFormatUsages[i];",
        ),
        native,
        context,
        cmake,
    ),
    (
        "missing-format-supported-copy",
        header,
        replace_once(
            mapper,
            "result.formats[i].supportedUsages =\n"
            "        snapshot.formats[i].supportedUsages;",
            "(void)snapshot.formats[i].supportedUsages;",
        ),
        native,
        context,
        cmake,
    ),
    (
        "replaced-format-supported-copy",
        header,
        replace_once(
            mapper,
            "snapshot.formats[i].supportedUsages;",
            "snapshot.formats[i].knownUsages;",
        ),
        native,
        context,
        cmake,
    ),
    (
        "masked-format-supported-copy",
        header,
        replace_once(
            mapper,
            "snapshot.formats[i].supportedUsages;",
            "snapshot.formats[i].supportedUsages & "
            "snapshot.formats[i].knownUsages;",
        ),
        native,
        context,
        cmake,
    ),
    (
        "format-field-order",
        replace_once(
            header,
            "  IOSDeviceNativeProbe probes[5];\n"
            "  IOSDeviceNativeFormat formats[5];",
            "  IOSDeviceNativeFormat formats[5];\n"
            "  IOSDeviceNativeProbe probes[5];",
        ),
        mapper,
        native,
        context,
        cmake,
    ),
    (
        "format-cardinality",
        replace_once(
            header,
            "  IOSDeviceNativeFormat formats[5];",
            "  IOSDeviceNativeFormat formats[4];",
        ),
        mapper,
        native,
        context,
        cmake,
    ),
))
mutations = (
    (
        "duplicate-borrow",
        header,
        mapper,
        native.replace(
            "Tempest::MetalApi::borrowDevice(owner)",
            "Tempest::MetalApi::borrowDevice(owner); "
            "Tempest::MetalApi::borrowDevice(owner)",
            1,
        ),
        context,
        cmake,
    ),
    (
        "actual-mesh-factory-call",
        header,
        mapper,
        native + factory_witness,
        context,
        cmake,
    ),
    (
        "create-default-device",
        header,
        mapper,
        native + "\nauto p26b1Device = "
        "MTL::CreateSystemDefaultDevice();\n",
        context,
        cmake,
    ),
    (
        "missing-metalfx-selector",
        header,
        mapper,
        native.replace(
            "@selector(supportsDevice:)",
            "@selector(description)",
            1,
        ),
        context,
        cmake,
    ),
    (
        "rt-from-render",
        header,
        mapper,
        replace_once(
            native,
            "@selector(supportsRaytracing)",
            "@selector(supportsRaytracingFromRender)",
        ),
        context,
        cmake,
    ),
    (
        "metalfx-scaler-factory",
        header,
        mapper,
        native + (
            "\nvoid p26b1ScalerWitness() { "
            "[MTLFXSpatialScalerDescriptor "
            "newSpatialScalerWithDevice:nil]; }\n"
        ),
        context,
        cmake,
    ),
    (
        "command-commit",
        header,
        mapper,
        native + (
            "\nvoid p26b1CommitWitness(id device) { "
            "[device commit]; }\n"
        ),
        context,
        cmake,
    ),
    (
        "actual-metal4-factory",
        header,
        mapper,
        native + (
            "\nvoid p26b1Metal4Witness(id<MTLDevice> device) { "
            "[device newMTL4CommandQueue]; }\n"
        ),
        context,
        cmake,
    ),
    (
        "dynamic-neutral-storage",
        header,
        mapper + "\nstd::vector<int> p26b1Dynamic;\n",
        native,
        context,
        cmake,
    ),
    (
        "model-policy-neutral",
        header,
        mapper + "\nconst char* p26b1Model = \"iPhone16,2\";\n",
        native,
        context,
        cmake,
    ),
    (
        "missing-apple-family",
        header,
        mapper,
        replace_once(
            native,
            "MTLGPUFamilyApple7",
            "MTLGPUFamilyApple6",
        ),
        context,
        cmake,
    ),
    (
        "missing-direct-limit",
        header,
        mapper,
        replace_once(
            native,
            "[device maxThreadgroupMemoryLength]",
            "[device description]",
        ),
        context,
        cmake,
    ),
    (
        "present-drawable",
        header,
        mapper,
        native + (
            "\nvoid p26b1PresentWitness(id device) { "
            "[device presentDrawable:nil]; }\n"
        ),
        context,
        cmake,
    ),
    (
        "create-command-queue",
        header,
        mapper,
        native + (
            "\nvoid p26b1QueueWitness(id<MTLDevice> device) { "
            "[device newCommandQueue]; }\n"
        ),
        context,
        cmake,
    ),
    (
        "create-buffer",
        header,
        mapper,
        native + (
            "\nvoid p26b1BufferWitness(id<MTLDevice> device) { "
            "[device newBufferWithLength:4 options:0]; }\n"
        ),
        context,
        cmake,
    ),
    (
        "stored-borrow",
        header + "\nTempest::BorrowedMetalDevice stored;\n",
        mapper,
        native,
        context,
        cmake,
    ),
    (
        "duplicate-caller",
        header,
        mapper,
        native,
        context.replace(
            "deviceFacts(iosCollectDeviceFacts(device))",
            "deviceFacts(iosCollectDeviceFacts(device)), "
            "p26b1Duplicate(iosCollectDeviceFacts(device))",
            1,
        ),
        cmake,
    ),
    (
        "migrated-exception-scope",
        header,
        mapper,
        migrated_exception_scope,
        context,
        cmake,
    ),
    (
        "strong-metalfx",
        header,
        mapper,
        native,
        context,
        replace_once(
            cmake,
            '"-weak_framework MetalFX"',
            '"-framework MetalFX"',
        ),
    ),
) + tuple(format_mutations)
mutations_killed = 0
for label, h, m, n, c, build in mutations:
    try:
        validate(h, m, n, c, build)
    except (ValueError, IndexError):
        mutations_killed += 1
    else:
        raise SystemExit(
            "P2.6b1 source mutation survived: " + label
        )
if mutations_killed != 32:
    raise SystemExit(
        "P2.6b1+b2a source mutation count drifted"
    )
print("P2.6b1+b2a source oracle: mutations-killed=32")
PY

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

printf '\n### CI contract: Verify P2.3b resource allocator contract\n'
set -euo pipefail

allocator_files=(
  game/graphics/iosmetalresourceallocator.h
  game/graphics/iosmetalresourceallocator.cpp
  game/graphics/iosmetalresourceallocator.mm
)
for file in "${allocator_files[@]}" ios/tests/iosmetalresourceallocator.cpp; do
  test -f "$file"
done

if grep -nE \
    '#import|<Metal/|Objective-C|id[[:space:]]*<|void[[:space:]]*\*|MTL[A-Z]' \
    game/graphics/iosmetalresourceallocator.h; then
  echo 'P2.3b public allocator contract is not host-neutral'
  exit 1
fi

if grep -nE \
    'MTLHeap|newHeap|[Hh]eap|sizeAndAlign|makeAliasable|supportsFamily|supportsTextureSampleCount|newCommandQueue|MTLCommandQueue|MTLCommandBuffer|MTL.*CommandEncoder|MTLRenderPass|renderCommandEncoder|computeCommandEncoder|blitCommandEncoder|renderPassDescriptor|Tempest::(CommandBuffer|Encoder)|commandBuffer|setFramebuffer|submit|FrameContext|IOSMetalResourceIntent' \
    "${allocator_files[@]}"; then
  echo 'P2.3b allocator escaped the D-050 allocation-only scope'
  exit 1
fi
if [[ "$(grep -Ec \
    '^[[:space:]]*inline constexpr uint32_t IOSFramePlanABIVersion[[:space:]]*=[[:space:]]*4u;[[:space:]]*$' \
    game/graphics/iosframeplan.h)" -ne 1 ]]; then
  echo 'P2.3b frozen IOSFramePlan ABI 4 declaration is missing or ambiguous'
  exit 1
fi

xcrun clang++ -std=c++20 \
  -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame -isystem lib/Tempest/Engine/include \
  ios/tests/iosmetalresourceallocator.cpp \
  game/graphics/iosmetalresourceallocator.cpp \
  -o "$RUNNER_TEMP/iosmetalresourceallocator"
"$RUNNER_TEMP/iosmetalresourceallocator"

xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
  -arch arm64 -miphoneos-version-min=16.4 -fno-objc-arc \
  -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include -fsyntax-only \
  game/graphics/iosmetalresourceallocator.mm
xcrun clang++ -x objective-c++ -std=c++20 -fno-objc-arc \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include -fsyntax-only \
  game/graphics/iosmetalresourceallocator.mm

test -x ios/device-test/validate-resource-allocator-self-test-log.py
python3 ios/device-test/validate-resource-allocator-self-test-log.py --self-test
ios/device-test/run-smoke-test.sh \
  --require-resource-allocator-self-test --self-test
if ios/device-test/run-smoke-test.sh \
    --require-resource-allocator-self-test \
    --require-bink-self-test --self-test; then
  echo 'resource allocator/Bink harness conflict survived'
  exit 1
fi
if ios/device-test/run-smoke-test.sh \
    --require-resource-allocator-self-test \
    --expected-fault post-submit-suboptimal --self-test; then
  echo 'resource allocator/fault harness conflict survived'
  exit 1
fi
if OPENGOTHIC_IOS_EXPECTED_FAULT=post-submit-suboptimal \
    ios/device-test/run-smoke-test.sh \
    --require-resource-allocator-self-test --self-test; then
  echo 'resource allocator host profile accepted an injected fault'
  exit 1
fi
grep -Fq -- '--require-resource-allocator-self-test' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'validate_resource_allocator_binary_profile()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'unrequested resource allocator binary profile survived' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'RESOURCE_ALLOCATOR_SELF_TEST_PID' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'build/device-self-test/%s/resource-allocator\n' \
  ios/device-test/run-smoke-test.sh
grep -Fq "printf '%s/%s-%s-%s\\n'" \
  ios/device-test/run-smoke-test.sh
grep -Fq 'resource_allocator_self_test_process_survived=' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'processes.json processes-id3-window-start.json' \
  ios/device-test/run-smoke-test.sh
grep -Fq -- '--expect-absent' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'ensure_durable_zero || fail "durable final application cleanup failed"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_crash_state final' \
  ios/device-test/run-smoke-test.sh

python3 - <<'PY'
from pathlib import Path
import re

context = Path("game/graphics/iosmetalcontext.cpp").read_text()
native = Path("game/graphics/iosmetalresourceallocator.mm").read_text()
harness = Path("ios/device-test/run-smoke-test.sh").read_text()
armed = (
    "RendererIOS resource allocator self-test: ARMED "
    "case=private-memoryless-4x4-rgba8-v1"
)
passed = (
    "allocation-only=1 encoded=0 render-pass=0 submitted=0 "
    "created=2 live=0 released=2"
)
if context.count(armed) != 1 or context.count(passed) != 1:
    raise SystemExit("resource allocator device markers are not exact and unique")
ownership = (
    r"\bIOSMetalResourceAllocator\s+resourceAllocator\s*;",
    r"\bresourceAllocator\s*\(\s*device\s*\)",
    r"runIOSResourceAllocatorSelfTest\s*\(\s*resourceAllocator\s*,\s*device\s*\)\s*;",
)
for contract in ownership:
    if len(re.findall(contract, context)) != 1:
        raise SystemExit(
            f"resource allocator Impl ownership contract is not unique: {contract}"
        )
if re.search(r"\bIOSMetalResourceAllocator\s+allocator\s*\(", context):
    raise SystemExit("resource allocator self-test constructs a local allocator")
if context.count('#include "iosmetalresourceallocator.h"') != 1:
    raise SystemExit("resource allocator production include is not unique")
allocator_self_test = context.split(
    "void runIOSResourceAllocatorSelfTest(", 1
)[1].split("\n#endif", 1)[0]
if allocator_self_test.count("iosMetalResourceLifetimeSnapshot()") != 3:
    raise SystemExit("resource allocator lifetime proof is not before/inside/after")
lifetime_oracle = (
    "createdDelta==2u",
    "liveInsideDelta==2u",
    "releasedInsideDelta==0u",
    "releasedDelta==2u",
    "lifetimeAfter.live==lifetimeBefore.live",
)
for contract in lifetime_oracle:
    if allocator_self_test.count(contract) != 1:
        raise SystemExit(f"resource allocator lifetime oracle is missing: {contract}")
native_lifetime_updates = (
    "ResourceLifetime.created.fetch_add(1u,std::memory_order_relaxed);",
    "ResourceLifetime.live.fetch_add(1u,std::memory_order_relaxed);",
    "ResourceLifetime.live.fetch_sub(1u,std::memory_order_relaxed);",
    "ResourceLifetime.released.fetch_add(1u,std::memory_order_relaxed);",
)
if any(native.count(update) != 1 for update in native_lifetime_updates):
    raise SystemExit("native resource owner lifetime accounting is not exact")
pid_check = harness.index(
    'str(matches[0].get("processIdentifier")) '
    '!= expected_resource_allocator_pid'
)
survived = harness.index(
    "RESOURCE_ALLOCATOR_SELF_TEST_PROCESS_SURVIVED=1"
)
stop = harness.index('echo "== stopping $BUNDLE_ID after smoke window =="')
if not pid_check < survived < stop:
    raise SystemExit("resource allocator same-PID survival proof is out of order")
if harness.count("RESOURCE_ALLOCATOR_SELF_TEST_PROCESS_SURVIVED=0") != 1:
    raise SystemExit("resource allocator survival evidence lacks one fail-closed default")
if (
    harness.count('processes.json \\') != 1
    or harness.count("processes.json processes-id3-window-start.json") != 1
):
    raise SystemExit("end process evidence is not preserved on PASS and failure")
if "IOSFramePlanABIVersion==4u" not in Path(
    "ios/tests/iosframeplan.cpp"
).read_text():
    raise SystemExit("IOSFramePlan ABI4 host gate is missing")
PY

printf '\n### CI contract: Verify P2.3c clear-only pass contract\n'
set -euo pipefail

probe_files=(
  game/graphics/iosmetalresourceclearpassprobe.h
  game/graphics/iosmetalresourceclearpassprobe.cpp
  game/graphics/iosmetalresourceclearpassprobe.mm
  game/graphics/iosmetalresourceallocatornative.h
)
for file in "${probe_files[@]}" \
    ios/tests/iosmetalresourceclearpassprobe.cpp; do
  test -f "$file"
done
test -x ios/device-test/validate-clear-only-pass-self-test-log.py
test -x ios/device-test/validate-metal-capture-artifact.py
python3 ios/device-test/validate-clear-only-pass-self-test-log.py --self-test
python3 ios/device-test/validate-metal-capture-artifact.py --self-test
ios/device-test/run-smoke-test.sh \
  --require-clear-only-pass-self-test --self-test
if ios/device-test/run-smoke-test.sh \
    --require-clear-only-pass-self-test \
    --require-bink-self-test --self-test; then
  echo 'clear-only pass/Bink harness conflict survived'
  exit 1
fi
if ios/device-test/run-smoke-test.sh \
    --require-clear-only-pass-self-test \
    --require-resource-allocator-self-test --self-test; then
  echo 'clear-only pass/resource allocator harness conflict survived'
  exit 1
fi
if ios/device-test/run-smoke-test.sh \
    --require-clear-only-pass-self-test \
    --expected-fault post-submit-suboptimal --self-test; then
  echo 'clear-only pass/fault harness conflict survived'
  exit 1
fi
if OPENGOTHIC_IOS_EXPECTED_FAULT=post-submit-suboptimal \
    ios/device-test/run-smoke-test.sh \
    --require-clear-only-pass-self-test --self-test; then
  echo 'clear-only pass host profile accepted an injected fault'
  exit 1
fi
if ios/device-test/run-smoke-test.sh \
    --require-clear-only-pass-self-test \
    --pipeline-archive-test-mode cold --self-test; then
  echo 'clear-only pass/pipeline archive harness conflict survived'
  exit 1
fi
if [ "$CLEAR_ONLY_PASS_SELF_TEST" = ON ] && {
    [ "$REQUESTED_FAULT" != none ] ||
    [ "$REQUESTED_BINK_SELF_TEST" = ON ] ||
    [ "$REQUESTED_RESOURCE_ALLOCATOR_SELF_TEST" = ON ] ||
    [ "$REQUESTED_SHADING_PROTOTYPE_TILE_SELF_TEST" = ON ] ||
    [ "$REQUESTED_SHADING_PROTOTYPE_FORWARD_SELF_TEST" = ON ];
}; then
  echo 'clear-only pass workflow input conflicts with fault/other self-test'
  exit 1
fi

bash -n ios/device-test/run-smoke-test.sh
python3 -m py_compile \
  ios/device-test/validate-clear-only-pass-self-test-log.py \
  ios/device-test/validate-metal-capture-artifact.py
grep -Fq -- '--require-clear-only-pass-self-test' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'validate_clear_only_pass_binary_profile()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'build/device-self-test/%s/clear-only-pass\n' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'clear_only_pass_self_test_process_survived=' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'self_test_profile=clear-only-pass' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'processes-clear-only-pass-window-start.json' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'trap cleanup EXIT' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_crash_state before' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_crash_state after' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'ensure_durable_zero || fail "durable final application cleanup failed"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_crash_state final' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_clear_only_capture_artifact()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'clear_only_capture_manifest_sha256=' \
  ios/device-test/run-smoke-test.sh
test "$(grep -Fc \
  'signed_executable_sha256=$APP_EXECUTABLE_SHA256' \
  ios/device-test/run-smoke-test.sh)" -eq 3

if grep -nEi \
    'newCommandQueue|MTLCommandQueue|newCommandBuffer|waitIdle|nextDrawable|presentDrawable|drawPrimitives|drawIndexedPrimitives|newRenderPipelineState|newComputePipelineState|newLibrary|blitCommandEncoder|readPixels|getBytes|MTLHeap|newHeap|sizeAndAlign|makeAliasable|supportsFamily|supportsTextureSampleCount|MSAA|capabilit' \
    "${probe_files[@]}"; then
  echo 'P2.3c clear-only probe escaped its exact two-pass scope'
  exit 1
fi

xcrun clang++ -std=c++20 \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=1 \
  -DOPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame -isystem lib/Tempest/Engine/include \
  ios/tests/iosmetalresourceclearpassprobe.cpp \
  game/graphics/iosmetalresourceclearpassprobe.cpp \
  game/graphics/iosmetalresourceallocator.cpp \
  game/graphics/iosframeplan.cpp \
  -o "$RUNNER_TEMP/iosmetalresourceclearpassprobe"
"$RUNNER_TEMP/iosmetalresourceclearpassprobe"

xcrun clang++ -x c++ -std=c++20 \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include -fsyntax-only \
  game/graphics/iosmetalresourceclearpassprobe.cpp
xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
  -arch arm64 -miphoneos-version-min=16.4 -fno-objc-arc \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include \
  -isystem lib/Tempest/Engine/thirdparty/metal-cpp -fsyntax-only \
  game/graphics/iosmetalresourceclearpassprobe.mm
xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
  -arch arm64 -miphoneos-version-min=16.4 -fno-objc-arc \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include \
  -isystem lib/Tempest/Engine/thirdparty/metal-cpp -fsyntax-only \
  game/graphics/iosmetalcapturesession.mm
xcrun clang++ -x objective-c++ -std=c++20 -fno-objc-arc \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include \
  -isystem lib/Tempest/Engine/thirdparty/metal-cpp -fsyntax-only \
  game/graphics/iosmetalresourceclearpassprobe.mm
xcrun clang++ -x objective-c++ -std=c++20 -fno-objc-arc \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include \
  -isystem lib/Tempest/Engine/thirdparty/metal-cpp -fsyntax-only \
  game/graphics/iosmetalcapturesession.mm

# CI_CONTRACT_P23C_COMPILE_END
python3 - <<'PY'
import plistlib
from pathlib import Path

context = Path("game/graphics/iosmetalcontext.cpp").read_text()
harness = Path("ios/device-test/run-smoke-test.sh").read_text()
contracts = Path("scripts/ci_contracts.command").read_text()
profile = Path("scripts/ci_build_profile.command").read_text()
neutral = Path(
    "game/graphics/iosmetalresourceclearpassprobe.cpp"
).read_text()
native = Path(
    "game/graphics/iosmetalresourceclearpassprobe.mm"
).read_text()
capture_session = Path(
    "game/graphics/iosmetalcapturesession.mm"
).read_text()
validator = Path(
    "ios/device-test/validate-clear-only-pass-self-test-log.py"
).read_text()
capture_validator = Path(
    "ios/device-test/validate-metal-capture-artifact.py"
).read_text()
host_test = Path(
    "ios/tests/iosmetalresourceclearpassprobe.cpp"
).read_text()
cmake = Path("CMakeLists.txt").read_text()
plist_template = Path("Info.plist.in").read_text()
markers = (
    "RendererIOS clear-only pass self-test: ARMED "
    "case=pm-clear-v1 abi=4 resources=3 "
    "logical-passes=3 private=1 memoryless=1",
    "RendererIOS clear-only pass self-test: ENCODED "
    "case=pm-clear-v1 physical-passes=2 "
    "command-buffers=1 render-encoders=2 private-load=clear "
    "private-store=store memoryless-load=clear "
    "memoryless-store=dont-care draws=0 pipelines=0 drawable=0 present=0",
    "RendererIOS clear-only pass self-test: SUBMITTED "
    "case=pm-clear-v1 command-buffers=1 submits=1",
    "RendererIOS clear-only pass self-test: PASS "
    "case=pm-clear-v1 terminal=completed "
    "created=2 live=0 released=2 wait-idle=0",
)

def require_marker_byte_budget(candidates):
    if len(candidates) != 4:
        raise RuntimeError("clear-only marker set is not exactly four lines")
    lengths = tuple(len(marker.encode("utf-8")) for marker in candidates)
    if any(length > 250 for length in lengths):
        raise RuntimeError(
            f"clear-only marker exceeds 250-byte device limit: {lengths}"
        )
    return lengths

marker_lengths = require_marker_byte_budget(markers)
if marker_lengths != (119, 246, 93, 119):
    raise SystemExit(
        f"clear-only marker byte lengths changed unexpectedly: {marker_lengths}"
    )
overlong_markers = list(markers)
overlong_markers[1] += "x" * (251-marker_lengths[1])
try:
    require_marker_byte_budget(tuple(overlong_markers))
except RuntimeError:
    pass
else:
    raise SystemExit("overlong clear-only marker mutation survived")

marker_scope = context.split(
    "constexpr char RendererIOSClearOnlyPassSelfTestArmed[]", 1
)[1].split("\n#endif", 1)[0]
for marker in markers:
    if marker_scope.count(marker) != 1:
        raise SystemExit(
            f"clear-only pass production marker is not exact: {marker}"
        )
capture_marker_max = (
    "RendererIOS clear-only capture: ACQUIRED case=pm-clear-v1 "
    "file=RendererIOS-pm-clear-v1.gputrace kind=directory "
    "bytes=18446744073709551615"
)
if len(capture_marker_max.encode("utf-8")) > 250:
    raise SystemExit("clear-only capture marker exceeds device log budget")
if context.count(
    '"\\x01RendererIOS clear-only capture: ACQUIRED"'
) != 1:
    raise SystemExit("clear-only capture binary marker is not exact")

capture_cmake = cmake.split(
    'option(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST', 1
)[1].split('set(_renderer_ios_fault_modes', 1)[0]
for literal in (
    'set(OPENGOTHIC_RENDERER_IOS_METAL_CAPTURE_PLIST_ENTRY "")',
    'if(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST OR\n'
    '     OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST OR\n'
    '     OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)',
    '<key>MetalCaptureEnabled</key>',
    '<true/>',
):
    if capture_cmake.count(literal) != 1:
        raise SystemExit(f"capture plist CMake contract is not exact: {literal}")
placeholder = '${OPENGOTHIC_RENDERER_IOS_METAL_CAPTURE_PLIST_ENTRY}'
if plist_template.count(placeholder) != 1:
    raise SystemExit("capture plist template placeholder is not exact")
off_plist = plistlib.loads(
    plist_template.replace(placeholder, "").encode("utf-8")
)
on_plist = plistlib.loads(
    plist_template.replace(
        placeholder,
        "  <key>MetalCaptureEnabled</key>\n  <true/>",
    ).encode("utf-8")
)
if "MetalCaptureEnabled" in off_plist:
    raise SystemExit("normal plist enables programmatic capture")
if on_plist.get("MetalCaptureEnabled") is not True:
    raise SystemExit("clear-only plist does not enable programmatic capture")

def exact_scope(source, start, end, label):
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f"{label} boundaries are not exact")
    start_position = source.index(start)
    end_position = source.index(end, start_position + len(start))
    if end_position <= start_position:
        raise RuntimeError(f"{label} boundaries are out of order")
    return source[start_position + len(start):end_position]

def build_step(source):
    return exact_scope(
        source,
        "printf '\\n### CI profile Build iOS Release\\n'",
        "printf '\\n### CI profile Verify P2.6b1 final weak MetalFX dependency\\n'",
        "profile build",
    )

def require_exact_binary_cardinality(scope):
    contracts = []
    for marker in markers:
        exact = f"grep -Fxc -- '{marker}'"
        if scope.count(exact) != 1:
            raise RuntimeError(
                f"binary profile cardinality is not exact: {marker}"
            )
        position = scope.index(exact)
        start = scope.rfind("\n", 0, position) + 1
        first_end = scope.index("\n", position)
        second_end = scope.index("\n", first_end + 1)
        contract = scope[start:second_end]
        if not contract.lstrip().startswith('test "$(grep -Fxc --'):
            raise RuntimeError(
                f"binary profile reverted to presence-only: {marker}"
            )
        if '"$APP_STRINGS" || true)" -eq 1' not in contract:
            raise RuntimeError(
                f"binary profile does not require cardinality one: {marker}"
            )
        if f"grep -Fxq '{marker}'" in scope:
            raise RuntimeError(
                f"binary profile retains a presence-only oracle: {marker}"
            )
        contracts.append(contract)
    return contracts

binary_scope = build_step(profile)
binary_contracts = require_exact_binary_cardinality(binary_scope)
presence_only_contract = binary_contracts[0].replace(
    "grep -Fxc --", "grep -Fxq --", 1
)
presence_only = binary_scope.replace(
    binary_contracts[0], presence_only_contract, 1
)
try:
    require_exact_binary_cardinality(presence_only)
except RuntimeError:
    pass
else:
    raise SystemExit("presence-only binary profile mutation survived")
duplicate = binary_scope.replace(
    binary_contracts[0],
    binary_contracts[0] + "\n" + binary_contracts[0],
    1,
)
try:
    require_exact_binary_cardinality(duplicate)
except RuntimeError:
    pass
else:
    raise SystemExit("duplicate binary cardinality oracle survived")
external_fixture = profile + "\n# fixture duplicate: " + markers[0] + "\n"
require_exact_binary_cardinality(build_step(external_fixture))
start_probe = context.split(
    "void startClearOnlyPassSelfTest() noexcept {", 1
)[1].split("\n  void pollClearOnlyPassSelfTest() noexcept {", 1)[0]
poll_probe = context.split(
    "void pollClearOnlyPassSelfTest() noexcept {", 1
)[1].split(
    "\n  void settleClearOnlyPassAfterConfirmedIdle() noexcept {", 1
)[0]
finish_probe = context.split(
    "bool finishClearOnlyPassAfterTerminal(", 1
)[1].split("\n  void startClearOnlyPassSelfTest() noexcept {", 1)[0]
if start_probe.count("device.commandBuffer()") != 1:
    raise SystemExit("clear-only probe must create exactly one Tempest command buffer")
if start_probe.count("device.submit(clearOnlyCommand)") != 1:
    raise SystemExit("clear-only probe must perform exactly one Tempest submit")
capture_start = start_probe.index("clearOnlyCapture.start(device,captureReason)")
private_allocation = start_probe.index("resourceAllocator.allocate(")
command_buffer = start_probe.index("device.commandBuffer()")
submit = start_probe.index("device.submit(clearOnlyCommand)")
capture_stop = start_probe.index("clearOnlyCapture.stopAndInspect(")
if not capture_start < private_allocation < command_buffer < submit < capture_stop:
    raise SystemExit("programmatic capture boundary is out of order")
if poll_probe.count("clearOnlyFence.wait(0u)") != 1:
    raise SystemExit("clear-only PASS path must use exactly one zero-timeout fence poll")
if finish_probe.count("RendererIOSClearOnlyPassSelfTestPassed") != 1:
    raise SystemExit("clear-only PASS marker is not terminal-lifetime scoped")
if "waitIdle" in start_probe + poll_probe + finish_probe:
    raise SystemExit("clear-only PASS path invokes waitIdle")
if native.count(
    "renderCommandEncoderWithDescriptor:descriptor.get()"
) != 1:
    raise SystemExit("clear-only native helper has an ambiguous encoder source")
if native.count("encodeClear(nativeCommand") != 2:
    raise SystemExit("clear-only native callback must invoke exactly two render passes")
if native.count("Tempest::MetalApi::withActiveCommandBuffer(") != 1:
    raise SystemExit("clear-only probe must borrow exactly one active command buffer")
for literal in (
    "supportsDestination:MTLCaptureDestinationGPUTraceDocument",
    "startCaptureWithDescriptor:descriptor.get()",
    "descriptor.get().captureObject = nativeDevice",
):
    if capture_session.count(literal) != 1:
        raise SystemExit(f"common programmatic capture contract is not exact: {literal}")
for literal in (
    "RendererIOS-pm-clear-v1.gputrace",
    "RIOS pm-clear CB",
    "RIOS private 4x4",
    "RIOS memoryless 4x4",
    "RIOS private clear",
    "RIOS memoryless clear",
):
    if native.count(literal) != 1:
        raise SystemExit(f"clear capture adapter contract is not exact: {literal}")
for forbidden in ("Sha256", "CommonCrypto", "newCommandQueue"):
    if forbidden in native or forbidden in capture_session:
        raise SystemExit(f"programmatic capture contains forbidden runtime code: {forbidden}")
cancel_capture = capture_session.split(
    "void IOSMetalCaptureSession::cancel() noexcept {", 1
)[1].split(
    "\nvoid IOSMetalCaptureSession::reset() noexcept {", 1
)[0]
cancel_try, cancel_catch = cancel_capture.split("@catch", 1)
if (
    cancel_try.count("[impl->manager stopCapture];") != 1
    or cancel_try.count("impl->captureActive = false;") != 1
    or "impl->captureActive = false;" in cancel_catch
):
    raise SystemExit("capture cancel hides an ambiguous stop exception")
for literal in (
    "capture package contains a symlink",
    "capture package contains a special node",
    "capture package regular-file content is empty",
    "capture package exceeds the accepted byte limit",
    'f"{digest}  {relative}\\n"',
):
    if literal not in capture_validator:
        raise SystemExit(f"host capture validator omits: {literal}")
normalizer_contract = (
    "MaxCaptureArtifactBytes = 512u*1024u*1024u",
    "ScopedFileDescriptor rootParentDescriptor(::open(",
    "::fstatat(rootParentDescriptor.get(),rootName.c_str(),&requestedStat,",
    "ScopedFileDescriptor rootDescriptor(::openat(",
    "sameNodeIdentity(requestedStat,openedRootStat)",
    "rootDirectoryEntryIdentityMatches(",
    "::fdopendir(duplicate)",
    "::rewinddir(value)",
    "::readdir(stream.get())",
    "::fstatat(directoryDescriptor,name.c_str(),&entryStat,",
    "readlinkat(",
    "openRootedDirectory(",
    "O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC",
    "O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC",
    "AT_SYMLINK_NOFOLLOW",
    'value==".."',
    "relativeTarget==relativeLink",
    "sameFileIdentity(sourceStat,plan.targetStat)",
    "copyRegularFile(source.get(),temporary.get(),sourceBytes)",
    "::fsync(destination)==0",
    "prepareCaptureLinkTemporary(rootDescriptor.get(),plan)",
    "renameat(parent.get(),temporaryName.c_str(),",
    "::symlinkat(plan.rawTarget.c_str(),parent.get(),",
    "rollbackCaptureLinks(",
    '"capture-package-rollback-failed"',
    "inspectNormalizedDirectory(",
    "rootDescriptor.get(),plannedBytes,artifact",
    'reason = "capture-package-post-normalization-invalid"',
)
for literal in normalizer_contract:
    if literal not in neutral:
        raise SystemExit(f"capture normalizer omits: {literal}")
prepare_all = neutral.index(
    "for(const auto& relativeLink:relativeLinks)"
)
copy_all = neutral.index(
    "for(auto& plan:linkPlans)"
)
commit_all = neutral.index(
    "for(std::size_t index=0u;index<linkPlans.size();++index)"
)
final_rescan = neutral.index(
    "normalized = inspectNormalizedDirectory("
)
final_root_identity = neutral.index(
    "if(!rootDirectoryEntryIdentityMatches(",
    final_rescan,
)
final_success = neutral.index("reason = nullptr;", final_root_identity)
if not (
    prepare_all < copy_all < commit_all < final_rescan
    < final_root_identity < final_success
):
    raise SystemExit(
        "capture normalization is not validate/copy/commit/rescan/root-check"
    )
normalizer_entry = neutral.split(
    "bool iosMetalNormalizeAndInspectCaptureArtifact(", 1
)[1].split("IOSFramePlan iosMetalResourceClearPassPlan()", 1)[0]
if normalizer_entry.count(
    "rootDirectoryEntryIdentityMatches("
) != 2:
    raise SystemExit(
        "capture normalizer does not revalidate file and directory roots"
    )
for forbidden in (
    "recursive_directory_iterator",
    "std::filesystem::canonical",
    "std::filesystem::symlink_status",
    "std::filesystem::file_size",
):
    if forbidden in neutral:
        raise SystemExit(
            f"capture normalizer returned to path traversal: {forbidden}"
        )
p23_compile_scope = exact_scope(
    contracts,
    "printf '\\n### CI contract: " +
    "Verify P2.3c clear-only pass contract\\n'",
    "# CI_CONTRACT_" + "P23C_COMPILE_END",
    "P2.3c compile",
)
if p23_compile_scope.count(
    "-DOPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS=1"
) != 1:
    raise SystemExit("capture rollback fault hook is not host-test-only")
for literal in (
    "MTLTexture-26-0-mipmap0-slice0",
    "MTLTexture-27-0-mipmap0-slice0",
    "MTLTexture-28-0-mipmap0-slice0",
    'std::filesystem::create_symlink("../outside"',
    "capture-package-special-node",
    ".rendererios-materializing",
    ".rendererios-rollback",
    "iosMetalCaptureNormalizerFailCommitForTesting(1u)",
    "iosMetalCaptureNormalizerSetBeforeRootCheckHookForTesting(",
    '"capture-package-materialization-failed"',
    '"capture-artifact-root-changed"',
    "RootSwapHookSucceeded",
    "RegularRootSwapHookSucceeded",
):
    if literal not in host_test:
        raise SystemExit(f"capture normalization host test omits: {literal}")
report_oracle = neutral.split(
    "bool iosMetalResourceClearPassNativeReportMatches(", 1
)[1]
for zero_counter in (
    "report.draws==0u",
    "report.pipelines==0u",
    "report.drawable==0u",
    "report.present==0u",
):
    if report_oracle.count(zero_counter) != 1:
        raise SystemExit(
            f"clear-only physical zero oracle is not exact: {zero_counter}"
        )
begin_frame = context.split(
    "std::optional<IOSMetalContext::FrameLease> "
    "IOSMetalContext::beginFrame() {", 1
)[1].split(
    "\nbool IOSMetalContext::frameAdmissionActive() const noexcept {", 1
)[0]
profile_gate = begin_frame.split(
    "#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)",
    1,
)[1].split("#endif", 1)[0]
if profile_gate.count("impl->pollClearOnlyPassSelfTest();") != 1:
    raise SystemExit("clear-only profile does not own frame admission")
if profile_gate.count("return std::nullopt;") != 1:
    raise SystemExit("clear-only profile can enter production frame admission")
for production_call in (
    "pollPresentFailure",
    "startEncoding",
    "device.submit",
    "swapchain",
    "gpuScene",
):
    if production_call in profile_gate:
        raise SystemExit(
            f"clear-only admission gate invokes production work: {production_call}"
        )
if begin_frame.index("impl->pollClearOnlyPassSelfTest();") > begin_frame.index(
    'impl->pollPresentFailure("RendererIOS asynchronous Metal present failed")'
):
    raise SystemExit("clear-only probe begins after production present polling")
if "not ordinary_frame_lines" not in validator:
    raise SystemExit(
        "clear-only runtime validator does not require zero ordinary frames"
    )
evidence_root = harness.split(
    "smoke_evidence_root() {", 1
)[1].split("\nsmoke_evidence_path() {", 1)[0]
evidence_leaf = harness.split(
    "smoke_evidence_path() {", 1
)[1].split("\npublish_evidence_path() {", 1)[0]
if evidence_root.count(
    "build/device-self-test/%s/clear-only-pass\\n"
) != 1:
    raise SystemExit("clear-only evidence root is not exact and scoped")
if evidence_leaf.count("printf '%s/%s-%s-%s\\n'") != 1:
    raise SystemExit("shared immutable evidence leaf is not exact")
failure_evidence = harness.split(
    "preserve_failure_evidence() {", 1
)[1].split("\ncleanup() {", 1)[0]
for artifact in (
    "clear-only-pass-self-test-summary.txt",
    "clear-only-capture-summary.txt",
    "clear-only-capture-listing.json",
    "$CLEAR_ONLY_CAPTURE_NAME",
    "processes-clear-only-pass-window-start.json",
    "processes-clear-only-pass-window-start-attempt-*.json",
    "write_clear_only_pass_self_test_result_fields",
):
    if artifact not in failure_evidence:
        raise SystemExit(
            f"clear-only failure evidence omits {artifact}"
        )
cleanup = harness.split("\ncleanup() {", 1)[1].split(
    "\ntrap cleanup EXIT", 1
)[0]
if cleanup.index("ensure_durable_zero") > cleanup.index(
    "preserve_failure_evidence"
):
    raise SystemExit(
        "clear-only failure evidence is preserved before durable cleanup"
    )
if cleanup.index("capture_clear_only_capture_artifact") > cleanup.index(
    "preserve_failure_evidence"
):
    raise SystemExit("capture recovery runs after failure evidence preservation")
initialization = harness.split(
    'WORK="$(mktemp -d -t opengothic-device-smoke)"', 1
)[1].split('APP_EXECUTABLE="$(', 1)[0]
if initialization.count(
    "CLEAR_ONLY_PASS_SELF_TEST_PROCESS_SURVIVED=0"
) != 1:
    raise SystemExit("clear-only survival evidence lacks one fail-closed default")
if initialization.count('CLEAR_ONLY_CAPTURE_STATUS="not-required"') != 1:
    raise SystemExit("clear-only capture status lacks one fail-closed default")
pid_check = harness.index(
    'str(matches[0].get("processIdentifier")) '
    '!= expected_clear_only_pass_pid'
)
survived = harness.index("CLEAR_ONLY_PASS_SELF_TEST_PROCESS_SURVIVED=1")
stop = harness.index('echo "== stopping $BUNDLE_ID after smoke window =="')
if not pid_check < survived < stop:
    raise SystemExit("clear-only pass same-PID survival proof is out of order")
clear_branch = harness.index(
    "if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then",
    harness.index('[[ -s "$WORK/log.txt" ]]'),
)
id3_branch = harness.index(
    'if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]',
    clear_branch,
)
healthy_parser = harness.index(
    'python3 - "$WORK/log.txt" "$WORK/runtime-compilation-summary.txt"',
    id3_branch,
)
if not clear_branch < id3_branch < healthy_parser:
    raise SystemExit(
        "clear-only pass validation is not before fault/healthy parsers"
    )
PY

printf '\n### CI contract: Verify RendererIOS save-preview routing policy\n'
set -euo pipefail

test -f game/graphics/iossavepreviewpolicy.h
test -f ios/tests/iossavepreviewpolicy.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iossavepreviewpolicy.cpp \
  -o "$RUNNER_TEMP/iossavepreviewpolicy"
"$RUNNER_TEMP/iossavepreviewpolicy"

grep -Fq 'requiresGpuSavePreviewCapture()' game/graphics/iosmetalcontext.cpp
grep -Fq 'if(!renderer.requiresGpuSavePreviewCapture())' game/mainwindow.cpp
grep -Fq 'save-cpu-fastpath' game/graphics/iosmetalcontext.cpp
grep -Fq 'savePreviewRoute=' game/graphics/iosmetalcontext.cpp
grep -Fq 'route=cpu-placeholder' game/mainwindow.cpp
grep -Fq 'route=gpu-diagnostic' game/mainwindow.cpp
grep -Fq 'pixels[i*4u+3u] = 255u;' game/mainwindow.cpp
grep -Fq 'request-to-accepted-us=' game/mainwindow.cpp
grep -Fq 'serialize-us=' game/mainwindow.cpp
grep -Fq 'request-to-complete-us=' game/mainwindow.cpp
grep -Fq 'wait-idle-us=' game/graphics/iosmetalcontext.cpp
grep -Fq 'RendererIOS save preview diagnostic capture' game/graphics/iosmetalcontext.cpp
! grep -Fq 'RendererIOS save preview placeholder' game/graphics/iosmetalcontext.cpp
test "$(grep -Fc '!configuredSavePreviewNeedsGpuCapture() ||' game/graphics/iosmetalcontext.cpp)" -eq 1
test "$(grep -Fc 'impl->device.attachment(TextureFormat::RGBA8,dstW,dstH)' game/graphics/iosmetalcontext.cpp)" -eq 1
test "$(grep -Fc 'device.readPixels(savePreview)' game/graphics/iosmetalcontext.cpp)" -eq 1
grep -Fq 'previewFenceErrorAfterTerminal()' game/graphics/iosmetalcontext.cpp

printf '\n### CI contract: Verify RendererIOS legacy shader compilation policy\n'
set -euo pipefail

test -f game/graphics/shadercompilationpolicy.h
test -f ios/tests/iosshadercompilationpolicy.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadercompilationpolicy.cpp \
  -o "$RUNNER_TEMP/iosshadercompilationpolicy"
"$RUNNER_TEMP/iosshadercompilationpolicy"

grep -Fq 'if(!allowsMaterialPipelines())' \
  game/graphics/shaders.cpp
grep -Fq 'sourceOnlyDrawCommandKey(' \
  game/graphics/drawcommands.cpp
grep -Fq 'material-pipelines=source-metadata-only pfx-pipelines=disabled' \
  game/graphics/shaders.cpp
grep -Fq 'runtime_compilation_frame_source_growth=' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'An explicitly selected paired device may establish its CoreDevice/DDI' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'save runtime totals must remain exact 0/0/2' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'runtime compilation frame markers are not contiguous' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'the first presented frame must have exact offline shader totals' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'builtin runtime attribution markers do not cover presents 1 through 300' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'builtin_render_active_roles=' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'builtin_source_role_counts=' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'new_game_builtin_render = (0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0)' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'new-game runtime render transition occurred after present 300' \
  ios/device-test/run-smoke-test.sh

printf '\n### CI contract: Verify RendererIOS pipeline archive policy\n'
set -euo pipefail

test -f game/graphics/iospipelinearchivepolicy.h
test -f ios/tests/iospipelinearchivepolicy.cpp
test -x ios/device-test/run-pipeline-archive-test.sh
test -x ios/device-test/validate-pipeline-archive-log.py
test -x ios/device-test/run-semantic-pipeline-archive-test.sh
test -x ios/device-test/validate-semantic-pipeline-archive-evidence.py
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iospipelinearchivepolicy.cpp \
  -o "$RUNNER_TEMP/iospipelinearchivepolicy"
"$RUNNER_TEMP/iospipelinearchivepolicy"
test "$(/bin/bash -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')" = 3.2
/bin/bash -n ios/device-test/run-pipeline-archive-test.sh
python3 ios/device-test/validate-pipeline-archive-log.py --self-test
/bin/bash ios/device-test/run-pipeline-archive-test.sh --self-test
bash -n ios/device-test/run-semantic-pipeline-archive-test.sh
ios/device-test/run-semantic-pipeline-archive-test.sh --self-test
grep -Fq 'OPENGOTHIC_IOS_EXPECTED_BUILD="$EXPECTED_BUILD"' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq -- '--evidence-path-file "$BASE_EVIDENCE_PATH_FILE"' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'BASE_EVIDENCE="$(read_base_smoke_evidence' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'base-smoke-evidence-path.txt' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'pipeline archive wrapper/smoke SHA-local contract self-test passed' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'pipeline archive Bash build resolution contract self-test passed' \
  ios/device-test/run-pipeline-archive-test.sh

grep -Fq 'FirstFlushPresent = 300u' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'LastFlushPresent =' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'successfulPresents<FirstFlushPresent' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'successfulPresents>LastFlushPresent' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'constexpr FlushDecision advanceFlushStateAfterPresent(' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'bool succeeded, bool dirtyAfter' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'Archive::advanceFlushStateAfterPresent(' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'const bool dirtyAfter =' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'len(marker_lines) % 8 == 0' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'validate_late_snapshot_pair(pre, post)' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'incomplete late snapshot pair self-test unexpectedly passed' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'reordered late snapshot pair self-test unexpectedly passed' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'late archive summary does not use the final POST snapshot' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'last archive snapshot present exceeds the runtime frame range' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'changed late snapshot metadata self-test unexpectedly passed' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'phase in ("inventory-cold", "inventory-warm")' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq '"inventory-cold": (2, 4, 6),' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq '"inventory-warm": (2, 3, 4),' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} runtime must transition exactly "' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} skipped render transition self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} jumped render transition self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} wrong render step self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} late render transition self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} broken render plateau self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'INVENTORY_POST_UI_BUILTIN_RENDER = (' \
  ios/device-test/validate-pipeline-archive-log.py
python3 - <<'PY'
import ast
from pathlib import Path

tree = ast.parse(
    Path("ios/device-test/validate-pipeline-archive-log.py").read_text()
)
expected = {
    "SAVE_BUILTIN_RENDER": (0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0),
    "INVENTORY_POST_UI_BUILTIN_RENDER": (
        0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0
    ),
}
actual = {}
for node in tree.body:
    if not isinstance(node, ast.Assign) or len(node.targets) != 1:
        continue
    target = node.targets[0]
    if isinstance(target, ast.Name) and target.id in expected:
        actual[target.id] = ast.literal_eval(node.value)
if actual != expected:
    raise SystemExit(
        f"Builtin inventory role-vector ABI drift: {actual}"
    )
PY
grep -Fq 'ColorTrianglesAlpha (index 3)' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'if inventory_phase and present >= FIRST_FLUSH_PRESENT:' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} missing ColorTrianglesAlpha role self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} extra ColorTrianglesOpaque role self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} wrong builtin render role self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'f"{phase} wrong builtin role phase timing self-test unexpectedly passed"' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq -- '--baseline-only --evidence-path-file "$WORK/baseline-path.txt"' \
  ios/device-test/run-semantic-pipeline-archive-test.sh
grep -Fq -- '--pipeline-archive-phase inventory-cold' \
  ios/device-test/run-semantic-pipeline-archive-test.sh
grep -Fq -- '--pipeline-archive-phase inventory-warm' \
  ios/device-test/run-semantic-pipeline-archive-test.sh
grep -Fq -- '--source-sha "$EXPECTED_SHA"' \
  ios/device-test/run-semantic-pipeline-archive-test.sh
grep -Fq -- '--metallib-sha256 "$METALLIB_SHA256"' \
  ios/device-test/run-semantic-pipeline-archive-test.sh
grep -Fq 'provenance_bytes == expected_provenance(metallib_sha256)' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'cache["archive_sha256"] == sha256(archive)' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'recorded_bytes == len(archive_bytes)' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'cache["provenance_sha256"] == sha256(provenance)' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'baseline_archive != cold_archive' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'cold_archive == warm_archive' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'baseline_provenance == cold_provenance == warm_provenance' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
test "$(grep -Fc '"runtime_render": "6" if phase == "inventory-cold" else "4"' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py)" -eq 2
grep -Fq 'swapped inventory-cold runtime render summary self-test unexpectedly passed' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'swapped inventory-warm runtime render summary self-test unexpectedly passed' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'mixed source self-test unexpectedly passed' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'wrong metallib provenance self-test unexpectedly passed' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'stale cache archive SHA-256 self-test unexpectedly passed' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'stale cache archive size self-test unexpectedly passed' \
  ios/device-test/validate-semantic-pipeline-archive-evidence.py
grep -Fq 'exact $PIPELINE_ARCHIVE_PHASE archive POST at present 300' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'copy_pipeline_cache_evidence || fail' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq -- '--scenario "$SCENARIO"' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'parser.add_argument("--scenario", choices=("save", "new-game"))' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'NEW_GAME_BUILTIN_RENDER = (0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0)' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'transition_present <= FIRST_FLUSH_PRESENT' \
  ios/device-test/validate-pipeline-archive-log.py
test "$(grep -Fc 'echo "scenario=$SCENARIO"' \
  ios/device-test/run-pipeline-archive-test.sh)" -eq 6
test "$(grep -Fc 'echo "save_slot=$SCENARIO_SAVE_SLOT"' \
  ios/device-test/run-pipeline-archive-test.sh)" -eq 6
grep -Fq 'missing new-game transition self-test passed' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'post-300 new-game transition self-test passed' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'wrong new-game role-3 self-test passed' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'post-plateau growth self-test passed' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'new-game pipeline archive mode has no confirmed scene world gate' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'new-game pipeline archive mode has no non-empty scene snapshot' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'MetalBuiltinRenderRole::ColorTrianglesAlpha' \
  ios/patches/apply-patches.sh
grep -Fq 'opengothic-ios-patch-stack-v14' \
  ios/patches/apply-patches.sh

grep -Fq 'RendererIOS/PipelineArchives/schema-1/RendererIOS-abi-7.binaryarchive' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'PreviousArchiveFileName' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq '"RendererIOS-abi-6.binaryarchive"' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq '"RendererIOS-abi-6.provenance"' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'NSSearchPathForDirectoriesInDomains(' \
  game/graphics/rendereriosplatform.mm
grep -Fq 'NSCachesDirectory,NSUserDomainMask,YES' \
  game/graphics/rendereriosplatform.mm
grep -Fq 'metallib-sha256=' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'NSDataWritingAtomic' \
  game/graphics/rendereriosplatform.mm
grep -Fq 'CorruptArchivePayloadSha256' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'TestModeLogPrefix.data()' game/main.cpp
grep -Fq 'O_NOFOLLOW' game/graphics/rendereriosplatform.mm
grep -Fq '::mkdirat(' game/graphics/rendereriosplatform.mm
grep -Fq '::openat(' game/graphics/rendereriosplatform.mm
grep -Fq '::fstatat(' game/graphics/rendereriosplatform.mm
grep -Fq '::unlinkat(' game/graphics/rendereriosplatform.mm
grep -Fq '::renameat(' game/graphics/rendereriosplatform.mm
grep -Fq 'provenanceAfter!=provenanceBefore' \
  game/graphics/rendereriosplatform.mm
grep -Fq 'sha256=' \
  ios/device-test/validate-pipeline-archive-log.py
grep -Fq 'pipeline archive provenance-policy:' \
  game/graphics/iospipelinearchivepolicy.h
grep -Fq 'ProvenancePolicyLogPrefix.data()' game/main.cpp
! grep -Fq 'provenance-path=' game/main.cpp
grep -Fq 'flushPipelineArchive' game/graphics/iosmetalcontext.cpp
grep -Fq 'SnapshotStateLogPrefix.data()' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'SnapshotRenderLogPrefix.data()' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'SnapshotComputeLogPrefix.data()' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'SnapshotFlushLogPrefix.data()' \
  game/graphics/iosmetalcontext.cpp
grep -Fq '" empty="' game/graphics/iosmetalcontext.cpp
grep -Fq '" disabled="' game/graphics/iosmetalcontext.cpp
! grep -Fq '" created-empty="' game/graphics/iosmetalcontext.cpp
! grep -Fq '" disabled-after-error="' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'run-smoke-test.sh' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'run_direct_phase warm' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'run_direct_phase corrupt' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'run_direct_phase recovery-warm' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq -- '--pipeline-archive-test-mode cold' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'run_direct_phase corrupt corrupt' \
  ios/device-test/run-pipeline-archive-test.sh
! grep -Fq 'device copy to' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'device copy to --device "$DEVICE"' \
  ios/device-test/run-smoke-test.sh
! grep -Fq -- '--remove-existing-content' \
  ios/device-test/run-pipeline-archive-test.sh
! grep -Fq -- '--remove-existing-content' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'remote_mutating_copy_count=0' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'OpenGothic container has missing/invalid resources:' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'resources.get("isDirectory") is not True' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'or resources.get("isSymbolicLink") is not False' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'game Data/_work/system or Gothic.dat/Gothic.ini preflight failed before install' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'Gothic.dat' ios/device-test/run-smoke-test.sh
grep -Fq 'Gothic.ini' ios/device-test/run-smoke-test.sh
grep -Fq 'verify_existing_game_data before' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'verify_existing_game_data after' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'record_zero_scan final' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'phase=trap-cleanup game_processes=0' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'install_count=1' \
  ios/device-test/run-pipeline-archive-test.sh
grep -Fq 'uninstall_count=0' \
  ios/device-test/run-pipeline-archive-test.sh

printf '\n### CI contract: Verify P2.1 native asset registry contract\n'
set -euo pipefail

test -f game/graphics/iossceneassetregistry.h
test -f game/graphics/iossceneassetregistry.cpp
test -f ios/tests/iossceneassetregistry.cpp
printf '#include "graphics/iossceneassetregistry.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -isystem lib/Tempest/Engine/include -fsyntax-only -
xcrun clang++ -x c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include -fsyntax-only \
  game/graphics/iossceneassetregistry.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include \
  ios/tests/iossceneassetregistry.cpp \
  -o "$RUNNER_TEMP/iossceneassetregistry"
"$RUNNER_TEMP/iossceneassetregistry"

test -f game/graphics/iosscenesource.h
test -f ios/tests/iosscenesourcecontract.cpp
if grep -Eq 'DrawCommands|DrawBuckets|cmdId|clusterId|std::function' \
    game/graphics/iosscenesource.h; then
  echo 'RendererIOS source boundary leaks legacy renderer internals'
  exit 1
fi
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  ios/tests/iosscenesourcecontract.cpp \
  game/graphics/bounds.cpp \
  -o "$RUNNER_TEMP/iosscenesourcecontract"
"$RUNNER_TEMP/iosscenesourcecontract"

printf '\n### CI contract: Verify P2.1 Landscape extractor contract\n'
set -euo pipefail

test -f game/graphics/iossceneextractorplan.h
test -f game/graphics/iossceneextractor.h
test -f game/graphics/iossceneextractor.cpp
test -f ios/tests/iossceneextractorplan.cpp

printf '#include "graphics/iossceneextractorplan.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -x c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iossceneextractor.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  ios/tests/iossceneextractorplan.cpp \
  -o "$RUNNER_TEMP/iossceneextractorplan"
"$RUNNER_TEMP/iossceneextractorplan"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address -fno-omit-frame-pointer \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  ios/tests/iossceneextractorplan.cpp \
  -o "$RUNNER_TEMP/iossceneextractorplan-asan"
"$RUNNER_TEMP/iossceneextractorplan-asan"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=undefined -fno-sanitize-recover=undefined \
  -fno-omit-frame-pointer \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  ios/tests/iossceneextractorplan.cpp \
  -o "$RUNNER_TEMP/iossceneextractorplan-ubsan"
"$RUNNER_TEMP/iossceneextractorplan-ubsan"
test -x scripts/validate-scene-source-census-log.py
PYTHONDONTWRITEBYTECODE=1 python3 \
  scripts/validate-scene-source-census-log.py --self-test
test -x scripts/test-p21d2a-frame-animation-contract.py
test -x scripts/test-p21d2-frame-animation-vertical.py
test -x scripts/test-p21d2-frame-animation-device-parser.py
test -x ios/device-test/validate-frame-animation-log.py
test -x ios/device-test/validate-uv-animation-log.py
PYTHONDONTWRITEBYTECODE=1 python3 \
  scripts/test-p21d2-frame-animation-vertical.py
PYTHONDONTWRITEBYTECODE=1 python3 \
  scripts/test-p21d2-frame-animation-device-parser.py
PYTHONDONTWRITEBYTECODE=1 python3 \
  ios/device-test/validate-uv-animation-log.py --self-test

if grep -Eq 'DrawCommands|DrawBuckets|cmdId|clusterId|std::function' \
    game/graphics/iossceneextractorplan.h \
    game/graphics/iossceneextractor.h; then
  echo 'RendererIOS extractor contract leaks legacy renderer internals'
  exit 1
fi
python3 - <<'PY'
from pathlib import Path

source = Path("game/graphics/iossceneextractor.cpp").read_text()
required = (
    (
        "actual-alpha-func-mapping",
        """  const IOSSceneMaterialMapping materialMapping =
      source.material!=nullptr
        ? iosSceneMaterialMapping(source.material->alpha)
        : IOSSceneMaterialMapping{};""",
        """  const IOSSceneMaterialMapping materialMapping = {};""",
    ),
    (
        "mapped-material-admission",
        "  candidate.hasMappedMaterialCategory = materialMapping.mapped;",
        "  candidate.hasMappedMaterialCategory = false;",
    ),
    (
        "mapped-material-category",
        "  candidate.materialCategory = materialMapping.category;",
        "  candidate.materialCategory = IOSMaterialCategory::Opaque;",
    ),
    (
        "fallback-provenance",
        """  candidate.usesFallbackTexture =
      materialMapping==IOSSceneMaterialMapping{
          IOSMaterialCategory::Opaque,true} &&
      !hasFrameAnimation &&
      !candidate.hasBaseColorTexture;""",
        """  candidate.usesFallbackTexture = false;""",
    ),
    (
        "frame-animation-source",
        """  const bool hasFrameAnimation =
      source.material!=nullptr && !source.material->frames.empty();""",
        """  const bool hasFrameAnimation = false;""",
    ),
    (
        "uv-animation-source",
        """  const bool hasUvAnimation =
      source.material!=nullptr && source.material->hasUvAnimation();""",
        """  const bool hasUvAnimation = false;""",
    ),
    (
        "texture-animation-mode-source",
        """  const IOSSceneTextureAnimationMode textureAnimation =
      iosSceneTextureAnimationMode(hasFrameAnimation,hasUvAnimation);""",
        """  const IOSSceneTextureAnimationMode textureAnimation =
      IOSSceneTextureAnimationMode::FrameOnly;""",
    ),
    (
        "frame-animation-candidate",
        "  candidate.hasFrameAnimation = hasFrameAnimation;",
        "  candidate.hasFrameAnimation = false;",
    ),
    (
        "uv-animation-candidate",
        "  candidate.hasUvAnimation = hasUvAnimation;",
        """  candidate.hasUvAnimation = false;""",
    ),
    (
        "raw-source-census",
        """  if(!recordIOSSceneRawSource(
       source.kind,rawMaterial,hasFrameAnimation,hasUvAnimation,
       context.report.stats)) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return;
    }""",
        """  if(false) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return;
    }""",
    ),
    (
        "texture-animation-outcome-wiring",
        """    case IOSSceneSourcePlanResult::SkippedTextureAnimation:
      if(!recordIOSScenePlanResult(
           planned,plan,context.report.stats,textureAnimation))""",
        """    case IOSSceneSourcePlanResult::SkippedTextureAnimation:
      if(!recordIOSScenePlanResult(
           planned,plan,context.report.stats,
           IOSSceneTextureAnimationMode::FrameOnly))""",
    ),
    (
        "successful-census-final-gate",
        """  if(!context.report.stats.hasConsistentSuccessfulCensus()) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return context.report;
    }""",
        """  if(false) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return context.report;
    }""",
    ),
    (
        "snapshot-fallback-provenance",
        "  materialRecord.usesFallbackTexture = plan.usesFallbackTexture;",
        "  materialRecord.usesFallbackTexture = false;",
    ),
    (
        "snapshot-kind",
        "  entityRecord.kind           = plan.kind;",
        "  entityRecord.kind           = IOSSceneMeshKind::Unsupported;",
    ),
)


def valid(candidate: str) -> bool:
    return all(candidate.count(snippet) == 1 for _, snippet, _ in required)


missing = [label for label, snippet, _ in required if source.count(snippet) != 1]
if missing:
    raise SystemExit(
        "RendererIOS extractor adapter assignment missing or duplicated: "
        + ",".join(missing)
    )

mutations_killed = 0
for label, snippet, replacement in required:
    for operation, mutant in (
        ("removed", source.replace(snippet, "", 1)),
        ("replaced", source.replace(snippet, replacement, 1)),
    ):
        if valid(mutant):
            raise SystemExit(
                "RendererIOS extractor adapter mutation survived: "
                + label
                + "-"
                + operation
            )
        mutations_killed += 1
marker_source = Path("game/graphics/rendererios.cpp").read_text()
marker_outcome = """               " x=",uint64_t(extraction.stats.skippedTextureFrameOnly),",",
               uint64_t(extraction.stats.skippedTextureUvOnly),",",
               uint64_t(extraction.stats.skippedTextureFrameAndUv),"""
if marker_source.count(marker_outcome) != 1:
    raise SystemExit(
        "RendererIOS texture animation outcome marker is missing or duplicated"
    )
for operation, mutant in (
    ("removed", marker_source.replace(marker_outcome, "", 1)),
    (
        "collapsed",
        marker_source.replace(
            marker_outcome,
            """               " x=",uint64_t(extraction.stats.skippedTextureAnimation),",0,0",""",
            1,
        ),
    ),
):
    if mutant.count(marker_outcome) == 1:
        raise SystemExit(
            "RendererIOS texture animation marker mutation survived: "
            + operation
        )
    mutations_killed += 1

if mutations_killed != 30:
    raise SystemExit("RendererIOS extractor adapter mutation count drifted")
print("RendererIOS extractor adapter oracle: mutations-killed=30")
PY
python3 - <<'PY'
from pathlib import Path

paths = {
    path: Path(path).read_text()
    for path in (
        "game/graphics/iossceneextractorplan.h",
        "game/graphics/iossceneextractor.cpp",
        "game/graphics/iosscenesnapshot.cpp",
        "game/graphics/iosgpusceneplan.h",
        "game/graphics/iosgpuscene.mm",
        "game/graphics/iosmetalcontext.cpp",
    )
}
required = (
    ("extractor-two-category-admission",
     "game/graphics/iossceneextractorplan.h",
     """source.materialCategory!=IOSMaterialCategory::Opaque &&
     source.materialCategory!=IOSMaterialCategory::AlphaTest"""),
    ("extractor-uv-period-provenance",
     "game/graphics/iossceneextractorplan.h",
     """const bool periodsHaveUv = source.uvPeriodX!=0 || source.uvPeriodY!=0;
  if(source.hasUvAnimation!=periodsHaveUv)
    return IOSSceneSourcePlanResult::InvalidSource;"""),
    ("extractor-uv-only-texture-provenance",
     "game/graphics/iossceneextractorplan.h",
     """if(textureAnimation==IOSSceneTextureAnimationMode::UvOnly &&
     (!source.hasBaseColorTexture || source.usesFallbackTexture))
    return IOSSceneSourcePlanResult::InvalidSource;"""),
    ("extractor-frame-and-uv-texture-provenance",
     "game/graphics/iossceneextractorplan.h",
     """if(textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv &&
     (!source.hasValidFrameSequence || source.usesFallbackTexture))
    return IOSSceneSourcePlanResult::InvalidSource;"""),
    ("extractor-alpha-texture-provenance",
     "game/graphics/iossceneextractorplan.h",
     """const bool selectsFrame =
      textureAnimation==IOSSceneTextureAnimationMode::FrameOnly ||
      textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv;
  if(source.materialCategory==IOSMaterialCategory::AlphaTest &&
     ((!source.hasBaseColorTexture &&
       !selectsFrame) ||
      source.usesFallbackTexture))"""),
    ("extractor-uv-evaluation",
     "game/graphics/iossceneextractorplan.h",
     """if((textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||
      textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv) &&
     evaluateIOSSceneUVOffset(
         source.sceneTimeMs,source.uvPeriodX,source.uvPeriodY,
         uvOffset)!=IOSSceneUVOffsetResult::Evaluated)
    return IOSSceneSourcePlanResult::InvalidSource;"""),
    ("extractor-uv-plan-publication",
     "game/graphics/iossceneextractorplan.h",
     """out.uvPeriodX         = source.uvPeriodX;
  out.uvPeriodY         = source.uvPeriodY;
  out.uvOffset          = uvOffset;"""),
    ("extractor-animation-sidecar-partition",
     "game/graphics/iossceneextractor.cpp",
     """if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly)
    context.report.frameAnimation.selections.push_back(
        {plan.textureStableKey,plan.frameOrdinal,texture});
  else if(plan.textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||
          plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv)
    context.report.uvAnimation.selections.push_back(
        {plan.textureStableKey,plan.textureAnimation,plan.frameOrdinal,
         texture,plan.uvOffset});"""),
    ("extractor-snapshot-uv-publication",
     "game/graphics/iossceneextractor.cpp",
     "materialRecord.uvOffset         = plan.uvOffset;"),
    ("extractor-uv-sidecar-validation",
     "game/graphics/iossceneextractor.cpp",
     """!finalizeIOSUVAnimationEvidence(context.report.uvAnimation) ||
     context.report.uvAnimation.admittedUvOnly!=
         context.report.stats.admittedUvOnly ||
     context.report.uvAnimation.admittedFrameAndUv!=
         context.report.stats.admittedFrameAndUv ||
     context.report.uvAnimation.plannedCount!=
         context.report.stats.admittedUvOnly+
             context.report.stats.admittedFrameAndUv) {
    (void)recordIOSSceneInvalidSource(context.report.stats);
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return context.report;
    }"""),
    ("snapshot-alpha-category",
     "game/graphics/iosscenesnapshot.cpp",
     """case IOSMaterialCategory::AlphaTest:
      return bool(material.baseColorTexture) &&"""),
    ("snapshot-alpha-cutoff",
     "game/graphics/iosscenesnapshot.cpp",
     "material.alphaCutoff==0.5f"),
    ("gpu-plan-unsupported-selector",
     "game/graphics/iosgpusceneplan.h",
     "pipeline==IOSGPUScenePipelineSelector::Unsupported"),
    ("gpu-plan-alpha-selector",
     "game/graphics/iosgpusceneplan.h",
     "pipeline==IOSGPUScenePipelineSelector::AlphaTest"),
    ("gpu-plan-alpha-texture-provenance",
     "game/graphics/iosgpusceneplan.h",
     """!source.material.baseColorTexture || !source.hasTexture ||
       source.material.usesFallbackTexture"""),
    ("gpu-plan-alpha-cutoff",
     "game/graphics/iosgpusceneplan.h",
     "source.material.alphaCutoff!=0.5f"),
    ("opaque-fragment-abi",
     "game/graphics/iosgpuscene.mm",
     "RendererIOSShader::FragmentFunction.data()"),
    ("alpha-fragment-abi",
     "game/graphics/iosgpuscene.mm",
     "RendererIOSShader::AlphaTestFragmentFunction.data()"),
    ("explicit-nonblended-pso",
     "game/graphics/iosgpuscene.mm",
     "pipelineDesc.colorAttachments[0].blendingEnabled = NO;"),
    ("opaque-pso-state",
     "game/graphics/iosgpuscene.mm",
     "opaquePipelineState    = opaquePipelineOwner.relinquish();"),
    ("alpha-pso-state",
     "game/graphics/iosgpuscene.mm",
     "alphaTestPipelineState = alphaTestPipelineOwner.relinquish();"),
    ("alpha-fragment-descriptor-assignment",
     "game/graphics/iosgpuscene.mm",
     """pipelineDesc.fragmentFunction =
          (id<MTLFunction>)alphaTestFragmentFunction.get();"""),
    ("strict-selector",
     "game/graphics/iosgpuscene.mm",
     """iosGPUScenePipelineSelectionMatches(
           plan.materialCategory,plan.pipeline)"""),
    ("required-functions-availability-map",
     "game/graphics/iosgpuscene.mm",
     "iosGPUSceneRequiredShaderFunctionsAreAvailable("),
    ("required-pso-availability-map",
     "game/graphics/iosgpuscene.mm",
     "iosGPUSceneProductionPipelineStatesAreAvailable("),
    ("pipeline-initialization-success",
     "game/graphics/iosgpuscene.mm",
     "initializationResult   = IOSGPUScene::Result::Success;"),
    ("planned-production-count",
     "game/graphics/iosgpuscene.mm",
     "plan.usesFallbackTexture,false,report.counts.planned"),
    ("drawn-production-count",
     "game/graphics/iosgpuscene.mm",
     "plan.usesFallbackTexture,true,nextCounts.drawn"),
    ("production-count-equations",
     "game/graphics/iosgpuscene.mm",
     "iosGPUSceneProductionReportCountsAreConsistent("),
    ("production-marker-set",
     "game/graphics/iosmetalcontext.cpp",
     "const IOSGPUSceneMarker markers[] = {"),
    ("identity-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneIdentityMarker("),
    ("material-planned-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneMaterialPlannedMarker("),
    ("material-drawn-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneMaterialDrawnMarker("),
    ("kind-planned-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneKindPlannedMarker("),
    ("kind-drawn-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneKindDrawnMarker("),
    ("alpha-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneAlphaMarker("),
    ("fail-contract-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneFailContractMarker("),
    ("fail-selector-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneFailSelectorMarker("),
    ("fail-execution-marker-call",
     "game/graphics/iosmetalcontext.cpp",
     "iosGPUSceneFailExecutionMarker("),
    ("failure-marker-before-fatal",
     "game/graphics/iosmetalcontext.cpp",
     """report.result!=IOSGPUScene::Result::Success ||
           forceNativeSceneMarkers ||
           input.snapshot->sequence.value==1u"""),
)
marker_order = (
    "iosGPUSceneIdentityMarker(",
    "iosGPUSceneMaterialPlannedMarker(",
    "iosGPUSceneMaterialDrawnMarker(",
    "iosGPUSceneKindPlannedMarker(",
    "iosGPUSceneKindDrawnMarker(",
    "iosGPUSceneAlphaMarker(",
    "iosGPUSceneFailContractMarker(",
    "iosGPUSceneFailSelectorMarker(",
    "iosGPUSceneFailExecutionMarker(",
)


def valid(sources: dict[str, str]) -> bool:
    if not all(sources[path].count(snippet) == 1
               for _, path, snippet in required):
        return False
    marker_source = sources["game/graphics/iosmetalcontext.cpp"]
    return [
        marker_source.index(marker) for marker in marker_order
    ] == sorted(marker_source.index(marker) for marker in marker_order)


missing = [
    label for label, path, snippet in required
    if paths[path].count(snippet) != 1
]
if missing:
    raise SystemExit(
        "RendererIOS C3b2 source contract missing or duplicated: "
        + ",".join(missing)
    )
if paths["game/graphics/iosgpuscene.mm"].count(
        "[device newRenderPipelineStateWithDescriptor:pipelineDesc") != 2:
    raise SystemExit("RendererIOS C3b2 must create exactly two offline PSOs")
for forbidden in (
    "newLibraryWithSource",
    "newCommandQueue",
    "presentDrawable",
    "mode=causal-a",
    "mode=causal-b",
):
    if forbidden in paths["game/graphics/iosgpuscene.mm"] or \
       forbidden in paths["game/graphics/iosmetalcontext.cpp"]:
        raise SystemExit(
            "RendererIOS C3b2 product path contains forbidden token: "
            + forbidden
        )

mutations_killed = 0
for label, path, snippet in required:
    for operation, replacement in (
        ("removed", ""),
        ("replaced", "C3B2_MUTANT"),
    ):
        mutant = dict(paths)
        mutant[path] = mutant[path].replace(snippet,replacement,1)
        if valid(mutant):
            raise SystemExit(
                "RendererIOS C3b2 source mutation survived: "
                + label + "-" + operation
            )
        mutations_killed += 1
marker_path = "game/graphics/iosmetalcontext.cpp"
for index in range(len(marker_order)-1):
    mutant = dict(paths)
    first = marker_order[index]
    second = marker_order[index+1]
    swapped = mutant[marker_path].replace(first,"C3B2_MARKER_SWAP",1)
    swapped = swapped.replace(second,first,1)
    mutant[marker_path] = swapped.replace("C3B2_MARKER_SWAP",second,1)
    if valid(mutant):
        raise SystemExit(
            "RendererIOS C3b2 marker-order mutation survived: "
            + str(index)
        )
    mutations_killed += 1
expected_mutations = 2*len(required)+len(marker_order)-1
if mutations_killed != expected_mutations:
    raise SystemExit("RendererIOS C3b2 mutation count drifted")
print(
    "RendererIOS C3b2 source oracle: mutations-killed="
    + str(mutations_killed)
)
PY

printf '\n### CI contract: Verify RendererIOS native GPU and offline Metal contracts\n'
set -euo pipefail

test -f game/graphics/iosgpusceneplan.h
test -f game/graphics/iosgpuscene.h
test -f game/graphics/iosgpuscene.mm
test -f game/graphics/ioslandscapeshaderabi.h
test -f game/graphics/iosshadingprototypeshaderabi.h
test -f game/graphics/iosshadingprototypepipeline.h
test -f game/graphics/iosshadingprototypepipeline.cpp
test -f game/graphics/iosshadingprototypepipeline.mm
test -f game/graphics/iosshadingprototypepipelinenative.h
test -f game/graphics/iosshadingprototypeforwardpipeline.h
test -f game/graphics/iosshadingprototypeforwardpipeline.cpp
test -f game/graphics/iosshadingprototypeforwardpipeline.mm
test -f game/graphics/iosshadingprototypeforwardpipelinenative.h
test -f game/graphics/iosshadingprototypeforwardprobe.h
test -f game/graphics/iosshadingprototypeforwardprobe.cpp
test -f game/graphics/iosshadingprototypeforwardprobe.mm
test -f game/graphics/iosshadingprototypetileprobe.h
test -f game/graphics/iosshadingprototypetileprobe.cpp
test -f game/graphics/iosshadingprototypetileprobe.mm
test -f game/graphics/iosbuiltinshaderabi.h
test -f game/graphics/iosinventoryshaderabi.h
test -f game/graphics/iosbinkshaderabi.h
test -f game/graphics/iosbinkselftest.h
test -f game/graphics/iosgpubink.h
test -f game/graphics/iosgpubink.mm
test -f shader/ios-metal/landscape.metal
test -f shader/ios-metal/bink.metal
test -f shader/ios-metal/ui.metal
test -f shader/ios-metal/inventory.metal
test -f shader/ios-metal/shading-prototypes.metal
test -f ios/tests/iosgpusceneplan.cpp
test -f game/graphics/iosuvanimationdiagnostics.h
test -f ios/tests/iosuvanimationdiagnostics.cpp
test -f ios/tests/ioslandscapeshader.cpp
test -f ios/tests/iosbuiltinshader.cpp
test -f ios/tests/iosinventoryshader.cpp
test -f ios/tests/iosshadingprototypeshader.cpp
test -f ios/tests/iosshadingprototypepipeline.cpp
test -f ios/tests/iosshadingprototypeforwardpipeline.cpp
test -f ios/tests/iosshadingprototypeforwardprobe.cpp
test -f ios/tests/iosshadingprototypetileprobe.cpp
test -f ios/tests/iosbinkshader.cpp
test -f ios/tests/iosbinkselftest.cpp

printf '#include "graphics/iosgpusceneplan.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
printf '#include "graphics/iosgpuscene.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosgpusceneplan.cpp \
  -o "$RUNNER_TEMP/iosgpusceneplan"
"$RUNNER_TEMP/iosgpusceneplan"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame ios/tests/iosuvanimationdiagnostics.cpp \
  -o "$RUNNER_TEMP/iosuvanimationdiagnostics"
"$RUNNER_TEMP/iosuvanimationdiagnostics"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address -fno-omit-frame-pointer \
  -Igame ios/tests/iosuvanimationdiagnostics.cpp \
  -o "$RUNNER_TEMP/iosuvanimationdiagnostics-asan"
"$RUNNER_TEMP/iosuvanimationdiagnostics-asan"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=undefined -fno-sanitize-recover=undefined \
  -fno-omit-frame-pointer \
  -Igame ios/tests/iosuvanimationdiagnostics.cpp \
  -o "$RUNNER_TEMP/iosuvanimationdiagnostics-ubsan"
"$RUNNER_TEMP/iosuvanimationdiagnostics-ubsan"

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
printf '#include "graphics/iosshadingprototypepipeline.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypepipeline.cpp \
  game/graphics/iosshadingprototypepipeline.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypepipeline"
"$RUNNER_TEMP/iosshadingprototypepipeline"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypepipeline.cpp \
  game/graphics/iosshadingprototypepipeline.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypepipeline-sanitized"
"$RUNNER_TEMP/iosshadingprototypepipeline-sanitized"
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/iosshadingprototypepipeline.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -c game/graphics/iosshadingprototypepipeline.mm \
  -o "$RUNNER_TEMP/iosshadingprototypepipeline.o"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -fsyntax-only ios/tests/iosshadingprototypepipeline.cpp
printf '#include "graphics/iosshadingprototypeforwardpipeline.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeforwardpipeline.cpp \
  game/graphics/iosshadingprototypeforwardpipeline.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardpipeline"
"$RUNNER_TEMP/iosshadingprototypeforwardpipeline"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypeforwardpipeline.cpp \
  game/graphics/iosshadingprototypeforwardpipeline.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardpipeline-sanitized"
"$RUNNER_TEMP/iosshadingprototypeforwardpipeline-sanitized"
printf '#include "graphics/iosshadingprototypeforwardpipeline.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -target arm64-apple-ios16.4 \
    -isysroot "$IOS_SDK" \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -c game/graphics/iosshadingprototypeforwardpipeline.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardpipeline-cpp.o"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -fsyntax-only ios/tests/iosshadingprototypeforwardpipeline.cpp
xcrun clang++ -x objective-c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only \
  game/graphics/iosshadingprototypeforwardpipeline.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -c game/graphics/iosshadingprototypeforwardpipeline.mm \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardpipeline-macos.o"
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only \
  game/graphics/iosshadingprototypeforwardpipeline.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -c game/graphics/iosshadingprototypeforwardpipeline.mm \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardpipeline-mm.o"
printf '#include "graphics/iosshadingprototypeforwardprobe.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
printf '#include "graphics/iosshadingprototypeforwardpipelinenative.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeforwardprobe.cpp \
  game/graphics/iosshadingprototypeforwardprobe.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardprobe"
"$RUNNER_TEMP/iosshadingprototypeforwardprobe"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypeforwardprobe.cpp \
  game/graphics/iosshadingprototypeforwardprobe.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardprobe-sanitized"
"$RUNNER_TEMP/iosshadingprototypeforwardprobe-sanitized"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -fsyntax-only \
  game/graphics/iosshadingprototypeforwardprobe.cpp \
  ios/tests/iosshadingprototypeforwardprobe.cpp
xcrun clang++ -x objective-c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only \
  game/graphics/iosshadingprototypeforwardprobe.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1 \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only \
  game/graphics/iosshadingprototypeforwardprobe.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -c game/graphics/iosshadingprototypeforwardprobe.mm \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardprobe-macos.o"
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only \
  game/graphics/iosshadingprototypeforwardprobe.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1 \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only \
  game/graphics/iosshadingprototypeforwardprobe.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -c game/graphics/iosshadingprototypeforwardprobe.mm \
  -o "$RUNNER_TEMP/iosshadingprototypeforwardprobe-ios.o"
printf '#include "graphics/iosshadingprototypetileprobe.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypetileprobe.cpp \
  game/graphics/iosshadingprototypetileprobe.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypetileprobe"
"$RUNNER_TEMP/iosshadingprototypetileprobe"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypetileprobe.cpp \
  game/graphics/iosshadingprototypetileprobe.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypetileprobe-sanitized"
"$RUNNER_TEMP/iosshadingprototypetileprobe-sanitized"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -fsyntax-only ios/tests/iosshadingprototypetileprobe.cpp
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/iosshadingprototypetileprobe.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -c game/graphics/iosshadingprototypetileprobe.mm \
  -o "$RUNNER_TEMP/iosshadingprototypetileprobe.o"
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iosgpuscene.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iosgpubink.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/rendereriosplatform.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/rendereriosplatform.mm

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/ioslandscapeshader.cpp \
  -o "$RUNNER_TEMP/ioslandscapeshader"
"$RUNNER_TEMP/ioslandscapeshader" \
  shader/ios-metal/landscape.metal "$PWD"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address -fno-omit-frame-pointer \
  -Igame \
  ios/tests/ioslandscapeshader.cpp \
  -o "$RUNNER_TEMP/ioslandscapeshader-asan"
"$RUNNER_TEMP/ioslandscapeshader-asan" \
  shader/ios-metal/landscape.metal "$PWD"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=undefined -fno-sanitize-recover=undefined \
  -fno-omit-frame-pointer \
  -Igame \
  ios/tests/ioslandscapeshader.cpp \
  -o "$RUNNER_TEMP/ioslandscapeshader-ubsan"
"$RUNNER_TEMP/ioslandscapeshader-ubsan" \
  shader/ios-metal/landscape.metal "$PWD"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosbinkshader.cpp \
  -o "$RUNNER_TEMP/iosbinkshader"
"$RUNNER_TEMP/iosbinkshader" \
  shader/ios-metal/bink.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosbuiltinshader.cpp \
  -o "$RUNNER_TEMP/iosbuiltinshader"
"$RUNNER_TEMP/iosbuiltinshader" \
  shader/ios-metal/ui.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosinventoryshader.cpp \
  -o "$RUNNER_TEMP/iosinventoryshader"
"$RUNNER_TEMP/iosinventoryshader" \
  shader/ios-metal/inventory.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeshader.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeshader"
"$RUNNER_TEMP/iosshadingprototypeshader" \
  shader/ios-metal/shading-prototypes.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypeshader.cpp \
  -o "$RUNNER_TEMP/iosshadingprototypeshader-sanitized"
"$RUNNER_TEMP/iosshadingprototypeshader-sanitized" \
  shader/ios-metal/shading-prototypes.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosbinkselftest.cpp \
  -o "$RUNNER_TEMP/iosbinkselftest"
"$RUNNER_TEMP/iosbinkselftest"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -Wall -Wextra -Werror \
  -c "$PWD/shader/ios-metal/landscape.metal" \
  -o "$RUNNER_TEMP/ios-landscape.air"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -c "$PWD/shader/ios-metal/bink.metal" \
  -o "$RUNNER_TEMP/ios-bink.air"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -c "$PWD/shader/ios-metal/ui.metal" \
  -o "$RUNNER_TEMP/ios-ui.air"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -c "$PWD/shader/ios-metal/inventory.metal" \
  -o "$RUNNER_TEMP/ios-inventory.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$RUNNER_TEMP/ios-landscape.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$RUNNER_TEMP/ios-bink.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$RUNNER_TEMP/ios-ui.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$RUNNER_TEMP/ios-inventory.air"

P25C1A_BASELINE_SHA=d30ff428f237bbc8d1c25e5954d4df3381740339
P25C1A_TRACKED_SOURCE="$PWD/shader/ios-metal/shading-prototypes.metal"
P25C1A_BASELINE_SOURCE="$RUNNER_TEMP/RendererIOS-ShadingPrototypes.baseline.metal"
P25C1A_CANDIDATE_SOURCE="$RUNNER_TEMP/RendererIOS-ShadingPrototypes.candidate.metal"
P25C1A_STRICT_AIR="$RUNNER_TEMP/ios-shading-prototypes-strict.air"
P25C1A_BASELINE_AIR="$RUNNER_TEMP/ios-shading-prototypes-baseline.air"
P25C1A_CANDIDATE_AIR="$RUNNER_TEMP/ios-shading-prototypes-candidate.air"
P25C1A_BASELINE_METALLIB="$RUNNER_TEMP/RendererIOS.baseline.metallib"
P25C1A_CANDIDATE_METALLIB="$RUNNER_TEMP/RendererIOS.candidate.metallib"

git cat-file -e "${P25C1A_BASELINE_SHA}^{commit}"
git merge-base --is-ancestor "$P25C1A_BASELINE_SHA" HEAD
for source in \
    shader/ios-metal/bink.metal \
    shader/ios-metal/ui.metal \
    shader/ios-metal/inventory.metal; do
  if ! git diff --quiet "$P25C1A_BASELINE_SHA" -- "$source"; then
    echo "P2.5c1a fixed metallib input changed since c0: $source"
    exit 1
  fi
done

xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -Wall -Wextra -Werror \
  -c "$P25C1A_TRACKED_SOURCE" \
  -o "$P25C1A_STRICT_AIR"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$P25C1A_STRICT_AIR"

compile_production_shading_prototype() {
  local output="$1"
  xcrun --sdk iphoneos metal \
    -target air64-apple-ios16.4 \
    -c "$P25C1A_TRACKED_SOURCE" \
    -o "$output"
}
link_rendererios_metallib() {
  local prototype_air="$1"
  local output="$2"
  xcrun --sdk iphoneos metallib \
    "$RUNNER_TEMP/ios-landscape.air" \
    "$RUNNER_TEMP/ios-bink.air" \
    "$RUNNER_TEMP/ios-ui.air" \
    "$RUNNER_TEMP/ios-inventory.air" \
    "$prototype_air" \
    -o "$output"
}

cp "$P25C1A_TRACKED_SOURCE" "$P25C1A_CANDIDATE_SOURCE"
git show \
  "$P25C1A_BASELINE_SHA:shader/ios-metal/shading-prototypes.metal" \
  >"$P25C1A_BASELINE_SOURCE"
if cmp -s "$P25C1A_BASELINE_SOURCE" "$P25C1A_CANDIDATE_SOURCE"; then
  echo 'P2.5c1a candidate source is identical to the c0 baseline'
  exit 1
fi
restore_p25c1a_candidate() {
  cp "$P25C1A_CANDIDATE_SOURCE" "$P25C1A_TRACKED_SOURCE"
}
trap restore_p25c1a_candidate EXIT
trap 'restore_p25c1a_candidate; exit 130' HUP INT TERM
cp "$P25C1A_BASELINE_SOURCE" "$P25C1A_TRACKED_SOURCE"
cmp -s "$P25C1A_BASELINE_SOURCE" "$P25C1A_TRACKED_SOURCE"
compile_production_shading_prototype "$P25C1A_BASELINE_AIR"
restore_p25c1a_candidate
cmp -s "$P25C1A_CANDIDATE_SOURCE" "$P25C1A_TRACKED_SOURCE"
compile_production_shading_prototype "$P25C1A_CANDIDATE_AIR"
trap - EXIT HUP INT TERM
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$P25C1A_BASELINE_AIR"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$P25C1A_CANDIDATE_AIR"

link_rendererios_metallib \
  "$P25C1A_BASELINE_AIR" "$P25C1A_BASELINE_METALLIB"
link_rendererios_metallib \
  "$P25C1A_CANDIDATE_AIR" "$P25C1A_CANDIDATE_METALLIB"

EXPECTED_RIOS_EXPORTS="$(printf '%s\n' \
  riosLandscapeVertex riosLandscapeFragment \
  riosLandscapeAlphaTestFragment \
  riosBinkVertex riosBinkFragment \
  riosUiColorVertex riosUiColorFragment \
  riosUiTextureVertex riosUiTextureFragment \
  riosInventoryVertex riosInventoryFragment \
  riosShadingPrototypeVertex \
  riosTileDeferredMaterialFragment \
  riosTileDeferredLighting \
  riosForwardPlusBuildLightList \
  riosForwardPlusFragment | LC_ALL=C sort)"
require_exact_rendererios_exports() {
  local metallib="$1"
  local exports
  local function
  for function in \
      riosLandscapeVertex riosLandscapeFragment \
      riosLandscapeAlphaTestFragment \
      riosBinkVertex riosBinkFragment \
      riosUiColorVertex riosUiColorFragment \
      riosUiTextureVertex riosUiTextureFragment \
      riosInventoryVertex riosInventoryFragment \
      riosShadingPrototypeVertex \
      riosTileDeferredMaterialFragment \
      riosTileDeferredLighting \
      riosForwardPlusBuildLightList \
      riosForwardPlusFragment; do
    LC_ALL=C grep -aFq "$function" "$metallib"
  done
  exports="$(xcrun --sdk iphoneos metal-nm "$metallib" |
    awk '$2 == "T" { print $3 }' | LC_ALL=C sort)"
  test "$exports" = "$EXPECTED_RIOS_EXPORTS"
  test "$(printf '%s\n' "$exports" | wc -l | tr -d ' ')" -eq 16
}
require_exact_rendererios_exports "$P25C1A_BASELINE_METALLIB"
require_exact_rendererios_exports "$P25C1A_CANDIDATE_METALLIB"

P25C1A_BASELINE_DIGEST="$(
  shasum -a 256 "$P25C1A_BASELINE_METALLIB" | awk '{print $1}'
)"
P25C1A_CANDIDATE_DIGEST="$(
  shasum -a 256 "$P25C1A_CANDIDATE_METALLIB" | awk '{print $1}'
)"
test "$P25C1A_BASELINE_DIGEST" != "$P25C1A_CANDIDATE_DIGEST"
printf '%s\n' "$P25C1A_BASELINE_DIGEST" \
  >"$RUNNER_TEMP/RendererIOS.baseline.sha256"
printf '%s\n' "$P25C1A_CANDIDATE_DIGEST" \
  >"$RUNNER_TEMP/RendererIOS.candidate.sha256"

cat >"$RUNNER_TEMP/iosshadingprototypeprovenance.cpp" <<'CPP'
#define OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS 1
#include "graphics/iospipelinearchivepolicy.h"

#include <string>
#include <string_view>

namespace Archive = RendererIOSPipelineArchive;

int main(int argc, char** argv) {
  static_assert(Archive::ProvenanceSchemaVersion==1u);
  static_assert(Archive::CacheSchemaVersion==1u);
  static_assert(Archive::PipelineKeyAbiVersion==1u);
  static_assert(Archive::MetallibAbiVersion==7u);
  static_assert(Archive::TestModeDirectoryComponents[0]=="RendererIOS");
  static_assert(
    Archive::TestModeDirectoryComponents[1]=="PipelineArchives");
  static_assert(Archive::TestModeDirectoryComponents[2]=="schema-1");
  static_assert(
    Archive::RelativeArchivePath==
    "RendererIOS/PipelineArchives/schema-1/"
    "RendererIOS-abi-7.binaryarchive");
  if(argc!=3)
    return 1;
  const std::string_view candidate = argv[1];
  const std::string_view baseline = argv[2];
  if(!Archive::isLowercaseSha256(candidate) ||
     !Archive::isLowercaseSha256(baseline) ||
     candidate==baseline)
    return 2;
  const std::string record = Archive::provenanceRecord(candidate);
  if(record.empty() ||
     !Archive::provenanceMatches(record,candidate) ||
     Archive::provenanceMatches(record,baseline))
    return 3;
  const std::string expected =
    "renderer=RendererIOS\n"
    "provenance-schema=1\n"
    "cache-schema=1\n"
    "pipeline-key-abi=1\n"
    "metallib-abi=7\n"
    "metallib-sha256="+std::string(candidate)+"\n"
    "archive-file=RendererIOS-abi-7.binaryarchive\n";
  return record==expected ? 0 : 4;
}
CPP
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  "$RUNNER_TEMP/iosshadingprototypeprovenance.cpp" \
  -o "$RUNNER_TEMP/iosshadingprototypeprovenance"
"$RUNNER_TEMP/iosshadingprototypeprovenance" \
  "$P25C1A_CANDIDATE_DIGEST" "$P25C1A_BASELINE_DIGEST"

if grep -Eq \
    'newLibraryWithSource|compileSource|MTLCompileOptions|newCommandQueue|commandBufferWith|presentDrawable' \
    shader/ios-metal/shading-prototypes.metal \
    game/graphics/iosshadingprototypeshaderabi.h; then
  echo 'P2.5b0 prototype ABI contains runtime compilation or ownership'
  exit 1
fi
if rg -n \
    'riosForwardPlusBuildLightList|riosForwardPlusFragment' \
    game \
    --glob '!iosshadingprototypeshaderabi.h' \
    --glob '!iosshadingprototypeforwardpipeline.h' \
    --glob '!iosshadingprototypeforwardpipeline.cpp' \
    --glob '!iosshadingprototypeforwardpipeline.mm' \
    --glob '!iosshadingprototypeforwardpipelinenative.h' \
    --glob '!iosshadingprototypeforwardprobe.h' \
    --glob '!iosshadingprototypeforwardprobe.cpp' \
    --glob '!iosshadingprototypeforwardprobe.mm'; then
  echo 'P2.5c0 Forward+ ABI escaped its factory allowlist'
  exit 1
fi
if grep -Eq \
    'ForwardLightListFunction|ForwardFragmentFunction|riosForwardPlus|FunctionNames\[' \
    game/graphics/iosshadingprototypepipeline.h \
    game/graphics/iosshadingprototypepipeline.cpp \
    game/graphics/iosshadingprototypepipeline.mm; then
  echo 'P2.5b1 Tile-only factory references a reserved Forward+ ABI'
  exit 1
fi
test "$(grep -Fc 'iosCreateShadingPrototypePipeline' \
    game/graphics/iosmetalcontext.cpp)" -eq 1
if rg -n 'iosCreateShadingPrototypePipeline' game \
    --glob '!iosshadingprototypepipeline.h' \
    --glob '!iosshadingprototypepipeline.mm' \
    --glob '!iosmetalcontext.cpp'; then
  echo 'P2.5b3 Tile factory caller escaped its exact iosmetalcontext.cpp allowlist'
  exit 1
fi
test "$(grep -Fc 'iosCreateShadingPrototypeForwardPipeline' \
    game/graphics/iosmetalcontext.cpp)" -eq 1
if rg -n 'iosCreateShadingPrototypeForwardPipeline' game \
    --glob '!iosshadingprototypeforwardpipeline.h' \
    --glob '!iosshadingprototypeforwardpipeline.mm' \
    --glob '!iosmetalcontext.cpp'; then
  echo 'P2.5c1b1 Forward+ factory caller escaped its exact iosmetalcontext.cpp allowlist'
  exit 1
fi
python3 - <<'PY'
from pathlib import Path

context = "game/graphics/iosmetalcontext.cpp"
pipeline_h = "game/graphics/iosshadingprototypeforwardpipeline.h"
pipeline_mm = "game/graphics/iosshadingprototypeforwardpipeline.mm"
probe_h = "game/graphics/iosshadingprototypeforwardprobe.h"
probe_mm = "game/graphics/iosshadingprototypeforwardprobe.mm"
contracts = {
    "iosCreateShadingPrototypeForwardPipeline": {
        pipeline_h: 2, pipeline_mm: 1, context: 1,
    },
    "iosCreateShadingPrototypeForwardLightList": {
        probe_h: 2, probe_mm: 1, context: 1,
    },
    "iosReadShadingPrototypeForwardLightListContents": {
        probe_h: 2, probe_mm: 1, context: 1,
    },
    "iosEncodeShadingPrototypeForwardProbe": {
        probe_h: 1, probe_mm: 1, context: 1,
    },
}
paths = {path for files in contracts.values() for path in files}
sources = {path: Path(path).read_text() for path in paths}

def accepts(candidate):
    return all(
        candidate[path].count(symbol) == expected
        for symbol, files in contracts.items()
        for path, expected in files.items()
    )

if not accepts(sources):
    raise SystemExit("P2.5c1b1 Forward caller occurrence contract failed")
mutations_killed = 0
for symbol, files in contracts.items():
    for path in files:
        mutated = dict(sources)
        mutated[path] += "\n" + symbol + "\n"
        if accepts(mutated):
            raise SystemExit(
                "P2.5c1b1 Forward caller duplicate survived: "
                + symbol + " in " + path
            )
        mutations_killed += 1
if mutations_killed != 12:
    raise SystemExit("P2.5c1b1 Forward caller mutation count drifted")
print("P2.5c1b1 Forward caller oracle: mutations-killed=12")
PY
if grep -Eq \
    '#import|<Metal/|@interface|id<MTL|MTL[A-Z]|__OBJC__' \
    game/graphics/iosshadingprototypeforwardpipeline.h \
    game/graphics/iosshadingprototypeforwardpipeline.cpp; then
  echo 'P2.5c0 host-neutral contract leaks Objective-C or Metal'
  exit 1
fi
P25C0_RUNTIME_DENY='MTLCreateSystemDefaultDevice|newCommandQueue|MTLCommandQueue|MTLCommandBuffer|newCommandBuffer|commandBufferWith|commandBuffer\]|CommandEncoder|setRenderPipelineState|setComputePipelineState|drawPrimitives|drawIndexedPrimitives|dispatchThreadgroups|dispatchThreads|presentDrawable|commit\]|enqueue\]|waitUntilCompleted|newLibraryWithSource|newDefaultLibrary|MTLCompileOptions|newBufferWith|newTextureWith|newHeap|makeAliasable|MTLBinaryArchive|addRenderPipelineFunctions|addComputePipelineFunctions|serializeToURL|MetalFX|withActiveCommandBuffer|withActiveRenderEncoder|IOSShadingPrototypePlan'
if grep -Eq "$P25C0_RUNTIME_DENY" \
    game/graphics/iosshadingprototypeforwardpipeline.h \
    game/graphics/iosshadingprototypeforwardpipeline.cpp \
    game/graphics/iosshadingprototypeforwardpipeline.mm; then
  echo 'P2.5c0 Forward+ factory owns forbidden runtime work'
  exit 1
fi
grep -Fq 'Tempest::MetalApi::borrowDevice(owner)' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq 'supportsFamily:MTLGPUFamilyApple4' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq 'newLibraryWithURL:libraryUrl error:&libraryError' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq 'ForwardLightListFunction' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq 'ForwardFragmentFunction' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
test "$(grep -Fc 'setConstantValue:&alphaTest' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 2
test "$(grep -Fc 'alphaTest = false;' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 1
test "$(grep -Fc 'alphaTest = true;' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 1
test "$(grep -Fc 'constantValues:' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 2
test "$(grep -Fc 'MTLPipelineOptionBindingInfo' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 2
test "$(grep -Fc \
    'newComputePipelineStateWithDescriptor:descriptor' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 1
grep -Fq 'descriptor.computeFunction = function;' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
test "$(grep -Fc \
    'newRenderPipelineStateWithDescriptor:descriptor' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 1
test "$(grep -Fc 'descriptor.binaryArchives = nil;' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 2
grep -Fq \
  'descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = NO;' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq \
  'descriptor.maxTotalThreadsPerThreadgroup = NSUInteger(0u);' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq 'descriptor.stageInputDescriptor = nil;' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
test "$(grep -Fc \
    'descriptor.supportIndirectCommandBuffers = NO;' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 2
grep -Fq 'descriptor.linkedFunctions = nil;' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq 'descriptor.supportAddingBinaryFunctions = NO;' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq 'descriptor.maxCallStackDepth = NSUInteger(1u);' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq 'descriptor.rasterizationEnabled = YES;' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
test "$(python3 - <<'PY'
from pathlib import Path

source = Path(
    "game/graphics/iosshadingprototypeforwardpipeline.mm"
).read_text()
normalized = "".join(source.split())
needle = (
    "static_assert("
    "RendererIOSShadingPrototypeShader::"
    "TotalMetallibExportCount==16u);"
)
print(normalized.count(needle))
PY
)" -eq 1
grep -Fq 'static_assert(sizeof(Report)==372u);' \
  ios/tests/iosshadingprototypeforwardpipeline.cpp
grep -Fq 'if(mutations!=197u)' \
  ios/tests/iosshadingprototypeforwardpipeline.cpp
grep -Fq \
  'respectsGlobalPipelineBeforeReflectionPrecedence' \
  ios/tests/iosshadingprototypeforwardpipeline.cpp
grep -Fq 'respectsPartialNativeBuildPrecedence' \
  ios/tests/iosshadingprototypeforwardpipeline.cpp
grep -Fq \
  'const std::array<NativePipelineBuild,3u> builds =' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq \
  'computeBuild!=NativePipelineBuild::CreationFailed' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq \
  'opaqueBuild!=NativePipelineBuild::CreationFailed' \
  game/graphics/iosshadingprototypeforwardpipeline.mm
grep -Fq \
  'alphaBuild!=NativePipelineBuild::CreationFailed' \
  game/graphics/iosshadingprototypeforwardpipeline.mm

P25C1B0_HOST_FILES=(
  game/graphics/iosshadingprototypeforwardprobe.h
  game/graphics/iosshadingprototypeforwardprobe.cpp
)
P25C1B0_NATIVE_FILES=(
  game/graphics/iosshadingprototypeforwardpipelinenative.h
  game/graphics/iosshadingprototypeforwardprobe.mm
)
if grep -Eq \
    '#import|<Metal/|@interface|id[[:space:]]*<MTL|namespace[[:space:]]+MTL|__OBJC__|void[[:space:]]*\*|NativeHandle' \
    "${P25C1B0_HOST_FILES[@]}"; then
  echo 'P2.5c1b0 host-neutral Forward probe leaks Objective-C or Metal'
  exit 1
fi
if grep -Eq '#import|<Metal/|@interface|id<MTL|__OBJC__' \
    game/graphics/iosshadingprototypeforwardpipelinenative.h; then
  echo 'P2.5c1b0 private native view includes Objective-C or Metal headers'
  exit 1
fi
P25C1B0_FORBIDDEN='MTLCreateSystemDefaultDevice|newCommandQueue|newCommandBuffer|commandBufferWith|commandBuffer\]|id[[:space:]]*<MTLFence>|newFence|newEvent|newSharedEvent|updateFence|waitForFence|(^|[^[:alnum:]_])readBytes[[:space:]]*\(|(^|[^[:alnum:]_])readPixels[[:space:]]*\(|getBytes|(^|[^[:alnum:]_])submit[[:space:]]*\(|commit\]|enqueue\]|waitUntilCompleted\]|addCompletedHandler:|withActiveRenderEncoder|blitCommandEncoder|parallelRenderCommandEncoder|resourceStateCommandEncoder|accelerationStructureCommandEncoder|dispatchThreadgroups|drawIndexedPrimitives|drawMesh|executeCommandsInBuffer|useResource|useHeap|memoryBarrier|sampleCounters|resolveCounters|synchronizeResource|synchronizeTexture|startCapture|stopCapture|nextDrawable|presentDrawable|newLibraryWithSource|newDefaultLibrary|newLibraryWithURL|newFunctionWithName|newComputePipelineState|newRenderPipelineState|newTextureWith|newHeap|newSamplerState|newArgumentEncoder|newAccelerationStructure|newIndirectCommandBuffer|makeAliasable|MTLCompileOptions|MTLBinaryArchive|addRenderPipelineFunctions|addComputePipelineFunctions|serializeToURL|MetalFX'
for fixture in \
    'MTLCreateSystemDefaultDevice()' \
    '[device newCommandQueue]' \
    '[device newCommandBuffer]' \
    'id<MTLFence> fence' \
    '[device newSharedEvent]' \
    '[encoder updateFence:fence]' \
    '[encoder waitForFence:fence]' \
    'device.readBytes(buffer,0u,bytes)' \
    'texture.readPixels(output)' \
    '[texture getBytes:bytes bytesPerRow:row]' \
    'device.submit(command)' \
    '[command addCompletedHandler:handler]' \
    '[command commit]' \
    '[command enqueue]' \
    '[command waitUntilCompleted]' \
    '[queue commandBuffer]' \
    'Tempest::MetalApi::withActiveRenderEncoder(' \
    '[command blitCommandEncoder]' \
    '[compute dispatchThreadgroups:grid threadsPerThreadgroup:size]' \
    '[render drawIndexedPrimitives:type indexCount:count]' \
    '[render useResource:resource usage:usage]' \
    '[capture startCaptureWithDescriptor:descriptor error:&error]' \
    '[capture stopCapture]' \
    '[swapchain nextDrawable]' \
    '[command presentDrawable:drawable]' \
    '[device newLibraryWithSource:source options:nil error:&error]' \
    '[device newDefaultLibrary]' \
    '[device newLibraryWithURL:url error:&error]' \
    '[library newFunctionWithName:name]' \
    '[device newComputePipelineStateWithDescriptor:descriptor]' \
    '[device newRenderPipelineStateWithDescriptor:descriptor]' \
    '[device newTextureWithDescriptor:descriptor]' \
    '[device newHeapWithDescriptor:descriptor]' \
    '[device newSamplerStateWithDescriptor:descriptor]' \
    '[device newIndirectCommandBufferWithDescriptor:descriptor]' \
    '[resource makeAliasable]' \
    'MTLCompileOptions* options' \
    'id<MTLBinaryArchive> archive' \
    '[archive addRenderPipelineFunctionsWithDescriptor:descriptor]' \
    '[archive addComputePipelineFunctionsWithDescriptor:descriptor]' \
    '[archive serializeToURL:url error:&error]' \
    'MetalFX::TemporalScaler'; do
  printf '%s\n' "$fixture" |
    grep -Eq "$P25C1B0_FORBIDDEN"
done
if grep -Eq "$P25C1B0_FORBIDDEN" \
    "${P25C1B0_NATIVE_FILES[@]}"; then
  echo 'P2.5c1b0 Forward probe escaped its compile-only encode boundary'
  exit 1
fi
test "$(grep -Fc 'Tempest::MetalApi::withActiveCommandBuffer(' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'newBufferWithLength:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'computeCommandEncoder' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'renderCommandEncoderWithDescriptor:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'setComputePipelineState:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'setBuffer:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'dispatchThreads:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'setFragmentBuffer:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'setVertexBytes:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'setRenderPipelineState:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 2
test "$(grep -Fc 'drawPrimitives:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 2
test "$(grep -Fc 'endEncoding]' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'if(!compute.endOnce())' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'if(!render.endOnce())' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
grep -Fq 'ForwardLightListByteSize' \
  game/graphics/iosshadingprototypeforwardprobe.mm
grep -Fq 'ForwardLightListSentinel' \
  game/graphics/iosshadingprototypeforwardprobe.mm
test "$(grep -Fc 'std::fill_n(' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
test "$(grep -Fc 'std::memcpy(' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
grep -Fq 'MTLLoadActionClear' \
  game/graphics/iosshadingprototypeforwardprobe.mm
grep -Fq 'MTLStoreActionStore' \
  game/graphics/iosshadingprototypeforwardprobe.mm
grep -Fq 'MTLClearColorMake(0.0,0.0,0.0,0.0)' \
  game/graphics/iosshadingprototypeforwardprobe.mm
grep -Fq 'colorAttachments[OutputAttachment]' \
  game/graphics/iosshadingprototypeforwardprobe.mm
grep -Fq 'depthAttachment.texture==nil' \
  game/graphics/iosshadingprototypeforwardprobe.mm
grep -Fq 'stencilAttachment.texture==nil' \
  game/graphics/iosshadingprototypeforwardprobe.mm
grep -Fq 'output.sampleCount==NSUInteger(1u)' \
  game/graphics/iosshadingprototypeforwardprobe.mm
test "$(grep -Fc 'MTLPrimitiveTypeTriangle' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 2
python3 - <<'PY'
from pathlib import Path

source = Path(
    "game/graphics/iosshadingprototypeforwardprobe.mm"
).read_text()
compact = "".join(source.split())

options = (
    "MTLResourceStorageModeShared|"
    "MTLResourceHazardTrackingModeTracked"
)
if compact.count(options) != 1:
    raise SystemExit(
        "P2.5c1b0 requires exactly Shared|Tracked buffer options"
    )

exact_native_contract = {
    "Tempest::MetalApi::borrowDevice(": 2,
    "IOSShadingPrototypeForwardPipelineNativeAccess::borrow(": 1,
    "IOSMetalResourceTextureNativeAccess::borrow(": 1,
    "IOSShadingPrototypeForwardLightListNativeAccess::borrow(": 2,
    "output.snapshot()": 1,
    (
        "setBuffer:lightList"
        "offset:static_cast<NSUInteger>(LightListOffset)"
        "atIndex:static_cast<NSUInteger>("
        "Shader::ForwardLightListBuffer)"
    ): 1,
    (
        "setFragmentBuffer:lightList"
        "offset:static_cast<NSUInteger>(LightListOffset)"
        "atIndex:static_cast<NSUInteger>("
        "Shader::ForwardLightListBuffer)"
    ): 1,
    (
        "setVertexBytes:Vertices.data()"
        "length:sizeof(Vertices)"
        "atIndex:static_cast<NSUInteger>("
        "PipelineContract::VertexBufferIndex)"
    ): 1,
    (
        "drawPrimitives:MTLPrimitiveTypeTriangle"
        "vertexStart:static_cast<NSUInteger>("
        "OpaqueVertexStart)"
        "vertexCount:static_cast<NSUInteger>("
        "TriangleVertexCount)"
    ): 1,
    (
        "drawPrimitives:MTLPrimitiveTypeTriangle"
        "vertexStart:static_cast<NSUInteger>("
        "AlphaTestVertexStart)"
        "vertexCount:static_cast<NSUInteger>("
        "TriangleVertexCount)"
    ): 1,
    "outputSnapshot.format==IOSPixelFormat::Rgba8Unorm": 1,
    (
        "outputSnapshot.storage=="
        "IOSMetalResourceStorage::Private"
    ): 1,
    (
        "report.outputWidth==OutputWidth&&"
        "report.outputHeight==OutputHeight&&"
        "report.outputMipLevels==OutputMipLevels&&"
        "report.outputSampleCount==OutputSampleCount&&"
        "outputSnapshot.depth==1u&&"
        "outputSnapshot.arrayLength==1u&&"
        "outputSnapshot.usageExactlyRepresented&&"
        "outputSnapshot.usage=="
        "IOSResourceUsage::RenderAttachment"
    ): 1,
}
for needle, expected in exact_native_contract.items():
    if compact.count(needle) != expected:
        raise SystemExit(
            "P2.5c1b0 native contract is not exact: "
            + needle
        )

compute = source.index("[command computeCommandEncoder]")
compute_end = source.index("if(!compute.endOnce())",compute)
render = source.index(
    "renderCommandEncoderWithDescriptor:",compute_end
)
render_end = source.index("if(!render.endOnce())",render)
if not compute < compute_end < render < render_end:
    raise SystemExit(
        "P2.5c1b0 encoder order is not compute/end/render/end"
    )

dispatch = source.index("dispatchThreads:",compute)
dispatch_done = source.index("report.dispatches = 1u;",dispatch)
dispatch_block = source[dispatch:dispatch_done]
dimensions = (
    "ForwardLightListGridWidth",
    "ForwardLightListGridHeight",
    "ForwardLightListGridDepth",
    "ForwardLightListThreadsPerThreadgroupWidth",
    "ForwardLightListThreadsPerThreadgroupHeight",
    "ForwardLightListThreadsPerThreadgroupDepth",
)
for dimension in dimensions:
    if dispatch_block.count(dimension) != 1:
        raise SystemExit(
            "P2.5c1b0 dispatch does not bind exact unit geometry: "
            + dimension
        )
PY
for symbol in \
    iosCreateShadingPrototypeForwardLightList \
    iosReadShadingPrototypeForwardLightListContents \
    iosEncodeShadingPrototypeForwardProbe; do
  test "$(grep -Fc "$symbol" \
      game/graphics/iosmetalcontext.cpp)" -eq 1
  matches="$(rg -l "$symbol" game | sort)"
  test "$matches" = \
    $'game/graphics/iosmetalcontext.cpp\ngame/graphics/iosshadingprototypeforwardprobe.h\ngame/graphics/iosshadingprototypeforwardprobe.mm'
done
test "$(rg -l \
    'IOSShadingPrototypeForwardPipelineNativeAccess' game |
    sort)" = \
  $'game/graphics/iosshadingprototypeforwardpipeline.h\ngame/graphics/iosshadingprototypeforwardpipeline.mm\ngame/graphics/iosshadingprototypeforwardpipelinenative.h\ngame/graphics/iosshadingprototypeforwardprobe.mm'
for label in \
    'RendererIOS Forward BuildLightList' \
    'RendererIOS Forward Opaque' \
    'RendererIOS Forward AlphaTest'; do
  grep -Fq "$label" \
    game/graphics/iosshadingprototypeforwardpipeline.h
  grep -Fq "$label" \
    game/graphics/iosshadingprototypeforwardpipeline.mm
done
test "$(grep -Fc 'descriptor.label =' \
    game/graphics/iosshadingprototypeforwardpipeline.mm)" -eq 2
for label in \
    'RendererIOS Forward Compute Encoder' \
    'RendererIOS Forward Render Encoder' \
    'RendererIOS Forward LightList 256B'; do
  grep -Fq "$label" \
    game/graphics/iosshadingprototypeforwardprobe.h
  test "$(grep -Fc "$label" \
      game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1
done
test "$(grep -Fc 'std::array<uint32_t,8u> reserved{};' \
    game/graphics/iosshadingprototypeforwardprobe.h)" -eq 3
for field in abiVersion structSize flags failureReason; do
  test "$(grep -Ec \
    "uint32_t[[:space:]]+${field}[[:space:]]*=[[:space:]]*0u;" \
    game/graphics/iosshadingprototypeforwardprobe.h)" -eq 3
done
for abi in \
    'sizeof(LightListReport)==164u' \
    'sizeof(ProbeReport)==468u' \
    'sizeof(TerminalReport)==268u' \
    'alignof(LightListReport)==4u' \
    'alignof(ProbeReport)==4u' \
    'alignof(TerminalReport)==4u'; do
  grep -Fq "$abi" \
    ios/tests/iosshadingprototypeforwardprobe.cpp
done
grep -Fq 'mutations=all-report-fields' \
  ios/tests/iosshadingprototypeforwardprobe.cpp
test "$(grep -Fc 'iosEncodeShadingPrototypeTileProbe' \
    game/graphics/iosmetalcontext.cpp)" -eq 1
if rg -n 'iosEncodeShadingPrototypeTileProbe' game \
    --glob '!iosshadingprototypetileprobe.h' \
    --glob '!iosshadingprototypetileprobe.mm' \
    --glob '!iosmetalcontext.cpp'; then
  echo 'P2.5b3 Tile encode caller escaped its exact iosmetalcontext.cpp allowlist'
  exit 1
fi
if grep -Eq \
    '#import|<Metal/|@interface|id<MTL|MTL[A-Z]|__OBJC__' \
    game/graphics/iosshadingprototypepipeline.h \
    game/graphics/iosshadingprototypepipeline.cpp; then
  echo 'P2.5b1 host-neutral contract leaks Objective-C or Metal'
  exit 1
fi
if grep -Eq \
    'MTLCreateSystemDefaultDevice|newCommandQueue|MTLCommandQueue|MTLCommandBuffer|newCommandBuffer|commandBufferWith|commandBuffer\\]|CommandEncoder|setRenderPipelineState|drawPrimitives|drawIndexedPrimitives|dispatchThreadgroups|dispatchThreads|presentDrawable|commit\\]|enqueue\\]|waitUntilCompleted|newLibraryWithSource|newDefaultLibrary|MTLCompileOptions|newComputePipelineState|MTLComputePipeline|newBufferWith|newTextureWith|newHeap|makeAliasable|MTLBinaryArchive|addRenderPipelineFunctions|serializeToURL|MetalFX' \
    game/graphics/iosshadingprototypepipeline.mm; then
  echo 'P2.5b1 factory owns runtime work, resources, or source compilation'
  exit 1
fi
grep -Fq 'Tempest::MetalApi::borrowDevice(owner)' \
  game/graphics/iosshadingprototypepipeline.mm
grep -Fq 'supportsFamily:MTLGPUFamilyApple4' \
  game/graphics/iosshadingprototypepipeline.mm
grep -Fq 'newLibraryWithURL:libraryUrl error:&libraryError' \
  game/graphics/iosshadingprototypepipeline.mm
grep -Fq 'newFunctionWithName:(NSString*)materialName.get()' \
  game/graphics/iosshadingprototypepipeline.mm
test "$(grep -Fc 'setConstantValue:&alphaTest' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 2
test "$(grep -Fc 'alphaTest = false;' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 1
test "$(grep -Fc 'alphaTest = true;' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 1
test "$(grep -Fc 'constantValues:' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 2
grep -Fq 'MTLPipelineOptionBindingInfo' \
  game/graphics/iosshadingprototypepipeline.mm
test "$(grep -Fc \
    'newRenderPipelineStateWithDescriptor:descriptor' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 1
test "$(grep -Fc \
    'newRenderPipelineStateWithTileDescriptor:descriptor' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 1
test "$(grep -Fc 'descriptor.binaryArchives = nil;' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 2
if rg -n 'descriptor\.binaryArchives[[:space:]]+=[[:space:]]+' \
    game/graphics/iosshadingprototypepipeline.mm |
    grep -Fv 'descriptor.binaryArchives = nil;'; then
  echo 'P2.5b1 factory attaches a mutable pipeline archive'
  exit 1
fi

if grep -Eq \
    '#import|<Metal/|id<MTL|MTL[A-Z]|__OBJC__' \
    game/graphics/iosshadingprototypetileprobe.h \
    game/graphics/iosshadingprototypetileprobe.cpp; then
  echo 'P2.5b2a0 host report leaks Objective-C or Metal'
  exit 1
fi
P25B2_RUNTIME_DENY='Forward|riosForward|newLibraryWithSource|newDefaultLibrary|MTLCompileOptions|newCommandQueue|commandBufferWith|newCommandBuffer|commandBuffer[[:space:]]*(\(|\])|newBufferWith|newTextureWith|newHeap|newFence|MTLFence|makeAliasable|MTLCapture|newComputePipelineState|computeCommandEncoder|blitCommandEncoder|nextDrawable|presentDrawable|readPixels|(^|[^[:alnum:]_])submit[[:space:]]*\(|commit\]|enqueue\]|waitIdle|[.]wait[[:space:]]*\(|waitUntilCompleted|addCompletedHandler|MTLBinaryArchive|addRenderPipelineFunctions|serializeToURL|MetalFX'
for fixture in \
    'device.submit(command,fence)' \
    '[queue commandBuffer]' \
    'queue.commandBuffer()' \
    '[command commit]' \
    '[command enqueue]' \
    'device.waitIdle()' \
    'fence.wait()' \
    '[command addCompletedHandler:handler]'; do
  printf '%s\n' "$fixture" |
    grep -Eq "$P25B2_RUNTIME_DENY"
done
if grep -Eq "$P25B2_RUNTIME_DENY" \
    game/graphics/iosshadingprototypetileprobe.h \
    game/graphics/iosshadingprototypetileprobe.cpp \
    game/graphics/iosshadingprototypetileprobe.mm \
    game/graphics/iosshadingprototypepipelinenative.h; then
  echo 'P2.5b2a0 owns forbidden runtime work or references Forward'
  exit 1
fi
test "$(grep -Fc 'Tempest::MetalApi::withActiveCommandBuffer(' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1
test "$(grep -Fc 'renderCommandEncoderWithDescriptor:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1
test "$(grep -Fc 'setVertexBytes:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1
test "$(grep -Fc 'setRenderPipelineState:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 3
test "$(grep -Fc 'drawPrimitives:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 2
test "$(grep -Fc 'dispatchThreadsPerTile:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1
grep -Fq 'MTLClearColorMake(0.0,0.0,0.0,0.0)' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'descriptor.get().imageblockSampleLength =' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'descriptor.get().threadgroupMemoryLength =' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'descriptor.get().tileWidth =' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'descriptor.get().tileHeight =' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'report.materialTextures = 0u;' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'static_assert(sizeof(Vertices)==VertexBytes);' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'MaximumEndAttempts = 2u;' \
  game/graphics/iosshadingprototypetileprobe.mm
test "$(grep -Fc '(void)attemptEnd();' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1
test "$(grep -Fc 'std::terminate();' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1
grep -Fq 'static_assert(Mutators.size()==52u);' \
  ios/tests/iosshadingprototypetileprobe.cpp
grep -Fq 'static_assert(sizeof(Report)==172u);' \
  ios/tests/iosshadingprototypetileprobe.cpp
grep -Fq 'static_assert(offsetof(Report,operations)==168u);' \
  ios/tests/iosshadingprototypetileprobe.cpp

if grep -Eq \
    'newCommandQueue|commandBufferWith|commandBuffer\]|presentDrawable|endEncoding|commit\]|enqueue\]|waitUntilCompleted|MTLCommandQueue|MTLCommandBuffer|gapi/metal/mt' \
    game/graphics/iosgpuscene.mm \
    game/graphics/iosgpubink.mm; then
  echo 'A native RendererIOS path bypasses the scoped Tempest Metal encoder bridge'
  exit 1
fi
if grep -Eq \
    'newLibraryWithSource|compileSource|MTLCompileOptions' \
    game/graphics/iosgpuscene.mm \
    game/graphics/iosgpubink.mm; then
  echo 'A native RendererIOS path performs forbidden runtime shader compilation'
  exit 1
fi
if grep -Eq \
    'WorldView|DrawCommands|DrawBuckets|Shaders|InventoryMenu|VideoWidget' \
    game/graphics/iosgpusceneplan.h \
    game/graphics/iosgpuscene.h; then
  echo 'IOSGPUScene public contract leaks legacy renderer internals'
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
    "case=tile-prototype-v1 contract=1 metallib-abi=7 "
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
TILE_BUILD="$RUNNER_TEMP/renderer-ios-tile-pbx-tile"
cmake --build "$TILE_BUILD" --config Release -- \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
TILE_APP="$TILE_BUILD/opengothic/Release/Gothic2Notr.app"
TILE_BINARY="$TILE_APP/Gothic2Notr"
test -f "$TILE_BINARY"
test "$(/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
  "$TILE_APP/Info.plist")" = true
TILE_STRINGS="$RUNNER_TEMP/Gothic2Notr-shading-prototype-tile.strings"
strings "$TILE_BINARY" >"$TILE_STRINGS"
for marker in \
    'RendererIOS shading prototype tile self-test: ARMED case=tile-prototype-v1 contract=1 metallib-abi=7 minimum-apple=4 output=4x4 rgba8-private=1' \
    'RendererIOS shading prototype tile self-test: FACTORY READY case=tile-prototype-v1 pipelines=3 forward=0 runtime-delta=0 builtin-delta=0 archive-delta=0' \
    'RendererIOS shading prototype tile self-test: ENCODED case=tile-prototype-v1 pass=1 encoder=1 draws=2 opaque=1 alpha=1 tdispatch=1 vb=168 output=1 mat=0 ib=4 clear-a=0 tgmem=0 size=16 dispatch=16x16x1 order=opaque,alpha,tile drawable=0 present=0' \
    'RendererIOS shading prototype tile self-test: SUBMITTED case=tile-prototype-v1 command-buffers=1 submits=1' \
    'RendererIOS shading prototype tile self-test: PASS case=tile-prototype-v1 terminal=completed created=1 live=0 released=1 wait-idle=0 runtime-delta=0 builtin-delta=0 archive-delta=0' \
    'RendererIOS shading prototype tile self-test: UNSUPPORTED case=tile-prototype-v1 reason=apple4-required side-effects=0' \
    'RendererIOS shading prototype tile capture: ACQUIRED'; do
  test "$(grep -Fxc "$marker" "$TILE_STRINGS" || true)" -eq 1
done

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
cmake --build "$FORWARD_BUILD" --config Release -- \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
FORWARD_APP="$FORWARD_BUILD/opengothic/Release/Gothic2Notr.app"
FORWARD_BINARY="$FORWARD_APP/Gothic2Notr"
test -f "$FORWARD_BINARY"
test "$(/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
  "$FORWARD_APP/Info.plist")" = true
FORWARD_STRINGS="$RUNNER_TEMP/Gothic2Notr-shading-prototype-forward.strings"
strings "$FORWARD_BINARY" >"$FORWARD_STRINGS"
for marker in \
    'RendererIOS shading prototype forward self-test: ARMED case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward self-test: FACTORY READY case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward self-test: ENCODED case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward self-test: SUBMITTED case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward self-test: TERMINAL case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward self-test: READBACK case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward self-test: PASS case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward self-test: UNSUPPORTED case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward self-test: FAIL case=forward-prototype-v1 nonce=' \
    'RendererIOS shading prototype forward capture: ACQUIRED case=forward-prototype-v1 nonce=' \
    '-renderer-ios-forward-self-test-nonce='; do
  test "$(grep -Fxc -- "$marker" "$FORWARD_STRINGS" || true)" -eq 1
done

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

printf '\n### CI contract: Verify P2.1c3b3 causal device harness\n'
set -euo pipefail

CAUSAL_HARNESS=ios/device-test/run-smoke-test.sh
test -x "$CAUSAL_HARNESS"
/bin/bash -n "$CAUSAL_HARNESS"
/bin/bash "$CAUSAL_HARNESS" --self-test \
  --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 18446744073709551615
/bin/bash ios/device-test/run-pipeline-archive-test.sh --self-test

expect_causal_harness_parser_failure() {
  local name="$1"
  shift
  if /bin/bash "$CAUSAL_HARNESS" "$@" >/dev/null 2>&1; then
    echo "causal device harness parser mutation survived: $name"
    exit 1
  fi
}
expect_causal_harness_parser_failure missing-sequence \
  --self-test --native-alpha-test-causal-mode causal-a
expect_causal_harness_parser_failure missing-mode \
  --self-test --native-alpha-test-causal-sequence 7
expect_causal_harness_parser_failure wrong-mode \
  --self-test --native-alpha-test-causal-mode production \
  --native-alpha-test-causal-sequence 7
expect_causal_harness_parser_failure duplicate-mode \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 7
expect_causal_harness_parser_failure duplicate-sequence \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 7 \
  --native-alpha-test-causal-sequence 8
expect_causal_harness_parser_failure zero-sequence \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 0
expect_causal_harness_parser_failure leading-zero-sequence \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 01
expect_causal_harness_parser_failure overflowing-sequence \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 18446744073709551616
expect_causal_harness_parser_failure extra-causal-argument \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 7 \
  --renderer-ios-native-alpha-test-causal-extra=1
expect_causal_harness_parser_failure competing-self-test \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 7 --require-bink-self-test
expect_causal_harness_parser_failure competing-fault \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 7 \
  --expected-fault post-submit-suboptimal
expect_causal_harness_parser_failure fault-history-reset \
  --self-test --native-alpha-test-causal-mode causal-a \
  --native-alpha-test-causal-sequence 7 \
  --expected-fault post-submit-suboptimal --expected-fault none

python3 - "$CAUSAL_HARNESS" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
launch_block = (
    '  LAUNCH_ARGS+=(\n'
    '    "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}'
    '${NATIVE_ALPHA_TEST_CAUSAL_MODE}"\n'
    '    "${NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT}'
    '${NATIVE_ALPHA_TEST_CAUSAL_NONCE}"\n'
    '    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}'
    '${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"\n'
    "  )"
)
requested_guard = (
    '[[ "$(grep -Fxc -- "$NATIVE_ALPHA_TEST_CAUSAL_MODE" \\\n'
    '    "$strings_file" || true)" -eq 1 ]] || return 1'
)
failure_install = (
    '"$PASS_EVIDENCE_DIR/causal-contract.json" FAIL "$cleanup_result" ||'
)
expected_schema = {
    "schemaVersion", "result", "parentSha", "mode", "nonce",
    "targetSequence", "launchBoundary", "armedLine", "encodedLine",
    "draws", "alpha", "binarySha256", "metallibSha256", "cleanupResult",
}

def validate(candidate):
    required = (
        "is_canonical_positive_uint64()",
        "generate_native_alpha_test_causal_nonce()",
        "validate_native_alpha_test_causal_binary_profile()",
        "validate_native_alpha_test_causal_log()",
        "write_native_alpha_test_causal_contract()",
        "install_native_alpha_test_causal_contract()",
        "commit_native_alpha_test_causal_pass_evidence()",
        "retract_native_alpha_test_causal_pass_evidence()",
        "invalidate_native_alpha_test_causal_result()",
        "finalize_native_alpha_test_causal_cleanup()",
        "run_native_alpha_test_causal_host_self_test()",
        "pull_runtime_logs native-alpha-test-causal-prelaunch",
        "stderr-native-alpha-test-causal-prelaunch.log",
        "causal-log-replaced-markers-before-shell.txt",
        "write_native_alpha_test_causal_contract PASS passed",
        'write_native_alpha_test_causal_contract FAIL "$cleanup_result"',
        "causal-contract.json",
        "len(causal) != 2",
        "len(shell) != 1 or shell[0][1] != expected_build",
        'len(fault) != 1 or fault[0][1] != "none"',
        "shell[0][0] < encoded[0][0]",
        "fault[0][0] < encoded[0][0]",
        "armed[0][0] < encoded[0][0]",
        '"missing-shell": current.replace(shell_line, "")',
        '"duplicate-shell": current.replace(shell_line, shell_line + shell_line)',
        '"wrong-shell": current.replace(build, "f" * 40)',
        '"missing-fault": current.replace(fault_line, "")',
        '"duplicate-fault": current.replace(fault_line, fault_line + fault_line)',
        '"wrong-fault": current.replace("fault mode=none", "fault mode=unexpected")',
        '"shell-after-encoded": armed_line + fault_line + encoded_line + shell_line',
        '"fault-after-encoded": armed_line + shell_line + encoded_line + fault_line',
        '"encoded-before-armed": identity_lines + encoded_line + armed_line',
        '"encoded-before-identity": armed_line + encoded_line + identity_lines',
        "alpha <= 0 or draws < alpha",
        "fatal.search(segment) or fatal.search(stderr_segment)",
        'if injected_fault == "copy":',
        'if injected_fault == "readback":',
        "type(payload[\"targetSequence\"]) is not int",
        "((EXPECTED_FAULT_SEEN == 0))",
        'fail "native alpha-test causal mode requires an exact-SHA build"',
        "prepare_causal_finalizer_fixture publish-fail",
        "causal evidence-path publication failure returned success",
        "causal ordinary FAIL left a provisional PASS result",
        'EVIDENCE_PATH_FILE="$directory/causal-finalizer-evidence-path.txt"',
        'EVIDENCE_PATH_FILE="$caller_evidence_path_file"',
        "smoke final evidence path publication self-test failed",
    )
    for literal in required:
        if literal not in candidate:
            raise ValueError("causal harness contract drifted: " + literal)
    for bash4_only in ("declare -A", "mapfile ", "readarray ", "local -n "):
        if bash4_only in candidate:
            raise ValueError("causal harness is not Bash 3.2: " + bash4_only)
    if candidate.count(requested_guard) != 1:
        raise ValueError("causal requested binary token is not exact-one")

    launch_start = candidate.index("LAUNCH_ARGS=(-nomenu)")
    launch_end = candidate.index(
        'if ((NEW_GAME != 0)); then\n  echo "== unattended launch:',
        launch_start,
    )
    launch = candidate[launch_start:launch_end]
    if launch.count(launch_block) != 1:
        raise ValueError("causal launch is not one exact contiguous argv triple")

    contract_source = candidate[candidate.index(
        "write_native_alpha_test_causal_contract()"
    ):]
    match = re.search(
        r'keys = \{\n(?P<body>.*?)\n\}', contract_source, re.DOTALL
    )
    if match is None:
        raise ValueError("causal contract schema is missing")
    actual = set(re.findall(
        r'"([A-Za-z][A-Za-z0-9]+)"', match.group("body")
    ))
    if actual != expected_schema:
        raise ValueError("causal contract exact schema drifted")

    finalizer = candidate[
        candidate.index("finalize_native_alpha_test_causal_cleanup() {"):
        candidate.index("validate_native_alpha_test_causal_log() {")
    ]
    for literal in (
        "if ((original_status != 0 || CAUSAL_FINALIZER_CLEANUP_STATUS != 0))",
        "commit_native_alpha_test_causal_pass_evidence",
        failure_install,
        "CAUSAL_FINALIZER_PUBLISHED=1",
    ):
        if literal not in finalizer:
            raise ValueError("causal finalizer drifted: " + literal)
    if finalizer.count("install_native_alpha_test_causal_contract") != 2:
        raise ValueError("causal finalizer lost PASS/FAIL contract installs")
    if finalizer.count(
        'if publish_evidence_path "$PASS_EVIDENCE_DIR"; then'
    ) != 1:
        raise ValueError("causal finalizer lost checked evidence-path publication")
    if finalizer.count(
        "retract_native_alpha_test_causal_pass_evidence \\"
    ) != 1:
        raise ValueError("causal finalizer lost atomic PASS retraction")
    if finalizer.count(
        "invalidate_native_alpha_test_causal_result \\"
    ) != 1:
        raise ValueError("causal finalizer lost FAIL result invalidation")
    cleanup = candidate[
        candidate.index("\ncleanup() {"):
        candidate.index("trap cleanup EXIT")
    ]
    if 'publish_evidence_path "$PASS_EVIDENCE_DIR"' in cleanup:
        raise ValueError("causal cleanup bypasses fail-closed publication")
    if (
        'OUT="$OUT_ROOT/.pending-pass-$timestamp-$$"' not in candidate
        or 'PASS_EVIDENCE_FINAL_DIR="$OUT"' not in candidate
    ):
        raise ValueError("causal PASS evidence is not atomically published")
    host_self_test = candidate[
        candidate.index("run_host_contract_self_test() {"):
        candidate.index("\nwhile [[ $# -gt 0 ]]; do")
    ]
    causal_fixture_call = "run_native_alpha_test_causal_host_self_test \\"
    final_publication = 'publish_evidence_path "$actual"'
    if (
        host_self_test.count(causal_fixture_call) != 1
        or host_self_test.count(final_publication) != 1
        or host_self_test.index(causal_fixture_call)
        >= host_self_test.index(final_publication)
    ):
        raise ValueError("causal fixture can overwrite final host evidence path")

def replace_once(candidate, before, after):
    if candidate.count(before) != 1:
        raise SystemExit("causal mutation anchor drifted: " + before)
    return candidate.replace(before, after, 1)

validate(source)
mutations = (
    replace_once(source, "len(causal) != 2", "len(causal) < 2"),
    replace_once(
        source,
        "len(shell) != 1 or shell[0][1] != expected_build",
        "len(shell) < 1 or shell[0][1] != expected_build",
    ),
    replace_once(
        source,
        'len(fault) != 1 or fault[0][1] != "none"',
        'len(fault) < 1 or fault[0][1] != "none"',
    ),
    replace_once(
        source,
        "shell[0][0] < encoded[0][0]",
        "shell[0][0] > encoded[0][0]",
    ),
    replace_once(
        source,
        "fault[0][0] < encoded[0][0]",
        "fault[0][0] > encoded[0][0]",
    ),
    replace_once(
        source,
        "armed[0][0] < encoded[0][0]",
        "armed[0][0] > encoded[0][0]",
    ),
    replace_once(
        source,
        "alpha <= 0 or draws < alpha",
        "alpha < 0 or draws < alpha",
    ),
    replace_once(source, requested_guard, requested_guard.replace("-eq", "-le")),
    replace_once(
        source,
        launch_block,
        launch_block.replace(
            "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}"
            "${NATIVE_ALPHA_TEST_CAUSAL_MODE}",
            "${NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT}"
            "${NATIVE_ALPHA_TEST_CAUSAL_NONCE}",
            1,
        ),
    ),
    replace_once(
        source,
        '    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}'
        '${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"\n  )',
        '    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}'
        '${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"\n'
        '    "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}'
        '${NATIVE_ALPHA_TEST_CAUSAL_MODE}"\n  )',
    ),
    replace_once(
        source,
        "if ((original_status != 0 || "
        "CAUSAL_FINALIZER_CLEANUP_STATUS != 0)); then",
        "if ((original_status != 0 && "
        "CAUSAL_FINALIZER_CLEANUP_STATUS != 0)); then",
    ),
    replace_once(source, failure_install, failure_install.replace("FAIL", "PASS")),
    replace_once(
        source, 'if injected_fault == "copy":',
        'if injected_fault == "disabled-copy":',
    ),
    replace_once(
        source, 'if injected_fault == "readback":',
        'if injected_fault == "disabled-readback":',
    ),
    replace_once(
        source,
        "fatal.search(segment) or fatal.search(stderr_segment)",
        "fatal.search(segment)",
    ),
    replace_once(
        source,
        "((EXPECTED_FAULT_SEEN == 0))",
        "((EXPECTED_FAULT_SEEN >= 0))",
    ),
    replace_once(
        source,
        "commit_native_alpha_test_causal_pass_evidence \\",
        "true # missing atomic causal PASS rename",
    ),
    replace_once(
        source,
        'if publish_evidence_path "$PASS_EVIDENCE_DIR"; then',
        "if true; then # ignored causal evidence-path publication",
    ),
    replace_once(
        source,
        "retract_native_alpha_test_causal_pass_evidence \\",
        "true # missing atomic causal PASS retraction",
    ),
    replace_once(
        source,
        "invalidate_native_alpha_test_causal_result \\",
        "true # missing causal FAIL result invalidation",
    ),
    replace_once(
        source,
        'EVIDENCE_PATH_FILE="$directory/causal-finalizer-evidence-path.txt"',
        'EVIDENCE_PATH_FILE="$caller_evidence_path_file"',
    ),
    replace_once(
        source,
        'publish_evidence_path "$actual"',
        "true # missing final host evidence-path publication",
    ),
)
killed = 0
for mutation in mutations:
    try:
        validate(mutation)
    except ValueError:
        killed += 1
    else:
        raise SystemExit("causal harness source mutation survived")
if killed != 22:
    raise SystemExit("causal harness mutation count drifted")
print(f"causal device harness source oracle: mutations-killed={killed}")
PY

printf '\n### CI contract: Verify physical-device smoke cleanup contract\n'
set -euo pipefail

test -x ios/device-test/run-smoke-test.sh
test -x ios/device-test/validate-fault-log.py
test -x ios/device-test/validate-preview-fence-fault-log.py
test -x ios/device-test/validate-frame-fence-fault-log.py
bash -n ios/device-test/run-smoke-test.sh
ios/device-test/run-smoke-test.sh --self-test
OPENGOTHIC_IOS_EXPECTED_FAULT=post-submit-suboptimal \
  ios/device-test/run-smoke-test.sh --self-test
OPENGOTHIC_IOS_EXPECTED_FAULT=preview-fence-error-after-terminal \
  ios/device-test/run-smoke-test.sh --save-slot 1 --self-test
OPENGOTHIC_IOS_EXPECTED_FAULT=frame-fence-error-after-terminal \
  ios/device-test/run-smoke-test.sh --self-test
python3 ios/device-test/validate-fault-log.py --self-test
python3 ios/device-test/validate-preview-fence-fault-log.py --self-test
python3 ios/device-test/validate-frame-fence-fault-log.py --self-test
grep -Fq 'trap cleanup EXIT' ios/device-test/run-smoke-test.sh
grep -Fq -- '--expected-fault)' ios/device-test/run-smoke-test.sh
grep -Fq 'EXPECTED_FAULT="none"' ios/device-test/run-smoke-test.sh
grep -Fq 'python3 "$ROOT/ios/device-test/validate-fault-log.py"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'python3 "$ROOT/ios/device-test/validate-preview-fence-fault-log.py"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'python3 "$ROOT/ios/device-test/validate-frame-fence-fault-log.py"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'elif [[ "$EXPECTED_FAULT" == frame-fence-error-after-terminal ]]; then' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'ID4 summary key mismatch' ios/device-test/run-smoke-test.sh
grep -Fq '"id4_post_fault_present_count"' \
  ios/device-test/run-smoke-test.sh
grep -Fq '"id4_resume_settled_count"' \
  ios/device-test/run-smoke-test.sh
grep -Fq '"id4_resumed_one_count"' \
  ios/device-test/run-smoke-test.sh
grep -Fq '"id4_post_fault_present_count": post_fault_present_count' \
  ios/device-test/validate-frame-fence-fault-log.py
grep -Fq '"id4_resume_settled_count": resume_settled_count' \
  ios/device-test/validate-frame-fence-fault-log.py
grep -Fq '"id4_resumed_one_count": resumed_one_count' \
  ios/device-test/validate-frame-fence-fault-log.py
grep -Fq 'PASS — ID4 terminal frame-fence fatal gate proven; app stopped' \
  ios/device-test/run-smoke-test.sh
grep -Fq '"preview-fence-error-after-terminal",' \
  ios/device-test/run-smoke-test.sh
grep -Fq '((DURATION <= 45))' ios/device-test/run-smoke-test.sh
grep -Fq 'PROCESS_SURVIVED_FAULT_WINDOW=1' \
  ios/device-test/run-smoke-test.sh
grep -Fq '((PROCESS_SURVIVED_FAULT_WINDOW == 1))' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'ID3 summary key mismatch' ios/device-test/run-smoke-test.sh
test "$(grep -Fxc \
  '  ios/device-test/run-smoke-test.sh --save-slot 1 --self-test' \
  scripts/ci_contracts.command)" -eq 1
grep -Fq 'preview-fence-save-v1' game/commandline.cpp
grep -Fq 'OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 3' game/commandline.cpp
grep -Fq 'RendererIOS preview fence save script: REQUESTED' game/mainwindow.cpp
grep -Fq '[save] RendererIOS preview queued: source=gpu-diagnostic' \
  game/mainwindow.cpp
grep -Fq 'ID3_COMPLETION_OBSERVED=1' ios/device-test/run-smoke-test.sh
grep -Fq 'ID3_POST_COMPLETION_STABLE_SECONDS=10' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'id3_protected_saves_1_4_match=' ios/device-test/run-smoke-test.sh
grep -Fq 'id3_destination_restored=' ios/device-test/run-smoke-test.sh
grep -Fq 'id3_recovery_path=' ios/device-test/run-smoke-test.sh
grep -Fq 'id3_recovery_preserved=' ios/device-test/run-smoke-test.sh
grep -Fq 'build/private-device-recovery/id3/' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_id3_save_postflight_raw()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'release_id3_recovery_if_safe()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'discover_id3_fault_window_pid()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'id3_pid_discovery_attempts=' ios/device-test/run-smoke-test.sh
grep -Fq 'save preview allocation failed' \
  ios/device-test/validate-preview-fence-fault-log.py
grep -Fq 'allocation returned an empty image' \
  ios/device-test/validate-preview-fence-fault-log.py
grep -Fq 'render-counter-regression' \
  ios/device-test/validate-preview-fence-fault-log.py
grep -Fq 'queued-after-second-post-request-present' \
  ios/device-test/validate-preview-fence-fault-log.py
grep -Fq 'fatal-suffix-stderr' \
  ios/device-test/validate-preview-fence-fault-log.py
! grep -Fq 'complete_us >= accepted_us' \
  ios/device-test/validate-preview-fence-fault-log.py
! grep -Fq 'completed < accepted' ios/device-test/run-smoke-test.sh
grep -Fq 'line.startswith("RendererIOS shell: version=")' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'line.startswith("RendererIOS configured fault mode=")' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'CONFIGURED_FAULT_RE = re.compile(' \
  ios/device-test/validate-fault-log.py
grep -Fq '"missing-configured":' \
  ios/device-test/validate-fault-log.py
grep -Fq '"duplicate-configured":' \
  ios/device-test/validate-fault-log.py
grep -Fq '"wrong-configured":' \
  ios/device-test/validate-fault-log.py
grep -Fq 'wrapped_shell = base.replace(' \
  ios/device-test/validate-fault-log.py
grep -Fq -- '--summary "$WORK/fault-log-summary.txt"' \
  ios/device-test/run-smoke-test.sh
grep -Fq '[[ "$POST_CRASH_SHA" != "$PRE_CRASH_SHA" ]]' \
  ios/device-test/run-smoke-test.sh
grep -Fq '"id5_reset_present_baseline"' \
  ios/device-test/run-smoke-test.sh
grep -Fq '"id5_post_reset_max_present"' \
  ios/device-test/run-smoke-test.sh
grep -Fq '"id5_post_reset_present_delta"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'cat "$WORK/fault-log-summary.txt"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'swapchain reset failed' \
  ios/device-test/validate-fault-log.py
grep -Fq 'smoke_evidence_path()' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'capture_crash_state cleanup "$WORK/crash-after-cleanup.log"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'could not establish pre-run crash.log state' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'could not establish post-run crash.log state' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'could not establish final crash.log state' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'crash-listing-before.json crash-listing-after.json' \
  ios/device-test/run-smoke-test.sh
test "$(grep -Fc 'echo "expected_build=$EXPECTED_BUILD"' \
  ios/device-test/run-smoke-test.sh)" -eq 3
test "$(grep -Fc 'echo "expected_fault=$EXPECTED_FAULT"' \
  ios/device-test/run-smoke-test.sh)" -eq 3
test "$(grep -Fc 'echo "fault_log_validation=$FAULT_LOG_VALIDATION"' \
  ios/device-test/run-smoke-test.sh)" -eq 2
test "$(grep -Fc 'echo "process_survived_fault_window=$PROCESS_SURVIVED_FAULT_WINDOW"' \
  ios/device-test/run-smoke-test.sh)" -eq 3
test "$(grep -Fc 'echo "pre_crash_sha256=$PRE_CRASH_SHA"' \
  ios/device-test/run-smoke-test.sh)" -eq 3
test "$(grep -Fc 'echo "post_crash_sha256=$POST_CRASH_SHA"' \
  ios/device-test/run-smoke-test.sh)" -eq 3
grep -Fq 'stop_running_app 1 || fail "pre-launch application cleanup failed"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'stop_running_app 1 || fail "application cleanup failed"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'park_settings_foreground || fail "could not park Settings at PASS boundary"' \
  ios/device-test/run-smoke-test.sh
grep -Fq -- '--terminate-existing --activate com.apple.Preferences' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'stop_running_app 1 || fail "final application cleanup failed"' \
  ios/device-test/run-smoke-test.sh
grep -Fq -- '--kill --quiet' ios/device-test/run-smoke-test.sh
grep -Fq 'original_exit_status=' ios/device-test/run-smoke-test.sh
test "$(grep -Fc 'echo "device_process_stopped=$DEVICE_PROCESS_STOPPED"' \
  ios/device-test/run-smoke-test.sh)" -eq 1
grep -Fxq 'readonly DURABLE_ZERO_MAX_CYCLES=3' \
  ios/device-test/run-smoke-test.sh
grep -Fxq 'readonly DURABLE_ZERO_SCANS_PER_CYCLE=10' \
  ios/device-test/run-smoke-test.sh
grep -Fxq 'readonly DURABLE_ZERO_INTERVAL_SECONDS=10' \
  ios/device-test/run-smoke-test.sh
grep -Fxq 'readonly DURABLE_ZERO_REQUIRED_STABLE_SECONDS=90' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'ensure_durable_zero || fail "durable final application cleanup failed"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'processes-durable-zero-cycle-$cycle-scan-$scan.json' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'run_battery_safety_fallback || true' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'durable_zero_stable_seconds=$DURABLE_ZERO_STABLE_SECONDS' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'durable_zero_required_stable_seconds=$DURABLE_ZERO_REQUIRED_STABLE_SECONDS' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'durable_zero_final_zero=$DURABLE_ZERO_FINAL_ZERO' \
  ios/device-test/run-smoke-test.sh
test "$(grep -Fc \
  'DURABLE_ZERO_STABLE_SECONDS >= DURABLE_ZERO_REQUIRED_STABLE_SECONDS' \
  ios/device-test/run-smoke-test.sh)" -eq 2
grep -Fq 'battery_fallback_final_zero=$BATTERY_FALLBACK_FINAL_ZERO' \
  ios/device-test/run-smoke-test.sh
test "$(grep -Fc 'echo "scenario=$SCENARIO"' \
  ios/device-test/run-smoke-test.sh)" -eq 2
test "$(grep -Fc 'echo "save_slot=$SCENARIO_SAVE_SLOT"' \
  ios/device-test/run-smoke-test.sh)" -eq 2
grep -Fq 'select_device_record()' ios/device-test/run-smoke-test.sh
grep -Fq 'attempt=%d result=retry' ios/device-test/run-smoke-test.sh
grep -Fq '((attempt < 5)) && sleep 1' ios/device-test/run-smoke-test.sh
grep -Fq 'OPENGOTHIC_IOS_DEVICE_SELECTION_TEST_FAIL_FIRST' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'device_selection_attempts=' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'device_selection_method=' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'copy_private_evidence_path "$WORK/device-selection.log"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'd.get("interface") == "usb"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'd.get("hardwareProperties", {}).get("udid") in usb_udids' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'OpenGothic container has missing/invalid resources:' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'phase=trap-cleanup game_processes=0' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'game Data/_work/system or Gothic.dat/Gothic.ini preflight failed before install' \
  ios/device-test/run-smoke-test.sh

python3 - <<'PY'
from pathlib import Path

source = Path("ios/device-test/run-smoke-test.sh").read_text()
context = Path("game/graphics/iosmetalcontext.cpp").read_text()
resize = context.split("void IOSMetalContext::resize() {", 1)[1].split(
    "\nbool IOSMetalContext::suspend() noexcept {", 1
)[0]
resize_contract = (
    "impl->swapchain.reset();",
    "impl->resetTargets();",
    "#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)",
    'impl->logLifecycleCounts("resize-settled",true);',
    "#endif",
    "catch(const SwapchainSuboptimal&)",
)
resize_positions = [resize.index(literal) for literal in resize_contract]
if resize_positions != sorted(resize_positions):
    raise SystemExit("resize-settled marker is not guarded after full reset success")
if resize.count('impl->logLifecycleCounts("resize-settled",true);') != 1:
    raise SystemExit("resize-settled marker is not unique")
fault_evidence_literal = (
    '"RendererIOS configured fault mode=" '
    'OPENGOTHIC_RENDERER_IOS_FAULT_MODE_NAME'
)
if context.count(fault_evidence_literal) != 1:
    raise SystemExit("compiled fault-mode evidence marker is not unique")
if context.count('Log::i(RendererIOSConfiguredFaultModeEvidence);') != 1:
    raise SystemExit("compiled fault-mode evidence marker is not emitted")
expected_build_preflight = source.index(
    'grep -Fxq "$EXPECTED_BUILD" "$WORK/app-strings.txt"')
expected_build_binding = source.index(
    '[[ "$EXPECTED_BUILD" == "$EXPECTED_SHA" ||')
expected_fault_preflight = source.index(
    'grep -Fxq "RendererIOS configured fault mode=$EXPECTED_FAULT"')
selection = source.index('DEVICE_RECORD="$(select_device_record)"')
bundle = source.index('BUNDLE_ID="${OPENGOTHIC_IOS_BUNDLE_ID:-}"')
selection_evidence = source.index(
    'copy_private_evidence_path "$WORK/device-selection.log"')
game_data_preflight = source.index(
    'game Data/_work/system or Gothic.dat/Gothic.ini '
    'preflight failed before install')
install = source.index('echo "== installing $BUNDLE_ID =="')
stopped = source.index('stop_running_app 1 || fail "application cleanup failed"')
runtime_shell_oracle = source.index('shell_count = sum(')
runtime_fault_oracle = source.index('configured_count = sum(')
runtime_diagnostics = source.index(
    "rg -F 'RendererIOS diagnostics: ON'"
)
preview_fence_parser = source.index(
    'python3 "$ROOT/ios/device-test/validate-preview-fence-fault-log.py"')
preview_fence_summary = source.index('ID3 summary key mismatch')
frame_fence_parser = source.index(
    'python3 "$ROOT/ios/device-test/validate-frame-fence-fault-log.py"')
frame_fence_summary = source.index('ID4 summary key mismatch')
fault_parser = source.index(
    'python3 "$ROOT/ios/device-test/validate-fault-log.py"')
fault_summary = source.index('ID5 summary key mismatch')
crash_sentinel = source.index(
    '[[ "$POST_CRASH_SHA" != "$PRE_CRASH_SHA" ]]',
    fault_summary,
)
durable = source.index(
    'ensure_durable_zero || fail "durable final application cleanup failed"')
final_crash_sentinel = source.index(
    'capture_crash_state final "$WORK/crash-final.log"')
pass_fault_namespace = source.index(
    'OUT="$(smoke_evidence_path pass')
evidence_published = source.index('publish_evidence_path "$OUT"')
result = source.index('echo "result=PASS"')
if not expected_build_binding < expected_build_preflight < expected_fault_preflight < selection < bundle:
    raise SystemExit("bounded device selection retry runs after app inspection")
if not bundle < game_data_preflight < install:
    raise SystemExit("game-data preflight does not fail before install")
if not stopped < runtime_shell_oracle < runtime_fault_oracle < runtime_diagnostics < preview_fence_parser < preview_fence_summary < frame_fence_parser < frame_fence_summary < fault_parser < fault_summary < crash_sentinel < durable < final_crash_sentinel < pass_fault_namespace < evidence_published < result:
    raise SystemExit("device PASS is emitted before cleanup proof")
id3_anchor = source.index(
    "# ID3 is fatal only after its nonce-scoped save request has queued a GPU preview.")
id4_anchor = source.index(
    "# ID4 is intentionally fatal after exactly one full frames-in-flight rotation.")
id4_else = source.index(
    '\nelse\npython3 - "$WORK/log.txt" "$WORK/runtime-compilation-summary.txt"',
    id4_anchor,
)
validation_end = source.index(
    '\ncapture_crash_state after "$WORK/crash.log"', id4_else)
id3_branch = source[id3_anchor:id4_anchor]
id4_branch = source[id4_anchor:id4_else]
healthy_and_id5_branch = source[id4_else:validation_end]
if 'validate-preview-fence-fault-log.py' not in id3_branch:
    raise SystemExit("ID3 branch does not call its dedicated validator")
if 'validate-frame-fence-fault-log.py' in id3_branch or 'validate-fault-log.py' in id3_branch:
    raise SystemExit("ID3 branch calls a different fault validator")
if 'ID3 summary key mismatch' not in id3_branch:
    raise SystemExit("ID3 branch does not validate its exact summary")
if 'runtime-compilation-summary.txt' in id3_branch:
    raise SystemExit("ID3 branch enters the healthy 300-present parser")
if 'fatal RendererIOS/runtime signature found' in id3_branch:
    raise SystemExit("ID3 branch enters the healthy fatal denylist")
if 'validate-frame-fence-fault-log.py' not in id4_branch:
    raise SystemExit("ID4 branch does not call its dedicated validator")
if 'validate-preview-fence-fault-log.py' in id4_branch:
    raise SystemExit("ID4 branch calls the ID3 validator")
if 'validate-fault-log.py' in id4_branch:
    raise SystemExit("ID4 branch calls the ID5 validator")
if 'ID4 summary key mismatch' not in id4_branch:
    raise SystemExit("ID4 branch does not validate its exact summary")
if 'runtime-compilation-summary.txt' in id4_branch:
    raise SystemExit("ID4 branch enters the healthy 300-present parser")
if 'fatal RendererIOS/runtime signature found' in id4_branch:
    raise SystemExit("ID4 branch enters the healthy fatal denylist")
if 'validate-fault-log.py' not in healthy_and_id5_branch:
    raise SystemExit("ID5 branch lost its dedicated validator")
if 'validate-frame-fence-fault-log.py' in healthy_and_id5_branch:
    raise SystemExit("healthy/ID5 branch calls the ID4 validator")
if 'validate-preview-fence-fault-log.py' in healthy_and_id5_branch:
    raise SystemExit("healthy/ID5 branch calls the ID3 validator")
if 'fatal RendererIOS/runtime signature found' not in healthy_and_id5_branch:
    raise SystemExit("healthy/ID5 branch lost its fatal denylist")
if not stopped < selection_evidence < result:
    raise SystemExit("device selection evidence is copied before cleanup proof")
legacy_guard = (
    '[[ "$expected_fault" == none && '
    '"$expected_build" == "$expected_sha" ]]; then'
)
evidence_root = source.split(
    'smoke_evidence_root() {', 1)[1].split(
    '\nsmoke_evidence_path() {', 1)[0]
evidence_leaf = source.split(
    'smoke_evidence_path() {', 1)[1].split(
    '\npublish_evidence_path() {', 1)[0]
if evidence_root.count(legacy_guard) != 1:
    raise SystemExit("legacy smoke evidence path is not clean-none-only")
if evidence_root.count('%s/build/device-fault/%s/%s\\n') != 1:
    raise SystemExit("fault evidence does not use exact build/fault namespace")
if evidence_leaf.count("printf '%s/%s-%s-%s\\n'") != 1:
    raise SystemExit("fault evidence does not use the immutable shared leaf")
failure_evidence = source.split(
    'preserve_failure_evidence() {', 1)[1].split(
    '\ncleanup() {', 1)[0]
if failure_evidence.count('smoke_evidence_path failure') != 1:
    raise SystemExit("fault failure evidence bypasses the shared resolver")
raw_capture = source.index(
    'capture_id3_save_postflight_raw ||',
    source.index('echo "== stopping $BUNDLE_ID after smoke window =="'),
)
destination_restore = source.index(
    'restore_id3_destination_if_needed ||', raw_capture)
integrity_verify = source.index(
    'verify_id3_save_integrity ||', destination_restore)
recovery_release = source.index(
    'release_id3_recovery_if_safe ||', integrity_verify)
if not raw_capture < destination_restore < integrity_verify < recovery_release:
    raise SystemExit("ID3 raw capture/restore/integrity/release order is invalid")
raw_function = source.split(
    'capture_id3_save_postflight_raw() {', 1)[1].split(
    '\nverify_id3_save_integrity() {', 1
)[0]
if 'ID3_DESTINATION_RESTORED == 0' not in raw_function:
    raise SystemExit("ID3 raw capture can overwrite its fault artifact after restore")
cleanup_function = source.split("\ncleanup() {", 1)[1].split(
    "\ntrap cleanup EXIT", 1)[0]
cleanup_contract = (
    'capture_id3_save_postflight_raw',
    'restore_id3_destination_if_needed',
    'verify_id3_save_integrity',
    'preserve_id3_recovery_if_present',
    'preserve_failure_evidence',
)
cleanup_positions = [
    cleanup_function.index(literal) for literal in cleanup_contract
]
if cleanup_positions != sorted(cleanup_positions):
    raise SystemExit("ID3 cleanup does not preserve recovery after restore/integrity")
crash_function = source.split('capture_crash_state() {', 1)[1].split(
    '\npreserve_failure_evidence() {', 1
)[0]
crash_contract = (
    'if ! xcrun devicectl device info files --device "$DEVICE"',
    'state="$(crash_listing_state "$listing")"',
    'if [[ "$state" == missing ]]',
    'if ! xcrun devicectl device copy from --device "$DEVICE"',
    'sha="$(shasum -a 256 "$destination"',
)
crash_positions = [crash_function.index(value) for value in crash_contract]
if crash_positions != sorted(crash_positions):
    raise SystemExit("crash sentinel query/copy/hash contract is out of order")
for failure_state in ('query-error', 'provider-error', 'copy-error', 'hash-error'):
    if failure_state not in crash_function:
        raise SystemExit(f"crash sentinel omits {failure_state}")
durable_function = source.split("ensure_durable_zero() {", 1)[1].split(
    "\nwrite_durable_result_fields() {", 1)[0]
durable_contract = (
    'while ((DURABLE_ZERO_CYCLES_USED < DURABLE_ZERO_MAX_CYCLES)); do',
    'stop_running_app 1',
    'park_settings_foreground',
    'for ((scan=1; scan<=DURABLE_ZERO_SCANS_PER_CYCLE; ++scan)); do',
    'processes-durable-zero-cycle-$cycle-scan-$scan.json',
    'processes-durable-zero-cycle-$cycle-final.json',
    'DURABLE_ZERO_FINAL_ZERO=1',
    'run_battery_safety_fallback || true',
)
durable_positions = [
    durable_function.index(literal) for literal in durable_contract
]
if durable_positions != sorted(durable_positions):
    raise SystemExit("physical smoke durable-zero contract is out of order")
if 'DURABLE_ZERO_CYCLES_USED=0' in durable_function:
    raise SystemExit("physical smoke durable-zero resets its global cycle budget")
schedule_contract = (
    'scheduled_elapsed=$(((scan-1)*DURABLE_ZERO_INTERVAL_SECONDS))',
    'wait_seconds=$((scheduled_elapsed-(SECONDS-cycle_started)))',
    '((wait_seconds <= 0)) || sleep "$wait_seconds"',
)
schedule_positions = [
    durable_function.index(literal) for literal in schedule_contract
]
if schedule_positions != sorted(schedule_positions):
    raise SystemExit("physical smoke durable scan schedule is out of order")
if durable_function.rfind('return 1') < durable_function.index(
    'run_battery_safety_fallback || true'):
    raise SystemExit("physical smoke durable-zero exhaustion is not fail-closed")
cleanup_function = source.split("\ncleanup() {", 1)[1].split(
    "\ntrap cleanup EXIT", 1)[0]
cleanup_contract = (
    'local status=$?',
    'if ensure_durable_zero; then',
    'phase=trap-cleanup game_processes=0',
    'cleanup_status=1',
)
cleanup_positions = [
    cleanup_function.index(literal) for literal in cleanup_contract
]
if cleanup_positions != sorted(cleanup_positions):
    raise SystemExit("physical smoke EXIT trap bypasses durable-zero cleanup")
cleanup_crash_refresh = cleanup_function.index(
    'capture_crash_state cleanup "$WORK/crash-after-cleanup.log"'
)
cleanup_crash_compare = cleanup_function.index(
    '[[ "$POST_CRASH_SHA" != "$PRE_CRASH_SHA" ]]'
)
cleanup_result = cleanup_function.index('preserve_failure_evidence')
cleanup_pass = cleanup_function.index(
    'echo "PASS — offline metallib + scenario counters'
)
if not cleanup_crash_refresh < cleanup_crash_compare < cleanup_result < cleanup_pass:
    raise SystemExit("cleanup result uses stale post-crash state")
pass_boundary = source.split(
    '# Validation can take long enough for SpringBoard', 1)[1]
pass_contract = (
    'stop_running_app 1 || fail "final application cleanup failed"',
    'park_settings_foreground || fail "could not park Settings at PASS boundary"',
    'ensure_durable_zero || fail "durable final application cleanup failed"',
    'DURABLE_ZERO_STABLE_SECONDS >= DURABLE_ZERO_REQUIRED_STABLE_SECONDS',
    'DURABLE_ZERO_FINAL_ZERO == 1',
    'echo "result=PASS"',
)
pass_positions = [pass_boundary.index(literal) for literal in pass_contract]
if pass_positions != sorted(pass_positions):
    raise SystemExit("physical smoke PASS is emitted before durable-zero proof")
PY

printf '\n### CI contract: canonical generated target\n'
cmake --preset renderer-ios-on -B build-renderer-ios \
  -DOPENGOTHIC_IOS_VERSION=1.0.0 \
  -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="$GITHUB_SHA"

printf '\n### CI contract: Verify P2.6a capabilities source target membership\n'
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import re

source = "game/graphics/iosdevicecapabilities.cpp"
project = Path(
    "build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj"
).read_text()
escaped_source = re.escape(source)

def validate_project(candidate_project):
    file_references = candidate_project.split(
        "/* Begin PBXFileReference section */", 1
    )[1].split("/* End PBXFileReference section */", 1)[0]
    build_files = candidate_project.split(
        "/* Begin PBXBuildFile section */", 1
    )[1].split("/* End PBXBuildFile section */", 1)[0]
    reference_matches = list(re.finditer(
        rf"^\s*([A-F0-9]{{24}}) "
        rf"/\* [^\n]*{escaped_source} \*/ = "
        rf"\{{isa = PBXFileReference;"
        rf"[^\n]*path = {escaped_source};[^\n]*\}};$",
        file_references,
        re.M,
    ))
    if len(reference_matches) != 1:
        raise ValueError(
            "iosdevicecapabilities.cpp does not have exactly one "
            "PBXFileReference"
        )
    file_reference_id = reference_matches[0].group(1)
    build_file_matches = list(re.finditer(
        rf"^\s*([A-F0-9]{{24}}) "
        rf"/\* [^\n]*{escaped_source} \*/ = "
        rf"\{{isa = PBXBuildFile; "
        rf"fileRef = ([A-F0-9]{{24}}) "
        rf"/\* [^\n]*{escaped_source} \*/; \}};$",
        build_files,
        re.M,
    ))
    if len(build_file_matches) != 1:
        raise ValueError(
            "iosdevicecapabilities.cpp does not have exactly one "
            "PBXBuildFile"
        )
    build_file_id = build_file_matches[0].group(1)
    build_file_reference_id = build_file_matches[0].group(2)
    if build_file_reference_id != file_reference_id:
        raise ValueError(
            "iosdevicecapabilities.cpp PBXBuildFile does not point "
            "to its exact PBXFileReference"
        )
    linked_build_file_ids = re.findall(
        rf"^\s*([A-F0-9]{{24}}) /\* [^\n]* \*/ = "
        rf"\{{isa = PBXBuildFile; "
        rf"fileRef = {file_reference_id} "
        r"/\* [^\n]* \*/; \};$",
        build_files,
        re.M,
    )
    if linked_build_file_ids != [build_file_id]:
        raise ValueError(
            "exact iosdevicecapabilities.cpp PBXFileReference is "
            "not linked by exactly its one PBXBuildFile"
        )

    targets = re.findall(
        r"\b([A-F0-9]{24}) /\* [^*]+ \*/ = \{\n"
        r"\s*isa = PBXNativeTarget;(.*?)\n\s*\};",
        candidate_project,
        re.S,
    )
    gothic = [
        body for _, body in targets
        if re.search(r"^\s*name = Gothic2Notr;$", body, re.M)
    ]
    if len(gothic) != 1:
        raise ValueError(
            "could not identify exact Gothic2Notr target"
        )
    source_phase = re.search(
        r"([A-F0-9]{24}) /\* Sources \*/", gothic[0]
    )
    if source_phase is None:
        raise ValueError("Gothic2Notr target has no Sources phase")
    phase = re.search(
        rf"\b{source_phase.group(1)} /\* Sources \*/ = \{{\n"
        r"\s*isa = PBXSourcesBuildPhase;(.*?)\n\s*\};",
        candidate_project,
        re.S,
    )
    if phase is None:
        raise ValueError(
            "could not read Gothic2Notr Sources phase"
        )
    gothic_member_matches = list(re.finditer(
        rf"^\s*([A-F0-9]{{24}}) "
        rf"/\* [^\n]*{escaped_source} \*/,$",
        phase.group(1),
        re.M,
    ))
    gothic_members = [
        match.group(1) for match in gothic_member_matches
    ]
    if gothic_members != [build_file_id]:
        raise ValueError(
            "exact iosdevicecapabilities.cpp PBXBuildFile is not "
            "exactly once in Gothic2Notr Sources"
        )
    sources_phases = re.findall(
        r"\b[A-F0-9]{24} /\* Sources \*/ = \{\n"
        r"\s*isa = PBXSourcesBuildPhase;(.*?)\n\s*\};",
        candidate_project,
        re.S,
    )
    all_source_members = sum(
        len(re.findall(
            rf"^\s*{build_file_id} "
            r"/\* [^\n]* \*/,$",
            body,
            re.M,
        ))
        for body in sources_phases
    )
    if all_source_members != 1:
        raise ValueError(
            "iosdevicecapabilities.cpp PBXBuildFile appears "
            "outside its one Gothic2Notr Sources membership"
        )
    return (
        file_reference_id,
        build_file_id,
        reference_matches[0].group(0),
        build_file_matches[0].group(0),
        gothic_member_matches[0].group(0),
    )

try:
    (
        file_reference_id,
        build_file_id,
        reference_line,
        build_file_line,
        gothic_member_line,
    ) = validate_project(project)
except (ValueError, IndexError) as error:
    raise SystemExit(str(error)) from error

def replace_once(text, before, after):
    if text.count(before) != 1:
        raise SystemExit(
            "PBX mutation anchor is not unique: " + before
        )
    return text.replace(before, after, 1)

invalid_id = "F" * 24
alias_id = "E" * 24
alternate_comment_member = re.sub(
    r"/\* [^\n]* \*/",
    "/* unrelated.cpp */",
    gothic_member_line,
    count=1,
)
alias_build_file_line = (
    f"\t\t{alias_id} /* unrelated.cpp */ = "
    f"{{isa = PBXBuildFile; fileRef = {file_reference_id} "
    "/* unrelated.cpp */; };"
)
mutations = (
    (
        "duplicate-file-reference",
        replace_once(
            project,
            reference_line,
            reference_line + "\n" + reference_line,
        ),
    ),
    (
        "wrong-build-file-reference",
        replace_once(
            project,
            f"fileRef = {file_reference_id} /*",
            f"fileRef = {invalid_id} /*",
        ),
    ),
    (
        "wrong-gothic-membership-id",
        replace_once(
            project,
            gothic_member_line,
            gothic_member_line.replace(
                build_file_id, invalid_id, 1
            ),
        ),
    ),
    (
        "duplicate-gothic-membership",
        replace_once(
            project,
            gothic_member_line,
            gothic_member_line + "\n" + gothic_member_line,
        ),
    ),
    (
        "duplicate-membership-id-different-comment",
        replace_once(
            project,
            gothic_member_line,
            gothic_member_line + "\n"
            + alternate_comment_member,
        ),
    ),
    (
        "duplicate-file-reference-link-different-comment",
        replace_once(
            project,
            build_file_line,
            build_file_line + "\n" + alias_build_file_line,
        ),
    ),
)
mutations_killed = 0
for label, candidate_project in mutations:
    try:
        validate_project(candidate_project)
    except (ValueError, IndexError):
        mutations_killed += 1
    else:
        raise SystemExit(
            "P2.6a PBX structural mutation survived: " + label
        )
if mutations_killed != 6:
    raise SystemExit(
        "P2.6a PBX structural mutation count drifted"
    )
print("P2.6a PBX structural oracle: mutations-killed=6")
PY

printf '\n### CI contract: Verify P2.6b1 collector source target membership\n'
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import re

project = Path(
    "build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj"
).read_text()
sources = (
    "game/graphics/iosdevicefactscollector.cpp",
    "game/graphics/iosdevicefactscollector.mm",
)

def sections(candidate_project):
    file_references = candidate_project.split(
        "/* Begin PBXFileReference section */", 1
    )[1].split("/* End PBXFileReference section */", 1)[0]
    build_files = candidate_project.split(
        "/* Begin PBXBuildFile section */", 1
    )[1].split("/* End PBXBuildFile section */", 1)[0]
    targets = re.findall(
        r"\b([A-F0-9]{24}) /\* [^*]+ \*/ = \{\n"
        r"\s*isa = PBXNativeTarget;(.*?)\n\s*\};",
        candidate_project,
        re.S,
    )
    gothic = [
        body for _, body in targets
        if re.search(r"^\s*name = Gothic2Notr;$", body, re.M)
    ]
    if len(gothic) != 1:
        raise ValueError("could not identify exact Gothic2Notr target")
    source_phase = re.search(
        r"([A-F0-9]{24}) /\* Sources \*/", gothic[0]
    )
    if source_phase is None:
        raise ValueError("Gothic2Notr target has no Sources phase")
    phase_matches = list(re.finditer(
        r"\b([A-F0-9]{24}) /\* Sources \*/ = \{\n"
        r"\s*isa = PBXSourcesBuildPhase;(.*?)\n\s*\};",
        candidate_project,
        re.S,
    ))
    gothic_phases = [
        match for match in phase_matches
        if match.group(1) == source_phase.group(1)
    ]
    if len(gothic_phases) != 1:
        raise ValueError("could not read exact Gothic2Notr Sources phase")
    return (
        file_references,
        build_files,
        phase_matches,
        gothic_phases[0],
    )

def validate_source(candidate_project, source):
    (
        file_references,
        build_files,
        phase_matches,
        gothic_phase,
    ) = sections(candidate_project)
    escaped = re.escape(source)
    reference_matches = list(re.finditer(
        rf"^\s*([A-F0-9]{{24}}) "
        rf"/\* [^\n]*{escaped} \*/ = "
        rf"\{{isa = PBXFileReference;"
        rf"[^\n]*path = {escaped};[^\n]*\}};$",
        file_references,
        re.M,
    ))
    if len(reference_matches) != 1:
        raise ValueError(
            source + " does not have exactly one PBXFileReference"
        )
    reference_id = reference_matches[0].group(1)
    build_matches = list(re.finditer(
        rf"^\s*([A-F0-9]{{24}}) "
        rf"/\* [^\n]*{escaped} \*/ = "
        rf"\{{isa = PBXBuildFile; "
        rf"fileRef = ([A-F0-9]{{24}}) "
        rf"/\* [^\n]*{escaped} \*/; \}};$",
        build_files,
        re.M,
    ))
    if len(build_matches) != 1:
        raise ValueError(
            source + " does not have exactly one PBXBuildFile"
        )
    build_id = build_matches[0].group(1)
    if build_matches[0].group(2) != reference_id:
        raise ValueError(source + " PBXBuildFile points elsewhere")
    linked_builds = re.findall(
        rf"^\s*([A-F0-9]{{24}}) /\* [^\n]* \*/ = "
        rf"\{{isa = PBXBuildFile; fileRef = {reference_id} "
        r"/\* [^\n]* \*/; \};$",
        build_files,
        re.M,
    )
    if linked_builds != [build_id]:
        raise ValueError(
            source + " reference has non-exact PBXBuildFile linkage"
        )
    member_matches = list(re.finditer(
        rf"^\s*{build_id} /\* [^\n]*{escaped} \*/,$",
        gothic_phase.group(2),
        re.M,
    ))
    if len(member_matches) != 1:
        raise ValueError(
            source + " is not exactly once in Gothic2Notr Sources"
        )
    all_memberships = sum(
        len(re.findall(
            rf"^\s*{build_id} /\* [^\n]* \*/,$",
            phase.group(2),
            re.M,
        ))
        for phase in phase_matches
    )
    if all_memberships != 1:
        raise ValueError(
            source + " PBXBuildFile appears in another Sources phase"
        )
    return {
        "reference_id": reference_id,
        "build_id": build_id,
        "reference_line": reference_matches[0].group(0),
        "build_line": build_matches[0].group(0),
        "member_line": member_matches[0].group(0),
        "gothic_phase_id": gothic_phase.group(1),
    }

def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(
            "PBX mutation anchor is not unique: " + before
        )
    return text.replace(before, after, 1)

total_mutations = 0
for source in sources:
    anchors = validate_source(project, source)
    invalid_id = "F" * 24
    duplicate_build_id = "E" * 24
    duplicate_build_line = re.sub(
        rf"^\s*{anchors['build_id']}",
        "\t\t" + duplicate_build_id,
        anchors["build_line"],
    )
    mutations = [
        (
            "duplicate-reference",
            replace_once(
                project,
                anchors["reference_line"],
                anchors["reference_line"] + "\n"
                + anchors["reference_line"],
            ),
        ),
        (
            "wrong-build-reference",
            replace_once(
                project,
                "fileRef = " + anchors["reference_id"] + " /*",
                "fileRef = " + invalid_id + " /*",
            ),
        ),
        (
            "duplicate-build-file",
            replace_once(
                project,
                anchors["build_line"],
                anchors["build_line"] + "\n"
                + duplicate_build_line,
            ),
        ),
        (
            "wrong-gothic-member",
            replace_once(
                project,
                anchors["member_line"],
                anchors["member_line"].replace(
                    anchors["build_id"], invalid_id, 1
                ),
            ),
        ),
        (
            "duplicate-gothic-member",
            replace_once(
                project,
                anchors["member_line"],
                anchors["member_line"] + "\n"
                + anchors["member_line"],
            ),
        ),
    ]
    (
        _,
        _,
        phase_matches,
        gothic_phase,
    ) = sections(project)
    other_phases = [
        phase for phase in phase_matches
        if phase.group(1) != gothic_phase.group(1)
    ]
    if not other_phases:
        raise SystemExit(
            "PBX fixture has no second Sources phase for mutation"
        )
    other_phase = other_phases[0]
    other_body = other_phase.group(0)
    injected_other = replace_once(
        other_body,
        "files = (\n",
        "files = (\n" + anchors["member_line"] + "\n",
    )
    mutations.append((
        "other-target-membership",
        replace_once(project, other_body, injected_other),
    ))

    killed = 0
    for label, candidate in mutations:
        try:
            validate_source(candidate, source)
        except (ValueError, IndexError):
            killed += 1
        else:
            raise SystemExit(
                "P2.6b1 PBX mutation survived for "
                + source + ": " + label
            )
    if killed != 6:
        raise SystemExit(
            "P2.6b1 PBX mutation count drifted for " + source
        )
    total_mutations += killed
if total_mutations != 12:
    raise SystemExit("P2.6b1 total PBX mutation count drifted")
print("P2.6b1 PBX oracle: sources=2 mutations-killed=12")
PY

printf '\n### CI contract: Assert legacy renderer is not in the target\n'
if grep -Eq '(^|[^[:alnum:]_])renderer\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj; then
  echo 'legacy game/graphics/renderer.cpp is still present in the RendererIOS target'
  exit 1
fi
grep -Eq '(^|[^[:alnum:]_])rendererios\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosmetalcontext\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosframeinput\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq 'game/graphics/iosframeplan\.cpp \*/ = \{isa = PBXBuildFile; fileRef =' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
awk '
  /Begin PBXSourcesBuildPhase section/ { in_sources=1 }
  /End PBXSourcesBuildPhase section/ { in_sources=0 }
  in_sources && /game\/graphics\/iosframeplan\.cpp \*\// { found=1 }
  END { exit found ? 0 : 1 }
' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosrenderworld\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosscenesnapshot\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iossceneconversion\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iossceneassetregistry\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iossceneextractor\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosgpuscene\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosgpubink\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosmetalresourceallocator\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosmetalresourceallocator\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosshadingprototypepipeline\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosshadingprototypepipeline\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosshadingprototypeforwardpipeline\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosshadingprototypeforwardpipeline\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosshadingprototypeforwardprobe\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosshadingprototypeforwardprobe\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosshadingprototypetileprobe\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosshadingprototypetileprobe\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
for source in iosshadingprototypepipeline.cpp \
    iosshadingprototypepipeline.mm \
    iosshadingprototypeforwardpipeline.cpp \
    iosshadingprototypeforwardpipeline.mm \
    iosshadingprototypeforwardprobe.cpp \
    iosshadingprototypeforwardprobe.mm \
    iosshadingprototypetileprobe.cpp \
    iosshadingprototypetileprobe.mm; do
  test "$(grep -Fc \
    "game/graphics/${source} */ = {isa = PBXBuildFile; fileRef =" \
    build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj)" -eq 1
done
python3 - <<'PY'
from pathlib import Path
import re

project = Path(
    "build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj"
).read_text()
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
for source in (
    "iosshadingprototypepipeline.cpp",
    "iosshadingprototypepipeline.mm",
    "iosshadingprototypeforwardpipeline.cpp",
    "iosshadingprototypeforwardpipeline.mm",
    "iosshadingprototypeforwardprobe.cpp",
    "iosshadingprototypeforwardprobe.mm",
    "iosshadingprototypetileprobe.cpp",
    "iosshadingprototypetileprobe.mm",
):
    if phase.group(1).count(source) != 1:
        raise SystemExit(
            f"{source} is not exactly once in Gothic2Notr Sources"
        )
PY
grep -Eq '(^|[^[:alnum:]_])iosmetalresourceclearpassprobe\.cpp([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Eq '(^|[^[:alnum:]_])iosmetalresourceclearpassprobe\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
for source in iosmetalresourceclearpassprobe.cpp \
    iosmetalresourceclearpassprobe.mm; do
  awk -v source="$source" '
    /Begin PBXSourcesBuildPhase section/ { in_sources=1 }
    /End PBXSourcesBuildPhase section/ { in_sources=0 }
    in_sources && index($0,source)>0 { found=1 }
    END { exit found ? 0 : 1 }
  ' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
done
grep -Eq '(^|[^[:alnum:]_])rendereriosplatform\.mm([^[:alnum:]_]|$)' build-renderer-ios/Gothic2Notr.xcodeproj/project.pbxproj
grep -Fq 'legacyShaders(Shaders::CompilationProfile::RendererIOSBridge)' game/graphics/iosmetalcontext.cpp
grep -Fq 'profile=bridge-only eager-bridge-pipelines=inventory offline-native-pipelines=builtin,bink legacy-batch=disabled material-pipelines=source-metadata-only pfx-pipelines=disabled' game/graphics/shaders.cpp
! grep -Fq 'Shaders::inst().bink' game/ui/videowidget.cpp
grep -Fq 'runtimeCompilationSnapshot(device)' game/graphics/iosmetalcontext.cpp
grep -Fq 'builtinRuntimeSnapshot(device)' game/graphics/iosmetalcontext.cpp
grep -Fq 'point=legacy-bridge role-abi=1 available=' game/graphics/iosmetalcontext.cpp
grep -Fq 'MetalBuiltinOfflineManifest manifest;' game/main.cpp
grep -Fq 'MetalApi>(flg,manifest)' game/main.cpp
grep -Fq 'RendererIOS builtin shader library: source=offline-metallib' game/main.cpp
grep -Fq 'runtime_compilation_bridge_source_delta=' ios/device-test/run-smoke-test.sh
grep -Fq 'builtin_render_active_roles=' ios/device-test/run-smoke-test.sh
grep -Fq 'impl->logRuntimeCompilationFrame(impl->counters.presentAccepted);' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST' CMakeLists.txt
grep -Fq 'materializeBinkSelfTestAfterTerminal(' \
  game/graphics/iosmetalcontext.cpp
grep -Fq -- '--require-bink-self-test' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST' CMakeLists.txt
grep -Fq -- '--require-resource-allocator-self-test' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST' CMakeLists.txt
grep -Fq -- '--require-clear-only-pass-self-test' \
  ios/device-test/run-smoke-test.sh

printf '\n### CI contract: Verify RendererIOS UI automation contract\n'
set -euo pipefail

test -x ios/device-test/run-ui-automation-test.sh
test -x ios/device-test/validate-ui-automation-log.py
test -f ios/device-test/select-ui-automation-target.py
/bin/bash -n ios/device-test/run-ui-automation-test.sh
PYTHONPYCACHEPREFIX="$RUNNER_TEMP/renderer-ios-python-cache" \
  python3 -m py_compile \
    ios/device-test/select-ui-automation-target.py
PYTHONDONTWRITEBYTECODE=1 \
  python3 ios/device-test/select-ui-automation-target.py self-test
/bin/bash ios/device-test/run-ui-automation-test.sh --self-test
python3 ios/device-test/validate-ui-automation-log.py --self-test
test -x ios/device-test/run-semantic-ui-lifecycle-test.sh
test -x ios/device-test/validate-semantic-ui-lifecycle-log.py
test -x ios/device-test/semantic-console-supervisor.py
test -x ios/device-test/test-semantic-console-harness.sh
bash -n ios/device-test/run-semantic-ui-lifecycle-test.sh
bash -n ios/device-test/test-semantic-console-harness.sh
python3 ios/device-test/validate-semantic-ui-lifecycle-log.py --self-test
python3 ios/device-test/semantic-console-supervisor.py self-test
bash ios/device-test/test-semantic-console-harness.sh
grep -Fq 'trap cleanup EXIT' \
  ios/device-test/run-ui-automation-test.sh
grep -Fq -- '--kill --quiet' \
  ios/device-test/run-ui-automation-test.sh
grep -Fq 'stop_running_app 1 || fail "post-test application cleanup failed"' \
  ios/device-test/run-ui-automation-test.sh
grep -Fq '"skippedTests": 0' \
  ios/device-test/run-ui-automation-test.sh
grep -Fq 'crash.log changed during the UI automation run' \
  ios/device-test/run-ui-automation-test.sh
! grep -Fq 'XCTSkip' \
  ios/device-test/ui-automation/RendererIOSUITests/RendererIOSUITests.swift
grep -Fq 'fence-terminal=1 submitted=1 presented=1' \
  ios/device-test/validate-ui-automation-log.py
grep -Fxq '[[ "$SCENARIO" != save ]] || VALIDATOR_ARGS+=(--require-ui-items)' \
  ios/device-test/run-ui-automation-test.sh
grep -Fxq '    parser.add_argument("--require-ui-items", action="store_true")' \
  ios/device-test/validate-ui-automation-log.py
grep -Fxq '        require_ui_items=args.require_ui_items,' \
  ios/device-test/validate-ui-automation-log.py
grep -Fxq '    r"ui-item-draw-count=(\d+) "' \
  ios/device-test/validate-ui-automation-log.py
grep -Fq '++drawCalls;' game/graphics/inventoryrenderer.cpp
grep -Fq 'uiItemDrawCount = inventory.draw(encoder);' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'unknown RendererIOS semantic script argument' \
  game/commandline.cpp
grep -Fq '"-renderer-ios-semantic-script=save-ui-lifecycle-v1";' \
  game/commandline.cpp
grep -Fq 'RendererIOS semantic script requires diagnostics' \
  game/commandline.cpp
grep -Fq 'duplicate RendererIOS semantic script argument' \
  game/commandline.cpp
grep -Fq 'missing RendererIOS semantic nonce argument' \
  game/commandline.cpp
grep -Fq 'RendererIOS semantic script requires one numeric save argument' \
  game/commandline.cpp
grep -Fq 'IOSFunctionalEvidenceSnapshot functionalEvidenceSnapshot() const noexcept' \
  game/graphics/rendererios.h
grep -Fq 'functionalEvidenceSnapshot.inventoryItemDrawCount' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'const bool proveUiItems = evidence.uiItemDrawCount>0u' \
  game/graphics/iosmetalcontext.cpp
grep -Fq 'uiAction(KeyCodec::Inventory);' game/mainwindow.cpp
grep -Fq 'padOpenItemRing();' game/mainwindow.cpp
grep -Fq 'padOpenWeaponsRing();' game/mainwindow.cpp
grep -Fq 'padRingCancel();' game/mainwindow.cpp
grep -Fq 'com.apple.Preferences' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq -- '--terminate-existing --activate com.apple.Preferences' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'SEMANTIC FALLBACK PASS' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'select_device_record()' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'require_same_game_pid before-cleanup || status=1' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'finalize_runtime 1 || fail' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq -- '--terminate-existing --console --json-output "$WORK/console-launch.json"' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq -- '--stop-request "$WORK/console-stop-request"' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq -- '--instance-token "$CONSOLE_INSTANCE_TOKEN"' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'begin_console_startup_critical_section' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fxq 'CONSOLE_STARTUP_PID=$!' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'finish_console_startup_critical_section || fail' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'wait_for_game_pid || fail' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fxq 'readonly PROCESS_QUERY_TIMEOUT_SECONDS=5' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq -- '--timeout "$PROCESS_QUERY_TIMEOUT_SECONDS"' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_launcher_reaped=$CONSOLE_LAUNCHER_REAPED' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_launcher_exit_code=$CONSOLE_LAUNCHER_EXIT_CODE' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_launcher_premature_exit=$CONSOLE_LAUNCHER_PREMATURE_EXIT' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_launcher_forced_kill=$CONSOLE_LAUNCHER_FORCED_KILL' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_observer_state=$CONSOLE_OBSERVER_STATE' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_observer_errors=$CONSOLE_OBSERVER_ERRORS' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_stop_requested=$CONSOLE_STOP_REQUESTED' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_prestop_liveness=$CONSOLE_PRESTOP_LIVENESS' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_startup_signal_status=$CONSOLE_STARTUP_SIGNAL_STATUS' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'console_marker_hits=$CONSOLE_MARKER_HITS' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'start_new_session=True' \
  ios/device-test/semantic-console-supervisor.py
grep -Fq 'signal.signal(caught, signal.SIG_IGN)' \
  ios/device-test/semantic-console-supervisor.py
grep -Fq 'with raw_path.open("xb", buffering=0) as raw:' \
  ios/device-test/semantic-console-supervisor.py
grep -Fq 'os.replace(temporary, path)' \
  ios/device-test/semantic-console-supervisor.py
! grep -Fq -- '--terminate-existing --console --timeout' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
! grep -Fq 'pull_live_log' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
! grep -Fq 'log-live.txt' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
! grep -Fq 'snapshot_logs before-cleanup' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fxq 'readonly DOCUMENT_COPY_MAX_ATTEMPTS=3' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'for ((attempt=1; attempt<=DOCUMENT_COPY_MAX_ATTEMPTS; ++attempt)); do' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'copy-retry file=$name attempt=$attempt/$DOCUMENT_COPY_MAX_ATTEMPTS result=provider-failure' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'provider listed Documents/$name but copy failed after $DOCUMENT_COPY_MAX_ATTEMPTS attempts' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'could not distinguish missing Documents/$name from provider failure after $DOCUMENT_COPY_MAX_ATTEMPTS attempts' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fxq 'readonly DURABLE_ZERO_MAX_CYCLES=3' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fxq 'readonly DURABLE_ZERO_SCANS_PER_CYCLE=10' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fxq 'readonly DURABLE_ZERO_INTERVAL_SECONDS=10' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fxq 'readonly DURABLE_ZERO_REQUIRED_STABLE_SECONDS=90' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'while ((DURABLE_ZERO_CYCLES_USED < DURABLE_ZERO_MAX_CYCLES)); do' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'for ((scan=1; scan<=DURABLE_ZERO_SCANS_PER_CYCLE; ++scan)); do' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'elapsed-seconds=$cycle_elapsed result=respawn' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'processes-durable-zero-cycle-$cycle-final.json' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'durable_zero_respawns_detected=$DURABLE_ZERO_RESPAWNS_DETECTED' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'durable_zero_query_failures=$DURABLE_ZERO_QUERY_FAILURES' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'durable_zero_stop_failures=$DURABLE_ZERO_STOP_FAILURES' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'durable_zero_park_failures=$DURABLE_ZERO_PARK_FAILURES' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'durable_zero_stable=$DURABLE_ZERO_STABLE' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'durable_zero_stable_seconds=$DURABLE_ZERO_STABLE_SECONDS' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'durable_zero_final_zero=$DURABLE_ZERO_FINAL_ZERO' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'durable_zero_elapsed_seconds=$DURABLE_ZERO_ELAPSED_SECONDS' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
grep -Fq 'DURABLE_ZERO_STABLE_SECONDS < DURABLE_ZERO_REQUIRED_STABLE_SECONDS' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
! grep -Eq 'device process (suspend|resume)' \
  ios/device-test/run-semantic-ui-lifecycle-test.sh
python3 - <<'PY'
import re
from pathlib import Path
harness = Path("ios/device-test/run-semantic-ui-lifecycle-test.sh").read_text()
supervisor = Path("ios/device-test/semantic-console-supervisor.py").read_text()
copy_function = harness.split("copy_document_file() {", 1)[1].split("\nsnapshot_logs() {", 1)[0]
copy_contract = (
    'for ((attempt=1; attempt<=DOCUMENT_COPY_MAX_ATTEMPTS; ++attempt)); do',
    'document_file_exists',
    'xcrun devicectl device copy from',
    '((attempt == DOCUMENT_COPY_MAX_ATTEMPTS)) || sleep 1',
    'return 2',
)
copy_positions = [copy_function.index(literal) for literal in copy_contract]
if copy_positions != sorted(copy_positions):
    raise SystemExit("semantic document-copy retry contract is out of order")
durable_function = harness.split("ensure_durable_zero() {", 1)[1].split("\ndocument_file_exists() {", 1)[0]
durable_contract = (
    'while ((DURABLE_ZERO_CYCLES_USED < DURABLE_ZERO_MAX_CYCLES)); do',
    'if ! stop_running_app 1; then',
    'if ! park_settings_foreground; then',
    'for ((scan=1; scan<=DURABLE_ZERO_SCANS_PER_CYCLE; ++scan)); do',
    'sleep "$DURABLE_ZERO_INTERVAL_SECONDS"',
    'processes-durable-zero-cycle-$cycle-scan-$scan.json',
    'scan=$scan elapsed-seconds=$cycle_elapsed result=query-failure',
    'scan=$scan elapsed-seconds=$cycle_elapsed result=respawn',
    'DURABLE_ZERO_STABLE_SECONDS < DURABLE_ZERO_REQUIRED_STABLE_SECONDS',
    'processes-durable-zero-cycle-$cycle-final.json',
    'DURABLE_ZERO_FINAL_ZERO=1',
    'processes-durable-zero-emergency-final.json',
)
durable_positions = [durable_function.index(literal) for literal in durable_contract]
if durable_positions != sorted(durable_positions):
    raise SystemExit("semantic durable-zero cleanup contract is out of order")
if 'DURABLE_ZERO_CYCLES_USED=0' in durable_function:
    raise SystemExit("semantic durable-zero cleanup resets its global cycle budget")
if 'DURABLE_ZERO_QUERY_FAILURES=0' in durable_function:
    raise SystemExit("semantic durable-zero cleanup resets query-failure evidence")
if harness.count('DEVICE_PROCESS_STOPPED=1') != 2:
    raise SystemExit("device_process_stopped has an unguarded success assignment")
if 'FINALIZATION_ATTEMPTED' in harness:
    raise SystemExit("trap cleanup may not be gated by a finalization-attempt flag")
constants = {}
for name in (
    "DURABLE_ZERO_MAX_CYCLES",
    "DURABLE_ZERO_SCANS_PER_CYCLE",
    "DURABLE_ZERO_INTERVAL_SECONDS",
    "DURABLE_ZERO_REQUIRED_STABLE_SECONDS",
):
    match = re.search(rf"^readonly {name}=([0-9]+)$", harness, re.MULTILINE)
    if match is None:
        raise SystemExit(f"missing semantic durable-zero constant: {name}")
    constants[name] = int(match.group(1))
scheduled_span = (
    constants["DURABLE_ZERO_SCANS_PER_CYCLE"] - 1
) * constants["DURABLE_ZERO_INTERVAL_SECONDS"]
if constants["DURABLE_ZERO_MAX_CYCLES"] > 3:
    raise SystemExit("semantic durable-zero cleanup exceeds three global cycles")
if constants["DURABLE_ZERO_SCANS_PER_CYCLE"] < 10 or scheduled_span < 90:
    raise SystemExit("semantic durable-zero scan schedule is shorter than t=0..90s")
if constants["DURABLE_ZERO_REQUIRED_STABLE_SECONDS"] < 90:
    raise SystemExit("semantic durable-zero stable-window gate is shorter than 90 seconds")
cleanup_function = harness.split("\ncleanup() {", 1)[1].split("\ntrap cleanup", 1)[0]
if 'local status=$?' not in cleanup_function:
    raise SystemExit("semantic trap cleanup does not preserve the original status")
if 'finalize_runtime || cleanup_status=1' not in cleanup_function:
    raise SystemExit("semantic trap cleanup does not consume the remaining durable budget")
if durable_function.rfind('return 1') < durable_function.index('processes-durable-zero-emergency-final.json'):
    raise SystemExit("semantic durable-zero exhaustion is not fail-closed")
game_pid_function = harness.split("wait_for_game_pid() {", 1)[1].split("\nwait_for_marker() {", 1)[0]
game_pid_contract = (
    'deadline=$((SECONDS+GAME_PID_DISCOVERY_SECONDS))',
    'while ((SECONDS < deadline)); do',
    'list_game_pids',
    'require_console_running game-pid-discovery',
    'GAME_PID="$pids"',
)
game_pid_positions = [game_pid_function.index(literal) for literal in game_pid_contract]
if game_pid_positions != sorted(game_pid_positions):
    raise SystemExit("semantic console GAME_PID discovery contract is out of order")
wait_function = harness.split("wait_for_marker() {", 1)[1].split("\npreserve_evidence() {", 1)[0]
wait_contract = (
    'require_same_game_pid "$label"',
    '"$CONSOLE_SUPERVISOR" probe',
    'script-fail)',
    'duplicate)',
    'require_console_running "marker-$label"',
    '[[ "$marker_state" == marker ]]',
    'CONSOLE_MARKER_HITS=$((CONSOLE_MARKER_HITS+1))',
)
wait_positions = [wait_function.index(literal) for literal in wait_contract]
if wait_positions != sorted(wait_positions):
    raise SystemExit("semantic raw-console marker wait contract is out of order")
if any(forbidden in wait_function for forbidden in (
    "copy_document_file", "snapshot_logs", "Documents/", "log-live.txt"
)):
    raise SystemExit("semantic marker wait reads the live Documents provider")
active_runtime = harness.split("RUNTIME_ARMED=1", 1)[1].split("finalize_runtime 1 || fail", 1)[0]
if "copy_document_file" in active_runtime or "snapshot_logs" in active_runtime:
    raise SystemExit("semantic active runtime still polls the Documents provider")
console_launch = active_runtime.split('"$CONSOLE_SUPERVISOR" supervise', 1)[1].split("CONSOLE_STARTUP_PID=$!", 1)[0]
if "--timeout" in console_launch:
    raise SystemExit("semantic devicectl console launch has an overall timeout")
if harness.count("snapshot_logs ") != 2:
    raise SystemExit("semantic harness must only snapshot Documents pre-test and final")
finalize_function = harness.split("finalize_runtime() {", 1)[1].split("\ncleanup() {", 1)[0]
finalize_contract = (
    'snapshot_console_before_stop || status=1',
    'require_same_game_pid before-cleanup || status=1',
    'require_console_running before-stop',
    'CONSOLE_PRESTOP_LIVENESS=1',
    'if ensure_durable_zero; then',
    'reap_console_launcher || status=1',
    '((CONSOLE_LAUNCHER_REAPED != 0)) || status=1',
    'if ((durable_zero != 0 && CONSOLE_LAUNCHER_REAPED != 0)); then',
    'snapshot_logs final || status=1',
)
finalize_positions = [finalize_function.index(literal) for literal in finalize_contract]
if finalize_positions != sorted(finalize_positions):
    raise SystemExit("semantic raw/stop/reap/final-copy contract is out of order")
reap_function = harness.split("reap_console_launcher() {", 1)[1].split("\nsnapshot_console_before_stop() {", 1)[0]
reap_contract = (
    'request_console_stop || true',
    'observe_console_launcher',
    'capture_console_launcher_exit reaped-after-device-zero',
    'request_console_stop || return 1',
    'observe_console_launcher',
    'capture_console_launcher_exit reaped-after-supervisor-stop-request',
    'refusing unsafe PID kill',
)
reap_positions = []
cursor = 0
for literal in reap_contract:
    position = reap_function.index(literal, cursor)
    reap_positions.append(position)
    cursor = position + len(literal)
capture_function = harness.split("capture_console_launcher_exit() {", 1)[1].split("\nrequest_console_stop() {", 1)[0]
capture_contract = (
    'observe_console_launcher',
    '[[ "$CONSOLE_OBSERVER_STATE" == EXITED ]]',
    'wait "$CONSOLE_LAUNCHER_PID"',
    'read_console_status',
    '[[ "$CONSOLE_STREAM_STATE" != exited ]]',
)
capture_positions = [capture_function.index(literal) for literal in capture_contract]
if capture_positions != sorted(capture_positions):
    raise SystemExit("semantic console wait is not gated by proven process exit")
request_function = harness.split("request_console_stop() {", 1)[1].split("\ndefer_console_startup_signal() {", 1)[0]
observer_function = harness.split("observe_console_launcher() {", 1)[1].split("\nrequire_console_running() {", 1)[0]
pid_action_pattern = re.compile(r"(?m)^\s*(?:if\s+|!\s*)?kill(?:\s|$)")
for name, function in (
    ("capture", capture_function),
    ("request", request_function),
    ("reap", reap_function),
):
    if pid_action_pattern.search(function):
        raise SystemExit(f"semantic console {name} may not signal a PID")
observer_kill_lines = [
    line.strip() for line in observer_function.splitlines()
    if re.match(r"^\s*(?:if\s+|!\s*)?kill(?:\s|$)", line)
]
if observer_kill_lines != [
    'if kill -0 "$CONSOLE_LAUNCHER_PID" 2>/dev/null; then'
]:
    raise SystemExit("semantic console observer may only use exact kill -0 liveness probe")
observer_identity = (
    'ps -ww -p "$CONSOLE_LAUNCHER_PID"',
    '"$process_parent" == "$CONSOLE_PARENT_PID" &&',
    '"$process_command" == *"$CONSOLE_SUPERVISOR"* &&',
    '"$process_command" == *" supervise "* &&',
    '"$process_command" == *"--instance-token $CONSOLE_INSTANCE_TOKEN"* &&',
    '"$process_command" == *"--status $WORK/console-status.json"* &&',
    '"$process_command" == *"--stop-request $WORK/console-stop-request"*',
)
observer_positions = [observer_function.index(literal) for literal in observer_identity]
if observer_positions != sorted(observer_positions):
    raise SystemExit("semantic console observer identity contract is out of order")
begin_startup = harness.split("begin_console_startup_critical_section() {", 1)[1].split("\nfinish_console_startup_critical_section() {", 1)[0]
finish_startup = harness.split("finish_console_startup_critical_section() {", 1)[1].split("\nreap_console_launcher() {", 1)[0]
for literal in (
    "trap 'defer_console_startup_signal 130' INT",
    "trap 'defer_console_startup_signal 143' TERM",
    "trap 'defer_console_startup_signal 129' HUP",
):
    if literal not in begin_startup:
        raise SystemExit("semantic console startup does not defer all exit signals")
finish_contract = (
    'CONSOLE_LAUNCHER_PID="$CONSOLE_STARTUP_PID"',
    "trap 'exit 130' INT",
    "trap 'exit 143' TERM",
    "trap 'exit 129' HUP",
    'exit "$CONSOLE_STARTUP_SIGNAL_STATUS"',
)
finish_positions = [finish_startup.index(literal) for literal in finish_contract]
if finish_positions != sorted(finish_positions):
    raise SystemExit("semantic console startup PID/signal handoff is out of order")
supervisor_contract = (
    'signal.signal(caught, signal.SIG_IGN)',
    'with raw_path.open("xb", buffering=0) as raw:',
    'start_new_session=True',
    'requested_token = stop_request_path.read_text().strip()',
    'if requested_token == instance_token:',
    'child.kill()',
    'returncode = child.wait()',
    'base["forced_kill"] = True',
)
supervisor_positions = [supervisor.index(literal) for literal in supervisor_contract]
if supervisor_positions != sorted(supervisor_positions):
    raise SystemExit("semantic console supervisor contract is out of order")
if supervisor.rfind('state="exited"') < supervisor.index('returncode = child.wait()'):
    raise SystemExit("semantic console supervisor does not publish terminal child status")
for fixture in ("lf", "crlf", "partial", "bare-cr", "crcrlf", "wrong-nonce", "current-fail", "duplicate", "early exit", "wrong stop token", "authenticated stop", "publish-failure"):
    if fixture not in supervisor:
        raise SystemExit(f"semantic console supervisor lacks {fixture} self-test")
ordered = (
    'stop_running_app 1 || fail "pre-test game cleanup failed"',
    'snapshot_logs pre-test || fail',
    'begin_console_startup_critical_section',
    'RUNTIME_ARMED=1',
    '"$CONSOLE_SUPERVISOR" supervise',
    '--terminate-existing --console --json-output "$WORK/console-launch.json"',
    'CONSOLE_STARTUP_PID=$!',
    'finish_console_startup_critical_section || fail',
    'wait_for_game_pid || fail',
    'wait_for_marker armed',
    'finalize_runtime 1 || fail',
    '[[ -s "$WORK/log-final.txt" ]]',
    'python3 - "$WORK/log-final.txt" "$EXPECTED_SHA"',
    'VALIDATOR_ARGS=("$WORK/log-final.txt" --nonce "$NONCE")',
    '"$VALIDATOR" "${VALIDATOR_ARGS[@]}"',
    'echo "SEMANTIC FALLBACK PASS',
)
main_flow = harness.split("SETTINGS_AVAILABLE=1", 1)[1]
positions = [main_flow.index(literal) for literal in ordered]
if positions != sorted(positions):
    raise SystemExit("semantic cleanup/validation/PASS contract is out of order")
pipeline_main_start = 'RUNTIME_ARMED=1'
pipeline_main_end = (
    'echo "SEMANTIC FALLBACK PASS — '
    'Inventory/QuickRings/lifecycle; app stopped"'
)
if harness.count(pipeline_main_start) != 1 or harness.count(pipeline_main_end) != 1:
    raise SystemExit("semantic pipeline main execution region is not exact")
pipeline_main = harness[
    harness.index(pipeline_main_start):harness.index(pipeline_main_end)
]
pipeline_main_order = (
    'wait_for_marker archive-post "$ARCHIVE_POST" 180 ||',
    'finalize_runtime 1 || fail "battery-safe final cleanup/evidence pull failed"',
    'RUNTIME_ARMED=0',
    'copy_pipeline_cache_evidence || fail "could not preserve pipeline archive cache evidence"',
    '[[ -s "$WORK/log-final.txt" ]] || fail "device produced no final log.txt"',
    'python3 - "$WORK/log-final.txt" "$EXPECTED_SHA" <<\'PY\' ||',
    '"$VALIDATOR" "${VALIDATOR_ARGS[@]}" || fail "semantic evidence validation failed"',
    'python3 "$PIPELINE_VALIDATOR" \\',
    'preserve_evidence PASS',
)
for literal in pipeline_main_order:
    if pipeline_main.count(literal) != 1:
        raise SystemExit(
            f"semantic pipeline main execution contract is not exact: {literal}"
        )
pipeline_main_positions = [
    pipeline_main.index(literal) for literal in pipeline_main_order
]
if pipeline_main_positions != sorted(pipeline_main_positions):
    raise SystemExit(
        "semantic pipeline POST/finalize/durable-zero/cache/validation/PASS "
        "contract is out of order"
    )
PY
xcodebuild \
  -project ios/device-test/ui-automation/RendererIOSUITests.xcodeproj \
  -scheme RendererIOSUITests \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$RUNNER_TEMP/renderer-ios-ui-tests" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

printf '\nRendererIOS CI contracts passed exactly once\n'
