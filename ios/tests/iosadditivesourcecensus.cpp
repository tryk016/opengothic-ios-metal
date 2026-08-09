#define OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS 1

#include "graphics/iosadditivesourcecensus.h"

#include <cassert>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

namespace {

void validatePublicContract() {
  static_assert(sizeof(IOSAdditiveSourceCensus)==sizeof(uint64_t)*29u);
  static_assert(std::is_nothrow_default_constructible_v<
                IOSAdditiveSourceCensus>);
  static_assert(noexcept(iosRecordAdditiveSourceCensus(
      IOSSceneSourceKind::Static,
      std::declval<std::optional<Material::AlphaFunc>>(),
      IOSSceneTextureAnimationMode::None,
      std::declval<IOSAdditiveSourceCensus&>())));
  static_assert(noexcept(iosFinalizeAdditiveSourceCensus(
      std::declval<const IOSAdditiveSourceCensus&>(),uint64_t{})));
  static_assert(static_cast<uint8_t>(IOSAdditiveCensusResult::Ignored)==0u);
  static_assert(static_cast<uint8_t>(IOSAdditiveCensusResult::Recorded)==1u);
  static_assert(static_cast<uint8_t>(IOSAdditiveCensusResult::Invalid)==2u);
  static_assert(static_cast<uint8_t>(IOSAdditiveCensusResult::Overflow)==3u);
  }

void validateMatrix() {
  IOSAdditiveSourceCensus census;
  for(uint8_t kind=0; kind<7u; ++kind) {
    for(uint8_t mode=0; mode<4u; ++mode) {
      assert(iosRecordAdditiveSourceCensus(
          static_cast<IOSSceneSourceKind>(kind),Material::AdditiveLight,
          static_cast<IOSSceneTextureAnimationMode>(mode),census)==
          IOSAdditiveCensusResult::Recorded);
      assert(census.cells[static_cast<std::size_t>(kind)*4u+mode]==1u);
      }
    }
  assert(census.total==28u);
  assert(iosFinalizeAdditiveSourceCensus(census,28u));
  }

void validateIgnoredAndInvalid() {
  IOSAdditiveSourceCensus census;
  for(const auto alpha:{
        Material::Solid,Material::AlphaTest,Material::Water,Material::Ghost,
        Material::Multiply,Material::Multiply2,Material::Transparent})
    assert(iosRecordAdditiveSourceCensus(
        IOSSceneSourceKind::Static,alpha,
        IOSSceneTextureAnimationMode::None,census)==
        IOSAdditiveCensusResult::Ignored);
  assert(iosRecordAdditiveSourceCensus(
      IOSSceneSourceKind::Static,std::nullopt,
      IOSSceneTextureAnimationMode::None,census)==
      IOSAdditiveCensusResult::Ignored);
  assert(census==IOSAdditiveSourceCensus{});

  for(const auto result:{
        iosRecordAdditiveSourceCensus(
            static_cast<IOSSceneSourceKind>(7u),Material::AdditiveLight,
            IOSSceneTextureAnimationMode::None,census),
        iosRecordAdditiveSourceCensus(
            IOSSceneSourceKind::Static,Material::AdditiveLight,
            static_cast<IOSSceneTextureAnimationMode>(4u),census),
        iosRecordAdditiveSourceCensus(
            IOSSceneSourceKind::Static,
            static_cast<Material::AlphaFunc>(8u),
            IOSSceneTextureAnimationMode::None,census),
        iosRecordAdditiveSourceCensus(
            static_cast<IOSSceneSourceKind>(255u),std::nullopt,
            IOSSceneTextureAnimationMode::None,census),
        iosRecordAdditiveSourceCensus(
            IOSSceneSourceKind::Static,std::nullopt,
            static_cast<IOSSceneTextureAnimationMode>(255u),census),
        iosRecordAdditiveSourceCensus(
            static_cast<IOSSceneSourceKind>(255u),Material::Solid,
            IOSSceneTextureAnimationMode::None,census)})
    assert(result==IOSAdditiveCensusResult::Invalid);
  assert(census==IOSAdditiveSourceCensus{});
  }

void validateAtomicOverflow() {
  IOSAdditiveSourceCensus cellOverflow;
  cellOverflow.cells[4] = std::numeric_limits<uint64_t>::max();
  const auto cellBefore = cellOverflow;
  assert(iosRecordAdditiveSourceCensus(
      IOSSceneSourceKind::Static,Material::AdditiveLight,
      IOSSceneTextureAnimationMode::None,cellOverflow)==
      IOSAdditiveCensusResult::Overflow);
  assert(cellOverflow==cellBefore);

  IOSAdditiveSourceCensus totalOverflow;
  totalOverflow.total = std::numeric_limits<uint64_t>::max();
  const auto totalBefore = totalOverflow;
  assert(iosRecordAdditiveSourceCensus(
      IOSSceneSourceKind::Static,Material::AdditiveLight,
      IOSSceneTextureAnimationMode::None,totalOverflow)==
      IOSAdditiveCensusResult::Overflow);
  assert(totalOverflow==totalBefore);
  }

void validateConservation() {
  IOSAdditiveSourceCensus census;
  census.cells[0] = 1u;
  census.cells[27] = 2u;
  census.total = 3u;
  assert(iosFinalizeAdditiveSourceCensus(census,3u));
  assert(!iosFinalizeAdditiveSourceCensus(census,2u));
  census.total = 2u;
  assert(!iosFinalizeAdditiveSourceCensus(census,2u));

  IOSAdditiveSourceCensus sumOverflow;
  sumOverflow.cells[0] = std::numeric_limits<uint64_t>::max();
  sumOverflow.cells[1] = 1u;
  sumOverflow.total = std::numeric_limits<uint64_t>::max();
  assert(!iosFinalizeAdditiveSourceCensus(
      sumOverflow,std::numeric_limits<uint64_t>::max()));

  IOSAdditiveSourceCensus wrapToMatchingZero;
  wrapToMatchingZero.cells[0] = std::numeric_limits<uint64_t>::max();
  wrapToMatchingZero.cells[1] = 1u;
  wrapToMatchingZero.total = 0u;
  assert(!iosFinalizeAdditiveSourceCensus(wrapToMatchingZero,0u));
  }

void validateAcceptedCommitGate() {
  IOSAdditiveSourceCensus census;
  assert(iosRecordAdditiveSourceCensus(
      IOSSceneSourceKind::Static,Material::AdditiveLight,
      IOSSceneTextureAnimationMode::None,census)==
      IOSAdditiveCensusResult::Recorded);
  const auto sequenceOne =
      prepareIOSAdditiveSourceCensusDiagnosticCandidate(
          census,1u,7u,1u);
  assert(sequenceOne.valid);
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      sequenceOne,false,false,11u,11u,7u,1u));
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      sequenceOne,false,true,11u,11u,7u,1u));
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      sequenceOne,true,false,11u,11u,7u,1u));
  assert(iosAdditiveSourceCensusCandidateAcceptsCommit(
      sequenceOne,true,true,11u,11u,7u,1u));
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      sequenceOne,true,true,11u,12u,7u,1u));
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      sequenceOne,true,true,11u,11u,8u,1u));
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      sequenceOne,true,true,11u,11u,7u,300u));

  const auto cadence300 =
      prepareIOSAdditiveSourceCensusDiagnosticCandidate(
          census,1u,7u,300u);
  const auto offCadence =
      prepareIOSAdditiveSourceCensusDiagnosticCandidate(
          census,1u,7u,299u);
  assert(iosAdditiveSourceCensusCandidateAcceptsCommit(
      cadence300,true,true,11u,11u,7u,300u));
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      offCadence,true,true,11u,11u,7u,299u));

  const auto invalidConservation =
      prepareIOSAdditiveSourceCensusDiagnosticCandidate(
          census,0u,7u,1u);
  assert(!invalidConservation.valid);
  assert(!iosAdditiveSourceCensusCandidateAcceptsCommit(
      invalidConservation,true,true,11u,11u,7u,1u));
  }

bool rendererAcceptedCommitSourceOracle(std::string_view view) {
  const auto buildSnapshot = view.find(
      "auto snapshot = impl->renderWorld.buildSnapshot(std::move(scene));");
  const auto submitFrame = view.find(
      "RendererIOS::SubmitResult RendererIOS::submitFrame",buildSnapshot);
  if(buildSnapshot==std::string_view::npos ||
     submitFrame==std::string_view::npos ||
     view.substr(buildSnapshot,submitFrame-buildSnapshot).find(
         "logAdditiveSourceCensus(")!=std::string_view::npos)
    return false;

  const auto acceptedCommit = view.find(
      "const bool accepted = !submitted || state.world->commitAccepted(*state.scene);",
      submitFrame);
  const auto successfulCommit = view.find(
      "if(submitted && accepted) {",
      acceptedCommit);
  const auto censusCommit = view.find(
      "state.renderer->commitAdditiveSourceCensusDiagnostics(",
      successfulCommit);
  const auto cleanup = view.find(
      "state.renderer->clearPreparedScene(state.serial);",censusCommit);
  if(acceptedCommit==std::string_view::npos ||
     successfulCommit==std::string_view::npos ||
     censusCommit==std::string_view::npos || cleanup==std::string_view::npos ||
     !(acceptedCommit<successfulCommit && successfulCommit<censusCommit &&
       censusCommit<cleanup))
    return false;

  const auto guardOpen = view.find('{',successfulCommit);
  if(guardOpen==std::string_view::npos || guardOpen>=censusCommit)
    return false;
  std::size_t depth = 0;
  std::size_t guardClose = std::string_view::npos;
  for(std::size_t index=guardOpen; index<cleanup; ++index) {
    if(view[index]=='{')
      ++depth;
    else if(view[index]=='}') {
      if(depth==0u)
        return false;
      --depth;
      if(depth==0u) {
        guardClose = index;
        break;
        }
      }
    }
  return guardClose!=std::string_view::npos && censusCommit<guardClose;
  }

void validateRendererAcceptedCommitSourceOracle() {
  std::ifstream input("game/graphics/rendererios.cpp",std::ios::binary);
  assert(input);
  const std::string source{
      std::istreambuf_iterator<char>(input),
      std::istreambuf_iterator<char>()};
  assert(rendererAcceptedCommitSourceOracle(source));

  std::string outsideAcceptedGuard = source;
  const std::string guard = "if(submitted && accepted) {";
  const auto guardAt = outsideAcceptedGuard.find(guard);
  assert(guardAt!=std::string::npos);
  outsideAcceptedGuard.replace(guardAt,guard.size(),"{");
  assert(!rendererAcceptedCommitSourceOracle(outsideAcceptedGuard));
  }

}

int main() {
  validatePublicContract();
  validateMatrix();
  validateIgnoredAndInvalid();
  validateAtomicOverflow();
  validateConservation();
  validateAcceptedCommitGate();
  validateRendererAcceptedCommitSourceOracle();
  return 0;
  }
