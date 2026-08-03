#pragma once

#include "iossceneassetregistry.h"
#include "iossceneextractorplan.h"
#include "iosscenesource.h"
#include "material.h"

#include <cstddef>
#include <limits>
#include <optional>

class IOSRenderWorld;

namespace Tempest {
class Device;
}

enum class IOSSceneExtractionResult : uint8_t {
  Success,
  FrameAlreadyPopulated,
  RegistryUnavailable,
  RegistryResetRequired,
  GenerationMismatch,
  InvalidSource,
  AssetBindFailed,
  };

struct IOSSceneSourceKindCensus final {
  std::size_t landscape = 0;
  std::size_t staticMesh = 0;
  std::size_t movable = 0;
  std::size_t animated = 0;
  std::size_t particle = 0;
  std::size_t morph = 0;
  std::size_t unsupported = 0;
  std::size_t unknown = 0;

  constexpr bool operator==(const IOSSceneSourceKindCensus&) const noexcept =
      default;
  };

struct IOSSceneMaterialCensus final {
  std::size_t solid = 0;
  std::size_t alphaTest = 0;
  std::size_t water = 0;
  std::size_t ghost = 0;
  std::size_t multiply = 0;
  std::size_t multiply2 = 0;
  std::size_t transparent = 0;
  std::size_t additiveLight = 0;
  std::size_t missing = 0;
  std::size_t unknown = 0;

  constexpr bool operator==(const IOSSceneMaterialCensus&) const noexcept =
      default;
  };

struct IOSSceneSourceCensus final {
  IOSSceneSourceKindCensus kinds;
  IOSSceneMaterialCensus   materials;
  std::size_t              frameAnimated = 0;
  std::size_t              uvAnimated = 0;

  constexpr bool operator==(const IOSSceneSourceCensus&) const noexcept =
      default;
  };

inline constexpr bool incrementIOSSceneCounter(std::size_t& value) noexcept {
  if(value==std::numeric_limits<std::size_t>::max())
    return false;
  ++value;
  return true;
  }

inline constexpr bool addIOSSceneCounter(
    std::size_t& total, std::size_t value) noexcept {
  if(value>std::numeric_limits<std::size_t>::max()-total)
    return false;
  total += value;
  return true;
  }

struct IOSSceneExtractionStats final {
  IOSSceneSourceCensus census;
  std::size_t visited = 0;
  std::size_t planned = 0;
  std::size_t plannedOpaque = 0;
  std::size_t plannedAlphaTest = 0;
  std::size_t plannedLandscape = 0;
  std::size_t plannedStatic = 0;
  std::size_t plannedMovable = 0;
  std::size_t skippedKind = 0;
  std::size_t skippedMaterial = 0;
  std::size_t skippedTextureAnimation = 0;
  std::size_t fallbackTexture = 0;
  std::size_t alphaFallback = 0;
  std::size_t invalidSource = 0;

  constexpr bool operator==(const IOSSceneExtractionStats&) const noexcept =
      default;

  constexpr bool hasConsistentPlannedCounts() const noexcept {
    const bool materialSumValid =
        plannedOpaque<=
          std::numeric_limits<std::size_t>::max()-plannedAlphaTest;
    const bool firstKindSumValid =
        plannedLandscape<=
          std::numeric_limits<std::size_t>::max()-plannedStatic;
    const std::size_t firstKindSum =
        firstKindSumValid ? plannedLandscape+plannedStatic : 0u;
    const bool kindSumValid =
        firstKindSumValid &&
        firstKindSum<=
          std::numeric_limits<std::size_t>::max()-plannedMovable;
    return materialSumValid && kindSumValid &&
        planned==plannedOpaque+plannedAlphaTest &&
        planned==firstKindSum+plannedMovable &&
        alphaFallback<=plannedAlphaTest;
    }

  constexpr bool hasConsistentSuccessfulCensus() const noexcept {
    std::size_t kindTotal = 0;
    const bool kindSumValid =
        addIOSSceneCounter(kindTotal,census.kinds.landscape) &&
        addIOSSceneCounter(kindTotal,census.kinds.staticMesh) &&
        addIOSSceneCounter(kindTotal,census.kinds.movable) &&
        addIOSSceneCounter(kindTotal,census.kinds.animated) &&
        addIOSSceneCounter(kindTotal,census.kinds.particle) &&
        addIOSSceneCounter(kindTotal,census.kinds.morph) &&
        addIOSSceneCounter(kindTotal,census.kinds.unsupported) &&
        addIOSSceneCounter(kindTotal,census.kinds.unknown);
    std::size_t materialTotal = 0;
    const bool materialSumValid =
        addIOSSceneCounter(materialTotal,census.materials.solid) &&
        addIOSSceneCounter(materialTotal,census.materials.alphaTest) &&
        addIOSSceneCounter(materialTotal,census.materials.water) &&
        addIOSSceneCounter(materialTotal,census.materials.ghost) &&
        addIOSSceneCounter(materialTotal,census.materials.multiply) &&
        addIOSSceneCounter(materialTotal,census.materials.multiply2) &&
        addIOSSceneCounter(materialTotal,census.materials.transparent) &&
        addIOSSceneCounter(materialTotal,census.materials.additiveLight) &&
        addIOSSceneCounter(materialTotal,census.materials.missing) &&
        addIOSSceneCounter(materialTotal,census.materials.unknown);
    std::size_t outcomeTotal = 0;
    const bool outcomeSumValid =
        addIOSSceneCounter(outcomeTotal,planned) &&
        addIOSSceneCounter(outcomeTotal,skippedKind) &&
        addIOSSceneCounter(outcomeTotal,skippedMaterial) &&
        addIOSSceneCounter(outcomeTotal,skippedTextureAnimation);
    return hasConsistentPlannedCounts() &&
        kindSumValid && materialSumValid && outcomeSumValid &&
        kindTotal==visited && materialTotal==visited &&
        outcomeTotal==visited && invalidSource==0u &&
        census.frameAnimated<=visited && census.uvAnimated<=visited &&
        census.kinds.unknown==0u && census.materials.unknown==0u;
    }
  };

struct IOSSceneExtractionReport final {
  IOSSceneExtractionResult result = IOSSceneExtractionResult::Success;
  IOSSceneExtractionStats  stats;
  std::optional<IOSSceneAssetBindResult> bindFailure;
  };

struct IOSSceneMaterialMapping final {
  IOSMaterialCategory category = IOSMaterialCategory::Opaque;
  bool                mapped = false;

  constexpr bool operator==(const IOSSceneMaterialMapping&) const noexcept =
      default;
  };

inline constexpr IOSSceneMaterialMapping iosSceneMaterialMapping(
    Material::AlphaFunc alpha) noexcept {
  switch(alpha) {
    case Material::Solid:
      return {IOSMaterialCategory::Opaque,true};
    case Material::AlphaTest:
      return {IOSMaterialCategory::AlphaTest,true};
    case Material::Water:
    case Material::Ghost:
    case Material::Multiply:
    case Material::Multiply2:
    case Material::Transparent:
    case Material::AdditiveLight:
      return {};
    }
  return {};
  }

inline constexpr IOSSceneMeshKind iosSceneOpaqueMeshKind(
    IOSSceneSourceKind kind) noexcept {
  switch(kind) {
    case IOSSceneSourceKind::Landscape:
      return IOSSceneMeshKind::Landscape;
    case IOSSceneSourceKind::Static:
      return IOSSceneMeshKind::Static;
    case IOSSceneSourceKind::Movable:
      return IOSSceneMeshKind::Movable;
    case IOSSceneSourceKind::Animated:
    case IOSSceneSourceKind::Particle:
    case IOSSceneSourceKind::Morph:
    case IOSSceneSourceKind::Unsupported:
      return IOSSceneMeshKind::Unsupported;
    }
  return IOSSceneMeshKind::Unsupported;
  }

inline constexpr bool isIOSSceneAssetBindSuccess(
    IOSSceneAssetBindResult result) noexcept {
  return result==IOSSceneAssetBindResult::Bound ||
         result==IOSSceneAssetBindResult::AlreadyBound;
  }

inline bool recordIOSSceneInvalidSource(
    IOSSceneExtractionStats& stats) noexcept {
  (void)incrementIOSSceneCounter(stats.invalidSource);
  return false;
  }

inline bool recordIOSSceneRawSource(
    IOSSceneSourceKind kind,
    std::optional<Material::AlphaFunc> material,
    bool hasFrameAnimation,
    bool hasUvAnimation,
    IOSSceneExtractionStats& stats) noexcept {
  IOSSceneExtractionStats next = stats;
  if(!incrementIOSSceneCounter(next.visited))
    return recordIOSSceneInvalidSource(stats);

  bool knownKind = true;
  std::size_t* kindCounter = nullptr;
  switch(kind) {
    case IOSSceneSourceKind::Landscape:
      kindCounter = &next.census.kinds.landscape;
      break;
    case IOSSceneSourceKind::Static:
      kindCounter = &next.census.kinds.staticMesh;
      break;
    case IOSSceneSourceKind::Movable:
      kindCounter = &next.census.kinds.movable;
      break;
    case IOSSceneSourceKind::Animated:
      kindCounter = &next.census.kinds.animated;
      break;
    case IOSSceneSourceKind::Particle:
      kindCounter = &next.census.kinds.particle;
      break;
    case IOSSceneSourceKind::Morph:
      kindCounter = &next.census.kinds.morph;
      break;
    case IOSSceneSourceKind::Unsupported:
      kindCounter = &next.census.kinds.unsupported;
      break;
    default:
      knownKind = false;
      kindCounter = &next.census.kinds.unknown;
      break;
    }
  if(!incrementIOSSceneCounter(*kindCounter))
    return recordIOSSceneInvalidSource(stats);

  bool knownMaterial = true;
  std::size_t* materialCounter = nullptr;
  if(!material.has_value()) {
    materialCounter = &next.census.materials.missing;
    }
  else {
    switch(*material) {
      case Material::Solid:
        materialCounter = &next.census.materials.solid;
        break;
      case Material::AlphaTest:
        materialCounter = &next.census.materials.alphaTest;
        break;
      case Material::Water:
        materialCounter = &next.census.materials.water;
        break;
      case Material::Ghost:
        materialCounter = &next.census.materials.ghost;
        break;
      case Material::Multiply:
        materialCounter = &next.census.materials.multiply;
        break;
      case Material::Multiply2:
        materialCounter = &next.census.materials.multiply2;
        break;
      case Material::Transparent:
        materialCounter = &next.census.materials.transparent;
        break;
      case Material::AdditiveLight:
        materialCounter = &next.census.materials.additiveLight;
        break;
      default:
        knownMaterial = false;
        materialCounter = &next.census.materials.unknown;
        break;
      }
    }
  if(!incrementIOSSceneCounter(*materialCounter) ||
     (hasFrameAnimation &&
      !incrementIOSSceneCounter(next.census.frameAnimated)) ||
     (hasUvAnimation &&
      !incrementIOSSceneCounter(next.census.uvAnimated)))
    return recordIOSSceneInvalidSource(stats);
  if(!knownKind || !knownMaterial) {
    if(!incrementIOSSceneCounter(next.invalidSource))
      return false;
    stats = next;
    return false;
    }
  stats = next;
  return true;
  }

inline bool recordIOSScenePlanResult(
    IOSSceneSourcePlanResult result,
    const IOSSceneOpaqueMeshPlan& plan,
    IOSSceneExtractionStats& stats) noexcept {
  switch(result) {
    case IOSSceneSourcePlanResult::Planned: {
      if(plan.materialCategory!=IOSMaterialCategory::Opaque &&
         plan.materialCategory!=IOSMaterialCategory::AlphaTest) {
        return recordIOSSceneInvalidSource(stats);
        }
      if(plan.kind!=IOSSceneMeshKind::Landscape &&
         plan.kind!=IOSSceneMeshKind::Static &&
         plan.kind!=IOSSceneMeshKind::Movable) {
        return recordIOSSceneInvalidSource(stats);
        }
      IOSSceneExtractionStats next = stats;
      if(!incrementIOSSceneCounter(next.planned))
        return recordIOSSceneInvalidSource(stats);
      if(plan.materialCategory==IOSMaterialCategory::Opaque) {
        if(!incrementIOSSceneCounter(next.plannedOpaque))
          return recordIOSSceneInvalidSource(stats);
        }
      else if(!incrementIOSSceneCounter(next.plannedAlphaTest))
        return recordIOSSceneInvalidSource(stats);
      switch(plan.kind) {
        case IOSSceneMeshKind::Landscape:
          if(!incrementIOSSceneCounter(next.plannedLandscape))
            return recordIOSSceneInvalidSource(stats);
          break;
        case IOSSceneMeshKind::Static:
          if(!incrementIOSSceneCounter(next.plannedStatic))
            return recordIOSSceneInvalidSource(stats);
          break;
        case IOSSceneMeshKind::Movable:
          if(!incrementIOSSceneCounter(next.plannedMovable))
            return recordIOSSceneInvalidSource(stats);
          break;
        case IOSSceneMeshKind::Unsupported:
          return recordIOSSceneInvalidSource(stats);
        }
      if(plan.usesFallbackTexture &&
         !incrementIOSSceneCounter(next.fallbackTexture))
        return recordIOSSceneInvalidSource(stats);
      if(plan.materialCategory==IOSMaterialCategory::AlphaTest &&
         plan.usesFallbackTexture &&
         !incrementIOSSceneCounter(next.alphaFallback))
        return recordIOSSceneInvalidSource(stats);
      if(!next.hasConsistentPlannedCounts()) {
        return recordIOSSceneInvalidSource(stats);
        }
      stats = next;
      return true;
      }
    case IOSSceneSourcePlanResult::SkippedKind: {
      IOSSceneExtractionStats next = stats;
      if(!incrementIOSSceneCounter(next.skippedKind) ||
         !next.hasConsistentPlannedCounts())
        return recordIOSSceneInvalidSource(stats);
      stats = next;
      return true;
      }
    case IOSSceneSourcePlanResult::SkippedMaterial: {
      IOSSceneExtractionStats next = stats;
      if(!incrementIOSSceneCounter(next.skippedMaterial) ||
         !next.hasConsistentPlannedCounts())
        return recordIOSSceneInvalidSource(stats);
      stats = next;
      return true;
      }
    case IOSSceneSourcePlanResult::SkippedTextureAnimation: {
      IOSSceneExtractionStats next = stats;
      if(!incrementIOSSceneCounter(next.skippedTextureAnimation) ||
         !next.hasConsistentPlannedCounts())
        return recordIOSSceneInvalidSource(stats);
      stats = next;
      return true;
      }
    case IOSSceneSourcePlanResult::InvalidSource:
      return recordIOSSceneInvalidSource(stats);
    }
  return recordIOSSceneInvalidSource(stats);
  }

// The caller stages only extraction-owned entities/materials. Failure leaves
// the destination frame logically unchanged; success publishes both vectors
// together without allocation.
inline bool publishIOSSceneExtraction(
    IOSSceneExtractionResult result,
    IOSSceneFrameState& staging,
    IOSSceneFrameState& frame) noexcept {
  if(result!=IOSSceneExtractionResult::Success)
    return false;
  frame.entities.swap(staging.entities);
  frame.materials.swap(staging.materials);
  return true;
  }

class IOSSceneExtractor final {
  public:
    IOSSceneExtractionReport extractOpaqueMeshes(
        const IOSSceneSourceProvider& source,
        const Tempest::Device& device,
        IOSRenderWorld& renderWorld,
        IOSSceneAssetRegistry& assets,
        IOSSceneFrameState& frame) const;
  };
