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
    "callback": ("scene", "Tempest::MetalApi::withActiveCommandBuffer(", 1),
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
    "continuation-cache-release": ("scene", "[multiply2ContinuationDepthStencil release];", 1),
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
        candidate["scene"].find("context.scene->multiply2DepthState,1u"),
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
        candidate["scene"].find("if(target==nil) {"),
        candidate["scene"].find("[device newTextureWithDescriptor:textureDescriptor]"),
        candidate["scene"].find("multiply2ContinuationDepthStencil = allocated.relinquish();"),
        candidate["scene"].find("else if(!validContinuationTarget(target))"),
    )
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
                scene_order + context_order + admission_order + resource_order) and
            scene_order == tuple(sorted(scene_order)) and
            context_order == tuple(sorted(context_order)) and
            admission_order == tuple(sorted(admission_order)) and
            resource_order == tuple(sorted(resource_order)) and
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
print(
    "RendererIOS Multiply2 focused contract passed: "
    f"source-cases={len(requirements)} order=37 mutations-killed={killed}"
)
PY
