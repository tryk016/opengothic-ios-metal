#include "iosmetalresourceclearpassprobe.h"

#include "iosmetalresourceallocator.h"
#include "iosmetalresourceallocatornative.h"

#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <TargetConditionals.h>

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
#include <cerrno>
#include <new>
#include <sys/stat.h>
#endif

#if __has_feature(objc_arc)
#error "RendererIOS clear-only pass probe requires non-ARC Objective-C++"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) && !TARGET_OS_IOS
#error "RendererIOS clear-only pass self-test is available only for iOS"
#endif

namespace {

template<class T>
class OwnedObjectiveC final {
  public:
    explicit OwnedObjectiveC(T value) noexcept
      : value(value) {
      }

    ~OwnedObjectiveC() noexcept {
      @try {
        [value release];
        }
      @catch(NSException*) {
        }
      }

    OwnedObjectiveC(const OwnedObjectiveC&) = delete;
    OwnedObjectiveC& operator=(const OwnedObjectiveC&) = delete;

    T get() const noexcept {
      return value;
      }

  private:
    T value = nil;
  };

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

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
constexpr char CaptureArtifactName[] =
    "RendererIOS-pm-clear-v1.gputrace";
#endif

}

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
struct IOSMetalResourceClearPassCapture::Impl final {
  MTLCaptureManager* manager = nil;
  NSURL* outputURL = nil;
  bool captureActive = false;

  ~Impl() {
    if(captureActive && manager!=nil) {
      @try {
        [manager stopCapture];
        }
      @catch(NSException*) {
        }
      }
    @try {
      [outputURL release];
      }
    @catch(NSException*) {
      }
    @try {
      [manager release];
      }
    @catch(NSException*) {
      }
    }
  };

IOSMetalResourceClearPassCapture::~IOSMetalResourceClearPassCapture() {
  cancel();
  delete impl;
  }

bool IOSMetalResourceClearPassCapture::start(
    Tempest::Device& device,
    const char*& reason) noexcept {
  reason = "capture-start-failed";
  if(impl!=nullptr)
    return false;
  impl = new(std::nothrow) Impl();
  if(impl==nullptr) {
    reason = "capture-state-allocation-failed";
    return false;
    }

  @autoreleasepool {
    @try {
      const auto borrowed = Tempest::MetalApi::borrowDevice(device);
      id<MTLDevice> nativeDevice =
          reinterpret_cast<id<MTLDevice>>((void*)borrowed.get());
      if(nativeDevice==nil) {
        reason = "capture-device-unavailable";
        return false;
        }

      OwnedObjectiveC<NSFileManager*> files(
          [[NSFileManager alloc] init]);
      if(files.get()==nil) {
        reason = "capture-file-manager-unavailable";
        return false;
        }
      NSArray<NSURL*>* documents =
          [files.get() URLsForDirectory:NSDocumentDirectory
                              inDomains:NSUserDomainMask];
      NSURL* documentsURL = [documents lastObject];
      NSString* captureName = [NSString stringWithUTF8String:CaptureArtifactName];
      NSURL* outputURL = [documentsURL
          URLByAppendingPathComponent:captureName
                           isDirectory:NO];
      const bool exactPath = captureName!=nil && documentsURL!=nil &&
          outputURL!=nil &&
          [[outputURL lastPathComponent]
            isEqualToString:captureName] &&
          [[[outputURL URLByDeletingLastPathComponent] standardizedURL]
            isEqual:[documentsURL standardizedURL]];
      if(!exactPath) {
        reason = "capture-output-path-invalid";
        return false;
        }

      const char* outputPath = [outputURL fileSystemRepresentation];
      if(outputPath==nullptr) {
        reason = "capture-output-path-unavailable";
        return false;
        }
      struct stat existing = {};
      if(::lstat(outputPath,&existing)==0) {
        NSError* removeError = nil;
        if(![files.get() removeItemAtURL:outputURL error:&removeError]) {
          (void)removeError;
          reason = "capture-stale-artifact-removal-failed";
          return false;
          }
        }
      else if(errno!=ENOENT) {
        reason = "capture-stale-artifact-inspection-failed";
        return false;
        }
      if(::lstat(outputPath,&existing)==0 || errno!=ENOENT) {
        reason = "capture-output-not-empty";
        return false;
        }

      MTLCaptureManager* manager = [MTLCaptureManager sharedCaptureManager];
      if(manager==nil ||
         ![manager supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
        reason = "capture-gputrace-destination-unsupported";
        return false;
        }
      OwnedObjectiveC<MTLCaptureDescriptor*> descriptor(
          [[MTLCaptureDescriptor alloc] init]);
      if(descriptor.get()==nil) {
        reason = "capture-descriptor-allocation-failed";
        return false;
        }
      descriptor.get().captureObject = nativeDevice;
      descriptor.get().destination = MTLCaptureDestinationGPUTraceDocument;
      descriptor.get().outputURL = outputURL;
      impl->manager = [manager retain];
      impl->outputURL = [outputURL retain];
      // Treat an Objective-C exception from start as ambiguous. The caller's
      // failure path will invoke cancel(), and Impl teardown retries if that
      // stop also throws.
      impl->captureActive = true;
      NSError* captureError = nil;
      const BOOL started = [manager startCaptureWithDescriptor:descriptor.get()
                                                         error:&captureError];
      (void)captureError;
      if(!started) {
        impl->captureActive = false;
        reason = "capture-manager-start-rejected";
        return false;
        }

      reason = nullptr;
      return true;
      }
    @catch(NSException*) {
      reason = "capture-start-objective-c-exception";
      return false;
      }
    }
  }

bool IOSMetalResourceClearPassCapture::stopAndInspect(
    IOSMetalCaptureArtifact& artifact,
    const char*& reason) noexcept {
  artifact = {};
  reason = "capture-stop-failed";
  if(impl==nullptr || !impl->captureActive || impl->manager==nil ||
     impl->outputURL==nil) {
    reason = "capture-not-active";
    return false;
    }
  @autoreleasepool {
    @try {
      [impl->manager stopCapture];
      impl->captureActive = false;
      const char* rawPath = [impl->outputURL fileSystemRepresentation];
      if(rawPath==nullptr) {
        reason = "capture-output-path-unavailable-after-stop";
        return false;
        }
      if(!iosMetalNormalizeAndInspectCaptureArtifact(
           rawPath,artifact,reason)) {
        if(reason==nullptr)
          reason = "capture-artifact-invalid";
        return false;
        }
      reason = nullptr;
      return true;
      }
    @catch(NSException*) {
      reason = "capture-stop-objective-c-exception";
      return false;
      }
    }
  }

void IOSMetalResourceClearPassCapture::cancel() noexcept {
  if(impl==nullptr || !impl->captureActive || impl->manager==nil)
    return;
  @try {
    [impl->manager stopCapture];
    impl->captureActive = false;
    }
  @catch(NSException*) {
    }
  }

bool IOSMetalResourceClearPassCapture::active() const noexcept {
  return impl!=nullptr && impl->captureActive;
  }

const char* iosMetalCaptureArtifactKindName(
    IOSMetalCaptureArtifactKind kind) noexcept {
  switch(kind) {
    case IOSMetalCaptureArtifactKind::File:      return "file";
    case IOSMetalCaptureArtifactKind::Directory: return "directory";
    }
  return "invalid";
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
