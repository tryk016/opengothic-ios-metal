#include "iosfeaturepolicy.h"

namespace {

bool featureProbe(
    IOSFeatureId feature,
    IOSDeviceProbeId& probe) noexcept {
  switch(feature) {
    case IOSFeatureId::MetalFxSpatial:
      probe = IOSDeviceProbeId::MetalFxSpatial;
      return true;
    case IOSFeatureId::MetalFxTemporal:
      probe = IOSDeviceProbeId::MetalFxTemporal;
      return true;
    case IOSFeatureId::MeshShading:
      probe = IOSDeviceProbeId::MeshShading;
      return true;
    case IOSFeatureId::RayTracing:
      probe = IOSDeviceProbeId::RayTracing;
      return true;
    case IOSFeatureId::Metal4Transport:
      probe = IOSDeviceProbeId::Metal4Transport;
      return true;
    case IOSFeatureId::Count:
      break;
    }
  return false;
  }

}

IOSFeaturePolicyState iosEvaluateFeaturePolicy(
    const IOSDeviceFacts& facts,
    IOSFeaturePolicyInput input) noexcept {
  IOSFeaturePolicyState state{
    input.requested,
    false,
    false,
    IOSFeatureFallbackReason::InvalidFeature,
    };

  IOSDeviceProbeId probeId = IOSDeviceProbeId::Count;
  if(!featureProbe(input.feature,probeId))
    return state;

  const ProbeFacts& probe =
      facts.facts().probes[static_cast<uint8_t>(probeId)];
  const bool availabilityKnown =
      (probe.knownStages & Availability)!=0u;
  const bool availabilityPassed =
      (probe.passedStages & Availability)!=0u;
  const bool deviceSupportKnown =
      (probe.knownStages & DeviceSupport)!=0u;
  const bool deviceSupportPassed =
      (probe.passedStages & DeviceSupport)!=0u;
  state.eligible =
      availabilityKnown && availabilityPassed &&
      deviceSupportKnown && deviceSupportPassed;

  if(!input.requested) {
    state.fallbackReason = IOSFeatureFallbackReason::NotRequested;
    return state;
    }
  if(!availabilityKnown) {
    state.fallbackReason =
        IOSFeatureFallbackReason::AvailabilityUnknown;
    return state;
    }
  if(!availabilityPassed) {
    state.fallbackReason =
        IOSFeatureFallbackReason::AvailabilityUnsupported;
    return state;
    }
  if(!deviceSupportKnown) {
    state.fallbackReason =
        IOSFeatureFallbackReason::DeviceSupportUnknown;
    return state;
    }
  if(!deviceSupportPassed) {
    state.fallbackReason =
        IOSFeatureFallbackReason::DeviceSupportUnsupported;
    return state;
    }
  if(!input.activationSucceeded) {
    state.fallbackReason = IOSFeatureFallbackReason::ActivationFailed;
    return state;
    }

  state.active = true;
  state.fallbackReason = IOSFeatureFallbackReason::None;
  return state;
  }
