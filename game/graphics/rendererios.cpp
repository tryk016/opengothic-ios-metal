#include "rendererios.h"

#include <Tempest/Device>
#include <Tempest/Log>
#include <Tempest/Painter>

#include <stdexcept>
#include <type_traits>
#include <utility>
#include <vector>

#include "iosmetalcontext.h"
#include "iosgpusceneplan.h"
#include "iosrenderworld.h"
#include "iossceneassetregistry.h"
#include "iossceneextractor.h"
#include "iosuvanimationdiagnostics.h"

#if !defined(OPENGOTHIC_RENDERER_IOS_BUILD_SHA)
#define OPENGOTHIC_RENDERER_IOS_BUILD_SHA "local"
#endif

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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  uint64_t preparedFrameAnimationSerial = 0;
  IOSFrameAnimationEvidence preparedFrameAnimation;
  IOSFrameAnimationDiagnosticState frameAnimationDiagnostics;
  uint64_t preparedUVAnimationSerial = 0;
  IOSUVAnimationEvidence preparedUVAnimation;
  IOSUVAnimationDiagnosticState uvAnimationDiagnostics;
#endif

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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    preparedFrameAnimation = {};
    preparedFrameAnimationSerial = 0;
    preparedUVAnimation = {};
    preparedUVAnimationSerial = 0;
#endif
    }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  void acceptFrameAnimationGeneration(uint64_t generation) noexcept {
    if(frameAnimationDiagnostics.generation==generation)
      return;
    frameAnimationDiagnostics = {};
    frameAnimationDiagnostics.generation = generation;
    }

  void resetFrameAnimationDiagnostics() noexcept {
    frameAnimationDiagnostics = {};
    }

  void acceptUVAnimationGeneration(uint64_t generation) noexcept {
    if(uvAnimationDiagnostics.generation==generation)
      return;
    uvAnimationDiagnostics = {};
    uvAnimationDiagnostics.generation = generation;
    }

  void resetUVAnimationDiagnostics() noexcept {
    uvAnimationDiagnostics = {};
    }

  void commitFrameAnimationDiagnostics(
      const IOSFrameAnimationDiagnosticCandidate& candidate,
      const IOSGPUSceneFrameAnimationDrawReport* drawn,
      uint64_t serial,
      uint64_t generation,
      uint64_t sequence) noexcept {
    if(serial==0u || preparedFrameAnimationSerial!=serial ||
       candidate.generation!=generation ||
       candidate.sequence!=sequence ||
       drawn==nullptr ||
       !iosFrameAnimationDiagnosticCandidateAcceptsDrawn(
           frameAnimationDiagnostics,candidate,
           preparedFrameAnimation,*drawn))
      return;
    const IOSGPUSceneMarker primary = iosFrameAnimationMarker(
        candidate,preparedFrameAnimation,
        OPENGOTHIC_RENDERER_IOS_BUILD_SHA);
    const IOSGPUSceneMarker detail =
        iosFrameAnimationDetailMarker(candidate,*drawn);
    if(!primary || !detail || primary.length>254u || detail.length>254u)
      return;
    try {
      Log::i(primary.text.data());
      Log::i(detail.text.data());
      }
    catch(...) {
      return;
      }

    (void)commitIOSFrameAnimationDiagnosticState(
        true,candidate,std::move(preparedFrameAnimation),
        *drawn,frameAnimationDiagnostics);
    }

  void commitUVAnimationDiagnostics(
      const IOSUVAnimationDiagnosticCandidate& candidate,
      const IOSGPUSceneUVAnimationDrawReport* drawn,
      uint64_t serial,
      uint64_t generation,
      uint64_t sequence) noexcept {
    if(serial==0u || preparedUVAnimationSerial!=serial ||
       candidate.generation!=generation ||
       candidate.sequence!=sequence || drawn==nullptr ||
       !iosUVAnimationDiagnosticCandidateAcceptsDrawn(
           uvAnimationDiagnostics,candidate,
           preparedUVAnimation,*drawn))
      return;

    try {
      const IOSGPUSceneMarker primary = iosUVAnimationMarker(
          candidate,preparedUVAnimation,*drawn,
          OPENGOTHIC_RENDERER_IOS_BUILD_SHA);
      const IOSGPUSceneMarker detail = iosUVAnimationDetailMarker(
          candidate,preparedUVAnimation,*drawn);
      if(!primary || !detail || primary.length>254u || detail.length>254u)
        return;

      std::vector<IOSGPUSceneMarker> sources;
      sources.reserve(preparedUVAnimation.selections.size());
      for(std::size_t index=0;
          index<preparedUVAnimation.selections.size();
          ++index) {
        IOSGPUSceneMarker marker = iosUVAnimationSourceMarker(
            candidate,preparedUVAnimation,*drawn,index);
        if(!marker || marker.length>254u)
          return;
        sources.emplace_back(std::move(marker));
        }

      Log::i(primary.text.data());
      Log::i(detail.text.data());
      for(const auto& marker:sources)
        Log::i(marker.text.data());
      }
    catch(...) {
      return;
      }

    (void)commitIOSUVAnimationDiagnosticState(
        true,candidate,std::move(preparedUVAnimation),
        *drawn,uvAnimationDiagnostics);
    }
#endif
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

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  IOSFrameAnimationEvidence frameAnimation;
  IOSUVAnimationEvidence uvAnimation;
#endif

  if(bool(source)) {
    auto extraction = impl->extractor.extractOpaqueMeshes(
      source,impl->device,impl->renderWorld,impl->assets,scene);
    if(extraction.result!=IOSSceneExtractionResult::Success)
      throw std::runtime_error(
        "RendererIOS opaque mesh scene extraction failed");
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    const auto nextSequence =
        impl->renderWorld.lastAcceptedSequence().value+1u;
    if(nextSequence==1u || nextSequence%300u==0u) {
      try {
        Log::d("RendererIOS source census: v=2 b=",
               OPENGOTHIC_RENDERER_IOS_BUILD_SHA,
               " g=",impl->renderWorld.generation().value,
               " s=",nextSequence,
               " k=",uint64_t(extraction.stats.census.kinds.landscape),",",
               uint64_t(extraction.stats.census.kinds.staticMesh),",",
               uint64_t(extraction.stats.census.kinds.movable),",",
               uint64_t(extraction.stats.census.kinds.animated),",",
               uint64_t(extraction.stats.census.kinds.particle),",",
               uint64_t(extraction.stats.census.kinds.morph),",",
               uint64_t(extraction.stats.census.kinds.unsupported),",",
               uint64_t(extraction.stats.census.kinds.unknown),
               " m=",uint64_t(extraction.stats.census.materials.solid),",",
               uint64_t(extraction.stats.census.materials.alphaTest),",",
               uint64_t(extraction.stats.census.materials.water),",",
               uint64_t(extraction.stats.census.materials.ghost),",",
               uint64_t(extraction.stats.census.materials.multiply),",",
               uint64_t(extraction.stats.census.materials.multiply2),",",
               uint64_t(extraction.stats.census.materials.transparent),",",
               uint64_t(extraction.stats.census.materials.additiveLight),",",
               uint64_t(extraction.stats.census.materials.missing),",",
               uint64_t(extraction.stats.census.materials.unknown),
               " a=",uint64_t(extraction.stats.census.frameAnimated),",",
               uint64_t(extraction.stats.census.uvAnimated),
               " x=",uint64_t(extraction.stats.skippedTextureFrameOnly),",",
               uint64_t(extraction.stats.skippedTextureUvOnly),",",
               uint64_t(extraction.stats.skippedTextureFrameAndUv),
               " o=",uint64_t(extraction.stats.visited),",",
               uint64_t(extraction.stats.planned),",",
               uint64_t(extraction.stats.skippedKind),",",
               uint64_t(extraction.stats.skippedMaterial),",",
               uint64_t(extraction.stats.skippedTextureAnimation),",",
               uint64_t(extraction.stats.invalidSource));
        Log::d("RendererIOS opaque mesh extraction: visited=",
               uint64_t(extraction.stats.visited),
               " planned=",uint64_t(extraction.stats.planned),
               " planned-landscape=",
               uint64_t(extraction.stats.plannedLandscape),
               " planned-static=",
               uint64_t(extraction.stats.plannedStatic),
               " planned-movable=",
               uint64_t(extraction.stats.plannedMovable),
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    frameAnimation = std::move(extraction.frameAnimation);
    uvAnimation = std::move(extraction.uvAnimation);
#endif
    }

  auto snapshot = impl->renderWorld.buildSnapshot(std::move(scene));
  impl->preparedScene       = snapshot;
  impl->preparedSceneSerial = frame.serial;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  impl->preparedFrameAnimation = std::move(frameAnimation);
  impl->preparedFrameAnimationSerial = frame.serial;
  impl->preparedUVAnimation = std::move(uvAnimation);
  impl->preparedUVAnimationSerial = frame.serial;
#endif
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

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  const auto frameAnimationCandidate =
      prepareIOSFrameAnimationDiagnosticCandidate(
          impl->frameAnimationDiagnostics,
          input.snapshot->generation.value,
          input.snapshot->sequence.value,
          impl->preparedFrameAnimation);
  const IOSFrameAnimationEvidence* const frameAnimation =
      frameAnimationCandidate.valid
        ? &impl->preparedFrameAnimation
        : nullptr;
  const auto uvAnimationCandidate =
      prepareIOSUVAnimationDiagnosticCandidate(
          impl->uvAnimationDiagnostics,
          input.snapshot->generation.value,
          input.snapshot->sequence.value,
          impl->preparedUVAnimation);
  const IOSUVAnimationEvidence* const uvAnimation =
      uvAnimationCandidate.valid
        ? &impl->preparedUVAnimation
        : nullptr;
  const bool forceNativeSceneMarkers =
      frameAnimationCandidate.valid || uvAnimationCandidate.valid;
#else
  const IOSFrameAnimationEvidence* const frameAnimation = nullptr;
  const IOSUVAnimationEvidence* const uvAnimation = nullptr;
  const bool forceNativeSceneMarkers = false;
#endif

  struct FrameCompletion final {
    FrameTicket*               ticket = nullptr;
    Impl*                      renderer = nullptr;
    IOSRenderWorld*            world  = nullptr;
    const IOSSceneSnapshotPtr* scene  = nullptr;
    uint64_t                   serial = 0;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    IOSFrameAnimationDiagnosticCandidate frameAnimationCandidate;
    IOSUVAnimationDiagnosticCandidate uvAnimationCandidate;
#endif
    };

  const IOSMetalContext::FrameLease lease = {frame.frameSlot,frame.serial};
  FrameCompletion completion = {
    &frame,
    impl.get(),
    &impl->renderWorld,
    &input.sceneSnapshot(),
    frame.serial,
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    frameAnimationCandidate,
    uvAnimationCandidate,
#endif
    };
  const auto completeFrame = [](
      void* opaque,
      bool submitted,
      const IOSGPUSceneFrameAnimationDrawReport* frameAnimationDrawn,
      const IOSGPUSceneUVAnimationDrawReport* uvAnimationDrawn)
      noexcept -> bool {
    auto& state = *static_cast<FrameCompletion*>(opaque);
    const bool accepted = !submitted || state.world->commitAccepted(*state.scene);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    if(submitted && accepted) {
      state.renderer->acceptFrameAnimationGeneration(
          (*state.scene)->generation.value);
      state.renderer->commitFrameAnimationDiagnostics(
          state.frameAnimationCandidate,frameAnimationDrawn,
          state.serial,(*state.scene)->generation.value,
          (*state.scene)->sequence.value);
      state.renderer->acceptUVAnimationGeneration(
          (*state.scene)->generation.value);
      state.renderer->commitUVAnimationDiagnostics(
          state.uvAnimationCandidate,uvAnimationDrawn,
          state.serial,(*state.scene)->generation.value,
          (*state.scene)->sequence.value);
      }
#else
    (void)frameAnimationDrawn;
    (void)uvAnimationDrawn;
#endif
    state.renderer->clearPreparedScene(state.serial);
    state.ticket->disarm();
    return accepted;
    };
  const auto result = impl->context.submitFrame(
    lease,input,impl->assets,
    frameAnimation,uvAnimation,forceNativeSceneMarkers,
    &completion,completeFrame);
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  impl->resetFrameAnimationDiagnostics();
  impl->resetUVAnimationDiagnostics();
#endif
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  impl->resetFrameAnimationDiagnostics();
  impl->resetUVAnimationDiagnostics();
#endif
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
