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
  InvalidDefaultClass = 8u,
  };

enum class IOSFeatureDefaultClass : uint8_t {
  Safe = 0u,
  Apple8 = 1u,
  Apple9 = 2u,
  Apple10 = 3u,
  Count = 4u,
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

struct IOSFeaturePolicyDefaultsInput final {
  IOSFeatureId feature;
  IOSFeatureDefaultClass defaults;
  bool activationSucceeded;
  };

struct IOSFeatureDefaultRequest final {
  bool requested;
  IOSFeatureFallbackReason fallbackReason;
  };

IOSFeaturePolicyState iosEvaluateFeaturePolicy(
    const IOSDeviceFacts& facts,
    IOSFeaturePolicyInput input) noexcept;

IOSFeatureDefaultRequest iosResolveFeatureDefaultRequest(
    IOSFeatureId feature,
    IOSFeatureDefaultClass defaults) noexcept;

IOSFeaturePolicyState iosEvaluateFeaturePolicyDefaults(
    const IOSDeviceFacts& facts,
    IOSFeaturePolicyDefaultsInput input) noexcept;

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

static_assert(sizeof(IOSFeaturePolicyDefaultsInput)==3u);
static_assert(alignof(IOSFeaturePolicyDefaultsInput)==1u);
static_assert(std::is_standard_layout_v<IOSFeaturePolicyDefaultsInput>);
static_assert(std::is_trivially_copyable_v<IOSFeaturePolicyDefaultsInput>);
static_assert(offsetof(IOSFeaturePolicyDefaultsInput,feature)==0u);
static_assert(offsetof(IOSFeaturePolicyDefaultsInput,defaults)==1u);
static_assert(
    offsetof(IOSFeaturePolicyDefaultsInput,activationSucceeded)==2u);

static_assert(sizeof(IOSFeatureDefaultRequest)==2u);
static_assert(alignof(IOSFeatureDefaultRequest)==1u);
static_assert(std::is_standard_layout_v<IOSFeatureDefaultRequest>);
static_assert(std::is_trivially_copyable_v<IOSFeatureDefaultRequest>);
static_assert(offsetof(IOSFeatureDefaultRequest,requested)==0u);
static_assert(offsetof(IOSFeatureDefaultRequest,fallbackReason)==1u);
