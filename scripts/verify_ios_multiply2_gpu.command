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
    "hdr-view": ("context", "impl->linearHDRProof->nativeCopyView(", 1),
    "coverage-prepare": ("context", "impl->multiply2Coverage->prepareFrame(", 1),
    "coverage-encoded": ("context", "impl->multiply2Coverage->markEncoded(", 1),
    "coverage-submitted": ("context", "impl->multiply2Coverage->markSubmitted(", 1),
    "coverage-terminal": ("context", "multiply2Coverage->completeAfterTerminal(", 1),
    "magic": ("coverage-cpp", "std::byte{'M'},std::byte{'C'},std::byte{'9'},std::byte{0}", 1),
    "header-160": ("coverage-h", "IOSMultiply2CoverageProofV1HeaderBytes = 160u", 1),
    "payload-domain": ("coverage-cpp", "if(byte>1u)", 1),
    "coverage-required": ("coverage-cpp", "IOSMultiply2CoverageProofError::MissingCoverage", 1),
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
        candidate["context"].find("impl->linearHDRMetal->encodeToneResolve("),
    )
    return (all(position >= 0 for position in scene_order + context_order) and
            scene_order == tuple(sorted(scene_order)) and
            context_order == tuple(sorted(context_order)))

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
    f"source-cases={len(requirements)} order=13 mutations-killed={killed}"
)
PY
