#include "rendererios.h"

#include <Tempest/Device>
#include <Tempest/Painter>

#include <stdexcept>
#include <type_traits>
#include <utility>

#include "iosmetalcontext.h"

using namespace Tempest;

namespace {

static_assert(!std::is_copy_constructible_v<RendererIOS::FrameTicket>);
static_assert(std::is_nothrow_move_constructible_v<RendererIOS::FrameTicket>);
static_assert(std::is_nothrow_move_assignable_v<RendererIOS::FrameTicket>);

}

struct RendererIOS::TicketControl final {
  explicit TicketControl(RendererIOS& owner):owner(&owner) {
    }

  RendererIOS* owner = nullptr;
  };

struct RendererIOS::Impl final {
  Impl(Device& device, SystemApi::Window* window)
    : context(device,window) {
    }

  IOSMetalContext context;
  };

RendererIOS::FrameTicket::FrameTicket(const std::shared_ptr<TicketControl>& control,
                                      uint8_t slot, uint64_t serial) noexcept
  : control(control), serial(serial), frameSlot(slot) {
  }

RendererIOS::FrameTicket::FrameTicket(FrameTicket&& other) noexcept
  : control(std::move(other.control)), serial(other.serial), frameSlot(other.frameSlot) {
  other.disarm();
  }

RendererIOS::FrameTicket& RendererIOS::FrameTicket::operator=(FrameTicket&& other) noexcept {
  if(this==&other)
    return *this;
  if(auto state=control.lock(); state!=nullptr && state->owner!=nullptr)
    state->owner->cancelFrame(serial);
  control   = std::move(other.control);
  serial    = other.serial;
  frameSlot = other.frameSlot;
  other.disarm();
  return *this;
  }

RendererIOS::FrameTicket::~FrameTicket() {
  if(auto state=control.lock(); state!=nullptr && state->owner!=nullptr)
    state->owner->cancelFrame(serial);
  }

void RendererIOS::FrameTicket::disarm() noexcept {
  control.reset();
  serial = 0;
  }

RendererIOS::RendererIOS(Device& device, SystemApi::Window* window)
  : ticketControl(std::make_shared<TicketControl>(*this)),
    impl(std::make_unique<Impl>(device,window)) {
  }

RendererIOS::~RendererIOS() {
  ticketControl->owner = nullptr;
  }

std::optional<RendererIOS::FrameTicket> RendererIOS::beginFrame() {
  auto frame = impl->context.beginFrame();
  if(!frame)
    return std::nullopt;
  return FrameTicket(ticketControl,frame->slot,frame->serial);
  }

void RendererIOS::prepareVideo(FrameTicket& frame, VideoWidget& video) {
  if(!impl->context.frameAdmissionActive())
    return;
  const auto control = frame.control.lock();
  if(control.get()!=ticketControl.get())
    throw std::logic_error("RendererIOS received an invalid frame ticket for video preparation");
  impl->context.prepareVideo({frame.frameSlot,frame.serial},video);
  }

RendererIOS::SubmitResult RendererIOS::submitFrame(FrameTicket&& frame, const FrameInput& input) {
  if(!impl->context.frameAdmissionActive()) {
    impl->context.cancelFrame(frame.serial);
    frame.disarm();
    return {};
    }
  const auto control = frame.control.lock();
  if(control.get()!=ticketControl.get())
    throw std::logic_error("RendererIOS received an invalid frame ticket");

  const IOSMetalContext::FrameLease lease = {frame.frameSlot,frame.serial};
  const IOSMetalContext::FrameInputView frameInput = {
    input.uiLayer,
    input.numberOverlay,
    input.inventory,
    input.videoActive,
    input.captureSavePreview,
    };
  const auto consumeFrame = [](void* ticket) noexcept {
    static_cast<FrameTicket*>(ticket)->disarm();
    };
  const auto result = impl->context.submitFrame(
    lease,frameInput,&frame,consumeFrame);
  return SubmitResult{result.savePreviewQueued};
  }

Size RendererIOS::drawableSize() const {
  return impl->context.drawableSize();
  }

bool RendererIOS::pollDeviceFailure() noexcept {
  return impl->context.pollDeviceFailure();
  }

std::string_view RendererIOS::failureReason() const noexcept {
  return impl->context.failureReason();
  }

void RendererIOS::resize() {
  impl->context.resize();
  }

bool RendererIOS::suspend() noexcept {
  return impl->context.suspend();
  }

bool RendererIOS::resume() noexcept {
  return impl->context.resume();
  }

bool RendererIOS::waitIdle() noexcept {
  return impl->context.waitIdle();
  }

void RendererIOS::shutdown() noexcept {
  impl->context.shutdown();
  }

void RendererIOS::prepareForOwnerRelease() noexcept {
  impl->context.prepareForOwnerRelease();
  }

void RendererIOS::onWorldChanged() {
  impl->context.onWorldChanged();
  }

bool RendererIOS::savePreviewReady() {
  return impl->context.savePreviewReady();
  }

bool RendererIOS::savePreviewIsPlaceholder() const noexcept {
  return impl->context.savePreviewIsPlaceholder();
  }

Pixmap RendererIOS::takeSavePreview() {
  return impl->context.takeSavePreview();
  }

Pixmap RendererIOS::screenshot() {
  return impl->context.screenshot();
  }

void RendererIOS::dbgDraw(Painter& painter) {
  impl->context.dbgDraw(painter);
  }

bool RendererIOS::ssaoBuffersAllocated() const noexcept {
  return impl->context.ssaoBuffersAllocated();
  }

void RendererIOS::cancelFrame(uint64_t serial) noexcept {
  if(impl)
    impl->context.cancelFrame(serial);
  }
