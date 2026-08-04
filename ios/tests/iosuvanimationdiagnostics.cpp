#include "graphics/iosuvanimationdiagnostics.h"

#include <cassert>
#include <cstdint>
#include <limits>
#include <string_view>
#include <utility>

namespace {

constexpr uint64_t Generation = 7u;

IOSUVAnimationEvidence makeEvidence(float firstX = 0.25f,
                                    float firstY = 0.f,
                                    float secondX = -0.5f,
                                    float secondY = 0.75f) {
  IOSUVAnimationEvidence evidence;
  evidence.selections = {
    {90u,IOSSceneTextureAnimationMode::FrameAndUv,3u,
     {{Generation},18u},{secondX,secondY}},
    {40u,IOSSceneTextureAnimationMode::UvOnly,0u,
     {{Generation},14u},{firstX,firstY}},
    };
  assert(finalizeIOSUVAnimationEvidence(evidence));
  return evidence;
  }

IOSGPUSceneUVAnimationDrawReport makeDrawn(
    const IOSUVAnimationEvidence& evidence) {
  IOSGPUSceneUVAnimationDrawReport drawn;
  drawn.encodedEntries = evidence.selections;
  drawn.drawnUvOnly = evidence.admittedUvOnly;
  drawn.drawnFrameAndUv = evidence.admittedFrameAndUv;
  drawn.encodedCount = evidence.plannedCount;
  drawn.encodedTextureDigest = evidence.textureSelectionDigest;
  drawn.encodedUVDigest = evidence.plannedUVDigest;
  drawn.valid = true;
  return drawn;
  }

void validateCanonicalCandidateAndCohort() {
  IOSUVAnimationDiagnosticState state;
  IOSUVAnimationEvidence empty;
  assert(finalizeIOSUVAnimationEvidence(empty));
  assert(!prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,1u,empty).valid);

  const auto baseline = makeEvidence();
  const auto candidate = prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,11u,baseline);
  assert(candidate.valid);
  assert(candidate.phase==IOSUVAnimationDiagnosticPhase::Baseline);
  assert(candidate.generation==Generation);
  assert(candidate.sequence==11u);
  assert(candidate.admittedUvOnly==1u);
  assert(candidate.admittedFrameAndUv==1u);
  assert(candidate.plannedCount==2u);
  assert(candidate.sourceDigest==baseline.sourceDigest);
  assert(candidate.plannedTextureDigest==
         baseline.textureSelectionDigest);
  assert(candidate.plannedUVDigest==baseline.plannedUVDigest);

  auto wrongGeneration = baseline;
  wrongGeneration.selections[0].selectedHandle.generation = {Generation+1u};
  wrongGeneration.selections[1].selectedHandle.generation = {Generation+1u};
  assert(finalizeIOSUVAnimationEvidence(wrongGeneration));
  assert(!prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,11u,wrongGeneration).valid);

  auto changedValues = makeEvidence(0.5f,0.f,-0.25f,0.75f);
  assert(iosUVAnimationEvidenceHasSameCohort(baseline,changedValues));

  auto changedTexture = baseline;
  changedTexture.selections[1].frameOrdinal = 12u;
  changedTexture.selections[1].selectedHandle.value = 44u;
  assert(finalizeIOSUVAnimationEvidence(changedTexture));
  assert(iosUVAnimationEvidenceHasSameCohort(baseline,changedTexture));

  auto changedMode = baseline;
  changedMode.selections[0].mode = IOSSceneTextureAnimationMode::FrameAndUv;
  changedMode.selections[0].frameOrdinal = 1u;
  assert(finalizeIOSUVAnimationEvidence(changedMode));
  assert(!iosUVAnimationEvidenceHasSameCohort(baseline,changedMode));

  auto changedSource = baseline;
  changedSource.selections[0].sourceId = 41u;
  assert(finalizeIOSUVAnimationEvidence(changedSource));
  assert(!iosUVAnimationEvidenceHasSameCohort(baseline,changedSource));
  }

void validateDrawReportAcceptance() {
  const auto evidence = makeEvidence();
  const auto drawn = makeDrawn(evidence);
  assert(iosUVAnimationDrawReportMatchesEvidence(evidence,drawn));

  const auto rejects = [&](IOSGPUSceneUVAnimationDrawReport changed) {
    assert(!iosUVAnimationDrawReportMatchesEvidence(evidence,changed));
    };
  {
    auto changed = drawn;
    changed.valid = false;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    ++changed.drawnUvOnly;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    ++changed.drawnFrameAndUv;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    --changed.encodedCount;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    changed.encodedEntries.pop_back();
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    changed.encodedTextureDigest ^= 1u;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    changed.encodedUVDigest ^= 1u;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    ++changed.encodedEntries[0].sourceId;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    changed.encodedEntries[0].mode =
        IOSSceneTextureAnimationMode::FrameAndUv;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    ++changed.encodedEntries[0].frameOrdinal;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    ++changed.encodedEntries[0].selectedHandle.value;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    changed.encodedEntries[0].uvOffset.x = -0.f;
    rejects(std::move(changed));
  }
  {
    auto changed = drawn;
    changed.encodedEntries[1].uvOffset.y = 0.5f;
    rejects(std::move(changed));
  }
  }

void validateStateTransitionsAndAtomicCommit() {
  IOSUVAnimationDiagnosticState state;
  auto baseline = makeEvidence();
  const auto baselineDrawn = makeDrawn(baseline);
  const auto baselineCandidate = prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,11u,baseline);
  assert(iosUVAnimationDiagnosticCandidateAcceptsDrawn(
      state,baselineCandidate,baseline,baselineDrawn));

  const auto originalState = state;
  auto rejectedBaseline = baseline;
  assert(!commitIOSUVAnimationDiagnosticState(
      false,baselineCandidate,std::move(rejectedBaseline),
      baselineDrawn,state));
  assert(state==originalState);

  assert(commitIOSUVAnimationDiagnosticState(
      true,baselineCandidate,std::move(baseline),baselineDrawn,state));
  assert(state.generation==Generation);
  assert(state.baselineSequence==11u);
  assert(state.baselineCommitted);
  assert(!state.transitionCommitted);

  auto sameUV = makeEvidence();
  sameUV.selections[1].frameOrdinal = 4u;
  sameUV.selections[1].selectedHandle.value = 19u;
  assert(finalizeIOSUVAnimationEvidence(sameUV));
  assert(sameUV.plannedUVDigest==state.baseline.plannedUVDigest);
  assert(!prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,12u,sameUV).valid);

  auto changedUV = makeEvidence(0.5f,0.f,-0.25f,0.75f);
  const auto transitionCandidate =
      prepareIOSUVAnimationDiagnosticCandidate(
          state,Generation,13u,changedUV);
  assert(transitionCandidate.valid);
  assert(transitionCandidate.phase==
         IOSUVAnimationDiagnosticPhase::Transition);
  assert(!prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,11u,changedUV).valid);

  auto changedCohort = changedUV;
  changedCohort.selections[0].sourceId = 41u;
  assert(finalizeIOSUVAnimationEvidence(changedCohort));
  assert(!prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,13u,changedCohort).valid);

  auto badDrawn = makeDrawn(changedUV);
  badDrawn.encodedUVDigest ^= 1u;
  const auto beforeRejectedTransition = state;
  auto rejectedTransition = changedUV;
  assert(!commitIOSUVAnimationDiagnosticState(
      true,transitionCandidate,std::move(rejectedTransition),
      badDrawn,state));
  assert(state==beforeRejectedTransition);

  const auto transitionDrawn = makeDrawn(changedUV);
  assert(commitIOSUVAnimationDiagnosticState(
      true,transitionCandidate,std::move(changedUV),
      transitionDrawn,state));
  assert(state.transitionCommitted);

  const auto anotherChange = makeEvidence(0.75f,0.f,-0.125f,0.75f);
  assert(!prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,14u,anotherChange).valid);

  const auto nextGeneration = makeEvidence();
  auto generationEvidence = nextGeneration;
  for(auto& selection:generationEvidence.selections)
    selection.selectedHandle.generation = {Generation+1u};
  assert(finalizeIOSUVAnimationEvidence(generationEvidence));
  const auto generationCandidate =
      prepareIOSUVAnimationDiagnosticCandidate(
          state,Generation+1u,1u,generationEvidence);
  assert(generationCandidate.valid);
  assert(generationCandidate.phase==
         IOSUVAnimationDiagnosticPhase::Baseline);
  }

void validateFrozenMarkers() {
  const auto evidence = makeEvidence();
  const auto drawn = makeDrawn(evidence);
  IOSUVAnimationDiagnosticState state;
  const auto candidate = prepareIOSUVAnimationDiagnosticCandidate(
      state,Generation,11u,evidence);

  const auto primary = iosUVAnimationMarker(
      candidate,evidence,drawn,
      "0123456789abcdef0123456789abcdef01234567");
  const auto detail = iosUVAnimationDetailMarker(
      candidate,evidence,drawn);
  const auto first = iosUVAnimationSourceMarker(
      candidate,evidence,drawn,0u);
  const auto second = iosUVAnimationSourceMarker(
      candidate,evidence,drawn,1u);
  assert(primary && detail && first && second);
  assert(primary.length<=254u && detail.length<=254u &&
         first.length<=254u && second.length<=254u);
  assert(std::string_view(primary.text.data())==
      "RendererIOS UV animation: v=1 p=B "
      "b=0123456789abcdef0123456789abcdef01234567 "
      "g=7 s=11 a=2 u=1 c=1 d=2 sd=14cb9d94c0308bd7");
  assert(std::string_view(detail.text.data())==
      "RendererIOS UV animation detail: v=1 p=B g=7 s=11 "
      "pt=ef2a7680dc2f24c9 et=ef2a7680dc2f24c9 "
      "pu=13a6354e31fe5b59 eu=13a6354e31fe5b59");
  assert(std::string_view(first.text.data())==
      "RendererIOS UV animation source: v=1 p=B g=7 s=11 "
      "i=40 m=U o=0 h=14 x=3e800000 y=00000000 "
      "ex=3e800000 ey=00000000");
  assert(std::string_view(second.text.data())==
      "RendererIOS UV animation source: v=1 p=B g=7 s=11 "
      "i=90 m=C o=3 h=18 x=bf000000 y=3f400000 "
      "ex=bf000000 ey=3f400000");
  assert(!iosUVAnimationSourceMarker(
      candidate,evidence,drawn,2u));
  auto invalidPhase = candidate;
  invalidPhase.phase = static_cast<IOSUVAnimationDiagnosticPhase>(255u);
  assert(!iosUVAnimationMarker(
      invalidPhase,evidence,drawn,
      "0123456789abcdef0123456789abcdef01234567"));

  constexpr auto maximum = std::numeric_limits<uint64_t>::max();
  constexpr auto maximumSize = std::numeric_limits<std::size_t>::max();
  const auto longestPrimary = iosUVAnimationFormatMarker(
      IOSUVAnimationDiagnosticPhase::Transition,
      "ffffffffffffffffffffffffffffffffffffffff",
      maximum,maximum,maximumSize,maximumSize,maximumSize,maximumSize,
      maximum);
  const auto longestDetail = iosUVAnimationFormatDetailMarker(
      IOSUVAnimationDiagnosticPhase::Transition,
      maximum,maximum,maximum,maximum,maximum,maximum);
  const auto longestSource = iosUVAnimationFormatSourceMarker(
      IOSUVAnimationDiagnosticPhase::Transition,
      maximum,maximum,maximum,
      IOSSceneTextureAnimationMode::FrameAndUv,
      maximum,maximum,
      std::numeric_limits<uint32_t>::max(),
      std::numeric_limits<uint32_t>::max(),
      std::numeric_limits<uint32_t>::max(),
      std::numeric_limits<uint32_t>::max());
  assert(longestPrimary && longestPrimary.length==234u);
  assert(longestDetail && longestDetail.length==166u);
  assert(longestSource && longestSource.length==205u);
  }

}

int main() {
  validateCanonicalCandidateAndCohort();
  validateDrawReportAcceptance();
  validateStateTransitionsAndAtomicCommit();
  validateFrozenMarkers();
  }
