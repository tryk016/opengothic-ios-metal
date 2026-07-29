#pragma once

#include "iosscenesnapshot.h"

#include <cmath>
#include <cstdint>
#include <limits>

enum class IOSSceneSourcePlanResult : uint8_t {
  Planned,
  SkippedKind,
  SkippedMaterial,
  SkippedTextureAnimation,
  InvalidSource,
  };

struct IOSSceneOpaqueMeshCandidate final {
  uint64_t       sourceId = 0;
  IOSSceneMeshKind kind = IOSSceneMeshKind::Unsupported;
  bool           hasStaticMesh = false;
  bool           hasMaterial = false;
  bool           hasMappedMaterialCategory = false;
  IOSMaterialCategory materialCategory = IOSMaterialCategory::Opaque;
  bool           hasBaseColorTexture = false;
  bool           usesFallbackTexture = false;
  bool           hasFrameAnimation = false;
  bool           hasUvAnimation = false;
  bool           hasLocalBounds = false;
  IOSMatrix4x4   transform;
  IOSBounds      localBounds;
  IOSIndexRange  indices;
  };

// Pointer-free plan. The four stable keys deliberately share sourceId but are
// resolved in independent IOSRenderWorld registries.
struct IOSSceneOpaqueMeshPlan final {
  IOSSceneMeshKind    kind = IOSSceneMeshKind::Unsupported;
  uint64_t            entityStableKey = 0;
  uint64_t            meshStableKey = 0;
  uint64_t            materialStableKey = 0;
  uint64_t            textureStableKey = 0;
  IOSMatrix4x4        transform;
  IOSBounds           localBounds;
  IOSIndexRange       indices;
  IOSMaterialCategory materialCategory = IOSMaterialCategory::Opaque;
  uint64_t            visibilityMask = IOSSceneVisibilityMain;
  bool                usesFallbackTexture = false;
  };

inline IOSSceneSourcePlanResult planIOSOpaqueMeshSource(
    const IOSSceneOpaqueMeshCandidate& source,
    IOSSceneOpaqueMeshPlan& out) noexcept {
  out = IOSSceneOpaqueMeshPlan();
  switch(source.kind) {
    case IOSSceneMeshKind::Landscape:
    case IOSSceneMeshKind::Static:
    case IOSSceneMeshKind::Movable:
      break;
    case IOSSceneMeshKind::Unsupported:
      return IOSSceneSourcePlanResult::SkippedKind;
    }
  if(source.kind!=IOSSceneMeshKind::Landscape &&
     source.kind!=IOSSceneMeshKind::Static &&
     source.kind!=IOSSceneMeshKind::Movable)
    return IOSSceneSourcePlanResult::SkippedKind;
  if(!source.hasMaterial)
    return IOSSceneSourcePlanResult::InvalidSource;
  if(!source.hasMappedMaterialCategory)
    return IOSSceneSourcePlanResult::SkippedMaterial;
  if(source.materialCategory!=IOSMaterialCategory::Opaque &&
     source.materialCategory!=IOSMaterialCategory::AlphaTest)
    return IOSSceneSourcePlanResult::SkippedMaterial;
  if(source.materialCategory==IOSMaterialCategory::AlphaTest &&
     (!source.hasBaseColorTexture || source.usesFallbackTexture))
    return IOSSceneSourcePlanResult::SkippedMaterial;
  if(source.hasFrameAnimation || source.hasUvAnimation)
    return IOSSceneSourcePlanResult::SkippedTextureAnimation;
  if(source.materialCategory==IOSMaterialCategory::Opaque &&
     source.hasBaseColorTexture==source.usesFallbackTexture)
    return IOSSceneSourcePlanResult::InvalidSource;
  if(source.sourceId==0 || !source.hasStaticMesh || !source.hasLocalBounds ||
     source.indices.count==0 ||
     source.indices.count%uint32_t(3)!=0 ||
     source.indices.count>
       std::numeric_limits<uint32_t>::max()-source.indices.offset)
    return IOSSceneSourcePlanResult::InvalidSource;

  for(const float value:source.transform.elements)
    if(!std::isfinite(value))
      return IOSSceneSourcePlanResult::InvalidSource;

  const auto& minimum = source.localBounds.minimum;
  const auto& maximum = source.localBounds.maximum;
  const bool finiteBounds =
      std::isfinite(minimum.x) && std::isfinite(minimum.y) &&
      std::isfinite(minimum.z) && std::isfinite(maximum.x) &&
      std::isfinite(maximum.y) && std::isfinite(maximum.z);
  const bool orderedBounds =
      minimum.x<=maximum.x &&
      minimum.y<=maximum.y &&
      minimum.z<=maximum.z;
  if(!finiteBounds || !orderedBounds)
    return IOSSceneSourcePlanResult::InvalidSource;

  out.kind              = source.kind;
  out.entityStableKey   = source.sourceId;
  out.meshStableKey     = source.sourceId;
  out.materialStableKey = source.sourceId;
  out.textureStableKey  = source.sourceId;
  out.transform         = source.transform;
  out.localBounds       = source.localBounds;
  out.indices           = source.indices;
  out.materialCategory  = source.materialCategory;
  out.visibilityMask    = IOSSceneVisibilityMain;
  out.usesFallbackTexture = source.usesFallbackTexture;
  return IOSSceneSourcePlanResult::Planned;
  }
