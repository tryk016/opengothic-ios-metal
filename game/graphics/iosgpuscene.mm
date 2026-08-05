#include "iosgpuscene.h"

#include "iosgpusceneplan.h"
#include "ioslandscapeshaderabi.h"
#include "iossceneassetregistry.h"
#include "resources.h"

#include <Tempest/CommandBuffer>
#include <Tempest/Device>
#include <Tempest/Encoder>
#include <Tempest/Log>
#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
#include <crt_externs.h>
#endif

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <unordered_set>
#include <utility>
#include <vector>

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

    OwnedObjectiveC(OwnedObjectiveC&& other) noexcept
      : value(other.relinquish()) {
      }

    OwnedObjectiveC& operator=(OwnedObjectiveC&& other) noexcept {
      if(this==&other)
        return *this;
      [value release];
      value = other.relinquish();
      return *this;
      }

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

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
__attribute__((used,retain))
const std::array<std::string_view,3>
    IOSGPUSceneCausalArgumentBinaryContract = {
      IOSGPUSceneCausalModeArgument,
      IOSGPUSceneCausalNonceArgument,
      IOSGPUSceneCausalSequenceArgument,
    };
#endif

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
    case IOSGPUScene::ColorFormat::Rg11B10Float:
      return MTLPixelFormatRG11B10Float;
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

bool drawConstantsReflectionMatches(
    MTLRenderPipelineReflection* reflection) noexcept {
  if(reflection==nil || reflection.vertexBindings==nil)
    return false;

  NSUInteger matchingArguments = 0u;
  for(id<MTLBinding> binding in reflection.vertexBindings) {
    if(binding.index!=NSUInteger(1u))
      continue;
    ++matchingArguments;
    if(!binding.used || !binding.argument ||
       binding.type!=MTLBindingTypeBuffer)
      return false;
    id<MTLBufferBinding> buffer = (id<MTLBufferBinding>)binding;
    if(buffer.bufferDataSize!=sizeof(IOSGPUSceneDrawConstants) ||
       buffer.bufferAlignment!=alignof(IOSGPUSceneDrawConstants))
      return false;
    }
  return matchingArguments==NSUInteger(1u);
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
    case IOSGPUSceneDrawPlanResult::InvalidAlphaCutoff:
      return IOSGPUScene::Result::InvalidAlphaCutoff;
    case IOSGPUSceneDrawPlanResult::MissingAlphaTexture:
      return IOSGPUScene::Result::MissingAlphaTexture;
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

bool validSceneKind(IOSSceneMeshKind kind) noexcept {
  return kind==IOSSceneMeshKind::Landscape ||
         kind==IOSSceneMeshKind::Static ||
         kind==IOSSceneMeshKind::Movable;
  }

void recordFailure(uint64_t& counter,
                   IOSGPUScene::Report& report) noexcept {
  if(iosGPUSceneCheckedIncrement(counter))
    return;
  report.result = IOSGPUScene::Result::CountOverflow;
  report.failures.overflow = 1u;
  }

void recordPlanFailure(
    IOSGPUScene::Report& report,
    IOSGPUSceneDrawPlanResult result,
    const IOSGPUSceneMeshCandidate& source) noexcept {
  report.result        = resultForPlan(result);
  report.failingHandle = iosGPUSceneFailingHandle(result,source);
  switch(result) {
    case IOSGPUSceneDrawPlanResult::UnsupportedMaterial:
      recordFailure(report.failures.unknownCategory,report);
      return;
    case IOSGPUSceneDrawPlanResult::InvalidAlphaCutoff:
      recordFailure(report.failures.invalidCutoff,report);
      return;
    case IOSGPUSceneDrawPlanResult::MissingAlphaTexture:
      recordFailure(report.failures.missingAlphaTexture,report);
      return;
    case IOSGPUSceneDrawPlanResult::InvalidMesh:
      if(!validSceneKind(source.entity.kind))
        recordFailure(report.failures.unknownKind,report);
      return;
    case IOSGPUSceneDrawPlanResult::Draw:
    case IOSGPUSceneDrawPlanResult::SkippedVisibility:
    case IOSGPUSceneDrawPlanResult::GenerationMismatch:
    case IOSGPUSceneDrawPlanResult::MissingMaterial:
    case IOSGPUSceneDrawPlanResult::MissingTexture:
    case IOSGPUSceneDrawPlanResult::InvalidTexture:
    case IOSGPUSceneDrawPlanResult::MissingMesh:
      return;
    }
  }

bool recordCountFailure(
    IOSGPUSceneCountResult result,
    IOSGPUScene::Report& report) noexcept {
  switch(result) {
    case IOSGPUSceneCountResult::Recorded:
      return true;
    case IOSGPUSceneCountResult::UnknownCategory:
      report.result = IOSGPUScene::Result::UnsupportedMaterial;
      recordFailure(report.failures.unknownCategory,report);
      return false;
    case IOSGPUSceneCountResult::UnknownKind:
      report.result = IOSGPUScene::Result::InvalidMesh;
      recordFailure(report.failures.unknownKind,report);
      return false;
    case IOSGPUSceneCountResult::InconsistentCounts:
      report.result = IOSGPUScene::Result::CountMismatch;
      recordFailure(report.failures.plannedDrawn,report);
      return false;
    case IOSGPUSceneCountResult::Overflow:
      report.result = IOSGPUScene::Result::CountOverflow;
      recordFailure(report.failures.overflow,report);
      return false;
    }
  report.result = IOSGPUScene::Result::CountMismatch;
  recordFailure(report.failures.plannedDrawn,report);
  return false;
  }

void recordPlannedDrawnFailure(IOSGPUScene::Report& report) noexcept {
  if(report.counts.planned.material!=report.counts.drawn.material ||
     report.counts.planned.kind!=report.counts.drawn.kind)
    recordFailure(report.failures.plannedDrawn,report);
  }

}

struct IOSGPUScene::Impl final {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  struct NativeTargetDraw final {
    IOSGPUSceneDrawPlan plan;
    id                  pipelineState = nil;
    id                  vertexBuffer = nil;
    id                  indexBuffer = nil;
    id                  baseColorTexture = nil;
    OwnedObjectiveC     drawId;
    OwnedObjectiveC     drawBind;

    NativeTargetDraw() = default;
    NativeTargetDraw(const NativeTargetDraw&) = delete;
    NativeTargetDraw& operator=(const NativeTargetDraw&) = delete;
    NativeTargetDraw(NativeTargetDraw&&) noexcept = default;
    NativeTargetDraw& operator=(NativeTargetDraw&&) noexcept = default;
    };
#endif

  struct NativeEncodeContext final {
    Impl*                         scene = nullptr;
    const IOSSceneSnapshot*       snapshot = nullptr;
    const IOSSceneAssetRegistry*  assets = nullptr;
    IOSGPUSceneFrameAnimationTracker* frameAnimation = nullptr;
    IOSGPUSceneUVAnimationTracker* uvAnimation = nullptr;
    IOSGPUScene::Report           report;
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    IOSGPUSceneCausalFrameRoute    route =
        IOSGPUSceneCausalFrameRoute::Production;
    const std::vector<NativeTargetDraw>* targetDraws = nullptr;
    IOSGPUSceneFrameCounts         targetCounts;
    bool                           targetNativeCompleted = false;
    bool                           targetNativeException = false;
#endif
    };

  static void encodeLandscape(void* opaque,
                              MTL::RenderCommandEncoder* nativeEncoder);

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  void failCausal(uint64_t generation,
                  uint64_t sequence,
                  IOSGPUSceneCausalFailureReason reason) noexcept;
#endif

  Impl(Tempest::Device& owner, TargetLayout target)
    : owner(owner), nativeDevice(Tempest::MetalApi::borrowDevice(owner)) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    const int* const processArgumentCountAddress = _NSGetArgc();
    char*** const processArgumentVectorAddress = _NSGetArgv();
    const int processArgumentCount =
        processArgumentCountAddress!=nullptr
          ? *processArgumentCountAddress
          : -1;
    const char* const* processArgumentVector =
        processArgumentVectorAddress!=nullptr
          ? const_cast<const char* const*>(
                *processArgumentVectorAddress)
          : nullptr;
    IOSGPUSceneCausalArguments causalArguments;
    const IOSGPUSceneCausalArgumentResult parseResult =
        iosGPUSceneParseCausalArguments(
            processArgumentCount,processArgumentVector,
            causalArguments);
    if(parseResult!=IOSGPUSceneCausalArgumentResult::Accepted) {
      const IOSGPUSceneMarker marker =
          iosGPUSceneCausalParseFailMarker(
              iosGPUSceneCompiledMode(),parseResult);
      if(marker)
        Tempest::Log::e(marker.text.data());
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      return;
      }
    if(!iosGPUSceneInitializeCausalRuntime(
           causalArguments,causalState)) {
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      return;
      }
    causalArgumentsAccepted = true;
    const IOSGPUSceneMarker armed =
        iosGPUSceneCausalArmedMarker(causalState);
    if(!armed) {
      failCausal(
          0u,0u,
          IOSGPUSceneCausalFailureReason::MarkerPreflight);
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      return;
      }
    Tempest::Log::i(armed.text.data());
#endif
    if(!nativeDevice) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      failCausal(
          0u,0u,IOSGPUSceneCausalFailureReason::NativeEncode);
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      return;
#else
      throw std::invalid_argument(
        "RendererIOS IOSGPUScene requires the owning Tempest Metal device");
#endif
      }
    if(target.sampleCount!=1u) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      failCausal(
          0u,0u,
          IOSGPUSceneCausalFailureReason::PipelinePreflight);
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      return;
#else
      throw std::invalid_argument(
        "RendererIOS IOSGPUScene first slice supports one sample only");
#endif
      }

    @autoreleasepool {
      id<MTLDevice> device =
          (id<MTLDevice>)(void*)nativeDevice.get();
      const MTLPixelFormat colorFormat = nativeColorFormat(target.color);
      const MTLPixelFormat depthFormat = nativeDepthFormat(target.depth);

      OwnedObjectiveC libraryName(
          [[NSString alloc]
              initWithBytes:RendererIOSShader::LibraryName.data()
                     length:RendererIOSShader::LibraryName.size()
                                encoding:NSUTF8StringEncoding]);
      if(libraryName.get()==nil) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        failCausal(
            0u,0u,
            IOSGPUSceneCausalFailureReason::MarkerPreflight);
        initializationResult =
            IOSGPUScene::Result::NativeEncodingFailed;
        return;
#else
        throw std::runtime_error(
          "RendererIOS IOSGPUScene could not create its metallib resource name");
#endif
        }

      NSBundle* bundle = [NSBundle mainBundle];
      NSURL* libraryUrl =
          [bundle URLForResource:(NSString*)libraryName.get()
                   withExtension:@"metallib"];
      if(libraryUrl==nil) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        failCausal(
            0u,0u,
            IOSGPUSceneCausalFailureReason::PipelinePreflight);
        initializationResult =
            IOSGPUScene::Result::NativeEncodingFailed;
        return;
#else
        throw std::runtime_error(
          "RendererIOS IOSGPUScene could not find RendererIOS.metallib");
#endif
        }

      NSError* libraryError = nil;
      OwnedObjectiveC library(
          [device newLibraryWithURL:libraryUrl error:&libraryError]);
      if(library.get()==nil) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        failCausal(
            0u,0u,
            IOSGPUSceneCausalFailureReason::PipelinePreflight);
        initializationResult =
            IOSGPUScene::Result::NativeEncodingFailed;
        return;
#else
        throw std::runtime_error(
          metalFailure("RendererIOS IOSGPUScene metallib loading failed",
                       libraryError));
#endif
        }
      Tempest::Log::i(
        "RendererIOS shader library: source=offline-metallib resource=",
        RendererIOSShader::LibraryName,".metallib abi=",
        RendererIOSShader::AbiVersion);

      OwnedObjectiveC vertexName(
          [[NSString alloc]
              initWithBytes:RendererIOSShader::VertexFunction.data()
                     length:RendererIOSShader::VertexFunction.size()
                                encoding:NSUTF8StringEncoding]);
      OwnedObjectiveC fragmentName(
          [[NSString alloc]
              initWithBytes:RendererIOSShader::FragmentFunction.data()
                     length:RendererIOSShader::FragmentFunction.size()
                                encoding:NSUTF8StringEncoding]);
      OwnedObjectiveC alphaTestFragmentName(
          [[NSString alloc]
              initWithBytes:
                  RendererIOSShader::AlphaTestFragmentFunction.data()
                     length:
                  RendererIOSShader::AlphaTestFragmentFunction.size()
                                encoding:NSUTF8StringEncoding]);
      id<MTLLibrary> nativeLibrary = (id<MTLLibrary>)library.get();
      OwnedObjectiveC vertexFunction(
          [nativeLibrary newFunctionWithName:(NSString*)vertexName.get()]);
      OwnedObjectiveC fragmentFunction(
          [nativeLibrary newFunctionWithName:(NSString*)fragmentName.get()]);
      OwnedObjectiveC alphaTestFragmentFunction(
          [nativeLibrary
              newFunctionWithName:(NSString*)alphaTestFragmentName.get()]);
      if(!iosGPUSceneRequiredShaderFunctionsAreAvailable(
             vertexFunction.get()!=nil,
             fragmentFunction.get()!=nil,
             alphaTestFragmentFunction.get()!=nil)) {
        Tempest::Log::e(
          "RendererIOS IOSGPUScene initialization: "
          "result=pipeline-unavailable reason=missing-shader-function");
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        failCausal(
            0u,0u,
            IOSGPUSceneCausalFailureReason::PipelinePreflight);
        initializationResult =
            IOSGPUScene::Result::NativeEncodingFailed;
#endif
        return;
        }

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
      pipelineDesc.colorAttachments[0].blendingEnabled = NO;
      pipelineDesc.depthAttachmentPixelFormat      = depthFormat;
      pipelineDesc.rasterSampleCount = NSUInteger(target.sampleCount);
      pipelineDesc.alphaToCoverageEnabled = NO;
      pipelineDesc.alphaToOneEnabled      = NO;

      NSError* opaquePipelineError = nil;
      MTLRenderPipelineReflection* opaquePipelineReflection = nil;
      OwnedObjectiveC opaquePipelineOwner(
          [device newRenderPipelineStateWithDescriptor:pipelineDesc
                                               options:(
              MTLPipelineOptionBindingInfo |
              MTLPipelineOptionBufferTypeInfo)
                                            reflection:&opaquePipelineReflection
                                                 error:&opaquePipelineError]);
      const bool opaqueReflectionMatches =
          drawConstantsReflectionMatches(opaquePipelineReflection);
      if(opaquePipelineOwner.get()==nil || !opaqueReflectionMatches) {
        if(opaquePipelineOwner.get()==nil)
          Tempest::Log::e(
            metalFailure(
                "RendererIOS IOSGPUScene initialization: "
                "result=pipeline-unavailable reason=opaque-pso",
                opaquePipelineError));
        else
          Tempest::Log::e(
              "RendererIOS IOSGPUScene initialization: "
              "result=pipeline-unavailable "
              "reason=opaque-draw-constants-reflection");
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        failCausal(
            0u,0u,
            IOSGPUSceneCausalFailureReason::PipelinePreflight);
        initializationResult =
            IOSGPUScene::Result::NativeEncodingFailed;
#endif
        return;
        }

      pipelineDesc.fragmentFunction =
          (id<MTLFunction>)alphaTestFragmentFunction.get();
      NSError* alphaTestPipelineError = nil;
      MTLRenderPipelineReflection* alphaTestPipelineReflection = nil;
      OwnedObjectiveC alphaTestPipelineOwner(
          [device newRenderPipelineStateWithDescriptor:pipelineDesc
                                               options:(
              MTLPipelineOptionBindingInfo |
              MTLPipelineOptionBufferTypeInfo)
                                            reflection:&alphaTestPipelineReflection
                                                 error:&alphaTestPipelineError]);
      if(!iosGPUSceneProductionPipelineStatesAreAvailable(
             opaquePipelineOwner.get()!=nil,
             alphaTestPipelineOwner.get()!=nil) ||
         !drawConstantsReflectionMatches(alphaTestPipelineReflection)) {
        if(alphaTestPipelineOwner.get()==nil)
          Tempest::Log::e(
            metalFailure(
                "RendererIOS IOSGPUScene initialization: "
                "result=pipeline-unavailable reason=alpha-test-pso",
                alphaTestPipelineError));
        else
          Tempest::Log::e(
              "RendererIOS IOSGPUScene initialization: "
              "result=pipeline-unavailable "
              "reason=alpha-test-draw-constants-reflection");
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        failCausal(
            0u,0u,
            IOSGPUSceneCausalFailureReason::PipelinePreflight);
        initializationResult =
            IOSGPUScene::Result::NativeEncodingFailed;
#endif
        return;
        }

      OwnedObjectiveC depthDescriptor(
          [[MTLDepthStencilDescriptor alloc] init]);
      MTLDepthStencilDescriptor* depthDesc =
          (MTLDepthStencilDescriptor*)depthDescriptor.get();
      depthDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
      depthDesc.depthWriteEnabled    = YES;
      OwnedObjectiveC depthOwner(
          [device newDepthStencilStateWithDescriptor:depthDesc]);
      if(depthOwner.get()==nil) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        failCausal(
            0u,0u,
            IOSGPUSceneCausalFailureReason::PipelinePreflight);
        initializationResult =
            IOSGPUScene::Result::NativeEncodingFailed;
        return;
#else
        throw std::runtime_error(
          "RendererIOS IOSGPUScene depth-state creation failed");
#endif
        }

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
      if(samplerOwner.get()==nil) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        failCausal(
            0u,0u,
            IOSGPUSceneCausalFailureReason::PipelinePreflight);
        initializationResult =
            IOSGPUScene::Result::NativeEncodingFailed;
        return;
#else
        throw std::runtime_error(
          "RendererIOS IOSGPUScene sampler-state creation failed");
#endif
        }

      opaquePipelineState    = opaquePipelineOwner.relinquish();
      alphaTestPipelineState = alphaTestPipelineOwner.relinquish();
      depthState             = depthOwner.relinquish();
      samplerState           = samplerOwner.relinquish();
      initializationResult   = IOSGPUScene::Result::Success;
      }
    }

  ~Impl() {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(causalArgumentsAccepted &&
       causalState.phase==
           IOSGPUSceneCausalRuntimePhase::AwaitingTarget)
      failCausal(
          causalState.generation,causalState.lastSequence,
          IOSGPUSceneCausalFailureReason::TargetNotObserved);
#endif
    [samplerState release];
    [depthState release];
    [alphaTestPipelineState release];
    [opaquePipelineState release];
    }

  Tempest::Device&                  owner;
  Tempest::BorrowedMetalDevice      nativeDevice;
  id                               opaquePipelineState = nil;
  id                               alphaTestPipelineState = nil;
  id                               depthState = nil;
  id                               samplerState = nil;
  IOSGPUScene::Result              initializationResult =
      IOSGPUScene::Result::PipelineUnavailable;
  NativeTextureValidationCache     textureValidation;
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  IOSGPUSceneCausalRuntimeState     causalState;
  bool                              causalArgumentsAccepted = false;
#endif
  };

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
void IOSGPUScene::Impl::failCausal(
    uint64_t generation,
    uint64_t sequence,
    IOSGPUSceneCausalFailureReason reason) noexcept {
  if(!causalArgumentsAccepted ||
     !iosGPUSceneTransitionCausalFailure(causalState,reason))
    return;
  const IOSGPUSceneMarker marker =
      iosGPUSceneCausalFailMarker(
          causalState,generation,sequence,reason);
  if(marker)
    Tempest::Log::e(marker.text.data());
  }
#endif

void IOSGPUScene::Impl::encodeLandscape(
    void* opaque,
    MTL::RenderCommandEncoder* nativeEncoder) {
  if(opaque==nullptr)
    return;
  auto& context = *static_cast<NativeEncodeContext*>(opaque);
  if(context.scene==nullptr || context.snapshot==nullptr ||
     context.assets==nullptr || nativeEncoder==nullptr) {
    context.report.result = IOSGPUScene::Result::NativeEncodingFailed;
    recordFailure(context.report.failures.nativeEncode,context.report);
    recordPlannedDrawnFailure(context.report);
    return;
    }

  id<MTLRenderCommandEncoder> encoder =
      (id<MTLRenderCommandEncoder>)(void*)nativeEncoder;

  const auto restoreEncoderState = [&]() {
    [encoder setFragmentTexture:nil atIndex:0u];
    [encoder setFragmentSamplerState:nil atIndex:0u];
    [encoder setDepthStencilState:nil];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFrontFacingWinding:MTLWindingClockwise];
    };

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  if(context.route==IOSGPUSceneCausalFrameRoute::Target) {
    if(context.targetDraws==nullptr ||
       context.targetDraws->empty()) {
      context.report.result =
          IOSGPUScene::Result::NativeEncodingFailed;
      return;
      }
    @try {
      [encoder setDepthStencilState:
          (id<MTLDepthStencilState>)context.scene->depthState];
      [encoder setFrontFacingWinding:MTLWindingClockwise];
      [encoder setCullMode:MTLCullModeFront];
      [encoder setFragmentSamplerState:
          (id<MTLSamplerState>)context.scene->samplerState
                              atIndex:0u];
      for(const auto& draw:*context.targetDraws) {
        [encoder setVertexBuffer:
            (id<MTLBuffer>)draw.vertexBuffer
                         offset:0u
                        atIndex:0u];
        [encoder setVertexBytes:&draw.plan.constants
                         length:sizeof(draw.plan.constants)
                        atIndex:1u];
        [encoder setFragmentTexture:
            (id<MTLTexture>)draw.baseColorTexture
                               atIndex:0u];
        [encoder insertDebugSignpost:(NSString*)draw.drawId.get()];
        [encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];
        [encoder setRenderPipelineState:
            (id<MTLRenderPipelineState>)draw.pipelineState];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:draw.plan.indexCount
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:(id<MTLBuffer>)draw.indexBuffer
                     indexBufferOffset:draw.plan.indexBufferOffset
                         instanceCount:1u
                            baseVertex:0
                          baseInstance:0u];
        if(context.frameAnimation!=nullptr) {
          const auto animationRecorded =
              recordIOSGPUSceneFrameAnimationDraw(
                  *context.frameAnimation,
                  draw.plan.baseColorTexture);
          if(animationRecorded!=
                 IOSGPUSceneFrameAnimationRecordResult::IgnoredStatic &&
             animationRecorded!=
                 IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated) {
            restoreEncoderState();
            context.report.result =
                IOSGPUScene::Result::AnimationEvidenceMismatch;
            context.report.failingHandle =
                draw.plan.baseColorTexture.value;
            return;
            }
          }
        if(context.uvAnimation!=nullptr) {
          const auto uvAnimationRecorded =
              recordIOSGPUSceneUVAnimationDraw(
                  *context.uvAnimation,draw.plan);
          if(uvAnimationRecorded!=
                 IOSGPUSceneUVAnimationRecordResult::IgnoredStatic &&
             uvAnimationRecorded!=
                 IOSGPUSceneUVAnimationRecordResult::RecordedUvOnly &&
             uvAnimationRecorded!=
                 IOSGPUSceneUVAnimationRecordResult::RecordedFrameAndUv) {
            restoreEncoderState();
            context.report.result =
                IOSGPUScene::Result::AnimationEvidenceMismatch;
            context.report.failingHandle =
                draw.plan.baseColorTexture.value;
            return;
            }
          }
        }
      restoreEncoderState();
      if(context.frameAnimation!=nullptr &&
         !finalizeIOSGPUSceneFrameAnimationDrawReport(
             *context.frameAnimation,
             context.report.frameAnimation)) {
        context.report.result =
            IOSGPUScene::Result::AnimationEvidenceMismatch;
        return;
        }
      if(context.uvAnimation!=nullptr &&
         !finalizeIOSGPUSceneUVAnimationDrawReport(
             *context.uvAnimation,
             context.report.uvAnimation)) {
        context.report.result =
            IOSGPUScene::Result::AnimationEvidenceMismatch;
        return;
        }
      context.report.counts = context.targetCounts;
      context.report.drawCount =
          context.targetCounts.drawn.material.total;
      context.report.texturedDrawCount =
          context.targetCounts.drawn.texturedDraws;
      context.report.result = IOSGPUScene::Result::Success;
      context.targetNativeCompleted = true;
      }
    @catch(NSException* exception) {
      (void)exception;
      context.targetNativeException = true;
      context.report.result =
          IOSGPUScene::Result::NativeEncodingFailed;
      }
    return;
    }
#endif

  [encoder setDepthStencilState:
      (id<MTLDepthStencilState>)context.scene->depthState];
  [encoder setFrontFacingWinding:MTLWindingClockwise];
  [encoder setCullMode:MTLCullModeFront];
  [encoder setFragmentSamplerState:
      (id<MTLSamplerState>)context.scene->samplerState
                          atIndex:0u];

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
      recordPlanFailure(context.report,planned,source);
      recordPlannedDrawnFailure(context.report);
      restoreEncoderState();
      return;
      }

    const auto* mesh = context.assets->lookupMesh(entity.mesh);
    if(mesh==nullptr) {
      context.report.result        = IOSGPUScene::Result::MissingMesh;
      context.report.failingHandle = entity.mesh.value;
      recordPlannedDrawnFailure(context.report);
      restoreEncoderState();
      return;
      }

    const auto* texture =
        context.assets->lookupTexture(plan.baseColorTexture);
    if(texture==nullptr || !texture->texture) {
      context.report.result =
          plan.materialCategory==IOSMaterialCategory::AlphaTest
            ? IOSGPUScene::Result::MissingAlphaTexture
            : IOSGPUScene::Result::MissingTexture;
      context.report.failingHandle = plan.baseColorTexture.value;
      if(plan.materialCategory==IOSMaterialCategory::AlphaTest)
        recordFailure(
            context.report.failures.missingAlphaTexture,context.report);
      recordPlannedDrawnFailure(context.report);
      restoreEncoderState();
      return;
      }

    if(!iosGPUScenePipelineSelectionMatches(
           plan.materialCategory,plan.pipeline)) {
      context.report.result = IOSGPUScene::Result::SelectorMismatch;
      context.report.failingHandle = entity.material.value;
      recordFailure(context.report.failures.selectorMismatch,context.report);
      recordPlannedDrawnFailure(context.report);
      restoreEncoderState();
      return;
      }

    id<MTLRenderPipelineState> pipelineState = nil;
    IOSGPUSceneFrameCounts nextCounts = context.report.counts;
    if(!recordCountFailure(
           recordIOSGPUSceneDrawCount(
               plan.materialCategory,plan.kind,
               plan.usesFallbackTexture,true,nextCounts.drawn),
           context.report)) {
      recordPlannedDrawnFailure(context.report);
      restoreEncoderState();
      return;
      }
    switch(plan.pipeline) {
      case IOSGPUScenePipelineSelector::Opaque:
        pipelineState =
            (id<MTLRenderPipelineState>)
                context.scene->opaquePipelineState;
        if(!iosGPUSceneCheckedIncrement(nextCounts.opaquePsoBinds)) {
          context.report.result = IOSGPUScene::Result::CountOverflow;
          recordFailure(context.report.failures.overflow,context.report);
          recordPlannedDrawnFailure(context.report);
          restoreEncoderState();
          return;
          }
        break;
      case IOSGPUScenePipelineSelector::AlphaTest:
        pipelineState =
            (id<MTLRenderPipelineState>)
                context.scene->alphaTestPipelineState;
        if(!iosGPUSceneCheckedIncrement(nextCounts.alphaPsoBinds)) {
          context.report.result = IOSGPUScene::Result::CountOverflow;
          recordFailure(context.report.failures.overflow,context.report);
          recordPlannedDrawnFailure(context.report);
          restoreEncoderState();
          return;
          }
        break;
      case IOSGPUScenePipelineSelector::Unsupported:
        context.report.result = IOSGPUScene::Result::SelectorMismatch;
        context.report.failingHandle = entity.material.value;
        recordFailure(
            context.report.failures.selectorMismatch,context.report);
        recordPlannedDrawnFailure(context.report);
        restoreEncoderState();
        return;
      }
    if(pipelineState==nil) {
      context.report.result = IOSGPUScene::Result::PipelineUnavailable;
      context.report.failingHandle = entity.material.value;
      recordFailure(context.report.failures.psoUnavailable,context.report);
      recordPlannedDrawnFailure(context.report);
      restoreEncoderState();
      return;
      }

    id<MTLBuffer> vertexBuffer =
        (id<MTLBuffer>)(void*)mesh->vertexBuffer.get();
    id<MTLBuffer> indexBuffer =
        (id<MTLBuffer>)(void*)mesh->indexBuffer.get();
    id<MTLTexture> baseColorTexture =
        (id<MTLTexture>)(void*)texture->texture.get();
    [encoder setRenderPipelineState:pipelineState];
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
    if(context.frameAnimation!=nullptr) {
      const auto animationRecorded =
          recordIOSGPUSceneFrameAnimationDraw(
              *context.frameAnimation,plan.baseColorTexture);
      if(animationRecorded!=
             IOSGPUSceneFrameAnimationRecordResult::IgnoredStatic &&
         animationRecorded!=
             IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated) {
        context.report.result =
            IOSGPUScene::Result::AnimationEvidenceMismatch;
        context.report.failingHandle = plan.baseColorTexture.value;
        restoreEncoderState();
        return;
        }
      }
    if(context.uvAnimation!=nullptr) {
      const auto uvAnimationRecorded =
          recordIOSGPUSceneUVAnimationDraw(
              *context.uvAnimation,plan);
      if(uvAnimationRecorded!=
             IOSGPUSceneUVAnimationRecordResult::IgnoredStatic &&
         uvAnimationRecorded!=
             IOSGPUSceneUVAnimationRecordResult::RecordedUvOnly &&
         uvAnimationRecorded!=
             IOSGPUSceneUVAnimationRecordResult::RecordedFrameAndUv) {
        context.report.result =
            IOSGPUScene::Result::AnimationEvidenceMismatch;
        context.report.failingHandle = plan.baseColorTexture.value;
        restoreEncoderState();
        return;
        }
      }
    context.report.counts = nextCounts;
    context.report.drawCount =
        context.report.counts.drawn.material.total;
    context.report.texturedDrawCount =
        context.report.counts.drawn.texturedDraws;
    }

  restoreEncoderState();
  if(!iosGPUSceneProductionReportCountsAreConsistent(
         context.report.counts,context.report.failures)) {
    context.report.result = IOSGPUScene::Result::CountMismatch;
    recordFailure(context.report.failures.plannedDrawn,context.report);
    return;
    }
  if(context.uvAnimation!=nullptr &&
     !finalizeIOSGPUSceneUVAnimationDrawReport(
         *context.uvAnimation,context.report.uvAnimation)) {
    context.report.result =
        IOSGPUScene::Result::AnimationEvidenceMismatch;
    return;
    }
  if(context.frameAnimation!=nullptr &&
     !finalizeIOSGPUSceneFrameAnimationDrawReport(
         *context.frameAnimation,context.report.frameAnimation)) {
    context.report.result =
        IOSGPUScene::Result::AnimationEvidenceMismatch;
    return;
    }
  context.report.result =
      context.report.counts.drawn.material.total!=0u
        ? IOSGPUScene::Result::Success
        : IOSGPUScene::Result::Empty;
  }

IOSGPUScene::IOSGPUScene(Tempest::Device& device, TargetLayout target)
  : impl(std::make_unique<Impl>(device,target)) {
  }

IOSGPUScene::~IOSGPUScene() = default;

bool IOSGPUScene::pipelinesReady() const noexcept {
  return impl!=nullptr &&
         impl->initializationResult==IOSGPUScene::Result::Success;
  }

IOSGPUScene::Report IOSGPUScene::encode(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSSceneSnapshot& snapshot,
    const IOSSceneAssetRegistry& assets,
    const IOSFrameAnimationEvidence* frameAnimation,
    const IOSUVAnimationEvidence* uvAnimation) noexcept {
  Report report = makeReport(Result::NativeEncodingFailed);
  if(impl==nullptr) {
    report.result = Result::PipelineUnavailable;
    recordFailure(report.failures.psoUnavailable,report);
    return report;
    }
  if(impl->initializationResult!=Result::Success) {
    report.result = impl->initializationResult;
    if(report.result==Result::NativeEncodingFailed)
      recordFailure(report.failures.nativeEncode,report);
    else
      recordFailure(report.failures.psoUnavailable,report);
    return report;
    }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  const uint64_t causalGeneration = snapshot.generation.value;
  const uint64_t causalSequence = snapshot.sequence.value;
  const auto causalFailure = [&](
      IOSGPUSceneCausalFailureReason reason) {
    Report failure = makeReport(Result::NativeEncodingFailed);
    recordFailure(failure.failures.nativeEncode,failure);
    impl->failCausal(causalGeneration,causalSequence,reason);
    return failure;
    };
  IOSGPUSceneCausalFrameRoute causalRoute =
      IOSGPUSceneCausalFrameRoute::Production;
  IOSGPUSceneCausalRuntimeState causalPrepared =
      impl->causalState;
  const IOSGPUSceneCausalFrameResult causalObservation =
      iosGPUScenePrepareCausalObservation(
          impl->causalState,causalGeneration,causalSequence,
          causalRoute,causalPrepared);
  if(causalObservation!=IOSGPUSceneCausalFrameResult::Prepared)
    return causalFailure(
        iosGPUSceneCausalFailureReasonForFrameResult(
            causalObservation));
#endif

  if(!assets.isInitialized() ||
     assets.state()!=IOSSceneAssetRegistryState::Active ||
     !assets.nativeDevice() ||
     assets.nativeDevice().get()!=impl->nativeDevice.get()) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::AssetPreflight);
#endif
    return makeReport(Result::RegistryUnavailable);
    }
  if(!snapshot.generation ||
     snapshot.generation!=assets.generation()) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::AssetPreflight);
#endif
    return makeReport(Result::GenerationMismatch);
    }

  IOSGPUSceneFrameAnimationTracker frameAnimationTracker;
  const bool trackFrameAnimation = frameAnimation!=nullptr;
  if(trackFrameAnimation &&
     !prepareIOSGPUSceneFrameAnimationTracker(
         *frameAnimation,snapshot.generation,
         frameAnimationTracker))
    return makeReport(Result::AnimationEvidenceMismatch);
  IOSGPUSceneUVAnimationTracker uvAnimationTracker;
  const bool trackUVAnimation = uvAnimation!=nullptr;
  if(trackUVAnimation &&
     !prepareIOSGPUSceneUVAnimationTracker(
         *uvAnimation,snapshot.generation,uvAnimationTracker))
    return makeReport(Result::AnimationEvidenceMismatch);

  try {
    for(const auto& entity:snapshot.entities) {
      const auto source = candidate(
          snapshot,assets,impl->textureValidation,entity);
      IOSGPUSceneDrawPlan plan;
      const auto planned =
          planIOSGPUSceneDraw(snapshot.currentCamera,source,plan);
      if(planned==IOSGPUSceneDrawPlanResult::SkippedVisibility)
        continue;
      if(planned!=IOSGPUSceneDrawPlanResult::Draw) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::PlanPreflight);
#endif
        recordPlanFailure(report,planned,source);
        return report;
        }
      if(!recordCountFailure(
             recordIOSGPUSceneDrawCount(
                 plan.materialCategory,plan.kind,
                 plan.usesFallbackTexture,false,report.counts.planned),
             report)) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::PlanPreflight);
#endif
        return report;
        }
      }
    }
  catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::PlanPreflight);
#endif
    report.result = Result::NativeEncodingFailed;
    recordFailure(report.failures.nativeEncode,report);
    return report;
    }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  if(causalRoute==IOSGPUSceneCausalFrameRoute::Target &&
     report.counts.planned.material.alphaTest==0u)
    return causalFailure(
        IOSGPUSceneCausalFailureReason::MissingAlphaTestDraw);
#endif

  if(report.counts.planned.material.total==0u) {
    if(trackFrameAnimation &&
       !finalizeIOSGPUSceneFrameAnimationDrawReport(
           frameAnimationTracker,report.frameAnimation)) {
      report.result = Result::AnimationEvidenceMismatch;
      return report;
      }
    if(trackUVAnimation &&
       !finalizeIOSGPUSceneUVAnimationDrawReport(
           uvAnimationTracker,report.uvAnimation)) {
      report.result = Result::AnimationEvidenceMismatch;
      return report;
      }
    report.result = Result::Empty;
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    IOSGPUSceneCausalRuntimeState committed;
    if(!iosGPUSceneCommitCausalPreparation(
           impl->causalState,causalPrepared,causalRoute,
           report.counts,0u,0u,false,false,true,committed))
      return causalFailure(
          IOSGPUSceneCausalFailureReason::EquationsPreflight);
    impl->causalState = committed;
#endif
    return report;
    }
  if(impl->opaquePipelineState==nil ||
     impl->alphaTestPipelineState==nil ||
     impl->depthState==nil ||
     impl->samplerState==nil) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::PipelinePreflight);
#endif
    report.result = Result::PipelineUnavailable;
    recordFailure(report.failures.psoUnavailable,report);
    recordPlannedDrawnFailure(report);
    return report;
    }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  std::vector<Impl::NativeTargetDraw> targetDraws;
  IOSGPUSceneFrameCounts targetCounts = report.counts;
  uint64_t targetOrdinal = 0u;
  IOSGPUSceneMarker targetEncodedMarker;
  if(causalRoute==IOSGPUSceneCausalFrameRoute::Target) {
    try {
      if(report.counts.planned.material.total>
         std::numeric_limits<std::size_t>::max())
        return causalFailure(
            IOSGPUSceneCausalFailureReason::OrdinalPreflight);
      targetDraws.reserve(
          static_cast<std::size_t>(
              report.counts.planned.material.total));
      for(const auto& entity:snapshot.entities) {
        const auto source = candidate(
            snapshot,assets,impl->textureValidation,entity);
        IOSGPUSceneDrawPlan plan;
        const IOSGPUSceneDrawPlanResult planned =
            planIOSGPUSceneDraw(
                snapshot.currentCamera,source,plan);
        if(planned==IOSGPUSceneDrawPlanResult::SkippedVisibility)
          continue;
        if(planned!=IOSGPUSceneDrawPlanResult::Draw)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::PlanPreflight);

        const auto* mesh = assets.lookupMesh(entity.mesh);
        const auto* texture =
            assets.lookupTexture(plan.baseColorTexture);
        if(mesh==nullptr || texture==nullptr ||
           !mesh->vertexBuffer || !mesh->indexBuffer ||
           !texture->texture)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::AssetPreflight);

        IOSGPUSceneDrawDispatch dispatch;
        if(recordIOSGPUSceneDrawDispatchForRoute(
               causalRoute,plan.materialCategory,plan.kind,
               plan.usesFallbackTexture,true,plan.pipeline,
               targetCounts,dispatch)!=
           IOSGPUSceneDrawDispatchResult::Recorded)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::DispatchPreflight);

        id<MTLRenderPipelineState> effectivePipeline = nil;
        switch(dispatch.effective) {
          case IOSGPUScenePipelineSelector::Opaque:
            effectivePipeline =
                (id<MTLRenderPipelineState>)
                    impl->opaquePipelineState;
            break;
          case IOSGPUScenePipelineSelector::AlphaTest:
            effectivePipeline =
                (id<MTLRenderPipelineState>)
                    impl->alphaTestPipelineState;
            break;
          case IOSGPUScenePipelineSelector::Unsupported:
            break;
          }
        id<MTLBuffer> vertexBuffer =
            (id<MTLBuffer>)(void*)mesh->vertexBuffer.get();
        id<MTLBuffer> indexBuffer =
            (id<MTLBuffer>)(void*)mesh->indexBuffer.get();
        id<MTLTexture> baseColorTexture =
            (id<MTLTexture>)(void*)texture->texture.get();
        if(effectivePipeline==nil || vertexBuffer==nil ||
           indexBuffer==nil || baseColorTexture==nil)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::PipelinePreflight);

        uint64_t ordinal = 0u;
        if(!iosGPUSceneTakeNextCausalDrawOrdinal(
               targetOrdinal,ordinal))
          return causalFailure(
              IOSGPUSceneCausalFailureReason::OrdinalPreflight);
        IOSGPUSceneCausalDrawIdentity identity;
        if(makeIOSGPUSceneCausalDrawIdentity(
               causalPrepared.arguments.nonce.data(),
               causalGeneration,causalSequence,ordinal,dispatch,
               plan.kind,plan.baseColorTexture.value,
               entity.mesh.value,plan.indexCount,identity)!=
           IOSGPUSceneCausalDrawIdentityResult::Created)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::IdentityPreflight);
        const IOSGPUSceneMarker drawId =
            iosGPUSceneCausalDrawIdSignpost(identity);
        const IOSGPUSceneMarker drawBind =
            iosGPUSceneCausalDrawBindSignpost(identity);
        if(!drawId || !drawBind)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::MarkerPreflight);

        Impl::NativeTargetDraw draw;
        draw.plan = plan;
        draw.pipelineState = effectivePipeline;
        draw.vertexBuffer = vertexBuffer;
        draw.indexBuffer = indexBuffer;
        draw.baseColorTexture = baseColorTexture;
        draw.drawId = OwnedObjectiveC(
            [[NSString alloc]
                initWithBytes:drawId.text.data()
                       length:drawId.length
                     encoding:NSUTF8StringEncoding]);
        draw.drawBind = OwnedObjectiveC(
            [[NSString alloc]
                initWithBytes:drawBind.text.data()
                       length:drawBind.length
                     encoding:NSUTF8StringEncoding]);
        if(draw.drawId.get()==nil || draw.drawBind.get()==nil)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::MarkerPreflight);
        targetDraws.emplace_back(std::move(draw));
        }
      }
    catch(...) {
      return causalFailure(
          IOSGPUSceneCausalFailureReason::NativeException);
      }
    if(!iosGPUSceneCausalPreparationIsValid(
           causalPrepared,causalRoute,targetCounts,
           static_cast<uint64_t>(targetDraws.size()),
           targetOrdinal,true,true,true))
      return causalFailure(
          IOSGPUSceneCausalFailureReason::EquationsPreflight);
    IOSGPUSceneCausalRuntimeState encodedPreview =
        causalPrepared;
    encodedPreview.phase =
        IOSGPUSceneCausalRuntimePhase::TargetEncoded;
    targetEncodedMarker = iosGPUSceneCausalEncodedMarker(
        encodedPreview,targetCounts.drawn.material.total,
        targetCounts.drawn.material.alphaTest);
    if(!targetEncodedMarker)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::MarkerPreflight);
    }
#endif

  Impl::NativeEncodeContext context;
  context.scene    = impl.get();
  context.snapshot = &snapshot;
  context.assets   = &assets;
  context.frameAnimation =
      trackFrameAnimation ? &frameAnimationTracker : nullptr;
  context.uvAnimation =
      trackUVAnimation ? &uvAnimationTracker : nullptr;
  context.report   = report;
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  context.route = causalRoute;
  if(causalRoute==IOSGPUSceneCausalFrameRoute::Target) {
    context.targetDraws = &targetDraws;
    context.targetCounts = targetCounts;
    }
#endif
  try {
    const bool encoded = Tempest::MetalApi::withActiveRenderEncoder(
        impl->owner,encoder,&context,&Impl::encodeLandscape);
    if(!encoded) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
        return causalFailure(
            IOSGPUSceneCausalFailureReason::NoActiveRenderEncoder);
#endif
      context.report.result = Result::NoActiveRenderEncoder;
      recordFailure(
          context.report.failures.nativeEncode,context.report);
      recordPlannedDrawnFailure(context.report);
      return context.report;
      }
    }
  catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::NativeException);
#endif
    context.report.result = Result::NativeEncodingFailed;
    recordFailure(
        context.report.failures.nativeEncode,context.report);
    recordPlannedDrawnFailure(context.report);
    return context.report;
    }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  if(causalRoute==IOSGPUSceneCausalFrameRoute::Target) {
    if(context.targetNativeException)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::NativeException);
    if(!context.targetNativeCompleted ||
       context.report.result!=Result::Success)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::NativeEncode);
    IOSGPUSceneCausalRuntimeState committed;
    if(!iosGPUSceneCommitCausalPreparation(
           impl->causalState,causalPrepared,causalRoute,
           context.report.counts,
           static_cast<uint64_t>(targetDraws.size()),
           targetOrdinal,true,true,
           iosGPUSceneFailureCountsAreClear(
               context.report.failures),
           committed))
      return causalFailure(
          IOSGPUSceneCausalFailureReason::EquationsPreflight);
    impl->causalState = committed;
    Tempest::Log::i(targetEncodedMarker.text.data());
    return context.report;
    }
  if(context.report.result==Result::Success ||
     context.report.result==Result::Empty) {
    IOSGPUSceneCausalRuntimeState committed;
    if(!iosGPUSceneCommitCausalPreparation(
           impl->causalState,causalPrepared,causalRoute,
           context.report.counts,
           context.report.counts.drawn.material.total,
           0u,false,false,
           iosGPUSceneFailureCountsAreClear(
               context.report.failures),
           committed))
      return causalFailure(
          IOSGPUSceneCausalFailureReason::EquationsPreflight);
    impl->causalState = committed;
    }
#endif
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
    case IOSGPUScene::Result::InvalidAlphaCutoff:
      return "invalid-alpha-cutoff";
    case IOSGPUScene::Result::MissingAlphaTexture:
      return "missing-alpha-texture";
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
    case IOSGPUScene::Result::SelectorMismatch:
      return "selector-mismatch";
    case IOSGPUScene::Result::CountOverflow:
      return "count-overflow";
    case IOSGPUScene::Result::CountMismatch:
      return "count-mismatch";
    case IOSGPUScene::Result::AnimationEvidenceMismatch:
      return "animation-evidence-mismatch";
    case IOSGPUScene::Result::NativeEncodingFailed:
      return "native-encoding-failed";
    }
  return "unknown";
  }
