#include "graphics/iossceneextractor.h"

#include <cassert>
#include <limits>
#include <type_traits>

namespace {

IOSSceneLandscapeCandidate candidate() {
  IOSSceneLandscapeCandidate source;
  source.sourceId       = 41;
  source.isLandscape    = true;
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

}

int main() {
  static_assert(std::is_trivially_copyable_v<IOSSceneLandscapeCandidate>);
  static_assert(std::is_trivially_copyable_v<IOSSceneLandscapePlan>);

  using Extract = IOSSceneExtractionReport (IOSSceneExtractor::*)(
      const IOSSceneSourceProvider&,const Tempest::Device&,IOSRenderWorld&,
      IOSSceneAssetRegistry&,IOSSceneFrameState&) const;
  static_assert(std::is_same_v<
      decltype(&IOSSceneExtractor::extractLandscape),
      Extract>);

  IOSSceneLandscapePlan plan;
  const auto accepted = candidate();
  assert(planIOSLandscapeSource(accepted,plan)==
         IOSSceneSourcePlanResult::Planned);
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

  auto otherKind = accepted;
  otherKind.isLandscape = false;
  assert(planIOSLandscapeSource(otherKind,plan)==
         IOSSceneSourcePlanResult::SkippedKind);

  auto alphaTest = accepted;
  alphaTest.isSolidMaterial = false;
  assert(planIOSLandscapeSource(alphaTest,plan)==
         IOSSceneSourcePlanResult::SkippedMaterial);

  auto animatedTexture = accepted;
  animatedTexture.hasTextureAnimation = true;
  assert(planIOSLandscapeSource(animatedTexture,plan)==
         IOSSceneSourcePlanResult::SkippedTextureAnimation);
  assert(plan.entityStableKey==0u);
  assert(plan.textureStableKey==0u);
  assert(plan.indices==IOSIndexRange{});

  auto noMaterial = accepted;
  noMaterial.hasMaterial = false;
  assert(planIOSLandscapeSource(noMaterial,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto noMesh = accepted;
  noMesh.hasStaticMesh = false;
  assert(planIOSLandscapeSource(noMesh,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto noTexture = accepted;
  noTexture.hasBaseColorTexture = false;
  assert(planIOSLandscapeSource(noTexture,plan)==
         IOSSceneSourcePlanResult::Planned);
  assert(plan.usesFallbackTexture);
  assert(plan.textureStableKey==noTexture.sourceId);

  auto noIdentity = accepted;
  noIdentity.sourceId = 0;
  assert(planIOSLandscapeSource(noIdentity,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto noBounds = accepted;
  noBounds.hasLocalBounds = false;
  assert(planIOSLandscapeSource(noBounds,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto nonTriangle = accepted;
  nonTriangle.indices.count = 4;
  assert(planIOSLandscapeSource(nonTriangle,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto overflow = accepted;
  overflow.indices = {std::numeric_limits<uint32_t>::max()-2u,3};
  assert(planIOSLandscapeSource(overflow,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto invalidBounds = accepted;
  invalidBounds.localBounds.minimum.x = 10.f;
  assert(planIOSLandscapeSource(invalidBounds,plan)==
         IOSSceneSourcePlanResult::InvalidSource);

  auto nonFinite = accepted;
  nonFinite.transform.elements[0] =
      std::numeric_limits<float>::infinity();
  assert(planIOSLandscapeSource(nonFinite,plan)==
         IOSSceneSourcePlanResult::InvalidSource);
  }
