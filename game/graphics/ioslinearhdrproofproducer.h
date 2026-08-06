#pragma once

#include "ioslinearhdrproof.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string_view>
#include <vector>

namespace Tempest {
class Attachment;
class CommandBuffer;
class Device;
template<class T>
class Encoder;
}

enum class IOSLinearHDRProofProducerState : uint8_t {
  Disabled,
  Armed,
  Encoded,
  Submitted,
  Completed,
  Published,
  Failed,
  };

enum class IOSLinearHDRProofProducerEvent : uint8_t {
  Arm,
  Encode,
  Submit,
  Complete,
  Publish,
  Fail,
  };

enum class IOSLinearHDRProofFailureClass : uint8_t {
  Contract,
  Gpu,
  Io,
  };

enum class IOSLinearHDRProofFailureReason : uint8_t {
  Rng,
  RngZero,
  Sha,
  Layout,
  State,
  Target,
  Label,
  BufferAlloc,
  BufferMap,
  CopyEncode,
  SubmitAmbiguous,
  Fence,
  Idle,
  Present,
  Stale,
  Parse,
  Open,
  Write,
  FileFsync,
  Close,
  Rename,
  DirFsync,
  Cleanup,
  };

struct IOSLinearHDRProofMetadata final {
  uint32_t width = 0u;
  uint32_t height = 0u;
  uint32_t bytesPerRow = 0u;
  uint64_t logicalBytes = 0u;
  uint64_t targetGeneration = 0u;
  uint64_t snapshotSequence = 0u;
  std::array<uint8_t,16u> proofId{};
  std::array<uint8_t,20u> buildSha{};
  };

bool iosAdvanceLinearHDRProofProducerState(
    IOSLinearHDRProofProducerState& state,
    IOSLinearHDRProofProducerEvent event) noexcept;
IOSLinearHDRProofFailureClass iosLinearHDRProofFailureClass(
    IOSLinearHDRProofFailureReason reason) noexcept;
const char* iosLinearHDRProofFailureClassName(
    IOSLinearHDRProofFailureClass value) noexcept;
const char* iosLinearHDRProofFailureReasonName(
    IOSLinearHDRProofFailureReason value) noexcept;
bool iosLinearHDRProofParseBuildSha(
    std::string_view text,
    std::array<uint8_t,20u>& bytes) noexcept;
bool iosLinearHDRProofFormatIdentity(
    const std::array<uint8_t,16u>& bytes,
    std::array<char,33u>& text) noexcept;
bool iosLinearHDRProofBuildArtifactV1(
    const IOSLinearHDRProofMetadata& metadata,
    std::span<const std::byte> payload,
    std::vector<std::byte>& artifact) noexcept;
bool iosLinearHDRProofFormatSuccessLine(
    const IOSLinearHDRProofMetadata& metadata,
    std::array<char,255u>& line) noexcept;

class IOSLinearHDRProofFrame final {
  public:
    IOSLinearHDRProofFrame() noexcept;
    ~IOSLinearHDRProofFrame();
    IOSLinearHDRProofFrame(IOSLinearHDRProofFrame&&) noexcept;
    IOSLinearHDRProofFrame& operator=(IOSLinearHDRProofFrame&&) noexcept;

    IOSLinearHDRProofFrame(const IOSLinearHDRProofFrame&) = delete;
    IOSLinearHDRProofFrame& operator=(const IOSLinearHDRProofFrame&) = delete;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;

  friend class IOSLinearHDRProofProducer;
  };

class IOSLinearHDRProofProducer final {
  public:
    explicit IOSLinearHDRProofProducer(Tempest::Device& device) noexcept;
    ~IOSLinearHDRProofProducer();

    IOSLinearHDRProofProducer(const IOSLinearHDRProofProducer&) = delete;
    IOSLinearHDRProofProducer& operator=(
        const IOSLinearHDRProofProducer&) = delete;

    IOSLinearHDRProofProducerState state() const noexcept;
    bool armed() const noexcept;
    bool labelSceneTarget(Tempest::Attachment& target) noexcept;
    bool prepareFrame(
        IOSLinearHDRProofFrame& frame,
        const Tempest::Attachment& source,
        uint64_t targetGeneration,
        uint64_t snapshotSequence,
        uint32_t width,
        uint32_t height) noexcept;
    bool encodeCopy(
        IOSLinearHDRProofFrame& frame,
        Tempest::Encoder<Tempest::CommandBuffer>& encoder,
        const Tempest::Attachment& source) noexcept;
    void markSubmitted(IOSLinearHDRProofFrame& frame) noexcept;
    void markSubmitAmbiguous(IOSLinearHDRProofFrame& frame) noexcept;
    void abortBeforeSubmit(IOSLinearHDRProofFrame& frame) noexcept;
    void latchPresentFailure(IOSLinearHDRProofFrame& frame) noexcept;
    void markFenceFailure(IOSLinearHDRProofFrame& frame) noexcept;
    void markIdleFailure(IOSLinearHDRProofFrame& frame) noexcept;
    void markPostSubmitFailure(IOSLinearHDRProofFrame& frame) noexcept;
    bool isSubmitted(const IOSLinearHDRProofFrame& frame) const noexcept;
    bool hasOwners(const IOSLinearHDRProofFrame& frame) const noexcept;
    void completeAfterTerminal(
        IOSLinearHDRProofFrame& frame,
        uint64_t currentTargetGeneration,
        uint32_t currentWidth,
        uint32_t currentHeight) noexcept;
    void releaseAfterTerminal(IOSLinearHDRProofFrame& frame) noexcept;

    std::string_view sceneMarker() const noexcept;
    std::string_view copyMarker() const noexcept;
    std::string_view toneResolveMarker() const noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
  };
