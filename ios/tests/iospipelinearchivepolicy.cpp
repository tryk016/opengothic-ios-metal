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
  assert(Archive::advanceFlushStateAfterPresent(warmClean,299u,false)==
         Archive::FlushDecision::None);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,300u,false)==
         Archive::FlushDecision::SettleClean);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,300u,false)!=
         Archive::FlushDecision::FlushDirty);
  Archive::settleCleanArchive(warmClean);
  assert(warmClean.attempts==0u);
  assert(warmClean.settled);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,301u,true)==
         Archive::FlushDecision::None);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,302u,true)==
         Archive::FlushDecision::None);

  assert(Archive::advanceFlushStateAfterPresent(warmClean,900u,true)==
         Archive::FlushDecision::FlushDirty);
  assert(warmClean.attempts==0u);
  assert(!warmClean.settled);
  assert(warmClean.phase==Archive::FlushPhase::DirtyActive);
  Archive::recordFlushResult(warmClean,true,true);
  assert(warmClean.attempts==1u);
  assert(!warmClean.settled);
  assert(warmClean.phase==Archive::FlushPhase::DirtyActive);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,901u,true)==
         Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(warmClean,true,true);
  assert(warmClean.attempts==2u);
  assert(!warmClean.settled);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,902u,true)==
         Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(warmClean,true,false);
  assert(warmClean.attempts==Archive::MaxFlushAttempts);
  assert(warmClean.settled);
  assert(warmClean.phase==Archive::FlushPhase::Clean);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,903u,true)==
         Archive::FlushDecision::FlushDirty);
  assert(warmClean.attempts==0u);
  Archive::recordFlushResult(warmClean,false,true);
  assert(warmClean.attempts==1u);
  assert(!warmClean.settled);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,904u,true)==
         Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(warmClean,false,true);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,905u,true)==
         Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(warmClean,false,true);
  assert(warmClean.attempts==Archive::MaxFlushAttempts);
  assert(warmClean.settled);
  assert(warmClean.phase==Archive::FlushPhase::DirtyExhausted);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,906u,true)==
         Archive::FlushDecision::None);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,907u,false)==
         Archive::FlushDecision::None);
  assert(warmClean.phase==Archive::FlushPhase::Clean);
  assert(Archive::advanceFlushStateAfterPresent(warmClean,908u,true)==
         Archive::FlushDecision::FlushDirty);
  assert(warmClean.attempts==0u);
  Archive::recordFlushResult(warmClean,true,false);
  assert(warmClean.phase==Archive::FlushPhase::Clean);

  Archive::FlushState coldDirty;
  assert(Archive::advanceFlushStateAfterPresent(coldDirty,299u,true)!=
         Archive::FlushDecision::FlushDirty);
  assert(Archive::advanceFlushStateAfterPresent(coldDirty,300u,true)==
         Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(coldDirty,true,false);
  assert(coldDirty.attempts==1u);
  assert(coldDirty.settled);
  assert(Archive::advanceFlushStateAfterPresent(coldDirty,301u,true)!=
         Archive::FlushDecision::FlushDirty);

  Archive::FlushState retryThenSuccess;
  assert(Archive::advanceFlushStateAfterPresent(
    retryThenSuccess,300u,true)==Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(retryThenSuccess,false,true);
  assert(!retryThenSuccess.settled);
  assert(Archive::advanceFlushStateAfterPresent(
    retryThenSuccess,301u,true)==Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(retryThenSuccess,false,true);
  assert(Archive::advanceFlushStateAfterPresent(
    retryThenSuccess,302u,true)==Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(retryThenSuccess,true,false);
  assert(retryThenSuccess.attempts==3u);
  assert(retryThenSuccess.settled);

  Archive::FlushState exhausted;
  for(uint64_t present=Archive::FirstFlushPresent;
      present<=Archive::LastFlushPresent; ++present) {
    assert(Archive::advanceFlushStateAfterPresent(
      exhausted,present,true)==Archive::FlushDecision::FlushDirty);
    Archive::recordFlushResult(exhausted,false,true);
    }
  assert(exhausted.attempts==Archive::MaxFlushAttempts);
  assert(exhausted.settled);
  assert(Archive::advanceFlushStateAfterPresent(
    exhausted,Archive::LastFlushPresent,true)!=
         Archive::FlushDecision::FlushDirty);
  assert(Archive::advanceFlushStateAfterPresent(
    exhausted,Archive::LastFlushPresent+1u,true)!=
         Archive::FlushDecision::FlushDirty);

  Archive::FlushState lateExhausted;
  assert(Archive::advanceFlushStateAfterPresent(
    lateExhausted,300u,false)==
         Archive::FlushDecision::SettleClean);
  Archive::settleCleanArchive(lateExhausted);
  for(uint64_t present=800u; present<803u; ++present) {
    assert(Archive::advanceFlushStateAfterPresent(
      lateExhausted,present,true)==Archive::FlushDecision::FlushDirty);
    Archive::recordFlushResult(lateExhausted,false,true);
    }
  assert(lateExhausted.attempts==Archive::MaxFlushAttempts);
  assert(lateExhausted.settled);
  assert(lateExhausted.phase==Archive::FlushPhase::DirtyExhausted);
  for(uint64_t present=803u; present<900u; ++present)
    assert(Archive::advanceFlushStateAfterPresent(
      lateExhausted,present,true)!=Archive::FlushDecision::FlushDirty);
  assert(lateExhausted.attempts==Archive::MaxFlushAttempts);
  assert(lateExhausted.phase==Archive::FlushPhase::DirtyExhausted);

  assert(Archive::advanceFlushStateAfterPresent(
    lateExhausted,900u,false)==Archive::FlushDecision::None);
  assert(lateExhausted.attempts==Archive::MaxFlushAttempts);
  assert(lateExhausted.settled);
  assert(lateExhausted.phase==Archive::FlushPhase::Clean);
  assert(Archive::advanceFlushStateAfterPresent(
    lateExhausted,901u,true)==Archive::FlushDecision::FlushDirty);
  assert(lateExhausted.attempts==0u);
  assert(!lateExhausted.settled);
  assert(lateExhausted.phase==Archive::FlushPhase::DirtyActive);
  Archive::recordFlushResult(lateExhausted,false,true);
  assert(lateExhausted.attempts==1u);

  Archive::FlushState outsideWindow;
  assert(Archive::advanceFlushStateAfterPresent(outsideWindow,0u,true)==
         Archive::FlushDecision::None);
  assert(Archive::advanceFlushStateAfterPresent(outsideWindow,299u,true)==
         Archive::FlushDecision::None);
  assert(Archive::advanceFlushStateAfterPresent(outsideWindow,303u,true)==
         Archive::FlushDecision::None);
  assert(outsideWindow.settled);
  assert(outsideWindow.phase==Archive::FlushPhase::DirtyExhausted);
  assert(Archive::advanceFlushStateAfterPresent(outsideWindow,304u,false)==
         Archive::FlushDecision::None);
  assert(outsideWindow.phase==Archive::FlushPhase::Clean);
  assert(Archive::advanceFlushStateAfterPresent(outsideWindow,305u,true)==
         Archive::FlushDecision::FlushDirty);

  Archive::FlushState confirmedAfterSuccess;
  assert(Archive::advanceFlushStateAfterPresent(
    confirmedAfterSuccess,300u,false)==Archive::FlushDecision::SettleClean);
  Archive::settleCleanArchive(confirmedAfterSuccess);
  assert(Archive::advanceFlushStateAfterPresent(
    confirmedAfterSuccess,700u,true)==Archive::FlushDecision::FlushDirty);
  Archive::recordFlushResult(confirmedAfterSuccess,true,false);
  assert(confirmedAfterSuccess.attempts==1u);
  assert(confirmedAfterSuccess.settled);
  assert(confirmedAfterSuccess.phase==Archive::FlushPhase::Clean);
  assert(Archive::advanceFlushStateAfterPresent(
    confirmedAfterSuccess,701u,true)==Archive::FlushDecision::FlushDirty);
  assert(confirmedAfterSuccess.attempts==0u);
  assert(confirmedAfterSuccess.phase==Archive::FlushPhase::DirtyActive);
  return 0;
  }
