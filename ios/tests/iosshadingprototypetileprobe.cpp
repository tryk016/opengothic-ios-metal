#include "graphics/iosshadingprototypetileprobe.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace {

using Report = IOSShadingPrototypeTileProbeReport;
using Operation = IOSShadingPrototypeTileProbeOperation;
using Mutator = void (*)(Report&) noexcept;

void contractVersion(Report& report) noexcept {
  ++report.contractVersion;
  }

#define RIOS_BOOL_MUTATOR(name)                 \
  void name(Report& report) noexcept {           \
    report.name = !report.name;                  \
    }

RIOS_BOOL_MUTATOR(borrowedExistingDevice)
RIOS_BOOL_MUTATOR(borrowedVirginCommandBuffer)
RIOS_BOOL_MUTATOR(supportsApple4)
RIOS_BOOL_MUTATOR(pipelineReady)
RIOS_BOOL_MUTATOR(pipelineSameDevice)
RIOS_BOOL_MUTATOR(outputAvailable)
RIOS_BOOL_MUTATOR(outputSameDevice)
RIOS_BOOL_MUTATOR(outputType2D)
RIOS_BOOL_MUTATOR(outputRgba8Unorm)
RIOS_BOOL_MUTATOR(outputPrivate)
RIOS_BOOL_MUTATOR(outputExtentMatches)
RIOS_BOOL_MUTATOR(transparentBlackClear)
RIOS_BOOL_MUTATOR(encoded)

#undef RIOS_BOOL_MUTATOR

#define RIOS_COUNTER_MUTATOR(name)              \
  void name(Report& report) noexcept {           \
    ++report.name;                               \
    }

RIOS_COUNTER_MUTATOR(physicalPasses)
RIOS_COUNTER_MUTATOR(commandBuffers)
RIOS_COUNTER_MUTATOR(withActiveCommandBufferCalls)
RIOS_COUNTER_MUTATOR(renderEncoders)
RIOS_COUNTER_MUTATOR(outputAttachments)
RIOS_COUNTER_MUTATOR(outputAttachmentIndex)
RIOS_COUNTER_MUTATOR(materialTextures)
RIOS_COUNTER_MUTATOR(pipelineStates)
RIOS_COUNTER_MUTATOR(vertexByteBindings)
RIOS_COUNTER_MUTATOR(vertices)
RIOS_COUNTER_MUTATOR(vertexBytes)
RIOS_COUNTER_MUTATOR(draws)
RIOS_COUNTER_MUTATOR(opaqueDraws)
RIOS_COUNTER_MUTATOR(alphaTestDraws)
RIOS_COUNTER_MUTATOR(tileDispatches)
RIOS_COUNTER_MUTATOR(imageblockBytesPerSample)
RIOS_COUNTER_MUTATOR(threadgroupMemoryLength)
RIOS_COUNTER_MUTATOR(tileWidth)
RIOS_COUNTER_MUTATOR(tileHeight)
RIOS_COUNTER_MUTATOR(dispatchWidth)
RIOS_COUNTER_MUTATOR(dispatchHeight)
RIOS_COUNTER_MUTATOR(dispatchDepth)
RIOS_COUNTER_MUTATOR(endEncodingCalls)
RIOS_COUNTER_MUTATOR(computeEncoders)
RIOS_COUNTER_MUTATOR(blitEncoders)
RIOS_COUNTER_MUTATOR(helperDeviceCreations)
RIOS_COUNTER_MUTATOR(helperQueueCreations)
RIOS_COUNTER_MUTATOR(helperCommandBufferCreations)
RIOS_COUNTER_MUTATOR(helperFenceCreations)
RIOS_COUNTER_MUTATOR(helperResourceCreations)
RIOS_COUNTER_MUTATOR(captureStarts)
RIOS_COUNTER_MUTATOR(helperSubmits)
RIOS_COUNTER_MUTATOR(helperCommits)
RIOS_COUNTER_MUTATOR(helperWaits)
RIOS_COUNTER_MUTATOR(drawableAcquisitions)
RIOS_COUNTER_MUTATOR(presents)
RIOS_COUNTER_MUTATOR(operationCount)

#undef RIOS_COUNTER_MUTATOR

void operationOrder(Report& report) noexcept {
  report.operations[0] = Operation::DispatchTileLighting;
  }

constexpr std::array<Mutator,52u> Mutators = {
  contractVersion,
  borrowedExistingDevice,
  borrowedVirginCommandBuffer,
  supportsApple4,
  pipelineReady,
  pipelineSameDevice,
  outputAvailable,
  outputSameDevice,
  outputType2D,
  outputRgba8Unorm,
  outputPrivate,
  outputExtentMatches,
  transparentBlackClear,
  encoded,
  physicalPasses,
  commandBuffers,
  withActiveCommandBufferCalls,
  renderEncoders,
  outputAttachments,
  outputAttachmentIndex,
  materialTextures,
  pipelineStates,
  vertexByteBindings,
  vertices,
  vertexBytes,
  draws,
  opaqueDraws,
  alphaTestDraws,
  tileDispatches,
  imageblockBytesPerSample,
  threadgroupMemoryLength,
  tileWidth,
  tileHeight,
  dispatchWidth,
  dispatchHeight,
  dispatchDepth,
  endEncodingCalls,
  computeEncoders,
  blitEncoders,
  helperDeviceCreations,
  helperQueueCreations,
  helperCommandBufferCreations,
  helperFenceCreations,
  helperResourceCreations,
  captureStarts,
  helperSubmits,
  helperCommits,
  helperWaits,
  drawableAcquisitions,
  presents,
  operationCount,
  operationOrder,
  };

bool rejectsMutations() noexcept {
  for(const Mutator mutate:Mutators) {
    Report report = iosCanonicalShadingPrototypeTileProbeReport();
    mutate(report);
    if(iosShadingPrototypeTileProbeReportMatches(report))
      return false;
    }
  return true;
  }

}

int main() {
  using namespace RendererIOSShadingPrototypeTileProbe;

  static_assert(ContractVersion==1u);
  static_assert(MinimumAppleGPUFamily==4u);
  static_assert(OutputWidth==4u);
  static_assert(OutputHeight==4u);
  static_assert(OutputAttachment==0u);
  static_assert(ImageblockBytesPerSample==4u);
  static_assert(ThreadgroupMemoryLength==0u);
  static_assert(TileWidth==16u);
  static_assert(TileHeight==16u);
  static_assert(DispatchWidth==16u);
  static_assert(DispatchHeight==16u);
  static_assert(DispatchDepth==1u);
  static_assert(VertexStride==28u);
  static_assert(VertexCount==6u);
  static_assert(VertexBytes==168u);
  static_assert(static_cast<uint8_t>(Operation::DrawOpaque)==0u);
  static_assert(static_cast<uint8_t>(Operation::DrawAlphaTest)==1u);
  static_assert(static_cast<uint8_t>(
                    Operation::DispatchTileLighting)==2u);
  static_assert(std::is_aggregate_v<Report>);
  static_assert(std::is_trivially_copyable_v<Report>);
  static_assert(std::is_standard_layout_v<Report>);
  static_assert(sizeof(Operation)==1u);
  static_assert(alignof(Operation)==1u);
  static_assert(sizeof(Report)==172u);
  static_assert(alignof(Report)==4u);
  static_assert(offsetof(Report,contractVersion)==0u);
  static_assert(offsetof(Report,borrowedExistingDevice)==4u);
  static_assert(offsetof(Report,encoded)==16u);
  static_assert(offsetof(Report,physicalPasses)==20u);
  static_assert(offsetof(Report,materialTextures)==44u);
  static_assert(offsetof(Report,vertices)==56u);
  static_assert(offsetof(Report,imageblockBytesPerSample)==80u);
  static_assert(offsetof(Report,helperDeviceCreations)==120u);
  static_assert(offsetof(Report,helperSubmits)==144u);
  static_assert(offsetof(Report,operationCount)==164u);
  static_assert(offsetof(Report,operations)==168u);
  static_assert(Mutators.size()==52u);

  const Report report = iosCanonicalShadingPrototypeTileProbeReport();
  const std::array<Operation,3u> operations = {
    Operation::DrawOpaque,
    Operation::DrawAlphaTest,
    Operation::DispatchTileLighting,
    };
  if(!iosShadingPrototypeTileProbeReportMatches(report) ||
     report.contractVersion!=ContractVersion ||
     !report.borrowedExistingDevice ||
     !report.borrowedVirginCommandBuffer ||
     !report.supportsApple4 ||
     !report.pipelineReady ||
     !report.pipelineSameDevice ||
     !report.outputAvailable ||
     !report.outputSameDevice ||
     !report.outputType2D ||
     !report.outputRgba8Unorm ||
     !report.outputPrivate ||
     !report.outputExtentMatches ||
     !report.transparentBlackClear ||
     !report.encoded ||
     report.physicalPasses!=1u ||
     report.commandBuffers!=1u ||
     report.withActiveCommandBufferCalls!=1u ||
     report.renderEncoders!=1u ||
     report.outputAttachments!=1u ||
     report.outputAttachmentIndex!=OutputAttachment ||
     report.materialTextures!=0u ||
     report.pipelineStates!=3u ||
     report.vertexByteBindings!=1u ||
     report.vertices!=VertexCount ||
     report.vertexBytes!=VertexBytes ||
     report.draws!=2u ||
     report.opaqueDraws!=1u ||
     report.alphaTestDraws!=1u ||
     report.tileDispatches!=1u ||
     report.imageblockBytesPerSample!=ImageblockBytesPerSample ||
     report.threadgroupMemoryLength!=ThreadgroupMemoryLength ||
     report.tileWidth!=TileWidth ||
     report.tileHeight!=TileHeight ||
     report.dispatchWidth!=DispatchWidth ||
     report.dispatchHeight!=DispatchHeight ||
     report.dispatchDepth!=DispatchDepth ||
     report.endEncodingCalls!=1u ||
     report.computeEncoders!=0u ||
     report.blitEncoders!=0u ||
     report.helperDeviceCreations!=0u ||
     report.helperQueueCreations!=0u ||
     report.helperCommandBufferCreations!=0u ||
     report.helperFenceCreations!=0u ||
     report.helperResourceCreations!=0u ||
     report.captureStarts!=0u ||
     report.helperSubmits!=0u ||
     report.helperCommits!=0u ||
     report.helperWaits!=0u ||
     report.drawableAcquisitions!=0u ||
     report.presents!=0u ||
     report.operationCount!=operations.size() ||
     report.operations!=operations ||
     !rejectsMutations())
    return 1;
  return 0;
  }
