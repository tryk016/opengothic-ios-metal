#include "iosshadingprototypetileprobe.h"

IOSShadingPrototypeTileProbeReport
    iosCanonicalShadingPrototypeTileProbeReport() noexcept {
  using namespace RendererIOSShadingPrototypeTileProbe;

  IOSShadingPrototypeTileProbeReport report;
  report.contractVersion = ContractVersion;
  report.borrowedExistingDevice = true;
  report.borrowedVirginCommandBuffer = true;
  report.supportsApple4 = true;
  report.pipelineReady = true;
  report.pipelineSameDevice = true;
  report.outputAvailable = true;
  report.outputSameDevice = true;
  report.outputType2D = true;
  report.outputRgba8Unorm = true;
  report.outputPrivate = true;
  report.outputExtentMatches = true;
  report.transparentBlackClear = true;
  report.encoded = true;
  report.physicalPasses = 1u;
  report.commandBuffers = 1u;
  report.withActiveCommandBufferCalls = 1u;
  report.renderEncoders = 1u;
  report.outputAttachments = 1u;
  report.outputAttachmentIndex = OutputAttachment;
  report.materialTextures = 0u;
  report.pipelineStates = 3u;
  report.vertexByteBindings = 1u;
  report.vertices = VertexCount;
  report.vertexBytes = VertexBytes;
  report.draws = 2u;
  report.opaqueDraws = 1u;
  report.alphaTestDraws = 1u;
  report.tileDispatches = 1u;
  report.imageblockBytesPerSample = ImageblockBytesPerSample;
  report.threadgroupMemoryLength = ThreadgroupMemoryLength;
  report.tileWidth = TileWidth;
  report.tileHeight = TileHeight;
  report.dispatchWidth = DispatchWidth;
  report.dispatchHeight = DispatchHeight;
  report.dispatchDepth = DispatchDepth;
  report.endEncodingCalls = 1u;
  report.computeEncoders = 0u;
  report.blitEncoders = 0u;
  report.helperDeviceCreations = 0u;
  report.helperQueueCreations = 0u;
  report.helperCommandBufferCreations = 0u;
  report.helperFenceCreations = 0u;
  report.helperResourceCreations = 0u;
  report.captureStarts = 0u;
  report.helperSubmits = 0u;
  report.helperCommits = 0u;
  report.helperWaits = 0u;
  report.drawableAcquisitions = 0u;
  report.presents = 0u;
  report.operationCount = 3u;
  report.operations = {
    IOSShadingPrototypeTileProbeOperation::DrawOpaque,
    IOSShadingPrototypeTileProbeOperation::DrawAlphaTest,
    IOSShadingPrototypeTileProbeOperation::DispatchTileLighting,
    };
  return report;
  }

bool iosShadingPrototypeTileProbeReportMatches(
    const IOSShadingPrototypeTileProbeReport& report) noexcept {
  return report==iosCanonicalShadingPrototypeTileProbeReport();
  }
