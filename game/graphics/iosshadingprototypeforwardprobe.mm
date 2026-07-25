#include "iosshadingprototypeforwardprobe.h"

#include "iosmetalresourceallocator.h"
#include "iosmetalresourceallocatornative.h"
#include "iosshadingprototypeforwardpipelinenative.h"

#include <Tempest/CommandBuffer>
#include <Tempest/Device>
#include <Tempest/Encoder>
#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <utility>

#if __has_feature(objc_arc)
#error "IOSShadingPrototypeForwardProbe requires non-ARC Objective-C++ mode"
#endif

namespace MTL {
class Buffer;
}

class IOSShadingPrototypeForwardLightListNativeAccess final {
  public:
    [[nodiscard]] static MTL::Buffer* borrow(
        const IOSShadingPrototypeForwardLightList& lightList) noexcept;
  };

namespace {

using namespace RendererIOSShadingPrototypeForwardProbe;
namespace Shader = RendererIOSShadingPrototypeShader;
namespace PipelineContract =
    RendererIOSShadingPrototypeForwardPipeline;

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
struct LightListLifetimeCounters final {
  std::atomic<uint64_t> created{0u};
  std::atomic<uint64_t> live{0u};
  std::atomic<uint64_t> released{0u};
  };

LightListLifetimeCounters LightListLifetime;
#endif

static_assert(Shader::ForwardLightListByteSize==256u);
static_assert(Shader::ForwardLightListWordCount==64u);
static_assert(Shader::ForwardLightListWordBytes==sizeof(uint32_t));
static_assert(Shader::ForwardLightListBuffer==0u);
static_assert(Shader::ForwardLightListGridWidth==1u);
static_assert(Shader::ForwardLightListGridHeight==1u);
static_assert(Shader::ForwardLightListGridDepth==1u);
static_assert(
    Shader::ForwardLightListThreadsPerThreadgroupWidth==1u);
static_assert(
    Shader::ForwardLightListThreadsPerThreadgroupHeight==1u);
static_assert(
    Shader::ForwardLightListThreadsPerThreadgroupDepth==1u);
static_assert(PipelineContract::VertexBufferIndex==0u);
static_assert(sizeof(float)==4u);

struct ForwardProbeVertex final {
  std::array<float,3u> position;
  std::array<float,4u> color;
  };

static_assert(sizeof(ForwardProbeVertex)==VertexStride);
static_assert(alignof(ForwardProbeVertex)==alignof(float));

constexpr std::array<ForwardProbeVertex,VertexCount> Vertices = {{
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

    T relinquish() noexcept {
      const T result = value;
      value = nil;
      return result;
      }

  private:
    T value = nil;
  };

template<class NativeEncoder>
class ScopedNativeEncoder final {
  public:
    explicit ScopedNativeEncoder(NativeEncoder value) noexcept
      : value(value) {
      }

    ~ScopedNativeEncoder() noexcept {
      closeOrTerminate();
      }

    ScopedNativeEncoder(const ScopedNativeEncoder&) = delete;
    ScopedNativeEncoder& operator=(const ScopedNativeEncoder&) = delete;

    explicit operator bool() const noexcept {
      return value!=nil;
      }

    NativeEncoder get() const noexcept {
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
      if(value!=nil && !endSucceeded)
        std::terminate();
      }

    NativeEncoder value = nil;
    uint32_t endAttempts = 0u;
    bool endSucceeded = false;
  };

bool exactString(NSString* actual,
                 std::string_view expected) {
  if(actual==nil)
    return false;
  OwnedObjectiveC<NSString*> expectedString(
      [[NSString alloc]
          initWithBytes:expected.data()
                 length:expected.size()
               encoding:NSUTF8StringEncoding]);
  return expectedString.get()!=nil &&
         [actual isEqualToString:expectedString.get()];
  }

uint32_t reason(
    IOSShadingPrototypeForwardFailureReason value) noexcept {
  return static_cast<uint32_t>(value);
  }

uint32_t operation(
    IOSShadingPrototypeForwardProbeOperation value) noexcept {
  return static_cast<uint32_t>(value);
  }

void appendOperation(
    IOSShadingPrototypeForwardProbeReportV1& report,
    IOSShadingPrototypeForwardProbeOperation value) noexcept {
  if(report.operationCount>=report.operations.size())
    return;
  report.operations[report.operationCount] = operation(value);
  ++report.operationCount;
  }

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

struct NativeEncodeContext final {
  MTL::Device* device = nullptr;
  MTL::Texture* output = nullptr;
  MTL::Buffer* lightList = nullptr;
  IOSShadingPrototypeForwardPipelineNativeView pipelines;
  IOSShadingPrototypeForwardProbeReportV1* report = nullptr;
  bool succeeded = false;
  };

void encodeForwardProbe(void* rawContext,
                        MTL::CommandBuffer* rawCommand) {
  auto& context = *static_cast<NativeEncodeContext*>(rawContext);
  if(rawCommand==nullptr || context.device==nullptr ||
     context.output==nullptr || context.lightList==nullptr ||
     context.report==nullptr ||
     context.pipelines.device!=context.device ||
     context.pipelines.buildLightList==nullptr ||
     context.pipelines.opaque==nullptr ||
     context.pipelines.alphaTest==nullptr)
    return;

  auto& report = *context.report;
  report.failureReason =
      reason(IOSShadingPrototypeForwardFailureReason::
                 EncodedContractMismatch);

  id<MTLCommandBuffer> command =
      reinterpret_cast<id<MTLCommandBuffer>>((void*)rawCommand);
  id<MTLDevice> device =
      reinterpret_cast<id<MTLDevice>>((void*)context.device);
  id<MTLTexture> output =
      reinterpret_cast<id<MTLTexture>>((void*)context.output);
  id<MTLBuffer> lightList =
      reinterpret_cast<id<MTLBuffer>>((void*)context.lightList);
  id<MTLComputePipelineState> buildLightList =
      reinterpret_cast<id<MTLComputePipelineState>>(
          (void*)context.pipelines.buildLightList);
  id<MTLRenderPipelineState> opaque =
      reinterpret_cast<id<MTLRenderPipelineState>>(
          (void*)context.pipelines.opaque);
  id<MTLRenderPipelineState> alphaTest =
      reinterpret_cast<id<MTLRenderPipelineState>>(
          (void*)context.pipelines.alphaTest);

  @autoreleasepool {
    @try {
      if(command==nil || device==nil || output==nil ||
         lightList==nil || buildLightList==nil ||
         opaque==nil || alphaTest==nil ||
         command.device!=device || output.device!=device ||
         lightList.device!=device ||
         buildLightList.device!=device ||
         opaque.device!=device || alphaTest.device!=device)
        return;

      command.label = @"RendererIOS Forward Prototype CB";
      report.borrowedInactiveCommandBuffer = 1u;
      report.commandBuffers = 1u;
      report.commandBufferRetainedReferencesDisabled =
          command.retainedReferences==NO ? 1u : 0u;
      if(report.commandBufferRetainedReferencesDisabled!=1u)
        return;

      report.computePipelineLabelMatches =
          exactString(buildLightList.label,ComputePipelineLabel)
              ? 1u : 0u;
      report.opaquePipelineLabelMatches =
          exactString(opaque.label,OpaquePipelineLabel) ? 1u : 0u;
      report.alphaTestPipelineLabelMatches =
          exactString(alphaTest.label,AlphaTestPipelineLabel)
              ? 1u : 0u;
      if(report.computePipelineLabelMatches!=1u ||
         report.opaquePipelineLabelMatches!=1u ||
         report.alphaTestPipelineLabelMatches!=1u)
        return;

      {
        ScopedNativeEncoder<id<MTLComputeCommandEncoder>>
            compute([command computeCommandEncoder]);
        if(!compute)
          return;
        compute.get().label =
            @"RendererIOS Forward Compute Encoder";
        report.computeEncoderLabelMatches =
            exactString(compute.get().label,ComputeEncoderLabel)
                ? 1u : 0u;
        if(report.computeEncoderLabelMatches!=1u)
          return;

        report.physicalPasses = 1u;
        report.computeEncoders = 1u;
        [compute.get() setComputePipelineState:buildLightList];
        report.computePipelineBinds = 1u;
        ++report.pipelineStates;
        [compute.get()
            setBuffer:lightList
              offset:static_cast<NSUInteger>(LightListOffset)
             atIndex:static_cast<NSUInteger>(
                         Shader::ForwardLightListBuffer)];
        report.computeBufferBindings = 1u;
        report.computeBufferIndex =
            Shader::ForwardLightListBuffer;
        report.computeBufferOffset = LightListOffset;
        [compute.get()
            dispatchThreads:
                MTLSizeMake(
                    static_cast<NSUInteger>(
                        Shader::ForwardLightListGridWidth),
                    static_cast<NSUInteger>(
                        Shader::ForwardLightListGridHeight),
                    static_cast<NSUInteger>(
                        Shader::ForwardLightListGridDepth))
            threadsPerThreadgroup:
                MTLSizeMake(
                    static_cast<NSUInteger>(
                        Shader::
                            ForwardLightListThreadsPerThreadgroupWidth),
                    static_cast<NSUInteger>(
                        Shader::
                            ForwardLightListThreadsPerThreadgroupHeight),
                    static_cast<NSUInteger>(
                        Shader::
                            ForwardLightListThreadsPerThreadgroupDepth))];
        report.dispatches = 1u;
        report.gridWidth = Shader::ForwardLightListGridWidth;
        report.gridHeight = Shader::ForwardLightListGridHeight;
        report.gridDepth = Shader::ForwardLightListGridDepth;
        report.threadsPerThreadgroupWidth =
            Shader::ForwardLightListThreadsPerThreadgroupWidth;
        report.threadsPerThreadgroupHeight =
            Shader::ForwardLightListThreadsPerThreadgroupHeight;
        report.threadsPerThreadgroupDepth =
            Shader::ForwardLightListThreadsPerThreadgroupDepth;
        appendOperation(
            report,
            IOSShadingPrototypeForwardProbeOperation::
                BuildLightList);

        if(!compute.endOnce())
          return;
        ++report.endEncodingCalls;
        report.computeEndedBeforeRender = 1u;
        }

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

      const MTLClearColor clear = color.clearColor;
      report.outputLoadClear =
          color.loadAction==MTLLoadActionClear ? 1u : 0u;
      report.outputStoreStore =
          color.storeAction==MTLStoreActionStore ? 1u : 0u;
      report.outputClearStore =
          report.outputLoadClear==1u &&
          report.outputStoreStore==1u ? 1u : 0u;
      report.transparentBlackClear =
          clear.red==0.0 && clear.green==0.0 &&
          clear.blue==0.0 && clear.alpha==0.0 ? 1u : 0u;
      report.outputAttachments =
          onlyOutputAttachment(descriptor.get(),output) ? 1u : 0u;
      report.outputAttachmentIndex = OutputAttachment;
      report.otherColorAttachments = 0u;
      report.depthAttachments =
          descriptor.get().depthAttachment.texture==nil ? 0u : 1u;
      report.stencilAttachments =
          descriptor.get().stencilAttachment.texture==nil ? 0u : 1u;
      report.sampleCountOne = output.sampleCount==NSUInteger(1u)
                                  ? 1u : 0u;
      if(report.outputClearStore!=1u ||
         report.transparentBlackClear!=1u ||
         report.outputAttachments!=1u ||
         report.depthAttachments!=0u ||
         report.stencilAttachments!=0u ||
         report.sampleCountOne!=1u)
        return;

      {
        ScopedNativeEncoder<id<MTLRenderCommandEncoder>>
            render([command
                renderCommandEncoderWithDescriptor:
                    descriptor.get()]);
        if(!render)
          return;
        render.get().label =
            @"RendererIOS Forward Render Encoder";
        report.renderEncoderLabelMatches =
            exactString(render.get().label,RenderEncoderLabel)
                ? 1u : 0u;
        if(report.renderEncoderLabelMatches!=1u)
          return;

        report.physicalPasses = 2u;
        report.renderEncoders = 1u;
        [render.get()
            setVertexBytes:Vertices.data()
                    length:sizeof(Vertices)
                   atIndex:static_cast<NSUInteger>(
                               PipelineContract::
                                   VertexBufferIndex)];
        report.vertexByteBindings = 1u;
        report.vertexBufferIndex =
            PipelineContract::VertexBufferIndex;
        report.vertices = VertexCount;
        report.vertexBytes = VertexBytes;
        report.vertexStride = VertexStride;
        report.primitiveTriangle = 1u;

        [render.get()
            setFragmentBuffer:lightList
                       offset:static_cast<NSUInteger>(
                                  LightListOffset)
                      atIndex:static_cast<NSUInteger>(
                                  Shader::
                                      ForwardLightListBuffer)];
        report.fragmentBufferBindings = 1u;
        report.fragmentBufferIndex =
            Shader::ForwardLightListBuffer;
        report.fragmentBufferOffset = LightListOffset;

        [render.get() setRenderPipelineState:opaque];
        report.opaquePipelineBinds = 1u;
        ++report.pipelineStates;
        [render.get()
            drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:static_cast<NSUInteger>(
                                OpaqueVertexStart)
                vertexCount:static_cast<NSUInteger>(
                                TriangleVertexCount)];
        ++report.draws;
        ++report.opaqueDraws;
        report.opaqueVertexStart = OpaqueVertexStart;
        report.opaqueVertexCount = TriangleVertexCount;
        appendOperation(
            report,
            IOSShadingPrototypeForwardProbeOperation::DrawOpaque);

        [render.get() setRenderPipelineState:alphaTest];
        report.alphaTestPipelineBinds = 1u;
        ++report.pipelineStates;
        [render.get()
            drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:static_cast<NSUInteger>(
                                AlphaTestVertexStart)
                vertexCount:static_cast<NSUInteger>(
                                TriangleVertexCount)];
        ++report.draws;
        ++report.alphaTestDraws;
        report.alphaTestVertexStart = AlphaTestVertexStart;
        report.alphaTestVertexCount = TriangleVertexCount;
        appendOperation(
            report,
            IOSShadingPrototypeForwardProbeOperation::
                DrawAlphaTest);

        if(!render.endOnce())
          return;
        ++report.endEncodingCalls;
        report.renderEnded = 1u;
        }

      report.encoded = 1u;
      report.flags =
          ProbeFlagInputsValid |
          ProbeFlagOutputContractValid |
          ProbeFlagLightListContractValid |
          ProbeFlagEncoded |
          ProbeFlagExactSequence |
          ProbeFlagExactGeometry |
          ProbeFlagExactLabels |
          ProbeFlagNoForbiddenSideEffects;
      report.failureReason =
          reason(IOSShadingPrototypeForwardFailureReason::None);
      context.succeeded =
          iosValidateShadingPrototypeForwardProbeReportV1(report);
      }
    @catch(NSException*) {
      context.succeeded = false;
      }
    }
  }

}

struct IOSShadingPrototypeForwardLightList::Impl final {
  explicit Impl(id<MTLBuffer> buffer) noexcept
    : buffer(buffer) {
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
    LightListLifetime.created.fetch_add(
        1u,std::memory_order_relaxed);
    LightListLifetime.live.fetch_add(
        1u,std::memory_order_relaxed);
#endif
    }

  ~Impl() {
    [buffer release];
#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
    LightListLifetime.live.fetch_sub(
        1u,std::memory_order_relaxed);
    LightListLifetime.released.fetch_add(
        1u,std::memory_order_relaxed);
#endif
    }

  Impl(const Impl&) = delete;
  Impl& operator=(const Impl&) = delete;

  id<MTLBuffer> buffer = nil;
  };

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
IOSShadingPrototypeForwardLightListLifetimeSnapshot
    iosShadingPrototypeForwardLightListLifetimeSnapshot() noexcept {
  IOSShadingPrototypeForwardLightListLifetimeSnapshot snapshot;
  snapshot.created =
      LightListLifetime.created.load(std::memory_order_relaxed);
  snapshot.live =
      LightListLifetime.live.load(std::memory_order_relaxed);
  snapshot.released =
      LightListLifetime.released.load(std::memory_order_relaxed);
  return snapshot;
  }
#endif

MTL::Buffer* IOSShadingPrototypeForwardLightListNativeAccess::borrow(
    const IOSShadingPrototypeForwardLightList& lightList) noexcept {
  if(lightList.impl==nullptr || lightList.impl->buffer==nil)
    return nullptr;
  return reinterpret_cast<MTL::Buffer*>(
      (void*)lightList.impl->buffer);
  }

IOSShadingPrototypeForwardLightList::
    IOSShadingPrototypeForwardLightList() noexcept = default;
IOSShadingPrototypeForwardLightList::
    ~IOSShadingPrototypeForwardLightList() = default;
IOSShadingPrototypeForwardLightList::
    IOSShadingPrototypeForwardLightList(
        IOSShadingPrototypeForwardLightList&& other) noexcept
  : lightListReport(other.lightListReport),
    impl(std::move(other.impl)) {
  other.lightListReport = {};
  }

IOSShadingPrototypeForwardLightList&
    IOSShadingPrototypeForwardLightList::operator=(
        IOSShadingPrototypeForwardLightList&& other) noexcept {
  if(this==&other)
    return *this;
  lightListReport = other.lightListReport;
  impl = std::move(other.impl);
  other.lightListReport = {};
  return *this;
  }

IOSShadingPrototypeForwardLightList::
    IOSShadingPrototypeForwardLightList(
        IOSShadingPrototypeForwardLightListReportV1 report,
        std::unique_ptr<Impl>&& impl) noexcept
  : lightListReport(report),
    impl(std::move(impl)) {
  }

IOSShadingPrototypeForwardLightList::operator bool() const noexcept {
  return impl!=nullptr &&
         iosValidateShadingPrototypeForwardLightListReportV1(
             lightListReport);
  }

const IOSShadingPrototypeForwardLightListReportV1&
    IOSShadingPrototypeForwardLightList::report() const noexcept {
  return lightListReport;
  }

IOSShadingPrototypeForwardLightList
    iosCreateShadingPrototypeForwardLightList(
        Tempest::Device& owner) noexcept {
  using namespace RendererIOSShadingPrototypeForwardProbe;
  namespace Shader = RendererIOSShadingPrototypeShader;
  using LightList = IOSShadingPrototypeForwardLightList;

  IOSShadingPrototypeForwardLightListReportV1 report;
  report.abiVersion = ABIVersion;
  report.structSize = static_cast<uint32_t>(sizeof(report));
  report.failureReason =
      reason(IOSShadingPrototypeForwardFailureReason::
                 LightListAllocationOrContractMismatch);
  report.byteSize = Shader::ForwardLightListByteSize;
  report.wordBytes = Shader::ForwardLightListWordBytes;
  report.wordCount = Shader::ForwardLightListWordCount;
  report.requestedStorageMode = StorageModeShared;
  report.requestedHazardTrackingMode =
      HazardTrackingModeTracked;
  report.bindingOffset = LightListOffset;
  report.sentinelValue = Shader::ForwardLightListSentinel;

  @try {
    try {
      @autoreleasepool {
        const Tempest::BorrowedMetalDevice borrowed =
            Tempest::MetalApi::borrowDevice(owner);
        if(!borrowed) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         SnapshotUnavailable);
          return LightList(report,{});
          }
        id<MTLDevice> device =
            reinterpret_cast<id<MTLDevice>>(
                (void*)borrowed.get());
        if(device==nil) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         SnapshotUnavailable);
          return LightList(report,{});
          }

        const MTLResourceOptions options =
            MTLResourceStorageModeShared |
            MTLResourceHazardTrackingModeTracked;
        OwnedObjectiveC<id<MTLBuffer>> buffer(
            [device
                newBufferWithLength:static_cast<NSUInteger>(
                                        Shader::
                                            ForwardLightListByteSize)
                            options:options]);
        if(buffer.get()==nil)
          return LightList(report,{});
        report.ownerCreatedDelta = 1u;
        report.ownerLiveDelta = 1u;

        buffer.get().label =
            @"RendererIOS Forward LightList 256B";
        report.observedByteSize =
            static_cast<uint32_t>(buffer.get().length);
        report.observedStorageMode =
            buffer.get().storageMode==MTLStorageModeShared
                ? StorageModeShared : 0u;
        report.observedHazardTrackingMode =
            buffer.get().hazardTrackingMode==
                    MTLHazardTrackingModeTracked
                ? HazardTrackingModeTracked : 0u;
        report.sameDevice =
            buffer.get().device==device ? 1u : 0u;
        report.contentsAvailable =
            buffer.get().contents!=nullptr ? 1u : 0u;
        if(report.observedHazardTrackingMode!=
               HazardTrackingModeTracked) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         HazardModeUntracked);
          return LightList(report,{});
          }
        if(report.observedByteSize!=
               Shader::ForwardLightListByteSize ||
           report.observedStorageMode!=StorageModeShared ||
           report.sameDevice!=1u ||
           report.contentsAvailable!=1u ||
           !exactString(buffer.get().label,
                        LightListBufferLabel))
          return LightList(report,{});

        report.prefillAttempted = 1u;
        auto* words =
            static_cast<uint32_t*>(buffer.get().contents);
        std::fill_n(
            words,
            static_cast<std::size_t>(
                Shader::ForwardLightListWordCount),
            Shader::ForwardLightListSentinel);
        report.prefilledWords =
            Shader::ForwardLightListWordCount;
        for(std::size_t index=0u;
            index<
                static_cast<std::size_t>(
                    Shader::ForwardLightListWordCount);
            ++index) {
          if(words[index]==Shader::ForwardLightListSentinel) {
            ++report.prefillVerifiedWords;
            ++report.sentinelWords;
            }
          else {
            ++report.unexpectedWords;
            }
          }
        if(report.prefillVerifiedWords!=
               Shader::ForwardLightListWordCount ||
           report.sentinelWords!=
               Shader::ForwardLightListWordCount ||
           report.unexpectedWords!=0u) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         SentinelPrefillMismatch);
          return LightList(report,{});
          }

        std::unique_ptr<LightList::Impl> impl(
            new(std::nothrow)
                LightList::Impl(buffer.relinquish()));
        if(impl==nullptr)
          return LightList(report,{});

        report.flags = LightListKnownFlagsMask;
        report.failureReason =
            reason(IOSShadingPrototypeForwardFailureReason::None);
        if(!iosValidateShadingPrototypeForwardLightListReportV1(
               report)) {
          report.flags = 0u;
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         LightListAllocationOrContractMismatch);
          return LightList(report,{});
          }
        return LightList(report,std::move(impl));
        }
      }
    catch(...) {
      return LightList(report,{});
      }
    }
  @catch(NSException*) {
    return LightList(report,{});
    }
  }

bool iosReadShadingPrototypeForwardLightListContents(
    const IOSShadingPrototypeForwardLightList& lightList,
    std::array<
        uint32_t,
        RendererIOSShadingPrototypeShader::ForwardLightListWordCount>&
        words) noexcept {
  words.fill(RendererIOSShadingPrototypeShader::
                 ForwardLightListSentinel);
  if(!lightList)
    return false;
  @try {
    id<MTLBuffer> buffer =
        lightList.impl!=nullptr
            ? lightList.impl->buffer : nil;
    if(buffer==nil ||
       buffer.length!=
           static_cast<NSUInteger>(
               RendererIOSShadingPrototypeShader::
                   ForwardLightListByteSize) ||
       buffer.storageMode!=MTLStorageModeShared ||
       buffer.hazardTrackingMode!=
           MTLHazardTrackingModeTracked ||
       buffer.contents==nullptr)
      return false;
    std::memcpy(
        words.data(),buffer.contents,
        static_cast<std::size_t>(
            RendererIOSShadingPrototypeShader::
                ForwardLightListByteSize));
    return true;
    }
  @catch(NSException*) {
    words.fill(RendererIOSShadingPrototypeShader::
                   ForwardLightListSentinel);
    return false;
    }
  }

bool iosEncodeShadingPrototypeForwardProbe(
    Tempest::Device& device,
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSShadingPrototypeForwardPipeline& pipeline,
    const IOSMetalResourceTexture& output,
    const IOSShadingPrototypeForwardLightList& lightList,
    IOSShadingPrototypeForwardProbeReportV1& report) noexcept {
  using namespace RendererIOSShadingPrototypeForwardProbe;

  report = {};
  report.abiVersion = ABIVersion;
  report.structSize = static_cast<uint32_t>(sizeof(report));
  report.failureReason =
      reason(IOSShadingPrototypeForwardFailureReason::
                 FactoryContractMismatch);

  @try {
    try {
      @autoreleasepool {
        if(!pipeline ||
           pipeline.status()!=
               IOSShadingPrototypeForwardPipelineStatus::Ready)
          return false;
        report.pipelineReady = 1u;
        report.factoryReady = 1u;
        report.supportsApple4 =
            pipeline.report().supportsApple4 ? 1u : 0u;
        if(report.supportsApple4!=1u) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         UnsupportedAppleFamily);
          return false;
          }

        const auto& factoryReport = pipeline.report();
        const auto canonicalFactoryReport =
            iosCanonicalShadingPrototypeForwardPipelineReport();
        report.actualReflectionAvailable =
            factoryReport.computePipeline.reflectionAvailable &&
            factoryReport.renderPipelines[0].
                reflectionAvailable &&
            factoryReport.renderPipelines[1].
                reflectionAvailable ? 1u : 0u;
        report.computeBindingExact =
            factoryReport.computePipeline.computeBindings==
                canonicalFactoryReport.computePipeline.
                    computeBindings ? 1u : 0u;
        report.vertexBindingExact =
            factoryReport.renderPipelines[0].vertexBindings==
                canonicalFactoryReport.renderPipelines[0].
                    vertexBindings &&
            factoryReport.renderPipelines[1].vertexBindings==
                canonicalFactoryReport.renderPipelines[1].
                    vertexBindings ? 1u : 0u;
        report.fragmentBindingExact =
            factoryReport.renderPipelines[0].fragmentBindings==
                canonicalFactoryReport.renderPipelines[0].
                    fragmentBindings &&
            factoryReport.renderPipelines[1].fragmentBindings==
                canonicalFactoryReport.renderPipelines[1].
                    fragmentBindings ? 1u : 0u;
        if(report.actualReflectionAvailable!=1u ||
           report.computeBindingExact!=1u ||
           report.vertexBindingExact!=1u ||
           report.fragmentBindingExact!=1u) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         FactoryReflectionMismatch);
          return false;
          }

        IOSShadingPrototypeForwardPipelineNativeView pipelines;
        if(!IOSShadingPrototypeForwardPipelineNativeAccess::borrow(
               pipeline,pipelines))
          return false;

        const Tempest::BorrowedMetalDevice borrowed =
            Tempest::MetalApi::borrowDevice(device);
        report.borrowedExistingDevice =
            borrowed ? 1u : 0u;
        if(!borrowed) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         SnapshotUnavailable);
          return false;
          }
        MTL::Device* nativeDevice = borrowed.get();
        report.pipelineSameDevice =
            pipelines.device==nativeDevice ? 1u : 0u;
        report.sameDeviceAllPipelines =
            report.pipelineSameDevice;
        if(report.pipelineSameDevice!=1u)
          return false;

        const IOSMetalTextureSnapshot outputSnapshot =
            output.snapshot();
        report.outputAvailable =
            outputSnapshot.available ? 1u : 0u;
        report.outputSameDevice =
            outputSnapshot.deviceIdentity==
                reinterpret_cast<uintptr_t>(
                    (void*)nativeDevice) ? 1u : 0u;
        report.outputType2D =
            outputSnapshot.type==IOSMetalTextureType::Type2D
                ? 1u : 0u;
        report.outputRgba8Unorm =
            outputSnapshot.format==IOSPixelFormat::Rgba8Unorm
                ? 1u : 0u;
        report.outputPrivate =
            outputSnapshot.storage==
                IOSMetalResourceStorage::Private ? 1u : 0u;
        report.outputWidth = outputSnapshot.extent.width;
        report.outputHeight = outputSnapshot.extent.height;
        report.outputMipLevels = outputSnapshot.mipLevels;
        report.outputSampleCount = outputSnapshot.sampleCount;
        report.outputExtentMatches =
            report.outputWidth==OutputWidth &&
            report.outputHeight==OutputHeight &&
            report.outputMipLevels==OutputMipLevels &&
            report.outputSampleCount==OutputSampleCount &&
            outputSnapshot.depth==1u &&
            outputSnapshot.arrayLength==1u &&
            outputSnapshot.usageExactlyRepresented &&
            outputSnapshot.usage==
                IOSResourceUsage::RenderAttachment ? 1u : 0u;
        if(report.outputAvailable!=1u ||
           report.outputSameDevice!=1u ||
           report.outputType2D!=1u ||
           report.outputRgba8Unorm!=1u ||
           report.outputPrivate!=1u ||
           report.outputExtentMatches!=1u) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         OutputAllocationOrLifetimeMismatch);
          return false;
          }

        const auto& lightListReport = lightList.report();
        report.lightListAvailable = lightList ? 1u : 0u;
        report.lightListSameDevice = 0u;
        report.lightListShared =
            lightListReport.observedStorageMode==
                    StorageModeShared ? 1u : 0u;
        report.lightListTracked =
            lightListReport.observedHazardTrackingMode==
                    HazardTrackingModeTracked ? 1u : 0u;
        report.lightListByteSize =
            lightListReport.observedByteSize;
        report.lightListOffset =
            lightListReport.bindingOffset;
        if(report.lightListAvailable!=1u ||
           report.lightListShared!=1u ||
           report.lightListTracked!=1u ||
           report.lightListByteSize!=
               Shader::ForwardLightListByteSize ||
           report.lightListOffset!=LightListOffset ||
           !iosValidateShadingPrototypeForwardLightListReportV1(
               lightListReport)) {
          report.failureReason =
              reason(IOSShadingPrototypeForwardFailureReason::
                         LightListAllocationOrContractMismatch);
          return false;
          }
        MTL::Texture* nativeOutput =
            IOSMetalResourceTextureNativeAccess::borrow(output);
        MTL::Buffer* nativeLightList =
            IOSShadingPrototypeForwardLightListNativeAccess::
                borrow(lightList);
        if(nativeOutput==nullptr || nativeLightList==nullptr)
          return false;
        id<MTLBuffer> actualLightList =
            reinterpret_cast<id<MTLBuffer>>((void*)nativeLightList);
        report.lightListSameDevice =
            actualLightList!=nil &&
            actualLightList.device==
                reinterpret_cast<id<MTLDevice>>(
                    (void*)nativeDevice) ? 1u : 0u;
        report.sameDeviceAllResources =
            report.outputSameDevice==1u &&
            report.lightListSameDevice==1u ? 1u : 0u;
        if(report.sameDeviceAllResources!=1u)
          return false;

        NativeEncodeContext context;
        context.device = nativeDevice;
        context.output = nativeOutput;
        context.lightList = nativeLightList;
        context.pipelines = pipelines;
        context.report = &report;
        report.withActiveCommandBufferCalls = 1u;
        report.failureReason =
            reason(IOSShadingPrototypeForwardFailureReason::
                       NativeEncodeRejected);
        const bool bridgeAccepted =
            Tempest::MetalApi::withActiveCommandBuffer(
                device,encoder,&context,encodeForwardProbe);
        if(!bridgeAccepted || !context.succeeded ||
           !iosValidateShadingPrototypeForwardProbeReportV1(
               report)) {
          if(report.failureReason==
                 reason(IOSShadingPrototypeForwardFailureReason::
                            None)) {
            report.flags = 0u;
            report.failureReason =
                reason(IOSShadingPrototypeForwardFailureReason::
                           NativeEncodeRejected);
            }
          return false;
          }
        return true;
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
