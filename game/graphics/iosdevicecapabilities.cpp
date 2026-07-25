#include "iosdevicecapabilities.h"

#include <utility>

namespace {

constexpr uint8_t ProbeCount =
    static_cast<uint8_t>(IOSDeviceProbeId::Count);
constexpr uint8_t FormatCount =
    static_cast<uint8_t>(IOSDeviceFormatId::Count);
constexpr uint8_t LimitCount =
    static_cast<uint8_t>(IOSDeviceLimitId::Count);
constexpr uint32_t KnownLimitMask = (1u << LimitCount)-1u;

constexpr IOSDeviceFactsFailure success() noexcept {
  return {};
  }

constexpr IOSDeviceFactsFailure failure(
    IOSDeviceFactsError error,
    IOSDeviceFactsSection section,
    uint8_t index,
    uint32_t raw) noexcept {
  return {error,section,index,0u,raw};
  }

constexpr uint8_t requiredFormatUsages(uint8_t index) noexcept {
  switch(static_cast<IOSDeviceFormatId>(index)) {
    case IOSDeviceFormatId::Rg11B10Float:
    case IOSDeviceFormatId::Rgba16Float:
      return Sampled | ColorAttachment | ShaderWrite;
    case IOSDeviceFormatId::Rg16Float:
      return Sampled | ColorAttachment;
    case IOSDeviceFormatId::Depth16Unorm:
    case IOSDeviceFormatId::Depth32Float:
      return Sampled | DepthAttachment;
    case IOSDeviceFormatId::Count:
      break;
    }
  return 0u;
  }

constexpr IOSDeviceFactsFailure validateVersion(
    const IOSVersionTriplet& version,
    IOSDeviceFactsSection section) noexcept {
  if(version.major==0u) {
    if(version.minor!=0u)
      return failure(
          IOSDeviceFactsError::VersionUnknownTupleNonZero,
          section,1u,version.minor);
    if(version.patch!=0u)
      return failure(
          IOSDeviceFactsError::VersionUnknownTupleNonZero,
          section,2u,version.patch);
    }
  if(version.reserved!=0u)
    return failure(
        IOSDeviceFactsError::VersionReservedNonZero,
        section,3u,version.reserved);
  return success();
  }

constexpr IOSDeviceFactsFailure validate(
    const IOSDeviceFactsData& data) noexcept {
  if(data.abiVersion!=IOSDeviceFactsABIVersion)
    return failure(
        IOSDeviceFactsError::AbiVersionMismatch,
        IOSDeviceFactsSection::Header,0u,data.abiVersion);
  if(data.structSize!=IOSDeviceFactsStructSize)
    return failure(
        IOSDeviceFactsError::StructSizeMismatch,
        IOSDeviceFactsSection::Header,1u,data.structSize);
  if(data.probeContractVersion!=IOSDeviceProbeContractVersion)
    return failure(
        IOSDeviceFactsError::ProbeContractVersionMismatch,
        IOSDeviceFactsSection::Header,2u,data.probeContractVersion);
  if(data.flags!=0u)
    return failure(
        IOSDeviceFactsError::FlagsNonZero,
        IOSDeviceFactsSection::Header,3u,data.flags);
  if(data.probeCount!=ProbeCount)
    return failure(
        IOSDeviceFactsError::ProbeCountMismatch,
        IOSDeviceFactsSection::Header,4u,data.probeCount);
  if(data.formatCount!=FormatCount)
    return failure(
        IOSDeviceFactsError::FormatCountMismatch,
        IOSDeviceFactsSection::Header,5u,data.formatCount);
  if(data.limitCount!=LimitCount)
    return failure(
        IOSDeviceFactsError::LimitCountMismatch,
        IOSDeviceFactsSection::Header,6u,data.limitCount);

  IOSDeviceFactsFailure current =
      validateVersion(
          data.runtimeVersion,
          IOSDeviceFactsSection::RuntimeVersion);
  if(current.error!=IOSDeviceFactsError::None)
    return current;
  current =
      validateVersion(data.sdkVersion,IOSDeviceFactsSection::SdkVersion);
  if(current.error!=IOSDeviceFactsError::None)
    return current;

  if(data.highestKnownAppleFamily>10u)
    return failure(
        IOSDeviceFactsError::HighestKnownAppleFamilyOutOfRange,
        IOSDeviceFactsSection::Families,0u,
        data.highestKnownAppleFamily);
  if(data.highestKnownMetalFamily>4u)
    return failure(
        IOSDeviceFactsError::HighestKnownMetalFamilyOutOfRange,
        IOSDeviceFactsSection::Families,1u,
        data.highestKnownMetalFamily);

  for(uint8_t i=0u; i<3u; ++i) {
    if(data.reservedHeader[i]!=0u)
      return failure(
          IOSDeviceFactsError::ReservedNonZero,
          IOSDeviceFactsSection::ReservedHeader,i,
          data.reservedHeader[i]);
    }

  for(uint8_t i=0u; i<ProbeCount; ++i) {
    const ProbeFacts& probe = data.probes[i];
    if(probe.probeId!=i)
      return failure(
          IOSDeviceFactsError::ProbeOrder,
          IOSDeviceFactsSection::Probe,i,probe.probeId);
    if(probe.requiredStages!=IOSDeviceRequiredProbeStages)
      return failure(
          IOSDeviceFactsError::ProbeRequiredStagesMismatch,
          IOSDeviceFactsSection::Probe,i,probe.requiredStages);
    if((probe.knownStages & ~probe.requiredStages)!=0u)
      return failure(
          IOSDeviceFactsError::ProbeKnownStagesOutsideRequired,
          IOSDeviceFactsSection::Probe,i,probe.knownStages);
    if((probe.passedStages & ~probe.knownStages)!=0u)
      return failure(
          IOSDeviceFactsError::ProbePassedStagesOutsideKnown,
          IOSDeviceFactsSection::Probe,i,probe.passedStages);
    const bool deviceSupportKnown =
        (probe.knownStages & DeviceSupport)!=0u;
    const bool availabilityKnownAndPassed =
        (probe.knownStages & Availability)!=0u &&
        (probe.passedStages & Availability)!=0u;
    if(deviceSupportKnown && !availabilityKnownAndPassed) {
      const uint32_t raw =
          uint32_t(probe.requiredStages) |
          (uint32_t(probe.knownStages) << 8u) |
          (uint32_t(probe.passedStages) << 16u) |
          (uint32_t(probe.probeId) << 24u);
      return failure(
          IOSDeviceFactsError::ProbeDeviceSupportWithoutAvailability,
          IOSDeviceFactsSection::Probe,i,raw);
      }
    }

  for(uint8_t i=0u; i<FormatCount; ++i) {
    const FormatFacts& format = data.formats[i];
    if(format.requiredUsages!=requiredFormatUsages(i))
      return failure(
          IOSDeviceFactsError::FormatRequiredUsagesMismatch,
          IOSDeviceFactsSection::Format,i,format.requiredUsages);
    if((format.knownUsages & ~format.requiredUsages)!=0u)
      return failure(
          IOSDeviceFactsError::FormatKnownUsagesOutsideRequired,
          IOSDeviceFactsSection::Format,i,format.knownUsages);
    if((format.supportedUsages & ~format.knownUsages)!=0u)
      return failure(
          IOSDeviceFactsError::FormatSupportedUsagesOutsideKnown,
          IOSDeviceFactsSection::Format,i,format.supportedUsages);
    if(format.reserved!=0u)
      return failure(
          IOSDeviceFactsError::ReservedNonZero,
          IOSDeviceFactsSection::Format,i,format.reserved);
    }

  if((data.knownLimitMask & ~KnownLimitMask)!=0u)
    return failure(
        IOSDeviceFactsError::LimitKnownMaskOutOfRange,
        IOSDeviceFactsSection::Limit,0xFFu,data.knownLimitMask);
  for(uint8_t i=0u; i<LimitCount; ++i) {
    const uint32_t bit = 1u << i;
    if((data.knownLimitMask & bit)==0u && data.limits[i]!=0u)
      return failure(
          IOSDeviceFactsError::UnknownLimitValueNonZero,
          IOSDeviceFactsSection::Limit,i,data.limits[i]);
    }

  for(uint8_t i=0u; i<12u; ++i) {
    if(data.reserved[i]!=0u)
      return failure(
          IOSDeviceFactsError::ReservedNonZero,
          IOSDeviceFactsSection::ReservedTail,i,data.reserved[i]);
    }
  return success();
  }

}

const IOSDeviceFactsData& IOSDeviceFacts::facts() const noexcept {
  return data_;
  }

IOSDeviceFactsCreateResult IOSDeviceFacts::create(
    const IOSDeviceFactsData& data) noexcept {
  const IOSDeviceFactsFailure validation = validate(data);
  if(validation.error!=IOSDeviceFactsError::None)
    return {std::nullopt,validation};
  IOSDeviceFacts value(data);
  return {
    std::optional<IOSDeviceFacts>(std::move(value)),
    success(),
    };
  }
