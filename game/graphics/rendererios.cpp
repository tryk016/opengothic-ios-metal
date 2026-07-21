#include "rendererios.h"

#include <Tempest/Device>
#include <Tempest/Log>
#include <Tempest/Painter>

#include <stdexcept>
#include <type_traits>
#include <utility>

#include "iosmetalcontext.h"
#include "iosrenderworld.h"
#include "iossceneassetregistry.h"
#include "iossceneextractor.h"

using namespace Tempest;

namespace {

static_assert(!std::is_copy_constructible_v<RendererIOS::FrameTicket>);
static_assert(std::is_nothrow_move_constructible_v<RendererIOS::FrameTicket>);
static_assert(std::is_nothrow_move_assignable_v<RendererIOS::FrameTicket>);
static_assert(!std::is_copy_constructible_v<IOSFrameInput>);
static_assert(std::is_nothrow_move_constructible_v<IOSFrameInput>);

}

struct RendererIOS::TicketControl final {
  explicit TicketControl(RendererIOS& owner):owner(&owner) {
    }

  RendererIOS* owner = nullptr;
  };

struct RendererIOS::Impl final {
  Impl(Device& device, SystemApi::Window* window)
    : device(device),
      assets(device,renderWorld.generation()),
      context(device,window) {
    }

  Device&          device;
  IOSRenderWorld renderWorld;
  IOSSceneAssetRegistry assets;
  IOSSceneExtractor extractor;
  IOSMetalContext context;
  bool            worldOwnersDetached = false;
  uint64_t        preparedSceneSerial  = 0;
  IOSSceneSnapshotPtr preparedScene;

  bool matchesPreparedScene(uint64_t serial,
                            const IOSSceneSnapshotPtr& scene) const noexcept {
    return serial!=0 && preparedSceneSerial==serial &&
           preparedScene!=nullptr && preparedScene.get()==scene.get() &&
           !preparedScene.owner_before(scene) &&
           !scene.owner_before(preparedScene);
    }

  void clearPreparedScene(uint64_t serial = 0) noexcept {
    if(serial!=0 && preparedSceneSerial!=serial)
      return;
    preparedScene.reset();
    preparedSceneSerial = 0;
    }
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  try {
    Log::i("RendererIOS scene boundary: input=IOSFrameInput world=IOSRenderWorld snapshot=IOSSceneSnapshot");
    }
  catch(...) {
    }
#endif
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

IOSSceneSnapshotPtr RendererIOS::buildSceneSnapshot(FrameTicket& frame,
                                                    const IOSSceneSourceProvider& source,
                                                    IOSSceneFrameState&& scene) {
  if(!impl->context.frameAdmissionActive())
    throw std::logic_error("RendererIOS cannot build a scene snapshot while frame admission is closed");
  const auto control = frame.control.lock();
  const IOSMetalContext::FrameLease lease = {frame.frameSlot,frame.serial};
  if(control.get()!=ticketControl.get() ||
     !impl->context.ownsActiveFrame(lease))
    throw std::logic_error("RendererIOS received an invalid frame ticket for scene preparation");
  if(impl->preparedSceneSerial!=0)
    throw std::logic_error("RendererIOS scene snapshot was already prepared for this frame");
  if(bool(source) && impl->worldOwnersDetached)
    throw std::logic_error(
      "RendererIOS cannot extract an attached world while its owners are detached");

  if(bool(source)) {
    const auto extraction = impl->extractor.extractLandscape(
      source,impl->device,impl->renderWorld,impl->assets,scene);
    if(extraction.result!=IOSSceneExtractionResult::Success)
      throw std::runtime_error("RendererIOS Landscape scene extraction failed");
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    const auto nextSequence =
        impl->renderWorld.lastAcceptedSequence().value+1u;
    if(nextSequence==1u || nextSequence%300u==0u) {
      try {
        Log::d("RendererIOS Landscape extraction: visited=",
               uint64_t(extraction.stats.visited),
               " planned=",uint64_t(extraction.stats.planned),
               " skipped-kind=",uint64_t(extraction.stats.skippedKind),
               " skipped-material=",
               uint64_t(extraction.stats.skippedMaterial),
               " skipped-texture-animation=",
               uint64_t(extraction.stats.skippedTextureAnimation),
               " fallback-texture=",
               uint64_t(extraction.stats.fallbackTexture),
               " invalid=",uint64_t(extraction.stats.invalidSource));
        }
      catch(...) {
        }
      }
#endif
    }

  auto snapshot = impl->renderWorld.buildSnapshot(std::move(scene));
  impl->preparedScene       = snapshot;
  impl->preparedSceneSerial = frame.serial;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  if(impl->renderWorld.lastAcceptedSequence().value==0u ||
     snapshot->sequence.value%300u==0u) {
    try {
      Log::d("RendererIOS scene snapshot: generation=",snapshot->generation.value,
             " sequence=",snapshot->sequence.value,
             " slot=",uint32_t(frame.frameSlot),
             " entities=",uint64_t(snapshot->entities.size()),
             " lights=",uint64_t(snapshot->lights.size()),
             " history-valid=",snapshot->historyValid ? 1 : 0);
      }
    catch(...) {
      }
    }
#endif
  return snapshot;
  }

IOSUIPacket RendererIOS::prepareUi(FrameTicket& frame,
                                   const VectorImage& uiLayer,
                                   const VectorImage& numberOverlay,
                                   InventoryMenu& inventory,
                                   bool videoActive) {
  if(!impl->context.frameAdmissionActive())
    return {};
  const auto control = frame.control.lock();
  if(control.get()!=ticketControl.get())
    throw std::logic_error("RendererIOS received an invalid frame ticket for UI preparation");
  return impl->context.prepareUi({frame.frameSlot,frame.serial},
                                 uiLayer,numberOverlay,inventory,videoActive);
  }

IOSVideoPacket RendererIOS::prepareVideo(FrameTicket& frame, VideoWidget& video) {
  if(!impl->context.frameAdmissionActive())
    return {};
  const auto control = frame.control.lock();
  if(control.get()!=ticketControl.get())
    throw std::logic_error("RendererIOS received an invalid frame ticket for video preparation");
  return impl->context.prepareVideo({frame.frameSlot,frame.serial},video);
  }

RendererIOS::SubmitResult RendererIOS::submitFrame(FrameTicket&& frame,
                                                   IOSFrameInput input) {
  if(!impl->context.frameAdmissionActive()) {
    impl->context.cancelFrame(frame.serial);
    impl->clearPreparedScene(frame.serial);
    frame.disarm();
    return {};
    }
  const auto control = frame.control.lock();
  if(control.get()!=ticketControl.get())
    throw std::logic_error("RendererIOS received an invalid frame ticket");
  if(!impl->matchesPreparedScene(frame.serial,input.sceneSnapshot()) ||
     !impl->renderWorld.acceptsForSubmit(input.sceneSnapshot())) {
    impl->context.cancelFrame(frame.serial);
    impl->clearPreparedScene(frame.serial);
    frame.disarm();
    throw std::logic_error("RendererIOS received a stale or foreign scene snapshot");
    }
  input.transportSerial = frame.serial;

  struct FrameCompletion final {
    FrameTicket*               ticket = nullptr;
    Impl*                      renderer = nullptr;
    IOSRenderWorld*            world  = nullptr;
    const IOSSceneSnapshotPtr* scene  = nullptr;
    uint64_t                   serial = 0;
    };

  const IOSMetalContext::FrameLease lease = {frame.frameSlot,frame.serial};
  FrameCompletion completion = {
    &frame,
    impl.get(),
    &impl->renderWorld,
    &input.sceneSnapshot(),
    frame.serial,
    };
  const auto completeFrame = [](void* opaque, bool submitted) noexcept -> bool {
    auto& state = *static_cast<FrameCompletion*>(opaque);
    const bool accepted = !submitted || state.world->commitAccepted(*state.scene);
    state.renderer->clearPreparedScene(state.serial);
    state.ticket->disarm();
    return accepted;
    };
  const auto result = impl->context.submitFrame(
    lease,input,impl->assets,&completion,completeFrame);
  return SubmitResult{result.savePreviewQueued};
  }

Size RendererIOS::drawableSize() const {
  return impl->context.drawableSize();
  }

IOSWorldGeneration RendererIOS::sceneGeneration() const noexcept {
  return impl->renderWorld.generation();
  }

bool RendererIOS::pollDeviceFailure() noexcept {
  return impl->context.pollDeviceFailure();
  }

std::string_view RendererIOS::failureReason() const noexcept {
  return impl->context.failureReason();
  }

void RendererIOS::resize() {
  try {
    impl->context.resize();
    }
  catch(...) {
    impl->clearPreparedScene();
    impl->renderWorld.resetHistory();
    throw;
    }
  impl->clearPreparedScene();
  impl->renderWorld.resetHistory();
  }

bool RendererIOS::suspend() noexcept {
  const bool suspended = impl->context.suspend();
  impl->clearPreparedScene();
  impl->renderWorld.resetHistory();
  return suspended;
  }

bool RendererIOS::resume() noexcept {
  const bool resumed = impl->context.resume();
  impl->clearPreparedScene();
  if(resumed)
    impl->renderWorld.resetHistory();
  return resumed;
  }

bool RendererIOS::waitIdle() noexcept {
  const bool idle = impl->context.waitIdle();
  impl->clearPreparedScene();
  impl->renderWorld.resetHistory();
  return idle;
  }

void RendererIOS::shutdown() noexcept {
  impl->context.shutdown();
  impl->clearPreparedScene();
  impl->assets.clearAfterConfirmedIdle();
  impl->worldOwnersDetached = true;
  }

void RendererIOS::prepareForOwnerRelease() noexcept {
  impl->context.prepareForOwnerRelease();
  impl->clearPreparedScene();
  if(impl->worldOwnersDetached)
    return;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  const auto oldGeneration = impl->renderWorld.generation();
#endif
  impl->assets.clearAfterConfirmedIdle();
  impl->renderWorld.resetWorld();
  impl->worldOwnersDetached = true;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  try {
    Log::i("RendererIOS scene world detach: old-generation=",oldGeneration.value,
           " detached-generation=",impl->renderWorld.generation().value,
           " retained-after=",uint64_t(impl->context.retainedSceneCount()),
           " idle-confirmed=1");
    }
  catch(...) {
    }
#endif
  }

bool RendererIOS::restoreAfterOwnerRelease() noexcept {
  if(!impl->worldOwnersDetached)
    return true;
  if(!impl->context.frameAdmissionActive() ||
     !impl->context.failureReason().empty())
    return false;
  if(!impl->assets.resetGeneration(impl->device,
                                   impl->renderWorld.generation()))
    return false;
  impl->worldOwnersDetached = false;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  try {
    Log::i("RendererIOS scene world rollback: generation=",
           impl->renderWorld.generation().value,
           " retained-after=",uint64_t(impl->context.retainedSceneCount()),
           " idle-confirmed=1");
    }
  catch(...) {
    }
#endif
  return true;
  }

void RendererIOS::onWorldChanged() {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  const auto oldGeneration = impl->renderWorld.generation();
#endif
  impl->context.onWorldChanged();
  impl->clearPreparedScene();
  impl->assets.clearAfterConfirmedIdle();
  impl->renderWorld.resetWorld();
  impl->worldOwnersDetached = true;
  if(!impl->context.failureReason().empty())
    return;
  if(!impl->assets.resetGeneration(impl->device,
                                   impl->renderWorld.generation()))
    throw std::runtime_error(
      "RendererIOS could not reset native scene assets for the new world");
  impl->worldOwnersDetached = false;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  try {
    Log::i("RendererIOS scene world gate: old-generation=",oldGeneration.value,
           " new-generation=",impl->renderWorld.generation().value,
           " retained-after=",uint64_t(impl->context.retainedSceneCount()),
           " idle-confirmed=1");
    }
  catch(...) {
    }
#endif
  }

bool RendererIOS::requiresGpuSavePreviewCapture() const noexcept {
  return impl->context.requiresGpuSavePreviewCapture();
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

#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
IOSFunctionalEvidenceSnapshot
RendererIOS::functionalEvidenceSnapshot() const noexcept {
  return impl->context.functionalEvidenceSnapshot();
  }
#endif

void RendererIOS::cancelFrame(uint64_t serial) noexcept {
  if(impl) {
    impl->context.cancelFrame(serial);
    impl->clearPreparedScene(serial);
    }
  }
