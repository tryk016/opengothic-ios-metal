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

bool validDefaultClass(IOSFeatureDefaultClass defaults) noexcept {
  switch(defaults) {
    case IOSFeatureDefaultClass::Safe:
    case IOSFeatureDefaultClass::Apple8:
    case IOSFeatureDefaultClass::Apple9:
    case IOSFeatureDefaultClass::Apple10:
      return true;
    case IOSFeatureDefaultClass::Count:
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

IOSFeatureDefaultRequest iosResolveFeatureDefaultRequest(
    IOSFeatureId feature,
    IOSFeatureDefaultClass defaults) noexcept {
  IOSDeviceProbeId unusedProbe = IOSDeviceProbeId::Count;
  if(!featureProbe(feature,unusedProbe))
    return {false,IOSFeatureFallbackReason::InvalidFeature};
  if(!validDefaultClass(defaults))
    return {false,IOSFeatureFallbackReason::InvalidDefaultClass};

  switch(defaults) {
    case IOSFeatureDefaultClass::Safe:
      switch(feature) {
        case IOSFeatureId::MetalFxSpatial:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::MetalFxTemporal:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::MeshShading:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::RayTracing:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::Metal4Transport:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::Count:
          break;
        }
      break;
    case IOSFeatureDefaultClass::Apple8:
      switch(feature) {
        case IOSFeatureId::MetalFxSpatial:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::MetalFxTemporal:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::MeshShading:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::RayTracing:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::Metal4Transport:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::Count:
          break;
        }
      break;
    case IOSFeatureDefaultClass::Apple9:
      switch(feature) {
        case IOSFeatureId::MetalFxSpatial:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::MetalFxTemporal:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::MeshShading:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::RayTracing:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::Metal4Transport:
          return {false,IOSFeatureFallbackReason::None};
        case IOSFeatureId::Count:
          break;
        }
      break;
    case IOSFeatureDefaultClass::Apple10:
      switch(feature) {
        case IOSFeatureId::MetalFxSpatial:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::MetalFxTemporal:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::MeshShading:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::RayTracing:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::Metal4Transport:
          return {true,IOSFeatureFallbackReason::None};
        case IOSFeatureId::Count:
          break;
        }
      break;
    case IOSFeatureDefaultClass::Count:
      break;
    }
  return {false,IOSFeatureFallbackReason::InvalidDefaultClass};
  }

IOSFeaturePolicyState iosEvaluateFeaturePolicyDefaults(
    const IOSDeviceFacts& facts,
    IOSFeaturePolicyDefaultsInput input) noexcept {
  const IOSFeatureDefaultRequest request =
      iosResolveFeatureDefaultRequest(input.feature,input.defaults);
  IOSFeaturePolicyState state = iosEvaluateFeaturePolicy(
      facts,
      {input.feature,request.requested,input.activationSucceeded});
  if(request.fallbackReason!=IOSFeatureFallbackReason::None)
    state.fallbackReason = request.fallbackReason;
  return state;
  }
