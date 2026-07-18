#pragma once

#include "iosscenesnapshot.h"

#include <cmath>
#include <cstdint>
#include <limits>

enum class IOSSceneSourcePlanResult : uint8_t {
  Planned,
  SkippedKind,
  SkippedMaterial,
  InvalidSource,
  };

struct IOSSceneLandscapeCandidate final {
  uint64_t       sourceId = 0;
  bool           isLandscape = false;
  bool           hasStaticMesh = false;
  bool           hasMaterial = false;
  bool           isSolidMaterial = false;
  bool           hasLocalBounds = false;
  IOSMatrix4x4   transform;
  IOSBounds      localBounds;
  IOSIndexRange  indices;
  };

// Pointer-free plan. The three stable keys deliberately share sourceId but are
// resolved in independent IOSRenderWorld registries.
struct IOSSceneLandscapePlan final {
  uint64_t            entityStableKey = 0;
  uint64_t            meshStableKey = 0;
  uint64_t            materialStableKey = 0;
  IOSMatrix4x4        transform;
  IOSBounds           localBounds;
  IOSIndexRange       indices;
  IOSMaterialCategory materialCategory = IOSMaterialCategory::Opaque;
  uint64_t            visibilityMask = IOSSceneVisibilityMain;
  };

inline IOSSceneSourcePlanResult planIOSLandscapeSource(
    const IOSSceneLandscapeCandidate& source,
    IOSSceneLandscapePlan& out) noexcept {
  out = IOSSceneLandscapePlan();
  if(!source.isLandscape)
    return IOSSceneSourcePlanResult::SkippedKind;
  if(!source.hasMaterial)
    return IOSSceneSourcePlanResult::InvalidSource;
  if(!source.isSolidMaterial)
    return IOSSceneSourcePlanResult::SkippedMaterial;
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

  out.entityStableKey   = source.sourceId;
  out.meshStableKey     = source.sourceId;
  out.materialStableKey = source.sourceId;
  out.transform         = source.transform;
  out.localBounds       = source.localBounds;
  out.indices           = source.indices;
  out.materialCategory  = IOSMaterialCategory::Opaque;
  out.visibilityMask    = IOSSceneVisibilityMain;
  return IOSSceneSourcePlanResult::Planned;
  }
