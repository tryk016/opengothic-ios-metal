#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace RendererIOSPipelineArchive {

inline constexpr uint32_t CacheSchemaVersion    = 1u;
inline constexpr uint32_t PipelineKeyAbiVersion = 1u;
inline constexpr uint32_t MetallibAbiVersion    = 4u;
inline constexpr uint32_t ProvenanceSchemaVersion = 1u;

inline constexpr std::string_view RelativeDirectory =
    "RendererIOS/PipelineArchives/schema-1";
inline constexpr std::string_view ArchiveFileName =
    "RendererIOS-abi-4.binaryarchive";
inline constexpr std::string_view RelativeArchivePath =
    "RendererIOS/PipelineArchives/schema-1/RendererIOS-abi-4.binaryarchive";
inline constexpr std::string_view ProvenanceFileName =
    "RendererIOS-abi-4.provenance";

// Tempest::Log uses a 256-byte Context buffer including its terminator. Keep
// each marker strictly below 255 payload bytes even when monotonic uint64_t
// counters reach their full decimal width.
inline constexpr size_t LogMarkerPayloadLimit = 255u;
inline constexpr std::string_view ProvenancePolicyLogPrefix =
    "RendererIOS pipeline archive provenance-policy: configured=";
inline constexpr std::string_view SnapshotStateLogPrefix =
    "RendererIOS pipeline archive snapshot-state: point=";
inline constexpr std::string_view SnapshotRenderLogPrefix =
    "RendererIOS pipeline archive snapshot-render: point=";
inline constexpr std::string_view SnapshotComputeLogPrefix =
    "RendererIOS pipeline archive snapshot-compute: point=";
inline constexpr std::string_view SnapshotFlushLogPrefix =
    "RendererIOS pipeline archive snapshot-flush: point=";

inline constexpr std::string_view SnapshotStateWorstCase =
    "RendererIOS pipeline archive snapshot-state: point=post "
    "presents=18446744073709551615 abi=1 size=120 flags=63 schema=1 key=1 "
    "metallib=4 cfg=1 available=1 loaded=1 empty=1 dirty=1 disabled=1 "
    "load-fail=18446744073709551615 rebuild=18446744073709551615";
inline constexpr std::string_view SnapshotRenderWorstCase =
    "RendererIOS pipeline archive snapshot-render: point=post "
    "presents=18446744073709551615 hit=18446744073709551615 "
    "miss=18446744073709551615 add=18446744073709551615 "
    "fallback=18446744073709551615";
inline constexpr std::string_view SnapshotComputeWorstCase =
    "RendererIOS pipeline archive snapshot-compute: point=post "
    "presents=18446744073709551615 hit=18446744073709551615 "
    "miss=18446744073709551615 add=18446744073709551615 "
    "fallback=18446744073709551615";
inline constexpr std::string_view SnapshotFlushWorstCase =
    "RendererIOS pipeline archive snapshot-flush: point=post "
    "presents=18446744073709551615 attempt=18446744073709551615 "
    "success=18446744073709551615 fail=18446744073709551615 "
    "invoked=1 result=1 bounded=255 settled=1";
inline constexpr std::string_view ProvenancePolicyWorstCase =
    "RendererIOS pipeline archive provenance-policy: configured=1 schema=1 "
    "key=1 metallib=4 "
    "digest=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff "
    "stale-reset=1";

static_assert(SnapshotStateWorstCase.size()<LogMarkerPayloadLimit);
static_assert(SnapshotRenderWorstCase.size()<LogMarkerPayloadLimit);
static_assert(SnapshotComputeWorstCase.size()<LogMarkerPayloadLimit);
static_assert(SnapshotFlushWorstCase.size()<LogMarkerPayloadLimit);
static_assert(ProvenancePolicyWorstCase.size()<LogMarkerPayloadLimit);

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)

inline constexpr uint32_t TestModeAbiVersion = 1u;
inline constexpr std::array<std::string_view,3> TestModeDirectoryComponents = {
  "RendererIOS","PipelineArchives","schema-1",
  };

enum class TestMode : uint8_t {
  None,
  Cold,
  Corrupt,
  };

struct TestModeParseResult final {
  TestMode mode      = TestMode::None;
  bool     conflict  = false;
  bool     duplicate = false;
  bool     unknown   = false;

  constexpr bool valid() const noexcept {
    return !conflict && !duplicate && !unknown;
    }
  };

inline constexpr std::string_view TestModeArgumentPrefix =
    "-renderer-ios-pipeline-archive-";
inline constexpr std::string_view TestModeColdArgument =
    "-renderer-ios-pipeline-archive-cold";
inline constexpr std::string_view TestModeCorruptArgument =
    "-renderer-ios-pipeline-archive-corrupt";
inline constexpr std::string_view TestModeTemporaryFileName =
    "RendererIOS-abi-4.binaryarchive.test-mode.tmp";
inline constexpr std::string_view TestModeLogPrefix =
    "RendererIOS pipeline archive test-mode: mode=";

// This exact payload is deliberately not a Metal binary archive. Keep its
// bytes and digest stable so a host test and the device harness can prove that
// the app, rather than an out-of-process container mutation, exercised the
// corrupt-cache path.
inline constexpr std::string_view CorruptArchivePayload =
    "RendererIOS-D041-invalid-binary-archive-v1\n";
inline constexpr std::string_view CorruptArchivePayloadSha256 =
    "8386a739719ee835402af74a36bef9667a5e7ad2f630b8f3d5b1a4cd2c1e54fa";

inline constexpr std::string_view TestModeMarkerWorstCase =
    "RendererIOS pipeline archive test-mode: mode=corrupt applied=1 abi=1 "
    "bytes=18446744073709551615 removed-verified=1 write-verified=1 "
    "sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

static_assert(!CorruptArchivePayload.empty());
static_assert(TestModeMarkerWorstCase.size()<LogMarkerPayloadLimit);

constexpr TestModeParseResult parseTestMode(
    int argc, const char* const* argv) noexcept {
  unsigned coldCount    = 0u;
  unsigned corruptCount = 0u;
  bool     unknown      = false;
  if(argc>1 && argv!=nullptr) {
    for(int i=1; i<argc; ++i) {
      if(argv[i]==nullptr)
        continue;
      const std::string_view argument = argv[i];
      if(argument==TestModeColdArgument)
        ++coldCount;
      else if(argument==TestModeCorruptArgument)
        ++corruptCount;
      else if(argument.starts_with(TestModeArgumentPrefix))
        unknown = true;
      }
    }
  TestModeParseResult result;
  result.conflict  = coldCount>0u && corruptCount>0u;
  result.duplicate = coldCount>1u || corruptCount>1u;
  result.unknown   = unknown;
  if(result.valid()) {
    if(coldCount==1u)
      result.mode = TestMode::Cold;
    else if(corruptCount==1u)
      result.mode = TestMode::Corrupt;
    }
  return result;
  }

constexpr std::string_view testModeName(TestMode mode) noexcept {
  switch(mode) {
    case TestMode::None:    return "none";
    case TestMode::Cold:    return "cold";
    case TestMode::Corrupt: return "corrupt";
    }
  return "none";
  }

#endif

constexpr bool isLowercaseSha256(std::string_view digest) noexcept {
  if(digest.size()!=64u)
    return false;
  for(const char ch:digest) {
    const bool decimal = ch>='0' && ch<='9';
    const bool hex     = ch>='a' && ch<='f';
    if(!decimal && !hex)
      return false;
    }
  return true;
  }

inline std::string provenanceRecord(std::string_view metallibSha256) {
  if(!isLowercaseSha256(metallibSha256))
    return {};
  std::string record;
  record.reserve(256u);
  record += "renderer=RendererIOS\n";
  record += "provenance-schema=";
  record += std::to_string(ProvenanceSchemaVersion);
  record += "\ncache-schema=";
  record += std::to_string(CacheSchemaVersion);
  record += "\npipeline-key-abi=";
  record += std::to_string(PipelineKeyAbiVersion);
  record += "\nmetallib-abi=";
  record += std::to_string(MetallibAbiVersion);
  record += "\n";
  record += "metallib-sha256=";
  record += metallibSha256;
  record += "\narchive-file=RendererIOS-abi-4.binaryarchive\n";
  return record;
  }

inline bool provenanceMatches(
    std::string_view record, std::string_view metallibSha256) {
  const std::string expected = provenanceRecord(metallibSha256);
  return !expected.empty() && record==expected;
  }

struct FlushState final {
  uint8_t attempts = 0u;
  bool    settled  = false;
  };

inline constexpr uint64_t FirstFlushPresent = 300u;
inline constexpr uint8_t  MaxFlushAttempts  = 3u;
inline constexpr uint64_t LastFlushPresent =
    FirstFlushPresent+uint64_t(MaxFlushAttempts)-1u;

enum class FlushDecision : uint8_t {
  None,
  SettleClean,
  FlushDirty,
  };

constexpr FlushDecision flushDecisionAfterPresent(
    const FlushState& state, uint64_t successfulPresents,
    bool dirty) noexcept {
  if(state.settled ||
     state.attempts>=MaxFlushAttempts ||
     successfulPresents<FirstFlushPresent ||
     successfulPresents>LastFlushPresent)
    return FlushDecision::None;
  return dirty ? FlushDecision::FlushDirty
               : FlushDecision::SettleClean;
  }

constexpr bool shouldFlushAfterPresent(
    const FlushState& state, uint64_t successfulPresents,
    bool dirty) noexcept {
  return flushDecisionAfterPresent(
           state,successfulPresents,dirty)==
         FlushDecision::FlushDirty;
  }

constexpr void settleCleanArchive(FlushState& state) noexcept {
  state.settled = true;
  }

constexpr void recordFlushResult(
    FlushState& state, bool succeeded) noexcept {
  if(state.settled || state.attempts>=MaxFlushAttempts)
    return;
  state.attempts = static_cast<uint8_t>(state.attempts+1u);
  state.settled = succeeded || state.attempts>=MaxFlushAttempts;
  }

}
