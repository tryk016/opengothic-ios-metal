#pragma once

#include "iosscenesnapshot.h"

#include <cstdint>
#include <utility>

class IOSMetalContext;
class RendererIOS;

class IOSUIPacket final {
  public:
    IOSUIPacket() noexcept = default;
    IOSUIPacket(const IOSUIPacket&) = delete;
    IOSUIPacket& operator=(const IOSUIPacket&) = delete;

    IOSUIPacket(IOSUIPacket&& other) noexcept;
    IOSUIPacket& operator=(IOSUIPacket&& other) noexcept;

  private:
    explicit IOSUIPacket(uint64_t serial) noexcept;

    uint64_t transportSerial = 0;

  friend class IOSMetalContext;
  };

class IOSVideoPacket final {
  public:
    IOSVideoPacket() noexcept = default;
    IOSVideoPacket(const IOSVideoPacket&) = delete;
    IOSVideoPacket& operator=(const IOSVideoPacket&) = delete;

    IOSVideoPacket(IOSVideoPacket&& other) noexcept;
    IOSVideoPacket& operator=(IOSVideoPacket&& other) noexcept;

  private:
    explicit IOSVideoPacket(uint64_t serial) noexcept;

    uint64_t transportSerial = 0;

  friend class IOSMetalContext;
  };

struct IOSCaptureRequest final {
  enum class Kind : uint8_t {
    None,
    SavePreview,
    };

  Kind kind = Kind::None;

  static constexpr IOSCaptureRequest savePreview() noexcept {
    return {Kind::SavePreview};
    }
  };

class IOSFrameInput final {
  public:
    IOSFrameInput(IOSSceneSnapshotPtr snapshot,
                  IOSUIPacket&& ui,
                  IOSVideoPacket&& video,
                  IOSCaptureRequest capture = {}) noexcept;

    IOSFrameInput(const IOSFrameInput&) = delete;
    IOSFrameInput& operator=(const IOSFrameInput&) = delete;
    IOSFrameInput(IOSFrameInput&&) noexcept = default;
    IOSFrameInput& operator=(IOSFrameInput&&) noexcept = default;

    const IOSSceneSnapshotPtr& sceneSnapshot() const noexcept {
      return snapshot;
      }

    IOSCaptureRequest captureRequest() const noexcept {
      return capture;
      }

  private:
    IOSSceneSnapshotPtr snapshot;
    IOSUIPacket         ui;
    IOSVideoPacket      video;
    IOSCaptureRequest   capture;
    uint64_t            transportSerial = 0;

  friend class IOSMetalContext;
  friend class RendererIOS;
  };
