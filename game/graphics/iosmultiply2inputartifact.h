#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

inline constexpr std::size_t IOSMultiply2InputV1HeaderBytes = 64u;
inline constexpr std::size_t IOSMultiply2InputV1RecordBytes = 256u;
inline constexpr std::size_t IOSMultiply2InputV1ConstantsBytes = 160u;
inline constexpr uint64_t IOSMultiply2InputV1MinimumBaseRecords = 1u;
inline constexpr uint64_t IOSMultiply2InputV1MaximumBaseRecords = 100000u;
inline constexpr uint64_t IOSMultiply2InputV1Multiply2Records = 1u;
inline constexpr uint64_t IOSMultiply2InputV1MaximumRecords = 100001u;
inline constexpr uint64_t IOSMultiply2InputV1MaximumPayloadBytes = 25600256u;
inline constexpr uint64_t IOSMultiply2InputMaterialFlagStaticNone =
    uint64_t(1u) << 1u;

enum class IOSMultiply2InputKind : uint8_t {
  Landscape = 1u,
  Static = 2u,
  Movable = 3u,
  };

enum class IOSMultiply2InputCategory : uint8_t {
  Opaque = 0u,
  AlphaTest = 1u,
  Multiply2 = 5u,
  };

enum class IOSMultiply2InputAnimation : uint8_t {
  None = 0u,
  FrameOnly = 1u,
  UvOnly = 2u,
  FrameAndUv = 3u,
  };

enum class IOSMultiply2InputTextureFormat : uint32_t {
  Rgba8Unorm = 1u,
  Bc1Rgba = 2u,
  Bc2Rgba = 3u,
  Bc3Rgba = 4u,
  };

enum class IOSMultiply2InputPhase : uint8_t {
  Base = 0u,
  Multiply2 = 1u,
  };

struct IOSMultiply2InputHeaderV1 final {
  uint64_t baseCount = 0u;
  uint64_t multiply2Count = 0u;
  uint64_t targetGeneration = 0u;
  uint64_t snapshotSequence = 0u;

  constexpr bool operator==(const IOSMultiply2InputHeaderV1&) const noexcept =
      default;
  };

struct IOSMultiply2InputRecordV1 final {
  uint64_t sourceId = 0u;
  uint64_t meshId = 0u;
  uint64_t materialId = 0u;
  uint64_t textureId = 0u;
  uint64_t indexByteOffset = 0u;
  uint64_t indexCount = 0u;
  uint64_t vertexBufferBytes = 0u;
  uint64_t indexBufferBytes = 0u;
  uint64_t materialFlags = 0u;
  uint32_t vertexStride = 0u;
  uint32_t textureWidth = 0u;
  uint32_t textureHeight = 0u;
  uint32_t textureMipCount = 0u;
  IOSMultiply2InputTextureFormat textureFormat =
      IOSMultiply2InputTextureFormat::Rgba8Unorm;
  IOSMultiply2InputKind kind = IOSMultiply2InputKind::Landscape;
  IOSMultiply2InputCategory category = IOSMultiply2InputCategory::Opaque;
  IOSMultiply2InputAnimation animation = IOSMultiply2InputAnimation::None;
  IOSMultiply2InputPhase phase = IOSMultiply2InputPhase::Base;
  std::array<std::byte,IOSMultiply2InputV1ConstantsBytes> constants{};

  constexpr bool operator==(const IOSMultiply2InputRecordV1&) const noexcept =
      default;
  };

struct IOSMultiply2InputArtifactViewV1 final {
  IOSMultiply2InputHeaderV1 header;
  std::span<const std::byte> basePayload;
  std::span<const std::byte> multiply2Payload;
  };

inline constexpr bool iosMultiply2InputArtifactV1AcceptsPublication(
    const IOSMultiply2InputHeaderV1& header,
    uint64_t preparedSerial,
    uint64_t submittedSerial,
    bool submitted,
    bool accepted,
    bool terminalCompleted,
    bool gpuSucceeded,
    uint64_t acceptedGeneration,
    uint64_t acceptedSequence) noexcept {
  return header.baseCount>=IOSMultiply2InputV1MinimumBaseRecords &&
      header.baseCount<=IOSMultiply2InputV1MaximumBaseRecords &&
      header.multiply2Count==IOSMultiply2InputV1Multiply2Records &&
      header.targetGeneration!=0u && header.snapshotSequence!=0u &&
      preparedSerial!=0u && preparedSerial==submittedSerial && submitted &&
      accepted && terminalCompleted && gpuSucceeded &&
      header.targetGeneration==acceptedGeneration &&
      header.snapshotSequence==acceptedSequence;
  }

enum class IOSMultiply2InputArtifactError : uint8_t {
  None = 0u,
  InvalidInputSize,
  InvalidMagic,
  UnsupportedSchema,
  InvalidEndian,
  InvalidHeaderSize,
  InvalidCounts,
  InvalidRecordSize,
  InvalidConstantsSize,
  InvalidIdentity,
  NonZeroHeaderFlags,
  NonZeroHeaderReserved,
  SizeOverflow,
  UnknownKind,
  UnknownCategory,
  UnknownAnimation,
  UnknownTextureFormat,
  UnknownMaterialFlags,
  InvalidRecord,
  InvalidPhaseRecord,
  SourceOrder,
  DuplicateSource,
  AllocationFailure,
  };

enum class IOSMultiply2InputPublishResult : uint8_t {
  Published = 0u,
  InvalidArgument,
  InvalidArtifact,
  OpenDirectoryFailed,
  TemporaryExists,
  OpenTemporaryFailed,
  WriteFailed,
  FileSyncFailed,
  CloseFailed,
  AlreadyExists,
  PublishFailed,
  TemporaryCleanupFailed,
  DirectorySyncFailed,
  DirectoryPolicyFailed,
  PublishedFilePolicyFailed,
  ReadBackFailed,
  VerificationFailed,
  };

IOSMultiply2InputArtifactError iosValidateMultiply2InputRecordV1(
    const IOSMultiply2InputRecordV1& record) noexcept;
IOSMultiply2InputArtifactError iosBuildMultiply2InputArtifactV1(
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::span<const IOSMultiply2InputRecordV1> base,
    std::span<const IOSMultiply2InputRecordV1> multiply2,
    std::vector<std::byte>& artifact) noexcept;
IOSMultiply2InputArtifactError iosParseMultiply2InputArtifactV1(
    std::span<const std::byte> input,
    IOSMultiply2InputArtifactViewV1& view) noexcept;
IOSMultiply2InputArtifactError iosDecodeMultiply2InputRecordV1(
    std::span<const std::byte> encoded,
    IOSMultiply2InputRecordV1& record) noexcept;

bool iosMultiply2InputArtifactV1Filename(
    char mode,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::string& filename) noexcept;
IOSMultiply2InputPublishResult iosPublishMultiply2InputArtifactV1NoClobber(
    std::string_view directory,
    char mode,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::span<const std::byte> artifact,
    std::string_view temporaryTag,
    std::string& publishedPath,
    std::vector<std::byte>& publishedBytes) noexcept;
