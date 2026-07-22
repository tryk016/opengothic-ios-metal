#pragma once

#include "iosframeplan.h"

#include <cstddef>
#include <cstdint>

namespace Tempest {
class CommandBuffer;
class Device;
template<class T>
class Encoder;
}

class IOSMetalResourceTexture;

enum class IOSMetalResourceClearPassPlanStatus : uint8_t {
  Supported   = 0,
  Invalid     = 1,
  Unsupported = 2,
  };

struct IOSMetalResourceClearPassSelection final {
  IOSMetalResourceClearPassPlanStatus status =
      IOSMetalResourceClearPassPlanStatus::Unsupported;
  std::size_t presentResource = 0u;
  std::size_t privateResource = 0u;
  std::size_t memorylessResource = 0u;
  std::size_t privatePass = 0u;
  std::size_t memorylessPass = 0u;
  std::size_t presentPass = 0u;

  explicit operator bool() const noexcept {
    return status==IOSMetalResourceClearPassPlanStatus::Supported;
    }
  };

// The ABI 4 logical contract contains three resources and three passes. The
// external Present anchor is deliberately never encoded by this probe.
[[nodiscard]] IOSFramePlan iosMetalResourceClearPassPlan();

[[nodiscard]] IOSMetalResourceClearPassSelection
    iosMetalResourceSelectClearPassPlan(const IOSFramePlan& plan) noexcept;

const char* iosMetalResourceClearPassPlanStatusName(
    IOSMetalResourceClearPassPlanStatus status) noexcept;

struct IOSMetalResourceClearPassNativeReport final {
  uint32_t physicalPasses = 0u;
  uint32_t commandBuffers = 0u;
  uint32_t renderEncoders = 0u;
  uint32_t submits = 0u;
  uint32_t draws = 0u;
  uint32_t pipelines = 0u;
  uint32_t drawable = 0u;
  uint32_t present = 0u;
  IOSLoadAction privateLoad = IOSLoadAction::NotApplicable;
  IOSStoreAction privateStore = IOSStoreAction::NotApplicable;
  IOSLoadAction memorylessLoad = IOSLoadAction::NotApplicable;
  IOSStoreAction memorylessStore = IOSStoreAction::NotApplicable;
  bool encoded = false;
  };

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
enum class IOSMetalCaptureArtifactKind : uint8_t {
  File,
  Directory,
  };

struct IOSMetalCaptureArtifact final {
  IOSMetalCaptureArtifactKind kind = IOSMetalCaptureArtifactKind::File;
  uint64_t bytes = 0u;
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

// MRC-safe, fail-closed programmatic capture around only the clear-only probe.
// The implementation borrows the existing Tempest Metal device and never
// creates a device, queue, command buffer or drawable.
class IOSMetalResourceClearPassCapture final {
  public:
    IOSMetalResourceClearPassCapture() noexcept = default;
    ~IOSMetalResourceClearPassCapture();

    IOSMetalResourceClearPassCapture(
        const IOSMetalResourceClearPassCapture&) = delete;
    IOSMetalResourceClearPassCapture& operator=(
        const IOSMetalResourceClearPassCapture&) = delete;

    [[nodiscard]] bool start(Tempest::Device& device,
                             const char*& reason) noexcept;
    [[nodiscard]] bool stopAndInspect(IOSMetalCaptureArtifact& artifact,
                                      const char*& reason) noexcept;
    void cancel() noexcept;
    [[nodiscard]] bool active() const noexcept;

  private:
    struct Impl;
    Impl* impl = nullptr;
  };

const char* iosMetalCaptureArtifactKindName(
    IOSMetalCaptureArtifactKind kind) noexcept;
#endif

[[nodiscard]] bool iosMetalResourceClearPassNativeReportMatches(
    const IOSMetalResourceClearPassNativeReport& report) noexcept;

// Encodes into the already active, virgin Tempest command buffer. Ownership,
// submit, fence polling and lifetime accounting remain with IOSMetalContext.
[[nodiscard]] bool iosMetalResourceEncodeClearPassProbe(
    Tempest::Device& device,
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSMetalResourceTexture& privateTexture,
    const IOSMetalResourceTexture& memorylessTexture,
    IOSMetalResourceClearPassNativeReport& report);
