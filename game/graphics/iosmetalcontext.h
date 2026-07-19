#pragma once

#include <Tempest/Pixmap>
#include <Tempest/Size>
#include <Tempest/SystemApi>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string_view>

#include "iosframeinput.h"

namespace Tempest {
class Device;
class Painter;
class VectorImage;
}

class InventoryMenu;
class IOSSceneAssetRegistry;
class VideoWidget;

class IOSMetalContext final {
  public:
    struct FrameLease final {
      uint8_t  slot   = 0;
      uint64_t serial = 0;
      };

    struct SubmitResult final {
      bool savePreviewQueued = false;
      };

    using CompleteFrame = bool (*)(void*,bool) noexcept;

    IOSMetalContext(Tempest::Device& device, Tempest::SystemApi::Window* window);
    ~IOSMetalContext();

    IOSMetalContext(const IOSMetalContext&) = delete;
    IOSMetalContext& operator=(const IOSMetalContext&) = delete;

    std::optional<FrameLease> beginFrame();
    bool                      frameAdmissionActive() const noexcept;
    bool                      ownsActiveFrame(const FrameLease& frame) const noexcept;
    IOSUIPacket               prepareUi(const FrameLease& frame,
                                        const Tempest::VectorImage& uiLayer,
                                        const Tempest::VectorImage& numberOverlay,
                                        InventoryMenu& inventory,
                                        bool videoActive);
    IOSVideoPacket            prepareVideo(const FrameLease& frame,
                                           VideoWidget& video);
    SubmitResult              submitFrame(const FrameLease& frame,
                                          const IOSFrameInput& input,
                                          const IOSSceneAssetRegistry& assets,
                                          void* completion,
                                          CompleteFrame completeFrame);
    void                      cancelFrame(uint64_t serial) noexcept;

    Tempest::Size    drawableSize() const;
    bool             pollDeviceFailure() noexcept;
    std::string_view failureReason() const noexcept;
    void             resize();
    bool             suspend() noexcept;
    bool             resume() noexcept;
    bool             waitIdle() noexcept;
    void             shutdown() noexcept;
    void             prepareForOwnerRelease() noexcept;
    void             onWorldChanged();
    std::size_t      retainedSceneCount() const noexcept;

    bool             requiresGpuSavePreviewCapture() const noexcept;
    bool             savePreviewReady();
    bool             savePreviewIsPlaceholder() const noexcept;
    Tempest::Pixmap  takeSavePreview();
    Tempest::Pixmap  screenshot();

    void             dbgDraw(Tempest::Painter& painter);
    bool             ssaoBuffersAllocated() const noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
  };
