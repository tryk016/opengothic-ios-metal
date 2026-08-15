#include "iossceneextractor.h"

#include "iosrenderworld.h"
#include "iossceneconversion.h"
#include "material.h"
#include "mesh/submesh/staticmesh.h"
#include "resources.h"

#include <Tempest/Device>

#include <cstdint>
#include <type_traits>
#include <utility>
#include <vector>

namespace {

using MaterialUVPeriod = std::remove_cvref_t<decltype(
    std::declval<Material>().texAniMapDirPeriod.x)>;
static_assert(std::is_signed_v<MaterialUVPeriod>);
static_assert(sizeof(MaterialUVPeriod)==sizeof(int32_t));

struct ExtractionContext final {
  const Tempest::Device* device = nullptr;
  IOSRenderWorld*        renderWorld = nullptr;
  IOSSceneAssetRegistry* assets = nullptr;
  uint64_t               sceneTimeMs = 0;

  IOSSceneFrameState               staging;
  IOSSceneExtractionReport          report;
  };

IOSBounds bounds(const IOSSceneSource& source) noexcept {
  return {
    {source.localBoundsMin.x,
     source.localBoundsMin.y,
     source.localBoundsMin.z},
    {source.localBoundsMax.x,
     source.localBoundsMax.y,
     source.localBoundsMax.z},
    };
  }

void visitSource(void* opaque, const IOSSceneSource& source) {
  auto& context = *static_cast<ExtractionContext*>(opaque);
  if(context.report.result!=IOSSceneExtractionResult::Success)
    return;

  const std::optional<Material::AlphaFunc> rawMaterial =
      source.material!=nullptr
        ? std::optional<Material::AlphaFunc>{source.material->alpha}
        : std::nullopt;
  const bool hasFrameAnimation =
      source.material!=nullptr && !source.material->frames.empty();
  const bool hasUvAnimation =
      source.material!=nullptr && source.material->hasUvAnimation();
  const IOSSceneTextureAnimationMode textureAnimation =
      iosSceneTextureAnimationMode(hasFrameAnimation,hasUvAnimation);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  const auto remainingMaterialCensusResult =
      iosRecordRemainingMaterialCensus(
          source.kind,rawMaterial,textureAnimation,
          context.report.remainingMaterialCensus);
  if(remainingMaterialCensusResult==
         IOSRemainingMaterialCensusResult::Invalid ||
     remainingMaterialCensusResult==
         IOSRemainingMaterialCensusResult::Overflow) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return;
    }
  const auto additiveCensusResult = iosRecordAdditiveSourceCensus(
      source.kind,rawMaterial,textureAnimation,
      context.report.additiveSourceCensus);
  if(additiveCensusResult==IOSAdditiveCensusResult::Invalid ||
     additiveCensusResult==IOSAdditiveCensusResult::Overflow) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return;
    }
#endif
  if(!recordIOSSceneRawSource(
       source.kind,rawMaterial,hasFrameAnimation,hasUvAnimation,
       context.report.stats)) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return;
    }
  IOSSceneOpaqueMeshCandidate candidate;
  candidate.sourceId       = source.sourceId;
  candidate.kind           = iosSceneOpaqueMeshKind(source.kind);
  candidate.hasStaticMesh  = source.mesh!=nullptr;
  candidate.hasMaterial    = source.material!=nullptr;
  const IOSSceneMaterialMapping materialMapping =
      source.material!=nullptr
        ? iosSceneMaterialMapping(source.material->alpha)
        : IOSSceneMaterialMapping{};
  candidate.hasMappedMaterialCategory = materialMapping.mapped;
  candidate.materialCategory = materialMapping.category;
  candidate.hasBaseColorTexture =
      source.material!=nullptr && source.material->tex!=nullptr;
  candidate.usesFallbackTexture =
      iosSceneMaterialUsesFallbackTexture(
          source.material,materialMapping,hasFrameAnimation,
          source.material!=nullptr
            ? &Resources::fallbackTexture()
            : nullptr);
  candidate.alphaWeight = source.material!=nullptr
      ? source.material->alphaWeight
      : 1.f;
  candidate.hasFrameAnimation = hasFrameAnimation;
  candidate.hasUvAnimation = hasUvAnimation;
  candidate.hasValidFrameSequence =
      hasFrameAnimation && hasValidIOSSceneFrameSequence(source.material);
  candidate.sceneTimeMs = context.sceneTimeMs;
  candidate.frameCount = source.material!=nullptr
      ? static_cast<uint64_t>(source.material->frames.size())
      : 0u;
  candidate.framePeriodMs = iosSceneFramePeriodMs(
      hasFrameAnimation,
      source.material!=nullptr ? source.material->texAniFPSInv : 0u);
  candidate.uvPeriodX = source.material!=nullptr
      ? static_cast<int32_t>(source.material->texAniMapDirPeriod.x)
      : 0;
  candidate.uvPeriodY = source.material!=nullptr
      ? static_cast<int32_t>(source.material->texAniMapDirPeriod.y)
      : 0;
  candidate.hasLocalBounds = source.hasLocalBounds;
  candidate.transform      = IOSSceneConversion::matrix(source.transform);
  candidate.localBounds    = bounds(source);
  candidate.indices        = {source.firstIndex,source.indexCount};

  IOSSceneOpaqueMeshPlan plan;
  const auto planned = planIOSOpaqueMeshSource(candidate,plan);
  switch(planned) {
    case IOSSceneSourcePlanResult::SkippedKind:
    case IOSSceneSourcePlanResult::SkippedMaterial:
    case IOSSceneSourcePlanResult::SkippedTextureAnimation:
      if(!recordIOSScenePlanResult(
           planned,plan,context.report.stats,textureAnimation))
        context.report.result = IOSSceneExtractionResult::InvalidSource;
      return;
    case IOSSceneSourcePlanResult::InvalidSource:
      (void)recordIOSScenePlanResult(planned,plan,context.report.stats);
      context.report.result = IOSSceneExtractionResult::InvalidSource;
      return;
    case IOSSceneSourcePlanResult::Planned:
      break;
    }

  const Tempest::Texture2d* selectedTexture = nullptr;
  if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly ||
     plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv) {
    if(selectIOSSceneFrameTextureForExtraction(
           source.material,plan,selectedTexture)!=
       IOSSceneExtractionResult::Success) {
      (void)recordIOSSceneInvalidSource(context.report.stats);
      context.report.result = IOSSceneExtractionResult::InvalidSource;
      return;
      }
    }

  const IOSRenderEntityId entity =
      context.renderWorld->resolveEntity(plan.entityStableKey);
  const IOSMeshHandle mesh =
      context.renderWorld->resolveMesh(plan.meshStableKey);
  const IOSMaterialHandle material =
      context.renderWorld->resolveMaterial(plan.materialStableKey);
  const IOSTextureHandle texture =
      plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly ||
      plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv
        ? context.renderWorld->resolveFrameTexture(
              plan.textureStableKey,plan.frameOrdinal)
        : context.renderWorld->resolveTexture(plan.textureStableKey);

  const auto bound = context.assets->bindMesh(
      *context.device,
      mesh,
      source.mesh->vbo,
      source.mesh->ibo,
      sizeof(Resources::Vertex),
      std::size_t(plan.indices.offset),
      std::size_t(plan.indices.count),
      plan.localBounds);
  if(!isIOSSceneAssetBindSuccess(bound)) {
    context.report.result = IOSSceneExtractionResult::AssetBindFailed;
    context.report.bindFailure = bound;
    return;
    }

  const Tempest::Texture2d& baseColorTexture =
      selectedTexture!=nullptr
        ? *selectedTexture
        : source.material->tex!=nullptr
        ? *source.material->tex
        : Resources::fallbackTexture();
  const auto textureBound = context.assets->bindTexture(
      *context.device,texture,baseColorTexture);
  if(!isIOSSceneAssetBindSuccess(textureBound)) {
    context.report.result = IOSSceneExtractionResult::AssetBindFailed;
    context.report.bindFailure = textureBound;
    return;
    }

  if(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly)
    context.report.frameAnimation.selections.push_back(
        {plan.textureStableKey,plan.frameOrdinal,texture});
  else if(plan.textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||
          plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv)
    context.report.uvAnimation.selections.push_back(
        {plan.textureStableKey,plan.textureAnimation,plan.frameOrdinal,
         texture,plan.uvOffset});

  IOSMaterial materialRecord;
  materialRecord.id               = material;
  materialRecord.baseColorTexture = texture;
  materialRecord.usesFallbackTexture = plan.usesFallbackTexture;
  materialRecord.category         = plan.materialCategory;
  materialRecord.baseColor.w      = plan.baseColorAlpha;
  materialRecord.uvOffset         = plan.uvOffset;
  materialRecord.flags            = plan.materialFlags;
  context.staging.materials.push_back(materialRecord);

  IOSRenderEntityState entityRecord;
  entityRecord.id             = entity;
  entityRecord.mesh           = mesh;
  entityRecord.material       = material;
  entityRecord.kind           = plan.kind;
  entityRecord.transform      = plan.transform;
  entityRecord.bounds         = plan.localBounds;
  entityRecord.visibilityMask = plan.visibilityMask;
  context.staging.entities.push_back(entityRecord);
  if(!recordIOSScenePlanResult(
       IOSSceneSourcePlanResult::Planned,plan,context.report.stats,
       textureAnimation))
    context.report.result = IOSSceneExtractionResult::InvalidSource;
  }

}

IOSSceneExtractionReport IOSSceneExtractor::extractOpaqueMeshes(
    const IOSSceneSourceProvider& source,
    const Tempest::Device& device,
    IOSRenderWorld& renderWorld,
    IOSSceneAssetRegistry& assets,
    IOSSceneFrameState& frame) const {
  IOSSceneExtractionReport report;
  if(!frame.entities.empty() || !frame.materials.empty()) {
    report.result = IOSSceneExtractionResult::FrameAlreadyPopulated;
    return report;
    }
  if(!assets.isInitialized()) {
    report.result = IOSSceneExtractionResult::RegistryUnavailable;
    return report;
    }
  if(assets.state()!=IOSSceneAssetRegistryState::Active) {
    report.result = IOSSceneExtractionResult::RegistryResetRequired;
    return report;
    }
  if(assets.generation()!=renderWorld.generation()) {
    report.result = IOSSceneExtractionResult::GenerationMismatch;
    return report;
    }

  ExtractionContext context;
  context.device      = &device;
  context.renderWorld = &renderWorld;
  context.assets      = &assets;
  context.sceneTimeMs = frame.sceneTimeMs;
  source.visit(&context,&visitSource);
  if(context.report.result!=IOSSceneExtractionResult::Success)
    return context.report;
  if(!context.report.stats.hasConsistentSuccessfulCensus()) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return context.report;
    }
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  static_assert(sizeof(std::size_t)<=sizeof(uint64_t));
  if(!iosFinalizeAdditiveSourceCensus(
       context.report.additiveSourceCensus,
       static_cast<uint64_t>(
           context.report.stats.census.materials.additiveLight))) {
    (void)recordIOSSceneInvalidSource(context.report.stats);
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return context.report;
    }
  const std::array<uint64_t,IOSRemainingMaterialCount> remainingRawTotals = {
    static_cast<uint64_t>(context.report.stats.census.materials.water),
    static_cast<uint64_t>(context.report.stats.census.materials.ghost),
    static_cast<uint64_t>(context.report.stats.census.materials.multiply),
    static_cast<uint64_t>(context.report.stats.census.materials.multiply2),
    static_cast<uint64_t>(context.report.stats.census.materials.transparent),
    };
  if(!iosFinalizeRemainingMaterialCensus(
       context.report.remainingMaterialCensus,remainingRawTotals)) {
    (void)recordIOSSceneInvalidSource(context.report.stats);
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return context.report;
    }
#endif
  if(!finalizeIOSFrameAnimationEvidence(context.report.frameAnimation) ||
     context.report.frameAnimation.admittedFrameOnly!=
         context.report.stats.admittedFrameOnly ||
     context.report.frameAnimation.nonzeroFrameOrdinals!=
         context.report.stats.nonzeroFrameOrdinals ||
     !finalizeIOSUVAnimationEvidence(context.report.uvAnimation) ||
     context.report.uvAnimation.admittedUvOnly!=
         context.report.stats.admittedUvOnly ||
     context.report.uvAnimation.admittedFrameAndUv!=
         context.report.stats.admittedFrameAndUv ||
     context.report.uvAnimation.plannedCount!=
         context.report.stats.admittedUvOnly+
             context.report.stats.admittedFrameAndUv) {
    (void)recordIOSSceneInvalidSource(context.report.stats);
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return context.report;
    }

  if(!publishIOSSceneExtraction(
       context.report.result,context.staging,frame)) {
    context.report.result = IOSSceneExtractionResult::InvalidSource;
    return context.report;
    }
  return context.report;
  }
