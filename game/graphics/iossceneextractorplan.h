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

enum class IOSSceneTextureAnimationMode : uint8_t {
  None,
  FrameOnly,
  UvOnly,
  FrameAndUv,
  };

enum class IOSSceneFrameSelectionResult : uint8_t {
  Selected,
  InvalidFrameCount,
  InvalidFramePeriod,
  };

inline constexpr IOSSceneFrameSelectionResult selectIOSSceneTextureFrame(
    uint64_t sceneTimeMs,
    uint64_t framePeriodMs,
    uint64_t frameCount,
    uint64_t& outFrameOrdinal) noexcept {
  if(frameCount==0)
    return IOSSceneFrameSelectionResult::InvalidFrameCount;
  if(framePeriodMs==0)
    return IOSSceneFrameSelectionResult::InvalidFramePeriod;
  outFrameOrdinal = (sceneTimeMs/framePeriodMs)%frameCount;
  return IOSSceneFrameSelectionResult::Selected;
  }

inline constexpr IOSSceneTextureAnimationMode iosSceneTextureAnimationMode(
    bool hasFrameAnimation, bool hasUvAnimation) noexcept {
  if(hasFrameAnimation)
    return hasUvAnimation
        ? IOSSceneTextureAnimationMode::FrameAndUv
        : IOSSceneTextureAnimationMode::FrameOnly;
  return hasUvAnimation
      ? IOSSceneTextureAnimationMode::UvOnly
      : IOSSceneTextureAnimationMode::None;
  }

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
  uint64_t       sceneTimeMs = 0;
  uint64_t       frameCount = 0;
  uint64_t       framePeriodMs = 0;
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
  IOSSceneTextureAnimationMode textureAnimation =
      IOSSceneTextureAnimationMode::None;
  uint64_t            frameOrdinal = 0;
  bool                usesFallbackTexture = false;
  };

inline IOSSceneSourcePlanResult planIOSOpaqueMeshSource(
    const IOSSceneOpaqueMeshCandidate& source,
    IOSSceneOpaqueMeshPlan& out) noexcept {
  out = IOSSceneOpaqueMeshPlan();
  const IOSSceneTextureAnimationMode textureAnimation =
      iosSceneTextureAnimationMode(
          source.hasFrameAnimation,source.hasUvAnimation);
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
  if(textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||
     textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv)
    return IOSSceneSourcePlanResult::SkippedTextureAnimation;
  if(source.materialCategory==IOSMaterialCategory::AlphaTest &&
     ((!source.hasBaseColorTexture &&
       textureAnimation!=IOSSceneTextureAnimationMode::FrameOnly) ||
      source.usesFallbackTexture))
    return IOSSceneSourcePlanResult::SkippedMaterial;
  uint64_t frameOrdinal = 0;
  if(textureAnimation==IOSSceneTextureAnimationMode::FrameOnly &&
     selectIOSSceneTextureFrame(
         source.sceneTimeMs,source.framePeriodMs,source.frameCount,
         frameOrdinal)!=IOSSceneFrameSelectionResult::Selected)
    return IOSSceneSourcePlanResult::InvalidSource;
  const bool hasEffectiveBaseColorTexture =
      source.hasBaseColorTexture ||
      textureAnimation==IOSSceneTextureAnimationMode::FrameOnly;
  if(source.materialCategory==IOSMaterialCategory::Opaque &&
     hasEffectiveBaseColorTexture==source.usesFallbackTexture)
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
  out.textureAnimation  = textureAnimation;
  out.frameOrdinal      = frameOrdinal;
  out.usesFallbackTexture = source.usesFallbackTexture;
  return IOSSceneSourcePlanResult::Planned;
  }
