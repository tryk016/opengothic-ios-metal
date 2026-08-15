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

compile_and_run "$TMP_ROOT/artifact" \
  -Igame ios/tests/iosmultiply2inputartifact.cpp \
  game/graphics/iosmultiply2inputartifact.cpp
compile_and_run "$TMP_ROOT/artifact-asan" \
  -fsanitize=address -fno-omit-frame-pointer \
  -Igame ios/tests/iosmultiply2inputartifact.cpp \
  game/graphics/iosmultiply2inputartifact.cpp
compile_and_run "$TMP_ROOT/artifact-ubsan" \
  -fsanitize=undefined -fno-sanitize-recover=undefined \
  -fno-omit-frame-pointer \
  -Igame ios/tests/iosmultiply2inputartifact.cpp \
  game/graphics/iosmultiply2inputartifact.cpp
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
cmake = (root / "CMakeLists.txt").read_text()
presets = (root / "CMakePresets.json").read_text()
scene = (root / "game/graphics/iosgpuscene.mm").read_text()
context = (root / "game/graphics/iosmetalcontext.cpp").read_text()
header = (root / "game/graphics/iosgpuscene.h").read_text()
plan = (root / "game/graphics/iosgpusceneplan.h").read_text()
ci_profile = (root / "scripts/ci_build_profile.command").read_text()
policy = (root / "verification-policy.json").read_text()

required = {
    "cmake-mode": (cmake, 'OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_MODE', 11),
    "cmake-a": (cmake, 'OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1', 1),
    "cmake-b": (cmake, 'OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B=1', 1),
    "preset-a": (presets, 'renderer-ios-multiply2-a-hdr', 4),
    "preset-b": (presets, 'renderer-ios-multiply2-b-hdr', 4),
    "rgb-a": (scene, 'additiveColor.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;', 1),
    "rgb-b": (scene, 'additiveColor.sourceRGBBlendFactor = MTLBlendFactorZero;', 2),
    "alpha-source": (scene, 'additiveColor.sourceAlphaBlendFactor = MTLBlendFactorDestinationColor;', 1),
    "alpha-destination": (scene, 'additiveColor.destinationAlphaBlendFactor = MTLBlendFactorSourceColor;', 1),
    "phase-copy": (context, 'encodePreparedThroughMultiply2(', 1),
    "phase-additive": (context, 'encodePreparedAdditive(encoder,preparedScene)', 1),
    "phase0-reentry": (scene, '(phase==0u && prepared.impl!=nullptr &&', 1),
    "phase-draw-count": (scene, '++context.report.encodedPhaseDrawCount;', 1),
    "phase-textured-count": (scene, '++context.report.encodedPhaseTexturedDrawCount;', 1),
    "phase-count-preserve": (scene, 'context.report.encodedPhaseDrawCount = encodedPhaseDrawCount;', 1),
    "phase-textured-preserve": (scene, 'context.report.encodedPhaseTexturedDrawCount =\n        encodedPhaseTexturedDrawCount;', 1),
    "base-count-check": (context, 'report.encodedPhaseDrawCount!=baseMultiply2Planned', 1),
    "additive-count-check": (context, 'additiveReport.encodedPhaseDrawCount!=additivePlanned', 1),
    "depth-first-preserve": (context, '{impl->linearHDRTargets.depth,1.f,Tempest::Preserve}', 1),
    "depth-second-preserve": (context, '{impl->linearHDRTargets.depth,\n            Tempest::Preserve,Tempest::Preserve});', 1),
    "artifact-parse": (context, 'iosParseMultiply2InputArtifactV1(', 1),
    "artifact-publish": (context, 'iosPublishMultiply2InputArtifactV1NoClobber(', 1),
    "distinct-artifact": (header, 'struct Multiply2InputArtifact final', 1),
    "distinct-frame-carrier": (context, 'IOSGPUScene::Multiply2InputArtifact emissiveInput;', 1),
    "marker-a": (plan, 'return "multiply2-a";', 1),
    "marker-b": (plan, 'return "multiply2-b";', 1),
    "initial-pso-preflight": (scene, 'iosGPUSceneInitialPipelineStatesAreAvailable(', 1),
    "artifact-animation": (scene, 'emissiveArtifactAnimation(\n       plan.baseColorTexture,frameAnimation,uvAnimation,record.animation)', 1),
    "draw-id-signpost": (scene, 'iosGPUSceneMultiply2DrawIdSignpost(identity)', 1),
    "draw-bind-signpost": (scene, 'iosGPUSceneMultiply2DrawBindSignpost(identity)', 1),
    "private-evidence-directory": (context, '/Documents/RendererIOS-multiply2-evidence', 1),
    "published-byte-sha": (context, 'materializeEmissiveTerminal(publishedBytes)', 1),
    "ci-output-profile": (ci_profile, 'if [[ "$PROFILE" == additive-*-hdr ||\n      "$PROFILE" == multiply2-*-hdr ]]; then', 2),
    "policy-a": (policy, '"build-multiply2-a-hdr"', 2),
    "policy-b": (policy, '"build-multiply2-b-hdr"', 2),
}
for label, (source, token, expected) in required.items():
    if source.count(token) != expected:
        raise SystemExit(f"Multiply2 source contract drifted: {label}")
if 'using Multiply2InputArtifact =' in header:
    raise SystemExit("Multiply2 artifact carrier aliases Additive")
if '#define OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A 1' in context or \
   '#define OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B 1' in context:
    raise SystemExit("Multiply2 lifecycle aliases Additive compile mode")

ordered = (
    context.index('encodePreparedThroughMultiply2('),
    context.index('impl->linearHDRProof->encodeCopy('),
    context.index('encodePreparedAdditive(encoder,preparedScene)'),
    context.index('impl->linearHDRMetal->encodeToneResolve('),
)
if ordered != tuple(sorted(ordered)):
    raise SystemExit("Multiply2 HDR phase ordering drifted")

texts = {
    "scene": scene,
    "context": context,
    "header": header,
    "plan": plan,
    "ci": ci_profile,
    "policy": policy,
}
mutation_requirements = {
    "counter-restore": ("scene", 'context.report.encodedPhaseDrawCount = encodedPhaseDrawCount;', 1),
    "textured-counter-restore": ("scene", 'context.report.encodedPhaseTexturedDrawCount =\n        encodedPhaseTexturedDrawCount;', 1),
    "rgb-source": ("scene", 'additiveColor.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;', 1),
    "rgb-destination": ("scene", 'additiveColor.destinationRGBBlendFactor = MTLBlendFactorSourceColor;', 1),
    "rgb-operation": ("scene", 'additiveColor.rgbBlendOperation = MTLBlendOperationAdd;', 2),
    "alpha-source": ("scene", 'additiveColor.sourceAlphaBlendFactor = MTLBlendFactorDestinationColor;', 1),
    "alpha-destination": ("scene", 'additiveColor.destinationAlphaBlendFactor = MTLBlendFactorSourceColor;', 1),
    "phase-reentry": ("scene", '(phase==0u && prepared.impl!=nullptr &&', 1),
    "base-count": ("context", 'report.encodedPhaseDrawCount!=baseMultiply2Planned', 1),
    "additive-count": ("context", 'additiveReport.encodedPhaseDrawCount!=additivePlanned', 1),
    "depth-first": ("context", '{impl->linearHDRTargets.depth,1.f,Tempest::Preserve}', 1),
    "depth-second": ("context", '{impl->linearHDRTargets.depth,\n            Tempest::Preserve,Tempest::Preserve});', 1),
    "carrier": ("context", 'IOSGPUScene::Multiply2InputArtifact emissiveInput;', 1),
    "marker-a": ("plan", 'return "multiply2-a";', 1),
    "marker-b": ("plan", 'return "multiply2-b";', 1),
    "ci-outputs": ("ci", 'if [[ "$PROFILE" == additive-*-hdr ||\n      "$PROFILE" == multiply2-*-hdr ]]; then', 2),
    "policy-a": ("policy", '"build-multiply2-a-hdr"', 2),
    "policy-b": ("policy", '"build-multiply2-b-hdr"', 2),
}

def accepts(candidate):
    if any(candidate[source].count(token) != expected
           for source, token, expected in mutation_requirements.values()):
        return False
    positions = (
        candidate["context"].find('encodePreparedThroughMultiply2('),
        candidate["context"].find('impl->linearHDRProof->encodeCopy('),
        candidate["context"].find('encodePreparedAdditive(encoder,preparedScene)'),
        candidate["context"].find('impl->linearHDRMetal->encodeToneResolve('),
    )
    return positions == tuple(sorted(positions))

if not accepts(texts):
    raise SystemExit("Multiply2 mutation oracle rejected the canonical source")
killed = 0
for label, (source, token, _expected) in mutation_requirements.items():
    mutant = dict(texts)
    mutant[source] = mutant[source].replace(token, f"MUTATED_{label}", 1)
    if accepts(mutant):
        raise SystemExit(f"Multiply2 mutation survived: {label}")
    killed += 1
print(
    "RendererIOS Multiply2 focused contract passed: "
    f"source-cases={len(required)} order=4 mutations-killed={killed}"
)
PY
