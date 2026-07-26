#include "graphics/iosfeaturepolicy.h"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <type_traits>
#include <utility>

namespace {

constexpr uint8_t ProbeCount =
    static_cast<uint8_t>(IOSDeviceProbeId::Count);
constexpr uint8_t FormatCount =
    static_cast<uint8_t>(IOSDeviceFormatId::Count);
constexpr uint8_t LimitCount =
    static_cast<uint8_t>(IOSDeviceLimitId::Count);

constexpr IOSFeatureId Features[ProbeCount] = {
  IOSFeatureId::MetalFxSpatial,
  IOSFeatureId::MetalFxTemporal,
  IOSFeatureId::MeshShading,
  IOSFeatureId::RayTracing,
  IOSFeatureId::Metal4Transport,
  };

constexpr uint8_t RequiredFormatUsages[FormatCount] = {
  0x0Bu,0x0Bu,0x03u,0x05u,0x05u,
  };

IOSDeviceFactsData canonicalData() {
  IOSDeviceFactsData data{};
  data.abiVersion = IOSDeviceFactsABIVersion;
  data.structSize = IOSDeviceFactsStructSize;
  data.probeContractVersion = IOSDeviceProbeContractVersion;
  data.probeCount = ProbeCount;
  data.formatCount = FormatCount;
  data.limitCount = LimitCount;
  for(uint8_t i=0u; i<ProbeCount; ++i) {
    data.probes[i].requiredStages = IOSDeviceRequiredProbeStages;
    data.probes[i].probeId = i;
    }
  for(uint8_t i=0u; i<FormatCount; ++i)
    data.formats[i].requiredUsages = RequiredFormatUsages[i];
  return data;
  }

IOSDeviceFacts requireFacts(const IOSDeviceFactsData& data) {
  IOSDeviceFactsCreateResult result = IOSDeviceFacts::create(data);
  assert(result.value.has_value());
  assert(result.failure.error==IOSDeviceFactsError::None);
  return std::move(*result.value);
  }

IOSDeviceFacts factsWithProbe(
    uint8_t index,
    uint8_t knownStages,
    uint8_t passedStages) {
  IOSDeviceFactsData data = canonicalData();
  data.probes[index].knownStages = knownStages;
  data.probes[index].passedStages = passedStages;
  return requireFacts(data);
  }

void expectState(
    const IOSFeaturePolicyState& state,
    bool requested,
    bool eligible,
    bool active,
    IOSFeatureFallbackReason fallbackReason) {
  assert(state.requested==requested);
  assert(state.eligible==eligible);
  assert(state.active==active);
  assert(state.fallbackReason==fallbackReason);
  assert((state.fallbackReason==IOSFeatureFallbackReason::None)==
         state.active);
  }

}

int main() {
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSFeatureId>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSFeatureFallbackReason>,uint8_t>);
  static_assert(static_cast<uint8_t>(
      IOSFeatureId::MetalFxSpatial)==0u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureId::MetalFxTemporal)==1u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureId::MeshShading)==2u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureId::RayTracing)==3u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureId::Metal4Transport)==4u);
  static_assert(static_cast<uint8_t>(IOSFeatureId::Count)==5u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::None)==0u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::InvalidFeature)==1u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::NotRequested)==2u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::AvailabilityUnknown)==3u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::AvailabilityUnsupported)==4u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::DeviceSupportUnknown)==5u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::DeviceSupportUnsupported)==6u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::ActivationFailed)==7u);

  using EvaluateSignature = IOSFeaturePolicyState (*)(
      const IOSDeviceFacts&,IOSFeaturePolicyInput) noexcept;
  static_assert(std::is_same_v<
      decltype(&iosEvaluateFeaturePolicy),EvaluateSignature>);
  static_assert(noexcept(iosEvaluateFeaturePolicy(
      std::declval<const IOSDeviceFacts&>(),
      std::declval<IOSFeaturePolicyInput>())));

  for(uint8_t i=0u; i<ProbeCount; ++i) {
    const IOSDeviceFacts facts =
        factsWithProbe(i,IOSDeviceRequiredProbeStages,
                      IOSDeviceRequiredProbeStages);
    expectState(
        iosEvaluateFeaturePolicy(
            facts,{Features[i],true,true}),
        true,true,true,IOSFeatureFallbackReason::None);
    for(uint8_t other=0u; other<ProbeCount; ++other) {
      if(other==i)
        continue;
      expectState(
          iosEvaluateFeaturePolicy(
              facts,{Features[other],true,true}),
          true,false,false,
          IOSFeatureFallbackReason::AvailabilityUnknown);
      }
    }

  const IOSDeviceFacts supported =
      factsWithProbe(0u,IOSDeviceRequiredProbeStages,
                     IOSDeviceRequiredProbeStages);
  expectState(
      iosEvaluateFeaturePolicy(
          supported,{IOSFeatureId::MetalFxSpatial,false,true}),
      false,true,false,IOSFeatureFallbackReason::NotRequested);
  expectState(
      iosEvaluateFeaturePolicy(
          supported,{IOSFeatureId::Count,false,true}),
      false,false,false,IOSFeatureFallbackReason::InvalidFeature);
  expectState(
      iosEvaluateFeaturePolicy(
          supported,
          {static_cast<IOSFeatureId>(0xFFu),true,true}),
      true,false,false,IOSFeatureFallbackReason::InvalidFeature);
  expectState(
      iosEvaluateFeaturePolicy(
          supported,{IOSFeatureId::MetalFxSpatial,true,false}),
      true,true,false,IOSFeatureFallbackReason::ActivationFailed);

  const IOSDeviceFacts availabilityUnknown =
      factsWithProbe(0u,0u,0u);
  expectState(
      iosEvaluateFeaturePolicy(
          availabilityUnknown,
          {IOSFeatureId::MetalFxSpatial,true,true}),
      true,false,false,
      IOSFeatureFallbackReason::AvailabilityUnknown);

  const IOSDeviceFacts availabilityUnsupported =
      factsWithProbe(0u,Availability,0u);
  expectState(
      iosEvaluateFeaturePolicy(
          availabilityUnsupported,
          {IOSFeatureId::MetalFxSpatial,true,true}),
      true,false,false,
      IOSFeatureFallbackReason::AvailabilityUnsupported);

  const IOSDeviceFacts deviceSupportUnknown =
      factsWithProbe(0u,Availability,Availability);
  expectState(
      iosEvaluateFeaturePolicy(
          deviceSupportUnknown,
          {IOSFeatureId::MetalFxSpatial,true,true}),
      true,false,false,
      IOSFeatureFallbackReason::DeviceSupportUnknown);

  const IOSDeviceFacts deviceSupportUnsupported =
      factsWithProbe(0u,IOSDeviceRequiredProbeStages,Availability);
  expectState(
      iosEvaluateFeaturePolicy(
          deviceSupportUnsupported,
          {IOSFeatureId::MetalFxSpatial,true,true}),
      true,false,false,
      IOSFeatureFallbackReason::DeviceSupportUnsupported);
  expectState(
      iosEvaluateFeaturePolicy(
          deviceSupportUnsupported,
          {IOSFeatureId::MetalFxSpatial,false,true}),
      false,false,false,IOSFeatureFallbackReason::NotRequested);

  IOSDeviceFactsData unrelatedPositive = canonicalData();
  unrelatedPositive.highestKnownAppleFamily = 10u;
  unrelatedPositive.highestKnownMetalFamily = 4u;
  for(uint8_t i=0u; i<FormatCount; ++i) {
    unrelatedPositive.formats[i].knownUsages =
        unrelatedPositive.formats[i].requiredUsages;
    unrelatedPositive.formats[i].supportedUsages =
        unrelatedPositive.formats[i].requiredUsages;
    }
  unrelatedPositive.knownLimitMask = (1u << LimitCount)-1u;
  for(uint8_t i=0u; i<LimitCount; ++i)
    unrelatedPositive.limits[i] = uint32_t(i)+1u;
  const IOSDeviceFacts unrelated = requireFacts(unrelatedPositive);
  expectState(
      iosEvaluateFeaturePolicy(
          unrelated,{IOSFeatureId::Metal4Transport,true,true}),
      true,false,false,
      IOSFeatureFallbackReason::AvailabilityUnknown);

  return 0;
  }
