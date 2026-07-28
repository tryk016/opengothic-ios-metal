#pragma once

#include "iossceneassetregistry.h"
#include "iossceneextractorplan.h"
#include "iosscenesource.h"

#include <cstddef>
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
  std::size_t plannedLandscape = 0;
  std::size_t plannedStatic = 0;
  std::size_t plannedMovable = 0;
  std::size_t skippedKind = 0;
  std::size_t skippedMaterial = 0;
  std::size_t skippedTextureAnimation = 0;
  std::size_t fallbackTexture = 0;
  std::size_t invalidSource = 0;

  constexpr bool hasConsistentPlannedCounts() const noexcept {
    return planned==plannedLandscape+plannedStatic+plannedMovable;
    }
  };

struct IOSSceneExtractionReport final {
  IOSSceneExtractionResult result = IOSSceneExtractionResult::Success;
  IOSSceneExtractionStats  stats;
  std::optional<IOSSceneAssetBindResult> bindFailure;
  };

inline constexpr IOSSceneOpaqueMeshKind iosSceneOpaqueMeshKind(
    IOSSceneSourceKind kind) noexcept {
  switch(kind) {
    case IOSSceneSourceKind::Landscape:
      return IOSSceneOpaqueMeshKind::Landscape;
    case IOSSceneSourceKind::Static:
      return IOSSceneOpaqueMeshKind::Static;
    case IOSSceneSourceKind::Movable:
      return IOSSceneOpaqueMeshKind::Movable;
    case IOSSceneSourceKind::Animated:
    case IOSSceneSourceKind::Particle:
    case IOSSceneSourceKind::Morph:
    case IOSSceneSourceKind::Unsupported:
      return IOSSceneOpaqueMeshKind::Unsupported;
    }
  return IOSSceneOpaqueMeshKind::Unsupported;
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
    case IOSSceneSourcePlanResult::Planned:
      switch(plan.kind) {
        case IOSSceneOpaqueMeshKind::Landscape:
          ++stats.planned;
          ++stats.plannedLandscape;
          break;
        case IOSSceneOpaqueMeshKind::Static:
          ++stats.planned;
          ++stats.plannedStatic;
          break;
        case IOSSceneOpaqueMeshKind::Movable:
          ++stats.planned;
          ++stats.plannedMovable;
          break;
        case IOSSceneOpaqueMeshKind::Unsupported:
          ++stats.invalidSource;
          return false;
        }
      if(plan.kind!=IOSSceneOpaqueMeshKind::Landscape &&
         plan.kind!=IOSSceneOpaqueMeshKind::Static &&
         plan.kind!=IOSSceneOpaqueMeshKind::Movable) {
        ++stats.invalidSource;
        return false;
        }
      if(plan.usesFallbackTexture)
        ++stats.fallbackTexture;
      return stats.hasConsistentPlannedCounts();
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
