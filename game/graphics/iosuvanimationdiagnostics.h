#pragma once

#include "iosgpusceneplan.h"

#include <cstddef>
#include <cstdint>
#include <utility>

enum class IOSUVAnimationDiagnosticPhase : uint8_t {
  Baseline,
  Transition,
  };

struct IOSUVAnimationDiagnosticState final {
  uint64_t               generation = 0;
  uint64_t               baselineSequence = 0;
  IOSUVAnimationEvidence baseline;
  bool                   baselineCommitted = false;
  bool                   transitionCommitted = false;

  bool operator==(const IOSUVAnimationDiagnosticState&) const = default;
  };

struct IOSUVAnimationDiagnosticCandidate final {
  IOSUVAnimationDiagnosticPhase phase =
      IOSUVAnimationDiagnosticPhase::Baseline;
  uint64_t    generation = 0;
  uint64_t    sequence = 0;
  std::size_t admittedUvOnly = 0;
  std::size_t admittedFrameAndUv = 0;
  std::size_t plannedCount = 0;
  uint64_t    sourceDigest = IOSUVAnimationFNV1aOffset;
  uint64_t    plannedTextureDigest = IOSUVAnimationFNV1aOffset;
  uint64_t    plannedUVDigest = IOSUVAnimationFNV1aOffset;
  bool        valid = false;
  };

inline constexpr bool isIOSUVAnimationDiagnosticPhase(
    IOSUVAnimationDiagnosticPhase phase) noexcept {
  return phase==IOSUVAnimationDiagnosticPhase::Baseline ||
      phase==IOSUVAnimationDiagnosticPhase::Transition;
  }

inline constexpr char iosUVAnimationDiagnosticPhaseName(
    IOSUVAnimationDiagnosticPhase phase) noexcept {
  return phase==IOSUVAnimationDiagnosticPhase::Baseline ? 'B' : 'T';
  }

inline constexpr char iosUVAnimationDiagnosticModeName(
    IOSSceneTextureAnimationMode mode) noexcept {
  return mode==IOSSceneTextureAnimationMode::UvOnly ? 'U' : 'C';
  }

inline bool iosUVAnimationEvidenceMatchesGeneration(
    const IOSUVAnimationEvidence& evidence,
    uint64_t generation) noexcept {
  if(generation==0u || evidence.selections.empty())
    return false;
  for(const auto& selection:evidence.selections)
    if(selection.selectedHandle.generation.value!=generation)
      return false;
  return true;
  }

inline bool iosUVAnimationEvidenceHasSameCohort(
    const IOSUVAnimationEvidence& lhs,
    const IOSUVAnimationEvidence& rhs) noexcept {
  if(!isCanonicalIOSUVAnimationEvidence(lhs) ||
     !isCanonicalIOSUVAnimationEvidence(rhs) ||
     lhs.sourceDigest!=rhs.sourceDigest ||
     lhs.selections.size()!=rhs.selections.size())
    return false;
  for(std::size_t index=0; index<lhs.selections.size(); ++index) {
    const auto& left = lhs.selections[index];
    const auto& right = rhs.selections[index];
    if(left.sourceId!=right.sourceId || left.mode!=right.mode)
      return false;
    }
  return true;
  }

inline bool iosUVAnimationDrawReportMatchesEvidence(
    const IOSUVAnimationEvidence& evidence,
    const IOSGPUSceneUVAnimationDrawReport& report) noexcept {
  if(!report.valid ||
     !isCanonicalIOSUVAnimationEvidence(evidence) ||
     evidence.selections.empty() ||
     evidence.plannedCount!=evidence.selections.size() ||
     report.drawnUvOnly!=evidence.admittedUvOnly ||
     report.drawnFrameAndUv!=evidence.admittedFrameAndUv ||
     report.encodedCount!=evidence.plannedCount ||
     report.encodedEntries.size()!=evidence.plannedCount ||
     report.encodedTextureDigest!=evidence.textureSelectionDigest ||
     report.encodedUVDigest!=evidence.plannedUVDigest)
    return false;

  if(report.drawnUvOnly>report.encodedCount ||
     report.drawnFrameAndUv>report.encodedCount-report.drawnUvOnly)
    return false;
  if(report.drawnUvOnly+report.drawnFrameAndUv!=report.encodedCount)
    return false;

  uint64_t encodedTextureDigest = IOSUVAnimationFNV1aOffset;
  uint64_t encodedUVDigest = IOSUVAnimationFNV1aOffset;
  for(std::size_t index=0; index<evidence.selections.size(); ++index) {
    const auto& planned = evidence.selections[index];
    const auto& encoded = report.encodedEntries[index];
    if(encoded.sourceId!=planned.sourceId || encoded.mode!=planned.mode ||
       encoded.frameOrdinal!=planned.frameOrdinal ||
       encoded.selectedHandle!=planned.selectedHandle ||
       !isCanonicalIOSUVAnimationOffset(encoded.uvOffset) ||
       iosUVAnimationFloatBits(encoded.uvOffset.x)!=
           iosUVAnimationFloatBits(planned.uvOffset.x) ||
       iosUVAnimationFloatBits(encoded.uvOffset.y)!=
           iosUVAnimationFloatBits(planned.uvOffset.y))
      return false;

    encodedTextureDigest = iosUVAnimationFNV1aAppendUint64(
        encodedTextureDigest,encoded.sourceId);
    encodedTextureDigest = iosUVAnimationFNV1aAppendUint32(
        encodedTextureDigest,static_cast<uint32_t>(encoded.mode));
    encodedTextureDigest = iosUVAnimationFNV1aAppendUint64(
        encodedTextureDigest,encoded.frameOrdinal);
    encodedTextureDigest = iosUVAnimationFNV1aAppendUint64(
        encodedTextureDigest,encoded.selectedHandle.generation.value);
    encodedTextureDigest = iosUVAnimationFNV1aAppendUint64(
        encodedTextureDigest,encoded.selectedHandle.value);
    encodedUVDigest = iosUVAnimationFNV1aAppendUint64(
        encodedUVDigest,encoded.sourceId);
    encodedUVDigest = iosUVAnimationFNV1aAppendUint32(
        encodedUVDigest,iosUVAnimationFloatBits(encoded.uvOffset.x));
    encodedUVDigest = iosUVAnimationFNV1aAppendUint32(
        encodedUVDigest,iosUVAnimationFloatBits(encoded.uvOffset.y));
    }
  return encodedTextureDigest==report.encodedTextureDigest &&
         encodedUVDigest==report.encodedUVDigest;
  }

inline bool iosUVAnimationCandidateMatchesEvidence(
    const IOSUVAnimationDiagnosticCandidate& candidate,
    const IOSUVAnimationEvidence& evidence) noexcept {
  return candidate.valid && candidate.generation!=0u &&
      candidate.sequence!=0u &&
      isIOSUVAnimationDiagnosticPhase(candidate.phase) &&
      isCanonicalIOSUVAnimationEvidence(evidence) &&
      !evidence.selections.empty() &&
      iosUVAnimationEvidenceMatchesGeneration(
          evidence,candidate.generation) &&
      candidate.admittedUvOnly==evidence.admittedUvOnly &&
      candidate.admittedFrameAndUv==evidence.admittedFrameAndUv &&
      candidate.plannedCount==evidence.plannedCount &&
      candidate.sourceDigest==evidence.sourceDigest &&
      candidate.plannedTextureDigest==evidence.textureSelectionDigest &&
      candidate.plannedUVDigest==evidence.plannedUVDigest;
  }

inline IOSUVAnimationDiagnosticCandidate
    prepareIOSUVAnimationDiagnosticCandidate(
        const IOSUVAnimationDiagnosticState& state,
        uint64_t generation,
        uint64_t sequence,
        const IOSUVAnimationEvidence& evidence) noexcept {
  IOSUVAnimationDiagnosticCandidate candidate;
  if(generation==0u || sequence==0u ||
     !isCanonicalIOSUVAnimationEvidence(evidence) ||
     evidence.selections.empty() ||
     !iosUVAnimationEvidenceMatchesGeneration(evidence,generation))
    return candidate;

  candidate.generation = generation;
  candidate.sequence = sequence;
  candidate.admittedUvOnly = evidence.admittedUvOnly;
  candidate.admittedFrameAndUv = evidence.admittedFrameAndUv;
  candidate.plannedCount = evidence.plannedCount;
  candidate.sourceDigest = evidence.sourceDigest;
  candidate.plannedTextureDigest = evidence.textureSelectionDigest;
  candidate.plannedUVDigest = evidence.plannedUVDigest;
  if(state.generation!=generation || !state.baselineCommitted) {
    candidate.phase = IOSUVAnimationDiagnosticPhase::Baseline;
    candidate.valid = true;
    return candidate;
    }
  if(state.transitionCommitted || sequence<=state.baselineSequence ||
     state.baseline.selections.empty() ||
     !iosUVAnimationEvidenceHasSameCohort(state.baseline,evidence) ||
     state.baseline.plannedUVDigest==evidence.plannedUVDigest)
    return {};

  candidate.phase = IOSUVAnimationDiagnosticPhase::Transition;
  candidate.valid = true;
  return candidate;
  }

inline bool iosUVAnimationDiagnosticCandidateAcceptsDrawn(
    const IOSUVAnimationDiagnosticState& state,
    const IOSUVAnimationDiagnosticCandidate& candidate,
    const IOSUVAnimationEvidence& evidence,
    const IOSGPUSceneUVAnimationDrawReport& drawn) noexcept {
  if(!iosUVAnimationCandidateMatchesEvidence(candidate,evidence) ||
     !iosUVAnimationDrawReportMatchesEvidence(evidence,drawn))
    return false;
  if(candidate.phase==IOSUVAnimationDiagnosticPhase::Baseline)
    return state.generation!=candidate.generation ||
           !state.baselineCommitted;
  return state.generation==candidate.generation &&
      state.baselineCommitted && !state.transitionCommitted &&
      candidate.sequence>state.baselineSequence &&
      iosUVAnimationEvidenceHasSameCohort(state.baseline,evidence) &&
      state.baseline.plannedUVDigest!=evidence.plannedUVDigest;
  }

inline bool commitIOSUVAnimationDiagnosticState(
    bool submitAccepted,
    const IOSUVAnimationDiagnosticCandidate& candidate,
    IOSUVAnimationEvidence&& evidence,
    const IOSGPUSceneUVAnimationDrawReport& drawn,
    IOSUVAnimationDiagnosticState& state) noexcept {
  if(!submitAccepted ||
     !iosUVAnimationDiagnosticCandidateAcceptsDrawn(
         state,candidate,evidence,drawn))
    return false;
  if(candidate.phase==IOSUVAnimationDiagnosticPhase::Baseline) {
    IOSUVAnimationDiagnosticState committed;
    committed.generation = candidate.generation;
    committed.baselineSequence = candidate.sequence;
    committed.baseline = std::move(evidence);
    committed.baselineCommitted = true;
    state = std::move(committed);
    }
  else {
    state.transitionCommitted = true;
    }
  return true;
  }

inline IOSGPUSceneMarker iosUVAnimationFormatMarker(
    IOSUVAnimationDiagnosticPhase phase,
    const char* buildSha,
    uint64_t generation,
    uint64_t sequence,
    std::size_t admitted,
    std::size_t admittedUvOnly,
    std::size_t admittedFrameAndUv,
    std::size_t drawn,
    uint64_t sourceDigest) noexcept {
  if(!isIOSUVAnimationDiagnosticPhase(phase) ||
     buildSha==nullptr || buildSha[0]=='\0' ||
     generation==0u || sequence==0u || admitted==0u)
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS UV animation: v=1 p=%c b=%s g=%llu s=%llu "
      "a=%llu u=%llu c=%llu d=%llu sd=%016llx",
      iosUVAnimationDiagnosticPhaseName(phase),buildSha,
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence),
      static_cast<unsigned long long>(admitted),
      static_cast<unsigned long long>(admittedUvOnly),
      static_cast<unsigned long long>(admittedFrameAndUv),
      static_cast<unsigned long long>(drawn),
      static_cast<unsigned long long>(sourceDigest));
  }

inline IOSGPUSceneMarker iosUVAnimationFormatDetailMarker(
    IOSUVAnimationDiagnosticPhase phase,
    uint64_t generation,
    uint64_t sequence,
    uint64_t plannedTextureDigest,
    uint64_t encodedTextureDigest,
    uint64_t plannedUVDigest,
    uint64_t encodedUVDigest) noexcept {
  if(!isIOSUVAnimationDiagnosticPhase(phase) ||
     generation==0u || sequence==0u)
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS UV animation detail: v=1 p=%c g=%llu s=%llu "
      "pt=%016llx et=%016llx pu=%016llx eu=%016llx",
      iosUVAnimationDiagnosticPhaseName(phase),
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence),
      static_cast<unsigned long long>(plannedTextureDigest),
      static_cast<unsigned long long>(encodedTextureDigest),
      static_cast<unsigned long long>(plannedUVDigest),
      static_cast<unsigned long long>(encodedUVDigest));
  }

inline IOSGPUSceneMarker iosUVAnimationFormatSourceMarker(
    IOSUVAnimationDiagnosticPhase phase,
    uint64_t generation,
    uint64_t sequence,
    uint64_t sourceId,
    IOSSceneTextureAnimationMode mode,
    uint64_t ordinal,
    uint64_t encodedHandle,
    uint32_t plannedX,
    uint32_t plannedY,
    uint32_t encodedX,
    uint32_t encodedY) noexcept {
  if(!isIOSUVAnimationDiagnosticPhase(phase) ||
     generation==0u || sequence==0u || sourceId==0u || encodedHandle==0u ||
     (mode!=IOSSceneTextureAnimationMode::UvOnly &&
      mode!=IOSSceneTextureAnimationMode::FrameAndUv))
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS UV animation source: v=1 p=%c g=%llu s=%llu "
      "i=%llu m=%c o=%llu h=%llu x=%08x y=%08x ex=%08x ey=%08x",
      iosUVAnimationDiagnosticPhaseName(phase),
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence),
      static_cast<unsigned long long>(sourceId),
      iosUVAnimationDiagnosticModeName(mode),
      static_cast<unsigned long long>(ordinal),
      static_cast<unsigned long long>(encodedHandle),
      static_cast<unsigned>(plannedX),
      static_cast<unsigned>(plannedY),
      static_cast<unsigned>(encodedX),
      static_cast<unsigned>(encodedY));
  }

inline IOSGPUSceneMarker iosUVAnimationMarker(
    const IOSUVAnimationDiagnosticCandidate& candidate,
    const IOSUVAnimationEvidence& evidence,
    const IOSGPUSceneUVAnimationDrawReport& drawn,
    const char* buildSha) noexcept {
  if(!iosUVAnimationCandidateMatchesEvidence(candidate,evidence) ||
     !iosUVAnimationDrawReportMatchesEvidence(evidence,drawn) ||
     buildSha==nullptr || buildSha[0]=='\0')
    return {};
  return iosUVAnimationFormatMarker(
      candidate.phase,buildSha,candidate.generation,candidate.sequence,
      evidence.plannedCount,evidence.admittedUvOnly,
      evidence.admittedFrameAndUv,drawn.encodedCount,
      evidence.sourceDigest);
  }

inline IOSGPUSceneMarker iosUVAnimationDetailMarker(
    const IOSUVAnimationDiagnosticCandidate& candidate,
    const IOSUVAnimationEvidence& evidence,
    const IOSGPUSceneUVAnimationDrawReport& drawn) noexcept {
  if(!iosUVAnimationCandidateMatchesEvidence(candidate,evidence) ||
     !iosUVAnimationDrawReportMatchesEvidence(evidence,drawn))
    return {};
  return iosUVAnimationFormatDetailMarker(
      candidate.phase,candidate.generation,candidate.sequence,
      evidence.textureSelectionDigest,drawn.encodedTextureDigest,
      evidence.plannedUVDigest,drawn.encodedUVDigest);
  }

inline IOSGPUSceneMarker iosUVAnimationSourceMarker(
    const IOSUVAnimationDiagnosticCandidate& candidate,
    const IOSUVAnimationEvidence& evidence,
    const IOSGPUSceneUVAnimationDrawReport& drawn,
    std::size_t index) noexcept {
  if(!iosUVAnimationCandidateMatchesEvidence(candidate,evidence) ||
     !iosUVAnimationDrawReportMatchesEvidence(evidence,drawn) ||
     index>=evidence.selections.size())
    return {};
  const auto& planned = evidence.selections[index];
  const auto& encoded = drawn.encodedEntries[index];
  return iosUVAnimationFormatSourceMarker(
      candidate.phase,candidate.generation,candidate.sequence,
      planned.sourceId,planned.mode,planned.frameOrdinal,
      encoded.selectedHandle.value,
      iosUVAnimationFloatBits(planned.uvOffset.x),
      iosUVAnimationFloatBits(planned.uvOffset.y),
      iosUVAnimationFloatBits(encoded.uvOffset.x),
      iosUVAnimationFloatBits(encoded.uvOffset.y));
  }
