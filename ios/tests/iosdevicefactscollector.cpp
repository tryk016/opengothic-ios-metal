#include "graphics/iosdevicefactscollector.h"

#include <cassert>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace {

constexpr uint8_t ProbeCount =
    static_cast<uint8_t>(IOSDeviceProbeId::Count);
constexpr uint8_t LimitCount =
    static_cast<uint8_t>(IOSDeviceLimitId::Count);

constexpr uint16_t appleMask(uint8_t family) noexcept {
  return static_cast<uint16_t>(uint16_t(1u) << family);
  }

constexpr uint8_t metalMask(uint8_t family) noexcept {
  return static_cast<uint8_t>(uint8_t(1u) << family);
  }

constexpr uint32_t limitMask(IOSDeviceLimitId limit) noexcept {
  return uint32_t(1u) << static_cast<uint8_t>(limit);
  }

IOSDeviceFactsData requireValue(
    const IOSDeviceFactsCreateResult& result) {
  assert(result.value.has_value());
  assert(result.failure.error==IOSDeviceFactsError::None);
  assert(result.failure.section==IOSDeviceFactsSection::None);
  assert(result.failure.index==0xFFu);
  assert(result.failure.reserved==0u);
  assert(result.failure.raw==0u);
  return result.value->facts();
  }

void requireUnknownProbe(const ProbeFacts& probe, uint8_t index) {
  assert(probe.requiredStages==IOSDeviceRequiredProbeStages);
  assert(probe.knownStages==0u);
  assert(probe.passedStages==0u);
  assert(probe.probeId==index);
  }

void requireProbe(
    const ProbeFacts& probe,
    uint8_t known,
    uint8_t passed,
    uint8_t index) {
  assert(probe.requiredStages==IOSDeviceRequiredProbeStages);
  assert(probe.knownStages==known);
  assert(probe.passedStages==passed);
  assert(probe.probeId==index);
  }

void requireUnknownVersion(const IOSVersionTriplet& version) {
  assert(version.major==0u);
  assert(version.minor==0u);
  assert(version.patch==0u);
  assert(version.reserved==0u);
  }

IOSDeviceNativeSnapshot a17Reference() {
  IOSDeviceNativeSnapshot result;
  result.runtimeVersion =
      {26,6,0,IOSDeviceNativeTruth::Yes};
  result.sdkVersion =
      {27,0,0,IOSDeviceNativeTruth::Yes};
  for(uint8_t family=1u; family<=10u; ++family)
    result.knownAppleFamilyMask |= appleMask(family);
  for(uint8_t family=1u; family<=9u; ++family)
    result.supportedAppleFamilyMask |= appleMask(family);
  result.knownMetalFamilyMask = metalMask(3u) | metalMask(4u);
  result.supportedMetalFamilyMask = metalMask(3u) | metalMask(4u);
  result.probes[static_cast<uint8_t>(
      IOSDeviceProbeId::MetalFxSpatial)] =
      {IOSDeviceNativeTruth::Yes,IOSDeviceNativeTruth::Yes};
  result.probes[static_cast<uint8_t>(
      IOSDeviceProbeId::MetalFxTemporal)] =
      {IOSDeviceNativeTruth::Yes,IOSDeviceNativeTruth::Yes};
  result.probes[static_cast<uint8_t>(
      IOSDeviceProbeId::MeshShading)] =
      {IOSDeviceNativeTruth::Yes,IOSDeviceNativeTruth::Unknown};
  result.probes[static_cast<uint8_t>(
      IOSDeviceProbeId::RayTracing)] =
      {IOSDeviceNativeTruth::Yes,IOSDeviceNativeTruth::Yes};
  result.probes[static_cast<uint8_t>(
      IOSDeviceProbeId::Metal4Transport)] =
      {IOSDeviceNativeTruth::Yes,IOSDeviceNativeTruth::Yes};
  result.knownLimitMask = IOSDeviceNativeKnownLimitMask;
  result.limits[4] = 1024u;
  result.limits[5] = 1024u;
  result.limits[6] = 1024u;
  result.limits[8] = 32768u;
  return result;
  }

}

int main() {
  static_assert(std::is_standard_layout_v<IOSDeviceNativeVersion>);
  static_assert(std::is_trivially_copyable_v<IOSDeviceNativeVersion>);
  static_assert(std::is_standard_layout_v<IOSDeviceNativeProbe>);
  static_assert(std::is_trivially_copyable_v<IOSDeviceNativeProbe>);
  static_assert(std::is_standard_layout_v<IOSDeviceNativeSnapshot>);
  static_assert(std::is_trivially_copyable_v<IOSDeviceNativeSnapshot>);
  static_assert(IOSDeviceNativeKnownLimitMask==0x170u);
  using MapperSignature = IOSDeviceFactsCreateResult (*)(
      const IOSDeviceNativeSnapshot&) noexcept;
  using CollectorSignature = IOSDeviceFactsCreateResult (*)(
      const Tempest::Device&) noexcept;
  using LoggerSignature = void (*)(
      const IOSDeviceFactsCreateResult&) noexcept;
  static_assert(std::is_same_v<
      decltype(&iosMapDeviceNativeSnapshot),MapperSignature>);
  static_assert(std::is_same_v<
      decltype(&iosCollectDeviceFacts),CollectorSignature>);
  static_assert(std::is_same_v<
      decltype(&iosLogDeviceFacts),LoggerSignature>);

  IOSDeviceNativeSnapshot unknown;
  const IOSDeviceFactsData& unknownFacts =
      requireValue(iosMapDeviceNativeSnapshot(unknown));
  assert(unknownFacts.runtimeVersion.major==0u);
  assert(unknownFacts.runtimeVersion.minor==0u);
  assert(unknownFacts.runtimeVersion.patch==0u);
  assert(unknownFacts.sdkVersion.major==0u);
  assert(unknownFacts.highestKnownAppleFamily==0u);
  assert(unknownFacts.highestKnownMetalFamily==0u);
  for(uint8_t i=0u; i<ProbeCount; ++i)
    requireUnknownProbe(unknownFacts.probes[i],i);
  for(const FormatFacts& format:unknownFacts.formats) {
    assert(format.knownUsages==0u);
    assert(format.supportedUsages==0u);
    assert(format.reserved==0u);
  }
  assert(unknownFacts.formats[0].requiredUsages==
         (Sampled | ColorAttachment | ShaderWrite));
  assert(unknownFacts.formats[1].requiredUsages==
         (Sampled | ColorAttachment | ShaderWrite));
  assert(unknownFacts.formats[2].requiredUsages==
         (Sampled | ColorAttachment));
  assert(unknownFacts.formats[3].requiredUsages==
         (Sampled | DepthAttachment));
  assert(unknownFacts.formats[4].requiredUsages==
         (Sampled | DepthAttachment));
  assert(unknownFacts.knownLimitMask==0u);
  for(uint8_t i=0u; i<LimitCount; ++i)
    assert(unknownFacts.limits[i]==0u);

  const IOSDeviceFactsData& a17 =
      requireValue(iosMapDeviceNativeSnapshot(a17Reference()));
  assert(a17.runtimeVersion.major==26u);
  assert(a17.runtimeVersion.minor==6u);
  assert(a17.runtimeVersion.patch==0u);
  assert(a17.sdkVersion.major==27u);
  assert(a17.sdkVersion.minor==0u);
  assert(a17.sdkVersion.patch==0u);
  assert(a17.highestKnownAppleFamily==9u);
  assert(a17.highestKnownMetalFamily==4u);
  requireProbe(a17.probes[0],Availability | DeviceSupport,
               Availability | DeviceSupport,0u);
  requireProbe(a17.probes[1],Availability | DeviceSupport,
               Availability | DeviceSupport,1u);
  requireProbe(a17.probes[2],Availability,Availability,2u);
  requireProbe(a17.probes[3],Availability | DeviceSupport,
               Availability | DeviceSupport,3u);
  requireProbe(a17.probes[4],Availability | DeviceSupport,
               Availability | DeviceSupport,4u);
  assert(a17.knownLimitMask==0x170u);
  assert(a17.limits[4]==1024u);
  assert(a17.limits[5]==1024u);
  assert(a17.limits[6]==1024u);
  assert(a17.limits[8]==32768u);

  for(uint8_t i=0u; i<ProbeCount; ++i) {
    IOSDeviceNativeSnapshot no;
    no.probes[i] =
        {IOSDeviceNativeTruth::No,IOSDeviceNativeTruth::Yes};
    const IOSDeviceFactsData& factsNo =
        requireValue(iosMapDeviceNativeSnapshot(no));
    requireProbe(factsNo.probes[i],Availability,0u,i);

    IOSDeviceNativeSnapshot yesNo;
    yesNo.probes[i] =
        {IOSDeviceNativeTruth::Yes,IOSDeviceNativeTruth::No};
    const IOSDeviceFactsData& factsYesNo =
        requireValue(iosMapDeviceNativeSnapshot(yesNo));
    requireProbe(
        factsYesNo.probes[i],
        Availability | DeviceSupport,Availability,i);

    IOSDeviceNativeSnapshot yesYes;
    yesYes.probes[i] =
        {IOSDeviceNativeTruth::Yes,IOSDeviceNativeTruth::Yes};
    const IOSDeviceFactsData& factsYesYes =
        requireValue(iosMapDeviceNativeSnapshot(yesYes));
    requireProbe(
        factsYesYes.probes[i],
        Availability | DeviceSupport,
        Availability | DeviceSupport,i);

    IOSDeviceNativeSnapshot invalid;
    invalid.probes[i].availability =
        static_cast<IOSDeviceNativeTruth>(0xFFu);
    invalid.probes[i].deviceSupport =
        IOSDeviceNativeTruth::Yes;
    const IOSDeviceFactsData& invalidFacts =
        requireValue(iosMapDeviceNativeSnapshot(invalid));
    requireUnknownProbe(invalidFacts.probes[i],i);

    IOSDeviceNativeSnapshot invalidSupport;
    invalidSupport.probes[i].availability =
        IOSDeviceNativeTruth::Yes;
    invalidSupport.probes[i].deviceSupport =
        static_cast<IOSDeviceNativeTruth>(0xFFu);
    const IOSDeviceFactsData& invalidSupportFacts =
        requireValue(iosMapDeviceNativeSnapshot(invalidSupport));
    requireProbe(
        invalidSupportFacts.probes[i],
        Availability,Availability,i);
  }

  for(uint8_t component=0u; component<3u; ++component) {
    IOSDeviceNativeSnapshot overflow = a17Reference();
    int64_t* runtimeComponents[] = {
      &overflow.runtimeVersion.major,
      &overflow.runtimeVersion.minor,
      &overflow.runtimeVersion.patch,
      };
    *runtimeComponents[component] =
        int64_t(std::numeric_limits<uint16_t>::max())+1;
    const IOSDeviceFactsData& overflowFacts =
        requireValue(iosMapDeviceNativeSnapshot(overflow));
    assert(overflowFacts.runtimeVersion.major==0u);
    assert(overflowFacts.runtimeVersion.minor==0u);
    assert(overflowFacts.runtimeVersion.patch==0u);
    assert(overflowFacts.sdkVersion.major==27u);
    assert(overflowFacts.highestKnownAppleFamily==9u);
    assert(overflowFacts.knownLimitMask==0x170u);

    IOSDeviceNativeSnapshot sdkOverflow = a17Reference();
    int64_t* sdkComponents[] = {
      &sdkOverflow.sdkVersion.major,
      &sdkOverflow.sdkVersion.minor,
      &sdkOverflow.sdkVersion.patch,
      };
    *sdkComponents[component] =
        int64_t(std::numeric_limits<uint16_t>::max())+1;
    const IOSDeviceFactsData& sdkOverflowFacts =
        requireValue(iosMapDeviceNativeSnapshot(sdkOverflow));
    assert(sdkOverflowFacts.runtimeVersion.major==26u);
    requireUnknownVersion(sdkOverflowFacts.sdkVersion);
    assert(sdkOverflowFacts.highestKnownAppleFamily==9u);
    assert(sdkOverflowFacts.knownLimitMask==0x170u);

    IOSDeviceNativeSnapshot runtimeNegativeComponent =
        a17Reference();
    int64_t* runtimeNegativeComponents[] = {
      &runtimeNegativeComponent.runtimeVersion.major,
      &runtimeNegativeComponent.runtimeVersion.minor,
      &runtimeNegativeComponent.runtimeVersion.patch,
      };
    *runtimeNegativeComponents[component] = -1;
    const IOSDeviceFactsData& runtimeNegativeComponentFacts =
        requireValue(
            iosMapDeviceNativeSnapshot(runtimeNegativeComponent));
    requireUnknownVersion(
        runtimeNegativeComponentFacts.runtimeVersion);
    assert(runtimeNegativeComponentFacts.sdkVersion.major==27u);
    assert(runtimeNegativeComponentFacts.highestKnownAppleFamily==9u);
    assert(runtimeNegativeComponentFacts.knownLimitMask==0x170u);

    IOSDeviceNativeSnapshot sdkNegativeComponent =
        a17Reference();
    int64_t* sdkNegativeComponents[] = {
      &sdkNegativeComponent.sdkVersion.major,
      &sdkNegativeComponent.sdkVersion.minor,
      &sdkNegativeComponent.sdkVersion.patch,
      };
    *sdkNegativeComponents[component] = -1;
    const IOSDeviceFactsData& sdkNegativeComponentFacts =
        requireValue(
            iosMapDeviceNativeSnapshot(sdkNegativeComponent));
    assert(sdkNegativeComponentFacts.runtimeVersion.major==26u);
    requireUnknownVersion(sdkNegativeComponentFacts.sdkVersion);
    assert(sdkNegativeComponentFacts.highestKnownAppleFamily==9u);
    assert(sdkNegativeComponentFacts.knownLimitMask==0x170u);
  }

  IOSDeviceNativeSnapshot nonCanonical = a17Reference();
  nonCanonical.runtimeVersion.major = 0;
  nonCanonical.runtimeVersion.minor = 1;
  const IOSDeviceFactsData& nonCanonicalFacts =
      requireValue(iosMapDeviceNativeSnapshot(nonCanonical));
  assert(nonCanonicalFacts.runtimeVersion.major==0u);
  assert(nonCanonicalFacts.runtimeVersion.minor==0u);
  assert(nonCanonicalFacts.runtimeVersion.patch==0u);
  assert(nonCanonicalFacts.sdkVersion.major==27u);

  IOSDeviceNativeSnapshot sdkNonCanonical = a17Reference();
  sdkNonCanonical.sdkVersion.major = 0;
  sdkNonCanonical.sdkVersion.patch = 1;
  const IOSDeviceFactsData& sdkNonCanonicalFacts =
      requireValue(iosMapDeviceNativeSnapshot(sdkNonCanonical));
  assert(sdkNonCanonicalFacts.runtimeVersion.major==26u);
  requireUnknownVersion(sdkNonCanonicalFacts.sdkVersion);

  IOSDeviceNativeSnapshot runtimeNegative = a17Reference();
  runtimeNegative.runtimeVersion.minor = -1;
  const IOSDeviceFactsData& runtimeNegativeFacts =
      requireValue(iosMapDeviceNativeSnapshot(runtimeNegative));
  requireUnknownVersion(runtimeNegativeFacts.runtimeVersion);
  assert(runtimeNegativeFacts.sdkVersion.major==27u);

  IOSDeviceNativeSnapshot negative = a17Reference();
  negative.sdkVersion.patch = -1;
  const IOSDeviceFactsData& negativeFacts =
      requireValue(iosMapDeviceNativeSnapshot(negative));
  assert(negativeFacts.runtimeVersion.major==26u);
  assert(negativeFacts.sdkVersion.major==0u);
  assert(negativeFacts.sdkVersion.minor==0u);
  assert(negativeFacts.sdkVersion.patch==0u);

  constexpr IOSDeviceNativeTruth InvalidVersionStates[] = {
    IOSDeviceNativeTruth::Unknown,
    IOSDeviceNativeTruth::No,
    static_cast<IOSDeviceNativeTruth>(0xFFu),
    };
  for(IOSDeviceNativeTruth invalidState:InvalidVersionStates) {
    IOSDeviceNativeSnapshot runtimeState = a17Reference();
    runtimeState.runtimeVersion.known = invalidState;
    const IOSDeviceFactsData& runtimeStateFacts =
        requireValue(iosMapDeviceNativeSnapshot(runtimeState));
    requireUnknownVersion(runtimeStateFacts.runtimeVersion);
    assert(runtimeStateFacts.sdkVersion.major==27u);

    IOSDeviceNativeSnapshot sdkState = a17Reference();
    sdkState.sdkVersion.known = invalidState;
    const IOSDeviceFactsData& sdkStateFacts =
        requireValue(iosMapDeviceNativeSnapshot(sdkState));
    assert(sdkStateFacts.runtimeVersion.major==26u);
    requireUnknownVersion(sdkStateFacts.sdkVersion);
  }

  for(uint8_t familyIndex=1u; familyIndex<=10u; ++familyIndex) {
    IOSDeviceNativeSnapshot apple;
    apple.knownAppleFamilyMask = appleMask(familyIndex);
    apple.supportedAppleFamilyMask = appleMask(familyIndex);
    const IOSDeviceFactsData& appleFacts =
        requireValue(iosMapDeviceNativeSnapshot(apple));
    assert(appleFacts.highestKnownAppleFamily==familyIndex);
  }
  for(uint8_t familyIndex=3u; familyIndex<=4u; ++familyIndex) {
    IOSDeviceNativeSnapshot metal;
    metal.knownMetalFamilyMask = metalMask(familyIndex);
    metal.supportedMetalFamilyMask = metalMask(familyIndex);
    const IOSDeviceFactsData& metalFacts =
        requireValue(iosMapDeviceNativeSnapshot(metal));
    assert(metalFacts.highestKnownMetalFamily==familyIndex);
  }

  IOSDeviceNativeSnapshot family;
  family.knownAppleFamilyMask = appleMask(8u) | appleMask(10u);
  family.supportedAppleFamilyMask = appleMask(9u) | appleMask(10u);
  family.knownMetalFamilyMask = metalMask(3u);
  family.supportedMetalFamilyMask = metalMask(3u) | metalMask(4u);
  const IOSDeviceFactsData& familyFacts =
      requireValue(iosMapDeviceNativeSnapshot(family));
  assert(familyFacts.highestKnownAppleFamily==10u);
  assert(familyFacts.highestKnownMetalFamily==3u);

  constexpr IOSDeviceLimitId DirectLimits[] = {
    IOSDeviceLimitId::ComputeMaxGroupSizeX,
    IOSDeviceLimitId::ComputeMaxGroupSizeY,
    IOSDeviceLimitId::ComputeMaxGroupSizeZ,
    IOSDeviceLimitId::ComputeMaxSharedMemoryBytes,
    };
  const IOSDeviceNativeSnapshot referenceLimits = a17Reference();
  for(IOSDeviceLimitId directLimit:DirectLimits) {
    const uint8_t index = static_cast<uint8_t>(directLimit);
    IOSDeviceNativeSnapshot oneLimit;
    oneLimit.knownLimitMask = limitMask(directLimit);
    oneLimit.limits[index] = uint64_t(index)+100u;
    const IOSDeviceFactsData& oneLimitFacts =
        requireValue(iosMapDeviceNativeSnapshot(oneLimit));
    assert(oneLimitFacts.knownLimitMask==limitMask(directLimit));
    assert(oneLimitFacts.limits[index]==uint32_t(index)+100u);

    IOSDeviceNativeSnapshot zeroLimit;
    zeroLimit.knownLimitMask = limitMask(directLimit);
    const IOSDeviceFactsData& zeroLimitFacts =
        requireValue(iosMapDeviceNativeSnapshot(zeroLimit));
    assert(zeroLimitFacts.knownLimitMask==limitMask(directLimit));
    assert(zeroLimitFacts.limits[index]==0u);

    IOSDeviceNativeSnapshot overflowLimit = a17Reference();
    overflowLimit.limits[index] =
        uint64_t(std::numeric_limits<uint32_t>::max())+1u;
    const IOSDeviceFactsData& overflowLimitFacts =
        requireValue(iosMapDeviceNativeSnapshot(overflowLimit));
    assert(overflowLimitFacts.knownLimitMask==
           (IOSDeviceNativeKnownLimitMask &
            ~limitMask(directLimit)));
    assert(overflowLimitFacts.limits[index]==0u);
    for(IOSDeviceLimitId otherLimit:DirectLimits) {
      if(otherLimit==directLimit)
        continue;
      const uint8_t otherIndex =
          static_cast<uint8_t>(otherLimit);
      assert(overflowLimitFacts.limits[otherIndex]==
             referenceLimits.limits[otherIndex]);
    }

    IOSDeviceNativeSnapshot missingLimit = a17Reference();
    missingLimit.knownLimitMask &= ~limitMask(directLimit);
    const IOSDeviceFactsData& missingLimitFacts =
        requireValue(iosMapDeviceNativeSnapshot(missingLimit));
    assert(missingLimitFacts.knownLimitMask==
           (IOSDeviceNativeKnownLimitMask &
            ~limitMask(directLimit)));
    assert(missingLimitFacts.limits[index]==0u);
    for(IOSDeviceLimitId otherLimit:DirectLimits) {
      if(otherLimit==directLimit)
        continue;
      const uint8_t otherIndex =
          static_cast<uint8_t>(otherLimit);
      assert(missingLimitFacts.limits[otherIndex]==
             referenceLimits.limits[otherIndex]);
    }
    assert(missingLimitFacts.runtimeVersion.major==26u);
    assert(missingLimitFacts.highestKnownAppleFamily==9u);
  }

  IOSDeviceNativeSnapshot nonContractLimits;
  nonContractLimits.knownLimitMask =
      limitMask(IOSDeviceLimitId::MaxTexture2DDimensionPixels) |
      limitMask(IOSDeviceLimitId::ComputeMaxInvocations) |
      limitMask(IOSDeviceLimitId::MeshMaxGroupSizeZ);
  nonContractLimits.limits[0] = 16384u;
  nonContractLimits.limits[7] = 1024u;
  nonContractLimits.limits[14] = 1024u;
  const IOSDeviceFactsData& nonContractFacts =
      requireValue(iosMapDeviceNativeSnapshot(nonContractLimits));
  assert(nonContractFacts.knownLimitMask==0u);
  assert(nonContractFacts.limits[0]==0u);
  assert(nonContractFacts.limits[7]==0u);
  assert(nonContractFacts.limits[14]==0u);

  IOSDeviceNativeSnapshot zeroMask = a17Reference();
  zeroMask.knownLimitMask = 0u;
  const IOSDeviceFactsData& zeroMaskFacts =
      requireValue(iosMapDeviceNativeSnapshot(zeroMask));
  assert(zeroMaskFacts.knownLimitMask==0u);
  for(uint8_t i=0u; i<LimitCount; ++i)
    assert(zeroMaskFacts.limits[i]==0u);

  return 0;
  }
