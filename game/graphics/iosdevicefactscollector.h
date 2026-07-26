#pragma once

#include "iosdevicecapabilities.h"

#include <cstdint>

namespace Tempest {
class Device;
}

enum class IOSDeviceNativeTruth : uint8_t {
  Unknown = 0u,
  No = 1u,
  Yes = 2u,
  };

struct IOSDeviceNativeVersion final {
  int64_t major = 0;
  int64_t minor = 0;
  int64_t patch = 0;
  IOSDeviceNativeTruth known = IOSDeviceNativeTruth::Unknown;
  };

struct IOSDeviceNativeProbe final {
  IOSDeviceNativeTruth availability = IOSDeviceNativeTruth::Unknown;
  IOSDeviceNativeTruth deviceSupport = IOSDeviceNativeTruth::Unknown;
  };

struct IOSDeviceNativeFormat final {
  uint8_t knownUsages = 0u;
  uint8_t supportedUsages = 0u;
  };

struct IOSDeviceNativeSnapshot final {
  IOSDeviceNativeVersion runtimeVersion;
  IOSDeviceNativeVersion sdkVersion;
  uint16_t knownAppleFamilyMask = 0u;
  uint16_t supportedAppleFamilyMask = 0u;
  uint8_t knownMetalFamilyMask = 0u;
  uint8_t supportedMetalFamilyMask = 0u;
  IOSDeviceNativeProbe probes[5];
  IOSDeviceNativeFormat formats[5];
  uint32_t knownLimitMask = 0u;
  uint64_t limits[15] = {};
  };

inline constexpr uint32_t IOSDeviceNativeKnownLimitMask =
    (1u << static_cast<uint8_t>(
        IOSDeviceLimitId::ComputeMaxGroupSizeX)) |
    (1u << static_cast<uint8_t>(
        IOSDeviceLimitId::ComputeMaxGroupSizeY)) |
    (1u << static_cast<uint8_t>(
        IOSDeviceLimitId::ComputeMaxGroupSizeZ)) |
    (1u << static_cast<uint8_t>(
        IOSDeviceLimitId::ComputeMaxSharedMemoryBytes));

IOSDeviceFactsCreateResult iosMapDeviceNativeSnapshot(
    const IOSDeviceNativeSnapshot& snapshot) noexcept;

IOSDeviceFactsCreateResult iosCollectDeviceFacts(
    const Tempest::Device& device) noexcept;

void iosLogDeviceFacts(
    const IOSDeviceFactsCreateResult& result) noexcept;
