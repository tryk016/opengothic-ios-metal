#pragma once

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)

#include <cstddef>
#include <cstdint>

namespace Tempest {
class Device;
}

enum class IOSMetalCaptureArtifactKind : uint8_t {
  File,
  Directory,
  };

struct IOSMetalCaptureArtifact final {
  IOSMetalCaptureArtifactKind kind = IOSMetalCaptureArtifactKind::File;
  uint64_t bytes = 0u;
  };

enum class IOSLinearHDRCaptureStartResult : uint8_t {
  Started,
  RejectedInactive,
  AmbiguousActive,
  };

enum class IOSMetalCaptureExistingArtifactPolicy : uint8_t {
  RemoveExactOwned,
  RequireAbsent,
  };

struct IOSMetalCaptureStartObservation final {
  bool startReturn = false;
  bool activeAfter = false;
  bool complete = false;
  };

// Apple GPU trace packages may use relative in-package symlinks for shared
// resource payloads. Descriptor-anchor the complete walk, prepare every copy
// before commit, roll back partial commits, require a zero-symlink/special-node
// rescan, and revalidate the root name through its retained parent descriptor.
// Kept host-neutral for mutation tests.
[[nodiscard]] bool iosMetalNormalizeAndInspectCaptureArtifact(
    const char* rootPath,
    IOSMetalCaptureArtifact& artifact,
    const char*& reason) noexcept;

#if defined(OPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS)
// Host-only deterministic fault hook; never compiled into the iOS target.
void iosMetalCaptureNormalizerFailCommitForTesting(
    std::size_t index) noexcept;
void iosMetalCaptureNormalizerSetBeforeRootCheckHookForTesting(
    void (*hook)(const char*) noexcept) noexcept;
#endif

// MRC-safe, fail-closed programmatic capture around an isolated RendererIOS
// probe. The session borrows the existing Tempest Metal device and never
// creates a device, queue, command buffer or drawable.
class IOSMetalCaptureSession final {
  public:
    IOSMetalCaptureSession() noexcept = default;
    ~IOSMetalCaptureSession();

    IOSMetalCaptureSession(const IOSMetalCaptureSession&) = delete;
    IOSMetalCaptureSession& operator=(const IOSMetalCaptureSession&) = delete;

    [[nodiscard]] bool start(Tempest::Device& device,
                             const char* artifactName,
                             const char*& reason) noexcept;
    [[nodiscard]] IOSLinearHDRCaptureStartResult beginCapture(
        Tempest::Device& device,
        const char* artifactName,
        IOSMetalCaptureExistingArtifactPolicy existingArtifactPolicy,
        const char*& reason) noexcept;
    [[nodiscard]] bool stopAndInspect(IOSMetalCaptureArtifact& artifact,
                                      const char*& reason) noexcept;
    void cancel() noexcept;
    void reset() noexcept;
    [[nodiscard]] bool initialized() const noexcept;
    [[nodiscard]] bool active() const noexcept;
    [[nodiscard]] IOSMetalCaptureStartObservation
        startObservation() const noexcept;

  private:
    struct Impl;
    Impl* impl = nullptr;
  };

const char* iosMetalCaptureArtifactKindName(
    IOSMetalCaptureArtifactKind kind) noexcept;

#endif
