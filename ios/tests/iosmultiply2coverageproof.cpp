#include "graphics/iosmultiply2coverageproof.h"

#include <cassert>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace {

IOSMultiply2CoverageProofMetadata metadata() {
  IOSMultiply2CoverageProofMetadata value;
  value.width = 4u;
  value.height = 3u;
  value.bytesPerRow = 4u;
  value.sampleCount = 1u;
  value.payloadBytes = 12u;
  value.targetGeneration = 7u;
  value.snapshotSequence = 11u;
  value.sourceId = 13u;
  value.indexByteOffset = 16u;
  value.indexCount = 6u;
  value.viewport = {0u,0u,4u,3u};
  value.scissor = value.viewport;
  value.proofId[0] = 1u;
  value.buildSha[0] = 2u;
  return value;
}

}

int main() {
  const auto canonicalMetadata = metadata();
  std::vector<std::byte> payload(12u,std::byte{0});
  payload[5] = std::byte{1};
  std::vector<std::byte> artifact;
  assert(iosBuildMultiply2CoverageProofV1(
      canonicalMetadata,payload,artifact));
  assert(artifact.size()==IOSMultiply2CoverageProofV1HeaderBytes+12u);
  IOSMultiply2CoverageProofView view;
  assert(iosParseMultiply2CoverageProofV1(artifact,view)==
         IOSMultiply2CoverageProofError::None);
  assert(view.metadata.targetGeneration==7u);
  assert(view.metadata.snapshotSequence==11u);
  assert(view.metadata.sourceId==13u);
  assert(view.metadata.indexByteOffset==16u);
  assert(view.metadata.indexCount==6u);
  assert(view.payload.size()==payload.size());
  assert(std::equal(view.payload.begin(),view.payload.end(),payload.begin()));

  std::size_t killed = 0u;
  const auto reject = [&](std::vector<std::byte> mutant) {
    IOSMultiply2CoverageProofView rejected;
    assert(iosParseMultiply2CoverageProofV1(mutant,rejected)!=
           IOSMultiply2CoverageProofError::None);
    ++killed;
  };
  for(const std::size_t offset:{0u,8u,10u,12u,16u,20u,24u,28u,
                                32u,88u,104u,148u,152u}) {
    auto mutant = artifact;
    mutant[offset] ^= std::byte{0xff};
    reject(std::move(mutant));
  }
  for(const std::size_t offset:{40u,48u,56u,72u}) {
    auto mutant = artifact;
    std::fill_n(mutant.begin()+static_cast<std::ptrdiff_t>(offset),
                8u,std::byte{0});
    reject(std::move(mutant));
  }
  for(const auto [offset,length]:
      {std::pair<std::size_t,std::size_t>{112u,16u},{128u,20u}}) {
    auto mutant = artifact;
    std::fill_n(mutant.begin()+static_cast<std::ptrdiff_t>(offset),
                length,std::byte{0});
    reject(std::move(mutant));
  }
  {
    auto mutant = artifact;
    mutant[IOSMultiply2CoverageProofV1HeaderBytes+5u] = std::byte{2};
    reject(std::move(mutant));
  }
  {
    auto mutant = artifact;
    mutant.resize(mutant.size()-1u);
    reject(std::move(mutant));
  }
  {
    auto mutant = artifact;
    mutant.push_back(std::byte{0});
    reject(std::move(mutant));
  }
  {
    std::vector<std::byte> emptyCoverage(payload.size(),std::byte{0});
    std::vector<std::byte> rejected;
    assert(!iosBuildMultiply2CoverageProofV1(
        canonicalMetadata,emptyCoverage,rejected));
    ++killed;
  }
  assert(killed==23u);
  return 0;
}
