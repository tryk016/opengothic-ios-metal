#include "iosshadingprototypeforwardpipeline.h"
#include "iosshadingprototypeforwardpipelinenative.h"

#include "ioslandscapeshaderabi.h"
#include "iosshadingprototypeshaderabi.h"

#include <Tempest/Device>
#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <string_view>
#include <utility>

#if __has_feature(objc_arc)
#error "IOSShadingPrototypeForwardPipeline requires the project's non-ARC Objective-C++ mode"
#endif

namespace {

using namespace RendererIOSShadingPrototypeForwardPipeline;

static_assert(RendererIOSShader::AbiVersion==OfflineMetallibAbi);
static_assert(
    RendererIOSShadingPrototypeShader::AlphaTestFunctionConstant==
    AlphaTestFunctionConstant);
static_assert(
    RendererIOSShadingPrototypeShader::PositionAttribute==
    PositionAttribute);
static_assert(
    RendererIOSShadingPrototypeShader::ColorAttribute==
    ColorAttribute);
static_assert(
    RendererIOSShadingPrototypeShader::ForwardLightListBuffer==
    LightListBufferIndex);
static_assert(
    RendererIOSShadingPrototypeShader::TileFinalColorAttachment==
    FinalColorAttachment);
static_assert(
    RendererIOSShadingPrototypeShader::TotalMetallibExportCount==16u);

class OwnedObjectiveC final {
  public:
    explicit OwnedObjectiveC(id value = nil) noexcept
      : value(value) {
      }

    ~OwnedObjectiveC() {
      [value release];
      }

    OwnedObjectiveC(const OwnedObjectiveC&) = delete;
    OwnedObjectiveC& operator=(const OwnedObjectiveC&) = delete;

    id get() const noexcept {
      return value;
      }

    void reset(id replacement = nil) {
      if(value==replacement)
        return;
      [value release];
      value = replacement;
      }

    id relinquish() noexcept {
      const id result = value;
      value = nil;
      return result;
      }

  private:
    id value = nil;
  };

enum class BindingStage : uint8_t {
  Compute,
  Vertex,
  Fragment,
  Tile,
  Object,
  Mesh,
  };

uint32_t narrow(NSUInteger value) noexcept {
  constexpr uint32_t Invalid = std::numeric_limits<uint32_t>::max();
  if(value>static_cast<NSUInteger>(Invalid))
    return Invalid;
  return static_cast<uint32_t>(value);
  }

bool emptyCollection(id value) noexcept {
  return value==nil || [value count]==NSUInteger(0u);
  }

bool linkedFunctionsEmpty(MTLLinkedFunctions* linkedFunctions) noexcept {
  return linkedFunctions==nil ||
         (emptyCollection(linkedFunctions.functions) &&
          emptyCollection(linkedFunctions.binaryFunctions) &&
          emptyCollection(linkedFunctions.groups) &&
          emptyCollection(linkedFunctions.privateFunctions));
  }

bool sameStageInputLayout(
    MTLBufferLayoutDescriptor* actual,
    MTLBufferLayoutDescriptor* expected) noexcept {
  if(actual==nil || expected==nil)
    return actual==expected;
  return actual.stride==expected.stride &&
         actual.stepFunction==expected.stepFunction &&
         actual.stepRate==expected.stepRate;
  }

bool sameStageInputAttribute(
    MTLAttributeDescriptor* actual,
    MTLAttributeDescriptor* expected) noexcept {
  if(actual==nil || expected==nil)
    return actual==expected;
  return actual.format==expected.format &&
         actual.offset==expected.offset &&
         actual.bufferIndex==expected.bufferIndex;
  }

bool stageInputDescriptorEmpty(
    MTLStageInputOutputDescriptor* descriptor) noexcept {
  if(descriptor==nil)
    return true;

  MTLStageInputOutputDescriptor* defaults =
      [MTLStageInputOutputDescriptor stageInputOutputDescriptor];
  if(defaults==nil)
    return false;
  [defaults reset];
  if(descriptor.indexType!=defaults.indexType ||
     descriptor.indexBufferIndex!=defaults.indexBufferIndex)
    return false;

  // Metal exposes 31 stage buffer/attribute slots (indices 0...30).
  constexpr NSUInteger StageInputSlotCount = NSUInteger(31u);
  for(NSUInteger i=0u; i<StageInputSlotCount; ++i) {
    if(!sameStageInputLayout(
           descriptor.layouts[i],defaults.layouts[i]) ||
       !sameStageInputAttribute(
           descriptor.attributes[i],defaults.attributes[i]))
      return false;
    }
  return true;
  }

OwnedObjectiveC makeString(std::string_view value) {
  return OwnedObjectiveC(
      [[NSString alloc]
          initWithBytes:value.data()
                 length:value.size()
               encoding:NSUTF8StringEncoding]);
  }

IOSShadingPrototypeForwardFunctionStage neutralStage(
    MTLFunctionType stage) noexcept {
  switch(stage) {
    case MTLFunctionTypeVertex:
      return IOSShadingPrototypeForwardFunctionStage::Vertex;
    case MTLFunctionTypeFragment:
      return IOSShadingPrototypeForwardFunctionStage::Fragment;
    case MTLFunctionTypeKernel:
      return IOSShadingPrototypeForwardFunctionStage::Kernel;
    default:
      return IOSShadingPrototypeForwardFunctionStage::Unknown;
    }
  }

IOSShadingPrototypeForwardBindingNativeType neutralBindingType(
    MTLBindingType type) noexcept {
  return type==MTLBindingTypeBuffer
      ? IOSShadingPrototypeForwardBindingNativeType::Buffer
      : IOSShadingPrototypeForwardBindingNativeType::Unknown;
  }

IOSShadingPrototypeForwardBindingAccess neutralBindingAccess(
    MTLBindingAccess access) noexcept {
  switch(access) {
    case MTLBindingAccessReadOnly:
      return IOSShadingPrototypeForwardBindingAccess::ReadOnly;
    case MTLBindingAccessReadWrite:
      return IOSShadingPrototypeForwardBindingAccess::ReadWrite;
    case MTLBindingAccessWriteOnly:
      return IOSShadingPrototypeForwardBindingAccess::WriteOnly;
    }
  return IOSShadingPrototypeForwardBindingAccess::Unknown;
  }

IOSShadingPrototypeForwardBindingSemantic neutralBindingSemantic(
    BindingStage stage,
    MTLBindingType type,
    NSUInteger index) noexcept {
  if(type!=MTLBindingTypeBuffer)
    return IOSShadingPrototypeForwardBindingSemantic::Unknown;
  if(stage==BindingStage::Vertex &&
     index==static_cast<NSUInteger>(VertexBufferIndex))
    return IOSShadingPrototypeForwardBindingSemantic::VertexBuffer;
  if((stage==BindingStage::Compute ||
      stage==BindingStage::Fragment) &&
     index==static_cast<NSUInteger>(LightListBufferIndex))
    return IOSShadingPrototypeForwardBindingSemantic::LightListBuffer;
  return IOSShadingPrototypeForwardBindingSemantic::Unknown;
  }

IOSShadingPrototypeForwardFunctionStage neutralBindingStage(
    BindingStage stage) noexcept {
  switch(stage) {
    case BindingStage::Compute:
      return IOSShadingPrototypeForwardFunctionStage::Kernel;
    case BindingStage::Vertex:
      return IOSShadingPrototypeForwardFunctionStage::Vertex;
    case BindingStage::Fragment:
      return IOSShadingPrototypeForwardFunctionStage::Fragment;
    case BindingStage::Tile:
    case BindingStage::Object:
    case BindingStage::Mesh:
      return IOSShadingPrototypeForwardFunctionStage::Unknown;
    }
  return IOSShadingPrototypeForwardFunctionStage::Unknown;
  }

IOSShadingPrototypeForwardBindingListReport normalizeBindings(
    NSArray<id<MTLBinding>>* bindings,
    BindingStage stage) {
  IOSShadingPrototypeForwardBindingListReport report;
  report.available = bindings!=nil;
  if(bindings==nil)
    return report;

  NSUInteger bindingCount = 0u;
  for(NSUInteger i=0u; i<bindings.count; ++i) {
    id<MTLBinding> binding = [bindings objectAtIndex:i];
    if(binding==nil)
      continue;
    if(bindingCount<
       static_cast<NSUInteger>(report.bindings.size())) {
      auto& normalized =
          report.bindings[static_cast<std::size_t>(bindingCount)];
      normalized.stage = neutralBindingStage(stage);
      normalized.semantic =
          neutralBindingSemantic(stage,binding.type,binding.index);
      normalized.nativeType = neutralBindingType(binding.type);
      normalized.access = neutralBindingAccess(binding.access);
      normalized.used = binding.isUsed==YES;
      normalized.index = narrow(binding.index);
      }
    else {
      report.overflow = true;
      }
    if(bindingCount==std::numeric_limits<NSUInteger>::max()) {
      report.overflow = true;
      }
    else {
      ++bindingCount;
      }
    }
  report.count = narrow(bindingCount);
  report.overflow =
      report.overflow ||
      bindingCount>
          static_cast<NSUInteger>(report.bindings.size());
  return report;
  }

IOSShadingPrototypeForwardFunctionReport normalizeFunction(
    id<MTLFunction> function,
    NSString* expectedName,
    NSString* alphaConstantName,
    id<MTLDevice> expectedDevice) {
  IOSShadingPrototypeForwardFunctionReport report;
  if(function==nil)
    return report;
  report.available = true;
  report.nameMatches =
      expectedName!=nil &&
      [function.name isEqualToString:expectedName];
  report.sameDevice = function.device==expectedDevice;
  report.stage = neutralStage(function.functionType);

  NSDictionary<NSString*,MTLFunctionConstant*>* constants =
      function.functionConstantsDictionary;
  report.functionConstantCount =
      constants!=nil ? narrow(constants.count) : 0u;
  MTLFunctionConstant* constant =
      alphaConstantName!=nil
          ? [constants objectForKey:alphaConstantName]
          : nil;
  if(constant!=nil) {
    report.alphaTest.available = true;
    report.alphaTest.nameMatches =
        [constant.name isEqualToString:alphaConstantName];
    report.alphaTest.indexMatches =
        constant.index==
        static_cast<NSUInteger>(AlphaTestFunctionConstant);
    report.alphaTest.boolType = constant.type==MTLDataTypeBool;
    report.alphaTest.required = constant.required==YES;
    }
  return report;
  }

IOSShadingPrototypeForwardSpecializationReport normalizeSpecialization(
    id<MTLFunction> function,
    NSString* expectedName,
    id<MTLDevice> expectedDevice,
    bool alphaTestEnabled) {
  IOSShadingPrototypeForwardSpecializationReport report;
  if(function==nil)
    return report;
  report.available = true;
  report.nameMatches =
      expectedName!=nil &&
      [function.name isEqualToString:expectedName];
  report.sameDevice = function.device==expectedDevice;
  report.stage = neutralStage(function.functionType);
  report.alphaTestEnabled = alphaTestEnabled;
  return report;
  }

bool vertexDescriptorMatches(
    MTLVertexDescriptor* descriptor) {
  if(descriptor==nil)
    return false;
  return descriptor.attributes[PositionAttribute].format==
             MTLVertexFormatFloat3 &&
         descriptor.attributes[PositionAttribute].offset==
             static_cast<NSUInteger>(PositionOffset) &&
         descriptor.attributes[PositionAttribute].bufferIndex==
             static_cast<NSUInteger>(VertexBufferIndex) &&
         descriptor.attributes[ColorAttribute].format==
             MTLVertexFormatFloat4 &&
         descriptor.attributes[ColorAttribute].offset==
             static_cast<NSUInteger>(ColorOffset) &&
         descriptor.attributes[ColorAttribute].bufferIndex==
             static_cast<NSUInteger>(VertexBufferIndex) &&
         descriptor.layouts[VertexBufferIndex].stride==
             static_cast<NSUInteger>(VertexStride) &&
         descriptor.layouts[VertexBufferIndex].stepFunction==
             MTLVertexStepFunctionPerVertex &&
         descriptor.layouts[VertexBufferIndex].stepRate==
             NSUInteger(1u);
  }

bool unusedColorAttachmentsInvalid(
    MTLRenderPipelineDescriptor* descriptor) {
  if(descriptor==nil)
    return false;
  for(NSUInteger i=1u;
      i<static_cast<NSUInteger>(ColorAttachmentCount); ++i) {
    if(descriptor.colorAttachments[i].pixelFormat!=
       MTLPixelFormatInvalid)
      return false;
    }
  return true;
  }

enum class NativePipelineBuild : uint8_t {
  Ready,
  CreationFailed,
  ReflectionFailed,
  };

NativePipelineBuild buildComputePipeline(
    id<MTLDevice> device,
    id<MTLFunction> function,
    IOSShadingPrototypeForwardComputePipelineReport& report,
    OwnedObjectiveC& pipelineOwner) {
  OwnedObjectiveC descriptorOwner(
      [[MTLComputePipelineDescriptor alloc] init]);
  MTLComputePipelineDescriptor* descriptor =
      (MTLComputePipelineDescriptor*)descriptorOwner.get();
  if(descriptor==nil)
    return NativePipelineBuild::CreationFailed;
  descriptor.computeFunction = function;
  descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = NO;
  descriptor.maxTotalThreadsPerThreadgroup = NSUInteger(0u);
  descriptor.stageInputDescriptor = nil;
  descriptor.supportIndirectCommandBuffers = NO;
  descriptor.binaryArchives = nil;
  descriptor.linkedFunctions = nil;
  descriptor.supportAddingBinaryFunctions = NO;
  descriptor.maxCallStackDepth = NSUInteger(1u);
  descriptor.label =
      @"RendererIOS Forward BuildLightList";

  report.binaryArchivesNil = descriptor.binaryArchives==nil;
  report.functionMatches = descriptor.computeFunction==function;
  report.threadGroupSizeMultipleDisabled =
      descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth==NO;
  report.maxTotalThreadsPerThreadgroupZero =
      descriptor.maxTotalThreadsPerThreadgroup==NSUInteger(0u);
  report.stageInputDescriptorEmpty =
      stageInputDescriptorEmpty(descriptor.stageInputDescriptor);
  report.indirectCommandBuffersDisabled =
      descriptor.supportIndirectCommandBuffers==NO;
  report.linkedFunctionsEmpty =
      linkedFunctionsEmpty(descriptor.linkedFunctions);
  report.addingBinaryFunctionsDisabled =
      descriptor.supportAddingBinaryFunctions==NO;
  report.maxCallStackDepth = narrow(descriptor.maxCallStackDepth);

  NSError* error = nil;
  MTLAutoreleasedComputePipelineReflection reflection = nil;
  id<MTLComputePipelineState> pipeline =
      [device newComputePipelineStateWithDescriptor:descriptor
                                            options:
                                                MTLPipelineOptionBindingInfo
                                         reflection:&reflection
                                              error:&error];
  pipelineOwner.reset(pipeline);
  report.available = pipeline!=nil;
  if(pipeline==nil || error!=nil)
    return NativePipelineBuild::CreationFailed;
  report.sameDevice = pipeline.device==device;
  report.reflectionAvailable = reflection!=nil;
  if(reflection==nil)
    return NativePipelineBuild::ReflectionFailed;
  report.computeBindings =
      normalizeBindings(reflection.bindings,BindingStage::Compute);
  return NativePipelineBuild::Ready;
  }

NativePipelineBuild buildRenderPipeline(
    id<MTLDevice> device,
    id<MTLFunction> vertexFunction,
    id<MTLFunction> fragmentFunction,
    bool alphaTestEnabled,
    IOSShadingPrototypeForwardRenderPipelineReport& report,
    OwnedObjectiveC& pipelineOwner) {
  OwnedObjectiveC vertexDescriptorOwner(
      [[MTLVertexDescriptor alloc] init]);
  MTLVertexDescriptor* vertexDescriptor =
      (MTLVertexDescriptor*)vertexDescriptorOwner.get();
  if(vertexDescriptor==nil)
    return NativePipelineBuild::CreationFailed;
  vertexDescriptor.attributes[PositionAttribute].format =
      MTLVertexFormatFloat3;
  vertexDescriptor.attributes[PositionAttribute].offset =
      static_cast<NSUInteger>(PositionOffset);
  vertexDescriptor.attributes[PositionAttribute].bufferIndex =
      static_cast<NSUInteger>(VertexBufferIndex);
  vertexDescriptor.attributes[ColorAttribute].format =
      MTLVertexFormatFloat4;
  vertexDescriptor.attributes[ColorAttribute].offset =
      static_cast<NSUInteger>(ColorOffset);
  vertexDescriptor.attributes[ColorAttribute].bufferIndex =
      static_cast<NSUInteger>(VertexBufferIndex);
  vertexDescriptor.layouts[VertexBufferIndex].stride =
      static_cast<NSUInteger>(VertexStride);
  vertexDescriptor.layouts[VertexBufferIndex].stepFunction =
      MTLVertexStepFunctionPerVertex;
  vertexDescriptor.layouts[VertexBufferIndex].stepRate = NSUInteger(1u);

  OwnedObjectiveC descriptorOwner(
      [[MTLRenderPipelineDescriptor alloc] init]);
  MTLRenderPipelineDescriptor* descriptor =
      (MTLRenderPipelineDescriptor*)descriptorOwner.get();
  if(descriptor==nil)
    return NativePipelineBuild::CreationFailed;
  descriptor.vertexFunction = vertexFunction;
  descriptor.fragmentFunction = fragmentFunction;
  descriptor.vertexDescriptor = vertexDescriptor;
  descriptor.colorAttachments[FinalColorAttachment].pixelFormat =
      MTLPixelFormatRGBA8Unorm;
  descriptor.colorAttachments[FinalColorAttachment].writeMask =
      MTLColorWriteMaskAll;
  descriptor.colorAttachments[FinalColorAttachment].blendingEnabled = NO;
  for(NSUInteger i=1u;
      i<static_cast<NSUInteger>(ColorAttachmentCount); ++i)
    descriptor.colorAttachments[i].pixelFormat = MTLPixelFormatInvalid;
  descriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
  descriptor.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
  descriptor.rasterSampleCount = NSUInteger(1u);
  descriptor.inputPrimitiveTopology =
      MTLPrimitiveTopologyClassTriangle;
  descriptor.alphaToCoverageEnabled = NO;
  descriptor.alphaToOneEnabled = NO;
  descriptor.rasterizationEnabled = YES;
  descriptor.supportIndirectCommandBuffers = NO;
  descriptor.binaryArchives = nil;
  descriptor.label =
      alphaTestEnabled
          ? @"RendererIOS Forward AlphaTest"
          : @"RendererIOS Forward Opaque";

  report.binaryArchivesNil = descriptor.binaryArchives==nil;
  report.vertexDescriptorMatches =
      vertexDescriptorMatches(vertexDescriptor);
  report.colorAttachmentRgba8Unorm =
      descriptor.colorAttachments[FinalColorAttachment].pixelFormat==
          MTLPixelFormatRGBA8Unorm;
  report.unusedColorAttachmentsInvalid =
      unusedColorAttachmentsInvalid(descriptor);
  report.colorWriteMaskAll =
      descriptor.colorAttachments[FinalColorAttachment].writeMask==
          MTLColorWriteMaskAll;
  report.blendingDisabled =
      descriptor.colorAttachments[FinalColorAttachment].
          blendingEnabled==NO;
  report.depthStencilDisabled =
      descriptor.depthAttachmentPixelFormat==MTLPixelFormatInvalid &&
      descriptor.stencilAttachmentPixelFormat==MTLPixelFormatInvalid;
  report.triangleTopology =
      descriptor.inputPrimitiveTopology==
          MTLPrimitiveTopologyClassTriangle;
  report.alphaToCoverageDisabled =
      descriptor.alphaToCoverageEnabled==NO;
  report.alphaToOneDisabled =
      descriptor.alphaToOneEnabled==NO;
  report.rasterizationEnabled =
      descriptor.rasterizationEnabled==YES;
  report.indirectCommandBuffersDisabled =
      descriptor.supportIndirectCommandBuffers==NO;
  report.alphaTestEnabled = alphaTestEnabled;
  report.sampleCount = narrow(descriptor.rasterSampleCount);

  NSError* error = nil;
  MTLAutoreleasedRenderPipelineReflection reflection = nil;
  id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithDescriptor:descriptor
                                           options:
                                               MTLPipelineOptionBindingInfo
                                        reflection:&reflection
                                             error:&error];
  pipelineOwner.reset(pipeline);
  report.available = pipeline!=nil;
  if(pipeline==nil || error!=nil)
    return NativePipelineBuild::CreationFailed;
  report.sameDevice = pipeline.device==device;
  report.imageblockBytesPerSample =
      narrow(pipeline.imageblockSampleLength);
  report.reflectionAvailable = reflection!=nil;
  if(reflection==nil)
    return NativePipelineBuild::ReflectionFailed;
  report.vertexBindings =
      normalizeBindings(reflection.vertexBindings,BindingStage::Vertex);
  report.fragmentBindings =
      normalizeBindings(
          reflection.fragmentBindings,BindingStage::Fragment);
  report.tileBindings =
      normalizeBindings(reflection.tileBindings,BindingStage::Tile);
  report.objectBindings =
      normalizeBindings(reflection.objectBindings,BindingStage::Object);
  report.meshBindings =
      normalizeBindings(reflection.meshBindings,BindingStage::Mesh);
  return NativePipelineBuild::Ready;
  }

}

struct IOSShadingPrototypeForwardPipeline::Impl final {
  Impl(id computePipeline,
       id opaquePipeline,
       id alphaPipeline) noexcept
    : computePipeline(computePipeline),
      opaquePipeline(opaquePipeline),
      alphaPipeline(alphaPipeline) {
    }

  ~Impl() {
    [alphaPipeline release];
    [opaquePipeline release];
    [computePipeline release];
    }

  Impl(const Impl&) = delete;
  Impl& operator=(const Impl&) = delete;

  id computePipeline = nil;
  id opaquePipeline = nil;
  id alphaPipeline = nil;
  };

bool IOSShadingPrototypeForwardPipelineNativeAccess::borrow(
    const IOSShadingPrototypeForwardPipeline& pipeline,
    IOSShadingPrototypeForwardPipelineNativeView& view) noexcept {
  view = {};
  if(pipeline.pipelineStatus!=
         IOSShadingPrototypeForwardPipelineStatus::Ready ||
     pipeline.impl==nullptr ||
     pipeline.impl->computePipeline==nil ||
     pipeline.impl->opaquePipeline==nil ||
     pipeline.impl->alphaPipeline==nil)
    return false;

  @try {
    id<MTLComputePipelineState> compute =
        (id<MTLComputePipelineState>)
            pipeline.impl->computePipeline;
    id<MTLRenderPipelineState> opaque =
        (id<MTLRenderPipelineState>)
            pipeline.impl->opaquePipeline;
    id<MTLRenderPipelineState> alpha =
        (id<MTLRenderPipelineState>)
            pipeline.impl->alphaPipeline;
    id<MTLDevice> device = compute.device;
    if(device==nil || opaque.device!=device ||
       alpha.device!=device ||
       ![compute.label
           isEqualToString:
               @"RendererIOS Forward BuildLightList"] ||
       ![opaque.label
           isEqualToString:@"RendererIOS Forward Opaque"] ||
       ![alpha.label
           isEqualToString:@"RendererIOS Forward AlphaTest"])
      return false;

    view.device =
        reinterpret_cast<MTL::Device*>((void*)device);
    view.buildLightList =
        reinterpret_cast<MTL::ComputePipelineState*>(
            (void*)compute);
    view.opaque =
        reinterpret_cast<MTL::RenderPipelineState*>(
            (void*)opaque);
    view.alphaTest =
        reinterpret_cast<MTL::RenderPipelineState*>(
            (void*)alpha);
    return true;
    }
  @catch(NSException*) {
    view = {};
    return false;
    }
  }

IOSShadingPrototypeForwardPipeline::
    IOSShadingPrototypeForwardPipeline() noexcept = default;
IOSShadingPrototypeForwardPipeline::
    ~IOSShadingPrototypeForwardPipeline() = default;

IOSShadingPrototypeForwardPipeline::
    IOSShadingPrototypeForwardPipeline(
        IOSShadingPrototypeForwardPipeline&& other) noexcept
  : pipelineStatus(other.pipelineStatus),
    pipelineReport(other.pipelineReport),
    impl(std::move(other.impl)) {
  other.pipelineStatus =
      IOSShadingPrototypeForwardPipelineStatus::InternalFailure;
  other.pipelineReport = {};
  }

IOSShadingPrototypeForwardPipeline&
    IOSShadingPrototypeForwardPipeline::operator=(
        IOSShadingPrototypeForwardPipeline&& other) noexcept {
  if(this==&other)
    return *this;
  pipelineStatus = other.pipelineStatus;
  pipelineReport = other.pipelineReport;
  impl = std::move(other.impl);
  other.pipelineStatus =
      IOSShadingPrototypeForwardPipelineStatus::InternalFailure;
  other.pipelineReport = {};
  return *this;
  }

IOSShadingPrototypeForwardPipeline::
    IOSShadingPrototypeForwardPipeline(
        IOSShadingPrototypeForwardPipelineStatus status,
        IOSShadingPrototypeForwardPipelineReport report,
        std::unique_ptr<Impl>&& impl) noexcept
  : pipelineStatus(status),
    pipelineReport(report),
    impl(std::move(impl)) {
  }

IOSShadingPrototypeForwardPipeline::operator bool() const noexcept {
  return pipelineStatus==
             IOSShadingPrototypeForwardPipelineStatus::Ready &&
         impl!=nullptr;
  }

IOSShadingPrototypeForwardPipelineStatus
    IOSShadingPrototypeForwardPipeline::status() const noexcept {
  return pipelineStatus;
  }

const IOSShadingPrototypeForwardPipelineReport&
    IOSShadingPrototypeForwardPipeline::report() const noexcept {
  return pipelineReport;
  }

IOSShadingPrototypeForwardPipeline
    iosCreateShadingPrototypeForwardPipeline(
        Tempest::Device& owner) noexcept {
  using namespace RendererIOSShadingPrototypeForwardPipeline;
  using Pipeline = IOSShadingPrototypeForwardPipeline;
  using Status = IOSShadingPrototypeForwardPipelineStatus;

  IOSShadingPrototypeForwardPipelineReport report;
  report.contractVersion = ContractVersion;
  report.offlineMetallibAbi = OfflineMetallibAbi;

  @try {
    try {
      @autoreleasepool {
        const Tempest::BorrowedMetalDevice borrowedDevice =
            Tempest::MetalApi::borrowDevice(owner);
        if(!borrowedDevice)
          return Pipeline(Status::DeviceUnavailable,report,{});
        id<MTLDevice> device =
            (id<MTLDevice>)(void*)borrowedDevice.get();
        report.deviceAvailable = device!=nil;
        if(device==nil)
          return Pipeline(Status::DeviceUnavailable,report,{});

        report.supportsApple4 =
            [device supportsFamily:MTLGPUFamilyApple4]==YES;
        if(!report.supportsApple4)
          return Pipeline(Status::UnsupportedCapability,report,{});

        OwnedObjectiveC libraryName(
            makeString(RendererIOSShader::LibraryName).relinquish());
        if(libraryName.get()==nil)
          return Pipeline(Status::InternalFailure,report,{});
        NSBundle* bundle = [NSBundle mainBundle];
        NSURL* libraryUrl =
            [bundle URLForResource:(NSString*)libraryName.get()
                     withExtension:@"metallib"];
        if(libraryUrl==nil)
          return Pipeline(Status::LibraryUnavailable,report,{});

        NSError* libraryError = nil;
        OwnedObjectiveC library(
            [device newLibraryWithURL:libraryUrl error:&libraryError]);
        report.libraryAvailable =
            library.get()!=nil && libraryError==nil;
        id<MTLLibrary> nativeLibrary = (id<MTLLibrary>)library.get();
        report.librarySameDevice =
            nativeLibrary!=nil && nativeLibrary.device==device;
        if(!report.libraryAvailable || !report.librarySameDevice)
          return Pipeline(Status::LibraryUnavailable,report,{});

        OwnedObjectiveC vertexName(
            makeString(
                RendererIOSShadingPrototypeShader::VertexFunction)
                .relinquish());
        OwnedObjectiveC computeName(
            makeString(
                RendererIOSShadingPrototypeShader::
                    ForwardLightListFunction)
                .relinquish());
        OwnedObjectiveC fragmentName(
            makeString(
                RendererIOSShadingPrototypeShader::
                    ForwardFragmentFunction)
                .relinquish());
        OwnedObjectiveC constantName(
            makeString(AlphaTestFunctionConstantName).relinquish());
        if(vertexName.get()==nil || computeName.get()==nil ||
           fragmentName.get()==nil || constantName.get()==nil)
          return Pipeline(Status::InternalFailure,report,{});

        OwnedObjectiveC vertexFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)vertexName.get()]);
        OwnedObjectiveC computeFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)computeName.get()]);
        OwnedObjectiveC fragmentFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)fragmentName.get()]);
        report.functions[0] = normalizeFunction(
            (id<MTLFunction>)vertexFunction.get(),
            (NSString*)vertexName.get(),nil,device);
        report.functions[1] = normalizeFunction(
            (id<MTLFunction>)computeFunction.get(),
            (NSString*)computeName.get(),nil,device);
        report.functions[2] = normalizeFunction(
            (id<MTLFunction>)fragmentFunction.get(),
            (NSString*)fragmentName.get(),
            (NSString*)constantName.get(),device);
        for(const auto& function:report.functions)
          report.resolvedFunctionCount +=
              function.available ? 1u : 0u;

        OwnedObjectiveC constantValues(
            [[MTLFunctionConstantValues alloc] init]);
        if(constantValues.get()==nil)
          return Pipeline(Status::InternalFailure,report,{});
        bool alphaTest = false;
        [(MTLFunctionConstantValues*)constantValues.get()
            setConstantValue:&alphaTest
                        type:MTLDataTypeBool
                     atIndex:static_cast<NSUInteger>(
                                 AlphaTestFunctionConstant)];
        NSError* opaqueError = nil;
        OwnedObjectiveC opaqueFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)fragmentName.get()
                     constantValues:
                         (MTLFunctionConstantValues*)constantValues.get()
                              error:&opaqueError]);
        alphaTest = true;
        [(MTLFunctionConstantValues*)constantValues.get()
            setConstantValue:&alphaTest
                        type:MTLDataTypeBool
                     atIndex:static_cast<NSUInteger>(
                                 AlphaTestFunctionConstant)];
        NSError* alphaError = nil;
        OwnedObjectiveC alphaFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)fragmentName.get()
                     constantValues:
                         (MTLFunctionConstantValues*)constantValues.get()
                              error:&alphaError]);
        report.fragmentSpecializations[0] =
            normalizeSpecialization(
                (id<MTLFunction>)opaqueFunction.get(),
                (NSString*)fragmentName.get(),device,false);
        report.fragmentSpecializations[1] =
            normalizeSpecialization(
                (id<MTLFunction>)alphaFunction.get(),
                (NSString*)fragmentName.get(),device,true);
        for(const auto& specialization:
            report.fragmentSpecializations)
          report.specializationCount +=
              specialization.available ? 1u : 0u;

        const IOSShadingPrototypeForwardPipelineReport canonical =
            iosCanonicalShadingPrototypeForwardPipelineReport();
        if(opaqueError!=nil || alphaError!=nil ||
           report.resolvedFunctionCount!=ResolvedFunctionCount ||
           report.specializationCount!=SpecializationCount ||
           report.functions!=canonical.functions ||
           report.fragmentSpecializations!=
               canonical.fragmentSpecializations)
          return Pipeline(Status::FunctionMismatch,report,{});

        OwnedObjectiveC computePipeline;
        OwnedObjectiveC opaquePipeline;
        OwnedObjectiveC alphaPipeline;
        const NativePipelineBuild computeBuild = buildComputePipeline(
            device,(id<MTLFunction>)computeFunction.get(),
            report.computePipeline,computePipeline);
        if(computeBuild!=NativePipelineBuild::CreationFailed &&
           report.computePipeline.available)
          ++report.createdComputePipelineCount;

        const NativePipelineBuild opaqueBuild = buildRenderPipeline(
            device,(id<MTLFunction>)vertexFunction.get(),
            (id<MTLFunction>)opaqueFunction.get(),false,
            report.renderPipelines[0],opaquePipeline);
        if(opaqueBuild!=NativePipelineBuild::CreationFailed &&
           report.renderPipelines[0].available)
          ++report.createdRenderPipelineCount;

        const NativePipelineBuild alphaBuild = buildRenderPipeline(
            device,(id<MTLFunction>)vertexFunction.get(),
            (id<MTLFunction>)alphaFunction.get(),true,
            report.renderPipelines[1],alphaPipeline);
        if(alphaBuild!=NativePipelineBuild::CreationFailed &&
           report.renderPipelines[1].available)
          ++report.createdRenderPipelineCount;

        const std::array<NativePipelineBuild,3u> builds = {
          computeBuild,opaqueBuild,alphaBuild,
          };
        for(const NativePipelineBuild result:builds) {
          if(result==NativePipelineBuild::CreationFailed)
            return Pipeline(
                Status::PipelineCreationFailed,report,{});
          }

        const Status validation =
            iosValidateShadingPrototypeForwardPipelineReport(report);
        if(validation!=Status::Ready)
          return Pipeline(validation,report,{});

        std::unique_ptr<Pipeline::Impl> impl(
            new Pipeline::Impl(
                computePipeline.relinquish(),
                opaquePipeline.relinquish(),
                alphaPipeline.relinquish()));
        return Pipeline(Status::Ready,report,std::move(impl));
        }
      }
    catch(...) {
      return Pipeline(Status::InternalFailure,report,{});
      }
    }
  @catch(NSException* exception) {
    (void)exception;
    return Pipeline(Status::InternalFailure,report,{});
    }
  }
