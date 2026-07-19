#include "iosgpuscene.h"

#include "iosgpusceneplan.h"
#include "ioslandscapeshader.h"
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
#include <unordered_set>

#if __has_feature(objc_arc)
#error "IOSGPUScene requires the project's non-ARC Objective-C++ mode"
#endif

namespace {

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

MTLPixelFormat nativeTextureFormat(IOSSceneTextureFormat format) noexcept {
  switch(format) {
    case IOSSceneTextureFormat::Rgba8Unorm:
      return MTLPixelFormatRGBA8Unorm;
    case IOSSceneTextureFormat::Bc1Rgba:
      return MTLPixelFormatBC1_RGBA;
    case IOSSceneTextureFormat::Bc2Rgba:
      return MTLPixelFormatBC2_RGBA;
    case IOSSceneTextureFormat::Bc3Rgba:
      return MTLPixelFormatBC3_RGBA;
    case IOSSceneTextureFormat::Invalid:
      return MTLPixelFormatInvalid;
    }
  return MTLPixelFormatInvalid;
  }

bool validNativeTexture(const IOSSceneTextureAsset& asset,
                        Tempest::BorrowedMetalDevice expectedDevice) noexcept {
  if(!asset.texture || !expectedDevice)
    return false;

  id<MTLTexture> texture =
      (id<MTLTexture>)(void*)asset.texture.get();
  id<MTLDevice> device =
      (id<MTLDevice>)(void*)expectedDevice.get();
  const auto& metadata = asset.metadata;
  const MTLPixelFormat expectedFormat =
      nativeTextureFormat(metadata.format);
  return texture!=nil &&
         texture.device==device &&
         texture.textureType==MTLTextureType2D &&
         texture.sampleCount==NSUInteger(1u) &&
         texture.depth==NSUInteger(1u) &&
         texture.arrayLength==NSUInteger(1u) &&
         (texture.usage&MTLTextureUsageShaderRead)==
             MTLTextureUsageShaderRead &&
         texture.width==NSUInteger(metadata.width) &&
         texture.height==NSUInteger(metadata.height) &&
         texture.mipmapLevelCount==NSUInteger(metadata.mipCount) &&
         expectedFormat!=MTLPixelFormatInvalid &&
         texture.pixelFormat==expectedFormat;
  }

struct NativeTextureValidationCache final {
  IOSWorldGeneration         generation;
  std::unordered_set<uint64_t> validatedHandles;
  };

bool validNativeTextureCached(
    NativeTextureValidationCache& cache,
    IOSWorldGeneration generation,
    IOSTextureHandle handle,
    const IOSSceneTextureAsset& asset,
    Tempest::BorrowedMetalDevice expectedDevice) {
  if(cache.generation!=generation) {
    cache.validatedHandles.clear();
    cache.generation = generation;
    }
  if(cache.validatedHandles.find(handle.value)!=
     cache.validatedHandles.end())
    return true;
  if(!validNativeTexture(asset,expectedDevice))
    return false;
  cache.validatedHandles.insert(handle.value);
  return true;
  }

IOSGPUSceneMeshCandidate candidate(
    const IOSSceneSnapshot& snapshot,
    const IOSSceneAssetRegistry& assets,
    NativeTextureValidationCache& textureValidation,
    const IOSRenderEntity& entity) {
  IOSGPUSceneMeshCandidate result;
  result.snapshotGeneration = snapshot.generation;
  result.registryGeneration = assets.generation();
  result.entity             = entity;

  if(const auto* material=findMaterial(snapshot,entity.material);
     material!=nullptr) {
    result.material    = *material;
    result.hasMaterial = true;

    if(const auto* texture=assets.lookupTexture(material->baseColorTexture);
       texture!=nullptr) {
      result.hasTexture       = true;
      result.hasNativeTexture = bool(texture->texture);
      result.hasSupportedTextureFormat =
          texture->metadata.format!=IOSSceneTextureFormat::Invalid;
      result.hasValidNativeTexture =
          validNativeTextureCached(
              textureValidation,snapshot.generation,
              material->baseColorTexture,*texture,assets.nativeDevice());
      result.textureWidth     = texture->metadata.width;
      result.textureHeight    = texture->metadata.height;
      result.textureMipCount  = texture->metadata.mipCount;
      }
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
    case IOSGPUSceneDrawPlanResult::MissingTexture:
      return IOSGPUScene::Result::MissingTexture;
    case IOSGPUSceneDrawPlanResult::InvalidTexture:
      return IOSGPUScene::Result::InvalidTexture;
    case IOSGPUSceneDrawPlanResult::MissingMesh:
      return IOSGPUScene::Result::MissingMesh;
    case IOSGPUSceneDrawPlanResult::InvalidMesh:
      return IOSGPUScene::Result::InvalidMesh;
    }
  return IOSGPUScene::Result::NativeEncodingFailed;
  }

IOSGPUScene::Report makeReport(IOSGPUScene::Result result,
                               uint64_t failingHandle = 0) noexcept {
  IOSGPUScene::Report report;
  report.result        = result;
  report.failingHandle = failingHandle;
  return report;
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
          [[NSString alloc]
              initWithBytes:RendererIOSShader::Landscape.data()
                     length:RendererIOSShader::Landscape.size()
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
      pipelineDesc.rasterSampleCount = NSUInteger(target.sampleCount);

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

      OwnedObjectiveC samplerDescriptor(
          [[MTLSamplerDescriptor alloc] init]);
      MTLSamplerDescriptor* samplerDesc =
          (MTLSamplerDescriptor*)samplerDescriptor.get();
      samplerDesc.minFilter             = MTLSamplerMinMagFilterLinear;
      samplerDesc.magFilter             = MTLSamplerMinMagFilterLinear;
      samplerDesc.mipFilter             = MTLSamplerMipFilterLinear;
      samplerDesc.sAddressMode          = MTLSamplerAddressModeRepeat;
      samplerDesc.tAddressMode          = MTLSamplerAddressModeRepeat;
      samplerDesc.rAddressMode          = MTLSamplerAddressModeRepeat;
      samplerDesc.maxAnisotropy         = 16u;
      samplerDesc.normalizedCoordinates = YES;
      samplerDesc.borderColor           = MTLSamplerBorderColorOpaqueWhite;
      samplerDesc.lodAverage            = NO;
      samplerDesc.supportArgumentBuffers = NO;
      OwnedObjectiveC samplerOwner(
          [device newSamplerStateWithDescriptor:samplerDesc]);
      if(samplerOwner.get()==nil)
        throw std::runtime_error(
          "RendererIOS IOSGPUScene sampler-state creation failed");

      pipelineState = pipelineOwner.relinquish();
      depthState    = depthOwner.relinquish();
      samplerState  = samplerOwner.relinquish();
      }
    }

  ~Impl() {
    [samplerState release];
    [depthState release];
    [pipelineState release];
    }

  Tempest::Device&                  owner;
  Tempest::BorrowedMetalDevice      nativeDevice;
  id                               pipelineState = nil;
  id                               depthState = nil;
  id                               samplerState = nil;
  NativeTextureValidationCache     textureValidation;
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
  [encoder setFragmentSamplerState:
      (id<MTLSamplerState>)context.scene->samplerState
                          atIndex:0u];

  const auto restoreEncoderState = [&]() {
    [encoder setFragmentTexture:nil atIndex:0u];
    [encoder setFragmentSamplerState:nil atIndex:0u];
    [encoder setDepthStencilState:nil];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFrontFacingWinding:MTLWindingClockwise];
    };

  uint32_t drawCount = 0;
  uint32_t texturedDrawCount = 0;
  for(const auto& entity:context.snapshot->entities) {
    const auto source = candidate(
        *context.snapshot,*context.assets,
        context.scene->textureValidation,entity);
    IOSGPUSceneDrawPlan plan;
    const auto planned =
        planIOSGPUSceneDraw(context.snapshot->currentCamera,source,plan);
    if(planned==IOSGPUSceneDrawPlanResult::SkippedVisibility)
      continue;
    if(planned!=IOSGPUSceneDrawPlanResult::Draw) {
      context.report.result        = resultForPlan(planned);
      context.report.failingHandle =
          iosGPUSceneFailingHandle(planned,source);
      restoreEncoderState();
      return;
      }

    const auto* mesh = context.assets->lookupMesh(entity.mesh);
    if(mesh==nullptr) {
      context.report.result        = IOSGPUScene::Result::MissingMesh;
      context.report.failingHandle = entity.mesh.value;
      restoreEncoderState();
      return;
      }

    const auto* texture =
        context.assets->lookupTexture(plan.baseColorTexture);
    if(texture==nullptr || !texture->texture) {
      context.report.result        = IOSGPUScene::Result::MissingTexture;
      context.report.failingHandle = plan.baseColorTexture.value;
      restoreEncoderState();
      return;
      }

    id<MTLBuffer> vertexBuffer =
        (id<MTLBuffer>)(void*)mesh->vertexBuffer.get();
    id<MTLBuffer> indexBuffer =
        (id<MTLBuffer>)(void*)mesh->indexBuffer.get();
    id<MTLTexture> baseColorTexture =
        (id<MTLTexture>)(void*)texture->texture.get();
    [encoder setVertexBuffer:vertexBuffer offset:0u atIndex:0u];
    [encoder setVertexBytes:&plan.constants
                     length:sizeof(plan.constants)
                    atIndex:1u];
    [encoder setFragmentTexture:baseColorTexture atIndex:0u];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:plan.indexCount
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:indexBuffer
                 indexBufferOffset:plan.indexBufferOffset
                     instanceCount:1u
                        baseVertex:0
                        baseInstance:0u];
    ++drawCount;
    ++texturedDrawCount;
    }

  restoreEncoderState();
  context.report.result    =
      drawCount!=0u ? IOSGPUScene::Result::Success
                    : IOSGPUScene::Result::Empty;
  context.report.drawCount         = drawCount;
  context.report.texturedDrawCount = texturedDrawCount;
  }

IOSGPUScene::IOSGPUScene(Tempest::Device& device, TargetLayout target)
  : impl(std::make_unique<Impl>(device,target)) {
  }

IOSGPUScene::~IOSGPUScene() = default;

IOSGPUScene::Report IOSGPUScene::encode(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSSceneSnapshot& snapshot,
    const IOSSceneAssetRegistry& assets) noexcept {
  if(impl==nullptr || impl->pipelineState==nil || impl->depthState==nil ||
     impl->samplerState==nil)
    return makeReport(Result::PipelineUnavailable);
  if(!assets.isInitialized() ||
     assets.state()!=IOSSceneAssetRegistryState::Active ||
     !assets.nativeDevice() ||
     assets.nativeDevice().get()!=impl->nativeDevice.get())
    return makeReport(Result::RegistryUnavailable);
  if(!snapshot.generation ||
     snapshot.generation!=assets.generation())
    return makeReport(Result::GenerationMismatch);

  uint32_t plannedDraws = 0;
  try {
    for(const auto& entity:snapshot.entities) {
      const auto source = candidate(
          snapshot,assets,impl->textureValidation,entity);
      IOSGPUSceneDrawPlan plan;
      const auto planned =
          planIOSGPUSceneDraw(snapshot.currentCamera,source,plan);
      if(planned==IOSGPUSceneDrawPlanResult::SkippedVisibility)
        continue;
      if(planned!=IOSGPUSceneDrawPlanResult::Draw)
        return makeReport(
            resultForPlan(planned),iosGPUSceneFailingHandle(planned,source));
      if(plannedDraws==std::numeric_limits<uint32_t>::max())
        return makeReport(Result::InvalidMesh,entity.mesh.value);
      ++plannedDraws;
      }
    }
  catch(...) {
    return makeReport(Result::NativeEncodingFailed);
    }
  if(plannedDraws==0u)
    return makeReport(Result::Empty);

  Impl::NativeEncodeContext context;
  context.scene    = impl.get();
  context.snapshot = &snapshot;
  context.assets   = &assets;
  context.report   = makeReport(Result::NativeEncodingFailed);
  try {
    const bool encoded = Tempest::MetalApi::withActiveRenderEncoder(
        impl->owner,encoder,&context,&Impl::encodeLandscape);
    if(!encoded)
      return makeReport(Result::NoActiveRenderEncoder);
    }
  catch(...) {
    return makeReport(Result::NativeEncodingFailed);
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
    case IOSGPUScene::Result::MissingTexture:
      return "missing-texture";
    case IOSGPUScene::Result::InvalidTexture:
      return "invalid-texture";
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
