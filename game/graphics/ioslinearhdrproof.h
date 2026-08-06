#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

#include "ioslinearhdr.h"

inline constexpr size_t IOSLinearHDRProofV1HeaderBytes = 160u;
inline constexpr uint32_t IOSLinearHDRProofV1MaximumExtent = 16384u;
inline constexpr uint64_t IOSLinearHDRProofV1MaximumPayloadBytes =
    256u*1024u*1024u;

enum class IOSLinearHDRProofChannel : uint8_t {
  R = 0u,
  G = 1u,
  B = 2u,
  };

struct IOSLinearHDRProofView final {
  std::span<const std::byte> payload;
  uint32_t width = 0u;
  uint32_t height = 0u;
  uint32_t bytesPerRow = 0u;
  uint64_t logicalBytes = 0u;
  uint64_t targetGeneration = 0u;
  uint64_t snapshotSequence = 0u;
  std::array<uint8_t,16u> proofId{};
  std::array<uint8_t,20u> buildSha{};
  };

struct IOSLinearHDRProofScan final {
  IOSLinearHDRRGB maximum;
  uint32_t x = 0u;
  uint32_t y = 0u;
  IOSLinearHDRProofChannel channel = IOSLinearHDRProofChannel::R;
  };

enum class IOSLinearHDRProofError : uint8_t {
  None = 0u,
  InvalidInputSize = 1u,
  InvalidMagic = 2u,
  UnsupportedSchema = 3u,
  InvalidHeaderSize = 4u,
  UnsupportedProducerVersion = 5u,
  UnsupportedPixelFormat = 6u,
  InvalidExtent = 7u,
  InvalidRowPitch = 8u,
  InvalidLogicalBytes = 9u,
  InvalidIdentity = 10u,
  InvalidSubresource = 11u,
  NonZeroReserved = 12u,
  InvalidResourceLabel = 13u,
  SizeOverflow = 14u,
  InvalidView = 15u,
  InvalidPackedValue = 16u,
  };

bool iosDecodeLinearHDRRG11B10(
    uint32_t word,
    IOSLinearHDRRGB& decoded) noexcept;
IOSLinearHDRProofError iosParseLinearHDRProofV1(
    std::span<const std::byte> input,
    IOSLinearHDRProofView& view) noexcept;
IOSLinearHDRProofError iosScanLinearHDRProofV1(
    const IOSLinearHDRProofView& view,
    IOSLinearHDRProofScan& scan) noexcept;
