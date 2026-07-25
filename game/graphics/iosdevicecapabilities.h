#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <type_traits>

inline constexpr uint32_t IOSDeviceFactsABIVersion = 1u;
inline constexpr uint32_t IOSDeviceFactsStructSize = 192u;
inline constexpr uint32_t IOSDeviceProbeContractVersion = 1u;

enum class IOSDeviceProbeId : uint8_t {
  MetalFxSpatial = 0u,
  MetalFxTemporal = 1u,
  MeshShading = 2u,
  RayTracing = 3u,
  Metal4Transport = 4u,
  Count = 5u,
  };

enum IOSDeviceProbeStage : uint8_t {
  Availability = 1u << 0u,
  DeviceSupport = 1u << 1u,
  };

inline constexpr uint8_t IOSDeviceRequiredProbeStages =
    Availability | DeviceSupport;

struct ProbeFacts final {
  uint8_t requiredStages;
  uint8_t knownStages;
  uint8_t passedStages;
  uint8_t probeId;
  };

enum class IOSDeviceFormatId : uint8_t {
  Rg11B10Float = 0u,
  Rgba16Float = 1u,
  Rg16Float = 2u,
  Depth16Unorm = 3u,
  Depth32Float = 4u,
  Count = 5u,
  };

enum IOSDeviceFormatUsage : uint8_t {
  Sampled = 1u << 0u,
  ColorAttachment = 1u << 1u,
  DepthAttachment = 1u << 2u,
  ShaderWrite = 1u << 3u,
  };

struct FormatFacts final {
  uint8_t requiredUsages;
  uint8_t knownUsages;
  uint8_t supportedUsages;
  uint8_t reserved;
  };

enum class IOSDeviceLimitId : uint8_t {
  MaxTexture2DDimensionPixels = 0u,
  ComputeMaxGroupsX = 1u,
  ComputeMaxGroupsY = 2u,
  ComputeMaxGroupsZ = 3u,
  ComputeMaxGroupSizeX = 4u,
  ComputeMaxGroupSizeY = 5u,
  ComputeMaxGroupSizeZ = 6u,
  ComputeMaxInvocations = 7u,
  ComputeMaxSharedMemoryBytes = 8u,
  MeshMaxGroupsX = 9u,
  MeshMaxGroupsY = 10u,
  MeshMaxGroupsZ = 11u,
  MeshMaxGroupSizeX = 12u,
  MeshMaxGroupSizeY = 13u,
  MeshMaxGroupSizeZ = 14u,
  Count = 15u,
  };

struct IOSVersionTriplet final {
  uint16_t major;
  uint16_t minor;
  uint16_t patch;
  uint16_t reserved;
  };

struct alignas(4) IOSDeviceFactsData final {
  uint32_t abiVersion;
  uint32_t structSize;
  uint32_t probeContractVersion;
  uint32_t flags;
  IOSVersionTriplet runtimeVersion;
  IOSVersionTriplet sdkVersion;
  uint8_t highestKnownAppleFamily;
  uint8_t highestKnownMetalFamily;
  uint8_t probeCount;
  uint8_t formatCount;
  uint8_t limitCount;
  uint8_t reservedHeader[3];
  ProbeFacts probes[5];
  FormatFacts formats[5];
  uint32_t knownLimitMask;
  uint32_t limits[15];
  uint32_t reserved[12];
  };

enum class IOSDeviceFactsError : uint8_t {
  None = 0u,
  AbiVersionMismatch = 1u,
  StructSizeMismatch = 2u,
  ProbeContractVersionMismatch = 3u,
  FlagsNonZero = 4u,
  ProbeCountMismatch = 5u,
  FormatCountMismatch = 6u,
  LimitCountMismatch = 7u,
  VersionUnknownTupleNonZero = 8u,
  VersionReservedNonZero = 9u,
  HighestKnownAppleFamilyOutOfRange = 10u,
  HighestKnownMetalFamilyOutOfRange = 11u,
  ReservedNonZero = 12u,
  ProbeOrder = 13u,
  ProbeRequiredStagesMismatch = 14u,
  ProbeKnownStagesOutsideRequired = 15u,
  ProbePassedStagesOutsideKnown = 16u,
  ProbeDeviceSupportWithoutAvailability = 17u,
  FormatRequiredUsagesMismatch = 18u,
  FormatKnownUsagesOutsideRequired = 19u,
  FormatSupportedUsagesOutsideKnown = 20u,
  LimitKnownMaskOutOfRange = 21u,
  UnknownLimitValueNonZero = 22u,
  };

enum class IOSDeviceFactsSection : uint8_t {
  None = 0u,
  Header = 1u,
  RuntimeVersion = 2u,
  SdkVersion = 3u,
  Families = 4u,
  ReservedHeader = 5u,
  Probe = 6u,
  Format = 7u,
  Limit = 8u,
  ReservedTail = 9u,
  };

struct IOSDeviceFactsFailure final {
  IOSDeviceFactsError error = IOSDeviceFactsError::None;
  IOSDeviceFactsSection section = IOSDeviceFactsSection::None;
  uint8_t index = 0xFFu;
  uint8_t reserved = 0u;
  uint32_t raw = 0u;
  };

struct IOSDeviceFactsCreateResult;

class IOSDeviceFacts final {
  public:
    IOSDeviceFacts(const IOSDeviceFacts&) = default;
    IOSDeviceFacts(IOSDeviceFacts&&) = default;
    IOSDeviceFacts& operator=(const IOSDeviceFacts&) = delete;
    IOSDeviceFacts& operator=(IOSDeviceFacts&&) = delete;

    static IOSDeviceFactsCreateResult create(
        const IOSDeviceFactsData& data) noexcept;

    const IOSDeviceFactsData& facts() const noexcept;

  private:
    IOSDeviceFacts() = delete;
    explicit IOSDeviceFacts(const IOSDeviceFactsData& source) noexcept
      : data_(source) {
      }

  private:
    IOSDeviceFactsData data_;
  };

struct IOSDeviceFactsCreateResult final {
  std::optional<IOSDeviceFacts> value;
  IOSDeviceFactsFailure failure;
  };

static_assert(static_cast<uint8_t>(IOSDeviceProbeId::MetalFxSpatial)==0u);
static_assert(static_cast<uint8_t>(IOSDeviceProbeId::MetalFxTemporal)==1u);
static_assert(static_cast<uint8_t>(IOSDeviceProbeId::MeshShading)==2u);
static_assert(static_cast<uint8_t>(IOSDeviceProbeId::RayTracing)==3u);
static_assert(static_cast<uint8_t>(IOSDeviceProbeId::Metal4Transport)==4u);
static_assert(static_cast<uint8_t>(IOSDeviceProbeId::Count)==5u);
static_assert(Availability==0x01u);
static_assert(DeviceSupport==0x02u);
static_assert(sizeof(ProbeFacts)==4u);
static_assert(alignof(ProbeFacts)==1u);
static_assert(std::is_trivial_v<ProbeFacts>);
static_assert(offsetof(ProbeFacts,requiredStages)==0u);
static_assert(offsetof(ProbeFacts,knownStages)==1u);
static_assert(offsetof(ProbeFacts,passedStages)==2u);
static_assert(offsetof(ProbeFacts,probeId)==3u);

static_assert(static_cast<uint8_t>(IOSDeviceFormatId::Rg11B10Float)==0u);
static_assert(static_cast<uint8_t>(IOSDeviceFormatId::Rgba16Float)==1u);
static_assert(static_cast<uint8_t>(IOSDeviceFormatId::Rg16Float)==2u);
static_assert(static_cast<uint8_t>(IOSDeviceFormatId::Depth16Unorm)==3u);
static_assert(static_cast<uint8_t>(IOSDeviceFormatId::Depth32Float)==4u);
static_assert(static_cast<uint8_t>(IOSDeviceFormatId::Count)==5u);
static_assert(Sampled==0x01u);
static_assert(ColorAttachment==0x02u);
static_assert(DepthAttachment==0x04u);
static_assert(ShaderWrite==0x08u);
static_assert(sizeof(FormatFacts)==4u);
static_assert(alignof(FormatFacts)==1u);
static_assert(std::is_trivial_v<FormatFacts>);
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
static_assert(static_cast<uint8_t>(IOSDeviceLimitId::Count)==15u);

static_assert(sizeof(IOSVersionTriplet)==8u);
static_assert(alignof(IOSVersionTriplet)==2u);
static_assert(std::is_trivial_v<IOSVersionTriplet>);
static_assert(offsetof(IOSVersionTriplet,major)==0u);
static_assert(offsetof(IOSVersionTriplet,minor)==2u);
static_assert(offsetof(IOSVersionTriplet,patch)==4u);
static_assert(offsetof(IOSVersionTriplet,reserved)==6u);
static_assert(sizeof(IOSDeviceFactsData)==IOSDeviceFactsStructSize);
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
static_assert(std::is_standard_layout_v<IOSDeviceFactsFailure>);
static_assert(std::is_trivially_copyable_v<IOSDeviceFactsFailure>);
static_assert(offsetof(IOSDeviceFactsFailure,error)==0u);
static_assert(offsetof(IOSDeviceFactsFailure,section)==1u);
static_assert(offsetof(IOSDeviceFactsFailure,index)==2u);
static_assert(offsetof(IOSDeviceFactsFailure,reserved)==3u);
static_assert(offsetof(IOSDeviceFactsFailure,raw)==4u);
