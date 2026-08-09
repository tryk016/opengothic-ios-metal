#include "graphics/iossceneextractor.h"

#include <array>
#include <bit>
#include <cassert>
#include <cstdlib>
#include <limits>
#include <new>
#include <optional>
#include <type_traits>
#include <vector>

namespace AllocationProbe {
bool forbidden = false;
}

void* operator new(std::size_t size) {
  if(AllocationProbe::forbidden)
    throw std::bad_alloc();
  if(void* memory=std::malloc(size==0u ? 1u : size))
    return memory;
  throw std::bad_alloc();
  }

void* operator new[](std::size_t size) {
  return ::operator new(size);
  }

void operator delete(void* memory) noexcept {
  std::free(memory);
  }

void operator delete[](void* memory) noexcept {
  ::operator delete(memory);
  }

void operator delete(void* memory, std::size_t) noexcept {
  ::operator delete(memory);
  }

void operator delete[](void* memory, std::size_t) noexcept {
  ::operator delete[](memory);
  }

namespace {

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
void validateAdditiveCensusReportSidecar() {
  IOSSceneExtractionReport report;
  assert(report.additiveSourceCensus==IOSAdditiveSourceCensus{});
  assert(iosRecordAdditiveSourceCensus(
      IOSSceneSourceKind::Movable,Material::AdditiveLight,
      IOSSceneTextureAnimationMode::FrameAndUv,
      report.additiveSourceCensus)==IOSAdditiveCensusResult::Recorded);
  assert(report.additiveSourceCensus.cells[11]==1u);
  assert(iosFinalizeAdditiveSourceCensus(
      report.additiveSourceCensus,1u));
  const auto candidate = prepareIOSAdditiveSourceCensusDiagnosticCandidate(
      report.additiveSourceCensus,1u,3u,300u);
  assert(candidate.valid);
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      candidate,true,false,9u,9u,3u,300u));
  assert(iosAdditiveSourceCensusCandidateAcceptsCommit(
      candidate,true,true,9u,9u,3u,300u));
  }
#endif

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
  return lhs.sceneTimeMs==rhs.sceneTimeMs &&
         lhs.camera==rhs.camera &&
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
  static_assert(
      std::is_trivially_copyable_v<IOSSceneFrameSelectionResult>);
  static_assert(std::is_trivially_copyable_v<IOSSceneUVOffsetResult>);
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
  assert((iosSceneMaterialMapping(Material::AdditiveLight)==
          IOSSceneMaterialMapping{IOSMaterialCategory::Additive,true}));
  for(const auto alpha:{
        Material::Water,
        Material::Ghost,
        Material::Multiply,
        Material::Multiply2,
        Material::Transparent,
        static_cast<Material::AlphaFunc>(255u)}) {
    assert(iosSceneMaterialMapping(alpha)==IOSSceneMaterialMapping{});
    }
  }

void validateStaticAdditiveNoneAdmission() {
  auto additive = candidate(
      IOSSceneMeshKind::Static,IOSMaterialCategory::Additive);
  additive.alphaWeight = 0.375f;
  IOSSceneOpaqueMeshPlan plan;
  assert(planIOSOpaqueMeshSource(additive,plan)==
         IOSSceneSourcePlanResult::Planned);
  assert(plan.kind==IOSSceneMeshKind::Static);
  assert(plan.materialCategory==IOSMaterialCategory::Additive);
  assert(plan.textureAnimation==IOSSceneTextureAnimationMode::None);
  assert(plan.baseColorAlpha==0.375f);
  assert(plan.materialFlags==IOSMaterialFlagStaticAdditiveNone);
  assert(!plan.usesFallbackTexture);
  assert(plan.uvOffset==IOSFloat2{});

  for(const float alpha:{0.f,1.f}) {
    additive.alphaWeight = alpha;
    assert(planIOSOpaqueMeshSource(additive,plan)==
           IOSSceneSourcePlanResult::Planned);
    assert(plan.baseColorAlpha==alpha);
    }

  // DEFAULT.TGA provenance is intentionally absent: every resolved,
  // non-fallback texture follows the same positive path.
  additive.alphaWeight = 1.f;
  additive.hasBaseColorTexture = true;
  additive.usesFallbackTexture = false;
  assert(planIOSOpaqueMeshSource(additive,plan)==
         IOSSceneSourcePlanResult::Planned);

  for(const auto kind:{
        IOSSceneMeshKind::Landscape,
        IOSSceneMeshKind::Movable}) {
    auto wrongKind = additive;
    wrongKind.kind = kind;
    assert(planIOSOpaqueMeshSource(wrongKind,plan)==
           IOSSceneSourcePlanResult::SkippedMaterial);
    }
  auto unsupportedKind = additive;
  unsupportedKind.kind = IOSSceneMeshKind::Unsupported;
  assert(planIOSOpaqueMeshSource(unsupportedKind,plan)==
         IOSSceneSourcePlanResult::SkippedKind);
  auto unknownKind = additive;
  unknownKind.kind = static_cast<IOSSceneMeshKind>(255u);
  assert(planIOSOpaqueMeshSource(unknownKind,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  alignas(void*) std::array<std::byte,2u> textureIdentities{};
  const auto* localFallback =
      reinterpret_cast<const Tempest::Texture2d*>(
          textureIdentities.data());
  const auto* regularTexture =
      reinterpret_cast<const Tempest::Texture2d*>(
          textureIdentities.data()+1u);
  Material material;
  material.alpha = Material::AdditiveLight;
  material.tex = localFallback;
  assert(iosSceneMaterialUsesFallbackTexture(
      &material,iosSceneMaterialMapping(material.alpha),false,
      localFallback));
  material.tex = regularTexture;
  assert(!iosSceneMaterialUsesFallbackTexture(
      &material,iosSceneMaterialMapping(material.alpha),false,
      localFallback));
  material.alpha = Material::Solid;
  material.tex = nullptr;
  assert(iosSceneMaterialUsesFallbackTexture(
      &material,iosSceneMaterialMapping(material.alpha),false,
      localFallback));
  assert(!iosSceneMaterialUsesFallbackTexture(
      &material,iosSceneMaterialMapping(material.alpha),true,
      localFallback));

  for(const auto mode:{
        IOSSceneTextureAnimationMode::FrameOnly,
        IOSSceneTextureAnimationMode::UvOnly,
        IOSSceneTextureAnimationMode::FrameAndUv}) {
    auto animated = additive;
    animated.hasFrameAnimation =
        mode==IOSSceneTextureAnimationMode::FrameOnly ||
        mode==IOSSceneTextureAnimationMode::FrameAndUv;
    animated.hasUvAnimation =
        mode==IOSSceneTextureAnimationMode::UvOnly ||
        mode==IOSSceneTextureAnimationMode::FrameAndUv;
    animated.hasValidFrameSequence = animated.hasFrameAnimation;
    animated.frameCount = animated.hasFrameAnimation ? 2u : 0u;
    animated.framePeriodMs = 10u;
    animated.uvPeriodX = animated.hasUvAnimation ? 4 : 0;
    animated.hasBaseColorTexture = false;
    animated.usesFallbackTexture = true;
    animated.alphaWeight = std::numeric_limits<float>::quiet_NaN();
    assert(planIOSOpaqueMeshSource(animated,plan)==
           IOSSceneSourcePlanResult::SkippedTextureAnimation);
    assert(plan==IOSSceneOpaqueMeshPlan{});
    IOSSceneExtractionStats skipped;
    assert(recordIOSSceneRawSource(
        IOSSceneSourceKind::Static,Material::AdditiveLight,
        animated.hasFrameAnimation,animated.hasUvAnimation,skipped));
    assert(recordIOSScenePlanResult(
        IOSSceneSourcePlanResult::SkippedTextureAnimation,plan,skipped,
        mode));
    assert(skipped.skippedTextureAnimation==1u);
    assert(skipped.plannedAdditive==0u);
    assert(skipped.hasConsistentSuccessfulCensus());
    }

  for(const float alpha:{
        -0.001f,
        1.001f,
        std::numeric_limits<float>::infinity(),
        -std::numeric_limits<float>::infinity(),
        std::numeric_limits<float>::quiet_NaN()}) {
    auto invalidAlpha = additive;
    invalidAlpha.alphaWeight = alpha;
    assert(planIOSOpaqueMeshSource(invalidAlpha,plan)==
           IOSSceneSourcePlanResult::InvalidSource);
    assert(plan==IOSSceneOpaqueMeshPlan{});
    }

  auto nullTexture = additive;
  nullTexture.hasBaseColorTexture = false;
  assert(planIOSOpaqueMeshSource(nullTexture,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  auto fallbackTexture = additive;
  fallbackTexture.usesFallbackTexture = true;
  assert(planIOSOpaqueMeshSource(fallbackTexture,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  auto staleFrameStructure = additive;
  staleFrameStructure.hasValidFrameSequence = true;
  assert(planIOSOpaqueMeshSource(staleFrameStructure,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  staleFrameStructure = additive;
  staleFrameStructure.frameCount = 1u;
  assert(planIOSOpaqueMeshSource(staleFrameStructure,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  auto staleUvStructure = additive;
  staleUvStructure.uvPeriodY = 1;
  assert(planIOSOpaqueMeshSource(staleUvStructure,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  auto missingMaterial = additive;
  missingMaterial.hasMaterial = false;
  assert(planIOSOpaqueMeshSource(missingMaterial,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  auto unknownMaterial = additive;
  unknownMaterial.materialCategory =
      static_cast<IOSMaterialCategory>(255u);
  assert(planIOSOpaqueMeshSource(unknownMaterial,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  unknownMaterial.hasMappedMaterialCategory = false;
  assert(planIOSOpaqueMeshSource(unknownMaterial,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  IOSSceneExtractionStats stats;
  assert(recordIOSSceneRawSource(
      IOSSceneSourceKind::Static,Material::AdditiveLight,false,false,stats));
  assert(planIOSOpaqueMeshSource(additive,plan)==
         IOSSceneSourcePlanResult::Planned);
  assert(recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::Planned,plan,stats));
  assert(stats.planned==1u);
  assert(stats.plannedAdditive==1u);
  assert(stats.plannedStatic==1u);
  assert(stats.hasConsistentSuccessfulCensus());

  for(const auto mutation:{0u,1u,2u,3u,4u}) {
    auto forged = plan;
    switch(mutation) {
      case 0u:
        forged.materialFlags = IOSMaterialFlagNone;
        break;
      case 1u:
        forged.materialFlags |= uint64_t(1) << 63u;
        break;
      case 2u:
        forged.kind = IOSSceneMeshKind::Movable;
        break;
      case 3u:
        forged.textureAnimation = IOSSceneTextureAnimationMode::UvOnly;
        break;
      case 4u:
        forged.baseColorAlpha =
            std::numeric_limits<float>::quiet_NaN();
        break;
      }
    IOSSceneExtractionStats rejected;
    assert(!recordIOSScenePlanResult(
        IOSSceneSourcePlanResult::Planned,forged,rejected,
        forged.textureAnimation));
    assert(rejected.planned==0u);
    assert(rejected.plannedAdditive==0u);
    assert(rejected.invalidSource==1u);
    }

  auto forgedOpaque = acceptedPlan(
      IOSSceneSourceKind::Static,Material::Solid);
  forgedOpaque.materialFlags = IOSMaterialFlagStaticAdditiveNone;
  IOSSceneExtractionStats rejectedOpaque;
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::Planned,forgedOpaque,rejectedOpaque));
  assert(rejectedOpaque.planned==0u);
  assert(rejectedOpaque.invalidSource==1u);
  }

void validateUVOffsetEvaluation() {
  using Result = IOSSceneUVOffsetResult;
  IOSFloat2 offset = {9.f,10.f};
  assert(evaluateIOSSceneUVOffset(7u,4,-5,offset)==Result::Evaluated);
  assert((offset==IOSFloat2{0.75f,-0.4f}));

  const uint64_t wrapped = (uint64_t(1u)<<32u)+2u;
  assert(evaluateIOSSceneUVOffset(wrapped,3,0,offset)==Result::Evaluated);
  assert((offset==IOSFloat2{2.f/3.f,0.f}));
  assert(std::bit_cast<uint32_t>(offset.y)==0u);

  assert(evaluateIOSSceneUVOffset(
      std::numeric_limits<uint64_t>::max(),-1,1,offset)==Result::Evaluated);
  assert(offset==IOSFloat2{});
  assert(std::bit_cast<uint32_t>(offset.x)==0u);
  assert(std::bit_cast<uint32_t>(offset.y)==0u);

  offset = {9.f,10.f};
  assert(evaluateIOSSceneUVOffset(1u,0,0,offset)==Result::InvalidPeriods);
  assert(offset==IOSFloat2{});
  offset = {9.f,10.f};
  assert(evaluateIOSSceneUVOffset(
      1u,std::numeric_limits<int32_t>::min(),1,offset)==
      Result::InvalidPeriods);
  assert(offset==IOSFloat2{});
  offset = {9.f,10.f};
  assert(evaluateIOSSceneUVOffset(
      1u,1,std::numeric_limits<int32_t>::min(),offset)==
      Result::InvalidPeriods);
  assert(offset==IOSFloat2{});
  }

void validateFrameSelection() {
  using Result = IOSSceneFrameSelectionResult;

  uint64_t ordinal = 0xA5A5A5A5A5A5A5A5u;
  assert(selectIOSSceneTextureFrame(100u,10u,0u,ordinal)==
         Result::InvalidFrameCount);
  assert(ordinal==0xA5A5A5A5A5A5A5A5u);

  assert(selectIOSSceneTextureFrame(100u,0u,4u,ordinal)==
         Result::InvalidFramePeriod);
  assert(ordinal==0xA5A5A5A5A5A5A5A5u);

  assert(selectIOSSceneTextureFrame(100u,0u,0u,ordinal)==
         Result::InvalidFrameCount);
  assert(ordinal==0xA5A5A5A5A5A5A5A5u);

  assert(selectIOSSceneTextureFrame(0u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==0u);
  assert(selectIOSSceneTextureFrame(9u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==0u);
  assert(selectIOSSceneTextureFrame(10u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==1u);
  assert(selectIOSSceneTextureFrame(29u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==2u);
  assert(selectIOSSceneTextureFrame(30u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==0u);
  assert(selectIOSSceneTextureFrame(31u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==0u);

  const uint64_t maximum = std::numeric_limits<uint64_t>::max();
  assert(selectIOSSceneTextureFrame(maximum,maximum,7u,ordinal)==
         Result::Selected);
  assert(ordinal==1u);
  assert(selectIOSSceneTextureFrame(maximum,2u,maximum,ordinal)==
         Result::Selected);
  assert(ordinal==maximum/2u);
  assert(selectIOSSceneTextureFrame(maximum,1u,maximum,ordinal)==
         Result::Selected);
  assert(ordinal==0u);
  }

void validateFrameAnimationEvidence() {
  auto digest = [](std::initializer_list<uint64_t> words) {
    uint64_t value = IOSFrameAnimationFNV1aOffset;
    for(const uint64_t word:words)
      value = iosFrameAnimationFNV1aAppendWord(value,word);
    return value;
    };
  assert(digest({})==0xcbf29ce484222325ull);
  assert(digest({0u})==0xa8c7f832281a39c5ull);
  assert(digest({1u})==0x89cd31291d2aefa4ull);
  assert(digest({1u,2u})==0x7717980363c8e066ull);
  assert(digest({std::numeric_limits<uint64_t>::max()})==
         0x8cf51a8bfca3883dull);
  assert(digest({2u,1u})==0x072184407c3a4ac6ull);

  IOSFrameAnimationEvidence evidence;
  evidence.selections = {
    {9u,2u,{{7u},31u}},
    {3u,0u,{{7u},29u}},
    };
  assert(finalizeIOSFrameAnimationEvidence(evidence));
  assert(evidence.selections[0].sourceId==3u);
  assert(evidence.selections[1].sourceId==9u);
  assert(evidence.admittedFrameOnly==2u);
  assert(evidence.nonzeroFrameOrdinals==1u);
  assert(evidence.sourceDigest==digest({3u,9u}));
  assert(evidence.pairDigest==digest({3u,0u,9u,2u}));
  assert(isCanonicalIOSFrameAnimationEvidence(evidence));

  auto reordered = evidence;
  std::swap(reordered.selections[0],reordered.selections[1]);
  assert(!isCanonicalIOSFrameAnimationEvidence(reordered));
  auto duplicate = evidence;
  duplicate.selections[1].sourceId = duplicate.selections[0].sourceId;
  assert(!finalizeIOSFrameAnimationEvidence(duplicate));
  auto duplicateHandle = evidence;
  duplicateHandle.selections[1].selectedHandle =
      duplicateHandle.selections[0].selectedHandle;
  assert(!finalizeIOSFrameAnimationEvidence(duplicateHandle));
  assert(!isCanonicalIOSFrameAnimationEvidence(duplicateHandle));
  auto mixedGeneration = evidence;
  mixedGeneration.selections[1].selectedHandle.generation = {8u};
  assert(!finalizeIOSFrameAnimationEvidence(mixedGeneration));
  assert(!isCanonicalIOSFrameAnimationEvidence(mixedGeneration));
  auto zeroSource = evidence;
  zeroSource.selections[0].sourceId = 0u;
  assert(!finalizeIOSFrameAnimationEvidence(zeroSource));
  auto emptyHandle = evidence;
  emptyHandle.selections[0].selectedHandle = {};
  assert(!finalizeIOSFrameAnimationEvidence(emptyHandle));
  }

void validateUVAnimationEvidence() {
  IOSUVAnimationEvidence evidence;
  evidence.selections = {
    {9u,IOSSceneTextureAnimationMode::FrameAndUv,2u,{{7u},31u},
     {0.75f,-0.4f}},
    {3u,IOSSceneTextureAnimationMode::UvOnly,0u,{{7u},29u},
     {0.f,0.5f}},
    };
  assert(finalizeIOSUVAnimationEvidence(evidence));
  assert(evidence.selections[0].sourceId==3u);
  assert(evidence.selections[1].sourceId==9u);
  assert(evidence.admittedUvOnly==1u);
  assert(evidence.admittedFrameAndUv==1u);
  assert(evidence.plannedCount==2u);

  uint64_t sourceDigest = IOSUVAnimationFNV1aOffset;
  sourceDigest = iosUVAnimationFNV1aAppendUint64(sourceDigest,3u);
  sourceDigest = iosUVAnimationFNV1aAppendUint64(sourceDigest,9u);
  assert(evidence.sourceDigest==sourceDigest);

  uint64_t uvDigest = IOSUVAnimationFNV1aOffset;
  uvDigest = iosUVAnimationFNV1aAppendUint64(uvDigest,3u);
  uvDigest = iosUVAnimationFNV1aAppendUint32(
      uvDigest,std::bit_cast<uint32_t>(0.f));
  uvDigest = iosUVAnimationFNV1aAppendUint32(
      uvDigest,std::bit_cast<uint32_t>(0.5f));
  uvDigest = iosUVAnimationFNV1aAppendUint64(uvDigest,9u);
  uvDigest = iosUVAnimationFNV1aAppendUint32(
      uvDigest,std::bit_cast<uint32_t>(0.75f));
  uvDigest = iosUVAnimationFNV1aAppendUint32(
      uvDigest,std::bit_cast<uint32_t>(-0.4f));
  assert(evidence.plannedUVDigest==uvDigest);
  assert(isCanonicalIOSUVAnimationEvidence(evidence));
  static_assert(noexcept(isCanonicalIOSUVAnimationEvidence(evidence)));
  const auto* const selectionStorage = evidence.selections.data();
  const std::size_t selectionCapacity = evidence.selections.capacity();
  AllocationProbe::forbidden = true;
  const bool canonicalWithoutAllocation =
      isCanonicalIOSUVAnimationEvidence(evidence);
  AllocationProbe::forbidden = false;
  assert(canonicalWithoutAllocation);
  assert(evidence.selections.data()==selectionStorage);
  assert(evidence.selections.capacity()==selectionCapacity);

  auto reordered = evidence;
  std::swap(reordered.selections[0],reordered.selections[1]);
  assert(!isCanonicalIOSUVAnimationEvidence(reordered));
  auto duplicateSource = evidence;
  duplicateSource.selections[1].sourceId =
      duplicateSource.selections[0].sourceId;
  assert(!finalizeIOSUVAnimationEvidence(duplicateSource));
  auto duplicateHandle = evidence;
  duplicateHandle.selections[1].selectedHandle =
      duplicateHandle.selections[0].selectedHandle;
  assert(!finalizeIOSUVAnimationEvidence(duplicateHandle));
  auto wrongMode = evidence;
  wrongMode.selections[0].mode = IOSSceneTextureAnimationMode::FrameOnly;
  assert(!finalizeIOSUVAnimationEvidence(wrongMode));
  auto uvOnlyOrdinal = evidence;
  uvOnlyOrdinal.selections[0].frameOrdinal = 1u;
  assert(!finalizeIOSUVAnimationEvidence(uvOnlyOrdinal));
  auto negativeZero = evidence;
  negativeZero.selections[0].uvOffset.x = -0.f;
  assert(!finalizeIOSUVAnimationEvidence(negativeZero));
  auto nonFinite = evidence;
  nonFinite.selections[0].uvOffset.y =
      std::numeric_limits<float>::infinity();
  assert(!finalizeIOSUVAnimationEvidence(nonFinite));
  }

void validateUVAdmission() {
  for(const auto category:{
        IOSMaterialCategory::Opaque,
        IOSMaterialCategory::AlphaTest}) {
    for(const auto kind:{
          IOSSceneMeshKind::Landscape,
          IOSSceneMeshKind::Static,
          IOSSceneMeshKind::Movable}) {
      auto uvOnly = candidate(kind,category);
      uvOnly.hasUvAnimation = true;
      uvOnly.uvPeriodX = 4;
      uvOnly.uvPeriodY = -5;
      uvOnly.sceneTimeMs = 7u;
      IOSSceneOpaqueMeshPlan uvPlan;
      assert(planIOSOpaqueMeshSource(uvOnly,uvPlan)==
             IOSSceneSourcePlanResult::Planned);
      assert(uvPlan.textureAnimation==IOSSceneTextureAnimationMode::UvOnly);
      assert(uvPlan.frameOrdinal==0u);
      assert(uvPlan.uvPeriodX==4);
      assert(uvPlan.uvPeriodY==-5);
      assert((uvPlan.uvOffset==IOSFloat2{0.75f,-0.4f}));
      assert(!uvPlan.usesFallbackTexture);

      auto combined = candidate(kind,category);
      combined.hasBaseColorTexture = false;
      combined.hasFrameAnimation = true;
      combined.hasUvAnimation = true;
      combined.hasValidFrameSequence = true;
      combined.frameCount = 3u;
      combined.framePeriodMs = 10u;
      combined.uvPeriodX = -4;
      combined.uvPeriodY = 5;
      combined.sceneTimeMs = 29u;
      IOSSceneOpaqueMeshPlan combinedPlan;
      assert(planIOSOpaqueMeshSource(combined,combinedPlan)==
             IOSSceneSourcePlanResult::Planned);
      assert(combinedPlan.textureAnimation==
             IOSSceneTextureAnimationMode::FrameAndUv);
      assert(combinedPlan.frameOrdinal==2u);
      assert((combinedPlan.uvOffset==IOSFloat2{-0.25f,0.8f}));
      assert(!combinedPlan.usesFallbackTexture);

      IOSSceneExtractionStats stats;
      stats.visited = 2u;
      if(kind==IOSSceneMeshKind::Landscape)
        stats.census.kinds.landscape = 2u;
      else if(kind==IOSSceneMeshKind::Static)
        stats.census.kinds.staticMesh = 2u;
      else
        stats.census.kinds.movable = 2u;
      if(category==IOSMaterialCategory::Opaque)
        stats.census.materials.solid = 2u;
      else
        stats.census.materials.alphaTest = 2u;
      stats.census.frameAnimated = 1u;
      stats.census.uvAnimated = 2u;
      assert(recordIOSScenePlanResult(
          IOSSceneSourcePlanResult::Planned,uvPlan,stats,
          IOSSceneTextureAnimationMode::UvOnly));
      assert(recordIOSScenePlanResult(
          IOSSceneSourcePlanResult::Planned,combinedPlan,stats,
          IOSSceneTextureAnimationMode::FrameAndUv));
      assert(stats.admittedFrameOnly==0u);
      assert(stats.admittedUvOnly==1u);
      assert(stats.admittedFrameAndUv==1u);
      assert(stats.hasConsistentSuccessfulCensus());
      }
    }

  IOSSceneOpaqueMeshPlan plan;
  auto missingBase = candidate();
  missingBase.hasBaseColorTexture = false;
  missingBase.hasUvAnimation = true;
  missingBase.uvPeriodX = 2;
  assert(planIOSOpaqueMeshSource(missingBase,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  assert(plan.kind==IOSSceneMeshKind::Unsupported);
  assert(plan.entityStableKey==0u);
  assert(plan.textureAnimation==IOSSceneTextureAnimationMode::None);
  assert(plan.uvOffset==IOSFloat2{});

  auto fallback = candidate();
  fallback.hasUvAnimation = true;
  fallback.uvPeriodX = 2;
  fallback.usesFallbackTexture = true;
  assert(planIOSOpaqueMeshSource(fallback,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto invalidSequence = candidate();
  invalidSequence.hasFrameAnimation = true;
  invalidSequence.hasUvAnimation = true;
  invalidSequence.frameCount = 2u;
  invalidSequence.framePeriodMs = 10u;
  invalidSequence.uvPeriodY = 3;
  assert(planIOSOpaqueMeshSource(invalidSequence,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  invalidSequence.hasValidFrameSequence = true;
  invalidSequence.framePeriodMs = 0u;
  assert(planIOSOpaqueMeshSource(invalidSequence,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  invalidSequence.framePeriodMs = 10u;
  invalidSequence.uvPeriodY = std::numeric_limits<int32_t>::min();
  assert(planIOSOpaqueMeshSource(invalidSequence,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto mismatchedFlag = candidate();
  mismatchedFlag.hasUvAnimation = true;
  assert(planIOSOpaqueMeshSource(mismatchedFlag,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  }

void validateFrameOnlyAdmission() {
  for(const auto category:{
        IOSMaterialCategory::Opaque,
        IOSMaterialCategory::AlphaTest}) {
    auto source = candidate(IOSSceneMeshKind::Static,category);
    source.hasFrameAnimation = true;
    source.sceneTimeMs = 29u;
    source.framePeriodMs = 10u;
    source.frameCount = 3u;
    IOSSceneOpaqueMeshPlan plan;
    assert(planIOSOpaqueMeshSource(source,plan)==
           IOSSceneSourcePlanResult::Planned);
    assert(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly);
    assert(plan.frameOrdinal==2u);
    assert(plan.textureStableKey==source.sourceId);

    IOSSceneExtractionStats stats;
    stats.visited = 1u;
    stats.census.kinds.staticMesh = 1u;
    if(category==IOSMaterialCategory::Opaque)
      stats.census.materials.solid = 1u;
    else
      stats.census.materials.alphaTest = 1u;
    stats.census.frameAnimated = 1u;
    assert(recordIOSScenePlanResult(
        IOSSceneSourcePlanResult::Planned,plan,stats,
        IOSSceneTextureAnimationMode::FrameOnly));
    assert(stats.planned==1u);
    assert(stats.admittedFrameOnly==1u);
    assert(stats.nonzeroFrameOrdinals==1u);
    assert(stats.hasConsistentSuccessfulCensus());
    }

  auto selectedWithoutStaticBase = candidate();
  selectedWithoutStaticBase.hasBaseColorTexture = false;
  selectedWithoutStaticBase.hasFrameAnimation = true;
  selectedWithoutStaticBase.frameCount = 2u;
  selectedWithoutStaticBase.framePeriodMs = 10u;
  IOSSceneOpaqueMeshPlan selectedPlan;
  assert(planIOSOpaqueMeshSource(selectedWithoutStaticBase,selectedPlan)==
         IOSSceneSourcePlanResult::Planned);
  assert(!selectedPlan.usesFallbackTexture);

  auto zeroPeriod = candidate();
  zeroPeriod.hasFrameAnimation = true;
  zeroPeriod.frameCount = 2u;
  IOSSceneOpaqueMeshPlan plan;
  assert(planIOSOpaqueMeshSource(zeroPeriod,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  assert(plan.kind==IOSSceneMeshKind::Unsupported);
  assert(plan.textureStableKey==0u);
  assert(plan.textureAnimation==IOSSceneTextureAnimationMode::None);

  auto zeroCount = zeroPeriod;
  zeroCount.framePeriodMs = 10u;
  zeroCount.frameCount = 0u;
  assert(planIOSOpaqueMeshSource(zeroCount,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  assert(plan.kind==IOSSceneMeshKind::Unsupported);
  assert(plan.textureStableKey==0u);
  assert(plan.textureAnimation==IOSSceneTextureAnimationMode::None);
  }

void validateFrameTextureAdapter() {
  Material material;
  const auto* frame0 = reinterpret_cast<const Tempest::Texture2d*>(
      std::uintptr_t(0x1000u));
  const auto* frame1 = reinterpret_cast<const Tempest::Texture2d*>(
      std::uintptr_t(0x2000u));
  material.frames = {frame0,frame1};
  assert(hasValidIOSSceneFrameSequence(&material));

  IOSSceneOpaqueMeshPlan plan;
  plan.textureAnimation = IOSSceneTextureAnimationMode::FrameOnly;
  plan.frameOrdinal = 1u;
  const Tempest::Texture2d* selected = frame0;
  assert(selectIOSSceneFrameTextureForExtraction(
      &material,plan,selected)==IOSSceneExtractionResult::Success);
  assert(selected==frame1);
  plan.textureAnimation = IOSSceneTextureAnimationMode::FrameAndUv;
  assert(selectIOSSceneFrameTextureForExtraction(
      &material,plan,selected)==IOSSceneExtractionResult::Success);
  assert(selected==frame1);

  const auto* sentinel = reinterpret_cast<const Tempest::Texture2d*>(
      std::uintptr_t(0x3000u));
  selected = sentinel;
  plan.frameOrdinal = 2u;
  assert(selectIOSSceneFrameTextureForExtraction(
      &material,plan,selected)==IOSSceneExtractionResult::InvalidSource);
  assert(selected==sentinel);
  plan.frameOrdinal = 1u;
  material.frames[1] = nullptr;
  assert(!hasValidIOSSceneFrameSequence(&material));
  assert(selectIOSSceneFrameTextureForExtraction(
      &material,plan,selected)==IOSSceneExtractionResult::InvalidSource);
  assert(selected==sentinel);
  assert(selectIOSSceneFrameTextureForExtraction(
      nullptr,plan,selected)==IOSSceneExtractionResult::InvalidSource);
  assert(selected==sentinel);
  material.frames.clear();
  assert(!hasValidIOSSceneFrameSequence(&material));
  assert(!hasValidIOSSceneFrameSequence(nullptr));
  plan.textureAnimation = IOSSceneTextureAnimationMode::None;
  assert(selectIOSSceneFrameTextureForExtraction(
      &material,plan,selected)==IOSSceneExtractionResult::InvalidSource);
  assert(selected==sentinel);
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
         IOSSceneSourcePlanResult::InvalidSource);

  for(const auto category:{
        IOSMaterialCategory::Transparent,
        IOSMaterialCategory::Water}) {
    auto unsupportedMaterial =
        candidate(IOSSceneMeshKind::Landscape,category);
    assert(planIOSOpaqueMeshSource(unsupportedMaterial,plan)==
           IOSSceneSourcePlanResult::SkippedMaterial);
    }
  auto fabricatedMaterial = candidate(
      IOSSceneMeshKind::Landscape,
      static_cast<IOSMaterialCategory>(255u));
  assert(planIOSOpaqueMeshSource(fabricatedMaterial,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  for(const auto kind:{
        IOSSceneMeshKind::Landscape,
        IOSSceneMeshKind::Static,
        IOSSceneMeshKind::Movable}) {
    auto alphaTest = candidate(kind,IOSMaterialCategory::AlphaTest);
    assert(planIOSOpaqueMeshSource(alphaTest,plan)==
           IOSSceneSourcePlanResult::Planned);
    auto alphaFrameAnimated = alphaTest;
    alphaFrameAnimated.hasFrameAnimation = true;
    alphaFrameAnimated.frameCount = 3u;
    alphaFrameAnimated.framePeriodMs = 10u;
    assert(planIOSOpaqueMeshSource(alphaFrameAnimated,plan)==
           IOSSceneSourcePlanResult::Planned);
    assert(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameOnly);
    auto alphaUvAnimated = alphaTest;
    alphaUvAnimated.hasBaseColorTexture = false;
    alphaUvAnimated.hasUvAnimation = true;
    alphaUvAnimated.uvPeriodX = 10;
    assert(planIOSOpaqueMeshSource(alphaUvAnimated,plan)==
           IOSSceneSourcePlanResult::InvalidSource);

    auto frameAnimated = candidate(kind);
    frameAnimated.hasFrameAnimation = true;
    frameAnimated.frameCount = 3u;
    frameAnimated.framePeriodMs = 10u;
    assert(planIOSOpaqueMeshSource(frameAnimated,plan)==
           IOSSceneSourcePlanResult::Planned);
    auto uvAnimated = candidate(kind);
    uvAnimated.hasUvAnimation = true;
    uvAnimated.uvPeriodY = -10;
    assert(planIOSOpaqueMeshSource(uvAnimated,plan)==
           IOSSceneSourcePlanResult::Planned);
    assert(plan.textureAnimation==IOSSceneTextureAnimationMode::UvOnly);
    auto frameAndUvAnimated = candidate(kind);
    frameAndUvAnimated.hasBaseColorTexture = false;
    frameAndUvAnimated.hasFrameAnimation = true;
    frameAndUvAnimated.hasUvAnimation = true;
    frameAndUvAnimated.hasValidFrameSequence = true;
    frameAndUvAnimated.frameCount = 3u;
    frameAndUvAnimated.framePeriodMs = 10u;
    frameAndUvAnimated.uvPeriodX = 10;
    assert(planIOSOpaqueMeshSource(frameAndUvAnimated,plan)==
           IOSSceneSourcePlanResult::Planned);
    assert(plan.textureAnimation==IOSSceneTextureAnimationMode::FrameAndUv);
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
  animationSkip.hasUvAnimation = true;
  animationSkip.hasValidFrameSequence = true;
  animationSkip.frameCount = 2u;
  animationSkip.framePeriodMs = 10u;
  animationSkip.uvPeriodX = 4;
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
  stats.census.uvAnimated = 1u;
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
  assert(stats.planned==4u);
  assert(stats.plannedOpaque==3u);
  assert(stats.plannedAlphaTest==1u);
  assert(stats.plannedLandscape==2u);
  assert(stats.plannedStatic==1u);
  assert(stats.plannedMovable==1u);
  assert(stats.skippedKind==1u);
  assert(stats.skippedMaterial==1u);
  assert(stats.skippedTextureAnimation==0u);
  assert(stats.skippedTextureFrameOnly==0u);
  assert(stats.skippedTextureUvOnly==0u);
  assert(stats.skippedTextureFrameAndUv==0u);
  assert(stats.admittedFrameAndUv==1u);
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
  for(const auto alpha:{
        Material::Solid,
        Material::AlphaTest,
        Material::AdditiveLight}) {
    recordRawOutcome(
        IOSSceneSourceKind::Static,alpha,false,false,
        IOSSceneSourcePlanResult::Planned,stats);
    }
  for(const auto alpha:{
        Material::Water,
        Material::Ghost,
        Material::Multiply,
        Material::Multiply2,
        Material::Transparent}) {
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
  assert(stats.planned==3u);
  assert(stats.plannedAdditive==1u);
  assert(stats.skippedMaterial==5u);
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
  auto frameOnly = candidate(IOSSceneMeshKind::Static);
  frameOnly.hasFrameAnimation = true;
  frameOnly.frameCount = 2u;
  frameOnly.framePeriodMs = 10u;
  auto uvOnly = candidate(
      IOSSceneMeshKind::Movable,IOSMaterialCategory::AlphaTest);
  uvOnly.hasUvAnimation = true;
  uvOnly.uvPeriodX = 4;
  auto combined = candidate(
      IOSSceneMeshKind::Landscape,IOSMaterialCategory::AlphaTest);
  combined.hasFrameAnimation = true;
  combined.hasUvAnimation = true;
  combined.hasValidFrameSequence = true;
  combined.frameCount = 2u;
  combined.framePeriodMs = 10u;
  combined.uvPeriodY = -4;
  for(const auto& source:{frameOnly,uvOnly,combined}) {
    assert(recordIOSSceneRawSource(
        source.kind==IOSSceneMeshKind::Static
            ? IOSSceneSourceKind::Static
            : source.kind==IOSSceneMeshKind::Movable
            ? IOSSceneSourceKind::Movable
            : IOSSceneSourceKind::Landscape,
        source.materialCategory==IOSMaterialCategory::Opaque
            ? Material::Solid
            : Material::AlphaTest,
        source.hasFrameAnimation,source.hasUvAnimation,stats));
    IOSSceneOpaqueMeshPlan plan;
    assert(planIOSOpaqueMeshSource(source,plan)==
           IOSSceneSourcePlanResult::Planned);
    assert(recordIOSScenePlanResult(
        IOSSceneSourcePlanResult::Planned,plan,stats,
        iosSceneTextureAnimationMode(
            source.hasFrameAnimation,source.hasUvAnimation)));
    }
  recordRawOutcome(
      IOSSceneSourceKind::Animated,Material::Solid,true,false,
      IOSSceneSourcePlanResult::SkippedKind,stats);
  recordRawOutcome(
      IOSSceneSourceKind::Static,Material::Water,false,true,
      IOSSceneSourcePlanResult::SkippedMaterial,stats);

  assert(stats.census.frameAnimated==3u);
  assert(stats.census.uvAnimated==3u);
  assert(stats.skippedTextureAnimation==0u);
  assert(stats.skippedTextureFrameOnly==0u);
  assert(stats.skippedTextureUvOnly==0u);
  assert(stats.skippedTextureFrameAndUv==0u);
  assert(stats.admittedFrameOnly==1u);
  assert(stats.admittedUvOnly==1u);
  assert(stats.admittedFrameAndUv==1u);
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
  frameBound.census.frameAnimated = 1u;
  assert(!frameBound.hasConsistentTextureAnimationCounts());
  assert(!frameBound.hasConsistentSuccessfulCensus());

  IOSSceneExtractionStats uvBound = stats;
  uvBound.census.uvAnimated = 1u;
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

  IOSSceneExtractionStats additiveOverflow;
  additiveOverflow.planned = std::numeric_limits<std::size_t>::max();
  additiveOverflow.plannedAdditive = additiveOverflow.planned;
  additiveOverflow.plannedStatic = additiveOverflow.planned;
  const IOSSceneExtractionStats additiveBefore = additiveOverflow;
  IOSSceneOpaqueMeshPlan additivePlan;
  assert(planIOSOpaqueMeshSource(
      candidate(IOSSceneMeshKind::Static,IOSMaterialCategory::Additive),
      additivePlan)==IOSSceneSourcePlanResult::Planned);
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::Planned,additivePlan,additiveOverflow));
  assert(additiveOverflow.planned==additiveBefore.planned);
  assert(additiveOverflow.plannedAdditive==
         additiveBefore.plannedAdditive);
  assert(additiveOverflow.invalidSource==1u);

  for(const auto mode:{
        IOSSceneTextureAnimationMode::UvOnly,
        IOSSceneTextureAnimationMode::FrameAndUv}) {
    auto source = candidate();
    source.hasUvAnimation = true;
    source.uvPeriodX = 4;
    if(mode==IOSSceneTextureAnimationMode::FrameAndUv) {
      source.hasFrameAnimation = true;
      source.hasValidFrameSequence = true;
      source.frameCount = 2u;
      source.framePeriodMs = 10u;
      }
    IOSSceneOpaqueMeshPlan plan;
    assert(planIOSOpaqueMeshSource(source,plan)==
           IOSSceneSourcePlanResult::Planned);
    IOSSceneExtractionStats stats;
    std::size_t& admitted =
        mode==IOSSceneTextureAnimationMode::UvOnly
          ? stats.admittedUvOnly
          : stats.admittedFrameAndUv;
    admitted = std::numeric_limits<std::size_t>::max();
    assert(!recordIOSScenePlanResult(
        IOSSceneSourcePlanResult::Planned,plan,stats,mode));
    assert(admitted==std::numeric_limits<std::size_t>::max());
    assert(stats.planned==0u);
    assert(stats.invalidSource==1u);
    }

  IOSSceneExtractionStats fabricatedModeStats;
  IOSSceneOpaqueMeshPlan staticPlan;
  assert(planIOSOpaqueMeshSource(candidate(),staticPlan)==
         IOSSceneSourcePlanResult::Planned);
  assert(!recordIOSScenePlanResult(
      IOSSceneSourcePlanResult::Planned,staticPlan,fabricatedModeStats,
      static_cast<IOSSceneTextureAnimationMode>(255u)));
  assert(fabricatedModeStats.invalidSource==1u);

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
  frame.sceneTimeMs = 123456u;
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
  rejectedFrame.sceneTimeMs = 654321u;
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

  IOSSceneFrameState additiveDestination;
  additiveDestination.sceneTimeMs = 777u;
  const IOSSceneFrameState additiveBefore = additiveDestination;
  IOSSceneFrameState additiveStaging;
  auto additiveEntity = entity(50u);
  additiveEntity.kind = IOSSceneMeshKind::Static;
  auto additiveMaterial = material(52u);
  additiveMaterial.category = IOSMaterialCategory::Additive;
  additiveMaterial.flags = IOSMaterialFlagStaticAdditiveNone;
  additiveStaging.entities.push_back(additiveEntity);
  additiveStaging.materials.push_back(additiveMaterial);
  assert(!publishIOSSceneExtraction(
      IOSSceneExtractionResult::AssetBindFailed,
      additiveStaging,additiveDestination));
  assert(sameFrame(additiveDestination,additiveBefore));
  assert(additiveStaging.entities.size()==1u);
  assert(additiveStaging.materials.size()==1u);

  IOSSceneFrameState destination;
  destination.sceneTimeMs = 789012u;
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
  assert(destination.sceneTimeMs==destinationBefore.sceneTimeMs);
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
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  validateAdditiveCensusReportSidecar();
#endif
  validatePublicContract();
  validateStaticAdditiveNoneAdmission();
  validateFrameSelection();
  validateUVOffsetEvaluation();
  validateFrameAnimationEvidence();
  validateUVAnimationEvidence();
  validateFrameOnlyAdmission();
  validateUVAdmission();
  validateFrameTextureAdapter();
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
