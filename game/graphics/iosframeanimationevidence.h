#pragma once

#include "iosscenesnapshot.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

inline constexpr uint64_t IOSFrameAnimationFNV1aOffset =
    14695981039346656037ull;
inline constexpr uint64_t IOSFrameAnimationFNV1aPrime = 1099511628211ull;

inline constexpr uint64_t iosFrameAnimationFNV1aAppendWord(
    uint64_t digest, uint64_t word) noexcept {
  for(unsigned byte=0; byte<8u; ++byte) {
    digest ^= word & uint64_t(0xffu);
    digest *= IOSFrameAnimationFNV1aPrime;
    word >>= 8u;
    }
  return digest;
  }

struct IOSFrameAnimationSelection final {
  uint64_t         sourceId = 0;
  uint64_t         frameOrdinal = 0;
  IOSTextureHandle selectedHandle;

  constexpr bool operator==(
      const IOSFrameAnimationSelection&) const noexcept = default;
  };

struct IOSFrameAnimationEvidence final {
  std::vector<IOSFrameAnimationSelection> selections;
  std::size_t admittedFrameOnly = 0;
  std::size_t nonzeroFrameOrdinals = 0;
  uint64_t sourceDigest = IOSFrameAnimationFNV1aOffset;
  uint64_t pairDigest = IOSFrameAnimationFNV1aOffset;

  bool operator==(const IOSFrameAnimationEvidence&) const = default;
  };

inline bool hasCanonicalIOSFrameAnimationSelectionIdentities(
    const std::vector<IOSFrameAnimationSelection>& selections) noexcept {
  IOSWorldGeneration generation;
  uint64_t previousSourceId = 0;
  for(std::size_t index=0; index<selections.size(); ++index) {
    const auto& selection = selections[index];
    if(selection.sourceId==0 || !selection.selectedHandle ||
       selection.sourceId<=previousSourceId)
      return false;
    previousSourceId = selection.sourceId;

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

inline bool finalizeIOSFrameAnimationEvidence(
    IOSFrameAnimationEvidence& evidence) noexcept {
  std::sort(
      evidence.selections.begin(),evidence.selections.end(),
      [](const IOSFrameAnimationSelection& lhs,
         const IOSFrameAnimationSelection& rhs) noexcept {
        return lhs.sourceId<rhs.sourceId;
        });

  if(!hasCanonicalIOSFrameAnimationSelectionIdentities(evidence.selections))
    return false;

  std::size_t nonzero = 0;
  uint64_t sourceDigest = IOSFrameAnimationFNV1aOffset;
  uint64_t pairDigest = IOSFrameAnimationFNV1aOffset;
  for(const auto& selection:evidence.selections) {
    if(selection.frameOrdinal!=0)
      ++nonzero;
    sourceDigest = iosFrameAnimationFNV1aAppendWord(
        sourceDigest,selection.sourceId);
    pairDigest = iosFrameAnimationFNV1aAppendWord(
        pairDigest,selection.sourceId);
    pairDigest = iosFrameAnimationFNV1aAppendWord(
        pairDigest,selection.frameOrdinal);
    }

  evidence.admittedFrameOnly = evidence.selections.size();
  evidence.nonzeroFrameOrdinals = nonzero;
  evidence.sourceDigest = sourceDigest;
  evidence.pairDigest = pairDigest;
  return true;
  }

inline bool isCanonicalIOSFrameAnimationEvidence(
    const IOSFrameAnimationEvidence& evidence) noexcept {
  if(!hasCanonicalIOSFrameAnimationSelectionIdentities(evidence.selections))
    return false;

  std::size_t nonzero = 0;
  uint64_t sourceDigest = IOSFrameAnimationFNV1aOffset;
  uint64_t pairDigest = IOSFrameAnimationFNV1aOffset;
  for(const auto& selection:evidence.selections) {
    if(selection.frameOrdinal!=0)
      ++nonzero;
    sourceDigest = iosFrameAnimationFNV1aAppendWord(
        sourceDigest,selection.sourceId);
    pairDigest = iosFrameAnimationFNV1aAppendWord(
        pairDigest,selection.sourceId);
    pairDigest = iosFrameAnimationFNV1aAppendWord(
        pairDigest,selection.frameOrdinal);
    }
  return evidence.admittedFrameOnly==evidence.selections.size() &&
         evidence.nonzeroFrameOrdinals==nonzero &&
         evidence.sourceDigest==sourceDigest &&
         evidence.pairDigest==pairDigest;
  }
