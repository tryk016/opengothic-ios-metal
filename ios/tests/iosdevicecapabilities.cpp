#include "graphics/iosdevicecapabilities.h"

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

constexpr uint8_t requiredFormatUsages(uint8_t index) noexcept {
  constexpr uint8_t required[] = {
    0x0Bu,0x0Bu,0x03u,0x05u,0x05u,
    };
  return required[index];
  }

IOSDeviceFactsData canonicalData() {
  IOSDeviceFactsData data{};
  data.abiVersion = IOSDeviceFactsABIVersion;
  data.structSize = IOSDeviceFactsStructSize;
  data.probeContractVersion = IOSDeviceProbeContractVersion;
  data.runtimeVersion = {16u,4u,1u,0u};
  data.sdkVersion = {27u,0u,0u,0u};
  data.highestKnownAppleFamily = 9u;
  data.highestKnownMetalFamily = 3u;
  data.probeCount = ProbeCount;
  data.formatCount = FormatCount;
  data.limitCount = LimitCount;
  for(uint8_t i=0u; i<ProbeCount; ++i) {
    data.probes[i].requiredStages = IOSDeviceRequiredProbeStages;
    data.probes[i].probeId = i;
    }
  data.probes[0].knownStages = IOSDeviceRequiredProbeStages;
  data.probes[0].passedStages = IOSDeviceRequiredProbeStages;
  data.probes[1].knownStages = IOSDeviceRequiredProbeStages;
  data.probes[1].passedStages = Availability;
  data.probes[2].knownStages = Availability;
  data.probes[2].passedStages = Availability;
  data.probes[3].knownStages = Availability;
  data.probes[4].knownStages = 0u;

  for(uint8_t i=0u; i<FormatCount; ++i)
    data.formats[i].requiredUsages = requiredFormatUsages(i);
  data.formats[1].knownUsages = 0x0Bu;
  data.formats[1].supportedUsages = 0x03u;
  data.formats[2].knownUsages = 0x03u;
  data.formats[2].supportedUsages = 0x03u;
  data.formats[3].knownUsages = 0x05u;
  data.formats[3].supportedUsages = 0x01u;

  data.knownLimitMask =
      (1u << static_cast<uint8_t>(
          IOSDeviceLimitId::MaxTexture2DDimensionPixels)) |
      (1u << static_cast<uint8_t>(
          IOSDeviceLimitId::ComputeMaxGroupsX));
  data.limits[static_cast<uint8_t>(
      IOSDeviceLimitId::MaxTexture2DDimensionPixels)] = 16384u;
  data.limits[static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxGroupsX)] = 0u;
  return data;
  }

bool sameFailure(
    const IOSDeviceFactsFailure& actual,
    IOSDeviceFactsError error,
    IOSDeviceFactsSection section,
    uint8_t index,
    uint32_t raw) {
  return actual.error==error &&
         actual.section==section &&
         actual.index==index &&
         actual.reserved==0u &&
         actual.raw==raw;
  }

template<class Mutate>
bool rejects(
    Mutate mutate,
    IOSDeviceFactsError error,
    IOSDeviceFactsSection section,
    uint8_t index,
    uint32_t raw,
    uint32_t& mutations) {
  IOSDeviceFactsData data = canonicalData();
  mutate(data);
  const IOSDeviceFactsCreateResult result =
      IOSDeviceFacts::create(data);
  ++mutations;
  return !result.value.has_value() &&
         sameFailure(result.failure,error,section,index,raw);
  }

template<class Mutate>
bool accepts(Mutate mutate, uint32_t& mutations) {
  IOSDeviceFactsData data = canonicalData();
  mutate(data);
  const IOSDeviceFactsCreateResult result =
      IOSDeviceFacts::create(data);
  ++mutations;
  return result.value.has_value() &&
         sameFailure(
             result.failure,
             IOSDeviceFactsError::None,
             IOSDeviceFactsSection::None,
             0xFFu,0u);
  }

enum class LocalState : uint8_t {
  NotApplicable,
  Unknown,
  No,
  Yes,
  };

constexpr LocalState probeState(
    const ProbeFacts& facts,
    uint8_t stage) noexcept {
  if((facts.requiredStages & stage)==0u)
    return LocalState::NotApplicable;
  if((facts.knownStages & stage)==0u)
    return LocalState::Unknown;
  return (facts.passedStages & stage)==0u
      ? LocalState::No
      : LocalState::Yes;
  }

}

int main() {
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSDeviceProbeId>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSDeviceProbeStage>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSDeviceFormatId>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSDeviceFormatUsage>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSDeviceLimitId>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSDeviceFactsError>,uint8_t>);
  static_assert(std::is_same_v<
      std::underlying_type_t<IOSDeviceFactsSection>,uint8_t>);

  static_assert(IOSDeviceFactsABIVersion==1u);
  static_assert(IOSDeviceFactsStructSize==192u);
  static_assert(IOSDeviceProbeContractVersion==1u);
  static_assert(IOSDeviceRequiredProbeStages==0x03u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceProbeId::MetalFxSpatial)==0u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceProbeId::MetalFxTemporal)==1u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceProbeId::MeshShading)==2u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceProbeId::RayTracing)==3u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceProbeId::Metal4Transport)==4u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceProbeId::Count)==5u);
  static_assert(Availability==0x01u);
  static_assert(DeviceSupport==0x02u);
  static_assert(sizeof(ProbeFacts)==4u);
  static_assert(offsetof(ProbeFacts,requiredStages)==0u);
  static_assert(offsetof(ProbeFacts,knownStages)==1u);
  static_assert(offsetof(ProbeFacts,passedStages)==2u);
  static_assert(offsetof(ProbeFacts,probeId)==3u);

  static_assert(static_cast<uint8_t>(
      IOSDeviceFormatId::Rg11B10Float)==0u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFormatId::Rgba16Float)==1u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFormatId::Rg16Float)==2u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFormatId::Depth16Unorm)==3u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFormatId::Depth32Float)==4u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFormatId::Count)==5u);
  static_assert(Sampled==0x01u);
  static_assert(ColorAttachment==0x02u);
  static_assert(DepthAttachment==0x04u);
  static_assert(ShaderWrite==0x08u);
  static_assert(sizeof(FormatFacts)==4u);
  static_assert(offsetof(FormatFacts,requiredUsages)==0u);
  static_assert(offsetof(FormatFacts,knownUsages)==1u);
  static_assert(offsetof(FormatFacts,supportedUsages)==2u);
  static_assert(offsetof(FormatFacts,reserved)==3u);

  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::MaxTexture2DDimensionPixels)==0u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxGroupsX)==1u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxGroupsY)==2u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxGroupsZ)==3u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxGroupSizeX)==4u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxGroupSizeY)==5u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxGroupSizeZ)==6u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxInvocations)==7u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::ComputeMaxSharedMemoryBytes)==8u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::MeshMaxGroupsX)==9u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::MeshMaxGroupsY)==10u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::MeshMaxGroupsZ)==11u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::MeshMaxGroupSizeX)==12u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::MeshMaxGroupSizeY)==13u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::MeshMaxGroupSizeZ)==14u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceLimitId::Count)==15u);
  static_assert(sizeof(IOSVersionTriplet)==8u);
  static_assert(offsetof(IOSVersionTriplet,major)==0u);
  static_assert(offsetof(IOSVersionTriplet,minor)==2u);
  static_assert(offsetof(IOSVersionTriplet,patch)==4u);
  static_assert(offsetof(IOSVersionTriplet,reserved)==6u);
  static_assert(sizeof(IOSDeviceFactsData)==192u);
  static_assert(alignof(IOSDeviceFactsData)==4u);
  static_assert(std::is_standard_layout_v<IOSDeviceFactsData>);
  static_assert(std::is_trivial_v<IOSDeviceFactsData>);
  static_assert(std::is_trivially_copyable_v<IOSDeviceFactsData>);
  static_assert(std::is_trivially_destructible_v<IOSDeviceFactsData>);
  static_assert(offsetof(IOSDeviceFactsData,abiVersion)==0u);
  static_assert(offsetof(IOSDeviceFactsData,structSize)==4u);
  static_assert(offsetof(IOSDeviceFactsData,probeContractVersion)==8u);
  static_assert(offsetof(IOSDeviceFactsData,flags)==12u);
  static_assert(offsetof(IOSDeviceFactsData,runtimeVersion)==16u);
  static_assert(offsetof(IOSDeviceFactsData,sdkVersion)==24u);
  static_assert(offsetof(IOSDeviceFactsData,highestKnownAppleFamily)==32u);
  static_assert(offsetof(IOSDeviceFactsData,highestKnownMetalFamily)==33u);
  static_assert(offsetof(IOSDeviceFactsData,probeCount)==34u);
  static_assert(offsetof(IOSDeviceFactsData,formatCount)==35u);
  static_assert(offsetof(IOSDeviceFactsData,limitCount)==36u);
  static_assert(offsetof(IOSDeviceFactsData,reservedHeader)==37u);
  static_assert(offsetof(IOSDeviceFactsData,probes)==40u);
  static_assert(offsetof(IOSDeviceFactsData,formats)==60u);
  static_assert(offsetof(IOSDeviceFactsData,knownLimitMask)==80u);
  static_assert(offsetof(IOSDeviceFactsData,limits)==84u);
  static_assert(offsetof(IOSDeviceFactsData,reserved)==144u);

  static_assert(sizeof(IOSDeviceFactsFailure)==8u);
  static_assert(alignof(IOSDeviceFactsFailure)==4u);
  static_assert(offsetof(IOSDeviceFactsFailure,error)==0u);
  static_assert(offsetof(IOSDeviceFactsFailure,section)==1u);
  static_assert(offsetof(IOSDeviceFactsFailure,index)==2u);
  static_assert(offsetof(IOSDeviceFactsFailure,reserved)==3u);
  static_assert(offsetof(IOSDeviceFactsFailure,raw)==4u);

  static_assert(!std::is_default_constructible_v<IOSDeviceFacts>);
  static_assert(!std::is_constructible_v<
      IOSDeviceFacts,const IOSDeviceFactsData&>);
  static_assert(std::is_final_v<IOSDeviceFacts>);
  static_assert(sizeof(IOSDeviceFacts)==192u);
  static_assert(alignof(IOSDeviceFacts)==4u);
  static_assert(std::is_standard_layout_v<IOSDeviceFacts>);
  static_assert(std::is_trivially_copyable_v<IOSDeviceFacts>);
  static_assert(std::is_trivially_destructible_v<IOSDeviceFacts>);
  static_assert(std::is_copy_constructible_v<IOSDeviceFacts>);
  static_assert(std::is_move_constructible_v<IOSDeviceFacts>);
  static_assert(!std::is_copy_assignable_v<IOSDeviceFacts>);
  static_assert(!std::is_move_assignable_v<IOSDeviceFacts>);
  using CreateSignature = IOSDeviceFactsCreateResult (*)(
      const IOSDeviceFactsData&) noexcept;
  using FactsSignature =
      const IOSDeviceFactsData& (IOSDeviceFacts::*)() const noexcept;
  static_assert(std::is_same_v<
      decltype(&IOSDeviceFacts::create),CreateSignature>);
  static_assert(std::is_same_v<
      decltype(&IOSDeviceFacts::facts),FactsSignature>);
  static_assert(std::is_same_v<
      decltype(IOSDeviceFactsCreateResult::value),
      std::optional<IOSDeviceFacts>>);
  static_assert(std::is_same_v<
      decltype(IOSDeviceFactsCreateResult::failure),
      IOSDeviceFactsFailure>);
  static_assert(noexcept(IOSDeviceFacts::create(
      std::declval<const IOSDeviceFactsData&>())));
  static_assert(std::is_same_v<
      decltype(std::declval<const IOSDeviceFacts&>().facts()),
      const IOSDeviceFactsData&>);

  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::None)==0u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::AbiVersionMismatch)==1u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::StructSizeMismatch)==2u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::ProbeContractVersionMismatch)==3u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::FlagsNonZero)==4u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::ProbeCountMismatch)==5u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::FormatCountMismatch)==6u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::LimitCountMismatch)==7u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::VersionUnknownTupleNonZero)==8u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::VersionReservedNonZero)==9u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::HighestKnownAppleFamilyOutOfRange)==10u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::HighestKnownMetalFamilyOutOfRange)==11u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::ReservedNonZero)==12u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::ProbeOrder)==13u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::ProbeRequiredStagesMismatch)==14u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::ProbeKnownStagesOutsideRequired)==15u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::ProbePassedStagesOutsideKnown)==16u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::ProbeDeviceSupportWithoutAvailability)==17u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::FormatRequiredUsagesMismatch)==18u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::FormatKnownUsagesOutsideRequired)==19u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::FormatSupportedUsagesOutsideKnown)==20u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::LimitKnownMaskOutOfRange)==21u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsError::UnknownLimitValueNonZero)==22u);

  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::None)==0u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::Header)==1u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::RuntimeVersion)==2u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::SdkVersion)==3u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::Families)==4u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::ReservedHeader)==5u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::Probe)==6u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::Format)==7u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::Limit)==8u);
  static_assert(static_cast<uint8_t>(
      IOSDeviceFactsSection::ReservedTail)==9u);

  IOSDeviceFactsData input = canonicalData();
  IOSDeviceFactsCreateResult canonical =
      IOSDeviceFacts::create(input);
  assert(canonical.value.has_value());
  assert(sameFailure(
      canonical.failure,
      IOSDeviceFactsError::None,
      IOSDeviceFactsSection::None,
      0xFFu,0u));
  assert(canonical.value->facts().abiVersion==
         IOSDeviceFactsABIVersion);
  input.abiVersion = 99u;
  assert(canonical.value->facts().abiVersion==
         IOSDeviceFactsABIVersion);
  IOSDeviceFacts copied(*canonical.value);
  IOSDeviceFacts moved(std::move(copied));
  assert(moved.facts().structSize==IOSDeviceFactsStructSize);

  const IOSDeviceFactsData& facts = canonical.value->facts();
  assert(probeState(facts.probes[0],Availability)==LocalState::Yes);
  assert(probeState(facts.probes[1],DeviceSupport)==LocalState::No);
  assert(probeState(facts.probes[2],DeviceSupport)==LocalState::Unknown);
  ProbeFacts notApplicable = facts.probes[2];
  notApplicable.requiredStages = Availability;
  assert(probeState(notApplicable,DeviceSupport)==
         LocalState::NotApplicable);

  uint32_t mutations = 0u;
  assert(rejects(
      [](auto& data) { data.abiVersion = 2u; },
      IOSDeviceFactsError::AbiVersionMismatch,
      IOSDeviceFactsSection::Header,0u,2u,mutations));
  assert(rejects(
      [](auto& data) { data.structSize = 191u; },
      IOSDeviceFactsError::StructSizeMismatch,
      IOSDeviceFactsSection::Header,1u,191u,mutations));
  assert(rejects(
      [](auto& data) { data.probeContractVersion = 2u; },
      IOSDeviceFactsError::ProbeContractVersionMismatch,
      IOSDeviceFactsSection::Header,2u,2u,mutations));
  assert(rejects(
      [](auto& data) { data.flags = 1u; },
      IOSDeviceFactsError::FlagsNonZero,
      IOSDeviceFactsSection::Header,3u,1u,mutations));
  assert(rejects(
      [](auto& data) { data.probeCount = 4u; },
      IOSDeviceFactsError::ProbeCountMismatch,
      IOSDeviceFactsSection::Header,4u,4u,mutations));
  assert(rejects(
      [](auto& data) { data.formatCount = 4u; },
      IOSDeviceFactsError::FormatCountMismatch,
      IOSDeviceFactsSection::Header,5u,4u,mutations));
  assert(rejects(
      [](auto& data) { data.limitCount = 14u; },
      IOSDeviceFactsError::LimitCountMismatch,
      IOSDeviceFactsSection::Header,6u,14u,mutations));

  for(const bool runtime:{true,false}) {
    const IOSDeviceFactsSection section = runtime
        ? IOSDeviceFactsSection::RuntimeVersion
        : IOSDeviceFactsSection::SdkVersion;
    assert(rejects(
        [runtime](auto& data) {
          auto& version =
              runtime ? data.runtimeVersion : data.sdkVersion;
          version.major = 0u;
          version.minor = 7u;
          version.patch = 8u;
          version.reserved = 9u;
          },
        IOSDeviceFactsError::VersionUnknownTupleNonZero,
        section,1u,7u,mutations));
    assert(rejects(
        [runtime](auto& data) {
          auto& version =
              runtime ? data.runtimeVersion : data.sdkVersion;
          version.major = 0u;
          version.minor = 0u;
          version.patch = 8u;
          version.reserved = 9u;
          },
        IOSDeviceFactsError::VersionUnknownTupleNonZero,
        section,2u,8u,mutations));
    assert(rejects(
        [runtime](auto& data) {
          auto& version =
              runtime ? data.runtimeVersion : data.sdkVersion;
          version.major = 0u;
          version.minor = 0u;
          version.patch = 0u;
          version.reserved = 9u;
          },
        IOSDeviceFactsError::VersionReservedNonZero,
        section,3u,9u,mutations));
    assert(rejects(
        [runtime](auto& data) {
          auto& version =
              runtime ? data.runtimeVersion : data.sdkVersion;
          version.major = 1u;
          version.reserved = 9u;
          },
        IOSDeviceFactsError::VersionReservedNonZero,
        section,3u,9u,mutations));
    assert(accepts(
        [runtime](auto& data) {
          auto& version =
              runtime ? data.runtimeVersion : data.sdkVersion;
          version = {};
          },
        mutations));
    assert(accepts(
        [runtime](auto& data) {
          auto& version =
              runtime ? data.runtimeVersion : data.sdkVersion;
          version = {1u,65535u,65535u,0u};
          },
        mutations));
    }

  assert(rejects(
      [](auto& data) { data.highestKnownAppleFamily = 11u; },
      IOSDeviceFactsError::HighestKnownAppleFamilyOutOfRange,
      IOSDeviceFactsSection::Families,0u,11u,mutations));
  assert(rejects(
      [](auto& data) { data.highestKnownMetalFamily = 5u; },
      IOSDeviceFactsError::HighestKnownMetalFamilyOutOfRange,
      IOSDeviceFactsSection::Families,1u,5u,mutations));
  assert(accepts(
      [](auto& data) {
        data.highestKnownAppleFamily = 0u;
        data.highestKnownMetalFamily = 0u;
        },
      mutations));
  assert(accepts(
      [](auto& data) {
        data.highestKnownAppleFamily = 10u;
        data.highestKnownMetalFamily = 4u;
        },
      mutations));

  for(uint8_t i=0u; i<3u; ++i) {
    assert(rejects(
        [i](auto& data) { data.reservedHeader[i] = uint8_t(i+1u); },
        IOSDeviceFactsError::ReservedNonZero,
        IOSDeviceFactsSection::ReservedHeader,i,uint32_t(i+1u),
        mutations));
    }

  for(uint8_t i=0u; i<ProbeCount; ++i) {
    assert(rejects(
        [i](auto& data) {
          data.probes[i].probeId = uint8_t((i+1u)%ProbeCount);
          },
        IOSDeviceFactsError::ProbeOrder,
        IOSDeviceFactsSection::Probe,i,uint32_t((i+1u)%ProbeCount),
        mutations));
    assert(rejects(
        [i](auto& data) { data.probes[i].requiredStages = Availability; },
        IOSDeviceFactsError::ProbeRequiredStagesMismatch,
        IOSDeviceFactsSection::Probe,i,Availability,mutations));
    assert(rejects(
        [i](auto& data) {
          data.probes[i].knownStages =
              uint8_t(data.probes[i].requiredStages | 0x80u);
          },
        IOSDeviceFactsError::ProbeKnownStagesOutsideRequired,
        IOSDeviceFactsSection::Probe,i,
        uint32_t(IOSDeviceRequiredProbeStages | 0x80u),mutations));
    assert(rejects(
        [i](auto& data) {
          data.probes[i].knownStages = 0u;
          data.probes[i].passedStages = Availability;
          },
        IOSDeviceFactsError::ProbePassedStagesOutsideKnown,
        IOSDeviceFactsSection::Probe,i,Availability,mutations));
    const uint32_t dependencyRaw =
        uint32_t(IOSDeviceRequiredProbeStages) |
        (uint32_t(DeviceSupport) << 8u) |
        (uint32_t(i) << 24u);
    assert(rejects(
        [i](auto& data) {
          data.probes[i].knownStages = DeviceSupport;
          data.probes[i].passedStages = 0u;
          },
        IOSDeviceFactsError::ProbeDeviceSupportWithoutAvailability,
        IOSDeviceFactsSection::Probe,i,dependencyRaw,mutations));
    const uint32_t availabilityNoRaw =
        uint32_t(IOSDeviceRequiredProbeStages) |
        (uint32_t(IOSDeviceRequiredProbeStages) << 8u) |
        (uint32_t(DeviceSupport) << 16u) |
        (uint32_t(i) << 24u);
    assert(rejects(
        [i](auto& data) {
          data.probes[i].knownStages =
              IOSDeviceRequiredProbeStages;
          data.probes[i].passedStages = DeviceSupport;
          },
        IOSDeviceFactsError::ProbeDeviceSupportWithoutAvailability,
        IOSDeviceFactsSection::Probe,i,availabilityNoRaw,mutations));
    }

  for(uint8_t i=0u; i<FormatCount; ++i) {
    assert(rejects(
        [i](auto& data) { data.formats[i].requiredUsages ^= 0x01u; },
        IOSDeviceFactsError::FormatRequiredUsagesMismatch,
        IOSDeviceFactsSection::Format,i,
        uint32_t(requiredFormatUsages(i) ^ 0x01u),mutations));
    assert(rejects(
        [i](auto& data) {
          data.formats[i].knownUsages =
              uint8_t(data.formats[i].requiredUsages | 0x80u);
          },
        IOSDeviceFactsError::FormatKnownUsagesOutsideRequired,
        IOSDeviceFactsSection::Format,i,
        uint32_t(requiredFormatUsages(i) | 0x80u),mutations));
    assert(rejects(
        [i](auto& data) {
          data.formats[i].knownUsages = 0u;
          data.formats[i].supportedUsages =
              data.formats[i].requiredUsages;
          },
        IOSDeviceFactsError::FormatSupportedUsagesOutsideKnown,
        IOSDeviceFactsSection::Format,i,
        requiredFormatUsages(i),mutations));
    assert(rejects(
        [i](auto& data) { data.formats[i].reserved = uint8_t(i+1u); },
        IOSDeviceFactsError::ReservedNonZero,
        IOSDeviceFactsSection::Format,i,uint32_t(i+1u),mutations));
    }

  for(uint8_t bit=LimitCount; bit<32u; ++bit) {
    const uint32_t mask =
        canonicalData().knownLimitMask | (1u << bit);
    assert(rejects(
        [bit](auto& data) { data.knownLimitMask |= 1u << bit; },
        IOSDeviceFactsError::LimitKnownMaskOutOfRange,
        IOSDeviceFactsSection::Limit,0xFFu,mask,mutations));
    }
  for(uint8_t i=0u; i<LimitCount; ++i) {
    assert(rejects(
        [i](auto& data) {
          data.knownLimitMask &= ~(1u << i);
          data.limits[i] = uint32_t(i)+1u;
          },
        IOSDeviceFactsError::UnknownLimitValueNonZero,
        IOSDeviceFactsSection::Limit,i,uint32_t(i)+1u,mutations));
    assert(accepts(
        [i](auto& data) {
          data.knownLimitMask |= 1u << i;
          data.limits[i] = 0u;
        },
        mutations));
    }
  assert(accepts(
      [](auto& data) {
        data.probes[static_cast<uint8_t>(
            IOSDeviceProbeId::MeshShading)].knownStages =
                Availability;
        data.probes[static_cast<uint8_t>(
            IOSDeviceProbeId::MeshShading)].passedStages = 0u;
        data.knownLimitMask = (1u << LimitCount)-1u;
        for(uint8_t i=0u; i<LimitCount; ++i)
          data.limits[i] = uint32_t(i)+1u;
        },
      mutations));

  for(uint8_t i=0u; i<12u; ++i) {
    assert(rejects(
        [i](auto& data) { data.reserved[i] = uint32_t(i)+1u; },
        IOSDeviceFactsError::ReservedNonZero,
        IOSDeviceFactsSection::ReservedTail,i,uint32_t(i)+1u,
        mutations));
    }

  assert(rejects(
      [](auto& data) {
        data.abiVersion = 2u;
        data.flags = 1u;
        data.runtimeVersion = {0u,1u,1u,1u};
        },
      IOSDeviceFactsError::AbiVersionMismatch,
      IOSDeviceFactsSection::Header,0u,2u,mutations));
  assert(rejects(
      [](auto& data) {
        data.limitCount = 14u;
        data.runtimeVersion = {0u,1u,0u,0u};
        },
      IOSDeviceFactsError::LimitCountMismatch,
      IOSDeviceFactsSection::Header,6u,14u,mutations));
  assert(rejects(
      [](auto& data) {
        data.runtimeVersion = {0u,1u,2u,3u};
        data.sdkVersion = {0u,4u,5u,6u};
        },
      IOSDeviceFactsError::VersionUnknownTupleNonZero,
      IOSDeviceFactsSection::RuntimeVersion,1u,1u,mutations));
  assert(rejects(
      [](auto& data) {
        data.sdkVersion = {0u,0u,2u,0u};
        data.highestKnownAppleFamily = 11u;
        },
      IOSDeviceFactsError::VersionUnknownTupleNonZero,
      IOSDeviceFactsSection::SdkVersion,2u,2u,mutations));
  assert(rejects(
      [](auto& data) {
        data.highestKnownAppleFamily = 11u;
        data.highestKnownMetalFamily = 5u;
        },
      IOSDeviceFactsError::HighestKnownAppleFamilyOutOfRange,
      IOSDeviceFactsSection::Families,0u,11u,mutations));
  assert(rejects(
      [](auto& data) {
        data.highestKnownMetalFamily = 5u;
        data.reservedHeader[0] = 1u;
        },
      IOSDeviceFactsError::HighestKnownMetalFamilyOutOfRange,
      IOSDeviceFactsSection::Families,1u,5u,mutations));
  assert(rejects(
      [](auto& data) {
        data.reservedHeader[0] = 1u;
        data.reservedHeader[1] = 2u;
        },
      IOSDeviceFactsError::ReservedNonZero,
      IOSDeviceFactsSection::ReservedHeader,0u,1u,mutations));
  assert(rejects(
      [](auto& data) {
        data.reservedHeader[2] = 3u;
        data.probes[0].probeId = 4u;
        },
      IOSDeviceFactsError::ReservedNonZero,
      IOSDeviceFactsSection::ReservedHeader,2u,3u,mutations));
  assert(rejects(
      [](auto& data) {
        data.probes[0].probeId = 4u;
        data.probes[0].requiredStages = Availability;
        data.probes[0].knownStages = 0x80u;
        data.probes[0].passedStages = 0x80u;
        },
      IOSDeviceFactsError::ProbeOrder,
      IOSDeviceFactsSection::Probe,0u,4u,mutations));
  assert(rejects(
      [](auto& data) {
        data.probes[0].requiredStages = Availability;
        data.probes[0].knownStages = 0x80u;
        },
      IOSDeviceFactsError::ProbeRequiredStagesMismatch,
      IOSDeviceFactsSection::Probe,0u,Availability,mutations));
  assert(rejects(
      [](auto& data) {
        data.probes[0].requiredStages = Availability;
        data.probes[1].probeId = 4u;
        },
      IOSDeviceFactsError::ProbeRequiredStagesMismatch,
      IOSDeviceFactsSection::Probe,0u,Availability,mutations));
  assert(rejects(
      [](auto& data) {
        data.probes[4].knownStages = DeviceSupport;
        data.probes[4].passedStages = 0u;
        data.formats[0].requiredUsages = Sampled;
        },
      IOSDeviceFactsError::ProbeDeviceSupportWithoutAvailability,
      IOSDeviceFactsSection::Probe,4u,
      uint32_t(IOSDeviceRequiredProbeStages) |
          (uint32_t(DeviceSupport) << 8u) |
          (uint32_t(4u) << 24u),
      mutations));
  assert(rejects(
      [](auto& data) {
        data.formats[0].requiredUsages = Sampled;
        data.formats[0].knownUsages = 0x80u;
        data.formats[0].supportedUsages = 0x80u;
        data.formats[0].reserved = 1u;
        },
      IOSDeviceFactsError::FormatRequiredUsagesMismatch,
      IOSDeviceFactsSection::Format,0u,Sampled,mutations));
  assert(rejects(
      [](auto& data) {
        data.formats[0].knownUsages = 0u;
        data.formats[0].supportedUsages = Sampled;
        data.formats[1].requiredUsages = Sampled;
        },
      IOSDeviceFactsError::FormatSupportedUsagesOutsideKnown,
      IOSDeviceFactsSection::Format,0u,Sampled,mutations));
  assert(rejects(
      [](auto& data) {
        data.formats[4].reserved = 7u;
        data.knownLimitMask |= 1u << 31u;
        },
      IOSDeviceFactsError::ReservedNonZero,
      IOSDeviceFactsSection::Format,4u,7u,mutations));
  assert(rejects(
      [](auto& data) {
        data.knownLimitMask |= 1u << 31u;
        data.limits[2] = 7u;
        },
      IOSDeviceFactsError::LimitKnownMaskOutOfRange,
      IOSDeviceFactsSection::Limit,0xFFu,
      canonicalData().knownLimitMask | (1u << 31u),mutations));
  assert(rejects(
      [](auto& data) {
        data.limits[2] = 3u;
        data.limits[3] = 4u;
        },
      IOSDeviceFactsError::UnknownLimitValueNonZero,
      IOSDeviceFactsSection::Limit,2u,3u,mutations));
  assert(rejects(
      [](auto& data) {
        data.limits[14] = 15u;
        data.reserved[0] = 1u;
        },
      IOSDeviceFactsError::UnknownLimitValueNonZero,
      IOSDeviceFactsSection::Limit,14u,15u,mutations));
  assert(rejects(
      [](auto& data) {
        data.reserved[0] = 1u;
        data.reserved[1] = 2u;
        },
      IOSDeviceFactsError::ReservedNonZero,
      IOSDeviceFactsSection::ReservedTail,0u,1u,mutations));

  assert(mutations==155u);
  return 0;
  }
