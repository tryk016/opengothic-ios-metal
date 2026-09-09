#include "iosgpuscene.h"
#include "iosupscaler.h"
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
#include "iosraytracing.h"
#endif

#include "ioslinearhdrproofproducer.h"
#include "iosmultiply2coverageproof.h"

#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)
#include "iosadditiveinputartifact.h"
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
#include "iosmultiply2inputartifact.h"
#endif
#include "iosgpusceneplan.h"
#include "ioslandscapeshaderabi.h"
#include "iossceneassetregistry.h"
#include "iosscenelighting.h"
#include "resources.h"

#include <Tempest/CommandBuffer>
#include <Tempest/Device>
#include <Tempest/Encoder>
#include <Tempest/Attachment>
#include <Tempest/Log>
#include <Tempest/MetalApi>
#include <Tempest/Texture2d>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
#include <crt_externs.h>
#endif

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <tuple>
#include <unordered_set>
#include <utility>
#include <vector>

#if __has_feature(objc_arc)
#error "IOSGPUScene requires the project's non-ARC Objective-C++ mode"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC) && \
    !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) && \
    !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
#error "Multiply2 GPU visibility diagnostic requires a Multiply2 causal A/B build"
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

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A)
constexpr std::string_view IOSGPUSceneMultiply2Mode = "multiply2-a-hdr";
__attribute__((used,retain))
const char IOSGPUSceneMultiply2BinaryContract[] =
    "RIOS_MULTIPLY2_CAUSAL_MODE=multiply2-a-hdr";
#elif defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
constexpr std::string_view IOSGPUSceneMultiply2Mode = "multiply2-b-hdr";
__attribute__((used,retain))
const char IOSGPUSceneMultiply2BinaryContract[] =
    "RIOS_MULTIPLY2_CAUSAL_MODE=multiply2-b-hdr";
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)
#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A)
constexpr std::string_view IOSGPUSceneAdditiveMode = "additive-a-hdr";
constexpr char IOSGPUSceneAdditiveModeLeaf = 'a';
__attribute__((used,retain))
const char IOSGPUSceneAdditiveBinaryContract[] =
    "RIOS_ADDITIVE_CAUSAL_MODE=additive-a-hdr";
#else
constexpr std::string_view IOSGPUSceneAdditiveMode = "additive-b-hdr";
constexpr char IOSGPUSceneAdditiveModeLeaf = 'b';
__attribute__((used,retain))
const char IOSGPUSceneAdditiveBinaryContract[] =
    "RIOS_ADDITIVE_CAUSAL_MODE=additive-b-hdr";
#endif
constexpr std::string_view IOSGPUSceneAdditiveArgumentPrefix =
    "-renderer-ios-additive-causal-mode=";

bool iosGPUSceneAdditiveArgumentsAccepted() noexcept {
  const int* countAddress = _NSGetArgc();
  char*** vectorAddress = _NSGetArgv();
  if(countAddress==nullptr || vectorAddress==nullptr ||
     *vectorAddress==nullptr || *countAddress<1)
    return false;
  const char* const* arguments =
      const_cast<const char* const*>(*vectorAddress);
  std::size_t matching = 0u;
  for(int index=1; index<*countAddress; ++index) {
    if(arguments[index]==nullptr)
      return false;
    const std::string_view argument(arguments[index]);
    if(!argument.starts_with(IOSGPUSceneAdditiveArgumentPrefix))
      continue;
    if(argument.substr(IOSGPUSceneAdditiveArgumentPrefix.size())!=
       IOSGPUSceneAdditiveMode)
      return false;
    ++matching;
    }
  return matching==1u;
  }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
constexpr std::string_view IOSGPUSceneMultiply2ArgumentPrefix =
    "-renderer-ios-multiply2-causal-mode=";

bool iosGPUSceneMultiply2ArgumentsAccepted() noexcept {
  const int* countAddress = _NSGetArgc();
  char*** vectorAddress = _NSGetArgv();
  if(countAddress==nullptr || vectorAddress==nullptr ||
     *vectorAddress==nullptr || *countAddress<1)
    return false;
  const char* const* arguments =
      const_cast<const char* const*>(*vectorAddress);
  std::size_t matching = 0u;
  for(int index=1; index<*countAddress; ++index) {
    if(arguments[index]==nullptr)
      return false;
    const std::string_view argument(arguments[index]);
    if(!argument.starts_with(IOSGPUSceneMultiply2ArgumentPrefix))
      continue;
    if(argument.substr(IOSGPUSceneMultiply2ArgumentPrefix.size())!=
       IOSGPUSceneMultiply2Mode)
      return false;
    ++matching;
    }
  return matching==1u;
  }
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
    case IOSGPUScene::DepthFormat::Depth32FloatStencil8:
      return MTLPixelFormatDepth32Float_Stencil8;
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
    if(!iosGPUSceneDrawConstantsReflectionLayoutMatches(
           buffer.bufferDataSize,buffer.bufferAlignment))
      return false;
    }
  return matchingArguments==NSUInteger(1u);
  }

bool lightingReflectionMatches(MTLRenderPipelineReflection* reflection) {
  for(id<MTLBinding> binding in reflection.fragmentBindings)
    if(binding.index==0 && binding.type==MTLBindingTypeBuffer)
      return ((id<MTLBufferBinding>)binding).bufferDataSize==sizeof(IOSSceneLightingConstants);
  return false;
  }

std::string drawConstantsReflectionDetails(
    MTLRenderPipelineReflection* reflection) {
  if(reflection==nil)
    return "reflection=nil";
  if(reflection.vertexBindings==nil)
    return "vertex-bindings=nil";

  std::string result = "vertex-bindings=" +
      std::to_string(reflection.vertexBindings.count);
  for(id<MTLBinding> binding in reflection.vertexBindings) {
    result += " [index=" + std::to_string(binding.index) +
              " used=" + std::to_string(binding.used ? 1u : 0u) +
              " argument=" + std::to_string(binding.argument ? 1u : 0u) +
              " type=" + std::to_string(binding.type);
    if(binding.type==MTLBindingTypeBuffer) {
      id<MTLBufferBinding> buffer = (id<MTLBufferBinding>)binding;
      result += " bytes=" + std::to_string(buffer.bufferDataSize) +
                " alignment=" + std::to_string(buffer.bufferAlignment);
      }
    result += "]";
    }
  return result;
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
         kind==IOSSceneMeshKind::Movable ||
         kind==IOSSceneMeshKind::Animated ||
         kind==IOSSceneMeshKind::Morph;
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

struct IOSDeformationConstants final {
  uint32_t boneOffset = 0;
  uint32_t morphOffset = 0;
  uint32_t morphCount = 0;
  float fatness = 0.f;
  };
static_assert(sizeof(IOSDeformationConstants)==16);
static_assert(sizeof(IOSMorphLayer)==20);
static_assert(sizeof(Resources::VertexA)==92);

struct alignas(16) IOSGPUInstance final {
  IOSMatrix4x4 model;
  IOSFloat4 baseColor;
  IOSFloat2 uvOffset;
  float fatness = 0.f;
  uint32_t landscape = 0;
  };
static_assert(sizeof(IOSGPUInstance)==96);

struct alignas(16) IOSMotionInstance final {
  IOSMatrix4x4 model;
  float fatness = 0.f;
  };
static_assert(sizeof(IOSMotionInstance)==80);

struct alignas(16) IOSMotionConstants final {
  IOSMatrix4x4 previousModel, previousViewProjection;
  IOSFloat4 jitter, extent;
  float previousFatness = 0.f;
  };
static_assert(sizeof(IOSMotionConstants)==176);

struct IOSParticlePreparedBatch final {
  IOSParticleBatch batch;
  id texture = nil;
  };

struct alignas(16) IOSParticleCameraConstants final {
  IOSMatrix4x4 viewProjection, view;
  IOSFloat4 left, top, depth;
  };
static_assert(sizeof(IOSParticleCameraConstants)==176);

struct IOSGPUSceneNativePreparedDraw final {
  IOSGPUSceneDrawPlan plan;
  IOSDeformationConstants deformation;
  id deformationBuffer = nil;
  id previousDeformationBuffer = nil;
  IOSMatrix4x4 previousTransform;
  float previousFatness = 0.f;
  id morphIndices = nil;
  id morphSamples = nil;
  id tessellationFactors = nil;
  size_t tessellationOffset = 0;
  id instanceBuffer = nil;
  id previousInstanceBuffer = nil;
  size_t instanceOffset = 0;
  size_t instanceCount = 1;
  float cameraDepth = 0.f;
  uint64_t sourceId = 0;
  bool metal4Eligible = false;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
  IOSMultiply2VisibilityClipClass visibilityClipClass =
      IOSMultiply2VisibilityClipClass::Indeterminate;
#endif
  id                  pipelineState = nil;
  id                  vertexBuffer = nil;
  id                  indexBuffer = nil;
  id                  baseColorTexture = nil;
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
  OwnedObjectiveC     drawId;
  OwnedObjectiveC     drawBind;
#endif

  IOSGPUSceneNativePreparedDraw() = default;
  IOSGPUSceneNativePreparedDraw(const IOSGPUSceneNativePreparedDraw&) = delete;
  IOSGPUSceneNativePreparedDraw& operator=(
      const IOSGPUSceneNativePreparedDraw&) = delete;
  IOSGPUSceneNativePreparedDraw(
      IOSGPUSceneNativePreparedDraw&&) noexcept = default;
  IOSGPUSceneNativePreparedDraw& operator=(
      IOSGPUSceneNativePreparedDraw&&) noexcept = default;
  };

void bindGeometry(id<MTLRenderCommandEncoder> encoder,
                  const IOSGPUSceneNativePreparedDraw& draw) {
  [encoder setVertexBuffer:(id<MTLBuffer>)draw.vertexBuffer offset:0 atIndex:0];
  [encoder setVertexBytes:&draw.plan.constants length:sizeof(draw.plan.constants) atIndex:1];
  [encoder setVertexBytes:&draw.deformation length:sizeof(draw.deformation) atIndex:2];
  if(draw.instanceCount>1)
    [encoder setVertexBuffer:(id<MTLBuffer>)draw.instanceBuffer offset:draw.instanceOffset atIndex:6];
  if(draw.plan.kind==IOSSceneMeshKind::Animated || draw.plan.kind==IOSSceneMeshKind::Morph)
    [encoder setVertexBuffer:(id<MTLBuffer>)draw.deformationBuffer offset:0 atIndex:3];
  if(draw.plan.kind==IOSSceneMeshKind::Morph) {
    [encoder setVertexBuffer:(id<MTLBuffer>)draw.morphIndices offset:0 atIndex:4];
    [encoder setVertexBuffer:(id<MTLBuffer>)draw.morphSamples offset:0 atIndex:5];
    }
  }


bool materializeReportMarkers(
    uint64_t generation, uint64_t sequence,
    IOSGPUScene::Report& report) noexcept {
  report.markers = {
      iosGPUSceneIdentityMarker(generation,sequence),
      iosGPUSceneMaterialPlannedMarker(report.counts),
      iosGPUSceneMaterialDrawnMarker(report.counts),
      iosGPUSceneKindPlannedMarker(report.counts),
      iosGPUSceneKindDrawnMarker(report.counts),
      iosGPUSceneAlphaMarker(report.counts),
      iosGPUSceneAdditiveMarker(report.counts),
      iosGPUSceneFailContractMarker(report.failures),
      iosGPUSceneFailSelectorMarker(report.failures),
      iosGPUSceneFailExecutionMarker(report.failures),
      };
  report.markersReady = std::all_of(
      report.markers.begin(),report.markers.end(),
      [](const IOSGPUSceneMarker& marker) noexcept {
        return bool(marker);
        });
  return report.markersReady;
  }

template<class Animation>
bool emissiveArtifactAnimation(
    IOSTextureHandle selectedTexture,
    const IOSFrameAnimationEvidence* frameAnimation,
    const IOSUVAnimationEvidence* uvAnimation,
    Animation& output) noexcept {
  const IOSFrameAnimationSelection* frame = nullptr;
  if(frameAnimation!=nullptr) {
    for(const auto& selection:frameAnimation->selections) {
      if(selection.selectedHandle!=selectedTexture)
        continue;
      if(frame!=nullptr)
        return false;
      frame = &selection;
      }
    }
  const IOSUVAnimationSelection* uv = nullptr;
  if(uvAnimation!=nullptr) {
    for(const auto& selection:uvAnimation->selections) {
      if(selection.selectedHandle!=selectedTexture)
        continue;
      if(uv!=nullptr)
        return false;
      uv = &selection;
      }
    }
  if(frame!=nullptr && uv!=nullptr)
    return false;
  if(frame!=nullptr) {
    output = Animation::FrameOnly;
    return true;
    }
  if(uv!=nullptr) {
    if(uv->mode==IOSSceneTextureAnimationMode::UvOnly)
      output = Animation::UvOnly;
    else if(uv->mode==IOSSceneTextureAnimationMode::FrameAndUv)
      output = Animation::FrameAndUv;
    else
      return false;
    return true;
    }
  output = Animation::None;
  return true;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)
bool additiveArtifactTextureFormat(
    IOSSceneTextureFormat value,
    IOSAdditiveInputTextureFormat& output) noexcept {
  switch(value) {
    case IOSSceneTextureFormat::Rgba8Unorm:
      output = IOSAdditiveInputTextureFormat::Rgba8Unorm;
      return true;
    case IOSSceneTextureFormat::Bc1Rgba:
      output = IOSAdditiveInputTextureFormat::Bc1Rgba;
      return true;
    case IOSSceneTextureFormat::Bc2Rgba:
      output = IOSAdditiveInputTextureFormat::Bc2Rgba;
      return true;
    case IOSSceneTextureFormat::Bc3Rgba:
      output = IOSAdditiveInputTextureFormat::Bc3Rgba;
      return true;
    case IOSSceneTextureFormat::Invalid:
      return false;
    }
  return false;
  }

bool additiveArtifactKind(
    IOSSceneMeshKind value, IOSAdditiveInputKind& output) noexcept {
  switch(value) {
    case IOSSceneMeshKind::Landscape:
      output = IOSAdditiveInputKind::Landscape;
      return true;
    case IOSSceneMeshKind::Static:
      output = IOSAdditiveInputKind::Static;
      return true;
    case IOSSceneMeshKind::Movable:
      output = IOSAdditiveInputKind::Movable;
      return true;
    case IOSSceneMeshKind::Animated:
    case IOSSceneMeshKind::Morph:
    case IOSSceneMeshKind::Unsupported:
      return false;
    }
  return false;
  }

bool additiveArtifactCategory(
    IOSMaterialCategory value,
    IOSAdditiveInputCategory& output) noexcept {
  switch(value) {
    case IOSMaterialCategory::Opaque:
      output = IOSAdditiveInputCategory::Opaque;
      return true;
    case IOSMaterialCategory::AlphaTest:
      output = IOSAdditiveInputCategory::AlphaTest;
      return true;
    case IOSMaterialCategory::Additive:
      output = IOSAdditiveInputCategory::Additive;
      return true;
    case IOSMaterialCategory::Multiply2:
    case IOSMaterialCategory::Transparent:
    case IOSMaterialCategory::Water:
    case IOSMaterialCategory::Ghost:
    case IOSMaterialCategory::Multiply:
      return false;
    }
  return false;
  }

bool makeAdditiveArtifactRecord(
    const IOSRenderEntity& entity,
    const IOSGPUSceneDrawPlan& plan,
    const IOSSceneMeshAsset& mesh,
    const IOSSceneTextureAsset& texture,
    const IOSFrameAnimationEvidence* frameAnimation,
    const IOSUVAnimationEvidence* uvAnimation,
    IOSAdditiveInputRecordV1& output) noexcept {
  static_assert(sizeof(std::size_t)<=sizeof(uint64_t));
  static_assert(sizeof(IOSGPUSceneDrawConstants)==
                IOSAdditiveInputV1ConstantsBytes);
  static_assert(std::is_trivially_copyable_v<IOSGPUSceneDrawConstants>);
  IOSAdditiveInputRecordV1 record;
  record.sourceId = entity.id.value;
  record.meshId = entity.mesh.value;
  record.materialId = entity.material.value;
  record.textureId = plan.baseColorTexture.value;
  record.indexByteOffset = static_cast<uint64_t>(plan.indexBufferOffset);
  record.indexCount = static_cast<uint64_t>(plan.indexCount);
  record.vertexBufferBytes =
      static_cast<uint64_t>(mesh.metadata.vertexBufferByteSize);
  record.indexBufferBytes =
      static_cast<uint64_t>(mesh.metadata.indexBufferByteSize);
  record.materialFlags = plan.materialFlags;
  record.vertexStride = static_cast<uint32_t>(mesh.metadata.vertexStride);
  record.textureWidth = texture.metadata.width;
  record.textureHeight = texture.metadata.height;
  record.textureMipCount = texture.metadata.mipCount;
  if(!additiveArtifactTextureFormat(
         texture.metadata.format,record.textureFormat) ||
     !additiveArtifactKind(plan.kind,record.kind) ||
     !additiveArtifactCategory(plan.materialCategory,record.category) ||
     !emissiveArtifactAnimation(
         plan.baseColorTexture,frameAnimation,uvAnimation,record.animation))
    return false;
  std::memcpy(record.constants.data(),&plan.constants,
              sizeof(plan.constants));
  output = record;
  return true;
  }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
bool makeMultiply2ArtifactRecord(
    const IOSRenderEntity& entity,
    const IOSGPUSceneDrawPlan& plan,
    const IOSSceneMeshAsset& mesh,
    const IOSSceneTextureAsset& texture,
    const IOSFrameAnimationEvidence* frameAnimation,
    const IOSUVAnimationEvidence* uvAnimation,
    IOSMultiply2InputRecordV1& output) noexcept {
  static_assert(sizeof(IOSGPUSceneDrawConstants)==
                IOSMultiply2InputV1ConstantsBytes);
  IOSMultiply2InputRecordV1 record;
  record.sourceId = entity.id.value;
  record.meshId = entity.mesh.value;
  record.materialId = entity.material.value;
  record.textureId = plan.baseColorTexture.value;
  record.indexByteOffset = static_cast<uint64_t>(plan.indexBufferOffset);
  record.indexCount = static_cast<uint64_t>(plan.indexCount);
  record.vertexBufferBytes =
      static_cast<uint64_t>(mesh.metadata.vertexBufferByteSize);
  record.indexBufferBytes =
      static_cast<uint64_t>(mesh.metadata.indexBufferByteSize);
  record.materialFlags = plan.materialFlags;
  record.vertexStride = static_cast<uint32_t>(mesh.metadata.vertexStride);
  record.textureWidth = texture.metadata.width;
  record.textureHeight = texture.metadata.height;
  record.textureMipCount = texture.metadata.mipCount;
  switch(texture.metadata.format) {
    case IOSSceneTextureFormat::Rgba8Unorm:
      record.textureFormat = IOSMultiply2InputTextureFormat::Rgba8Unorm;
      break;
    case IOSSceneTextureFormat::Bc1Rgba:
      record.textureFormat = IOSMultiply2InputTextureFormat::Bc1Rgba;
      break;
    case IOSSceneTextureFormat::Bc2Rgba:
      record.textureFormat = IOSMultiply2InputTextureFormat::Bc2Rgba;
      break;
    case IOSSceneTextureFormat::Bc3Rgba:
      record.textureFormat = IOSMultiply2InputTextureFormat::Bc3Rgba;
      break;
    case IOSSceneTextureFormat::Invalid:
      return false;
    }
  switch(plan.kind) {
    case IOSSceneMeshKind::Landscape:
      record.kind = IOSMultiply2InputKind::Landscape;
      break;
    case IOSSceneMeshKind::Static:
      record.kind = IOSMultiply2InputKind::Static;
      break;
    case IOSSceneMeshKind::Movable:
      record.kind = IOSMultiply2InputKind::Movable;
      break;
    case IOSSceneMeshKind::Animated:
    case IOSSceneMeshKind::Morph:
    case IOSSceneMeshKind::Unsupported:
      return false;
    }
  switch(plan.materialCategory) {
    case IOSMaterialCategory::Opaque:
      record.category = IOSMultiply2InputCategory::Opaque;
      record.phase = IOSMultiply2InputPhase::Base;
      break;
    case IOSMaterialCategory::AlphaTest:
      record.category = IOSMultiply2InputCategory::AlphaTest;
      record.phase = IOSMultiply2InputPhase::Base;
      break;
    case IOSMaterialCategory::Multiply2:
      record.category = IOSMultiply2InputCategory::Multiply2;
      record.phase = IOSMultiply2InputPhase::Multiply2;
      break;
    case IOSMaterialCategory::Additive:
    case IOSMaterialCategory::Transparent:
    case IOSMaterialCategory::Water:
    case IOSMaterialCategory::Ghost:
    case IOSMaterialCategory::Multiply:
      return false;
  }
  if(!emissiveArtifactAnimation(
       plan.baseColorTexture,frameAnimation,uvAnimation,record.animation))
    return false;
  std::memcpy(record.constants.data(),&plan.constants,sizeof(plan.constants));
  if(iosValidateMultiply2InputRecordV1(record)!=
     IOSMultiply2InputArtifactError::None)
    return false;
  output = record;
  return true;
  }
#endif

}

struct IOSGPUScene::PreparedFrame::Uploads final {
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
  IOSRayTracing::Frame rays;
#endif
  OwnedObjectiveC bones;
  OwnedObjectiveC morphLayers;
  OwnedObjectiveC instances;
  OwnedObjectiveC previousBones, previousMorphLayers, previousInstances;
  OwnedObjectiveC lights;
  OwnedObjectiveC tessellationFactors;
  OwnedObjectiveC particles;
#if defined(OPENGOTHIC_RENDERER_IOS_METAL4)
  OwnedObjectiveC metal4Uniforms;
#endif

  static id<MTLBuffer> reserve(id<MTLDevice> device, OwnedObjectiveC& storage, size_t size) {
    auto buffer = (id<MTLBuffer>)storage.get();
    if(buffer==nil || buffer.length<size) {
      storage = OwnedObjectiveC([device newBufferWithLength:size options:MTLResourceStorageModeShared]);
      if(storage.get()==nil)
        throw std::bad_alloc();
      buffer = (id<MTLBuffer>)storage.get();
      }
    return buffer;
    }

  static void write(id<MTLDevice> device, OwnedObjectiveC& storage,
                    const void* bytes, size_t size) {
    if(size!=0)
      std::memcpy(reserve(device,storage,size).contents,bytes,size);
    }
  };

struct IOSGPUScene::PreparedFrame::Impl final {
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
  IOSRayTracing::Frame* rays = nullptr;
  int rayTracingMode = 0;
#endif
  const void* owner = nullptr;
  std::vector<IOSGPUSceneNativePreparedDraw> base;
  std::vector<IOSGPUSceneNativePreparedDraw> multiply2;
  std::vector<IOSGPUSceneNativePreparedDraw> additive;
  std::vector<IOSGPUSceneNativePreparedDraw> transparent;
  std::vector<IOSGPUSceneNativePreparedDraw> water, ghost, multiply;
  std::array<std::vector<IOSGPUSceneNativePreparedDraw>,2> shadows;
  std::array<std::vector<IOSParticlePreparedBatch>,8> particles;
  IOSParticleCameraConstants particleCamera;
  id particleBuffer = nil;

  bool needsSceneCopy() const noexcept {
    return !water.empty() || !ghost.empty() || !particles[size_t(IOSMaterialCategory::Ghost)].empty();
    }
  IOSSceneLightingConstants lighting;
  id lightBuffer = nil;
  std::array<id,6> skyImages = {};
  IOSFloat4 cloudOffsets;
  IOSMatrix4x4 viewProjection;
  bool skyReady = false;
#if defined(OPENGOTHIC_RENDERER_IOS_METAL4)
  OwnedObjectiveC metal4VertexTable, metal4FragmentTable, metal4Residency;
  id metal4Uniforms = nil;
#endif
  IOSGPUScene::Report report;
  IOSGPUScene::AdditiveInputArtifact additiveInput;
  IOSGPUScene::Multiply2InputArtifact multiply2Input;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
  IOSGPUSceneMultiply2DrawIdentity multiply2DrawIdentity;
  bool multiply2DrawIdentityReady = false;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  IOSGPUSceneCausalFrameRoute causalRoute =
      IOSGPUSceneCausalFrameRoute::Production;
  IOSGPUSceneCausalRuntimeState causalPrepared;
  IOSGPUSceneMarker targetEncodedMarker;
  uint64_t targetOrdinal = 0u;
#endif
  bool nativeCompleted = false;
  bool nativeBaseMultiplyCompleted = false;
  bool nativeAdditiveCompleted = false;
  bool nativeException = false;
  bool ready = false;

  void markNativeBaseMultiplyCompleted() noexcept {
    nativeBaseMultiplyCompleted = true;
    }

  void markNativeAdditiveCompleted() noexcept {
    nativeAdditiveCompleted = true;
    }

  void markNativeException() noexcept {
    nativeException = true;
    }
  };

struct IOSGPUScene::Impl final {
  struct NativeEncodeContext final {
    Impl*                    scene = nullptr;
    PreparedFrame::Impl*     prepared = nullptr;
    IOSGPUScene::Report      report;
    uint8_t                  phase = 0u;
    id sceneHDR = nil;
    std::string_view sceneMarker;
    const SceneOutput* output = nullptr;
    // Prefix and suffix preserve the base draw order around one Metal 4 run.
    uint8_t segment = 0;
    size_t metal4Begin = 0, metal4End = 0;
    };

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
  enum class NativeMultiply2EncodeMode : uint8_t {
    CaptureProof,
    Continuation,
    };

  struct NativeMultiply2Context final {
    explicit NativeMultiply2Context(
        NativeMultiply2EncodeMode requestedMode) noexcept
      : mode(requestedMode) {
      }

    const NativeMultiply2EncodeMode mode;
    Impl* scene = nullptr;
    PreparedFrame::Impl* prepared = nullptr;
    id sceneHDR = nil;
    id hdrProofBuffer = nil;
    id depthStencil = nil;
    id coverageBuffer = nil;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
    id visibilityResultBuffer = nil;
#endif
    uint32_t width = 0u;
    uint32_t height = 0u;
    uint32_t hdrBytesPerRow = 0u;
    uint32_t coverageBytesPerRow = 0u;
    std::string_view sceneMarker;
    std::string_view proofMarker;
    IOSGPUScene::Report report;
    bool succeeded = false;
    };

  static void encodeMultiply2(
      void* opaque, MTL::CommandBuffer* nativeCommandBuffer);
  IOSGPUScene::Report runMultiply2(
      Tempest::Encoder<Tempest::CommandBuffer>& encoder,
      NativeMultiply2Context& context) noexcept;
  bool continuationDepthStencilForSceneHDR(
      id sceneHDR, id& depthStencil,
      uint32_t& width, uint32_t& height) noexcept;
#endif

  static void encodeLandscape(void* opaque,
                              MTL::RenderCommandEncoder* nativeEncoder);
  static void encodeScene(void* opaque, MTL::CommandBuffer* command);
#if defined(OPENGOTHIC_RENDERER_IOS_METAL4)
  bool prepareMetal4(NativeEncodeContext& context, PreparedFrame::Uploads& uploads);
  static bool encodeMetal4(void* opaque, MTL::CommandBuffer* prefix, void* body, MTL::CommandBuffer* suffix);
#endif
  bool initializeMotion(id<MTLDevice> device, id<MTLLibrary> library, MTLVertexDescriptor* vertices);
  bool encodeMotion(id<MTLCommandBuffer> command, const PreparedFrame::Impl& prepared,
                    const IOSSceneSnapshot& snapshot);
  bool encodeWaterFactors(id<MTLCommandBuffer> command, const PreparedFrame::Impl& prepared);
  void ensureSceneTargets(id<MTLTexture> color, const PreparedFrame::Impl& prepared);
  bool encodeShadows(id<MTLCommandBuffer> command, PreparedFrame::Impl& prepared);
  void bindLighting(id<MTLRenderCommandEncoder> encoder, const PreparedFrame::Impl& prepared);
  void encodeParticles(id<MTLRenderCommandEncoder> encoder, const PreparedFrame::Impl& prepared,
                       IOSMaterialCategory material, int shadow = -1);
  bool encodeSkyLut(id<MTLCommandBuffer> command, const PreparedFrame::Impl& prepared);
  void encodeSky(id<MTLRenderCommandEncoder> encoder, const PreparedFrame::Impl& prepared);
  void encodeRain(id<MTLRenderCommandEncoder> encoder, const PreparedFrame::Impl& prepared);

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  void failCausal(uint64_t generation,
                  uint64_t sequence,
                  IOSGPUSceneCausalFailureReason reason) noexcept;
#endif

  Impl(Tempest::Device& owner, TargetLayout target)
    : owner(owner), nativeDevice(Tempest::MetalApi::borrowDevice(owner)) {
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
    if(!iosGPUSceneMultiply2ArgumentsAccepted()) {
      Tempest::Log::e(
          "RendererIOS multiply2 causal: v=1 mode=",
          IOSGPUSceneMultiply2Mode,
          " terminal=F class=contract reason=launch-argument");
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      emissiveTerminalReported = true;
      return;
      }
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)
    if(!iosGPUSceneAdditiveArgumentsAccepted()) {
      Tempest::Log::e(
          "RendererIOS additive causal: v=1 mode=",
          IOSGPUSceneAdditiveMode,
          " terminal=F class=contract reason=launch-argument");
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      emissiveTerminalReported = true;
      return;
      }
#endif
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
    if(target.color!=IOSGPUScene::ColorFormat::Rg11B10Float ||
       target.sampleCount!=1u
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
       || target.depth!=IOSGPUScene::DepthFormat::Depth32FloatStencil8
#endif
       ) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      failCausal(
          0u,0u,
          IOSGPUSceneCausalFailureReason::PipelinePreflight);
      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;
      return;
#else
      throw std::invalid_argument(
        "RendererIOS IOSGPUScene requires one-sample RG11B10Float");
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
      OwnedObjectiveC additiveFragmentName(
          [[NSString alloc]
              initWithBytes:
                  RendererIOSShader::AdditiveFragmentFunction.data()
                     length:
                  RendererIOSShader::AdditiveFragmentFunction.size()
                                encoding:NSUTF8StringEncoding]);
      id<MTLLibrary> nativeLibrary = (id<MTLLibrary>)library.get();
      OwnedObjectiveC vertexFunction(
          [nativeLibrary newFunctionWithName:(NSString*)vertexName.get()]);
      OwnedObjectiveC fragmentFunction(
          [nativeLibrary newFunctionWithName:(NSString*)fragmentName.get()]);
      OwnedObjectiveC alphaTestFragmentFunction(
          [nativeLibrary
              newFunctionWithName:(NSString*)alphaTestFragmentName.get()]);
      OwnedObjectiveC additiveFragmentFunction(
          [nativeLibrary
              newFunctionWithName:(NSString*)additiveFragmentName.get()]);
      if(!iosGPUSceneRequiredShaderFunctionsAreAvailable(
             vertexFunction.get()!=nil,
             fragmentFunction.get()!=nil,
             alphaTestFragmentFunction.get()!=nil,
             additiveFragmentFunction.get()!=nil)) {
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
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
      pipelineDesc.stencilAttachmentPixelFormat    = depthFormat;
#endif
      pipelineDesc.rasterSampleCount = NSUInteger(target.sampleCount);
      pipelineDesc.alphaToCoverageEnabled = NO;
      pipelineDesc.alphaToOneEnabled      = NO;
      pipelineDesc.label = @"RendererIOS.Static.Opaque";

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
          drawConstantsReflectionMatches(opaquePipelineReflection) &&
          lightingReflectionMatches(opaquePipelineReflection);
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
              "reason=opaque-draw-constants-reflection ",
              drawConstantsReflectionDetails(opaquePipelineReflection));
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
      pipelineDesc.label = @"RendererIOS.Static.AlphaTest";
      NSError* alphaTestPipelineError = nil;
      MTLRenderPipelineReflection* alphaTestPipelineReflection = nil;
      OwnedObjectiveC alphaTestPipelineOwner(
          [device newRenderPipelineStateWithDescriptor:pipelineDesc
                                               options:(
              MTLPipelineOptionBindingInfo |
              MTLPipelineOptionBufferTypeInfo)
                                            reflection:&alphaTestPipelineReflection
                                                 error:&alphaTestPipelineError]);
      if(alphaTestPipelineOwner.get()==nil ||
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

      pipelineDesc.label = @"RendererIOS.Static.Additive";
      pipelineDesc.fragmentFunction =
          (id<MTLFunction>)additiveFragmentFunction.get();
      MTLRenderPipelineColorAttachmentDescriptor* additiveColor =
          pipelineDesc.colorAttachments[0];
      additiveColor.blendingEnabled = YES;
#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)
      additiveColor.sourceRGBBlendFactor = MTLBlendFactorZero;
#else
      additiveColor.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
#endif
      additiveColor.destinationRGBBlendFactor = MTLBlendFactorOne;
      additiveColor.rgbBlendOperation = MTLBlendOperationAdd;
      additiveColor.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
      additiveColor.destinationAlphaBlendFactor = MTLBlendFactorOne;
      additiveColor.alphaBlendOperation = MTLBlendOperationAdd;
      NSError* additivePipelineError = nil;
      MTLRenderPipelineReflection* additivePipelineReflection = nil;
      OwnedObjectiveC additivePipelineOwner(
          [device newRenderPipelineStateWithDescriptor:pipelineDesc
                                               options:(
              MTLPipelineOptionBindingInfo |
              MTLPipelineOptionBufferTypeInfo)
                                            reflection:&additivePipelineReflection
                                                 error:&additivePipelineError]);
      if(!iosGPUSceneInitialPipelineStatesAreAvailable(
             opaquePipelineOwner.get()!=nil,
             alphaTestPipelineOwner.get()!=nil,
             additivePipelineOwner.get()!=nil) ||
         !drawConstantsReflectionMatches(additivePipelineReflection)) {
        if(additivePipelineOwner.get()==nil)
          Tempest::Log::e(
            metalFailure(
                "RendererIOS IOSGPUScene initialization: "
                "result=pipeline-unavailable reason=additive-pso",
                additivePipelineError));
        else
          Tempest::Log::e(
              "RendererIOS IOSGPUScene initialization: "
              "result=pipeline-unavailable "
              "reason=additive-draw-constants-reflection");
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

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
      additiveColor.sourceRGBBlendFactor = MTLBlendFactorZero;
#else
      additiveColor.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;
#endif
      pipelineDesc.label = @"RendererIOS.Static.Multiply2";
      additiveColor.destinationRGBBlendFactor = MTLBlendFactorSourceColor;
      additiveColor.rgbBlendOperation = MTLBlendOperationAdd;
      additiveColor.sourceAlphaBlendFactor = MTLBlendFactorDestinationColor;
      additiveColor.destinationAlphaBlendFactor = MTLBlendFactorSourceColor;
      additiveColor.alphaBlendOperation = MTLBlendOperationAdd;
      NSError* multiply2PipelineError = nil;
      MTLRenderPipelineReflection* multiply2PipelineReflection = nil;
      OwnedObjectiveC multiply2PipelineOwner(
          [device newRenderPipelineStateWithDescriptor:pipelineDesc
                                               options:(
              MTLPipelineOptionBindingInfo |
              MTLPipelineOptionBufferTypeInfo)
                                            reflection:&multiply2PipelineReflection
                                                 error:&multiply2PipelineError]);
      if(!iosGPUSceneProductionPipelineStatesAreAvailable(
             opaquePipelineOwner.get()!=nil,
             alphaTestPipelineOwner.get()!=nil,
             additivePipelineOwner.get()!=nil,
             multiply2PipelineOwner.get()!=nil) ||
         !drawConstantsReflectionMatches(multiply2PipelineReflection)) {
        if(multiply2PipelineOwner.get()==nil)
          Tempest::Log::e(
            metalFailure(
                "RendererIOS IOSGPUScene initialization: "
                "result=pipeline-unavailable reason=multiply2-pso",
                multiply2PipelineError));
        else
          Tempest::Log::e(
              "RendererIOS IOSGPUScene initialization: "
              "result=pipeline-unavailable "
              "reason=multiply2-draw-constants-reflection");
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

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      additiveColor.writeMask = MTLColorWriteMaskNone;
      additiveColor.blendingEnabled = NO;
      pipelineDesc.label = @"RendererIOS.Static.Multiply2.Visibility.v1";
      NSError* visibilityPipelineError = nil;
      MTLRenderPipelineReflection* visibilityPipelineReflection = nil;
      OwnedObjectiveC visibilityPipelineOwner(
          [device newRenderPipelineStateWithDescriptor:pipelineDesc
                                               options:(
              MTLPipelineOptionBindingInfo |
              MTLPipelineOptionBufferTypeInfo)
                                            reflection:&visibilityPipelineReflection
                                                 error:&visibilityPipelineError]);
      if(visibilityPipelineOwner.get()==nil ||
         !drawConstantsReflectionMatches(visibilityPipelineReflection)) {
        if(visibilityPipelineOwner.get()==nil)
          Tempest::Log::e(
            metalFailure(
                "RendererIOS IOSGPUScene initialization: "
                "result=pipeline-unavailable reason=multiply2-visibility-pso",
                visibilityPipelineError));
        else
          Tempest::Log::e(
              "RendererIOS IOSGPUScene initialization: "
              "result=pipeline-unavailable "
              "reason=multiply2-visibility-draw-constants-reflection");
        return;
        }
#endif

      OwnedObjectiveC depthDescriptor(
          [[MTLDepthStencilDescriptor alloc] init]);
      MTLDepthStencilDescriptor* depthDesc =
          (MTLDepthStencilDescriptor*)depthDescriptor.get();
      depthDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
      depthDesc.depthWriteEnabled    = YES;
      OwnedObjectiveC depthOwner(
          [device newDepthStencilStateWithDescriptor:depthDesc]);
      depthDesc.depthWriteEnabled = NO;
      OwnedObjectiveC additiveDepthOwner(
          [device newDepthStencilStateWithDescriptor:depthDesc]);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
      OwnedObjectiveC stencilDescriptor(
          [[MTLStencilDescriptor alloc] init]);
      MTLStencilDescriptor* stencilDesc =
          (MTLStencilDescriptor*)stencilDescriptor.get();
      stencilDesc.stencilCompareFunction = MTLCompareFunctionAlways;
      stencilDesc.stencilFailureOperation = MTLStencilOperationKeep;
      stencilDesc.depthFailureOperation = MTLStencilOperationKeep;
      stencilDesc.depthStencilPassOperation = MTLStencilOperationReplace;
      stencilDesc.readMask = 0xffu;
      stencilDesc.writeMask = 0xffu;
      depthDesc.frontFaceStencil = stencilDesc;
      depthDesc.backFaceStencil = stencilDesc;
#endif
      OwnedObjectiveC multiply2DepthOwner(
          [device newDepthStencilStateWithDescriptor:depthDesc]);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      depthDesc.depthCompareFunction = MTLCompareFunctionAlways;
      depthDesc.depthWriteEnabled = NO;
      depthDesc.frontFaceStencil = nil;
      depthDesc.backFaceStencil = nil;
      OwnedObjectiveC visibilityRasterDepthOwner(
          [device newDepthStencilStateWithDescriptor:depthDesc]);
      OwnedObjectiveC visibilityStencilDescriptor(
          [[MTLStencilDescriptor alloc] init]);
      MTLStencilDescriptor* visibilityStencilDesc =
          (MTLStencilDescriptor*)visibilityStencilDescriptor.get();
      visibilityStencilDesc.stencilCompareFunction = MTLCompareFunctionEqual;
      visibilityStencilDesc.stencilFailureOperation = MTLStencilOperationKeep;
      visibilityStencilDesc.depthFailureOperation = MTLStencilOperationKeep;
      visibilityStencilDesc.depthStencilPassOperation = MTLStencilOperationKeep;
      visibilityStencilDesc.readMask = 0xffu;
      visibilityStencilDesc.writeMask = 0u;
      depthDesc.frontFaceStencil = visibilityStencilDesc;
      depthDesc.backFaceStencil = visibilityStencilDesc;
      OwnedObjectiveC visibilityStencilDepthOwner(
          [device newDepthStencilStateWithDescriptor:depthDesc]);
      if(visibilityRasterDepthOwner.get()==nil ||
         visibilityStencilDepthOwner.get()==nil)
        return;
#endif
      if(!iosGPUSceneProductionDepthStatesAreAvailable(
             depthOwner.get()!=nil,additiveDepthOwner.get()!=nil,
             multiply2DepthOwner.get()!=nil)) {
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
#if defined(OPENGOTHIC_RENDERER_IOS_METAL4)
      samplerDesc.supportArgumentBuffers = YES;
#else
      samplerDesc.supportArgumentBuffers = NO;
#endif
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

      // Skinning fetches the packed 92-byte VertexA directly; morph uses the
      // static vertex descriptor. Both share the existing material fragments.
      for(size_t geometry=0;geometry<3;++geometry) {
        OwnedObjectiveC function([nativeLibrary newFunctionWithName:
            geometry==0 ? @"riosSkinnedVertex" :
            geometry==1 ? @"riosMorphVertex" : @"riosInstancedVertex"]);
        pipelineDesc.vertexFunction = (id<MTLFunction>)function.get();
        pipelineDesc.vertexDescriptor = geometry==0 ? nil : descriptor;
        pipelineDesc.colorAttachments[0].blendingEnabled = NO;
        for(size_t alpha=0;alpha<2;++alpha) {
          pipelineDesc.fragmentFunction = (id<MTLFunction>)(alpha==0
              ? fragmentFunction.get() : alphaTestFragmentFunction.get());
          NSError* error = nil;
          OwnedObjectiveC pipeline([device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error]);
          if(pipeline.get()==nil)
            throw std::runtime_error(metalFailure("RendererIOS deformation pipeline",error));
          geometryPipelines[geometry*2+alpha] = std::move(pipeline);
          }
        }

      OwnedObjectiveC skyVertex([nativeLibrary newFunctionWithName:@"riosSkyVertex"]);
      OwnedObjectiveC skyFragment([nativeLibrary newFunctionWithName:@"riosSkyFragment"]);
      OwnedObjectiveC skyCompute([nativeLibrary newFunctionWithName:@"riosSkyLut"]);
      NSError* skyError = nil;
      skyComputePipeline = OwnedObjectiveC([device newComputePipelineStateWithFunction:
          (id<MTLFunction>)skyCompute.get() error:&skyError]);
      if(skyComputePipeline.get()==nil)
        throw std::runtime_error(metalFailure("RendererIOS sky compute pipeline",skyError));
      pipelineDesc.vertexFunction = (id<MTLFunction>)skyVertex.get();
      pipelineDesc.vertexDescriptor = nil;
      pipelineDesc.fragmentFunction = (id<MTLFunction>)skyFragment.get();
      pipelineDesc.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
      skyPipeline = OwnedObjectiveC([device newRenderPipelineStateWithDescriptor:pipelineDesc error:&skyError]);
      if(skyPipeline.get()==nil)
        throw std::runtime_error(metalFailure("RendererIOS sky render pipeline",skyError));
      MTLTextureDescriptor* skyTexture = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:128 height:64 mipmapped:NO];
      skyTexture.storageMode = MTLStorageModePrivate;
      skyTexture.hazardTrackingMode = MTLHazardTrackingModeTracked;
      skyTexture.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
      skyLut = OwnedObjectiveC([device newTextureWithDescriptor:skyTexture]);
      if(skyLut.get()==nil)
        throw std::bad_alloc();

      OwnedObjectiveC transparentFragment([nativeLibrary newFunctionWithName:@"riosLandscapeTransparentFragment"]);
      if(transparentFragment.get()==nil)
        throw std::runtime_error("RendererIOS transparent shader is missing");
      for(size_t geometry=0;geometry<3;++geometry) {
        OwnedObjectiveC function([nativeLibrary newFunctionWithName:
            geometry==0 ? @"riosLandscapeVertex" :
            geometry==1 ? @"riosSkinnedVertex" : @"riosMorphVertex"]);
        pipelineDesc.vertexFunction = (id<MTLFunction>)function.get();
        pipelineDesc.vertexDescriptor = geometry==1 ? nil : descriptor;
        pipelineDesc.fragmentFunction = (id<MTLFunction>)transparentFragment.get();
        auto color = pipelineDesc.colorAttachments[0];
        color.writeMask = MTLColorWriteMaskAll;
        color.blendingEnabled = YES;
        color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        color.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        NSError* error = nil;
        transparentPipelines[geometry] = OwnedObjectiveC(
            [device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error]);
        if(transparentPipelines[geometry].get()==nil)
          throw std::runtime_error(metalFailure("RendererIOS transparent pipeline",error));
        }

      OwnedObjectiveC rainVertex([nativeLibrary newFunctionWithName:@"riosRainVertex"]);
      OwnedObjectiveC rainFragment([nativeLibrary newFunctionWithName:@"riosRainFragment"]);
      pipelineDesc.vertexFunction = (id<MTLFunction>)rainVertex.get();
      pipelineDesc.vertexDescriptor = nil;
      pipelineDesc.fragmentFunction = (id<MTLFunction>)rainFragment.get();
      NSError* rainError = nil;
      rainPipeline = OwnedObjectiveC([device newRenderPipelineStateWithDescriptor:pipelineDesc error:&rainError]);
      if(rainPipeline.get()==nil)
        throw std::runtime_error(metalFailure("RendererIOS rain pipeline",rainError));

      // Material pipelines share the same static, skinned and morph bindings.
      for(size_t material=0;material<materialPipelines.size();++material) {
        OwnedObjectiveC fragment([nativeLibrary newFunctionWithName:
            material==0 ? @"riosWaterFragment" : material==1 ? @"riosGhostFragment" : @"riosLandscapeAdditiveFragment"]);
        for(size_t geometry=0;geometry<3;++geometry) {
          if(material>=3 && geometry==0)
            continue; // Existing static Additive/Multiply2 PSOs retain causal controls.
          OwnedObjectiveC vertex([nativeLibrary newFunctionWithName:
              geometry==0 ? @"riosLandscapeVertex" : geometry==1 ? @"riosSkinnedVertex" : @"riosMorphVertex"]);
          pipelineDesc.vertexFunction = (id<MTLFunction>)vertex.get();
          pipelineDesc.vertexDescriptor = geometry==1 ? nil : descriptor;
          pipelineDesc.fragmentFunction = (id<MTLFunction>)fragment.get();
          auto color = pipelineDesc.colorAttachments[0];
          color.blendingEnabled = material>=2;
          color.sourceRGBBlendFactor = material==3 ? MTLBlendFactorSourceAlpha : MTLBlendFactorDestinationColor;
          color.destinationRGBBlendFactor = material==3 ? MTLBlendFactorOne : MTLBlendFactorSourceColor;
          color.sourceAlphaBlendFactor = color.sourceRGBBlendFactor;
          color.destinationAlphaBlendFactor = color.destinationRGBBlendFactor;
          NSError* error = nil;
          materialPipelines[material][geometry] = OwnedObjectiveC(
              [device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error]);
          if(materialPipelines[material][geometry].get()==nil)
            throw std::runtime_error(metalFailure("RendererIOS material pipeline",error));
          }
        }
      OwnedObjectiveC underwater([nativeLibrary newFunctionWithName:@"riosUnderwaterFragment"]);
      pipelineDesc.vertexFunction = (id<MTLFunction>)skyVertex.get();
      pipelineDesc.vertexDescriptor = nil;
      pipelineDesc.fragmentFunction = (id<MTLFunction>)underwater.get();
      pipelineDesc.colorAttachments[0].blendingEnabled = NO;
      pipelineDesc.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
      pipelineDesc.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
      NSError* waterError = nil;
      underwaterPipeline = OwnedObjectiveC([device newRenderPipelineStateWithDescriptor:pipelineDesc error:&waterError]);
      if(underwaterPipeline.get()==nil)
        throw std::runtime_error(metalFailure("RendererIOS underwater pipeline",waterError));
      pipelineDesc.depthAttachmentPixelFormat = nativeDepthFormat(target.depth);
      pipelineDesc.stencilAttachmentPixelFormat = target.depth==DepthFormat::Depth32FloatStencil8
          ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
      // Simulator exposes Apple2; tessellation starts at Apple3/Mac2.
      if([device supportsFamily:MTLGPUFamilyApple3] || [device supportsFamily:MTLGPUFamilyMac2]) {
        OwnedObjectiveC patchVertex([nativeLibrary newFunctionWithName:@"riosWaterPatchVertex"]);
        OwnedObjectiveC waterFragment([nativeLibrary newFunctionWithName:@"riosWaterFragment"]);
        OwnedObjectiveC waterFactors([nativeLibrary newFunctionWithName:@"riosWaterFactors"]);
        pipelineDesc.vertexFunction = (id<MTLFunction>)patchVertex.get();
        pipelineDesc.fragmentFunction = (id<MTLFunction>)waterFragment.get();
        pipelineDesc.maxTessellationFactor =
            [device supportsFamily:MTLGPUFamilyApple5] || [device supportsFamily:MTLGPUFamilyMac2] ? 64 : 16;
        pipelineDesc.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
        pipelineDesc.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionPerPatch;
        pipelineDesc.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeNone;
        pipelineDesc.tessellationPartitionMode = MTLTessellationPartitionModeFractionalOdd;
        pipelineDesc.tessellationOutputWindingOrder = MTLWindingClockwise;
        waterPatchPipeline = OwnedObjectiveC([device newRenderPipelineStateWithDescriptor:pipelineDesc error:&waterError]);
        waterFactorPipeline = OwnedObjectiveC([device newComputePipelineStateWithFunction:
            (id<MTLFunction>)waterFactors.get() error:&waterError]);
        if(waterPatchPipeline.get()==nil || waterFactorPipeline.get()==nil)
          throw std::runtime_error(metalFailure("RendererIOS water tessellation pipeline",waterError));
        pipelineDesc.maxTessellationFactor = 16;
        }


      OwnedObjectiveC shadowAlpha([nativeLibrary newFunctionWithName:@"riosShadowAlphaTestFragment"]);
      if(shadowAlpha.get()==nil)
        throw std::runtime_error("RendererIOS shadow alpha shader is missing");
      pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
      pipelineDesc.colorAttachments[0].blendingEnabled = NO;
      pipelineDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
      pipelineDesc.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
      pipelineDesc.rasterSampleCount = 1;
      for(size_t geometry=0;geometry<3;++geometry) {
        OwnedObjectiveC function([nativeLibrary newFunctionWithName:
            geometry==0 ? @"riosLandscapeVertex" :
            geometry==1 ? @"riosSkinnedVertex" : @"riosMorphVertex"]);
        pipelineDesc.vertexFunction = (id<MTLFunction>)function.get();
        pipelineDesc.vertexDescriptor = geometry==1 ? nil : descriptor;
        for(size_t alpha=0;alpha<2;++alpha) {
          pipelineDesc.fragmentFunction = alpha==0 ? nil : (id<MTLFunction>)shadowAlpha.get();
          NSError* error = nil;
          OwnedObjectiveC pipeline([device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error]);
          if(pipeline.get()==nil)
            throw std::runtime_error(metalFailure("RendererIOS shadow pipeline",error));
          shadowPipelines[geometry*2+alpha] = std::move(pipeline);
          }
        }
      OwnedObjectiveC particleVertex([nativeLibrary newFunctionWithName:@"riosParticleVertex"]);
      pipelineDesc.vertexFunction = (id<MTLFunction>)particleVertex.get();
      pipelineDesc.vertexDescriptor = nil;
      for(size_t alpha=0;alpha<2;++alpha) {
        pipelineDesc.fragmentFunction = alpha==0 ? nil : (id<MTLFunction>)shadowAlpha.get();
        NSError* error = nil;
        particleShadowPipelines[alpha] = OwnedObjectiveC([device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error]);
        if(particleShadowPipelines[alpha].get()==nil)
          throw std::runtime_error(metalFailure("RendererIOS particle shadow pipeline",error));
        }
      pipelineDesc.colorAttachments[0].pixelFormat = colorFormat;
      pipelineDesc.depthAttachmentPixelFormat = depthFormat;
      for(size_t i=0;i<particlePipelines.size();++i) {
        const auto material = IOSMaterialCategory(i);
        if(material==IOSMaterialCategory::Water)
          continue;
        OwnedObjectiveC fragment([nativeLibrary newFunctionWithName:
            material==IOSMaterialCategory::Opaque ? @"riosLandscapeFragment" :
            material==IOSMaterialCategory::AlphaTest ? @"riosLandscapeAlphaTestFragment" :
            material==IOSMaterialCategory::Transparent ? @"riosLandscapeTransparentFragment" :
            material==IOSMaterialCategory::Ghost ? @"riosGhostFragment" : @"riosLandscapeAdditiveFragment"]);
        pipelineDesc.fragmentFunction = (id<MTLFunction>)fragment.get();
        auto color = pipelineDesc.colorAttachments[0];
        color.blendingEnabled = material!=IOSMaterialCategory::Opaque &&
            material!=IOSMaterialCategory::AlphaTest && material!=IOSMaterialCategory::Ghost;
        const bool multiply = material==IOSMaterialCategory::Multiply || material==IOSMaterialCategory::Multiply2;
        color.sourceRGBBlendFactor = multiply ? MTLBlendFactorDestinationColor : MTLBlendFactorSourceAlpha;
        color.destinationRGBBlendFactor = multiply ? MTLBlendFactorSourceColor :
            material==IOSMaterialCategory::Additive ? MTLBlendFactorOne : MTLBlendFactorOneMinusSourceAlpha;
        color.sourceAlphaBlendFactor = color.sourceRGBBlendFactor;
        color.destinationAlphaBlendFactor = color.destinationRGBBlendFactor;
        NSError* error = nil;
        particlePipelines[i] = OwnedObjectiveC([device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error]);
        if(particlePipelines[i].get()==nil)
          throw std::runtime_error(metalFailure("RendererIOS particle pipeline",error));
        }

      depthDesc.frontFaceStencil = nil;
      depthDesc.backFaceStencil = nil;
      depthDesc.depthCompareFunction = MTLCompareFunctionGreater;
      depthDesc.depthWriteEnabled = YES;
      shadowDepthState = OwnedObjectiveC([device newDepthStencilStateWithDescriptor:depthDesc]);
      if(shadowDepthState.get()==nil)
        throw std::runtime_error("RendererIOS shadow depth state is unavailable");
      for(size_t layer=0;layer<shadowMaps.size();++layer) {
        const NSUInteger size = layer==0 ? 2048u : 1024u;
        MTLTextureDescriptor* texture = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:size height:size mipmapped:NO];
        texture.storageMode = MTLStorageModePrivate;
        texture.hazardTrackingMode = MTLHazardTrackingModeTracked;
        texture.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        shadowMaps[layer] = OwnedObjectiveC([device newTextureWithDescriptor:texture]);
        if(shadowMaps[layer].get()==nil)
          throw std::bad_alloc();
        }

      @try { motionReady = initializeMotion(device,nativeLibrary,descriptor); }
      @catch(NSException*) { motionReady = false; }

      opaquePipelineState    = opaquePipelineOwner.relinquish();
      alphaTestPipelineState = alphaTestPipelineOwner.relinquish();
      additivePipelineState  = additivePipelineOwner.relinquish();
      multiply2PipelineState = multiply2PipelineOwner.relinquish();
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      multiply2VisibilityPipelineState =
          visibilityPipelineOwner.relinquish();
#endif
      baseDepthState         = depthOwner.relinquish();
      additiveDepthState     = additiveDepthOwner.relinquish();
      multiply2DepthState    = multiply2DepthOwner.relinquish();
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      multiply2VisibilityRasterDepthState =
          visibilityRasterDepthOwner.relinquish();
      multiply2VisibilityStencilDepthState =
          visibilityStencilDepthOwner.relinquish();
#endif
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
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
    [multiply2ContinuationDepthStencil release];
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
    [multiply2VisibilityStencilDepthState release];
    [multiply2VisibilityRasterDepthState release];
    [multiply2VisibilityPipelineState release];
#endif
    [samplerState release];
    [multiply2DepthState release];
    [additiveDepthState release];
    [baseDepthState release];
    [multiply2PipelineState release];
    [additivePipelineState release];
    [alphaTestPipelineState release];
    [opaquePipelineState release];
    }

  Tempest::Device&                  owner;
  Tempest::BorrowedMetalDevice      nativeDevice;
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
  std::unique_ptr<IOSRayTracing> rayTracing;
  bool rayTracingUnavailable = false;
#endif
  bool                            geometryReported = false;
  std::array<OwnedObjectiveC,6>     geometryPipelines;
  std::array<OwnedObjectiveC,6>     shadowPipelines;
  std::array<OwnedObjectiveC,8>     particlePipelines;
  std::array<OwnedObjectiveC,2>     particleShadowPipelines;
  std::array<OwnedObjectiveC,3>     transparentPipelines;
  std::array<std::array<OwnedObjectiveC,3>,5> materialPipelines;
  OwnedObjectiveC waterPatchPipeline, waterFactorPipeline, underwaterPipeline;
  OwnedObjectiveC sceneDepth, sceneColorCopy, sceneDepthCopy;
  std::array<OwnedObjectiveC,4> motionPipelines;
  std::array<OwnedObjectiveC,5> reactivePipelines;
  OwnedObjectiveC skyMotionPipeline, motionDepthState, motionTexture, reactiveTexture;
  bool motionReady = false;
  std::array<OwnedObjectiveC,2>     shadowMaps;
  OwnedObjectiveC                 shadowDepthState;
  OwnedObjectiveC                 skyLut;
  OwnedObjectiveC                 skyComputePipeline;
  OwnedObjectiveC                 skyPipeline;
  OwnedObjectiveC                 rainPipeline;
  id                               opaquePipelineState = nil;
  id                               alphaTestPipelineState = nil;
  id                               additivePipelineState = nil;
  id                               multiply2PipelineState = nil;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
  id                               multiply2VisibilityPipelineState = nil;
#endif
  id                               baseDepthState = nil;
  id                               additiveDepthState = nil;
  id                               multiply2DepthState = nil;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
  id                               multiply2VisibilityRasterDepthState = nil;
  id                               multiply2VisibilityStencilDepthState = nil;
#endif
  id                               samplerState = nil;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
  id                               multiply2ContinuationDepthStencil = nil;
#endif
  IOSGPUScene::Result              initializationResult =
      IOSGPUScene::Result::PipelineUnavailable;
  NativeTextureValidationCache     textureValidation;
  bool                              emissiveTerminalReported = false;
#if defined(OPENGOTHIC_RENDERER_IOS_SIMULATOR_SMOKE)
  bool                              simulatorSmokeBudgetReported = false;
#endif
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

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
bool IOSGPUScene::Impl::continuationDepthStencilForSceneHDR(
    id sceneHDRObject, id& depthStencilObject,
    uint32_t& width, uint32_t& height) noexcept {
  depthStencilObject = nil;
  width = 0u;
  height = 0u;
  @autoreleasepool {
    @try {
      id<MTLDevice> device =
          (id<MTLDevice>)(void*)nativeDevice.get();
      id<MTLTexture> sceneHDR = (id<MTLTexture>)sceneHDRObject;
      if(device==nil || sceneHDR==nil || sceneHDR.device!=device ||
         sceneHDR.textureType!=MTLTextureType2D ||
         sceneHDR.pixelFormat!=MTLPixelFormatRG11B10Float ||
         sceneHDR.width==0u || sceneHDR.height==0u ||
         sceneHDR.width>std::numeric_limits<uint32_t>::max() ||
         sceneHDR.height>std::numeric_limits<uint32_t>::max() ||
         sceneHDR.depth!=1u || sceneHDR.mipmapLevelCount!=1u ||
         sceneHDR.arrayLength!=1u || sceneHDR.sampleCount!=1u)
        return false;

      const auto validContinuationTarget =
          [&](id<MTLTexture> target) noexcept {
        return target!=nil && target.device==device &&
               target.textureType==MTLTextureType2D &&
               target.pixelFormat==MTLPixelFormatDepth32Float_Stencil8 &&
               target.width==sceneHDR.width &&
               target.height==sceneHDR.height && target.depth==1u &&
               target.mipmapLevelCount==1u && target.arrayLength==1u &&
               target.sampleCount==1u &&
               target.storageMode==MTLStorageModePrivate &&
               target.cpuCacheMode==MTLCPUCacheModeDefaultCache &&
               target.hazardTrackingMode==MTLHazardTrackingModeTracked &&
               target.usage==MTLTextureUsageRenderTarget;
      };

      id<MTLTexture> target =
          (id<MTLTexture>)multiply2ContinuationDepthStencil;
      if(target==nil || target.width!=sceneHDR.width ||
         target.height!=sceneHDR.height) {
        OwnedObjectiveC descriptor(
            [[MTLTextureDescriptor alloc] init]);
        if(descriptor.get()==nil)
          return false;
        MTLTextureDescriptor* textureDescriptor =
            (MTLTextureDescriptor*)descriptor.get();
        textureDescriptor.textureType = MTLTextureType2D;
        textureDescriptor.pixelFormat =
            MTLPixelFormatDepth32Float_Stencil8;
        textureDescriptor.width = sceneHDR.width;
        textureDescriptor.height = sceneHDR.height;
        textureDescriptor.depth = 1u;
        textureDescriptor.mipmapLevelCount = 1u;
        textureDescriptor.sampleCount = 1u;
        textureDescriptor.arrayLength = 1u;
        textureDescriptor.resourceOptions =
            MTLResourceCPUCacheModeDefaultCache |
            MTLResourceStorageModePrivate |
            MTLResourceHazardTrackingModeTracked;
        textureDescriptor.usage = MTLTextureUsageRenderTarget;
        OwnedObjectiveC allocated(
            [device newTextureWithDescriptor:textureDescriptor]);
        target = (id<MTLTexture>)allocated.get();
        if(!validContinuationTarget(target))
          return false;
        [target setLabel:
            @"RendererIOS.Multiply2.ContinuationDepthStencil.v1"];
        [multiply2ContinuationDepthStencil release];
        multiply2ContinuationDepthStencil = allocated.relinquish();
        }
      else if(!validContinuationTarget(target)) {
        return false;
        }

      depthStencilObject = target;
      width = static_cast<uint32_t>(sceneHDR.width);
      height = static_cast<uint32_t>(sceneHDR.height);
      return true;
    }
    @catch(NSException*) {
      depthStencilObject = nil;
      width = 0u;
      height = 0u;
      return false;
    }
  }
}

void IOSGPUScene::Impl::encodeMultiply2(
    void* opaque, MTL::CommandBuffer* nativeCommandBuffer) {
  if(opaque==nullptr || nativeCommandBuffer==nullptr)
    return;
  auto& context = *static_cast<NativeMultiply2Context*>(opaque);
  const bool captureProof =
      context.mode==NativeMultiply2EncodeMode::CaptureProof;
  const bool continuation =
      context.mode==NativeMultiply2EncodeMode::Continuation;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
  const bool visibilityModeResourcesAreValid =
      captureProof ? context.visibilityResultBuffer!=nil
                   : continuation && context.visibilityResultBuffer==nil;
#else
  constexpr bool visibilityModeResourcesAreValid = true;
#endif
  const bool modeResourcesAreValid =
      captureProof
        ? context.hdrProofBuffer!=nil && context.coverageBuffer!=nil &&
          context.hdrBytesPerRow==context.width*4u &&
          context.coverageBytesPerRow>=context.width &&
          context.sceneMarker.size()==53u &&
          context.proofMarker.size()==57u
        : continuation && context.hdrProofBuffer==nil &&
          context.coverageBuffer==nil && context.hdrBytesPerRow==0u &&
          context.coverageBytesPerRow==0u && context.sceneMarker.empty() &&
          context.proofMarker.empty();
  if(context.scene==nullptr || context.prepared==nullptr ||
     context.prepared->owner!=context.scene || !context.prepared->ready ||
     context.prepared->multiply2.size()!=1u ||
     context.sceneHDR==nil || context.depthStencil==nil ||
     context.width==0u || context.height==0u ||
     !modeResourcesAreValid || !visibilityModeResourcesAreValid)
    return;

  id<MTLCommandBuffer> command =
      (id<MTLCommandBuffer>)(void*)nativeCommandBuffer;
  id<MTLTexture> sceneHDR = (id<MTLTexture>)context.sceneHDR;
  id<MTLTexture> depthStencil = (id<MTLTexture>)context.depthStencil;
  id<MTLBuffer> hdrProofBuffer = (id<MTLBuffer>)context.hdrProofBuffer;
  id<MTLBuffer> coverageBuffer = (id<MTLBuffer>)context.coverageBuffer;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
  id<MTLBuffer> visibilityResultBuffer =
      (id<MTLBuffer>)context.visibilityResultBuffer;
#endif
  OwnedObjectiveC sceneMarker;
  OwnedObjectiveC proofMarker;
  if(captureProof) {
    sceneMarker = OwnedObjectiveC([[NSString alloc]
        initWithBytes:context.sceneMarker.data()
               length:context.sceneMarker.size()
             encoding:NSUTF8StringEncoding]);
    proofMarker = OwnedObjectiveC([[NSString alloc]
        initWithBytes:context.proofMarker.data()
               length:context.proofMarker.size()
             encoding:NSUTF8StringEncoding]);
    if(sceneMarker.get()==nil || proofMarker.get()==nil)
      return;
    }
  id<MTLRenderCommandEncoder> renderEncoder = nil;
  id<MTLBlitCommandEncoder> blitEncoder = nil;
  const auto endRender = [&]() noexcept {
    if(renderEncoder==nil)
      return true;
    @try {
      [renderEncoder endEncoding];
      renderEncoder = nil;
      return true;
    }
    @catch(NSException*) {
      return false;
    }
  };
  const auto endBlit = [&]() noexcept {
    if(blitEncoder==nil)
      return true;
    @try {
      [blitEncoder endEncoding];
      blitEncoder = nil;
      return true;
    }
    @catch(NSException*) {
      return false;
    }
  };
  const auto closeOrTerminate = [&]() noexcept {
    bool closed = endRender();
    closed = endBlit() && closed;
    if(!closed)
      std::terminate();
  };

  @autoreleasepool {
    @try {
      id<MTLDevice> device =
          (id<MTLDevice>)(void*)context.scene->nativeDevice.get();
      const bool modeNativeResourcesAreValid =
          captureProof
            ? hdrProofBuffer.device==device &&
              coverageBuffer.device==device &&
              hdrProofBuffer.storageMode==MTLStorageModeShared &&
              coverageBuffer.storageMode==MTLStorageModeShared
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
              && visibilityResultBuffer.device==device &&
              visibilityResultBuffer.storageMode==MTLStorageModeShared &&
              visibilityResultBuffer.length>=
                  IOSMultiply2VisibilityResultBytes &&
              visibilityResultBuffer.contents!=nullptr
#endif
            : continuation &&
              depthStencil==
                  (id<MTLTexture>)context.scene->
                      multiply2ContinuationDepthStencil;
      if(command==nil || device==nil || command.device!=device ||
         sceneHDR.device!=device || depthStencil.device!=device ||
         sceneHDR.pixelFormat!=MTLPixelFormatRG11B10Float ||
         sceneHDR.width!=NSUInteger(context.width) ||
         sceneHDR.height!=NSUInteger(context.height) ||
         sceneHDR.sampleCount!=1u ||
         sceneHDR.textureType!=MTLTextureType2D ||
         depthStencil.pixelFormat!=MTLPixelFormatDepth32Float_Stencil8 ||
         depthStencil.width!=NSUInteger(context.width) ||
         depthStencil.height!=NSUInteger(context.height) ||
         depthStencil.sampleCount!=1u ||
         depthStencil.textureType!=MTLTextureType2D ||
         depthStencil.depth!=1u || depthStencil.mipmapLevelCount!=1u ||
         depthStencil.arrayLength!=1u ||
         depthStencil.storageMode!=MTLStorageModePrivate ||
         depthStencil.cpuCacheMode!=MTLCPUCacheModeDefaultCache ||
         depthStencil.hazardTrackingMode!=MTLHazardTrackingModeTracked ||
         depthStencil.usage!=MTLTextureUsageRenderTarget ||
         !modeNativeResourcesAreValid)
        return;

      if(!context.scene->encodeShadows(command,*context.prepared) ||
         !context.scene->encodeSkyLut(command,*context.prepared))
        return;
      const MTLViewport viewport = {
          0.0,0.0,double(context.width),double(context.height),0.0,1.0};
      const MTLScissorRect scissor = {
          0u,0u,NSUInteger(context.width),NSUInteger(context.height)};
      const auto encodeDraws = [&](id<MTLRenderCommandEncoder> encoder,
                                   const auto& draws,
                                   id depthState,
                                   uint32_t stencilReference) {
        context.scene->bindLighting(encoder,*context.prepared);
        [encoder setDepthStencilState:(id<MTLDepthStencilState>)depthState];
        [encoder setStencilReferenceValue:stencilReference];
        for(const auto& draw:draws) {
          [encoder setRenderPipelineState:
              (id<MTLRenderPipelineState>)draw.pipelineState];
          bindGeometry(encoder,draw);
          [encoder setFragmentTexture:
              (id<MTLTexture>)draw.baseColorTexture atIndex:0u];
          if(draw.drawId.get()!=nil && draw.drawBind.get()!=nil) {
            [encoder insertDebugSignpost:(NSString*)draw.drawId.get()];
            [encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];
          }
          [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                              indexCount:draw.plan.indexCount
                               indexType:MTLIndexTypeUInt32
                             indexBuffer:(id<MTLBuffer>)draw.indexBuffer
                       indexBufferOffset:draw.plan.indexBufferOffset
                           instanceCount:1u baseVertex:0 baseInstance:0u];
          ++context.report.encodedPhaseDrawCount;
          if(draw.baseColorTexture!=nil)
            ++context.report.encodedPhaseTexturedDrawCount;
        }
      };

      MTLRenderPassDescriptor* first =
          [[MTLRenderPassDescriptor alloc] init];
      if(first==nil)
        return;
      first.colorAttachments[0].texture = sceneHDR;
      first.colorAttachments[0].loadAction = MTLLoadActionClear;
      first.colorAttachments[0].storeAction = MTLStoreActionStore;
      first.colorAttachments[0].clearColor =
          MTLClearColorMake(0.0,0.0,0.0,0.0);
      first.depthAttachment.texture = depthStencil;
      first.depthAttachment.loadAction = MTLLoadActionClear;
      first.depthAttachment.storeAction = MTLStoreActionStore;
      first.depthAttachment.clearDepth = 1.0;
      first.stencilAttachment.texture = depthStencil;
      first.stencilAttachment.loadAction = MTLLoadActionClear;
      first.stencilAttachment.storeAction = MTLStoreActionStore;
      first.stencilAttachment.clearStencil = 0u;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      if(captureProof)
        first.visibilityResultBuffer = visibilityResultBuffer;
#endif
      renderEncoder = [command renderCommandEncoderWithDescriptor:first];
      [first release];
      if(renderEncoder==nil)
        return;
      if(captureProof) {
        [renderEncoder setLabel:(NSString*)sceneMarker.get()];
        [renderEncoder pushDebugGroup:(NSString*)sceneMarker.get()];
        [renderEncoder insertDebugSignpost:
            @"RendererIOS.Multiply2.BaseAndCausal.v1"];
        }
      else {
        [renderEncoder setLabel:
            @"RendererIOS.Multiply2.BaseAndContinuation.v1"];
        [renderEncoder pushDebugGroup:
            @"RendererIOS.Multiply2.BaseAndContinuation.v1"];
        [renderEncoder insertDebugSignpost:
            @"RendererIOS.Multiply2.BaseAndContinuation.v1"];
        }
      [renderEncoder setViewport:viewport];
      [renderEncoder setScissorRect:scissor];
      [renderEncoder setFrontFacingWinding:MTLWindingClockwise];
      [renderEncoder setCullMode:MTLCullModeFront];
      [renderEncoder setFragmentSamplerState:
          (id<MTLSamplerState>)context.scene->samplerState atIndex:0u];
      context.scene->encodeSky(renderEncoder,*context.prepared);
      encodeDraws(renderEncoder,context.prepared->base,
                  context.scene->baseDepthState,0u);
      [renderEncoder setDepthStencilState:
          (id<MTLDepthStencilState>)context.scene->multiply2DepthState];
      [renderEncoder setStencilReferenceValue:1u];
      const auto& productionDraw = context.prepared->multiply2.front();
      [renderEncoder setRenderPipelineState:
          (id<MTLRenderPipelineState>)productionDraw.pipelineState];
      bindGeometry(renderEncoder,productionDraw);
      [renderEncoder setFragmentTexture:
          (id<MTLTexture>)productionDraw.baseColorTexture atIndex:0u];
      if(productionDraw.drawId.get()!=nil &&
         productionDraw.drawBind.get()!=nil) {
        [renderEncoder insertDebugSignpost:
            (NSString*)productionDraw.drawId.get()];
        [renderEncoder insertDebugSignpost:
            (NSString*)productionDraw.drawBind.get()];
      }
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      if(captureProof)
        [renderEncoder setVisibilityResultMode:MTLVisibilityResultModeBoolean
                                          offset:IOSMultiply2VisibilityProductionOffset];
#endif
      [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:productionDraw.plan.indexCount
                                 indexType:MTLIndexTypeUInt32
                               indexBuffer:(id<MTLBuffer>)productionDraw.indexBuffer
                         indexBufferOffset:productionDraw.plan.indexBufferOffset
                             instanceCount:1u baseVertex:0 baseInstance:0u];
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      if(captureProof)
        [renderEncoder setVisibilityResultMode:MTLVisibilityResultModeDisabled
                                          offset:0u];
#endif
      ++context.report.encodedPhaseDrawCount;
      if(productionDraw.baseColorTexture!=nil)
        ++context.report.encodedPhaseTexturedDrawCount;
      [renderEncoder setFragmentTexture:nil atIndex:0u];
      [renderEncoder setFragmentSamplerState:nil atIndex:0u];
      [renderEncoder popDebugGroup];
      if(!endRender()) {
        closeOrTerminate();
        return;
      }
      context.prepared->markNativeBaseMultiplyCompleted();

      if(captureProof) {
        blitEncoder = [command blitCommandEncoder];
        if(blitEncoder==nil)
          return;
        [blitEncoder setLabel:(NSString*)proofMarker.get()];
        [blitEncoder pushDebugGroup:(NSString*)proofMarker.get()];
        const MTLOrigin origin = MTLOriginMake(0u,0u,0u);
        const MTLSize size =
            MTLSizeMake(context.width,context.height,1u);
        [blitEncoder insertDebugSignpost:@"RendererIOS.HDRProofCopy.Multiply2.v1"];
        [blitEncoder copyFromTexture:sceneHDR sourceSlice:0u sourceLevel:0u
                        sourceOrigin:origin sourceSize:size
                            toBuffer:hdrProofBuffer destinationOffset:0u
               destinationBytesPerRow:context.hdrBytesPerRow
             destinationBytesPerImage:
                 NSUInteger(context.hdrBytesPerRow)*context.height
                             options:MTLBlitOptionNone];
        [blitEncoder popDebugGroup];
        if(!endBlit()) {
          closeOrTerminate();
          return;
          }

        blitEncoder = [command blitCommandEncoder];
        if(blitEncoder==nil)
          return;
        [blitEncoder setLabel:@"RendererIOS.Multiply2.CausalCopies.v1"];
        [blitEncoder pushDebugGroup:
            @"RendererIOS.Multiply2.CoverageStencilCopy.v1"];
        [blitEncoder insertDebugSignpost:@"RendererIOS.Multiply2.CoverageStencilCopy.v1"];
        [blitEncoder copyFromTexture:depthStencil sourceSlice:0u sourceLevel:0u
                        sourceOrigin:origin sourceSize:size
                            toBuffer:coverageBuffer destinationOffset:0u
               destinationBytesPerRow:context.coverageBytesPerRow
             destinationBytesPerImage:
                 NSUInteger(context.coverageBytesPerRow)*context.height
                             options:MTLBlitOptionStencilFromDepthStencil];
        [blitEncoder popDebugGroup];
        if(!endBlit()) {
          closeOrTerminate();
          return;
          }
      }

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      if(captureProof) {
        MTLRenderPassDescriptor* visibilityPass =
            [[MTLRenderPassDescriptor alloc] init];
        if(visibilityPass==nil)
          return;
        visibilityPass.colorAttachments[0].texture = sceneHDR;
        visibilityPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        visibilityPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        visibilityPass.depthAttachment.texture = depthStencil;
        visibilityPass.depthAttachment.loadAction = MTLLoadActionLoad;
        visibilityPass.depthAttachment.storeAction = MTLStoreActionStore;
        visibilityPass.stencilAttachment.texture = depthStencil;
        visibilityPass.stencilAttachment.loadAction = MTLLoadActionLoad;
        visibilityPass.stencilAttachment.storeAction = MTLStoreActionStore;
        visibilityPass.visibilityResultBuffer = visibilityResultBuffer;
        renderEncoder =
            [command renderCommandEncoderWithDescriptor:visibilityPass];
        [visibilityPass release];
        if(renderEncoder==nil)
          return;
        [renderEncoder setLabel:
            @"RendererIOS.Multiply2.VisibilityDiagnostic.v1"];
        [renderEncoder pushDebugGroup:
            @"RendererIOS.Multiply2.VisibilityDiagnostic.v1"];
        [renderEncoder setViewport:viewport];
        [renderEncoder setScissorRect:scissor];
        [renderEncoder setFrontFacingWinding:MTLWindingClockwise];
        [renderEncoder setCullMode:MTLCullModeFront];
        [renderEncoder setFragmentSamplerState:
            (id<MTLSamplerState>)context.scene->samplerState atIndex:0u];
        const auto& draw = context.prepared->multiply2.front();
        [renderEncoder setRenderPipelineState:
            (id<MTLRenderPipelineState>)
                context.scene->multiply2VisibilityPipelineState];
        bindGeometry(renderEncoder,draw);
        [renderEncoder setFragmentTexture:
            (id<MTLTexture>)draw.baseColorTexture atIndex:0u];

        [renderEncoder setDepthStencilState:
            (id<MTLDepthStencilState>)
                context.scene->multiply2VisibilityRasterDepthState];
        [renderEncoder setStencilReferenceValue:0u];
        [renderEncoder setVisibilityResultMode:MTLVisibilityResultModeBoolean
                                          offset:IOSMultiply2VisibilityRasterOffset];
        [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                  indexCount:draw.plan.indexCount
                                   indexType:MTLIndexTypeUInt32
                                 indexBuffer:(id<MTLBuffer>)draw.indexBuffer
                           indexBufferOffset:draw.plan.indexBufferOffset
                               instanceCount:1u baseVertex:0 baseInstance:0u];
        [renderEncoder setVisibilityResultMode:MTLVisibilityResultModeDisabled
                                          offset:0u];

        [renderEncoder setDepthStencilState:
            (id<MTLDepthStencilState>)
                context.scene->multiply2VisibilityStencilDepthState];
        [renderEncoder setStencilReferenceValue:1u];
        [renderEncoder setVisibilityResultMode:MTLVisibilityResultModeBoolean
                                          offset:IOSMultiply2VisibilityStencilOffset];
        [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                  indexCount:draw.plan.indexCount
                                   indexType:MTLIndexTypeUInt32
                                 indexBuffer:(id<MTLBuffer>)draw.indexBuffer
                           indexBufferOffset:draw.plan.indexBufferOffset
                               instanceCount:1u baseVertex:0 baseInstance:0u];
        [renderEncoder setVisibilityResultMode:MTLVisibilityResultModeDisabled
                                          offset:0u];
        [renderEncoder setFragmentTexture:nil atIndex:0u];
        [renderEncoder setFragmentSamplerState:nil atIndex:0u];
        [renderEncoder popDebugGroup];
        if(!endRender()) {
          closeOrTerminate();
          return;
          }
      }
#endif

      MTLRenderPassDescriptor* second =
          [[MTLRenderPassDescriptor alloc] init];
      if(second==nil)
        return;
      second.colorAttachments[0].texture = sceneHDR;
      second.colorAttachments[0].loadAction = MTLLoadActionLoad;
      second.colorAttachments[0].storeAction = MTLStoreActionStore;
      second.depthAttachment.texture = depthStencil;
      second.depthAttachment.loadAction = MTLLoadActionLoad;
      second.depthAttachment.storeAction = MTLStoreActionStore;
      second.stencilAttachment.texture = depthStencil;
      second.stencilAttachment.loadAction = MTLLoadActionLoad;
      second.stencilAttachment.storeAction = MTLStoreActionStore;
      renderEncoder = [command renderCommandEncoderWithDescriptor:second];
      [second release];
      if(renderEncoder==nil)
        return;
      if(captureProof) {
        [renderEncoder setLabel:@"RendererIOS.Multiply2.AdditiveAfterProof.v1"];
        [renderEncoder pushDebugGroup:
            @"RendererIOS.Multiply2.AdditiveAfterProof.v1"];
        }
      else {
        [renderEncoder setLabel:
            @"RendererIOS.Multiply2.AdditiveContinuation.v1"];
        [renderEncoder pushDebugGroup:
            @"RendererIOS.Multiply2.AdditiveContinuation.v1"];
        [renderEncoder insertDebugSignpost:
            @"RendererIOS.Multiply2.AdditiveContinuation.v1"];
        }
      [renderEncoder setViewport:viewport];
      [renderEncoder setScissorRect:scissor];
      [renderEncoder setFrontFacingWinding:MTLWindingClockwise];
      [renderEncoder setCullMode:MTLCullModeFront];
      [renderEncoder setFragmentSamplerState:
          (id<MTLSamplerState>)context.scene->samplerState atIndex:0u];
      encodeDraws(renderEncoder,context.prepared->additive,
                  context.scene->additiveDepthState,0u);
      encodeDraws(renderEncoder,context.prepared->transparent,
                  context.scene->additiveDepthState,0u);
      context.scene->encodeRain(renderEncoder,*context.prepared);
      [renderEncoder setFragmentTexture:nil atIndex:0u];
      [renderEncoder setFragmentSamplerState:nil atIndex:0u];
      [renderEncoder popDebugGroup];
      if(!endRender()) {
        closeOrTerminate();
        return;
      }
      context.prepared->markNativeAdditiveCompleted();
      context.prepared->nativeCompleted = true;
      context.succeeded = true;
    }
    @catch(NSException*) {
      context.prepared->markNativeException();
      closeOrTerminate();
    }
  }
}

IOSGPUScene::Report IOSGPUScene::Impl::runMultiply2(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    NativeMultiply2Context& context) noexcept {
  try {
    const bool accepted = Tempest::MetalApi::withActiveCommandBuffer(
        owner,encoder,&context,&Impl::encodeMultiply2);
    if(!accepted || !context.succeeded ||
       context.prepared==nullptr || context.prepared->nativeException ||
       !context.prepared->nativeCompleted ||
       context.report.encodedPhaseDrawCount!=context.report.drawCount ||
       context.report.encodedPhaseTexturedDrawCount!=
           context.report.texturedDrawCount) {
      context.report.result = IOSGPUScene::Result::NativeEncodingFailed;
      recordFailure(context.report.failures.nativeEncode,context.report);
      recordPlannedDrawnFailure(context.report);
      if(context.prepared!=nullptr)
        context.prepared->ready = false;
      return context.report;
      }
    context.prepared->ready = false;
    return context.report;
  }
  catch(...) {
    context.report.result = IOSGPUScene::Result::NativeEncodingFailed;
    recordFailure(context.report.failures.nativeEncode,context.report);
    recordPlannedDrawnFailure(context.report);
    if(context.prepared!=nullptr) {
      context.prepared->markNativeException();
      context.prepared->ready = false;
      }
    return context.report;
  }
}
#endif

void IOSGPUScene::Impl::bindLighting(id<MTLRenderCommandEncoder> encoder,
                                    const PreparedFrame::Impl& prepared) {
  [encoder setFragmentBytes:&prepared.lighting length:sizeof(prepared.lighting) atIndex:0];
  [encoder setFragmentBuffer:(id<MTLBuffer>)prepared.lightBuffer offset:0 atIndex:1];
  for(size_t layer=0;layer<shadowMaps.size();++layer)
    [encoder setFragmentTexture:(id<MTLTexture>)shadowMaps[layer].get() atIndex:layer+1];
  }

bool IOSGPUScene::Impl::encodeShadows(id<MTLCommandBuffer> command,
                                     PreparedFrame::Impl& prepared) {
  @autoreleasepool {
    for(size_t layer=0;layer<shadowMaps.size();++layer) {
      id<MTLTexture> map = (id<MTLTexture>)shadowMaps[layer].get();
      MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
      pass.depthAttachment.texture = map;
      pass.depthAttachment.loadAction = MTLLoadActionClear;
      pass.depthAttachment.storeAction = MTLStoreActionStore;
      pass.depthAttachment.clearDepth = 0.0;
      id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
      if(encoder==nil)
        return false;
      @try {
        encoder.label = layer==0 ? @"RendererIOS shadow near" : @"RendererIOS shadow far";
        [encoder setViewport:MTLViewport{0,0,double(map.width),double(map.height),0,1}];
        [encoder setDepthStencilState:(id<MTLDepthStencilState>)shadowDepthState.get()];
        [encoder setFrontFacingWinding:MTLWindingClockwise];
        [encoder setCullMode:MTLCullModeFront];
        [encoder setFragmentSamplerState:(id<MTLSamplerState>)samplerState atIndex:0];
        for(const auto& draw:prepared.shadows[layer]) {
          [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)draw.pipelineState];
          bindGeometry(encoder,draw);
          [encoder setFragmentTexture:(id<MTLTexture>)draw.baseColorTexture atIndex:0];
          [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:draw.plan.indexCount
                               indexType:MTLIndexTypeUInt32 indexBuffer:(id<MTLBuffer>)draw.indexBuffer
                       indexBufferOffset:draw.plan.indexBufferOffset];
          }
        if(prepared.lighting.sunDirection.w!=0.f) {
          encodeParticles(encoder,prepared,IOSMaterialCategory::Opaque,int(layer));
          encodeParticles(encoder,prepared,IOSMaterialCategory::AlphaTest,int(layer));
          }
        }
      @finally {
        [encoder endEncoding];
        }
      }
    }
  return true;
  }

bool IOSGPUScene::Impl::encodeSkyLut(id<MTLCommandBuffer> command,
                                    const PreparedFrame::Impl& prepared) {
  if(!prepared.skyReady)
    return true;
  id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
  if(encoder==nil)
    return false;
  @try {
    encoder.label = @"RendererIOS atmosphere LUT";
    [encoder setComputePipelineState:(id<MTLComputePipelineState>)skyComputePipeline.get()];
    [encoder setBytes:&prepared.lighting length:sizeof(prepared.lighting) atIndex:0];
    [encoder setTexture:(id<MTLTexture>)skyLut.get() atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(128,64,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    }
  @finally {
    [encoder endEncoding];
    }
  return true;
  }

void IOSGPUScene::Impl::encodeSky(id<MTLRenderCommandEncoder> encoder,
                                 const PreparedFrame::Impl& prepared) {
  if(!prepared.skyReady)
    return;
  [encoder setCullMode:MTLCullModeNone];
  [encoder setDepthStencilState:(id<MTLDepthStencilState>)additiveDepthState];
  [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)skyPipeline.get()];
  bindLighting(encoder,prepared);
  [encoder setFragmentBytes:&prepared.cloudOffsets length:sizeof(prepared.cloudOffsets) atIndex:2];
  [encoder setFragmentTexture:(id<MTLTexture>)skyLut.get() atIndex:0];
  for(size_t i=0;i<prepared.skyImages.size();++i)
    [encoder setFragmentTexture:(id<MTLTexture>)prepared.skyImages[i] atIndex:i+3];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [encoder setCullMode:MTLCullModeFront];
  }

void IOSGPUScene::Impl::encodeParticles(id<MTLRenderCommandEncoder> encoder,
                                        const PreparedFrame::Impl& prepared,
                                        IOSMaterialCategory material, int shadow) {
  const auto& batches = prepared.particles[size_t(material)];
  if(batches.empty())
    return;
  auto camera = prepared.particleCamera;
  if(shadow>=0)
    camera.viewProjection = prepared.lighting.viewShadow[size_t(shadow)];
  [encoder setCullMode:MTLCullModeNone];
  [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)(shadow>=0
      ? particleShadowPipelines[size_t(material==IOSMaterialCategory::AlphaTest)].get()
      : particlePipelines[size_t(material)].get())];
  [encoder setVertexBuffer:(id<MTLBuffer>)prepared.particleBuffer offset:0 atIndex:0];
  [encoder setVertexBytes:&camera length:sizeof(camera) atIndex:1];
  for(const auto& value:batches) {
    [encoder setFragmentTexture:(id<MTLTexture>)value.texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
             instanceCount:value.batch.vertices.count baseInstance:value.batch.vertices.offset];
    }
  [encoder setCullMode:MTLCullModeFront];
  }

void IOSGPUScene::Impl::encodeRain(id<MTLRenderCommandEncoder> encoder,
                                  const PreparedFrame::Impl& prepared) {
  if(prepared.lighting.skyParameters.y<=0.f)
    return;
  [encoder setCullMode:MTLCullModeNone];
  [encoder setDepthStencilState:(id<MTLDepthStencilState>)additiveDepthState];
  [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)rainPipeline.get()];
  [encoder setVertexBytes:&prepared.viewProjection length:sizeof(prepared.viewProjection) atIndex:0];
  [encoder setVertexBytes:&prepared.lighting length:sizeof(prepared.lighting) atIndex:1];
  [encoder setFragmentBytes:&prepared.lighting length:sizeof(prepared.lighting) atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:256];
  [encoder setCullMode:MTLCullModeFront];
  }

void IOSGPUScene::Impl::ensureSceneTargets(id<MTLTexture> color,
                                          const PreparedFrame::Impl& prepared) {
  auto depth = (id<MTLTexture>)sceneDepth.get();
  if(depth!=nil && (depth.width!=color.width || depth.height!=color.height)) {
    sceneDepth = OwnedObjectiveC();
    sceneColorCopy = OwnedObjectiveC();
    sceneDepthCopy = OwnedObjectiveC();
    motionTexture = OwnedObjectiveC();
    reactiveTexture = OwnedObjectiveC();
    }
  const auto allocate = [&](OwnedObjectiveC& storage, MTLPixelFormat format) {
    if(storage.get()!=nil)
      return;
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        format width:color.width height:color.height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.hazardTrackingMode = MTLHazardTrackingModeTracked;
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    storage = OwnedObjectiveC([color.device newTextureWithDescriptor:desc]);
    if(storage.get()==nil)
      throw std::bad_alloc();
    };
  allocate(sceneDepth,MTLPixelFormatDepth32Float);
  if(prepared.needsSceneCopy() || prepared.lighting.lightInfo[2]!=0)
    allocate(sceneColorCopy,color.pixelFormat);
  if(!prepared.water.empty())
    allocate(sceneDepthCopy,MTLPixelFormatDepth32Float);
  }

bool IOSGPUScene::Impl::initializeMotion(id<MTLDevice> device, id<MTLLibrary> library,
                                          MTLVertexDescriptor* vertices) {
  OwnedObjectiveC descriptor([[MTLRenderPipelineDescriptor alloc] init]);
  auto desc=(MTLRenderPipelineDescriptor*)descriptor.get();
  desc.colorAttachments[0].pixelFormat=MTLPixelFormatRG16Float;
  desc.colorAttachments[1].pixelFormat=MTLPixelFormatR8Unorm;
  desc.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
  const auto pipeline = [&](OwnedObjectiveC& owner, NSString* vertex, NSString* fragment, bool packed) {
    OwnedObjectiveC v([library newFunctionWithName:vertex]), f([library newFunctionWithName:fragment]);
    desc.vertexFunction=(id<MTLFunction>)v.get(); desc.fragmentFunction=(id<MTLFunction>)f.get();
    desc.vertexDescriptor=packed ? nil : vertices;
    if(v.get()==nil || f.get()==nil) return false;
    owner=OwnedObjectiveC([device newRenderPipelineStateWithDescriptor:desc error:nil]);
    return owner.get()!=nil;
    };
  NSArray<NSString*>* motionNames=@[@"riosMotionVertex",@"riosMotionSkinnedVertex",
                                    @"riosMotionMorphVertex",@"riosMotionInstancedVertex"];
  for(size_t i=0;i<motionPipelines.size();++i)
    if(!pipeline(motionPipelines[i],motionNames[i],@"riosMotionFragment",i==1)) return false;
  if(!pipeline(skyMotionPipeline,@"riosSkyVertex",@"riosSkyMotionFragment",true)) return false;
  desc.colorAttachments[0].writeMask=MTLColorWriteMaskNone;
  auto reactive=desc.colorAttachments[1];
  reactive.blendingEnabled=YES;
  reactive.rgbBlendOperation=MTLBlendOperationMax;
  reactive.alphaBlendOperation=MTLBlendOperationMax;
  reactive.sourceRGBBlendFactor=MTLBlendFactorOne;
  reactive.destinationRGBBlendFactor=MTLBlendFactorOne;
  reactive.sourceAlphaBlendFactor=MTLBlendFactorOne;
  reactive.destinationAlphaBlendFactor=MTLBlendFactorOne;
  NSArray<NSString*>* reactiveNames=@[@"riosLandscapeVertex",@"riosSkinnedVertex",
                                      @"riosMorphVertex",@"riosParticleVertex"];
  for(size_t i=0;i<4;++i)
    if(!pipeline(reactivePipelines[i],reactiveNames[i],@"riosReactiveFragment",i==1 || i==3)) return false;
  if(waterPatchPipeline.get()!=nil) {
    desc.maxTessellationFactor=[device supportsFamily:MTLGPUFamilyApple5] || [device supportsFamily:MTLGPUFamilyMac2] ? 64 : 16;
    desc.tessellationFactorFormat=MTLTessellationFactorFormatHalf;
    desc.tessellationFactorStepFunction=MTLTessellationFactorStepFunctionPerPatch;
    desc.tessellationControlPointIndexType=MTLTessellationControlPointIndexTypeNone;
    desc.tessellationPartitionMode=MTLTessellationPartitionModeFractionalOdd;
    desc.tessellationOutputWindingOrder=MTLWindingClockwise;
    if(!pipeline(reactivePipelines[4],@"riosWaterPatchVertex",@"riosReactiveFragment",true)) return false;
    }
  MTLDepthStencilDescriptor* depth=[MTLDepthStencilDescriptor new];
  depth.depthCompareFunction=MTLCompareFunctionLessEqual;
  depth.depthWriteEnabled=NO;
  motionDepthState=OwnedObjectiveC([device newDepthStencilStateWithDescriptor:depth]);
  [depth release];
  return motionDepthState.get()!=nil;
  }

bool IOSGPUScene::Impl::encodeMotion(id<MTLCommandBuffer> command,
                                      const PreparedFrame::Impl& prepared,
                                      const IOSSceneSnapshot& snapshot) {
  @try {
    auto depth=(id<MTLTexture>)sceneDepth.get();
    const auto allocate = [&](OwnedObjectiveC& texture, MTLPixelFormat format) {
      if(texture.get()!=nil) return true;
      auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
          width:depth.width height:depth.height mipmapped:NO];
      desc.storageMode=MTLStorageModePrivate;
      desc.usage=MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
      texture=OwnedObjectiveC([depth.device newTextureWithDescriptor:desc]);
      return texture.get()!=nil;
      };
    if(!motionReady || !allocate(motionTexture,MTLPixelFormatRG16Float) ||
       !allocate(reactiveTexture,MTLPixelFormatR8Unorm)) return false;
    auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=(id<MTLTexture>)motionTexture.get();
    pass.colorAttachments[1].texture=(id<MTLTexture>)reactiveTexture.get();
    for(NSUInteger i=0;i<2;++i) {
      pass.colorAttachments[i].loadAction=MTLLoadActionClear;
      pass.colorAttachments[i].storeAction=MTLStoreActionStore;
      }
    pass.depthAttachment.texture=depth;
    pass.depthAttachment.loadAction=MTLLoadActionLoad;
    pass.depthAttachment.storeAction=MTLStoreActionStore;
    auto encoder=[command renderCommandEncoderWithDescriptor:pass];
    if(encoder==nil) return false;
    @try {
      encoder.label=@"RendererIOS temporal motion and reactive mask";
      [encoder setViewport:MTLViewport{0,0,double(depth.width),double(depth.height),0,1}];
      const auto& current=snapshot.currentCamera;
      const auto& previous=snapshot.previousCamera;
      IOSMotionConstants motion;
      motion.previousViewProjection=previous.viewProjection;
      motion.jitter={current.jitter.x,current.jitter.y,previous.jitter.x,previous.jitter.y};
      motion.extent={float(current.viewport.width),float(current.viewport.height),
                     float(previous.viewport.width),float(previous.viewport.height)};
      // Rain overlays and underwater distortion have no persistent surface history.
      const float globalReactive=current.underwater ? 1.f : std::clamp(prepared.lighting.skyParameters.y*0.25f,0.f,1.f);
      [encoder setFragmentBytes:&globalReactive length:sizeof(globalReactive) atIndex:1];
      [encoder setFragmentBytes:&motion length:sizeof(motion) atIndex:9];
      [encoder setCullMode:MTLCullModeNone];
      [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)skyMotionPipeline.get()];
      [encoder setFragmentBytes:&prepared.lighting length:sizeof(prepared.lighting) atIndex:0];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [encoder setCullMode:MTLCullModeFront];
      [encoder setDepthStencilState:(id<MTLDepthStencilState>)motionDepthState.get()];
      [encoder setFragmentSamplerState:(id<MTLSamplerState>)samplerState atIndex:0];
      const auto drawGeometry = [&](const auto& draw, bool reactive) {
        const size_t geometry=draw.instanceCount>1 ? 3u : draw.plan.kind==IOSSceneMeshKind::Animated ? 1u :
                              draw.plan.kind==IOSSceneMeshKind::Morph ? 2u : 0u;
        const uint32_t material=uint32_t(draw.plan.materialCategory);
        [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)(reactive
            ? reactivePipelines[draw.tessellationFactors!=nil ? 4u : geometry].get() : motionPipelines[geometry].get())];
        bindGeometry(encoder,draw);
        [encoder setFragmentTexture:(id<MTLTexture>)draw.baseColorTexture atIndex:0];
        [encoder setFragmentBytes:&material length:sizeof(material) atIndex:0];
        if(!reactive) {
          motion.previousModel=draw.previousTransform;
          motion.previousFatness=draw.previousFatness;
          [encoder setVertexBytes:&motion length:sizeof(motion) atIndex:9];
          if(geometry==1 || geometry==2)
            [encoder setVertexBuffer:(id<MTLBuffer>)draw.previousDeformationBuffer offset:0 atIndex:10];
          if(geometry==3)
            [encoder setVertexBuffer:(id<MTLBuffer>)draw.previousInstanceBuffer
                             offset:draw.instanceOffset/sizeof(IOSGPUInstance)*sizeof(IOSMotionInstance) atIndex:11];
          }
        if(draw.tessellationFactors!=nil) {
          [encoder setVertexBuffer:(id<MTLBuffer>)draw.indexBuffer offset:draw.plan.indexBufferOffset atIndex:7];
          [encoder setVertexBytes:&prepared.lighting length:sizeof(prepared.lighting) atIndex:8];
          [encoder setTessellationFactorBuffer:(id<MTLBuffer>)draw.tessellationFactors offset:draw.tessellationOffset instanceStride:0];
          [encoder drawPatches:3 patchStart:0 patchCount:draw.plan.indexCount/3 patchIndexBuffer:nil
             patchIndexBufferOffset:0 instanceCount:1 baseInstance:0];
          }
        else
          [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:draw.plan.indexCount indexType:MTLIndexTypeUInt32
                             indexBuffer:(id<MTLBuffer>)draw.indexBuffer indexBufferOffset:draw.plan.indexBufferOffset
                           instanceCount:draw.instanceCount];
        };
      for(const auto& draw:prepared.base) drawGeometry(draw,false);
      [encoder setCullMode:MTLCullModeNone];
      for(const auto& draw:prepared.water) drawGeometry(draw,true);
      [encoder setCullMode:MTLCullModeFront];
      for(const auto* draws:{&prepared.ghost,&prepared.multiply,
                             &prepared.multiply2,&prepared.additive,&prepared.transparent})
        for(const auto& draw:*draws) drawGeometry(draw,true);
      [encoder setCullMode:MTLCullModeNone];
      [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)reactivePipelines[3].get()];
      [encoder setVertexBuffer:(id<MTLBuffer>)prepared.particleBuffer offset:0 atIndex:0];
      [encoder setVertexBytes:&prepared.particleCamera length:sizeof(prepared.particleCamera) atIndex:1];
      for(size_t i=0;i<prepared.particles.size();++i) {
        const uint32_t material=uint32_t(i);
        [encoder setFragmentBytes:&material length:sizeof(material) atIndex:0];
        for(const auto& value:prepared.particles[i]) {
          [encoder setFragmentTexture:(id<MTLTexture>)value.texture atIndex:0];
          [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
                   instanceCount:value.batch.vertices.count baseInstance:value.batch.vertices.offset];
          }
        }
      }
    @finally { [encoder endEncoding]; }
    return true;
    }
  @catch(NSException*) { return false; }
  }

bool IOSGPUScene::Impl::encodeWaterFactors(id<MTLCommandBuffer> command,
                                          const PreparedFrame::Impl& prepared) {
  if(std::none_of(prepared.water.begin(),prepared.water.end(),[](const auto& d) {
       return d.tessellationFactors!=nil;
       }))
    return true;
  id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
  if(encoder==nil)
    return false;
  @try {
    encoder.label = @"RendererIOS water tessellation factors";
    [encoder setComputePipelineState:(id<MTLComputePipelineState>)waterFactorPipeline.get()];
    for(const auto& draw:prepared.water) {
      if(draw.tessellationFactors==nil)
        continue;
      [encoder setBuffer:(id<MTLBuffer>)draw.vertexBuffer offset:0 atIndex:0];
      [encoder setBytes:&draw.plan.constants length:sizeof(draw.plan.constants) atIndex:1];
      [encoder setBuffer:(id<MTLBuffer>)draw.indexBuffer offset:draw.plan.indexBufferOffset atIndex:2];
      [encoder setBuffer:(id<MTLBuffer>)draw.tessellationFactors offset:draw.tessellationOffset atIndex:3];
      const uint32_t patchCount = uint32_t(draw.plan.indexCount/3);
      [encoder setBytes:&patchCount length:sizeof(patchCount) atIndex:4];
      [encoder dispatchThreadgroups:MTLSizeMake((patchCount+31u)/32u,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
      }
    }
  @finally {
    [encoder endEncoding];
    }
  return true;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_METAL4)
namespace {
struct alignas(16) IOSMetal4DrawUniforms {
  IOSGPUSceneDrawConstants draw;
  IOSDeformationConstants deformation;
  };
constexpr size_t Metal4DrawStride = (sizeof(IOSMetal4DrawUniforms)+255u)&~size_t(255u);
constexpr size_t Metal4DrawOffset = (sizeof(IOSSceneLightingConstants)+255u)&~size_t(255u);
}

bool IOSGPUScene::Impl::prepareMetal4(NativeEncodeContext& context, PreparedFrame::Uploads& uploads) {
  if(@available(iOS 26.0,macOS 26.0,*)) {
    try {
      @try {
        auto& prepared = *context.prepared;
        auto device = (id<MTLDevice>)(void*)Tempest::MetalApi::borrowDevice(owner).get();
        const size_t count = context.metal4End-context.metal4Begin;
        const auto uniforms = PreparedFrame::Uploads::reserve(device,uploads.metal4Uniforms,
            Metal4DrawOffset+count*Metal4DrawStride);
        prepared.metal4Uniforms = uniforms;
        auto bytes = static_cast<std::byte*>(uniforms.contents);
        std::memcpy(bytes,&prepared.lighting,sizeof(prepared.lighting));
        for(size_t i=0;i<count;++i) {
          const auto& draw = prepared.base[context.metal4Begin+i];
          const IOSMetal4DrawUniforms value{draw.plan.constants,draw.deformation};
          std::memcpy(bytes+Metal4DrawOffset+i*Metal4DrawStride,&value,sizeof(value));
          }
        OwnedObjectiveC tableDescriptor([MTL4ArgumentTableDescriptor new]);
        auto tableDesc = (MTL4ArgumentTableDescriptor*)tableDescriptor.get();
        tableDesc.maxBufferBindCount = 7;
        prepared.metal4VertexTable = OwnedObjectiveC([device newArgumentTableWithDescriptor:tableDesc error:nil]);
        tableDesc.maxBufferBindCount = 2;
        tableDesc.maxTextureBindCount = 3;
        tableDesc.maxSamplerStateBindCount = 1;
        prepared.metal4FragmentTable = OwnedObjectiveC([device newArgumentTableWithDescriptor:tableDesc error:nil]);
        OwnedObjectiveC residencyDescriptor([MTLResidencySetDescriptor new]);
        prepared.metal4Residency = OwnedObjectiveC([device newResidencySetWithDescriptor:
            (MTLResidencySetDescriptor*)residencyDescriptor.get() error:nil]);
        if(prepared.metal4VertexTable.get()==nil || prepared.metal4FragmentTable.get()==nil ||
           prepared.metal4Residency.get()==nil)
          return false;
        auto residency = (id<MTLResidencySet>)prepared.metal4Residency.get();
        const auto add = [&](id resource) { if(resource!=nil) [residency addAllocation:resource]; };
        add(uniforms); add(context.sceneHDR); add(sceneDepth.get()); add(prepared.lightBuffer);
        for(const auto& map:shadowMaps) add(map.get());
        for(size_t i=context.metal4Begin;i<context.metal4End;++i) {
          const auto& draw = prepared.base[i];
          add(draw.vertexBuffer); add(draw.indexBuffer); add(draw.baseColorTexture); add(draw.instanceBuffer);
          }
        [residency commit];
        auto fragment = (id<MTL4ArgumentTable>)prepared.metal4FragmentTable.get();
        [fragment setAddress:uniforms.gpuAddress atIndex:0];
        [fragment setAddress:((id<MTLBuffer>)prepared.lightBuffer).gpuAddress atIndex:1];
        for(size_t i=0;i<shadowMaps.size();++i)
          [fragment setTexture:((id<MTLTexture>)shadowMaps[i].get()).gpuResourceID atIndex:i+1];
        [fragment setSamplerState:((id<MTLSamplerState>)samplerState).gpuResourceID atIndex:0];
        return true;
        }
      @catch(NSException*) { return false; }
      }
    catch(...) { return false; }
    }
  return false;
  }

bool IOSGPUScene::Impl::encodeMetal4(void* opaque, MTL::CommandBuffer* prefix,
                                    void* body, MTL::CommandBuffer* suffix) {
  if(@available(iOS 26.0,macOS 26.0,*)) {
    auto& context = *static_cast<NativeEncodeContext*>(opaque);
    auto& prepared = *context.prepared;
    auto& scene = *context.scene;
    context.segment = 1;
    encodeScene(&context,prefix);
    if(context.report.result!=Result::Success)
      return false;
    uint64_t firstDraws = context.report.encodedPhaseDrawCount;
    uint64_t firstTextures = context.report.encodedPhaseTexturedDrawCount;
    auto command = (id<MTL4CommandBuffer>)body;
    [command useResidencySet:(id<MTLResidencySet>)prepared.metal4Residency.get()];
    OwnedObjectiveC descriptor([MTL4RenderPassDescriptor new]);
    auto pass = (MTL4RenderPassDescriptor*)descriptor.get();
    auto color = (id<MTLTexture>)context.sceneHDR;
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = (id<MTLTexture>)scene.sceneDepth.get();
    pass.depthAttachment.loadAction = MTLLoadActionLoad;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    auto encoder = [command renderCommandEncoderWithDescriptor:pass];
    if(encoder==nil)
      return false;
    @try {
      encoder.label = @"RendererIOS Metal4 opaque";
      [encoder setViewport:MTLViewport{0,0,double(color.width),double(color.height),0,1}];
      [encoder setFrontFacingWinding:MTLWindingClockwise];
      [encoder setCullMode:MTLCullModeFront];
      [encoder setDepthStencilState:(id<MTLDepthStencilState>)scene.baseDepthState];
      auto vertex = (id<MTL4ArgumentTable>)prepared.metal4VertexTable.get();
      auto fragment = (id<MTL4ArgumentTable>)prepared.metal4FragmentTable.get();
      [encoder setArgumentTable:vertex atStages:MTLRenderStageVertex];
      [encoder setArgumentTable:fragment atStages:MTLRenderStageFragment];
      for(size_t i=context.metal4Begin;i<context.metal4End;++i) {
        const auto& draw = prepared.base[i];
        const uint64_t uniforms = ((id<MTLBuffer>)prepared.metal4Uniforms).gpuAddress+
            Metal4DrawOffset+(i-context.metal4Begin)*Metal4DrawStride;
        [vertex setAddress:((id<MTLBuffer>)draw.vertexBuffer).gpuAddress atIndex:0];
        [vertex setAddress:uniforms atIndex:1];
        [vertex setAddress:uniforms+offsetof(IOSMetal4DrawUniforms,deformation) atIndex:2];
        if(draw.instanceCount>1)
          [vertex setAddress:((id<MTLBuffer>)draw.instanceBuffer).gpuAddress+draw.instanceOffset atIndex:6];
        [fragment setTexture:((id<MTLTexture>)draw.baseColorTexture).gpuResourceID atIndex:0];
        [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)draw.pipelineState];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:draw.plan.indexCount
             indexType:MTLIndexTypeUInt32
             indexBuffer:((id<MTLBuffer>)draw.indexBuffer).gpuAddress+draw.plan.indexBufferOffset
             indexBufferLength:draw.plan.indexCount*sizeof(uint32_t) instanceCount:draw.instanceCount
             baseVertex:0 baseInstance:0];
        firstDraws += draw.instanceCount;
        firstTextures += draw.instanceCount;
        }
      }
    @finally { [encoder endEncoding]; }
    context.segment = 2;
    encodeScene(&context,suffix);
    context.report.encodedPhaseDrawCount += firstDraws;
    context.report.encodedPhaseTexturedDrawCount += firstTextures;
    return context.report.result==Result::Success;
    }
  return false;
  }
#endif

void IOSGPUScene::Impl::encodeScene(void* opaque, MTL::CommandBuffer* nativeCommand) {
  auto& context = *static_cast<NativeEncodeContext*>(opaque);
  auto& scene = *context.scene;
  auto& prepared = *context.prepared;
  id<MTLCommandBuffer> command = (id<MTLCommandBuffer>)(void*)nativeCommand;
  @try {
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
    if(context.segment!=2 && prepared.rays!=nullptr &&
       !scene.rayTracing->encodeBuilds(*prepared.rays,nativeCommand)) {
      context.report.rayTracingFailed=true;
      context.report.result=Result::NativeEncodingFailed;
      return;
      }
#endif
    if(context.segment!=2 && (!scene.encodeShadows(command,prepared) || !scene.encodeSkyLut(command,prepared) ||
       !scene.encodeWaterFactors(command,prepared))) {
      context.report.result = Result::NativeEncodingFailed;
      return;
      }
    if(context.sceneHDR==nil)
      return; // Retained alpha-test causal path owns its later Tempest render pass.
    id<MTLTexture> color = (id<MTLTexture>)context.sceneHDR;
    id<MTLTexture> depth = (id<MTLTexture>)scene.sceneDepth.get();
    const auto copyScene = [&](bool copyDepth) {
      id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
      if(blit==nil)
        throw std::runtime_error("RendererIOS scene copy encoder unavailable");
      @try {
        const MTLSize size = MTLSizeMake(color.width,color.height,1);
        [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                   sourceSize:size toTexture:(id<MTLTexture>)scene.sceneColorCopy.get()
             destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        if(copyDepth)
          [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                     sourceSize:size toTexture:(id<MTLTexture>)scene.sceneDepthCopy.get()
               destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        }
      @finally {
        [blit endEncoding];
        }
      };
    OwnedObjectiveC sceneLabel;
    if(!context.sceneMarker.empty())
      sceneLabel = OwnedObjectiveC([[NSString alloc] initWithBytes:context.sceneMarker.data()
          length:context.sceneMarker.size() encoding:NSUTF8StringEncoding]);
    const auto render = [&](uint8_t phase, bool clear, bool underwater) {
      MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = color;
      pass.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      if(!underwater) {
        pass.depthAttachment.texture = depth;
        pass.depthAttachment.loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = 1.0;
        }
      id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
      if(encoder==nil)
        throw std::runtime_error("RendererIOS scene encoder unavailable");
      @try {
        encoder.label = clear && sceneLabel.get()!=nil ? (NSString*)sceneLabel.get() :
            underwater ? @"RendererIOS underwater" : @"RendererIOS scene";
        [encoder setViewport:MTLViewport{0,0,double(color.width),double(color.height),0,1}];
        if(underwater) {
          [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)scene.underwaterPipeline.get()];
          [encoder setCullMode:MTLCullModeNone];
          [encoder setFragmentBytes:&prepared.lighting length:sizeof(prepared.lighting) atIndex:0];
          [encoder setFragmentTexture:(id<MTLTexture>)scene.sceneColorCopy.get() atIndex:9];
          [encoder setFragmentTexture:depth atIndex:10];
          [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
          }
        else {
          context.phase = phase;
          encodeLandscape(&context,(MTL::RenderCommandEncoder*)(void*)encoder);
          }
        }
      @finally {
        [encoder endEncoding];
        }
      };
    const bool copies = prepared.needsSceneCopy();
    bool ao=false;
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
    ao=prepared.rays!=nullptr && (prepared.rayTracingMode==1 || prepared.rayTracingMode==3) && context.output!=nullptr;
#endif
    render(ao ? 5u : copies || context.segment==1 ? 3u : 0u,context.segment!=2,false);
    if(context.segment==1)
      return;
    if(context.report.result!=Result::Success)
      return;
    bool motionEncoded=false;
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
    if(ao) {
      motionEncoded=scene.encodeMotion(command,prepared,context.output->snapshot);
      if(!scene.rayTracing->encodeAmbientOcclusion(*prepared.rays,nativeCommand,(MTL::Texture*)(void*)color,
          (MTL::Texture*)(void*)depth,motionEncoded ? (MTL::Texture*)(void*)scene.motionTexture.get() : nullptr,
          motionEncoded ? (MTL::Texture*)(void*)scene.reactiveTexture.get() : nullptr,context.output->snapshot)) {
        context.report.rayTracingFailed=true;
        context.report.result=Result::NativeEncodingFailed;
        return;
        }
      const auto baseDraws=context.report.encodedPhaseDrawCount;
      const auto baseTextures=context.report.encodedPhaseTexturedDrawCount;
      render(6u,false,false);
      context.report.encodedPhaseDrawCount+=baseDraws;
      context.report.encodedPhaseTexturedDrawCount+=baseTextures;
      }
#endif
    if(copies || ao) {
      const auto baseDraws = context.report.encodedPhaseDrawCount;
      const auto baseTextures = context.report.encodedPhaseTexturedDrawCount;
      if(copies) copyScene(!prepared.water.empty());
      render(4u,false,false);
      context.report.encodedPhaseDrawCount += baseDraws;
      context.report.encodedPhaseTexturedDrawCount += baseTextures;
      }
    if(context.report.result==Result::Success && prepared.lighting.lightInfo[2]!=0) {
      copyScene(false);
      render(0u,false,true);
      }
    if(context.report.result==Result::Success && context.output!=nullptr) {
      const auto& output=*context.output;
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
      if(prepared.rays!=nullptr && prepared.rayTracingMode==2 &&
         !scene.rayTracing->encodeDebug(*prepared.rays,nativeCommand,(MTL::Texture*)(void*)color,output.snapshot.currentCamera)) {
        context.report.rayTracingFailed=true;
        context.report.result=Result::NativeEncodingFailed;
        return;
        }
#endif
      IOSUpscalerTemporalInputs temporal;
      if(output.upscaler.activeMode()==IOSUpscalerMode::Temporal &&
         (ao ? motionEncoded : scene.encodeMotion(command,prepared,output.snapshot)))
        temporal = {(MTL::Texture*)(void*)depth,(MTL::Texture*)(void*)scene.motionTexture.get(),
                    (MTL::Texture*)(void*)scene.reactiveTexture.get()};
      if(!output.upscaler.encodeNative(nativeCommand,(MTL::Texture*)(void*)color,temporal,output.snapshot,output.tone))
        context.report.result=Result::NativeEncodingFailed;
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
      if(context.report.result==Result::Success && prepared.rays!=nullptr)
        context.report.rayTracingEncodedMode=ao ? (prepared.rays->ready() ? 1 : 3)
            : prepared.rayTracingMode==2 && prepared.rays->ready() ? 2 : 0;
#endif
      }
    }
  @catch(NSException*) {
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
    context.report.rayTracingFailed=prepared.rays!=nullptr;
#endif
    prepared.nativeException = true;
    context.report.result = Result::NativeEncodingFailed;
    }
  }

bool IOSGPUScene::encodePreparedEnvironment(Tempest::Encoder<Tempest::CommandBuffer>& encoder,
                                           PreparedFrame& prepared) noexcept {
  if(impl==nullptr || prepared.impl==nullptr || !prepared.impl->ready)
    return false;
  Impl::NativeEncodeContext context;
  context.scene = impl.get();
  context.prepared = prepared.impl.get();
  context.report.result = Result::Success;
  try {
    return Tempest::MetalApi::withActiveCommandBuffer(impl->owner,encoder,&context,&Impl::encodeScene) &&
           context.report.result==Result::Success;
    }
  catch(...) {
    return false;
    }
  }

IOSGPUScene::Report IOSGPUScene::encodePreparedScene(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder, PreparedFrame& prepared,
    const Tempest::Attachment& sceneHDR, std::string_view marker, const SceneOutput* output) noexcept {
  Report failure = makeReport(Result::NativeEncodingFailed);
  if(impl==nullptr || prepared.impl==nullptr || !prepared.impl->ready)
    return failure;
  Impl::NativeEncodeContext context;
  context.scene = impl.get();
  context.prepared = prepared.impl.get();
  context.report = prepared.impl->report;
  try {
    const auto& texture = Tempest::textureCast<const Tempest::Texture2d&>(sceneHDR);
    const auto borrowed = Tempest::MetalApi::borrowTexture(impl->owner,texture);
    if(!borrowed)
      return failure;
    context.sceneHDR = (id)(void*)borrowed.get();
    context.sceneMarker = marker;
    context.output = output;
    impl->ensureSceneTargets((id<MTLTexture>)context.sceneHDR,*prepared.impl);
    bool encoded = false;
    bool metal4Unavailable = false, metal4Failed = false;
    uint64_t metal4DrawCount = 0;
#if defined(OPENGOTHIC_RENDERER_IOS_METAL4)
    if(output!=nullptr && output->metal4Requested) {
      const auto& draws = prepared.impl->base;
      while(context.metal4Begin<draws.size() && !draws[context.metal4Begin].metal4Eligible)
        ++context.metal4Begin;
      context.metal4End = context.metal4Begin;
      while(context.metal4End<draws.size() && draws[context.metal4End].metal4Eligible)
        ++context.metal4End;
      if(context.metal4Begin!=context.metal4End) {
        if(impl->prepareMetal4(context,*prepared.uploads)) {
          auto result = Tempest::Metal4InteropResult::Failed;
          try { result = Tempest::MetalApi::stageMetal4Interop(impl->owner,encoder,&context,&Impl::encodeMetal4); }
          catch(...) {}
          encoded = result==Tempest::Metal4InteropResult::Encoded;
          metal4Failed = result==Tempest::Metal4InteropResult::Failed;
          metal4Unavailable = result==Tempest::Metal4InteropResult::Unsupported;
          if(encoded) metal4DrawCount = context.metal4End-context.metal4Begin;
          }
        else { metal4Unavailable = true; }
        }
      }
#endif
    if(!encoded && !metal4Failed)
      encoded = Tempest::MetalApi::withActiveCommandBuffer(impl->owner,encoder,&context,&Impl::encodeScene);
    prepared.impl->ready = false;
    context.report.metal4Unavailable = metal4Unavailable;
    context.report.metal4Failed = metal4Failed;
    context.report.metal4DrawCount = metal4DrawCount;
    if(!encoded || !prepared.impl->nativeCompleted || prepared.impl->nativeException)
      context.report.result = Result::NativeEncodingFailed;
    return context.report;
    }
  catch(...) {
    prepared.impl->ready = false;
    return failure;
    }
  }

void IOSGPUScene::Impl::encodeLandscape(
    void* opaque,
    MTL::RenderCommandEncoder* nativeEncoder) {
  if(opaque==nullptr)
    return;
  auto& context = *static_cast<NativeEncodeContext*>(opaque);
  if(context.scene==nullptr || context.prepared==nullptr ||
     nativeEncoder==nullptr ||
     context.prepared->owner!=context.scene ||
     !context.prepared->ready) {
    context.report.result = IOSGPUScene::Result::NativeEncodingFailed;
    recordFailure(context.report.failures.nativeEncode,context.report);
    recordPlannedDrawnFailure(context.report);
    return;
    }

  id<MTLRenderCommandEncoder> encoder =
      (id<MTLRenderCommandEncoder>)(void*)nativeEncoder;
  context.report.encodedPhaseDrawCount = 0u;
  context.report.encodedPhaseTexturedDrawCount = 0u;
  const auto restoreEncoderState = [&]() {
    [encoder setFragmentTexture:nil atIndex:0u];
    [encoder setFragmentSamplerState:nil atIndex:0u];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFrontFacingWinding:MTLWindingClockwise];
    };
  const auto encodePhase = [&](
      const std::vector<IOSGPUSceneNativePreparedDraw>& draws,
      id depthState, size_t begin = 0, size_t end = std::numeric_limits<size_t>::max()) {
    [encoder setDepthStencilState:(id<MTLDepthStencilState>)depthState];
    for(size_t i=begin;i<std::min(end,draws.size());++i) {
      const auto& draw = draws[i];
      [encoder setRenderPipelineState:
          (id<MTLRenderPipelineState>)draw.pipelineState];
      bindGeometry(encoder,draw);
      [encoder setFragmentBytes:&draw.plan.constants length:sizeof(draw.plan.constants) atIndex:3];
      [encoder setFragmentTexture:(id<MTLTexture>)draw.baseColorTexture
                           atIndex:0u];
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      const bool emitDrawSignposts =
          context.prepared->causalRoute==
              IOSGPUSceneCausalFrameRoute::Target;
#elif defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
      defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
      const bool emitDrawSignposts =
          draw.drawId.get()!=nil && draw.drawBind.get()!=nil;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
      if(emitDrawSignposts) {
        [encoder insertDebugSignpost:(NSString*)draw.drawId.get()];
        [encoder insertDebugSignpost:(NSString*)draw.drawBind.get()];
        }
#endif
      if(draw.tessellationFactors!=nil) {
        [encoder setVertexBuffer:(id<MTLBuffer>)draw.indexBuffer offset:draw.plan.indexBufferOffset atIndex:7];
        [encoder setVertexBytes:&context.prepared->lighting length:sizeof(context.prepared->lighting) atIndex:8];
        [encoder setTessellationFactorBuffer:(id<MTLBuffer>)draw.tessellationFactors offset:draw.tessellationOffset instanceStride:0];
        [encoder drawPatches:3 patchStart:0 patchCount:draw.plan.indexCount/3 patchIndexBuffer:nil
           patchIndexBufferOffset:0 instanceCount:1 baseInstance:0];
        }
      else {
      [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                          indexCount:draw.plan.indexCount
                           indexType:MTLIndexTypeUInt32
                         indexBuffer:(id<MTLBuffer>)draw.indexBuffer
                   indexBufferOffset:draw.plan.indexBufferOffset
                       instanceCount:draw.instanceCount
                          baseVertex:0
                        baseInstance:0u];
        }
      context.report.encodedPhaseDrawCount += draw.instanceCount;
      if(draw.baseColorTexture!=nil)
        context.report.encodedPhaseTexturedDrawCount += draw.instanceCount;
      }
    };

  @try {
    context.scene->bindLighting(encoder,*context.prepared);
    [encoder setFragmentBytes:&context.prepared->viewProjection length:sizeof(context.prepared->viewProjection) atIndex:4];
    [encoder setFragmentBytes:&context.prepared->cloudOffsets length:sizeof(context.prepared->cloudOffsets) atIndex:2];
    [encoder setFragmentTexture:(id<MTLTexture>)context.scene->sceneColorCopy.get() atIndex:9];
    [encoder setFragmentTexture:(id<MTLTexture>)context.scene->sceneDepthCopy.get() atIndex:10];
    [encoder setFragmentTexture:(id<MTLTexture>)context.scene->skyLut.get() atIndex:11];
    for(size_t i=0;i<context.prepared->skyImages.size();++i)
      [encoder setFragmentTexture:(id<MTLTexture>)context.prepared->skyImages[i] atIndex:i+3];
    [encoder setFrontFacingWinding:MTLWindingClockwise];
    [encoder setCullMode:MTLCullModeFront];
    [encoder setFragmentSamplerState:
        (id<MTLSamplerState>)context.scene->samplerState
                            atIndex:0u];
    if(context.phase==0u || context.phase==1u || context.phase==3u || context.phase==5u) {
      if(context.segment!=2)
        context.scene->encodeSky(encoder,*context.prepared);
      encodePhase(context.prepared->base,context.scene->baseDepthState,
                  context.segment==2 ? context.metal4End : 0,
                  context.segment==1 ? context.metal4Begin : context.prepared->base.size());
      }
    if(context.segment!=1 && (context.phase==0u || context.phase==1u || context.phase==3u || context.phase==6u)) {
      context.scene->encodeParticles(encoder,*context.prepared,IOSMaterialCategory::Opaque);
      context.scene->encodeParticles(encoder,*context.prepared,IOSMaterialCategory::AlphaTest);
      }
    if(context.phase==0u || context.phase==1u || context.phase==4u) {
      [encoder setCullMode:MTLCullModeNone];
      encodePhase(context.prepared->water,context.scene->baseDepthState);
      [encoder setCullMode:MTLCullModeFront];
      encodePhase(context.prepared->ghost,context.scene->baseDepthState);
      context.scene->encodeParticles(encoder,*context.prepared,IOSMaterialCategory::Ghost);
      encodePhase(context.prepared->multiply,context.scene->multiply2DepthState);
      context.scene->encodeParticles(encoder,*context.prepared,IOSMaterialCategory::Multiply);
      encodePhase(context.prepared->multiply2,
                  context.scene->multiply2DepthState);
      context.scene->encodeParticles(encoder,*context.prepared,IOSMaterialCategory::Multiply2);
      context.prepared->nativeBaseMultiplyCompleted = true;
      }
    if(context.phase==0u || context.phase==2u || context.phase==4u) {
      encodePhase(context.prepared->additive,
                  context.scene->additiveDepthState);
      context.scene->encodeParticles(encoder,*context.prepared,IOSMaterialCategory::Additive);
      encodePhase(context.prepared->transparent,
                  context.scene->additiveDepthState);
      context.scene->encodeParticles(encoder,*context.prepared,IOSMaterialCategory::Transparent);
      context.scene->encodeRain(encoder,*context.prepared);
      context.prepared->nativeAdditiveCompleted = true;
      }
    restoreEncoderState();
    context.prepared->nativeCompleted =
        context.prepared->nativeBaseMultiplyCompleted &&
        context.prepared->nativeAdditiveCompleted;
    const uint64_t encodedPhaseDrawCount =
        context.report.encodedPhaseDrawCount;
    const uint64_t encodedPhaseTexturedDrawCount =
        context.report.encodedPhaseTexturedDrawCount;
    context.report = context.prepared->report;
    context.report.encodedPhaseDrawCount = encodedPhaseDrawCount;
    context.report.encodedPhaseTexturedDrawCount =
        encodedPhaseTexturedDrawCount;
    }
  @catch(NSException* exception) {
    (void)exception;
    context.prepared->nativeException = true;
    context.report.result = IOSGPUScene::Result::NativeEncodingFailed;
    recordFailure(context.report.failures.nativeEncode,context.report);
    recordPlannedDrawnFailure(context.report);
    }
  }
IOSGPUScene::IOSGPUScene(Tempest::Device& device, TargetLayout target)
  : impl(std::make_unique<Impl>(device,target)) {
  }

IOSGPUScene::~IOSGPUScene() = default;

bool IOSGPUScene::pipelinesReady() const noexcept {
  return impl!=nullptr &&
         impl->initializationResult==IOSGPUScene::Result::Success;
  }

bool IOSGPUScene::additiveTerminalFailureReported() const noexcept {
  return impl!=nullptr && impl->emissiveTerminalReported;
  }

IOSGPUScene::PreparedFrame::PreparedFrame() noexcept = default;
IOSGPUScene::PreparedFrame::~PreparedFrame() = default;
IOSGPUScene::PreparedFrame::PreparedFrame(PreparedFrame&&) noexcept = default;
IOSGPUScene::PreparedFrame& IOSGPUScene::PreparedFrame::operator=(
    PreparedFrame&&) noexcept = default;

void IOSGPUScene::PreparedFrame::markSubmitted() noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
  if(impl!=nullptr && impl->rays!=nullptr) impl->rays->markSubmitted();
#endif
  }

void IOSGPUScene::PreparedFrame::completeConfirmed() noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
  if(uploads!=nullptr) uploads->rays.completeConfirmed();
#endif
  }

bool IOSGPUScene::PreparedFrame::ready() const noexcept {
  return impl!=nullptr && impl->ready;
  }

IOSGPUScene::AdditiveInputArtifact
    IOSGPUScene::PreparedFrame::takeAdditiveInputArtifact() noexcept {
  if(impl==nullptr || !impl->ready || impl->nativeException ||
     impl->report.result!=IOSGPUScene::Result::Success)
    return {};
  IOSGPUScene::AdditiveInputArtifact result =
      std::move(impl->additiveInput);
  impl->additiveInput = {};
  return result;
  }

IOSGPUScene::Multiply2InputArtifact
    IOSGPUScene::PreparedFrame::takeMultiply2InputArtifact() noexcept {
  if(impl==nullptr || !impl->ready || impl->nativeException ||
     impl->report.result!=IOSGPUScene::Result::Success)
    return {};
  IOSGPUScene::Multiply2InputArtifact result =
      std::move(impl->multiply2Input);
  impl->multiply2Input = {};
  return result;
  }

IOSGPUScene::Report IOSGPUScene::prepareFrame(
    PreparedFrame& prepared,
    uint64_t targetGeneration,
    const IOSSceneSnapshot& snapshot,
    const IOSSceneAssetRegistry& assets,
    const IOSFrameAnimationEvidence* frameAnimation,
    const IOSUVAnimationEvidence* uvAnimation, bool temporal, int rayTracingMode) noexcept {
#if !defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
  (void)rayTracingMode;
#else
  temporal |= rayTracingMode==1 || rayTracingMode==3;
#endif
  prepared.impl.reset();
  (void)targetGeneration;
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
  if(!iosGPUSceneProductionPipelineStatesAreAvailable(
         impl->opaquePipelineState!=nil,
         impl->alphaTestPipelineState!=nil,
         impl->additivePipelineState!=nil,
         impl->multiply2PipelineState!=nil) ||
     !iosGPUSceneProductionDepthStatesAreAvailable(
         impl->baseDepthState!=nil,impl->additiveDepthState!=nil,
         impl->multiply2DepthState!=nil) ||
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
     impl->multiply2VisibilityPipelineState==nil ||
     impl->multiply2VisibilityRasterDepthState==nil ||
     impl->multiply2VisibilityStencilDepthState==nil ||
#endif
     impl->samplerState==nil) {
    report.result = Result::PipelineUnavailable;
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
    prepared.impl.reset();
    return failure;
    };
  IOSGPUSceneCausalFrameRoute causalRoute =
      IOSGPUSceneCausalFrameRoute::Production;
  IOSGPUSceneCausalRuntimeState causalPrepared = impl->causalState;
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
    if(prepared.uploads==nullptr)
      prepared.uploads = std::make_unique<PreparedFrame::Uploads>();
    auto nativeDevice = (id<MTLDevice>)(void*)assets.nativeDevice().get();
    PreparedFrame::Uploads::write(nativeDevice,prepared.uploads->bones,
        snapshot.currentBones.data(),snapshot.currentBones.size()*sizeof(IOSMatrix4x4));
    PreparedFrame::Uploads::write(nativeDevice,prepared.uploads->morphLayers,
        snapshot.currentMorphLayers.data(),snapshot.currentMorphLayers.size()*sizeof(IOSMorphLayer));
    if(temporal) {
      PreparedFrame::Uploads::write(nativeDevice,prepared.uploads->previousBones,
          snapshot.previousBones.data(),snapshot.previousBones.size()*sizeof(IOSMatrix4x4));
      PreparedFrame::Uploads::write(nativeDevice,prepared.uploads->previousMorphLayers,
          snapshot.previousMorphLayers.data(),snapshot.previousMorphLayers.size()*sizeof(IOSMorphLayer));
      }
    auto candidateFrame = std::make_unique<PreparedFrame::Impl>();
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
    std::vector<IOSRayTracing::Geometry> rayGeometry;
#endif
    candidateFrame->owner = impl.get();
    candidateFrame->lighting = iosSceneLighting(snapshot.currentSky,snapshot.currentCamera);
    candidateFrame->lighting.fogParameters.z = float(snapshot.sceneTimeMs%60000u)/1000.f;
    candidateFrame->lighting.lightInfo[1] = uint32_t(snapshot.sceneTimeMs);
    candidateFrame->lighting.lightInfo[2] = snapshot.currentCamera.underwater ? 1u : 0u;
    candidateFrame->viewProjection = snapshot.currentCamera.viewProjection;
    std::vector<IOSPointLightConstants> lights;
    lights.reserve(std::max(size_t(1),snapshot.lights.size()));
    for(const auto& light:snapshot.lights) {
      if(light.type!=IOSLightType::Point || light.range<=0.f ||
         (light.visibilityMask&IOSSceneVisibilityMain)==0 ||
         !iosGPUScenePointLightVisible(light,snapshot.currentCamera.viewProjection))
        continue;
      const float scale = light.intensity*candidateFrame->lighting.ambientColor.w;
      lights.push_back({{light.position.x,light.position.y,light.position.z,light.range},
                        {light.color.x*scale,light.color.y*scale,light.color.z*scale,0.f}});
      }
    candidateFrame->lighting.lightInfo[0] = uint32_t(lights.size());
    if(lights.empty())
      lights.emplace_back();
    PreparedFrame::Uploads::write(nativeDevice,prepared.uploads->lights,
        lights.data(),lights.size()*sizeof(IOSPointLightConstants));
    candidateFrame->lightBuffer = prepared.uploads->lights.get();
    candidateFrame->cloudOffsets = snapshot.currentSky.cloudOffsets;
    candidateFrame->skyReady = (snapshot.featureMask&IOSSceneFeatureSky)!=0;
    for(size_t i=0;i<candidateFrame->skyImages.size();++i) {
      const auto* image = assets.lookupTexture(snapshot.currentSky.textures[i]);
      candidateFrame->skyImages[i] = image!=nullptr ? (id)(void*)image->texture.get() : nil;
      candidateFrame->skyReady &= candidateFrame->skyImages[i]!=nil;
      }
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    candidateFrame->causalRoute = causalRoute;
    candidateFrame->causalPrepared = causalPrepared;
#endif
    candidateFrame->particleCamera.viewProjection = snapshot.currentCamera.viewProjection;
    candidateFrame->particleCamera.view = snapshot.currentCamera.view;
    const auto basis = [&](size_t row) {
      const auto& vp = snapshot.currentCamera.viewProjection;
      const auto& camera = snapshot.currentCamera;
      const float jitter = row==0 ? 2.f*camera.jitter.x/float(camera.viewport.width) :
                           row==1 ? 2.f*camera.jitter.y/float(camera.viewport.height) : 0.f;
      const float x = vp.at(row,0)-jitter*vp.at(3,0), y = vp.at(row,1)-jitter*vp.at(3,1),
                  z = vp.at(row,2)-jitter*vp.at(3,2);
      const float scale = 1.f/std::sqrt(x*x+y*y+z*z);
      return IOSFloat4{x*scale,y*scale,z*scale,0.f};
      };
    candidateFrame->particleCamera.left = basis(0);
    candidateFrame->particleCamera.top = basis(1);
    candidateFrame->particleCamera.depth = basis(2);
    std::vector<IOSParticleVertex> particleVertices;
    particleVertices.reserve(snapshot.particles.size());
    struct TransparentParticle { uint32_t vertex; size_t batch; float depth; };
    std::vector<TransparentParticle> transparentParticles;
    const auto appendParticles = [&](const IOSParticleBatch& batch, uint32_t offset, uint32_t count) {
      const auto* texture = assets.lookupTexture(batch.texture);
      if(texture==nullptr || !texture->texture)
        throw std::runtime_error("RendererIOS particle texture unavailable");
      IOSParticlePreparedBatch next{batch,(id)(void*)texture->texture.get()};
      next.batch.vertices = {uint32_t(particleVertices.size()),count};
      particleVertices.insert(particleVertices.end(),snapshot.particles.begin()+offset,
                              snapshot.particles.begin()+offset+count);
      auto& batches = candidateFrame->particles[size_t(batch.material)];
      if(!batches.empty() && batches.back().texture==next.texture &&
         batches.back().batch.vertices.offset+batches.back().batch.vertices.count==next.batch.vertices.offset)
        batches.back().batch.vertices.count += count;
      else
        batches.push_back(next);
      };
    for(size_t i=0;i<snapshot.particleBatches.size();++i) {
      const auto& batch = snapshot.particleBatches[i];
      if(batch.material!=IOSMaterialCategory::Transparent) {
        appendParticles(batch,batch.vertices.offset,batch.vertices.count);
        continue;
        }
      const auto& vp = snapshot.currentCamera.viewProjection;
      for(uint32_t v=batch.vertices.offset;v<batch.vertices.offset+batch.vertices.count;++v) {
        const auto& p = snapshot.particles[v];
        const bool trail = (p.bits&8u)!=0;
        const IOSFloat3 pos = {p.position.x+(trail ? p.direction.x*0.5f : 0.f),
                              p.position.y+(trail ? p.direction.y*0.5f : 0.f),
                              p.position.z+(trail ? p.direction.z*0.5f : 0.f)};
        const float depth = vp.at(3,0)*pos.x+vp.at(3,1)*pos.y+vp.at(3,2)*pos.z+vp.at(3,3);
        transparentParticles.push_back({v,i,depth});
        }
      }
    std::stable_sort(transparentParticles.begin(),transparentParticles.end(),
        [](const auto& a,const auto& b) { return a.depth>b.depth; });
    for(const auto& particle:transparentParticles)
      appendParticles(snapshot.particleBatches[particle.batch],particle.vertex,1);
    PreparedFrame::Uploads::write(nativeDevice,prepared.uploads->particles,
        particleVertices.data(),particleVertices.size()*sizeof(IOSParticleVertex));
    candidateFrame->particleBuffer = prepared.uploads->particles.get();
    candidateFrame->lighting.lightInfo[3] = candidateFrame->skyReady ? 1u : 0u;
    candidateFrame->base.reserve(snapshot.entities.size());
    candidateFrame->multiply2.reserve(snapshot.entities.size());
    candidateFrame->additive.reserve(snapshot.entities.size());
#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)
    std::vector<IOSAdditiveInputRecordV1> baseRecords;
    std::vector<IOSAdditiveInputRecordV1> additiveRecords;
    baseRecords.reserve(snapshot.entities.size());
    additiveRecords.reserve(snapshot.entities.size());
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
    std::vector<IOSMultiply2InputRecordV1> multiply2BaseRecords;
    std::vector<IOSMultiply2InputRecordV1> multiply2Records;
    multiply2BaseRecords.reserve(snapshot.entities.size());
    multiply2Records.reserve(1u);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SIMULATOR_SMOKE)
    std::size_t simulatorSelectedDraws = 0u;
    std::size_t simulatorCulledDraws = 0u;
    std::size_t simulatorBudgetSkippedDraws = 0u;
#endif

    for(const auto& entity:snapshot.entities) {
      const auto source = candidate(
          snapshot,assets,impl->textureValidation,entity);
      IOSGPUSceneDrawPlan plan;
      const IOSGPUSceneDrawPlanResult planned =
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
      const auto* mesh = assets.lookupMesh(entity.mesh);
      const auto* texture = assets.lookupTexture(plan.baseColorTexture);
      // Inactive morph layers leave the base mesh bounds unchanged.
      const bool canCullByBounds = entity.fatness==0.f && plan.kind!=IOSSceneMeshKind::Animated &&
          (plan.kind!=IOSSceneMeshKind::Morph || std::none_of(
              snapshot.currentMorphLayers.begin()+entity.morphRange.offset,
              snapshot.currentMorphLayers.begin()+entity.morphRange.offset+entity.morphRange.count,
              [](const auto& layer) { return layer.intensity!=0.f; }));
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
      if((rayTracingMode==1 || rayTracingMode==2) && !impl->rayTracingUnavailable && mesh!=nullptr &&
         (entity.kind==IOSSceneMeshKind::Landscape || entity.kind==IOSSceneMeshKind::Static) &&
         plan.pipeline==IOSGPUScenePipelineSelector::Opaque && entity.fatness==0.f &&
         plan.constants.waveMaxAmplitude==0.f) {
        rayGeometry.push_back({entity.mesh.value,mesh->vertexBuffer.get(),mesh->indexBuffer.get(),
            mesh->metadata.vertexStride,mesh->metadata.firstIndex,mesh->metadata.indexCount,entity.currentTransform});
        }
#endif
      const auto nativeDraw = [&]() {
        IOSGPUSceneNativePreparedDraw draw;
        draw.plan = plan;
        draw.previousTransform = entity.previousTransform;
        draw.previousFatness = entity.previousFatness;
        draw.previousDeformationBuffer = plan.kind==IOSSceneMeshKind::Animated
            ? prepared.uploads->previousBones.get() : prepared.uploads->previousMorphLayers.get();
        draw.deformation = {entity.boneRange.offset,entity.morphRange.offset,
                            entity.morphRange.count,entity.fatness};
        draw.deformationBuffer = plan.kind==IOSSceneMeshKind::Animated
            ? prepared.uploads->bones.get() : prepared.uploads->morphLayers.get();
        draw.morphIndices = (id)(void*)mesh->morphIndices.get();
        draw.morphSamples = (id)(void*)mesh->morphSamples.get();
        draw.vertexBuffer = (id)(void*)mesh->vertexBuffer.get();
        draw.indexBuffer = (id)(void*)mesh->indexBuffer.get();
        draw.baseColorTexture = (id)(void*)texture->texture.get();
        draw.metal4Eligible = (plan.kind==IOSSceneMeshKind::Landscape || plan.kind==IOSSceneMeshKind::Static) &&
                             plan.pipeline==IOSGPUScenePipelineSelector::Opaque && draw.baseColorTexture!=nil;
        return draw;
        };
      if(snapshot.currentSky.shadowsEnabled && (entity.visibilityMask&IOSSceneVisibilityShadow)!=0 &&
         (plan.pipeline==IOSGPUScenePipelineSelector::Opaque ||
          plan.pipeline==IOSGPUScenePipelineSelector::AlphaTest)) {
        const size_t geometry = plan.kind==IOSSceneMeshKind::Animated ? 1u :
                                plan.kind==IOSSceneMeshKind::Morph ? 2u : 0u;
        const size_t alpha = plan.pipeline==IOSGPUScenePipelineSelector::AlphaTest ? 1u : 0u;
        for(size_t layer=0;layer<2;++layer) {
          if(canCullByBounds &&
             classifyIOSGPUSceneMultiply2ClipBounds(entity.bounds,plan.constants.model,
                 snapshot.currentSky.viewShadow[layer])==IOSGPUSceneMultiply2ClipBoundsResult::DefinitelyOutside)
            continue;
          auto draw = nativeDraw();
          draw.plan.constants.viewProjection = snapshot.currentSky.viewShadow[layer];
          draw.pipelineState = impl->shadowPipelines[geometry*2+alpha].get();
          candidateFrame->shadows[layer].push_back(std::move(draw));
          }
        }
      const auto selectedTexture = [&](const auto& selection) {
        return selection.selectedHandle==plan.baseColorTexture;
        };
      const bool requiresAnimationEvidence =
          (frameAnimation!=nullptr && std::any_of(frameAnimation->selections.begin(),
              frameAnimation->selections.end(),selectedTexture)) ||
          (uvAnimation!=nullptr && std::any_of(uvAnimation->selections.begin(),
              uvAnimation->selections.end(),selectedTexture));
      (void)requiresAnimationEvidence;
#if !defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) && \
    !defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) && \
    !defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) && \
    !defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B) && \
    !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) && \
    !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
      if(canCullByBounds &&
         plan.pipeline!=IOSGPUScenePipelineSelector::Water &&
         !requiresAnimationEvidence &&
         classifyIOSGPUSceneMultiply2ClipBounds(
             entity.bounds,plan.constants.model,
             plan.constants.viewProjection)==
           IOSGPUSceneMultiply2ClipBoundsResult::DefinitelyOutside) {
#if defined(OPENGOTHIC_RENDERER_IOS_SIMULATOR_SMOKE)
        ++simulatorCulledDraws;
#endif
        continue;
        }
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_SIMULATOR_SMOKE)
      if(!requiresAnimationEvidence && !iosGPUSceneSimulatorSmokeDrawBudgetAccepts(
           simulatorSelectedDraws)) {
        ++simulatorBudgetSkippedDraws;
        continue;
        }
      ++simulatorSelectedDraws;
#endif
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

      if(mesh==nullptr || texture==nullptr ||
         !mesh->vertexBuffer || !mesh->indexBuffer ||
         !texture->texture) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::AssetPreflight);
#endif
        report.result = mesh==nullptr ? Result::MissingMesh :
            plan.materialCategory==IOSMaterialCategory::AlphaTest
              ? Result::MissingAlphaTexture : Result::MissingTexture;
        report.failingHandle = mesh==nullptr
            ? entity.mesh.value : plan.baseColorTexture.value;
        if(report.result==Result::MissingAlphaTexture)
          recordFailure(report.failures.missingAlphaTexture,report);
        return report;
        }
      if(!iosGPUScenePipelineSelectionMatches(
             plan.materialCategory,plan.pipeline)) {
        report.result = Result::SelectorMismatch;
        report.failingHandle = entity.material.value;
        recordFailure(report.failures.selectorMismatch,report);
        return report;
        }

      IOSGPUSceneDrawDispatch dispatch;
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      const IOSGPUSceneDrawDispatchResult dispatched =
          recordIOSGPUSceneDrawDispatchForRoute(
              causalRoute,plan.materialCategory,plan.kind,
              plan.usesFallbackTexture,true,plan.pipeline,
              report.counts,dispatch);
#else
      const IOSGPUSceneDrawDispatchResult dispatched =
          recordIOSGPUSceneProductionDrawDispatch(
              plan.materialCategory,plan.kind,
              plan.usesFallbackTexture,true,plan.pipeline,
              report.counts,dispatch);
#endif
      if(dispatched!=IOSGPUSceneDrawDispatchResult::Recorded) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::DispatchPreflight);
#endif
        report.result = dispatched==IOSGPUSceneDrawDispatchResult::Overflow
            ? Result::CountOverflow : Result::SelectorMismatch;
        recordFailure(
            dispatched==IOSGPUSceneDrawDispatchResult::Overflow
              ? report.failures.overflow
              : report.failures.selectorMismatch,
            report);
        return report;
        }

      id<MTLRenderPipelineState> pipelineState = nil;
      switch(dispatch.effective) {
        case IOSGPUScenePipelineSelector::Opaque:
          pipelineState =
              (id<MTLRenderPipelineState>)impl->opaquePipelineState;
          break;
        case IOSGPUScenePipelineSelector::AlphaTest:
          pipelineState =
              (id<MTLRenderPipelineState>)impl->alphaTestPipelineState;
          break;
        case IOSGPUScenePipelineSelector::Additive:
          pipelineState =
              (id<MTLRenderPipelineState>)impl->additivePipelineState;
          break;
        case IOSGPUScenePipelineSelector::Multiply2:
          pipelineState =
              (id<MTLRenderPipelineState>)impl->multiply2PipelineState;
          break;
        case IOSGPUScenePipelineSelector::Transparent:
          pipelineState = (id<MTLRenderPipelineState>)impl->transparentPipelines[0].get();
          break;
        case IOSGPUScenePipelineSelector::Water:
          pipelineState = (id<MTLRenderPipelineState>)impl->materialPipelines[0][0].get();
          break;
        case IOSGPUScenePipelineSelector::Ghost:
          pipelineState = (id<MTLRenderPipelineState>)impl->materialPipelines[1][0].get();
          break;
        case IOSGPUScenePipelineSelector::Multiply:
          pipelineState = (id<MTLRenderPipelineState>)impl->materialPipelines[2][0].get();
          break;
        case IOSGPUScenePipelineSelector::Unsupported:
          break;
        }
      if(plan.kind==IOSSceneMeshKind::Animated || plan.kind==IOSSceneMeshKind::Morph) {
        const size_t geometry = plan.kind==IOSSceneMeshKind::Animated ? 0u : 1u;
        const size_t alpha = dispatch.effective==IOSGPUScenePipelineSelector::AlphaTest ? 1u : 0u;
        switch(dispatch.effective) {
          case IOSGPUScenePipelineSelector::Water:
          case IOSGPUScenePipelineSelector::Ghost:
          case IOSGPUScenePipelineSelector::Multiply:
          case IOSGPUScenePipelineSelector::Additive:
          case IOSGPUScenePipelineSelector::Multiply2: {
            const size_t material = dispatch.effective==IOSGPUScenePipelineSelector::Water ? 0u :
                dispatch.effective==IOSGPUScenePipelineSelector::Ghost ? 1u :
                dispatch.effective==IOSGPUScenePipelineSelector::Multiply ? 2u :
                dispatch.effective==IOSGPUScenePipelineSelector::Additive ? 3u : 4u;
            pipelineState = (id<MTLRenderPipelineState>)impl->materialPipelines[material][geometry+1].get();
            break;
            }
          default:
            pipelineState = (id<MTLRenderPipelineState>)(dispatch.effective==IOSGPUScenePipelineSelector::Transparent
                ? impl->transparentPipelines[geometry+1].get() : impl->geometryPipelines[geometry*2+alpha].get());
            break;
          }
        }
      id<MTLBuffer> vertexBuffer =
          (id<MTLBuffer>)(void*)mesh->vertexBuffer.get();
      id<MTLBuffer> indexBuffer =
          (id<MTLBuffer>)(void*)mesh->indexBuffer.get();
      id<MTLTexture> baseColorTexture =
          (id<MTLTexture>)(void*)texture->texture.get();
      if(pipelineState==nil || vertexBuffer==nil ||
         indexBuffer==nil || baseColorTexture==nil) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
        if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
          return causalFailure(
              IOSGPUSceneCausalFailureReason::PipelinePreflight);
#endif
        report.result = Result::PipelineUnavailable;
        report.failingHandle = entity.material.value;
        recordFailure(report.failures.psoUnavailable,report);
        return report;
        }

      if(trackFrameAnimation) {
        const auto recorded = recordIOSGPUSceneFrameAnimationDraw(
            frameAnimationTracker,plan.baseColorTexture);
        if(recorded!=
               IOSGPUSceneFrameAnimationRecordResult::IgnoredStatic &&
           recorded!=
               IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated) {
          report.result = Result::AnimationEvidenceMismatch;
          report.failingHandle = plan.baseColorTexture.value;
          return report;
          }
        }
      if(trackUVAnimation) {
        const auto recorded = recordIOSGPUSceneUVAnimationDraw(
            uvAnimationTracker,plan);
        if(recorded!=IOSGPUSceneUVAnimationRecordResult::IgnoredStatic &&
           recorded!=IOSGPUSceneUVAnimationRecordResult::RecordedUvOnly &&
           recorded!=
               IOSGPUSceneUVAnimationRecordResult::RecordedFrameAndUv) {
          report.result = Result::AnimationEvidenceMismatch;
          report.failingHandle = plan.baseColorTexture.value;
          return report;
          }
        }

      auto draw = nativeDraw();
      draw.sourceId = entity.id.value;
      draw.cameraDepth = iosSceneCameraDepth(entity.bounds,plan.constants.model,snapshot.currentCamera.view);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
      if(plan.pipeline==IOSGPUScenePipelineSelector::Multiply2) {
        switch(classifyIOSGPUSceneMultiply2ClipBounds(
            entity.bounds,plan.constants.model,
            plan.constants.viewProjection)) {
          case IOSGPUSceneMultiply2ClipBoundsResult::Intersects:
            draw.visibilityClipClass =
                IOSMultiply2VisibilityClipClass::Intersects;
            break;
          case IOSGPUSceneMultiply2ClipBoundsResult::DefinitelyOutside:
            draw.visibilityClipClass =
                IOSMultiply2VisibilityClipClass::DefinitelyOutside;
            break;
          case IOSGPUSceneMultiply2ClipBoundsResult::Indeterminate:
            draw.visibilityClipClass =
                IOSMultiply2VisibilityClipClass::Indeterminate;
            break;
        }
      }
#endif
      draw.pipelineState = pipelineState;
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      if(causalRoute==IOSGPUSceneCausalFrameRoute::Target) {
        uint64_t ordinal = 0u;
        if(!iosGPUSceneTakeNextCausalDrawOrdinal(
               candidateFrame->targetOrdinal,ordinal))
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
        }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
      if(plan.pipeline!=IOSGPUScenePipelineSelector::Additive) {
        IOSGPUSceneMultiply2DrawIdentity identity;
        if(!makeIOSGPUSceneMultiply2DrawIdentity(
               targetGeneration,snapshot.sequence.value,
               entity.id.value,entity.mesh.value,entity.material.value,
               plan.baseColorTexture.value,
               static_cast<uint64_t>(plan.indexBufferOffset),
               static_cast<uint64_t>(plan.indexCount),
               plan.pipeline,plan.kind,identity)) {
          report.result = Result::NativeEncodingFailed;
          report.failingHandle = entity.id.value;
          recordFailure(report.failures.nativeEncode,report);
          return report;
          }
        const IOSGPUSceneMarker drawId =
            iosGPUSceneMultiply2DrawIdSignpost(identity);
        const IOSGPUSceneMarker drawBind =
            iosGPUSceneMultiply2DrawBindSignpost(identity);
        if(!drawId || !drawBind) {
          report.result = Result::NativeEncodingFailed;
          report.failingHandle = entity.id.value;
          recordFailure(report.failures.nativeEncode,report);
          return report;
          }
        OwnedObjectiveC multiply2DrawId(
            [[NSString alloc]
                initWithBytes:drawId.text.data()
                       length:drawId.length
                     encoding:NSUTF8StringEncoding]);
        OwnedObjectiveC multiply2DrawBind(
            [[NSString alloc]
                initWithBytes:drawBind.text.data()
                       length:drawBind.length
                     encoding:NSUTF8StringEncoding]);
        if(multiply2DrawId.get()==nil || multiply2DrawBind.get()==nil) {
          report.result = Result::NativeEncodingFailed;
          report.failingHandle = entity.id.value;
          recordFailure(report.failures.nativeEncode,report);
          return report;
          }
        if(plan.pipeline==IOSGPUScenePipelineSelector::Multiply2) {
          if(candidateFrame->multiply2DrawIdentityReady) {
            report.result = Result::CountMismatch;
            report.failingHandle = entity.id.value;
            recordFailure(report.failures.plannedDrawn,report);
            return report;
            }
          candidateFrame->multiply2DrawIdentity = identity;
          candidateFrame->multiply2DrawIdentityReady = true;
          }
        draw.drawId = std::move(multiply2DrawId);
        draw.drawBind = std::move(multiply2DrawBind);
        }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)
      if(plan.pipeline!=IOSGPUScenePipelineSelector::Multiply2) {
        IOSAdditiveInputRecordV1 artifactRecord;
        if(!makeAdditiveArtifactRecord(
               entity,plan,*mesh,*texture,frameAnimation,uvAnimation,
               artifactRecord)) {
          report.result = Result::AnimationEvidenceMismatch;
          report.failingHandle = entity.id.value;
          return report;
          }
        if(plan.pipeline==IOSGPUScenePipelineSelector::Additive)
          additiveRecords.emplace_back(std::move(artifactRecord));
        else
          baseRecords.emplace_back(std::move(artifactRecord));
      }
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
      if(plan.pipeline==IOSGPUScenePipelineSelector::Opaque ||
         plan.pipeline==IOSGPUScenePipelineSelector::AlphaTest ||
         plan.pipeline==IOSGPUScenePipelineSelector::Multiply2) {
        IOSMultiply2InputRecordV1 artifactRecord;
        if(!makeMultiply2ArtifactRecord(
               entity,plan,*mesh,*texture,frameAnimation,uvAnimation,
               artifactRecord)) {
          report.result = Result::AnimationEvidenceMismatch;
          report.failingHandle = entity.id.value;
          return report;
          }
        if(plan.pipeline==IOSGPUScenePipelineSelector::Multiply2)
          multiply2Records.emplace_back(std::move(artifactRecord));
        else
          multiply2BaseRecords.emplace_back(std::move(artifactRecord));
        }
#endif
      if(plan.pipeline==IOSGPUScenePipelineSelector::Additive)
        candidateFrame->additive.emplace_back(std::move(draw));
      else if(plan.pipeline==IOSGPUScenePipelineSelector::Multiply2)
        candidateFrame->multiply2.emplace_back(std::move(draw));
      else if(plan.pipeline==IOSGPUScenePipelineSelector::Transparent)
        candidateFrame->transparent.emplace_back(std::move(draw));
      else if(plan.pipeline==IOSGPUScenePipelineSelector::Water)
        candidateFrame->water.emplace_back(std::move(draw));
      else if(plan.pipeline==IOSGPUScenePipelineSelector::Ghost)
        candidateFrame->ghost.emplace_back(std::move(draw));
      else if(plan.pipeline==IOSGPUScenePipelineSelector::Multiply)
        candidateFrame->multiply.emplace_back(std::move(draw));
      else
        candidateFrame->base.emplace_back(std::move(draw));
      }

#if defined(OPENGOTHIC_RENDERER_IOS_SIMULATOR_SMOKE)
    if(!impl->simulatorSmokeBudgetReported) {
      Tempest::Log::i(
          "RendererIOS simulator smoke budget: selected=",
          simulatorSelectedDraws," culled=",simulatorCulledDraws,
          " budget-skipped=",simulatorBudgetSkippedDraws,
          " limit=",IOSGPUSceneSimulatorSmokeDrawBudget);
      impl->simulatorSmokeBudgetReported = true;
      }
#endif

#if !defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) && \
    !defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) && \
    !defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) && \
    !defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B) && \
    !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) && \
    !defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
    // Entity IDs retain history; only resolved resources determine batches.
    const auto canInstance = [](const auto& draw) {
      return draw.plan.kind!=IOSSceneMeshKind::Animated && draw.plan.kind!=IOSSceneMeshKind::Morph;
      };
    const auto key = [&](const auto& draw) {
      return std::tuple{!canInstance(draw),uintptr_t(draw.pipelineState),
          uintptr_t(draw.vertexBuffer),uintptr_t(draw.indexBuffer),
          uintptr_t(draw.baseColorTexture),draw.plan.indexBufferOffset,draw.plan.indexCount};
      };
    auto& draws = candidateFrame->base;
    std::stable_sort(draws.begin(),draws.end(),[&](const auto& a,const auto& b) { return key(a)<key(b); });
    std::vector<IOSGPUInstance> instances;
    std::vector<IOSMotionInstance> previousInstances;
    std::vector<IOSGPUSceneNativePreparedDraw> batches;
    batches.reserve(draws.size());
    for(size_t first=0;first<draws.size();) {
      size_t end = first+1;
      if(canInstance(draws[first]))
        while(end<draws.size() && key(draws[first])==key(draws[end]))
          ++end;
      if(end-first>1) {
        draws[first].instanceOffset = instances.size()*sizeof(IOSGPUInstance);
        draws[first].instanceCount = end-first;
        const size_t alpha = draws[first].plan.pipeline==IOSGPUScenePipelineSelector::AlphaTest ? 1u : 0u;
        draws[first].pipelineState = impl->geometryPipelines[4u+alpha].get();
        for(size_t i=first;i<end;++i) {
          const auto& draw = draws[i];
          draws[first].metal4Eligible &= draw.metal4Eligible;
          if(temporal) previousInstances.push_back({draw.previousTransform,draw.previousFatness});
          instances.push_back({draw.plan.constants.model,draw.plan.constants.baseColor,
                               draw.plan.constants.uvOffset,draw.deformation.fatness,draw.plan.constants.landscape});
          }
        }
      batches.push_back(std::move(draws[first]));
      first = end;
      }
    PreparedFrame::Uploads::write(nativeDevice,prepared.uploads->instances,
        instances.data(),instances.size()*sizeof(IOSGPUInstance));
    if(temporal)
      PreparedFrame::Uploads::write(nativeDevice,prepared.uploads->previousInstances,
          previousInstances.data(),previousInstances.size()*sizeof(IOSMotionInstance));
    for(auto& draw:batches) {
      if(draw.instanceCount>1) {
        draw.instanceBuffer = prepared.uploads->instances.get();
        draw.previousInstanceBuffer = prepared.uploads->previousInstances.get();
        }
      }
    draws = std::move(batches);
#endif
    size_t factorBytes = 0;
    for(auto& draw:candidateFrame->water) {
      if(impl->waterPatchPipeline.get()==nil || draw.plan.kind!=IOSSceneMeshKind::Landscape || draw.plan.constants.waveMaxAmplitude<=0.f)
        continue;
      draw.tessellationOffset = factorBytes;
      factorBytes += ((draw.plan.indexCount/3u*8u)+255u)&~size_t(255u);
      draw.pipelineState = impl->waterPatchPipeline.get();
      }
    if(factorBytes!=0) {
      const id factors = PreparedFrame::Uploads::reserve(nativeDevice,prepared.uploads->tessellationFactors,factorBytes);
      for(auto& draw:candidateFrame->water)
        if(draw.plan.kind==IOSSceneMeshKind::Landscape && draw.plan.constants.waveMaxAmplitude>0.f)
          draw.tessellationFactors = factors;
      }
    auto& transparent = candidateFrame->transparent;
    std::sort(transparent.begin(),transparent.end(),[](const auto& a,const auto& b) {
      return a.cameraDepth!=b.cameraDepth ? a.cameraDepth>b.cameraDepth : a.sourceId<b.sourceId;
      });
    if((!impl->geometryReported
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        || snapshot.sequence.value%300u==0u
#endif
        ) && !candidateFrame->base.empty()) {
      Tempest::Log::i("RendererIOS native geometry: entities=",report.counts.drawn.material.total,
          " draw-calls=",candidateFrame->base.size()+candidateFrame->multiply2.size()+candidateFrame->additive.size()+candidateFrame->transparent.size()+candidateFrame->water.size()+candidateFrame->ghost.size()+candidateFrame->multiply.size(),
          " animated=",report.counts.drawn.kind.animated," morph=",report.counts.drawn.kind.morph,
          " lights=",snapshot.lights.size()," visible-lights=",candidateFrame->lighting.lightInfo[0],
          " shadow-near=",candidateFrame->shadows[0].size()," shadow-far=",candidateFrame->shadows[1].size(),
          " generation=",snapshot.generation.value," sequence=",snapshot.sequence.value,
          " transparent=",candidateFrame->transparent.size(),
          " water=",candidateFrame->water.size()," particles=",snapshot.particles.size()," particle-batches=",snapshot.particleBatches.size(),
          " sun-y=",snapshot.currentSky.sunDirection.y," rain=",snapshot.currentSky.rainIntensity);
      impl->geometryReported = true;
      }

    report.drawCount = report.counts.drawn.material.total;
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
    if(rayTracingMode!=0) {
      try {
        @try {
          if(impl->rayTracing==nullptr)
            impl->rayTracing=std::make_unique<IOSRayTracing>(impl->nativeDevice.get());
          if(impl->rayTracingUnavailable || !impl->rayTracing->supported()) {
            rayGeometry.clear();
            rayTracingMode=rayTracingMode==2 ? 0 : 3;
            }
          if(rayTracingMode!=0) {
            impl->rayTracing->prepare(prepared.uploads->rays,snapshot.generation.value,rayGeometry);
            candidateFrame->rays=&prepared.uploads->rays;
            candidateFrame->rayTracingMode=rayTracingMode;
            }
          }
        @catch(NSException*) { throw std::runtime_error("RendererIOS RT preparation failed"); }
        }
      catch(...) {
        impl->rayTracingUnavailable=true;
        Tempest::Log::e("RendererIOS RT unavailable; raster fallback");
        }
      }
#endif
    report.texturedDrawCount = report.counts.drawn.texturedDraws;
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

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    const bool countsConsistent =
        causalRoute==IOSGPUSceneCausalFrameRoute::Target
          ? iosGPUSceneReportCountsAreConsistentForMode(
                report.counts,report.failures)
          : iosGPUSceneProductionReportCountsAreConsistent(
                report.counts,report.failures);
#else
    const bool countsConsistent =
        iosGPUSceneProductionReportCountsAreConsistent(
            report.counts,report.failures);
#endif
    if(!countsConsistent) {
      report.result = Result::CountMismatch;
      recordFailure(report.failures.plannedDrawn,report);
      return report;
      }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(causalRoute==IOSGPUSceneCausalFrameRoute::Target) {
      if(report.counts.planned.material.alphaTest==0u)
        return causalFailure(
            IOSGPUSceneCausalFailureReason::MissingAlphaTestDraw);
      const uint64_t preparedDraws =
          static_cast<uint64_t>(candidateFrame->base.size())+
          static_cast<uint64_t>(candidateFrame->additive.size())+
          static_cast<uint64_t>(candidateFrame->multiply2.size());
      if(!iosGPUSceneCausalPreparationIsValid(
             causalPrepared,causalRoute,report.counts,
             preparedDraws,candidateFrame->targetOrdinal,
             true,true,true))
        return causalFailure(
            IOSGPUSceneCausalFailureReason::EquationsPreflight);
      IOSGPUSceneCausalRuntimeState encodedPreview = causalPrepared;
      encodedPreview.phase =
          IOSGPUSceneCausalRuntimePhase::TargetEncoded;
      candidateFrame->targetEncodedMarker =
          iosGPUSceneCausalEncodedMarker(
              encodedPreview,report.counts.drawn.material.total,
              report.counts.drawn.material.alphaTest);
      if(!candidateFrame->targetEncodedMarker)
        return causalFailure(
            IOSGPUSceneCausalFailureReason::MarkerPreflight);
      }
#endif

    // An all-culled frame still clears/resolves HDR and must not latch failure.
    report.result = Result::Success;
    if(!materializeReportMarkers(
           snapshot.generation.value,snapshot.sequence.value,report)) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
        return causalFailure(
            IOSGPUSceneCausalFailureReason::MarkerPreflight);
#endif
      report.result = Result::NativeEncodingFailed;
      recordFailure(report.failures.nativeEncode,report);
      return report;
      }

#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)
    if(targetGeneration==0u) {
      report.result = Result::NativeEncodingFailed;
      recordFailure(report.failures.nativeEncode,report);
      return report;
      }
    std::vector<std::byte> artifact;
    if(iosBuildAdditiveInputArtifactV1(
           targetGeneration,snapshot.sequence.value,
           baseRecords,additiveRecords,artifact)!=
       IOSAdditiveInputArtifactError::None) {
      report.result = Result::NativeEncodingFailed;
      recordFailure(report.failures.nativeEncode,report);
      return report;
      }
    candidateFrame->additiveInput.bytes = std::move(artifact);
    candidateFrame->additiveInput.generation = targetGeneration;
    candidateFrame->additiveInput.sequence = snapshot.sequence.value;
    candidateFrame->additiveInput.mode = IOSGPUSceneAdditiveModeLeaf;
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
    if(targetGeneration==0u) {
      report.result = Result::NativeEncodingFailed;
      recordFailure(report.failures.nativeEncode,report);
      return report;
      }
    std::vector<std::byte> multiply2Artifact;
    if(iosBuildMultiply2InputArtifactV1(
           targetGeneration,snapshot.sequence.value,
           multiply2BaseRecords,multiply2Records,multiply2Artifact)!=
       IOSMultiply2InputArtifactError::None) {
      report.result = Result::NativeEncodingFailed;
      recordFailure(report.failures.nativeEncode,report);
      return report;
      }
    if(multiply2Records.size()!=1u ||
       !candidateFrame->multiply2DrawIdentityReady ||
       candidateFrame->multiply2.size()!=1u) {
      report.result = Result::CountMismatch;
      recordFailure(report.failures.plannedDrawn,report);
      return report;
      }
    candidateFrame->multiply2Input.bytes = std::move(multiply2Artifact);
    candidateFrame->multiply2Input.generation = targetGeneration;
    candidateFrame->multiply2Input.sequence = snapshot.sequence.value;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A)
    candidateFrame->multiply2Input.mode = 'a';
#else
    candidateFrame->multiply2Input.mode = 'b';
#endif
#endif
    candidateFrame->report = report;
    candidateFrame->ready = true;
    prepared.impl = std::move(candidateFrame);
    return report;
    }
  catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(causalRoute==IOSGPUSceneCausalFrameRoute::Target)
      return causalFailure(
          IOSGPUSceneCausalFailureReason::NativeException);
#endif
    report.result = Result::NativeEncodingFailed;
    recordFailure(report.failures.nativeEncode,report);
    prepared.impl.reset();
    return report;
    }
  }

IOSGPUScene::Report IOSGPUScene::encodePrepared(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    PreparedFrame& prepared) noexcept {
  return encodePreparedPhase(encoder,prepared,0u);
  }

IOSGPUScene::Report IOSGPUScene::encodePreparedThroughMultiply2(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    PreparedFrame& prepared) noexcept {
  return encodePreparedPhase(encoder,prepared,1u);
  }

IOSGPUScene::Report IOSGPUScene::encodePreparedAdditive(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    PreparedFrame& prepared) noexcept {
  return encodePreparedPhase(encoder,prepared,2u);
  }

bool IOSGPUScene::multiply2CoverageMetadata(
    const PreparedFrame& prepared,
    const IOSLinearHDRProofMetadata& hdrProof,
    uint32_t width,
    uint32_t height,
    IOSMultiply2CoverageProofMetadata& metadata) const noexcept {
  metadata = {};
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
  if(impl==nullptr || prepared.impl==nullptr ||
     prepared.impl->owner!=impl.get() || !prepared.impl->ready ||
     !prepared.impl->multiply2DrawIdentityReady ||
     prepared.impl->multiply2.size()!=1u || width==0u || height==0u ||
     hdrProof.width!=width || hdrProof.height!=height ||
     hdrProof.bytesPerRow!=width*4u ||
     hdrProof.logicalBytes!=uint64_t(width)*uint64_t(height)*4u)
    return false;
  const auto& identity = prepared.impl->multiply2DrawIdentity;
  if(identity.selector!=IOSGPUScenePipelineSelector::Multiply2 ||
     identity.kind!=IOSSceneMeshKind::Static ||
     identity.generation!=hdrProof.targetGeneration ||
     identity.sequence!=hdrProof.snapshotSequence ||
     identity.source==0u || identity.indexCount==0u)
    return false;
  metadata.width = width;
  metadata.height = height;
  metadata.bytesPerRow = width;
  metadata.sampleCount = 1u;
  metadata.payloadBytes = uint64_t(width)*uint64_t(height);
  metadata.targetGeneration = identity.generation;
  metadata.snapshotSequence = identity.sequence;
  metadata.sourceId = identity.source;
  metadata.indexByteOffset = identity.indexOffset;
  metadata.indexCount = identity.indexCount;
  metadata.viewport = {0u,0u,width,height};
  metadata.scissor = metadata.viewport;
  metadata.proofId = hdrProof.proofId;
  metadata.buildSha = hdrProof.buildSha;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
  metadata.visibilityClipClass =
      prepared.impl->multiply2.front().visibilityClipClass;
#endif
  return true;
#else
  (void)prepared;
  (void)hdrProof;
  (void)width;
  (void)height;
  return false;
#endif
}

IOSGPUScene::Report IOSGPUScene::encodePreparedMultiply2Causal(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    PreparedFrame& prepared,
    const Tempest::Attachment& sceneHDR,
    const IOSLinearHDRProofNativeView& hdrProof,
    const IOSMultiply2CoverageNativeView& coverage) noexcept {
  Report report = makeReport(Result::NativeEncodingFailed);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
  if(impl==nullptr || prepared.impl==nullptr ||
     prepared.impl->owner!=impl.get() || !prepared.impl->ready ||
     prepared.impl->nativeCompleted ||
     !prepared.impl->multiply2DrawIdentityReady ||
     prepared.impl->multiply2.size()!=1u ||
     hdrProof.sourceTexture==nullptr ||
     hdrProof.destinationBuffer==nullptr ||
     coverage.depthStencilTexture==nullptr ||
     coverage.coverageBuffer==nullptr ||
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
     coverage.visibilityResultBuffer==nullptr ||
     coverage.metadata.visibilityClipClass!=
         prepared.impl->multiply2.front().visibilityClipClass ||
#endif
     coverage.width==0u || coverage.height==0u ||
     coverage.width!=coverage.metadata.width ||
     coverage.height!=coverage.metadata.height ||
     coverage.gpuBytesPerRow<coverage.width ||
     hdrProof.metadata.width!=coverage.width ||
     hdrProof.metadata.height!=coverage.height ||
     hdrProof.metadata.bytesPerRow!=coverage.width*4u ||
     coverage.metadata.targetGeneration!=
         hdrProof.metadata.targetGeneration ||
     coverage.metadata.snapshotSequence!=
         hdrProof.metadata.snapshotSequence ||
     coverage.metadata.proofId!=hdrProof.metadata.proofId ||
     coverage.metadata.buildSha!=hdrProof.metadata.buildSha ||
     coverage.metadata.sourceId!=
         prepared.impl->multiply2DrawIdentity.source ||
     coverage.metadata.indexByteOffset!=
         prepared.impl->multiply2DrawIdentity.indexOffset ||
     coverage.metadata.indexCount!=
         prepared.impl->multiply2DrawIdentity.indexCount) {
    recordFailure(report.failures.nativeEncode,report);
    return report;
    }
  try {
    const auto& texture =
        Tempest::textureCast<const Tempest::Texture2d&>(sceneHDR);
    const auto borrowed = Tempest::MetalApi::borrowTexture(impl->owner,texture);
    if(!borrowed || (void*)borrowed.get()!=hdrProof.sourceTexture) {
      recordFailure(report.failures.nativeEncode,report);
      prepared.impl->ready = false;
      return report;
      }
    Impl::NativeMultiply2Context context(
        Impl::NativeMultiply2EncodeMode::CaptureProof);
    context.scene = impl.get();
    context.prepared = prepared.impl.get();
    context.sceneHDR = (id)hdrProof.sourceTexture;
    context.hdrProofBuffer = (id)hdrProof.destinationBuffer;
    context.depthStencil = (id)coverage.depthStencilTexture;
    context.coverageBuffer = (id)coverage.coverageBuffer;
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_GPU_VISIBILITY_DIAGNOSTIC)
    context.visibilityResultBuffer =
        (id)coverage.visibilityResultBuffer;
#endif
    context.width = coverage.width;
    context.height = coverage.height;
    context.hdrBytesPerRow = hdrProof.metadata.bytesPerRow;
    context.coverageBytesPerRow = coverage.gpuBytesPerRow;
    context.sceneMarker = hdrProof.sceneMarker;
    context.proofMarker = hdrProof.copyMarker;
    context.report = prepared.impl->report;
    context.report.encodedPhaseDrawCount = 0u;
    context.report.encodedPhaseTexturedDrawCount = 0u;
    return impl->runMultiply2(encoder,context);
  }
  catch(...) {
    recordFailure(report.failures.nativeEncode,report);
    recordPlannedDrawnFailure(report);
    if(prepared.impl!=nullptr) {
      prepared.impl->nativeException = true;
      prepared.impl->ready = false;
      }
    return report;
  }
#else
  (void)encoder;
  (void)prepared;
  (void)sceneHDR;
  (void)hdrProof;
  (void)coverage;
  recordFailure(report.failures.nativeEncode,report);
  return report;
#endif
}

IOSGPUScene::Report IOSGPUScene::encodePreparedMultiply2Continuation(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    PreparedFrame& prepared,
    const Tempest::Attachment& sceneHDR) noexcept {
  Report report = makeReport(Result::NativeEncodingFailed);
#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
  if(impl==nullptr || prepared.impl==nullptr ||
     prepared.impl->owner!=impl.get()) {
    recordFailure(report.failures.nativeEncode,report);
    return report;
    }
  report = prepared.impl->report;
  const auto failContinuation = [&]() noexcept {
    report.result = Result::NativeEncodingFailed;
    recordFailure(report.failures.nativeEncode,report);
    recordPlannedDrawnFailure(report);
    prepared.impl->ready = false;
    return report;
    };
  if(!prepared.impl->ready || prepared.impl->nativeCompleted ||
     !prepared.impl->multiply2DrawIdentityReady ||
     prepared.impl->multiply2.size()!=1u)
    return failContinuation();

  try {
    const auto& texture =
        Tempest::textureCast<const Tempest::Texture2d&>(sceneHDR);
    const auto borrowed =
        Tempest::MetalApi::borrowTexture(impl->owner,texture);
    if(!borrowed)
      return failContinuation();
    id<MTLTexture> nativeSceneHDR =
        (id<MTLTexture>)(void*)borrowed.get();
    id depthStencil = nil;
    uint32_t width = 0u;
    uint32_t height = 0u;
    if(!impl->continuationDepthStencilForSceneHDR(
         nativeSceneHDR,depthStencil,width,height))
      return failContinuation();

    Impl::NativeMultiply2Context context(
        Impl::NativeMultiply2EncodeMode::Continuation);
    context.scene = impl.get();
    context.prepared = prepared.impl.get();
    context.sceneHDR = nativeSceneHDR;
    context.depthStencil = depthStencil;
    context.width = width;
    context.height = height;
    context.report = report;
    context.report.encodedPhaseDrawCount = 0u;
    context.report.encodedPhaseTexturedDrawCount = 0u;
    return impl->runMultiply2(encoder,context);
  }
  catch(...) {
    prepared.impl->nativeException = true;
    return failContinuation();
  }
#else
  (void)encoder;
  (void)prepared;
  (void)sceneHDR;
  recordFailure(report.failures.nativeEncode,report);
  return report;
#endif
}

IOSGPUScene::Report IOSGPUScene::encodePreparedPhase(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    PreparedFrame& prepared,
    uint8_t phase) noexcept {
  Report report = makeReport(Result::NativeEncodingFailed);
  if(phase>2u ||
     (phase==0u && prepared.impl!=nullptr &&
      (prepared.impl->nativeBaseMultiplyCompleted ||
       prepared.impl->nativeAdditiveCompleted)) ||
     (phase==1u && prepared.impl!=nullptr &&
      prepared.impl->nativeBaseMultiplyCompleted) ||
     (phase==2u && (prepared.impl==nullptr ||
      !prepared.impl->nativeBaseMultiplyCompleted ||
      prepared.impl->nativeAdditiveCompleted))) {
    recordFailure(report.failures.nativeEncode,report);
    return report;
    }
  if(impl==nullptr || prepared.impl==nullptr ||
     prepared.impl->owner!=impl.get() || !prepared.impl->ready) {
    recordFailure(report.failures.nativeEncode,report);
    return report;
    }
  report = prepared.impl->report;
  Impl::NativeEncodeContext context;
  context.scene = impl.get();
  context.prepared = prepared.impl.get();
  context.report = report;
  context.phase = phase;
  try {
    const bool encoded = Tempest::MetalApi::withActiveRenderEncoder(
        impl->owner,encoder,&context,&Impl::encodeLandscape);
    if(!encoded) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
      if(prepared.impl->causalRoute==
           IOSGPUSceneCausalFrameRoute::Target) {
        impl->failCausal(
            prepared.impl->causalPrepared.generation,
            prepared.impl->causalPrepared.lastSequence,
            IOSGPUSceneCausalFailureReason::NoActiveRenderEncoder);
        }
#endif
      context.report.result = Result::NoActiveRenderEncoder;
      recordFailure(
          context.report.failures.nativeEncode,context.report);
      recordPlannedDrawnFailure(context.report);
      prepared.impl->ready = false;
      return context.report;
      }
    }
  catch(...) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(prepared.impl->causalRoute==
         IOSGPUSceneCausalFrameRoute::Target) {
      impl->failCausal(
          prepared.impl->causalPrepared.generation,
          prepared.impl->causalPrepared.lastSequence,
          IOSGPUSceneCausalFailureReason::NativeException);
      }
#endif
    context.report.result = Result::NativeEncodingFailed;
    recordFailure(
        context.report.failures.nativeEncode,context.report);
    recordPlannedDrawnFailure(context.report);
    prepared.impl->ready = false;
    return context.report;
    }

  const bool phaseCompleted = phase==1u
      ? prepared.impl->nativeBaseMultiplyCompleted
      : prepared.impl->nativeCompleted;
  if(prepared.impl->nativeException || !phaseCompleted ||
     context.report.result!=Result::Success) {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    if(prepared.impl->causalRoute==
         IOSGPUSceneCausalFrameRoute::Target) {
      impl->failCausal(
          prepared.impl->causalPrepared.generation,
          prepared.impl->causalPrepared.lastSequence,
          prepared.impl->nativeException
            ? IOSGPUSceneCausalFailureReason::NativeException
            : IOSGPUSceneCausalFailureReason::NativeEncode);
      }
#endif
    prepared.impl->ready = false;
    return context.report;
    }

  if(phase==1u)
    return context.report;

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  const uint64_t drawCount =
      static_cast<uint64_t>(prepared.impl->base.size())+
      static_cast<uint64_t>(prepared.impl->additive.size())+
      static_cast<uint64_t>(prepared.impl->multiply2.size());
  IOSGPUSceneCausalRuntimeState committed;
  const bool target =
      prepared.impl->causalRoute==IOSGPUSceneCausalFrameRoute::Target;
  if(!iosGPUSceneCommitCausalPreparation(
         impl->causalState,prepared.impl->causalPrepared,
         prepared.impl->causalRoute,context.report.counts,
         drawCount,target ? prepared.impl->targetOrdinal : 0u,
         target,target,
         iosGPUSceneFailureCountsAreClear(
             context.report.failures),
         committed)) {
    impl->failCausal(
        prepared.impl->causalPrepared.generation,
        prepared.impl->causalPrepared.lastSequence,
        IOSGPUSceneCausalFailureReason::EquationsPreflight);
    context.report.result = Result::NativeEncodingFailed;
    recordFailure(context.report.failures.nativeEncode,context.report);
    prepared.impl->ready = false;
    return context.report;
    }
  impl->causalState = committed;
  if(target)
    Tempest::Log::i(
        prepared.impl->targetEncodedMarker.text.data());
#endif
  prepared.impl->ready = false;
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

bool IOSGPUScene::motionPipelinesReady() const noexcept {
  return impl!=nullptr && impl->motionReady;
  }

void IOSGPUScene::trimMemory() noexcept {
  impl->sceneColorCopy = OwnedObjectiveC();
  impl->sceneDepthCopy = OwnedObjectiveC();
#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
  if(impl->rayTracing!=nullptr) impl->rayTracing->clearAfterConfirmedIdle();
  impl->rayTracingUnavailable=false;
#endif
  }
