#pragma once

#include "iosframeplan.h"

#include <cstddef>
#include <cstdint>

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
#include "iosmetalcapturesession.h"
#endif

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
// Compatibility adapter over the shared isolated-probe capture session.
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
    IOSMetalCaptureSession session;
  };
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
