#include "iosmetalcontext.h"

#include <Tempest/Attachment>
#include <Tempest/CommandBuffer>
#include <Tempest/Device>
#include <Tempest/Except>
#include <Tempest/Fence>
#include <Tempest/Log>
#include <Tempest/MetalApi>
#include <Tempest/Painter>
#include <Tempest/Pixmap>
#include <Tempest/Swapchain>
#include <Tempest/VectorImage>
#include <Tempest/ZBuffer>

#include <algorithm>
#include <array>
#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST)
#include <atomic>
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#include <chrono>
#endif
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>

#include "iosgpuscene.h"
#include "iosgpubink.h"
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
#include "iosbinkselftest.h"
#endif
#include "iosmetalresourceallocator.h"
#include "iospipelinearchivepolicy.h"
#include "iossavepreviewpolicy.h"
#include "iossceneassetregistry.h"
#include "resources.h"
#include "rendereriosplatform.h"
#include "shaders.h"
#include "ui/inventorymenu.h"
#include "ui/videowidget.h"

using namespace Tempest;

static_assert(std::is_nothrow_move_assignable_v<CommandBuffer>);
static_assert(MetalPipelineArchiveSnapshot::AbiVersion==1u);
static_assert(MetalPipelineArchiveSnapshot::StructSize==120u);
static_assert(
  (MetalPipelineArchiveSnapshot::Configured |
   MetalPipelineArchiveSnapshot::Available |
   MetalPipelineArchiveSnapshot::LoadedFromDisk |
   MetalPipelineArchiveSnapshot::CreatedEmpty |
   MetalPipelineArchiveSnapshot::Dirty |
   MetalPipelineArchiveSnapshot::DisabledAfterError)==63u);

#if !defined(OPENGOTHIC_RENDERER_IOS_BUILD_SHA)
#define OPENGOTHIC_RENDERER_IOS_BUILD_SHA "local"
#endif

#if !defined(OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID)
#define OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID 0
#endif

#if !defined(OPENGOTHIC_RENDERER_IOS_FAULT_MODE_NAME)
#define OPENGOTHIC_RENDERER_IOS_FAULT_MODE_NAME "none"
#endif

constexpr char RendererIOSConfiguredFaultModeEvidence[] =
  "RendererIOS configured fault mode=" OPENGOTHIC_RENDERER_IOS_FAULT_MODE_NAME;

#if OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID < 0 || OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID > 8
#error "Unsupported RendererIOS fault mode id"
#endif

#if OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 0 && !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "RendererIOS fault injection requires diagnostics"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST) && !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "RendererIOS Bink self-test requires diagnostics"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST) && OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 0
#error "RendererIOS Bink self-test requires fault mode none"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) && !defined(__IOS__)
#error "RendererIOS resource allocator self-test requires iOS"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) && !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "RendererIOS resource allocator self-test requires diagnostics"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) && OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 0
#error "RendererIOS resource allocator self-test requires fault mode none"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) && defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
#error "RendererIOS resource allocator and Bink self-tests are mutually exclusive"
#endif

namespace {

IOSGPUScene::DepthFormat iosGPUSceneDepthFormat(TextureFormat format) {
  switch(format) {
    case TextureFormat::Depth16:
      return IOSGPUScene::DepthFormat::Depth16Unorm;
    case TextureFormat::Depth32F:
      return IOSGPUScene::DepthFormat::Depth32Float;
    default:
      throw std::runtime_error(
        "RendererIOS IOSGPUScene requires Depth16 or Depth32F");
    }
  }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
const char* rendererIOSUISurfaceEvidenceName(
    RendererIOSUISurfaceEvidence value) noexcept {
  switch(value) {
    case RendererIOSUISurfaceEvidence::None:             return "none";
    case RendererIOSUISurfaceEvidence::Inventory:        return "inventory";
    case RendererIOSUISurfaceEvidence::QuickRingItems:   return "quickring-items";
    case RendererIOSUISurfaceEvidence::QuickRingWeapons: return "quickring-weapons";
    }
  return "unknown";
  }
#endif

enum class SettleReason : uint8_t {
  Resize,
  Suspend,
  Resume,
  ExternalWait,
  OwnerRelease,
  Shutdown,
  FinalDestruction,
  };

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
const char* settleReasonName(SettleReason reason) noexcept {
  switch(reason) {
    case SettleReason::Resize:           return "resize";
    case SettleReason::Suspend:          return "suspend";
    case SettleReason::Resume:           return "resume";
    case SettleReason::ExternalWait:     return "external-wait";
    case SettleReason::OwnerRelease:     return "owner-release";
    case SettleReason::Shutdown:         return "shutdown";
    case SettleReason::FinalDestruction: return "final-destruction";
    }
  return "unknown";
  }
#endif

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

static_assert(static_cast<uint8_t>(
                RendererIOSFaultMode::PreviewAttachmentMissing)==1u);
static_assert(static_cast<uint8_t>(
                RendererIOSFaultMode::PreviewReadbackError)==2u);
static_assert(static_cast<uint8_t>(
                RendererIOSFaultMode::PreviewFenceErrorAfterTerminal)==3u);

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

constexpr bool configuredSavePreviewNeedsGpuCapture() noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  return iosSavePreviewNeedsGpuCapture(
    true,static_cast<uint32_t>(OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID));
#else
  return iosSavePreviewNeedsGpuCapture(
    false,static_cast<uint32_t>(OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID));
#endif
  }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
uint64_t rendererIOSClockUs() noexcept {
  using Clock = std::chrono::steady_clock;
  return static_cast<uint64_t>(
    std::chrono::duration_cast<std::chrono::microseconds>(
      Clock::now().time_since_epoch()).count());
  }
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

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST)
constexpr char RendererIOSResourceAllocatorSelfTestArmed[] = "RendererIOS resource allocator self-test: ARMED case=private-memoryless-4x4-rgba8-v1";
constexpr char RendererIOSResourceAllocatorSelfTestPassed[] = "RendererIOS resource allocator self-test: PASS case=private-memoryless-4x4-rgba8-v1 allocation-only=1 encoded=0 render-pass=0 submitted=0 created=2 live=0 released=2";

IOSResourceDesc iosResourceAllocatorSelfTestTexture(
    uint32_t id, bool memoryless) noexcept {
  IOSResourceDesc resource;
  resource.id = IOSResourceId{id};
  resource.kind = IOSResourceKind::Texture;
  resource.lifetime = IOSResourceLifetime::Transient;
  resource.initialContent = IOSInitialContent::Undefined;
  resource.memoryless = memoryless;
  resource.aliasable = false;
  resource.aliasGroup = {};
  resource.layout = {
    IOSPixelFormat::Rgba8Unorm,{4u,4u},1u,1u,0u,
    };
  resource.usage = IOSResourceUsage::RenderAttachment;
  return resource;
  }

IOSFramePlan iosResourceAllocatorSelfTestPlan(bool memoryless) {
  IOSResourceDesc present;
  present.id = IOSResourceId{1u};
  present.kind = IOSResourceKind::Texture;
  present.lifetime = IOSResourceLifetime::External;
  present.initialContent = IOSInitialContent::Undefined;
  present.layout = {
    IOSPixelFormat::Bgra8Unorm,{4u,4u},1u,1u,0u,
    };
  present.usage = IOSResourceUsage::RenderAttachment |
                  IOSResourceUsage::Present;

  IOSFramePlan plan;
  plan.resources = {
    present,
    iosResourceAllocatorSelfTestTexture(2u,memoryless),
    };
  plan.passes = {
    {IOSPassId{1u},IOSPassKind::Render,{
      {IOSResourceId{1u},IOSUseSemantic::RenderAttachment,
       IOSLoadAction::Clear,IOSStoreAction::Store,
       IOSAttachmentWriteMode::MayPreserve},
      {IOSResourceId{2u},IOSUseSemantic::RenderAttachment,
       IOSLoadAction::Clear,IOSStoreAction::Discard,
       IOSAttachmentWriteMode::MayPreserve},
      }},
    {IOSPassId{2u},IOSPassKind::Present,{
      {IOSResourceId{1u},IOSUseSemantic::PresentSource,
       IOSLoadAction::NotApplicable,IOSStoreAction::NotApplicable,
       IOSAttachmentWriteMode::NotApplicable},
      }},
    };
  return plan;
  }

void runIOSResourceAllocatorSelfTest(IOSMetalResourceAllocator& allocator,
                                     Device& device) {
  static_assert(IOSFramePlanABIVersion==4u);
  static std::atomic_flag started = ATOMIC_FLAG_INIT;
  if(started.test_and_set())
    return;
  Log::i(RendererIOSResourceAllocatorSelfTestArmed);

  const IOSFramePlan privatePlan =
      iosResourceAllocatorSelfTestPlan(false);
  const IOSFramePlan memorylessPlan =
      iosResourceAllocatorSelfTestPlan(true);
  const IOSFramePlanValidation privateValidation = privatePlan.validate();
  const IOSFramePlanValidation memorylessValidation =
      memorylessPlan.validate();
  if(!privateValidation || !memorylessValidation) {
    const IOSFramePlanValidation& validation = !privateValidation
                                             ? privateValidation
                                             : memorylessValidation;
    Log::e("RendererIOS resource allocator self-test: FAIL case=private-memoryless-4x4-rgba8-v1 reason=invalid-frame-plan error=",
           static_cast<uint32_t>(validation.error),
           " resource=",validation.resource.value,
           " pass=",validation.pass.value,
           " allocation-only=1 encoded=0 render-pass=0 submitted=0 created=0 live=0 released=0");
    throw std::runtime_error(
      "RendererIOS resource allocator self-test frame plan is invalid");
    }

  const IOSResourceDesc& privateResource = privatePlan.resources[1];
  const IOSResourceDesc& memorylessResource = memorylessPlan.resources[1];
  const bool exactRequestPair =
      privateResource.id==memorylessResource.id &&
      privateResource.kind==memorylessResource.kind &&
      privateResource.lifetime==memorylessResource.lifetime &&
      privateResource.initialContent==memorylessResource.initialContent &&
      !privateResource.memoryless && memorylessResource.memoryless &&
      privateResource.aliasable==memorylessResource.aliasable &&
      privateResource.aliasGroup==memorylessResource.aliasGroup &&
      privateResource.layout==memorylessResource.layout &&
      privateResource.usage==memorylessResource.usage;
  const IOSMetalResourcePreflight privatePreflight =
      iosMetalResourcePreflight(privateResource);
  const IOSMetalResourcePreflight memorylessPreflight =
      iosMetalResourcePreflight(memorylessResource);
  const BorrowedMetalDevice expectedDevice = MetalApi::borrowDevice(device);
  const uintptr_t expectedDeviceIdentity =
      reinterpret_cast<uintptr_t>(expectedDevice.get());

  const IOSMetalResourceLifetimeSnapshot lifetimeBefore =
      iosMetalResourceLifetimeSnapshot();
  IOSMetalResourceLifetimeSnapshot lifetimeInside;
  bool metadataPassed = false;
  {
    IOSMetalResourceTexture privateTexture =
        allocator.allocate(privateResource);
    IOSMetalResourceTexture memorylessTexture =
        allocator.allocate(memorylessResource);

    const IOSMetalTextureSnapshot privateSnapshot = privateTexture.snapshot();
    const IOSMetalTextureSnapshot memorylessSnapshot =
        memorylessTexture.snapshot();
    lifetimeInside = iosMetalResourceLifetimeSnapshot();
    metadataPassed = exactRequestPair && bool(expectedDevice) &&
                     bool(privatePreflight) && bool(memorylessPreflight) &&
                     privatePreflight.storage==IOSMetalResourceStorage::Private &&
                     memorylessPreflight.storage==IOSMetalResourceStorage::Memoryless &&
                     iosMetalTextureMatches(
                       privateSnapshot,privateResource,
                       IOSMetalResourceStorage::Private) &&
                     iosMetalTextureMatches(
                       memorylessSnapshot,memorylessResource,
                       IOSMetalResourceStorage::Memoryless) &&
                     privateSnapshot.textureIdentity!=
                       memorylessSnapshot.textureIdentity &&
                     privateSnapshot.deviceIdentity==expectedDeviceIdentity &&
                     memorylessSnapshot.deviceIdentity==expectedDeviceIdentity;
    }

  const IOSMetalResourceLifetimeSnapshot lifetimeAfter =
      iosMetalResourceLifetimeSnapshot();
  const bool createdMonotonic =
      lifetimeInside.created>=lifetimeBefore.created &&
      lifetimeAfter.created>=lifetimeInside.created;
  const bool liveInsideMonotonic =
      lifetimeInside.live>=lifetimeBefore.live;
  const bool releasedMonotonic =
      lifetimeInside.released>=lifetimeBefore.released &&
      lifetimeAfter.released>=lifetimeInside.released;
  const bool monotonic = createdMonotonic && liveInsideMonotonic &&
                         releasedMonotonic;
  const uint64_t createdDelta = createdMonotonic
                              ? lifetimeAfter.created-lifetimeBefore.created
                              : 0u;
  const uint64_t liveInsideDelta = liveInsideMonotonic
                                 ? lifetimeInside.live-lifetimeBefore.live
                                 : 0u;
  const uint64_t releasedInsideDelta = releasedMonotonic
                                     ? lifetimeInside.released-
                                       lifetimeBefore.released
                                     : 0u;
  const uint64_t releasedDelta = releasedMonotonic
                               ? lifetimeAfter.released-
                                 lifetimeBefore.released
                               : 0u;
  const bool lifetimePassed =
      monotonic && createdDelta==2u && liveInsideDelta==2u &&
      releasedInsideDelta==0u &&
      lifetimeAfter.created==lifetimeInside.created &&
      lifetimeAfter.live==lifetimeBefore.live && releasedDelta==2u;
  if(!metadataPassed || !lifetimePassed) {
    Log::e("RendererIOS resource allocator self-test: FAIL case=private-memoryless-4x4-rgba8-v1 reason=native-metadata-or-lifetime-mismatch allocation-only=1 encoded=0 render-pass=0 submitted=0 metadata=",
           metadataPassed ? 1 : 0,
           " monotonic=",monotonic ? 1 : 0,
           " created-before=",lifetimeBefore.created,
           " created-inside=",lifetimeInside.created,
           " created-after=",lifetimeAfter.created,
           " created-delta=",createdDelta,
           " live-before=",lifetimeBefore.live,
           " live-inside=",lifetimeInside.live,
           " live-after=",lifetimeAfter.live,
           " live-inside-delta=",liveInsideDelta,
           " released-before=",lifetimeBefore.released,
           " released-inside=",lifetimeInside.released,
           " released-after=",lifetimeAfter.released,
           " released-inside-delta=",releasedInsideDelta,
           " released-delta=",releasedDelta);
    throw std::runtime_error(
      "RendererIOS resource allocator self-test allocation failed");
    }
  Log::i(RendererIOSResourceAllocatorSelfTestPassed);
  }
#endif

}

struct IOSMetalContext::Impl final {
  enum class PreviewState : uint8_t {
    Idle,
    AwaitingGpu,
    ReadyCpu,
    ReadyPlaceholder,
    };

#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
  enum class BinkSelfTestState : uint8_t {
    Armed,
    Ready,
    EncodedPendingSubmit,
    AwaitingGpu,
    Passed,
    Failed,
    };
#endif

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

  struct PreparedUi final {
    uint64_t       serial      = 0;
    InventoryMenu* inventory   = nullptr;
    bool           videoActive = false;
    };

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  struct FunctionalEvidence final {
    RendererIOSUISurfaceEvidence uiSurface =
      RendererIOSUISurfaceEvidence::None;
    uint64_t serial           = 0;
    uint64_t uiItemDrawCount  = 0;
    uint64_t realBinkOrdinal  = 0;
    uint64_t resumeCycle      = 0;
    bool     presentAccepted  = false;
    };
#endif

  struct FrameContext final {
    VectorImage::Mesh          uiMesh;
    VectorImage::Mesh          numberMesh;
    VideoWidget::PreparedFrame videoFrame;
    IOSSceneSnapshotPtr        sceneFrame;
    PreparedUi                 uiPayload;
    uint64_t                   videoSerial = 0;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    FunctionalEvidence         functionalEvidence;
#endif
    bool                       submitted = false;
    bool                       discardCommandAfterIdle = false;
    bool                       rebuildCommand = false;
    // Impl teardown settles explicitly. Reverse member destruction still
    // drops the fence and command before the scene/video keep-alives.
    CommandBuffer              command;
    Fence                      fence;
    };

  Impl(Device& device, SystemApi::Window* window)
    : device(device), resourceAllocator(device), swapchain(device,window),
      runtimeBeforeLegacyShaders(MetalApi::runtimeCompilationSnapshot(device)),
      builtinRuntimeBeforeLegacyShaders(
        MetalApi::builtinRuntimeSnapshot(device)),
      legacyShaders(Shaders::CompilationProfile::RendererIOSBridge),
      runtimeAfterLegacyShaders(MetalApi::runtimeCompilationSnapshot(device)),
      builtinRuntimeAfterLegacyShaders(
        MetalApi::builtinRuntimeSnapshot(device)) {
#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST)
    runIOSResourceAllocatorSelfTest(resourceAllocator,device);
#endif
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
    if(!depthSupported)
      throw std::runtime_error(
        "RendererIOS IOSGPUScene requires a supported Metal depth format");
    gpuScene = std::make_unique<IOSGPUScene>(
      device,
      IOSGPUScene::TargetLayout{
        IOSGPUScene::ColorFormat::Bgra8Unorm,
        iosGPUSceneDepthFormat(depthFormat),
        1u,
        });
    gpuBink = std::make_unique<IOSGPUBink>(device);
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
    armBinkSelfTest();
#endif

    for(auto& frame:frames)
      frame.command = device.commandBuffer();
    resetTargets();
    const auto platform = rendererIOSPlatformInfo();
    try {
      Log::i(RendererIOSConfiguredFaultModeEvidence);
      Log::i("RendererIOS shell: version=1 profile=Safe features=native-landscape-textured,ui,inventory,save-placeholder,save-cpu-fastpath build=",
             OPENGOTHIC_RENDERER_IOS_BUILD_SHA," gpu=",device.properties().name,
             " deviceFamily=",platform.deviceFamily.data()," iOS=",platform.osVersion.data(),
             " faultMode=",fault.name(),
             " savePreviewRoute=",
             configuredSavePreviewNeedsGpuCapture()
               ? "gpu-diagnostic"
               : "cpu-placeholder");
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      Log::i("RendererIOS diagnostics: ON frames-in-flight=",Resources::MaxFramesInFlight,
             " context=IOSMetalContext transport=Tempest");
      logRuntimeCompilationBridge();
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
      Log::i("RendererIOS Bink self-test: ARMED case=yuv420p-4x4-padded-v1");
#endif
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

  void logRuntimeCompilationBridge() noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    try {
      const bool available =
        runtimeBeforeLegacyShaders.available &&
        runtimeAfterLegacyShaders.available;
      Log::i(
        "RendererIOS runtime compilation: point=legacy-bridge available=",
        available ? 1 : 0,
        " source-before=",runtimeBeforeLegacyShaders.sourceLibraryRequests,
        " source-after=",runtimeAfterLegacyShaders.sourceLibraryRequests,
        " source-delta=",
        counterDelta(runtimeAfterLegacyShaders.sourceLibraryRequests,
                     runtimeBeforeLegacyShaders.sourceLibraryRequests),
        " compute-before=",runtimeBeforeLegacyShaders.computePsoRequests,
        " compute-after=",runtimeAfterLegacyShaders.computePsoRequests,
        " compute-delta=",
        counterDelta(runtimeAfterLegacyShaders.computePsoRequests,
                     runtimeBeforeLegacyShaders.computePsoRequests),
        " render-before=",runtimeBeforeLegacyShaders.renderPsoRequests,
        " render-after=",runtimeAfterLegacyShaders.renderPsoRequests,
        " render-delta=",
        counterDelta(runtimeAfterLegacyShaders.renderPsoRequests,
                     runtimeBeforeLegacyShaders.renderPsoRequests));
      const auto& sourceBefore =
        builtinRuntimeBeforeLegacyShaders.sourceLibraryRequests;
      const auto& sourceAfter =
        builtinRuntimeAfterLegacyShaders.sourceLibraryRequests;
      const auto& renderBefore =
        builtinRuntimeBeforeLegacyShaders.renderPsoRequests;
      const auto& renderAfter =
        builtinRuntimeAfterLegacyShaders.renderPsoRequests;
      Log::i(
        "RendererIOS builtin runtime attribution: point=legacy-bridge role-abi=1 available=",
        builtinRuntimeBeforeLegacyShaders.available &&
        builtinRuntimeAfterLegacyShaders.available ? 1 : 0,
        " source-before=",
        sourceBefore[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::ColorVertex)],",",
        sourceBefore[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::ColorFragment)],",",
        sourceBefore[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::TextureVertex)],",",
        sourceBefore[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::TextureFragment)],
        " source-after=",
        sourceAfter[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::ColorVertex)],",",
        sourceAfter[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::ColorFragment)],",",
        sourceAfter[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::TextureVertex)],",",
        sourceAfter[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::TextureFragment)],
        " render-before=",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesOpaque)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesOpaque)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesAlpha)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesAlpha)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesAdditive)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesAdditive)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesOpaque)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesOpaque)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesAlpha)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesAlpha)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesAdditive)],",",
        renderBefore[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesAdditive)],
        " render-after=",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesOpaque)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesOpaque)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesAlpha)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesAlpha)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesAdditive)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesAdditive)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesOpaque)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesOpaque)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesAlpha)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesAlpha)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesAdditive)],",",
        renderAfter[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesAdditive)]);
      }
    catch(...) {
      }
#endif
    }

  void logRuntimeCompilationFrame(uint64_t presents) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    try {
      const auto snapshot = MetalApi::runtimeCompilationSnapshot(device);
      Log::d("RendererIOS runtime compilation: point=frame presents=",presents,
             " available=",snapshot.available ? 1 : 0,
             " source=",snapshot.sourceLibraryRequests,
             " compute=",snapshot.computePsoRequests,
             " render=",snapshot.renderPsoRequests);
      if(presents!=1u && presents%300u!=0u)
        return;
      const auto builtin = MetalApi::builtinRuntimeSnapshot(device);
      const auto& source = builtin.sourceLibraryRequests;
      const auto& render = builtin.renderPsoRequests;
      Log::d(
        "RendererIOS builtin runtime attribution: point=frame presents=",presents,
        " role-abi=1 available=",builtin.available ? 1 : 0,
        " source=",
        source[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::ColorVertex)],",",
        source[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::ColorFragment)],",",
        source[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::TextureVertex)],",",
        source[metalBuiltinSourceRoleIndex(
          MetalBuiltinSourceRole::TextureFragment)],
        " render=",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesOpaque)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesOpaque)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesAlpha)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesAlpha)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorLinesAdditive)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::ColorTrianglesAdditive)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesOpaque)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesOpaque)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesAlpha)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesAlpha)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureLinesAdditive)],",",
        render[metalBuiltinRenderRoleIndex(
          MetalBuiltinRenderRole::TextureTrianglesAdditive)]);
      }
    catch(...) {
      }
#else
    (void)presents;
#endif
    }

  void logPipelineArchiveSnapshot(
      const char* point, uint64_t presents,
      const MetalPipelineArchiveSnapshot& snapshot,
      bool flushInvoked, bool flushSucceeded) noexcept {
    namespace Archive = RendererIOSPipelineArchive;
    const auto hasFlag = [&snapshot](uint32_t flag) noexcept {
      return (snapshot.flags&flag)!=0u;
      };
    try {
      Log::i(
        Archive::SnapshotStateLogPrefix.data(),point,
        " presents=",presents,
        " abi=",snapshot.abiVersion,
        " size=",snapshot.structSize,
        " flags=",snapshot.flags,
        " schema=",Archive::CacheSchemaVersion,
        " key=",Archive::PipelineKeyAbiVersion,
        " metallib=",Archive::MetallibAbiVersion,
        " cfg=",
        hasFlag(MetalPipelineArchiveSnapshot::Configured) ? 1 : 0,
        " available=",
        hasFlag(MetalPipelineArchiveSnapshot::Available) ? 1 : 0,
        " loaded=",
        hasFlag(MetalPipelineArchiveSnapshot::LoadedFromDisk) ? 1 : 0,
        " empty=",
        hasFlag(MetalPipelineArchiveSnapshot::CreatedEmpty) ? 1 : 0,
        " dirty=",
        hasFlag(MetalPipelineArchiveSnapshot::Dirty) ? 1 : 0,
        " disabled=",
        hasFlag(MetalPipelineArchiveSnapshot::DisabledAfterError) ? 1 : 0,
        " load-fail=",snapshot.loadFailures,
        " rebuild=",snapshot.rebuilds);
      Log::i(
        Archive::SnapshotRenderLogPrefix.data(),point,
        " presents=",presents,
        " hit=",snapshot.renderHits,
        " miss=",snapshot.renderMisses,
        " add=",snapshot.renderAdds,
        " fallback=",snapshot.renderFallbacks);
      Log::i(
        Archive::SnapshotComputeLogPrefix.data(),point,
        " presents=",presents,
        " hit=",snapshot.computeHits,
        " miss=",snapshot.computeMisses,
        " add=",snapshot.computeAdds,
        " fallback=",snapshot.computeFallbacks);
      Log::i(
        Archive::SnapshotFlushLogPrefix.data(),point,
        " presents=",presents,
        " attempt=",snapshot.flushAttempts,
        " success=",snapshot.flushSuccesses,
        " fail=",snapshot.flushFailures,
        " invoked=",flushInvoked ? 1 : 0,
        " result=",flushSucceeded ? 1 : 0,
        " bounded=",uint32_t(pipelineArchiveFlush.attempts),
        " settled=",pipelineArchiveFlush.settled ? 1 : 0);
      }
    catch(...) {
      }
    }

  void flushPipelineArchiveAfterPresent(uint64_t presents) noexcept {
    namespace Archive = RendererIOSPipelineArchive;
    const auto before =
      MetalApi::pipelineArchiveSnapshot(device);
    const bool dirty =
      (before.flags&MetalPipelineArchiveSnapshot::Dirty)!=0u;
    const auto decision = Archive::flushDecisionAfterPresent(
      pipelineArchiveFlush,presents,dirty);
    if(decision==Archive::FlushDecision::None)
      return;

    logPipelineArchiveSnapshot(
      "pre",presents,before,false,false);
    bool flushInvoked = false;
    bool flushSucceeded = false;
    if(decision==Archive::FlushDecision::SettleClean) {
      Archive::settleCleanArchive(pipelineArchiveFlush);
      }
    else {
      flushInvoked = true;
      flushSucceeded =
        MetalApi::flushPipelineArchive(device);
      Archive::recordFlushResult(
        pipelineArchiveFlush,flushSucceeded);
      }
    const auto after =
      MetalApi::pipelineArchiveSnapshot(device);
    logPipelineArchiveSnapshot(
      "post",presents,after,flushInvoked,flushSucceeded);
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

#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
  void armBinkSelfTest() noexcept {
    binkSelfTestState = BinkSelfTestState::Armed;
    }

  void prepareBinkSelfTest() {
    if(binkSelfTestState!=BinkSelfTestState::Armed)
      return;
    const size_t alignment =
      std::max<size_t>(device.properties().ssbo.offsetAlign,4u);
    const auto testCase = makeIOSBinkSelfTestCase(alignment);
    binkSelfTestTarget =
      device.attachment(TextureFormat::RGBA8,
                        static_cast<uint32_t>(IOSBinkSelfTestWidth),
                        static_cast<uint32_t>(IOSBinkSelfTestHeight));
    binkSelfTestPlanes =
      device.ssbo(BufferHeap::Upload,
                  testCase.planes.data(),testCase.planes.size());
    if(binkSelfTestTarget.isEmpty() || binkSelfTestPlanes.isEmpty())
      throw std::runtime_error(
        "RendererIOS Bink self-test could not allocate its resources");

    binkSelfTestLayout.offsetU = testCase.offsetU;
    binkSelfTestLayout.offsetV = testCase.offsetV;
    binkSelfTestLayout.strideY = testCase.strideY;
    binkSelfTestLayout.strideU = testCase.strideU;
    binkSelfTestLayout.strideV = testCase.strideV;
    binkSelfTestEncodedFramesBefore = gpuBink->encodedFrames();
    binkSelfTestState = BinkSelfTestState::Ready;
    }

  bool encodeBinkSelfTest(
      Encoder<CommandBuffer>& encoder, uint8_t slot, uint64_t serial) {
    if(binkSelfTestState!=BinkSelfTestState::Ready)
      return false;
    encoder.setDebugMarker("RendererIOS Bink synthetic YUV self-test");
    encoder.setFramebuffer(
      {{binkSelfTestTarget,OpaqueBlack,Tempest::Preserve}});
    gpuBink->encode(encoder,binkSelfTestPlanes,binkSelfTestLayout);
    if(gpuBink->encodedFrames()!=binkSelfTestEncodedFramesBefore+1u)
      throw std::runtime_error(
        "RendererIOS Bink self-test encode counter did not advance once");
    binkSelfTestSlot = slot;
    binkSelfTestSerial = serial;
    binkSelfTestState = BinkSelfTestState::EncodedPendingSubmit;
    return true;
    }

  void acceptBinkSelfTestSubmit(uint8_t slot) noexcept {
    if(binkSelfTestState!=BinkSelfTestState::EncodedPendingSubmit ||
       binkSelfTestSlot!=slot)
      return;
    binkSelfTestState = BinkSelfTestState::AwaitingGpu;
    }

  void releaseBinkSelfTestResources() noexcept {
    binkSelfTestTarget = Attachment();
    binkSelfTestPlanes = StorageBuffer();
    }

  void materializeBinkSelfTestAfterTerminal(
      FrameContext& terminalFrame, uint8_t terminalSlot,
      const char* operation) noexcept {
    if(binkSelfTestState!=BinkSelfTestState::AwaitingGpu ||
       binkSelfTestSlot!=terminalSlot ||
       !terminalFrame.submitted)
      return;
    if(failed) {
      binkSelfTestState = BinkSelfTestState::Failed;
      return;
      }

    try {
      Pixmap rgba = device.readPixels(binkSelfTestTarget);
      if(rgba.format()!=TextureFormat::RGBA8 ||
         rgba.w()!=static_cast<uint32_t>(IOSBinkSelfTestWidth) ||
         rgba.h()!=static_cast<uint32_t>(IOSBinkSelfTestHeight) ||
         rgba.dataSize()!=IOSBinkSelfTestExpectedBytes) {
        std::array<char,192> detail = {};
        std::snprintf(
          detail.data(),detail.size(),
          "unexpected readback format=%u width=%u height=%u bytes=%zu",
          unsigned(rgba.format()),unsigned(rgba.w()),unsigned(rgba.h()),
          rgba.dataSize());
        fail(operation,detail.data());
        return;
        }

      const auto validation =
        validateIOSBinkSelfTestRgba(rgba.data(),rgba.dataSize());
      if(!validation.passed) {
        std::array<char,192> detail = {};
        std::snprintf(
          detail.data(),detail.size(),
          "RGBA mismatch offset=%zu expected=%u actual=%u",
          validation.firstMismatch,
          unsigned(validation.expected),unsigned(validation.actual));
        fail(operation,detail.data());
        return;
        }

      std::array<char,17> hash = {};
      std::snprintf(
        hash.data(),hash.size(),"%016llx",
        static_cast<unsigned long long>(validation.fnv1a64));
      Log::i(
        "RendererIOS Bink self-test: PASS case=yuv420p-4x4-padded-v1",
        " fence-terminal=1 bytes=",rgba.dataSize(),
        " rgba-fnv1a64=",hash.data(),
        " slot=",uint32_t(binkSelfTestSlot),
        " serial=",binkSelfTestSerial,
        " encoded-frames-delta=",
        gpuBink->encodedFrames()-binkSelfTestEncodedFramesBefore);
      binkSelfTestState = BinkSelfTestState::Passed;
      releaseBinkSelfTestResources();
      }
    catch(const std::exception& e) {
      fail(operation,e.what());
      }
    catch(...) {
      fail(operation);
      }
    }
#endif

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
    cancelActiveFrame();
    lifecycleState = LifecycleState::Fatal;
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
    if(binkSelfTestState!=BinkSelfTestState::Passed &&
       binkSelfTestState!=BinkSelfTestState::Failed) {
      try {
        Log::e("RendererIOS Bink self-test: FAIL case=yuv420p-4x4-padded-v1",
               " operation=",operation,
               detail!=nullptr ? " detail=" : "",
               detail!=nullptr ? detail : "");
        }
      catch(...) {
        }
      binkSelfTestState = BinkSelfTestState::Failed;
      }
#endif
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
    for(auto& frame:frames) {
      frame.fence     = Fence();
      frame.submitted = false;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      frame.functionalEvidence = {};
#endif
      }
    }

  void releaseVideoFrame(FrameContext& frame) noexcept {
    frame.videoFrame  = VideoWidget::PreparedFrame();
    frame.videoSerial = 0;
    }

  void releaseVideoFrames() noexcept {
    for(auto& frame:frames)
      releaseVideoFrame(frame);
    }

  void releaseSceneFrame(FrameContext& frame) noexcept {
    if(frame.sceneFrame!=nullptr)
      ++sceneReleaseCount;
    frame.sceneFrame.reset();
    }

  void releaseSceneFrames() noexcept {
    for(auto& frame:frames)
      releaseSceneFrame(frame);
    }

  void retainSceneFrame(FrameContext& frame,
                        const IOSSceneSnapshotPtr& scene) noexcept {
    frame.sceneFrame = scene;
    ++sceneRetainCount;
    }

  void logSceneLifetime(SettleReason reason) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    try {
      const uint64_t live = uint64_t(std::count_if(
        frames.begin(),frames.end(),
        [](const FrameContext& frame) {
          return frame.sceneFrame!=nullptr;
          }));
      Log::i("RendererIOS scene lifetime: reason=",settleReasonName(reason),
             " retained=",sceneRetainCount,
             " released=",sceneReleaseCount,
             " live=",live);
      }
    catch(...) {
      }
#else
    (void)reason;
#endif
    }

  void clearPreparedUi(FrameContext& frame) noexcept {
    frame.uiPayload = {};
    }

  void discardUnsubmittedCommand(FrameContext& frame) noexcept {
    // Metal command buffers use retainedReferences=false. Once native borrowed
    // VBO/IBO handles have been encoded, an unsubmitted command must not
    // survive the scene owners that back those handles. Moving an empty wrapper
    // here synchronously destroys the native command without allocating.
    frame.command = CommandBuffer();
    frame.discardCommandAfterIdle = false;
    frame.rebuildCommand = true;
    }

  void discardAmbiguousCommandsAfterConfirmedIdle() noexcept {
    for(auto& frame:frames) {
      if(frame.discardCommandAfterIdle)
        discardUnsubmittedCommand(frame);
      }
    }

  void rebuildCommandIfDiscarded(FrameContext& frame) {
    if(!frame.rebuildCommand)
      return;
    frame.command = device.commandBuffer();
    frame.rebuildCommand = false;
    }

  void cancelActiveFrameKeepingSlotResources(FrameContext& frame) noexcept {
    // A throwing Metal commit has an ambiguous disposition: it may already be
    // enqueued even though no Fence wrapper was returned. Keep video/scene
    // resources alive until device.waitIdle() establishes the terminal point.
    if(frameActive && &frames[nextSlot]==&frame)
      clearPreparedUi(frame);
    frame.discardCommandAfterIdle = true;
    frameActive  = false;
    activeSerial = 0;
    }

  void cancelActiveFrame() noexcept {
    if(frameActive) {
      auto& frame = frames[nextSlot];
      clearPreparedUi(frame);
      releaseVideoFrame(frame);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      frame.functionalEvidence = {};
#endif
      }
    frameActive  = false;
    activeSerial = 0;
    }

  void retireSlotAfterTerminal(FrameContext& frame) noexcept {
    frame.submitted = false;
    clearPreparedUi(frame);
    releaseVideoFrame(frame);
    releaseSceneFrame(frame);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    frame.functionalEvidence = {};
#endif
    }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  bool uiSurfaceAlreadyProven(RendererIOSUISurfaceEvidence value) const noexcept {
    switch(value) {
      case RendererIOSUISurfaceEvidence::None:             return true;
      case RendererIOSUISurfaceEvidence::Inventory:        return inventoryEvidenceProven;
      case RendererIOSUISurfaceEvidence::QuickRingItems:   return quickRingItemsEvidenceProven;
      case RendererIOSUISurfaceEvidence::QuickRingWeapons: return quickRingWeaponsEvidenceProven;
      }
    return true;
    }

  bool uiSurfaceItemsAlreadyProven(
      RendererIOSUISurfaceEvidence value) const noexcept {
    switch(value) {
      case RendererIOSUISurfaceEvidence::None:
        return true;
      case RendererIOSUISurfaceEvidence::Inventory:
        return functionalEvidenceSnapshot.inventorySerial!=0u;
      case RendererIOSUISurfaceEvidence::QuickRingItems:
        return functionalEvidenceSnapshot.itemRingSerial!=0u;
      case RendererIOSUISurfaceEvidence::QuickRingWeapons:
        return functionalEvidenceSnapshot.weaponRingSerial!=0u;
      }
    return true;
    }

  void markUiSurfaceProven(RendererIOSUISurfaceEvidence value) noexcept {
    switch(value) {
      case RendererIOSUISurfaceEvidence::None:             return;
      case RendererIOSUISurfaceEvidence::Inventory:
        inventoryEvidenceProven = true;
        return;
      case RendererIOSUISurfaceEvidence::QuickRingItems:
        quickRingItemsEvidenceProven = true;
        return;
      case RendererIOSUISurfaceEvidence::QuickRingWeapons:
        quickRingWeaponsEvidenceProven = true;
        return;
      }
    }

  void emitFunctionalEvidenceAfterTerminal(FrameContext& frame,
                                           uint8_t slot) noexcept {
    auto& evidence = frame.functionalEvidence;
    if(!frame.submitted || !evidence.presentAccepted) {
      evidence = {};
      return;
      }

    const bool proveUiSurface =
      !uiSurfaceAlreadyProven(evidence.uiSurface);
    // Preserve the surface-only new-game oracle, but let a later populated
    // terminal frame independently prove real item draws for save tests.
    const bool proveUiItems = evidence.uiItemDrawCount>0u &&
                              !uiSurfaceItemsAlreadyProven(evidence.uiSurface);
    const bool proveUi = proveUiSurface || proveUiItems;
    const bool proveBink =
      (evidence.realBinkOrdinal==1u && !realBinkFirstEvidenceProven) ||
      (evidence.realBinkOrdinal==30u && !realBinkThirtyEvidenceProven);
    const bool proveResume =
      evidence.resumeCycle!=0u &&
      evidence.resumeCycle>resumeEvidenceCycleProven;
    if(!proveUi && !proveBink && !proveResume) {
      evidence = {};
      return;
      }

    try {
      Log::i("RendererIOS functional evidence: fence-terminal=1",
             " submitted=1 presented=1 slot=",uint32_t(slot),
             " serial=",evidence.serial,
             " ui=",proveUi
               ? rendererIOSUISurfaceEvidenceName(evidence.uiSurface)
               : "none",
             " ui-item-draw-count=",proveUi ? evidence.uiItemDrawCount : 0u,
             " real-bink-ordinal=",proveBink ? evidence.realBinkOrdinal : 0u,
             " resume-cycle=",proveResume ? evidence.resumeCycle : 0u);
      if(proveUiSurface)
        markUiSurfaceProven(evidence.uiSurface);
      if(proveUiItems) {
        switch(evidence.uiSurface) {
          case RendererIOSUISurfaceEvidence::None:
            break;
          case RendererIOSUISurfaceEvidence::Inventory:
            functionalEvidenceSnapshot.inventorySerial = evidence.serial;
            functionalEvidenceSnapshot.inventoryItemDrawCount =
              evidence.uiItemDrawCount;
            break;
          case RendererIOSUISurfaceEvidence::QuickRingItems:
            functionalEvidenceSnapshot.itemRingSerial = evidence.serial;
            functionalEvidenceSnapshot.itemRingItemDrawCount =
              evidence.uiItemDrawCount;
            break;
          case RendererIOSUISurfaceEvidence::QuickRingWeapons:
            functionalEvidenceSnapshot.weaponRingSerial = evidence.serial;
            functionalEvidenceSnapshot.weaponRingItemDrawCount =
              evidence.uiItemDrawCount;
            break;
          }
        }
      if(proveBink) {
        if(evidence.realBinkOrdinal==1u)
          realBinkFirstEvidenceProven = true;
        if(evidence.realBinkOrdinal==30u)
          realBinkThirtyEvidenceProven = true;
        }
      if(proveResume) {
        resumeEvidenceCycleProven = evidence.resumeCycle;
        functionalEvidenceSnapshot.resumeSerial = evidence.serial;
        functionalEvidenceSnapshot.resumeCycle  = evidence.resumeCycle;
        }
      }
    catch(...) {
      }
    evidence = {};
    }
#endif

  void stopFrameAdmission(LifecycleState state) noexcept {
    lifecycleState = state;
    cancelActiveFrame();
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    const uint64_t waitStartedUs = rendererIOSClockUs();
#endif
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    try {
      Log::i("RendererIOS GPU settle timing: reason=",settleReasonName(reason),
             " wait-idle-us=",rendererIOSClockUs()-waitStartedUs,
             " idle-confirmed=1");
      }
    catch(...) {
      }
#endif

    if(idleConfirmed!=nullptr)
      *idleConfirmed = true;

    // An exception from Metal commit has ambiguous disposition. Only after
    // waitIdle succeeds may the encoded command be destroyed; do that before
    // releasing the borrowed buffers' scene/video owners below.
    discardAmbiguousCommandsAfterConfirmedIdle();

    const bool presentHealthy = pollPresentFailure(
      "RendererIOS asynchronous Metal present failed");
    releaseRetainedPreviewAfterIdle();

    // Metal Device::waitIdle() only waits for completion. Error propagation is
    // owned by Fence::wait(), so inspect every terminal fence before releasing
    // the wrappers or claiming a clean lifecycle transition.
    for(auto& frame:frames) {
      try {
        if(!frame.fence.wait(0)) {
          neutralizeFences();
          releaseVideoFrames();
          releaseSceneFrames();
          logSceneLifetime(reason);
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
        releaseSceneFrames();
        logSceneLifetime(reason);
        forcePreviewPlaceholder();
        releaseRetainedPreviewAfterIdle();
        fail(operation,e.what());
        logFatalSettledOnce();
        return false;
        }
      catch(...) {
        neutralizeFences();
        releaseVideoFrames();
        releaseSceneFrames();
        logSceneLifetime(reason);
        forcePreviewPlaceholder();
        releaseRetainedPreviewAfterIdle();
        fail(operation);
        logFatalSettledOnce();
        return false;
        }
      }

#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
    materializeBinkSelfTestAfterTerminal(
      frames[binkSelfTestSlot],binkSelfTestSlot,
      "RendererIOS Bink self-test readback failed");
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    if(presentHealthy && !failed) {
      for(uint32_t slot=0; slot<uint32_t(frames.size()); ++slot)
        emitFunctionalEvidenceAfterTerminal(
          frames[slot],static_cast<uint8_t>(slot));
      }
#endif
    neutralizeFences();
    releaseVideoFrames();
    releaseSceneFrames();
    logSceneLifetime(reason);
    logFatalSettledOnce();
    return presentHealthy && !failed;
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
  IOSMetalResourceAllocator                    resourceAllocator;
  Swapchain                                    swapchain;

  // The P2.1a public frame ABI is neutral. VectorImage, InventoryRenderer and
  // VideoWidget remain a private transitional bridge until their data is
  // exported into renderer-owned packets later in P2.1. RendererIOS selects
  // the bridge-only shader profile so this ownership does not start the
  // legacy renderer's eager shader compilation job.
  MetalRuntimeCompilationSnapshot              runtimeBeforeLegacyShaders;
  MetalBuiltinRuntimeSnapshot                  builtinRuntimeBeforeLegacyShaders;
  Shaders                                      legacyShaders;
  MetalRuntimeCompilationSnapshot              runtimeAfterLegacyShaders;
  MetalBuiltinRuntimeSnapshot                  builtinRuntimeAfterLegacyShaders;

  std::array<FrameContext,Resources::MaxFramesInFlight> frames;
  uint64_t                                      sceneRetainCount  = 0;
  uint64_t                                      sceneReleaseCount = 0;
  FaultInjection                               fault;

  ZBuffer                                      overlayDepth;
  TextureFormat                                depthFormat = TextureFormat::Depth16;
  bool                                         depthSupported = false;
  std::unique_ptr<IOSGPUScene>                  gpuScene;
  std::unique_ptr<IOSGPUBink>                   gpuBink;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  uint64_t                                     realBinkEncodeCount = 0;
  uint64_t                                     activeResumeCycle = 0;
  uint64_t                                     resumeEvidenceCycleProven = 0;
  bool                                         realBinkFirstEvidenceProven = false;
  bool                                         realBinkThirtyEvidenceProven = false;
  bool                                         inventoryEvidenceProven = false;
  bool                                         quickRingItemsEvidenceProven = false;
  bool                                         quickRingWeaponsEvidenceProven = false;
  IOSFunctionalEvidenceSnapshot                functionalEvidenceSnapshot;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
  Attachment                                   binkSelfTestTarget;
  StorageBuffer                                binkSelfTestPlanes;
  IOSGPUBink::PlaneLayout                      binkSelfTestLayout;
  BinkSelfTestState                            binkSelfTestState =
                                                  BinkSelfTestState::Armed;
  uint64_t                                     binkSelfTestSerial = 0;
  uint64_t                                     binkSelfTestEncodedFramesBefore = 0;
  uint8_t                                      binkSelfTestSlot = 0;
#endif

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
  RendererIOSPipelineArchive::FlushState       pipelineArchiveFlush;
  SubmissionCounters                           counters;
  SubmissionCounters                           fatalCounters;
  bool                                         fatalCountersCaptured = false;
  bool                                         fatalSettledLogged = false;
  bool                                         shutdownCountsLogged = false;
  std::array<char,512>                         fatalMessage = {};
  bool                                         failed = false;
  };

IOSMetalContext::IOSMetalContext(Device& device, SystemApi::Window* window)
  : impl(std::make_unique<Impl>(device,window)) {
  }

IOSMetalContext::~IOSMetalContext() = default;

std::optional<IOSMetalContext::FrameLease> IOSMetalContext::beginFrame() {
  if(impl->lifecycleState!=Impl::LifecycleState::Active)
    return std::nullopt;
  if(!impl->pollPresentFailure("RendererIOS asynchronous Metal present failed"))
    return std::nullopt;
  if(impl->frameActive)
    throw std::logic_error("RendererIOS frame ticket is already active");

  const uint8_t slot = impl->nextSlot;
  auto& frameContext = impl->frames[slot];
  if(frameContext.discardCommandAfterIdle) {
    // An ambiguous Metal commit may still own this slot's unretained native
    // resources. Admission is forbidden until a lifecycle settle confirms
    // device idle and discards that command.
    impl->forcePreviewPlaceholder();
    impl->fail(
      "RendererIOS command buffer requires confirmed idle before reuse");
    return std::nullopt;
    }
  bool previewFenceFault = false;
  try {
    if(!frameContext.fence.wait(0))
      return std::nullopt;
    if(frameContext.submitted &&
       impl->previewState==Impl::PreviewState::AwaitingGpu &&
       impl->previewSlot==slot &&
       impl->fault.previewFenceErrorAfterTerminal()) {
      previewFenceFault = true;
      throw DeviceLostException(
        "RendererIOS diagnostics injected a terminal save-preview fence error");
      }
    if(frameContext.submitted && impl->fault.frameFenceErrorAfterTerminal())
      throw DeviceLostException("RendererIOS diagnostics injected a terminal frame-fence error");
    }
  catch(const std::exception& e) {
    // Do not retry a Metal error command buffer: Tempest maps it to device
    // lost/hang. Dropping the fence also prevents its throwing destructor.
    frameContext.fence = Fence();
    impl->retireSlotAfterTerminal(frameContext);
    impl->forcePreviewPlaceholder();
    impl->fail(previewFenceFault ? "RendererIOS Metal save-preview fence failed"
                                : "RendererIOS Metal frame fence failed",
               e.what());
    return std::nullopt;
    }
  catch(...) {
    frameContext.fence = Fence();
    impl->retireSlotAfterTerminal(frameContext);
    impl->forcePreviewPlaceholder();
    impl->fail(previewFenceFault ? "RendererIOS Metal save-preview fence failed"
                                : "RendererIOS Metal frame fence failed");
    return std::nullopt;
    }
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
  impl->materializeBinkSelfTestAfterTerminal(
    frameContext,slot,"RendererIOS Bink self-test readback failed");
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  if(!impl->failed)
    impl->emitFunctionalEvidenceAfterTerminal(frameContext,slot);
#endif
  frameContext.fence = Fence();
  impl->retireSlotAfterTerminal(frameContext);
  if(impl->failed)
    return std::nullopt;
  if(impl->previewState==Impl::PreviewState::AwaitingGpu && impl->previewSlot==slot)
    impl->materializePreviewSafely("RendererIOS save-preview materialization failed");
  if(impl->failed)
    return std::nullopt;

  try {
    impl->rebuildCommandIfDiscarded(frameContext);
    }
  catch(const std::exception& e) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS command-buffer rebuild failed",e.what());
    return std::nullopt;
    }
  catch(...) {
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS command-buffer rebuild failed");
    return std::nullopt;
    }

  Resources::resetRecycled(slot);
  impl->frameActive  = true;
  impl->activeSerial = impl->nextSerial++;
  return FrameLease{slot,impl->activeSerial};
  }

bool IOSMetalContext::frameAdmissionActive() const noexcept {
  return impl->lifecycleState==Impl::LifecycleState::Active;
  }

bool IOSMetalContext::ownsActiveFrame(const FrameLease& frame) const noexcept {
  return impl->lifecycleState==Impl::LifecycleState::Active &&
         impl->frameActive &&
         frame.serial!=0 &&
         frame.serial==impl->activeSerial &&
         frame.slot==impl->nextSlot;
  }

IOSUIPacket IOSMetalContext::prepareUi(const FrameLease& frame,
                                       const VectorImage& uiLayer,
                                       const VectorImage& numberOverlay,
                                       InventoryMenu& inventory,
                                       bool videoActive) {
  if(impl->lifecycleState!=Impl::LifecycleState::Active)
    return {};
  if(!impl->frameActive || frame.serial!=impl->activeSerial ||
     frame.slot!=impl->nextSlot)
    throw std::logic_error("RendererIOS received an invalid frame ticket for UI preparation");

  const uint8_t slot = frame.slot;
  auto& frameContext = impl->frames[slot];
  if(frameContext.uiPayload.serial!=0)
    throw std::logic_error("RendererIOS UI payload was already prepared for this frame");
  try {
    frameContext.uiMesh.update(impl->device,uiLayer);
    frameContext.numberMesh.update(impl->device,numberOverlay);
    frameContext.uiPayload = {frame.serial,&inventory,videoActive};
    return IOSUIPacket(frame.serial);
    }
  catch(const std::exception& e) {
    impl->clearPreparedUi(frameContext);
    impl->fail("RendererIOS UI frame preparation failed",e.what());
    throw;
    }
  catch(...) {
    impl->clearPreparedUi(frameContext);
    impl->fail("RendererIOS UI frame preparation failed");
    throw;
    }
  }

IOSVideoPacket IOSMetalContext::prepareVideo(const FrameLease& frame,
                                             VideoWidget& video) {
  if(impl->lifecycleState!=Impl::LifecycleState::Active)
    return {};
  if(!impl->frameActive || frame.serial!=impl->activeSerial ||
     frame.slot!=impl->nextSlot)
    throw std::logic_error("RendererIOS received an invalid frame ticket for video preparation");

  const uint8_t slot = frame.slot;
  auto& frameContext = impl->frames[slot];
  if(frameContext.videoSerial!=0)
    throw std::logic_error("RendererIOS video payload was already prepared for this frame");
  try {
    frameContext.videoFrame = video.prepareFrame(impl->device,slot);
    frameContext.videoSerial = frame.serial;
    return IOSVideoPacket(frame.serial);
    }
  catch(const std::exception& e) {
    impl->releaseVideoFrame(frameContext);
    impl->fail("RendererIOS video frame preparation failed",e.what());
    throw;
    }
  catch(...) {
    impl->releaseVideoFrame(frameContext);
    impl->fail("RendererIOS video frame preparation failed");
    throw;
    }
  }

IOSMetalContext::SubmitResult IOSMetalContext::submitFrame(
    const FrameLease& frame, const IOSFrameInput& input,
    const IOSSceneAssetRegistry& assets,
    void* completion, CompleteFrame completeFrame) {
  if(completeFrame==nullptr)
    throw std::logic_error("RendererIOS received an empty frame completion");
  if(impl->lifecycleState!=Impl::LifecycleState::Active) {
    cancelFrame(frame.serial);
    (void)completeFrame(completion,false);
    return {};
    }
  if(!impl->frameActive || frame.serial!=impl->activeSerial ||
     frame.slot!=impl->nextSlot)
    throw std::logic_error("RendererIOS received an invalid frame ticket");

  const uint8_t slot = frame.slot;
  auto& frameContext = impl->frames[slot];
  if(!impl->pollPresentFailure("RendererIOS asynchronous Metal present failed")) {
    cancelFrame(frame.serial);
    (void)completeFrame(completion,false);
    return {};
    }

  const auto abandonFrame = [&]() noexcept {
    cancelFrame(frame.serial);
    (void)completeFrame(completion,false);
    };
  const auto abandonFrameKeepingSlotResources = [&]() noexcept {
    impl->cancelActiveFrameKeepingSlotResources(frameContext);
    (void)completeFrame(completion,false);
    };

  InventoryMenu* inventoryOwner = nullptr;
  bool           videoActive    = false;
  try {
    if(input.transportSerial!=frame.serial ||
       input.snapshot==nullptr ||
       !input.snapshot->readyForSubmit())
      throw std::logic_error("RendererIOS received an invalid scene snapshot");
    if(frameContext.sceneFrame!=nullptr)
      throw std::logic_error("RendererIOS scene slot was not retired before reuse");
    if(input.ui.transportSerial!=frame.serial)
      throw std::logic_error("RendererIOS received an invalid UI packet");

    const auto uiPayload = frameContext.uiPayload;
    if(uiPayload.serial!=frame.serial || uiPayload.inventory==nullptr)
      throw std::logic_error("RendererIOS UI packet has no matching prepared payload");
    if(uiPayload.videoActive) {
      if(input.video.transportSerial!=frame.serial ||
         frameContext.videoSerial!=frame.serial)
        throw std::logic_error("RendererIOS video packet has no matching prepared payload");
      }
    else if(input.video.transportSerial!=0 || frameContext.videoSerial!=0) {
      throw std::logic_error("RendererIOS received video payload for a non-video frame");
      }

    // The only borrowed UI owner is copied to this synchronous scope and
    // removed from context state before encoding. It cannot cross submit.
    inventoryOwner = uiPayload.inventory;
    videoActive    = uiPayload.videoActive;
    impl->clearPreparedUi(frameContext);
    }
  catch(...) {
    abandonFrame();
    throw;
    }
  InventoryMenu& inventory = *inventoryOwner;

  // Retain before encoding so the post-submit commit contains no allocation.
  // Pre-submit failures release this slot in the catch paths below.
  impl->retainSceneFrame(frameContext,input.snapshot);

  bool previewAccepted = false;
  bool previewFallback = false;
  bool submissionAttempted = false;

  try {
    if(input.capture.kind==IOSCaptureRequest::Kind::SavePreview &&
       impl->previewState==Impl::PreviewState::Idle) {
      previewAccepted = true;
      if(!configuredSavePreviewNeedsGpuCapture() ||
         impl->fault.previewAttachmentMissing()) {
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

#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
    impl->prepareBinkSelfTest();
#endif
    auto& command = frameContext.command;
    {
      auto encoder = command.startEncoding(impl->device);
      if(frameContext.videoFrame) {
        if(impl->gpuBink==nullptr)
          throw std::runtime_error(
              "RendererIOS native Bink pipeline is unavailable");
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        const uint64_t encodedFramesBefore = impl->gpuBink->encodedFrames();
#endif
        VideoWidget::encodePrepared(
            encoder,slot,frameContext.videoFrame,*impl->gpuBink);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        const uint64_t encodedFramesAfter = impl->gpuBink->encodedFrames();
        if(encodedFramesAfter==encodedFramesBefore+1u) {
          ++impl->realBinkEncodeCount;
          if(impl->realBinkEncodeCount==1u ||
             impl->realBinkEncodeCount==30u) {
            frameContext.functionalEvidence.realBinkOrdinal =
              impl->realBinkEncodeCount;
            }
          }
#endif
        }
      auto& drawable = impl->swapchain[impl->swapchain.currentImage()];

      const bool sceneVisible = !videoActive &&
        std::any_of(input.snapshot->entities.begin(),
                    input.snapshot->entities.end(),
                    [](const IOSRenderEntity& entity) {
                      return (entity.visibilityMask&
                              IOSSceneVisibilityMain)!=0;
                    });
      if(sceneVisible) {
        if(impl->overlayDepth.isEmpty())
          throw std::runtime_error(
            "RendererIOS native Landscape pass has no depth attachment");
        encoder.setDebugMarker("RendererIOS native Landscape");
        encoder.setFramebuffer(
          {{drawable,OpaqueBlack,Tempest::Preserve}},
          {impl->overlayDepth,1.f,Tempest::Preserve});
        const auto report =
          impl->gpuScene->encode(encoder,*input.snapshot,assets);
        if(report.result!=IOSGPUScene::Result::Success) {
          throw std::runtime_error(
            std::string("RendererIOS native Landscape encode failed: ")+
            iosGPUSceneResultName(report.result)+
            " handle="+std::to_string(report.failingHandle));
          }
        if(report.drawCount==0u ||
           report.texturedDrawCount!=report.drawCount) {
          throw std::runtime_error(
            std::string(
              "RendererIOS native Landscape texture coverage failed: draws=")+
            std::to_string(report.drawCount)+
            " textured="+std::to_string(report.texturedDrawCount));
          }
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        if(input.snapshot->sequence.value==1u ||
           input.snapshot->sequence.value%300u==0u) {
          Log::d("RendererIOS native Landscape: generation=",
                 input.snapshot->generation.value,
                 " sequence=",input.snapshot->sequence.value,
                 " draws=",uint64_t(report.drawCount),
                 " textured=",uint64_t(report.texturedDrawCount));
          }
#endif
        encoder.setDebugMarker("RendererIOS UI over native Landscape");
        encoder.setFramebuffer(
          {{drawable,Tempest::Preserve,Tempest::Preserve}});
        }
      else {
        encoder.setDebugMarker("RendererIOS shell clear/UI");
        encoder.setFramebuffer(
          {{drawable,OpaqueBlack,Tempest::Preserve}});
      }
      frameContext.uiMesh.draw(encoder);

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      const RendererIOSUISurfaceEvidence uiSurface =
        videoActive ? RendererIOSUISurfaceEvidence::None
                    : inventory.itemRenderer().rendererIOSUISurface();
      uint64_t uiItemDrawCount = 0;
#endif

      const bool inventoryMenuVisible =
        inventory.isOpen()!=InventoryMenu::State::Closed;
      const bool ringIcons = !videoActive && inventory.itemRenderer().hasItems();
      const bool inventoryVisible = inventoryMenuVisible || ringIcons;
      if(inventoryVisible) {
        if(!impl->overlayDepth.isEmpty()) {
          encoder.setDebugMarker("RendererIOS bootstrap inventory");
          encoder.setFramebuffer({{drawable,Tempest::Preserve,Tempest::Preserve}},
                                 {impl->overlayDepth,1.f,Tempest::Preserve});
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
          uiItemDrawCount = inventory.draw(encoder);
#else
          inventory.draw(encoder);
#endif
          }

        encoder.setDebugMarker("RendererIOS bootstrap inventory counters");
        encoder.setFramebuffer({{drawable,Tempest::Preserve,Tempest::Preserve}});
        frameContext.numberMesh.draw(encoder);
        }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      if(uiSurface!=RendererIOSUISurfaceEvidence::None &&
         (!impl->uiSurfaceAlreadyProven(uiSurface) ||
          (uiItemDrawCount>0u &&
           !impl->uiSurfaceItemsAlreadyProven(uiSurface)))) {
        frameContext.functionalEvidence.uiSurface = uiSurface;
        frameContext.functionalEvidence.uiItemDrawCount = uiItemDrawCount;
        }
#endif

      if(previewAccepted && !previewFallback) {
        encoder.setDebugMarker("RendererIOS save preview diagnostic capture");
        encoder.setFramebuffer({{impl->savePreview,OpaqueBlack,Tempest::Preserve}});
        }
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
      (void)impl->encodeBinkSelfTest(encoder,slot,frame.serial);
#endif
      }

    ++impl->counters.submitAttempts;
    submissionAttempted = true;
    Fence submittedFence = impl->device.submit(command);
    frameContext.fence = std::move(submittedFence);
    frameContext.submitted = true;
    ++impl->counters.submitAccepted;
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
    impl->acceptBinkSelfTestSubmit(slot);
#endif

    // Submission consumes the ticket and commits temporal history even if
    // drawable presentation subsequently reports SwapchainSuboptimal. Every
    // operation in this block is noexcept and the slot owns all keep-alives.
    impl->frameActive  = false;
    impl->activeSerial = 0;
    if(!completeFrame(completion,true)) {
      impl->fail("RendererIOS accepted frame could not commit scene history");
      return {};
      }

    if(impl->fault.postSubmitSuboptimal())
      throw SwapchainSuboptimal();
    ++impl->counters.presentAttempts;
    impl->device.present(impl->swapchain);
    ++impl->counters.presentAccepted;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    frameContext.functionalEvidence.serial = frame.serial;
    frameContext.functionalEvidence.presentAccepted = true;
    if(impl->activeResumeCycle>impl->resumeEvidenceCycleProven)
      frameContext.functionalEvidence.resumeCycle = impl->activeResumeCycle;
#endif
    impl->flushPipelineArchiveAfterPresent(
      impl->counters.presentAccepted);

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
    impl->logRuntimeCompilationFrame(impl->counters.presentAccepted);
#endif

    (void)impl->pollPresentFailure(
      "RendererIOS asynchronous Metal present failed");

    return SubmitResult{previewAccepted};
    }
  catch(const SwapchainSuboptimal&) {
    // Drawable replacement is a recoverable surface lifecycle event. The
    // submitted frame, if any, is settled by resize() before targets are reused.
    if(!frameContext.submitted) {
      if(submissionAttempted) {
        abandonFrameKeepingSlotResources();
        }
      else {
        impl->discardUnsubmittedCommand(frameContext);
        impl->releaseSceneFrame(frameContext);
        abandonFrame();
        }
      }
    throw;
    }
  catch(const std::exception& e) {
    if(!frameContext.submitted) {
      if(submissionAttempted) {
        abandonFrameKeepingSlotResources();
        }
      else {
        impl->discardUnsubmittedCommand(frameContext);
        impl->releaseSceneFrame(frameContext);
        abandonFrame();
        }
      }
    impl->forcePreviewPlaceholder();
    if(impl->pollPresentFailure("RendererIOS asynchronous Metal present failed"))
      impl->fail("RendererIOS frame submission failed",e.what());
    throw;
    }
  catch(...) {
    if(!frameContext.submitted) {
      if(submissionAttempted) {
        abandonFrameKeepingSlotResources();
        }
      else {
        impl->discardUnsubmittedCommand(frameContext);
        impl->releaseSceneFrame(frameContext);
        abandonFrame();
        }
      }
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS frame submission failed");
    throw;
    }
  }

Size IOSMetalContext::drawableSize() const {
  return Size(static_cast<int>(impl->swapchain.w()),static_cast<int>(impl->swapchain.h()));
  }

bool IOSMetalContext::pollDeviceFailure() noexcept {
  return impl->pollPresentFailure(
    "RendererIOS asynchronous Metal present failed");
  }

std::string_view IOSMetalContext::failureReason() const noexcept {
  return impl->failed ? std::string_view(impl->fatalMessage.data()) : std::string_view();
  }

void IOSMetalContext::resize() {
  if(impl->lifecycleState!=Impl::LifecycleState::Active)
    return;
  impl->cancelActiveFrame();
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    impl->logLifecycleCounts("resize-settled",true);
#endif
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

bool IOSMetalContext::suspend() noexcept {
  if(impl->lifecycleState==Impl::LifecycleState::Stopped)
    return false;
  if(impl->lifecycleState==Impl::LifecycleState::Active) {
    impl->lifecycleState = Impl::LifecycleState::Suspended;
    }

  impl->cancelActiveFrame();

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

bool IOSMetalContext::resume() noexcept {
  if(impl->failed || impl->lifecycleState==Impl::LifecycleState::Fatal ||
     impl->lifecycleState==Impl::LifecycleState::Stopped)
    return false;
  if(impl->lifecycleState==Impl::LifecycleState::Active) {
    impl->lifecycleState = Impl::LifecycleState::Suspended;
    }

  impl->cancelActiveFrame();

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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    ++impl->activeResumeCycle;
#endif
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

bool IOSMetalContext::waitIdle() noexcept {
  impl->cancelActiveFrame();
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

void IOSMetalContext::shutdown() noexcept {
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

void IOSMetalContext::prepareForOwnerRelease() noexcept {
  impl->cancelActiveFrame();
  if(!impl->confirmGpuIdle(SettleReason::OwnerRelease,
                           "RendererIOS owner-release GPU settle failed"))
    impl->terminateWithoutTeardown(
      "RendererIOS owner release could not confirm device idle after three attempts");
  impl->materializePreviewSafely("RendererIOS owner-release preview finalization failed");
  impl->logFatalSettledOnce();
  }

void IOSMetalContext::onWorldChanged() {
  prepareForOwnerRelease();
  if(impl->failed || impl->lifecycleState==Impl::LifecycleState::Stopped)
    return;
  impl->frameActive  = false;
  impl->activeSerial = 0;
  impl->nextSlot     = 0;
  try {
    for(auto& frame:impl->frames) {
      frame.command = impl->device.commandBuffer();
      frame.discardCommandAfterIdle = false;
      frame.rebuildCommand = false;
      }
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

bool IOSMetalContext::savePreviewReady() {
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
  auto& frameContext = impl->frames[impl->previewSlot];
  try {
    if(!frameContext.fence.wait(0))
      return false;
    if(frameContext.submitted &&
       impl->fault.previewFenceErrorAfterTerminal())
      throw DeviceLostException(
        "RendererIOS diagnostics injected a terminal save-preview fence error");
    impl->materializePreviewSafely("RendererIOS save-preview materialization failed");
    return impl->previewState==Impl::PreviewState::ReadyCpu ||
           impl->previewState==Impl::PreviewState::ReadyPlaceholder;
    }
  catch(const std::exception& e) {
    frameContext.fence = Fence();
    impl->retireSlotAfterTerminal(frameContext);
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS Metal save-preview fence failed",e.what());
    return true;
    }
  catch(...) {
    frameContext.fence = Fence();
    impl->retireSlotAfterTerminal(frameContext);
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS Metal save-preview fence failed");
    return true;
    }
  }

bool IOSMetalContext::requiresGpuSavePreviewCapture() const noexcept {
  return configuredSavePreviewNeedsGpuCapture();
  }

bool IOSMetalContext::savePreviewIsPlaceholder() const noexcept {
  return impl->previewState==Impl::PreviewState::ReadyPlaceholder;
  }

Pixmap IOSMetalContext::takeSavePreview() {
  if(impl->previewState==Impl::PreviewState::ReadyCpu) {
    Pixmap result = std::move(impl->completedPreview);
    impl->clearPreview();
    return result;
    }
  if(impl->previewState==Impl::PreviewState::ReadyPlaceholder) {
    impl->clearPreview();
    return blackPixmap(IOSSavePreviewPlaceholderWidth,
                       IOSSavePreviewPlaceholderHeight);
    }
  throw std::logic_error("RendererIOS save preview is not ready");
  }

Pixmap IOSMetalContext::screenshot() {
  const uint32_t w = std::max(impl->swapchain.w(),1u);
  const uint32_t h = std::max(impl->swapchain.h(),1u);
  return blackPixmap(w,h);
  }

void IOSMetalContext::dbgDraw(Painter& painter) {
  (void)painter;
  }

bool IOSMetalContext::ssaoBuffersAllocated() const noexcept {
  return false;
  }

#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
IOSFunctionalEvidenceSnapshot
IOSMetalContext::functionalEvidenceSnapshot() const noexcept {
  return impl->functionalEvidenceSnapshot;
  }
#endif

void IOSMetalContext::cancelFrame(uint64_t serial) noexcept {
  if(!impl || !impl->frameActive || impl->activeSerial!=serial)
    return;
  impl->cancelActiveFrame();
  }

std::size_t IOSMetalContext::retainedSceneCount() const noexcept {
  return std::size_t(std::count_if(impl->frames.begin(),impl->frames.end(),
    [](const Impl::FrameContext& frame) {
      return frame.sceneFrame!=nullptr;
      }));
  }
