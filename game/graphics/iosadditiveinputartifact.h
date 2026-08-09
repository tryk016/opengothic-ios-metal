#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

inline constexpr std::size_t IOSAdditiveInputV1HeaderBytes = 64u;
inline constexpr std::size_t IOSAdditiveInputV1RecordBytes = 256u;
inline constexpr std::size_t IOSAdditiveInputV1ConstantsBytes = 160u;
inline constexpr uint64_t IOSAdditiveInputV1MinimumBaseRecords = 1u;
inline constexpr uint64_t IOSAdditiveInputV1MaximumBaseRecords = 100000u;
inline constexpr uint64_t IOSAdditiveInputV1AdditiveRecords = 183u;
inline constexpr uint64_t IOSAdditiveInputV1MaximumRecords = 100183u;
inline constexpr uint64_t IOSAdditiveInputV1MaximumPayloadBytes = 25646848u;
inline constexpr uint64_t IOSAdditiveInputMaterialFlagStaticAdditiveNone =
    uint64_t(1u) << 0u;

enum class IOSAdditiveInputKind : uint8_t {
  Landscape = 1u,
  Static = 2u,
  Movable = 3u,
  };

enum class IOSAdditiveInputCategory : uint8_t {
  Opaque = 0u,
  AlphaTest = 1u,
  Additive = 3u,
  };

enum class IOSAdditiveInputAnimation : uint8_t {
  None = 0u,
  FrameOnly = 1u,
  UvOnly = 2u,
  FrameAndUv = 3u,
  };

enum class IOSAdditiveInputTextureFormat : uint32_t {
  Rgba8Unorm = 1u,
  Bc1Rgba = 2u,
  Bc2Rgba = 3u,
  Bc3Rgba = 4u,
  };

enum class IOSAdditiveInputPhase : uint8_t {
  Base = 0u,
  Additive = 1u,
  };

struct IOSAdditiveInputHeaderV1 final {
  uint64_t baseCount = 0u;
  uint64_t additiveCount = 0u;
  uint64_t targetGeneration = 0u;
  uint64_t snapshotSequence = 0u;

  constexpr bool operator==(const IOSAdditiveInputHeaderV1&) const noexcept =
      default;
  };

struct IOSAdditiveInputRecordV1 final {
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
  IOSAdditiveInputTextureFormat textureFormat =
      IOSAdditiveInputTextureFormat::Rgba8Unorm;
  IOSAdditiveInputKind kind = IOSAdditiveInputKind::Landscape;
  IOSAdditiveInputCategory category = IOSAdditiveInputCategory::Opaque;
  IOSAdditiveInputAnimation animation = IOSAdditiveInputAnimation::None;
  std::array<std::byte,IOSAdditiveInputV1ConstantsBytes> constants{};

  constexpr bool operator==(const IOSAdditiveInputRecordV1&) const noexcept =
      default;
  };

struct IOSAdditiveInputArtifactViewV1 final {
  IOSAdditiveInputHeaderV1 header;
  std::span<const std::byte> basePayload;
  std::span<const std::byte> additivePayload;
  };

inline constexpr bool iosAdditiveInputArtifactV1AcceptsPublication(
    const IOSAdditiveInputHeaderV1& header,
    uint64_t preparedSerial,
    uint64_t submittedSerial,
    bool submitted,
    bool accepted,
    bool terminalCompleted,
    bool gpuSucceeded,
    uint64_t acceptedGeneration,
    uint64_t acceptedSequence) noexcept {
  return header.baseCount>=IOSAdditiveInputV1MinimumBaseRecords &&
      header.baseCount<=IOSAdditiveInputV1MaximumBaseRecords &&
      header.additiveCount==IOSAdditiveInputV1AdditiveRecords &&
      header.targetGeneration!=0u && header.snapshotSequence!=0u &&
      preparedSerial!=0u && preparedSerial==submittedSerial && submitted &&
      accepted && terminalCompleted && gpuSucceeded &&
      header.targetGeneration==acceptedGeneration &&
      header.snapshotSequence==acceptedSequence;
  }

enum class IOSAdditiveInputArtifactError : uint8_t {
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
  NonZeroRecordReserved,
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

enum class IOSAdditiveInputPublishResult : uint8_t {
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
  };

IOSAdditiveInputArtifactError iosValidateAdditiveInputRecordV1(
    const IOSAdditiveInputRecordV1& record,
    IOSAdditiveInputPhase phase) noexcept;
IOSAdditiveInputArtifactError iosBuildAdditiveInputArtifactV1(
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::span<const IOSAdditiveInputRecordV1> base,
    std::span<const IOSAdditiveInputRecordV1> additive,
    std::vector<std::byte>& artifact) noexcept;
IOSAdditiveInputArtifactError iosParseAdditiveInputArtifactV1(
    std::span<const std::byte> input,
    IOSAdditiveInputArtifactViewV1& view) noexcept;
IOSAdditiveInputArtifactError iosDecodeAdditiveInputRecordV1(
    std::span<const std::byte> encoded,
    IOSAdditiveInputPhase phase,
    IOSAdditiveInputRecordV1& record) noexcept;

bool iosAdditiveInputArtifactV1Filename(
    char mode,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::string& filename) noexcept;
IOSAdditiveInputPublishResult iosPublishAdditiveInputArtifactV1NoClobber(
    std::string_view directory,
    char mode,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::span<const std::byte> artifact,
    std::string_view temporaryTag,
    std::string& publishedPath) noexcept;
