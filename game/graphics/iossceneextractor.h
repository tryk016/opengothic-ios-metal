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

struct IOSSceneExtractionStats final {
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

inline bool recordIOSScenePlanResult(
    IOSSceneSourcePlanResult result,
    const IOSSceneOpaqueMeshPlan& plan,
    IOSSceneExtractionStats& stats) noexcept {
  switch(result) {
    case IOSSceneSourcePlanResult::Planned: {
      if(plan.materialCategory!=IOSMaterialCategory::Opaque &&
         plan.materialCategory!=IOSMaterialCategory::AlphaTest) {
        ++stats.invalidSource;
        return false;
        }
      if(plan.kind!=IOSSceneMeshKind::Landscape &&
         plan.kind!=IOSSceneMeshKind::Static &&
         plan.kind!=IOSSceneMeshKind::Movable) {
        ++stats.invalidSource;
        return false;
        }
      IOSSceneExtractionStats next = stats;
      const auto increment = [](std::size_t& value) noexcept {
        if(value==std::numeric_limits<std::size_t>::max())
          return false;
        ++value;
        return true;
        };
      if(!increment(next.planned)) {
        ++stats.invalidSource;
        return false;
        }
      if(plan.materialCategory==IOSMaterialCategory::Opaque) {
        if(!increment(next.plannedOpaque)) {
          ++stats.invalidSource;
          return false;
          }
        }
      else if(!increment(next.plannedAlphaTest)) {
        ++stats.invalidSource;
        return false;
        }
      switch(plan.kind) {
        case IOSSceneMeshKind::Landscape:
          if(!increment(next.plannedLandscape)) {
            ++stats.invalidSource;
            return false;
            }
          break;
        case IOSSceneMeshKind::Static:
          if(!increment(next.plannedStatic)) {
            ++stats.invalidSource;
            return false;
            }
          break;
        case IOSSceneMeshKind::Movable:
          if(!increment(next.plannedMovable)) {
            ++stats.invalidSource;
            return false;
            }
          break;
        case IOSSceneMeshKind::Unsupported:
          ++stats.invalidSource;
          return false;
        }
      if(plan.usesFallbackTexture &&
         !increment(next.fallbackTexture)) {
        ++stats.invalidSource;
        return false;
        }
      if(plan.materialCategory==IOSMaterialCategory::AlphaTest &&
         plan.usesFallbackTexture &&
         !increment(next.alphaFallback)) {
        ++stats.invalidSource;
        return false;
        }
      if(!next.hasConsistentPlannedCounts()) {
        ++stats.invalidSource;
        return false;
        }
      stats = next;
      return true;
      }
    case IOSSceneSourcePlanResult::SkippedKind:
      ++stats.skippedKind;
      return stats.hasConsistentPlannedCounts();
    case IOSSceneSourcePlanResult::SkippedMaterial:
      ++stats.skippedMaterial;
      return stats.hasConsistentPlannedCounts();
    case IOSSceneSourcePlanResult::SkippedTextureAnimation:
      ++stats.skippedTextureAnimation;
      return stats.hasConsistentPlannedCounts();
    case IOSSceneSourcePlanResult::InvalidSource:
      ++stats.invalidSource;
      return false;
    }
  ++stats.invalidSource;
  return false;
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
