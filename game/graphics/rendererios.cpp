#include "rendererios.h"

#include <Tempest/Attachment>
#include <Tempest/CommandBuffer>
#include <Tempest/Device>
#include <Tempest/Except>
#include <Tempest/Fence>
#include <Tempest/Log>
#include <Tempest/Painter>
#include <Tempest/Pixmap>
#include <Tempest/Swapchain>
#include <Tempest/VectorImage>
#include <Tempest/ZBuffer>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <type_traits>
#include <utility>

#include "resources.h"
#include "rendereriosplatform.h"
#include "shaders.h"
#include "ui/inventorymenu.h"
#include "ui/videowidget.h"

using namespace Tempest;

#if !defined(OPENGOTHIC_RENDERER_IOS_BUILD_SHA)
#define OPENGOTHIC_RENDERER_IOS_BUILD_SHA "local"
#endif

#if !defined(OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID)
#define OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID 0
#endif

#if !defined(OPENGOTHIC_RENDERER_IOS_FAULT_MODE_NAME)
#define OPENGOTHIC_RENDERER_IOS_FAULT_MODE_NAME "none"
#endif

#if OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID < 0 || OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID > 8
#error "Unsupported RendererIOS fault mode id"
#endif

#if OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 0 && !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "RendererIOS fault injection requires diagnostics"
#endif

namespace {

enum class SettleReason : uint8_t {
  Resize,
  Suspend,
  Resume,
  ExternalWait,
  OwnerRelease,
  Shutdown,
  FinalDestruction,
  };

enum class RendererIOSFaultMode : uint8_t {
  None                           = 0,
  PreviewAttachmentMissing       = 1,
  PreviewReadbackError           = 2,
  PreviewFenceErrorAfterTerminal = 3,
  FrameFenceErrorAfterTerminal   = 4,
  PostSubmitSuboptimal           = 5,
  ShutdownIdleUnconfirmedOnce    = 6,
  AsyncPresentErrorAfterTerminal = 7,
  LoaderThreadStartFailureOnce   = 8,
  };

const char* presentFailureName(PresentFailureKind kind) noexcept {
  switch(kind) {
    case PresentFailureKind::None:             return "none";
    case PresentFailureKind::DeviceLost:       return "device-lost";
    case PresentFailureKind::Timeout:          return "timeout";
    case PresentFailureKind::OutOfMemory:      return "out-of-memory";
    case PresentFailureKind::InvalidResource:  return "invalid-resource";
    case PresentFailureKind::Internal:         return "internal";
    case PresentFailureKind::UnexpectedStatus: return "unexpected-status";
    case PresentFailureKind::Unknown:          return "unknown";
    }
  return "unknown";
  }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
constexpr auto ConfiguredFaultMode =
  static_cast<RendererIOSFaultMode>(OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID);
#endif

struct FaultInjection final {
  const char* name() const noexcept {
    return OPENGOTHIC_RENDERER_IOS_FAULT_MODE_NAME;
    }

  bool previewAttachmentMissing() noexcept {
    return consume(RendererIOSFaultMode::PreviewAttachmentMissing,
                   "preview-attachment-missing");
    }

  bool previewReadbackError() noexcept {
    return consume(RendererIOSFaultMode::PreviewReadbackError,
                   "preview-readback-after-terminal-fence");
    }

  bool previewFenceErrorAfterTerminal() noexcept {
    return consume(RendererIOSFaultMode::PreviewFenceErrorAfterTerminal,
                   "preview-fence-after-terminal");
    }

  bool frameFenceErrorAfterTerminal() noexcept {
    return consume(RendererIOSFaultMode::FrameFenceErrorAfterTerminal,
                   "frame-fence-after-terminal");
    }

  bool postSubmitSuboptimal() noexcept {
    return consume(RendererIOSFaultMode::PostSubmitSuboptimal,
                   "post-submit-pre-present");
    }

  bool shutdownIdleUnconfirmedOnce(SettleReason reason,
                                   uint64_t presentedFrames) noexcept {
    if(reason!=SettleReason::Shutdown || presentedFrames==0u)
      return false;
    return consume(RendererIOSFaultMode::ShutdownIdleUnconfirmedOnce,
                   "shutdown-before-device-idle");
    }

  void observeAsyncPresentError(int64_t nativeCode) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    if(nativeCode==-1)
      (void)consume(RendererIOSFaultMode::AsyncPresentErrorAfterTerminal,
                    "tempest-present-completion");
#else
    (void)nativeCode;
#endif
    }

  private:
    bool consume(RendererIOSFaultMode expected, const char* point) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      if(ConfiguredFaultMode!=expected || fired)
        return false;
      fired = true;
      try {
        Log::e("RendererIOS fault injection fired: mode=",name(),
               " point=",point," build=",OPENGOTHIC_RENDERER_IOS_BUILD_SHA);
        }
      catch(...) {
        }
      return true;
#else
      (void)expected;
      (void)point;
      return false;
#endif
      }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    bool fired = false;
#endif
  };

const Vec4 OpaqueBlack(0.f,0.f,0.f,1.f);

static_assert(!std::is_copy_constructible_v<RendererIOS::FrameTicket>);
static_assert(std::is_nothrow_move_constructible_v<RendererIOS::FrameTicket>);
static_assert(std::is_nothrow_move_assignable_v<RendererIOS::FrameTicket>);
static_assert(std::is_nothrow_move_assignable_v<Fence>);
static_assert(!std::is_copy_constructible_v<VideoWidget::PreparedFrame>);
static_assert(std::is_nothrow_move_assignable_v<VideoWidget::PreparedFrame>);

Pixmap blackPixmap(uint32_t w, uint32_t h) {
  w = std::max(w,1u);
  h = std::max(h,1u);
  Pixmap image(w,h,TextureFormat::RGBA8);
  auto* pixels = static_cast<uint8_t*>(image.data());
  const size_t count = size_t(w)*size_t(h);
  for(size_t i=0; i<count; ++i)
    pixels[i*4u+3u] = 255u;
  return image;
  }

}

struct RendererIOS::TicketControl final {
  explicit TicketControl(RendererIOS& owner):owner(&owner) {
    }

  RendererIOS* owner = nullptr;
  };

struct RendererIOS::Impl final {
  enum class PreviewState : uint8_t {
    Idle,
    AwaitingGpu,
    ReadyCpu,
    ReadyPlaceholder,
    };

  enum class LifecycleState : uint8_t {
    Active,
    Suspended,
    Fatal,
    Stopped,
    };

  struct SubmissionCounters final {
    uint64_t submitAttempts  = 0;
    uint64_t submitAccepted  = 0;
    uint64_t presentAttempts = 0;
    uint64_t presentAccepted = 0;
    };

  Impl(Device& device, SystemApi::Window* window)
    : device(device), swapchain(device,window) {
    (void)legacyShaders;
    static constexpr TextureFormat depthCandidates[] = {
      TextureFormat::Depth16,
      TextureFormat::Depth32F,
      TextureFormat::Depth24x8,
      };
    for(const auto format:depthCandidates) {
      if(device.properties().hasDepthFormat(format)) {
        depthFormat = format;
        depthSupported = true;
        break;
        }
      }

    for(auto& command:commands)
      command = device.commandBuffer();
    resetTargets();
    const auto platform = rendererIOSPlatformInfo();
    try {
      Log::i("RendererIOS shell: version=1 profile=Safe features=clear,ui,inventory,save-placeholder build=",
             OPENGOTHIC_RENDERER_IOS_BUILD_SHA," gpu=",device.properties().name,
             " deviceFamily=",platform.deviceFamily.data()," iOS=",platform.osVersion.data(),
             " faultMode=",fault.name());
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      Log::i("RendererIOS diagnostics: ON frames-in-flight=",Resources::MaxFramesInFlight,
             " bootstrap=Tempest");
      if(ConfiguredFaultMode!=RendererIOSFaultMode::None)
        Log::i("RendererIOS fault injection armed: mode=",fault.name(),
               " build=",OPENGOTHIC_RENDERER_IOS_BUILD_SHA);
#else
      Log::i("RendererIOS diagnostics: OFF");
#endif
      }
    catch(...) {
      }
    }

  ~Impl() noexcept {
    stopFrameAdmission(LifecycleState::Stopped);
    if(!confirmGpuIdle(SettleReason::FinalDestruction,
                       "RendererIOS GPU shutdown failed")) {
      logShutdownCountsOnce("idle-unconfirmed");
      terminateWithoutTeardown("RendererIOS final GPU shutdown could not confirm device idle");
      }
    if(!failed) {
      try {
        Log::i("RendererIOS shell: clean shutdown after ",
               counters.presentAccepted," present calls");
        }
      catch(...) {
        }
      }
    logShutdownCountsOnce(failed ? "fatal" : "clean");
    }

  [[noreturn]] void terminateWithoutTeardown(const char* operation) noexcept {
    try {
      Log::e(operation,
             "; terminating without C++ teardown so in-flight GPU owners remain alive");
      }
    catch(...) {
      }
    std::_Exit(EXIT_FAILURE);
    }

  void resetTargets() {
    overlayDepth = ZBuffer();
    const uint32_t w = swapchain.w();
    const uint32_t h = swapchain.h();
    if(depthSupported && w>0u && h>0u)
      overlayDepth = device.zbuffer(depthFormat,w,h);
    }

  void clearPreview() {
    if(!previewAttachmentRetained) {
      savePreview = Attachment();
      previewTargetAllocated = false;
      previewAttachmentRetained = false;
      }
    completedPreview = Pixmap();
    previewState     = PreviewState::Idle;
    previewFallback  = false;
    previewSlot      = 0;
    }

  void forcePreviewPlaceholder() noexcept {
    if(previewTargetAllocated)
      previewAttachmentRetained = true;
    if(previewState==PreviewState::AwaitingGpu) {
      previewFallback = false;
      previewState    = PreviewState::ReadyPlaceholder;
      }
    // A submit/present failure can also happen after allocating the target but
    // before SubmitResult exposes the request. Keeping savePreview alive covers
    // that CaptureRequested path without a potentially throwing move.
    }

  void materializePreview() {
    if(previewState!=PreviewState::AwaitingGpu)
      return;
    if(previewFallback) {
      savePreview               = Attachment();
      previewTargetAllocated    = false;
      previewFallback           = false;
      previewAttachmentRetained = false;
      previewState              = PreviewState::ReadyPlaceholder;
      return;
    }
    try {
      if(fault.previewReadbackError())
        throw std::runtime_error("RendererIOS diagnostics injected a recoverable save-preview readback error");
      completedPreview          = device.readPixels(savePreview);
      savePreview               = Attachment();
      previewTargetAllocated    = false;
      previewAttachmentRetained = false;
      previewState              = PreviewState::ReadyCpu;
      }
    catch(const DeviceLostException& e) {
      forcePreviewPlaceholder();
      fail("RendererIOS Metal save-preview readback failed",e.what());
      }
    catch(const std::exception& e) {
      savePreview               = Attachment();
      previewTargetAllocated    = false;
      previewAttachmentRetained = false;
      previewState              = PreviewState::ReadyPlaceholder;
      try {
        Log::e("RendererIOS save-preview readback failed; using placeholder: ",e.what());
        }
      catch(...) {
        }
      }
    catch(...) {
      forcePreviewPlaceholder();
      fail("RendererIOS Metal save-preview readback failed");
      }
    }

  void materializePreviewSafely(const char* operation) noexcept {
    try {
      materializePreview();
      }
    catch(const std::exception& e) {
      forcePreviewPlaceholder();
      fail(operation,e.what());
      }
    catch(...) {
      forcePreviewPlaceholder();
      fail(operation);
      }
    }

  static uint64_t counterDelta(uint64_t value, uint64_t snapshot) noexcept {
    return value>=snapshot ? value-snapshot : 0u;
    }

  void captureFatalCounters() noexcept {
    if(fatalCountersCaptured)
      return;
    fatalCounters         = counters;
    fatalCountersCaptured = true;
    }

  void logFatalSnapshot() noexcept {
    if(!fatalCountersCaptured)
      return;
    try {
      Log::e("RendererIOS fatal snapshot: submit-attempts=",fatalCounters.submitAttempts,
             " submit-accepted=",fatalCounters.submitAccepted,
             " present-attempts=",fatalCounters.presentAttempts,
             " present-accepted=",fatalCounters.presentAccepted);
      }
    catch(...) {
      }
    }

  void logFatalSettledOnce() noexcept {
    if(!failed || fatalSettledLogged || !fatalCountersCaptured)
      return;
    fatalSettledLogged = true;
    try {
      Log::e("RendererIOS fatal settled: idle-confirmed=1",
             " submit-attempts=",counters.submitAttempts,
             " submit-accepted=",counters.submitAccepted,
             " present-attempts=",counters.presentAttempts,
             " present-accepted=",counters.presentAccepted);
      Log::e("RendererIOS fatal post-delta: submit-attempts=",
             counterDelta(counters.submitAttempts,fatalCounters.submitAttempts),
             " submit-accepted=",counterDelta(counters.submitAccepted,fatalCounters.submitAccepted),
             " present-attempts=",counterDelta(counters.presentAttempts,fatalCounters.presentAttempts),
             " present-accepted=",counterDelta(counters.presentAccepted,fatalCounters.presentAccepted));
      }
    catch(...) {
      }
    }

  void logShutdownCountsOnce(const char* outcome) noexcept {
    if(shutdownCountsLogged)
      return;
    shutdownCountsLogged = true;
    try {
      Log::i("RendererIOS shutdown counters: outcome=",outcome,
             " submit-attempts=",counters.submitAttempts,
             " submit-accepted=",counters.submitAccepted,
             " present-attempts=",counters.presentAttempts,
             " present-accepted=",counters.presentAccepted);
      Log::i("RendererIOS shutdown post-fatal delta: submit-attempts=",
             fatalCountersCaptured ?
               counterDelta(counters.submitAttempts,fatalCounters.submitAttempts) : 0u,
             " submit-accepted=",fatalCountersCaptured ?
               counterDelta(counters.submitAccepted,fatalCounters.submitAccepted) : 0u,
             " present-attempts=",fatalCountersCaptured ?
               counterDelta(counters.presentAttempts,fatalCounters.presentAttempts) : 0u,
             " present-accepted=",fatalCountersCaptured ?
               counterDelta(counters.presentAccepted,fatalCounters.presentAccepted) : 0u);
      }
    catch(...) {
      }
    }

  void logLifecycleCounts(const char* transition, bool idleConfirmed) noexcept {
    try {
      Log::i("RendererIOS lifecycle counters: transition=",transition,
             " idle-confirmed=",idleConfirmed ? 1 : 0,
             " submit-attempts=",counters.submitAttempts,
             " submit-accepted=",counters.submitAccepted,
             " present-attempts=",counters.presentAttempts,
             " present-accepted=",counters.presentAccepted);
      }
    catch(...) {
      }
    }

  void fail(const char* operation, const char* detail = nullptr) noexcept {
    // Fatal means no further GPU work, including save-preview readback. Keep
    // an allocated attachment alive until confirmed idle, but publish only the
    // CPU placeholder to the save pipeline.
    forcePreviewPlaceholder();
    frameActive  = false;
    activeSerial = 0;
    lifecycleState = LifecycleState::Fatal;
    if(failed)
      return;

    captureFatalCounters();
    failed = true;
    if(detail!=nullptr && detail[0]!='\0')
      std::snprintf(fatalMessage.data(),fatalMessage.size(),"%s: %s",operation,detail);
    else
      std::snprintf(fatalMessage.data(),fatalMessage.size(),"%s",operation);
    try {
      Log::e(fatalMessage.data());
      }
    catch(...) {
      // Failure handling must remain noexcept even if diagnostics allocation
      // itself fails under memory pressure.
      }
    logFatalSnapshot();
    }

  void neutralizeFences() noexcept {
    // Tempest::Fence::~Fence() waits and can throw for a completed Metal error.
    // Move-assigning an empty wrapper releases it without invoking that wait.
    for(size_t i=0; i<fences.size(); ++i) {
      fences[i]        = Fence();
      slotSubmitted[i] = false;
      }
    }

  void releaseVideoFrame(uint8_t slot) noexcept {
    videoFrames[slot] = VideoWidget::PreparedFrame();
    }

  void releaseVideoFrames() noexcept {
    for(uint8_t slot=0; slot<uint8_t(videoFrames.size()); ++slot)
      releaseVideoFrame(slot);
    }

  void stopFrameAdmission(LifecycleState state) noexcept {
    lifecycleState = state;
    if(frameActive)
      releaseVideoFrame(nextSlot);
    frameActive  = false;
    activeSerial = 0;
    }

  void releaseRetainedPreviewAfterIdle() noexcept {
    if(!previewAttachmentRetained)
      return;
    savePreview               = Attachment();
    previewTargetAllocated    = false;
    previewAttachmentRetained = false;
    }

  bool pollPresentFailure(const char* operation) noexcept {
    const PresentFailure failure = device.takePresentFailure();
    if(!failure)
      return !failed;

    fault.observeAsyncPresentError(failure.nativeCode);
    forcePreviewPlaceholder();
    if(failed)
      return false;

    std::array<char,256> detail = {};
    std::snprintf(detail.data(),detail.size(),
                  "kind=%s status=%d native=%lld serial=%llu",
                  presentFailureName(failure.kind),failure.statusCode,
                  static_cast<long long>(failure.nativeCode),
                  static_cast<unsigned long long>(failure.serial));
    fail(operation,detail.data());
    return false;
    }

  bool settleGpu(SettleReason reason, const char* operation,
                 bool* idleConfirmed = nullptr) noexcept {
    if(idleConfirmed!=nullptr)
      *idleConfirmed = false;
    if(fault.shutdownIdleUnconfirmedOnce(reason,counters.presentAccepted)) {
      neutralizeFences();
      forcePreviewPlaceholder();
      fail(operation,"fault injection: device idle deliberately left unconfirmed once");
      return false;
      }
    try {
      device.waitIdle();
      }
    catch(const std::exception& e) {
      neutralizeFences();
      forcePreviewPlaceholder();
      fail(operation,e.what());
      return false;
      }
    catch(...) {
      neutralizeFences();
      forcePreviewPlaceholder();
      fail(operation);
      return false;
      }

    if(idleConfirmed!=nullptr)
      *idleConfirmed = true;

    const bool presentHealthy = pollPresentFailure(
      "RendererIOS asynchronous Metal present failed");
    releaseRetainedPreviewAfterIdle();

    // Metal Device::waitIdle() only waits for completion. Error propagation is
    // owned by Fence::wait(), so inspect every terminal fence before releasing
    // the wrappers or claiming a clean lifecycle transition.
    for(auto& fence:fences) {
      try {
        if(!fence.wait(0)) {
          neutralizeFences();
          releaseVideoFrames();
          forcePreviewPlaceholder();
          releaseRetainedPreviewAfterIdle();
          fail(operation,"frame fence was not terminal after device idle");
          logFatalSettledOnce();
          return false;
          }
        }
      catch(const std::exception& e) {
        neutralizeFences();
        releaseVideoFrames();
        forcePreviewPlaceholder();
        releaseRetainedPreviewAfterIdle();
        fail(operation,e.what());
        logFatalSettledOnce();
        return false;
        }
      catch(...) {
        neutralizeFences();
        releaseVideoFrames();
        forcePreviewPlaceholder();
        releaseRetainedPreviewAfterIdle();
        fail(operation);
        logFatalSettledOnce();
        return false;
        }
      }

    neutralizeFences();
    releaseVideoFrames();
    logFatalSettledOnce();
    return presentHealthy;
    }

  bool confirmGpuIdle(SettleReason reason, const char* operation,
                      bool* cleanResult = nullptr) noexcept {
    if(cleanResult!=nullptr)
      *cleanResult = false;
    constexpr uint32_t MaxIdleAttempts = 3u;
    for(uint32_t attempt=0; attempt<MaxIdleAttempts; ++attempt) {
      bool idleConfirmed = false;
      const bool clean = settleGpu(reason,operation,&idleConfirmed);
      if(!idleConfirmed)
        continue;
      if(cleanResult!=nullptr)
        *cleanResult = clean;
      return true;
      }
    return false;
    }

  Device&                                      device;
  Swapchain                                    swapchain;

  // DrawCommands and InventoryRenderer still call Shaders::inst() while the
  // neutral scene packet is being introduced. This bootstrap dependency is
  // private and is removed together with BootstrapTempest at the start of P2.
  Shaders                                      legacyShaders;

  std::array<VectorImage::Mesh,Resources::MaxFramesInFlight> uiMeshes;
  std::array<VectorImage::Mesh,Resources::MaxFramesInFlight> numberMeshes;
  std::array<Fence,Resources::MaxFramesInFlight>              fences;
  std::array<bool,Resources::MaxFramesInFlight>               slotSubmitted = {};
  std::array<CommandBuffer,Resources::MaxFramesInFlight>      commands;
  std::array<VideoWidget::PreparedFrame,Resources::MaxFramesInFlight> videoFrames;
  FaultInjection                               fault;

  ZBuffer                                      overlayDepth;
  TextureFormat                                depthFormat = TextureFormat::Depth16;
  bool                                         depthSupported = false;

  Attachment                                   savePreview;
  Pixmap                                       completedPreview;
  PreviewState                                 previewState = PreviewState::Idle;
  uint8_t                                      previewSlot = 0;
  bool                                         previewFallback = false;
  bool                                         previewTargetAllocated = false;
  bool                                         previewAttachmentRetained = false;

  uint8_t                                      nextSlot = 0;
  uint64_t                                     nextSerial = 1;
  uint64_t                                     activeSerial = 0;
  bool                                         frameActive = false;
  LifecycleState                               lifecycleState = LifecycleState::Active;
  SubmissionCounters                           counters;
  SubmissionCounters                           fatalCounters;
  bool                                         fatalCountersCaptured = false;
  bool                                         fatalSettledLogged = false;
  bool                                         shutdownCountsLogged = false;
  std::array<char,512>                         fatalMessage = {};
  bool                                         failed = false;
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
  if(impl->lifecycleState!=Impl::LifecycleState::Active)
    return std::nullopt;
  if(!impl->pollPresentFailure("RendererIOS asynchronous Metal present failed"))
    return std::nullopt;
  if(impl->frameActive)
    throw std::logic_error("RendererIOS frame ticket is already active");

  const uint8_t slot = impl->nextSlot;
  bool previewFenceFault = false;
  try {
    if(!impl->fences[slot].wait(0))
      return std::nullopt;
    if(impl->slotSubmitted[slot] &&
       impl->previewState==Impl::PreviewState::AwaitingGpu &&
       impl->previewSlot==slot &&
       impl->fault.previewFenceErrorAfterTerminal()) {
      previewFenceFault = true;
      throw DeviceLostException(
        "RendererIOS diagnostics injected a terminal save-preview fence error");
      }
    if(impl->slotSubmitted[slot] && impl->fault.frameFenceErrorAfterTerminal())
      throw DeviceLostException("RendererIOS diagnostics injected a terminal frame-fence error");
    }
  catch(const std::exception& e) {
    // Do not retry a Metal error command buffer: Tempest maps it to device
    // lost/hang. Dropping the fence also prevents its throwing destructor.
    impl->fences[slot] = Fence();
    impl->slotSubmitted[slot] = false;
    impl->releaseVideoFrame(slot);
    impl->forcePreviewPlaceholder();
    impl->fail(previewFenceFault ? "RendererIOS Metal save-preview fence failed"
                                : "RendererIOS Metal frame fence failed",
               e.what());
    return std::nullopt;
    }
  catch(...) {
    impl->fences[slot] = Fence();
    impl->slotSubmitted[slot] = false;
    impl->releaseVideoFrame(slot);
    impl->forcePreviewPlaceholder();
    impl->fail(previewFenceFault ? "RendererIOS Metal save-preview fence failed"
                                : "RendererIOS Metal frame fence failed");
    return std::nullopt;
    }
  impl->slotSubmitted[slot] = false;
  impl->releaseVideoFrame(slot);
  if(impl->previewState==Impl::PreviewState::AwaitingGpu && impl->previewSlot==slot)
    impl->materializePreviewSafely("RendererIOS save-preview materialization failed");
  if(impl->failed)
    return std::nullopt;

  Resources::resetRecycled(slot);
  impl->frameActive  = true;
  impl->activeSerial = impl->nextSerial++;
  return FrameTicket(ticketControl,slot,impl->activeSerial);
  }

void RendererIOS::prepareVideo(FrameTicket& frame, VideoWidget& video) {
  if(impl->lifecycleState!=Impl::LifecycleState::Active)
    return;
  const auto control = frame.control.lock();
  if(control.get()!=ticketControl.get() || !impl->frameActive ||
     frame.serial!=impl->activeSerial || frame.frameSlot!=impl->nextSlot)
    throw std::logic_error("RendererIOS received an invalid frame ticket for video preparation");

  const uint8_t slot = frame.frameSlot;
  try {
    impl->videoFrames[slot] = video.prepareFrame(impl->device,slot);
    }
  catch(const std::exception& e) {
    impl->releaseVideoFrame(slot);
    impl->fail("RendererIOS video frame preparation failed",e.what());
    throw;
    }
  catch(...) {
    impl->releaseVideoFrame(slot);
    impl->fail("RendererIOS video frame preparation failed");
    throw;
    }
  }

RendererIOS::SubmitResult RendererIOS::submitFrame(FrameTicket&& frame, const FrameInput& input) {
  if(impl->lifecycleState!=Impl::LifecycleState::Active) {
    cancelFrame(frame.serial);
    frame.disarm();
    return {};
    }
  const auto control = frame.control.lock();
  if(control.get()!=ticketControl.get() || !impl->frameActive ||
     frame.serial!=impl->activeSerial || frame.frameSlot!=impl->nextSlot)
    throw std::logic_error("RendererIOS received an invalid frame ticket");

  const uint8_t slot = frame.frameSlot;
  if(!impl->pollPresentFailure("RendererIOS asynchronous Metal present failed")) {
    impl->releaseVideoFrame(slot);
    frame.disarm();
    return {};
    }
  bool previewAccepted = false;
  bool previewFallback = false;

  try {
    if(input.captureSavePreview && impl->previewState==Impl::PreviewState::Idle) {
      previewAccepted = true;
      if(impl->fault.previewAttachmentMissing()) {
        previewFallback = true;
        impl->savePreview = Attachment();
        impl->previewTargetAllocated = false;
        }
      else {
        try {
          constexpr uint32_t thumbnailWidth = 800u;
          const uint32_t srcW = std::max(impl->swapchain.w(),1u);
          const uint32_t srcH = std::max(impl->swapchain.h(),1u);
          const uint32_t dstW = std::min(thumbnailWidth,srcW);
          const uint32_t dstH = std::max(uint32_t((uint64_t(srcH)*uint64_t(dstW))/uint64_t(srcW)),1u);
          impl->savePreview = impl->device.attachment(TextureFormat::RGBA8,dstW,dstH);
          impl->previewTargetAllocated = !impl->savePreview.isEmpty();
          previewFallback = !impl->previewTargetAllocated;
          if(previewFallback) {
            try {
              Log::e("[RendererIOS] save preview allocation returned an empty image; deferring placeholder to the frame fence");
              }
            catch(...) {
              }
            }
          }
        catch(const std::exception& e) {
          previewFallback = true;
          impl->savePreview = Attachment();
          impl->previewTargetAllocated = false;
          try {
            Log::e("[RendererIOS] save preview allocation failed; deferring placeholder to the frame fence: ",e.what());
            }
          catch(...) {
            }
          }
        catch(...) {
          previewFallback = true;
          impl->savePreview = Attachment();
          impl->previewTargetAllocated = false;
          try {
            Log::e("[RendererIOS] save preview allocation failed; deferring placeholder to the frame fence");
            }
          catch(...) {
            }
          }
        }
      }

    impl->uiMeshes[slot].update(impl->device,input.uiLayer);
    impl->numberMeshes[slot].update(impl->device,input.numberOverlay);

    auto& command = impl->commands[slot];
    {
      auto encoder = command.startEncoding(impl->device);
      if(impl->videoFrames[slot])
        VideoWidget::encodePrepared(encoder,slot,impl->videoFrames[slot]);
      auto& drawable = impl->swapchain[impl->swapchain.currentImage()];

      encoder.setDebugMarker("RendererIOS shell clear/UI");
      encoder.setFramebuffer({{drawable,OpaqueBlack,Tempest::Preserve}});
      impl->uiMeshes[slot].draw(encoder);

      const bool ringIcons = !input.videoActive && input.inventory.itemRenderer().hasItems();
      const bool inventoryVisible = input.inventory.isOpen()!=InventoryMenu::State::Closed || ringIcons;
      if(inventoryVisible) {
        if(!impl->overlayDepth.isEmpty()) {
          encoder.setDebugMarker("RendererIOS bootstrap inventory");
          encoder.setFramebuffer({{drawable,Tempest::Preserve,Tempest::Preserve}},
                                 {impl->overlayDepth,1.f,Tempest::Preserve});
          input.inventory.draw(encoder);
          }

        encoder.setDebugMarker("RendererIOS bootstrap inventory counters");
        encoder.setFramebuffer({{drawable,Tempest::Preserve,Tempest::Preserve}});
        impl->numberMeshes[slot].draw(encoder);
        }

      if(previewAccepted && !previewFallback) {
        encoder.setDebugMarker("RendererIOS save preview placeholder");
        encoder.setFramebuffer({{impl->savePreview,OpaqueBlack,Tempest::Preserve}});
        }
      }

    ++impl->counters.submitAttempts;
    impl->fences[slot]        = impl->device.submit(command);
    ++impl->counters.submitAccepted;
    impl->slotSubmitted[slot] = true;

  // Submission consumes the ticket even if drawable presentation subsequently
  // reports SwapchainSuboptimal. The command already references per-slot video
  // and UI resources, so cancelFrame() must not release their keep-alives.
    impl->frameActive  = false;
    impl->activeSerial = 0;
    frame.disarm();

    if(impl->fault.postSubmitSuboptimal())
      throw SwapchainSuboptimal();
    ++impl->counters.presentAttempts;
    impl->device.present(impl->swapchain);
    ++impl->counters.presentAccepted;

    if(previewAccepted) {
      impl->previewState    = Impl::PreviewState::AwaitingGpu;
      impl->previewSlot     = slot;
      impl->previewFallback = previewFallback;
      }

    impl->nextSlot = static_cast<uint8_t>((uint32_t(slot)+1u)%uint32_t(Resources::MaxFramesInFlight));

    if(impl->counters.presentAccepted==300u) {
      try {
        Log::i("RendererIOS shell: 300 present calls submitted");
        }
      catch(...) {
        }
      }
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    if(impl->counters.presentAccepted==1u || impl->counters.presentAccepted%300u==0u) {
      try {
        Log::d("RendererIOS lifecycle: presents=",impl->counters.presentAccepted,
               " next-slot=",uint32_t(impl->nextSlot));
        }
      catch(...) {
        }
      }
#endif

    (void)impl->pollPresentFailure(
      "RendererIOS asynchronous Metal present failed");

    return SubmitResult{previewAccepted};
    }
  catch(const SwapchainSuboptimal&) {
    // Drawable replacement is a recoverable surface lifecycle event. The
    // submitted frame, if any, is settled by resize() before targets are reused.
    throw;
    }
  catch(const std::exception& e) {
    impl->forcePreviewPlaceholder();
    if(impl->pollPresentFailure("RendererIOS asynchronous Metal present failed"))
      impl->fail("RendererIOS frame submission failed",e.what());
    throw;
    }
  catch(...) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS frame submission failed");
    throw;
    }
  }

Size RendererIOS::drawableSize() const {
  return Size(static_cast<int>(impl->swapchain.w()),static_cast<int>(impl->swapchain.h()));
  }

bool RendererIOS::pollDeviceFailure() noexcept {
  return impl->pollPresentFailure(
    "RendererIOS asynchronous Metal present failed");
  }

std::string_view RendererIOS::failureReason() const noexcept {
  return impl->failed ? std::string_view(impl->fatalMessage.data()) : std::string_view();
  }

void RendererIOS::resize() {
  if(impl->lifecycleState!=Impl::LifecycleState::Active)
    return;
  if(impl->failed ||
     !impl->settleGpu(SettleReason::Resize,"RendererIOS resize GPU settle failed"))
    return;
  impl->materializePreviewSafely("RendererIOS resize preview finalization failed");
  if(impl->failed)
    return;
  impl->frameActive  = false;
  impl->activeSerial = 0;
  impl->nextSlot     = 0;
  if(impl->previewState==Impl::PreviewState::Idle) {
    impl->savePreview = Attachment();
    impl->previewTargetAllocated = false;
    impl->previewAttachmentRetained = false;
    }
  try {
    impl->swapchain.reset();
    impl->resetTargets();
    }
  catch(const SwapchainSuboptimal&) {
    throw;
    }
  catch(const std::exception& e) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS resize failed",e.what());
    }
  catch(...) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS resize failed");
    }
  }

bool RendererIOS::suspend() noexcept {
  if(impl->lifecycleState==Impl::LifecycleState::Stopped)
    return false;
  if(impl->lifecycleState==Impl::LifecycleState::Active) {
    impl->lifecycleState = Impl::LifecycleState::Suspended;
    }

  if(impl->frameActive) {
    impl->releaseVideoFrame(impl->nextSlot);
    impl->frameActive  = false;
    impl->activeSerial = 0;
    }

  bool idleConfirmed = false;
  impl->settleGpu(SettleReason::Suspend,
                  "RendererIOS suspend GPU settle failed",&idleConfirmed);
  impl->logLifecycleCounts("suspend-settled",idleConfirmed);
  if(idleConfirmed) {
    impl->materializePreviewSafely(
      "RendererIOS suspend preview finalization failed");
    impl->logFatalSettledOnce();
    }
  return idleConfirmed;
  }

bool RendererIOS::resume() noexcept {
  if(impl->failed || impl->lifecycleState==Impl::LifecycleState::Fatal ||
     impl->lifecycleState==Impl::LifecycleState::Stopped)
    return false;
  if(impl->lifecycleState==Impl::LifecycleState::Active) {
    impl->lifecycleState = Impl::LifecycleState::Suspended;
    }

  if(impl->frameActive) {
    impl->releaseVideoFrame(impl->nextSlot);
    impl->frameActive  = false;
    impl->activeSerial = 0;
    }

  bool idleConfirmed = false;
  impl->settleGpu(SettleReason::Resume,
                  "RendererIOS resume GPU settle failed",&idleConfirmed);
  impl->logLifecycleCounts("resume-settled",idleConfirmed);
  if(!idleConfirmed || impl->failed)
    return false;

  impl->materializePreviewSafely(
    "RendererIOS resume preview finalization failed");
  if(impl->failed) {
    impl->logFatalSettledOnce();
    return false;
    }

  impl->frameActive  = false;
  impl->activeSerial = 0;
  impl->nextSlot     = 0;
  if(impl->previewState==Impl::PreviewState::Idle) {
    impl->savePreview               = Attachment();
    impl->previewTargetAllocated    = false;
    impl->previewAttachmentRetained = false;
    }
  try {
    impl->swapchain.reset();
    impl->resetTargets();
    impl->lifecycleState = Impl::LifecycleState::Active;
    return true;
    }
  catch(const std::exception& e) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS resume swapchain reset failed",e.what());
    impl->logFatalSettledOnce();
    }
  catch(...) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS resume swapchain reset failed");
    impl->logFatalSettledOnce();
    }
  return false;
  }

bool RendererIOS::waitIdle() noexcept {
  bool idleConfirmed = false;
  impl->settleGpu(SettleReason::ExternalWait,
                  "RendererIOS wait-idle failed",&idleConfirmed);
  if(idleConfirmed)
    impl->materializePreviewSafely("RendererIOS wait-idle preview finalization failed");
  if(idleConfirmed) {
    impl->logFatalSettledOnce();
    }
  return idleConfirmed;
  }

void RendererIOS::shutdown() noexcept {
  impl->stopFrameAdmission(Impl::LifecycleState::Stopped);
  if(!impl->confirmGpuIdle(SettleReason::Shutdown,
                           "RendererIOS shutdown GPU settle failed")) {
    impl->logShutdownCountsOnce("idle-unconfirmed");
    impl->terminateWithoutTeardown(
      "RendererIOS shutdown could not confirm device idle after three attempts");
    }
  impl->materializePreviewSafely("RendererIOS shutdown preview finalization failed");
  impl->logFatalSettledOnce();
  impl->logShutdownCountsOnce(impl->failed ? "fatal" : "clean");
  }

void RendererIOS::prepareForOwnerRelease() noexcept {
  if(!impl->confirmGpuIdle(SettleReason::OwnerRelease,
                           "RendererIOS owner-release GPU settle failed"))
    impl->terminateWithoutTeardown(
      "RendererIOS owner release could not confirm device idle after three attempts");
  impl->materializePreviewSafely("RendererIOS owner-release preview finalization failed");
  impl->logFatalSettledOnce();
  }

void RendererIOS::onWorldChanged() {
  prepareForOwnerRelease();
  if(impl->failed || impl->lifecycleState==Impl::LifecycleState::Stopped)
    return;
  impl->frameActive  = false;
  impl->activeSerial = 0;
  impl->nextSlot     = 0;
  try {
    for(auto& command:impl->commands)
      command = impl->device.commandBuffer();
    }
  catch(const std::exception& e) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS world-change reset failed",e.what());
    }
  catch(...) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS world-change reset failed");
    }
  }

bool RendererIOS::savePreviewReady() {
  (void)impl->pollPresentFailure(
    "RendererIOS asynchronous Metal present failed");
  if(impl->previewState==Impl::PreviewState::ReadyCpu ||
     impl->previewState==Impl::PreviewState::ReadyPlaceholder)
    return true;
  if(impl->previewState!=Impl::PreviewState::AwaitingGpu)
    return false;
  if(impl->failed) {
    impl->forcePreviewPlaceholder();
    return true;
    }
  try {
    if(!impl->fences[impl->previewSlot].wait(0))
      return false;
    if(impl->slotSubmitted[impl->previewSlot] &&
       impl->fault.previewFenceErrorAfterTerminal())
      throw DeviceLostException(
        "RendererIOS diagnostics injected a terminal save-preview fence error");
    impl->materializePreviewSafely("RendererIOS save-preview materialization failed");
    return impl->previewState==Impl::PreviewState::ReadyCpu ||
           impl->previewState==Impl::PreviewState::ReadyPlaceholder;
    }
  catch(const std::exception& e) {
    impl->fences[impl->previewSlot] = Fence();
    impl->slotSubmitted[impl->previewSlot] = false;
    impl->releaseVideoFrame(impl->previewSlot);
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS Metal save-preview fence failed",e.what());
    return true;
    }
  catch(...) {
    impl->fences[impl->previewSlot] = Fence();
    impl->slotSubmitted[impl->previewSlot] = false;
    impl->releaseVideoFrame(impl->previewSlot);
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS Metal save-preview fence failed");
    return true;
    }
  }

bool RendererIOS::savePreviewIsPlaceholder() const noexcept {
  return impl->previewState==Impl::PreviewState::ReadyPlaceholder;
  }

Pixmap RendererIOS::takeSavePreview() {
  if(impl->previewState==Impl::PreviewState::ReadyCpu) {
    Pixmap result = std::move(impl->completedPreview);
    impl->clearPreview();
    return result;
    }
  if(impl->previewState==Impl::PreviewState::ReadyPlaceholder) {
    impl->clearPreview();
    return blackPixmap(4u,4u);
    }
  throw std::logic_error("RendererIOS save preview is not ready");
  }

Pixmap RendererIOS::screenshot() {
  const uint32_t w = std::max(impl->swapchain.w(),1u);
  const uint32_t h = std::max(impl->swapchain.h(),1u);
  return blackPixmap(w,h);
  }

void RendererIOS::dbgDraw(Painter& painter) {
  (void)painter;
  }

bool RendererIOS::ssaoBuffersAllocated() const noexcept {
  return false;
  }

void RendererIOS::cancelFrame(uint64_t serial) noexcept {
  if(!impl || !impl->frameActive || impl->activeSerial!=serial)
    return;
  impl->releaseVideoFrame(impl->nextSlot);
  impl->frameActive  = false;
  impl->activeSerial = 0;
  }
