#pragma once

#include "iossceneextractorplan.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

inline constexpr uint64_t IOSUVAnimationFNV1aOffset =
    14695981039346656037ull;
inline constexpr uint64_t IOSUVAnimationFNV1aPrime = 1099511628211ull;

inline constexpr uint64_t iosUVAnimationFNV1aAppendByte(
    uint64_t digest, uint8_t byte) noexcept {
  digest ^= byte;
  digest *= IOSUVAnimationFNV1aPrime;
  return digest;
  }

inline constexpr uint64_t iosUVAnimationFNV1aAppendUint32(
    uint64_t digest, uint32_t word) noexcept {
  for(unsigned byte=0; byte<4u; ++byte) {
    digest = iosUVAnimationFNV1aAppendByte(
        digest,static_cast<uint8_t>(word&uint32_t(0xffu)));
    word >>= 8u;
    }
  return digest;
  }

inline constexpr uint64_t iosUVAnimationFNV1aAppendUint64(
    uint64_t digest, uint64_t word) noexcept {
  for(unsigned byte=0; byte<8u; ++byte) {
    digest = iosUVAnimationFNV1aAppendByte(
        digest,static_cast<uint8_t>(word&uint64_t(0xffu)));
    word >>= 8u;
    }
  return digest;
  }

inline uint32_t iosUVAnimationFloatBits(float value) noexcept {
  return std::bit_cast<uint32_t>(value==0.f ? 0.f : value);
  }

struct IOSUVAnimationSelection final {
  uint64_t                     sourceId = 0;
  IOSSceneTextureAnimationMode mode = IOSSceneTextureAnimationMode::None;
  uint64_t                     frameOrdinal = 0;
  IOSTextureHandle             selectedHandle;
  IOSFloat2                    uvOffset;

  constexpr bool operator==(
      const IOSUVAnimationSelection&) const noexcept = default;
  };

struct IOSUVAnimationEvidence final {
  std::vector<IOSUVAnimationSelection> selections;
  std::size_t admittedUvOnly = 0;
  std::size_t admittedFrameAndUv = 0;
  std::size_t plannedCount = 0;
  uint64_t sourceDigest = IOSUVAnimationFNV1aOffset;
  uint64_t textureSelectionDigest = IOSUVAnimationFNV1aOffset;
  uint64_t plannedUVDigest = IOSUVAnimationFNV1aOffset;

  bool operator==(const IOSUVAnimationEvidence&) const = default;
  };

inline bool isCanonicalIOSUVAnimationOffset(IOSFloat2 offset) noexcept {
  if(!std::isfinite(offset.x) || !std::isfinite(offset.y))
    return false;
  return (offset.x!=0.f || std::bit_cast<uint32_t>(offset.x)==0u) &&
         (offset.y!=0.f || std::bit_cast<uint32_t>(offset.y)==0u);
  }

inline bool hasCanonicalIOSUVAnimationSelectionIdentities(
    const std::vector<IOSUVAnimationSelection>& selections) noexcept {
  IOSWorldGeneration generation;
  uint64_t previousSourceId = 0;
  for(std::size_t index=0; index<selections.size(); ++index) {
    const auto& selection = selections[index];
    if(selection.sourceId==0 || !selection.selectedHandle ||
       selection.sourceId<=previousSourceId ||
       !isCanonicalIOSUVAnimationOffset(selection.uvOffset))
      return false;
    previousSourceId = selection.sourceId;

    if(selection.mode==IOSSceneTextureAnimationMode::UvOnly) {
      if(selection.frameOrdinal!=0u)
        return false;
      }
    else if(selection.mode!=IOSSceneTextureAnimationMode::FrameAndUv) {
      return false;
      }

    if(index==0u)
      generation = selection.selectedHandle.generation;
    else if(selection.selectedHandle.generation!=generation)
      return false;

    for(std::size_t prior=0; prior<index; ++prior) {
      if(selection.selectedHandle==selections[prior].selectedHandle)
        return false;
      }
    }
  return true;
  }

struct IOSUVAnimationEvidenceSummary final {
  std::size_t admittedUvOnly = 0;
  std::size_t admittedFrameAndUv = 0;
  std::size_t plannedCount = 0;
  uint64_t sourceDigest = IOSUVAnimationFNV1aOffset;
  uint64_t textureSelectionDigest = IOSUVAnimationFNV1aOffset;
  uint64_t plannedUVDigest = IOSUVAnimationFNV1aOffset;
  };

inline bool summarizeCanonicalIOSUVAnimationEvidence(
    const std::vector<IOSUVAnimationSelection>& selections,
    IOSUVAnimationEvidenceSummary& summary) noexcept {
  summary = {};
  if(!hasCanonicalIOSUVAnimationSelectionIdentities(selections))
    return false;

  for(const auto& selection:selections) {
    if(selection.mode==IOSSceneTextureAnimationMode::UvOnly)
      ++summary.admittedUvOnly;
    else
      ++summary.admittedFrameAndUv;

    summary.sourceDigest = iosUVAnimationFNV1aAppendUint64(
        summary.sourceDigest,selection.sourceId);
    summary.textureSelectionDigest = iosUVAnimationFNV1aAppendUint64(
        summary.textureSelectionDigest,selection.sourceId);
    summary.textureSelectionDigest = iosUVAnimationFNV1aAppendUint32(
        summary.textureSelectionDigest,
        static_cast<uint32_t>(selection.mode));
    summary.textureSelectionDigest = iosUVAnimationFNV1aAppendUint64(
        summary.textureSelectionDigest,selection.frameOrdinal);
    summary.textureSelectionDigest = iosUVAnimationFNV1aAppendUint64(
        summary.textureSelectionDigest,
        selection.selectedHandle.generation.value);
    summary.textureSelectionDigest = iosUVAnimationFNV1aAppendUint64(
        summary.textureSelectionDigest,selection.selectedHandle.value);
    summary.plannedUVDigest = iosUVAnimationFNV1aAppendUint64(
        summary.plannedUVDigest,selection.sourceId);
    summary.plannedUVDigest = iosUVAnimationFNV1aAppendUint32(
        summary.plannedUVDigest,
        iosUVAnimationFloatBits(selection.uvOffset.x));
    summary.plannedUVDigest = iosUVAnimationFNV1aAppendUint32(
        summary.plannedUVDigest,
        iosUVAnimationFloatBits(selection.uvOffset.y));
    }
  summary.plannedCount = selections.size();
  return true;
  }

inline bool finalizeIOSUVAnimationEvidence(
    IOSUVAnimationEvidence& evidence) noexcept {
  std::sort(
      evidence.selections.begin(),evidence.selections.end(),
      [](const IOSUVAnimationSelection& lhs,
         const IOSUVAnimationSelection& rhs) noexcept {
        return lhs.sourceId<rhs.sourceId;
        });
  IOSUVAnimationEvidenceSummary summary;
  if(!summarizeCanonicalIOSUVAnimationEvidence(
         evidence.selections,summary))
    return false;

  evidence.admittedUvOnly = summary.admittedUvOnly;
  evidence.admittedFrameAndUv = summary.admittedFrameAndUv;
  evidence.plannedCount = summary.plannedCount;
  evidence.sourceDigest = summary.sourceDigest;
  evidence.textureSelectionDigest = summary.textureSelectionDigest;
  evidence.plannedUVDigest = summary.plannedUVDigest;
  return true;
  }

inline bool isCanonicalIOSUVAnimationEvidence(
    const IOSUVAnimationEvidence& evidence) noexcept {
  IOSUVAnimationEvidenceSummary summary;
  if(!summarizeCanonicalIOSUVAnimationEvidence(
         evidence.selections,summary))
    return false;
  return evidence.admittedUvOnly==summary.admittedUvOnly &&
      evidence.admittedFrameAndUv==summary.admittedFrameAndUv &&
      evidence.plannedCount==summary.plannedCount &&
      evidence.sourceDigest==summary.sourceDigest &&
      evidence.textureSelectionDigest==summary.textureSelectionDigest &&
      evidence.plannedUVDigest==summary.plannedUVDigest;
  }
