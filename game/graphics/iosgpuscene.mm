#include "iosgpuscene.h"

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

struct IOSGPUSceneNativePreparedDraw final {
  IOSGPUSceneDrawPlan plan;
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

struct IOSGPUScene::PreparedFrame::Impl final {
  const void* owner = nullptr;
  std::vector<IOSGPUSceneNativePreparedDraw> base;
  std::vector<IOSGPUSceneNativePreparedDraw> multiply2;
  std::vector<IOSGPUSceneNativePreparedDraw> additive;
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
    };

#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)
  struct NativeMultiply2CausalContext final {
    Impl* scene = nullptr;
    PreparedFrame::Impl* prepared = nullptr;
    id sceneHDR = nil;
    id hdrProofBuffer = nil;
    id depthStencil = nil;
    id coverageBuffer = nil;
    uint32_t width = 0u;
    uint32_t height = 0u;
    uint32_t hdrBytesPerRow = 0u;
    uint32_t coverageBytesPerRow = 0u;
    std::string_view sceneMarker;
    std::string_view proofMarker;
    IOSGPUScene::Report report;
    bool succeeded = false;
    };

  static void encodeMultiply2Causal(
      void* opaque, MTL::CommandBuffer* nativeCommandBuffer);
#endif

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
      additivePipelineState  = additivePipelineOwner.relinquish();
      multiply2PipelineState = multiply2PipelineOwner.relinquish();
      baseDepthState         = depthOwner.relinquish();
      additiveDepthState     = additiveDepthOwner.relinquish();
      multiply2DepthState    = multiply2DepthOwner.relinquish();
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
  id                               opaquePipelineState = nil;
  id                               alphaTestPipelineState = nil;
  id                               additivePipelineState = nil;
  id                               multiply2PipelineState = nil;
  id                               baseDepthState = nil;
  id                               additiveDepthState = nil;
  id                               multiply2DepthState = nil;
  id                               samplerState = nil;
  IOSGPUScene::Result              initializationResult =
      IOSGPUScene::Result::PipelineUnavailable;
  NativeTextureValidationCache     textureValidation;
  bool                              emissiveTerminalReported = false;
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
void IOSGPUScene::Impl::encodeMultiply2Causal(
    void* opaque, MTL::CommandBuffer* nativeCommandBuffer) {
  if(opaque==nullptr || nativeCommandBuffer==nullptr)
    return;
  auto& context = *static_cast<NativeMultiply2CausalContext*>(opaque);
  if(context.scene==nullptr || context.prepared==nullptr ||
     context.prepared->owner!=context.scene || !context.prepared->ready ||
     context.prepared->multiply2.size()!=1u ||
     context.sceneHDR==nil || context.hdrProofBuffer==nil ||
     context.depthStencil==nil || context.coverageBuffer==nil ||
     context.width==0u || context.height==0u ||
     context.hdrBytesPerRow!=context.width*4u ||
     context.coverageBytesPerRow<context.width ||
     context.sceneMarker.size()!=53u || context.proofMarker.size()!=57u)
    return;

  id<MTLCommandBuffer> command =
      (id<MTLCommandBuffer>)(void*)nativeCommandBuffer;
  id<MTLTexture> sceneHDR = (id<MTLTexture>)context.sceneHDR;
  id<MTLTexture> depthStencil = (id<MTLTexture>)context.depthStencil;
  id<MTLBuffer> hdrProofBuffer = (id<MTLBuffer>)context.hdrProofBuffer;
  id<MTLBuffer> coverageBuffer = (id<MTLBuffer>)context.coverageBuffer;
  OwnedObjectiveC sceneMarker([[NSString alloc]
      initWithBytes:context.sceneMarker.data()
             length:context.sceneMarker.size()
           encoding:NSUTF8StringEncoding]);
  OwnedObjectiveC proofMarker([[NSString alloc]
      initWithBytes:context.proofMarker.data()
             length:context.proofMarker.size()
           encoding:NSUTF8StringEncoding]);
  if(sceneMarker.get()==nil || proofMarker.get()==nil)
    return;
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
      if(command==nil || device==nil || command.device!=device ||
         sceneHDR.device!=device || depthStencil.device!=device ||
         hdrProofBuffer.device!=device || coverageBuffer.device!=device ||
         sceneHDR.pixelFormat!=MTLPixelFormatRG11B10Float ||
         sceneHDR.width!=NSUInteger(context.width) ||
         sceneHDR.height!=NSUInteger(context.height) ||
         sceneHDR.sampleCount!=1u ||
         depthStencil.pixelFormat!=MTLPixelFormatDepth32Float_Stencil8 ||
         depthStencil.width!=NSUInteger(context.width) ||
         depthStencil.height!=NSUInteger(context.height) ||
         depthStencil.sampleCount!=1u ||
         hdrProofBuffer.storageMode!=MTLStorageModeShared ||
         coverageBuffer.storageMode!=MTLStorageModeShared)
        return;

      const MTLViewport viewport = {
          0.0,0.0,double(context.width),double(context.height),0.0,1.0};
      const MTLScissorRect scissor = {
          0u,0u,NSUInteger(context.width),NSUInteger(context.height)};
      const auto encodeDraws = [&](id<MTLRenderCommandEncoder> encoder,
                                   const auto& draws,
                                   id depthState,
                                   uint32_t stencilReference) {
        [encoder setDepthStencilState:(id<MTLDepthStencilState>)depthState];
        [encoder setStencilReferenceValue:stencilReference];
        for(const auto& draw:draws) {
          [encoder setRenderPipelineState:
              (id<MTLRenderPipelineState>)draw.pipelineState];
          [encoder setVertexBuffer:(id<MTLBuffer>)draw.vertexBuffer
                            offset:0u atIndex:0u];
          [encoder setVertexBytes:&draw.plan.constants
                           length:sizeof(draw.plan.constants) atIndex:1u];
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
      renderEncoder = [command renderCommandEncoderWithDescriptor:first];
      [first release];
      if(renderEncoder==nil)
        return;
      [renderEncoder setLabel:(NSString*)sceneMarker.get()];
      [renderEncoder pushDebugGroup:(NSString*)sceneMarker.get()];
      [renderEncoder insertDebugSignpost:
          @"RendererIOS.Multiply2.BaseAndCausal.v1"];
      [renderEncoder setViewport:viewport];
      [renderEncoder setScissorRect:scissor];
      [renderEncoder setFrontFacingWinding:MTLWindingClockwise];
      [renderEncoder setCullMode:MTLCullModeFront];
      [renderEncoder setFragmentSamplerState:
          (id<MTLSamplerState>)context.scene->samplerState atIndex:0u];
      encodeDraws(renderEncoder,context.prepared->base,
                  context.scene->baseDepthState,0u);
      encodeDraws(renderEncoder,context.prepared->multiply2,
                  context.scene->multiply2DepthState,1u);
      [renderEncoder setFragmentTexture:nil atIndex:0u];
      [renderEncoder setFragmentSamplerState:nil atIndex:0u];
      [renderEncoder setDepthStencilState:nil];
      [renderEncoder popDebugGroup];
      if(!endRender()) {
        closeOrTerminate();
        return;
      }
      context.prepared->markNativeBaseMultiplyCompleted();

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
      [renderEncoder setLabel:@"RendererIOS.Multiply2.AdditiveAfterProof.v1"];
      [renderEncoder pushDebugGroup:
          @"RendererIOS.Multiply2.AdditiveAfterProof.v1"];
      [renderEncoder setViewport:viewport];
      [renderEncoder setScissorRect:scissor];
      [renderEncoder setFrontFacingWinding:MTLWindingClockwise];
      [renderEncoder setCullMode:MTLCullModeFront];
      [renderEncoder setFragmentSamplerState:
          (id<MTLSamplerState>)context.scene->samplerState atIndex:0u];
      encodeDraws(renderEncoder,context.prepared->additive,
                  context.scene->additiveDepthState,0u);
      [renderEncoder setFragmentTexture:nil atIndex:0u];
      [renderEncoder setFragmentSamplerState:nil atIndex:0u];
      [renderEncoder setDepthStencilState:nil];
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
#endif

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
    [encoder setDepthStencilState:nil];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFrontFacingWinding:MTLWindingClockwise];
    };
  const auto encodePhase = [&](
      const std::vector<IOSGPUSceneNativePreparedDraw>& draws,
      id depthState) {
    [encoder setDepthStencilState:(id<MTLDepthStencilState>)depthState];
    for(const auto& draw:draws) {
      [encoder setRenderPipelineState:
          (id<MTLRenderPipelineState>)draw.pipelineState];
      [encoder setVertexBuffer:(id<MTLBuffer>)draw.vertexBuffer
                        offset:0u
                       atIndex:0u];
      [encoder setVertexBytes:&draw.plan.constants
                       length:sizeof(draw.plan.constants)
                      atIndex:1u];
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
      [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                          indexCount:draw.plan.indexCount
                           indexType:MTLIndexTypeUInt32
                         indexBuffer:(id<MTLBuffer>)draw.indexBuffer
                   indexBufferOffset:draw.plan.indexBufferOffset
                       instanceCount:1u
                          baseVertex:0
                        baseInstance:0u];
      ++context.report.encodedPhaseDrawCount;
      if(draw.baseColorTexture!=nil)
        ++context.report.encodedPhaseTexturedDrawCount;
      }
    };

  @try {
    [encoder setFrontFacingWinding:MTLWindingClockwise];
    [encoder setCullMode:MTLCullModeFront];
    [encoder setFragmentSamplerState:
        (id<MTLSamplerState>)context.scene->samplerState
                            atIndex:0u];
    if(context.phase==0u || context.phase==1u) {
      encodePhase(context.prepared->base,context.scene->baseDepthState);
      encodePhase(context.prepared->multiply2,
                  context.scene->multiply2DepthState);
      context.prepared->nativeBaseMultiplyCompleted = true;
      }
    if(context.phase==0u || context.phase==2u) {
      encodePhase(context.prepared->additive,
                  context.scene->additiveDepthState);
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
    const IOSUVAnimationEvidence* uvAnimation) noexcept {
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
    auto candidateFrame = std::make_unique<PreparedFrame::Impl>();
    candidateFrame->owner = impl.get();
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    candidateFrame->causalRoute = causalRoute;
    candidateFrame->causalPrepared = causalPrepared;
#endif
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

      const auto* mesh = assets.lookupMesh(entity.mesh);
      const auto* texture = assets.lookupTexture(plan.baseColorTexture);
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
        case IOSGPUScenePipelineSelector::Unsupported:
          break;
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

      IOSGPUSceneNativePreparedDraw draw;
      draw.plan = plan;
      draw.pipelineState = pipelineState;
      draw.vertexBuffer = vertexBuffer;
      draw.indexBuffer = indexBuffer;
      draw.baseColorTexture = baseColorTexture;
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
      else
        candidateFrame->base.emplace_back(std::move(draw));
      }

    report.drawCount = report.counts.drawn.material.total;
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

    report.result = report.drawCount!=0u ? Result::Success : Result::Empty;
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
    Impl::NativeMultiply2CausalContext context;
    context.scene = impl.get();
    context.prepared = prepared.impl.get();
    context.sceneHDR = (id)hdrProof.sourceTexture;
    context.hdrProofBuffer = (id)hdrProof.destinationBuffer;
    context.depthStencil = (id)coverage.depthStencilTexture;
    context.coverageBuffer = (id)coverage.coverageBuffer;
    context.width = coverage.width;
    context.height = coverage.height;
    context.hdrBytesPerRow = hdrProof.metadata.bytesPerRow;
    context.coverageBytesPerRow = coverage.gpuBytesPerRow;
    context.sceneMarker = hdrProof.sceneMarker;
    context.proofMarker = hdrProof.copyMarker;
    context.report = prepared.impl->report;
    context.report.encodedPhaseDrawCount = 0u;
    context.report.encodedPhaseTexturedDrawCount = 0u;
    const bool accepted = Tempest::MetalApi::withActiveCommandBuffer(
        impl->owner,encoder,&context,&Impl::encodeMultiply2Causal);
    if(!accepted || !context.succeeded ||
       prepared.impl->nativeException ||
       !prepared.impl->nativeCompleted ||
       context.report.encodedPhaseDrawCount!=context.report.drawCount ||
       context.report.encodedPhaseTexturedDrawCount!=
           context.report.texturedDrawCount) {
      context.report.result = Result::NativeEncodingFailed;
      recordFailure(context.report.failures.nativeEncode,context.report);
      recordPlannedDrawnFailure(context.report);
      prepared.impl->ready = false;
      return context.report;
      }
    prepared.impl->ready = false;
    return context.report;
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
