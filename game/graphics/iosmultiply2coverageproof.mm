#include "iosmultiply2coverageproof.h"

#include <Tempest/Attachment>
#include <Tempest/Device>
#include <Tempest/Log>
#include <Tempest/MetalApi>
#include <Tempest/StorageBuffer>
#include <Tempest/Texture2d>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#if __has_feature(objc_arc)
#error "IOSMultiply2CoverageProofProducer requires non-ARC Objective-C++ mode"
#endif

namespace {

constexpr char FinalLeaf[] = "RendererIOS-multiply2-coverage-v1.bin";

bool checkedMultiply(uint64_t lhs, uint64_t rhs,
                     uint64_t& output) noexcept {
  if(lhs!=0u && rhs>std::numeric_limits<uint64_t>::max()/lhs)
    return false;
  output = lhs*rhs;
  return true;
}

bool writeAll(int file, std::span<const std::byte> bytes) noexcept {
  std::size_t offset = 0u;
  while(offset<bytes.size()) {
    const ssize_t written = ::write(
        file,bytes.data()+static_cast<std::ptrdiff_t>(offset),
        bytes.size()-offset);
    if(written<0 && errno==EINTR)
      continue;
    if(written<=0)
      return false;
    offset += static_cast<std::size_t>(written);
  }
  return true;
}

bool exactEvidenceDirectory(const char* path) noexcept {
  if(path==nullptr || path[0]=='\0')
    return false;
  if(::mkdir(path,0700)!=0 && errno!=EEXIST)
    return false;
  struct stat status{};
  return ::lstat(path,&status)==0 && S_ISDIR(status.st_mode) &&
         (status.st_mode&0777u)==0700u && status.st_uid==::getuid();
}

bool validMetadata(
    const IOSMultiply2CoverageProofMetadata& metadata) noexcept {
  const IOSMultiply2CoverageRect exact =
      {0u,0u,metadata.width,metadata.height};
  const auto nonzero = [](auto&& bytes) {
    return std::any_of(bytes.begin(),bytes.end(),[](uint8_t value) {
      return value!=0u;
    });
  };
  return metadata.width!=0u && metadata.height!=0u &&
         metadata.width<=IOSMultiply2CoverageProofV1MaximumExtent &&
         metadata.height<=IOSMultiply2CoverageProofV1MaximumExtent &&
         metadata.bytesPerRow==metadata.width &&
         metadata.sampleCount==1u &&
         metadata.payloadBytes==
             uint64_t(metadata.width)*uint64_t(metadata.height) &&
         metadata.targetGeneration!=0u && metadata.snapshotSequence!=0u &&
         metadata.sourceId!=0u && metadata.indexCount!=0u &&
         metadata.viewport==exact && metadata.scissor==exact &&
         nonzero(metadata.proofId) && nonzero(metadata.buildSha);
}

}

struct IOSMultiply2CoverageFrame::Impl final {
  explicit Impl(Tempest::StorageBuffer&& buffer) noexcept
    : buffer(std::move(buffer)) {
  }

  ~Impl() {
    [depthStencil release];
    [sceneHDR release];
  }

  Tempest::StorageBuffer buffer;
  id<MTLTexture> sceneHDR = nil;
  id<MTLTexture> depthStencil = nil;
  const std::byte* mapped = nullptr;
  IOSMultiply2CoverageProofMetadata metadata;
  uint32_t gpuBytesPerRow = 0u;
  bool encoded = false;
  bool submitted = false;
};

IOSMultiply2CoverageFrame::IOSMultiply2CoverageFrame() noexcept = default;
IOSMultiply2CoverageFrame::~IOSMultiply2CoverageFrame() = default;
IOSMultiply2CoverageFrame::IOSMultiply2CoverageFrame(
    IOSMultiply2CoverageFrame&&) noexcept = default;
IOSMultiply2CoverageFrame& IOSMultiply2CoverageFrame::operator=(
    IOSMultiply2CoverageFrame&&) noexcept = default;

struct IOSMultiply2CoverageProofProducer::Impl final {
  explicit Impl(Tempest::Device& owner) noexcept : owner(owner) {
    const char* home = std::getenv("HOME");
    if(home==nullptr || home[0]=='\0') {
      fail("documents-directory");
      return;
    }
    try {
      directoryPath = home;
      directoryPath += "/Documents/RendererIOS-multiply2-evidence";
    }
    catch(...) {
      fail("documents-directory");
      return;
    }
    if(!exactEvidenceDirectory(directoryPath.c_str())) {
      fail("evidence-directory-policy");
      return;
    }
    state = IOSMultiply2CoverageProducerState::Armed;
  }

  void fail(const char* reason) noexcept {
    if(state==IOSMultiply2CoverageProducerState::Published ||
       state==IOSMultiply2CoverageProducerState::Failed)
      return;
    state = IOSMultiply2CoverageProducerState::Failed;
    if(failureLogged)
      return;
    failureLogged = true;
    try {
      Tempest::Log::e(
          "RendererIOS multiply2 coverage: v=1 terminal=F reason=",reason);
    }
    catch(...) {
    }
  }

  bool prepareFrame(
      IOSMultiply2CoverageFrame& frame,
      const Tempest::Attachment& sceneHDR,
      const IOSMultiply2CoverageProofMetadata& metadata) noexcept {
    if(state!=IOSMultiply2CoverageProducerState::Armed ||
       activeFrame!=nullptr || frame.impl!=nullptr) {
      fail("state");
      return false;
    }
    if(!validMetadata(metadata)) {
      fail("layout");
      return false;
    }

    id<MTLTexture> nativeSceneHDR = nil;
    id<MTLTexture> depthStencil = nil;
    Tempest::StorageBuffer buffer;
    const std::byte* mapped = nullptr;
    uint64_t alignedRow = (uint64_t(metadata.width)+255u)&~uint64_t(255u);
    uint64_t gpuBytes = 0u;
    if(alignedRow>std::numeric_limits<uint32_t>::max() ||
       !checkedMultiply(alignedRow,uint64_t(metadata.height),gpuBytes) ||
       gpuBytes==0u || gpuBytes>std::numeric_limits<std::size_t>::max()) {
      fail("layout");
      return false;
    }
    try {
      const auto& texture =
          Tempest::textureCast<const Tempest::Texture2d&>(sceneHDR);
      const auto borrowedScene =
          Tempest::MetalApi::borrowTexture(owner,texture);
      const auto borrowedDevice = Tempest::MetalApi::borrowDevice(owner);
      if(!borrowedScene || !borrowedDevice) {
        fail("target");
        return false;
      }
      nativeSceneHDR = (id<MTLTexture>)(void*)borrowedScene.get();
      id<MTLDevice> device = (id<MTLDevice>)(void*)borrowedDevice.get();
      @autoreleasepool {
        @try {
          constexpr MTLTextureUsage sceneUsage =
              MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
          if(nativeSceneHDR==nil || nativeSceneHDR.device!=device ||
             nativeSceneHDR.pixelFormat!=MTLPixelFormatRG11B10Float ||
             nativeSceneHDR.storageMode!=MTLStorageModePrivate ||
             nativeSceneHDR.textureType!=MTLTextureType2D ||
             nativeSceneHDR.width!=NSUInteger(metadata.width) ||
             nativeSceneHDR.height!=NSUInteger(metadata.height) ||
             nativeSceneHDR.mipmapLevelCount!=1u ||
             nativeSceneHDR.arrayLength!=1u ||
             nativeSceneHDR.sampleCount!=1u ||
             nativeSceneHDR.usage!=sceneUsage) {
            fail("target");
            return false;
          }
          MTLTextureDescriptor* descriptor =
              [[MTLTextureDescriptor alloc] init];
          if(descriptor==nil) {
            fail("depth-stencil-allocation");
            return false;
          }
          descriptor.textureType = MTLTextureType2D;
          descriptor.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
          descriptor.width = NSUInteger(metadata.width);
          descriptor.height = NSUInteger(metadata.height);
          descriptor.depth = 1u;
          descriptor.mipmapLevelCount = 1u;
          descriptor.sampleCount = 1u;
          descriptor.arrayLength = 1u;
          descriptor.storageMode = MTLStorageModePrivate;
          descriptor.cpuCacheMode = MTLCPUCacheModeDefaultCache;
          descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
          descriptor.usage = MTLTextureUsageRenderTarget;
          depthStencil = [device newTextureWithDescriptor:descriptor];
          [descriptor release];
          if(depthStencil==nil || depthStencil.device!=device ||
             depthStencil.pixelFormat!=MTLPixelFormatDepth32Float_Stencil8 ||
             depthStencil.storageMode!=MTLStorageModePrivate ||
             depthStencil.width!=NSUInteger(metadata.width) ||
             depthStencil.height!=NSUInteger(metadata.height) ||
             depthStencil.sampleCount!=1u ||
             depthStencil.usage!=MTLTextureUsageRenderTarget) {
            [depthStencil release];
            fail("depth-stencil-allocation");
            return false;
          }
          depthStencil.label = @"RendererIOS.Multiply2.CausalStencil.v1";
        }
        @catch(NSException*) {
          [depthStencil release];
          fail("depth-stencil-allocation");
          return false;
        }
      }
      buffer = owner.ssbo(
          Tempest::BufferHeap::Upload,Tempest::Uninitialized,
          static_cast<std::size_t>(gpuBytes));
      if(buffer.isEmpty() || buffer.byteSize()!=gpuBytes) {
        [depthStencil release];
        fail("buffer-allocation");
        return false;
      }
      const auto borrowedBuffer = Tempest::MetalApi::borrowBuffer(owner,buffer);
      if(!borrowedBuffer) {
        [depthStencil release];
        fail("buffer-map");
        return false;
      }
      id<MTLBuffer> nativeBuffer = (id<MTLBuffer>)(void*)borrowedBuffer.get();
      @try {
        if(nativeBuffer.storageMode!=MTLStorageModeShared ||
           nativeBuffer.length<NSUInteger(gpuBytes) ||
           nativeBuffer.contents==nullptr) {
          [depthStencil release];
          fail("buffer-map");
          return false;
        }
        nativeBuffer.label = @"RendererIOS.Multiply2.CoverageReadback.v1";
        mapped = static_cast<const std::byte*>(nativeBuffer.contents);
      }
      @catch(NSException*) {
        [depthStencil release];
        fail("buffer-map");
        return false;
      }
    }
    catch(...) {
      [depthStencil release];
      fail("allocation");
      return false;
    }

    try {
      frame.impl = std::make_unique<IOSMultiply2CoverageFrame::Impl>(
          std::move(buffer));
    }
    catch(...) {
      [depthStencil release];
      fail("allocation");
      return false;
    }
    [nativeSceneHDR retain];
    frame.impl->sceneHDR = nativeSceneHDR;
    frame.impl->depthStencil = depthStencil;
    frame.impl->mapped = mapped;
    frame.impl->metadata = metadata;
    frame.impl->gpuBytesPerRow = static_cast<uint32_t>(alignedRow);
    activeFrame = &frame;
    state = IOSMultiply2CoverageProducerState::Prepared;
    return true;
  }

  bool nativeView(const IOSMultiply2CoverageFrame& frame,
                  IOSMultiply2CoverageNativeView& view) const noexcept {
    view = {};
    if(state!=IOSMultiply2CoverageProducerState::Prepared ||
       activeFrame!=&frame || frame.impl==nullptr ||
       frame.impl->sceneHDR==nil || frame.impl->depthStencil==nil ||
       frame.impl->mapped==nullptr)
      return false;
    try {
      const auto borrowed =
          Tempest::MetalApi::borrowBuffer(owner,frame.impl->buffer);
      if(!borrowed)
        return false;
      view.depthStencilTexture = (void*)frame.impl->depthStencil;
      view.coverageBuffer = (void*)borrowed.get();
      view.width = frame.impl->metadata.width;
      view.height = frame.impl->metadata.height;
      view.gpuBytesPerRow = frame.impl->gpuBytesPerRow;
      view.metadata = frame.impl->metadata;
      return view.depthStencilTexture!=nullptr &&
             view.coverageBuffer!=nullptr;
    }
    catch(...) {
      return false;
    }
  }

  bool markEncoded(IOSMultiply2CoverageFrame& frame) noexcept {
    if(state!=IOSMultiply2CoverageProducerState::Prepared ||
       activeFrame!=&frame || frame.impl==nullptr || frame.impl->encoded) {
      fail("state");
      return false;
    }
    frame.impl->encoded = true;
    state = IOSMultiply2CoverageProducerState::Encoded;
    return true;
  }

  void markSubmitted(IOSMultiply2CoverageFrame& frame) noexcept {
    if(state!=IOSMultiply2CoverageProducerState::Encoded ||
       activeFrame!=&frame || frame.impl==nullptr || !frame.impl->encoded) {
      fail("state");
      return;
    }
    frame.impl->submitted = true;
    state = IOSMultiply2CoverageProducerState::Submitted;
  }

  bool publish(IOSMultiply2CoverageFrame& frame) noexcept {
    if(state!=IOSMultiply2CoverageProducerState::Submitted ||
       activeFrame!=&frame || frame.impl==nullptr || !frame.impl->submitted ||
       frame.impl->mapped==nullptr) {
      fail("state");
      return false;
    }
    std::vector<std::byte> payload;
    try {
      payload.resize(static_cast<std::size_t>(
          frame.impl->metadata.payloadBytes));
      for(uint32_t y=0u; y<frame.impl->metadata.height; ++y) {
        const std::byte* source = frame.impl->mapped+
            static_cast<std::ptrdiff_t>(
                uint64_t(y)*frame.impl->gpuBytesPerRow);
        std::copy_n(
            source,frame.impl->metadata.width,
            payload.begin()+static_cast<std::ptrdiff_t>(
                uint64_t(y)*frame.impl->metadata.width));
      }
    }
    catch(...) {
      fail("payload");
      return false;
    }
    std::vector<std::byte> artifact;
    if(!iosBuildMultiply2CoverageProofV1(
           frame.impl->metadata,payload,artifact)) {
      fail("payload");
      return false;
    }
    IOSMultiply2CoverageProofView parsed;
    if(iosParseMultiply2CoverageProofV1(artifact,parsed)!=
         IOSMultiply2CoverageProofError::None ||
       parsed.metadata.targetGeneration!=
           frame.impl->metadata.targetGeneration ||
       parsed.metadata.snapshotSequence!=
           frame.impl->metadata.snapshotSequence) {
      fail("parse");
      return false;
    }
    int directory = ::open(
        directoryPath.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    if(directory<0) {
      fail("open-directory");
      return false;
    }
    std::string temporary;
    try {
      temporary = ".RendererIOS-multiply2-coverage-v1.g"+
          std::to_string(frame.impl->metadata.targetGeneration)+".s"+
          std::to_string(frame.impl->metadata.snapshotSequence)+".tmp";
    }
    catch(...) {
      (void)::close(directory);
      fail("temporary-name");
      return false;
    }
    int file = ::openat(
        directory,temporary.c_str(),
        O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(file<0) {
      (void)::close(directory);
      fail("open");
      return false;
    }
    bool committed = writeAll(file,artifact) && ::fsync(file)==0;
    committed = ::close(file)==0 && committed;
    file = -1;
    if(committed)
      committed = ::renameatx_np(
          directory,temporary.c_str(),directory,FinalLeaf,RENAME_EXCL)==0;
    if(!committed)
      (void)::unlinkat(directory,temporary.c_str(),0);
    if(committed)
      committed = ::fsync(directory)==0;
    (void)::close(directory);
    if(!committed) {
      fail("publish");
      return false;
    }
    state = IOSMultiply2CoverageProducerState::Published;
    try {
      Tempest::Log::i(
          "RendererIOS multiply2 coverage: v=1 g=",
          frame.impl->metadata.targetGeneration,
          " s=",frame.impl->metadata.snapshotSequence,
          " source=",frame.impl->metadata.sourceId,
          " width=",frame.impl->metadata.width,
          " height=",frame.impl->metadata.height,
          " terminal=C");
    }
    catch(...) {
      state = IOSMultiply2CoverageProducerState::Failed;
      return false;
    }
    return true;
  }

  Tempest::Device& owner;
  IOSMultiply2CoverageProducerState state =
      IOSMultiply2CoverageProducerState::Disabled;
  IOSMultiply2CoverageFrame* activeFrame = nullptr;
  std::string directoryPath;
  bool failureLogged = false;
};

IOSMultiply2CoverageProofProducer::IOSMultiply2CoverageProofProducer(
    Tempest::Device& device) noexcept {
  try {
    impl = std::make_unique<Impl>(device);
  }
  catch(...) {
    try {
      Tempest::Log::e(
          "RendererIOS multiply2 coverage: v=1 terminal=F reason=state");
    }
    catch(...) {
    }
  }
}

IOSMultiply2CoverageProofProducer::~IOSMultiply2CoverageProofProducer() =
    default;

IOSMultiply2CoverageProducerState
IOSMultiply2CoverageProofProducer::state() const noexcept {
  return impl!=nullptr ? impl->state
                       : IOSMultiply2CoverageProducerState::Failed;
}

bool IOSMultiply2CoverageProofProducer::armed() const noexcept {
  return state()==IOSMultiply2CoverageProducerState::Armed;
}

bool IOSMultiply2CoverageProofProducer::prepareFrame(
    IOSMultiply2CoverageFrame& frame,
    const Tempest::Attachment& sceneHDR,
    const IOSMultiply2CoverageProofMetadata& metadata) noexcept {
  return impl!=nullptr && impl->prepareFrame(frame,sceneHDR,metadata);
}

bool IOSMultiply2CoverageProofProducer::nativeView(
    const IOSMultiply2CoverageFrame& frame,
    IOSMultiply2CoverageNativeView& view) const noexcept {
  view = {};
  return impl!=nullptr && impl->nativeView(frame,view);
}

bool IOSMultiply2CoverageProofProducer::markEncoded(
    IOSMultiply2CoverageFrame& frame) noexcept {
  return impl!=nullptr && impl->markEncoded(frame);
}

void IOSMultiply2CoverageProofProducer::markSubmitted(
    IOSMultiply2CoverageFrame& frame) noexcept {
  if(impl!=nullptr)
    impl->markSubmitted(frame);
}

void IOSMultiply2CoverageProofProducer::markSubmitAmbiguous(
    IOSMultiply2CoverageFrame& frame) noexcept {
  if(impl!=nullptr && frame.impl!=nullptr)
    impl->fail("submit-ambiguous");
}

void IOSMultiply2CoverageProofProducer::abortBeforeSubmit(
    IOSMultiply2CoverageFrame& frame) noexcept {
  if(impl!=nullptr && frame.impl!=nullptr)
    impl->fail("pre-submit");
}

void IOSMultiply2CoverageProofProducer::markPostSubmitFailure(
    IOSMultiply2CoverageFrame& frame) noexcept {
  if(impl!=nullptr && frame.impl!=nullptr && frame.impl->submitted)
    impl->fail("post-submit");
}

void IOSMultiply2CoverageProofProducer::markIdleFailure(
    IOSMultiply2CoverageFrame& frame) noexcept {
  if(impl!=nullptr && frame.impl!=nullptr && frame.impl->submitted)
    impl->fail("idle");
}

bool IOSMultiply2CoverageProofProducer::isSubmitted(
    const IOSMultiply2CoverageFrame& frame) const noexcept {
  return frame.impl!=nullptr && frame.impl->submitted;
}

bool IOSMultiply2CoverageProofProducer::hasOwners(
    const IOSMultiply2CoverageFrame& frame) const noexcept {
  return frame.impl!=nullptr;
}

bool IOSMultiply2CoverageProofProducer::completeAfterTerminal(
    IOSMultiply2CoverageFrame& frame,
    uint64_t currentTargetGeneration,
    uint32_t currentWidth,
    uint32_t currentHeight) noexcept {
  if(impl==nullptr || frame.impl==nullptr || !frame.impl->submitted)
    return false;
  if(frame.impl->metadata.targetGeneration!=currentTargetGeneration ||
     frame.impl->metadata.width!=currentWidth ||
     frame.impl->metadata.height!=currentHeight) {
    impl->fail("stale");
    return false;
  }
  return impl->publish(frame);
}

void IOSMultiply2CoverageProofProducer::releaseAfterTerminal(
    IOSMultiply2CoverageFrame& frame) noexcept {
  if(impl!=nullptr && impl->activeFrame==&frame)
    impl->activeFrame = nullptr;
  frame.impl.reset();
}
