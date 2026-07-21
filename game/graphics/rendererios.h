#pragma once

#include <Tempest/Size>
#include <Tempest/SystemApi>
#include <Tempest/Pixmap>

#include <cstdint>
#include <memory>
#include <optional>
#include <string_view>

#include "iosframeinput.h"
#include "iosfunctionalevidence.h"

namespace Tempest {
class Device;
class Painter;
class VectorImage;
}

class InventoryMenu;
class VideoWidget;
struct IOSSceneSourceProvider;

class RendererIOS final {
  private:
    struct TicketControl;

  public:
    class FrameTicket final {
      public:
        FrameTicket(const FrameTicket&) = delete;
        FrameTicket& operator=(const FrameTicket&) = delete;

        FrameTicket(FrameTicket&& other) noexcept;
        FrameTicket& operator=(FrameTicket&& other) noexcept;
        ~FrameTicket();

      private:
        FrameTicket(const std::shared_ptr<TicketControl>& control,
                    uint8_t slot, uint64_t serial) noexcept;
        void disarm() noexcept;

        std::weak_ptr<TicketControl> control;
        uint64_t                     serial    = 0;
        uint8_t                      frameSlot = 0;

      friend class RendererIOS;
      };

    struct SubmitResult final {
      bool savePreviewQueued = false;
      };

    RendererIOS(Tempest::Device& device, Tempest::SystemApi::Window* window);
    ~RendererIOS();

    RendererIOS(const RendererIOS&) = delete;
    RendererIOS& operator=(const RendererIOS&) = delete;

    std::optional<FrameTicket> beginFrame();
    IOSSceneSnapshotPtr buildSceneSnapshot(FrameTicket& frame,
                                           const IOSSceneSourceProvider& source,
                                           IOSSceneFrameState&& scene);
    IOSUIPacket         prepareUi(FrameTicket& frame,
                                  const Tempest::VectorImage& uiLayer,
                                  const Tempest::VectorImage& numberOverlay,
                                  InventoryMenu& inventory,
                                  bool videoActive);
    IOSVideoPacket      prepareVideo(FrameTicket& frame, VideoWidget& video);
    SubmitResult        submitFrame(FrameTicket&& frame, IOSFrameInput input);

    Tempest::Size   drawableSize() const;
    IOSWorldGeneration sceneGeneration() const noexcept;
    bool            pollDeviceFailure() noexcept;
    std::string_view failureReason() const noexcept;
    void            resize();
    bool            suspend() noexcept;
    bool            resume() noexcept;
    bool            waitIdle() noexcept;
    void            shutdown() noexcept;
    void            prepareForOwnerRelease() noexcept;
    bool            restoreAfterOwnerRelease() noexcept;
    void            onWorldChanged();

    bool            requiresGpuSavePreviewCapture() const noexcept;
    bool            savePreviewReady();
    bool            savePreviewIsPlaceholder() const noexcept;
    Tempest::Pixmap takeSavePreview();
    Tempest::Pixmap screenshot();

    void dbgDraw(Tempest::Painter& painter);
    bool ssaoBuffersAllocated() const noexcept;
#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    IOSFunctionalEvidenceSnapshot functionalEvidenceSnapshot() const noexcept;
#endif

  private:
    struct Impl;

    void cancelFrame(uint64_t serial) noexcept;

    std::shared_ptr<TicketControl> ticketControl;
    std::unique_ptr<Impl>          impl;
  };
