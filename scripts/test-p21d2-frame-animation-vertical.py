#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
EXTRACTOR = ROOT / "game/graphics/iossceneextractor.cpp"
EXTRACTOR_HEADER = ROOT / "game/graphics/iossceneextractor.h"
PLAN = ROOT / "game/graphics/iossceneextractorplan.h"
EVIDENCE = ROOT / "game/graphics/iosframeanimationevidence.h"
TEST = ROOT / "ios/tests/iossceneextractorplan.cpp"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def compiler() -> list[str]:
    configured = os.environ.get("CXX")
    if configured:
        return shlex.split(configured)
    if shutil.which("xcrun"):
        return ["xcrun", "clang++"]
    found = shutil.which("clang++")
    if found:
        return [found]
    raise RuntimeError("clang++ not found")


def run(command: list[str], label: str) -> None:
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{label} failed:\n{result.stdout}{result.stderr}")


def sign_and_run(executable: Path, label: str) -> None:
    if sys.platform == "darwin" and shutil.which("codesign"):
        run(["codesign", "-f", "-s", "-", str(executable)], label + " codesign")
    run([str(executable)], label)


def compile_focused(cxx: list[str], workspace: Path, sanitizer: str | None) -> None:
    label = sanitizer or "strict"
    executable = workspace / f"iossceneextractorplan-{label}"
    command = [
        *cxx,
        "-std=c++20",
        "-Wall",
        "-Wextra",
        "-Wconversion",
        "-Wsign-conversion",
        "-Werror",
        "-Igame",
        "-isystem",
        "lib/Tempest/Engine/include",
        "-isystem",
        "lib/ZenKit/include",
        str(TEST),
        "-o",
        str(executable),
    ]
    if sanitizer:
        command.extend([f"-fsanitize={sanitizer}", "-fno-omit-frame-pointer"])
    run(command, f"focused {label} compile")
    sign_and_run(executable, f"focused {label} run")


def normalized(value: str) -> str:
    return " ".join(value.split())


def statement(source: str, anchor: str) -> str | None:
    if source.count(anchor) != 1:
        return None
    start = source.find(anchor)
    end = source.find(";", start)
    if end < 0:
        return None
    return normalized(source[start:end + 1])


def function_body(source: str, signature: str) -> str | None:
    if source.count(signature) != 1:
        return None
    start = source.find(signature)
    opening = source.find("{", start + len(signature))
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    return None


def region(source: str, start_anchor: str, end_anchor: str) -> str | None:
    if source.count(start_anchor) != 1:
        return None
    start = source.find(start_anchor)
    end = source.find(end_anchor, start + len(start_anchor))
    if end < 0:
        return None
    return source[start:end]


def require_exact_statement(
    errors: list[str], source: str, anchor: str, expected: str, label: str
) -> None:
    if statement(source, anchor) != expected:
        errors.append(f"{label} statement differs")


def require_order(
    errors: list[str], source: str, anchors: tuple[str, ...], label: str
) -> None:
    positions = [source.find(anchor) for anchor in anchors]
    if any(position < 0 for position in positions):
        errors.append(f"missing {label} step")
    elif positions != sorted(positions) or len(set(positions)) != len(positions):
        errors.append(f"{label} order differs")


def production_errors(extractor: str, header: str, plan: str) -> list[str]:
    errors: list[str] = []
    require_exact_statement(
        errors, extractor, "const bool hasFrameAnimation",
        "const bool hasFrameAnimation = source.material!=nullptr && "
        "!source.material->frames.empty();",
        "raw frame sequence",
    )
    require_exact_statement(
        errors, extractor, "candidate.usesFallbackTexture",
        "candidate.usesFallbackTexture = "
        "materialMapping==IOSSceneMaterialMapping{ "
        "IOSMaterialCategory::Opaque,true} && !hasFrameAnimation && "
        "!candidate.hasBaseColorTexture;",
        "static-only fallback",
    )
    require_exact_statement(
        errors, extractor, "candidate.sceneTimeMs",
        "candidate.sceneTimeMs = context.sceneTimeMs;", "world time",
    )
    require_exact_statement(
        errors, extractor, "candidate.frameCount",
        "candidate.frameCount = source.material!=nullptr ? "
        "static_cast<uint64_t>(source.material->frames.size()) : 0u;",
        "frame count",
    )
    require_exact_statement(
        errors, extractor, "candidate.framePeriodMs",
        "candidate.framePeriodMs = source.material!=nullptr ? "
        "source.material->texAniFPSInv : 0u;",
        "frame period",
    )
    require_exact_statement(
        errors, extractor, "candidate.hasValidFrameSequence",
        "candidate.hasValidFrameSequence = hasFrameAnimation && "
        "hasValidIOSSceneFrameSequence(source.material);",
        "combined frame sequence",
    )
    require_exact_statement(
        errors, extractor, "candidate.uvPeriodX",
        "candidate.uvPeriodX = source.material!=nullptr ? "
        "static_cast<int32_t>(source.material->texAniMapDirPeriod.x) : 0;",
        "UV period X",
    )
    require_exact_statement(
        errors, extractor, "candidate.uvPeriodY",
        "candidate.uvPeriodY = source.material!=nullptr ? "
        "static_cast<int32_t>(source.material->texAniMapDirPeriod.y) : 0;",
        "UV period Y",
    )
    require_exact_statement(
        errors, extractor, "const IOSTextureHandle texture",
        "const IOSTextureHandle texture = "
        "plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly || "
        "plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv ? "
        "context.renderWorld->resolveFrameTexture("
        " plan.textureStableKey,plan.frameOrdinal) : "
        "context.renderWorld->resolveTexture(plan.textureStableKey);",
        "frame-or-combined resolver",
    )
    require_exact_statement(
        errors, extractor, "const Tempest::Texture2d& baseColorTexture",
        "const Tempest::Texture2d& baseColorTexture = selectedTexture!=nullptr ? "
        "*selectedTexture : source.material->tex!=nullptr ? "
        "*source.material->tex : Resources::fallbackTexture();",
        "selected frame binding",
    )
    require_exact_statement(
        errors, extractor, "context.report.bindFailure = textureBound",
        "context.report.bindFailure = textureBound;", "exact texture bind failure",
    )
    require_exact_statement(
        errors, extractor, "context.report.frameAnimation.selections.push_back",
        "context.report.frameAnimation.selections.push_back( "
        "{plan.textureStableKey,plan.frameOrdinal,texture});",
        "frame evidence sidecar",
    )
    selector_block = region(
        extractor,
        "const Tempest::Texture2d* selectedTexture = nullptr;",
        "const IOSRenderEntityId entity",
    )
    expected_selector_block = normalized("""
      const Tempest::Texture2d* selectedTexture = nullptr;
      if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly ||
         plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv) {
        if(selectIOSSceneFrameTextureForExtraction(
               source.material,plan,selectedTexture)!=
           IOSSceneExtractionResult::Success) {
          (void)recordIOSSceneInvalidSource(context.report.stats);
          context.report.result = IOSSceneExtractionResult::InvalidSource;
          return;
          }
        }
    """)
    if selector_block is None or normalized(selector_block) != expected_selector_block:
        errors.append("checked selector control flow differs")

    bind_block = region(
        extractor,
        "const auto textureBound = context.assets->bindTexture(",
        "if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly)",
    )
    expected_bind_block = normalized("""
      const auto textureBound = context.assets->bindTexture(
          *context.device,texture,baseColorTexture);
      if(!isIOSSceneAssetBindSuccess(textureBound)) {
        context.report.result = IOSSceneExtractionResult::AssetBindFailed;
        context.report.bindFailure = textureBound;
        return;
        }
    """)
    if bind_block is None or normalized(bind_block) != expected_bind_block:
        errors.append("texture bind failure control flow differs")

    sidecar_block = region(
        extractor,
        "if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly)\n"
        "    context.report.frameAnimation.selections.push_back(",
        "IOSMaterial materialRecord;",
    )
    expected_sidecar_block = normalized("""
      if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly)
        context.report.frameAnimation.selections.push_back(
            {plan.textureStableKey,plan.frameOrdinal,texture});
      else if(plan.textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||
              plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv)
        context.report.uvAnimation.selections.push_back(
            {plan.textureStableKey,plan.textureAnimation,plan.frameOrdinal,
             texture,plan.uvOffset});
    """)
    if sidecar_block is None or normalized(sidecar_block) != expected_sidecar_block:
        errors.append("post-bind mode-exclusive sidecar control flow differs")

    visit = function_body(extractor, "void visitSource(void* opaque, const IOSSceneSource& source)")
    if visit is None:
        errors.append("visitSource body differs")
    else:
        require_order(
            errors, visit,
            (
                "const bool hasFrameAnimation",
                "candidate.hasValidFrameSequence",
                "candidate.uvPeriodX",
                "candidate.uvPeriodY",
                "planIOSOpaqueMeshSource(candidate,plan)",
                "selectIOSSceneFrameTextureForExtraction(",
                "resolveFrameTexture(",
                "context.assets->bindTexture(",
                "if(!isIOSSceneAssetBindSuccess(textureBound))",
                "context.report.frameAnimation.selections.push_back(",
                "context.report.uvAnimation.selections.push_back(",
                "context.staging.materials.push_back(",
                "context.staging.entities.push_back(",
                "recordIOSScenePlanResult(\n       IOSSceneSourcePlanResult::Planned",
            ),
            "classify/select/resolve/bind/stage",
        )
        if "publishIOSSceneExtraction" in visit or "frame." in visit:
            errors.append("visitSource must not publish or mutate destination frame")
        if any(token in visit for token in ("rollbackFrameTexture", "unresolveFrameTexture", "unbindTexture")):
            errors.append("pre-publication frame resolver must permit harmless orphans")

    extractor_body = function_body(
        extractor, "IOSSceneExtractionReport IOSSceneExtractor::extractOpaqueMeshes("
    )
    if extractor_body is None:
        errors.append("extractOpaqueMeshes body differs")
    else:
        require_order(
            errors, extractor_body,
            (
                "source.visit(&context,&visitSource);",
                "if(context.report.result!=IOSSceneExtractionResult::Success)",
                "finalizeIOSFrameAnimationEvidence(context.report.frameAnimation)",
                "publishIOSSceneExtraction(",
            ),
            "failure/finalize/atomic publication",
        )
        if extractor_body.count("publishIOSSceneExtraction(") != 1:
            errors.append("destination publication count differs")

    adapter = function_body(
        header, "inline IOSSceneExtractionResult selectIOSSceneFrameTextureForExtraction("
    )
    expected_adapter = normalized("""
      if(source==nullptr ||
         (plan.textureAnimation!=IOSSceneTextureAnimationMode::FrameOnly &&
          plan.textureAnimation!=IOSSceneTextureAnimationMode::FrameAndUv) ||
         plan.frameOrdinal>=static_cast<uint64_t>(source->frames.size()))
        return IOSSceneExtractionResult::InvalidSource;
      const auto* selected =
          source->frames[static_cast<std::size_t>(plan.frameOrdinal)];
      if(selected==nullptr)
        return IOSSceneExtractionResult::InvalidSource;
      outTexture = selected;
      return IOSSceneExtractionResult::Success;
    """)
    if adapter is None or normalized(adapter) != expected_adapter:
        errors.append("checked frame adapter body differs")

    publisher = function_body(header, "inline bool publishIOSSceneExtraction(")
    expected_publisher = normalized("""
      if(result!=IOSSceneExtractionResult::Success)
        return false;
      frame.entities.swap(staging.entities);
      frame.materials.swap(staging.materials);
      return true;
    """)
    if publisher is None or normalized(publisher) != expected_publisher:
        errors.append("atomic destination publisher body differs")

    uv_admission = region(
        plan,
        "const bool periodsHaveUv = source.uvPeriodX!=0 || source.uvPeriodY!=0;",
        "const bool hasEffectiveBaseColorTexture =",
    )
    expected_uv_admission = normalized("""
      const bool periodsHaveUv = source.uvPeriodX!=0 || source.uvPeriodY!=0;
      if(source.hasUvAnimation!=periodsHaveUv)
        return IOSSceneSourcePlanResult::InvalidSource;
      if(textureAnimation==IOSSceneTextureAnimationMode::UvOnly &&
         (!source.hasBaseColorTexture || source.usesFallbackTexture))
        return IOSSceneSourcePlanResult::InvalidSource;
      if(textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv &&
         (!source.hasValidFrameSequence || source.usesFallbackTexture))
        return IOSSceneSourcePlanResult::InvalidSource;
      const bool selectsFrame =
          textureAnimation==IOSSceneTextureAnimationMode::FrameOnly ||
          textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv;
      if(source.materialCategory==IOSMaterialCategory::AlphaTest &&
         ((!source.hasBaseColorTexture &&
           !selectsFrame) ||
          source.usesFallbackTexture))
        return IOSSceneSourcePlanResult::SkippedMaterial;
      uint64_t frameOrdinal = 0;
      if(selectsFrame &&
         selectIOSSceneTextureFrame(
             source.sceneTimeMs,source.framePeriodMs,source.frameCount,
             frameOrdinal)!=IOSSceneFrameSelectionResult::Selected)
        return IOSSceneSourcePlanResult::InvalidSource;
      IOSFloat2 uvOffset;
      if((textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||
          textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv) &&
         evaluateIOSSceneUVOffset(
             source.sceneTimeMs,source.uvPeriodX,source.uvPeriodY,
             uvOffset)!=IOSSceneUVOffsetResult::Evaluated)
        return IOSSceneSourcePlanResult::InvalidSource;
    """)
    if uv_admission is None or normalized(uv_admission) != expected_uv_admission:
        errors.append("checked frame/UV admission control flow differs")
    return errors


def require_production_oracle(extractor: str, header: str, plan: str) -> None:
    errors = production_errors(extractor, header, plan)
    require(not errors, "; ".join(errors))
    mutations = {
        "short-circuited-raw-frame-classifier": (
            extractor.replace(
                "source.material!=nullptr && !source.material->frames.empty()",
                "source.material!=nullptr && false && "
                "!source.material->frames.empty()",
                1,
            ),
            header,
            plan,
        ),
        "legacy-frame-classifier": (
            extractor.replace(
                "!source.material->frames.empty()",
                "source.material->hasFrameAnimation()",
                1,
            ),
            header,
            plan,
        ),
        "animated-fallback": (
            extractor.replace("      !hasFrameAnimation &&\n", "", 1),
            header,
            plan,
        ),
        "bind-static-texture": (
            extractor.replace(
                "selectedTexture!=nullptr\n        ? *selectedTexture",
                "false\n        ? *selectedTexture",
                1,
            ),
            header,
            plan,
        ),
        "collapsed-frame-handle": (
            extractor.replace(
                "resolveFrameTexture(\n              plan.textureStableKey,plan.frameOrdinal)",
                "resolveTexture(plan.textureStableKey)",
                1,
            ),
            header,
            plan,
        ),
        "missing-sidecar": (
            extractor.replace(
                "{plan.textureStableKey,plan.frameOrdinal,texture}",
                "{plan.textureStableKey,0u,texture}",
                1,
            ),
            header,
            plan,
        ),
        "collapsed-bind-failure": (
            extractor.replace(
                "context.report.bindFailure = textureBound;",
                "context.report.bindFailure.reset();",
                1,
            ),
            header,
            plan,
        ),
        "bypassed-frame-selector": (
            extractor.replace(
                "if(selectIOSSceneFrameTextureForExtraction(",
                "if(false && selectIOSSceneFrameTextureForExtraction(",
                1,
            ),
            header,
            plan,
        ),
        "bypassed-texture-bind-failure": (
            extractor.replace(
                "if(!isIOSSceneAssetBindSuccess(textureBound))",
                "if(false && !isIOSSceneAssetBindSuccess(textureBound))",
                1,
            ),
            header,
            plan,
        ),
        "bypassed-frame-sidecar": (
            extractor.replace(
                "if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly)\n"
                "    context.report.frameAnimation.selections.push_back(",
                "if(false && "
                "plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly)\n"
                "    context.report.frameAnimation.selections.push_back(",
                1,
            ),
            header,
            plan,
        ),
        "resolver-rollback": (
            extractor.replace(
                ": context.renderWorld->resolveTexture(plan.textureStableKey);",
                ": context.renderWorld->resolveTexture(plan.textureStableKey);\n"
                "  context.renderWorld->rollbackFrameTexture(texture);",
                1,
            ),
            header,
            plan,
        ),
        "accepted-null-frame": (
            extractor,
            header.replace(
                "if(selected==nullptr)\n    return IOSSceneExtractionResult::InvalidSource;",
                "if(false)\n    return IOSSceneExtractionResult::InvalidSource;",
                1,
            ),
            plan,
        ),
        "adapter-publishes-before-null-check": (
            extractor,
            header.replace(
                "  if(selected==nullptr)\n"
                "    return IOSSceneExtractionResult::InvalidSource;\n"
                "  outTexture = selected;",
                "  outTexture = selected;\n"
                "  if(selected==nullptr)\n"
                "    return IOSSceneExtractionResult::InvalidSource;",
                1,
            ),
            plan,
        ),
        "publisher-accepts-failure": (
            extractor,
            header.replace(
                "if(result!=IOSSceneExtractionResult::Success)",
                "if(false && result!=IOSSceneExtractionResult::Success)",
                1,
            ),
            plan,
        ),
        "uv-evaluator-no-op": (
            extractor,
            header,
            plan.replace(
                "     evaluateIOSSceneUVOffset(\n"
                "         source.sceneTimeMs,source.uvPeriodX,source.uvPeriodY,\n"
                "         uvOffset)!=IOSSceneUVOffsetResult::Evaluated)",
                "     (uvOffset = IOSFloat2{}, "
                "IOSSceneUVOffsetResult::Evaluated)!=\n"
                "         IOSSceneUVOffsetResult::Evaluated)",
                1,
            ),
        ),
        "drop-frame-from-combined": (
            extractor,
            header,
            plan.replace(
                "const bool selectsFrame =\n"
                "      textureAnimation==IOSSceneTextureAnimationMode::FrameOnly ||\n"
                "      textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv;",
                "const bool selectsFrame =\n"
                "      textureAnimation==IOSSceneTextureAnimationMode::FrameOnly;",
                1,
            ),
        ),
        "drop-uv-from-combined": (
            extractor,
            header,
            plan.replace(
                "if((textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||\n"
                "      textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv) &&",
                "if(textureAnimation==IOSSceneTextureAnimationMode::UvOnly &&",
                1,
            ),
        ),
        "partial-combined-sequence": (
            extractor,
            header,
            plan.replace(
                "(!source.hasValidFrameSequence || source.usesFallbackTexture)",
                "source.usesFallbackTexture",
                1,
            ),
        ),
        "combined-leaks-to-frame-sidecar": (
            extractor.replace(
                "if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly)\n"
                "    context.report.frameAnimation.selections.push_back(",
                "if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly ||\n"
                "   plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv)\n"
                "    context.report.frameAnimation.selections.push_back(",
                1,
            ),
            header,
            plan,
        ),
        "drop-combined-uv-sidecar": (
            extractor.replace(
                "else if(plan.textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||\n"
                "          plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv)",
                "else if(plan.textureAnimation==IOSSceneTextureAnimationMode::UvOnly)",
                1,
            ),
            header,
            plan,
        ),
    }
    for name, (mutated_extractor, mutated_header, mutated_plan) in mutations.items():
        require(
            (mutated_extractor, mutated_header, mutated_plan)
            != (extractor, header, plan),
            f"mutation did not match: {name}",
        )
        require(
            bool(production_errors(mutated_extractor, mutated_header, mutated_plan)),
            f"production mutation survived: {name}",
        )


EVIDENCE_DRIVER = r'''
#include "graphics/iosframeanimationevidence.h"
#include <cassert>
#include <cstdint>
#include <initializer_list>
#include <limits>
int main() {
  auto digest=[](std::initializer_list<uint64_t> words) {
    uint64_t value=IOSFrameAnimationFNV1aOffset;
    for(uint64_t word:words)
      value=iosFrameAnimationFNV1aAppendWord(value,word);
    return value;
  };
  assert(digest({})==0xcbf29ce484222325ull);
  assert(digest({0u})==0xa8c7f832281a39c5ull);
  assert(digest({1u})==0x89cd31291d2aefa4ull);
  assert(digest({1u,2u})==0x7717980363c8e066ull);
  assert(digest({std::numeric_limits<uint64_t>::max()})==0x8cf51a8bfca3883dull);
  assert(digest({2u,1u})==0x072184407c3a4ac6ull);
  IOSFrameAnimationEvidence duplicateHandle;
  duplicateHandle.selections = {
    {3u,0u,{{7u},29u}},
    {9u,2u,{{7u},29u}},
  };
  assert(!finalizeIOSFrameAnimationEvidence(duplicateHandle));
  IOSFrameAnimationEvidence mixedGeneration;
  mixedGeneration.selections = {
    {3u,0u,{{7u},29u}},
    {9u,2u,{{8u},31u}},
  };
  assert(!finalizeIOSFrameAnimationEvidence(mixedGeneration));
}
'''


def evidence_mutations(cxx: list[str], workspace: Path, source: str) -> None:
    mutations = {
        "wrong-offset": source.replace(
            "14695981039346656037ull", "1469598103934665603ull", 1
        ),
        "add-instead-of-xor": source.replace(
            "digest ^= word & uint64_t(0xffu);",
            "digest += word & uint64_t(0xffu);",
            1,
        ),
        "big-endian": source.replace("word >>= 8u;", "word <<= 8u;", 1),
        "accept-duplicate-handle": source.replace(
            "if(selection.selectedHandle==selections[prior].selectedHandle)",
            "if(false)",
            1,
        ),
        "accept-mixed-generation": source.replace(
            "else if(selection.selectedHandle.generation!=generation)",
            "else if(false)",
            1,
        ),
    }
    for name, mutated in mutations.items():
        require(mutated != source, f"FNV mutation did not match: {name}")
        root = workspace / f"mutation-{name}"
        include = root / "game/graphics"
        include.mkdir(parents=True)
        (include / "iosframeanimationevidence.h").write_text(mutated)
        driver = root / "driver.cpp"
        driver.write_text(EVIDENCE_DRIVER)
        executable = root / "driver"
        command = [
            *cxx,
            "-std=c++20",
            "-Wall",
            "-Wextra",
            "-Wconversion",
            "-Wsign-conversion",
            "-Werror",
            "-I",
            str(root / "game"),
            "-I",
            str(ROOT / "game/graphics"),
            str(driver),
            "-o",
            str(executable),
        ]
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        if compiled.returncode != 0:
            continue
        if sys.platform == "darwin" and shutil.which("codesign"):
            subprocess.run(
                ["codesign", "-f", "-s", "-", str(executable)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
        result = subprocess.run([str(executable)], cwd=ROOT, capture_output=True)
        require(result.returncode != 0, f"FNV mutation survived: {name}")


def main() -> int:
    cxx = compiler()
    extractor = EXTRACTOR.read_text()
    header = EXTRACTOR_HEADER.read_text()
    plan = PLAN.read_text()
    evidence = EVIDENCE.read_text()
    require_production_oracle(extractor, header, plan)

    with tempfile.TemporaryDirectory(prefix="p21d2-owner-a-") as temporary:
        workspace = Path(temporary)
        syntax = [
            *cxx,
            "-x",
            "c++",
            "-std=c++20",
            "-Wall",
            "-Wextra",
            "-Wconversion",
            "-Wsign-conversion",
            "-Werror",
            "-Igame",
            "-isystem",
            "lib/Tempest/Engine/include",
            "-isystem",
            "lib/ZenKit/include",
            "-fsyntax-only",
            str(EXTRACTOR),
        ]
        run(syntax, "extractor strict syntax")
        for sanitizer in (None, "address", "undefined"):
            compile_focused(cxx, workspace, sanitizer)
        evidence_mutations(cxx, workspace, evidence)

    d2a = ROOT / "scripts/test-p21d2a-frame-animation-contract.py"
    require(d2a.is_file(), "D2a contract oracle is missing")
    run([sys.executable, str(d2a)], "D2a contract oracle")
    print("P2.1d2 frame-animation vertical owner A: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"P2.1d2 frame-animation vertical owner A: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
