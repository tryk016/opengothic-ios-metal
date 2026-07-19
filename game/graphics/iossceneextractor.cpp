#include "iossceneextractor.h"

#include "iosrenderworld.h"
#include "iossceneconversion.h"
#include "material.h"
#include "mesh/submesh/staticmesh.h"
#include "resources.h"

#include <Tempest/Device>

#include <utility>
#include <vector>

namespace {

struct ExtractionContext final {
  const Tempest::Device* device = nullptr;
  IOSRenderWorld*        renderWorld = nullptr;
  IOSSceneAssetRegistry* assets = nullptr;

  std::vector<IOSRenderEntityState> entities;
  std::vector<IOSMaterial>          materials;
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

  ++context.report.stats.visited;
  IOSSceneLandscapeCandidate candidate;
  candidate.sourceId       = source.sourceId;
  candidate.isLandscape    =
      source.kind==IOSSceneSourceKind::Landscape;
  candidate.hasStaticMesh  = source.mesh!=nullptr;
  candidate.hasMaterial    = source.material!=nullptr;
  candidate.isSolidMaterial =
      source.material!=nullptr && source.material->alpha==Material::Solid;
  candidate.hasBaseColorTexture =
      source.material!=nullptr && source.material->tex!=nullptr;
  candidate.hasTextureAnimation =
      source.material!=nullptr &&
      (source.material->hasFrameAnimation() ||
       source.material->hasUvAnimation());
  candidate.hasLocalBounds = source.hasLocalBounds;
  candidate.transform      = IOSSceneConversion::matrix(source.transform);
  candidate.localBounds    = bounds(source);
  candidate.indices        = {source.firstIndex,source.indexCount};

  IOSSceneLandscapePlan plan;
  const auto planned = planIOSLandscapeSource(candidate,plan);
  switch(planned) {
    case IOSSceneSourcePlanResult::SkippedKind:
      ++context.report.stats.skippedKind;
      return;
    case IOSSceneSourcePlanResult::SkippedMaterial:
      ++context.report.stats.skippedMaterial;
      return;
    case IOSSceneSourcePlanResult::SkippedTextureAnimation:
      ++context.report.stats.skippedTextureAnimation;
      return;
    case IOSSceneSourcePlanResult::InvalidSource:
      ++context.report.stats.invalidSource;
      context.report.result = IOSSceneExtractionResult::InvalidSource;
      return;
    case IOSSceneSourcePlanResult::Planned:
      break;
    }

  const IOSRenderEntityId entity =
      context.renderWorld->resolveEntity(plan.entityStableKey);
  const IOSMeshHandle mesh =
      context.renderWorld->resolveMesh(plan.meshStableKey);
  const IOSMaterialHandle material =
      context.renderWorld->resolveMaterial(plan.materialStableKey);
  const IOSTextureHandle texture =
      context.renderWorld->resolveTexture(plan.textureStableKey);

  const auto bound = context.assets->bindMesh(
      *context.device,
      mesh,
      source.mesh->vbo,
      source.mesh->ibo,
      sizeof(Resources::Vertex),
      std::size_t(plan.indices.offset),
      std::size_t(plan.indices.count),
      plan.localBounds);
  if(bound!=IOSSceneAssetBindResult::Bound &&
     bound!=IOSSceneAssetBindResult::AlreadyBound) {
    context.report.result = IOSSceneExtractionResult::AssetBindFailed;
    context.report.bindFailure = bound;
    return;
    }

  const Tempest::Texture2d& baseColorTexture =
      source.material->tex!=nullptr
        ? *source.material->tex
        : Resources::fallbackTexture();
  const auto textureBound = context.assets->bindTexture(
      *context.device,texture,baseColorTexture);
  if(textureBound!=IOSSceneAssetBindResult::Bound &&
     textureBound!=IOSSceneAssetBindResult::AlreadyBound) {
    context.report.result = IOSSceneExtractionResult::AssetBindFailed;
    context.report.bindFailure = textureBound;
    return;
    }

  IOSMaterial materialRecord;
  materialRecord.id               = material;
  materialRecord.baseColorTexture = texture;
  materialRecord.category         = plan.materialCategory;
  context.materials.push_back(materialRecord);

  IOSRenderEntityState entityRecord;
  entityRecord.id             = entity;
  entityRecord.mesh           = mesh;
  entityRecord.material       = material;
  entityRecord.transform      = plan.transform;
  entityRecord.bounds         = plan.localBounds;
  entityRecord.visibilityMask = plan.visibilityMask;
  context.entities.push_back(entityRecord);
  ++context.report.stats.planned;
  if(plan.usesFallbackTexture)
    ++context.report.stats.fallbackTexture;
  }

}

IOSSceneExtractionReport IOSSceneExtractor::extractLandscape(
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
  source.visit(&context,&visitSource);
  if(context.report.result!=IOSSceneExtractionResult::Success)
    return context.report;

  frame.entities  = std::move(context.entities);
  frame.materials = std::move(context.materials);
  return context.report;
  }
