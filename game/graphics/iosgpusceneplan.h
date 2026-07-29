#pragma once

#include "iosscenesnapshot.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
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

enum class IOSGPUScenePipelineSelector : uint8_t {
  Unsupported,
  Opaque,
  AlphaTest,
  };

inline constexpr IOSGPUScenePipelineSelector iosGPUScenePipelineSelector(
    IOSMaterialCategory category) noexcept {
  switch(category) {
    case IOSMaterialCategory::Opaque:
      return IOSGPUScenePipelineSelector::Opaque;
    case IOSMaterialCategory::AlphaTest:
      return IOSGPUScenePipelineSelector::AlphaTest;
    case IOSMaterialCategory::Transparent:
    case IOSMaterialCategory::Additive:
    case IOSMaterialCategory::Water:
      return IOSGPUScenePipelineSelector::Unsupported;
    }
  return IOSGPUScenePipelineSelector::Unsupported;
  }

inline constexpr bool iosGPUScenePipelineSelectionMatches(
    IOSMaterialCategory category,
    IOSGPUScenePipelineSelector selected) noexcept {
  const IOSGPUScenePipelineSelector expected =
      iosGPUScenePipelineSelector(category);
  return expected!=IOSGPUScenePipelineSelector::Unsupported &&
      selected==expected;
  }

struct IOSGPUSceneMaterialCounts final {
  uint64_t total = 0;
  uint64_t opaque = 0;
  uint64_t alphaTest = 0;

  constexpr bool operator==(const IOSGPUSceneMaterialCounts&) const noexcept =
      default;
  };

struct IOSGPUSceneKindCounts final {
  uint64_t total = 0;
  uint64_t landscape = 0;
  uint64_t staticMeshes = 0;
  uint64_t movable = 0;

  constexpr bool operator==(const IOSGPUSceneKindCounts&) const noexcept =
      default;
  };

struct IOSGPUSceneDrawCounts final {
  IOSGPUSceneMaterialCounts material;
  IOSGPUSceneKindCounts     kind;
  uint64_t                  texturedDraws = 0;
  uint64_t                  alphaFallback = 0;

  constexpr bool operator==(const IOSGPUSceneDrawCounts&) const noexcept =
      default;
  };

struct IOSGPUSceneFrameCounts final {
  IOSGPUSceneDrawCounts planned;
  IOSGPUSceneDrawCounts drawn;
  uint64_t              opaquePsoBinds = 0;
  uint64_t              alphaPsoBinds = 0;
  uint64_t              controlAlphaToOpaqueBinds = 0;

  constexpr bool operator==(const IOSGPUSceneFrameCounts&) const noexcept =
      default;
  };

enum class IOSGPUSceneCountResult : uint8_t {
  Recorded,
  UnknownCategory,
  UnknownKind,
  InconsistentCounts,
  Overflow,
  };

inline constexpr bool iosGPUSceneCheckedIncrement(uint64_t& value) noexcept {
  if(value==std::numeric_limits<uint64_t>::max())
    return false;
  ++value;
  return true;
  }

inline constexpr bool iosGPUSceneCountsAreConsistent(
    const IOSGPUSceneDrawCounts& counts) noexcept {
  const bool materialSumValid =
      counts.material.opaque<=
        std::numeric_limits<uint64_t>::max()-counts.material.alphaTest;
  const bool firstKindSumValid =
      counts.kind.landscape<=
        std::numeric_limits<uint64_t>::max()-counts.kind.staticMeshes;
  const uint64_t firstKindSum =
      firstKindSumValid
        ? counts.kind.landscape+counts.kind.staticMeshes
        : 0u;
  const bool kindSumValid =
      firstKindSumValid &&
      firstKindSum<=std::numeric_limits<uint64_t>::max()-counts.kind.movable;
  return materialSumValid && kindSumValid &&
      counts.material.total==
        counts.material.opaque+counts.material.alphaTest &&
      counts.kind.total==firstKindSum+counts.kind.movable &&
      counts.material.total==counts.kind.total &&
      counts.texturedDraws<=counts.material.total &&
      counts.alphaFallback<=counts.material.alphaTest;
  }

inline constexpr bool iosGPUSceneFrameDrawCountsAreConsistent(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneCountsAreConsistent(counts.planned) &&
      iosGPUSceneCountsAreConsistent(counts.drawn) &&
      counts.planned.material==counts.drawn.material &&
      counts.planned.kind==counts.drawn.kind &&
      counts.planned.texturedDraws==0u &&
      counts.planned.alphaFallback==0u &&
      counts.drawn.texturedDraws==counts.drawn.material.total &&
      counts.drawn.alphaFallback==0u;
  }

inline constexpr bool iosGPUSceneProductionFrameCountsAreConsistent(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFrameDrawCountsAreConsistent(counts) &&
      counts.opaquePsoBinds==counts.drawn.material.opaque &&
      counts.alphaPsoBinds==counts.drawn.material.alphaTest &&
      counts.controlAlphaToOpaqueBinds==0u;
  }

inline constexpr bool iosGPUSceneCausalBFrameCountsAreConsistent(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFrameDrawCountsAreConsistent(counts) &&
      counts.opaquePsoBinds==counts.drawn.material.total &&
      counts.alphaPsoBinds==0u &&
      counts.controlAlphaToOpaqueBinds==counts.drawn.material.alphaTest;
  }

inline constexpr IOSGPUSceneCountResult recordIOSGPUSceneDrawCount(
    IOSMaterialCategory category,
    IOSSceneMeshKind kind,
    bool usesFallbackTexture,
    bool textured,
    IOSGPUSceneDrawCounts& counts) noexcept {
  const IOSGPUScenePipelineSelector selector =
      iosGPUScenePipelineSelector(category);
  if(selector==IOSGPUScenePipelineSelector::Unsupported)
    return IOSGPUSceneCountResult::UnknownCategory;
  switch(kind) {
    case IOSSceneMeshKind::Landscape:
    case IOSSceneMeshKind::Static:
    case IOSSceneMeshKind::Movable:
      break;
    case IOSSceneMeshKind::Unsupported:
      return IOSGPUSceneCountResult::UnknownKind;
    }
  if(kind!=IOSSceneMeshKind::Landscape &&
     kind!=IOSSceneMeshKind::Static &&
     kind!=IOSSceneMeshKind::Movable)
    return IOSGPUSceneCountResult::UnknownKind;
  if(!iosGPUSceneCountsAreConsistent(counts))
    return IOSGPUSceneCountResult::InconsistentCounts;

  IOSGPUSceneDrawCounts next = counts;
  if(!iosGPUSceneCheckedIncrement(next.material.total) ||
     !iosGPUSceneCheckedIncrement(next.kind.total))
    return IOSGPUSceneCountResult::Overflow;
  if(selector==IOSGPUScenePipelineSelector::Opaque) {
    if(!iosGPUSceneCheckedIncrement(next.material.opaque))
      return IOSGPUSceneCountResult::Overflow;
    }
  else if(!iosGPUSceneCheckedIncrement(next.material.alphaTest)) {
    return IOSGPUSceneCountResult::Overflow;
    }
  switch(kind) {
    case IOSSceneMeshKind::Landscape:
      if(!iosGPUSceneCheckedIncrement(next.kind.landscape))
        return IOSGPUSceneCountResult::Overflow;
      break;
    case IOSSceneMeshKind::Static:
      if(!iosGPUSceneCheckedIncrement(next.kind.staticMeshes))
        return IOSGPUSceneCountResult::Overflow;
      break;
    case IOSSceneMeshKind::Movable:
      if(!iosGPUSceneCheckedIncrement(next.kind.movable))
        return IOSGPUSceneCountResult::Overflow;
      break;
    case IOSSceneMeshKind::Unsupported:
      return IOSGPUSceneCountResult::UnknownKind;
    }
  if(textured && !iosGPUSceneCheckedIncrement(next.texturedDraws))
    return IOSGPUSceneCountResult::Overflow;
  if(selector==IOSGPUScenePipelineSelector::AlphaTest &&
     usesFallbackTexture &&
     !iosGPUSceneCheckedIncrement(next.alphaFallback))
    return IOSGPUSceneCountResult::Overflow;
  if(!iosGPUSceneCountsAreConsistent(next))
    return IOSGPUSceneCountResult::InconsistentCounts;
  counts = next;
  return IOSGPUSceneCountResult::Recorded;
  }

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
  IOSMaterialCategory      materialCategory = IOSMaterialCategory::Opaque;
  IOSSceneMeshKind         kind = IOSSceneMeshKind::Unsupported;
  IOSGPUScenePipelineSelector pipeline =
      IOSGPUScenePipelineSelector::Unsupported;
  bool                     usesFallbackTexture = false;
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
  const IOSGPUScenePipelineSelector pipeline =
      iosGPUScenePipelineSelector(source.material.category);
  // C3b1 exposes the neutral selector but keeps production GPU admission
  // fail-closed until the AlphaTest PSO and encode land atomically in C3b2.
  if(pipeline!=IOSGPUScenePipelineSelector::Opaque)
    return IOSGPUSceneDrawPlanResult::UnsupportedMaterial;
  switch(source.entity.kind) {
    case IOSSceneMeshKind::Landscape:
    case IOSSceneMeshKind::Static:
    case IOSSceneMeshKind::Movable:
      break;
    case IOSSceneMeshKind::Unsupported:
      return IOSGPUSceneDrawPlanResult::InvalidMesh;
    }
  if(source.entity.kind!=IOSSceneMeshKind::Landscape &&
     source.entity.kind!=IOSSceneMeshKind::Static &&
     source.entity.kind!=IOSSceneMeshKind::Movable)
    return IOSGPUSceneDrawPlanResult::InvalidMesh;
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
  out.materialCategory         = source.material.category;
  out.kind                     = source.entity.kind;
  out.pipeline                 = pipeline;
  out.usesFallbackTexture      = source.material.usesFallbackTexture;
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
