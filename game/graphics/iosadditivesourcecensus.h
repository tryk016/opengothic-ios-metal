#pragma once

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)

#include "iossceneextractorplan.h"
#include "iosscenesource.h"
#include "material.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>

struct IOSAdditiveSourceCensus final {
  std::array<uint64_t,28> cells{};
  uint64_t                total = 0;

  constexpr bool operator==(const IOSAdditiveSourceCensus&) const noexcept =
      default;
  };

enum class IOSAdditiveCensusResult : uint8_t {
  Ignored = 0,
  Recorded = 1,
  Invalid = 2,
  Overflow = 3,
  };

inline constexpr IOSAdditiveCensusResult iosRecordAdditiveSourceCensus(
    IOSSceneSourceKind kind,
    std::optional<Material::AlphaFunc> alpha,
    IOSSceneTextureAnimationMode mode,
    IOSAdditiveSourceCensus& census) noexcept {
  const auto kindValue = static_cast<uint8_t>(kind);
  const auto modeValue = static_cast<uint8_t>(mode);
  if(kindValue>static_cast<uint8_t>(IOSSceneSourceKind::Unsupported) ||
     modeValue>static_cast<uint8_t>(
         IOSSceneTextureAnimationMode::FrameAndUv))
    return IOSAdditiveCensusResult::Invalid;

  if(!alpha.has_value())
    return IOSAdditiveCensusResult::Ignored;
  switch(*alpha) {
    case Material::Solid:
    case Material::AlphaTest:
    case Material::Water:
    case Material::Ghost:
    case Material::Multiply:
    case Material::Multiply2:
    case Material::Transparent:
      return IOSAdditiveCensusResult::Ignored;
    case Material::AdditiveLight:
      break;
    default:
      return IOSAdditiveCensusResult::Invalid;
    }

  const std::size_t index =
      static_cast<std::size_t>(kindValue)*4u+
      static_cast<std::size_t>(modeValue);
  if(census.cells[index]==std::numeric_limits<uint64_t>::max() ||
     census.total==std::numeric_limits<uint64_t>::max())
    return IOSAdditiveCensusResult::Overflow;

  IOSAdditiveSourceCensus next = census;
  ++next.cells[index];
  ++next.total;
  census = next;
  return IOSAdditiveCensusResult::Recorded;
  }

inline constexpr bool iosFinalizeAdditiveSourceCensus(
    const IOSAdditiveSourceCensus& census,
    uint64_t rawAdditiveLight) noexcept {
  uint64_t checkedTotal = 0;
  for(const uint64_t cell:census.cells) {
    if(cell>std::numeric_limits<uint64_t>::max()-checkedTotal)
      return false;
    checkedTotal += cell;
    }
  return checkedTotal==census.total && census.total==rawAdditiveLight;
  }

struct IOSAdditiveSourceCensusDiagnosticCandidate final {
  IOSAdditiveSourceCensus census;
  uint64_t                rawAdditiveLight = 0;
  uint64_t                generation = 0;
  uint64_t                sequence = 0;
  bool                    valid = false;

  constexpr bool operator==(
      const IOSAdditiveSourceCensusDiagnosticCandidate&) const noexcept =
      default;
  };

inline constexpr IOSAdditiveSourceCensusDiagnosticCandidate
prepareIOSAdditiveSourceCensusDiagnosticCandidate(
    const IOSAdditiveSourceCensus& census,
    uint64_t rawAdditiveLight,
    uint64_t generation,
    uint64_t sequence) noexcept {
  if(generation==0u || sequence==0u ||
     !iosFinalizeAdditiveSourceCensus(census,rawAdditiveLight))
    return {};
  return {census,rawAdditiveLight,generation,sequence,true};
  }

inline constexpr bool iosAdditiveSourceCensusCandidateAcceptsCommit(
    const IOSAdditiveSourceCensusDiagnosticCandidate& candidate,
    bool submitted,
    bool accepted,
    uint64_t preparedSerial,
    uint64_t serial,
    uint64_t generation,
    uint64_t sequence) noexcept {
  return candidate.valid && submitted && accepted &&
      preparedSerial!=0u && preparedSerial==serial &&
      candidate.generation==generation && candidate.sequence==sequence &&
      (sequence==1u || sequence%300u==0u);
  }

#endif
