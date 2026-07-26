#include "iosdevicefactscollector.h"

#include <limits>

namespace {

constexpr uint8_t ProbeCount =
    static_cast<uint8_t>(IOSDeviceProbeId::Count);
constexpr uint8_t FormatCount =
    static_cast<uint8_t>(IOSDeviceFormatId::Count);
constexpr uint8_t LimitCount =
    static_cast<uint8_t>(IOSDeviceLimitId::Count);

constexpr uint8_t RequiredFormatUsages[FormatCount] = {
  0x0Bu,0x0Bu,0x03u,0x05u,0x05u,
  };

constexpr bool isKnown(IOSDeviceNativeTruth value) noexcept {
  return value==IOSDeviceNativeTruth::No ||
         value==IOSDeviceNativeTruth::Yes;
  }

constexpr bool isYes(IOSDeviceNativeTruth value) noexcept {
  return value==IOSDeviceNativeTruth::Yes;
  }

IOSVersionTriplet mapVersion(
    const IOSDeviceNativeVersion& source) noexcept {
  IOSVersionTriplet result{};
  if(source.known!=IOSDeviceNativeTruth::Yes)
    return result;
  constexpr int64_t Max =
      static_cast<int64_t>(std::numeric_limits<uint16_t>::max());
  if(source.major<=0 || source.major>Max ||
     source.minor<0 || source.minor>Max ||
     source.patch<0 || source.patch>Max)
    return result;
  result.major = static_cast<uint16_t>(source.major);
  result.minor = static_cast<uint16_t>(source.minor);
  result.patch = static_cast<uint16_t>(source.patch);
  return result;
  }

uint8_t highestAppleFamily(
    const IOSDeviceNativeSnapshot& source) noexcept {
  const uint16_t supported =
      source.knownAppleFamilyMask &
      source.supportedAppleFamilyMask;
  for(uint8_t family=10u; family>0u; --family) {
    if((supported & (uint16_t(1u) << family))!=0u)
      return family;
    }
  return 0u;
  }

uint8_t highestMetalFamily(
    const IOSDeviceNativeSnapshot& source) noexcept {
  const uint8_t supported =
      source.knownMetalFamilyMask &
      source.supportedMetalFamilyMask;
  for(uint8_t family=4u; family>=3u; --family) {
    if((supported & (uint8_t(1u) << family))!=0u)
      return family;
    }
  return 0u;
  }

ProbeFacts mapProbe(
    uint8_t index,
    const IOSDeviceNativeProbe& source) noexcept {
  ProbeFacts result{
    IOSDeviceRequiredProbeStages,
    0u,
    0u,
    index,
    };
  if(!isKnown(source.availability))
    return result;
  result.knownStages |= Availability;
  if(!isYes(source.availability))
    return result;
  result.passedStages |= Availability;
  if(!isKnown(source.deviceSupport))
    return result;
  result.knownStages |= DeviceSupport;
  if(isYes(source.deviceSupport))
    result.passedStages |= DeviceSupport;
  return result;
  }

}

IOSDeviceFactsCreateResult iosMapDeviceNativeSnapshot(
    const IOSDeviceNativeSnapshot& snapshot) noexcept {
  IOSDeviceFactsData result{};
  result.abiVersion = IOSDeviceFactsABIVersion;
  result.structSize = IOSDeviceFactsStructSize;
  result.probeContractVersion = IOSDeviceProbeContractVersion;
  result.runtimeVersion = mapVersion(snapshot.runtimeVersion);
  result.sdkVersion = mapVersion(snapshot.sdkVersion);
  result.highestKnownAppleFamily = highestAppleFamily(snapshot);
  result.highestKnownMetalFamily = highestMetalFamily(snapshot);
  result.probeCount = ProbeCount;
  result.formatCount = FormatCount;
  result.limitCount = LimitCount;

  for(uint8_t i=0u; i<ProbeCount; ++i)
    result.probes[i] = mapProbe(i,snapshot.probes[i]);

  for(uint8_t i=0u; i<FormatCount; ++i) {
    result.formats[i].requiredUsages = RequiredFormatUsages[i];
    result.formats[i].knownUsages =
        snapshot.formats[i].knownUsages;
    result.formats[i].supportedUsages =
        snapshot.formats[i].supportedUsages;
    }

  const uint32_t requestedMask =
      snapshot.knownLimitMask & IOSDeviceNativeKnownLimitMask;
  for(uint8_t i=0u; i<LimitCount; ++i) {
    const uint32_t bit = uint32_t(1u) << i;
    if((requestedMask & bit)==0u)
      continue;
    if(snapshot.limits[i]>
       uint64_t(std::numeric_limits<uint32_t>::max()))
      continue;
    result.knownLimitMask |= bit;
    result.limits[i] = static_cast<uint32_t>(snapshot.limits[i]);
    }

  return IOSDeviceFacts::create(result);
  }
