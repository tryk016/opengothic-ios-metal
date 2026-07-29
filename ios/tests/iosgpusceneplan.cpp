#include "graphics/iosgpusceneplan.h"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>
#include <utility>

namespace {

// Exact P2.1c2 compositional fixture, mirrored in iosscenecontract.cpp.
constexpr uint64_t MovableSourceId = 0x21C2u;

IOSMatrix4x4 movableT1() {
  IOSMatrix4x4 transform;
  transform.set(0u,3u,44.f);
  transform.set(1u,3u,55.f);
  transform.set(2u,3u,66.f);
  return transform;
  }

IOSGPUSceneMeshCandidate validCandidate() {
  IOSGPUSceneMeshCandidate source;
  source.snapshotGeneration    = IOSWorldGeneration{7};
  source.registryGeneration    = IOSWorldGeneration{7};
  source.entity.id             = {source.snapshotGeneration,1};
  source.entity.mesh           = {source.snapshotGeneration,2};
  source.entity.material       = {source.snapshotGeneration,3};
  source.entity.kind           = IOSSceneMeshKind::Landscape;
  source.entity.visibilityMask = IOSSceneVisibilityMain;
  source.material.id           = source.entity.material;
  source.material.category     = IOSMaterialCategory::Opaque;
  source.material.baseColor    = {0.25f,0.5f,0.75f,1.f};
  source.material.baseColorTexture = {source.snapshotGeneration,4};
  source.hasMaterial           = true;
  source.hasTexture            = true;
  source.hasNativeTexture      = true;
  source.hasSupportedTextureFormat = true;
  source.hasValidNativeTexture = true;
  source.textureWidth          = 512u;
  source.textureHeight         = 256u;
  source.textureMipCount       = 10u;
  source.hasMesh               = true;
  source.hasNativeVertexBuffer = true;
  source.hasNativeIndexBuffer  = true;
  source.vertexBufferByteSize  = IOSLandscapeVertexStride*4u;
  source.indexBufferByteSize   = IOSLandscapeIndexStride*12u;
  source.vertexStride          = IOSLandscapeVertexStride;
  source.firstIndex            = 3u;
  source.indexCount            = 6u;
  return source;
  }

}

int main() {
  IOSCameraState camera;
  camera.viewProjection.set(1u,2u,3.f);

  {
    auto source = validCandidate();
    source.entity.id.value = MovableSourceId;
    source.entity.kind = IOSSceneMeshKind::Movable;
    source.entity.currentTransform = movableT1();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::Draw);
    assert(plan.indexBufferOffset==3u*sizeof(uint32_t));
    assert(plan.indexCount==6u);
    assert(plan.constants.viewProjection.at(1u,2u)==3.f);
    assert(plan.constants.model==movableT1());
    assert(plan.constants.baseColor==source.material.baseColor);
    assert(plan.baseColorTexture==source.material.baseColorTexture);
    assert(plan.materialCategory==IOSMaterialCategory::Opaque);
    assert(plan.kind==IOSSceneMeshKind::Movable);
    assert(plan.pipeline==IOSGPUScenePipelineSelector::Opaque);
    assert(!plan.usesFallbackTexture);
    assert(iosGPUSceneFailingHandle(
               IOSGPUSceneDrawPlanResult::Draw,source)==0u);
  }

  {
    auto source = validCandidate();
    source.entity.visibilityMask = IOSSceneVisibilityShadow;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::SkippedVisibility);
  }

  {
    auto source = validCandidate();
    source.registryGeneration = IOSWorldGeneration{8};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::GenerationMismatch);
  }

  {
    auto source = validCandidate();
    source.hasMaterial = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingMaterial);
  }

  {
    auto source = validCandidate();
    source.material.id.value += 1u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingMaterial);
  }

  {
    assert(iosGPUScenePipelineSelector(IOSMaterialCategory::Opaque)==
           IOSGPUScenePipelineSelector::Opaque);
    assert(iosGPUScenePipelineSelector(IOSMaterialCategory::AlphaTest)==
           IOSGPUScenePipelineSelector::AlphaTest);
    assert(iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::Opaque,
        IOSGPUScenePipelineSelector::Opaque));
    assert(iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::AlphaTest,
        IOSGPUScenePipelineSelector::AlphaTest));
    assert(!iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::Opaque,
        IOSGPUScenePipelineSelector::AlphaTest));
    assert(!iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::AlphaTest,
        IOSGPUScenePipelineSelector::Opaque));
    assert(!iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::Opaque,
        IOSGPUScenePipelineSelector::Unsupported));
    for(unsigned mask=0u; mask<8u; ++mask) {
      const bool vertex = (mask&1u)!=0u;
      const bool opaqueFragment = (mask&2u)!=0u;
      const bool alphaTestFragment = (mask&4u)!=0u;
      assert(iosGPUSceneRequiredShaderFunctionsAreAvailable(
                 vertex,opaqueFragment,alphaTestFragment)==
             (mask==7u));
      }
    for(unsigned mask=0u; mask<4u; ++mask) {
      const bool opaque = (mask&1u)!=0u;
      const bool alphaTest = (mask&2u)!=0u;
      assert(iosGPUSceneProductionPipelineStatesAreAvailable(
                 opaque,alphaTest)==
             (mask==3u));
      }
    for(const auto category:{
          IOSMaterialCategory::Transparent,
          IOSMaterialCategory::Additive,
          IOSMaterialCategory::Water,
          static_cast<IOSMaterialCategory>(255u)}) {
      assert(iosGPUScenePipelineSelector(category)==
             IOSGPUScenePipelineSelector::Unsupported);
      auto source = validCandidate();
      source.material.category = category;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::UnsupportedMaterial);
      }
    for(const auto kind:{
          IOSSceneMeshKind::Landscape,
          IOSSceneMeshKind::Static,
          IOSSceneMeshKind::Movable}) {
      auto source = validCandidate();
      source.entity.kind = kind;
      source.material.category = IOSMaterialCategory::AlphaTest;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::Draw);
      assert(plan.kind==kind);
      assert(plan.materialCategory==IOSMaterialCategory::AlphaTest);
      assert(plan.pipeline==IOSGPUScenePipelineSelector::AlphaTest);
      assert(!plan.usesFallbackTexture);
      }
  }

  {
    for(const auto kind:{
          IOSSceneMeshKind::Landscape,
          IOSSceneMeshKind::Static,
          IOSSceneMeshKind::Movable}) {
      auto source = validCandidate();
      source.entity.kind = kind;
      source.material.usesFallbackTexture =
          kind==IOSSceneMeshKind::Static;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::Draw);
      assert(plan.kind==kind);
      assert(plan.materialCategory==IOSMaterialCategory::Opaque);
      assert(plan.pipeline==IOSGPUScenePipelineSelector::Opaque);
      assert(plan.usesFallbackTexture==
             source.material.usesFallbackTexture);
      }
  }

  {
    for(const auto kind:{
          IOSSceneMeshKind::Unsupported,
          static_cast<IOSSceneMeshKind>(255u)}) {
      auto source = validCandidate();
      source.entity.kind = kind;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::InvalidMesh);
      }
  }

  {
    auto source = validCandidate();
    source.material.baseColorTexture = {};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingTexture);
    assert(iosGPUSceneFailingHandle(
               IOSGPUSceneDrawPlanResult::MissingTexture,source)==
           source.entity.material.value);
  }

  {
    for(const bool removeHandle:{false,true}) {
      auto source = validCandidate();
      source.material.category = IOSMaterialCategory::AlphaTest;
      if(removeHandle)
        source.material.baseColorTexture = {};
      else
        source.hasTexture = false;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::MissingAlphaTexture);
      assert(iosGPUSceneFailingHandle(
                 IOSGPUSceneDrawPlanResult::MissingAlphaTexture,source)!=0u);
      }

    auto fallback = validCandidate();
    fallback.material.category = IOSMaterialCategory::AlphaTest;
    fallback.material.usesFallbackTexture = true;
    IOSGPUSceneDrawPlan fallbackPlan;
    assert(planIOSGPUSceneDraw(camera,fallback,fallbackPlan)==
           IOSGPUSceneDrawPlanResult::MissingAlphaTexture);

    for(const float cutoff:{
          0.f,0.499f,0.501f,1.f,
          std::numeric_limits<float>::quiet_NaN()}) {
      auto source = validCandidate();
      source.material.category = IOSMaterialCategory::AlphaTest;
      source.material.alphaCutoff = cutoff;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::InvalidAlphaCutoff);
      assert(iosGPUSceneFailingHandle(
                 IOSGPUSceneDrawPlanResult::InvalidAlphaCutoff,source)==
             source.entity.material.value);
      }
  }

  {
    auto source = validCandidate();
    source.material.baseColorTexture.generation = IOSWorldGeneration{8};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::GenerationMismatch);
    assert(iosGPUSceneFailingHandle(
               IOSGPUSceneDrawPlanResult::GenerationMismatch,source)==
           source.material.baseColorTexture.value);
  }

  {
    auto source = validCandidate();
    source.hasTexture = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingTexture);
  }

  {
    auto source = validCandidate();
    source.hasNativeTexture = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
    assert(iosGPUSceneFailingHandle(
               IOSGPUSceneDrawPlanResult::InvalidTexture,source)==
           source.material.baseColorTexture.value);
  }

  {
    auto source = validCandidate();
    source.hasSupportedTextureFormat = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.hasValidNativeTexture = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.textureWidth = 0u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.textureHeight = 0u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.textureMipCount = 0u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.textureMipCount = 11u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.hasMesh = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingMesh);
  }

  {
    auto source = validCandidate();
    source.entity.mesh.generation = IOSWorldGeneration{8};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::GenerationMismatch);
  }

  {
    auto source = validCandidate();
    source.entity.material.generation = IOSWorldGeneration{8};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::GenerationMismatch);
  }

  {
    auto source = validCandidate();
    source.hasNativeVertexBuffer = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.hasNativeIndexBuffer = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.vertexStride = IOSLandscapeVertexStride+4u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.vertexBufferByteSize = IOSLandscapeVertexStride+1u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.indexBufferByteSize -= 1u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.indexCount = 0u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.indexCount = 5u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.firstIndex = 10u;
    source.indexCount = 6u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    IOSGPUSceneDrawPlan plan;
    plan.indexBufferOffset = 99u;
    plan.indexCount        = 88u;
    plan.constants.baseColor = {1.f,1.f,1.f,1.f};
    source.hasMesh = false;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingMesh);
    assert(plan.indexBufferOffset==0u);
    assert(plan.indexCount==0u);
    assert(plan.constants.baseColor==IOSFloat4{});
    assert(plan.baseColorTexture==IOSTextureHandle{});
    assert(plan.materialCategory==IOSMaterialCategory::Opaque);
    assert(plan.kind==IOSSceneMeshKind::Unsupported);
    assert(plan.pipeline==IOSGPUScenePipelineSelector::Unsupported);
    assert(!plan.usesFallbackTexture);
  }

  {
    auto invalidCamera = camera;
    invalidCamera.viewProjection.elements[0] =
        std::numeric_limits<float>::infinity();
    auto source = validCandidate();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(invalidCamera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.entity.currentTransform.elements[0] =
        std::numeric_limits<float>::quiet_NaN();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.material.baseColor.x =
        std::numeric_limits<float>::infinity();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    IOSGPUSceneDrawCounts counts;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
        true,true,counts)==IOSGPUSceneCountResult::Recorded);
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Static,
        false,true,counts)==IOSGPUSceneCountResult::Recorded);
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Movable,
        true,false,counts)==IOSGPUSceneCountResult::Recorded);
    assert(counts.material.total==3u);
    assert(counts.material.opaque==1u);
    assert(counts.material.alphaTest==2u);
    assert(counts.kind.total==3u);
    assert(counts.kind.landscape==1u);
    assert(counts.kind.staticMeshes==1u);
    assert(counts.kind.movable==1u);
    assert(counts.texturedDraws==2u);
    assert(counts.alphaFallback==1u);
    assert(iosGPUSceneCountsAreConsistent(counts));

    const IOSGPUSceneDrawCounts before = counts;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Water,IOSSceneMeshKind::Landscape,
        false,true,counts)==IOSGPUSceneCountResult::UnknownCategory);
    assert(counts==before);
    assert(recordIOSGPUSceneDrawCount(
        static_cast<IOSMaterialCategory>(255u),
        IOSSceneMeshKind::Landscape,
        false,true,counts)==IOSGPUSceneCountResult::UnknownCategory);
    assert(counts==before);
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Unsupported,
        false,true,counts)==IOSGPUSceneCountResult::UnknownKind);
    assert(counts==before);
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,
        static_cast<IOSSceneMeshKind>(255u),
        false,true,counts)==IOSGPUSceneCountResult::UnknownKind);
    assert(counts==before);

    for(std::size_t mutation=0u; mutation<8u; ++mutation) {
      auto broken = before;
      switch(mutation) {
        case 0u: ++broken.material.total; break;
        case 1u: ++broken.material.opaque; break;
        case 2u: ++broken.material.alphaTest; break;
        case 3u: ++broken.kind.total; break;
        case 4u: ++broken.kind.landscape; break;
        case 5u: ++broken.kind.staticMeshes; break;
        case 6u: ++broken.kind.movable; break;
        case 7u: broken.alphaFallback =
            broken.material.alphaTest+1u; break;
      }
      assert(!iosGPUSceneCountsAreConsistent(broken));
      const auto brokenBefore = broken;
      assert(recordIOSGPUSceneDrawCount(
          IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
          false,true,broken)==
          IOSGPUSceneCountResult::InconsistentCounts);
      assert(broken==brokenBefore);
      }
    auto excessiveTextured = before;
    excessiveTextured.texturedDraws =
        excessiveTextured.material.total+1u;
    assert(!iosGPUSceneCountsAreConsistent(excessiveTextured));
    const auto excessiveTexturedBefore = excessiveTextured;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
        false,true,excessiveTextured)==
        IOSGPUSceneCountResult::InconsistentCounts);
    assert(excessiveTextured==excessiveTexturedBefore);

    IOSGPUSceneDrawCounts overflow;
    overflow.material.total = std::numeric_limits<uint64_t>::max();
    overflow.material.opaque = overflow.material.total;
    overflow.kind.total = overflow.material.total;
    overflow.kind.landscape = overflow.kind.total;
    overflow.texturedDraws = overflow.material.total;
    assert(iosGPUSceneCountsAreConsistent(overflow));
    const auto overflowBefore = overflow;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
        false,true,overflow)==IOSGPUSceneCountResult::Overflow);
    assert(overflow==overflowBefore);

    auto corrupted = before;
    ++corrupted.kind.total;
    const auto corruptedBefore = corrupted;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
        false,true,corrupted)==
        IOSGPUSceneCountResult::InconsistentCounts);
    assert(corrupted==corruptedBefore);
  }

  {
    IOSGPUSceneFrameCounts counts;
    for(const auto entry:{
          std::pair{IOSMaterialCategory::Opaque,
                    IOSSceneMeshKind::Landscape},
          std::pair{IOSMaterialCategory::AlphaTest,
                    IOSSceneMeshKind::Static},
          std::pair{IOSMaterialCategory::AlphaTest,
                    IOSSceneMeshKind::Movable}}) {
      assert(recordIOSGPUSceneDrawCount(
          entry.first,entry.second,false,false,counts.planned)==
          IOSGPUSceneCountResult::Recorded);
      assert(recordIOSGPUSceneDrawCount(
          entry.first,entry.second,false,true,counts.drawn)==
          IOSGPUSceneCountResult::Recorded);
      }
    counts.opaquePsoBinds = 1u;
    counts.alphaPsoBinds = 2u;
    assert(iosGPUSceneProductionFrameCountsAreConsistent(counts));
    IOSGPUSceneFailureCounts failures;
    assert(iosGPUSceneFailureCountsAreClear(failures));
    assert(iosGPUSceneProductionReportCountsAreConsistent(
        counts,failures));

    for(std::size_t mutation=0u; mutation<9u; ++mutation) {
      auto broken = failures;
      switch(mutation) {
        case 0u: ++broken.unknownCategory; break;
        case 1u: ++broken.unknownKind; break;
        case 2u: ++broken.invalidCutoff; break;
        case 3u: ++broken.missingAlphaTexture; break;
        case 4u: ++broken.selectorMismatch; break;
        case 5u: ++broken.psoUnavailable; break;
        case 6u: ++broken.overflow; break;
        case 7u: ++broken.plannedDrawn; break;
        case 8u: ++broken.nativeEncode; break;
        }
      assert(!iosGPUSceneFailureCountsAreClear(broken));
      assert(!iosGPUSceneProductionReportCountsAreConsistent(
          counts,broken));
      }

    for(std::size_t mutation=0u; mutation<23u; ++mutation) {
      auto broken = counts;
      switch(mutation) {
        case 0u: ++broken.planned.material.total; break;
        case 1u: ++broken.planned.material.opaque; break;
        case 2u: ++broken.planned.material.alphaTest; break;
        case 3u: ++broken.planned.kind.total; break;
        case 4u: ++broken.planned.kind.landscape; break;
        case 5u: ++broken.planned.kind.staticMeshes; break;
        case 6u: ++broken.planned.kind.movable; break;
        case 7u: ++broken.planned.texturedDraws; break;
        case 8u: ++broken.planned.alphaFallback; break;
        case 9u: ++broken.drawn.material.total; break;
        case 10u: ++broken.drawn.material.opaque; break;
        case 11u: ++broken.drawn.material.alphaTest; break;
        case 12u: ++broken.drawn.kind.total; break;
        case 13u: ++broken.drawn.kind.landscape; break;
        case 14u: ++broken.drawn.kind.staticMeshes; break;
        case 15u: ++broken.drawn.kind.movable; break;
        case 16u: --broken.drawn.texturedDraws; break;
        case 17u: ++broken.drawn.alphaFallback; break;
        case 18u: ++broken.opaquePsoBinds; break;
        case 19u: ++broken.alphaPsoBinds; break;
        case 20u: ++broken.controlAlphaToOpaqueBinds; break;
        case 21u: --broken.planned.material.total; break;
        case 22u: --broken.drawn.kind.total; break;
        }
      assert(!iosGPUSceneProductionFrameCountsAreConsistent(broken));
      }

    auto alphaFallback = counts;
    alphaFallback.drawn.alphaFallback = 1u;
    assert(!iosGPUSceneProductionFrameCountsAreConsistent(alphaFallback));

    auto causalB = counts;
    causalB.opaquePsoBinds = causalB.drawn.material.total;
    causalB.alphaPsoBinds = 0u;
    causalB.controlAlphaToOpaqueBinds =
        causalB.drawn.material.alphaTest;
    assert(iosGPUSceneCausalBFrameCountsAreConsistent(causalB));
    assert(!iosGPUSceneProductionFrameCountsAreConsistent(causalB));
    assert(!iosGPUSceneCausalBFrameCountsAreConsistent(counts));

    for(std::size_t mutation=0u; mutation<3u; ++mutation) {
      auto broken = causalB;
      switch(mutation) {
        case 0u: ++broken.opaquePsoBinds; break;
        case 1u: ++broken.alphaPsoBinds; break;
        case 2u: ++broken.controlAlphaToOpaqueBinds; break;
        }
      assert(!iosGPUSceneCausalBFrameCountsAreConsistent(broken));
      }
  }

  {
    IOSGPUSceneFrameCounts counts;
    counts.planned.material = {3u,1u,2u};
    counts.planned.kind = {3u,1u,1u,1u};
    counts.drawn.material = {3u,1u,2u};
    counts.drawn.kind = {3u,1u,1u,1u};
    counts.drawn.texturedDraws = 3u;
    counts.opaquePsoBinds = 1u;
    counts.alphaPsoBinds = 2u;
    IOSGPUSceneFailureCounts failures;

    const auto assertMarker = [](
        const IOSGPUSceneMarker& marker,
        std::string_view expected) {
      assert(marker);
      assert(marker.length==expected.size());
      assert(marker.length<IOSGPUSceneMarkerCapacity);
      assert(std::string_view(marker.text.data(),marker.length)==expected);
      };
    assertMarker(
        iosGPUSceneIdentityMarker(7u,300u),
        "RendererIOS native scene identity: mode=production "
        "generation=7 sequence=300");
    assertMarker(
        iosGPUSceneMaterialPlannedMarker(counts),
        "RendererIOS native scene material-planned: mode=production "
        "total=3 opaque=1 alpha=2");
    assertMarker(
        iosGPUSceneMaterialDrawnMarker(counts),
        "RendererIOS native scene material-drawn: mode=production "
        "total=3 opaque=1 alpha=2 textured=3");
    assertMarker(
        iosGPUSceneKindPlannedMarker(counts),
        "RendererIOS native scene kind-planned: mode=production "
        "total=3 landscape=1 static=1 movable=1");
    assertMarker(
        iosGPUSceneKindDrawnMarker(counts),
        "RendererIOS native scene kind-drawn: mode=production "
        "total=3 landscape=1 static=1 movable=1");
    assertMarker(
        iosGPUSceneAlphaMarker(counts),
        "RendererIOS native scene alpha: mode=production "
        "opaque-pso=1 alpha-pso=2 control-alpha-to-opaque=0 "
        "alpha-fallback=0");
    assertMarker(
        iosGPUSceneFailContractMarker(failures),
        "RendererIOS native scene fail-contract: mode=production "
        "unknown-category=0 unknown-kind=0 invalid-cutoff=0 "
        "missing-alpha-texture=0");
    assertMarker(
        iosGPUSceneFailSelectorMarker(failures),
        "RendererIOS native scene fail-selector: mode=production "
        "selector-mismatch=0 pso-unavailable=0");
    assertMarker(
        iosGPUSceneFailExecutionMarker(failures),
        "RendererIOS native scene fail-execution: mode=production "
        "overflow=0 planned-drawn=0 native-encode=0");

    constexpr uint64_t maximum =
        std::numeric_limits<uint64_t>::max();
    IOSGPUSceneFrameCounts worstFrame;
    worstFrame.planned.material = {maximum,maximum,maximum};
    worstFrame.planned.kind = {maximum,maximum,maximum,maximum};
    worstFrame.drawn.material = {maximum,maximum,maximum};
    worstFrame.drawn.kind = {maximum,maximum,maximum,maximum};
    worstFrame.drawn.texturedDraws = maximum;
    worstFrame.drawn.alphaFallback = maximum;
    worstFrame.opaquePsoBinds = maximum;
    worstFrame.alphaPsoBinds = maximum;
    worstFrame.controlAlphaToOpaqueBinds = maximum;
    IOSGPUSceneFailureCounts worstFailure = {
      maximum,maximum,maximum,maximum,maximum,
      maximum,maximum,maximum,maximum,
      };
    const IOSGPUSceneMarker worstMarkers[] = {
      iosGPUSceneIdentityMarker(maximum,maximum),
      iosGPUSceneMaterialPlannedMarker(worstFrame),
      iosGPUSceneMaterialDrawnMarker(worstFrame),
      iosGPUSceneKindPlannedMarker(worstFrame),
      iosGPUSceneKindDrawnMarker(worstFrame),
      iosGPUSceneAlphaMarker(worstFrame),
      iosGPUSceneFailContractMarker(worstFailure),
      iosGPUSceneFailSelectorMarker(worstFailure),
      iosGPUSceneFailExecutionMarker(worstFailure),
      };
    for(const auto& marker:worstMarkers) {
      assert(marker);
      assert(marker.length<IOSGPUSceneMarkerCapacity);
      }
  }
  return 0;
  }
