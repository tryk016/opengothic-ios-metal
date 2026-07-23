#include "iosmetalresourceclearpassprobe.h"

#include "iosmetalresourceallocator.h"
#include "iosmetalresourceallocatornative.h"

#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <TargetConditionals.h>

#if __has_feature(objc_arc)
#error "RendererIOS clear-only pass probe requires non-ARC Objective-C++"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) && !TARGET_OS_IOS
#error "RendererIOS clear-only pass self-test is available only for iOS"
#endif

namespace {

class OwnedDescriptor final {
  public:
    explicit OwnedDescriptor(MTLRenderPassDescriptor* value) noexcept
      : value(value) {
      }

    ~OwnedDescriptor() noexcept {
      @try {
        [value release];
        }
      @catch(NSException*) {
        }
      }

    OwnedDescriptor(const OwnedDescriptor&) = delete;
    OwnedDescriptor& operator=(const OwnedDescriptor&) = delete;

    MTLRenderPassDescriptor* get() const noexcept {
      return value;
      }

  private:
    MTLRenderPassDescriptor* value = nil;
  };

class ScopedRenderEncoder final {
  public:
    explicit ScopedRenderEncoder(id<MTLRenderCommandEncoder> value) noexcept
      : value(value) {
      @try {
        [value retain];
        }
      @catch(NSException*) {
        @try {
          [value endEncoding];
          }
        @catch(NSException*) {
          }
        this->value = nil;
        }
      }

    ~ScopedRenderEncoder() noexcept {
      if(value==nil)
        return;
      if(!endAttempted) {
        @try {
          endAttempted = true;
          [value endEncoding];
          }
        @catch(NSException*) {
          }
        }
      @try {
        [value release];
        }
      @catch(NSException*) {
        }
      }

    ScopedRenderEncoder(const ScopedRenderEncoder&) = delete;
    ScopedRenderEncoder& operator=(const ScopedRenderEncoder&) = delete;

    explicit operator bool() const noexcept {
      return value!=nil;
      }

    bool setLabelAndEnd(NSString* label) noexcept {
      if(value==nil)
        return false;
      @try {
        value.label = label;
        endAttempted = true;
        [value endEncoding];
        return true;
        }
      @catch(NSException*) {
        return false;
        }
      }

  private:
    id<MTLRenderCommandEncoder> value = nil;
    bool endAttempted = false;
  };

struct NativeEncodeContext final {
  MTL::Texture* privateTexture = nullptr;
  MTL::Texture* memorylessTexture = nullptr;
  IOSMetalResourceClearPassNativeReport* report = nullptr;
  bool succeeded = false;
  };

bool encodeClear(id<MTLCommandBuffer> command,
                 id<MTLTexture> texture,
                 MTLStoreAction store,
                 NSString* label) noexcept {
  @autoreleasepool {
    @try {
      MTLRenderPassDescriptor* allocated =
          [[MTLRenderPassDescriptor alloc] init];
      if(allocated==nil)
        return false;
      OwnedDescriptor descriptor(allocated);
      MTLRenderPassColorAttachmentDescriptor* color =
          descriptor.get().colorAttachments[0u];
      if(color==nil)
        return false;
      color.texture = texture;
      color.loadAction = MTLLoadActionClear;
      color.storeAction = store;
      color.clearColor = MTLClearColorMake(0.0,0.0,0.0,0.0);

      ScopedRenderEncoder encoder(
          [command renderCommandEncoderWithDescriptor:descriptor.get()]);
      return encoder.setLabelAndEnd(label);
      }
    @catch(NSException*) {
      return false;
      }
    }
  }

void encodeNativeClearPasses(void* rawContext,
                             MTL::CommandBuffer* command) {
  auto& context = *static_cast<NativeEncodeContext*>(rawContext);
  if(command==nullptr || context.privateTexture==nullptr ||
     context.memorylessTexture==nullptr || context.report==nullptr)
    return;

  id<MTLCommandBuffer> nativeCommand =
      reinterpret_cast<id<MTLCommandBuffer>>((void*)command);
  id<MTLTexture> nativePrivate =
      reinterpret_cast<id<MTLTexture>>((void*)context.privateTexture);
  id<MTLTexture> nativeMemoryless =
      reinterpret_cast<id<MTLTexture>>((void*)context.memorylessTexture);
  if(nativeCommand==nil || nativePrivate==nil || nativeMemoryless==nil)
    return;

  @try {
    nativeCommand.label = @"RIOS pm-clear CB";
    nativePrivate.label = @"RIOS private 4x4";
    nativeMemoryless.label = @"RIOS memoryless 4x4";

    context.report->commandBuffers = 1u;
    if(!encodeClear(nativeCommand,nativePrivate,MTLStoreActionStore,
                    @"RIOS private clear"))
      return;
    context.report->physicalPasses += 1u;
    context.report->renderEncoders += 1u;
    context.report->privateLoad = IOSLoadAction::Clear;
    context.report->privateStore = IOSStoreAction::Store;

    if(!encodeClear(nativeCommand,nativeMemoryless,MTLStoreActionDontCare,
                    @"RIOS memoryless clear"))
      return;
    context.report->physicalPasses += 1u;
    context.report->renderEncoders += 1u;
    context.report->memorylessLoad = IOSLoadAction::Clear;
    context.report->memorylessStore = IOSStoreAction::Discard;
    context.report->encoded = true;
    context.succeeded = true;
    }
  @catch(NSException*) {
    context.succeeded = false;
    }
  }

}

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
IOSMetalResourceClearPassCapture::~IOSMetalResourceClearPassCapture() =
    default;

bool IOSMetalResourceClearPassCapture::start(
    Tempest::Device& device,
    const char*& reason) noexcept {
  return session.start(
      device,"RendererIOS-pm-clear-v1.gputrace",reason);
  }

bool IOSMetalResourceClearPassCapture::stopAndInspect(
    IOSMetalCaptureArtifact& artifact,
    const char*& reason) noexcept {
  return session.stopAndInspect(artifact,reason);
  }

void IOSMetalResourceClearPassCapture::cancel() noexcept {
  session.cancel();
  }

bool IOSMetalResourceClearPassCapture::active() const noexcept {
  return session.active();
  }
#endif

bool iosMetalResourceEncodeClearPassProbe(
    Tempest::Device& device,
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSMetalResourceTexture& privateTexture,
    const IOSMetalResourceTexture& memorylessTexture,
    IOSMetalResourceClearPassNativeReport& report) {
  report = {};
  NativeEncodeContext context;
  context.privateTexture =
      IOSMetalResourceTextureNativeAccess::borrow(privateTexture);
  context.memorylessTexture =
      IOSMetalResourceTextureNativeAccess::borrow(memorylessTexture);
  context.report = &report;
  if(context.privateTexture==nullptr || context.memorylessTexture==nullptr)
    return false;

  const bool bridgeAccepted = Tempest::MetalApi::withActiveCommandBuffer(
      device,encoder,&context,encodeNativeClearPasses);
  return bridgeAccepted && context.succeeded &&
         iosMetalResourceClearPassNativeReportMatches(report);
  }
