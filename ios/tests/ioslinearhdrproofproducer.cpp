#include "graphics/ioslinearhdrproofproducer.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <span>
#include <string_view>
#include <vector>

namespace {

[[noreturn]] void fail() {
  std::abort();
  }

void require(bool condition) {
  if(!condition)
    fail();
  }

void testStateMachine() {
  IOSLinearHDRProofProducerState state =
      IOSLinearHDRProofProducerState::Disabled;
  require(!iosAdvanceLinearHDRProofProducerState(
      state,IOSLinearHDRProofProducerEvent::Encode));
  require(state==IOSLinearHDRProofProducerState::Disabled);
  for(const auto transition : {
      IOSLinearHDRProofProducerEvent::Arm,
      IOSLinearHDRProofProducerEvent::Encode,
      IOSLinearHDRProofProducerEvent::Submit,
      IOSLinearHDRProofProducerEvent::Complete,
      IOSLinearHDRProofProducerEvent::Publish,
      })
    require(iosAdvanceLinearHDRProofProducerState(state,transition));
  require(state==IOSLinearHDRProofProducerState::Published);
  require(!iosAdvanceLinearHDRProofProducerState(
      state,IOSLinearHDRProofProducerEvent::Arm));
  require(!iosAdvanceLinearHDRProofProducerState(
      state,IOSLinearHDRProofProducerEvent::Fail));

  state = IOSLinearHDRProofProducerState::Disabled;
  require(iosAdvanceLinearHDRProofProducerState(
      state,IOSLinearHDRProofProducerEvent::Arm));
  require(iosAdvanceLinearHDRProofProducerState(
      state,IOSLinearHDRProofProducerEvent::Fail));
  require(state==IOSLinearHDRProofProducerState::Failed);
  require(!iosAdvanceLinearHDRProofProducerState(
      state,IOSLinearHDRProofProducerEvent::Arm));
  }

void testBuildSha() {
  constexpr std::string_view Sha =
      "0123456789abcdef0123456789abcdef01234567";
  std::array<uint8_t,20u> bytes{};
  require(iosLinearHDRProofParseBuildSha(Sha,bytes));
  require(bytes[0u]==0x01u && bytes[1u]==0x23u &&
          bytes[18u]==0x45u && bytes[19u]==0x67u);
  const auto before = bytes;
  require(!iosLinearHDRProofParseBuildSha("local",bytes));
  require(bytes==before);
  require(!iosLinearHDRProofParseBuildSha(
      "0123456789ABCDEF0123456789abcdef01234567",bytes));
  require(bytes==before);
  require(!iosLinearHDRProofParseBuildSha(
      "0000000000000000000000000000000000000000",bytes));
  require(bytes==before);
  }

IOSLinearHDRProofMetadata metadata() {
  IOSLinearHDRProofMetadata result;
  result.width = 2u;
  result.height = 2u;
  result.bytesPerRow = 8u;
  result.logicalBytes = 16u;
  result.targetGeneration = 7u;
  result.snapshotSequence = 9u;
  for(size_t index=0u; index<result.proofId.size(); ++index)
    result.proofId[index] = uint8_t(index+1u);
  require(iosLinearHDRProofParseBuildSha(
      "0123456789abcdef0123456789abcdef01234567",result.buildSha));
  return result;
  }

void testArtifactRoundTrip() {
  const IOSLinearHDRProofMetadata input = metadata();
  const std::array<std::byte,16u> payload{};
  std::vector<std::byte> artifact;
  require(iosLinearHDRProofBuildArtifactV1(input,payload,artifact));
  require(artifact.size()==IOSLinearHDRProofV1HeaderBytes+payload.size());

  IOSLinearHDRProofView parsed;
  require(iosParseLinearHDRProofV1(artifact,parsed)==
          IOSLinearHDRProofError::None);
  require(parsed.width==input.width && parsed.height==input.height &&
          parsed.bytesPerRow==input.bytesPerRow &&
          parsed.logicalBytes==input.logicalBytes &&
          parsed.targetGeneration==input.targetGeneration &&
          parsed.snapshotSequence==input.snapshotSequence &&
          parsed.proofId==input.proofId && parsed.buildSha==input.buildSha &&
          parsed.payload.size()==payload.size());
  IOSLinearHDRProofScan scan;
  require(iosScanLinearHDRProofV1(parsed,scan)==
          IOSLinearHDRProofError::None);
  require(scan.maximum==IOSLinearHDRRGB{0.f,0.f,0.f});

  std::array<char,255u> line{};
  require(iosLinearHDRProofFormatSuccessLine(input,line));
  require(std::string_view(line.data())==
      "RendererIOS HDR proof: v=1 id=0102030405060708090a0b0c0d0e0f10 b=0123456789abcdef0123456789abcdef01234567 g=7 s=9 w=2 h=2 row=8 bytes=16 f=r11 m=0 a=0 terminal=C");
  require(std::string_view(line.data()).size()<255u);

  IOSLinearHDRProofMetadata invalid = input;
  invalid.bytesPerRow = 4u;
  const std::vector<std::byte> before = artifact;
  require(!iosLinearHDRProofBuildArtifactV1(invalid,payload,artifact));
  require(artifact==before);
  const auto lineBefore = line;
  require(!iosLinearHDRProofFormatSuccessLine(invalid,line));
  require(line==lineBefore);
  }

void testFailureVocabulary() {
  struct Entry final {
    IOSLinearHDRProofFailureReason reason;
    IOSLinearHDRProofFailureClass failureClass;
    std::string_view name;
    };
  constexpr Entry entries[] = {
    {IOSLinearHDRProofFailureReason::Rng,
     IOSLinearHDRProofFailureClass::Contract,"rng"},
    {IOSLinearHDRProofFailureReason::RngZero,
     IOSLinearHDRProofFailureClass::Contract,"rng-zero"},
    {IOSLinearHDRProofFailureReason::Sha,
     IOSLinearHDRProofFailureClass::Contract,"sha"},
    {IOSLinearHDRProofFailureReason::Layout,
     IOSLinearHDRProofFailureClass::Contract,"layout"},
    {IOSLinearHDRProofFailureReason::State,
     IOSLinearHDRProofFailureClass::Contract,"state"},
    {IOSLinearHDRProofFailureReason::Target,
     IOSLinearHDRProofFailureClass::Contract,"target"},
    {IOSLinearHDRProofFailureReason::Label,
     IOSLinearHDRProofFailureClass::Contract,"label"},
    {IOSLinearHDRProofFailureReason::BufferAlloc,
     IOSLinearHDRProofFailureClass::Contract,"buffer-alloc"},
    {IOSLinearHDRProofFailureReason::BufferMap,
     IOSLinearHDRProofFailureClass::Contract,"buffer-map"},
    {IOSLinearHDRProofFailureReason::CopyEncode,
     IOSLinearHDRProofFailureClass::Gpu,"copy-encode"},
    {IOSLinearHDRProofFailureReason::SubmitAmbiguous,
     IOSLinearHDRProofFailureClass::Gpu,"submit-ambiguous"},
    {IOSLinearHDRProofFailureReason::Fence,
     IOSLinearHDRProofFailureClass::Gpu,"fence"},
    {IOSLinearHDRProofFailureReason::Idle,
     IOSLinearHDRProofFailureClass::Gpu,"idle"},
    {IOSLinearHDRProofFailureReason::Present,
     IOSLinearHDRProofFailureClass::Gpu,"present"},
    {IOSLinearHDRProofFailureReason::Stale,
     IOSLinearHDRProofFailureClass::Contract,"stale"},
    {IOSLinearHDRProofFailureReason::Parse,
     IOSLinearHDRProofFailureClass::Contract,"parse"},
    {IOSLinearHDRProofFailureReason::Open,
     IOSLinearHDRProofFailureClass::Io,"open"},
    {IOSLinearHDRProofFailureReason::Write,
     IOSLinearHDRProofFailureClass::Io,"write"},
    {IOSLinearHDRProofFailureReason::FileFsync,
     IOSLinearHDRProofFailureClass::Io,"file-fsync"},
    {IOSLinearHDRProofFailureReason::Close,
     IOSLinearHDRProofFailureClass::Io,"close"},
    {IOSLinearHDRProofFailureReason::Rename,
     IOSLinearHDRProofFailureClass::Io,"rename"},
    {IOSLinearHDRProofFailureReason::DirFsync,
     IOSLinearHDRProofFailureClass::Io,"dir-fsync"},
    {IOSLinearHDRProofFailureReason::Cleanup,
     IOSLinearHDRProofFailureClass::Io,"cleanup"},
    };
  for(const auto& entry:entries) {
    require(iosLinearHDRProofFailureClass(entry.reason)==entry.failureClass);
    require(std::string_view(
        iosLinearHDRProofFailureReasonName(entry.reason))==entry.name);
    }
  }

}

int main() {
  testStateMachine();
  testBuildSha();
  testArtifactRoundTrip();
  testFailureVocabulary();
  return 0;
  }
