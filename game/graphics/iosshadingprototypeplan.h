#pragma once

#include "iosframeplan.h"

#include <array>
#include <cstdint>

inline constexpr uint32_t IOSShadingPrototypePlanABIVersion = 1u;
inline constexpr uint32_t IOSShadingPrototypeNoPass = 0xffffffffu;

enum class IOSShadingPrototypeKind : uint8_t {
  TileDeferred = 0,
  ForwardPlus  = 1,
  };

struct IOSShadingPrototypeCommonContract final {
  uint32_t       opaqueGeometryInputs = 1u;
  uint32_t       alphaTestGeometryInputs = 1u;
  uint32_t       lightInputs = 1u;
  IOSPixelFormat presentFormat = IOSPixelFormat::Bgra8Unorm;
  IOSPixelFormat outputFormat = IOSPixelFormat::Rgba8Unorm;
  IOSExtent2D    outputExtent = {4u,4u};
  uint32_t       outputMipLevels = 1u;
  uint32_t       outputSampleCount = 1u;

  friend bool operator==(IOSShadingPrototypeCommonContract,
                         IOSShadingPrototypeCommonContract) = default;
  };

struct IOSShadingPrototypeRuntimeContract final {
  uint32_t borrowedExistingDevice = 1u;
  uint32_t borrowedExistingQueue = 1u;
  uint32_t borrowedVirginCommandBuffer = 1u;
  uint32_t contextOwnsFence = 1u;
  uint32_t createsDevice = 0u;
  uint32_t createsQueue = 0u;
  uint32_t createsCommandBuffer = 0u;
  uint32_t commits = 0u;
  uint32_t waits = 0u;
  uint32_t drawableAcquisitions = 0u;
  uint32_t presents = 0u;

  friend bool operator==(IOSShadingPrototypeRuntimeContract,
                         IOSShadingPrototypeRuntimeContract) = default;
  };

enum class IOSShadingPrototypeOperation : uint8_t {
  BuildLightList         = 0,
  DrawOpaque             = 1,
  DrawAlphaTest          = 2,
  DispatchTileLighting   = 3,
  };

struct IOSShadingPrototypeTopology final {
  uint32_t commandBuffers = 0u;
  uint32_t submits = 0u;
  uint32_t renderEncoders = 0u;
  uint32_t draws = 0u;
  uint32_t tileDispatches = 0u;
  uint32_t computeEncoders = 0u;
  uint32_t drawableAcquisitions = 0u;
  uint32_t presents = 0u;
  uint32_t operationCount = 0u;
  std::array<IOSShadingPrototypeOperation,3u> operations = {};

  friend bool operator==(IOSShadingPrototypeTopology,
                         IOSShadingPrototypeTopology) = default;
  };

enum class IOSShadingPrototypePlanError : uint8_t {
  None                    = 0,
  UnsupportedKind         = 1,
  InvalidFramePlan        = 2,
  CommonContractMismatch  = 3,
  RuntimeContractMismatch = 4,
  TopologyMismatch        = 5,
  FramePlanMismatch       = 6,
  };

struct IOSShadingPrototypePlanValidation final {
  IOSShadingPrototypePlanError error =
      IOSShadingPrototypePlanError::None;
  IOSFramePlanValidation framePlan;

  explicit operator bool() const noexcept {
    return error==IOSShadingPrototypePlanError::None;
    }
  };

struct IOSShadingPrototypePlan final {
  IOSShadingPrototypeKind           kind =
      IOSShadingPrototypeKind::TileDeferred;
  IOSShadingPrototypeCommonContract common;
  IOSShadingPrototypeRuntimeContract runtime;
  IOSShadingPrototypeTopology       topology;
  IOSFramePlan                      framePlan;

  IOSShadingPrototypePlanValidation validate() const noexcept;
  };

enum class IOSShadingPrototypeSelectionStatus : uint8_t {
  Supported   = 0,
  Invalid     = 1,
  Unsupported = 2,
  };

struct IOSShadingPrototypePlanSelection final {
  IOSShadingPrototypeSelectionStatus status =
      IOSShadingPrototypeSelectionStatus::Unsupported;
  IOSShadingPrototypeKind kind =
      IOSShadingPrototypeKind::TileDeferred;
  uint32_t presentResource = 0u;
  uint32_t outputResource = 0u;
  uint32_t workingResource = 0u;
  uint32_t computePass = IOSShadingPrototypeNoPass;
  uint32_t renderPass = 0u;
  uint32_t presentPass = 0u;

  explicit operator bool() const noexcept {
    return status==IOSShadingPrototypeSelectionStatus::Supported;
    }
  };

[[nodiscard]] IOSShadingPrototypeCommonContract
    iosShadingPrototypeCommonContract() noexcept;

[[nodiscard]] IOSShadingPrototypeRuntimeContract
    iosShadingPrototypeRuntimeContract() noexcept;

[[nodiscard]] IOSShadingPrototypePlan
    iosShadingPrototypePlan(IOSShadingPrototypeKind kind);

[[nodiscard]] IOSShadingPrototypePlanSelection
    iosShadingPrototypeSelectPlan(
        const IOSShadingPrototypePlan& plan) noexcept;
