#include "graphics/iossceneextractor.h"

#include <cassert>
#include <limits>
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
    IOSSceneOpaqueMeshKind kind = IOSSceneOpaqueMeshKind::Landscape) {
  IOSSceneOpaqueMeshCandidate source;
  source.sourceId       = 41;
  source.kind           = kind;
  source.hasStaticMesh  = true;
  source.hasMaterial    = true;
  source.isSolidMaterial = true;
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
  return result;
  }

IOSMaterial material(uint64_t value) {
  IOSMaterial result;
  result.id = {{7},value};
  result.baseColorTexture = {{7},value+1u};
  return result;
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
  static_assert(std::is_trivially_copyable_v<IOSSceneOpaqueMeshKind>);
  static_assert(std::is_trivially_copyable_v<IOSSceneOpaqueMeshCandidate>);
  static_assert(std::is_trivially_copyable_v<IOSSceneOpaqueMeshPlan>);

  using Extract = IOSSceneExtractionReport (IOSSceneExtractor::*)(
      const IOSSceneSourceProvider&,const Tempest::Device&,IOSRenderWorld&,
      IOSSceneAssetRegistry&,IOSSceneFrameState&) const;
  static_assert(std::is_same_v<
      decltype(&IOSSceneExtractor::extractOpaqueMeshes),
      Extract>);

  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Landscape)==
         IOSSceneOpaqueMeshKind::Landscape);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Static)==
         IOSSceneOpaqueMeshKind::Static);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Movable)==
         IOSSceneOpaqueMeshKind::Movable);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Animated)==
         IOSSceneOpaqueMeshKind::Unsupported);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Particle)==
         IOSSceneOpaqueMeshKind::Unsupported);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Morph)==
         IOSSceneOpaqueMeshKind::Unsupported);
  assert(iosSceneOpaqueMeshKind(IOSSceneSourceKind::Unsupported)==
         IOSSceneOpaqueMeshKind::Unsupported);
  assert(iosSceneOpaqueMeshKind(
           static_cast<IOSSceneSourceKind>(255u))==
         IOSSceneOpaqueMeshKind::Unsupported);
  }

void validateAcceptedKinds() {
  for(const auto kind:{
        IOSSceneOpaqueMeshKind::Landscape,
        IOSSceneOpaqueMeshKind::Static,
        IOSSceneOpaqueMeshKind::Movable}) {
    const auto accepted = candidate(kind);
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
    assert(plan.materialCategory==IOSMaterialCategory::Opaque);
    assert(plan.visibilityMask==IOSSceneVisibilityMain);
    assert(!plan.usesFallbackTexture);
    }
  }

void validateSkippedSources() {
  IOSSceneOpaqueMeshPlan plan;
  auto unsupported = candidate(IOSSceneOpaqueMeshKind::Unsupported);
  assert(planIOSOpaqueMeshSource(unsupported,plan)==
         IOSSceneSourcePlanResult::SkippedKind);

  auto fabricated = candidate(
      static_cast<IOSSceneOpaqueMeshKind>(255u));
  assert(planIOSOpaqueMeshSource(fabricated,plan)==
         IOSSceneSourcePlanResult::SkippedKind);

  for(const auto kind:{
        IOSSceneOpaqueMeshKind::Landscape,
        IOSSceneOpaqueMeshKind::Static,
        IOSSceneOpaqueMeshKind::Movable}) {
    auto alphaTest = candidate(kind);
    alphaTest.isSolidMaterial = false;
    assert(planIOSOpaqueMeshSource(alphaTest,plan)==
           IOSSceneSourcePlanResult::SkippedMaterial);

    auto animatedTexture = candidate(kind);
    animatedTexture.hasTextureAnimation = true;
    assert(planIOSOpaqueMeshSource(animatedTexture,plan)==
           IOSSceneSourcePlanResult::SkippedTextureAnimation);
    assert(plan.kind==IOSSceneOpaqueMeshKind::Unsupported);
    assert(plan.entityStableKey==0u);
    assert(plan.textureStableKey==0u);
    assert(plan.indices==IOSIndexRange{});
    }
  }

void validateMalformedAcceptedKinds() {
  for(const auto kind:{
        IOSSceneOpaqueMeshKind::Landscape,
        IOSSceneOpaqueMeshKind::Static,
        IOSSceneOpaqueMeshKind::Movable}) {
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
  auto landscape = candidate(IOSSceneOpaqueMeshKind::Landscape);
  auto staticMesh = candidate(IOSSceneOpaqueMeshKind::Static);
  staticMesh.hasBaseColorTexture = false;
  auto movable = candidate(IOSSceneOpaqueMeshKind::Movable);
  auto unsupported = candidate(IOSSceneOpaqueMeshKind::Unsupported);
  auto materialSkip = candidate(IOSSceneOpaqueMeshKind::Static);
  materialSkip.isSolidMaterial = false;
  auto animationSkip = candidate(IOSSceneOpaqueMeshKind::Landscape);
  animationSkip.hasTextureAnimation = true;
  auto malformed = candidate(IOSSceneOpaqueMeshKind::Static);
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
  for(const auto& source:sources) {
    ++stats.visited;
    IOSSceneOpaqueMeshPlan plan;
    const auto result = planIOSOpaqueMeshSource(source,plan);
    const bool accepted = recordIOSScenePlanResult(result,plan,stats);
    assert(accepted==(result!=IOSSceneSourcePlanResult::InvalidSource));
    }

  assert(stats.visited==7u);
  assert(stats.planned==3u);
  assert(stats.plannedLandscape==1u);
  assert(stats.plannedStatic==1u);
  assert(stats.plannedMovable==1u);
  assert(stats.skippedKind==1u);
  assert(stats.skippedMaterial==1u);
  assert(stats.skippedTextureAnimation==1u);
  assert(stats.fallbackTexture==1u);
  assert(stats.invalidSource==1u);
  assert(stats.hasConsistentPlannedCounts());
  }

void validateStableKeysArePerLiveSlot() {
  auto first = candidate(IOSSceneOpaqueMeshKind::Movable);
  first.sourceId = 501u;
  auto second = first;
  second.sourceId = 502u;

  IOSSceneOpaqueMeshPlan firstPlan;
  IOSSceneOpaqueMeshPlan secondPlan;
  assert(planIOSOpaqueMeshSource(first,firstPlan)==
         IOSSceneSourcePlanResult::Planned);
  assert(planIOSOpaqueMeshSource(second,secondPlan)==
         IOSSceneSourcePlanResult::Planned);
  assert(firstPlan.kind==IOSSceneOpaqueMeshKind::Movable);
  assert(secondPlan.kind==IOSSceneOpaqueMeshKind::Movable);
  assert(firstPlan.entityStableKey!=secondPlan.entityStableKey);
  assert(firstPlan.meshStableKey!=secondPlan.meshStableKey);
  assert(firstPlan.materialStableKey!=secondPlan.materialStableKey);
  assert(firstPlan.textureStableKey!=secondPlan.textureStableKey);
  }

void validateRecordRejectsBrokenPlannedInvariant() {
  IOSSceneOpaqueMeshPlan movablePlan;
  assert(planIOSOpaqueMeshSource(
           candidate(IOSSceneOpaqueMeshKind::Movable),movablePlan)==
         IOSSceneSourcePlanResult::Planned);

  for(const auto result:{
        IOSSceneSourcePlanResult::Planned,
        IOSSceneSourcePlanResult::SkippedKind,
        IOSSceneSourcePlanResult::SkippedMaterial,
        IOSSceneSourcePlanResult::SkippedTextureAnimation}) {
    IOSSceneExtractionStats stats;
    stats.planned = 1u;
    assert(!stats.hasConsistentPlannedCounts());
    assert(!recordIOSScenePlanResult(result,movablePlan,stats));
    assert(!stats.hasConsistentPlannedCounts());
    }
  }

void validateMovableTransformFixture() {
  auto frameA = candidate(IOSSceneOpaqueMeshKind::Movable);
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
  assert(planA.kind==IOSSceneOpaqueMeshKind::Movable);
  assert(planB.kind==IOSSceneOpaqueMeshKind::Movable);
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
  validateStableKeysArePerLiveSlot();
  validateRecordRejectsBrokenPlannedInvariant();
  validateMovableTransformFixture();
  validateBindSuccessClassification();
  validateAtomicPublication();
  return 0;
  }
