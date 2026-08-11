#define OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS 1

#include "graphics/iosremainingmaterialcensus.h"

#include <array>
#include <cassert>
#include <cstdint>
#include <limits>
#include <optional>

namespace {

constexpr std::array<Material::AlphaFunc,IOSRemainingMaterialCount> materials = {
  Material::Water,Material::Ghost,Material::Multiply,Material::Multiply2,
  Material::Transparent,
  };

constexpr std::array<IOSSceneSourceKind,IOSRemainingMaterialKindCount> kinds = {
  IOSSceneSourceKind::Landscape,IOSSceneSourceKind::Static,
  IOSSceneSourceKind::Movable,IOSSceneSourceKind::Animated,
  IOSSceneSourceKind::Particle,IOSSceneSourceKind::Morph,
  IOSSceneSourceKind::Unsupported,
  };

constexpr std::array<IOSSceneTextureAnimationMode,
                     IOSRemainingMaterialModeCount> modes = {
  IOSSceneTextureAnimationMode::None,
  IOSSceneTextureAnimationMode::FrameOnly,
  IOSSceneTextureAnimationMode::UvOnly,
  IOSSceneTextureAnimationMode::FrameAndUv,
  };

void validateAllCellsAndConservation() {
  IOSRemainingMaterialCensus census;
  for(std::size_t material=0; material<materials.size(); ++material)
    for(std::size_t kind=0; kind<kinds.size(); ++kind)
      for(std::size_t mode=0; mode<modes.size(); ++mode) {
        const auto before = census;
        assert(iosRecordRemainingMaterialCensus(
                   kinds[kind],materials[material],modes[mode],census)==
               IOSRemainingMaterialCensusResult::Recorded);
        const std::size_t index =
            (material*kinds.size()+kind)*modes.size()+mode;
        assert(census.cells[index]==before.cells[index]+1u);
        assert(census.totals[material]==before.totals[material]+1u);
        assert(census.globalTotal==before.globalTotal+1u);
      }
  std::array<uint64_t,IOSRemainingMaterialCount> raw{};
  raw.fill(IOSRemainingMaterialKindCount*IOSRemainingMaterialModeCount);
  assert(iosFinalizeRemainingMaterialCensus(census,raw));
  assert(census.globalTotal==IOSRemainingMaterialCellCount);
}

void validateIgnoredAndInvalidPrecedence() {
  IOSRemainingMaterialCensus census;
  for(const auto material:{std::optional<Material::AlphaFunc>{},
                           std::optional<Material::AlphaFunc>{Material::Solid},
                           std::optional<Material::AlphaFunc>{Material::AlphaTest},
                           std::optional<Material::AlphaFunc>{Material::AdditiveLight}})
    assert(iosRecordRemainingMaterialCensus(
               IOSSceneSourceKind::Static,material,
               IOSSceneTextureAnimationMode::None,census)==
           IOSRemainingMaterialCensusResult::Ignored);
  assert(census==IOSRemainingMaterialCensus{});

  for(const auto material:{std::optional<Material::AlphaFunc>{},
                           std::optional<Material::AlphaFunc>{Material::Solid},
                           std::optional<Material::AlphaFunc>{Material::Water}}) {
    auto next = census;
    assert(iosRecordRemainingMaterialCensus(
               static_cast<IOSSceneSourceKind>(255u),material,
               IOSSceneTextureAnimationMode::None,next)==
           IOSRemainingMaterialCensusResult::Invalid);
    assert(next==census);
    next = census;
    assert(iosRecordRemainingMaterialCensus(
               IOSSceneSourceKind::Static,material,
               static_cast<IOSSceneTextureAnimationMode>(255u),next)==
           IOSRemainingMaterialCensusResult::Invalid);
    assert(next==census);
  }
  auto next = census;
  assert(iosRecordRemainingMaterialCensus(
             IOSSceneSourceKind::Static,
             static_cast<Material::AlphaFunc>(255u),
             IOSSceneTextureAnimationMode::None,next)==
         IOSRemainingMaterialCensusResult::Invalid);
  assert(next==census);
}

void validateAtomicOverflow() {
  constexpr uint64_t maximum = std::numeric_limits<uint64_t>::max();
  IOSRemainingMaterialCensus baseline;
  baseline.cells[0] = maximum;
  auto next = baseline;
  assert(iosRecordRemainingMaterialCensus(
             IOSSceneSourceKind::Landscape,Material::Water,
             IOSSceneTextureAnimationMode::None,next)==
         IOSRemainingMaterialCensusResult::Overflow);
  assert(next==baseline);

  baseline = {};
  baseline.totals[0] = maximum;
  next = baseline;
  assert(iosRecordRemainingMaterialCensus(
             IOSSceneSourceKind::Landscape,Material::Water,
             IOSSceneTextureAnimationMode::None,next)==
         IOSRemainingMaterialCensusResult::Overflow);
  assert(next==baseline);

  baseline = {};
  baseline.globalTotal = maximum;
  next = baseline;
  assert(iosRecordRemainingMaterialCensus(
             IOSSceneSourceKind::Landscape,Material::Water,
             IOSSceneTextureAnimationMode::None,next)==
         IOSRemainingMaterialCensusResult::Overflow);
  assert(next==baseline);
}

void validateFinalizerAndCandidate() {
  IOSRemainingMaterialCensus census;
  assert(iosRecordRemainingMaterialCensus(
             IOSSceneSourceKind::Static,Material::Transparent,
             IOSSceneTextureAnimationMode::FrameOnly,census)==
         IOSRemainingMaterialCensusResult::Recorded);
  std::array<uint64_t,IOSRemainingMaterialCount> raw = {0,0,0,0,1};
  assert(iosFinalizeRemainingMaterialCensus(census,raw));
  auto drift = raw;
  drift[4] = 2;
  assert(!iosFinalizeRemainingMaterialCensus(census,drift));
  auto broken = census;
  broken.totals[4] = 2;
  assert(!iosFinalizeRemainingMaterialCensus(broken,raw));
  broken = census;
  broken.globalTotal = 2;
  assert(!iosFinalizeRemainingMaterialCensus(broken,raw));

  const auto candidate = prepareIOSRemainingMaterialCensusDiagnosticCandidate(
      census,raw,3,1);
  assert(candidate.valid);
  assert(iosRemainingMaterialCensusCandidateAcceptsCommit(
      candidate,true,true,9,9,3,1));
  assert(!iosRemainingMaterialCensusCandidateAcceptsCommit(
      candidate,false,true,9,9,3,1));
  assert(!iosRemainingMaterialCensusCandidateAcceptsCommit(
      candidate,true,false,9,9,3,1));
  assert(!iosRemainingMaterialCensusCandidateAcceptsCommit(
      candidate,true,true,8,9,3,1));
  assert(!iosRemainingMaterialCensusCandidateAcceptsCommit(
      candidate,true,true,9,9,4,1));
  assert(!iosRemainingMaterialCensusCandidateAcceptsCommit(
      candidate,true,true,9,9,3,2));
  const auto cadence = prepareIOSRemainingMaterialCensusDiagnosticCandidate(
      census,raw,3,300);
  assert(iosRemainingMaterialCensusCandidateAcceptsCommit(
      cadence,true,true,9,9,3,300));
}

}

int main() {
  static_assert(IOSRemainingMaterialCount==5u);
  static_assert(IOSRemainingMaterialKindCount==7u);
  static_assert(IOSRemainingMaterialModeCount==4u);
  static_assert(IOSRemainingMaterialCellCount==140u);
  static_assert(static_cast<uint8_t>(
      IOSRemainingMaterialCensusResult::Ignored)==0u);
  static_assert(static_cast<uint8_t>(
      IOSRemainingMaterialCensusResult::Recorded)==1u);
  static_assert(static_cast<uint8_t>(
      IOSRemainingMaterialCensusResult::Invalid)==2u);
  static_assert(static_cast<uint8_t>(
      IOSRemainingMaterialCensusResult::Overflow)==3u);
  validateAllCellsAndConservation();
  validateIgnoredAndInvalidPrecedence();
  validateAtomicOverflow();
  validateFinalizerAndCandidate();
}
