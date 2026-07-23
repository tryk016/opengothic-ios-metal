#include "iosshadingprototypetileprobe.h"

#include "iosmetalresourceallocator.h"
#include "iosmetalresourceallocatornative.h"
#include "iosshadingprototypepipeline.h"
#include "iosshadingprototypepipelinenative.h"

#include <Tempest/CommandBuffer>
#include <Tempest/Device>
#include <Tempest/Encoder>
#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>

#if __has_feature(objc_arc)
#error "IOSShadingPrototypeTileProbe requires non-ARC Objective-C++ mode"
#endif

namespace {

using namespace RendererIOSShadingPrototypeTileProbe;

struct TileProbeVertex final {
  std::array<float,3u> position;
  std::array<float,4u> color;
  };

static_assert(sizeof(TileProbeVertex)==VertexStride);
static_assert(alignof(TileProbeVertex)==alignof(float));

constexpr std::array<TileProbeVertex,VertexCount> Vertices = {{
  {{{-0.90f,-0.80f,0.0f}},{{1.0f,0.0f,0.0f,1.0f}}},
  {{{-0.10f,-0.80f,0.0f}},{{1.0f,0.0f,0.0f,1.0f}}},
  {{{-0.50f, 0.80f,0.0f}},{{1.0f,0.0f,0.0f,1.0f}}},
  {{{ 0.10f,-0.80f,0.0f}},{{0.0f,1.0f,0.0f,0.25f}}},
  {{{ 0.90f,-0.80f,0.0f}},{{0.0f,1.0f,0.0f,0.25f}}},
  {{{ 0.50f, 0.80f,0.0f}},{{0.0f,1.0f,0.0f,0.25f}}},
  }};

static_assert(sizeof(Vertices)==VertexBytes);

template<class T>
class OwnedObjectiveC final {
  public:
    explicit OwnedObjectiveC(T value = nil) noexcept
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

class ScopedRenderEncoder final {
  public:
    explicit ScopedRenderEncoder(
        id<MTLRenderCommandEncoder> value) noexcept
      : value(value) {
      }

    ~ScopedRenderEncoder() noexcept {
      closeOrTerminate();
      }

    ScopedRenderEncoder(const ScopedRenderEncoder&) = delete;
    ScopedRenderEncoder& operator=(const ScopedRenderEncoder&) = delete;

    explicit operator bool() const noexcept {
      return value!=nil;
      }

    id<MTLRenderCommandEncoder> get() const noexcept {
      return value;
      }

    bool endOnce() noexcept {
      if(value==nil || endSucceeded)
        return false;
      return attemptEnd();
      }

  private:
    static constexpr uint32_t MaximumEndAttempts = 2u;

    bool attemptEnd() noexcept {
      if(value==nil || endSucceeded ||
         endAttempts>=MaximumEndAttempts)
        return endSucceeded;
      ++endAttempts;
      @try {
        [value endEncoding];
        endSucceeded = true;
        return true;
        }
      @catch(NSException*) {
        return false;
        }
      }

    void closeOrTerminate() noexcept {
      while(value!=nil && !endSucceeded &&
            endAttempts<MaximumEndAttempts)
        (void)attemptEnd();
      // Returning with a possibly-active native encoder would violate the
      // one-shot Tempest command-buffer bridge. Two ambiguous Objective-C
      // failures therefore become a fail-stop instead of leaked encoding.
      if(value!=nil && !endSucceeded)
        std::terminate();
      }

    id<MTLRenderCommandEncoder> value = nil;
    uint32_t endAttempts = 0u;
    bool endSucceeded = false;
  };

struct NativeEncodeContext final {
  MTL::Device* device = nullptr;
  MTL::Texture* output = nullptr;
  IOSShadingPrototypePipelineNativeView pipelines;
  IOSShadingPrototypeTileProbeReport* report = nullptr;
  bool succeeded = false;
  };

bool onlyOutputAttachment(
    MTLRenderPassDescriptor* descriptor,
    id<MTLTexture> output) {
  if(descriptor==nil ||
     descriptor.colorAttachments[OutputAttachment].texture!=output)
    return false;
  for(NSUInteger index=1u; index<NSUInteger(8u); ++index) {
    if(descriptor.colorAttachments[index].texture!=nil)
      return false;
    }
  return descriptor.depthAttachment.texture==nil &&
         descriptor.stencilAttachment.texture==nil;
  }

void appendOperation(
    IOSShadingPrototypeTileProbeReport& report,
    IOSShadingPrototypeTileProbeOperation operation) noexcept {
  if(report.operationCount>=report.operations.size())
    return;
  report.operations[report.operationCount] = operation;
  ++report.operationCount;
  }

void encodeTileProbe(void* rawContext,
                     MTL::CommandBuffer* rawCommand) {
  auto& context = *static_cast<NativeEncodeContext*>(rawContext);
  if(rawCommand==nullptr || context.device==nullptr ||
     context.output==nullptr || context.report==nullptr ||
     context.pipelines.device!=context.device ||
     context.pipelines.opaque==nullptr ||
     context.pipelines.alphaTest==nullptr ||
     context.pipelines.tileLighting==nullptr)
    return;

  auto& report = *context.report;
  id<MTLCommandBuffer> command =
      reinterpret_cast<id<MTLCommandBuffer>>((void*)rawCommand);
  id<MTLDevice> device =
      reinterpret_cast<id<MTLDevice>>((void*)context.device);
  id<MTLTexture> output =
      reinterpret_cast<id<MTLTexture>>((void*)context.output);
  id<MTLRenderPipelineState> opaque =
      reinterpret_cast<id<MTLRenderPipelineState>>(
          (void*)context.pipelines.opaque);
  id<MTLRenderPipelineState> alphaTest =
      reinterpret_cast<id<MTLRenderPipelineState>>(
          (void*)context.pipelines.alphaTest);
  id<MTLRenderPipelineState> tileLighting =
      reinterpret_cast<id<MTLRenderPipelineState>>(
          (void*)context.pipelines.tileLighting);

  @autoreleasepool {
    @try {
      if(command==nil || device==nil || output==nil ||
         opaque==nil || alphaTest==nil || tileLighting==nil ||
         command.device!=device || output.device!=device ||
         opaque.device!=device || alphaTest.device!=device ||
         tileLighting.device!=device)
        return;
      report.borrowedVirginCommandBuffer = true;

      OwnedObjectiveC<MTLRenderPassDescriptor*> descriptor(
          [[MTLRenderPassDescriptor alloc] init]);
      if(descriptor.get()==nil)
        return;
      MTLRenderPassColorAttachmentDescriptor* color =
          descriptor.get().colorAttachments[OutputAttachment];
      if(color==nil)
        return;
      color.texture = output;
      color.loadAction = MTLLoadActionClear;
      color.storeAction = MTLStoreActionStore;
      color.clearColor = MTLClearColorMake(0.0,0.0,0.0,0.0);
      descriptor.get().imageblockSampleLength =
          static_cast<NSUInteger>(ImageblockBytesPerSample);
      descriptor.get().threadgroupMemoryLength =
          static_cast<NSUInteger>(ThreadgroupMemoryLength);
      descriptor.get().tileWidth =
          static_cast<NSUInteger>(TileWidth);
      descriptor.get().tileHeight =
          static_cast<NSUInteger>(TileHeight);

      const MTLClearColor clear = color.clearColor;
      report.transparentBlackClear =
          color.loadAction==MTLLoadActionClear &&
          color.storeAction==MTLStoreActionStore &&
          clear.red==0.0 && clear.green==0.0 &&
          clear.blue==0.0 && clear.alpha==0.0;
      report.outputAttachments =
          onlyOutputAttachment(descriptor.get(),output) ? 1u : 0u;
      report.outputAttachmentIndex = OutputAttachment;
      report.materialTextures = 0u;
      report.imageblockBytesPerSample =
          static_cast<uint32_t>(
              descriptor.get().imageblockSampleLength);
      report.threadgroupMemoryLength =
          static_cast<uint32_t>(
              descriptor.get().threadgroupMemoryLength);
      report.tileWidth =
          static_cast<uint32_t>(descriptor.get().tileWidth);
      report.tileHeight =
          static_cast<uint32_t>(descriptor.get().tileHeight);
      if(!report.transparentBlackClear ||
         report.outputAttachments!=1u ||
         report.imageblockBytesPerSample!=
             ImageblockBytesPerSample ||
         report.threadgroupMemoryLength!=
             ThreadgroupMemoryLength ||
         report.tileWidth!=TileWidth ||
         report.tileHeight!=TileHeight)
        return;

      ScopedRenderEncoder encoder(
          [command renderCommandEncoderWithDescriptor:
                       descriptor.get()]);
      if(!encoder)
        return;
      report.physicalPasses = 1u;
      report.commandBuffers = 1u;
      report.renderEncoders = 1u;

      [encoder.get()
          setVertexBytes:Vertices.data()
                  length:sizeof(Vertices)
                 atIndex:NSUInteger(0u)];
      report.vertexByteBindings = 1u;
      report.vertices = VertexCount;
      report.vertexBytes = VertexBytes;

      [encoder.get() setRenderPipelineState:opaque];
      ++report.pipelineStates;
      [encoder.get() drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:NSUInteger(0u)
                        vertexCount:NSUInteger(3u)];
      ++report.draws;
      ++report.opaqueDraws;
      appendOperation(
          report,
          IOSShadingPrototypeTileProbeOperation::DrawOpaque);

      [encoder.get() setRenderPipelineState:alphaTest];
      ++report.pipelineStates;
      [encoder.get() drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:NSUInteger(3u)
                        vertexCount:NSUInteger(3u)];
      ++report.draws;
      ++report.alphaTestDraws;
      appendOperation(
          report,
          IOSShadingPrototypeTileProbeOperation::DrawAlphaTest);

      [encoder.get() setRenderPipelineState:tileLighting];
      ++report.pipelineStates;
      [encoder.get()
          dispatchThreadsPerTile:
              MTLSizeMake(
                  static_cast<NSUInteger>(DispatchWidth),
                  static_cast<NSUInteger>(DispatchHeight),
                  static_cast<NSUInteger>(DispatchDepth))];
      report.tileDispatches = 1u;
      report.dispatchWidth = DispatchWidth;
      report.dispatchHeight = DispatchHeight;
      report.dispatchDepth = DispatchDepth;
      appendOperation(
          report,
          IOSShadingPrototypeTileProbeOperation::DispatchTileLighting);

      if(!encoder.endOnce())
        return;
      report.endEncodingCalls = 1u;
      report.encoded = true;
      context.succeeded =
          iosShadingPrototypeTileProbeReportMatches(report);
      }
    @catch(NSException*) {
      context.succeeded = false;
      }
    }
  }

}

bool iosEncodeShadingPrototypeTileProbe(
    Tempest::Device& device,
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSShadingPrototypePipeline& pipeline,
    const IOSMetalResourceTexture& output,
    IOSShadingPrototypeTileProbeReport& report) noexcept {
  report = {};
  report.contractVersion = ContractVersion;

  @try {
    try {
      @autoreleasepool {
        if(!pipeline ||
           pipeline.status()!=
               IOSShadingPrototypePipelineStatus::Ready ||
           !pipeline.report().supportsApple4)
          return false;
        report.supportsApple4 = true;
        report.pipelineReady = true;

        IOSShadingPrototypePipelineNativeView pipelines;
        if(!IOSShadingPrototypePipelineNativeAccess::borrow(
               pipeline,pipelines))
          return false;

        const Tempest::BorrowedMetalDevice borrowedDevice =
            Tempest::MetalApi::borrowDevice(device);
        report.borrowedExistingDevice =
            static_cast<bool>(borrowedDevice);
        if(!borrowedDevice)
          return false;
        MTL::Device* nativeDevice = borrowedDevice.get();
        report.pipelineSameDevice =
            pipelines.device==nativeDevice;
        if(!report.pipelineSameDevice)
          return false;

        const IOSMetalTextureSnapshot outputSnapshot =
            output.snapshot();
        report.outputAvailable = outputSnapshot.available;
        report.outputSameDevice =
            outputSnapshot.deviceIdentity==
            reinterpret_cast<uintptr_t>((void*)nativeDevice);
        report.outputType2D =
            outputSnapshot.type==IOSMetalTextureType::Type2D;
        report.outputRgba8Unorm =
            outputSnapshot.format==IOSPixelFormat::Rgba8Unorm;
        report.outputPrivate =
            outputSnapshot.storage==
            IOSMetalResourceStorage::Private;
        report.outputExtentMatches =
            outputSnapshot.extent.width==OutputWidth &&
            outputSnapshot.extent.height==OutputHeight &&
            outputSnapshot.mipLevels==1u &&
            outputSnapshot.sampleCount==1u &&
            outputSnapshot.depth==1u &&
            outputSnapshot.arrayLength==1u &&
            outputSnapshot.usageExactlyRepresented &&
            outputSnapshot.usage==
                IOSResourceUsage::RenderAttachment;
        if(!report.outputAvailable ||
           !report.outputSameDevice ||
           !report.outputType2D ||
           !report.outputRgba8Unorm ||
           !report.outputPrivate ||
           !report.outputExtentMatches)
          return false;

        MTL::Texture* nativeOutput =
            IOSMetalResourceTextureNativeAccess::borrow(output);
        if(nativeOutput==nullptr)
          return false;

        NativeEncodeContext context;
        context.device = nativeDevice;
        context.output = nativeOutput;
        context.pipelines = pipelines;
        context.report = &report;
        report.withActiveCommandBufferCalls = 1u;
        const bool bridgeAccepted =
            Tempest::MetalApi::withActiveCommandBuffer(
                device,encoder,&context,encodeTileProbe);
        return bridgeAccepted && context.succeeded &&
               iosShadingPrototypeTileProbeReportMatches(report);
        }
      }
    catch(...) {
      return false;
      }
    }
  @catch(NSException*) {
    return false;
    }
  }
