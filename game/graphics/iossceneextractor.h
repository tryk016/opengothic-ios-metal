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
  std::size_t skippedKind = 0;
  std::size_t skippedMaterial = 0;
  std::size_t skippedTextureAnimation = 0;
  std::size_t fallbackTexture = 0;
  std::size_t invalidSource = 0;
  };

struct IOSSceneExtractionReport final {
  IOSSceneExtractionResult result = IOSSceneExtractionResult::Success;
  IOSSceneExtractionStats  stats;
  std::optional<IOSSceneAssetBindResult> bindFailure;
  };

class IOSSceneExtractor final {
  public:
    IOSSceneExtractionReport extractLandscape(
        const IOSSceneSourceProvider& source,
        const Tempest::Device& device,
        IOSRenderWorld& renderWorld,
        IOSSceneAssetRegistry& assets,
        IOSSceneFrameState& frame) const;
  };
