#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${GITHUB_SHA:?GITHUB_SHA must be set}"

bash ios/patches/apply-patches.sh

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
        "prepared,route,targetCounts,4u,4u,true,true,true",
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
        "candidateFrame->causalPrepared = causalPrepared;",
        "candidateFrame->base.reserve(snapshot.entities.size());",
        "candidateFrame->additive.reserve(snapshot.entities.size());",
        """switch(dispatch.effective) {
        case IOSGPUScenePipelineSelector::Opaque:
          pipelineState =
              (id<MTLRenderPipelineState>)impl->opaquePipelineState;
          break;
        case IOSGPUScenePipelineSelector::AlphaTest:
          pipelineState =
              (id<MTLRenderPipelineState>)impl->alphaTestPipelineState;
          break;
        case IOSGPUScenePipelineSelector::Additive:
          pipelineState =
              (id<MTLRenderPipelineState>)impl->additivePipelineState;
          break;
        case IOSGPUScenePipelineSelector::Multiply2:
          pipelineState =
              (id<MTLRenderPipelineState>)impl->multiply2PipelineState;
          break;
        case IOSGPUScenePipelineSelector::Unsupported:
          break;
        }""",
        "draw.pipelineState = pipelineState;",
        "candidateFrame->targetOrdinal,ordinal",
        "makeIOSGPUSceneCausalDrawIdentity(",
        "iosGPUSceneCausalDrawIdSignpost(identity)",
        "iosGPUSceneCausalDrawBindSignpost(identity)",
        "draw.drawId = OwnedObjectiveC(",
        "draw.drawBind = OwnedObjectiveC(",
        "candidateFrame->additive.emplace_back(std::move(draw));",
        "candidateFrame->base.emplace_back(std::move(draw));",
        "candidateFrame->targetEncodedMarker =",
        "prepared.impl = std::move(candidateFrame);",
        "const auto encodePhase = [&](",
        """[encoder setRenderPipelineState:
          (id<MTLRenderPipelineState>)draw.pipelineState];""",
        "if(context.phase==0u || context.phase==1u) {",
        "encodePhase(context.prepared->base,context.scene->baseDepthState);",
        """encodePhase(context.prepared->multiply2,
                  context.scene->multiply2DepthState);""",
        "context.prepared->nativeBaseMultiplyCompleted = true;",
        "if(context.phase==0u || context.phase==2u) {",
        """encodePhase(context.prepared->additive,
                  context.scene->additiveDepthState);""",
        "context.prepared->nativeAdditiveCompleted = true;",
        """context.prepared->nativeCompleted =
        context.prepared->nativeBaseMultiplyCompleted &&
        context.prepared->nativeAdditiveCompleted;""",
        "context.prepared->nativeException = true;",
        "const bool encoded = Tempest::MetalApi::withActiveRenderEncoder(",
        "context.report.result = Result::NoActiveRenderEncoder;",
        """const bool phaseCompleted = phase==1u
      ? prepared.impl->nativeBaseMultiplyCompleted
      : prepared.impl->nativeCompleted;""",
        "if(prepared.impl->nativeException ||",
        "iosGPUSceneCommitCausalPreparation(",
        "impl->causalState = committed;",
        "prepared.impl->targetEncodedMarker.text.data()",
        "IOSGPUSceneCausalFailureReason::MissingAlphaTestDraw",
    ),
}

expected_draw_operations = [
    "setRenderPipelineState",
    "setVertexBuffer",
    "setVertexBytes",
    "setFragmentTexture",
    "insertDebugSignpost",
    "insertDebugSignpost",
    "drawIndexedPrimitives",
]


def validate(candidate):
    for name, snippets in required_once.items():
        for snippet in snippets:
            if candidate[name].count(snippet) != 1:
                raise ValueError(name + " required-once drift: " + snippet)
    native = candidate["native"]
    header = candidate["header"]
    causal_init_start = native.index(
        "const int* const processArgumentCountAddress = _NSGetArgc();"
    )
    causal_init_end = native.index(
        "Tempest::Log::i(armed.text.data());", causal_init_start
    )
    causal_init = native[causal_init_start:causal_init_end]
    if causal_init.count("_NSGetArgc()") != 1 or \
       causal_init.count("_NSGetArgv()") != 1:
        raise ValueError("causal process argv is not parsed exactly once")
    if native.count("Tempest::Log::e(marker.text.data());") != 2:
        raise ValueError("parse/runtime FAIL log sites drifted")
    parse_order = (
        causal_init.index("_NSGetArgc()"),
        causal_init.index("_NSGetArgv()"),
        causal_init.index("iosGPUSceneParseCausalArguments("),
        causal_init.index("causalArgumentsAccepted = true;"),
    )
    if tuple(sorted(parse_order)) != parse_order:
        raise ValueError("causal argv/ARMED order drifted")
    prepare_start = native.index(
        "IOSGPUScene::Report IOSGPUScene::prepareFrame("
    )
    bridge_start = native.index(
        "IOSGPUScene::Report IOSGPUScene::encodePrepared("
    )
    prepare = native[prepare_start:bridge_start]
    prepare_order = tuple(
        prepare.index(token)
        for token in (
            "iosGPUScenePrepareCausalObservation(",
            "for(const auto& entity:snapshot.entities)",
            "recordIOSGPUSceneDrawDispatchForRoute(",
            "makeIOSGPUSceneCausalDrawIdentity(",
            "iosGPUSceneCausalDrawIdSignpost(identity)",
            "iosGPUSceneCausalDrawBindSignpost(identity)",
            "draw.drawId = OwnedObjectiveC(",
            "draw.drawBind = OwnedObjectiveC(",
            "candidateFrame->additive.emplace_back(std::move(draw));",
            "iosGPUSceneCausalPreparationIsValid(",
            "candidateFrame->targetEncodedMarker =",
            "candidateFrame->ready = true;",
            "prepared.impl = std::move(candidateFrame);",
        )
    )
    if tuple(sorted(prepare_order)) != prepare_order:
        raise ValueError("causal frozen preparation order drifted")
    if prepare.count("for(const auto& entity:snapshot.entities)") != 1:
        raise ValueError("frozen source-order entity loop drifted")
    if "startEncoding" in prepare or \
       "withActiveRenderEncoder" in prepare:
        raise ValueError("native bridge leaked into prepareFrame")

    native_start = native.index(
        "void IOSGPUScene::Impl::encodeLandscape("
    )
    native_end = native.index("IOSGPUScene::IOSGPUScene(", native_start)
    native_encode = native[native_start:native_end]
    phase_start = native_encode.index("const auto encodePhase = [&](")
    loop_start = native_encode.index("for(const auto& draw:", phase_start)
    loop_end = native_encode.index("\n    };", loop_start)
    draw_loop = native_encode[loop_start:loop_end]
    operations = re.findall(r"\[encoder ([A-Za-z]+)", draw_loop)
    if operations != expected_draw_operations:
        raise ValueError("frozen native draw operation order drifted")
    if draw_loop.index(
        "[encoder insertDebugSignpost:(NSString*)draw.drawId.get()]"
    ) > draw_loop.index(
        "[encoder insertDebugSignpost:(NSString*)draw.drawBind.get()]"
    ):
        raise ValueError("target draw-id/draw-bind order drifted")
    phase_order = (
        native_encode.index(
            "encodePhase(context.prepared->base,context.scene->baseDepthState);"
        ),
        native_encode.index("encodePhase(context.prepared->multiply2,"),
        native_encode.index(
            "context.prepared->nativeBaseMultiplyCompleted = true;"
        ),
        native_encode.index("encodePhase(context.prepared->additive,"),
        native_encode.index(
            "context.prepared->nativeAdditiveCompleted = true;"
        ),
        native_encode.index("context.prepared->nativeCompleted ="),
    )
    if tuple(sorted(phase_order)) != phase_order:
        raise ValueError("base/Multiply2/Additive frozen phase order drifted")
    exception_start = native_encode.index("@catch(NSException* exception)")
    exception_order = (
        exception_start,
        native_encode.index(
            "context.prepared->nativeException = true;", exception_start
        ),
        native_encode.index(
            "context.report.result = IOSGPUScene::Result::NativeEncodingFailed;",
            exception_start,
        ),
        native_encode.index(
            "recordFailure(context.report.failures.nativeEncode,context.report);",
            exception_start,
        ),
    )
    if tuple(sorted(exception_order)) != exception_order:
        raise ValueError("native exception failure order drifted")

    phase_bridge_start = native.index(
        "IOSGPUScene::Report IOSGPUScene::encodePreparedPhase("
    )
    finish = native[phase_bridge_start:]
    bridge = finish.index(
        "const bool encoded = Tempest::MetalApi::withActiveRenderEncoder("
    )
    no_encoder = finish.index("if(!encoded)")
    native_catch = finish.index("catch(...)")
    successful_bridge = finish.index(
        "if(prepared.impl->nativeException ||"
    )
    commit = finish.index("iosGPUSceneCommitCausalPreparation(")
    if not bridge < no_encoder < native_catch < successful_bridge < commit:
        raise ValueError("bridge/failure/commit order drifted")
    no_encoder_block = finish[no_encoder:native_catch]
    if "IOSGPUSceneCausalFailureReason::NoActiveRenderEncoder" not in \
       no_encoder_block or "return context.report;" not in no_encoder_block:
        raise ValueError("no-active-encoder failure is not terminal")
    catch_block = finish[native_catch:successful_bridge]
    if "IOSGPUSceneCausalFailureReason::NativeException" not in \
       catch_block or "return context.report;" not in catch_block:
        raise ValueError("native bridge exception is not terminal")
    success_guard = finish[successful_bridge:commit]
    for token in (
        "prepared.impl->nativeException",
        "!phaseCompleted",
        "context.report.result!=Result::Success",
        "return context.report;",
    ):
        if token not in success_guard:
            raise ValueError("successful bridge guard drifted: " + token)
    finish_order = (
        commit,
        finish.index("impl->causalState = committed;"),
        finish.index("prepared.impl->targetEncodedMarker.text.data()"),
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

def replace_legacy_native_encode(source: str, old: str, new: str) -> str:
    start = source.index("void IOSGPUScene::Impl::encodeLandscape(")
    end = source.index("IOSGPUScene::IOSGPUScene(", start)
    block = source[start:end]
    if block.count(old) != 1:
        raise ValueError("legacy native mutation anchor drifted: " + old)
    return source[:start] + block.replace(old, new, 1) + source[end:]

for operation in (
    "[encoder insertDebugSignpost:(NSString*)draw.drawId.get()];",
    "[encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];",
    """[encoder setRenderPipelineState:
          (id<MTLRenderPipelineState>)draw.pipelineState];""",
    "[encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle",
):
    mutant = dict(sources)
    mutant["native"] = replace_legacy_native_encode(native, operation, "")
    mutations.append(mutant)
    mutant = dict(sources)
    mutant["native"] = replace_legacy_native_encode(
        native, operation, operation + "\n" + operation
    )
    mutations.append(mutant)
mutant = dict(sources)
mutant["native"] = replace_legacy_native_encode(
    native,
    """[encoder insertDebugSignpost:(NSString*)draw.drawId.get()];
        [encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];""",
    """[encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];
        [encoder insertDebugSignpost:(NSString*)draw.drawId.get()];""",
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
    (
        """if(context.phase==0u || context.phase==1u) {
      encodePhase(context.prepared->base,context.scene->baseDepthState);
      encodePhase(context.prepared->multiply2,
                  context.scene->multiply2DepthState);
      context.prepared->nativeBaseMultiplyCompleted = true;
      }
    if(context.phase==0u || context.phase==2u) {
      encodePhase(context.prepared->additive,
                  context.scene->additiveDepthState);
      context.prepared->nativeAdditiveCompleted = true;
      }""",
        """if(context.phase==0u || context.phase==2u) {
      encodePhase(context.prepared->additive,
                  context.scene->additiveDepthState);
      context.prepared->nativeAdditiveCompleted = true;
      }
    if(context.phase==0u || context.phase==1u) {
      encodePhase(context.prepared->base,context.scene->baseDepthState);
      encodePhase(context.prepared->multiply2,
                  context.scene->multiply2DepthState);
      context.prepared->nativeBaseMultiplyCompleted = true;
      }""",
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
  if(target)
    Tempest::Log::i(
        prepared.impl->targetEncodedMarker.text.data());""",
    """if(target)
    Tempest::Log::i(
        prepared.impl->targetEncodedMarker.text.data());
  impl->causalState = committed;""",
    1,
)
mutations.append(mutant)
killed = 0
for mutation_index, mutation in enumerate(mutations):
    try:
        validate(mutation)
    except ValueError:
        killed += 1
    else:
        raise SystemExit(
            "P2.1c3b3c host/source mutation survived: "
            + str(mutation_index)
        )
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
    """if(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE
       STREQUAL "causal-a")""",
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1",
    """elseif(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE
         STREQUAL "causal-b")""",
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1",
    "RendererIOS native AlphaTest causal A/B builds require ",
    "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON",
    "OPENGOTHIC_RENDERER_IOS_FAULT_MODE=none",
    "exclusive with all other RendererIOS self-tests",
)
additive_contract = (
    'set(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE "none"',
    "PROPERTY STRINGS ${_renderer_ios_additive_causal_modes}",
    "_renderer_ios_additive_causal_mode_index EQUAL -1",
    "OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A=1",
    "OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B=1",
    "RendererIOS Additive causal A/B requires the exact diagnostics=ON, ",
    """NOT OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE
           STREQUAL "none" OR
       NOT OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE STREQUAL "none" OR
       NOT OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE OR""",
    "native AlphaTest, Additive, and Multiply2 causal modes are mutually exclusive",
)
multiply2_contract = (
    'set(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE "none"',
    "PROPERTY STRINGS ${_renderer_ios_multiply2_causal_modes}",
    "_renderer_ios_multiply2_causal_mode_index EQUAL -1",
    "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1",
    "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B=1",
    "RendererIOS Multiply2 causal A/B requires the exact diagnostics=ON, ",
    """NOT OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE
           STREQUAL "none" OR
       NOT OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE STREQUAL "none" OR
       NOT OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE OR""",
    "fault=none, AlphaTest-causal=none, Additive-causal=none, ",
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
    for literal in additive_contract:
        if literal not in candidate_cmake:
            raise ValueError("Additive CMake source contract drifted: " + literal)
    for literal in multiply2_contract:
        if literal not in candidate_cmake:
            raise ValueError("Multiply2 CMake source contract drifted: " + literal)
    if (
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST"
        in candidate_cmake
    ):
        raise ValueError("HOST_TEST leaked into product CMake")
    configure_presets = candidate_presets["configurePresets"]
    expected_names = [
        "renderer-ios-base",
        "renderer-ios-off",
        "renderer-ios-on",
        "renderer-ios-tile",
        "renderer-ios-forward",
        "renderer-ios-hdr-triple",
        "renderer-ios-additive-a-hdr",
        "renderer-ios-additive-b-hdr",
        "renderer-ios-multiply2-a-hdr",
        "renderer-ios-multiply2-b-hdr",
        "renderer-ios-causal-none",
        "renderer-ios-causal-a",
        "renderer-ios-causal-b",
    ]
    if [item["name"] for item in configure_presets] != expected_names:
        raise ValueError("causal configure preset set/order drifted")
    configure = {
        item["name"]: item
        for item in configure_presets
    }
    base_cache = configure["renderer-ios-base"]["cacheVariables"]
    if base_cache.get(
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE"
    ) != "none":
        raise ValueError("ordinary preset base is not explicit none")
    if base_cache.get(
        "OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE"
    ) != "none":
        raise ValueError("ordinary preset base Additive mode is not explicit none")
    if base_cache.get(
        "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE"
    ) != "none":
        raise ValueError("ordinary preset base Multiply2 mode is not explicit none")
    if base_cache.get(
        "OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE"
    ) != "OFF":
        raise ValueError("ordinary preset base capture gate is not OFF")
    hdr_triple = configure["renderer-ios-hdr-triple"]
    if hdr_triple.get("inherits") != "renderer-ios-base":
        raise ValueError("hdr-triple does not inherit base")
    if hdr_triple.get("binaryDir") != (
        "${sourceDir}/build/local-renderer-ios-hdr-triple"
    ):
        raise ValueError("hdr-triple binaryDir drifted")
    expected_hdr_triple_cache = {
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
    if hdr_triple.get("cacheVariables") != expected_hdr_triple_cache:
        raise ValueError("hdr-triple exact capture tuple drifted")
    for suffix, mode in (
        ("additive-a-hdr", "causal-a"),
        ("additive-b-hdr", "causal-b"),
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
            "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE": "none",
            "OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE": mode,
            "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE": "ON",
        }
        if preset.get("cacheVariables") != expected_cache:
            raise ValueError(suffix + " exact cache tuple drifted")
    for suffix, mode in (
        ("multiply2-a-hdr", "causal-a"),
        ("multiply2-b-hdr", "causal-b"),
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
            "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE": "none",
            "OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE": "none",
            "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE": mode,
            "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE": "ON",
        }
        if preset.get("cacheVariables") != expected_cache:
            raise ValueError(suffix + " exact cache tuple drifted")
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
        "renderer-ios-hdr-triple",
        "renderer-ios-additive-a-hdr",
        "renderer-ios-additive-b-hdr",
        "renderer-ios-multiply2-a-hdr",
        "renderer-ios-multiply2-b-hdr",
        "renderer-ios-causal-none",
        "renderer-ios-causal-a",
        "renderer-ios-causal-b",
    ]:
        raise ValueError("causal build preset order drifted")
    for literal in (
        "RAW_ACTIVE_FAULT_MODE_SET",
        "RAW_ADDITIVE_CAUSAL_MODE_SET",
        'RAW_MULTIPLY2_CAUSAL_MODE_SET="${MULTIPLY2_CAUSAL_MODE+x}"',
        "reject_causal_raw_conflict",
        '-DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE="$CAUSAL_MODE"',
        '-DOPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE="$ADDITIVE_CAUSAL_MODE"',
        '-DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE="$MULTIPLY2_CAUSAL_MODE"',
        "causal PBX global definitions drifted",
        "Multiply2 causal PBX global definitions drifted",
        "RendererIOS causal binary oracle:",
    ):
        if literal not in candidate_profile:
            raise ValueError("causal CI profile contract drifted: " + literal)
    for literal in (
        "causal-none|causal-a|causal-b",
        "additive-a-hdr|additive-b-hdr",
        "multiply2-a-hdr|multiply2-b-hdr",
        "RendererIOS Additive causal PBX oracle:",
        "RendererIOS causal PBX oracle:",
        "RendererIOS causal binary oracle:",
        "causal-invalid-non-ios",
        "RIOS_MULTIPLY2_CAUSAL_MODE=",
    ):
        if literal not in candidate_local:
            raise ValueError("causal local profile contract drifted: " + literal)


validate_sources(cmake, presets, profile, local)
source_mutations = []
for literal in cmake_contract[:8]:
    source_mutations.append(
        (cmake.replace(literal, "C3B3B_MUTANT", 1), presets, profile, local)
    )
for literal in additive_contract:
    source_mutations.append(
        (cmake.replace(literal, "E1B_MUTANT", 1), presets, profile, local)
    )
for literal in multiply2_contract:
    source_mutations.append(
        (cmake.replace(literal, "E2B_MUTANT", 1), presets, profile, local)
    )
mutated = deepcopy(presets)
del mutated["configurePresets"][0]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE"
]
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
del mutated["configurePresets"][0]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE"
]
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][10]["binaryDir"] = (
    "${sourceDir}/build/local-renderer-ios-causal-a"
)
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][11]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE"
] = "none"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][12]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST"
] = "ON"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][10]["environment"]["PACKAGE_DEVICE_IPA"] = "1"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][0]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE"
] = "ON"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][5]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE"
] = "OFF"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][8]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE"
] = "none"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][9]["cacheVariables"][
    "OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE"
] = "causal-a"
source_mutations.append((cmake, mutated, profile, local))
mutated = deepcopy(presets)
mutated["configurePresets"][8]["environment"]["PACKAGE_DEVICE_IPA"] = "1"
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
            'RAW_MULTIPLY2_CAUSAL_MODE_SET="${MULTIPLY2_CAUSAL_MODE+x}"',
            "RAW_MULTIPLY2_MODE_REMOVED=1",
            1,
        ),
        local,
    )
)
source_mutations.append(
    (
        cmake,
        presets,
        profile.replace(
            '-DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE="$MULTIPLY2_CAUSAL_MODE"',
            "-DMULTIPLY2_CAUSAL_MODE=none",
            1,
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
source_mutations.append(
    (
        cmake,
        presets,
        profile,
        local.replace(
            "multiply2-a-hdr|multiply2-b-hdr",
            "multiply2-profiles-removed",
            1,
        ),
    )
)
killed = 0
for mutation_index, mutation in enumerate(source_mutations):
    try:
        validate_sources(*mutation)
    except ValueError:
        killed += 1
    else:
        raise SystemExit(
            "causal source mutation survived: " + str(mutation_index)
        )
if killed != 41:
    raise SystemExit("causal source mutation count drifted")
print("RendererIOS causal/Additive/Multiply2 source oracle: mutations-killed=41")
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

ADDITIVE_CONTRACT_ROOT="$RUNNER_TEMP/renderer-ios-additive-contracts"
expect_additive_contract_configure_failure() {
  local profile="$1"
  local name="$2"
  shift 2
  local build="$ADDITIVE_CONTRACT_ROOT/invalid-$profile-$name"
  if cmake --preset "renderer-ios-$profile" -B "$build" \
      "$@" >/dev/null 2>&1; then
    echo "invalid Additive configure survived: $profile/$name"
    exit 1
  fi
}

expect_additive_contract_configure_failure additive-a-hdr unknown-mode \
  -DOPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE=unknown
for additive_profile_under_test in additive-a-hdr additive-b-hdr; do
  expect_additive_contract_configure_failure \
    "$additive_profile_under_test" diagnostics-off \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=OFF
  expect_additive_contract_configure_failure \
    "$additive_profile_under_test" fault \
    -DOPENGOTHIC_RENDERER_IOS_FAULT_MODE=post-submit-suboptimal
  expect_additive_contract_configure_failure \
    "$additive_profile_under_test" alpha-causal \
    -DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE=causal-a
  expect_additive_contract_configure_failure \
    "$additive_profile_under_test" triple-off \
    -DOPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE=OFF
  for option in \
      BINK_SELF_TEST \
      RESOURCE_ALLOCATOR_SELF_TEST \
      CLEAR_ONLY_PASS_SELF_TEST \
      SHADING_PROTOTYPE_TILE_SELF_TEST \
      SHADING_PROTOTYPE_FORWARD_SELF_TEST; do
    expect_additive_contract_configure_failure \
      "$additive_profile_under_test" "$option" \
      "-DOPENGOTHIC_RENDERER_IOS_${option}=ON"
  done
done
for additive_mode_under_test in causal-a causal-b; do
  if cmake -S "$PWD" \
      -B "$ADDITIVE_CONTRACT_ROOT/invalid-non-ios-$additive_mode_under_test" \
      -DOPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_MODE="$additive_mode_under_test" \
      >/dev/null 2>&1; then
    echo "non-iOS Additive configure survived: $additive_mode_under_test"
    exit 1
  fi
done

printf '\nRendererIOS causal contracts passed exactly once\n'
