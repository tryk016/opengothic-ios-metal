#include "graphics/iosgpusceneplan.h"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace {

IOSGPUSceneMeshCandidate validCandidate() {
  IOSGPUSceneMeshCandidate source;
  source.snapshotGeneration    = IOSWorldGeneration{7};
  source.registryGeneration    = IOSWorldGeneration{7};
  source.entity.id             = {source.snapshotGeneration,1};
  source.entity.mesh           = {source.snapshotGeneration,2};
  source.entity.material       = {source.snapshotGeneration,3};
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
    source.entity.currentTransform.set(2u,3u,4.f);
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::Draw);
    assert(plan.indexBufferOffset==3u*sizeof(uint32_t));
    assert(plan.indexCount==6u);
    assert(plan.constants.viewProjection.at(1u,2u)==3.f);
    assert(plan.constants.model.at(2u,3u)==4.f);
    assert(plan.constants.baseColor==source.material.baseColor);
    assert(plan.baseColorTexture==source.material.baseColorTexture);
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
    auto source = validCandidate();
    source.material.category = IOSMaterialCategory::AlphaTest;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::UnsupportedMaterial);
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
  return 0;
  }
