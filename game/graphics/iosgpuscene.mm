#include "iosgpuscene.h"

#include "iosgpusceneplan.h"
#include "iossceneassetregistry.h"
#include "resources.h"

#include <Tempest/CommandBuffer>
#include <Tempest/Device>
#include <Tempest/Encoder>
#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>

#if __has_feature(objc_arc)
#error "IOSGPUScene requires the project's non-ARC Objective-C++ mode"
#endif

namespace {

constexpr char LandscapeShaderSource[] = R"metal(
#include <metal_stdlib>
using namespace metal;

struct IOSLandscapeDrawConstants {
  float4x4 viewProjection;
  float4x4 model;
  float4   baseColor;
};

struct IOSLandscapeVertexIn {
  float3 position [[attribute(0)]];
  float3 normal   [[attribute(1)]];
  float2 uv       [[attribute(2)]];
  float4 color    [[attribute(3)]];
};

struct IOSLandscapeVertexOut {
  float4 position [[position]];
  float4 color;
};

vertex IOSLandscapeVertexOut riosLandscapeVertex(
    IOSLandscapeVertexIn in [[stage_in]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]]) {
  IOSLandscapeVertexOut out;
  const float4 world = draw.model*float4(in.position,1.0);
  float4 clip = draw.viewProjection*world;
  clip.y = -clip.y;
  out.position = clip;
  out.color = in.color*draw.baseColor;
  return out;
}

fragment float4 riosLandscapeFragment(
    IOSLandscapeVertexOut in [[stage_in]]) {
  return float4(in.color.rgb,1.0);
}
)metal";

static_assert(std::is_standard_layout_v<Resources::Vertex>);
static_assert(std::is_trivially_copyable_v<Resources::Vertex>);
static_assert(sizeof(Resources::Vertex)==IOSLandscapeVertexStride);
static_assert(alignof(Resources::Vertex)==alignof(float));
static_assert(offsetof(Resources::Vertex,pos)==0u);
static_assert(offsetof(Resources::Vertex,norm)==12u);
static_assert(offsetof(Resources::Vertex,uv)==24u);
static_assert(offsetof(Resources::Vertex,color)==32u);

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

    id relinquish() noexcept {
      const id result = value;
      value = nil;
      return result;
      }

  private:
    id value = nil;
  };

std::string metalFailure(const char* operation, NSError* error) {
  std::string result(operation);
  result += ": ";
  if(error==nil || error.localizedDescription==nil) {
    result += "unknown Metal error";
    return result;
    }
  const char* description = error.localizedDescription.UTF8String;
  result += description!=nullptr ? description : "unknown Metal error";
  return result;
  }

MTLPixelFormat nativeColorFormat(IOSGPUScene::ColorFormat format) {
  switch(format) {
    case IOSGPUScene::ColorFormat::Bgra8Unorm:
      return MTLPixelFormatBGRA8Unorm;
    }
  throw std::invalid_argument("RendererIOS IOSGPUScene received an unsupported color format");
  }

MTLPixelFormat nativeDepthFormat(IOSGPUScene::DepthFormat format) {
  switch(format) {
    case IOSGPUScene::DepthFormat::Depth16Unorm:
      return MTLPixelFormatDepth16Unorm;
    case IOSGPUScene::DepthFormat::Depth32Float:
      return MTLPixelFormatDepth32Float;
    }
  throw std::invalid_argument("RendererIOS IOSGPUScene received an unsupported depth format");
  }

const IOSMaterial* findMaterial(const IOSSceneSnapshot& snapshot,
                                IOSMaterialHandle handle) noexcept {
  const auto found = std::lower_bound(
      snapshot.materials.begin(),snapshot.materials.end(),handle.value,
      [](const IOSMaterial& material, uint64_t value) {
        return material.id.value<value;
        });
  if(found==snapshot.materials.end() || found->id!=handle)
    return nullptr;
  return &*found;
  }

IOSGPUSceneMeshCandidate candidate(
    const IOSSceneSnapshot& snapshot,
    const IOSSceneAssetRegistry& assets,
    const IOSRenderEntity& entity) noexcept {
  IOSGPUSceneMeshCandidate result;
  result.snapshotGeneration = snapshot.generation;
  result.registryGeneration = assets.generation();
  result.entity             = entity;

  if(const auto* material=findMaterial(snapshot,entity.material);
     material!=nullptr) {
    result.material    = *material;
    result.hasMaterial = true;
    }

  if(const auto* mesh=assets.lookupMesh(entity.mesh); mesh!=nullptr) {
    result.hasMesh                  = true;
    result.hasNativeVertexBuffer    = bool(mesh->vertexBuffer);
    result.hasNativeIndexBuffer     = bool(mesh->indexBuffer);
    result.vertexBufferByteSize     = mesh->metadata.vertexBufferByteSize;
    result.indexBufferByteSize      = mesh->metadata.indexBufferByteSize;
    result.vertexStride             = mesh->metadata.vertexStride;
    result.firstIndex               = mesh->metadata.firstIndex;
    result.indexCount               = mesh->metadata.indexCount;
    }
  return result;
  }

IOSGPUScene::Result resultForPlan(
    IOSGPUSceneDrawPlanResult result) noexcept {
  switch(result) {
    case IOSGPUSceneDrawPlanResult::Draw:
    case IOSGPUSceneDrawPlanResult::SkippedVisibility:
      return IOSGPUScene::Result::Success;
    case IOSGPUSceneDrawPlanResult::GenerationMismatch:
      return IOSGPUScene::Result::GenerationMismatch;
    case IOSGPUSceneDrawPlanResult::MissingMaterial:
      return IOSGPUScene::Result::MissingMaterial;
    case IOSGPUSceneDrawPlanResult::UnsupportedMaterial:
      return IOSGPUScene::Result::UnsupportedMaterial;
    case IOSGPUSceneDrawPlanResult::MissingMesh:
      return IOSGPUScene::Result::MissingMesh;
    case IOSGPUSceneDrawPlanResult::InvalidMesh:
      return IOSGPUScene::Result::InvalidMesh;
    }
  return IOSGPUScene::Result::NativeEncodingFailed;
  }

uint64_t failingHandle(IOSGPUSceneDrawPlanResult result,
                       const IOSRenderEntity& entity) noexcept {
  switch(result) {
    case IOSGPUSceneDrawPlanResult::MissingMaterial:
    case IOSGPUSceneDrawPlanResult::UnsupportedMaterial:
      return entity.material.value;
    case IOSGPUSceneDrawPlanResult::GenerationMismatch:
    case IOSGPUSceneDrawPlanResult::MissingMesh:
    case IOSGPUSceneDrawPlanResult::InvalidMesh:
      return entity.mesh.value;
    case IOSGPUSceneDrawPlanResult::Draw:
    case IOSGPUSceneDrawPlanResult::SkippedVisibility:
      return 0;
    }
  return 0;
  }

}

struct IOSGPUScene::Impl final {
  struct NativeEncodeContext final {
    Impl*                         scene = nullptr;
    const IOSSceneSnapshot*       snapshot = nullptr;
    const IOSSceneAssetRegistry*  assets = nullptr;
    IOSGPUScene::Report           report;
    };

  static void encodeLandscape(void* opaque,
                              MTL::RenderCommandEncoder* nativeEncoder);

  Impl(Tempest::Device& owner, TargetLayout target)
    : owner(owner), nativeDevice(Tempest::MetalApi::borrowDevice(owner)) {
    if(!nativeDevice)
      throw std::invalid_argument(
        "RendererIOS IOSGPUScene requires the owning Tempest Metal device");
    if(target.sampleCount!=1u)
      throw std::invalid_argument(
        "RendererIOS IOSGPUScene first slice supports one sample only");

    @autoreleasepool {
      id<MTLDevice> device =
          (id<MTLDevice>)(void*)nativeDevice.get();
      const MTLPixelFormat colorFormat = nativeColorFormat(target.color);
      const MTLPixelFormat depthFormat = nativeDepthFormat(target.depth);

      OwnedObjectiveC source(
          [[NSString alloc] initWithBytes:LandscapeShaderSource
                                  length:sizeof(LandscapeShaderSource)-1u
                                encoding:NSUTF8StringEncoding]);
      if(source.get()==nil)
        throw std::runtime_error(
          "RendererIOS IOSGPUScene could not create its Metal shader source");

      NSError* libraryError = nil;
      OwnedObjectiveC library(
          [device newLibraryWithSource:(NSString*)source.get()
                               options:nil
                                 error:&libraryError]);
      if(library.get()==nil)
        throw std::runtime_error(
          metalFailure("RendererIOS IOSGPUScene shader compilation failed",
                       libraryError));

      OwnedObjectiveC vertexName(
          [[NSString alloc] initWithUTF8String:"riosLandscapeVertex"]);
      OwnedObjectiveC fragmentName(
          [[NSString alloc] initWithUTF8String:"riosLandscapeFragment"]);
      id<MTLLibrary> nativeLibrary = (id<MTLLibrary>)library.get();
      OwnedObjectiveC vertexFunction(
          [nativeLibrary newFunctionWithName:(NSString*)vertexName.get()]);
      OwnedObjectiveC fragmentFunction(
          [nativeLibrary newFunctionWithName:(NSString*)fragmentName.get()]);
      if(vertexFunction.get()==nil || fragmentFunction.get()==nil)
        throw std::runtime_error(
          "RendererIOS IOSGPUScene could not resolve its Metal shader functions");

      OwnedObjectiveC vertexDescriptor(
          [[MTLVertexDescriptor alloc] init]);
      MTLVertexDescriptor* descriptor =
          (MTLVertexDescriptor*)vertexDescriptor.get();
      descriptor.attributes[0].format      = MTLVertexFormatFloat3;
      descriptor.attributes[0].offset      = 0u;
      descriptor.attributes[0].bufferIndex = 0u;
      descriptor.attributes[1].format      = MTLVertexFormatFloat3;
      descriptor.attributes[1].offset      = 12u;
      descriptor.attributes[1].bufferIndex = 0u;
      descriptor.attributes[2].format      = MTLVertexFormatFloat2;
      descriptor.attributes[2].offset      = 24u;
      descriptor.attributes[2].bufferIndex = 0u;
      descriptor.attributes[3].format      = MTLVertexFormatUChar4Normalized;
      descriptor.attributes[3].offset      = 32u;
      descriptor.attributes[3].bufferIndex = 0u;
      descriptor.layouts[0].stride         = IOSLandscapeVertexStride;
      descriptor.layouts[0].stepFunction   =
          MTLVertexStepFunctionPerVertex;
      descriptor.layouts[0].stepRate       = 1u;

      OwnedObjectiveC pipelineDescriptor(
          [[MTLRenderPipelineDescriptor alloc] init]);
      MTLRenderPipelineDescriptor* pipelineDesc =
          (MTLRenderPipelineDescriptor*)pipelineDescriptor.get();
      pipelineDesc.vertexFunction =
          (id<MTLFunction>)vertexFunction.get();
      pipelineDesc.fragmentFunction =
          (id<MTLFunction>)fragmentFunction.get();
      pipelineDesc.vertexDescriptor = descriptor;
      pipelineDesc.colorAttachments[0].pixelFormat = colorFormat;
      pipelineDesc.depthAttachmentPixelFormat      = depthFormat;
      pipelineDesc.sampleCount = NSUInteger(target.sampleCount);

      NSError* pipelineError = nil;
      OwnedObjectiveC pipelineOwner(
          [device newRenderPipelineStateWithDescriptor:pipelineDesc
                                                 error:&pipelineError]);
      if(pipelineOwner.get()==nil)
        throw std::runtime_error(
          metalFailure("RendererIOS IOSGPUScene pipeline creation failed",
                       pipelineError));

      OwnedObjectiveC depthDescriptor(
          [[MTLDepthStencilDescriptor alloc] init]);
      MTLDepthStencilDescriptor* depthDesc =
          (MTLDepthStencilDescriptor*)depthDescriptor.get();
      depthDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
      depthDesc.depthWriteEnabled    = YES;
      OwnedObjectiveC depthOwner(
          [device newDepthStencilStateWithDescriptor:depthDesc]);
      if(depthOwner.get()==nil)
        throw std::runtime_error(
          "RendererIOS IOSGPUScene depth-state creation failed");

      pipelineState = pipelineOwner.relinquish();
      depthState    = depthOwner.relinquish();
      }
    }

  ~Impl() {
    [depthState release];
    [pipelineState release];
    }

  Tempest::Device&                  owner;
  Tempest::BorrowedMetalDevice      nativeDevice;
  id                               pipelineState = nil;
  id                               depthState = nil;
  };

void IOSGPUScene::Impl::encodeLandscape(
    void* opaque,
    MTL::RenderCommandEncoder* nativeEncoder) {
  auto& context = *static_cast<NativeEncodeContext*>(opaque);
  if(context.scene==nullptr || context.snapshot==nullptr ||
     context.assets==nullptr || nativeEncoder==nullptr) {
    context.report.result = IOSGPUScene::Result::NativeEncodingFailed;
    return;
    }

  id<MTLRenderCommandEncoder> encoder =
      (id<MTLRenderCommandEncoder>)(void*)nativeEncoder;
  [encoder setRenderPipelineState:
      (id<MTLRenderPipelineState>)context.scene->pipelineState];
  [encoder setDepthStencilState:
      (id<MTLDepthStencilState>)context.scene->depthState];
  [encoder setFrontFacingWinding:MTLWindingClockwise];
  [encoder setCullMode:MTLCullModeFront];

  uint32_t drawCount = 0;
  for(const auto& entity:context.snapshot->entities) {
    const auto source = candidate(*context.snapshot,*context.assets,entity);
    IOSGPUSceneDrawPlan plan;
    const auto planned =
        planIOSGPUSceneDraw(context.snapshot->currentCamera,source,plan);
    if(planned==IOSGPUSceneDrawPlanResult::SkippedVisibility)
      continue;
    if(planned!=IOSGPUSceneDrawPlanResult::Draw) {
      context.report.result        = resultForPlan(planned);
      context.report.failingHandle = failingHandle(planned,entity);
      [encoder setDepthStencilState:nil];
      [encoder setCullMode:MTLCullModeNone];
      [encoder setFrontFacingWinding:MTLWindingClockwise];
      return;
      }

    const auto* mesh = context.assets->lookupMesh(entity.mesh);
    if(mesh==nullptr) {
      context.report.result        = IOSGPUScene::Result::MissingMesh;
      context.report.failingHandle = entity.mesh.value;
      [encoder setDepthStencilState:nil];
      [encoder setCullMode:MTLCullModeNone];
      [encoder setFrontFacingWinding:MTLWindingClockwise];
      return;
      }

    id<MTLBuffer> vertexBuffer =
        (id<MTLBuffer>)(void*)mesh->vertexBuffer.get();
    id<MTLBuffer> indexBuffer =
        (id<MTLBuffer>)(void*)mesh->indexBuffer.get();
    [encoder setVertexBuffer:vertexBuffer offset:0u atIndex:0u];
    [encoder setVertexBytes:&plan.constants
                     length:sizeof(plan.constants)
                    atIndex:1u];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:plan.indexCount
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:indexBuffer
                 indexBufferOffset:plan.indexBufferOffset
                     instanceCount:1u
                        baseVertex:0
                      baseInstance:0u];
    ++drawCount;
    }

  [encoder setDepthStencilState:nil];
  [encoder setCullMode:MTLCullModeNone];
  [encoder setFrontFacingWinding:MTLWindingClockwise];
  context.report.result    =
      drawCount!=0u ? IOSGPUScene::Result::Success
                    : IOSGPUScene::Result::Empty;
  context.report.drawCount = drawCount;
  }

IOSGPUScene::IOSGPUScene(Tempest::Device& device, TargetLayout target)
  : impl(std::make_unique<Impl>(device,target)) {
  }

IOSGPUScene::~IOSGPUScene() = default;

IOSGPUScene::Report IOSGPUScene::encode(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSSceneSnapshot& snapshot,
    const IOSSceneAssetRegistry& assets) noexcept {
  if(impl==nullptr || impl->pipelineState==nil || impl->depthState==nil)
    return {Result::PipelineUnavailable,0,0};
  if(!assets.isInitialized() ||
     assets.state()!=IOSSceneAssetRegistryState::Active ||
     !assets.nativeDevice() ||
     assets.nativeDevice().get()!=impl->nativeDevice.get())
    return {Result::RegistryUnavailable,0,0};
  if(!snapshot.generation ||
     snapshot.generation!=assets.generation())
    return {Result::GenerationMismatch,0,0};

  uint32_t plannedDraws = 0;
  for(const auto& entity:snapshot.entities) {
    const auto source = candidate(snapshot,assets,entity);
    IOSGPUSceneDrawPlan plan;
    const auto planned =
        planIOSGPUSceneDraw(snapshot.currentCamera,source,plan);
    if(planned==IOSGPUSceneDrawPlanResult::SkippedVisibility)
      continue;
    if(planned!=IOSGPUSceneDrawPlanResult::Draw)
      return {resultForPlan(planned),0,failingHandle(planned,entity)};
    if(plannedDraws==std::numeric_limits<uint32_t>::max())
      return {Result::InvalidMesh,0,entity.mesh.value};
    ++plannedDraws;
    }
  if(plannedDraws==0u)
    return {Result::Empty,0,0};

  Impl::NativeEncodeContext context;
  context.scene    = impl.get();
  context.snapshot = &snapshot;
  context.assets   = &assets;
  context.report   = {Result::NativeEncodingFailed,0,0};
  try {
    const bool encoded = Tempest::MetalApi::withActiveRenderEncoder(
        impl->owner,encoder,&context,&Impl::encodeLandscape);
    if(!encoded)
      return {Result::NoActiveRenderEncoder,0,0};
    }
  catch(...) {
    return {Result::NativeEncodingFailed,0,0};
    }
  return context.report;
  }

const char* iosGPUSceneResultName(IOSGPUScene::Result result) noexcept {
  switch(result) {
    case IOSGPUScene::Result::Success:
      return "success";
    case IOSGPUScene::Result::Empty:
      return "empty";
    case IOSGPUScene::Result::UnsupportedTarget:
      return "unsupported-target";
    case IOSGPUScene::Result::RegistryUnavailable:
      return "registry-unavailable";
    case IOSGPUScene::Result::GenerationMismatch:
      return "generation-mismatch";
    case IOSGPUScene::Result::MissingMaterial:
      return "missing-material";
    case IOSGPUScene::Result::UnsupportedMaterial:
      return "unsupported-material";
    case IOSGPUScene::Result::MissingMesh:
      return "missing-mesh";
    case IOSGPUScene::Result::InvalidMesh:
      return "invalid-mesh";
    case IOSGPUScene::Result::NoActiveRenderEncoder:
      return "no-active-render-encoder";
    case IOSGPUScene::Result::PipelineUnavailable:
      return "pipeline-unavailable";
    case IOSGPUScene::Result::NativeEncodingFailed:
      return "native-encoding-failed";
    }
  return "unknown";
  }
