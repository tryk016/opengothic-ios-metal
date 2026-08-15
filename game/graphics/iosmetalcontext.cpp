#include "iosmetalcontext.h"

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
#define OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE 1
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
#define OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL 1
#endif

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
#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
#include <atomic>
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#include <chrono>
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
#include <crt_externs.h>
#endif
#include <CommonCrypto/CommonDigest.h>
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
#include <cerrno>
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

#include "iosgpuscene.h"
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
#include "iosmultiply2inputartifact.h"
#include "iosmultiply2coverageproof.h"
#else
#include "iosadditiveinputartifact.h"
#endif
#endif
#include "iosgpubink.h"
#include "iosdevicefactscollector.h"
#include "iosfeaturepolicyprovenance.h"
#include "ioslinearhdr.h"
#include "ioslinearhdrmetal.h"
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#include "ioslinearhdrproofproducer.h"
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
#include "iosbinkselftest.h"
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
#include "iosmetalcapturesession.h"
#endif
#include "iosmetalresourceallocator.h"
#include "iosmetalresourceclearpassprobe.h"
#include "iospipelinearchivepolicy.h"
#include "iossavepreviewpolicy.h"
#include "iossceneassetregistry.h"
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
#include "iosshadingprototypeforwardpipeline.h"
#include "iosshadingprototypeforwardprobe.h"
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
#include "iosshadingprototypepipeline.h"
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
#include "iosshadingprototypeplan.h"
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
#include "iosshadingprototypetileprobe.h"
#endif
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

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) && \
    !defined(__IOS__)
#error "RendererIOS shading prototype Forward self-test requires iOS"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) && \
    !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "RendererIOS shading prototype Forward self-test requires diagnostics"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) && \
    OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 0
#error "RendererIOS shading prototype Forward self-test requires fault mode none"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) && \
    (defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST))
#error "RendererIOS shading prototype Forward and other self-tests are mutually exclusive"
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

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) && !defined(__IOS__)
#error "RendererIOS clear-only pass self-test requires iOS"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) && !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "RendererIOS clear-only pass self-test requires diagnostics"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) && OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 0
#error "RendererIOS clear-only pass self-test requires fault mode none"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) && \
    (defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST))
#error "RendererIOS clear-only pass, resource allocator and Bink self-tests are mutually exclusive"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) && \
    !defined(__IOS__)
#error "RendererIOS shading prototype Tile self-test requires iOS"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE) && \
    !defined(__IOS__)
#error "RendererIOS linear HDR GPU triple capture requires iOS"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE) && \
    !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "RendererIOS linear HDR GPU triple capture requires diagnostics"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE) && \
    OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 0
#error "RendererIOS linear HDR GPU triple capture requires fault mode none"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE) && \
    (defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
     defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B))
#error "RendererIOS linear HDR GPU triple capture requires the exact isolated tuple"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
constexpr char RendererIOSLinearHDRCaptureProfileEvidence[] =
  "RendererIOS HDR capture profile: v=1 mode=one-shot";
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) && \
    !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "RendererIOS shading prototype Tile self-test requires diagnostics"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) && \
    OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 0
#error "RendererIOS shading prototype Tile self-test requires fault mode none"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST) && \
    (defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST) || \
     defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST))
#error "RendererIOS shading prototype Tile and other self-tests are mutually exclusive"
#endif

namespace {

#if !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
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
#endif

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

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
constexpr char RendererIOSClearOnlyPassSelfTestArmed[] =
  "\x01RendererIOS clear-only pass self-test: ARMED case=pm-clear-v1 abi=4 resources=3 logical-passes=3 private=1 memoryless=1";
constexpr char RendererIOSClearOnlyPassSelfTestEncoded[] =
  "\x01RendererIOS clear-only pass self-test: ENCODED case=pm-clear-v1 physical-passes=2 command-buffers=1 render-encoders=2 private-load=clear private-store=store memoryless-load=clear memoryless-store=dont-care draws=0 pipelines=0 drawable=0 present=0";
constexpr char RendererIOSClearOnlyPassSelfTestSubmitted[] =
  "\x01RendererIOS clear-only pass self-test: SUBMITTED case=pm-clear-v1 command-buffers=1 submits=1";
constexpr char RendererIOSClearOnlyPassSelfTestPassed[] =
  "\x01RendererIOS clear-only pass self-test: PASS case=pm-clear-v1 terminal=completed created=2 live=0 released=2 wait-idle=0";
constexpr char RendererIOSClearOnlyCaptureAcquired[] =
  "\x01RendererIOS clear-only capture: ACQUIRED";

const char* rendererIOSClearOnlyPassMarkerText(const char* storage) noexcept {
  // The volatile load makes the non-printable leading byte part of the
  // observable object. It prevents Mach-O/link layout from joining an exact
  // marker to a preceding printable byte while the runtime log starts after
  // the sentinel and remains byte-for-byte unchanged.
  const volatile char* const observableStorage = storage;
  (void)*observableStorage;
  return storage+1u;
  }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
constexpr char RendererIOSShadingPrototypeTileSelfTestArmed[] =
  "\x01RendererIOS shading prototype tile self-test: ARMED case=tile-prototype-v1 contract=1 metallib-abi=9 minimum-apple=4 output=4x4 rgba8-private=1";
constexpr char RendererIOSShadingPrototypeTileSelfTestFactoryReady[] =
  "\x01RendererIOS shading prototype tile self-test: FACTORY READY case=tile-prototype-v1 pipelines=3 forward=0 runtime-delta=0 builtin-delta=0 archive-delta=0";
constexpr char RendererIOSShadingPrototypeTileSelfTestEncoded[] =
  "\x01RendererIOS shading prototype tile self-test: ENCODED case=tile-prototype-v1 pass=1 encoder=1 draws=2 opaque=1 alpha=1 tdispatch=1 vb=168 output=1 mat=0 ib=4 clear-a=0 tgmem=0 size=16 dispatch=16x16x1 order=opaque,alpha,tile drawable=0 present=0";
constexpr char RendererIOSShadingPrototypeTileSelfTestSubmitted[] =
  "\x01RendererIOS shading prototype tile self-test: SUBMITTED case=tile-prototype-v1 command-buffers=1 submits=1";
constexpr char RendererIOSShadingPrototypeTileSelfTestPassed[] =
  "\x01RendererIOS shading prototype tile self-test: PASS case=tile-prototype-v1 terminal=completed created=1 live=0 released=1 wait-idle=0 runtime-delta=0 builtin-delta=0 archive-delta=0";
constexpr char RendererIOSShadingPrototypeTileSelfTestUnsupported[] =
  "\x01RendererIOS shading prototype tile self-test: UNSUPPORTED case=tile-prototype-v1 reason=apple4-required side-effects=0";
constexpr char RendererIOSShadingPrototypeTileCaptureAcquired[] =
  "\x01RendererIOS shading prototype tile capture: ACQUIRED";
constexpr char RendererIOSShadingPrototypeTileCaptureName[] =
  "RendererIOS-tile-prototype-v1.gputrace";

static_assert(sizeof(RendererIOSShadingPrototypeTileSelfTestEncoded)-2u==245u);

const char* rendererIOSShadingPrototypeTileMarkerText(
    const char* storage) noexcept {
  const volatile char* const observableStorage = storage;
  (void)*observableStorage;
  return storage+1u;
  }

struct RendererIOSShadingPrototypeTileIsolationSnapshot final {
  MetalRuntimeCompilationSnapshot runtime;
  MetalBuiltinRuntimeSnapshot builtin;
  MetalPipelineArchiveSnapshot archive;
  };

bool rendererIOSShadingPrototypeTileArchiveEqual(
    const MetalPipelineArchiveSnapshot& lhs,
    const MetalPipelineArchiveSnapshot& rhs) noexcept {
  return lhs.abiVersion==rhs.abiVersion &&
         lhs.structSize==rhs.structSize &&
         lhs.flags==rhs.flags &&
         lhs.reserved==rhs.reserved &&
         lhs.loadFailures==rhs.loadFailures &&
         lhs.rebuilds==rhs.rebuilds &&
         lhs.renderHits==rhs.renderHits &&
         lhs.renderMisses==rhs.renderMisses &&
         lhs.renderAdds==rhs.renderAdds &&
         lhs.renderFallbacks==rhs.renderFallbacks &&
         lhs.computeHits==rhs.computeHits &&
         lhs.computeMisses==rhs.computeMisses &&
         lhs.computeAdds==rhs.computeAdds &&
         lhs.computeFallbacks==rhs.computeFallbacks &&
         lhs.flushAttempts==rhs.flushAttempts &&
         lhs.flushSuccesses==rhs.flushSuccesses &&
         lhs.flushFailures==rhs.flushFailures;
  }

bool rendererIOSShadingPrototypeTileIsolationSnapshotAvailable(
    const RendererIOSShadingPrototypeTileIsolationSnapshot& snapshot)
    noexcept {
  return snapshot.runtime.available && snapshot.builtin.available &&
         snapshot.archive.abiVersion==
             MetalPipelineArchiveSnapshot::AbiVersion &&
         snapshot.archive.structSize==
             MetalPipelineArchiveSnapshot::StructSize;
  }

bool rendererIOSShadingPrototypeTileIsolationSnapshotEqual(
    const RendererIOSShadingPrototypeTileIsolationSnapshot& lhs,
    const RendererIOSShadingPrototypeTileIsolationSnapshot& rhs)
    noexcept {
  return lhs.runtime.available==rhs.runtime.available &&
         lhs.runtime.sourceLibraryRequests==
             rhs.runtime.sourceLibraryRequests &&
         lhs.runtime.computePsoRequests==
             rhs.runtime.computePsoRequests &&
         lhs.runtime.renderPsoRequests==
             rhs.runtime.renderPsoRequests &&
         lhs.builtin.available==rhs.builtin.available &&
         lhs.builtin.sourceLibraryRequests==
             rhs.builtin.sourceLibraryRequests &&
         lhs.builtin.renderPsoRequests==
             rhs.builtin.renderPsoRequests &&
         rendererIOSShadingPrototypeTileArchiveEqual(
             lhs.archive,rhs.archive);
  }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
constexpr char RendererIOSShadingPrototypeForwardSelfTestArmed[] =
  "\x01RendererIOS shading prototype forward self-test: ARMED case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardSelfTestFactoryReady[] =
  "\x01RendererIOS shading prototype forward self-test: FACTORY READY case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardSelfTestEncoded[] =
  "\x01RendererIOS shading prototype forward self-test: ENCODED case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardSelfTestSubmitted[] =
  "\x01RendererIOS shading prototype forward self-test: SUBMITTED case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardSelfTestTerminal[] =
  "\x01RendererIOS shading prototype forward self-test: TERMINAL case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardSelfTestReadback[] =
  "\x01RendererIOS shading prototype forward self-test: READBACK case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardSelfTestPassed[] =
  "\x01RendererIOS shading prototype forward self-test: PASS case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardSelfTestUnsupported[] =
  "\x01RendererIOS shading prototype forward self-test: UNSUPPORTED case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardSelfTestFailed[] =
  "\x01RendererIOS shading prototype forward self-test: FAIL case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardCaptureAcquired[] =
  "\x01RendererIOS shading prototype forward capture: ACQUIRED case=forward-prototype-v1 nonce=";
constexpr char RendererIOSShadingPrototypeForwardCaptureName[] =
  "RendererIOS-forward-prototype-v1.gputrace";
constexpr char RendererIOSShadingPrototypeForwardNonceArgument[] =
  "\x01-renderer-ios-forward-self-test-nonce=";
static_assert(
    sizeof(RendererIOSShadingPrototypeForwardNonceArgument)-2u==38u);
static_assert(RendererIOSShadingPrototypeForwardNonceArgument[0]=='\x01');
static_assert(
    RendererIOSShadingPrototypeForwardNonceArgument[
        sizeof(RendererIOSShadingPrototypeForwardNonceArgument)-2u]=='=');
constexpr std::string_view
    RendererIOSShadingPrototypeForwardExpectedReadbackSHA256 =
        "d577b6dfa736657f93c3223b466c256c988d5eb5f02cc27ad47f92c1406f7dd2";

static_assert(
    sizeof(RendererIOSShadingPrototypeForwardSelfTestEncoded)-2u+
        32u+sizeof(
          " cb=1 compute=1 render=1 dispatch=1 draws=2 opaque=1 alpha=1 output=4x4 light-list=256 drawable=0 present=0")-1u <
        250u);

const char* rendererIOSShadingPrototypeForwardMarkerText(
    const char* storage) noexcept {
  const volatile char* const observableStorage = storage;
  (void)*observableStorage;
  return storage+1u;
  }

bool rendererIOSShadingPrototypeForwardReadNonce(
    std::array<char,33u>& result,
    const char*& reason) noexcept {
  result.fill('\0');
  reason = "nonce-missing";
  const int* const argc = _NSGetArgc();
  char*** const argv = _NSGetArgv();
  if(argc==nullptr || argv==nullptr || *argv==nullptr)
    return false;

  const std::string_view nonceArgument(
      rendererIOSShadingPrototypeForwardMarkerText(
          RendererIOSShadingPrototypeForwardNonceArgument),
      sizeof(RendererIOSShadingPrototypeForwardNonceArgument)-2u);
  uint32_t matches = 0u;
  for(int index=1; index<*argc; ++index) {
    const char* const raw = (*argv)[index];
    if(raw==nullptr)
      continue;
    const std::string_view argument(raw);
    constexpr std::string_view name =
        "-renderer-ios-forward-self-test-nonce";
    if(!argument.starts_with(name))
      continue;
    ++matches;
    if(matches!=1u ||
       !argument.starts_with(nonceArgument)) {
      reason = matches>1u ? "nonce-duplicate" : "nonce-malformed";
      continue;
      }
    const std::string_view nonce = argument.substr(
        nonceArgument.size());
    const bool valid = nonce.size()==32u &&
        std::all_of(nonce.begin(),nonce.end(),[](char value) noexcept {
          return (value>='0' && value<='9') ||
                 (value>='a' && value<='f');
          });
    if(!valid) {
      reason = "nonce-malformed";
      continue;
      }
    std::memcpy(result.data(),nonce.data(),nonce.size());
    }
  if(matches!=1u || result[0]=='\0') {
    if(matches>1u)
      reason = "nonce-duplicate";
    return false;
    }
  reason = nullptr;
  return true;
  }

std::array<char,CC_SHA256_DIGEST_LENGTH*2u+1u>
    rendererIOSShadingPrototypeForwardReadbackSHA256(
    const std::array<
        uint32_t,
        RendererIOSShadingPrototypeShader::
            ForwardLightListWordCount>& words) noexcept {
  std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> digest{};
  std::array<char,CC_SHA256_DIGEST_LENGTH*2u+1u> hex{};
  (void)CC_SHA256(
      words.data(),static_cast<CC_LONG>(sizeof(words)),digest.data());
  constexpr char digits[] = "0123456789abcdef";
  for(std::size_t index=0u; index<digest.size(); ++index) {
    hex[index*2u] = digits[digest[index]>>4u];
    hex[index*2u+1u] = digits[digest[index]&0x0fu];
    }
  return hex;
  }

struct RendererIOSShadingPrototypeForwardIsolationSnapshot final {
  MetalRuntimeCompilationSnapshot runtime;
  MetalBuiltinRuntimeSnapshot builtin;
  MetalPipelineArchiveSnapshot archive;
  };

bool rendererIOSShadingPrototypeForwardArchiveEqual(
    const MetalPipelineArchiveSnapshot& lhs,
    const MetalPipelineArchiveSnapshot& rhs) noexcept {
  return lhs.abiVersion==rhs.abiVersion &&
         lhs.structSize==rhs.structSize &&
         lhs.flags==rhs.flags &&
         lhs.reserved==rhs.reserved &&
         lhs.loadFailures==rhs.loadFailures &&
         lhs.rebuilds==rhs.rebuilds &&
         lhs.renderHits==rhs.renderHits &&
         lhs.renderMisses==rhs.renderMisses &&
         lhs.renderAdds==rhs.renderAdds &&
         lhs.renderFallbacks==rhs.renderFallbacks &&
         lhs.computeHits==rhs.computeHits &&
         lhs.computeMisses==rhs.computeMisses &&
         lhs.computeAdds==rhs.computeAdds &&
         lhs.computeFallbacks==rhs.computeFallbacks &&
         lhs.flushAttempts==rhs.flushAttempts &&
         lhs.flushSuccesses==rhs.flushSuccesses &&
         lhs.flushFailures==rhs.flushFailures;
  }

bool rendererIOSShadingPrototypeForwardIsolationSnapshotAvailable(
    const RendererIOSShadingPrototypeForwardIsolationSnapshot& snapshot)
    noexcept {
  return snapshot.runtime.available && snapshot.builtin.available &&
         snapshot.archive.abiVersion==
             MetalPipelineArchiveSnapshot::AbiVersion &&
         snapshot.archive.structSize==
             MetalPipelineArchiveSnapshot::StructSize;
  }

bool rendererIOSShadingPrototypeForwardIsolationSnapshotEqual(
    const RendererIOSShadingPrototypeForwardIsolationSnapshot& lhs,
    const RendererIOSShadingPrototypeForwardIsolationSnapshot& rhs)
    noexcept {
  return lhs.runtime.available==rhs.runtime.available &&
         lhs.runtime.sourceLibraryRequests==
             rhs.runtime.sourceLibraryRequests &&
         lhs.runtime.computePsoRequests==
             rhs.runtime.computePsoRequests &&
         lhs.runtime.renderPsoRequests==
             rhs.runtime.renderPsoRequests &&
         lhs.builtin.available==rhs.builtin.available &&
         lhs.builtin.sourceLibraryRequests==
             rhs.builtin.sourceLibraryRequests &&
         lhs.builtin.renderPsoRequests==
             rhs.builtin.renderPsoRequests &&
         rendererIOSShadingPrototypeForwardArchiveEqual(
             lhs.archive,rhs.archive);
  }

template<class T>
uint64_t rendererIOSShadingPrototypeForwardMismatchBit(
    const T& actual, const T& expected, uint32_t bit) noexcept {
  return actual==expected ? 0u : uint64_t(1u)<<bit;
  }

uint64_t rendererIOSShadingPrototypeForwardFunctionMismatchMask(
    const IOSShadingPrototypeForwardFunctionReport& actual,
    const IOSShadingPrototypeForwardFunctionReport& expected)
    noexcept {
  uint64_t mask = 0u;
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.available,expected.available,0u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.nameMatches,expected.nameMatches,1u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.sameDevice,expected.sameDevice,2u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.stage,expected.stage,3u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.functionConstantCount,
      expected.functionConstantCount,4u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaTest.available,
      expected.alphaTest.available,5u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaTest.nameMatches,
      expected.alphaTest.nameMatches,6u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaTest.indexMatches,
      expected.alphaTest.indexMatches,7u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaTest.boolType,
      expected.alphaTest.boolType,8u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaTest.required,
      expected.alphaTest.required,9u);
  return mask;
  }

uint64_t rendererIOSShadingPrototypeForwardSpecializationMismatchMask(
    const IOSShadingPrototypeForwardSpecializationReport& actual,
    const IOSShadingPrototypeForwardSpecializationReport& expected)
    noexcept {
  uint64_t mask = 0u;
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.available,expected.available,0u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.nameMatches,expected.nameMatches,1u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.sameDevice,expected.sameDevice,2u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.stage,expected.stage,3u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaTestEnabled,expected.alphaTestEnabled,4u);
  return mask;
  }

uint64_t rendererIOSShadingPrototypeForwardBindingMismatchMask(
    const IOSShadingPrototypeForwardBindingListReport& actual,
    const IOSShadingPrototypeForwardBindingListReport& expected)
    noexcept {
  uint64_t mask = 0u;
  const auto& lhs = actual.bindings[0];
  const auto& rhs = expected.bindings[0];
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      lhs.stage,rhs.stage,0u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      lhs.semantic,rhs.semantic,1u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      lhs.nativeType,rhs.nativeType,2u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      lhs.access,rhs.access,3u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      lhs.used,rhs.used,4u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      lhs.index,rhs.index,5u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.count,expected.count,6u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.available,expected.available,7u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.overflow,expected.overflow,8u);
  return mask;
  }

uint64_t rendererIOSShadingPrototypeForwardComputeMismatchMask(
    const IOSShadingPrototypeForwardComputePipelineReport& actual,
    const IOSShadingPrototypeForwardComputePipelineReport& expected)
    noexcept {
  uint64_t mask = 0u;
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.available,expected.available,0u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.sameDevice,expected.sameDevice,1u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.reflectionAvailable,expected.reflectionAvailable,2u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.binaryArchivesNil,expected.binaryArchivesNil,3u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.functionMatches,expected.functionMatches,4u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.threadGroupSizeMultipleDisabled,
      expected.threadGroupSizeMultipleDisabled,5u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.maxTotalThreadsPerThreadgroupZero,
      expected.maxTotalThreadsPerThreadgroupZero,6u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.stageInputDescriptorEmpty,
      expected.stageInputDescriptorEmpty,7u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.indirectCommandBuffersDisabled,
      expected.indirectCommandBuffersDisabled,8u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.linkedFunctionsEmpty,expected.linkedFunctionsEmpty,9u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.addingBinaryFunctionsDisabled,
      expected.addingBinaryFunctionsDisabled,10u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.maxCallStackDepth,expected.maxCallStackDepth,11u);
  return mask;
  }

uint64_t rendererIOSShadingPrototypeForwardRenderMismatchMask(
    const IOSShadingPrototypeForwardRenderPipelineReport& actual,
    const IOSShadingPrototypeForwardRenderPipelineReport& expected)
    noexcept {
  uint64_t mask = 0u;
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.available,expected.available,0u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.sameDevice,expected.sameDevice,1u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.reflectionAvailable,expected.reflectionAvailable,2u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.binaryArchivesNil,expected.binaryArchivesNil,3u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.vertexDescriptorMatches,
      expected.vertexDescriptorMatches,4u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.colorAttachmentRgba8Unorm,
      expected.colorAttachmentRgba8Unorm,5u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.unusedColorAttachmentsInvalid,
      expected.unusedColorAttachmentsInvalid,6u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.colorWriteMaskAll,expected.colorWriteMaskAll,7u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.blendingDisabled,expected.blendingDisabled,8u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.depthStencilDisabled,
      expected.depthStencilDisabled,9u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.triangleTopology,expected.triangleTopology,10u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaToCoverageDisabled,
      expected.alphaToCoverageDisabled,11u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaToOneDisabled,expected.alphaToOneDisabled,12u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.rasterizationEnabled,
      expected.rasterizationEnabled,13u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.indirectCommandBuffersDisabled,
      expected.indirectCommandBuffersDisabled,14u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.alphaTestEnabled,expected.alphaTestEnabled,15u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.sampleCount,expected.sampleCount,16u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.imageblockBytesPerSample,
      expected.imageblockBytesPerSample,17u);
  return mask;
  }

uint64_t rendererIOSShadingPrototypeForwardTopMismatchMask(
    const IOSShadingPrototypeForwardPipelineReport& actual,
    const IOSShadingPrototypeForwardPipelineReport& expected)
    noexcept {
  uint64_t mask = 0u;
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.contractVersion,expected.contractVersion,0u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.offlineMetallibAbi,expected.offlineMetallibAbi,1u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.deviceAvailable,expected.deviceAvailable,2u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.supportsApple4,expected.supportsApple4,3u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.libraryAvailable,expected.libraryAvailable,4u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.librarySameDevice,expected.librarySameDevice,5u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.resolvedFunctionCount,
      expected.resolvedFunctionCount,6u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.specializationCount,expected.specializationCount,7u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.createdComputePipelineCount,
      expected.createdComputePipelineCount,8u);
  mask |= rendererIOSShadingPrototypeForwardMismatchBit(
      actual.createdRenderPipelineCount,
      expected.createdRenderPipelineCount,9u);
  return mask;
  }

constexpr bool rendererIOSShadingPrototypeForwardMayWaitIdle(
    bool acquiredBeforeGate,
    bool irreversibleFailureRecorded) noexcept {
  return !acquiredBeforeGate || irreversibleFailureRecorded;
  }

static_assert(
    !rendererIOSShadingPrototypeForwardMayWaitIdle(true,false));
static_assert(
    rendererIOSShadingPrototypeForwardMayWaitIdle(true,true));
static_assert(
    rendererIOSShadingPrototypeForwardMayWaitIdle(false,false));
#endif

}

struct IOSMetalContext::Impl final {
  struct LinearHDRTargets final {
    Attachment color;
    ZBuffer depth;
    IOSLinearHDRExtent extent;
    uint64_t generation = 0u;

    bool current(uint32_t width, uint32_t height) const noexcept {
      return !color.isEmpty() && !depth.isEmpty() &&
             extent.width==width && extent.height==height;
      }
    };

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

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
  enum class ClearOnlyPassSelfTestState : uint8_t {
    Armed,
    Encoded,
    Submitted,
    SubmittedFailed,
    Ambiguous,
    Passed,
    Failed,
    };
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
  enum class ShadingPrototypeTileSelfTestState : uint8_t {
    Armed,
    FactoryReady,
    Encoded,
    Submitted,
    Acquired,
    Ambiguous,
    Unsupported,
    Passed,
    Failed,
    };
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
  enum class ShadingPrototypeForwardSelfTestState : uint8_t {
    Armed,
    FactoryReady,
    Encoded,
    Submitted,
    Acquired,
    Ambiguous,
    Unsupported,
    Passed,
    Failed,
    };
#endif

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
    IOSLinearHDRFrameSequence  linearHDRSequence;
    bool                       linearHDRPolicyReadyAtEncode = false;
    bool                       linearHDRTerminalPending = false;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    FunctionalEvidence         functionalEvidence;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    IOSGPUScene::Multiply2InputArtifact emissiveInput;
    IOSMultiply2CoverageFrame multiply2Coverage;
#else
    IOSGPUScene::AdditiveInputArtifact emissiveInput;
#endif
    uint64_t                   emissivePreparedSerial = 0;
    uint64_t                   emissiveSubmittedSerial = 0;
    bool                       emissiveSubmitAccepted = false;
    bool                       emissivePresentAccepted = false;
    bool                       emissiveTerminalReported = false;
#endif
    bool                       submitted = false;
    bool                       discardCommandAfterIdle = false;
    bool                       rebuildCommand = false;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    // The proof frame owns its Shared buffer and strong native source lease.
    // Declaration before command/fence makes reverse destruction release the
    // terminal wrappers before retainedReferences=false resource owners.
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    IOSLinearHDRCaptureFrame   linearHDRCapture;
#endif
    IOSLinearHDRProofFrame     linearHDRProof;
#endif
    // Impl teardown settles explicitly. Reverse member destruction still
    // drops the fence and command before the scene/video keep-alives.
    CommandBuffer              command;
    Fence                      fence;
    };

  Impl(Device& device, SystemApi::Window* window)
    : device(device), deviceFacts(iosCollectDeviceFacts(device)),
      resourceAllocator(device), swapchain(device,window),
      runtimeBeforeLegacyShaders(MetalApi::runtimeCompilationSnapshot(device)),
      builtinRuntimeBeforeLegacyShaders(
        MetalApi::builtinRuntimeSnapshot(device)),
      legacyShaders(Shaders::CompilationProfile::RendererIOSBridge),
      runtimeAfterLegacyShaders(MetalApi::runtimeCompilationSnapshot(device)),
      builtinRuntimeAfterLegacyShaders(
        MetalApi::builtinRuntimeSnapshot(device)) {
    iosLogDeviceFacts(deviceFacts);
    if(!deviceFacts.value)
      throw std::runtime_error(
        "RendererIOS device facts validation failed");
    linearHDRSettings = iosLinearHDRLoadSettings({}).state;
    try {
      linearHDRMetal = std::make_unique<IOSLinearHDRMetal>(device);
      linearHDRProbe = linearHDRMetal->probe();
      }
    catch(...) {
      linearHDRMetal.reset();
      linearHDRProbe = IOSLinearHDRProbeResult::factoryFailed();
      }
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
    if(depthSupported) {
      try {
        gpuScene = std::make_unique<IOSGPUScene>(
          device,
          IOSGPUScene::TargetLayout{
            IOSGPUScene::ColorFormat::Rg11B10Float,
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
            IOSGPUScene::DepthFormat::Depth32FloatStencil8,
#else
            iosGPUSceneDepthFormat(depthFormat),
#endif
            1u,
            });
        }
      catch(...) {
        gpuScene.reset();
        }
      }
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    if(gpuScene!=nullptr &&
       gpuScene->additiveTerminalFailureReported()) {
      emissiveProfileClaimed = true;
      emissiveProfileTerminalReported = true;
      }
    else if(gpuScene==nullptr) {
      emissiveProfileClaimed = true;
      emissiveProfileTerminalReported = true;
      logEmissiveTerminalFailure(0u,0u,"contract","initialization");
      }
#endif
    gpuBink = std::make_unique<IOSGPUBink>(device);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    try {
      linearHDRProof =
          std::make_unique<IOSLinearHDRProofProducer>(device);
      }
    catch(...) {
      try {
        Log::e("RendererIOS HDR proof: v=1 id=none terminal=F class=contract reason=state");
        }
      catch(...) {
        }
      }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    try {
      multiply2Coverage =
          std::make_unique<IOSMultiply2CoverageProofProducer>(device);
      if(!multiply2Coverage->armed())
        multiply2Coverage.reset();
      }
    catch(...) {
      multiply2Coverage.reset();
      }
#endif
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
    armBinkSelfTest();
#endif

    for(auto& frame:frames)
      frame.command = device.commandBuffer();
    resetTargets(IOSLinearHDRActivationAttempt::Startup);
    featurePolicyProvenance.emplace(
      iosBuildFeaturePolicyProvenance(
        *deviceFacts.value,
        IOSFeatureDefaultClass::Safe,
        {false,false,false,false,false}));
    std::array<char,IOSFeaturePolicyTelemetryCapacity>
        featurePolicyTelemetry{};
    const IOSFeatureTelemetryResult featurePolicyTelemetryResult =
      iosTakeFeaturePolicyTelemetry(
        featurePolicyTelemetryGate,
        *featurePolicyProvenance,
        featurePolicyTelemetry.data(),
        featurePolicyTelemetry.size());
    if(featurePolicyTelemetryResult!=IOSFeatureTelemetryResult::Emitted)
      throw std::runtime_error(
        "RendererIOS feature policy telemetry was not emitted");
    Log::i(featurePolicyTelemetry.data(),
           " build=",OPENGOTHIC_RENDERER_IOS_BUILD_SHA);
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
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      Log::i(RendererIOSLinearHDRCaptureProfileEvidence);
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

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
  bool clearOnlyRuntimeCompilationUnchanged() const noexcept {
    const MetalRuntimeCompilationSnapshot runtime =
        MetalApi::runtimeCompilationSnapshot(device);
    const MetalBuiltinRuntimeSnapshot builtin =
        MetalApi::builtinRuntimeSnapshot(device);
    return clearOnlyRuntimeBefore.available && runtime.available &&
           runtime.sourceLibraryRequests==
             clearOnlyRuntimeBefore.sourceLibraryRequests &&
           runtime.computePsoRequests==
             clearOnlyRuntimeBefore.computePsoRequests &&
           runtime.renderPsoRequests==
             clearOnlyRuntimeBefore.renderPsoRequests &&
           clearOnlyBuiltinRuntimeBefore.available && builtin.available &&
           builtin.sourceLibraryRequests==
             clearOnlyBuiltinRuntimeBefore.sourceLibraryRequests &&
           builtin.renderPsoRequests==
             clearOnlyBuiltinRuntimeBefore.renderPsoRequests;
    }

  void logClearOnlyPassFailure(const char* reason) noexcept {
    try {
      Log::e("RendererIOS clear-only pass self-test: FAIL case=pm-clear-v1 reason=",
             reason);
      }
    catch(...) {
      }
    }

  void releaseClearOnlyPassAfterCommand() noexcept {
    clearOnlyCommand = CommandBuffer();
    clearOnlyCommandActive = false;
    clearOnlyMemorylessTexture = IOSMetalResourceTexture();
    clearOnlyPrivateTexture = IOSMetalResourceTexture();
    }

  void failClearOnlyPassBeforeSubmit(const char* reason) noexcept {
    clearOnlyCapture.cancel();
    releaseClearOnlyPassAfterCommand();
    clearOnlyPassState = ClearOnlyPassSelfTestState::Failed;
    logClearOnlyPassFailure(reason);
    fail("RendererIOS clear-only pass self-test failed",reason);
    }

  void failClearOnlyPassAmbiguous(const char* reason) noexcept {
    // Device::submit may have enqueued the command before throwing. Keep the
    // command and both unretained texture owners until waitIdle confirms the
    // terminal point; the existing fail-stop path performs that settle.
    clearOnlyCapture.cancel();
    clearOnlyPassState = ClearOnlyPassSelfTestState::Ambiguous;
    logClearOnlyPassFailure(reason);
    fail("RendererIOS clear-only pass self-test failed",reason);
    }

  bool clearOnlyLifetimeLive() const noexcept {
    const IOSMetalResourceLifetimeSnapshot current =
        iosMetalResourceLifetimeSnapshot();
    return current.created>=clearOnlyLifetimeBefore.created &&
           current.live>=clearOnlyLifetimeBefore.live &&
           current.released>=clearOnlyLifetimeBefore.released &&
           current.created-clearOnlyLifetimeBefore.created==2u &&
           current.live-clearOnlyLifetimeBefore.live==2u &&
           current.released-clearOnlyLifetimeBefore.released==0u;
    }

  bool clearOnlyLifetimeReleased() const noexcept {
    const IOSMetalResourceLifetimeSnapshot current =
        iosMetalResourceLifetimeSnapshot();
    return current.created>=clearOnlyLifetimeBefore.created &&
           current.live==clearOnlyLifetimeBefore.live &&
           current.released>=clearOnlyLifetimeBefore.released &&
           current.created-clearOnlyLifetimeBefore.created==2u &&
           current.released-clearOnlyLifetimeBefore.released==2u;
    }

  bool finishClearOnlyPassAfterTerminal(bool polledWithoutWaitIdle) noexcept {
    const bool preReleasePassed = polledWithoutWaitIdle &&
                                  clearOnlyFenceActive &&
                                  clearOnlyCommandActive &&
                                  bool(clearOnlyPrivateTexture) &&
                                  bool(clearOnlyMemorylessTexture) &&
                                  !clearOnlyCapture.active() &&
                                  clearOnlyCaptureArtifact.bytes>0u &&
                                  clearOnlyLifetimeLive() &&
                                  clearOnlyRuntimeCompilationUnchanged();

    // Terminal fence first, then command, then the two texture owners. This is
    // the retainedReferences=false lifetime boundary.
    clearOnlyFence = Fence();
    clearOnlyFenceActive = false;
    releaseClearOnlyPassAfterCommand();

    const bool postReleasePassed = !clearOnlyFenceActive &&
                                   !clearOnlyCommandActive &&
                                   !clearOnlyPrivateTexture &&
                                   !clearOnlyMemorylessTexture &&
                                   clearOnlyLifetimeReleased() &&
                                   clearOnlyRuntimeCompilationUnchanged();
    if(!preReleasePassed || !postReleasePassed) {
      clearOnlyPassState = ClearOnlyPassSelfTestState::Failed;
      const char* const reason = !polledWithoutWaitIdle
                               ? "wait-idle-used"
                               : "terminal-lifetime-or-runtime-mismatch";
      logClearOnlyPassFailure(reason);
      fail("RendererIOS clear-only pass self-test failed",reason);
      return false;
      }

    clearOnlyPassState = ClearOnlyPassSelfTestState::Passed;
    try {
      Log::i(rendererIOSClearOnlyPassMarkerText(
        RendererIOSClearOnlyPassSelfTestPassed));
      }
    catch(...) {
      }
    return true;
    }

  void startClearOnlyPassSelfTest() noexcept {
    if(clearOnlyPassStarted)
      return;
    clearOnlyPassStarted = true;
    static_assert(IOSFramePlanABIVersion==4u);
    try {
      Log::i(rendererIOSClearOnlyPassMarkerText(
        RendererIOSClearOnlyPassSelfTestArmed));
      }
    catch(...) {
      }

    IOSFramePlan plan;
    try {
      plan = iosMetalResourceClearPassPlan();
      }
    catch(const std::exception& e) {
      failClearOnlyPassBeforeSubmit(e.what());
      return;
      }
    catch(...) {
      failClearOnlyPassBeforeSubmit("frame-plan-allocation-failed");
      return;
      }
    const IOSMetalResourceClearPassSelection selection =
        iosMetalResourceSelectClearPassPlan(plan);
    if(!selection) {
      failClearOnlyPassBeforeSubmit("invalid-or-unsupported-plan");
      return;
      }

    clearOnlyRuntimeBefore = MetalApi::runtimeCompilationSnapshot(device);
    clearOnlyBuiltinRuntimeBefore = MetalApi::builtinRuntimeSnapshot(device);
    clearOnlyLifetimeBefore = iosMetalResourceLifetimeSnapshot();
    const char* captureReason = nullptr;
    if(!clearOnlyCapture.start(device,captureReason)) {
      failClearOnlyPassBeforeSubmit(
        captureReason!=nullptr ? captureReason : "capture-start-failed");
      return;
      }
    clearOnlyPrivateTexture =
        resourceAllocator.allocate(plan.resources[selection.privateResource]);
    clearOnlyMemorylessTexture =
        resourceAllocator.allocate(plan.resources[selection.memorylessResource]);
    if(!clearOnlyPrivateTexture || !clearOnlyMemorylessTexture ||
       !iosMetalTextureMatches(
         clearOnlyPrivateTexture.snapshot(),
         plan.resources[selection.privateResource],
         IOSMetalResourceStorage::Private) ||
       !iosMetalTextureMatches(
         clearOnlyMemorylessTexture.snapshot(),
         plan.resources[selection.memorylessResource],
         IOSMetalResourceStorage::Memoryless) ||
       !clearOnlyLifetimeLive() || !clearOnlyRuntimeCompilationUnchanged()) {
      failClearOnlyPassBeforeSubmit("allocation-or-lifetime-mismatch");
      return;
      }

    try {
      clearOnlyCommand = device.commandBuffer();
      clearOnlyCommandActive = true;
      bool encodeAccepted = false;
      {
        auto encoder = clearOnlyCommand.startEncoding(device);
        encodeAccepted = iosMetalResourceEncodeClearPassProbe(
            device,encoder,clearOnlyPrivateTexture,
            clearOnlyMemorylessTexture,clearOnlyNativeReport);
        }
      if(!encodeAccepted ||
         !iosMetalResourceClearPassNativeReportMatches(
           clearOnlyNativeReport) ||
         !clearOnlyLifetimeLive() ||
         !clearOnlyRuntimeCompilationUnchanged()) {
        failClearOnlyPassBeforeSubmit(
          !encodeAccepted ? "native-encode-rejected"
                          : "encoded-contract-mismatch");
        return;
        }
      clearOnlyPassState = ClearOnlyPassSelfTestState::Encoded;
      Log::i(rendererIOSClearOnlyPassMarkerText(
        RendererIOSClearOnlyPassSelfTestEncoded));
      }
    catch(const std::exception& e) {
      failClearOnlyPassBeforeSubmit(e.what());
      return;
      }
    catch(...) {
      failClearOnlyPassBeforeSubmit("native-encode-exception");
      return;
      }

    try {
      Fence submitted = device.submit(clearOnlyCommand);
      clearOnlyFence = std::move(submitted);
      clearOnlyFenceActive = true;
      clearOnlyPassState = ClearOnlyPassSelfTestState::Submitted;
      }
    catch(const std::exception& e) {
      failClearOnlyPassAmbiguous(e.what());
      return;
      }
    catch(...) {
      failClearOnlyPassAmbiguous("submit-exception-ambiguous");
      return;
      }
    if(!clearOnlyCapture.stopAndInspect(
         clearOnlyCaptureArtifact,captureReason)) {
      clearOnlyCapture.cancel();
      clearOnlyPassState = ClearOnlyPassSelfTestState::SubmittedFailed;
      const char* const reason = captureReason!=nullptr
                               ? captureReason
                               : "capture-artifact-invalid";
      logClearOnlyPassFailure(reason);
      fail("RendererIOS clear-only pass self-test failed",reason);
      return;
      }
    try {
      Log::i(rendererIOSClearOnlyPassMarkerText(
        RendererIOSClearOnlyPassSelfTestSubmitted));
      Log::i(rendererIOSClearOnlyPassMarkerText(
               RendererIOSClearOnlyCaptureAcquired),
             " case=pm-clear-v1 file=RendererIOS-pm-clear-v1.gputrace kind=",
             iosMetalCaptureArtifactKindName(clearOnlyCaptureArtifact.kind),
             " bytes=",clearOnlyCaptureArtifact.bytes);
      }
    catch(...) {
      }
    }

  void pollClearOnlyPassSelfTest() noexcept {
    if(!clearOnlyPassStarted) {
      startClearOnlyPassSelfTest();
      return;
      }
    if(clearOnlyPassState!=ClearOnlyPassSelfTestState::Submitted)
      return;
    try {
      if(!clearOnlyFence.wait(0u))
        return;
      (void)finishClearOnlyPassAfterTerminal(true);
      }
    catch(const std::exception& e) {
      clearOnlyFence = Fence();
      clearOnlyFenceActive = false;
      releaseClearOnlyPassAfterCommand();
      clearOnlyPassState = ClearOnlyPassSelfTestState::Failed;
      logClearOnlyPassFailure(e.what());
      fail("RendererIOS clear-only pass self-test failed",e.what());
      }
    catch(...) {
      clearOnlyFence = Fence();
      clearOnlyFenceActive = false;
      releaseClearOnlyPassAfterCommand();
      clearOnlyPassState = ClearOnlyPassSelfTestState::Failed;
      logClearOnlyPassFailure("terminal-fence-error");
      fail("RendererIOS clear-only pass self-test failed",
           "terminal-fence-error");
      }
    }

  void settleClearOnlyPassAfterConfirmedIdle() noexcept {
    if(clearOnlyPassState==ClearOnlyPassSelfTestState::Ambiguous) {
      releaseClearOnlyPassAfterCommand();
      return;
      }
    if(clearOnlyPassState==ClearOnlyPassSelfTestState::SubmittedFailed) {
      clearOnlyFence = Fence();
      clearOnlyFenceActive = false;
      releaseClearOnlyPassAfterCommand();
      return;
      }
    if(clearOnlyPassState!=ClearOnlyPassSelfTestState::Submitted)
      return;
    try {
      if(!clearOnlyFence.wait(0u)) {
        logClearOnlyPassFailure("fence-nonterminal-after-wait-idle");
        fail("RendererIOS clear-only pass self-test failed",
             "fence-nonterminal-after-wait-idle");
        return;
        }
      (void)finishClearOnlyPassAfterTerminal(false);
      }
    catch(const std::exception& e) {
      clearOnlyFence = Fence();
      clearOnlyFenceActive = false;
      releaseClearOnlyPassAfterCommand();
      clearOnlyPassState = ClearOnlyPassSelfTestState::Failed;
      logClearOnlyPassFailure(e.what());
      fail("RendererIOS clear-only pass self-test failed",e.what());
      }
    catch(...) {
      clearOnlyFence = Fence();
      clearOnlyFenceActive = false;
      releaseClearOnlyPassAfterCommand();
      clearOnlyPassState = ClearOnlyPassSelfTestState::Failed;
      logClearOnlyPassFailure("terminal-fence-error-after-wait-idle");
      fail("RendererIOS clear-only pass self-test failed",
           "terminal-fence-error-after-wait-idle");
      }
    }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
  RendererIOSShadingPrototypeTileIsolationSnapshot
      shadingPrototypeTileIsolationSnapshot() const noexcept {
    RendererIOSShadingPrototypeTileIsolationSnapshot snapshot;
    snapshot.runtime = MetalApi::runtimeCompilationSnapshot(device);
    snapshot.builtin = MetalApi::builtinRuntimeSnapshot(device);
    snapshot.archive = MetalApi::pipelineArchiveSnapshot(device);
    return snapshot;
    }

  bool shadingPrototypeTileIsolationUnchanged() const noexcept {
    return rendererIOSShadingPrototypeTileIsolationSnapshotEqual(
        shadingPrototypeTileIsolationBefore,
        shadingPrototypeTileIsolationSnapshot());
    }

  bool shadingPrototypeTileLifetimeUnchanged() const noexcept {
    return iosMetalResourceLifetimeSnapshot()==
           shadingPrototypeTileLifetimeBefore;
    }

  bool shadingPrototypeTileLifetimeLive() const noexcept {
    const IOSMetalResourceLifetimeSnapshot current =
        iosMetalResourceLifetimeSnapshot();
    return current.created>=shadingPrototypeTileLifetimeBefore.created &&
           current.live>=shadingPrototypeTileLifetimeBefore.live &&
           current.released>=shadingPrototypeTileLifetimeBefore.released &&
           current.created-shadingPrototypeTileLifetimeBefore.created==1u &&
           current.live-shadingPrototypeTileLifetimeBefore.live==1u &&
           current.released-
               shadingPrototypeTileLifetimeBefore.released==0u;
    }

  bool shadingPrototypeTileLifetimeReleased() const noexcept {
    const IOSMetalResourceLifetimeSnapshot current =
        iosMetalResourceLifetimeSnapshot();
    return current.created>=shadingPrototypeTileLifetimeBefore.created &&
           current.live==shadingPrototypeTileLifetimeBefore.live &&
           current.released>=shadingPrototypeTileLifetimeBefore.released &&
           current.created-shadingPrototypeTileLifetimeBefore.created==1u &&
           current.released-
               shadingPrototypeTileLifetimeBefore.released==1u;
    }

  void logShadingPrototypeTileFailure(const char* reason) noexcept {
    try {
      Log::e("RendererIOS shading prototype tile self-test: FAIL case=tile-prototype-v1 reason=",
             reason);
      }
    catch(...) {
      }
    }

  void releaseShadingPrototypeTileOwnersAfterCommand() noexcept {
    shadingPrototypeTileCommand = CommandBuffer();
    shadingPrototypeTileCommandActive = false;
    shadingPrototypeTileOutput = IOSMetalResourceTexture();
    shadingPrototypeTilePipeline = IOSShadingPrototypePipeline();
    shadingPrototypeTileCapture.reset();
    }

  void failShadingPrototypeTileBeforeSubmit(
      const char* reason, const char* detail = nullptr) noexcept {
    releaseShadingPrototypeTileOwnersAfterCommand();
    shadingPrototypeTileFence = Fence();
    shadingPrototypeTileFenceActive = false;
    shadingPrototypeTileState =
        ShadingPrototypeTileSelfTestState::Failed;
    logShadingPrototypeTileFailure(reason);
    fail("RendererIOS shading prototype tile self-test failed",
         detail!=nullptr ? detail : reason);
    }

  void failShadingPrototypeTileAmbiguous(
      const char* reason, const char* detail = nullptr) noexcept {
    // A throwing submit or capture boundary may already have enqueued GPU work
    // or left capture active. Keep every retainedReferences=false owner and
    // the capture session until the common fail-stop path confirms device idle.
    shadingPrototypeTileState =
        ShadingPrototypeTileSelfTestState::Ambiguous;
    logShadingPrototypeTileFailure(reason);
    fail("RendererIOS shading prototype tile self-test failed",
         detail!=nullptr ? detail : reason);
    }

  void releaseShadingPrototypeTileAfterTerminal() noexcept {
    shadingPrototypeTileFence = Fence();
    shadingPrototypeTileFenceActive = false;
    releaseShadingPrototypeTileOwnersAfterCommand();
    }

  bool finishShadingPrototypeTileAfterTerminal(
      bool polledWithoutWaitIdle) noexcept {
    const bool preReleasePassed =
        polledWithoutWaitIdle &&
        shadingPrototypeTileState==
            ShadingPrototypeTileSelfTestState::Acquired &&
        shadingPrototypeTileFenceActive &&
        shadingPrototypeTileCommandActive &&
        bool(shadingPrototypeTileOutput) &&
        bool(shadingPrototypeTilePipeline) &&
        !shadingPrototypeTileCapture.active() &&
        shadingPrototypeTileCaptureArtifact.bytes>0u &&
        iosShadingPrototypeTileProbeReportMatches(
            shadingPrototypeTileNativeReport) &&
        shadingPrototypeTileLifetimeLive() &&
        shadingPrototypeTileIsolationUnchanged();

    // The terminal fence is the retainedReferences=false boundary. Drop it
    // first, then the command and its output/pipeline/capture keep-alives.
    releaseShadingPrototypeTileAfterTerminal();

    const bool postReleasePassed =
        !shadingPrototypeTileFenceActive &&
        !shadingPrototypeTileCommandActive &&
        !shadingPrototypeTileOutput &&
        !shadingPrototypeTilePipeline &&
        !shadingPrototypeTileCapture.active() &&
        shadingPrototypeTileLifetimeReleased() &&
        shadingPrototypeTileIsolationUnchanged();
    if(!preReleasePassed || !postReleasePassed) {
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Failed;
      const char* const reason = !polledWithoutWaitIdle
                               ? "wait-idle-used"
                               : "terminal-lifetime-or-counter-mismatch";
      logShadingPrototypeTileFailure(reason);
      fail("RendererIOS shading prototype tile self-test failed",reason);
      return false;
      }

    shadingPrototypeTileState =
        ShadingPrototypeTileSelfTestState::Passed;
    try {
      Log::i(rendererIOSShadingPrototypeTileMarkerText(
          RendererIOSShadingPrototypeTileSelfTestPassed));
      }
    catch(...) {
      }
    return true;
    }

  void startShadingPrototypeTileSelfTest() noexcept {
    if(shadingPrototypeTileStarted)
      return;
    shadingPrototypeTileStarted = true;
    static_assert(IOSShadingPrototypePlanABIVersion==1u);
    static_assert(
        RendererIOSShadingPrototypePipeline::OfflineMetallibAbi==9u);
    try {
      Log::i(rendererIOSShadingPrototypeTileMarkerText(
          RendererIOSShadingPrototypeTileSelfTestArmed));
      }
    catch(...) {
      }

    IOSShadingPrototypePlan plan;
    try {
      plan = iosShadingPrototypePlan(
          IOSShadingPrototypeKind::TileDeferred);
      }
    catch(...) {
      failShadingPrototypeTileBeforeSubmit(
          "plan-contract-mismatch");
      return;
      }
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(plan);
    const bool planMatches =
        bool(selection) &&
        selection.kind==IOSShadingPrototypeKind::TileDeferred &&
        selection.outputResource<plan.framePlan.resources.size() &&
        selection.workingResource<plan.framePlan.resources.size() &&
        selection.computePass==IOSShadingPrototypeNoPass &&
        selection.renderPass==0u && selection.presentPass==1u &&
        !plan.framePlan.resources[selection.outputResource].memoryless &&
        plan.framePlan.resources[selection.workingResource].memoryless &&
        plan.topology.commandBuffers==1u &&
        plan.topology.submits==1u &&
        plan.topology.renderEncoders==1u &&
        plan.topology.draws==2u &&
        plan.topology.tileDispatches==1u &&
        plan.topology.computeEncoders==0u &&
        plan.topology.drawableAcquisitions==0u &&
        plan.topology.presents==0u;
    if(!planMatches) {
      failShadingPrototypeTileBeforeSubmit(
          "plan-contract-mismatch");
      return;
      }

    shadingPrototypeTileIsolationBefore =
        shadingPrototypeTileIsolationSnapshot();
    shadingPrototypeTileLifetimeBefore =
        iosMetalResourceLifetimeSnapshot();
    if(!rendererIOSShadingPrototypeTileIsolationSnapshotAvailable(
           shadingPrototypeTileIsolationBefore)) {
      failShadingPrototypeTileBeforeSubmit("snapshot-unavailable");
      return;
      }

    shadingPrototypeTilePipeline =
        iosCreateShadingPrototypePipeline(device);
    if(shadingPrototypeTilePipeline.status()==
       IOSShadingPrototypePipelineStatus::UnsupportedCapability) {
      const auto& report = shadingPrototypeTilePipeline.report();
      const bool zeroSideEffects =
          !shadingPrototypeTilePipeline &&
          !report.supportsApple4 &&
          !report.libraryAvailable &&
          report.resolvedTileFunctionCount==0u &&
          report.createdTilePipelineCount==0u &&
          !shadingPrototypeTileOutput &&
          !shadingPrototypeTileCommandActive &&
          !shadingPrototypeTileFenceActive &&
          !shadingPrototypeTileCapture.active() &&
          shadingPrototypeTileCaptureArtifact.bytes==0u &&
          shadingPrototypeTileLifetimeUnchanged() &&
          shadingPrototypeTileIsolationUnchanged();
      if(!zeroSideEffects) {
        failShadingPrototypeTileBeforeSubmit(
            "unsupported-side-effect-mismatch");
        return;
        }
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Unsupported;
      try {
        Log::i(rendererIOSShadingPrototypeTileMarkerText(
            RendererIOSShadingPrototypeTileSelfTestUnsupported));
        }
      catch(...) {
        }
      return;
      }
    const IOSShadingPrototypePipelineStatus factoryStatus =
        shadingPrototypeTilePipeline.status();
    const auto& factoryReport =
        shadingPrototypeTilePipeline.report();
    const IOSShadingPrototypePipelineStatus validationStatus =
        iosValidateShadingPrototypePipelineReport(factoryReport);
    if(!shadingPrototypeTilePipeline ||
       factoryStatus!=IOSShadingPrototypePipelineStatus::Ready ||
       validationStatus!=IOSShadingPrototypePipelineStatus::Ready) {
      try {
        Log::e("RendererIOS shading prototype tile factory report: status=",
               iosShadingPrototypePipelineStatusName(factoryStatus),
               " validation=",
               iosShadingPrototypePipelineStatusName(validationStatus),
               " functions=",factoryReport.resolvedTileFunctionCount,
               " pipelines=",factoryReport.createdTilePipelineCount);
        for(std::size_t i=0u;
            i<factoryReport.materialPipelines.size(); ++i) {
          const auto& pipeline = factoryReport.materialPipelines[i];
          Log::e("RendererIOS shading prototype tile material report: index=",
                 i,
                 " available=",pipeline.available,
                 " reflection=",pipeline.reflectionAvailable,
                 " imageblock=",pipeline.imageblockBytesPerSample,
                 " bindings=",
                 pipeline.vertexBindings.count,",",
                 pipeline.fragmentBindings.count,",",
                 pipeline.tileBindings.count);
          }
        const auto& lighting = factoryReport.lightingPipeline;
        Log::e("RendererIOS shading prototype tile lighting report: available=",
               lighting.available,
               " reflection=",lighting.reflectionAvailable,
               " imageblock=",lighting.imageblockBytesPerSample,
               " bindings=",
               lighting.vertexBindings.count,",",
               lighting.fragmentBindings.count,",",
               lighting.tileBindings.count);
        }
      catch(...) {
        }
      failShadingPrototypeTileBeforeSubmit(
          "factory-contract-mismatch");
      return;
      }
    if(!shadingPrototypeTileIsolationUnchanged()) {
      failShadingPrototypeTileBeforeSubmit(
          "factory-counter-mismatch");
      return;
      }
    shadingPrototypeTileState =
        ShadingPrototypeTileSelfTestState::FactoryReady;
    try {
      Log::i(rendererIOSShadingPrototypeTileMarkerText(
          RendererIOSShadingPrototypeTileSelfTestFactoryReady));
      }
    catch(...) {
      }

    const IOSResourceDesc& outputResource =
        plan.framePlan.resources[selection.outputResource];
    shadingPrototypeTileOutput =
        resourceAllocator.allocate(outputResource);
    if(!shadingPrototypeTileOutput ||
       !iosMetalTextureMatches(
           shadingPrototypeTileOutput.snapshot(),outputResource,
           IOSMetalResourceStorage::Private) ||
       !shadingPrototypeTileLifetimeLive() ||
       !shadingPrototypeTileIsolationUnchanged()) {
      failShadingPrototypeTileBeforeSubmit(
          "output-allocation-or-lifetime-mismatch");
      return;
      }

    const char* captureReason = nullptr;
    if(!shadingPrototypeTileCapture.start(
           device,RendererIOSShadingPrototypeTileCaptureName,
           captureReason)) {
      if(shadingPrototypeTileCapture.active()) {
        failShadingPrototypeTileAmbiguous(
            "capture-start-ambiguous",captureReason);
        }
      else {
        failShadingPrototypeTileBeforeSubmit(
            "capture-start-failed",captureReason);
        }
      return;
      }

    try {
      shadingPrototypeTileCommand = device.commandBuffer();
      shadingPrototypeTileCommandActive = true;
      bool encodeAccepted = false;
      {
        auto encoder =
            shadingPrototypeTileCommand.startEncoding(device);
        encodeAccepted = iosEncodeShadingPrototypeTileProbe(
            device,encoder,shadingPrototypeTilePipeline,
            shadingPrototypeTileOutput,
            shadingPrototypeTileNativeReport);
        }
      if(!encodeAccepted) {
        failShadingPrototypeTileBeforeSubmit(
            "native-encode-rejected");
        return;
        }
      if(!iosShadingPrototypeTileProbeReportMatches(
             shadingPrototypeTileNativeReport) ||
         !shadingPrototypeTileLifetimeLive() ||
         !shadingPrototypeTileIsolationUnchanged()) {
        failShadingPrototypeTileBeforeSubmit(
            "encoded-contract-mismatch");
        return;
        }
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Encoded;
      Log::i(rendererIOSShadingPrototypeTileMarkerText(
          RendererIOSShadingPrototypeTileSelfTestEncoded));
      }
    catch(const std::exception& e) {
      failShadingPrototypeTileBeforeSubmit(
          shadingPrototypeTileCommandActive
              ? "native-encode-rejected"
              : "command-buffer-creation-failed",
          e.what());
      return;
      }
    catch(...) {
      failShadingPrototypeTileBeforeSubmit(
          shadingPrototypeTileCommandActive
              ? "native-encode-rejected"
              : "command-buffer-creation-failed");
      return;
      }

    try {
      Fence submitted =
          device.submit(shadingPrototypeTileCommand);
      shadingPrototypeTileFence = std::move(submitted);
      shadingPrototypeTileFenceActive = true;
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Submitted;
      Log::i(rendererIOSShadingPrototypeTileMarkerText(
          RendererIOSShadingPrototypeTileSelfTestSubmitted));
      }
    catch(const std::exception& e) {
      failShadingPrototypeTileAmbiguous(
          "submit-exception-ambiguous",e.what());
      return;
      }
    catch(...) {
      failShadingPrototypeTileAmbiguous(
          "submit-exception-ambiguous");
      return;
      }

    if(!shadingPrototypeTileCapture.stopAndInspect(
           shadingPrototypeTileCaptureArtifact,captureReason)) {
      failShadingPrototypeTileAmbiguous(
          "capture-acquisition-failed",captureReason);
      return;
      }
    shadingPrototypeTileState =
        ShadingPrototypeTileSelfTestState::Acquired;
    try {
      Log::i(rendererIOSShadingPrototypeTileMarkerText(
               RendererIOSShadingPrototypeTileCaptureAcquired),
             " case=tile-prototype-v1 file=",
             RendererIOSShadingPrototypeTileCaptureName,
             " kind=",
             iosMetalCaptureArtifactKindName(
                 shadingPrototypeTileCaptureArtifact.kind),
             " bytes=",shadingPrototypeTileCaptureArtifact.bytes);
      }
    catch(...) {
      }
    }

  void pollShadingPrototypeTileSelfTest() noexcept {
    if(!shadingPrototypeTileStarted) {
      startShadingPrototypeTileSelfTest();
      return;
      }
    if(shadingPrototypeTileState!=
       ShadingPrototypeTileSelfTestState::Acquired)
      return;
    try {
      if(!shadingPrototypeTileFence.wait(0u))
        return;
      (void)finishShadingPrototypeTileAfterTerminal(true);
      }
    catch(const std::exception& e) {
      releaseShadingPrototypeTileAfterTerminal();
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Failed;
      logShadingPrototypeTileFailure("terminal-fence-error");
      fail("RendererIOS shading prototype tile self-test failed",e.what());
      }
    catch(...) {
      releaseShadingPrototypeTileAfterTerminal();
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Failed;
      logShadingPrototypeTileFailure("terminal-fence-error");
      fail("RendererIOS shading prototype tile self-test failed",
           "terminal-fence-error");
      }
    }

  void settleShadingPrototypeTileAfterConfirmedIdle() noexcept {
    if(shadingPrototypeTileState==
           ShadingPrototypeTileSelfTestState::Ambiguous) {
      releaseShadingPrototypeTileAfterTerminal();
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Failed;
      return;
      }
    if(shadingPrototypeTileState!=
       ShadingPrototypeTileSelfTestState::Acquired)
      return;
    try {
      if(!shadingPrototypeTileFence.wait(0u)) {
        logShadingPrototypeTileFailure(
            "fence-nonterminal-after-wait-idle");
        fail("RendererIOS shading prototype tile self-test failed",
             "fence-nonterminal-after-wait-idle");
        return;
        }
      (void)finishShadingPrototypeTileAfterTerminal(false);
      }
    catch(const std::exception& e) {
      releaseShadingPrototypeTileAfterTerminal();
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Failed;
      logShadingPrototypeTileFailure("terminal-fence-error");
      fail("RendererIOS shading prototype tile self-test failed",e.what());
      }
    catch(...) {
      releaseShadingPrototypeTileAfterTerminal();
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Failed;
      logShadingPrototypeTileFailure("terminal-fence-error");
      fail("RendererIOS shading prototype tile self-test failed",
           "terminal-fence-error");
      }
    }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
  RendererIOSShadingPrototypeForwardIsolationSnapshot
      shadingPrototypeForwardIsolationSnapshot() const noexcept {
    RendererIOSShadingPrototypeForwardIsolationSnapshot snapshot;
    snapshot.runtime = MetalApi::runtimeCompilationSnapshot(device);
    snapshot.builtin = MetalApi::builtinRuntimeSnapshot(device);
    snapshot.archive = MetalApi::pipelineArchiveSnapshot(device);
    return snapshot;
    }

  bool shadingPrototypeForwardIsolationUnchanged() const noexcept {
    return rendererIOSShadingPrototypeForwardIsolationSnapshotEqual(
        shadingPrototypeForwardIsolationBefore,
        shadingPrototypeForwardIsolationSnapshot());
    }

  bool shadingPrototypeForwardOutputLifetimeLive() const noexcept {
    const IOSMetalResourceLifetimeSnapshot current =
        iosMetalResourceLifetimeSnapshot();
    return current.created>=
               shadingPrototypeForwardOutputLifetimeBefore.created &&
           current.live>=
               shadingPrototypeForwardOutputLifetimeBefore.live &&
           current.released>=
               shadingPrototypeForwardOutputLifetimeBefore.released &&
           current.created-
               shadingPrototypeForwardOutputLifetimeBefore.created==1u &&
           current.live-
               shadingPrototypeForwardOutputLifetimeBefore.live==1u &&
           current.released-
               shadingPrototypeForwardOutputLifetimeBefore.released==0u;
    }

  bool shadingPrototypeForwardOutputLifetimeReleased() const noexcept {
    const IOSMetalResourceLifetimeSnapshot current =
        iosMetalResourceLifetimeSnapshot();
    return current.created>=
               shadingPrototypeForwardOutputLifetimeBefore.created &&
           current.live==
               shadingPrototypeForwardOutputLifetimeBefore.live &&
           current.released>=
               shadingPrototypeForwardOutputLifetimeBefore.released &&
           current.created-
               shadingPrototypeForwardOutputLifetimeBefore.created==1u &&
           current.released-
               shadingPrototypeForwardOutputLifetimeBefore.released==1u;
    }

  bool shadingPrototypeForwardLightListLifetimeLive() const noexcept {
    const IOSShadingPrototypeForwardLightListLifetimeSnapshot current =
        iosShadingPrototypeForwardLightListLifetimeSnapshot();
    return current.created>=
               shadingPrototypeForwardLightListLifetimeBefore.created &&
           current.live>=
               shadingPrototypeForwardLightListLifetimeBefore.live &&
           current.released>=
               shadingPrototypeForwardLightListLifetimeBefore.released &&
           current.created-
               shadingPrototypeForwardLightListLifetimeBefore.created==1u &&
           current.live-
               shadingPrototypeForwardLightListLifetimeBefore.live==1u &&
           current.released-
               shadingPrototypeForwardLightListLifetimeBefore.released==0u;
    }

  bool shadingPrototypeForwardLightListLifetimeReleased() const noexcept {
    const IOSShadingPrototypeForwardLightListLifetimeSnapshot current =
        iosShadingPrototypeForwardLightListLifetimeSnapshot();
    return current.created>=
               shadingPrototypeForwardLightListLifetimeBefore.created &&
           current.live==
               shadingPrototypeForwardLightListLifetimeBefore.live &&
           current.released>=
               shadingPrototypeForwardLightListLifetimeBefore.released &&
           current.created-
               shadingPrototypeForwardLightListLifetimeBefore.created==1u &&
           current.released-
               shadingPrototypeForwardLightListLifetimeBefore.released==1u;
    }

  void logShadingPrototypeForwardFailure(
      const char* reason) noexcept {
    try {
      Log::e(rendererIOSShadingPrototypeForwardMarkerText(
                 RendererIOSShadingPrototypeForwardSelfTestFailed),
             shadingPrototypeForwardNonce.data(),
             " reason=",reason);
      }
    catch(...) {
      }
    }

  void logShadingPrototypeForwardFactoryFailure(
      IOSShadingPrototypeForwardPipelineStatus factoryStatus,
      IOSShadingPrototypeForwardPipelineStatus validationStatus,
      const IOSShadingPrototypeForwardPipelineReport& report)
      noexcept {
    const IOSShadingPrototypeForwardPipelineReport canonical =
        iosCanonicalShadingPrototypeForwardPipelineReport();
    try {
      Log::e(
          "RendererIOS Forward factory diag: nonce=",
          shadingPrototypeForwardNonce.data(),
          " part=top factory=",
          iosShadingPrototypeForwardPipelineStatusName(factoryStatus),
          " validation=",
          iosShadingPrototypeForwardPipelineStatusName(validationStatus),
          " owner=",bool(shadingPrototypeForwardPipeline) ? 1 : 0,
          " delta=",
          rendererIOSShadingPrototypeForwardTopMismatchMask(
              report,canonical),
          " fn=",
          rendererIOSShadingPrototypeForwardFunctionMismatchMask(
              report.functions[0],canonical.functions[0]),
          "/",
          rendererIOSShadingPrototypeForwardFunctionMismatchMask(
              report.functions[1],canonical.functions[1]),
          "/",
          rendererIOSShadingPrototypeForwardFunctionMismatchMask(
              report.functions[2],canonical.functions[2]),
          " spec=",
          rendererIOSShadingPrototypeForwardSpecializationMismatchMask(
              report.fragmentSpecializations[0],
              canonical.fragmentSpecializations[0]),
          "/",
          rendererIOSShadingPrototypeForwardSpecializationMismatchMask(
              report.fragmentSpecializations[1],
              canonical.fragmentSpecializations[1]));
      Log::e(
          "RendererIOS Forward factory diag: nonce=",
          shadingPrototypeForwardNonce.data(),
          " part=compute delta=",
          rendererIOSShadingPrototypeForwardComputeMismatchMask(
              report.computePipeline,canonical.computePipeline),
          " bindings=",
          rendererIOSShadingPrototypeForwardBindingMismatchMask(
              report.computePipeline.computeBindings,
              canonical.computePipeline.computeBindings));
      for(std::size_t index=0u;
          index<report.renderPipelines.size(); ++index) {
        const auto& actual = report.renderPipelines[index];
        const auto& expected = canonical.renderPipelines[index];
        Log::e(
            "RendererIOS Forward factory diag: nonce=",
            shadingPrototypeForwardNonce.data(),
            " part=render",index,
            " delta=",
            rendererIOSShadingPrototypeForwardRenderMismatchMask(
                actual,expected),
            " bindings=",
            rendererIOSShadingPrototypeForwardBindingMismatchMask(
                actual.vertexBindings,expected.vertexBindings),
            "/",
            rendererIOSShadingPrototypeForwardBindingMismatchMask(
                actual.fragmentBindings,expected.fragmentBindings),
            "/",
            rendererIOSShadingPrototypeForwardBindingMismatchMask(
                actual.tileBindings,expected.tileBindings),
            "/",
            rendererIOSShadingPrototypeForwardBindingMismatchMask(
                actual.objectBindings,expected.objectBindings),
            "/",
            rendererIOSShadingPrototypeForwardBindingMismatchMask(
                actual.meshBindings,expected.meshBindings));
        }
      }
    catch(...) {
      }
    }

  void releaseShadingPrototypeForwardOwnersBeforeSubmit() noexcept {
    shadingPrototypeForwardCommand = CommandBuffer();
    shadingPrototypeForwardCommandActive = false;
    shadingPrototypeForwardCapture.reset();
    shadingPrototypeForwardLightList =
        IOSShadingPrototypeForwardLightList();
    shadingPrototypeForwardOutput = IOSMetalResourceTexture();
    shadingPrototypeForwardPipeline =
        IOSShadingPrototypeForwardPipeline();
    shadingPrototypeForwardFence = Fence();
    shadingPrototypeForwardFenceActive = false;
    }

  void releaseShadingPrototypeForwardOwnersAfterTerminal() noexcept {
    // Fence is known terminal here. Drop it first, then the command buffer,
    // output, light list, pipeline and finally the stopped capture owner.
    shadingPrototypeForwardReleaseOrderExact = false;
    uint32_t releaseStep = 0u;
    shadingPrototypeForwardFence = Fence();
    shadingPrototypeForwardFenceActive = false;
    releaseStep = 1u;
    shadingPrototypeForwardCommand = CommandBuffer();
    shadingPrototypeForwardCommandActive = false;
    releaseStep = releaseStep==1u ? 2u : 0u;
    shadingPrototypeForwardOutput = IOSMetalResourceTexture();
    releaseStep = releaseStep==2u ? 3u : 0u;
    shadingPrototypeForwardLightList =
        IOSShadingPrototypeForwardLightList();
    releaseStep = releaseStep==3u ? 4u : 0u;
    shadingPrototypeForwardPipeline =
        IOSShadingPrototypeForwardPipeline();
    releaseStep = releaseStep==4u ? 5u : 0u;
    shadingPrototypeForwardCapture.reset();
    releaseStep = releaseStep==5u ? 6u : 0u;
    shadingPrototypeForwardReleaseOrderExact = releaseStep==6u;
    }

  void failShadingPrototypeForwardBeforeSubmit(
      const char* reason, const char* detail = nullptr) noexcept {
    releaseShadingPrototypeForwardOwnersBeforeSubmit();
    shadingPrototypeForwardState =
        ShadingPrototypeForwardSelfTestState::Failed;
    logShadingPrototypeForwardFailure(reason);
    fail("RendererIOS shading prototype forward self-test failed",
         detail!=nullptr ? detail : reason);
    }

  void failShadingPrototypeForwardAmbiguous(
      const char* reason, const char* detail = nullptr) noexcept {
    // Submit/capture/fence timeout cannot prove ownership is releasable.
    // Keep every owner until settleGpu has confirmed device idle.
    shadingPrototypeForwardState =
        ShadingPrototypeForwardSelfTestState::Ambiguous;
    logShadingPrototypeForwardFailure(reason);
    fail("RendererIOS shading prototype forward self-test failed",
         detail!=nullptr ? detail : reason);
    }

  void failShadingPrototypeForwardAfterTerminal(
      const char* reason, const char* detail = nullptr) noexcept {
    releaseShadingPrototypeForwardOwnersAfterTerminal();
    shadingPrototypeForwardState =
        ShadingPrototypeForwardSelfTestState::Failed;
    logShadingPrototypeForwardFailure(reason);
    fail("RendererIOS shading prototype forward self-test failed",
         detail!=nullptr ? detail : reason);
    }

  bool finishShadingPrototypeForwardAfterTerminal() noexcept {
    namespace Probe = RendererIOSShadingPrototypeForwardProbe;
    namespace Shader = RendererIOSShadingPrototypeShader;

    const bool terminalOwnersLive =
        shadingPrototypeForwardState==
            ShadingPrototypeForwardSelfTestState::Acquired &&
        shadingPrototypeForwardFenceActive &&
        shadingPrototypeForwardCommandActive &&
        bool(shadingPrototypeForwardOutput) &&
        bool(shadingPrototypeForwardLightList) &&
        bool(shadingPrototypeForwardPipeline) &&
        shadingPrototypeForwardCapture.initialized() &&
        !shadingPrototypeForwardCapture.active() &&
        shadingPrototypeForwardCaptureArtifact.bytes>0u &&
        iosValidateShadingPrototypeForwardProbeReportV1(
            shadingPrototypeForwardNativeReport) &&
        shadingPrototypeForwardOutputLifetimeLive() &&
        shadingPrototypeForwardLightListLifetimeLive() &&
        shadingPrototypeForwardIsolationUnchanged();
    if(!terminalOwnersLive) {
      failShadingPrototypeForwardAfterTerminal(
          "terminal-lifetime-or-counter-mismatch");
      return false;
      }

    try {
      Log::i(rendererIOSShadingPrototypeForwardMarkerText(
                 RendererIOSShadingPrototypeForwardSelfTestTerminal),
             shadingPrototypeForwardNonce.data(),
             " terminal=completed wait-calls=",
             shadingPrototypeForwardFenceWaitCalls,
             " zero-timeout=",
             shadingPrototypeForwardFenceWaitCalls,
             " nonterminal=",
             shadingPrototypeForwardFenceNonterminalPolls,
             " wait-idle=0");
      }
    catch(...) {
      }

    std::array<
        uint32_t,
        Shader::ForwardLightListWordCount> words{};
    if(!iosReadShadingPrototypeForwardLightListContents(
           shadingPrototypeForwardLightList,words)) {
      failShadingPrototypeForwardAfterTerminal(
          "readback-unavailable");
      return false;
      }

    uint32_t activeWords = 0u;
    uint32_t inactiveWords = 0u;
    uint32_t sentinelWords = 0u;
    uint32_t unexpectedWords = 0u;
    for(const uint32_t word:words) {
      if(word==Shader::ForwardLightListActiveValue)
        ++activeWords;
      else if(word==Shader::ForwardLightListInactiveValue)
        ++inactiveWords;
      else if(word==Shader::ForwardLightListSentinel)
        ++sentinelWords;
      else
        ++unexpectedWords;
      }
    const auto readbackSHA256 =
        rendererIOSShadingPrototypeForwardReadbackSHA256(words);
    const bool readbackExact =
        iosShadingPrototypeForwardLightListContentsMatch(words) &&
        std::string_view(readbackSHA256.data())==
            RendererIOSShadingPrototypeForwardExpectedReadbackSHA256;
    if(!readbackExact) {
      failShadingPrototypeForwardAfterTerminal(
          "readback-mismatch");
      return false;
      }
    try {
      Log::i(rendererIOSShadingPrototypeForwardMarkerText(
                 RendererIOSShadingPrototypeForwardSelfTestReadback),
             shadingPrototypeForwardNonce.data(),
             " bytes=",Shader::ForwardLightListByteSize,
             " words=",Shader::ForwardLightListWordCount,
             " exact=1 h=",readbackSHA256.data());
      }
    catch(...) {
      }

    IOSShadingPrototypeForwardTerminalReportV1 terminal =
        iosCanonicalShadingPrototypeForwardTerminalReportV1();
    terminal.terminalFenceWaitCalls =
        shadingPrototypeForwardFenceWaitCalls;
    terminal.terminalFenceZeroTimeoutCalls =
        shadingPrototypeForwardFenceWaitCalls;
    terminal.terminalFenceNonterminalPolls =
        shadingPrototypeForwardFenceNonterminalPolls;
    terminal.terminalFenceMonotonic =
        shadingPrototypeForwardFenceMonotonic ? 1u : 0u;
    terminal.terminalFenceMonotonicDeadlineUsed = 1u;
    terminal.directContentsAvailable = 1u;
    terminal.readbackCalls = 1u;
    terminal.firstWord = words[0];
    terminal.activeWords = activeWords;
    terminal.inactiveWords = inactiveWords;
    terminal.sentinelWords = sentinelWords;
    terminal.unexpectedWords = unexpectedWords;
    terminal.exactResult = readbackExact ? 1u : 0u;
    terminal.lightListLifetimeRetained =
        shadingPrototypeForwardLightListLifetimeLive() ? 1u : 0u;
    terminal.outputLifetimeRetained =
        shadingPrototypeForwardOutputLifetimeLive() ? 1u : 0u;
    terminal.commandBufferRetainedReferencesDisabledContract =
        shadingPrototypeForwardNativeReport.
            commandBufferRetainedReferencesDisabled;
    terminal.pipelineLiveAtTerminal =
        shadingPrototypeForwardPipeline ? 1u : 0u;
    terminal.outputLiveAtTerminal =
        shadingPrototypeForwardOutput ? 1u : 0u;
    terminal.lightListLiveAtTerminal =
        shadingPrototypeForwardLightList ? 1u : 0u;
    terminal.commandBufferLiveAtTerminal =
        shadingPrototypeForwardCommandActive ? 1u : 0u;
    terminal.captureOwnerInitializedAtTerminal =
        shadingPrototypeForwardCapture.initialized() ? 1u : 0u;
    terminal.captureActiveAtTerminal =
        shadingPrototypeForwardCapture.active() ? 1u : 0u;
    terminal.captureArtifactRetainedAtTerminal =
        shadingPrototypeForwardCaptureArtifact.bytes>0u ? 1u : 0u;
    terminal.fenceLiveAtTerminal =
        shadingPrototypeForwardFenceActive ? 1u : 0u;
    terminal.captureAcquisitionCalls =
        shadingPrototypeForwardCaptureAcquisitionCalls;
    terminal.captureAcquisitionFailures =
        shadingPrototypeForwardCaptureAcquisitionFailures;
    terminal.callerWaitIdleCalls =
        shadingPrototypeForwardWaitIdleCalls;

    releaseShadingPrototypeForwardOwnersAfterTerminal();

    terminal.outputLiveAfterReleaseDelta =
        shadingPrototypeForwardOutputLifetimeReleased() ? 0u : 1u;
    terminal.outputReleasedDelta =
        shadingPrototypeForwardOutputLifetimeReleased() ? 1u : 0u;
    terminal.lightListLiveAfterReleaseDelta =
        shadingPrototypeForwardLightListLifetimeReleased() ? 0u : 1u;
    terminal.lightListReleasedDelta =
        shadingPrototypeForwardLightListLifetimeReleased() ? 1u : 0u;
    terminal.pipelineReleasedAfterTerminal =
        !shadingPrototypeForwardPipeline ? 1u : 0u;
    terminal.outputReleasedAfterTerminal =
        !shadingPrototypeForwardOutput ? 1u : 0u;
    terminal.lightListReleasedAfterTerminal =
        !shadingPrototypeForwardLightList ? 1u : 0u;
    terminal.commandBufferReleasedAfterTerminal =
        !shadingPrototypeForwardCommandActive ? 1u : 0u;
    terminal.captureOwnerReleasedAfterTerminal =
        !shadingPrototypeForwardCapture.initialized() ? 1u : 0u;
    terminal.fenceReleasedAfterTerminal =
        !shadingPrototypeForwardFenceActive ? 1u : 0u;
    terminal.releaseOrderExact =
        shadingPrototypeForwardReleaseOrderExact &&
        terminal.pipelineReleasedAfterTerminal==1u &&
        terminal.outputReleasedAfterTerminal==1u &&
        terminal.lightListReleasedAfterTerminal==1u &&
        terminal.commandBufferReleasedAfterTerminal==1u &&
        terminal.captureOwnerReleasedAfterTerminal==1u &&
        terminal.fenceReleasedAfterTerminal==1u ? 1u : 0u;

    shadingPrototypeForwardTerminalReport = terminal;
    if(!iosValidateShadingPrototypeForwardTerminalReportV1(
           shadingPrototypeForwardTerminalReport) ||
       !shadingPrototypeForwardIsolationUnchanged()) {
      shadingPrototypeForwardState =
          ShadingPrototypeForwardSelfTestState::Failed;
      logShadingPrototypeForwardFailure(
          "terminal-lifetime-or-counter-mismatch");
      fail("RendererIOS shading prototype forward self-test failed",
           "terminal-lifetime-or-counter-mismatch");
      return false;
      }

    shadingPrototypeForwardState =
        ShadingPrototypeForwardSelfTestState::Passed;
    try {
      Log::i(rendererIOSShadingPrototypeForwardMarkerText(
                 RendererIOSShadingPrototypeForwardSelfTestPassed),
             shadingPrototypeForwardNonce.data(),
             " wait-idle=0 output=1/0/1 light-list=1/0/1 capture=1/0/1");
      }
    catch(...) {
      }
    return true;
    }

  void startShadingPrototypeForwardSelfTest() noexcept {
    namespace Pipeline =
        RendererIOSShadingPrototypeForwardPipeline;
    if(shadingPrototypeForwardStarted)
      return;
    shadingPrototypeForwardStarted = true;

    const char* nonceReason = nullptr;
    if(!rendererIOSShadingPrototypeForwardReadNonce(
           shadingPrototypeForwardNonce,nonceReason)) {
      shadingPrototypeForwardState =
          ShadingPrototypeForwardSelfTestState::Failed;
      try {
        Log::e("RendererIOS shading prototype forward preflight rejected: reason=",
               nonceReason!=nullptr ? nonceReason : "nonce-malformed",
               " side-effects=0");
        }
      catch(...) {
        }
      fail("RendererIOS shading prototype forward self-test failed",
           nonceReason!=nullptr ? nonceReason : "nonce-malformed");
      return;
      }

    static_assert(IOSShadingPrototypePlanABIVersion==1u);
    static_assert(Pipeline::OfflineMetallibAbi==9u);
    try {
      Log::i(rendererIOSShadingPrototypeForwardMarkerText(
             RendererIOSShadingPrototypeForwardSelfTestArmed),
             shadingPrototypeForwardNonce.data(),
             " contract=1 metallib-abi=9 minimum-apple=4");
      }
    catch(...) {
      }

    IOSShadingPrototypePlan plan;
    try {
      plan = iosShadingPrototypePlan(
          IOSShadingPrototypeKind::ForwardPlus);
      }
    catch(...) {
      failShadingPrototypeForwardBeforeSubmit(
          "plan-contract-mismatch");
      return;
      }
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(plan);
    const bool planMatches =
        bool(selection) &&
        selection.kind==IOSShadingPrototypeKind::ForwardPlus &&
        selection.presentResource==0u &&
        selection.outputResource==1u &&
        selection.workingResource==2u &&
        selection.computePass==0u &&
        selection.renderPass==1u &&
        selection.presentPass==2u &&
        plan.topology.commandBuffers==1u &&
        plan.topology.submits==1u &&
        plan.topology.renderEncoders==1u &&
        plan.topology.draws==2u &&
        plan.topology.tileDispatches==0u &&
        plan.topology.computeEncoders==1u &&
        plan.topology.drawableAcquisitions==0u &&
        plan.topology.presents==0u;
    if(!planMatches) {
      failShadingPrototypeForwardBeforeSubmit(
          "plan-contract-mismatch");
      return;
      }

    shadingPrototypeForwardIsolationBefore =
        shadingPrototypeForwardIsolationSnapshot();
    shadingPrototypeForwardOutputLifetimeBefore =
        iosMetalResourceLifetimeSnapshot();
    shadingPrototypeForwardLightListLifetimeBefore =
        iosShadingPrototypeForwardLightListLifetimeSnapshot();
    if(!rendererIOSShadingPrototypeForwardIsolationSnapshotAvailable(
           shadingPrototypeForwardIsolationBefore)) {
      failShadingPrototypeForwardBeforeSubmit(
          "snapshot-unavailable");
      return;
      }

    shadingPrototypeForwardPipeline =
        iosCreateShadingPrototypeForwardPipeline(device);
    if(shadingPrototypeForwardPipeline.status()==
       IOSShadingPrototypeForwardPipelineStatus::
           UnsupportedCapability) {
      const auto& report =
          shadingPrototypeForwardPipeline.report();
      const bool zeroSideEffects =
          !shadingPrototypeForwardPipeline &&
          !report.supportsApple4 &&
          !report.libraryAvailable &&
          report.resolvedFunctionCount==0u &&
          report.createdComputePipelineCount==0u &&
          report.createdRenderPipelineCount==0u &&
          !shadingPrototypeForwardOutput &&
          !shadingPrototypeForwardLightList &&
          !shadingPrototypeForwardCommandActive &&
          !shadingPrototypeForwardFenceActive &&
          !shadingPrototypeForwardCapture.initialized() &&
          shadingPrototypeForwardCaptureArtifact.bytes==0u &&
          shadingPrototypeForwardIsolationUnchanged();
      if(!zeroSideEffects) {
        failShadingPrototypeForwardBeforeSubmit(
            "factory-counter-mismatch");
        return;
        }
      shadingPrototypeForwardState =
          ShadingPrototypeForwardSelfTestState::Unsupported;
      try {
        Log::i(rendererIOSShadingPrototypeForwardMarkerText(
                   RendererIOSShadingPrototypeForwardSelfTestUnsupported),
               shadingPrototypeForwardNonce.data(),
               " reason=apple4-required side-effects=0");
        }
      catch(...) {
        }
      return;
      }

    const IOSShadingPrototypeForwardPipelineStatus factoryStatus =
        shadingPrototypeForwardPipeline.status();
    const auto& factoryReport =
        shadingPrototypeForwardPipeline.report();
    const IOSShadingPrototypeForwardPipelineStatus validationStatus =
        iosValidateShadingPrototypeForwardPipelineReport(
            factoryReport);
    if(!shadingPrototypeForwardPipeline ||
       factoryStatus!=
           IOSShadingPrototypeForwardPipelineStatus::Ready ||
       validationStatus!=
           IOSShadingPrototypeForwardPipelineStatus::Ready) {
      logShadingPrototypeForwardFactoryFailure(
          factoryStatus,validationStatus,factoryReport);
      failShadingPrototypeForwardBeforeSubmit(
          factoryStatus==
                  IOSShadingPrototypeForwardPipelineStatus::
                      ReflectionMismatch ||
              validationStatus==
                  IOSShadingPrototypeForwardPipelineStatus::
                      ReflectionMismatch
            ? "factory-reflection-mismatch"
            : "factory-contract-mismatch");
      return;
      }
    if(!shadingPrototypeForwardIsolationUnchanged()) {
      failShadingPrototypeForwardBeforeSubmit(
          "factory-counter-mismatch");
      return;
      }
    shadingPrototypeForwardState =
        ShadingPrototypeForwardSelfTestState::FactoryReady;
    try {
      Log::i(rendererIOSShadingPrototypeForwardMarkerText(
                 RendererIOSShadingPrototypeForwardSelfTestFactoryReady),
             shadingPrototypeForwardNonce.data(),
             " pipelines=3 reflection=1 runtime-delta=0 builtin-delta=0 archive-delta=0");
      }
    catch(...) {
      }

    const IOSResourceDesc& outputResource =
        plan.framePlan.resources[selection.outputResource];
    shadingPrototypeForwardOutput =
        resourceAllocator.allocate(outputResource);
    if(!shadingPrototypeForwardOutput ||
       !iosMetalTextureMatches(
           shadingPrototypeForwardOutput.snapshot(),outputResource,
           IOSMetalResourceStorage::Private) ||
       !shadingPrototypeForwardOutputLifetimeLive()) {
      failShadingPrototypeForwardBeforeSubmit(
          "output-allocation-or-lifetime-mismatch");
      return;
      }

    shadingPrototypeForwardLightList =
        iosCreateShadingPrototypeForwardLightList(device);
    if(!shadingPrototypeForwardLightList ||
       !iosValidateShadingPrototypeForwardLightListReportV1(
           shadingPrototypeForwardLightList.report()) ||
       !shadingPrototypeForwardLightListLifetimeLive() ||
       !shadingPrototypeForwardIsolationUnchanged()) {
      failShadingPrototypeForwardBeforeSubmit(
          "light-list-allocation-or-contract-mismatch");
      return;
      }

    const char* captureReason = nullptr;
    if(!shadingPrototypeForwardCapture.start(
           device,RendererIOSShadingPrototypeForwardCaptureName,
           captureReason)) {
      if(shadingPrototypeForwardCapture.active()) {
        failShadingPrototypeForwardAmbiguous(
            "capture-start-ambiguous",captureReason);
        }
      else {
        failShadingPrototypeForwardBeforeSubmit(
            "capture-start-failed",captureReason);
        }
      return;
      }

    try {
      shadingPrototypeForwardCommand = device.commandBuffer();
      shadingPrototypeForwardCommandActive = true;
      bool encodeAccepted = false;
      {
        auto encoder =
            shadingPrototypeForwardCommand.startEncoding(device);
        encodeAccepted = iosEncodeShadingPrototypeForwardProbe(
            device,encoder,shadingPrototypeForwardPipeline,
            shadingPrototypeForwardOutput,
            shadingPrototypeForwardLightList,
            shadingPrototypeForwardNativeReport);
        }
      if(!encodeAccepted) {
        failShadingPrototypeForwardBeforeSubmit(
            "native-encode-rejected");
        return;
        }
      if(!iosValidateShadingPrototypeForwardProbeReportV1(
             shadingPrototypeForwardNativeReport) ||
         !shadingPrototypeForwardOutputLifetimeLive() ||
         !shadingPrototypeForwardLightListLifetimeLive() ||
         !shadingPrototypeForwardIsolationUnchanged()) {
        failShadingPrototypeForwardBeforeSubmit(
            "encoded-contract-mismatch");
        return;
        }
      shadingPrototypeForwardState =
          ShadingPrototypeForwardSelfTestState::Encoded;
      Log::i(rendererIOSShadingPrototypeForwardMarkerText(
                 RendererIOSShadingPrototypeForwardSelfTestEncoded),
             shadingPrototypeForwardNonce.data(),
             " cb=1 compute=1 render=1 dispatch=1 draws=2 opaque=1 alpha=1 output=4x4 light-list=256 drawable=0 present=0");
      }
    catch(const std::exception& e) {
      failShadingPrototypeForwardBeforeSubmit(
          shadingPrototypeForwardCommandActive
            ? "native-encode-rejected"
            : "command-buffer-creation-failed",
          e.what());
      return;
      }
    catch(...) {
      failShadingPrototypeForwardBeforeSubmit(
          shadingPrototypeForwardCommandActive
            ? "native-encode-rejected"
            : "command-buffer-creation-failed");
      return;
      }

    try {
      Fence submitted =
          device.submit(shadingPrototypeForwardCommand);
      shadingPrototypeForwardFence = std::move(submitted);
      shadingPrototypeForwardFenceActive = true;
      shadingPrototypeForwardState =
          ShadingPrototypeForwardSelfTestState::Submitted;
      Log::i(rendererIOSShadingPrototypeForwardMarkerText(
                 RendererIOSShadingPrototypeForwardSelfTestSubmitted),
             shadingPrototypeForwardNonce.data(),
             " command-buffers=1 submits=1");
      }
    catch(const std::exception& e) {
      failShadingPrototypeForwardAmbiguous(
          "submit-exception-ambiguous",e.what());
      return;
      }
    catch(...) {
      failShadingPrototypeForwardAmbiguous(
          "submit-exception-ambiguous");
      return;
      }

    ++shadingPrototypeForwardCaptureAcquisitionCalls;
    if(!shadingPrototypeForwardCapture.stopAndInspect(
           shadingPrototypeForwardCaptureArtifact,captureReason)) {
      ++shadingPrototypeForwardCaptureAcquisitionFailures;
      failShadingPrototypeForwardAmbiguous(
          "capture-acquisition-failed",captureReason);
      return;
      }
    if(!shadingPrototypeForwardCapture.initialized() ||
       shadingPrototypeForwardCapture.active() ||
       shadingPrototypeForwardCaptureArtifact.bytes==0u) {
      ++shadingPrototypeForwardCaptureAcquisitionFailures;
      failShadingPrototypeForwardAmbiguous(
          "capture-acquisition-failed");
      return;
      }

    shadingPrototypeForwardState =
        ShadingPrototypeForwardSelfTestState::Acquired;
    shadingPrototypeForwardFencePollStarted =
        std::chrono::steady_clock::now();
    shadingPrototypeForwardFenceLastPoll =
        shadingPrototypeForwardFencePollStarted;
    try {
      Log::i(rendererIOSShadingPrototypeForwardMarkerText(
                 RendererIOSShadingPrototypeForwardCaptureAcquired),
             shadingPrototypeForwardNonce.data(),
             " file=",RendererIOSShadingPrototypeForwardCaptureName,
             " kind=",
             iosMetalCaptureArtifactKindName(
                 shadingPrototypeForwardCaptureArtifact.kind),
             " bytes=",
             shadingPrototypeForwardCaptureArtifact.bytes);
      }
    catch(...) {
      }
    }

  void pollShadingPrototypeForwardSelfTest() noexcept {
    namespace Probe = RendererIOSShadingPrototypeForwardProbe;
    if(!shadingPrototypeForwardStarted) {
      startShadingPrototypeForwardSelfTest();
      return;
      }
    if(shadingPrototypeForwardState!=
       ShadingPrototypeForwardSelfTestState::Acquired)
      return;

    const auto now = std::chrono::steady_clock::now();
    if(now<shadingPrototypeForwardFenceLastPoll) {
      shadingPrototypeForwardFenceMonotonic = false;
      failShadingPrototypeForwardAmbiguous(
          "terminal-fence-error");
      return;
    }
    shadingPrototypeForwardFenceLastPoll = now;
    const bool deadline =
        now-shadingPrototypeForwardFencePollStarted>=
            std::chrono::milliseconds(
                Probe::TerminalFenceDeadlineMilliseconds);
    if(deadline ||
       shadingPrototypeForwardFenceWaitCalls>=
           Probe::TerminalFenceMaximumPolls) {
      failShadingPrototypeForwardAmbiguous(
          "terminal-fence-timeout");
      return;
      }
    ++shadingPrototypeForwardFenceWaitCalls;
    try {
      if(shadingPrototypeForwardFence.wait(0u)) {
        (void)finishShadingPrototypeForwardAfterTerminal();
        return;
        }
      ++shadingPrototypeForwardFenceNonterminalPolls;
      if(shadingPrototypeForwardFenceWaitCalls>=
         Probe::TerminalFenceMaximumPolls)
        failShadingPrototypeForwardAmbiguous(
            "terminal-fence-timeout");
      }
    catch(const std::exception& e) {
      failShadingPrototypeForwardAmbiguous(
          "terminal-fence-error",e.what());
      }
    catch(...) {
      failShadingPrototypeForwardAmbiguous(
          "terminal-fence-error");
      }
    }

  void settleShadingPrototypeForwardAfterConfirmedIdle() noexcept {
    if(shadingPrototypeForwardState!=
       ShadingPrototypeForwardSelfTestState::Ambiguous)
      return;
    releaseShadingPrototypeForwardOwnersAfterTerminal();
    shadingPrototypeForwardState =
        ShadingPrototypeForwardSelfTestState::Failed;
    }
#endif

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
    const auto decision = Archive::advanceFlushStateAfterPresent(
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
      }
    const auto after =
      MetalApi::pipelineArchiveSnapshot(device);
    if(flushInvoked) {
      const bool dirtyAfter =
        (after.flags&MetalPipelineArchiveSnapshot::Dirty)!=0u;
      Archive::recordFlushResult(
        pipelineArchiveFlush,flushSucceeded,dirtyAfter);
      }
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
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    for(auto& frame:frames)
      failEmissiveInput(frame,"gpu","forced-termination");
#endif
    try {
      Log::e(operation,
             "; terminating without C++ teardown so in-flight GPU owners remain alive");
      }
    catch(...) {
      }
    std::_Exit(EXIT_FAILURE);
    }

  void resetTargets(IOSLinearHDRActivationAttempt attempt) noexcept {
    const uint32_t w = swapchain.w();
    const uint32_t h = swapchain.h();
    bool targetReady = false;
    uint64_t targetBytes = 0u;
    if(depthSupported && linearHDRMetal!=nullptr &&
       iosLinearHDRCheckedTargetByteSize({w,h},targetBytes) &&
       linearHDRTargets.generation!=std::numeric_limits<uint64_t>::max()) {
      try {
        LinearHDRTargets next;
        next.color = device.attachment(TextureFormat::R11G11B10UF,w,h);
        next.depth = device.zbuffer(depthFormat,w,h);
        next.extent = {w,h};
        next.generation = linearHDRTargets.generation+1u;
        targetReady = next.current(w,h) &&
                      linearHDRMetal->exactTarget(next.color,w,h);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        if(targetReady && linearHDRProof!=nullptr &&
           linearHDRProof->armed())
          (void)linearHDRProof->labelSceneTarget(next.color);
#endif
        if(targetReady)
          linearHDRTargets = std::move(next);
        }
      catch(...) {
        targetReady = false;
        }
      }
    linearHDRPolicy = iosEvaluateLinearHDRPolicy(
      true,linearHDRProbe,
      IOSLinearHDRActivationStatus{
        targetReady,
        gpuScene!=nullptr && gpuScene->pipelinesReady(),
        linearHDRMetal!=nullptr && linearHDRMetal->resolvePipelineReady(),
        });
    const IOSLinearHDRSafetyTransition transition =
        iosAdvanceLinearHDRSafetyState(
          linearHDRSafety,attempt,linearHDRPolicy);
    if(transition.protocolValid)
      linearHDRSafety = transition.state;
    else
      linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
    const char* attemptName = "invalid";
    switch(attempt) {
      case IOSLinearHDRActivationAttempt::Startup:
        attemptName = "startup";
        break;
      case IOSLinearHDRActivationAttempt::Recreate:
        attemptName = "recreate";
        break;
      }
    try {
      Log::i("RendererIOS linear HDR activation: attempt=",attemptName,
             " probe=",
             linearHDRProbe.reason()==IOSLinearHDRProbeReason::None ? 1 : 0,
             " target=",targetReady ? 1 : 0,
             " scene=",gpuScene!=nullptr && gpuScene->pipelinesReady() ? 1 : 0,
             " resolve=",linearHDRMetal!=nullptr &&
                           linearHDRMetal->resolvePipelineReady() ? 1 : 0,
             " ready=",linearHDRPolicy.ready ? 1 : 0,
             " safe=",linearHDRSafety.mode==
                         IOSLinearHDRSafetyMode::SafeNoScene ? 1 : 0,
             " bytes=",targetReady ? targetBytes : 0u,
             " generation=",linearHDRTargets.generation);
      }
    catch(...) {
      }
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

  void markLinearHDRTerminalFailed(FrameContext& frame) noexcept {
    if(!frame.linearHDRTerminalPending)
      return;
    (void)iosAdvanceLinearHDRFrameSequence(
      frame.linearHDRSequence,
      IOSLinearHDRFrameEvent::TerminalFailed,
      frame.linearHDRSequence.identity());
    frame.linearHDRTerminalPending = false;
    }

  void neutralizeFences() noexcept {
    // Tempest::Fence::~Fence() waits and can throw for a completed Metal error.
    // Move-assigning an empty wrapper releases it without invoking that wait.
    for(auto& frame:frames) {
      markLinearHDRTerminalFailed(frame);
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
      failEmissiveInput(frame,"gpu","terminal-abandoned");
#endif
      frame.fence     = Fence();
      frame.submitted = false;
      frame.linearHDRSequence = {};
      frame.linearHDRPolicyReadyAtEncode = false;
      frame.linearHDRTerminalPending = false;
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

#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
  static constexpr std::string_view emissiveModeName() noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE) && \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A)
    return "multiply2-a-hdr";
#elif defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    return "multiply2-b-hdr";
#elif defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A)
    return "additive-a-hdr";
#else
    return "additive-b-hdr";
#endif
    }

  static constexpr bool emissiveBuildShaIsValid() noexcept {
    constexpr std::string_view sha = OPENGOTHIC_RENDERER_IOS_BUILD_SHA;
    if(sha.size()!=40u)
      return false;
    for(char value:sha) {
      if(!((value>='0' && value<='9') ||
           (value>='a' && value<='f')))
        return false;
      }
    return true;
    }

  static void clearEmissiveInput(FrameContext& frame) noexcept {
    frame.emissiveInput = {};
    frame.emissivePreparedSerial = 0u;
    frame.emissiveSubmittedSerial = 0u;
    frame.emissiveSubmitAccepted = false;
    frame.emissivePresentAccepted = false;
    frame.emissiveTerminalReported = false;
    }

  static void logEmissiveTerminalFailure(
      uint64_t generation, uint64_t sequence,
      const char* failureClass, const char* reason) noexcept {
    (void)generation;
    (void)sequence;
    try {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
      Log::e("RendererIOS multiply2 causal: v=1 mode=",emissiveModeName(),
             " terminal=F class=",failureClass," reason=",reason);
#else
      Log::e("RendererIOS additive causal: v=1 mode=",emissiveModeName(),
             " terminal=F class=",failureClass," reason=",reason);
#endif
      }
    catch(...) {
      }
    }

  void failEmissiveInput(
      FrameContext& frame,
      const char* failureClass, const char* reason) noexcept {
    if(frame.emissiveInput && !frame.emissiveTerminalReported &&
       !emissiveProfileTerminalReported) {
      emissiveProfileClaimed = true;
      emissiveProfileTerminalReported = true;
      frame.emissiveTerminalReported = true;
      logEmissiveTerminalFailure(
          frame.emissiveInput.generation,frame.emissiveInput.sequence,
          failureClass,reason);
      }
    frame.emissiveInput = {};
    frame.emissivePreparedSerial = 0u;
    frame.emissiveSubmittedSerial = 0u;
    frame.emissiveSubmitAccepted = false;
    frame.emissivePresentAccepted = false;
    }

  void failUnclaimedEmissiveProfile(
      uint64_t generation, uint64_t sequence,
      const char* failureClass, const char* reason) noexcept {
    if(emissiveProfileClaimed || emissiveProfileTerminalReported)
      return;
    emissiveProfileClaimed = true;
    emissiveProfileTerminalReported = true;
    logEmissiveTerminalFailure(
        generation,sequence,failureClass,reason);
    }

  static std::array<char,CC_SHA256_DIGEST_LENGTH*2u+1u>
      emissiveArtifactSha256(
          std::span<const std::byte> bytes) noexcept {
    std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> digest{};
    std::array<char,CC_SHA256_DIGEST_LENGTH*2u+1u> encoded{};
    if(bytes.empty() ||
       bytes.size()>std::numeric_limits<CC_LONG>::max() ||
       CC_SHA256(bytes.data(),static_cast<CC_LONG>(bytes.size()),
                 digest.data())==nullptr)
      return encoded;
    constexpr char Hex[] = "0123456789abcdef";
    for(std::size_t index=0u; index<digest.size(); ++index) {
      encoded[index*2u] = Hex[digest[index] >> 4u];
      encoded[index*2u+1u] = Hex[digest[index]&0x0fu];
      }
    return encoded;
    }

  bool publishEmissiveInputAfterTerminal(FrameContext& frame) noexcept {
    if(!frame.emissiveInput)
      return true;
    if(!emissiveBuildShaIsValid()) {
      failEmissiveInput(frame,"contract","build-sha");
      return false;
      }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    IOSMultiply2InputArtifactViewV1 view;
    if(iosParseMultiply2InputArtifactV1(
           frame.emissiveInput.bytes,view)!=
       IOSMultiply2InputArtifactError::None) {
#else
    IOSAdditiveInputArtifactViewV1 view;
    if(iosParseAdditiveInputArtifactV1(
           frame.emissiveInput.bytes,view)!=
       IOSAdditiveInputArtifactError::None) {
#endif
      failEmissiveInput(frame,"contract","artifact-parse");
      return false;
      }
    if(!frame.emissivePresentAccepted ||
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
       !iosMultiply2InputArtifactV1AcceptsPublication(
#else
       !iosAdditiveInputArtifactV1AcceptsPublication(
#endif
           view.header,frame.emissivePreparedSerial,
           frame.emissiveSubmittedSerial,frame.submitted,
           frame.emissiveSubmitAccepted,true,true,
           frame.linearHDRSequence.identity().targetGeneration,
           frame.linearHDRSequence.identity().snapshotSequence)) {
      failEmissiveInput(frame,"contract","publication-admission");
      return false;
      }
    const char* home = std::getenv("HOME");
    if(home==nullptr || home[0]=='\0') {
      failEmissiveInput(frame,"io","documents-directory");
      return false;
      }
    std::string directory;
    std::string temporaryTag;
    try {
      directory = home;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
      directory += "/Documents/RendererIOS-multiply2-evidence";
#else
      directory += "/Documents";
#endif
      temporaryTag = "runtime-"+
          std::to_string(frame.emissivePreparedSerial);
      }
    catch(...) {
      failEmissiveInput(frame,"io","documents-directory");
      return false;
      }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(::mkdir(directory.c_str(),0700)!=0 && errno!=EEXIST) {
      failEmissiveInput(frame,"io","evidence-directory-create");
      return false;
      }
    struct stat evidenceDirectoryStatus{};
    if(::lstat(directory.c_str(),&evidenceDirectoryStatus)!=0 ||
       !S_ISDIR(evidenceDirectoryStatus.st_mode) ||
       (evidenceDirectoryStatus.st_mode&0777u)!=0700u ||
       evidenceDirectoryStatus.st_uid!=::getuid()) {
      failEmissiveInput(frame,"io","evidence-directory-policy");
      return false;
      }
#endif
    std::string terminal;
    const auto materializeEmissiveTerminal =
        [&](std::span<const std::byte> authenticatedBytes) noexcept {
      const auto sha = emissiveArtifactSha256(authenticatedBytes);
      if(sha[0]=='\0')
        return false;
      try {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
        terminal = "RendererIOS multiply2 causal: v=1 mode=";
#else
        terminal = "RendererIOS additive causal: v=1 mode=";
#endif
        terminal += emissiveModeName();
        terminal += " b=" OPENGOTHIC_RENDERER_IOS_BUILD_SHA " g=";
        terminal += std::to_string(view.header.targetGeneration);
        terminal += " s=";
        terminal += std::to_string(view.header.snapshotSequence);
        terminal += " base=";
        terminal += std::to_string(view.header.baseCount);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
        terminal += " multiply2=";
        terminal += std::to_string(view.header.multiply2Count);
#else
        terminal += " additive=";
        terminal += std::to_string(view.header.additiveCount);
#endif
        terminal += " input=";
        terminal += sha.data();
        terminal += " terminal=C";
        return true;
        }
      catch(...) {
        return false;
        }
      };
#if !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(!materializeEmissiveTerminal(frame.emissiveInput.bytes)) {
      failEmissiveInput(frame,"contract","terminal-marker");
      return false;
      }
#endif
    std::string publishedPath;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    std::vector<std::byte> publishedBytes;
    IOSMultiply2InputPublishResult publishResult =
        IOSMultiply2InputPublishResult::InvalidArgument;
#else
    IOSAdditiveInputPublishResult publishResult =
        IOSAdditiveInputPublishResult::InvalidArgument;
#endif
    try {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
      publishResult = iosPublishMultiply2InputArtifactV1NoClobber(
#else
      publishResult = iosPublishAdditiveInputArtifactV1NoClobber(
#endif
          directory,frame.emissiveInput.mode,
          frame.emissiveInput.generation,
          frame.emissiveInput.sequence,
          frame.emissiveInput.bytes,temporaryTag,publishedPath
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
          ,publishedBytes
#endif
          );
      }
    catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
      publishResult = IOSMultiply2InputPublishResult::PublishFailed;
#else
      publishResult = IOSAdditiveInputPublishResult::PublishFailed;
#endif
      }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(publishResult!=IOSMultiply2InputPublishResult::Published) {
#else
    if(publishResult!=IOSAdditiveInputPublishResult::Published) {
#endif
      failEmissiveInput(frame,"io","artifact-publish");
      return false;
      }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(!materializeEmissiveTerminal(publishedBytes)) {
      failEmissiveInput(frame,"contract","terminal-marker");
      return false;
      }
#endif
    try {
      Log::i(terminal);
      }
    catch(...) {
      }
    emissiveProfileTerminalReported = true;
    clearEmissiveInput(frame);
    return true;
    }
#endif

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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    if(linearHDRProof!=nullptr &&
       linearHDRProof->hasOwners(frame.linearHDRProof))
      linearHDRProof->markSubmitAmbiguous(frame.linearHDRProof);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(multiply2Coverage!=nullptr &&
       multiply2Coverage->hasOwners(frame.multiply2Coverage))
      multiply2Coverage->markSubmitAmbiguous(frame.multiply2Coverage);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    if(linearHDRProof!=nullptr &&
       linearHDRProof->captureHasOwners(frame.linearHDRCapture))
      linearHDRProof->markCaptureSubmitAmbiguous(frame.linearHDRCapture);
#endif
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    failEmissiveInput(frame,"gpu","submit-ambiguous");
#endif
    frame.discardCommandAfterIdle = true;
    frameActive  = false;
    activeSerial = 0;
    }

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
  void retainLinearHDRCapturePreSubmitFailure(
      FrameContext& frame) noexcept {
    if(linearHDRProof!=nullptr) {
      if(!frame.submitted &&
         linearHDRProof->hasOwners(frame.linearHDRProof))
        linearHDRProof->abortBeforeSubmit(frame.linearHDRProof);
      if(linearHDRProof->captureHasOwners(frame.linearHDRCapture))
        linearHDRProof->markCapturePreSubmitFailure(
            frame.linearHDRCapture);
      }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(multiply2Coverage!=nullptr && !frame.submitted &&
       multiply2Coverage->hasOwners(frame.multiply2Coverage))
      multiply2Coverage->abortBeforeSubmit(frame.multiply2Coverage);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    failEmissiveInput(frame,"gpu","pre-submit");
#endif
    clearPreparedUi(frame);
    frame.discardCommandAfterIdle = true;
    frameActive = false;
    activeSerial = 0;
    }
#endif

  void cancelActiveFrame() noexcept {
    if(frameActive) {
      auto& frame = frames[nextSlot];
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      if(linearHDRProof!=nullptr &&
         linearHDRProof->captureHasOwners(frame.linearHDRCapture)) {
        retainLinearHDRCapturePreSubmitFailure(frame);
        return;
        }
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      if(linearHDRProof!=nullptr &&
         linearHDRProof->hasOwners(frame.linearHDRProof)) {
        linearHDRProof->abortBeforeSubmit(frame.linearHDRProof);
        discardUnsubmittedCommand(frame);
        linearHDRProof->releaseAfterTerminal(frame.linearHDRProof);
        }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
      if(multiply2Coverage!=nullptr &&
         multiply2Coverage->hasOwners(frame.multiply2Coverage)) {
        multiply2Coverage->abortBeforeSubmit(frame.multiply2Coverage);
        multiply2Coverage->releaseAfterTerminal(frame.multiply2Coverage);
        }
#endif
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
      failEmissiveInput(frame,"gpu","pre-submit");
#endif
      clearPreparedUi(frame);
      releaseVideoFrame(frame);
      frame.linearHDRSequence = {};
      frame.linearHDRPolicyReadyAtEncode = false;
      frame.linearHDRTerminalPending = false;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      frame.functionalEvidence = {};
#endif
      }
    frameActive  = false;
    activeSerial = 0;
    }

  void retireSlotAfterTerminal(FrameContext& frame) noexcept {
    markLinearHDRTerminalFailed(frame);
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    failEmissiveInput(frame,"gpu","terminal-retire");
#endif
    frame.submitted = false;
    clearPreparedUi(frame);
    releaseVideoFrame(frame);
    releaseSceneFrame(frame);
    frame.linearHDRSequence = {};
    frame.linearHDRPolicyReadyAtEncode = false;
    frame.linearHDRTerminalPending = false;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    frame.functionalEvidence = {};
    if(linearHDRProof!=nullptr)
      linearHDRProof->releaseAfterTerminal(frame.linearHDRProof);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(multiply2Coverage!=nullptr)
      multiply2Coverage->releaseAfterTerminal(frame.multiply2Coverage);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    if(linearHDRProof!=nullptr)
      linearHDRProof->releaseCaptureAfterTerminal(frame.linearHDRCapture);
#endif
#endif
    }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  void markLinearHDRProofFenceFailure(FrameContext& frame) noexcept {
    if(linearHDRProof!=nullptr)
      linearHDRProof->markFenceFailure(frame.linearHDRProof);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(multiply2Coverage!=nullptr)
      multiply2Coverage->markPostSubmitFailure(frame.multiply2Coverage);
#endif
    }

  void markLinearHDRProofIdleFailure() noexcept {
    if(linearHDRProof==nullptr)
      return;
    for(auto& frame:frames)
      linearHDRProof->markIdleFailure(frame.linearHDRProof);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(multiply2Coverage!=nullptr) {
      for(auto& frame:frames)
        multiply2Coverage->markIdleFailure(frame.multiply2Coverage);
      }
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    for(auto& frame:frames)
      linearHDRProof->markCaptureIdleFailure(frame.linearHDRCapture);
#endif
    }

  void markLinearHDRProofPostSubmitFailure(FrameContext& frame) noexcept {
    if(linearHDRProof!=nullptr)
      linearHDRProof->markPostSubmitFailure(frame.linearHDRProof);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(multiply2Coverage!=nullptr)
      multiply2Coverage->markPostSubmitFailure(frame.multiply2Coverage);
#endif
    }

  void releaseLinearHDRProofFramesAfterTerminal() noexcept {
    if(linearHDRProof==nullptr)
      return;
    for(auto& frame:frames)
      linearHDRProof->releaseAfterTerminal(frame.linearHDRProof);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(multiply2Coverage!=nullptr) {
      for(auto& frame:frames)
        multiply2Coverage->releaseAfterTerminal(frame.multiply2Coverage);
      }
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    for(auto& frame:frames)
      linearHDRProof->releaseCaptureAfterTerminal(frame.linearHDRCapture);
#endif
    }

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
  void settleLinearHDRCapturesAfterConfirmedIdle() noexcept {
    if(linearHDRProof==nullptr)
      return;
    for(auto& frame:frames) {
      if(linearHDRProof->captureRequiresNoTeardown(
           frame.linearHDRCapture))
        terminateWithoutTeardown(
          "RendererIOS HDR capture has permanent start ambiguity");
      if(!linearHDRProof->settleCaptureAfterConfirmedIdle(
           frame.linearHDRCapture))
        terminateWithoutTeardown(
          "RendererIOS HDR capture could not confirm inactive state");
      }
    }

  bool hasLinearHDRCaptureOwners() const noexcept {
    if(linearHDRProof==nullptr)
      return false;
    for(const auto& frame:frames) {
      if(linearHDRProof->captureHasOwners(frame.linearHDRCapture))
        return true;
      }
    return false;
    }

  void terminateLinearHDRCaptureOnUnconfirmedIdle() noexcept {
    if(hasLinearHDRCaptureOwners())
      terminateWithoutTeardown(
        "RendererIOS HDR capture idle was not confirmed; retry is forbidden");
    }
#endif

  bool materializeLinearHDRProofAfterTerminal(
      FrameContext& frame, bool deviceAlreadyIdle = false,
      bool* idleConfirmed = nullptr) noexcept {
    if(idleConfirmed!=nullptr)
      *idleConfirmed = deviceAlreadyIdle;
    if(linearHDRProof==nullptr ||
       !linearHDRProof->isSubmitted(frame.linearHDRProof))
      return true;
    if(linearHDRProof->state()==
         IOSLinearHDRProofProducerState::Submitted &&
       !deviceAlreadyIdle) {
      try {
        device.waitIdle();
        if(idleConfirmed!=nullptr)
          *idleConfirmed = true;
        }
      catch(const std::exception& e) {
        linearHDRProof->markIdleFailure(frame.linearHDRProof);
        fail("RendererIOS HDR proof terminal idle failed",e.what());
        return false;
        }
      catch(...) {
        linearHDRProof->markIdleFailure(frame.linearHDRProof);
        fail("RendererIOS HDR proof terminal idle failed");
        return false;
        }
      }
    const bool presentHealthy = takePresentFailureAndLatchProof(
        "RendererIOS HDR proof terminal present failed");
    linearHDRProof->completeAfterTerminal(
        frame.linearHDRProof,linearHDRTargets.generation,
        linearHDRTargets.extent.width,linearHDRTargets.extent.height);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(multiply2Coverage==nullptr ||
       !multiply2Coverage->completeAfterTerminal(
           frame.multiply2Coverage,linearHDRTargets.generation,
           linearHDRTargets.extent.width,linearHDRTargets.extent.height))
      return false;
#endif
    return presentHealthy;
    }
#endif

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

  bool materializeLinearHDREvidenceAfterTerminal(
      FrameContext& frame, bool deviceAlreadyIdle = false) noexcept {
    if(!frame.linearHDRTerminalPending)
      return true;
    if(linearHDRProven.proven) {
      const bool completed = iosAdvanceLinearHDRFrameSequence(
          frame.linearHDRSequence,
          IOSLinearHDRFrameEvent::TerminalCompleted,
          frame.linearHDRSequence.identity())==
            IOSLinearHDRFrameError::None;
      frame.linearHDRTerminalPending = false;
      if(!completed) {
        linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
        fail("RendererIOS linear HDR terminal sequence failed");
        }
      return completed;
      }
    if(frame.linearHDRSequence.route()!=IOSLinearHDRFrameRoute::Scene) {
      const bool completed = iosAdvanceLinearHDRFrameSequence(
          frame.linearHDRSequence,
          IOSLinearHDRFrameEvent::TerminalCompleted,
          frame.linearHDRSequence.identity())==
            IOSLinearHDRFrameError::None;
      frame.linearHDRTerminalPending = false;
      return completed;
      }
#if !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    (void)deviceAlreadyIdle;
    const bool completed =
        iosAdvanceLinearHDRFrameSequence(
          frame.linearHDRSequence,
          IOSLinearHDRFrameEvent::TerminalCompleted,
          frame.linearHDRSequence.identity())==
            IOSLinearHDRFrameError::None &&
        iosLinearHDRCommitProvenEvidence(
          frame.linearHDRPolicyReadyAtEncode,
          frame.linearHDRSequence,linearHDRProven);
    frame.linearHDRTerminalPending = false;
    if(!completed) {
      linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
      fail("RendererIOS linear HDR terminal sequence failed");
      }
    return completed;
#else
    if(!deviceAlreadyIdle) {
      try {
        device.waitIdle();
        }
      catch(const std::exception& e) {
        (void)iosAdvanceLinearHDRFrameSequence(
          frame.linearHDRSequence,
          IOSLinearHDRFrameEvent::TerminalFailed,
          frame.linearHDRSequence.identity());
        frame.linearHDRTerminalPending = false;
        fail("RendererIOS linear HDR terminal settle failed",e.what());
        return false;
        }
      catch(...) {
        (void)iosAdvanceLinearHDRFrameSequence(
          frame.linearHDRSequence,
          IOSLinearHDRFrameEvent::TerminalFailed,
          frame.linearHDRSequence.identity());
        frame.linearHDRTerminalPending = false;
        fail("RendererIOS linear HDR terminal settle failed");
        return false;
        }
      }
    if(!takePresentFailureAndLatchProof(
         "RendererIOS linear HDR terminal present failed")) {
      (void)iosAdvanceLinearHDRFrameSequence(
        frame.linearHDRSequence,
        IOSLinearHDRFrameEvent::TerminalFailed,
        frame.linearHDRSequence.identity());
      frame.linearHDRTerminalPending = false;
      return false;
      }
    if(iosAdvanceLinearHDRFrameSequence(
         frame.linearHDRSequence,
         IOSLinearHDRFrameEvent::TerminalCompleted,
         frame.linearHDRSequence.identity())!=
           IOSLinearHDRFrameError::None ||
       !iosLinearHDRCommitProvenEvidence(
         frame.linearHDRPolicyReadyAtEncode,
         frame.linearHDRSequence,linearHDRProven)) {
      frame.linearHDRTerminalPending = false;
      linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
      fail("RendererIOS linear HDR terminal sequence failed");
      return false;
      }
    const IOSLinearHDRFrameIdentity identity =
        frame.linearHDRSequence.identity();
    try {
      Log::i("RendererIOS linear HDR: v=1 b=",
             OPENGOTHIC_RENDERER_IOS_BUILD_SHA,
             " g=",identity.targetGeneration,
             " s=",identity.snapshotSequence,
             " w=",identity.extent.width,
             " h=",identity.extent.height,
             " fmt=rg11b10f probe=1 target=1 scene=1 resolve=1 ui=",
             frame.linearHDRSequence.overlayHasUI() ? 1 : 0,
             " present=1 terminal=C");
      }
    catch(...) {
      }
    frame.linearHDRTerminalPending = false;
    return true;
#endif
    }

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

  bool takePresentFailureAndLatchProof(const char* operation) noexcept {
    const PresentFailure failure = device.takePresentFailure();
    if(!failure)
      return !failed;

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    if(linearHDRProof!=nullptr) {
      for(auto& frame:frames) {
        if(linearHDRProof->isSubmitted(frame.linearHDRProof))
          linearHDRProof->latchPresentFailure(frame.linearHDRProof);
        }
      }
#endif

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
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
    const bool forwardAcquiredBeforeWaitIdle =
        shadingPrototypeForwardState==
            ShadingPrototypeForwardSelfTestState::Acquired;
    if(forwardAcquiredBeforeWaitIdle) {
      ++shadingPrototypeForwardWaitIdleCalls;
      failShadingPrototypeForwardAmbiguous("wait-idle-used");
      }
    if(!rendererIOSShadingPrototypeForwardMayWaitIdle(
           forwardAcquiredBeforeWaitIdle,failed)) {
      fail("RendererIOS shading prototype forward self-test failed",
           "wait-idle-gate-invariant");
      return false;
    }
#endif
    if(fault.shutdownIdleUnconfirmedOnce(reason,counters.presentAccepted)) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      markLinearHDRProofIdleFailure();
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      terminateLinearHDRCaptureOnUnconfirmedIdle();
#endif
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      markLinearHDRProofIdleFailure();
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      terminateLinearHDRCaptureOnUnconfirmedIdle();
#endif
      forcePreviewPlaceholder();
      fail(operation,e.what());
      return false;
      }
    catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      markLinearHDRProofIdleFailure();
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      terminateLinearHDRCaptureOnUnconfirmedIdle();
#endif
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

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
    settleClearOnlyPassAfterConfirmedIdle();
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
    settleShadingPrototypeTileAfterConfirmedIdle();
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
    settleShadingPrototypeForwardAfterConfirmedIdle();
#endif

    // Metal Device::waitIdle() only waits for completion. Classify every proof
    // slot before any fence or retainedReferences=false owner is released,
    // even if another slot has already made the global context fatal.
    std::array<char,256u> firstFenceFailure{};
    bool fencesHealthy = true;
    for(size_t index=0u; index<frames.size(); ++index) {
      auto& frame = frames[index];
      try {
        if(!frame.fence.wait(0)) {
          fencesHealthy = false;
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
          markLinearHDRProofFenceFailure(frame);
#endif
          if(firstFenceFailure[0]=='\0')
            std::snprintf(firstFenceFailure.data(),firstFenceFailure.size(),
                          "%s","frame fence was not terminal after device idle");
          continue;
          }
        }
      catch(const std::exception& e) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        markLinearHDRProofFenceFailure(frame);
#endif
        fencesHealthy = false;
        if(firstFenceFailure[0]=='\0')
          std::snprintf(firstFenceFailure.data(),firstFenceFailure.size(),
                        "%s",e.what());
        }
      catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        markLinearHDRProofFenceFailure(frame);
#endif
        fencesHealthy = false;
        if(firstFenceFailure[0]=='\0')
          std::snprintf(firstFenceFailure.data(),firstFenceFailure.size(),
                        "%s","frame fence failed after device idle");
        }
      }

    const bool mailboxHealthy = takePresentFailureAndLatchProof(
        "RendererIOS asynchronous Metal present failed");
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    for(size_t index=0u; index<frames.size(); ++index)
      (void)materializeLinearHDRProofAfterTerminal(frames[index],true);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    // Numeric classification/materialization happens while the capture,
    // command and all borrowed-resource owners remain alive. Only a confirmed
    // inactive capture permits the release chain below.
    settleLinearHDRCapturesAfterConfirmedIdle();
#endif
    if(!fencesHealthy) {
      forcePreviewPlaceholder();
      fail(operation,firstFenceFailure.data());
      }

    bool presentHealthy = fencesHealthy && mailboxHealthy && !failed;
    if(presentHealthy) {
      for(auto& frame:frames) {
        if(!materializeLinearHDREvidenceAfterTerminal(frame,true)) {
          presentHealthy = false;
          break;
          }
        }
      }
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    if(presentHealthy) {
      for(auto& frame:frames) {
        if(!publishEmissiveInputAfterTerminal(frame)) {
          presentHealthy = false;
          fail("RendererIOS emissive input publication failed");
          break;
          }
        }
      }
#endif
    releaseRetainedPreviewAfterIdle();

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
    // A throwing submit or captured pre-submit failure can release its command
    // only after idle and fence classification, while numeric/capture owners
    // are still alive.
    discardAmbiguousCommandsAfterConfirmedIdle();
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    releaseLinearHDRProofFramesAfterTerminal();
#endif
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
      if(!idleConfirmed) {
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
        if(hasLinearHDRCaptureOwners())
          terminateWithoutTeardown(
            "RendererIOS HDR capture idle was not confirmed; retry is forbidden");
#endif
        continue;
        }
      if(cleanResult!=nullptr)
        *cleanResult = clean;
      return true;
      }
    return false;
    }

  Device&                                      device;
  const IOSDeviceFactsCreateResult             deviceFacts;
  std::optional<IOSFeaturePolicyProvenance>     featurePolicyProvenance;
  IOSFeatureTelemetryGate                      featurePolicyTelemetryGate;
  IOSMetalResourceAllocator                    resourceAllocator;
#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
  // Declaration order is the retainedReferences=false ownership contract:
  // capture is stopped explicitly after submit; reverse destruction otherwise
  // stops it before dropping fence, command, Memoryless, then Private.
  IOSMetalResourceTexture                      clearOnlyPrivateTexture;
  IOSMetalResourceTexture                      clearOnlyMemorylessTexture;
  CommandBuffer                                clearOnlyCommand;
  Fence                                        clearOnlyFence;
  IOSMetalResourceClearPassCapture             clearOnlyCapture;
  IOSMetalCaptureArtifact                      clearOnlyCaptureArtifact;
  MetalRuntimeCompilationSnapshot              clearOnlyRuntimeBefore;
  MetalBuiltinRuntimeSnapshot                  clearOnlyBuiltinRuntimeBefore;
  IOSMetalResourceLifetimeSnapshot             clearOnlyLifetimeBefore;
  IOSMetalResourceClearPassNativeReport        clearOnlyNativeReport;
  ClearOnlyPassSelfTestState                   clearOnlyPassState =
                                                  ClearOnlyPassSelfTestState::Armed;
  bool                                         clearOnlyPassStarted = false;
  bool                                         clearOnlyCommandActive = false;
  bool                                         clearOnlyFenceActive = false;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
  // Explicit terminal release is authoritative. Reverse destruction is still
  // fail-safe: capture, fence and command drop before the pipeline/output
  // handles borrowed by the retainedReferences=false command.
  IOSMetalResourceTexture
      shadingPrototypeTileOutput;
  IOSShadingPrototypePipeline
      shadingPrototypeTilePipeline;
  CommandBuffer
      shadingPrototypeTileCommand;
  Fence
      shadingPrototypeTileFence;
  IOSMetalCaptureSession
      shadingPrototypeTileCapture;
  IOSMetalCaptureArtifact
      shadingPrototypeTileCaptureArtifact;
  RendererIOSShadingPrototypeTileIsolationSnapshot
      shadingPrototypeTileIsolationBefore;
  IOSMetalResourceLifetimeSnapshot
      shadingPrototypeTileLifetimeBefore;
  IOSShadingPrototypeTileProbeReport
      shadingPrototypeTileNativeReport;
  ShadingPrototypeTileSelfTestState
      shadingPrototypeTileState =
          ShadingPrototypeTileSelfTestState::Armed;
  bool
      shadingPrototypeTileStarted = false;
  bool
      shadingPrototypeTileCommandActive = false;
  bool
      shadingPrototypeTileFenceActive = false;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
  // Explicit terminal release is authoritative. Reverse destruction is a
  // fail-safe that drops capture/fence/command before their unretained
  // pipeline, buffer and texture owners.
  IOSMetalResourceTexture
      shadingPrototypeForwardOutput;
  IOSShadingPrototypeForwardPipeline
      shadingPrototypeForwardPipeline;
  IOSShadingPrototypeForwardLightList
      shadingPrototypeForwardLightList;
  CommandBuffer
      shadingPrototypeForwardCommand;
  Fence
      shadingPrototypeForwardFence;
  IOSMetalCaptureSession
      shadingPrototypeForwardCapture;
  IOSMetalCaptureArtifact
      shadingPrototypeForwardCaptureArtifact;
  RendererIOSShadingPrototypeForwardIsolationSnapshot
      shadingPrototypeForwardIsolationBefore;
  IOSMetalResourceLifetimeSnapshot
      shadingPrototypeForwardOutputLifetimeBefore;
  IOSShadingPrototypeForwardLightListLifetimeSnapshot
      shadingPrototypeForwardLightListLifetimeBefore;
  IOSShadingPrototypeForwardProbeReportV1
      shadingPrototypeForwardNativeReport;
  IOSShadingPrototypeForwardTerminalReportV1
      shadingPrototypeForwardTerminalReport;
  ShadingPrototypeForwardSelfTestState
      shadingPrototypeForwardState =
          ShadingPrototypeForwardSelfTestState::Armed;
  std::array<char,33u>
      shadingPrototypeForwardNonce{};
  std::chrono::steady_clock::time_point
      shadingPrototypeForwardFencePollStarted{};
  std::chrono::steady_clock::time_point
      shadingPrototypeForwardFenceLastPoll{};
  uint32_t
      shadingPrototypeForwardFenceWaitCalls = 0u;
  uint32_t
      shadingPrototypeForwardFenceNonterminalPolls = 0u;
  uint32_t
      shadingPrototypeForwardCaptureAcquisitionCalls = 0u;
  uint32_t
      shadingPrototypeForwardCaptureAcquisitionFailures = 0u;
  uint32_t
      shadingPrototypeForwardWaitIdleCalls = 0u;
  bool
      shadingPrototypeForwardStarted = false;
  bool
      shadingPrototypeForwardCommandActive = false;
  bool
      shadingPrototypeForwardFenceActive = false;
  bool
      shadingPrototypeForwardFenceMonotonic = true;
  bool
      shadingPrototypeForwardReleaseOrderExact = false;
#endif
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

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  std::unique_ptr<IOSLinearHDRProofProducer>    linearHDRProof;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
  std::unique_ptr<IOSMultiply2CoverageProofProducer>
                                               multiply2Coverage;
#endif
  std::array<FrameContext,Resources::MaxFramesInFlight> frames;
  uint64_t                                      sceneRetainCount  = 0;
  uint64_t                                      sceneReleaseCount = 0;
  FaultInjection                               fault;

  LinearHDRTargets                             linearHDRTargets;
  IOSLinearHDRProbeResult                      linearHDRProbe =
      IOSLinearHDRProbeResult::factoryFailed();
  IOSLinearHDRPolicyState                      linearHDRPolicy;
  IOSLinearHDRSafetyState                      linearHDRSafety;
  IOSLinearHDRSettingsState                    linearHDRSettings;
  IOSLinearHDRProvenEvidence                   linearHDRProven;
  std::unique_ptr<IOSLinearHDRMetal>            linearHDRMetal;
  TextureFormat                                depthFormat = TextureFormat::Depth16;
  bool                                         depthSupported = false;
  std::unique_ptr<IOSGPUScene>                  gpuScene;
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
  bool                                         emissiveProfileTerminalReported = false;
  bool                                         emissiveProfileClaimed = false;
#endif
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
#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
  // The diagnostic profile owns admission: it submits only its isolated
  // clear-only probe and never reaches the production frame/present path.
  impl->pollClearOnlyPassSelfTest();
  return std::nullopt;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
  // The opt-in profile owns admission. It executes one isolated Tile probe
  // and never acquires a drawable or reaches the ordinary frame/present path.
  impl->pollShadingPrototypeTileSelfTest();
  return std::nullopt;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
  // The opt-in profile owns admission. It executes one isolated Forward
  // probe and never acquires a drawable or reaches ordinary frame/present.
  impl->pollShadingPrototypeForwardSelfTest();
  return std::nullopt;
#endif
  if(!impl->takePresentFailureAndLatchProof("RendererIOS asynchronous Metal present failed"))
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    impl->markLinearHDRProofFenceFailure(frameContext);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    impl->failEmissiveInput(frameContext,"gpu","fence");
#endif
    frameContext.fence = Fence();
    impl->retireSlotAfterTerminal(frameContext);
    impl->forcePreviewPlaceholder();
    impl->fail(previewFenceFault ? "RendererIOS Metal save-preview fence failed"
                                : "RendererIOS Metal frame fence failed",
               e.what());
    return std::nullopt;
    }
  catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    impl->markLinearHDRProofFenceFailure(frameContext);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    impl->failEmissiveInput(frameContext,"gpu","fence");
#endif
    frameContext.fence = Fence();
    impl->retireSlotAfterTerminal(frameContext);
    impl->forcePreviewPlaceholder();
    impl->fail(previewFenceFault ? "RendererIOS Metal save-preview fence failed"
                                : "RendererIOS Metal frame fence failed");
    return std::nullopt;
    }
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  bool proofIdleConfirmed = false;
  if(!impl->materializeLinearHDRProofAfterTerminal(
       frameContext,false,&proofIdleConfirmed)) {
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    impl->failEmissiveInput(frameContext,"gpu","proof-completion");
#endif
    return std::nullopt;
    }
  if(!impl->materializeLinearHDREvidenceAfterTerminal(
       frameContext,proofIdleConfirmed)) {
#else
  if(!impl->materializeLinearHDREvidenceAfterTerminal(frameContext)) {
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    impl->failEmissiveInput(frameContext,"gpu","terminal-completion");
#endif
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
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
  if(!impl->publishEmissiveInputAfterTerminal(frameContext)) {
    impl->fail("RendererIOS emissive input publication failed");
    return std::nullopt;
    }
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

  const IOSLinearHDRSettingsCommitResult settingsCommit =
      iosLinearHDRCommitSettingsAtFrameBoundary(
        impl->linearHDRSettings);
  impl->linearHDRSettings = settingsCommit.state;
  if(!iosLinearHDRToneValuesAreValid(
       impl->linearHDRSettings.committed))
    impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;

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
    const IOSFrameAnimationEvidence* frameAnimation,
    const IOSUVAnimationEvidence* uvAnimation,
    bool forceNativeSceneMarkers,
    void* completion, CompleteFrame completeFrame) {
#if !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  (void)forceNativeSceneMarkers;
#endif
  if(completeFrame==nullptr)
    throw std::logic_error("RendererIOS received an empty frame completion");
  if(impl->lifecycleState!=Impl::LifecycleState::Active) {
    cancelFrame(frame.serial);
    (void)completeFrame(completion,false,nullptr,nullptr);
    return {};
    }
  if(!impl->frameActive || frame.serial!=impl->activeSerial ||
     frame.slot!=impl->nextSlot)
    throw std::logic_error("RendererIOS received an invalid frame ticket");

  const uint8_t slot = frame.slot;
  auto& frameContext = impl->frames[slot];
  if(!impl->takePresentFailureAndLatchProof("RendererIOS asynchronous Metal present failed")) {
    cancelFrame(frame.serial);
    (void)completeFrame(completion,false,nullptr,nullptr);
    return {};
    }

  const auto abandonFrame = [&]() noexcept {
    cancelFrame(frame.serial);
    (void)completeFrame(completion,false,nullptr,nullptr);
    };
  const auto abandonFrameKeepingSlotResources = [&]() noexcept {
    impl->cancelActiveFrameKeepingSlotResources(frameContext);
    (void)completeFrame(completion,false,nullptr,nullptr);
    };

  InventoryMenu* inventoryOwner = nullptr;
  bool           videoActive    = false;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
  bool multiply2SplitPhaseStarted = false;
  const auto latchMultiply2SplitPhasePreSubmitFailure = [&]() noexcept {
    if(multiply2SplitPhaseStarted && !frameContext.submitted)
      impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
    };
#endif
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
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
  bool captureOnlyFailure = false;
#endif
  IOSGPUSceneFrameAnimationDrawReport frameAnimationDrawn;
  bool frameAnimationDrawnReady = false;
  IOSGPUSceneUVAnimationDrawReport uvAnimationDrawn;
  bool uvAnimationDrawnReady = false;
  IOSGPUScene::PreparedFrame preparedScene;
  IOSLinearHDRFrameSequence linearHDRSequence;
  IOSLinearHDRFrameIdentity linearHDRIdentity;
  bool linearHDRSequenceBegun = false;

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
    const bool sceneVisible = !videoActive &&
      std::any_of(input.snapshot->entities.begin(),
                  input.snapshot->entities.end(),
                  [](const IOSRenderEntity& entity) {
                    return (entity.visibilityMask&
                            IOSSceneVisibilityMain)!=0;
                  });
    bool linearHDRSceneActive = sceneVisible &&
      impl->linearHDRSafety.mode==IOSLinearHDRSafetyMode::Ready &&
      impl->linearHDRPolicy.ready &&
      impl->linearHDRTargets.current(
        impl->swapchain.w(),impl->swapchain.h()) &&
      impl->gpuScene!=nullptr && impl->linearHDRMetal!=nullptr;
    IOSGPUScene::Report preparedSceneReport;
    if(linearHDRSceneActive) {
      preparedSceneReport = impl->gpuScene->prepareFrame(
          preparedScene,impl->linearHDRTargets.generation,
          *input.snapshot,assets,
          frameAnimation,uvAnimation);
      if(preparedSceneReport.result!=IOSGPUScene::Result::Success ||
         !preparedScene.ready()) {
        impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
        linearHDRSceneActive = false;
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
        impl->failUnclaimedEmissiveProfile(
              input.snapshot->generation.value,
              input.snapshot->sequence.value,
              "contract","prepare-frame");
#endif
        }
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
      else {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
        IOSGPUScene::Multiply2InputArtifact frozenEmissiveInput =
            preparedScene.takeMultiply2InputArtifact();
#else
        IOSGPUScene::AdditiveInputArtifact frozenEmissiveInput =
            preparedScene.takeAdditiveInputArtifact();
#endif
        if(!frozenEmissiveInput) {
          impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
          linearHDRSceneActive = false;
          impl->failUnclaimedEmissiveProfile(
              input.snapshot->generation.value,
              input.snapshot->sequence.value,
              "contract","artifact-freeze");
          }
        else if(!impl->emissiveProfileClaimed) {
          impl->emissiveProfileClaimed = true;
          frameContext.emissiveInput = std::move(frozenEmissiveInput);
          frameContext.emissivePreparedSerial = frame.serial;
          }
        }
#endif
      }
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    if(linearHDRSceneActive && impl->linearHDRProof!=nullptr &&
       impl->linearHDRProof->captureProfileArmed()) {
      const IOSLinearHDRCaptureStartResult captureStart =
          impl->linearHDRProof->beginCapture(
              frameContext.linearHDRCapture);
      if(captureStart==IOSLinearHDRCaptureStartResult::AmbiguousActive) {
        impl->lifecycleState = Impl::LifecycleState::Fatal;
        impl->frameActive = false;
        impl->activeSerial = 0;
        if(impl->linearHDRProof->captureRequiresNoTeardown(
             frameContext.linearHDRCapture))
          impl->terminateWithoutTeardown(
            "RendererIOS HDR capture start observation is permanently ambiguous");
        throw std::runtime_error(
          "RendererIOS HDR capture start is ambiguous");
        }
      }
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

      const IOSLinearHDRFrameRoute linearHDRRoute =
          videoActive ? IOSLinearHDRFrameRoute::VideoBypass :
          !sceneVisible ? IOSLinearHDRFrameRoute::NoWorldBypass :
          linearHDRSceneActive ? IOSLinearHDRFrameRoute::Scene :
                                 IOSLinearHDRFrameRoute::SafeNoSceneBypass;
      linearHDRIdentity = {
        linearHDRRoute==IOSLinearHDRFrameRoute::Scene
          ? impl->linearHDRTargets.generation : 0u,
        linearHDRRoute==IOSLinearHDRFrameRoute::Scene
          ? input.snapshot->sequence.value : 0u,
        {impl->swapchain.w(),impl->swapchain.h()},
        };
      const IOSLinearHDRFrameSequenceBeginResult linearHDRBegin =
          iosBeginLinearHDRFrameSequence(
            linearHDRRoute,linearHDRIdentity);
      if(!linearHDRBegin)
        throw std::runtime_error(
          "RendererIOS linear HDR frame sequence could not begin");
      linearHDRSequence = linearHDRBegin.sequence;
      linearHDRSequenceBegun = true;
      const auto advanceLinearHDR =
          [&](IOSLinearHDRFrameEvent event,
              bool overlayHasUI = false) {
            if(iosAdvanceLinearHDRFrameSequence(
                 linearHDRSequence,event,linearHDRIdentity,
                 overlayHasUI)!=IOSLinearHDRFrameError::None)
              throw std::runtime_error(
                "RendererIOS linear HDR frame sequence order failed");
            };
      if(linearHDRSceneActive) {
        if(impl->linearHDRTargets.color.isEmpty()
#if !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
           || impl->linearHDRTargets.depth.isEmpty()
#endif
           )
          throw std::runtime_error(
            "RendererIOS native Landscape pass has no current HDR target pair");
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
        const auto failMultiply2SplitPhase =
            [this](std::string message) -> void {
          impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
          throw std::runtime_error(std::move(message));
          };
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        bool linearHDRProofPrepared = false;
        if(impl->linearHDRProof!=nullptr &&
           impl->linearHDRProof->armed()) {
          linearHDRProofPrepared = impl->linearHDRProof->prepareFrame(
              frameContext.linearHDRProof,
              impl->linearHDRTargets.color,
              impl->linearHDRTargets.generation,
              input.snapshot->sequence.value,
              impl->swapchain.w(),impl->swapchain.h());
          if(!linearHDRProofPrepared)
            throw std::runtime_error(
              "RendererIOS HDR proof preparation failed");
          }
        encoder.setDebugMarker(
          linearHDRProofPrepared
            ? impl->linearHDRProof->sceneMarker()
            : std::string_view("RendererIOS native Landscape HDR"));
#else
        encoder.setDebugMarker("RendererIOS native Landscape HDR");
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
        if(!linearHDRProofPrepared || impl->multiply2Coverage==nullptr)
          failMultiply2SplitPhase(
              "RendererIOS Multiply2 causal proof producers are unavailable");
        IOSLinearHDRProofNativeView hdrNative;
        IOSMultiply2CoverageProofMetadata coverageMetadata;
        IOSMultiply2CoverageNativeView coverageNative;
        if(!impl->linearHDRProof->nativeCopyView(
               frameContext.linearHDRProof,
               impl->linearHDRTargets.color,hdrNative) ||
           !impl->gpuScene->multiply2CoverageMetadata(
               preparedScene,hdrNative.metadata,
               impl->swapchain.w(),impl->swapchain.h(),
               coverageMetadata) ||
           !impl->multiply2Coverage->prepareFrame(
               frameContext.multiply2Coverage,
               impl->linearHDRTargets.color,coverageMetadata) ||
           !impl->multiply2Coverage->nativeView(
               frameContext.multiply2Coverage,coverageNative))
          failMultiply2SplitPhase(
              "RendererIOS Multiply2 causal coverage preflight failed");
        multiply2SplitPhaseStarted = true;
        const auto report =
          impl->gpuScene->encodePreparedMultiply2Causal(
              encoder,preparedScene,impl->linearHDRTargets.color,
              hdrNative,coverageNative);
        if(report.result==IOSGPUScene::Result::Success &&
           (!impl->linearHDRProof->markNativeCopyEncoded(
                frameContext.linearHDRProof) ||
            !impl->multiply2Coverage->markEncoded(
                frameContext.multiply2Coverage)))
          failMultiply2SplitPhase(
              "RendererIOS Multiply2 causal copy transition failed");
#else
        encoder.setFramebuffer({{impl->linearHDRTargets.color,Tempest::Vec4(0.f),Tempest::Preserve}},{impl->linearHDRTargets.depth,1.f,Tempest::Discard});
        const auto report =
          impl->gpuScene->encodePrepared(encoder,preparedScene);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        if(report.result!=IOSGPUScene::Result::Success ||
           forceNativeSceneMarkers ||
           input.snapshot->sequence.value==1u ||
           input.snapshot->sequence.value%300u==0u) {
          if(!report.markersReady) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
            failMultiply2SplitPhase(
                "RendererIOS native scene markers were not prepared");
#else
            throw std::runtime_error(
                "RendererIOS native scene markers were not prepared");
#endif
            }
          for(const auto& marker:report.markers) {
            if(!marker) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
              failMultiply2SplitPhase(
                  "RendererIOS native scene marker formatting failed");
#else
              throw std::runtime_error(
                  "RendererIOS native scene marker formatting failed");
#endif
              }
            Log::d(marker.text.data());
            }
        }
#endif
        if(report.result!=IOSGPUScene::Result::Success) {
          impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
          throw std::runtime_error(
            std::string("RendererIOS native Landscape encode failed: ")+
            iosGPUSceneResultName(report.result)+
            " handle="+std::to_string(report.failingHandle));
          }
        if(report.drawCount==0u ||
           report.texturedDrawCount!=report.drawCount) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
          failMultiply2SplitPhase(
              std::string(
                "RendererIOS native Landscape texture coverage failed: draws=")+
              std::to_string(report.drawCount)+
              " textured="+std::to_string(report.texturedDrawCount));
#else
          throw std::runtime_error(
            std::string(
              "RendererIOS native Landscape texture coverage failed: draws=")+
            std::to_string(report.drawCount)+
            " textured="+std::to_string(report.texturedDrawCount));
#endif
          }
        if(frameAnimation!=nullptr) {
          if(!report.frameAnimation.valid) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
            failMultiply2SplitPhase(
                "RendererIOS native Landscape frame-animation evidence was not finalized");
#else
            throw std::runtime_error(
                "RendererIOS native Landscape frame-animation evidence was not finalized");
#endif
            }
          frameAnimationDrawn = report.frameAnimation;
          frameAnimationDrawnReady = true;
          }
        if(uvAnimation!=nullptr) {
          if(!report.uvAnimation.valid) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
            failMultiply2SplitPhase(
                "RendererIOS native Landscape UV-animation evidence was not finalized");
#else
            throw std::runtime_error(
                "RendererIOS native Landscape UV-animation evidence was not finalized");
#endif
            }
          uvAnimationDrawn = report.uvAnimation;
          uvAnimationDrawnReady = true;
          }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        if(report.encodedPhaseDrawCount!=report.drawCount ||
           report.encodedPhaseTexturedDrawCount!=report.texturedDrawCount)
          failMultiply2SplitPhase(
              "RendererIOS Multiply2 native causal phase count mismatch");
#else
#error "Multiply2 causal lifecycle requires diagnostics"
#endif
#endif
        const IOSLinearHDRToneValues tone =
            impl->linearHDRSettings.committed;
        const IOSToneResolveConstants constants = {
          tone.brightness,tone.contrast,tone.gamma,tone.exposure,
          };
        encoder.setFramebuffer({});
        advanceLinearHDR(IOSLinearHDRFrameEvent::SceneHDR);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        if(linearHDRProofPrepared) {
#if !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
          encoder.setDebugMarker(impl->linearHDRProof->copyMarker());
          if(!impl->linearHDRProof->encodeCopy(
               frameContext.linearHDRProof,encoder,
               impl->linearHDRTargets.color))
            throw std::runtime_error(
              "RendererIOS HDR proof copy encode failed");
#endif
          encoder.setDebugMarker(
            impl->linearHDRProof->toneResolveMarker());
          }
        else {
          encoder.setDebugMarker("RendererIOS tone resolve");
          }
#else
        encoder.setDebugMarker("RendererIOS tone resolve");
#endif
        encoder.setFramebuffer(
          {{drawable,Tempest::Discard,Tempest::Preserve}});
        const IOSLinearHDRMetalEncodeResult resolve =
            impl->linearHDRMetal->encodeToneResolve(
              encoder,impl->linearHDRTargets.color,constants);
        if(resolve!=IOSLinearHDRMetalEncodeResult::Success) {
          impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
          throw std::runtime_error(
            std::string("RendererIOS tone resolve failed: ")+
            iosLinearHDRMetalEncodeResultName(resolve));
          }
        encoder.setFramebuffer({});
        advanceLinearHDR(IOSLinearHDRFrameEvent::ToneResolve);
        encoder.setDebugMarker("RendererIOS UI over tone resolve");
        encoder.setFramebuffer(
          {{drawable,Tempest::Preserve,Tempest::Preserve}});
        }
      else {
        encoder.setDebugMarker("RendererIOS shell clear/UI");
        encoder.setFramebuffer(
          {{drawable,OpaqueBlack,Tempest::Preserve}});
      }
      advanceLinearHDR(IOSLinearHDRFrameEvent::LdrOverlay,true);
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
        const bool currentInventoryDepth =
            impl->linearHDRTargets.current(
              impl->swapchain.w(),impl->swapchain.h());
        if(currentInventoryDepth) {
          encoder.setDebugMarker("RendererIOS bootstrap inventory");
          encoder.setFramebuffer({{drawable,Tempest::Preserve,Tempest::Preserve}},
                                 {impl->linearHDRTargets.depth,1.f,Tempest::Discard});
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    if(impl->linearHDRProof!=nullptr &&
       impl->linearHDRProof->hasOwners(frameContext.linearHDRProof))
      impl->linearHDRProof->markSubmitted(frameContext.linearHDRProof);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    if(impl->multiply2Coverage!=nullptr &&
       impl->multiply2Coverage->hasOwners(
           frameContext.multiply2Coverage))
      impl->multiply2Coverage->markSubmitted(
          frameContext.multiply2Coverage);
#endif
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    const bool linearHDRCaptureHealthy =
        impl->linearHDRProof==nullptr ||
        !impl->linearHDRProof->captureHasOwners(
          frameContext.linearHDRCapture) ||
        impl->linearHDRProof->markCaptureSubmittedAndStop(
          frameContext.linearHDRCapture);
#endif
    frameContext.fence = std::move(submittedFence);
    frameContext.submitted = true;
    ++impl->counters.submitAccepted;
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    if(frameContext.emissiveInput) {
      frameContext.emissiveSubmittedSerial = frame.serial;
      frameContext.emissiveSubmitAccepted = true;
      }
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    if(!linearHDRCaptureHealthy) {
      // Even when stopCapture returned after the submit, the capture terminal
      // is failed. Keep the submitted command, numeric frame and capture owner
      // anchored until the context-wide confirmed-idle release chain.
      frameContext.discardCommandAfterIdle = true;
      captureOnlyFailure = true;
      throw std::runtime_error(
        "RendererIOS HDR capture stop or inspection failed");
      }
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST)
    impl->acceptBinkSelfTestSubmit(slot);
#endif

    // Submission consumes the ticket and commits temporal history even if
    // drawable presentation subsequently reports SwapchainSuboptimal. Every
    // operation in this block is noexcept and the slot owns all keep-alives.
    impl->frameActive  = false;
    impl->activeSerial = 0;
    if(!completeFrame(
           completion,true,
           frameAnimationDrawnReady ? &frameAnimationDrawn : nullptr,
           uvAnimationDrawnReady ? &uvAnimationDrawn : nullptr)) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      impl->markLinearHDRProofPostSubmitFailure(frameContext);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
      impl->failEmissiveInput(
          frameContext,"gpu","history-commit");
#endif
      impl->fail("RendererIOS accepted frame could not commit scene history");
      return {};
      }

    if(impl->fault.postSubmitSuboptimal())
      throw SwapchainSuboptimal();
    ++impl->counters.presentAttempts;
    impl->device.present(impl->swapchain);
    ++impl->counters.presentAccepted;
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
    if(frameContext.emissiveInput)
      frameContext.emissivePresentAccepted = true;
#endif
    if(!linearHDRSequenceBegun ||
       iosAdvanceLinearHDRFrameSequence(
         linearHDRSequence,IOSLinearHDRFrameEvent::Present,
         linearHDRIdentity)!=IOSLinearHDRFrameError::None) {
      impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;
      throw std::runtime_error(
        "RendererIOS linear HDR present sequence failed");
      }
    frameContext.linearHDRSequence = linearHDRSequence;
    frameContext.linearHDRPolicyReadyAtEncode =
        linearHDRSequence.route()==IOSLinearHDRFrameRoute::Scene &&
        impl->linearHDRPolicy.ready;
    frameContext.linearHDRTerminalPending = true;
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

    (void)impl->takePresentFailureAndLatchProof(
      "RendererIOS asynchronous Metal present failed");

    return SubmitResult{previewAccepted};
    }
  catch(const SwapchainSuboptimal&) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    latchMultiply2SplitPhasePreSubmitFailure();
#endif
    // Drawable replacement is a recoverable surface lifecycle event. The
    // submitted frame, if any, is settled by resize() before targets are reused.
    if(frameContext.submitted) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      if(!captureOnlyFailure)
#endif
      impl->markLinearHDRProofPostSubmitFailure(frameContext);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
      impl->failEmissiveInput(frameContext,"gpu","post-submit");
#endif
      }
    else {
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      if(!submissionAttempted && impl->linearHDRProof!=nullptr &&
         impl->linearHDRProof->captureHasOwners(
           frameContext.linearHDRCapture)) {
        impl->retainLinearHDRCapturePreSubmitFailure(frameContext);
        (void)completeFrame(completion,false,nullptr,nullptr);
        }
      else
#endif
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
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    latchMultiply2SplitPhasePreSubmitFailure();
#endif
    if(frameContext.submitted) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      if(!captureOnlyFailure)
#endif
      impl->markLinearHDRProofPostSubmitFailure(frameContext);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
      impl->failEmissiveInput(frameContext,"gpu","post-submit");
#endif
      }
    else {
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      if(!submissionAttempted && impl->linearHDRProof!=nullptr &&
         impl->linearHDRProof->captureHasOwners(
           frameContext.linearHDRCapture)) {
        impl->retainLinearHDRCapturePreSubmitFailure(frameContext);
        (void)completeFrame(completion,false,nullptr,nullptr);
        }
      else
#endif
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
    if(impl->takePresentFailureAndLatchProof("RendererIOS asynchronous Metal present failed"))
      impl->fail("RendererIOS frame submission failed",e.what());
    throw;
    }
  catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)
    latchMultiply2SplitPhasePreSubmitFailure();
#endif
    if(frameContext.submitted) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      if(!captureOnlyFailure)
#endif
      impl->markLinearHDRProofPostSubmitFailure(frameContext);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL)
      impl->failEmissiveInput(frameContext,"gpu","post-submit");
#endif
      }
    else {
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
      if(!submissionAttempted && impl->linearHDRProof!=nullptr &&
         impl->linearHDRProof->captureHasOwners(
           frameContext.linearHDRCapture)) {
        impl->retainLinearHDRCapturePreSubmitFailure(frameContext);
        (void)completeFrame(completion,false,nullptr,nullptr);
        }
      else
#endif
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
  return impl->takePresentFailureAndLatchProof(
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
    impl->resetTargets(IOSLinearHDRActivationAttempt::Recreate);
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
    impl->resetTargets(IOSLinearHDRActivationAttempt::Recreate);
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

void IOSMetalContext::updateLinearHDRSettings(
    float brightness, float contrast, float gamma) noexcept {
  const IOSLinearHDRSettingsUpdateResult update =
      iosLinearHDRQueueSettingsUpdate(
        impl->linearHDRSettings,
        IOSLinearHDRRawSettings{brightness,contrast,gamma});
  impl->linearHDRSettings = update.state;
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
  (void)impl->takePresentFailureAndLatchProof(
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    impl->markLinearHDRProofFenceFailure(frameContext);
#endif
    frameContext.fence = Fence();
    impl->retireSlotAfterTerminal(frameContext);
    impl->forcePreviewPlaceholder();
    impl->fail("RendererIOS Metal save-preview fence failed",e.what());
    return true;
    }
  catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    impl->markLinearHDRProofFenceFailure(frameContext);
#endif
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

const IOSFeaturePolicyProvenance&
IOSMetalContext::featurePolicyProvenance() const noexcept {
  return *impl->featurePolicyProvenance;
  }
