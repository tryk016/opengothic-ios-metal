#pragma once

#include "iosscenesnapshot.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <type_traits>

inline constexpr std::size_t IOSLandscapeVertexStride = 36u;
inline constexpr std::size_t IOSLandscapeIndexStride  = sizeof(uint32_t);

enum class IOSGPUSceneDrawPlanResult : uint8_t {
  Draw,
  SkippedVisibility,
  GenerationMismatch,
  MissingMaterial,
  UnsupportedMaterial,
  MissingTexture,
  InvalidTexture,
  MissingMesh,
  InvalidMesh,
  };

struct IOSGPUSceneMeshCandidate final {
  IOSWorldGeneration snapshotGeneration;
  IOSWorldGeneration registryGeneration;
  IOSRenderEntity     entity;
  IOSMaterial         material;
  bool                hasMaterial = false;
  bool                hasTexture = false;
  bool                hasNativeTexture = false;
  bool                hasSupportedTextureFormat = false;
  bool                hasValidNativeTexture = false;
  uint32_t            textureWidth = 0;
  uint32_t            textureHeight = 0;
  uint32_t            textureMipCount = 0;
  bool                hasMesh = false;
  bool                hasNativeVertexBuffer = false;
  bool                hasNativeIndexBuffer = false;
  std::size_t         vertexBufferByteSize = 0;
  std::size_t         indexBufferByteSize = 0;
  std::size_t         vertexStride = 0;
  std::size_t         firstIndex = 0;
  std::size_t         indexCount = 0;
  };

inline uint64_t iosGPUSceneFailingHandle(
    IOSGPUSceneDrawPlanResult result,
    const IOSGPUSceneMeshCandidate& source) noexcept {
  switch(result) {
    case IOSGPUSceneDrawPlanResult::MissingMaterial:
    case IOSGPUSceneDrawPlanResult::UnsupportedMaterial:
      return source.entity.material.value;
    case IOSGPUSceneDrawPlanResult::MissingTexture:
      return source.material.baseColorTexture
          ? source.material.baseColorTexture.value
          : source.entity.material.value;
    case IOSGPUSceneDrawPlanResult::InvalidTexture:
      return source.material.baseColorTexture.value;
    case IOSGPUSceneDrawPlanResult::GenerationMismatch:
      if(source.material.baseColorTexture &&
         source.material.baseColorTexture.generation!=
             source.snapshotGeneration)
        return source.material.baseColorTexture.value;
      if(source.entity.material.generation!=source.snapshotGeneration)
        return source.entity.material.value;
      return source.entity.mesh.value;
    case IOSGPUSceneDrawPlanResult::MissingMesh:
    case IOSGPUSceneDrawPlanResult::InvalidMesh:
      return source.entity.mesh.value;
    case IOSGPUSceneDrawPlanResult::Draw:
    case IOSGPUSceneDrawPlanResult::SkippedVisibility:
      return 0;
    }
  return 0;
  }

struct alignas(16) IOSGPUSceneDrawConstants final {
  IOSMatrix4x4 viewProjection;
  IOSMatrix4x4 model;
  IOSFloat4    baseColor;
  };

struct IOSGPUSceneDrawPlan final {
  IOSGPUSceneDrawConstants constants;
  IOSTextureHandle         baseColorTexture;
  std::size_t              indexBufferOffset = 0;
  std::size_t              indexCount = 0;
  };

inline IOSGPUSceneDrawPlanResult planIOSGPUSceneDraw(
    const IOSCameraState& camera,
    const IOSGPUSceneMeshCandidate& source,
    IOSGPUSceneDrawPlan& out) noexcept {
  out = IOSGPUSceneDrawPlan();
  if((source.entity.visibilityMask&IOSSceneVisibilityMain)==0)
    return IOSGPUSceneDrawPlanResult::SkippedVisibility;
  if(!source.snapshotGeneration || !source.registryGeneration ||
     source.snapshotGeneration!=source.registryGeneration ||
     source.entity.mesh.generation!=source.snapshotGeneration ||
     source.entity.material.generation!=source.snapshotGeneration ||
     (source.material.baseColorTexture &&
      source.material.baseColorTexture.generation!=source.snapshotGeneration))
    return IOSGPUSceneDrawPlanResult::GenerationMismatch;
  if(!source.hasMaterial || source.material.id!=source.entity.material)
    return IOSGPUSceneDrawPlanResult::MissingMaterial;
  if(source.material.category!=IOSMaterialCategory::Opaque)
    return IOSGPUSceneDrawPlanResult::UnsupportedMaterial;
  if(!source.material.baseColorTexture || !source.hasTexture)
    return IOSGPUSceneDrawPlanResult::MissingTexture;
  if(!source.hasNativeTexture || !source.hasSupportedTextureFormat ||
     !source.hasValidNativeTexture || source.textureWidth==0u ||
     source.textureHeight==0u || source.textureMipCount==0u)
    return IOSGPUSceneDrawPlanResult::InvalidTexture;

  uint32_t maximumTextureMipCount = 1u;
  uint32_t maximumTextureExtent =
      source.textureWidth>source.textureHeight
        ? source.textureWidth
        : source.textureHeight;
  while(maximumTextureExtent>1u) {
    maximumTextureExtent /= 2u;
    ++maximumTextureMipCount;
    }
  if(source.textureMipCount>maximumTextureMipCount)
    return IOSGPUSceneDrawPlanResult::InvalidTexture;
  if(!source.hasMesh)
    return IOSGPUSceneDrawPlanResult::MissingMesh;

  const bool validVertexBuffer =
      source.hasNativeVertexBuffer &&
      source.vertexStride==IOSLandscapeVertexStride &&
      source.vertexBufferByteSize>=source.vertexStride &&
      source.vertexBufferByteSize%source.vertexStride==0;
  const bool validIndexBuffer =
      source.hasNativeIndexBuffer &&
      source.indexBufferByteSize>=IOSLandscapeIndexStride &&
      source.indexBufferByteSize%IOSLandscapeIndexStride==0;
  const std::size_t availableIndices =
      validIndexBuffer
        ? source.indexBufferByteSize/IOSLandscapeIndexStride
        : 0u;
  const bool validIndexRange =
      source.indexCount!=0 &&
      source.indexCount%std::size_t(3)==0 &&
      source.firstIndex<=availableIndices &&
      source.indexCount<=availableIndices-source.firstIndex;
  if(!validVertexBuffer || !validIndexBuffer || !validIndexRange)
    return IOSGPUSceneDrawPlanResult::InvalidMesh;

  for(const float component:camera.viewProjection.elements)
    if(!std::isfinite(component))
      return IOSGPUSceneDrawPlanResult::InvalidMesh;
  for(const float component:source.entity.currentTransform.elements)
    if(!std::isfinite(component))
      return IOSGPUSceneDrawPlanResult::InvalidMesh;
  if(!std::isfinite(source.material.baseColor.x) ||
     !std::isfinite(source.material.baseColor.y) ||
     !std::isfinite(source.material.baseColor.z) ||
     !std::isfinite(source.material.baseColor.w))
    return IOSGPUSceneDrawPlanResult::InvalidMesh;

  out.constants.viewProjection = camera.viewProjection;
  out.constants.model          = source.entity.currentTransform;
  out.constants.baseColor      = source.material.baseColor;
  out.baseColorTexture         = source.material.baseColorTexture;
  out.indexBufferOffset =
      source.firstIndex*IOSLandscapeIndexStride;
  out.indexCount = source.indexCount;
  return IOSGPUSceneDrawPlanResult::Draw;
  }

static_assert(sizeof(IOSMatrix4x4)==64u);
static_assert(sizeof(IOSFloat4)==16u);
static_assert(offsetof(IOSGPUSceneDrawConstants,viewProjection)==0u);
static_assert(offsetof(IOSGPUSceneDrawConstants,model)==64u);
static_assert(offsetof(IOSGPUSceneDrawConstants,baseColor)==128u);
static_assert(sizeof(IOSGPUSceneDrawConstants)==144u);
static_assert(alignof(IOSGPUSceneDrawConstants)==16u);
static_assert(std::is_trivially_copyable_v<IOSGPUSceneDrawConstants>);
