#include "graphics/iosfeaturepolicy.h"
#include "graphics/iosfeaturepolicyprovenance.h"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
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

constexpr IOSFeatureActivationResults allActivation(
    bool value) noexcept {
  return {value,value,value,value,value};
  }

IOSFeatureActivationResults activationFailureAt(
    uint8_t feature) noexcept {
  IOSFeatureActivationResults activation = allActivation(true);
  switch(feature) {
    case 0u:
      activation.metalFxSpatial = false;
      break;
    case 1u:
      activation.metalFxTemporal = false;
      break;
    case 2u:
      activation.meshShading = false;
      break;
    case 3u:
      activation.rayTracing = false;
      break;
    case 4u:
      activation.metal4Transport = false;
      break;
    default:
      assert(false);
      break;
    }
  return activation;
  }

void expectDecision(
    const IOSFeaturePolicyProvenance& provenance,
    IOSFeatureId feature,
    IOSDeviceProbeId probe,
    bool requested,
    bool eligible,
    bool active,
    IOSFeatureFallbackReason fallbackReason) {
  const IOSFeaturePolicyDecision* decision =
      provenance.decision(feature);
  assert(decision!=nullptr);
  assert(decision->feature==feature);
  assert(decision->probe==probe);
  expectState(
      decision->state,requested,eligible,active,fallbackReason);
  }

IOSFeaturePolicyProvenanceStorage provenanceStorage(
    const IOSFeaturePolicyProvenance& provenance) {
  IOSFeaturePolicyProvenanceStorage storage{};
  std::memcpy(&storage,&provenance,sizeof(storage));
  return storage;
  }

void replaceProvenanceStorage(
    IOSFeaturePolicyProvenance& provenance,
    const IOSFeaturePolicyProvenanceStorage& storage) {
  std::memcpy(&provenance,&storage,sizeof(storage));
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

void testProvenanceMatrixAndMapping() {
  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  for(uint8_t defaults=0u; defaults<DefaultClassCount; ++defaults) {
    const IOSFeaturePolicyProvenance provenance =
        iosBuildFeaturePolicyProvenance(
            supported,DefaultClasses[defaults],allActivation(true));
    assert(provenance.defaults()==DefaultClasses[defaults]);
    assert(provenance.factsAbiVersion()==IOSDeviceFactsABIVersion);
    assert(
        provenance.probeContractVersion()==
        IOSDeviceProbeContractVersion);
    const IOSFeaturePolicyDecision* first =
        provenance.decision(IOSFeatureId::MetalFxSpatial);
    assert(first!=nullptr);
    for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
      const bool requested = ExpectedRequests[defaults][feature];
      assert(provenance.decision(Features[feature])==first+feature);
      expectDecision(
          provenance,
          Features[feature],
          static_cast<IOSDeviceProbeId>(feature),
          requested,true,requested,
          requested
              ? IOSFeatureFallbackReason::None
              : IOSFeatureFallbackReason::NotRequested);
      }
    }

  assert(iosBuildFeaturePolicyProvenance(
      supported,IOSFeatureDefaultClass::Safe,
      allActivation(true)).decision(IOSFeatureId::Count)==nullptr);
  assert(iosBuildFeaturePolicyProvenance(
      supported,IOSFeatureDefaultClass::Safe,
      allActivation(true)).decision(
          static_cast<IOSFeatureId>(0xFFu))==nullptr);
  }

void testProvenanceFallbacksAndNamedActivation() {
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
      const IOSFeaturePolicyProvenance provenance =
          iosBuildFeaturePolicyProvenance(
              facts,IOSFeatureDefaultClass::Apple10,
              allActivation(true));
      expectDecision(
          provenance,Features[feature],
          static_cast<IOSDeviceProbeId>(feature),
          true,false,false,capability.fallbackReason);
      }

    const IOSDeviceFacts supported = factsWithAllProbes(
        IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
    const IOSFeaturePolicyProvenance provenance =
        iosBuildFeaturePolicyProvenance(
            supported,IOSFeatureDefaultClass::Apple10,
            activationFailureAt(feature));
    for(uint8_t decision=0u; decision<ProbeCount; ++decision) {
      const bool failed = decision==feature;
      expectDecision(
          provenance,Features[decision],
          static_cast<IOSDeviceProbeId>(decision),
          true,true,!failed,
          failed
              ? IOSFeatureFallbackReason::ActivationFailed
              : IOSFeatureFallbackReason::None);
      }
    }
  }

void testProvenanceInvalidDefaults() {
  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  const IOSDeviceFacts unknown = factsWithAllProbes(0u,0u);
  constexpr IOSFeatureDefaultClass InvalidDefaults[] = {
    IOSFeatureDefaultClass::Count,
    static_cast<IOSFeatureDefaultClass>(0xFFu),
    };
  for(const IOSFeatureDefaultClass defaults:InvalidDefaults) {
    const IOSFeaturePolicyProvenance supportedProvenance =
        iosBuildFeaturePolicyProvenance(
            supported,defaults,allActivation(true));
    const IOSFeaturePolicyProvenance unknownProvenance =
        iosBuildFeaturePolicyProvenance(
            unknown,defaults,allActivation(true));
    assert(supportedProvenance.defaults()==defaults);
    assert(unknownProvenance.defaults()==defaults);
    for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
      expectDecision(
          supportedProvenance,Features[feature],
          static_cast<IOSDeviceProbeId>(feature),
          false,true,false,
          IOSFeatureFallbackReason::InvalidDefaultClass);
      expectDecision(
          unknownProvenance,Features[feature],
          static_cast<IOSDeviceProbeId>(feature),
          false,false,false,
          IOSFeatureFallbackReason::InvalidDefaultClass);
      }
    }
  }

IOSFeaturePolicyProvenance provenanceAfterFactsLifetime() {
  const IOSDeviceFacts facts = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  return iosBuildFeaturePolicyProvenance(
      facts,IOSFeatureDefaultClass::Apple10,allActivation(true));
  }

void testProvenanceOwnsSnapshot() {
  IOSDeviceFactsData source = canonicalData();
  for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
    source.probes[feature].knownStages =
        IOSDeviceRequiredProbeStages;
    source.probes[feature].passedStages =
        IOSDeviceRequiredProbeStages;
    }
  const IOSDeviceFacts facts = requireFacts(source);
  IOSFeaturePolicyProvenance provenance =
      iosBuildFeaturePolicyProvenance(
          facts,IOSFeatureDefaultClass::Apple10,
          allActivation(true));
  for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
    source.probes[feature].knownStages = 0u;
    source.probes[feature].passedStages = 0u;
    expectDecision(
        provenance,Features[feature],
        static_cast<IOSDeviceProbeId>(feature),
        true,true,true,IOSFeatureFallbackReason::None);
    }

  IOSFeaturePolicyProvenance afterLifetime =
      provenanceAfterFactsLifetime();
  expectDecision(
      afterLifetime,IOSFeatureId::Metal4Transport,
      IOSDeviceProbeId::Metal4Transport,
      true,true,true,IOSFeatureFallbackReason::None);

  IOSFeaturePolicyProvenance copy = provenance;
  IOSFeaturePolicyProvenance moved = std::move(copy);
  copy = provenance;
  moved = std::move(copy);
  expectDecision(
      moved,IOSFeatureId::RayTracing,
      IOSDeviceProbeId::RayTracing,
      true,true,true,IOSFeatureFallbackReason::None);
  }

void assertUnchanged(
    const char* buffer,
    size_t capacity,
    char value) {
  for(size_t i=0u; i<capacity; ++i)
    assert(buffer[i]==value);
  }

void testTelemetryExactAndGateBoundaries() {
  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  const IOSFeaturePolicyProvenance provenance =
      iosBuildFeaturePolicyProvenance(
          supported,IOSFeatureDefaultClass::Apple9,
          allActivation(true));
  constexpr char Expected[] =
      "RendererIOS feature policy: schema=1 facts=1 probes=1 "
      "defaults=apple9 spatial=1/1/1/none temporal=1/1/1/none "
      "mesh=1/1/1/none rt=1/1/1/none "
      "metal4=0/1/0/not-requested";
  const size_t required = std::strlen(Expected)+1u;
  assert(required<=IOSFeaturePolicyTelemetryCapacity);

  IOSFeatureTelemetryGate gate{};
  char output[IOSFeaturePolicyTelemetryCapacity+8u];
  std::memset(output,'#',sizeof(output));
  assert(iosTakeFeaturePolicyTelemetry(
      gate,provenance,nullptr,0u)==
      IOSFeatureTelemetryResult::BufferTooSmall);
  assert(!gate.emitted);
  assertUnchanged(output,sizeof(output),'#');
  assert(iosTakeFeaturePolicyTelemetry(
      gate,provenance,output,0u)==
      IOSFeatureTelemetryResult::BufferTooSmall);
  assert(!gate.emitted);
  assertUnchanged(output,sizeof(output),'#');
  assert(iosTakeFeaturePolicyTelemetry(
      gate,provenance,output,required-1u)==
      IOSFeatureTelemetryResult::BufferTooSmall);
  assert(!gate.emitted);
  assertUnchanged(output,sizeof(output),'#');

  assert(iosTakeFeaturePolicyTelemetry(
      gate,provenance,output,required)==
      IOSFeatureTelemetryResult::Emitted);
  assert(gate.emitted);
  assert(std::strcmp(output,Expected)==0);
  assert(output[required]=='#');

  assert(iosTakeFeaturePolicyTelemetry(
      gate,provenance,nullptr,0u)==
      IOSFeatureTelemetryResult::AlreadyEmitted);
  std::memset(output,'!',sizeof(output));
  assert(iosTakeFeaturePolicyTelemetry(
      gate,provenance,output,1u)==
      IOSFeatureTelemetryResult::AlreadyEmitted);
  assertUnchanged(output,sizeof(output),'!');

  IOSFeatureTelemetryGate largerGate{};
  std::memset(output,'?',sizeof(output));
  assert(iosTakeFeaturePolicyTelemetry(
      largerGate,provenance,output,required+4u)==
      IOSFeatureTelemetryResult::Emitted);
  assert(std::strcmp(output,Expected)==0);
  assert(output[required]=='?');

  IOSFeatureTelemetryGate guaranteedGate{};
  std::memset(output,'~',sizeof(output));
  assert(iosTakeFeaturePolicyTelemetry(
      guaranteedGate,provenance,output,
      IOSFeaturePolicyTelemetryCapacity)==
      IOSFeatureTelemetryResult::Emitted);
  assert(std::strcmp(output,Expected)==0);
  }

void expectTelemetryContains(
    IOSFeaturePolicyProvenance provenance,
    const char* expected) {
  IOSFeatureTelemetryGate gate{};
  char output[IOSFeaturePolicyTelemetryCapacity]{};
  assert(iosTakeFeaturePolicyTelemetry(
      gate,provenance,output,sizeof(output))==
      IOSFeatureTelemetryResult::Emitted);
  assert(std::strstr(output,expected)!=nullptr);
  }

void testTelemetryEnumNamesAndMaximumCapacity() {
  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  constexpr const char* DefaultNames[] = {
    "defaults=safe",
    "defaults=apple8",
    "defaults=apple9",
    "defaults=apple10",
    };
  for(uint8_t defaults=0u; defaults<DefaultClassCount; ++defaults) {
    expectTelemetryContains(
        iosBuildFeaturePolicyProvenance(
            supported,DefaultClasses[defaults],allActivation(true)),
        DefaultNames[defaults]);
    }

  IOSFeaturePolicyProvenance first =
      iosBuildFeaturePolicyProvenance(
          supported,IOSFeatureDefaultClass::Safe,
          allActivation(true));
  IOSFeaturePolicyProvenanceStorage storage =
      provenanceStorage(first);
  storage.decisions[0].state.fallbackReason =
      IOSFeatureFallbackReason::None;
  storage.decisions[1].state.fallbackReason =
      IOSFeatureFallbackReason::InvalidFeature;
  storage.decisions[2].state.fallbackReason =
      IOSFeatureFallbackReason::NotRequested;
  storage.decisions[3].state.fallbackReason =
      IOSFeatureFallbackReason::AvailabilityUnknown;
  storage.decisions[4].state.fallbackReason =
      IOSFeatureFallbackReason::AvailabilityUnsupported;
  replaceProvenanceStorage(first,storage);
  expectTelemetryContains(first,"/none");
  expectTelemetryContains(first,"/invalid-feature");
  expectTelemetryContains(first,"/not-requested");
  expectTelemetryContains(first,"/availability-unknown");
  expectTelemetryContains(first,"/availability-unsupported");

  IOSFeaturePolicyProvenance second =
      iosBuildFeaturePolicyProvenance(
          supported,IOSFeatureDefaultClass::Safe,
          allActivation(true));
  storage = provenanceStorage(second);
  storage.decisions[0].state.fallbackReason =
      IOSFeatureFallbackReason::DeviceSupportUnknown;
  storage.decisions[1].state.fallbackReason =
      IOSFeatureFallbackReason::DeviceSupportUnsupported;
  storage.decisions[2].state.fallbackReason =
      IOSFeatureFallbackReason::ActivationFailed;
  storage.decisions[3].state.fallbackReason =
      IOSFeatureFallbackReason::InvalidDefaultClass;
  storage.decisions[4].state.fallbackReason =
      IOSFeatureFallbackReason::None;
  replaceProvenanceStorage(second,storage);
  expectTelemetryContains(second,"/device-support-unknown");
  expectTelemetryContains(second,"/device-support-unsupported");
  expectTelemetryContains(second,"/activation-failed");
  expectTelemetryContains(second,"/invalid-default-class");

  IOSFeaturePolicyProvenance maximum = second;
  storage = provenanceStorage(maximum);
  storage.factsAbiVersion = 0xFFFFFFFFu;
  storage.probeContractVersion = 0xFFFFFFFFu;
  storage.defaults = static_cast<IOSFeatureDefaultClass>(0xFFu);
  for(uint8_t feature=0u; feature<ProbeCount; ++feature) {
    storage.decisions[feature].state.fallbackReason =
        IOSFeatureFallbackReason::DeviceSupportUnsupported;
    }
  replaceProvenanceStorage(maximum,storage);
  IOSFeatureTelemetryGate gate{};
  char output[IOSFeaturePolicyTelemetryCapacity]{};
  assert(iosTakeFeaturePolicyTelemetry(
      gate,maximum,output,sizeof(output))==
      IOSFeatureTelemetryResult::Emitted);
  assert(std::strstr(output,"facts=4294967295")!=nullptr);
  assert(std::strstr(output,"probes=4294967295")!=nullptr);
  assert(std::strstr(output,"defaults=invalid")!=nullptr);
  assert(std::strlen(output)+1u<=sizeof(output));
  }

void testRuntimeSafePolicyMarkerContract() {
  const IOSDeviceFacts supported = factsWithAllProbes(
      IOSDeviceRequiredProbeStages,IOSDeviceRequiredProbeStages);
  const IOSFeaturePolicyProvenance provenance =
      iosBuildFeaturePolicyProvenance(
          supported,
          IOSFeatureDefaultClass::Safe,
          {false,false,false,false,false});
  constexpr char ExpectedCore[] =
      "RendererIOS feature policy: schema=1 facts=1 probes=1 "
      "defaults=safe spatial=0/1/0/not-requested "
      "temporal=0/1/0/not-requested "
      "mesh=0/1/0/not-requested rt=0/1/0/not-requested "
      "metal4=0/1/0/not-requested";
  constexpr char RuntimeSuffix[] = " build=host-safe-sha";
  constexpr char ExpectedRuntime[] =
      "RendererIOS feature policy: schema=1 facts=1 probes=1 "
      "defaults=safe spatial=0/1/0/not-requested "
      "temporal=0/1/0/not-requested "
      "mesh=0/1/0/not-requested rt=0/1/0/not-requested "
      "metal4=0/1/0/not-requested build=host-safe-sha";

  IOSFeatureTelemetryGate gate{};
  char core[IOSFeaturePolicyTelemetryCapacity]{};
  assert(iosTakeFeaturePolicyTelemetry(
      gate,provenance,core,sizeof(core))==
      IOSFeatureTelemetryResult::Emitted);
  assert(std::strcmp(core,ExpectedCore)==0);

  char runtime[sizeof(ExpectedRuntime)]{};
  const size_t coreLength = std::strlen(core);
  std::memcpy(runtime,core,coreLength);
  std::memcpy(
      runtime+coreLength,RuntimeSuffix,sizeof(RuntimeSuffix));
  assert(std::strcmp(runtime,ExpectedRuntime)==0);

  IOSFeatureTelemetryGate alreadyEmitted{true};
  assert(iosTakeFeaturePolicyTelemetry(
      alreadyEmitted,provenance,nullptr,0u)==
      IOSFeatureTelemetryResult::AlreadyEmitted);
  IOSFeatureTelemetryGate insufficient{};
  char tooSmall[1]{};
  assert(iosTakeFeaturePolicyTelemetry(
      insufficient,provenance,tooSmall,sizeof(tooSmall))==
      IOSFeatureTelemetryResult::BufferTooSmall);
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
  using BuildProvenanceSignature = IOSFeaturePolicyProvenance (*)(
      const IOSDeviceFacts&,IOSFeatureDefaultClass,
      IOSFeatureActivationResults) noexcept;
  using TakeTelemetrySignature = IOSFeatureTelemetryResult (*)(
      IOSFeatureTelemetryGate&,
      const IOSFeaturePolicyProvenance&,
      char*,size_t) noexcept;
  static_assert(std::is_same_v<
      decltype(&iosEvaluateFeaturePolicy),EvaluateSignature>);
  static_assert(std::is_same_v<
      decltype(&iosResolveFeatureDefaultRequest),ResolveSignature>);
  static_assert(std::is_same_v<
      decltype(&iosEvaluateFeaturePolicyDefaults),
      EvaluateDefaultsSignature>);
  static_assert(std::is_same_v<
      decltype(&iosBuildFeaturePolicyProvenance),
      BuildProvenanceSignature>);
  static_assert(std::is_same_v<
      decltype(&iosTakeFeaturePolicyTelemetry),
      TakeTelemetrySignature>);
  static_assert(noexcept(iosEvaluateFeaturePolicy(
      std::declval<const IOSDeviceFacts&>(),
      std::declval<IOSFeaturePolicyInput>())));
  static_assert(noexcept(iosResolveFeatureDefaultRequest(
      std::declval<IOSFeatureId>(),
      std::declval<IOSFeatureDefaultClass>())));
  static_assert(noexcept(iosEvaluateFeaturePolicyDefaults(
      std::declval<const IOSDeviceFacts&>(),
      std::declval<IOSFeaturePolicyDefaultsInput>())));
  static_assert(noexcept(iosBuildFeaturePolicyProvenance(
      std::declval<const IOSDeviceFacts&>(),
      std::declval<IOSFeatureDefaultClass>(),
      std::declval<IOSFeatureActivationResults>())));
  static_assert(noexcept(iosTakeFeaturePolicyTelemetry(
      std::declval<IOSFeatureTelemetryGate&>(),
      std::declval<const IOSFeaturePolicyProvenance&>(),
      std::declval<char*>(),
      std::declval<size_t>())));
  static_assert(!std::is_constructible_v<
      IOSFeaturePolicyProvenance,
      IOSFeaturePolicyProvenanceStorage>);

  testExactDefaultMatrix();
  testCapabilityFallbacksForEveryFeature();
  testActivationFailureForEveryFeature();
  testInvalidInputsAndPrecedence();
  testFactsNeverChooseOrBypassDefaults();
  testExplicitRequestRegression();
  testProvenanceMatrixAndMapping();
  testProvenanceFallbacksAndNamedActivation();
  testProvenanceInvalidDefaults();
  testProvenanceOwnsSnapshot();
  testTelemetryExactAndGateBoundaries();
  testTelemetryEnumNamesAndMaximumCapacity();
  testRuntimeSafePolicyMarkerContract();
  return 0;
  }
