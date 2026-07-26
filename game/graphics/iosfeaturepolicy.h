#pragma once

#include "iosdevicecapabilities.h"

#include <cstddef>
#include <cstdint>
#include <type_traits>

enum class IOSFeatureId : uint8_t {
  MetalFxSpatial = 0u,
  MetalFxTemporal = 1u,
  MeshShading = 2u,
  RayTracing = 3u,
  Metal4Transport = 4u,
  Count = 5u,
  };

enum class IOSFeatureFallbackReason : uint8_t {
  None = 0u,
  InvalidFeature = 1u,
  NotRequested = 2u,
  AvailabilityUnknown = 3u,
  AvailabilityUnsupported = 4u,
  DeviceSupportUnknown = 5u,
  DeviceSupportUnsupported = 6u,
  ActivationFailed = 7u,
  };

struct IOSFeaturePolicyInput final {
  IOSFeatureId feature;
  bool requested;
  bool activationSucceeded;
  };

struct IOSFeaturePolicyState final {
  bool requested;
  bool eligible;
  bool active;
  IOSFeatureFallbackReason fallbackReason;
  };

IOSFeaturePolicyState iosEvaluateFeaturePolicy(
    const IOSDeviceFacts& facts,
    IOSFeaturePolicyInput input) noexcept;

static_assert(sizeof(IOSFeaturePolicyInput)==3u);
static_assert(alignof(IOSFeaturePolicyInput)==1u);
static_assert(std::is_standard_layout_v<IOSFeaturePolicyInput>);
static_assert(std::is_trivially_copyable_v<IOSFeaturePolicyInput>);
static_assert(offsetof(IOSFeaturePolicyInput,feature)==0u);
static_assert(offsetof(IOSFeaturePolicyInput,requested)==1u);
static_assert(offsetof(IOSFeaturePolicyInput,activationSucceeded)==2u);

static_assert(sizeof(IOSFeaturePolicyState)==4u);
static_assert(alignof(IOSFeaturePolicyState)==1u);
static_assert(std::is_standard_layout_v<IOSFeaturePolicyState>);
static_assert(std::is_trivially_copyable_v<IOSFeaturePolicyState>);
static_assert(offsetof(IOSFeaturePolicyState,requested)==0u);
static_assert(offsetof(IOSFeaturePolicyState,eligible)==1u);
static_assert(offsetof(IOSFeaturePolicyState,active)==2u);
static_assert(offsetof(IOSFeaturePolicyState,fallbackReason)==3u);
