#include "ioslinearhdrproofproducer.h"

#include <Tempest/Attachment>
#include <Tempest/Device>
#include <Tempest/Encoder>
#include <Tempest/Log>
#include <Tempest/MetalApi>
#include <Tempest/StorageBuffer>
#include <Tempest/Texture2d>

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>
#import <Security/Security.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#if __has_feature(objc_arc)
#error "IOSLinearHDRProofProducer requires non-ARC Objective-C++ mode"
#endif

#if !defined(OPENGOTHIC_RENDERER_IOS_BUILD_SHA)
#define OPENGOTHIC_RENDERER_IOS_BUILD_SHA "local"
#endif

#if defined(__IOS__)

namespace {

constexpr char FinalLeaf[] = "RendererIOS-linear-hdr-proof-v1.bin";
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
constexpr char CaptureLeaf[] = "RendererIOS-linear-hdr-proof-v1.gputrace";
#endif

bool allZero(std::span<const uint8_t> bytes) noexcept {
  return std::all_of(bytes.begin(),bytes.end(),
                     [](uint8_t value) { return value==0u; });
  }

bool checkedMultiply(uint64_t lhs, uint64_t rhs, uint64_t& result) noexcept {
  if(lhs!=0u && rhs>std::numeric_limits<uint64_t>::max()/lhs)
    return false;
  result = lhs*rhs;
  return true;
  }

bool removeRegularIfPresent(int directory, const char* leaf) noexcept {
  struct stat status = {};
  if(fstatat(directory,leaf,&status,AT_SYMLINK_NOFOLLOW)!=0)
    return errno==ENOENT;
  if(!S_ISREG(status.st_mode))
    return false;
  return unlinkat(directory,leaf,0)==0;
  }

bool writeAll(int file, std::span<const std::byte> bytes) noexcept {
  size_t offset = 0u;
  while(offset<bytes.size()) {
    const ssize_t written =
        write(file,bytes.data()+static_cast<std::ptrdiff_t>(offset),
              bytes.size()-offset);
    if(written<0 && errno==EINTR)
      continue;
    if(written<=0)
      return false;
    offset += static_cast<size_t>(written);
    }
  return true;
  }

}

struct IOSLinearHDRProofFrame::Impl final {
  explicit Impl(Tempest::StorageBuffer&& buffer) noexcept
    :buffer(std::move(buffer)) {
    }

  ~Impl() {
    [source release];
    }

  Tempest::StorageBuffer buffer;
  id<MTLTexture> source = nil;
  const std::byte* mapped = nullptr;
  IOSLinearHDRProofMetadata metadata;
  bool encoded = false;
  bool submitted = false;
  bool submitAmbiguous = false;
  bool presentFailure = false;
  };

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
struct IOSLinearHDRCaptureFrame::Impl final {
  std::unique_ptr<IOSMetalCaptureSession> session;
  IOSLinearHDRCaptureState state = IOSLinearHDRCaptureState::Armed;
  IOSMetalCaptureStartObservation observation;
  bool terminalLogged = false;
  bool provenActive = false;
  bool permanentAmbiguous = false;
  };

IOSLinearHDRCaptureFrame::IOSLinearHDRCaptureFrame() noexcept = default;
IOSLinearHDRCaptureFrame::~IOSLinearHDRCaptureFrame() = default;
IOSLinearHDRCaptureFrame::IOSLinearHDRCaptureFrame(
    IOSLinearHDRCaptureFrame&&) noexcept = default;
IOSLinearHDRCaptureFrame& IOSLinearHDRCaptureFrame::operator=(
    IOSLinearHDRCaptureFrame&&) noexcept = default;
#endif

IOSLinearHDRProofFrame::IOSLinearHDRProofFrame() noexcept = default;
IOSLinearHDRProofFrame::~IOSLinearHDRProofFrame() = default;
IOSLinearHDRProofFrame::IOSLinearHDRProofFrame(
    IOSLinearHDRProofFrame&&) noexcept = default;
IOSLinearHDRProofFrame& IOSLinearHDRProofFrame::operator=(
    IOSLinearHDRProofFrame&&) noexcept = default;

struct IOSLinearHDRProofProducer::Impl final {
  explicit Impl(Tempest::Device& owner) noexcept : owner(owner) {
    arm();
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
    armCaptureProfile();
#endif
    }

  ~Impl() {
    if(directory>=0)
      (void)close(directory);
    }

  void fail(IOSLinearHDRProofFailureReason reason) noexcept {
    if(state==IOSLinearHDRProofProducerState::Published ||
       state==IOSLinearHDRProofProducerState::Failed)
      return;
    (void)iosAdvanceLinearHDRProofProducerState(
        state,IOSLinearHDRProofProducerEvent::Fail);
    if(failureLogged)
      return;
    failureLogged = true;
    std::array<char,255u> line{};
    const IOSLinearHDRProofFailureClass failureClass =
        iosLinearHDRProofFailureClass(reason);
    const int length = std::snprintf(
        line.data(),line.size(),
        "RendererIOS HDR proof: v=1 id=%s terminal=F class=%s reason=%s",
        identityAvailable ? identityText.data() : "none",
        iosLinearHDRProofFailureClassName(failureClass),
        iosLinearHDRProofFailureReasonName(reason));
    if(length<=0 || size_t(length)>=line.size())
      return;
    try {
      Tempest::Log::e(line.data());
      }
    catch(...) {
      }
    }

  void arm() noexcept {
    const int randomStatus = SecRandomCopyBytes(
        kSecRandomDefault,proofId.size(),proofId.data());
    if(randomStatus!=errSecSuccess) {
      fail(IOSLinearHDRProofFailureReason::Rng);
      return;
      }
    if(allZero(proofId)) {
      fail(IOSLinearHDRProofFailureReason::RngZero);
      return;
      }
    if(!iosLinearHDRProofFormatIdentity(proofId,identityText)) {
      fail(IOSLinearHDRProofFailureReason::RngZero);
      return;
      }
    identityAvailable = true;
    if(!iosLinearHDRProofParseBuildSha(
         OPENGOTHIC_RENDERER_IOS_BUILD_SHA,buildSha)) {
      fail(IOSLinearHDRProofFailureReason::Sha);
      return;
      }
    try {
      sceneMarkerText = std::string("RendererIOS.SceneHDR.")+
                        identityText.data();
      copyMarkerText = std::string("RendererIOS.HDRProofCopy.")+
                       identityText.data();
      toneMarkerText = std::string("RendererIOS.ToneResolve.")+
                       identityText.data();
      tempLeaf = std::string(".RendererIOS-linear-hdr-proof-v1.")+
                 identityText.data()+".tmp";
      }
    catch(...) {
      fail(IOSLinearHDRProofFailureReason::Label);
      return;
      }
    if(sceneMarkerText.size()!=53u || copyMarkerText.size()!=57u ||
       toneMarkerText.size()!=56u || tempLeaf.size()!=69u) {
      fail(IOSLinearHDRProofFailureReason::Label);
      return;
      }
    @autoreleasepool {
      @try {
        NSArray<NSURL*>* urls =
            [[NSFileManager defaultManager]
              URLsForDirectory:NSDocumentDirectory
                     inDomains:NSUserDomainMask];
        NSURL* documents = urls.firstObject;
        const char* path = documents.fileSystemRepresentation;
        if(path==nullptr) {
          fail(IOSLinearHDRProofFailureReason::Cleanup);
          return;
          }
        directory = open(path,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
        }
      @catch(NSException* exception) {
        (void)exception;
        directory = -1;
        }
      }
    if(directory<0 ||
       !removeRegularIfPresent(directory,FinalLeaf) ||
       !removeRegularIfPresent(directory,tempLeaf.c_str())) {
      fail(IOSLinearHDRProofFailureReason::Cleanup);
      return;
      }
    if(!iosAdvanceLinearHDRProofProducerState(
         state,IOSLinearHDRProofProducerEvent::Arm))
      fail(IOSLinearHDRProofFailureReason::State);
    }

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
  void logCaptureFailure(IOSLinearHDRCaptureFrame::Impl& frame,
                         const char* reason) noexcept {
    if(frame.terminalLogged)
      return;
    frame.terminalLogged = true;
    std::array<char,255u> line{};
    const int length = std::snprintf(
        line.data(),line.size(),
        "RendererIOS HDR capture: v=1 id=%s terminal=F reason=%s",
        identityAvailable ? identityText.data() : "none",reason);
    if(length<=0 || size_t(length)>=line.size())
      return;
    try {
      Tempest::Log::e(line.data());
      }
    catch(...) {
      }
    }

  void logCaptureSuccess(IOSLinearHDRCaptureFrame::Impl& frame,
                         const IOSMetalCaptureArtifact& artifact) noexcept {
    if(frame.terminalLogged)
      return;
    std::array<char,255u> line{};
    const int length = std::snprintf(
        line.data(),line.size(),
        "RendererIOS HDR capture: v=1 id=%s file=%s kind=%s bytes=%llu terminal=C",
        identityText.data(),CaptureLeaf,
        iosMetalCaptureArtifactKindName(artifact.kind),
        static_cast<unsigned long long>(artifact.bytes));
    if(length<=0 || size_t(length)>=line.size()) {
      logCaptureFailure(frame,"state");
      return;
      }
    frame.terminalLogged = true;
    try {
      Tempest::Log::i(line.data());
      }
    catch(...) {
      }
    }

  void armCaptureProfile() noexcept {
    if(state!=IOSLinearHDRProofProducerState::Armed)
      return;
    @autoreleasepool {
      @try {
        id value = [[NSBundle mainBundle]
            objectForInfoDictionaryKey:
              @"RendererIOSLinearHDRGPUTripleCapture"];
        const bool exactCFBoolean = value!=nil &&
            CFGetTypeID(static_cast<CFTypeRef>(value))==CFBooleanGetTypeID();
        const bool booleanValue = exactCFBoolean &&
            CFBooleanGetValue(static_cast<CFBooleanRef>(value));
        captureProfileArmed =
            iosLinearHDRCaptureProfileAcceptsExactBoolean(
                exactCFBoolean,booleanValue);
        }
      @catch(NSException*) {
        captureProfileArmed = false;
        }
      }
    if(captureProfileArmed)
      (void)iosAdvanceLinearHDRCaptureState(
          captureState,IOSLinearHDRCaptureEvent::Arm);
    }

  IOSLinearHDRCaptureStartResult beginCapture(
      IOSLinearHDRCaptureFrame& frame) noexcept {
    if(!captureProfileArmed || captureAttempted ||
       captureState!=IOSLinearHDRCaptureState::Armed ||
       state!=IOSLinearHDRProofProducerState::Armed || frame.impl!=nullptr)
      return IOSLinearHDRCaptureStartResult::RejectedInactive;
    captureAttempted = true;
    try {
      frame.impl = std::make_unique<IOSLinearHDRCaptureFrame::Impl>();
      frame.impl->session = std::make_unique<IOSMetalCaptureSession>();
      }
    catch(...) {
      (void)iosAdvanceLinearHDRCaptureState(
          captureState,IOSLinearHDRCaptureEvent::Fail);
      if(frame.impl!=nullptr) {
        frame.impl->state = IOSLinearHDRCaptureState::Failed;
        logCaptureFailure(*frame.impl,"start");
        }
      else {
        try {
          Tempest::Log::e(
            "RendererIOS HDR capture: v=1 id=none terminal=F reason=start");
          }
        catch(...) {
          }
        }
      return IOSLinearHDRCaptureStartResult::RejectedInactive;
      }
    const char* reason = nullptr;
    const IOSLinearHDRCaptureStartResult result =
        frame.impl->session->beginCapture(
            owner,CaptureLeaf,
            IOSMetalCaptureExistingArtifactPolicy::RequireAbsent,reason);
    (void)reason;
    frame.impl->observation = frame.impl->session->startObservation();
    const IOSLinearHDRCaptureObservationDecision decision =
        iosClassifyLinearHDRCaptureStartObservation(
            frame.impl->observation.startReturn,
            frame.impl->observation.activeAfter,
            frame.impl->observation.complete);
    if(result==IOSLinearHDRCaptureStartResult::Started &&
       decision==IOSLinearHDRCaptureObservationDecision::Started) {
      frame.impl->provenActive = true;
      (void)iosAdvanceLinearHDRCaptureState(
          captureState,IOSLinearHDRCaptureEvent::Start);
      frame.impl->state = captureState;
      return result;
      }
    if(result==IOSLinearHDRCaptureStartResult::RejectedInactive &&
       decision==IOSLinearHDRCaptureObservationDecision::RejectedInactive) {
      (void)iosAdvanceLinearHDRCaptureState(
          captureState,IOSLinearHDRCaptureEvent::Fail);
      frame.impl->state = IOSLinearHDRCaptureState::Failed;
      logCaptureFailure(*frame.impl,"start");
      frame.impl.reset();
      return IOSLinearHDRCaptureStartResult::RejectedInactive;
      }
    if(decision==IOSLinearHDRCaptureObservationDecision::ActiveFailure) {
      frame.impl->provenActive = true;
      (void)iosAdvanceLinearHDRCaptureState(
          captureState,IOSLinearHDRCaptureEvent::Fail);
      frame.impl->state = IOSLinearHDRCaptureState::Failed;
      logCaptureFailure(*frame.impl,"start-ambiguous");
      return IOSLinearHDRCaptureStartResult::AmbiguousActive;
      }
    frame.impl->permanentAmbiguous = true;
    (void)iosAdvanceLinearHDRCaptureState(
        captureState,IOSLinearHDRCaptureEvent::PermanentAmbiguity);
    frame.impl->state = IOSLinearHDRCaptureState::PermanentAmbiguous;
    logCaptureFailure(*frame.impl,"state");
    return IOSLinearHDRCaptureStartResult::AmbiguousActive;
    }

  void captureFailure(IOSLinearHDRCaptureFrame& frame,
                      const char* reason) noexcept {
    if(frame.impl==nullptr)
      return;
    if(frame.impl->state!=IOSLinearHDRCaptureState::PermanentAmbiguous) {
      (void)iosAdvanceLinearHDRCaptureState(
          captureState,IOSLinearHDRCaptureEvent::Fail);
      frame.impl->state = IOSLinearHDRCaptureState::Failed;
      }
    logCaptureFailure(*frame.impl,reason);
    }

  bool markCaptureSubmittedAndStop(
      IOSLinearHDRCaptureFrame& frame) noexcept {
    if(frame.impl==nullptr || frame.impl->session==nullptr ||
       frame.impl->state!=IOSLinearHDRCaptureState::Active ||
       !iosAdvanceLinearHDRCaptureState(
          captureState,IOSLinearHDRCaptureEvent::Submit)) {
      captureFailure(frame,"state");
      return false;
      }
    frame.impl->state = IOSLinearHDRCaptureState::Submitted;
    IOSMetalCaptureArtifact artifact;
    const char* reason = nullptr;
    if(!frame.impl->session->stopAndInspect(artifact,reason)) {
      (void)reason;
      captureFailure(frame,"stop");
      return false;
      }
    if(!iosAdvanceLinearHDRCaptureState(
         captureState,IOSLinearHDRCaptureEvent::Complete)) {
      captureFailure(frame,"state");
      return false;
      }
    frame.impl->state = IOSLinearHDRCaptureState::Completed;
    logCaptureSuccess(*frame.impl,artifact);
    return true;
    }
#endif

  bool labelSceneTarget(Tempest::Attachment& target) noexcept {
    if(state!=IOSLinearHDRProofProducerState::Armed)
      return false;
    try {
      auto& texture =
          Tempest::textureCast<Tempest::Texture2d&>(target);
      const auto borrowed = Tempest::MetalApi::borrowTexture(owner,texture);
      if(!borrowed) {
        fail(IOSLinearHDRProofFailureReason::Target);
        return false;
        }
      id<MTLTexture> native = (id<MTLTexture>)(void*)borrowed.get();
      @autoreleasepool {
        NSString* label = [[NSString alloc]
            initWithBytes:sceneMarkerText.data()
                   length:sceneMarkerText.size()
                 encoding:NSUTF8StringEncoding];
        if(label==nil) {
          fail(IOSLinearHDRProofFailureReason::Label);
          return false;
          }
        @try {
          native.label = label;
          const bool exact = native.label!=nil &&
                             [native.label isEqualToString:label];
          [label release];
          if(!exact) {
            fail(IOSLinearHDRProofFailureReason::Label);
            return false;
            }
          }
        @catch(NSException* exception) {
          (void)exception;
          [label release];
          fail(IOSLinearHDRProofFailureReason::Label);
          return false;
          }
        }
      }
    catch(...) {
      fail(IOSLinearHDRProofFailureReason::Label);
      return false;
      }
    return true;
    }

  bool prepareFrame(IOSLinearHDRProofFrame& frame,
                    const Tempest::Attachment& source,
                    uint64_t targetGeneration,
                    uint64_t snapshotSequence,
                    uint32_t width,
                    uint32_t height) noexcept {
    if(state!=IOSLinearHDRProofProducerState::Armed ||
       activeFrame!=nullptr || frame.impl!=nullptr) {
      fail(IOSLinearHDRProofFailureReason::State);
      return false;
      }
    uint64_t row = 0u;
    uint64_t logical = 0u;
    if(width==0u || height==0u ||
       width>IOSLinearHDRProofV1MaximumExtent ||
       height>IOSLinearHDRProofV1MaximumExtent ||
       targetGeneration==0u || snapshotSequence==0u ||
       !checkedMultiply(uint64_t(width),4u,row) ||
       row>std::numeric_limits<uint32_t>::max() ||
       !checkedMultiply(row,uint64_t(height),logical) ||
       logical>IOSLinearHDRProofV1MaximumPayloadBytes ||
       logical>std::numeric_limits<size_t>::max()) {
      fail(IOSLinearHDRProofFailureReason::Layout);
      return false;
      }
    id<MTLTexture> nativeSource = nil;
    bool targetValidated = false;
    try {
      if(source.isEmpty() || source.w()!=int(width) ||
         source.h()!=int(height)) {
        fail(IOSLinearHDRProofFailureReason::Target);
        return false;
        }
      const auto& texture =
          Tempest::textureCast<const Tempest::Texture2d&>(source);
      const auto borrowed = Tempest::MetalApi::borrowTexture(owner,texture);
      if(!borrowed) {
        fail(IOSLinearHDRProofFailureReason::Target);
        return false;
        }
      nativeSource = (id<MTLTexture>)(void*)borrowed.get();
      @try {
        constexpr MTLTextureUsage usage =
            MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        if(nativeSource.pixelFormat!=MTLPixelFormatRG11B10Float ||
           nativeSource.storageMode!=MTLStorageModePrivate ||
           nativeSource.textureType!=MTLTextureType2D ||
           nativeSource.width!=NSUInteger(width) ||
           nativeSource.height!=NSUInteger(height) ||
           nativeSource.mipmapLevelCount!=NSUInteger(1u) ||
           nativeSource.arrayLength!=NSUInteger(1u) ||
           nativeSource.sampleCount!=NSUInteger(1u) ||
           nativeSource.usage!=usage) {
          fail(IOSLinearHDRProofFailureReason::Target);
          return false;
          }
        targetValidated = true;
        @autoreleasepool {
          NSString* expected = [[[NSString alloc]
              initWithBytes:sceneMarkerText.data()
                     length:sceneMarkerText.size()
                   encoding:NSUTF8StringEncoding] autorelease];
          const bool exact = expected!=nil && nativeSource.label!=nil &&
                             [nativeSource.label isEqualToString:expected];
          if(!exact) {
            fail(IOSLinearHDRProofFailureReason::Label);
            return false;
            }
          }
        }
      @catch(NSException* exception) {
        (void)exception;
        if(state!=IOSLinearHDRProofProducerState::Failed)
          fail(targetValidated ? IOSLinearHDRProofFailureReason::Label
                               : IOSLinearHDRProofFailureReason::Target);
        return false;
        }
      }
    catch(...) {
      fail(IOSLinearHDRProofFailureReason::Target);
      return false;
      }

    Tempest::StorageBuffer buffer;
    try {
      buffer = owner.ssbo(
          Tempest::BufferHeap::Upload,Tempest::Uninitialized,
          static_cast<size_t>(logical));
      }
    catch(...) {
      fail(IOSLinearHDRProofFailureReason::BufferAlloc);
      return false;
      }
    if(buffer.isEmpty() || buffer.byteSize()!=logical) {
      fail(IOSLinearHDRProofFailureReason::BufferAlloc);
      return false;
      }
    const auto borrowedBuffer = Tempest::MetalApi::borrowBuffer(owner,buffer);
    if(!borrowedBuffer) {
      fail(IOSLinearHDRProofFailureReason::BufferMap);
      return false;
      }
    id<MTLBuffer> nativeBuffer =
        (id<MTLBuffer>)(void*)borrowedBuffer.get();
    void* mapped = nullptr;
    bool validNativeBuffer = false;
    @try {
      mapped = nativeBuffer.contents;
      validNativeBuffer =
          nativeBuffer.storageMode==MTLStorageModeShared &&
          mapped!=nullptr && nativeBuffer.length>=NSUInteger(logical);
      }
    @catch(NSException* exception) {
      (void)exception;
      }
    if(!validNativeBuffer) {
      fail(IOSLinearHDRProofFailureReason::BufferMap);
      return false;
      }

    try {
      frame.impl =
          std::make_unique<IOSLinearHDRProofFrame::Impl>(std::move(buffer));
      }
    catch(...) {
      fail(IOSLinearHDRProofFailureReason::BufferAlloc);
      return false;
      }
    [nativeSource retain];
    frame.impl->source = nativeSource;
    frame.impl->mapped = static_cast<const std::byte*>(mapped);
    frame.impl->metadata.width = width;
    frame.impl->metadata.height = height;
    frame.impl->metadata.bytesPerRow = static_cast<uint32_t>(row);
    frame.impl->metadata.logicalBytes = logical;
    frame.impl->metadata.targetGeneration = targetGeneration;
    frame.impl->metadata.snapshotSequence = snapshotSequence;
    frame.impl->metadata.proofId = proofId;
    frame.impl->metadata.buildSha = buildSha;
    activeFrame = &frame;
    return true;
    }

  bool encodeCopy(IOSLinearHDRProofFrame& frame,
                  Tempest::Encoder<Tempest::CommandBuffer>& encoder,
                  const Tempest::Attachment& source) noexcept {
    IOSLinearHDRProofNativeView nativeView;
    if(!this->nativeCopyView(frame,source,nativeView))
      return false;
    (void)nativeView;
    try {
      encoder.copy(source,0u,frame.impl->buffer,0u);
      }
    catch(...) {
      fail(IOSLinearHDRProofFailureReason::CopyEncode);
      return false;
      }
    return markNativeCopyEncoded(frame);
    }

  bool nativeCopyView(const IOSLinearHDRProofFrame& frame,
                      const Tempest::Attachment& source,
                      IOSLinearHDRProofNativeView& view) noexcept {
    view = {};
    if(state!=IOSLinearHDRProofProducerState::Armed ||
       activeFrame!=&frame || frame.impl==nullptr ||
       frame.impl->source==nil || frame.impl->mapped==nullptr) {
      fail(IOSLinearHDRProofFailureReason::State);
      return false;
      }
    try {
      const auto& texture =
          Tempest::textureCast<const Tempest::Texture2d&>(source);
      const auto borrowed = Tempest::MetalApi::borrowTexture(owner,texture);
      if(!borrowed ||
         (id<MTLTexture>)(void*)borrowed.get()!=frame.impl->source) {
        fail(IOSLinearHDRProofFailureReason::Stale);
        return false;
        }
      const auto borrowedBuffer =
          Tempest::MetalApi::borrowBuffer(owner,frame.impl->buffer);
      if(!borrowedBuffer) {
        fail(IOSLinearHDRProofFailureReason::Stale);
        return false;
        }
      view.sourceTexture = (void*)borrowed.get();
      view.destinationBuffer = (void*)borrowedBuffer.get();
      view.sceneMarker = sceneMarkerText;
      view.copyMarker = copyMarkerText;
      view.metadata = frame.impl->metadata;
      }
    catch(...) {
      fail(IOSLinearHDRProofFailureReason::Stale);
      return false;
      }
    return view.sourceTexture!=nullptr && view.destinationBuffer!=nullptr &&
           view.sceneMarker.size()==53u && view.copyMarker.size()==57u;
    }

  bool markNativeCopyEncoded(IOSLinearHDRProofFrame& frame) noexcept {
    if(state!=IOSLinearHDRProofProducerState::Armed ||
       activeFrame!=&frame || frame.impl==nullptr || frame.impl->encoded ||
       frame.impl->source==nil || frame.impl->mapped==nullptr) {
      fail(IOSLinearHDRProofFailureReason::State);
      return false;
      }
    if(!iosAdvanceLinearHDRProofProducerState(
         state,IOSLinearHDRProofProducerEvent::Encode)) {
      fail(IOSLinearHDRProofFailureReason::State);
      return false;
      }
    frame.impl->encoded = true;
    return true;
    }

  void markSubmitted(IOSLinearHDRProofFrame& frame) noexcept {
    if(activeFrame!=&frame || frame.impl==nullptr || !frame.impl->encoded ||
       !iosAdvanceLinearHDRProofProducerState(
          state,IOSLinearHDRProofProducerEvent::Submit)) {
      fail(IOSLinearHDRProofFailureReason::State);
      return;
      }
    frame.impl->submitted = true;
    }

  void publish(const IOSLinearHDRProofMetadata& metadata,
               std::span<const std::byte> payload) noexcept {
    std::vector<std::byte> artifact;
    if(!iosLinearHDRProofBuildArtifactV1(metadata,payload,artifact)) {
      fail(IOSLinearHDRProofFailureReason::Layout);
      return;
      }
    IOSLinearHDRProofView parsed;
    IOSLinearHDRProofScan scan;
    if(iosParseLinearHDRProofV1(artifact,parsed)!=
         IOSLinearHDRProofError::None ||
       iosScanLinearHDRProofV1(parsed,scan)!=
         IOSLinearHDRProofError::None) {
      fail(IOSLinearHDRProofFailureReason::Parse);
      return;
      }
    int file = openat(directory,tempLeaf.c_str(),
                      O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(file<0) {
      fail(IOSLinearHDRProofFailureReason::Open);
      return;
      }
    if(!writeAll(file,artifact)) {
      (void)close(file);
      (void)unlinkat(directory,tempLeaf.c_str(),0);
      fail(IOSLinearHDRProofFailureReason::Write);
      return;
      }
    if(fsync(file)!=0) {
      (void)close(file);
      (void)unlinkat(directory,tempLeaf.c_str(),0);
      fail(IOSLinearHDRProofFailureReason::FileFsync);
      return;
      }
    const int closeResult = close(file);
    file = -1;
    if(closeResult!=0) {
      (void)unlinkat(directory,tempLeaf.c_str(),0);
      fail(IOSLinearHDRProofFailureReason::Close);
      return;
      }
    if(renameatx_np(directory,tempLeaf.c_str(),directory,FinalLeaf,
                    RENAME_EXCL)!=0) {
      (void)unlinkat(directory,tempLeaf.c_str(),0);
      fail(IOSLinearHDRProofFailureReason::Rename);
      return;
      }
    if(fsync(directory)!=0) {
      fail(IOSLinearHDRProofFailureReason::DirFsync);
      return;
      }
    if(!iosAdvanceLinearHDRProofProducerState(
         state,IOSLinearHDRProofProducerEvent::Publish)) {
      fail(IOSLinearHDRProofFailureReason::State);
      return;
      }
    std::array<char,255u> line{};
    if(!iosLinearHDRProofFormatSuccessLine(metadata,line)) {
      // The final was committed but remains unaccepted without a success line.
      state = IOSLinearHDRProofProducerState::Completed;
      fail(IOSLinearHDRProofFailureReason::Layout);
      return;
      }
    try {
      Tempest::Log::i(line.data());
      }
    catch(...) {
      // Logging is the acceptance boundary. Leave the final quarantined.
      state = IOSLinearHDRProofProducerState::Completed;
      fail(IOSLinearHDRProofFailureReason::State);
      }
    }

  Tempest::Device& owner;
  IOSLinearHDRProofProducerState state =
      IOSLinearHDRProofProducerState::Disabled;
  std::array<uint8_t,16u> proofId{};
  std::array<uint8_t,20u> buildSha{};
  std::array<char,33u> identityText{};
  std::string sceneMarkerText;
  std::string copyMarkerText;
  std::string toneMarkerText;
  std::string tempLeaf;
  IOSLinearHDRProofFrame* activeFrame = nullptr;
  int directory = -1;
  bool identityAvailable = false;
  bool failureLogged = false;
#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
  IOSLinearHDRCaptureState captureState = IOSLinearHDRCaptureState::Disabled;
  bool captureProfileArmed = false;
  bool captureAttempted = false;
#endif
  };

IOSLinearHDRProofProducer::IOSLinearHDRProofProducer(
    Tempest::Device& device) noexcept {
  try {
    impl = std::make_unique<Impl>(device);
    }
  catch(...) {
    try {
      Tempest::Log::e(
        "RendererIOS HDR proof: v=1 id=none terminal=F class=contract reason=state");
      }
    catch(...) {
      }
    }
  }

IOSLinearHDRProofProducer::~IOSLinearHDRProofProducer() = default;

IOSLinearHDRProofProducerState IOSLinearHDRProofProducer::state() const noexcept {
  return impl!=nullptr ? impl->state
                       : IOSLinearHDRProofProducerState::Failed;
  }

bool IOSLinearHDRProofProducer::armed() const noexcept {
  return state()==IOSLinearHDRProofProducerState::Armed;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_LINEAR_HDR_GPU_TRIPLE_CAPTURE)
bool IOSLinearHDRProofProducer::captureProfileArmed() const noexcept {
  return impl!=nullptr && impl->captureProfileArmed &&
         impl->captureState==IOSLinearHDRCaptureState::Armed;
  }

IOSLinearHDRCaptureStartResult IOSLinearHDRProofProducer::beginCapture(
    IOSLinearHDRCaptureFrame& frame) noexcept {
  return impl!=nullptr ? impl->beginCapture(frame) :
                         IOSLinearHDRCaptureStartResult::RejectedInactive;
  }

void IOSLinearHDRProofProducer::markCapturePreSubmitFailure(
    IOSLinearHDRCaptureFrame& frame) noexcept {
  if(impl!=nullptr)
    impl->captureFailure(frame,"pre-submit");
  }

void IOSLinearHDRProofProducer::markCaptureSubmitAmbiguous(
    IOSLinearHDRCaptureFrame& frame) noexcept {
  if(impl!=nullptr)
    impl->captureFailure(frame,"submit-ambiguous");
  }

bool IOSLinearHDRProofProducer::markCaptureSubmittedAndStop(
    IOSLinearHDRCaptureFrame& frame) noexcept {
  return impl!=nullptr && impl->markCaptureSubmittedAndStop(frame);
  }

void IOSLinearHDRProofProducer::markCaptureIdleFailure(
    IOSLinearHDRCaptureFrame& frame) noexcept {
  if(impl!=nullptr)
    impl->captureFailure(frame,"idle");
  }

bool IOSLinearHDRProofProducer::captureHasOwners(
    const IOSLinearHDRCaptureFrame& frame) const noexcept {
  return frame.impl!=nullptr && frame.impl->session!=nullptr;
  }

bool IOSLinearHDRProofProducer::captureRequiresNoTeardown(
    const IOSLinearHDRCaptureFrame& frame) const noexcept {
  return frame.impl!=nullptr && frame.impl->permanentAmbiguous;
  }

bool IOSLinearHDRProofProducer::settleCaptureAfterConfirmedIdle(
    IOSLinearHDRCaptureFrame& frame) noexcept {
  if(frame.impl==nullptr || frame.impl->session==nullptr)
    return true;
  if(frame.impl->permanentAmbiguous)
    return false;
  if(frame.impl->session->active())
    frame.impl->session->cancel();
  return !frame.impl->session->active();
  }

void IOSLinearHDRProofProducer::releaseCaptureAfterTerminal(
    IOSLinearHDRCaptureFrame& frame) noexcept {
  if(frame.impl==nullptr || frame.impl->permanentAmbiguous ||
     (frame.impl->session!=nullptr && frame.impl->session->active()))
    return;
  frame.impl.reset();
  }
#endif

bool IOSLinearHDRProofProducer::labelSceneTarget(
    Tempest::Attachment& target) noexcept {
  return impl!=nullptr && impl->labelSceneTarget(target);
  }

bool IOSLinearHDRProofProducer::prepareFrame(
    IOSLinearHDRProofFrame& frame,
    const Tempest::Attachment& source,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    uint32_t width,
    uint32_t height) noexcept {
  return impl!=nullptr && impl->prepareFrame(
      frame,source,targetGeneration,snapshotSequence,width,height);
  }

bool IOSLinearHDRProofProducer::encodeCopy(
    IOSLinearHDRProofFrame& frame,
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const Tempest::Attachment& source) noexcept {
  return impl!=nullptr && impl->encodeCopy(frame,encoder,source);
  }

bool IOSLinearHDRProofProducer::nativeCopyView(
    const IOSLinearHDRProofFrame& frame,
    const Tempest::Attachment& source,
    IOSLinearHDRProofNativeView& view) noexcept {
  view = {};
  return impl!=nullptr && impl->nativeCopyView(frame,source,view);
  }

bool IOSLinearHDRProofProducer::markNativeCopyEncoded(
    IOSLinearHDRProofFrame& frame) noexcept {
  return impl!=nullptr && impl->markNativeCopyEncoded(frame);
  }

void IOSLinearHDRProofProducer::markSubmitted(
    IOSLinearHDRProofFrame& frame) noexcept {
  if(impl!=nullptr)
    impl->markSubmitted(frame);
  }

void IOSLinearHDRProofProducer::markSubmitAmbiguous(
    IOSLinearHDRProofFrame& frame) noexcept {
  if(impl==nullptr || frame.impl==nullptr)
    return;
  frame.impl->submitAmbiguous = true;
  impl->fail(IOSLinearHDRProofFailureReason::SubmitAmbiguous);
  }

void IOSLinearHDRProofProducer::abortBeforeSubmit(
    IOSLinearHDRProofFrame& frame) noexcept {
  if(impl!=nullptr && frame.impl!=nullptr)
    impl->fail(IOSLinearHDRProofFailureReason::CopyEncode);
  }

void IOSLinearHDRProofProducer::latchPresentFailure(
    IOSLinearHDRProofFrame& frame) noexcept {
  if(impl==nullptr || frame.impl==nullptr || !frame.impl->submitted)
    return;
  frame.impl->presentFailure = true;
  impl->fail(IOSLinearHDRProofFailureReason::Present);
  }

void IOSLinearHDRProofProducer::markFenceFailure(
    IOSLinearHDRProofFrame& frame) noexcept {
  if(impl!=nullptr && frame.impl!=nullptr && frame.impl->submitted)
    impl->fail(IOSLinearHDRProofFailureReason::Fence);
  }

void IOSLinearHDRProofProducer::markIdleFailure(
    IOSLinearHDRProofFrame& frame) noexcept {
  if(impl!=nullptr && frame.impl!=nullptr &&
     (frame.impl->submitted || frame.impl->submitAmbiguous))
    impl->fail(IOSLinearHDRProofFailureReason::Idle);
  }

void IOSLinearHDRProofProducer::markPostSubmitFailure(
    IOSLinearHDRProofFrame& frame) noexcept {
  latchPresentFailure(frame);
  }

bool IOSLinearHDRProofProducer::isSubmitted(
    const IOSLinearHDRProofFrame& frame) const noexcept {
  return frame.impl!=nullptr && frame.impl->submitted;
  }

bool IOSLinearHDRProofProducer::hasOwners(
    const IOSLinearHDRProofFrame& frame) const noexcept {
  return frame.impl!=nullptr;
  }

void IOSLinearHDRProofProducer::completeAfterTerminal(
    IOSLinearHDRProofFrame& frame,
    uint64_t currentTargetGeneration,
    uint32_t currentWidth,
    uint32_t currentHeight) noexcept {
  if(impl==nullptr || frame.impl==nullptr || !frame.impl->submitted ||
     impl->state==IOSLinearHDRProofProducerState::Failed)
    return;
  if(frame.impl->presentFailure) {
    impl->fail(IOSLinearHDRProofFailureReason::Present);
    return;
    }
  const auto& metadata = frame.impl->metadata;
  if(metadata.targetGeneration!=currentTargetGeneration ||
     metadata.width!=currentWidth || metadata.height!=currentHeight) {
    impl->fail(IOSLinearHDRProofFailureReason::Stale);
    return;
    }
  if(!iosAdvanceLinearHDRProofProducerState(
       impl->state,IOSLinearHDRProofProducerEvent::Complete)) {
    impl->fail(IOSLinearHDRProofFailureReason::State);
    return;
    }
  impl->publish(
      metadata,std::span<const std::byte>(
        frame.impl->mapped,static_cast<size_t>(metadata.logicalBytes)));
  }

void IOSLinearHDRProofProducer::releaseAfterTerminal(
    IOSLinearHDRProofFrame& frame) noexcept {
  if(impl!=nullptr && impl->activeFrame==&frame)
    impl->activeFrame = nullptr;
  frame.impl.reset();
  }

std::string_view IOSLinearHDRProofProducer::sceneMarker() const noexcept {
  return impl!=nullptr ? std::string_view(impl->sceneMarkerText)
                       : std::string_view();
  }

std::string_view IOSLinearHDRProofProducer::copyMarker() const noexcept {
  return impl!=nullptr ? std::string_view(impl->copyMarkerText)
                       : std::string_view();
  }

std::string_view IOSLinearHDRProofProducer::toneResolveMarker() const noexcept {
  return impl!=nullptr ? std::string_view(impl->toneMarkerText)
                       : std::string_view();
  }

#endif
