#pragma once

#include <cstdint>
#include <type_traits>

#include "iosframeplan.h"

inline constexpr uint32_t IOSLinearHDRContractVersion = 1u;
inline constexpr uint8_t IOSLinearHDRRequiredProbeUsages = 0x03u;
inline constexpr uint32_t IOSLinearHDRBytesPerPixel = 4u;

inline constexpr float IOSLinearHDRIdealTolerance = 2.0e-5f;
inline constexpr float IOSLinearHDRRG11B10Tolerance = 2.0f/255.0f;
inline constexpr float IOSLinearHDRFinalTolerance = 3.0f/255.0f;
inline constexpr float IOSLinearHDRTightRG11B10MutationTolerance = 1.0f/255.0f;
inline constexpr float IOSLinearHDRTightFinalMutationTolerance = 2.0f/255.0f;
inline constexpr float IOSLinearHDRB10BoundaryEncoded = 0.643773f;

inline constexpr IOSResourceId IOSLinearHDRSceneColorResource{1u};
inline constexpr IOSResourceId IOSLinearHDRSceneDepthResource{2u};
inline constexpr IOSResourceId IOSLinearHDRDrawableResource{3u};
inline constexpr IOSPassId IOSLinearHDRScenePass{1u};
inline constexpr IOSPassId IOSLinearHDRToneResolvePass{2u};
inline constexpr IOSPassId IOSLinearHDROverlayPass{3u};
inline constexpr IOSPassId IOSLinearHDRPresentPass{4u};

struct IOSLinearHDRRGB final {
  float r = 0.f;
  float g = 0.f;
  float b = 0.f;

  constexpr bool operator==(const IOSLinearHDRRGB&) const noexcept = default;
  };

struct IOSLinearHDRRawSettings final {
  float zVidBrightness = 0.5f;
  float zVidContrast = 0.5f;
  float zVidGamma = 0.5f;

  constexpr bool operator==(const IOSLinearHDRRawSettings&) const noexcept =
      default;
  };

// Host-neutral value contract. The native bridge maps these values explicitly
// to the separately owned GPU ABI structure.
struct IOSLinearHDRToneValues final {
  float brightness = 0.f;
  float contrast = 1.f;
  float gamma = 1.f/2.2f;
  float exposure = 1.f;

  constexpr bool operator==(const IOSLinearHDRToneValues&) const noexcept =
      default;
  };

enum class IOSLinearHDRSettingsAcceptance : uint8_t {
  Accepted = 0u,
  RejectedNonFinite = 1u,
  };

struct IOSLinearHDRSettingsState final {
  // Preserves the accepted raw triplet. Only derived runtime values clamp.
  IOSLinearHDRRawSettings lastKnownGood;
  IOSLinearHDRToneValues pending;
  IOSLinearHDRToneValues committed;
  bool pendingDirty = false;

  constexpr bool operator==(const IOSLinearHDRSettingsState&) const noexcept =
      default;
  };

struct IOSLinearHDRSettingsLoadResult final {
  IOSLinearHDRSettingsState state;
  bool usedDefaults = false;
  };

struct IOSLinearHDRSettingsUpdateResult final {
  IOSLinearHDRSettingsState state;
  IOSLinearHDRSettingsAcceptance acceptance =
      IOSLinearHDRSettingsAcceptance::RejectedNonFinite;
  };

struct IOSLinearHDRSettingsCommitResult final {
  IOSLinearHDRSettingsState state;
  bool committedPending = false;
  };

bool iosLinearHDRRawSettingsAreFinite(
    IOSLinearHDRRawSettings raw) noexcept;
IOSLinearHDRRawSettings iosLinearHDRClampRawSettings(
    IOSLinearHDRRawSettings raw) noexcept;
bool iosLinearHDRDeriveToneValues(
    IOSLinearHDRRawSettings raw,
    IOSLinearHDRToneValues& values) noexcept;
bool iosLinearHDRToneValuesAreValid(
    IOSLinearHDRToneValues values) noexcept;

IOSLinearHDRSettingsLoadResult iosLinearHDRLoadSettings(
    IOSLinearHDRRawSettings raw) noexcept;
IOSLinearHDRSettingsUpdateResult iosLinearHDRQueueSettingsUpdate(
    IOSLinearHDRSettingsState state,
    IOSLinearHDRRawSettings raw) noexcept;
IOSLinearHDRSettingsCommitResult iosLinearHDRCommitSettingsAtFrameBoundary(
    IOSLinearHDRSettingsState state) noexcept;

bool iosLinearHDRLift(
    IOSLinearHDRRGB currentLdrRgb,
    IOSLinearHDRRGB& sceneRgb) noexcept;
bool iosLinearHDRResolve(
    IOSLinearHDRRGB sceneRgb,
    IOSLinearHDRToneValues values,
    float dither,
    IOSLinearHDRRGB& resolvedRgb) noexcept;
float iosLinearHDRDither(float pixelCenterX, float pixelCenterY) noexcept;
IOSLinearHDRRGB iosLinearHDRQuantizeRG11B10(
    IOSLinearHDRRGB sceneRgb) noexcept;
IOSLinearHDRRGB iosLinearHDRQuantizeBGRA8(
    IOSLinearHDRRGB resolvedRgb) noexcept;
float iosLinearHDRMaximumAbsoluteError(
    IOSLinearHDRRGB lhs,
    IOSLinearHDRRGB rhs) noexcept;

enum class IOSLinearHDRProbeReason : uint8_t {
  None = 0u,
  FactoryFailed = 1u,
  };

class IOSLinearHDRProbeResult final {
  public:
    static constexpr IOSLinearHDRProbeResult success() noexcept {
      return IOSLinearHDRProbeResult(
          IOSLinearHDRProbeReason::None,
          IOSLinearHDRRequiredProbeUsages,
          IOSLinearHDRRequiredProbeUsages);
      }

    static constexpr IOSLinearHDRProbeResult factoryFailed() noexcept {
      return IOSLinearHDRProbeResult(
          IOSLinearHDRProbeReason::FactoryFailed,0u,0u);
      }

    static constexpr IOSLinearHDRProbeResult observed(
        uint8_t knownUsages,
        uint8_t supportedUsages) noexcept {
      return IOSLinearHDRProbeResult(
          IOSLinearHDRProbeReason::None,knownUsages,supportedUsages);
      }

    constexpr IOSLinearHDRProbeReason reason() const noexcept {
      return reason_;
      }

    constexpr uint8_t knownUsages() const noexcept {
      return knownUsages_;
      }

    constexpr uint8_t supportedUsages() const noexcept {
      return supportedUsages_;
      }

    constexpr bool operator==(
        const IOSLinearHDRProbeResult&) const noexcept = default;

  private:
    constexpr IOSLinearHDRProbeResult(
        IOSLinearHDRProbeReason reason,
        uint8_t knownUsages,
        uint8_t supportedUsages) noexcept
      : reason_(reason),
        knownUsages_(knownUsages),
        supportedUsages_(supportedUsages) {
      }

  private:
    IOSLinearHDRProbeReason reason_ = IOSLinearHDRProbeReason::FactoryFailed;
    uint8_t knownUsages_ = 0u;
    uint8_t supportedUsages_ = 0u;
  };

enum class IOSLinearHDRPolicyReason : uint8_t {
  NotRequested = 0u,
  ProbeFactoryFailed = 1u,
  ProbeUnknown = 2u,
  ProbeUnsupported = 3u,
  TargetFactoryFailed = 4u,
  ScenePipelineFailed = 5u,
  ResolvePipelineFailed = 6u,
  Ready = 7u,
  };

struct IOSLinearHDRActivationStatus final {
  bool targetReady = false;
  bool scenePipelineReady = false;
  bool resolvePipelineReady = false;
  };

struct IOSLinearHDRPolicyState final {
  bool requested = false;
  bool probeReady = false;
  bool ready = false;
  IOSLinearHDRPolicyReason reason = IOSLinearHDRPolicyReason::NotRequested;
  };

IOSLinearHDRPolicyState iosEvaluateLinearHDRPolicy(
    bool requested,
    IOSLinearHDRProbeResult probe,
    IOSLinearHDRActivationStatus activation) noexcept;

enum class IOSLinearHDRSafetyMode : uint8_t {
  AwaitingStartup = 0u,
  Ready = 1u,
  SafeNoScene = 2u,
  };

enum class IOSLinearHDRActivationAttempt : uint8_t {
  Startup = 0u,
  Recreate = 1u,
  };

struct IOSLinearHDRSafetyState final {
  IOSLinearHDRSafetyMode mode = IOSLinearHDRSafetyMode::AwaitingStartup;
  };

struct IOSLinearHDRSafetyTransition final {
  IOSLinearHDRSafetyState state;
  bool protocolValid = false;
  bool enteredSafeNoScene = false;
  };

IOSLinearHDRSafetyTransition iosAdvanceLinearHDRSafetyState(
    IOSLinearHDRSafetyState current,
    IOSLinearHDRActivationAttempt attempt,
    IOSLinearHDRPolicyState policy) noexcept;

enum class IOSLinearHDRWork : uint8_t {
  NativeSceneHDR = 0u,
  ToneResolve = 1u,
  DirectLdrScene = 2u,
  DrawableClear = 3u,
  LdrUI = 4u,
  LdrCounters = 5u,
  Bink = 6u,
  Inventory3D = 7u,
  };

bool iosLinearHDRWorkIsAllowed(
    IOSLinearHDRSafetyState safety,
    IOSLinearHDRWork work,
    bool hasCurrentExtentDepth) noexcept;

struct IOSLinearHDRExtent final {
  uint32_t width = 0u;
  uint32_t height = 0u;

  constexpr bool operator==(const IOSLinearHDRExtent&) const noexcept =
      default;
  };

struct IOSLinearHDRFrameIdentity final {
  uint64_t targetGeneration = 0u;
  uint64_t snapshotSequence = 0u;
  IOSLinearHDRExtent extent;

  constexpr bool operator==(const IOSLinearHDRFrameIdentity&) const noexcept =
      default;
  };

enum class IOSLinearHDRFrameRoute : uint8_t {
  Scene = 0u,
  VideoBypass = 1u,
  NoWorldBypass = 2u,
  SafeNoSceneBypass = 3u,
  };

enum class IOSLinearHDRFrameEvent : uint8_t {
  SceneHDR = 0u,
  ToneResolve = 1u,
  LdrOverlay = 2u,
  Present = 3u,
  TerminalCompleted = 4u,
  TerminalFailed = 5u,
  };

enum class IOSLinearHDRFrameStage : uint8_t {
  Invalid = 0u,
  Begun = 1u,
  SceneHDR = 2u,
  ToneResolve = 3u,
  LdrOverlay = 4u,
  Present = 5u,
  TerminalCompleted = 6u,
  TerminalFailed = 7u,
  };

enum class IOSLinearHDRFrameError : uint8_t {
  None = 0u,
  InvalidRoute = 1u,
  InvalidExtent = 2u,
  InvalidIdentity = 3u,
  ByteSizeOverflow = 4u,
  InvalidSequence = 5u,
  InvalidEvent = 6u,
  AlreadyTerminal = 7u,
  TargetGenerationMismatch = 8u,
  SnapshotSequenceMismatch = 9u,
  ExtentMismatch = 10u,
  BypassRejectsLinearStage = 11u,
  WrongOrder = 12u,
  TerminalFailure = 13u,
  };

struct IOSLinearHDRFrameSequenceBeginResult;

class IOSLinearHDRFrameSequence final {
  public:
    constexpr bool valid() const noexcept {
      return valid_;
      }

    constexpr IOSLinearHDRFrameIdentity identity() const noexcept {
      return identity_;
      }

    constexpr IOSLinearHDRFrameRoute route() const noexcept {
      return route_;
      }

    constexpr IOSLinearHDRFrameStage stage() const noexcept {
      return stage_;
      }

    constexpr IOSLinearHDRFrameError failure() const noexcept {
      return failure_;
      }

    constexpr bool sceneEncoded() const noexcept {
      return (completedStages_&SceneBit)!=0u;
      }

    constexpr bool resolveEncoded() const noexcept {
      return (completedStages_&ResolveBit)!=0u;
      }

    constexpr bool overlayEncoded() const noexcept {
      return (completedStages_&OverlayBit)!=0u;
      }

    constexpr bool presentAccepted() const noexcept {
      return (completedStages_&PresentBit)!=0u;
      }

    constexpr bool overlayHasUI() const noexcept {
      return overlayHasUI_;
      }

  private:
    static constexpr uint8_t SceneBit = uint8_t(1u << 0u);
    static constexpr uint8_t ResolveBit = uint8_t(1u << 1u);
    static constexpr uint8_t OverlayBit = uint8_t(1u << 2u);
    static constexpr uint8_t PresentBit = uint8_t(1u << 3u);

    IOSLinearHDRFrameIdentity identity_;
    IOSLinearHDRFrameRoute route_ = IOSLinearHDRFrameRoute::Scene;
    IOSLinearHDRFrameStage stage_ = IOSLinearHDRFrameStage::Invalid;
    IOSLinearHDRFrameError failure_ = IOSLinearHDRFrameError::InvalidSequence;
    uint8_t completedStages_ = 0u;
    bool overlayHasUI_ = false;
    bool valid_ = false;

    friend struct IOSLinearHDRFrameSequenceBeginResult;
    friend IOSLinearHDRFrameSequenceBeginResult iosBeginLinearHDRFrameSequence(
        IOSLinearHDRFrameRoute,
        IOSLinearHDRFrameIdentity) noexcept;
    friend IOSLinearHDRFrameError iosAdvanceLinearHDRFrameSequence(
        IOSLinearHDRFrameSequence&,
        IOSLinearHDRFrameEvent,
        IOSLinearHDRFrameIdentity,
        bool) noexcept;
    friend bool iosLinearHDRFrameSequenceCanProve(
        const IOSLinearHDRFrameSequence&) noexcept;
  };

struct IOSLinearHDRFrameSequenceBeginResult final {
  IOSLinearHDRFrameSequence sequence;
  IOSLinearHDRFrameError error = IOSLinearHDRFrameError::InvalidSequence;

  constexpr explicit operator bool() const noexcept {
    return error==IOSLinearHDRFrameError::None && sequence.valid();
    }
  };

bool iosLinearHDRCheckedTargetByteSize(
    IOSLinearHDRExtent extent,
    uint64_t& byteSize) noexcept;
IOSFramePlan iosLinearHDRStructuralFramePlan(
    IOSLinearHDRExtent extent,
    IOSPixelFormat depthFormat);
IOSLinearHDRFrameSequenceBeginResult iosBeginLinearHDRFrameSequence(
    IOSLinearHDRFrameRoute route,
    IOSLinearHDRFrameIdentity identity) noexcept;
IOSLinearHDRFrameError iosAdvanceLinearHDRFrameSequence(
    IOSLinearHDRFrameSequence& sequence,
    IOSLinearHDRFrameEvent event,
    IOSLinearHDRFrameIdentity identity,
    bool overlayHasUI = false) noexcept;
bool iosLinearHDRFrameSequenceCanProve(
    const IOSLinearHDRFrameSequence& sequence) noexcept;

struct IOSLinearHDRProvenEvidence final {
  IOSLinearHDRFrameIdentity identity;
  bool proven = false;
  };

bool iosLinearHDRCommitProvenEvidence(
    bool policyWasReadyAtEncode,
    const IOSLinearHDRFrameSequence& sequence,
    IOSLinearHDRProvenEvidence& evidence) noexcept;

static_assert(sizeof(IOSLinearHDRRGB)==12u);
static_assert(sizeof(IOSLinearHDRRawSettings)==12u);
static_assert(sizeof(IOSLinearHDRToneValues)==16u);
static_assert(alignof(IOSLinearHDRToneValues)==alignof(float));
static_assert(std::is_standard_layout_v<IOSLinearHDRToneValues>);
static_assert(std::is_trivially_copyable_v<IOSLinearHDRToneValues>);
static_assert(std::is_standard_layout_v<IOSLinearHDRProbeResult>);
static_assert(std::is_trivially_copyable_v<IOSLinearHDRProbeResult>);
static_assert(std::is_standard_layout_v<IOSLinearHDRFrameSequence>);
static_assert(std::is_trivially_copyable_v<IOSLinearHDRFrameSequence>);
static_assert(std::is_standard_layout_v<IOSLinearHDRProvenEvidence>);
static_assert(std::is_trivially_copyable_v<IOSLinearHDRProvenEvidence>);
