#include "iosfeaturepolicyprovenance.h"

#include <cstdio>
#include <cstring>

namespace {

const char* defaultsName(IOSFeatureDefaultClass defaults) noexcept {
  switch(defaults) {
    case IOSFeatureDefaultClass::Safe:
      return "safe";
    case IOSFeatureDefaultClass::Apple8:
      return "apple8";
    case IOSFeatureDefaultClass::Apple9:
      return "apple9";
    case IOSFeatureDefaultClass::Apple10:
      return "apple10";
    case IOSFeatureDefaultClass::Count:
      break;
    }
  return "invalid";
  }

const char* fallbackName(IOSFeatureFallbackReason fallback) noexcept {
  switch(fallback) {
    case IOSFeatureFallbackReason::None:
      return "none";
    case IOSFeatureFallbackReason::InvalidFeature:
      return "invalid-feature";
    case IOSFeatureFallbackReason::NotRequested:
      return "not-requested";
    case IOSFeatureFallbackReason::AvailabilityUnknown:
      return "availability-unknown";
    case IOSFeatureFallbackReason::AvailabilityUnsupported:
      return "availability-unsupported";
    case IOSFeatureFallbackReason::DeviceSupportUnknown:
      return "device-support-unknown";
    case IOSFeatureFallbackReason::DeviceSupportUnsupported:
      return "device-support-unsupported";
    case IOSFeatureFallbackReason::ActivationFailed:
      return "activation-failed";
    case IOSFeatureFallbackReason::InvalidDefaultClass:
      return "invalid-default-class";
    }
  return "invalid-feature";
  }

unsigned flag(bool value) noexcept {
  return value ? 1u : 0u;
  }

}

IOSFeaturePolicyProvenance::IOSFeaturePolicyProvenance(
    IOSFeaturePolicyProvenanceStorage storage) noexcept
  : storage_(storage) {
  }

IOSFeatureDefaultClass IOSFeaturePolicyProvenance::defaults()
    const noexcept {
  return storage_.defaults;
  }

uint32_t IOSFeaturePolicyProvenance::factsAbiVersion() const noexcept {
  return storage_.factsAbiVersion;
  }

uint32_t IOSFeaturePolicyProvenance::probeContractVersion()
    const noexcept {
  return storage_.probeContractVersion;
  }

const IOSFeaturePolicyDecision* IOSFeaturePolicyProvenance::decision(
    IOSFeatureId feature) const noexcept {
  switch(feature) {
    case IOSFeatureId::MetalFxSpatial:
      return &storage_.decisions[0];
    case IOSFeatureId::MetalFxTemporal:
      return &storage_.decisions[1];
    case IOSFeatureId::MeshShading:
      return &storage_.decisions[2];
    case IOSFeatureId::RayTracing:
      return &storage_.decisions[3];
    case IOSFeatureId::Metal4Transport:
      return &storage_.decisions[4];
    case IOSFeatureId::Count:
      break;
    }
  return nullptr;
  }

IOSFeaturePolicyProvenance iosBuildFeaturePolicyProvenance(
    const IOSDeviceFacts& facts,
    IOSFeatureDefaultClass defaults,
    IOSFeatureActivationResults activation) noexcept {
  IOSFeaturePolicyProvenanceStorage storage{};
  storage.factsAbiVersion = facts.facts().abiVersion;
  storage.probeContractVersion =
      facts.facts().probeContractVersion;
  storage.decisions[0] = {
    IOSFeatureId::MetalFxSpatial,
    IOSDeviceProbeId::MetalFxSpatial,
    iosEvaluateFeaturePolicyDefaults(
        facts,
        {IOSFeatureId::MetalFxSpatial,defaults,
         activation.metalFxSpatial}),
    };
  storage.decisions[1] = {
    IOSFeatureId::MetalFxTemporal,
    IOSDeviceProbeId::MetalFxTemporal,
    iosEvaluateFeaturePolicyDefaults(
        facts,
        {IOSFeatureId::MetalFxTemporal,defaults,
         activation.metalFxTemporal}),
    };
  storage.decisions[2] = {
    IOSFeatureId::MeshShading,
    IOSDeviceProbeId::MeshShading,
    iosEvaluateFeaturePolicyDefaults(
        facts,
        {IOSFeatureId::MeshShading,defaults,
         activation.meshShading}),
    };
  storage.decisions[3] = {
    IOSFeatureId::RayTracing,
    IOSDeviceProbeId::RayTracing,
    iosEvaluateFeaturePolicyDefaults(
        facts,
        {IOSFeatureId::RayTracing,defaults,
         activation.rayTracing}),
    };
  storage.decisions[4] = {
    IOSFeatureId::Metal4Transport,
    IOSDeviceProbeId::Metal4Transport,
    iosEvaluateFeaturePolicyDefaults(
        facts,
        {IOSFeatureId::Metal4Transport,defaults,
         activation.metal4Transport}),
    };
  storage.defaults = defaults;
  return IOSFeaturePolicyProvenance(storage);
  }

IOSFeatureTelemetryResult iosTakeFeaturePolicyTelemetry(
    IOSFeatureTelemetryGate& gate,
    const IOSFeaturePolicyProvenance& provenance,
    char* output,
    size_t capacity) noexcept {
  if(gate.emitted)
    return IOSFeatureTelemetryResult::AlreadyEmitted;

  const IOSFeaturePolicyDecision& spatial =
      *provenance.decision(IOSFeatureId::MetalFxSpatial);
  const IOSFeaturePolicyDecision& temporal =
      *provenance.decision(IOSFeatureId::MetalFxTemporal);
  const IOSFeaturePolicyDecision& mesh =
      *provenance.decision(IOSFeatureId::MeshShading);
  const IOSFeaturePolicyDecision& rayTracing =
      *provenance.decision(IOSFeatureId::RayTracing);
  const IOSFeaturePolicyDecision& metal4 =
      *provenance.decision(IOSFeatureId::Metal4Transport);

  char record[IOSFeaturePolicyTelemetryCapacity]{};
  const int written = std::snprintf(
      record,
      sizeof(record),
      "RendererIOS feature policy: schema=%u facts=%u probes=%u "
      "defaults=%s spatial=%u/%u/%u/%s temporal=%u/%u/%u/%s "
      "mesh=%u/%u/%u/%s rt=%u/%u/%u/%s metal4=%u/%u/%u/%s",
      static_cast<unsigned>(
          IOSFeaturePolicyProvenanceSchemaVersion),
      static_cast<unsigned>(provenance.factsAbiVersion()),
      static_cast<unsigned>(provenance.probeContractVersion()),
      defaultsName(provenance.defaults()),
      flag(spatial.state.requested),
      flag(spatial.state.eligible),
      flag(spatial.state.active),
      fallbackName(spatial.state.fallbackReason),
      flag(temporal.state.requested),
      flag(temporal.state.eligible),
      flag(temporal.state.active),
      fallbackName(temporal.state.fallbackReason),
      flag(mesh.state.requested),
      flag(mesh.state.eligible),
      flag(mesh.state.active),
      fallbackName(mesh.state.fallbackReason),
      flag(rayTracing.state.requested),
      flag(rayTracing.state.eligible),
      flag(rayTracing.state.active),
      fallbackName(rayTracing.state.fallbackReason),
      flag(metal4.state.requested),
      flag(metal4.state.eligible),
      flag(metal4.state.active),
      fallbackName(metal4.state.fallbackReason));
  if(written<0 ||
      static_cast<size_t>(written)>=sizeof(record))
    return IOSFeatureTelemetryResult::BufferTooSmall;
  const size_t required = static_cast<size_t>(written)+1u;
  if(output==nullptr || capacity<required)
    return IOSFeatureTelemetryResult::BufferTooSmall;

  std::memcpy(output,record,required);
  gate.emitted = true;
  return IOSFeatureTelemetryResult::Emitted;
  }
