#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <vector>

namespace Tempest {
class Attachment;
class Device;
}

inline constexpr std::size_t IOSMultiply2CoverageProofV1HeaderBytes = 160u;
inline constexpr uint32_t IOSMultiply2CoverageProofV1MaximumExtent = 4096u;
inline constexpr uint64_t IOSMultiply2CoverageProofV1MaximumPayloadBytes =
    uint64_t(IOSMultiply2CoverageProofV1MaximumExtent)*
    uint64_t(IOSMultiply2CoverageProofV1MaximumExtent);

struct IOSMultiply2CoverageRect final {
  uint32_t x = 0u;
  uint32_t y = 0u;
  uint32_t width = 0u;
  uint32_t height = 0u;

  constexpr bool operator==(
      const IOSMultiply2CoverageRect&) const noexcept = default;
};

struct IOSMultiply2CoverageProofMetadata final {
  uint32_t width = 0u;
  uint32_t height = 0u;
  uint32_t bytesPerRow = 0u;
  uint32_t sampleCount = 0u;
  uint64_t payloadBytes = 0u;
  uint64_t targetGeneration = 0u;
  uint64_t snapshotSequence = 0u;
  uint64_t sourceId = 0u;
  uint64_t indexByteOffset = 0u;
  uint64_t indexCount = 0u;
  IOSMultiply2CoverageRect viewport;
  IOSMultiply2CoverageRect scissor;
  std::array<uint8_t,16u> proofId{};
  std::array<uint8_t,20u> buildSha{};
};

struct IOSMultiply2CoverageProofView final {
  IOSMultiply2CoverageProofMetadata metadata;
  std::span<const std::byte> payload;
};

enum class IOSMultiply2CoverageProofError : uint8_t {
  None = 0u,
  InvalidInputSize,
  InvalidMagic,
  UnsupportedSchema,
  InvalidHeaderSize,
  InvalidExtent,
  InvalidRowPitch,
  InvalidSampleCount,
  InvalidPayloadSize,
  InvalidIdentity,
  InvalidViewport,
  NonZeroReserved,
  InvalidPayload,
  MissingCoverage,
  SizeOverflow,
};

bool iosBuildMultiply2CoverageProofV1(
    const IOSMultiply2CoverageProofMetadata& metadata,
    std::span<const std::byte> payload,
    std::vector<std::byte>& artifact) noexcept;
IOSMultiply2CoverageProofError iosParseMultiply2CoverageProofV1(
    std::span<const std::byte> artifact,
    IOSMultiply2CoverageProofView& view) noexcept;

struct IOSMultiply2CoverageNativeView final {
  void* depthStencilTexture = nullptr;
  void* coverageBuffer = nullptr;
  uint32_t width = 0u;
  uint32_t height = 0u;
  uint32_t gpuBytesPerRow = 0u;
  IOSMultiply2CoverageProofMetadata metadata;
};

enum class IOSMultiply2CoverageProducerState : uint8_t {
  Disabled,
  Armed,
  Prepared,
  Encoded,
  Submitted,
  Published,
  Failed,
};

class IOSMultiply2CoverageFrame final {
  public:
    IOSMultiply2CoverageFrame() noexcept;
    ~IOSMultiply2CoverageFrame();
    IOSMultiply2CoverageFrame(IOSMultiply2CoverageFrame&&) noexcept;
    IOSMultiply2CoverageFrame& operator=(IOSMultiply2CoverageFrame&&) noexcept;

    IOSMultiply2CoverageFrame(const IOSMultiply2CoverageFrame&) = delete;
    IOSMultiply2CoverageFrame& operator=(
        const IOSMultiply2CoverageFrame&) = delete;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;

  friend class IOSMultiply2CoverageProofProducer;
};

class IOSMultiply2CoverageProofProducer final {
  public:
    explicit IOSMultiply2CoverageProofProducer(Tempest::Device& device) noexcept;
    ~IOSMultiply2CoverageProofProducer();

    IOSMultiply2CoverageProofProducer(
        const IOSMultiply2CoverageProofProducer&) = delete;
    IOSMultiply2CoverageProofProducer& operator=(
        const IOSMultiply2CoverageProofProducer&) = delete;

    IOSMultiply2CoverageProducerState state() const noexcept;
    bool armed() const noexcept;
    bool prepareFrame(
        IOSMultiply2CoverageFrame& frame,
        const Tempest::Attachment& sceneHDR,
        const IOSMultiply2CoverageProofMetadata& metadata) noexcept;
    bool nativeView(
        const IOSMultiply2CoverageFrame& frame,
        IOSMultiply2CoverageNativeView& view) const noexcept;
    bool markEncoded(IOSMultiply2CoverageFrame& frame) noexcept;
    void markSubmitted(IOSMultiply2CoverageFrame& frame) noexcept;
    void markSubmitAmbiguous(IOSMultiply2CoverageFrame& frame) noexcept;
    void abortBeforeSubmit(IOSMultiply2CoverageFrame& frame) noexcept;
    void markPostSubmitFailure(IOSMultiply2CoverageFrame& frame) noexcept;
    void markIdleFailure(IOSMultiply2CoverageFrame& frame) noexcept;
    bool isSubmitted(const IOSMultiply2CoverageFrame& frame) const noexcept;
    bool hasOwners(const IOSMultiply2CoverageFrame& frame) const noexcept;
    bool completeAfterTerminal(
        IOSMultiply2CoverageFrame& frame,
        uint64_t currentTargetGeneration,
        uint32_t currentWidth,
        uint32_t currentHeight) noexcept;
    void releaseAfterTerminal(IOSMultiply2CoverageFrame& frame) noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
