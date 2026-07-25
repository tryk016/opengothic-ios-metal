#pragma once

#include "iosshadingprototypeforwardpipeline.h"
#include "iosshadingprototypeshaderabi.h"

#include <array>
#include <cstdint>
#include <memory>
#include <string_view>

namespace Tempest {
class CommandBuffer;
class Device;
template<class T>
class Encoder;
}

class IOSMetalResourceTexture;
namespace RendererIOSShadingPrototypeForwardProbe {

inline constexpr uint32_t ABIVersion = 1u;
inline constexpr uint32_t MinimumAppleGPUFamily = 4u;
inline constexpr uint32_t OutputWidth = 4u;
inline constexpr uint32_t OutputHeight = 4u;
inline constexpr uint32_t OutputMipLevels = 1u;
inline constexpr uint32_t OutputSampleCount = 1u;
inline constexpr uint32_t OutputAttachment = 0u;
inline constexpr uint32_t VertexStride = 28u;
inline constexpr uint32_t VertexCount = 6u;
inline constexpr uint32_t VertexBytes = VertexStride*VertexCount;
inline constexpr uint32_t OpaqueVertexStart = 0u;
inline constexpr uint32_t AlphaTestVertexStart = 3u;
inline constexpr uint32_t TriangleVertexCount = 3u;
inline constexpr uint32_t LightListOffset = 0u;
inline constexpr uint32_t TerminalFenceMaximumPolls = 120u;
inline constexpr uint32_t TerminalFenceDeadlineMilliseconds =
    30000u;

inline constexpr uint32_t StorageModeShared = 1u;
inline constexpr uint32_t HazardTrackingModeTracked = 1u;

inline constexpr std::string_view ComputePipelineLabel =
    RendererIOSShadingPrototypeForwardPipeline::ComputePipelineLabel;
inline constexpr std::string_view OpaquePipelineLabel =
    RendererIOSShadingPrototypeForwardPipeline::OpaquePipelineLabel;
inline constexpr std::string_view AlphaTestPipelineLabel =
    RendererIOSShadingPrototypeForwardPipeline::AlphaTestPipelineLabel;
inline constexpr std::string_view ComputeEncoderLabel =
    "RendererIOS Forward Compute Encoder";
inline constexpr std::string_view RenderEncoderLabel =
    "RendererIOS Forward Render Encoder";
inline constexpr std::string_view LightListBufferLabel =
    "RendererIOS Forward LightList 256B";
inline constexpr std::string_view CommandBufferLabel =
    "RendererIOS Forward Prototype CB";

inline constexpr uint32_t LightListFlagAvailable = 1u<<0u;
inline constexpr uint32_t LightListFlagSameDevice = 1u<<1u;
inline constexpr uint32_t LightListFlagRequestedShared = 1u<<2u;
inline constexpr uint32_t LightListFlagRequestedTracked = 1u<<3u;
inline constexpr uint32_t LightListFlagObservedShared = 1u<<4u;
inline constexpr uint32_t LightListFlagObservedTracked = 1u<<5u;
inline constexpr uint32_t LightListFlagContentsAvailable = 1u<<6u;
inline constexpr uint32_t LightListFlagSentinelPrefilled = 1u<<7u;
inline constexpr uint32_t LightListFlagLabelMatches = 1u<<8u;
inline constexpr uint32_t LightListKnownFlagsMask =
    LightListFlagAvailable |
    LightListFlagSameDevice |
    LightListFlagRequestedShared |
    LightListFlagRequestedTracked |
    LightListFlagObservedShared |
    LightListFlagObservedTracked |
    LightListFlagContentsAvailable |
    LightListFlagSentinelPrefilled |
    LightListFlagLabelMatches;

inline constexpr uint32_t ProbeFlagInputsValid = 1u<<0u;
inline constexpr uint32_t ProbeFlagOutputContractValid = 1u<<1u;
inline constexpr uint32_t ProbeFlagLightListContractValid = 1u<<2u;
inline constexpr uint32_t ProbeFlagEncoded = 1u<<3u;
inline constexpr uint32_t ProbeFlagExactSequence = 1u<<4u;
inline constexpr uint32_t ProbeFlagExactGeometry = 1u<<5u;
inline constexpr uint32_t ProbeFlagExactLabels = 1u<<6u;
inline constexpr uint32_t ProbeFlagNoForbiddenSideEffects = 1u<<7u;
inline constexpr uint32_t ProbeKnownFlagsMask =
    ProbeFlagInputsValid |
    ProbeFlagOutputContractValid |
    ProbeFlagLightListContractValid |
    ProbeFlagEncoded |
    ProbeFlagExactSequence |
    ProbeFlagExactGeometry |
    ProbeFlagExactLabels |
    ProbeFlagNoForbiddenSideEffects;

inline constexpr uint32_t TerminalFlagSubmitted = 1u<<0u;
inline constexpr uint32_t TerminalFlagFenceTerminal = 1u<<1u;
inline constexpr uint32_t TerminalFlagReadbackCanonical = 1u<<2u;
inline constexpr uint32_t TerminalFlagLifetimesValid = 1u<<3u;
inline constexpr uint32_t TerminalFlagCaptureOwnerInitialized = 1u<<4u;
inline constexpr uint32_t TerminalFlagCaptureInactive = 1u<<5u;
inline constexpr uint32_t TerminalFlagCaptureArtifactRetained = 1u<<6u;
inline constexpr uint32_t TerminalFlagNoForbiddenSync = 1u<<9u;
inline constexpr uint32_t TerminalKnownFlagsMask =
    TerminalFlagSubmitted |
    TerminalFlagFenceTerminal |
    TerminalFlagReadbackCanonical |
    TerminalFlagLifetimesValid |
    TerminalFlagCaptureOwnerInitialized |
    TerminalFlagCaptureInactive |
    TerminalFlagCaptureArtifactRetained |
    TerminalFlagNoForbiddenSync;

}

enum class IOSShadingPrototypeForwardFailureReason : uint32_t {
  None                                  = 0u,
  PlanContractMismatch                  = 1u,
  UnsupportedAppleFamily                = 2u,
  SnapshotUnavailable                   = 3u,
  FactoryContractMismatch               = 4u,
  FactoryReflectionMismatch             = 5u,
  FactoryCounterMismatch                = 6u,
  OutputAllocationOrLifetimeMismatch    = 7u,
  LightListAllocationOrContractMismatch = 8u,
  HazardModeUntracked                   = 9u,
  SentinelPrefillMismatch               = 10u,
  CaptureStartFailed                    = 11u,
  CaptureStartAmbiguous                 = 12u,
  CommandBufferCreationFailed           = 13u,
  NativeEncodeRejected                  = 14u,
  EncodedContractMismatch               = 15u,
  SubmitExceptionAmbiguous              = 16u,
  CaptureAcquisitionFailed              = 17u,
  TerminalFenceError                    = 18u,
  TerminalFenceTimeout                  = 19u,
  ReadbackUnavailable                   = 20u,
  ReadbackMismatch                      = 21u,
  TerminalLifetimeOrCounterMismatch     = 22u,
  ForbiddenWaitIdle                     = 23u,
  ForbiddenMTLFence                     = 24u,
  ForbiddenDeviceReadBytes              = 25u,
  Count                                 = 26u,
  };

enum class IOSShadingPrototypeForwardProbeOperation : uint32_t {
  BuildLightList = 0u,
  DrawOpaque     = 1u,
  DrawAlphaTest  = 2u,
  Count          = 3u,
  };

// Fixed-width creation/snapshot ABI. Its canonical value describes the
// required result of a future runtime instance; a host-only canonical value
// is not evidence that a physical Metal device produced these observations.
struct IOSShadingPrototypeForwardLightListReportV1 final {
  uint32_t abiVersion = 0u;
  uint32_t structSize = 0u;
  uint32_t flags = 0u;
  uint32_t failureReason = 0u;
  uint32_t byteSize = 0u;
  uint32_t wordBytes = 0u;
  uint32_t wordCount = 0u;
  uint32_t requestedStorageMode = 0u;
  uint32_t requestedHazardTrackingMode = 0u;
  uint32_t bindingOffset = 0u;
  uint32_t observedByteSize = 0u;
  uint32_t observedStorageMode = 0u;
  uint32_t observedHazardTrackingMode = 0u;
  uint32_t prefillAttempted = 0u;
  uint32_t prefilledWords = 0u;
  uint32_t prefillVerifiedWords = 0u;
  uint32_t sentinelWords = 0u;
  uint32_t unexpectedWords = 0u;
  uint32_t sentinelValue = 0u;
  uint32_t contentsAvailable = 0u;
  uint32_t sameDevice = 0u;
  uint32_t ownerCreatedDelta = 0u;
  uint32_t ownerLiveDelta = 0u;
  uint32_t ownerReleasedDelta = 0u;
  uint32_t helperDeviceCreations = 0u;
  uint32_t helperQueueCreations = 0u;
  uint32_t helperCommandBufferCreations = 0u;
  uint32_t helperFenceCreations = 0u;
  uint32_t helperSubmits = 0u;
  uint32_t helperCommits = 0u;
  uint32_t helperWaits = 0u;
  uint32_t helperMTLFenceUses = 0u;
  uint32_t helperDeviceReadBytesUses = 0u;
  std::array<uint32_t,8u> reserved{};

  friend bool operator==(
      IOSShadingPrototypeForwardLightListReportV1,
      IOSShadingPrototypeForwardLightListReportV1) = default;
  };

// Fixed-width encode ABI. All facts are populated from the native objects
// seen by the one-shot bridge; canonical host construction remains a contract
// oracle, not a device execution claim.
struct IOSShadingPrototypeForwardProbeReportV1 final {
  uint32_t abiVersion = 0u;
  uint32_t structSize = 0u;
  uint32_t flags = 0u;
  uint32_t failureReason = 0u;
  uint32_t borrowedExistingDevice = 0u;
  // The one-shot bridge proved no Tempest encoder was active at entry. This
  // deliberately does not claim that the command buffer was never encoded.
  uint32_t borrowedInactiveCommandBuffer = 0u;
  uint32_t supportsApple4 = 0u;
  uint32_t pipelineReady = 0u;
  uint32_t factoryReady = 0u;
  uint32_t actualReflectionAvailable = 0u;
  uint32_t computeBindingExact = 0u;
  uint32_t vertexBindingExact = 0u;
  uint32_t fragmentBindingExact = 0u;
  uint32_t pipelineSameDevice = 0u;
  uint32_t sameDeviceAllPipelines = 0u;
  uint32_t sameDeviceAllResources = 0u;
  uint32_t outputAvailable = 0u;
  uint32_t outputSameDevice = 0u;
  uint32_t outputType2D = 0u;
  uint32_t outputRgba8Unorm = 0u;
  uint32_t outputPrivate = 0u;
  uint32_t outputExtentMatches = 0u;
  uint32_t outputWidth = 0u;
  uint32_t outputHeight = 0u;
  uint32_t outputMipLevels = 0u;
  uint32_t outputSampleCount = 0u;
  uint32_t outputLoadClear = 0u;
  uint32_t outputStoreStore = 0u;
  uint32_t outputClearStore = 0u;
  uint32_t transparentBlackClear = 0u;
  uint32_t outputAttachments = 0u;
  uint32_t outputAttachmentIndex = 0u;
  uint32_t otherColorAttachments = 0u;
  uint32_t depthAttachments = 0u;
  uint32_t stencilAttachments = 0u;
  uint32_t sampleCountOne = 0u;
  uint32_t lightListAvailable = 0u;
  uint32_t lightListSameDevice = 0u;
  uint32_t lightListShared = 0u;
  uint32_t lightListTracked = 0u;
  uint32_t lightListByteSize = 0u;
  uint32_t lightListOffset = 0u;
  uint32_t encoded = 0u;
  uint32_t physicalPasses = 0u;
  uint32_t commandBuffers = 0u;
  uint32_t commandBufferRetainedReferencesDisabled = 0u;
  uint32_t withActiveCommandBufferCalls = 0u;
  uint32_t computeEncoders = 0u;
  uint32_t renderEncoders = 0u;
  uint32_t computeBufferBindings = 0u;
  uint32_t computeBufferIndex = 0u;
  uint32_t computeBufferOffset = 0u;
  uint32_t computePipelineBinds = 0u;
  uint32_t fragmentBufferBindings = 0u;
  uint32_t fragmentBufferIndex = 0u;
  uint32_t fragmentBufferOffset = 0u;
  uint32_t vertexBufferIndex = 0u;
  uint32_t opaquePipelineBinds = 0u;
  uint32_t alphaTestPipelineBinds = 0u;
  uint32_t pipelineStates = 0u;
  uint32_t vertexByteBindings = 0u;
  uint32_t vertices = 0u;
  uint32_t vertexBytes = 0u;
  uint32_t vertexStride = 0u;
  uint32_t primitiveTriangle = 0u;
  uint32_t dispatches = 0u;
  uint32_t gridWidth = 0u;
  uint32_t gridHeight = 0u;
  uint32_t gridDepth = 0u;
  uint32_t threadsPerThreadgroupWidth = 0u;
  uint32_t threadsPerThreadgroupHeight = 0u;
  uint32_t threadsPerThreadgroupDepth = 0u;
  uint32_t draws = 0u;
  uint32_t opaqueDraws = 0u;
  uint32_t alphaTestDraws = 0u;
  uint32_t opaqueVertexStart = 0u;
  uint32_t opaqueVertexCount = 0u;
  uint32_t alphaTestVertexStart = 0u;
  uint32_t alphaTestVertexCount = 0u;
  uint32_t endEncodingCalls = 0u;
  uint32_t computeEndedBeforeRender = 0u;
  uint32_t renderEnded = 0u;
  uint32_t computePipelineLabelMatches = 0u;
  uint32_t opaquePipelineLabelMatches = 0u;
  uint32_t alphaTestPipelineLabelMatches = 0u;
  uint32_t computeEncoderLabelMatches = 0u;
  uint32_t renderEncoderLabelMatches = 0u;
  uint32_t helperDeviceCreations = 0u;
  uint32_t helperQueueCreations = 0u;
  uint32_t helperCommandBufferCreations = 0u;
  uint32_t helperFenceCreations = 0u;
  uint32_t helperResourceCreations = 0u;
  uint32_t captureStarts = 0u;
  uint32_t helperSubmits = 0u;
  uint32_t helperCommits = 0u;
  uint32_t helperWaits = 0u;
  uint32_t helperCompletionHandlers = 0u;
  uint32_t helperReadbacks = 0u;
  uint32_t helperBinaryArchiveUses = 0u;
  uint32_t helperMTLFenceUses = 0u;
  uint32_t helperDeviceReadBytesUses = 0u;
  uint32_t drawableAcquisitions = 0u;
  uint32_t presents = 0u;
  uint32_t runtimeShaderCompilations = 0u;
  uint32_t archiveMutations = 0u;
  uint32_t operationCount = 0u;
  std::array<uint32_t,3u> operations{};
  std::array<uint32_t,8u> reserved{};

  friend bool operator==(
      IOSShadingPrototypeForwardProbeReportV1,
      IOSShadingPrototypeForwardProbeReportV1) = default;
  };

// Future c1b1 terminal PASS ABI. C1b0 freezes and mutation-tests it but does
// not construct a runtime terminal report, submit work, wait, or capture.
struct IOSShadingPrototypeForwardTerminalReportV1 final {
  uint32_t abiVersion = 0u;
  uint32_t structSize = 0u;
  uint32_t flags = 0u;
  uint32_t failureReason = 0u;
  uint32_t submittedCommandBuffers = 0u;
  uint32_t submitCalls = 0u;
  uint32_t terminalFenceWaitCalls = 0u;
  uint32_t terminalFenceCompleted = 0u;
  uint32_t terminalFenceErrors = 0u;
  uint32_t terminalFenceTimeouts = 0u;
  uint32_t terminalFenceZeroTimeoutCalls = 0u;
  uint32_t terminalFenceNonterminalPolls = 0u;
  uint32_t terminalFenceMonotonic = 0u;
  uint32_t terminalFenceMonotonicDeadlineUsed = 0u;
  uint32_t callerWaitUntilCompletedCalls = 0u;
  uint32_t callerCompletionHandlerCalls = 0u;
  uint32_t directContentsAvailable = 0u;
  uint32_t readbackCalls = 0u;
  uint32_t readbackOffset = 0u;
  uint32_t readbackBytes = 0u;
  uint32_t readbackWords = 0u;
  uint32_t firstWord = 0u;
  uint32_t activeWords = 0u;
  uint32_t inactiveWords = 0u;
  uint32_t sentinelWords = 0u;
  uint32_t unexpectedWords = 0u;
  uint32_t exactResult = 0u;
  uint32_t lightListLifetimeRetained = 0u;
  uint32_t outputLifetimeRetained = 0u;
  uint32_t commandBufferRetainedReferencesDisabledContract = 0u;
  uint32_t outputCreatedDelta = 0u;
  uint32_t outputLiveAfterReleaseDelta = 0u;
  uint32_t outputReleasedDelta = 0u;
  uint32_t lightListCreatedDelta = 0u;
  uint32_t lightListLiveAfterReleaseDelta = 0u;
  uint32_t lightListReleasedDelta = 0u;
  uint32_t releaseOrderExact = 0u;
  uint32_t pipelineLiveAtTerminal = 0u;
  uint32_t pipelineReleasedAfterTerminal = 0u;
  uint32_t outputLiveAtTerminal = 0u;
  uint32_t outputReleasedAfterTerminal = 0u;
  uint32_t lightListLiveAtTerminal = 0u;
  uint32_t lightListReleasedAfterTerminal = 0u;
  uint32_t commandBufferLiveAtTerminal = 0u;
  uint32_t commandBufferReleasedAfterTerminal = 0u;
  uint32_t captureOwnerInitializedAtTerminal = 0u;
  uint32_t captureActiveAtTerminal = 0u;
  uint32_t captureArtifactRetainedAtTerminal = 0u;
  uint32_t captureOwnerReleasedAfterTerminal = 0u;
  uint32_t fenceLiveAtTerminal = 0u;
  uint32_t fenceReleasedAfterTerminal = 0u;
  uint32_t captureAcquisitionCalls = 0u;
  uint32_t captureAcquisitionFailures = 0u;
  uint32_t callerWaitIdleCalls = 0u;
  uint32_t callerMTLFenceUses = 0u;
  uint32_t callerDeviceReadBytesCalls = 0u;
  uint32_t runtimeShaderCompilationDelta = 0u;
  uint32_t builtinShaderCompilationDelta = 0u;
  uint32_t binaryArchiveMutationDelta = 0u;
  std::array<uint32_t,8u> reserved{};

  friend bool operator==(
      IOSShadingPrototypeForwardTerminalReportV1,
      IOSShadingPrototypeForwardTerminalReportV1) = default;
  };

#if defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)
struct IOSShadingPrototypeForwardLightListLifetimeSnapshot final {
  uint64_t created = 0u;
  uint64_t live = 0u;
  uint64_t released = 0u;

  friend bool operator==(
      IOSShadingPrototypeForwardLightListLifetimeSnapshot,
      IOSShadingPrototypeForwardLightListLifetimeSnapshot) = default;
  };

[[nodiscard]] IOSShadingPrototypeForwardLightListLifetimeSnapshot
    iosShadingPrototypeForwardLightListLifetimeSnapshot() noexcept;
#endif

[[nodiscard]] IOSShadingPrototypeForwardLightListReportV1
    iosCanonicalShadingPrototypeForwardLightListReportV1() noexcept;
[[nodiscard]] IOSShadingPrototypeForwardProbeReportV1
    iosCanonicalShadingPrototypeForwardProbeReportV1() noexcept;
[[nodiscard]] IOSShadingPrototypeForwardTerminalReportV1
    iosCanonicalShadingPrototypeForwardTerminalReportV1() noexcept;

[[nodiscard]] bool iosValidateShadingPrototypeForwardLightListReportV1(
    const IOSShadingPrototypeForwardLightListReportV1& report) noexcept;
[[nodiscard]] bool iosValidateShadingPrototypeForwardProbeReportV1(
    const IOSShadingPrototypeForwardProbeReportV1& report) noexcept;
[[nodiscard]] bool iosValidateShadingPrototypeForwardTerminalReportV1(
    const IOSShadingPrototypeForwardTerminalReportV1& report) noexcept;

[[nodiscard]] bool iosShadingPrototypeForwardLightListContentsMatch(
    const std::array<
        uint32_t,
        RendererIOSShadingPrototypeShader::ForwardLightListWordCount>&
        words) noexcept;

class IOSShadingPrototypeForwardLightList final {
  public:
    IOSShadingPrototypeForwardLightList() noexcept;
    ~IOSShadingPrototypeForwardLightList();

    IOSShadingPrototypeForwardLightList(
        const IOSShadingPrototypeForwardLightList&) = delete;
    IOSShadingPrototypeForwardLightList& operator=(
        const IOSShadingPrototypeForwardLightList&) = delete;

    IOSShadingPrototypeForwardLightList(
        IOSShadingPrototypeForwardLightList&& other) noexcept;
    IOSShadingPrototypeForwardLightList& operator=(
        IOSShadingPrototypeForwardLightList&& other) noexcept;

    explicit operator bool() const noexcept;
    [[nodiscard]] const IOSShadingPrototypeForwardLightListReportV1&
        report() const noexcept;

  private:
    struct Impl;
    IOSShadingPrototypeForwardLightList(
        IOSShadingPrototypeForwardLightListReportV1 report,
        std::unique_ptr<Impl>&& impl) noexcept;

    IOSShadingPrototypeForwardLightListReportV1 lightListReport;
    std::unique_ptr<Impl> impl;

  friend IOSShadingPrototypeForwardLightList
      iosCreateShadingPrototypeForwardLightList(
          Tempest::Device&) noexcept;
  friend bool iosReadShadingPrototypeForwardLightListContents(
      const IOSShadingPrototypeForwardLightList&,
      std::array<
          uint32_t,
          RendererIOSShadingPrototypeShader::
              ForwardLightListWordCount>&) noexcept;
  friend class IOSShadingPrototypeForwardLightListNativeAccess;
  };

[[nodiscard]] IOSShadingPrototypeForwardLightList
    iosCreateShadingPrototypeForwardLightList(
        Tempest::Device& device) noexcept;

// Direct Shared-buffer contents copy only. The function never submits, waits,
// synchronizes, or calls Device::readBytes; c1b1 may invoke it only after its
// terminal Tempest fence has completed.
[[nodiscard]] bool iosReadShadingPrototypeForwardLightListContents(
    const IOSShadingPrototypeForwardLightList& lightList,
    std::array<
        uint32_t,
        RendererIOSShadingPrototypeShader::ForwardLightListWordCount>&
        words) noexcept;

// C1b0 compiles this one-shot bridge with zero production callers. The caller
// owns the active command buffer and output texture; this helper never submits,
// waits, captures, allocates a command buffer, acquires a drawable, or presents.
[[nodiscard]] bool iosEncodeShadingPrototypeForwardProbe(
    Tempest::Device& device,
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSShadingPrototypeForwardPipeline& pipeline,
    const IOSMetalResourceTexture& output,
    const IOSShadingPrototypeForwardLightList& lightList,
    IOSShadingPrototypeForwardProbeReportV1& report) noexcept;
