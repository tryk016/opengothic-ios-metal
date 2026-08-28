#include "graphics/iosmultiply2coverageproof.h"

#include <cassert>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string_view>
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
  const auto classify = [](
      uint64_t production, uint64_t raster, uint64_t stencil,
      IOSMultiply2VisibilityClipClass clip, bool canonicalCoverage) {
    return iosClassifyMultiply2VisibilityDiagnostic(
        production,raster,stencil,static_cast<uint64_t>(clip),
        canonicalCoverage);
  };
  using Classification = IOSMultiply2VisibilityDiagnosticClass;
  using Clip = IOSMultiply2VisibilityClipClass;
  const std::array indeterminateTruthTable = {
      Classification::NonRasterizedUnknown,
      Classification::DiagnosticInvalid,
      Classification::AllDepthRejected,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::StencilWriteMissing,
      Classification::StencilBlitOrReadbackLoss,
  };
  const std::array outsideTruthTable = {
      Classification::DefinitelyOutsideFrustum,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
  };
  const std::array canonicalCoverageTruthTable = {
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::DiagnosticInvalid,
      Classification::CoverageResident,
  };
  for(uint64_t bits=0u; bits<8u; ++bits) {
    const uint64_t production = (bits&4u)!=0u ? 7u : 0u;
    const uint64_t raster = (bits&2u)!=0u ? 9u : 0u;
    const uint64_t stencil = (bits&1u)!=0u ? 11u : 0u;
    assert(classify(production,raster,stencil,Clip::Indeterminate,false).
               classification==indeterminateTruthTable[bits]);
    assert(classify(production,raster,stencil,Clip::Intersects,false).
               classification==indeterminateTruthTable[bits]);
    assert(classify(production,raster,stencil,Clip::DefinitelyOutside,false).
               classification==outsideTruthTable[bits]);
    assert(classify(production,raster,stencil,Clip::Indeterminate,true).
               classification==canonicalCoverageTruthTable[bits]);
    assert(classify(production,raster,stencil,Clip::Intersects,true).
               classification==canonicalCoverageTruthTable[bits]);
    assert(classify(production,raster,stencil,Clip::DefinitelyOutside,true).
               classification==Classification::DiagnosticInvalid);
  }
  assert(iosClassifyMultiply2VisibilityDiagnostic(
      IOSMultiply2VisibilityProductionSentinel,0u,0u,
      static_cast<uint64_t>(Clip::Indeterminate),false).classification==
         Classification::DiagnosticInvalid);
  assert(iosClassifyMultiply2VisibilityDiagnostic(
      0u,IOSMultiply2VisibilityRasterSentinel,0u,
      static_cast<uint64_t>(Clip::Indeterminate),false).classification==
         Classification::DiagnosticInvalid);
  assert(iosClassifyMultiply2VisibilityDiagnostic(
      0u,0u,IOSMultiply2VisibilityStencilSentinel,
      static_cast<uint64_t>(Clip::Indeterminate),false).classification==
         Classification::DiagnosticInvalid);
  assert(iosClassifyMultiply2VisibilityDiagnostic(
      0u,0u,0u,0u,false).classification==Classification::DiagnosticInvalid);
  assert(std::string_view(iosMultiply2VisibilityDiagnosticClassName(
      Classification::DefinitelyOutsideFrustum))==
         "definitely-outside-frustum");
  assert(std::string_view(iosMultiply2VisibilityDiagnosticClassName(
      Classification::NonRasterizedUnknown))=="non-rasterized-unknown");
  assert(std::string_view(iosMultiply2VisibilityDiagnosticClassName(
      Classification::AllDepthRejected))=="all-depth-rejected");
  assert(std::string_view(iosMultiply2VisibilityDiagnosticClassName(
      Classification::StencilWriteMissing))=="stencil-write-missing");
  assert(std::string_view(iosMultiply2VisibilityDiagnosticClassName(
      Classification::StencilBlitOrReadbackLoss))==
         "stencil-blit-or-readback-loss");
  assert(std::string_view(iosMultiply2VisibilityDiagnosticClassName(
      Classification::DiagnosticInvalid))=="diagnostic-invalid");
  assert(std::string_view(iosMultiply2VisibilityClipClassName(
      Clip::DefinitelyOutside))=="definitely-outside");

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
