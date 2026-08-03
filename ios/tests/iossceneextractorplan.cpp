#include "graphics/iossceneextractor.h"

#include <array>
#include <cassert>
#include <limits>
#include <optional>
#include <type_traits>
#include <vector>

namespace {

// Exact P2.1c2 compositional fixture, mirrored in the history/GPU tests.
constexpr uint64_t MovableSourceId = 0x21C2u;

IOSMatrix4x4 movableT0() {
  IOSMatrix4x4 transform;
  transform.set(0u,3u,11.f);
  transform.set(1u,3u,22.f);
  transform.set(2u,3u,33.f);
  return transform;
  }

IOSMatrix4x4 movableT1() {
  IOSMatrix4x4 transform;
  transform.set(0u,3u,44.f);
  transform.set(1u,3u,55.f);
  transform.set(2u,3u,66.f);
  return transform;
  }

IOSSceneOpaqueMeshCandidate candidate(
    IOSSceneMeshKind kind = IOSSceneMeshKind::Landscape,
    IOSMaterialCategory category = IOSMaterialCategory::Opaque) {
  IOSSceneOpaqueMeshCandidate source;
  source.sourceId       = 41;
  source.kind           = kind;
  source.hasStaticMesh  = true;
  source.hasMaterial    = true;
  source.hasMappedMaterialCategory = true;
  source.materialCategory = category;
  source.hasBaseColorTexture = true;
  source.hasLocalBounds = true;
  source.localBounds    = {{-2.f,-3.f,-4.f},{5.f,6.f,7.f}};
  source.indices        = {192,384};
  source.transform.set(0,3,11.f);
  source.transform.set(1,3,12.f);
  source.transform.set(2,3,13.f);
  return source;
  }

IOSRenderEntityState entity(uint64_t value) {
  IOSRenderEntityState result;
  result.id = {{7},value};
  result.mesh = {{7},value+1u};
  result.material = {{7},value+2u};
  result.kind = IOSSceneMeshKind::Landscape;
  return result;
  }

IOSMaterial material(uint64_t value) {
  IOSMaterial result;
  result.id = {{7},value};
  result.baseColorTexture = {{7},value+1u};
  return result;
  }

IOSSceneOpaqueMeshPlan acceptedPlan(
    IOSSceneSourceKind kind,
    Material::AlphaFunc alpha = Material::Solid) {
  const auto mapping = iosSceneMaterialMapping(alpha);
  assert(mapping.mapped);
  IOSSceneOpaqueMeshPlan plan;
  assert(planIOSOpaqueMeshSource(
           candidate(iosSceneOpaqueMeshKind(kind),mapping.category),plan)==
         IOSSceneSourcePlanResult::Planned);
  return plan;
  }

void recordRawOutcome(
    IOSSceneSourceKind kind,
    std::optional<Material::AlphaFunc> alpha,
    bool frameAnimated,
    bool uvAnimated,
    IOSSceneSourcePlanResult outcome,
    IOSSceneExtractionStats& stats) {
  assert(recordIOSSceneRawSource(
      kind,alpha,frameAnimated,uvAnimated,stats));
  IOSSceneOpaqueMeshPlan plan;
  if(outcome==IOSSceneSourcePlanResult::Planned) {
    assert(alpha.has_value());
    plan = acceptedPlan(kind,*alpha);
    }
  assert(recordIOSScenePlanResult(
      outcome,plan,stats,
      iosSceneTextureAnimationMode(frameAnimated,uvAnimated)));
  }

bool sameFrame(const IOSSceneFrameState& lhs,
               const IOSSceneFrameState& rhs) {
  return lhs.camera==rhs.camera &&
         lhs.sky==rhs.sky &&
         lhs.entities==rhs.entities &&
         lhs.materials==rhs.materials &&
         lhs.lights==rhs.lights &&
         lhs.bones==rhs.bones &&
         lhs.morphWeights==rhs.morphWeights &&
         lhs.particles==rhs.particles &&
         lhs.effects==rhs.effects &&
         lhs.featureMask==rhs.featureMask &&
         lhs.resetHistory==rhs.resetHistory;
  }

void validatePublicContract() {
  static_assert(std::is_trivially_copyable_v<IOSSceneMeshKind>);
  static_assert(
      std::is_trivially_copyable_v<IOSSceneTextureAnimationMode>);
  static_assert(std::is_trivially_copyable_v<IOSSceneMaterialMapping>);
  static_assert(std::is_trivially_copyable_v<IOSSceneOpaqueMeshCandidate>);
  static_assert(std::is_trivially_copyable_v<IOSSceneOpaqueMeshPlan>);

  assert(iosSceneTextureAnimationMode(false,false)==
         IOSSceneTextureAnimationMode::None);
  assert(iosSceneTextureAnimationMode(true,false)==
         IOSSceneTextureAnimationMode::FrameOnly);
  assert(iosSceneTextureAnimationMode(false,true)==
         IOSSceneTextureAnimationMode::UvOnly);
  assert(iosSceneTextureAnimationMode(true,true)==
         IOSSceneTextureAnimationMode::FrameAndUv);

  using Extract = IOSSceneExtractionReport (IOSSceneExtractor::*)(
      const IOSSceneSourceProvider&,const Tempest::Device&,IOSRenderWorld&,
      IOSSceneAssetRegistry&,IOSSceneFrameState&) const;
  static_assert(std::is_same_v<
      decltype(&IOSSceneExtractor::extractOpaqueMeshes),
      Extract>);

  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Landscape)==
         IOSSceneMeshKind::Landscape);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Static)==
         IOSSceneMeshKind::Static);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Movable)==
         IOSSceneMeshKind::Movable);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Animated)==
         IOSSceneMeshKind::Unsupported);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Particle)==
         IOSSceneMeshKind::Unsupported);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Morph)==
         IOSSceneMeshKind::Unsupported);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Unsupported)==
         IOSSceneMeshKind::Unsupported);
  assert(iosSceneOpaqueMeshKind(
           static_cast<IOSSceneSourceKind>(255u))==
         IOSSceneMeshKind::Unsupported);
  assert((iosSceneMaterialMapping(Material::Solid)==
          IOSSceneMaterialMapping{IOSMaterialCategory::Opaque,true}));
  assert((iosSceneMaterialMapping(Material::AlphaTest)==
          IOSSceneMaterialMapping{IOSMaterialCategory::AlphaTest,true}));
  for(const auto alpha:{
        Material::Water,
        Material::Ghost,
        Material::Multiply,
        Material::Multiply2,
        Material::Transparent,
        Material::AdditiveLight,
        static_cast<Material::AlphaFunc>(255u)}) {
    assert(iosSceneMaterialMapping(alpha)==IOSSceneMaterialMapping{});
    }
  }

void validateAcceptedKinds() {
  for(const auto category:{
        IOSMaterialCategory::Opaque,
        IOSMaterialCategory::AlphaTest}) {
    for(const auto kind:{
          IOSSceneMeshKind::Landscape,
          IOSSceneMeshKind::Static,
          IOSSceneMeshKind::Movable}) {
      const auto accepted = candidate(kind,category);
      IOSSceneOpaqueMeshPlan plan;
      assert(planIOSOpaqueMeshSource(accepted,plan)==
             IOSSceneSourcePlanResult::Planned);
      assert(plan.kind==kind);
      assert(plan.entityStableKey==41);
      assert(plan.meshStableKey==41);
      assert(plan.materialStableKey==41);
      assert(plan.textureStableKey==41);
      assert(plan.indices==accepted.indices);
      assert(plan.localBounds==accepted.localBounds);
      assert(plan.transform==accepted.transform);
      assert(plan.materialCategory==category);
      assert(plan.visibilityMask==IOSSceneVisibilityMain);
      assert(!plan.usesFallbackTexture);
      }
    }
  }

void validateSkippedSources() {
  IOSSceneOpaqueMeshPlan plan;
  auto unsupported = candidate(IOSSceneMeshKind::Unsupported);
  assert(planIOSOpaqueMeshSource(unsupported,plan)==
         IOSSceneSourcePlanResult::SkippedKind);

  auto fabricated = candidate(
      static_cast<IOSSceneMeshKind>(255u));
  assert(planIOSOpaqueMeshSource(fabricated,plan)==
         IOSSceneSourcePlanResult::SkippedKind);

  for(const auto category:{
        IOSMaterialCategory::Transparent,
        IOSMaterialCategory::Additive,
        IOSMaterialCategory::Water,
        static_cast<IOSMaterialCategory>(255u)}) {
    auto unsupportedMaterial =
        candidate(IOSSceneMeshKind::Landscape,category);
    assert(planIOSOpaqueMeshSource(unsupportedMaterial,plan)==
           IOSSceneSourcePlanResult::SkippedMaterial);
    }

  for(const auto kind:{
        IOSSceneMeshKind::Landscape,
        IOSSceneMeshKind::Static,
        IOSSceneMeshKind::Movable}) {
    auto alphaTest = candidate(kind,IOSMaterialCategory::AlphaTest);
    assert(planIOSOpaqueMeshSource(alphaTest,plan)==
           IOSSceneSourcePlanResult::Planned);
    auto alphaFrameAnimated = alphaTest;
    alphaFrameAnimated.hasFrameAnimation = true;
    assert(planIOSOpaqueMeshSource(alphaFrameAnimated,plan)==
           IOSSceneSourcePlanResult::SkippedTextureAnimation);
    auto alphaUvAnimated = alphaTest;
    alphaUvAnimated.hasUvAnimation = true;
    assert(planIOSOpaqueMeshSource(alphaUvAnimated,plan)==
           IOSSceneSourcePlanResult::SkippedTextureAnimation);

    auto frameAnimated = candidate(kind);
    frameAnimated.hasFrameAnimation = true;
    assert(planIOSOpaqueMeshSource(frameAnimated,plan)==
           IOSSceneSourcePlanResult::SkippedTextureAnimation);
    auto uvAnimated = candidate(kind);
    uvAnimated.hasUvAnimation = true;
    assert(planIOSOpaqueMeshSource(uvAnimated,plan)==
           IOSSceneSourcePlanResult::SkippedTextureAnimation);
    assert(plan.kind==IOSSceneMeshKind::Unsupported);
    assert(plan.entityStableKey==0u);
    assert(plan.textureStableKey==0u);
    assert(plan.indices==IOSIndexRange{});
    }
  }

void validateMalformedAcceptedKinds() {
  for(const auto kind:{
        IOSSceneMeshKind::Landscape,
        IOSSceneMeshKind::Static,
        IOSSceneMeshKind::Movable}) {
    IOSSceneOpaqueMeshPlan plan;

    auto noMaterial = candidate(kind);
    noMaterial.hasMaterial = false;
    assert(planIOSOpaqueMeshSource(noMaterial,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto noMesh = candidate(kind);
    noMesh.hasStaticMesh = false;
    assert(planIOSOpaqueMeshSource(noMesh,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto noIdentity = candidate(kind);
    noIdentity.sourceId = 0;
    assert(planIOSOpaqueMeshSource(noIdentity,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto noBounds = candidate(kind);
    noBounds.hasLocalBounds = false;
    assert(planIOSOpaqueMeshSource(noBounds,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto empty = candidate(kind);
    empty.indices.count = 0;
    assert(planIOSOpaqueMeshSource(empty,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto nonTriangle = candidate(kind);
    nonTriangle.indices.count = 4;
    assert(planIOSOpaqueMeshSource(nonTriangle,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto overflow = candidate(kind);
    overflow.indices = {std::numeric_limits<uint32_t>::max()-2u,3};
    assert(planIOSOpaqueMeshSource(overflow,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto invalidBounds = candidate(kind);
    invalidBounds.localBounds.minimum.x = 10.f;
    assert(planIOSOpaqueMeshSource(invalidBounds,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto nonFinite = candidate(kind);
    nonFinite.transform.elements[0] =
        std::numeric_limits<float>::infinity();
    assert(planIOSOpaqueMeshSource(nonFinite,plan)==
           IOSSceneSourcePlanResult::InvalidSource);
    }
  }

void validateFallbackAndMixedCounters() {
  auto landscape = candidate(IOSSceneMeshKind::Landscape);
  auto staticMesh = candidate(IOSSceneMeshKind::Static);
  staticMesh.hasBaseColorTexture = false;
  staticMesh.usesFallbackTexture = true;
  auto movable = candidate(IOSSceneMeshKind::Movable);
  movable.materialCategory = IOSMaterialCategory::AlphaTest;
  auto unsupported = candidate(IOSSceneMeshKind::Unsupported);
  auto materialSkip = candidate(IOSSceneMeshKind::Static);
  materialSkip.hasMappedMaterialCategory = false;
  auto animationSkip = candidate(IOSSceneMeshKind::Landscape);
  animationSkip.hasFrameAnimation = true;
  auto malformed = candidate(IOSSceneMeshKind::Static);
  malformed.hasStaticMesh = false;

  const std::vector<IOSSceneOpaqueMeshCandidate> sources = {
    landscape,
    staticMesh,
    movable,
    unsupported,
    materialSkip,
    animationSkip,
    malformed,
    };

  IOSSceneExtractionStats stats;
  stats.census.frameAnimated = 1u;
  for(const auto& source:sources) {
    ++stats.visited;
    IOSSceneOpaqueMeshPlan plan;
    const auto result = planIOSOpaqueMeshSource(source,plan);
    const bool accepted = recordIOSScenePlanResult(
        result,plan,stats,
        iosSceneTextureAnimationMode(
            source.hasFrameAnimation,source.hasUvAnimation));
    assert(accepted==(result!=IOSSceneSourcePlanResult::InvalidSource));
    }

  assert(stats.visited==7u);
  assert(stats.planned==3u);
  assert(stats.plannedOpaque==2u);
  assert(stats.plannedAlphaTest==1u);
  assert(stats.plannedLandscape==1u);
  assert(stats.plannedStatic==1u);
  assert(stats.plannedMovable==1u);
  assert(stats.skippedKind==1u);
  assert(stats.skippedMaterial==1u);
  assert(stats.skippedTextureAnimation==1u);
  assert(stats.skippedTextureFrameOnly==1u);
  assert(stats.skippedTextureUvOnly==0u);
  assert(stats.skippedTextureFrameAndUv==0u);
  assert(stats.fallbackTexture==1u);
  assert(stats.alphaFallback==0u);
  assert(stats.invalidSource==1u);
  assert(stats.hasConsistentPlannedCounts());
  }

void validateRawKindCensus() {
  IOSSceneExtractionStats stats;
  recordRawOutcome(
      IOSSceneSourceKind::Landscape,Material::Solid,false,false,
      IOSSceneSourcePlanResult::Planned,stats);
  recordRawOutcome(
      IOSSceneSourceKind::Static,Material::Solid,false,false,
      IOSSceneSourcePlanResult::Planned,stats);
  recordRawOutcome(
      IOSSceneSourceKind::Movable,Material::Solid,false,false,
      IOSSceneSourcePlanResult::Planned,stats);
  for(const auto kind:{
        IOSSceneSourceKind::Animated,
        IOSSceneSourceKind::Particle,
        IOSSceneSourceKind::Morph,
        IOSSceneSourceKind::Unsupported}) {
    recordRawOutcome(
        kind,Material::Solid,false,false,
        IOSSceneSourcePlanResult::SkippedKind,stats);
    }

  assert(stats.visited==7u);
  assert(stats.census.kinds.landscape==1u);
  assert(stats.census.kinds.staticMesh==1u);
  assert(stats.census.kinds.movable==1u);
  assert(stats.census.kinds.animated==1u);
  assert(stats.census.kinds.particle==1u);
  assert(stats.census.kinds.morph==1u);
  assert(stats.census.kinds.unsupported==1u);
  assert(stats.census.kinds.unknown==0u);
  assert(stats.census.materials.solid==7u);
  assert(stats.planned==3u);
  assert(stats.skippedKind==4u);
  assert(stats.hasConsistentSuccessfulCensus());
  }

void validateRawMaterialCensus() {
  IOSSceneExtractionStats stats;
  for(const auto alpha:{Material::Solid,Material::AlphaTest}) {
    recordRawOutcome(
        IOSSceneSourceKind::Static,alpha,false,false,
        IOSSceneSourcePlanResult::Planned,stats);
    }
  for(const auto alpha:{
        Material::Water,
        Material::Ghost,
        Material::Multiply,
        Material::Multiply2,
        Material::Transparent,
        Material::AdditiveLight}) {
    recordRawOutcome(
        IOSSceneSourceKind::Static,alpha,false,false,
        IOSSceneSourcePlanResult::SkippedMaterial,stats);
    }

  assert(stats.visited==8u);
  assert(stats.census.kinds.staticMesh==8u);
  assert(stats.census.materials.solid==1u);
  assert(stats.census.materials.alphaTest==1u);
  assert(stats.census.materials.water==1u);
  assert(stats.census.materials.ghost==1u);
  assert(stats.census.materials.multiply==1u);
  assert(stats.census.materials.multiply2==1u);
  assert(stats.census.materials.transparent==1u);
  assert(stats.census.materials.additiveLight==1u);
  assert(stats.census.materials.missing==0u);
  assert(stats.census.materials.unknown==0u);
  assert(stats.planned==2u);
  assert(stats.skippedMaterial==6u);
  assert(stats.hasConsistentSuccessfulCensus());
  }

void validateMissingAndInvalidRawSources() {
  IOSSceneExtractionStats skippedMissing;
  recordRawOutcome(
      IOSSceneSourceKind::Unsupported,std::nullopt,false,false,
      IOSSceneSourcePlanResult::SkippedKind,skippedMissing);
  assert(skippedMissing.census.kinds.unsupported==1u);
  assert(skippedMissing.census.materials.missing==1u);
  assert(skippedMissing.census.materials.unknown==0u);
  assert(skippedMissing.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats missing;
  assert(recordIOSSceneRawSource(
      IOSSceneSourceKind::Static,std::nullopt,false,false,missing));
  assert(missing.visited==1u);
  assert(missing.census.kinds.staticMesh==1u);
  assert(missing.census.materials.missing==1u);
  assert(missing.census.materials.unknown==0u);
  IOSSceneOpaqueMeshPlan plan;
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::InvalidSource,plan,missing));
  assert(missing.invalidSource==1u);

  IOSSceneExtractionStats invalidMaterial;
  assert(!recordIOSSceneRawSource(
      IOSSceneSourceKind::Static,
      static_cast<Material::AlphaFunc>(255u),false,false,
      invalidMaterial));
  assert(invalidMaterial.visited==1u);
  assert(invalidMaterial.census.kinds.staticMesh==1u);
  assert(invalidMaterial.census.materials.missing==0u);
  assert(invalidMaterial.census.materials.unknown==1u);
  assert(invalidMaterial.invalidSource==1u);

  IOSSceneExtractionStats invalidKind;
  assert(!recordIOSSceneRawSource(
      static_cast<IOSSceneSourceKind>(255u),Material::Solid,false,false,
      invalidKind));
  assert(invalidKind.visited==1u);
  assert(invalidKind.census.kinds.unknown==1u);
  assert(invalidKind.census.materials.solid==1u);
  assert(invalidKind.invalidSource==1u);
  }

void validateOverlappingAnimationCensus() {
  IOSSceneExtractionStats stats;
  recordRawOutcome(
      IOSSceneSourceKind::Static,Material::Solid,true,false,
      IOSSceneSourcePlanResult::SkippedTextureAnimation,stats);
  recordRawOutcome(
      IOSSceneSourceKind::Movable,Material::AlphaTest,false,true,
      IOSSceneSourcePlanResult::SkippedTextureAnimation,stats);
  recordRawOutcome(
      IOSSceneSourceKind::Landscape,Material::AlphaTest,true,true,
      IOSSceneSourcePlanResult::SkippedTextureAnimation,stats);
  recordRawOutcome(
      IOSSceneSourceKind::Animated,Material::Solid,true,false,
      IOSSceneSourcePlanResult::SkippedKind,stats);
  recordRawOutcome(
      IOSSceneSourceKind::Static,Material::Water,false,true,
      IOSSceneSourcePlanResult::SkippedMaterial,stats);

  assert(stats.census.frameAnimated==3u);
  assert(stats.census.uvAnimated==3u);
  assert(stats.skippedTextureAnimation==3u);
  assert(stats.skippedTextureFrameOnly==1u);
  assert(stats.skippedTextureUvOnly==1u);
  assert(stats.skippedTextureFrameAndUv==1u);
  assert(stats.skippedKind==1u);
  assert(stats.skippedMaterial==1u);
  assert(stats.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats frameOverflow = stats;
  frameOverflow.census.frameAnimated = frameOverflow.visited+1u;
  assert(!frameOverflow.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats uvOverflow = stats;
  uvOverflow.census.uvAnimated = uvOverflow.visited+1u;
  assert(!uvOverflow.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats frameBound = stats;
  frameBound.census.frameAnimated = 2u;
  frameBound.skippedTextureFrameOnly = 2u;
  frameBound.skippedTextureUvOnly = 0u;
  assert(!frameBound.hasConsistentTextureAnimationCounts());
  assert(!frameBound.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats uvBound = stats;
  uvBound.census.uvAnimated = 2u;
  uvBound.skippedTextureFrameOnly = 0u;
  uvBound.skippedTextureUvOnly = 2u;
  assert(!uvBound.hasConsistentTextureAnimationCounts());
  assert(!uvBound.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats modeSumOverflow;
  modeSumOverflow.skippedTextureAnimation =
      std::numeric_limits<std::size_t>::max();
  modeSumOverflow.skippedTextureFrameOnly =
      std::numeric_limits<std::size_t>::max();
  modeSumOverflow.skippedTextureUvOnly = 1u;
  assert(!modeSumOverflow.hasConsistentTextureAnimationCounts());

  IOSSceneExtractionStats impossibleNone;
  assert(recordIOSSceneRawSource(
      IOSSceneSourceKind::Static,Material::Solid,false,false,
      impossibleNone));
  IOSSceneOpaqueMeshPlan plan;
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::SkippedTextureAnimation,plan,
      impossibleNone,IOSSceneTextureAnimationMode::None));
  assert(impossibleNone.skippedTextureAnimation==0u);
  assert(impossibleNone.invalidSource==1u);
  }

IOSSceneExtractionStats permutationStats(bool reverse) {
  struct Source final {
    IOSSceneSourceKind kind;
    Material::AlphaFunc alpha;
    bool frameAnimated;
    bool uvAnimated;
    IOSSceneSourcePlanResult outcome;
    };
  const std::array<Source,4> sources = {{
    {IOSSceneSourceKind::Landscape,Material::Solid,false,false,
     IOSSceneSourcePlanResult::Planned},
    {IOSSceneSourceKind::Animated,Material::Water,false,false,
     IOSSceneSourcePlanResult::SkippedKind},
    {IOSSceneSourceKind::Static,Material::Ghost,false,false,
     IOSSceneSourcePlanResult::SkippedMaterial},
    {IOSSceneSourceKind::Movable,Material::AlphaTest,true,true,
     IOSSceneSourcePlanResult::SkippedTextureAnimation},
    }};
  IOSSceneExtractionStats stats;
  for(std::size_t index = 0; index<sources.size(); ++index) {
    const std::size_t selected = reverse ? sources.size()-1u-index : index;
    const auto& source = sources[selected];
    recordRawOutcome(
        source.kind,source.alpha,source.frameAnimated,source.uvAnimated,
        source.outcome,stats);
    }
  assert(stats.hasConsistentSuccessfulCensus());
  return stats;
  }

void validateCensusPermutationInvariance() {
  assert(permutationStats(false)==permutationStats(true));
  }

void validateKindCounterOverflow(
    IOSSceneSourceKind kind,
    std::size_t IOSSceneSourceKindCensus::* member) {
  IOSSceneExtractionStats stats;
  stats.census.kinds.*member = std::numeric_limits<std::size_t>::max();
  const IOSSceneExtractionStats before = stats;
  assert(!recordIOSSceneRawSource(
      kind,Material::Solid,false,false,stats));
  IOSSceneExtractionStats expected = before;
  expected.invalidSource = 1u;
  assert(stats==expected);
  }

void validateMaterialCounterOverflow(
    std::optional<Material::AlphaFunc> alpha,
    std::size_t IOSSceneMaterialCensus::* member) {
  IOSSceneExtractionStats stats;
  stats.census.materials.*member =
      std::numeric_limits<std::size_t>::max();
  const IOSSceneExtractionStats before = stats;
  assert(!recordIOSSceneRawSource(
      IOSSceneSourceKind::Static,alpha,false,false,stats));
  IOSSceneExtractionStats expected = before;
  expected.invalidSource = 1u;
  assert(stats==expected);
  }

void validateOutcomeCounterOverflow(
    IOSSceneSourcePlanResult result,
    std::size_t IOSSceneExtractionStats::* member,
    IOSSceneTextureAnimationMode textureAnimation =
        IOSSceneTextureAnimationMode::None) {
  IOSSceneExtractionStats stats;
  stats.*member = std::numeric_limits<std::size_t>::max();
  if(textureAnimation==IOSSceneTextureAnimationMode::FrameOnly ||
     textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv)
    stats.census.frameAnimated =
        std::numeric_limits<std::size_t>::max();
  if(textureAnimation==IOSSceneTextureAnimationMode::UvOnly ||
     textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv)
    stats.census.uvAnimated =
        std::numeric_limits<std::size_t>::max();
  const IOSSceneExtractionStats before = stats;
  IOSSceneOpaqueMeshPlan plan;
  assert(!recordIOSScenePlanResult(
      result,plan,stats,textureAnimation));
  IOSSceneExtractionStats expected = before;
  expected.invalidSource = 1u;
  assert(stats==expected);
  }

void validateCheckedCensusCounters() {
  IOSSceneExtractionStats visitedOverflow;
  visitedOverflow.visited = std::numeric_limits<std::size_t>::max();
  assert(!recordIOSSceneRawSource(
      IOSSceneSourceKind::Static,Material::Solid,false,false,
      visitedOverflow));
  assert(visitedOverflow.visited==
         std::numeric_limits<std::size_t>::max());
  assert(visitedOverflow.invalidSource==1u);

  validateKindCounterOverflow(
      IOSSceneSourceKind::Landscape,&IOSSceneSourceKindCensus::landscape);
  validateKindCounterOverflow(
      IOSSceneSourceKind::Static,&IOSSceneSourceKindCensus::staticMesh);
  validateKindCounterOverflow(
      IOSSceneSourceKind::Movable,&IOSSceneSourceKindCensus::movable);
  validateKindCounterOverflow(
      IOSSceneSourceKind::Animated,&IOSSceneSourceKindCensus::animated);
  validateKindCounterOverflow(
      IOSSceneSourceKind::Particle,&IOSSceneSourceKindCensus::particle);
  validateKindCounterOverflow(
      IOSSceneSourceKind::Morph,&IOSSceneSourceKindCensus::morph);
  validateKindCounterOverflow(
      IOSSceneSourceKind::Unsupported,&IOSSceneSourceKindCensus::unsupported);
  validateKindCounterOverflow(
      static_cast<IOSSceneSourceKind>(255u),
      &IOSSceneSourceKindCensus::unknown);

  validateMaterialCounterOverflow(
      Material::Solid,&IOSSceneMaterialCensus::solid);
  validateMaterialCounterOverflow(
      Material::AlphaTest,&IOSSceneMaterialCensus::alphaTest);
  validateMaterialCounterOverflow(
      Material::Water,&IOSSceneMaterialCensus::water);
  validateMaterialCounterOverflow(
      Material::Ghost,&IOSSceneMaterialCensus::ghost);
  validateMaterialCounterOverflow(
      Material::Multiply,&IOSSceneMaterialCensus::multiply);
  validateMaterialCounterOverflow(
      Material::Multiply2,&IOSSceneMaterialCensus::multiply2);
  validateMaterialCounterOverflow(
      Material::Transparent,&IOSSceneMaterialCensus::transparent);
  validateMaterialCounterOverflow(
      Material::AdditiveLight,&IOSSceneMaterialCensus::additiveLight);
  validateMaterialCounterOverflow(
      std::nullopt,&IOSSceneMaterialCensus::missing);
  validateMaterialCounterOverflow(
      static_cast<Material::AlphaFunc>(255u),
      &IOSSceneMaterialCensus::unknown);

  for(const auto animated:{true,false}) {
    IOSSceneExtractionStats stats;
    std::size_t& counter = animated
        ? stats.census.frameAnimated
        : stats.census.uvAnimated;
    counter = std::numeric_limits<std::size_t>::max();
    const IOSSceneExtractionStats before = stats;
    assert(!recordIOSSceneRawSource(
        IOSSceneSourceKind::Static,Material::Solid,
        animated,!animated,stats));
    IOSSceneExtractionStats expected = before;
    expected.invalidSource = 1u;
    assert(stats==expected);
    }

  validateOutcomeCounterOverflow(
      IOSSceneSourcePlanResult::SkippedKind,
      &IOSSceneExtractionStats::skippedKind);
  validateOutcomeCounterOverflow(
      IOSSceneSourcePlanResult::SkippedMaterial,
      &IOSSceneExtractionStats::skippedMaterial);
  validateOutcomeCounterOverflow(
      IOSSceneSourcePlanResult::SkippedTextureAnimation,
      &IOSSceneExtractionStats::skippedTextureAnimation,
      IOSSceneTextureAnimationMode::FrameOnly);
  validateOutcomeCounterOverflow(
      IOSSceneSourcePlanResult::SkippedTextureAnimation,
      &IOSSceneExtractionStats::skippedTextureFrameOnly,
      IOSSceneTextureAnimationMode::FrameOnly);
  validateOutcomeCounterOverflow(
      IOSSceneSourcePlanResult::SkippedTextureAnimation,
      &IOSSceneExtractionStats::skippedTextureUvOnly,
      IOSSceneTextureAnimationMode::UvOnly);
  validateOutcomeCounterOverflow(
      IOSSceneSourcePlanResult::SkippedTextureAnimation,
      &IOSSceneExtractionStats::skippedTextureFrameAndUv,
      IOSSceneTextureAnimationMode::FrameAndUv);

  IOSSceneExtractionStats invalidOverflow;
  invalidOverflow.invalidSource = std::numeric_limits<std::size_t>::max();
  assert(!recordIOSSceneInvalidSource(invalidOverflow));
  assert(invalidOverflow.invalidSource==
         std::numeric_limits<std::size_t>::max());

  IOSSceneExtractionStats kindSumOverflow;
  kindSumOverflow.census.kinds.landscape =
      std::numeric_limits<std::size_t>::max();
  kindSumOverflow.census.kinds.staticMesh = 1u;
  assert(!kindSumOverflow.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats materialSumOverflow;
  materialSumOverflow.census.materials.solid =
      std::numeric_limits<std::size_t>::max();
  materialSumOverflow.census.materials.alphaTest = 1u;
  assert(!materialSumOverflow.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats outcomeSumOverflow;
  outcomeSumOverflow.planned = std::numeric_limits<std::size_t>::max();
  outcomeSumOverflow.plannedOpaque = outcomeSumOverflow.planned;
  outcomeSumOverflow.plannedLandscape = outcomeSumOverflow.planned;
  outcomeSumOverflow.skippedKind = 1u;
  assert(outcomeSumOverflow.hasConsistentPlannedCounts());
  assert(!outcomeSumOverflow.hasConsistentSuccessfulCensus());
  }

void validateStableKeysArePerLiveSlot() {
  auto first = candidate(IOSSceneMeshKind::Movable);
  first.sourceId = 501u;
  auto second = first;
  second.sourceId = 502u;

  IOSSceneOpaqueMeshPlan firstPlan;
  IOSSceneOpaqueMeshPlan secondPlan;
  assert(planIOSOpaqueMeshSource(first,firstPlan)==
         IOSSceneSourcePlanResult::Planned);
  assert(planIOSOpaqueMeshSource(second,secondPlan)==
         IOSSceneSourcePlanResult::Planned);
  assert(firstPlan.kind==IOSSceneMeshKind::Movable);
  assert(secondPlan.kind==IOSSceneMeshKind::Movable);
  assert(firstPlan.entityStableKey!=secondPlan.entityStableKey);
  assert(firstPlan.meshStableKey!=secondPlan.meshStableKey);
  assert(firstPlan.materialStableKey!=secondPlan.materialStableKey);
  assert(firstPlan.textureStableKey!=secondPlan.textureStableKey);
  }

void validateRecordRejectsBrokenPlannedInvariant() {
  IOSSceneOpaqueMeshPlan movablePlan;
  assert(planIOSOpaqueMeshSource(
           candidate(IOSSceneMeshKind::Movable),movablePlan)==
         IOSSceneSourcePlanResult::Planned);

  for(const auto result:{
        IOSSceneSourcePlanResult::Planned,
        IOSSceneSourcePlanResult::SkippedKind,
        IOSSceneSourcePlanResult::SkippedMaterial,
        IOSSceneSourcePlanResult::SkippedTextureAnimation}) {
    IOSSceneExtractionStats stats;
    stats.planned = 1u;
    assert(!stats.hasConsistentPlannedCounts());
    const auto animation =
        result==IOSSceneSourcePlanResult::SkippedTextureAnimation
          ? IOSSceneTextureAnimationMode::FrameOnly
          : IOSSceneTextureAnimationMode::None;
    assert(!recordIOSScenePlanResult(
        result,movablePlan,stats,animation));
    assert(!stats.hasConsistentPlannedCounts());
    }
  }

void validatePlanProvenanceAndCounterMutations() {
  IOSSceneOpaqueMeshPlan plan;
  auto fallback = candidate(IOSSceneMeshKind::Static);
  fallback.hasBaseColorTexture = false;
  fallback.usesFallbackTexture = true;
  assert(planIOSOpaqueMeshSource(fallback,plan)==
         IOSSceneSourcePlanResult::Planned);
  assert(plan.materialCategory==IOSMaterialCategory::Opaque);
  assert(plan.kind==IOSSceneMeshKind::Static);
  assert(plan.usesFallbackTexture);

  for(auto inconsistent:{
        candidate(IOSSceneMeshKind::Landscape),
        candidate(IOSSceneMeshKind::Movable)}) {
    inconsistent.usesFallbackTexture =
        inconsistent.hasBaseColorTexture;
    assert(planIOSOpaqueMeshSource(inconsistent,plan)==
           IOSSceneSourcePlanResult::InvalidSource);
    }
  auto missingProvenance = candidate(IOSSceneMeshKind::Landscape);
  missingProvenance.hasBaseColorTexture = false;
  missingProvenance.usesFallbackTexture = false;
  assert(planIOSOpaqueMeshSource(missingProvenance,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto alpha = candidate(
      IOSSceneMeshKind::Landscape,IOSMaterialCategory::AlphaTest);
  assert(planIOSOpaqueMeshSource(alpha,plan)==
         IOSSceneSourcePlanResult::Planned);
  assert(plan.materialCategory==IOSMaterialCategory::AlphaTest);
  assert(!plan.usesFallbackTexture);
  alpha.hasBaseColorTexture = false;
  alpha.usesFallbackTexture = false;
  assert(planIOSOpaqueMeshSource(alpha,plan)==
         IOSSceneSourcePlanResult::SkippedMaterial);
  alpha.usesFallbackTexture = true;
  assert(planIOSOpaqueMeshSource(alpha,plan)==
         IOSSceneSourcePlanResult::SkippedMaterial);

  IOSSceneExtractionStats overflow;
  overflow.planned = std::numeric_limits<std::size_t>::max();
  overflow.plannedOpaque = overflow.planned;
  overflow.plannedLandscape = overflow.planned;
  const IOSSceneExtractionStats before = overflow;
  IOSSceneOpaqueMeshPlan landscapePlan;
  assert(planIOSOpaqueMeshSource(
           candidate(IOSSceneMeshKind::Landscape),landscapePlan)==
         IOSSceneSourcePlanResult::Planned);
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::Planned,landscapePlan,overflow));
  assert(overflow.planned==before.planned);
  assert(overflow.plannedOpaque==before.plannedOpaque);
  assert(overflow.plannedLandscape==before.plannedLandscape);
  assert(overflow.invalidSource==before.invalidSource+1u);

  IOSSceneExtractionStats invalidStats;
  auto fabricatedPlan = landscapePlan;
  fabricatedPlan.materialCategory =
      static_cast<IOSMaterialCategory>(255u);
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::Planned,fabricatedPlan,invalidStats));
  assert(invalidStats.planned==0u);
  assert(invalidStats.invalidSource==1u);
  fabricatedPlan = landscapePlan;
  fabricatedPlan.kind = static_cast<IOSSceneMeshKind>(255u);
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::Planned,fabricatedPlan,invalidStats));
  assert(invalidStats.planned==0u);
  assert(invalidStats.invalidSource==2u);
  }

void validateMovableTransformFixture() {
  auto frameA = candidate(IOSSceneMeshKind::Movable);
  frameA.sourceId = MovableSourceId;
  frameA.transform = movableT0();
  auto frameB = frameA;
  frameB.transform = movableT1();

  IOSSceneOpaqueMeshPlan planA;
  IOSSceneOpaqueMeshPlan planB;
  assert(planIOSOpaqueMeshSource(frameA,planA)==
         IOSSceneSourcePlanResult::Planned);
  assert(planIOSOpaqueMeshSource(frameB,planB)==
         IOSSceneSourcePlanResult::Planned);
  assert(planA.kind==IOSSceneMeshKind::Movable);
  assert(planB.kind==IOSSceneMeshKind::Movable);
  assert(planA.entityStableKey==MovableSourceId);
  assert(planA.entityStableKey==planB.entityStableKey);
  assert(planA.meshStableKey==planB.meshStableKey);
  assert(planA.materialStableKey==planB.materialStableKey);
  assert(planA.textureStableKey==planB.textureStableKey);
  assert(planA.transform==movableT0());
  assert(planB.transform==movableT1());
  }

void validateBindSuccessClassification() {
  assert(isIOSSceneAssetBindSuccess(IOSSceneAssetBindResult::Bound));
  assert(isIOSSceneAssetBindSuccess(
      IOSSceneAssetBindResult::AlreadyBound));
  assert(!isIOSSceneAssetBindSuccess(
      IOSSceneAssetBindResult::InvalidDevice));
  assert(!isIOSSceneAssetBindSuccess(
      IOSSceneAssetBindResult::ResetRequired));
  assert(!isIOSSceneAssetBindSuccess(
      IOSSceneAssetBindResult::InvalidHandle));
  assert(!isIOSSceneAssetBindSuccess(
      IOSSceneAssetBindResult::InvalidMetadata));
  assert(!isIOSSceneAssetBindSuccess(
      IOSSceneAssetBindResult::NativeHandleUnavailable));
  assert(!isIOSSceneAssetBindSuccess(
      IOSSceneAssetBindResult::Conflict));
  assert(!isIOSSceneAssetBindSuccess(
      static_cast<IOSSceneAssetBindResult>(255u)));
  }

void validateAtomicPublication() {
  IOSSceneFrameState frame;
  frame.camera.position.x = 9.f;
  frame.entities.push_back(entity(900u));
  frame.materials.push_back(material(901u));
  frame.featureMask = IOSSceneFeatureFog;
  frame.resetHistory = true;
  const IOSSceneFrameState original = frame;

  for(const auto result:{
        IOSSceneExtractionResult::FrameAlreadyPopulated,
        IOSSceneExtractionResult::RegistryUnavailable,
        IOSSceneExtractionResult::RegistryResetRequired,
        IOSSceneExtractionResult::GenerationMismatch,
        IOSSceneExtractionResult::InvalidSource,
        IOSSceneExtractionResult::AssetBindFailed}) {
    IOSSceneFrameState staging;
    staging.entities.push_back(entity(10u));
    staging.materials.push_back(material(20u));
    assert(!publishIOSSceneExtraction(result,staging,frame));
    assert(sameFrame(frame,original));
    assert(staging.entities.size()==1u);
    assert(staging.materials.size()==1u);
    }

  IOSSceneFrameState rejectedFrame;
  rejectedFrame.camera.position.x = 23.f;
  rejectedFrame.featureMask = IOSSceneFeatureFog;
  const IOSSceneFrameState rejectedBefore = rejectedFrame;
  IOSSceneFrameState rejectedStaging;
  rejectedStaging.entities.push_back(entity(25u));
  rejectedStaging.materials.push_back(material(26u));
  IOSSceneExtractionStats rejectedStats;
  assert(recordIOSSceneRawSource(
      IOSSceneSourceKind::Static,Material::Solid,false,false,
      rejectedStats));
  rejectedStats.planned = std::numeric_limits<std::size_t>::max();
  rejectedStats.plannedOpaque = rejectedStats.planned;
  rejectedStats.plannedStatic = rejectedStats.planned;
  const auto plan = acceptedPlan(IOSSceneSourceKind::Static);
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::Planned,plan,rejectedStats));
  assert(rejectedStats.invalidSource==1u);
  assert(!publishIOSSceneExtraction(
      IOSSceneExtractionResult::InvalidSource,
      rejectedStaging,rejectedFrame));
  assert(sameFrame(rejectedFrame,rejectedBefore));
  assert(rejectedFrame.entities.empty());
  assert(rejectedFrame.materials.empty());
  assert(rejectedStaging.entities.size()==1u);
  assert(rejectedStaging.materials.size()==1u);

  IOSSceneFrameState destination;
  destination.camera.position.x = 17.f;
  destination.featureMask = IOSSceneFeatureLights;
  const IOSSceneFrameState destinationBefore = destination;
  IOSSceneFrameState staging;
  staging.entities.push_back(entity(30u));
  staging.materials.push_back(material(40u));
  const auto expectedEntities = staging.entities;
  const auto expectedMaterials = staging.materials;

  assert(publishIOSSceneExtraction(
      IOSSceneExtractionResult::Success,staging,destination));
  assert(destination.entities==expectedEntities);
  assert(destination.materials==expectedMaterials);
  assert(staging.entities.empty());
  assert(staging.materials.empty());
  assert(destination.camera==destinationBefore.camera);
  assert(destination.sky==destinationBefore.sky);
  assert(destination.lights==destinationBefore.lights);
  assert(destination.bones==destinationBefore.bones);
  assert(destination.morphWeights==destinationBefore.morphWeights);
  assert(destination.particles==destinationBefore.particles);
  assert(destination.effects==destinationBefore.effects);
  assert(destination.featureMask==destinationBefore.featureMask);
  assert(destination.resetHistory==destinationBefore.resetHistory);
  }

}

int main() {
  validatePublicContract();
  validateAcceptedKinds();
  validateSkippedSources();
  validateMalformedAcceptedKinds();
  validateFallbackAndMixedCounters();
  validateRawKindCensus();
  validateRawMaterialCensus();
  validateMissingAndInvalidRawSources();
  validateOverlappingAnimationCensus();
  validateCensusPermutationInvariance();
  validateCheckedCensusCounters();
  validateStableKeysArePerLiveSlot();
  validateRecordRejectsBrokenPlannedInvariant();
  validatePlanProvenanceAndCounterMutations();
  validateMovableTransformFixture();
  validateBindSuccessClassification();
  validateAtomicPublication();
  return 0;
  }
