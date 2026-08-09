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

enum class IOSSceneUVOffsetResult : uint8_t {
  Evaluated,
  InvalidPeriods,
  NonFinite,
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

inline IOSSceneUVOffsetResult evaluateIOSSceneUVOffset(
    uint64_t sceneTimeMs,
    int32_t periodX,
    int32_t periodY,
    IOSFloat2& outOffset) noexcept {
  outOffset = {};
  if((periodX==0 && periodY==0) ||
     periodX==std::numeric_limits<int32_t>::min() ||
     periodY==std::numeric_limits<int32_t>::min())
    return IOSSceneUVOffsetResult::InvalidPeriods;

  const uint32_t sceneTimeLow = static_cast<uint32_t>(sceneTimeMs);
  const auto evaluateAxis = [sceneTimeLow](int32_t period) noexcept {
    if(period==0)
      return 0.f;
    const int64_t widened = static_cast<int64_t>(period);
    const uint32_t magnitude = static_cast<uint32_t>(
        widened<0 ? -widened : widened);
    const float value =
        static_cast<float>(sceneTimeLow%magnitude)/
        static_cast<float>(period);
    return value==0.f ? 0.f : value;
    };

  const IOSFloat2 evaluated = {
    evaluateAxis(periodX),
    evaluateAxis(periodY),
    };
  if(!std::isfinite(evaluated.x) || !std::isfinite(evaluated.y))
    return IOSSceneUVOffsetResult::NonFinite;
  outOffset = evaluated;
  return IOSSceneUVOffsetResult::Evaluated;
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
  float          alphaWeight = 1.f;
  bool           hasFrameAnimation = false;
  bool           hasUvAnimation = false;
  bool           hasValidFrameSequence = false;
  uint64_t       sceneTimeMs = 0;
  uint64_t       frameCount = 0;
  uint64_t       framePeriodMs = 0;
  int32_t        uvPeriodX = 0;
  int32_t        uvPeriodY = 0;
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
  float               baseColorAlpha = 1.f;
  uint64_t            materialFlags = IOSMaterialFlagNone;
  uint64_t            visibilityMask = IOSSceneVisibilityMain;
  IOSSceneTextureAnimationMode textureAnimation =
      IOSSceneTextureAnimationMode::None;
  uint64_t            frameOrdinal = 0;
  int32_t             uvPeriodX = 0;
  int32_t             uvPeriodY = 0;
  IOSFloat2           uvOffset;
  bool                usesFallbackTexture = false;

  constexpr bool operator==(const IOSSceneOpaqueMeshPlan&) const noexcept =
      default;
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
    default:
      return IOSSceneSourcePlanResult::InvalidSource;
  }
  if(!source.hasMaterial)
    return IOSSceneSourcePlanResult::InvalidSource;
  switch(source.materialCategory) {
    case IOSMaterialCategory::Opaque:
    case IOSMaterialCategory::AlphaTest:
    case IOSMaterialCategory::Additive:
      break;
    case IOSMaterialCategory::Transparent:
    case IOSMaterialCategory::Water:
      return IOSSceneSourcePlanResult::SkippedMaterial;
    default:
      return IOSSceneSourcePlanResult::InvalidSource;
    }
  if(!source.hasMappedMaterialCategory)
    return IOSSceneSourcePlanResult::SkippedMaterial;
  const bool isAdditive =
      source.materialCategory==IOSMaterialCategory::Additive;
  if(isAdditive && source.kind!=IOSSceneMeshKind::Static)
    return IOSSceneSourcePlanResult::SkippedMaterial;
  if(isAdditive &&
     textureAnimation!=IOSSceneTextureAnimationMode::None)
    return IOSSceneSourcePlanResult::SkippedTextureAnimation;
  const bool periodsHaveUv = source.uvPeriodX!=0 || source.uvPeriodY!=0;
  if(source.hasUvAnimation!=periodsHaveUv)
    return IOSSceneSourcePlanResult::InvalidSource;
  if(isAdditive &&
     (!source.hasBaseColorTexture || source.usesFallbackTexture ||
      source.hasValidFrameSequence || source.frameCount!=0 ||
      !std::isfinite(source.alphaWeight) || source.alphaWeight<0.f ||
      source.alphaWeight>1.f))
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
  const bool hasEffectiveBaseColorTexture =
      source.hasBaseColorTexture || selectsFrame;
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
  out.baseColorAlpha    = isAdditive ? source.alphaWeight : 1.f;
  out.materialFlags     = isAdditive
      ? IOSMaterialFlagStaticAdditiveNone
      : IOSMaterialFlagNone;
  out.visibilityMask    = IOSSceneVisibilityMain;
  out.textureAnimation  = textureAnimation;
  out.frameOrdinal      = frameOrdinal;
  out.uvPeriodX         = source.uvPeriodX;
  out.uvPeriodY         = source.uvPeriodY;
  out.uvOffset          = uvOffset;
  out.usesFallbackTexture = source.usesFallbackTexture;
  return IOSSceneSourcePlanResult::Planned;
  }
