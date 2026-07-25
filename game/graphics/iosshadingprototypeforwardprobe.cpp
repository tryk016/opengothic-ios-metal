#include "iosshadingprototypeforwardprobe.h"

#include <cstddef>
#include <type_traits>

namespace {

using namespace RendererIOSShadingPrototypeForwardProbe;
namespace Shader = RendererIOSShadingPrototypeShader;

static_assert(sizeof(uint32_t)==4u);
static_assert(sizeof(IOSShadingPrototypeForwardFailureReason)==4u);
static_assert(sizeof(IOSShadingPrototypeForwardProbeOperation)==4u);
static_assert(std::is_standard_layout_v<
              IOSShadingPrototypeForwardLightListReportV1>);
static_assert(std::is_standard_layout_v<
              IOSShadingPrototypeForwardProbeReportV1>);
static_assert(std::is_standard_layout_v<
              IOSShadingPrototypeForwardTerminalReportV1>);
static_assert(std::is_trivially_copyable_v<
              IOSShadingPrototypeForwardLightListReportV1>);
static_assert(std::is_trivially_copyable_v<
              IOSShadingPrototypeForwardProbeReportV1>);
static_assert(std::is_trivially_copyable_v<
              IOSShadingPrototypeForwardTerminalReportV1>);

constexpr uint32_t value(
    IOSShadingPrototypeForwardFailureReason reason) noexcept {
  return static_cast<uint32_t>(reason);
  }

constexpr uint32_t value(
    IOSShadingPrototypeForwardProbeOperation operation) noexcept {
  return static_cast<uint32_t>(operation);
  }

template<class Report>
bool validPrefix(const Report& report,
                 uint32_t knownFlags) noexcept {
  return report.abiVersion==ABIVersion &&
         report.structSize==sizeof(Report) &&
         (report.flags&~knownFlags)==0u &&
         report.failureReason<
             value(IOSShadingPrototypeForwardFailureReason::Count);
  }

}

IOSShadingPrototypeForwardLightListReportV1
    iosCanonicalShadingPrototypeForwardLightListReportV1() noexcept {
  using namespace RendererIOSShadingPrototypeForwardProbe;
  namespace Shader = RendererIOSShadingPrototypeShader;

  IOSShadingPrototypeForwardLightListReportV1 report;
  report.abiVersion = ABIVersion;
  report.structSize = sizeof(report);
  report.flags = LightListKnownFlagsMask;
  report.failureReason =
      value(IOSShadingPrototypeForwardFailureReason::None);
  report.byteSize = Shader::ForwardLightListByteSize;
  report.wordBytes = Shader::ForwardLightListWordBytes;
  report.wordCount = Shader::ForwardLightListWordCount;
  report.requestedStorageMode = StorageModeShared;
  report.requestedHazardTrackingMode =
      HazardTrackingModeTracked;
  report.bindingOffset = LightListOffset;
  report.observedByteSize = Shader::ForwardLightListByteSize;
  report.observedStorageMode = StorageModeShared;
  report.observedHazardTrackingMode =
      HazardTrackingModeTracked;
  report.prefillAttempted = 1u;
  report.prefilledWords = Shader::ForwardLightListWordCount;
  report.prefillVerifiedWords =
      Shader::ForwardLightListWordCount;
  report.sentinelWords = Shader::ForwardLightListWordCount;
  report.sentinelValue = Shader::ForwardLightListSentinel;
  report.contentsAvailable = 1u;
  report.sameDevice = 1u;
  report.ownerCreatedDelta = 1u;
  report.ownerLiveDelta = 1u;
  return report;
  }

IOSShadingPrototypeForwardProbeReportV1
    iosCanonicalShadingPrototypeForwardProbeReportV1() noexcept {
  using namespace RendererIOSShadingPrototypeForwardProbe;
  namespace Shader = RendererIOSShadingPrototypeShader;

  IOSShadingPrototypeForwardProbeReportV1 report;
  report.abiVersion = ABIVersion;
  report.structSize = sizeof(report);
  report.flags = ProbeKnownFlagsMask;
  report.failureReason =
      value(IOSShadingPrototypeForwardFailureReason::None);
  report.borrowedExistingDevice = 1u;
  report.borrowedInactiveCommandBuffer = 1u;
  report.supportsApple4 = 1u;
  report.pipelineReady = 1u;
  report.factoryReady = 1u;
  report.actualReflectionAvailable = 1u;
  report.computeBindingExact = 1u;
  report.vertexBindingExact = 1u;
  report.fragmentBindingExact = 1u;
  report.pipelineSameDevice = 1u;
  report.sameDeviceAllPipelines = 1u;
  report.sameDeviceAllResources = 1u;
  report.outputAvailable = 1u;
  report.outputSameDevice = 1u;
  report.outputType2D = 1u;
  report.outputRgba8Unorm = 1u;
  report.outputPrivate = 1u;
  report.outputExtentMatches = 1u;
  report.outputWidth = OutputWidth;
  report.outputHeight = OutputHeight;
  report.outputMipLevels = OutputMipLevels;
  report.outputSampleCount = OutputSampleCount;
  report.outputLoadClear = 1u;
  report.outputStoreStore = 1u;
  report.outputClearStore = 1u;
  report.transparentBlackClear = 1u;
  report.outputAttachments = 1u;
  report.outputAttachmentIndex = OutputAttachment;
  report.sampleCountOne = 1u;
  report.lightListAvailable = 1u;
  report.lightListSameDevice = 1u;
  report.lightListShared = 1u;
  report.lightListTracked = 1u;
  report.lightListByteSize = Shader::ForwardLightListByteSize;
  report.lightListOffset = LightListOffset;
  report.encoded = 1u;
  report.physicalPasses = 2u;
  report.commandBuffers = 1u;
  report.commandBufferRetainedReferencesDisabled = 1u;
  report.withActiveCommandBufferCalls = 1u;
  report.computeEncoders = 1u;
  report.renderEncoders = 1u;
  report.computeBufferBindings = 1u;
  report.computeBufferIndex =
      Shader::ForwardLightListBuffer;
  report.computeBufferOffset = LightListOffset;
  report.computePipelineBinds = 1u;
  report.fragmentBufferBindings = 1u;
  report.fragmentBufferIndex =
      Shader::ForwardLightListBuffer;
  report.fragmentBufferOffset = LightListOffset;
  report.vertexBufferIndex =
      RendererIOSShadingPrototypeForwardPipeline::
          VertexBufferIndex;
  report.opaquePipelineBinds = 1u;
  report.alphaTestPipelineBinds = 1u;
  report.pipelineStates = 3u;
  report.vertexByteBindings = 1u;
  report.vertices = VertexCount;
  report.vertexBytes = VertexBytes;
  report.vertexStride = VertexStride;
  report.primitiveTriangle = 1u;
  report.dispatches = 1u;
  report.gridWidth = Shader::ForwardLightListGridWidth;
  report.gridHeight = Shader::ForwardLightListGridHeight;
  report.gridDepth = Shader::ForwardLightListGridDepth;
  report.threadsPerThreadgroupWidth =
      Shader::ForwardLightListThreadsPerThreadgroupWidth;
  report.threadsPerThreadgroupHeight =
      Shader::ForwardLightListThreadsPerThreadgroupHeight;
  report.threadsPerThreadgroupDepth =
      Shader::ForwardLightListThreadsPerThreadgroupDepth;
  report.draws = 2u;
  report.opaqueDraws = 1u;
  report.alphaTestDraws = 1u;
  report.opaqueVertexStart = OpaqueVertexStart;
  report.opaqueVertexCount = TriangleVertexCount;
  report.alphaTestVertexStart = AlphaTestVertexStart;
  report.alphaTestVertexCount = TriangleVertexCount;
  report.endEncodingCalls = 2u;
  report.computeEndedBeforeRender = 1u;
  report.renderEnded = 1u;
  report.computePipelineLabelMatches = 1u;
  report.opaquePipelineLabelMatches = 1u;
  report.alphaTestPipelineLabelMatches = 1u;
  report.computeEncoderLabelMatches = 1u;
  report.renderEncoderLabelMatches = 1u;
  report.operationCount =
      value(IOSShadingPrototypeForwardProbeOperation::Count);
  report.operations = {
    value(IOSShadingPrototypeForwardProbeOperation::BuildLightList),
    value(IOSShadingPrototypeForwardProbeOperation::DrawOpaque),
    value(IOSShadingPrototypeForwardProbeOperation::DrawAlphaTest),
    };
  return report;
  }

IOSShadingPrototypeForwardTerminalReportV1
    iosCanonicalShadingPrototypeForwardTerminalReportV1() noexcept {
  using namespace RendererIOSShadingPrototypeForwardProbe;
  namespace Shader = RendererIOSShadingPrototypeShader;

  IOSShadingPrototypeForwardTerminalReportV1 report;
  report.abiVersion = ABIVersion;
  report.structSize = sizeof(report);
  report.flags = TerminalKnownFlagsMask;
  report.failureReason =
      value(IOSShadingPrototypeForwardFailureReason::None);
  report.submittedCommandBuffers = 1u;
  report.submitCalls = 1u;
  report.terminalFenceWaitCalls = 1u;
  report.terminalFenceCompleted = 1u;
  report.terminalFenceZeroTimeoutCalls = 1u;
  report.terminalFenceMonotonic = 1u;
  report.terminalFenceMonotonicDeadlineUsed = 1u;
  report.directContentsAvailable = 1u;
  report.readbackCalls = 1u;
  report.readbackOffset = LightListOffset;
  report.readbackBytes = Shader::ForwardLightListByteSize;
  report.readbackWords = Shader::ForwardLightListWordCount;
  report.firstWord = Shader::ForwardLightListActiveValue;
  report.activeWords = 1u;
  report.inactiveWords =
      Shader::ForwardLightListWordCount-1u;
  report.exactResult = 1u;
  report.lightListLifetimeRetained = 1u;
  report.outputLifetimeRetained = 1u;
  report.commandBufferRetainedReferencesDisabledContract = 1u;
  report.outputCreatedDelta = 1u;
  report.outputReleasedDelta = 1u;
  report.lightListCreatedDelta = 1u;
  report.lightListReleasedDelta = 1u;
  report.releaseOrderExact = 1u;
  report.pipelineLiveAtTerminal = 1u;
  report.pipelineReleasedAfterTerminal = 1u;
  report.outputLiveAtTerminal = 1u;
  report.outputReleasedAfterTerminal = 1u;
  report.lightListLiveAtTerminal = 1u;
  report.lightListReleasedAfterTerminal = 1u;
  report.commandBufferLiveAtTerminal = 1u;
  report.commandBufferReleasedAfterTerminal = 1u;
  report.captureOwnerInitializedAtTerminal = 1u;
  report.captureArtifactRetainedAtTerminal = 1u;
  report.captureOwnerReleasedAfterTerminal = 1u;
  report.fenceLiveAtTerminal = 1u;
  report.fenceReleasedAfterTerminal = 1u;
  report.captureAcquisitionCalls = 1u;
  return report;
  }

bool iosValidateShadingPrototypeForwardLightListReportV1(
    const IOSShadingPrototypeForwardLightListReportV1& report) noexcept {
  using namespace RendererIOSShadingPrototypeForwardProbe;
  return validPrefix(report,LightListKnownFlagsMask) &&
         report==iosCanonicalShadingPrototypeForwardLightListReportV1();
  }

bool iosValidateShadingPrototypeForwardProbeReportV1(
    const IOSShadingPrototypeForwardProbeReportV1& report) noexcept {
  using namespace RendererIOSShadingPrototypeForwardProbe;
  return validPrefix(report,ProbeKnownFlagsMask) &&
         report==iosCanonicalShadingPrototypeForwardProbeReportV1();
  }

bool iosValidateShadingPrototypeForwardTerminalReportV1(
    const IOSShadingPrototypeForwardTerminalReportV1& report) noexcept {
  using namespace RendererIOSShadingPrototypeForwardProbe;
  if(!validPrefix(report,TerminalKnownFlagsMask) ||
     report.terminalFenceWaitCalls==0u ||
     report.terminalFenceWaitCalls>TerminalFenceMaximumPolls ||
     report.terminalFenceZeroTimeoutCalls!=
         report.terminalFenceWaitCalls ||
     report.terminalFenceNonterminalPolls!=
         report.terminalFenceWaitCalls-1u ||
     report.terminalFenceMonotonic!=1u)
    return false;
  IOSShadingPrototypeForwardTerminalReportV1 normalized = report;
  normalized.terminalFenceWaitCalls = 1u;
  normalized.terminalFenceZeroTimeoutCalls = 1u;
  normalized.terminalFenceNonterminalPolls = 0u;
  return normalized==
      iosCanonicalShadingPrototypeForwardTerminalReportV1();
  }

bool iosShadingPrototypeForwardLightListContentsMatch(
    const std::array<
        uint32_t,
        RendererIOSShadingPrototypeShader::ForwardLightListWordCount>&
        words) noexcept {
  namespace Shader = RendererIOSShadingPrototypeShader;
  if(words[0]!=Shader::ForwardLightListActiveValue)
    return false;
  for(std::size_t index=1u; index<words.size(); ++index) {
    if(words[index]!=Shader::ForwardLightListInactiveValue)
      return false;
    }
  return true;
  }
