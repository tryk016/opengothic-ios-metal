#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO"
TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/renderer-ios-multiply2-contract.$$"
mkdir -m 700 "$TMP_ROOT"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

compile_and_run() {
  local output="$1"
  shift
  xcrun clang++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    "$@" -o "$output"
  codesign -f -s - "$output" >/dev/null
  "$output"
}

for sanitizer in plain asan ubsan; do
  sanitizer_flags=(-fno-omit-frame-pointer)
  [[ "$sanitizer" != asan ]] ||
    sanitizer_flags=(-fsanitize=address -fno-omit-frame-pointer)
  [[ "$sanitizer" != ubsan ]] ||
    sanitizer_flags=(-fsanitize=undefined -fno-sanitize-recover=undefined
                     -fno-omit-frame-pointer)
  compile_and_run "$TMP_ROOT/input-$sanitizer" \
    "${sanitizer_flags[@]}" -Igame \
    ios/tests/iosmultiply2inputartifact.cpp \
    game/graphics/iosmultiply2inputartifact.cpp
  compile_and_run "$TMP_ROOT/coverage-$sanitizer" \
    "${sanitizer_flags[@]}" -Igame \
    ios/tests/iosmultiply2coverageproof.cpp \
    game/graphics/iosmultiply2coverageproof.cpp
done

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  ios.tests.test_multiply2_coverage_proof \
  ios.tests.test_multiply2_draw_evidence

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame ios/tests/iosmultiply2runtimecontract.cpp \
  -o "$TMP_ROOT/runtime"
codesign -f -s - "$TMP_ROOT/runtime" >/dev/null
"$TMP_ROOT/runtime" "$REPO"
compile_and_run "$TMP_ROOT/plan-a" \
  -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1 \
  -Igame ios/tests/iosgpusceneplan.cpp
compile_and_run "$TMP_ROOT/plan-b" \
  -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B=1 \
  -Igame ios/tests/iosgpusceneplan.cpp
if xcrun clang++ -std=c++20 -Wall -Wextra -Werror \
    -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1 \
    -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B=1 \
    -Igame -fsyntax-only ios/tests/iosgpusceneplan.cpp \
    >/dev/null 2>&1; then
  echo "Multiply2 causal macro conflict survived" >&2
  exit 1
fi

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
for variant in A B; do
  xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 -isysroot "$IOS_SDK" \
    -fno-objc-arc \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
    -DOPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE=1 \
    -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_${variant}=1 \
    -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=\"0000000000000000000000000000000000000000\" \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -isystem lib/Tempest/Engine/include \
    -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
    -isystem lib/ZenKit/include \
    -fsyntax-only game/graphics/iosgpuscene.mm
done
for variant in A B; do
  xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 -isysroot "$IOS_SDK" \
    -fno-objc-arc \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
    -DOPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE=1 \
    -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_${variant}=1 \
    -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC=1 \
    -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=\"0000000000000000000000000000000000000000\" \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -isystem lib/Tempest/Engine/include \
    -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
    -isystem lib/ZenKit/include \
    -fsyntax-only game/graphics/iosgpuscene.mm
done
xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 -isysroot "$IOS_SDK" \
  -fno-objc-arc \
  -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1 \
  -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC=1 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include \
  -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iosmultiply2coverageproof.mm
if xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 -isysroot "$IOS_SDK" \
    -fno-objc-arc \
    -DOPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC=1 \
    -Igame -isystem lib/Tempest/Engine/include \
    -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
    -isystem lib/ZenKit/include \
    -fsyntax-only game/graphics/iosgpuscene.mm >/dev/null 2>&1; then
  echo "Multiply2 visibility diagnostic survived without causal A/B" >&2
  exit 1
fi

python3 - "$REPO" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
texts = {
    "cmake": (root / "CMakeLists.txt").read_text(),
    "presets": (root / "CMakePresets.json").read_text(),
    "scene": (root / "game/graphics/iosgpuscene.mm").read_text(),
    "context": (root / "game/graphics/iosmetalcontext.cpp").read_text(),
    "header": (root / "game/graphics/iosgpuscene.h").read_text(),
    "coverage-h": (root / "game/graphics/iosmultiply2coverageproof.h").read_text(),
    "coverage-cpp": (root / "game/graphics/iosmultiply2coverageproof.cpp").read_text(),
    "coverage-mm": (root / "game/graphics/iosmultiply2coverageproof.mm").read_text(),
    "hdr-h": (root / "game/graphics/ioslinearhdrproofproducer.h").read_text(),
    "hdr-mm": (root / "game/graphics/ioslinearhdrproofproducer.mm").read_text(),
    "runner": (root / "ios/device-test/run-linear-hdr-proof-test.sh").read_text(),
    "validator": (root / "ios/device-test/validate-multiply2-coverage-proof.py").read_text(),
    "draw-collector": (root / "ios/device-test/collect-multiply2-draw-evidence.py").read_text(),
    "local-gate": (root / "scripts/verify-local-build.command").read_text(),
}

requirements = {
    "mode-a": ("cmake", "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1", 1),
    "mode-b": ("cmake", "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B=1", 1),
    "preset-a": ("presets", "renderer-ios-multiply2-a-hdr", 4),
    "preset-b": ("presets", "renderer-ios-multiply2-b-hdr", 4),
    "rgb-a": ("scene", "additiveColor.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;", 1),
    "rgb-b": ("scene", "additiveColor.sourceRGBBlendFactor = MTLBlendFactorZero;", 2),
    "depth-target": ("context", "IOSGPUScene::DepthFormat::Depth32FloatStencil8", 1),
    "stencil-format": ("scene", "pipelineDesc.stencilAttachmentPixelFormat    = depthFormat;", 1),
    "stencil-always": ("scene", "stencilDesc.stencilCompareFunction = MTLCompareFunctionAlways;", 1),
    "stencil-replace": ("scene", "stencilDesc.depthStencilPassOperation = MTLStencilOperationReplace;", 1),
    "stencil-read-mask": ("scene", "stencilDesc.readMask = 0xffu;", 1),
    "stencil-write-mask": ("scene", "stencilDesc.writeMask = 0xffu;", 1),
    "first-marker": ("scene", "RendererIOS.Multiply2.BaseAndCausal.v1", 1),
    "proof-marker": ("scene", "RendererIOS.HDRProofCopy.Multiply2.v1", 1),
    "coverage-marker": ("scene", "RendererIOS.Multiply2.CoverageStencilCopy.v1", 2),
    "stencil-blit": ("scene", "options:MTLBlitOptionStencilFromDepthStencil", 1),
    "second-marker": ("scene", "RendererIOS.Multiply2.AdditiveAfterProof.v1", 2),
    "coverage-metadata": ("scene", "bool IOSGPUScene::multiply2CoverageMetadata(", 1),
    "causal-entry": ("scene", "IOSGPUScene::Report IOSGPUScene::encodePreparedMultiply2Causal(", 1),
    "continuation-api": ("header", "Report encodePreparedMultiply2Continuation(", 1),
    "explicit-mode": ("scene", "enum class NativeMultiply2EncodeMode : uint8_t", 1),
    "capture-mode": ("scene", "Impl::NativeMultiply2EncodeMode::CaptureProof", 1),
    "continuation-mode": ("scene", "Impl::NativeMultiply2EncodeMode::Continuation", 1),
    "proofless-mode": ("scene", "continuation && context.hdrProofBuffer==nil", 1),
    "proofless-coverage": ("scene", "context.coverageBuffer==nil && context.hdrBytesPerRow==0u", 1),
    "proofless-pitches": ("scene", "context.coverageBytesPerRow==0u && context.sceneMarker.empty()", 1),
    "proofless-markers": ("scene", "context.proofMarker.empty();", 1),
    "capture-proof-resources": ("scene", "context.hdrProofBuffer!=nil && context.coverageBuffer!=nil", 1),
    "capture-proof-pitches": ("scene", "context.hdrBytesPerRow==context.width*4u", 1),
    "capture-only-blits": ("scene", "if(captureProof) {\n        blitEncoder = [command blitCommandEncoder];", 1),
    "shared-native-callback": ("scene", "&Impl::encodeMultiply2", 1),
    "continuation-depth-format": ("scene", "textureDescriptor.pixelFormat =\n            MTLPixelFormatDepth32Float_Stencil8;", 1),
    "continuation-sample": ("scene", "textureDescriptor.sampleCount = 1u;", 1),
    "continuation-private": ("scene", "MTLResourceStorageModePrivate |", 1),
    "continuation-default-cache": ("scene", "MTLResourceCPUCacheModeDefaultCache |", 1),
    "continuation-tracked": ("scene", "MTLResourceHazardTrackingModeTracked;", 1),
    "continuation-render-target": ("scene", "textureDescriptor.usage = MTLTextureUsageRenderTarget;", 1),
    "continuation-allocation": ("scene", "[device newTextureWithDescriptor:textureDescriptor]", 1),
    "continuation-cache-store": ("scene", "multiply2ContinuationDepthStencil = allocated.relinquish();", 1),
    "continuation-cache-release": ("scene", "[multiply2ContinuationDepthStencil release];", 2),
    "continuation-cache-mismatch": ("scene", "else if(!validContinuationTarget(target))", 1),
    "continuation-first-label": ("scene", "RendererIOS.Multiply2.BaseAndContinuation.v1", 3),
    "continuation-second-label": ("scene", "RendererIOS.Multiply2.AdditiveContinuation.v1", 3),
    "admission-helper": ("context", "constexpr IOSMultiply2SceneAdmission iosMultiply2SceneAdmission(", 1),
    "admission-armed": ("context", "hdr==IOSLinearHDRProofProducerState::Armed &&\n     coverage==IOSMultiply2CoverageProducerState::Armed", 1),
    "admission-submitted": ("context", "hdr==IOSLinearHDRProofProducerState::Submitted &&\n      coverage==IOSMultiply2CoverageProducerState::Submitted", 1),
    "admission-published": ("context", "hdr==IOSLinearHDRProofProducerState::Published &&\n      coverage==IOSMultiply2CoverageProducerState::Published", 1),
    "admission-capture-result": ("context", "return IOSMultiply2SceneAdmission::CaptureProof;", 1),
    "admission-continuation-result": ("context", "return IOSMultiply2SceneAdmission::Continuation;", 1),
    "admission-reject-result": ("context", "return IOSMultiply2SceneAdmission::Reject;", 1),
    "admission-producers": ("context", "const bool multiply2CausalProducersPresent =", 1),
    "admission-absent-hdr": ("context", ": IOSLinearHDRProofProducerState::Disabled;", 1),
    "admission-absent-coverage": ("context", ": IOSMultiply2CoverageProducerState::Disabled;", 1),
    "admission-capture-route": ("context", "multiply2Admission==IOSMultiply2SceneAdmission::CaptureProof;", 1),
    "admission-reject": ("context", "if(multiply2Admission==IOSMultiply2SceneAdmission::Reject)", 1),
    "continuation-entry": ("context", "impl->gpuScene->encodePreparedMultiply2Continuation(", 1),
    "hdr-view": ("context", "impl->linearHDRProof->nativeCopyView(", 1),
    "coverage-prepare": ("context", "impl->multiply2Coverage->prepareFrame(", 1),
    "coverage-encoded": ("context", "impl->multiply2Coverage->markEncoded(", 1),
    "coverage-submitted": ("context", "impl->multiply2Coverage->markSubmitted(", 1),
    "coverage-terminal": ("context", "multiply2Coverage->completeAfterTerminal(", 1),
    "magic": ("coverage-cpp", "std::byte{'M'},std::byte{'C'},std::byte{'9'},std::byte{0}", 1),
    "header-160": ("coverage-h", "IOSMultiply2CoverageProofV1HeaderBytes = 160u", 1),
    "payload-domain": ("coverage-cpp", "if(byte>1u)", 1),
    "coverage-required": ("coverage-cpp", "IOSMultiply2CoverageProofError::MissingCoverage", 1),
    "payload-invalid-byte": ("coverage-mm", 'fail("payload-invalid-byte");', 1),
    "payload-missing-coverage": ("coverage-mm", 'fail("payload-missing-coverage");', 1),
    "payload-build": ("coverage-mm", 'fail("payload-build");', 1),
    "private-ds": ("coverage-mm", "MTLPixelFormatDepth32Float_Stencil8", 2),
    "final-leaf": ("coverage-mm", "RendererIOS-multiply2-coverage-v1.bin", 1),
    "visibility-option": ("cmake", "OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC", 4),
    "visibility-option-default-off": ("cmake", '"Run one diagnostics-only Multiply2 GPU visibility classification" OFF)', 1),
    "visibility-option-causal-only": ("cmake", '"RendererIOS Multiply2 GPU visibility diagnostic requires causal-a or causal-b"', 1),
    "visibility-result-bytes": ("coverage-h", "IOSMultiply2VisibilityResultBytes = 32u", 1),
    "visibility-production-offset": ("coverage-h", "IOSMultiply2VisibilityProductionOffset = 0u", 1),
    "visibility-raster-offset": ("coverage-h", "IOSMultiply2VisibilityRasterOffset = 8u", 1),
    "visibility-stencil-offset": ("coverage-h", "IOSMultiply2VisibilityStencilOffset = 16u", 1),
    "visibility-clip-offset": ("coverage-h", "IOSMultiply2VisibilityClipClassOffset = 24u", 1),
    "visibility-production-sentinel": ("coverage-h", "0xd1a6000000000001ull", 1),
    "visibility-raster-sentinel": ("coverage-h", "0xd1a6000000000002ull", 1),
    "visibility-stencil-sentinel": ("coverage-h", "0xd1a6000000000003ull", 1),
    "visibility-classifier": ("coverage-cpp", "iosClassifyMultiply2VisibilityDiagnostic(", 1),
    "visibility-canonical-consistency": ("coverage-cpp", "if(canonicalCoverage &&\n     (!result.raster || !result.production || !result.stencil))", 1),
    "visibility-impossible-production": ("coverage-cpp", "if((result.production && !result.raster) ||", 1),
    "visibility-impossible-stencil": ("coverage-cpp", "(result.stencil && !result.production))", 1),
    "visibility-class-outside": ("coverage-cpp", 'return "definitely-outside-frustum";', 1),
    "visibility-class-nonraster": ("coverage-cpp", 'return "non-rasterized-unknown";', 1),
    "visibility-class-depth": ("coverage-cpp", 'return "all-depth-rejected";', 1),
    "visibility-class-stencil-write": ("coverage-cpp", 'return "stencil-write-missing";', 1),
    "visibility-class-stencil-loss": ("coverage-cpp", 'return "stencil-blit-or-readback-loss";', 1),
    "visibility-class-invalid": ("coverage-cpp", 'return "diagnostic-invalid";', 2),
    "visibility-buffer-owner": ("coverage-mm", "Tempest::StorageBuffer visibilityBuffer;", 2),
    "visibility-buffer-shared": ("coverage-mm", "nativeVisibility.storageMode!=MTLStorageModeShared", 1),
    "visibility-buffer-label": ("coverage-mm", "RendererIOS.Multiply2.VisibilityResult.v1", 1),
    "visibility-terminal-c": ("coverage-mm", "RendererIOS multiply2 visibility: v=1 terminal=C class=", 1),
    "visibility-terminal-f": ("coverage-mm", "RendererIOS multiply2 visibility: v=1 terminal=F class=diagnostic-invalid", 1),
    "visibility-pso-mask": ("scene", "additiveColor.writeMask = MTLColorWriteMaskNone;", 1),
    "visibility-pso-label": ("scene", "RendererIOS.Static.Multiply2.Visibility.v1", 1),
    "visibility-depth-always": ("scene", "depthDesc.depthCompareFunction = MTLCompareFunctionAlways;", 1),
    "visibility-depth-write-off": ("scene", "depthDesc.depthWriteEnabled = NO;", 2),
    "visibility-stencil-equal": ("scene", "visibilityStencilDesc.stencilCompareFunction = MTLCompareFunctionEqual;", 1),
    "visibility-stencil-failure-keep": ("scene", "visibilityStencilDesc.stencilFailureOperation = MTLStencilOperationKeep;", 1),
    "visibility-stencil-depth-failure-keep": ("scene", "visibilityStencilDesc.depthFailureOperation = MTLStencilOperationKeep;", 1),
    "visibility-stencil-keep": ("scene", "visibilityStencilDesc.depthStencilPassOperation = MTLStencilOperationKeep;", 1),
    "visibility-stencil-read-mask": ("scene", "visibilityStencilDesc.readMask = 0xffu;", 1),
    "visibility-stencil-write-mask": ("scene", "visibilityStencilDesc.writeMask = 0u;", 1),
    "visibility-first-buffer": ("scene", "first.visibilityResultBuffer = visibilityResultBuffer;", 1),
    "visibility-query-boolean": ("scene", "MTLVisibilityResultModeBoolean", 3),
    "visibility-query-disabled": ("scene", "MTLVisibilityResultModeDisabled", 3),
    "visibility-production-query": ("scene", "IOSMultiply2VisibilityProductionOffset", 1),
    "visibility-pass-label": ("scene", "RendererIOS.Multiply2.VisibilityDiagnostic.v1", 2),
    "visibility-raster-query": ("scene", "IOSMultiply2VisibilityRasterOffset", 1),
    "visibility-stencil-query": ("scene", "IOSMultiply2VisibilityStencilOffset", 1),
    "visibility-pass-attachments": ("scene", "visibilityPass.colorAttachments[0].texture = sceneHDR;\n        visibilityPass.colorAttachments[0].loadAction = MTLLoadActionLoad;\n        visibilityPass.colorAttachments[0].storeAction = MTLStoreActionStore;\n        visibilityPass.depthAttachment.texture = depthStencil;\n        visibilityPass.depthAttachment.loadAction = MTLLoadActionLoad;\n        visibilityPass.depthAttachment.storeAction = MTLStoreActionStore;\n        visibilityPass.stencilAttachment.texture = depthStencil;\n        visibilityPass.stencilAttachment.loadAction = MTLLoadActionLoad;\n        visibilityPass.stencilAttachment.storeAction = MTLStoreActionStore;", 1),
    "visibility-pass-raster-state": ("scene", "context.scene->multiply2VisibilityRasterDepthState", 1),
    "visibility-pass-stencil-state": ("scene", "context.scene->multiply2VisibilityStencilDepthState", 1),
    "visibility-pass-bindings": ("scene", "const auto& draw = context.prepared->multiply2.front();\n        [renderEncoder setRenderPipelineState:\n            (id<MTLRenderPipelineState>)\n                context.scene->multiply2VisibilityPipelineState];\n        bindGeometry(renderEncoder,draw);\n        [renderEncoder setFragmentTexture:\n            (id<MTLTexture>)draw.baseColorTexture atIndex:0u];", 1),
    "visibility-pass-fixed-state": ("scene", "[renderEncoder setViewport:viewport];\n        [renderEncoder setScissorRect:scissor];\n        [renderEncoder setFrontFacingWinding:MTLWindingClockwise];\n        [renderEncoder setCullMode:MTLCullModeFront];", 1),
    "visibility-pass-indexed-draws": ("scene", "[renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle", 3),
    "visibility-production-state": ("scene", "(id<MTLDepthStencilState>)context.scene->multiply2DepthState];", 1),
    "visibility-production-draw": ("scene", "indexCount:productionDraw.plan.indexCount", 1),
    "visibility-single-target-admission": ("scene", "prepared.impl->multiply2.size()!=1u ||\n     hdrProof.sourceTexture==nullptr", 1),
    "visibility-metadata-admission": ("scene", "coverage.metadata.visibilityClipClass!=\n         prepared.impl->multiply2.front().visibilityClipClass", 1),
    "visibility-empty-canonical-flow": ("coverage-mm", "#endif\n    if(hasInvalidCoverageByte) {\n      fail(\"payload-invalid-byte\");\n      return false;\n    }\n    if(!hasCoverage) {\n      fail(\"payload-missing-coverage\");", 1),
    "hdr-native-view": ("hdr-h", "struct IOSLinearHDRProofNativeView final", 1),
    "hdr-native-transition": ("hdr-mm", "markNativeCopyEncoded", 4),
    "sealed-handshake": ("runner", "OPENGOTHIC_MULTIPLY2_SEALED_OUTER_GUARD", 1),
    "coverage-copy": ("runner", "RendererIOS-multiply2-coverage-v1.bin", 1),
    "coverage-cli": ("validator", 'print("COVERAGE PASS")', 1),
    "draw-collector-runner": ("runner", 'python3 "$DRAW_COLLECTOR" --collect', 1),
    "draw-evidence-leaf": ("runner", "RendererIOS-multiply2-draw-evidence-v1-", 1),
    "draw-transcript-leaf": ("runner", "multiply2-draw-gpudebug-transcripts-v1", 1),
    "draw-ds-join": ("draw-collector", 'observed["depth"] == observed["stencil"] ==', 1),
    "draw-constants-index": ("draw-collector", '"constantsBufferIndex": 1', 1),
    "draw-inline-storage": ("draw-collector", '"constantsStorage": "inline"', 1),
    "draw-stencil-option": ("draw-collector", '"StencilFromDepthStencil"', 3),
    "draw-coverage-strip": ("draw-collector", "stripped == payload", 1),
    "draw-code-provenance": ("draw-collector", '"coverage-artifact+code-contract"', 2),
    "draw-pso-label": ("draw-collector", '"RendererIOS.Static.Multiply2"', 3),
    "inventory-cpp": ("local-gate", 'iosmultiply2coverageproof.cpp', 2),
    "inventory-mm": ("local-gate", 'iosmultiply2coverageproof.mm', 2),
}

def accepts(candidate: dict[str, str]) -> bool:
    if any(candidate[source].count(token) != expected
           for source, token, expected in requirements.values()):
        return False
    scene_order = (
        candidate["scene"].find("first.colorAttachments[0].texture = sceneHDR;"),
        candidate["scene"].find("context.scene->multiply2DepthState];"),
        candidate["scene"].find("RendererIOS.HDRProofCopy.Multiply2.v1"),
        candidate["scene"].find("RendererIOS.Multiply2.CoverageStencilCopy.v1"),
        candidate["scene"].find("options:MTLBlitOptionStencilFromDepthStencil"),
        candidate["scene"].find("RendererIOS.Multiply2.AdditiveAfterProof.v1"),
        candidate["scene"].find("context.scene->additiveDepthState,0u"),
    )
    context_order = (
        candidate["context"].find("impl->linearHDRProof->nativeCopyView("),
        candidate["context"].find("impl->gpuScene->multiply2CoverageMetadata("),
        candidate["context"].find("impl->multiply2Coverage->prepareFrame("),
        candidate["context"].find("impl->gpuScene->encodePreparedMultiply2Causal("),
        candidate["context"].find("impl->linearHDRProof->markNativeCopyEncoded("),
        candidate["context"].find("impl->gpuScene->encodePreparedMultiply2Continuation("),
        candidate["context"].find("impl->linearHDRMetal->encodeToneResolve("),
    )
    admission_order = (
        candidate["context"].find("constexpr IOSMultiply2SceneAdmission iosMultiply2SceneAdmission("),
        candidate["context"].find("IOSMultiply2SceneAdmission::CaptureProof;"),
        candidate["context"].find("IOSMultiply2SceneAdmission::Continuation;"),
        candidate["context"].find("IOSMultiply2SceneAdmission::Reject;"),
        candidate["context"].find("const IOSMultiply2SceneAdmission multiply2Admission ="),
        candidate["context"].find("if(multiply2Admission==IOSMultiply2SceneAdmission::Reject)"),
        candidate["context"].find("impl->gpuScene->encodePreparedMultiply2Causal("),
        candidate["context"].find("impl->gpuScene->encodePreparedMultiply2Continuation("),
    )
    resource_order = (
        candidate["scene"].find("bool IOSGPUScene::Impl::continuationDepthStencilForSceneHDR("),
        candidate["scene"].find("target.device==device"),
        candidate["scene"].find("target.pixelFormat==MTLPixelFormatDepth32Float_Stencil8"),
        candidate["scene"].find("target.width==sceneHDR.width"),
        candidate["scene"].find("target.height==sceneHDR.height"),
        candidate["scene"].find("target.sampleCount==1u"),
        candidate["scene"].find("target.storageMode==MTLStorageModePrivate"),
        candidate["scene"].find("target.usage==MTLTextureUsageRenderTarget"),
        candidate["scene"].find("if(target==nil || target.width!=sceneHDR.width ||"),
        candidate["scene"].find("target.height!=sceneHDR.height) {"),
        candidate["scene"].find("[device newTextureWithDescriptor:textureDescriptor]"),
        candidate["scene"].find("multiply2ContinuationDepthStencil = allocated.relinquish();"),
        candidate["scene"].find("else if(!validContinuationTarget(target))"),
    )
    visibility_order = (
        candidate["scene"].find("context.scene->multiply2DepthState];"),
        candidate["scene"].find("IOSMultiply2VisibilityProductionOffset"),
        candidate["scene"].find("RendererIOS.HDRProofCopy.Multiply2.v1"),
        candidate["scene"].find("options:MTLBlitOptionStencilFromDepthStencil"),
        candidate["scene"].find("RendererIOS.Multiply2.VisibilityDiagnostic.v1"),
        candidate["scene"].find("IOSMultiply2VisibilityRasterOffset"),
        candidate["scene"].find("IOSMultiply2VisibilityStencilOffset"),
        candidate["scene"].find("second.colorAttachments[0].texture = sceneHDR;"),
        candidate["scene"].find("context.scene->additiveDepthState,0u"),
    )
    visibility_terminal_order = (
        candidate["coverage-mm"].find("IOSMultiply2VisibilityProductionSentinel"),
        candidate["coverage-mm"].find("std::memcpy(\n        visibilityResults.data()"),
        candidate["coverage-mm"].find("RendererIOS multiply2 visibility: v=1 terminal=C class="),
        candidate["coverage-mm"].find("RendererIOS multiply2 visibility: v=1 terminal=F class=diagnostic-invalid"),
        candidate["coverage-mm"].find("if(hasInvalidCoverageByte) {"),
        candidate["coverage-mm"].find('fail("payload-invalid-byte");'),
        candidate["coverage-mm"].find("if(!hasCoverage) {"),
        candidate["coverage-mm"].find('fail("payload-missing-coverage");'),
        candidate["coverage-mm"].find("if(!visibilityValid || visibilityTerminalWriteFailed)"),
    )
    visibility_start = candidate["scene"].find(
        "MTLRenderPassDescriptor* visibilityPass")
    visibility_end = candidate["scene"].find(
        "MTLRenderPassDescriptor* second",visibility_start)
    visibility_slice = (candidate["scene"][visibility_start:visibility_end]
                        if visibility_start >= 0 and visibility_end >= 0
                        else "")
    visibility_is_noncanonical = (
        "draw.drawId" not in visibility_slice and
        "draw.drawBind" not in visibility_slice and
        "encodedPhaseDrawCount" not in visibility_slice and
        "encodedPhaseTexturedDrawCount" not in visibility_slice)
    visibility_bindings_are_exact = all(token in visibility_slice for token in (
        "visibilityPass.colorAttachments[0].texture = sceneHDR;",
        "visibilityPass.depthAttachment.texture = depthStencil;",
        "visibilityPass.stencilAttachment.texture = depthStencil;",
        "visibilityPass.visibilityResultBuffer = visibilityResultBuffer;",
        "context.scene->multiply2VisibilityPipelineState",
        "context.scene->multiply2VisibilityRasterDepthState",
        "context.scene->multiply2VisibilityStencilDepthState",
        "bindGeometry(renderEncoder,draw);",
        "draw.baseColorTexture",
        "draw.indexBuffer",
        "draw.plan.indexBufferOffset",
        "IOSMultiply2VisibilityRasterOffset",
        "IOSMultiply2VisibilityStencilOffset"))
    visibility_state_start = candidate["scene"].find(
        "depthDesc.depthCompareFunction = MTLCompareFunctionAlways;")
    visibility_state_end = candidate["scene"].find(
        "#endif",visibility_state_start)
    visibility_state_slice = (
        candidate["scene"][visibility_state_start:visibility_state_end]
        if visibility_state_start >= 0 and visibility_state_end >= 0 else "")
    production_start = candidate["scene"].find(
        "(id<MTLDepthStencilState>)context.scene->multiply2DepthState];")
    production_end = candidate["scene"].find(
        "++context.report.encodedPhaseDrawCount;",production_start)
    production_slice = (candidate["scene"][production_start:production_end]
                        if production_start >= 0 and production_end >= 0
                        else "")
    def ordered_in(block: str, tokens: tuple[str, ...]) -> bool:
        cursor = 0
        for token in tokens:
            cursor = block.find(token,cursor)
            if cursor < 0:
                return False
            cursor += len(token)
        return True
    visibility_states_exact = ordered_in(visibility_state_slice,(
        "depthDesc.depthCompareFunction = MTLCompareFunctionAlways;",
        "depthDesc.depthWriteEnabled = NO;",
        "depthDesc.frontFaceStencil = nil;",
        "depthDesc.backFaceStencil = nil;",
        "OwnedObjectiveC visibilityRasterDepthOwner(",
        "visibilityStencilDesc.stencilCompareFunction = MTLCompareFunctionEqual;",
        "visibilityStencilDesc.stencilFailureOperation = MTLStencilOperationKeep;",
        "visibilityStencilDesc.depthFailureOperation = MTLStencilOperationKeep;",
        "visibilityStencilDesc.depthStencilPassOperation = MTLStencilOperationKeep;",
        "visibilityStencilDesc.readMask = 0xffu;",
        "visibilityStencilDesc.writeMask = 0u;",
        "depthDesc.frontFaceStencil = visibilityStencilDesc;",
        "depthDesc.backFaceStencil = visibilityStencilDesc;",
        "OwnedObjectiveC visibilityStencilDepthOwner("))
    production_query_exact = ordered_in(production_slice,(
        "context.scene->multiply2DepthState",
        "setStencilReferenceValue:1u",
        "MTLVisibilityResultModeBoolean",
        "IOSMultiply2VisibilityProductionOffset",
        "indexCount:productionDraw.plan.indexCount",
        "indexBuffer:(id<MTLBuffer>)productionDraw.indexBuffer",
        "indexBufferOffset:productionDraw.plan.indexBufferOffset",
        "MTLVisibilityResultModeDisabled"))
    raster_query_exact = ordered_in(visibility_slice,(
        "context.scene->multiply2VisibilityRasterDepthState",
        "setStencilReferenceValue:0u",
        "MTLVisibilityResultModeBoolean",
        "IOSMultiply2VisibilityRasterOffset",
        "indexCount:draw.plan.indexCount",
        "indexType:MTLIndexTypeUInt32",
        "indexBuffer:(id<MTLBuffer>)draw.indexBuffer",
        "indexBufferOffset:draw.plan.indexBufferOffset",
        "instanceCount:1u baseVertex:0 baseInstance:0u",
        "MTLVisibilityResultModeDisabled",
        "context.scene->multiply2VisibilityStencilDepthState"))
    stencil_query_exact = ordered_in(visibility_slice,(
        "context.scene->multiply2VisibilityStencilDepthState",
        "setStencilReferenceValue:1u",
        "MTLVisibilityResultModeBoolean",
        "IOSMultiply2VisibilityStencilOffset",
        "indexCount:draw.plan.indexCount",
        "indexType:MTLIndexTypeUInt32",
        "indexBuffer:(id<MTLBuffer>)draw.indexBuffer",
        "indexBufferOffset:draw.plan.indexBufferOffset",
        "instanceCount:1u baseVertex:0 baseInstance:0u",
        "MTLVisibilityResultModeDisabled"))
    exact_diagnostic_draw = (
        "[renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle\n"
        "                                  indexCount:draw.plan.indexCount\n"
        "                                   indexType:MTLIndexTypeUInt32\n"
        "                                 indexBuffer:(id<MTLBuffer>)draw.indexBuffer\n"
        "                           indexBufferOffset:draw.plan.indexBufferOffset\n"
        "                               instanceCount:1u baseVertex:0 baseInstance:0u];")
    diagnostic_draw_count_exact = (
        visibility_slice.count(exact_diagnostic_draw)==2 and
        visibility_slice.count(
            "[renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle")==2)
    lifecycle_start = candidate["context"].find(
        "#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)\n"
        "        IOSGPUScene::Report report;")
    lifecycle_end = candidate["context"].find("#else", lifecycle_start)
    lifecycle = (candidate["context"][lifecycle_start:lifecycle_end]
                 if lifecycle_start >= 0 and lifecycle_end >= 0 else "")
    lifecycle_is_native_only = (
        "encodePreparedMultiply2Causal(" in lifecycle and
        "encodePreparedMultiply2Continuation(" in lifecycle and
        "encodePrepared(encoder,preparedScene)" not in lifecycle and
        "linearHDRTargets.depth" not in lifecycle and
        "setFramebuffer(" not in lifecycle)
    return (all(position >= 0 for position in
                scene_order + context_order + admission_order + resource_order +
                visibility_order + visibility_terminal_order) and
            scene_order == tuple(sorted(scene_order)) and
            context_order == tuple(sorted(context_order)) and
            admission_order == tuple(sorted(admission_order)) and
            resource_order == tuple(sorted(resource_order)) and
            visibility_order == tuple(sorted(visibility_order)) and
            visibility_terminal_order ==
                tuple(sorted(visibility_terminal_order)) and
            visibility_is_noncanonical and
            visibility_bindings_are_exact and
            visibility_states_exact and
            production_query_exact and raster_query_exact and
            stencil_query_exact and diagnostic_draw_count_exact and
            lifecycle_is_native_only)

if not accepts(texts):
    for label, (source, token, expected) in requirements.items():
        actual = texts[source].count(token)
        if actual != expected:
            raise SystemExit(
                f"Multiply2 source contract drifted: {label} expected={expected} actual={actual}")
    raise SystemExit("Multiply2 causal ordering drifted")

killed = 0
for label, (source, token, _expected) in requirements.items():
    mutant = dict(texts)
    mutant[source] = mutant[source].replace(token, f"MUTATED_{label}", 1)
    if accepts(mutant):
        raise SystemExit(f"Multiply2 mutation survived: {label}")
    killed += 1

def swapped(text: str, left: str, right: str) -> str:
    return text.replace(left,"__VISIBILITY_SWAP__",1).replace(
        right,left,1).replace("__VISIBILITY_SWAP__",right,1)

state_swap_mutants = {
    "production-raster-depth-state": swapped(
        texts["scene"],
        "context.scene->multiply2DepthState",
        "context.scene->multiply2VisibilityRasterDepthState"),
    "raster-stencil-depth-state": swapped(
        texts["scene"],
        "context.scene->multiply2VisibilityRasterDepthState",
        "context.scene->multiply2VisibilityStencilDepthState"),
}
for label, scene_mutant in state_swap_mutants.items():
    mutant = dict(texts)
    mutant["scene"] = scene_mutant
    if accepts(mutant):
        raise SystemExit(f"Multiply2 visibility state-swap mutation survived: {label}")
    killed += 1

def swap_query_modes(text: str, start_token: str, end_token: str) -> str:
    start = text.find(start_token)
    end = text.find(end_token,start)
    if start < 0 or end < 0:
        raise SystemExit("Multiply2 visibility query mutation fixture drifted")
    block = text[start:end]
    block = block.replace(
        "MTLVisibilityResultModeBoolean","__VISIBILITY_MODE__",1)
    block = block.replace(
        "MTLVisibilityResultModeDisabled","MTLVisibilityResultModeBoolean",1)
    block = block.replace(
        "__VISIBILITY_MODE__","MTLVisibilityResultModeDisabled",1)
    return text[:start]+block+text[end:]

query_mode_mutants = {
    "production-disable-before-draw": swap_query_modes(
        texts["scene"],"context.scene->multiply2DepthState];",
        "++context.report.encodedPhaseDrawCount;"),
    "raster-disable-before-draw": swap_query_modes(
        texts["scene"],"context.scene->multiply2VisibilityRasterDepthState",
        "context.scene->multiply2VisibilityStencilDepthState"),
    "stencil-disable-before-draw": swap_query_modes(
        texts["scene"],"context.scene->multiply2VisibilityStencilDepthState",
        "[renderEncoder setFragmentTexture:nil atIndex:0u]"),
}
for label, scene_mutant in query_mode_mutants.items():
    mutant = dict(texts)
    mutant["scene"] = scene_mutant
    if accepts(mutant):
        raise SystemExit(f"Multiply2 visibility disable-order mutation survived: {label}")
    killed += 1

def mutate_visibility_draw_parameter(
        text: str, token: str, replacement: str, occurrence: int) -> str:
    start = text.find("MTLRenderPassDescriptor* visibilityPass")
    end = text.find("MTLRenderPassDescriptor* second",start)
    if start < 0 or end < 0:
        raise SystemExit("Multiply2 visibility draw mutation fixture drifted")
    block = text[start:end]
    if block.count(token) != 2:
        raise SystemExit(
            "Multiply2 visibility draw parameter fixture drifted: " + token)
    offset = 0
    for _ in range(occurrence+1):
        offset = block.find(token,offset)
        if offset < 0:
            raise SystemExit(
                "Multiply2 visibility draw occurrence fixture drifted: " + token)
        if _ != occurrence:
            offset += len(token)
    block = block[:offset]+replacement+block[offset+len(token):]
    return text[:start]+block+text[end:]

diagnostic_draw_parameter_mutations = (
    ("index-type","indexType:MTLIndexTypeUInt32",
     "indexType:MTLIndexTypeUInt16"),
    ("instance-count","instanceCount:1u","instanceCount:2u"),
    ("base-vertex","baseVertex:0","baseVertex:1"),
    ("base-instance","baseInstance:0u","baseInstance:1u"),
)
for draw_name, occurrence in (("raster",0),("stencil",1)):
    for parameter, token, replacement in diagnostic_draw_parameter_mutations:
        mutant = dict(texts)
        mutant["scene"] = mutate_visibility_draw_parameter(
            texts["scene"],token,replacement,occurrence)
        if accepts(mutant):
            raise SystemExit(
                "Multiply2 visibility draw mutation survived: "
                f"{draw_name}-{parameter}")
        killed += 1
print(
    "RendererIOS Multiply2 focused contract passed: "
    f"source-cases={len(requirements)} order=63 mutations-killed={killed}"
)
PY
