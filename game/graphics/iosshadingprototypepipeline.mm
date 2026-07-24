#include "iosshadingprototypepipeline.h"

#include "ioslandscapeshaderabi.h"
#include "iosshadingprototypepipelinenative.h"
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
#error "IOSShadingPrototypePipeline requires the project's non-ARC Objective-C++ mode"
#endif

namespace {

using namespace RendererIOSShadingPrototypePipeline;

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
    RendererIOSShadingPrototypeShader::TileMaterialBytesPerSample==
    ExplicitMaterialBytesPerSample);
static_assert(
    RendererIOSShadingPrototypeShader::TileFinalColorAttachment==
    FinalColorAttachment);

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

uint32_t narrow(NSUInteger value) noexcept {
  constexpr uint32_t Invalid = std::numeric_limits<uint32_t>::max();
  if(value>static_cast<NSUInteger>(Invalid))
    return Invalid;
  return static_cast<uint32_t>(value);
  }

OwnedObjectiveC makeString(std::string_view value) {
  return OwnedObjectiveC(
      [[NSString alloc]
          initWithBytes:value.data()
                 length:value.size()
               encoding:NSUTF8StringEncoding]);
  }

IOSShadingPrototypeFunctionStage neutralStage(
    MTLFunctionType stage) noexcept {
  switch(stage) {
    case MTLFunctionTypeVertex:
      return IOSShadingPrototypeFunctionStage::Vertex;
    case MTLFunctionTypeFragment:
      return IOSShadingPrototypeFunctionStage::Fragment;
    case MTLFunctionTypeKernel:
      return IOSShadingPrototypeFunctionStage::Kernel;
    default:
      return IOSShadingPrototypeFunctionStage::Unknown;
    }
  }

IOSShadingPrototypeBindingType neutralBindingType(
    MTLBindingType type,
    NSUInteger index) noexcept {
  switch(type) {
    case MTLBindingTypeBuffer:
      return index==static_cast<NSUInteger>(VertexBuffer)
          ? IOSShadingPrototypeBindingType::VertexBuffer
          : IOSShadingPrototypeBindingType::Unknown;
    case MTLBindingTypeImageblockData:
      return IOSShadingPrototypeBindingType::ImageblockData;
    case MTLBindingTypeImageblock:
      return IOSShadingPrototypeBindingType::Imageblock;
    default:
      return IOSShadingPrototypeBindingType::Unknown;
    }
  }

IOSShadingPrototypeBindingListReport normalizeBindings(
    NSArray<id<MTLBinding>>* bindings) {
  IOSShadingPrototypeBindingListReport report;
  report.available = bindings!=nil;
  if(bindings==nil)
    return report;

  NSUInteger bindingCount = 0u;
  for(NSUInteger i=0u; i<bindings.count; ++i) {
    id<MTLBinding> binding = [bindings objectAtIndex:i];
    if(binding==nil)
      continue;
    const IOSShadingPrototypeBindingType type =
        neutralBindingType(binding.type,binding.index);
    if(bindingCount<
       static_cast<NSUInteger>(report.bindings.size())) {
      auto& normalized =
          report.bindings[static_cast<std::size_t>(bindingCount)];
      normalized.type = type;
      normalized.used = binding.isUsed==YES;
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

IOSShadingPrototypeFunctionReport normalizeFunction(
    id<MTLFunction> function,
    NSString* expectedName,
    NSString* alphaConstantName,
    id<MTLDevice> expectedDevice) {
  IOSShadingPrototypeFunctionReport report;
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

IOSShadingPrototypeSpecializationReport normalizeSpecialization(
    id<MTLFunction> function,
    NSString* expectedName,
    id<MTLDevice> expectedDevice,
    bool alphaTestEnabled) {
  IOSShadingPrototypeSpecializationReport report;
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
             static_cast<NSUInteger>(VertexBuffer) &&
         descriptor.attributes[ColorAttribute].format==
             MTLVertexFormatFloat4 &&
         descriptor.attributes[ColorAttribute].offset==
             static_cast<NSUInteger>(ColorOffset) &&
         descriptor.attributes[ColorAttribute].bufferIndex==
             static_cast<NSUInteger>(VertexBuffer) &&
         descriptor.layouts[VertexBuffer].stride==
             static_cast<NSUInteger>(VertexStride) &&
         descriptor.layouts[VertexBuffer].stepFunction==
             MTLVertexStepFunctionPerVertex &&
         descriptor.layouts[VertexBuffer].stepRate==NSUInteger(1u);
  }

bool unusedRenderColorAttachmentsInvalid(
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

bool unusedTileColorAttachmentsInvalid(
    MTLTileRenderPipelineDescriptor* descriptor) {
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

NativePipelineBuild buildMaterialPipeline(
    id<MTLDevice> device,
    id<MTLFunction> vertexFunction,
    id<MTLFunction> fragmentFunction,
    bool alphaTestEnabled,
    IOSShadingPrototypeMaterialPipelineReport& report,
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
      static_cast<NSUInteger>(VertexBuffer);
  vertexDescriptor.attributes[ColorAttribute].format =
      MTLVertexFormatFloat4;
  vertexDescriptor.attributes[ColorAttribute].offset =
      static_cast<NSUInteger>(ColorOffset);
  vertexDescriptor.attributes[ColorAttribute].bufferIndex =
      static_cast<NSUInteger>(VertexBuffer);
  vertexDescriptor.layouts[VertexBuffer].stride =
      static_cast<NSUInteger>(VertexStride);
  vertexDescriptor.layouts[VertexBuffer].stepFunction =
      MTLVertexStepFunctionPerVertex;
  vertexDescriptor.layouts[VertexBuffer].stepRate = NSUInteger(1u);

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
  descriptor.binaryArchives = nil;

  report.binaryArchivesNil = descriptor.binaryArchives==nil;
  report.vertexDescriptorMatches =
      vertexDescriptorMatches(vertexDescriptor);
  report.colorAttachmentRgba8Unorm =
      descriptor.colorAttachments[FinalColorAttachment].pixelFormat==
          MTLPixelFormatRGBA8Unorm;
  report.unusedColorAttachmentsInvalid =
      unusedRenderColorAttachmentsInvalid(descriptor);
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
  report.alphaTestEnabled = alphaTestEnabled;
  report.sampleCount = narrow(descriptor.rasterSampleCount);

  NSError* error = nil;
  MTLAutoreleasedRenderPipelineReflection reflection = nil;
  id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithDescriptor:descriptor
                                           options:MTLPipelineOptionBindingInfo
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
      normalizeBindings(reflection.vertexBindings);
  report.fragmentBindings =
      normalizeBindings(reflection.fragmentBindings);
  report.tileBindings =
      normalizeBindings(reflection.tileBindings);
  return NativePipelineBuild::Ready;
  }

NativePipelineBuild buildLightingPipeline(
    id<MTLDevice> device,
    id<MTLFunction> tileFunction,
    IOSShadingPrototypeTilePipelineReport& report,
    OwnedObjectiveC& pipelineOwner) {
  OwnedObjectiveC descriptorOwner(
      [[MTLTileRenderPipelineDescriptor alloc] init]);
  MTLTileRenderPipelineDescriptor* descriptor =
      (MTLTileRenderPipelineDescriptor*)descriptorOwner.get();
  if(descriptor==nil)
    return NativePipelineBuild::CreationFailed;
  descriptor.tileFunction = tileFunction;
  descriptor.rasterSampleCount = NSUInteger(1u);
  descriptor.colorAttachments[FinalColorAttachment].pixelFormat =
      MTLPixelFormatRGBA8Unorm;
  for(NSUInteger i=1u;
      i<static_cast<NSUInteger>(ColorAttachmentCount); ++i)
    descriptor.colorAttachments[i].pixelFormat = MTLPixelFormatInvalid;
  descriptor.threadgroupSizeMatchesTileSize = YES;
  descriptor.binaryArchives = nil;

  report.binaryArchivesNil = descriptor.binaryArchives==nil;
  report.colorAttachmentRgba8Unorm =
      descriptor.colorAttachments[FinalColorAttachment].pixelFormat==
          MTLPixelFormatRGBA8Unorm;
  report.unusedColorAttachmentsInvalid =
      unusedTileColorAttachmentsInvalid(descriptor);
  report.threadgroupSizeMatchesTileSize =
      descriptor.threadgroupSizeMatchesTileSize==YES;
  report.sampleCount = narrow(descriptor.rasterSampleCount);

  NSError* error = nil;
  MTLAutoreleasedRenderPipelineReflection reflection = nil;
  id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithTileDescriptor:descriptor
                                               options:MTLPipelineOptionBindingInfo
                                            reflection:&reflection
                                                 error:&error];
  pipelineOwner.reset(pipeline);
  report.available = pipeline!=nil;
  if(pipeline==nil || error!=nil)
    return NativePipelineBuild::CreationFailed;
  report.sameDevice = pipeline.device==device;
  report.threadgroupSizeMatchesTileSize =
      report.threadgroupSizeMatchesTileSize &&
      pipeline.threadgroupSizeMatchesTileSize==YES;
  report.imageblockBytesPerSample =
      narrow(pipeline.imageblockSampleLength);
  report.reflectionAvailable = reflection!=nil;
  if(reflection==nil)
    return NativePipelineBuild::ReflectionFailed;
  report.vertexBindings =
      normalizeBindings(reflection.vertexBindings);
  report.fragmentBindings =
      normalizeBindings(reflection.fragmentBindings);
  report.tileBindings =
      normalizeBindings(reflection.tileBindings);
  return NativePipelineBuild::Ready;
  }

IOSShadingPrototypePipelineStatus statusFor(
    NativePipelineBuild result) noexcept {
  switch(result) {
    case NativePipelineBuild::Ready:
      return IOSShadingPrototypePipelineStatus::Ready;
    case NativePipelineBuild::CreationFailed:
      return IOSShadingPrototypePipelineStatus::PipelineCreationFailed;
    case NativePipelineBuild::ReflectionFailed:
      return IOSShadingPrototypePipelineStatus::ReflectionMismatch;
    }
  return IOSShadingPrototypePipelineStatus::InternalFailure;
  }

}

struct IOSShadingPrototypePipeline::Impl final {
  Impl(id opaquePipeline,
       id alphaPipeline,
       id lightingPipeline) noexcept
    : opaquePipeline(opaquePipeline),
      alphaPipeline(alphaPipeline),
      lightingPipeline(lightingPipeline) {
    }

  ~Impl() {
    [lightingPipeline release];
    [alphaPipeline release];
    [opaquePipeline release];
    }

  Impl(const Impl&) = delete;
  Impl& operator=(const Impl&) = delete;

  id opaquePipeline = nil;
  id alphaPipeline = nil;
  id lightingPipeline = nil;
  };

bool IOSShadingPrototypePipelineNativeAccess::borrow(
    const IOSShadingPrototypePipeline& pipeline,
    IOSShadingPrototypePipelineNativeView& view) noexcept {
  view = {};
  if(pipeline.pipelineStatus!=
         IOSShadingPrototypePipelineStatus::Ready ||
     pipeline.impl==nullptr ||
     pipeline.impl->opaquePipeline==nil ||
     pipeline.impl->alphaPipeline==nil ||
     pipeline.impl->lightingPipeline==nil)
    return false;

  @try {
    id<MTLRenderPipelineState> opaque =
        (id<MTLRenderPipelineState>)pipeline.impl->opaquePipeline;
    id<MTLRenderPipelineState> alpha =
        (id<MTLRenderPipelineState>)pipeline.impl->alphaPipeline;
    id<MTLRenderPipelineState> lighting =
        (id<MTLRenderPipelineState>)pipeline.impl->lightingPipeline;
    id<MTLDevice> device = opaque.device;
    if(device==nil || alpha.device!=device ||
       lighting.device!=device)
      return false;

    view.device =
        reinterpret_cast<MTL::Device*>((void*)device);
    view.opaque =
        reinterpret_cast<MTL::RenderPipelineState*>((void*)opaque);
    view.alphaTest =
        reinterpret_cast<MTL::RenderPipelineState*>((void*)alpha);
    view.tileLighting =
        reinterpret_cast<MTL::RenderPipelineState*>((void*)lighting);
    return view.device!=nullptr &&
           view.opaque!=nullptr &&
           view.alphaTest!=nullptr &&
           view.tileLighting!=nullptr;
    }
  @catch(NSException*) {
    view = {};
    return false;
    }
  }

IOSShadingPrototypePipeline::IOSShadingPrototypePipeline() noexcept =
    default;
IOSShadingPrototypePipeline::~IOSShadingPrototypePipeline() = default;
IOSShadingPrototypePipeline::IOSShadingPrototypePipeline(
    IOSShadingPrototypePipeline&& other) noexcept = default;
IOSShadingPrototypePipeline& IOSShadingPrototypePipeline::operator=(
    IOSShadingPrototypePipeline&& other) noexcept = default;

IOSShadingPrototypePipeline::IOSShadingPrototypePipeline(
    IOSShadingPrototypePipelineStatus status,
    IOSShadingPrototypePipelineReport report,
    std::unique_ptr<Impl>&& impl) noexcept
  : pipelineStatus(status),
    pipelineReport(report),
    impl(std::move(impl)) {
  }

IOSShadingPrototypePipeline::operator bool() const noexcept {
  return pipelineStatus==IOSShadingPrototypePipelineStatus::Ready &&
         impl!=nullptr;
  }

IOSShadingPrototypePipelineStatus
    IOSShadingPrototypePipeline::status() const noexcept {
  return pipelineStatus;
  }

const IOSShadingPrototypePipelineReport&
    IOSShadingPrototypePipeline::report() const noexcept {
  return pipelineReport;
  }

IOSShadingPrototypePipeline iosCreateShadingPrototypePipeline(
    Tempest::Device& owner) noexcept {
  IOSShadingPrototypePipelineReport report;
  report.contractVersion = ContractVersion;
  report.offlineMetallibAbi = OfflineMetallibAbi;

  @try {
    try {
      @autoreleasepool {
        const Tempest::BorrowedMetalDevice borrowedDevice =
            Tempest::MetalApi::borrowDevice(owner);
        if(!borrowedDevice)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::DeviceUnavailable,
              report,{});
        id<MTLDevice> device =
            (id<MTLDevice>)(void*)borrowedDevice.get();
        report.deviceAvailable = device!=nil;
        if(device==nil)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::DeviceUnavailable,
              report,{});

        report.supportsApple4 =
            [device supportsFamily:MTLGPUFamilyApple4]==YES;
        if(!report.supportsApple4)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::UnsupportedCapability,
              report,{});

        OwnedObjectiveC libraryName(
            makeString(RendererIOSShader::LibraryName).relinquish());
        if(libraryName.get()==nil)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::InternalFailure,
              report,{});
        NSBundle* bundle = [NSBundle mainBundle];
        NSURL* libraryUrl =
            [bundle URLForResource:(NSString*)libraryName.get()
                     withExtension:@"metallib"];
        if(libraryUrl==nil)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::LibraryUnavailable,
              report,{});

        NSError* libraryError = nil;
        OwnedObjectiveC library(
            [device newLibraryWithURL:libraryUrl error:&libraryError]);
        report.libraryAvailable =
            library.get()!=nil && libraryError==nil;
        id<MTLLibrary> nativeLibrary =
            (id<MTLLibrary>)library.get();
        report.librarySameDevice =
            nativeLibrary!=nil && nativeLibrary.device==device;
        if(!report.libraryAvailable || !report.librarySameDevice)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::LibraryUnavailable,
              report,{});

        OwnedObjectiveC vertexName(
            makeString(
                RendererIOSShadingPrototypeShader::VertexFunction)
                .relinquish());
        OwnedObjectiveC materialName(
            makeString(
                RendererIOSShadingPrototypeShader::
                    TileMaterialFragmentFunction)
                .relinquish());
        OwnedObjectiveC lightingName(
            makeString(
                RendererIOSShadingPrototypeShader::TileLightingFunction)
                .relinquish());
        OwnedObjectiveC constantName(
            makeString(AlphaTestFunctionConstantName).relinquish());
        if(vertexName.get()==nil || materialName.get()==nil ||
           lightingName.get()==nil || constantName.get()==nil)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::InternalFailure,
              report,{});

        OwnedObjectiveC vertexFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)vertexName.get()]);
        OwnedObjectiveC materialFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)materialName.get()]);
        OwnedObjectiveC lightingFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)lightingName.get()]);
        report.functions[0] = normalizeFunction(
            (id<MTLFunction>)vertexFunction.get(),
            (NSString*)vertexName.get(),nil,device);
        report.functions[1] = normalizeFunction(
            (id<MTLFunction>)materialFunction.get(),
            (NSString*)materialName.get(),
            (NSString*)constantName.get(),device);
        report.functions[2] = normalizeFunction(
            (id<MTLFunction>)lightingFunction.get(),
            (NSString*)lightingName.get(),nil,device);
        for(const auto& function:report.functions)
          report.resolvedTileFunctionCount +=
              function.available ? 1u : 0u;

        OwnedObjectiveC constantValues(
            [[MTLFunctionConstantValues alloc] init]);
        if(constantValues.get()==nil)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::InternalFailure,
              report,{});
        bool alphaTest = false;
        [(MTLFunctionConstantValues*)constantValues.get()
            setConstantValue:&alphaTest
                        type:MTLDataTypeBool
                     atIndex:static_cast<NSUInteger>(
                                 AlphaTestFunctionConstant)];
        NSError* opaqueError = nil;
        OwnedObjectiveC opaqueFunction(
            [nativeLibrary
                newFunctionWithName:(NSString*)materialName.get()
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
                newFunctionWithName:(NSString*)materialName.get()
                     constantValues:
                         (MTLFunctionConstantValues*)constantValues.get()
                              error:&alphaError]);
        report.materialSpecializations[0] = normalizeSpecialization(
            (id<MTLFunction>)opaqueFunction.get(),
            (NSString*)materialName.get(),device,false);
        report.materialSpecializations[1] = normalizeSpecialization(
            (id<MTLFunction>)alphaFunction.get(),
            (NSString*)materialName.get(),device,true);
        const IOSShadingPrototypePipelineReport canonical =
            iosCanonicalShadingPrototypePipelineReport();
        if(opaqueError!=nil || alphaError!=nil ||
           report.resolvedTileFunctionCount!=TileFunctionCount ||
           report.functions!=canonical.functions ||
           report.materialSpecializations!=
               canonical.materialSpecializations)
          return IOSShadingPrototypePipeline(
              IOSShadingPrototypePipelineStatus::FunctionMismatch,
              report,{});

        OwnedObjectiveC opaquePipeline;
        OwnedObjectiveC alphaPipeline;
        OwnedObjectiveC lightingPipeline;
        NativePipelineBuild build = buildMaterialPipeline(
            device,(id<MTLFunction>)vertexFunction.get(),
            (id<MTLFunction>)opaqueFunction.get(),
            false,
            report.materialPipelines[0],opaquePipeline);
        if(build!=NativePipelineBuild::Ready)
          return IOSShadingPrototypePipeline(
              statusFor(build),report,{});
        ++report.createdTilePipelineCount;
        build = buildMaterialPipeline(
            device,(id<MTLFunction>)vertexFunction.get(),
            (id<MTLFunction>)alphaFunction.get(),
            true,
            report.materialPipelines[1],alphaPipeline);
        if(build!=NativePipelineBuild::Ready)
          return IOSShadingPrototypePipeline(
              statusFor(build),report,{});
        ++report.createdTilePipelineCount;
        build = buildLightingPipeline(
            device,(id<MTLFunction>)lightingFunction.get(),
            report.lightingPipeline,lightingPipeline);
        if(build!=NativePipelineBuild::Ready)
          return IOSShadingPrototypePipeline(
              statusFor(build),report,{});
        ++report.createdTilePipelineCount;

        const IOSShadingPrototypePipelineStatus validation =
            iosValidateShadingPrototypePipelineReport(report);
        if(validation!=IOSShadingPrototypePipelineStatus::Ready)
          return IOSShadingPrototypePipeline(validation,report,{});

        std::unique_ptr<IOSShadingPrototypePipeline::Impl> impl(
            new IOSShadingPrototypePipeline::Impl(
                opaquePipeline.relinquish(),
                alphaPipeline.relinquish(),
                lightingPipeline.relinquish()));
        return IOSShadingPrototypePipeline(
            IOSShadingPrototypePipelineStatus::Ready,
            report,std::move(impl));
        }
      }
    catch(...) {
      return IOSShadingPrototypePipeline(
          IOSShadingPrototypePipelineStatus::InternalFailure,
          report,{});
      }
    }
  @catch(NSException* exception) {
    (void)exception;
    return IOSShadingPrototypePipeline(
        IOSShadingPrototypePipelineStatus::InternalFailure,
        report,{});
    }
  }
