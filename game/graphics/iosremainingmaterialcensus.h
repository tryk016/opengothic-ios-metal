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

inline constexpr std::size_t IOSRemainingMaterialCount = 5u;
inline constexpr std::size_t IOSRemainingMaterialKindCount = 7u;
inline constexpr std::size_t IOSRemainingMaterialModeCount = 4u;
inline constexpr std::size_t IOSRemainingMaterialCellCount =
    IOSRemainingMaterialCount*IOSRemainingMaterialKindCount*
    IOSRemainingMaterialModeCount;

struct IOSRemainingMaterialCensus final {
  std::array<uint64_t,IOSRemainingMaterialCellCount> cells{};
  std::array<uint64_t,IOSRemainingMaterialCount> totals{};
  uint64_t globalTotal = 0;

  constexpr bool operator==(
      const IOSRemainingMaterialCensus&) const noexcept = default;
  };

enum class IOSRemainingMaterialCensusResult : uint8_t {
  Ignored = 0,
  Recorded = 1,
  Invalid = 2,
  Overflow = 3,
  };

inline constexpr std::optional<std::size_t> iosRemainingMaterialIndex(
    Material::AlphaFunc alpha) noexcept {
  switch(alpha) {
    case Material::Water:       return 0u;
    case Material::Ghost:       return 1u;
    case Material::Multiply:    return 2u;
    case Material::Multiply2:   return 3u;
    case Material::Transparent: return 4u;
    case Material::Solid:
    case Material::AlphaTest:
    case Material::AdditiveLight:
      return std::nullopt;
    }
  return std::nullopt;
  }

inline constexpr IOSRemainingMaterialCensusResult
iosRecordRemainingMaterialCensus(
    IOSSceneSourceKind kind,
    std::optional<Material::AlphaFunc> alpha,
    IOSSceneTextureAnimationMode mode,
    IOSRemainingMaterialCensus& census) noexcept {
  const auto kindValue = static_cast<uint8_t>(kind);
  const auto modeValue = static_cast<uint8_t>(mode);
  if(kindValue>static_cast<uint8_t>(IOSSceneSourceKind::Unsupported) ||
     modeValue>static_cast<uint8_t>(
         IOSSceneTextureAnimationMode::FrameAndUv))
    return IOSRemainingMaterialCensusResult::Invalid;

  if(!alpha.has_value())
    return IOSRemainingMaterialCensusResult::Ignored;

  std::optional<std::size_t> material;
  switch(*alpha) {
    case Material::Water:       material = 0u; break;
    case Material::Ghost:       material = 1u; break;
    case Material::Multiply:    material = 2u; break;
    case Material::Multiply2:   material = 3u; break;
    case Material::Transparent: material = 4u; break;
    case Material::Solid:
    case Material::AlphaTest:
    case Material::AdditiveLight:
      return IOSRemainingMaterialCensusResult::Ignored;
    default:
      return IOSRemainingMaterialCensusResult::Invalid;
    }

  const std::size_t index =
      (*material*IOSRemainingMaterialKindCount+
       static_cast<std::size_t>(kindValue))*IOSRemainingMaterialModeCount+
      static_cast<std::size_t>(modeValue);
  if(census.cells[index]==std::numeric_limits<uint64_t>::max() ||
     census.totals[*material]==std::numeric_limits<uint64_t>::max() ||
     census.globalTotal==std::numeric_limits<uint64_t>::max())
    return IOSRemainingMaterialCensusResult::Overflow;

  IOSRemainingMaterialCensus next = census;
  ++next.cells[index];
  ++next.totals[*material];
  ++next.globalTotal;
  census = next;
  return IOSRemainingMaterialCensusResult::Recorded;
  }

inline constexpr bool iosFinalizeRemainingMaterialCensus(
    const IOSRemainingMaterialCensus& census,
    const std::array<uint64_t,IOSRemainingMaterialCount>& rawTotals) noexcept {
  uint64_t globalRaw = 0;
  uint64_t globalTable = 0;
  for(std::size_t material=0; material<IOSRemainingMaterialCount; ++material) {
    uint64_t materialTable = 0;
    const std::size_t first = material*IOSRemainingMaterialKindCount*
                              IOSRemainingMaterialModeCount;
    const std::size_t last = first+IOSRemainingMaterialKindCount*
                                  IOSRemainingMaterialModeCount;
    for(std::size_t cell=first; cell<last; ++cell) {
      if(census.cells[cell]>
         std::numeric_limits<uint64_t>::max()-materialTable)
        return false;
      materialTable += census.cells[cell];
    }
    if(materialTable!=census.totals[material] ||
       materialTable!=rawTotals[material] ||
       rawTotals[material]>
           std::numeric_limits<uint64_t>::max()-globalRaw ||
       materialTable>
           std::numeric_limits<uint64_t>::max()-globalTable)
      return false;
    globalRaw += rawTotals[material];
    globalTable += materialTable;
  }
  return globalRaw==globalTable && globalTable==census.globalTotal;
  }

struct IOSRemainingMaterialCensusDiagnosticCandidate final {
  IOSRemainingMaterialCensus census;
  std::array<uint64_t,IOSRemainingMaterialCount> rawTotals{};
  uint64_t generation = 0;
  uint64_t sequence = 0;
  bool valid = false;

  constexpr bool operator==(
      const IOSRemainingMaterialCensusDiagnosticCandidate&) const noexcept =
      default;
  };

inline constexpr IOSRemainingMaterialCensusDiagnosticCandidate
prepareIOSRemainingMaterialCensusDiagnosticCandidate(
    const IOSRemainingMaterialCensus& census,
    const std::array<uint64_t,IOSRemainingMaterialCount>& rawTotals,
    uint64_t generation,
    uint64_t sequence) noexcept {
  if(generation==0u || sequence==0u ||
     !iosFinalizeRemainingMaterialCensus(census,rawTotals))
    return {};
  return {census,rawTotals,generation,sequence,true};
  }

inline constexpr bool iosRemainingMaterialCensusCandidateAcceptsCommit(
    const IOSRemainingMaterialCensusDiagnosticCandidate& candidate,
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
