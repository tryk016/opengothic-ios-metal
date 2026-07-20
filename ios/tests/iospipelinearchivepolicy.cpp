#define OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS 1
#include "graphics/iospipelinearchivepolicy.h"

#include <cassert>
#include <cstdint>
#include <string>
#include <string_view>

namespace Archive = RendererIOSPipelineArchive;

int main() {
  static_assert(Archive::CacheSchemaVersion==1u);
  static_assert(Archive::PipelineKeyAbiVersion==1u);
  static_assert(Archive::MetallibAbiVersion==4u);
  static_assert(Archive::ProvenanceSchemaVersion==1u);
  static_assert(Archive::TestModeAbiVersion==1u);
  static_assert(Archive::TestModeDirectoryComponents[0]=="RendererIOS");
  static_assert(Archive::TestModeDirectoryComponents[1]=="PipelineArchives");
  static_assert(Archive::TestModeDirectoryComponents[2]=="schema-1");
  static_assert(
    Archive::RelativeArchivePath==
    "RendererIOS/PipelineArchives/schema-1/"
    "RendererIOS-abi-4.binaryarchive");
  static_assert(Archive::FirstFlushPresent==300u);
  static_assert(Archive::MaxFlushAttempts==3u);
  static_assert(Archive::LastFlushPresent==302u);
  static_assert(Archive::LogMarkerPayloadLimit==255u);
  static_assert(Archive::SnapshotStateWorstCase.size()==249u);
  static_assert(Archive::SnapshotRenderWorstCase.size()==192u);
  static_assert(Archive::SnapshotComputeWorstCase.size()==193u);
  static_assert(Archive::SnapshotFlushWorstCase.size()==210u);
  static_assert(Archive::ProvenancePolicyWorstCase.size()==172u);
  static_assert(Archive::TestModeMarkerWorstCase.size()==203u);
  static_assert(Archive::TestModeTemporaryFileName==
    "RendererIOS-abi-4.binaryarchive.test-mode.tmp");
  static_assert(
    Archive::SnapshotStateWorstCase.size()<
    Archive::LogMarkerPayloadLimit);
  static_assert(
    Archive::SnapshotRenderWorstCase.size()<
    Archive::LogMarkerPayloadLimit);
  static_assert(
    Archive::SnapshotComputeWorstCase.size()<
    Archive::LogMarkerPayloadLimit);
  static_assert(
    Archive::SnapshotFlushWorstCase.size()<
    Archive::LogMarkerPayloadLimit);
  static_assert(
    Archive::ProvenancePolicyWorstCase.size()<
    Archive::LogMarkerPayloadLimit);
  static_assert(
    Archive::TestModeMarkerWorstCase.size()<
    Archive::LogMarkerPayloadLimit);

  static_assert(Archive::CorruptArchivePayload==
    "RendererIOS-D041-invalid-binary-archive-v1\n");
  static_assert(Archive::CorruptArchivePayload.size()==43u);
  static_assert(Archive::CorruptArchivePayloadSha256==
    "8386a739719ee835402af74a36bef9667a5e7ad2f630b8f3d5b1a4cd2c1e54fa");
  static_assert(Archive::isLowercaseSha256(
    Archive::CorruptArchivePayloadSha256));

  constexpr const char* noModeArgv[] = {
    "Gothic2Notr","-nomenu","-save","20",
    };
  constexpr auto noMode = Archive::parseTestMode(4,noModeArgv);
  static_assert(noMode.mode==Archive::TestMode::None);
  static_assert(noMode.valid());

  constexpr const char* coldArgv[] = {
    "Gothic2Notr","-renderer-ios-pipeline-archive-cold",
    };
  constexpr auto coldMode = Archive::parseTestMode(2,coldArgv);
  static_assert(coldMode.mode==Archive::TestMode::Cold);
  static_assert(coldMode.valid());

  constexpr const char* corruptArgv[] = {
    "Gothic2Notr","-renderer-ios-pipeline-archive-corrupt",
    };
  constexpr auto corruptMode = Archive::parseTestMode(2,corruptArgv);
  static_assert(corruptMode.mode==Archive::TestMode::Corrupt);
  static_assert(corruptMode.valid());

  constexpr const char* duplicateArgv[] = {
    "Gothic2Notr","-renderer-ios-pipeline-archive-cold",
    "-renderer-ios-pipeline-archive-cold",
    };
  constexpr auto duplicateMode = Archive::parseTestMode(3,duplicateArgv);
  static_assert(duplicateMode.mode==Archive::TestMode::None);
  static_assert(duplicateMode.duplicate);
  static_assert(!duplicateMode.valid());

  constexpr const char* conflictArgv[] = {
    "Gothic2Notr","-renderer-ios-pipeline-archive-corrupt",
    "-renderer-ios-pipeline-archive-cold",
    };
  constexpr auto conflictMode = Archive::parseTestMode(3,conflictArgv);
  static_assert(conflictMode.mode==Archive::TestMode::None);
  static_assert(conflictMode.conflict);
  static_assert(!conflictMode.valid());

  constexpr const char* inexactArgv[] = {
    "Gothic2Notr","renderer-ios-pipeline-archive-cold",
    "-renderer-ios-pipeline-archive-cold-extra",
    "-renderer-ios-pipeline-archive-none",
    };
  constexpr auto inexactMode = Archive::parseTestMode(4,inexactArgv);
  static_assert(inexactMode.mode==Archive::TestMode::None);
  static_assert(inexactMode.unknown);
  static_assert(!inexactMode.valid());
  static_assert(Archive::testModeName(Archive::TestMode::None)=="none");
  static_assert(Archive::testModeName(Archive::TestMode::Cold)=="cold");
  static_assert(Archive::testModeName(Archive::TestMode::Corrupt)=="corrupt");

  constexpr std::string_view digest =
    "0123456789abcdef0123456789abcdef"
    "0123456789abcdef0123456789abcdef";
  static_assert(Archive::isLowercaseSha256(digest));
  static_assert(!Archive::isLowercaseSha256("0123456789abcdef"));
  static_assert(!Archive::isLowercaseSha256(
    "0123456789ABCDEF0123456789abcdef"
    "0123456789abcdef0123456789abcdef"));
  static_assert(!Archive::isLowercaseSha256(
    "g123456789abcdef0123456789abcdef"
    "0123456789abcdef0123456789abcdef"));

  const std::string provenance = Archive::provenanceRecord(digest);
  assert(Archive::provenanceMatches(provenance,digest));
  assert(provenance.find("cache-schema=1\n")!=std::string::npos);
  assert(provenance.find("pipeline-key-abi=1\n")!=std::string::npos);
  assert(provenance.find("metallib-abi=4\n")!=std::string::npos);
  assert(provenance.find(
    "archive-file=RendererIOS-abi-4.binaryarchive\n")!=std::string::npos);
  const auto mutateField =
    [&provenance](std::string_view from, std::string_view to) {
      std::string mutated = provenance;
      const size_t offset = mutated.find(from);
      assert(offset!=std::string::npos);
      mutated.replace(offset,from.size(),to);
      return mutated;
      };
  assert(!Archive::provenanceMatches(
    mutateField("renderer=RendererIOS","renderer=Foreign"),digest));
  assert(!Archive::provenanceMatches(
    mutateField("provenance-schema=1","provenance-schema=2"),digest));
  assert(!Archive::provenanceMatches(
    mutateField("cache-schema=1","cache-schema=2"),digest));
  assert(!Archive::provenanceMatches(
    mutateField("pipeline-key-abi=1","pipeline-key-abi=2"),digest));
  assert(!Archive::provenanceMatches(
    mutateField("metallib-abi=4","metallib-abi=5"),digest));
  assert(!Archive::provenanceMatches(
    mutateField(
      "archive-file=RendererIOS-abi-4.binaryarchive",
      "archive-file=foreign.binaryarchive"),digest));
  assert(!Archive::provenanceMatches(provenance+"trailing-byte",digest));
  assert(!Archive::provenanceMatches(provenance,
    "1123456789abcdef0123456789abcdef"
    "0123456789abcdef0123456789abcdef"));
  assert(Archive::provenanceRecord("not-a-sha256").empty());

  Archive::FlushState warmClean;
  assert(Archive::flushDecisionAfterPresent(warmClean,299u,false)==
         Archive::FlushDecision::None);
  assert(Archive::flushDecisionAfterPresent(warmClean,300u,false)==
         Archive::FlushDecision::SettleClean);
  assert(!Archive::shouldFlushAfterPresent(warmClean,300u,false));
  Archive::settleCleanArchive(warmClean);
  assert(warmClean.attempts==0u);
  assert(warmClean.settled);
  assert(Archive::flushDecisionAfterPresent(warmClean,301u,true)==
         Archive::FlushDecision::None);

  Archive::FlushState coldDirty;
  assert(!Archive::shouldFlushAfterPresent(coldDirty,299u,true));
  assert(Archive::shouldFlushAfterPresent(coldDirty,300u,true));
  Archive::recordFlushResult(coldDirty,true);
  assert(coldDirty.attempts==1u);
  assert(coldDirty.settled);
  assert(!Archive::shouldFlushAfterPresent(coldDirty,301u,true));

  Archive::FlushState retryThenSuccess;
  assert(Archive::shouldFlushAfterPresent(retryThenSuccess,300u,true));
  Archive::recordFlushResult(retryThenSuccess,false);
  assert(!retryThenSuccess.settled);
  assert(Archive::shouldFlushAfterPresent(retryThenSuccess,301u,true));
  Archive::recordFlushResult(retryThenSuccess,false);
  assert(Archive::shouldFlushAfterPresent(retryThenSuccess,302u,true));
  Archive::recordFlushResult(retryThenSuccess,true);
  assert(retryThenSuccess.attempts==3u);
  assert(retryThenSuccess.settled);

  Archive::FlushState exhausted;
  for(uint64_t present=Archive::FirstFlushPresent;
      present<=Archive::LastFlushPresent; ++present) {
    assert(Archive::shouldFlushAfterPresent(exhausted,present,true));
    Archive::recordFlushResult(exhausted,false);
    }
  assert(exhausted.attempts==Archive::MaxFlushAttempts);
  assert(exhausted.settled);
  assert(!Archive::shouldFlushAfterPresent(
    exhausted,Archive::LastFlushPresent,true));
  assert(!Archive::shouldFlushAfterPresent(
    exhausted,Archive::LastFlushPresent+1u,true));

  Archive::FlushState outsideWindow;
  assert(Archive::flushDecisionAfterPresent(outsideWindow,0u,true)==
         Archive::FlushDecision::None);
  assert(Archive::flushDecisionAfterPresent(outsideWindow,299u,true)==
         Archive::FlushDecision::None);
  assert(Archive::flushDecisionAfterPresent(outsideWindow,303u,true)==
         Archive::FlushDecision::None);
  return 0;
  }
