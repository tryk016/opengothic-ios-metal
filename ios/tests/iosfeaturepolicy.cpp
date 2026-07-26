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
constexpr uint8_t DefaultClassCount =
    static_cast<uint8_t>(IOSFeatureDefaultClass::Count);

constexpr IOSFeatureId Features[ProbeCount] = {
  IOSFeatureId::MetalFxSpatial,
  IOSFeatureId::MetalFxTemporal,
  IOSFeatureId::MeshShading,
  IOSFeatureId::RayTracing,
  IOSFeatureId::Metal4Transport,
  };

constexpr IOSFeatureDefaultClass DefaultClasses[DefaultClassCount] = {
  IOSFeatureDefaultClass::Safe,
  IOSFeatureDefaultClass::Apple8,
  IOSFeatureDefaultClass::Apple9,
  IOSFeatureDefaultClass::Apple10,
  };

constexpr bool ExpectedRequests[DefaultClassCount][ProbeCount] = {
  {false,false,false,false,false},
  {true, true, false,false,false},
  {true, true, true, true, false},
  {true, true, true, true, true },
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

IOSDeviceFacts factsWithAllProbes(
    uint8_t knownStages,
    uint8_t passedStages) {
  IOSDeviceFactsData data = canonicalData();
  for(uint8_t i=0u; i<ProbeCount; ++i) {
    data.probes[i].knownStages = knownStages;
    data.probes[i].passedStages = passedStages;
    }
  return requireFacts(data);
  }

IOSDeviceFacts factsWithSingleProbe(
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

void expectDefaultRequest(
    IOSFeatureId feature,
    IOSFeatureDefaultClass defaults,
    bool requested,
    IOSFeatureFallbackReason fallbackReason) {
  const IOSFeatureDefaultRequest request =
      iosResolveFeatureDefaultRequest(feature,defaults);
  assert(request.requested==requested);
  assert(request.fallbackReason==fallbackReason);
  }

void testExactDefaultMatrix() {
  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  const IOSDeviceFacts unknown = factsWithAllProbes(0u,0u);

  for(uint8_t defaults=0u; defaults<DefaultClassCount; ++defaults) {
    for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
      const bool requested = ExpectedRequests[defaults][feature];
      expectDefaultRequest(
          Features[feature],DefaultClasses[defaults],
          requested,IOSFeatureFallbackReason::None);
      expectState(
          iosEvaluateFeaturePolicyDefaults(
              supported,
              {Features[feature],DefaultClasses[defaults],true}),
          requested,true,requested,
          requested
              ? IOSFeatureFallbackReason::None
              : IOSFeatureFallbackReason::NotRequested);
      expectState(
          iosEvaluateFeaturePolicyDefaults(
              unknown,
              {Features[feature],DefaultClasses[defaults],true}),
          requested,false,false,
          requested
              ? IOSFeatureFallbackReason::AvailabilityUnknown
              : IOSFeatureFallbackReason::NotRequested);
      }
    }
  }

void testCapabilityFallbacksForEveryFeature() {
  struct CapabilityCase final {
    uint8_t knownStages;
    uint8_t passedStages;
    IOSFeatureFallbackReason fallbackReason;
    };
  constexpr CapabilityCase cases[] = {
    {0u,0u,IOSFeatureFallbackReason::AvailabilityUnknown},
    {Availability,0u,
        IOSFeatureFallbackReason::AvailabilityUnsupported},
    {Availability,Availability,
        IOSFeatureFallbackReason::DeviceSupportUnknown},
    {IOSDeviceRequiredProbeStages,Availability,
        IOSFeatureFallbackReason::DeviceSupportUnsupported},
    };
  for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
    for(const CapabilityCase& capability:cases) {
      const IOSDeviceFacts facts = factsWithSingleProbe(
          feature,capability.knownStages,capability.passedStages);
      expectState(
          iosEvaluateFeaturePolicyDefaults(
              facts,
              {Features[feature],IOSFeatureDefaultClass::Apple10,true}),
          true,false,false,capability.fallbackReason);
      }
    }
  }

void testActivationFailureForEveryFeature() {
  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
    expectState(
        iosEvaluateFeaturePolicyDefaults(
            supported,
            {Features[feature],IOSFeatureDefaultClass::Apple10,false}),
        true,true,false,IOSFeatureFallbackReason::ActivationFailed);
    }
  }

void testInvalidInputsAndPrecedence() {
  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  const IOSDeviceFacts unknown = factsWithAllProbes(0u,0u);
  constexpr IOSFeatureId InvalidFeature =
      static_cast<IOSFeatureId>(0xFFu);
  constexpr IOSFeatureDefaultClass InvalidDefaults =
      static_cast<IOSFeatureDefaultClass>(0xFFu);

  for(const IOSFeatureId feature:
      {IOSFeatureId::Count,InvalidFeature}) {
    for(const IOSFeatureDefaultClass defaults:
        {IOSFeatureDefaultClass::Count,InvalidDefaults}) {
      expectDefaultRequest(
          feature,defaults,false,
          IOSFeatureFallbackReason::InvalidFeature);
      expectState(
          iosEvaluateFeaturePolicyDefaults(
              supported,{feature,defaults,true}),
          false,false,false,IOSFeatureFallbackReason::InvalidFeature);
      }
    }

  for(const IOSFeatureDefaultClass defaults:
      {IOSFeatureDefaultClass::Count,InvalidDefaults}) {
    expectDefaultRequest(
        IOSFeatureId::RayTracing,defaults,false,
        IOSFeatureFallbackReason::InvalidDefaultClass);
    expectState(
        iosEvaluateFeaturePolicyDefaults(
            supported,{IOSFeatureId::RayTracing,defaults,true}),
        false,true,false,
        IOSFeatureFallbackReason::InvalidDefaultClass);
    expectState(
        iosEvaluateFeaturePolicyDefaults(
            unknown,{IOSFeatureId::RayTracing,defaults,true}),
        false,false,false,
        IOSFeatureFallbackReason::InvalidDefaultClass);
    }
  }

void testFactsNeverChooseOrBypassDefaults() {
  IOSDeviceFactsData lowData = canonicalData();
  for(uint8_t i=0u; i<ProbeCount; ++i) {
    lowData.probes[i].knownStages = IOSDeviceRequiredProbeStages;
    lowData.probes[i].passedStages = IOSDeviceRequiredProbeStages;
    }
  IOSDeviceFactsData highData = lowData;
  highData.highestKnownAppleFamily = 10u;
  highData.highestKnownMetalFamily = 4u;
  highData.runtimeVersion = {99u,1u,2u,0u};
  highData.sdkVersion = {99u,3u,4u,0u};
  for(uint8_t i=0u; i<FormatCount; ++i) {
    highData.formats[i].knownUsages =
        highData.formats[i].requiredUsages;
    highData.formats[i].supportedUsages =
        highData.formats[i].requiredUsages;
    }
  highData.knownLimitMask = (1u << LimitCount)-1u;
  for(uint8_t i=0u; i<LimitCount; ++i)
    highData.limits[i] = uint32_t(i)+1u;

  const IOSDeviceFacts low = requireFacts(lowData);
  const IOSDeviceFacts high = requireFacts(highData);
  for(uint8_t defaults=0u; defaults<DefaultClassCount; ++defaults) {
    for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
      const bool requested = ExpectedRequests[defaults][feature];
      const IOSFeaturePolicyState lowState =
          iosEvaluateFeaturePolicyDefaults(
              low,{Features[feature],DefaultClasses[defaults],true});
      const IOSFeaturePolicyState highState =
          iosEvaluateFeaturePolicyDefaults(
              high,{Features[feature],DefaultClasses[defaults],true});
      expectState(
          lowState,requested,true,requested,
          requested
              ? IOSFeatureFallbackReason::None
              : IOSFeatureFallbackReason::NotRequested);
      expectState(
          highState,requested,true,requested,
          requested
              ? IOSFeatureFallbackReason::None
              : IOSFeatureFallbackReason::NotRequested);
      }
    }

  const IOSDeviceFacts empty = factsWithAllProbes(0u,0u);
  const IOSDeviceFacts negativeAvailability =
      factsWithAllProbes(Availability,0u);
  const IOSDeviceFacts negativeSupport = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,Availability);
  for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
    expectState(
        iosEvaluateFeaturePolicyDefaults(
            empty,
            {Features[feature],IOSFeatureDefaultClass::Apple10,true}),
        true,false,false,IOSFeatureFallbackReason::AvailabilityUnknown);
    expectState(
        iosEvaluateFeaturePolicyDefaults(
            negativeAvailability,
            {Features[feature],IOSFeatureDefaultClass::Apple10,true}),
        true,false,false,
        IOSFeatureFallbackReason::AvailabilityUnsupported);
    expectState(
        iosEvaluateFeaturePolicyDefaults(
            negativeSupport,
            {Features[feature],IOSFeatureDefaultClass::Apple10,true}),
        true,false,false,
        IOSFeatureFallbackReason::DeviceSupportUnsupported);
    }
  }

void testExplicitRequestRegression() {
  for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
    const IOSDeviceFacts facts = factsWithSingleProbe(
        feature,IOSDeviceRequiredProbeStages,
        IOSDeviceRequiredProbeStages);
    expectState(
        iosEvaluateFeaturePolicy(
            facts,{Features[feature],true,true}),
        true,true,true,IOSFeatureFallbackReason::None);
    expectState(
        iosEvaluateFeaturePolicy(
            facts,{Features[feature],false,true}),
        false,true,false,IOSFeatureFallbackReason::NotRequested);
    expectState(
        iosEvaluateFeaturePolicy(
            facts,{Features[feature],true,false}),
        true,true,false,IOSFeatureFallbackReason::ActivationFailed);
    }

  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  expectState(
      iosEvaluateFeaturePolicy(
          supported,{IOSFeatureId::Count,false,true}),
      false,false,false,IOSFeatureFallbackReason::InvalidFeature);
  expectState(
      iosEvaluateFeaturePolicy(
          supported,
          {static_cast<IOSFeatureId>(0xFFu),true,true}),
      true,false,false,IOSFeatureFallbackReason::InvalidFeature);
  }

}

int main() {
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSFeatureId>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSFeatureFallbackReason>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSFeatureDefaultClass>,uint8_t>);
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
  static_assert(static_cast<uint8_t>(
      IOSFeatureFallbackReason::InvalidDefaultClass)==8u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureDefaultClass::Safe)==0u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureDefaultClass::Apple8)==1u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureDefaultClass::Apple9)==2u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureDefaultClass::Apple10)==3u);
  static_assert(static_cast<uint8_t>(
      IOSFeatureDefaultClass::Count)==4u);

  using EvaluateSignature = IOSFeaturePolicyState (*)(
      const IOSDeviceFacts&,IOSFeaturePolicyInput) noexcept;
  using ResolveSignature = IOSFeatureDefaultRequest (*)(
      IOSFeatureId,IOSFeatureDefaultClass) noexcept;
  using EvaluateDefaultsSignature = IOSFeaturePolicyState (*)(
      const IOSDeviceFacts&,IOSFeaturePolicyDefaultsInput) noexcept;
  static_assert(std::is_same_v<
      decltype(&iosEvaluateFeaturePolicy),EvaluateSignature>);
  static_assert(std::is_same_v<
      decltype(&iosResolveFeatureDefaultRequest),ResolveSignature>);
  static_assert(std::is_same_v<
      decltype(&iosEvaluateFeaturePolicyDefaults),
      EvaluateDefaultsSignature>);
  static_assert(noexcept(iosEvaluateFeaturePolicy(
      std::declval<const IOSDeviceFacts&>(),
      std::declval<IOSFeaturePolicyInput>())));
  static_assert(noexcept(iosResolveFeatureDefaultRequest(
      std::declval<IOSFeatureId>(),
      std::declval<IOSFeatureDefaultClass>())));
  static_assert(noexcept(iosEvaluateFeaturePolicyDefaults(
      std::declval<const IOSDeviceFacts&>(),
      std::declval<IOSFeaturePolicyDefaultsInput>())));

  testExactDefaultMatrix();
  testCapabilityFallbacksForEveryFeature();
  testActivationFailureForEveryFeature();
  testInvalidInputsAndPrecedence();
  testFactsNeverChooseOrBypassDefaults();
  testExplicitRequestRegression();
  return 0;
  }
