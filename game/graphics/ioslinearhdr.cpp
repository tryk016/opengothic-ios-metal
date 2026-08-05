#include "ioslinearhdr.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace {

constexpr IOSLinearHDRRawSettings DefaultRawSettings{};
constexpr float GammaBase = 1.f/2.2f;
constexpr float MinimumBrightness = -0.05f;
constexpr float MaximumBrightness = 0.05f;
constexpr float MinimumContrast = 0.5f;
constexpr float MaximumContrast = 1.5f;
constexpr float MinimumGamma = GammaBase/2.f;
constexpr float MaximumGamma = GammaBase/0.01f;
constexpr float MinimumDither = -1.f/255.f;
constexpr float MaximumDither = 1.f/255.f;

bool finite(IOSLinearHDRRGB value) noexcept {
  return std::isfinite(value.r) &&
      std::isfinite(value.g) &&
      std::isfinite(value.b);
  }

float clamp01(float value) noexcept {
  return std::clamp(value,0.f,1.f);
  }

float acesTonemap(float value) noexcept {
  constexpr float a = 2.51f;
  constexpr float b = 0.03f;
  constexpr float c = 2.43f;
  constexpr float d = 0.59f;
  constexpr float e = 0.14f;
  const float numerator = value*(a*value+b);
  const float denominator = value*(c*value+d)+e;
  return clamp01(numerator/denominator);
  }

float acesTonemapInverse(float value) noexcept {
  const float radicand =
      -1.0127f*value*value+1.3702f*value+0.0009f;
  const float numerator =
      -0.59f*value+0.03f-std::sqrt(std::max(0.f,radicand));
  const float denominator = 2.f*(2.43f*value-2.51f);
  return numerator/denominator;
  }

float resolveComponent(
    float scene,
    IOSLinearHDRToneValues values,
    float dither) noexcept {
  float color = scene*values.exposure;
  color = std::max(0.f,color+values.brightness);
  color *= values.contrast;
  color = acesTonemap(color);
  color = std::pow(color,values.gamma);
  return color+dither;
  }

double roundToNearestEven(double value) noexcept {
  const double lower = std::floor(value);
  const double fraction = value-lower;
  if(fraction<0.5)
    return lower;
  if(fraction>0.5)
    return lower+1.0;
  return std::fmod(lower,2.0)==0.0 ? lower : lower+1.0;
  }

float quantizeUnsignedFloat(float value, int mantissaBits) noexcept {
  if(!std::isfinite(value))
    return std::numeric_limits<float>::quiet_NaN();
  if(value<=0.f)
    return 0.f;

  const double maximum =
      std::ldexp(2.0-std::ldexp(1.0,-mantissaBits),15);
  double source = std::min<double>(value,maximum);
  constexpr double minimumNormal = 0x1p-14;
  if(source<minimumNormal) {
    const double step = std::ldexp(1.0,-14-mantissaBits);
    source = roundToNearestEven(source/step)*step;
    return static_cast<float>(std::min(source,minimumNormal));
    }

  int exponent = 0;
  (void)std::frexp(source,&exponent);
  const int unbiasedExponent = exponent-1;
  const double step = std::ldexp(1.0,unbiasedExponent-mantissaBits);
  source = roundToNearestEven(source/step)*step;
  return static_cast<float>(std::min(source,maximum));
  }

float quantizeUnorm8(float value) noexcept {
  if(!std::isfinite(value))
    return std::numeric_limits<float>::quiet_NaN();
  const float encoded = clamp01(value);
  return std::floor(encoded*255.f+0.5f)/255.f;
  }

bool validProbeReason(IOSLinearHDRProbeReason reason) noexcept {
  switch(reason) {
    case IOSLinearHDRProbeReason::None:
    case IOSLinearHDRProbeReason::FactoryFailed:
      return true;
    }
  return false;
  }

bool canonicalPolicy(IOSLinearHDRPolicyState policy) noexcept {
  switch(policy.reason) {
    case IOSLinearHDRPolicyReason::NotRequested:
      return !policy.requested && !policy.probeReady && !policy.ready;
    case IOSLinearHDRPolicyReason::ProbeFactoryFailed:
    case IOSLinearHDRPolicyReason::ProbeUnknown:
    case IOSLinearHDRPolicyReason::ProbeUnsupported:
      return policy.requested && !policy.probeReady && !policy.ready;
    case IOSLinearHDRPolicyReason::TargetFactoryFailed:
    case IOSLinearHDRPolicyReason::ScenePipelineFailed:
    case IOSLinearHDRPolicyReason::ResolvePipelineFailed:
      return policy.requested && policy.probeReady && !policy.ready;
    case IOSLinearHDRPolicyReason::Ready:
      return policy.requested && policy.probeReady && policy.ready;
    }
  return false;
  }

bool validSafetyMode(IOSLinearHDRSafetyMode mode) noexcept {
  switch(mode) {
    case IOSLinearHDRSafetyMode::AwaitingStartup:
    case IOSLinearHDRSafetyMode::Ready:
    case IOSLinearHDRSafetyMode::SafeNoScene:
      return true;
    }
  return false;
  }

bool validAttempt(IOSLinearHDRActivationAttempt attempt) noexcept {
  switch(attempt) {
    case IOSLinearHDRActivationAttempt::Startup:
    case IOSLinearHDRActivationAttempt::Recreate:
      return true;
    }
  return false;
  }

bool validWork(IOSLinearHDRWork work) noexcept {
  switch(work) {
    case IOSLinearHDRWork::NativeSceneHDR:
    case IOSLinearHDRWork::ToneResolve:
    case IOSLinearHDRWork::DirectLdrScene:
    case IOSLinearHDRWork::DrawableClear:
    case IOSLinearHDRWork::LdrUI:
    case IOSLinearHDRWork::LdrCounters:
    case IOSLinearHDRWork::Bink:
    case IOSLinearHDRWork::Inventory3D:
      return true;
    }
  return false;
  }

bool validRoute(IOSLinearHDRFrameRoute route) noexcept {
  switch(route) {
    case IOSLinearHDRFrameRoute::Scene:
    case IOSLinearHDRFrameRoute::VideoBypass:
    case IOSLinearHDRFrameRoute::NoWorldBypass:
    case IOSLinearHDRFrameRoute::SafeNoSceneBypass:
      return true;
    }
  return false;
  }

bool validEvent(IOSLinearHDRFrameEvent event) noexcept {
  switch(event) {
    case IOSLinearHDRFrameEvent::SceneHDR:
    case IOSLinearHDRFrameEvent::ToneResolve:
    case IOSLinearHDRFrameEvent::LdrOverlay:
    case IOSLinearHDRFrameEvent::Present:
    case IOSLinearHDRFrameEvent::TerminalCompleted:
    case IOSLinearHDRFrameEvent::TerminalFailed:
      return true;
    }
  return false;
  }

bool terminal(IOSLinearHDRFrameStage stage) noexcept {
  return stage==IOSLinearHDRFrameStage::TerminalCompleted ||
      stage==IOSLinearHDRFrameStage::TerminalFailed;
  }

}

bool iosLinearHDRRawSettingsAreFinite(
    IOSLinearHDRRawSettings raw) noexcept {
  return std::isfinite(raw.zVidBrightness) &&
      std::isfinite(raw.zVidContrast) &&
      std::isfinite(raw.zVidGamma);
  }

IOSLinearHDRRawSettings iosLinearHDRClampRawSettings(
    IOSLinearHDRRawSettings raw) noexcept {
  if(!iosLinearHDRRawSettingsAreFinite(raw))
    return raw;
  raw.zVidBrightness = clamp01(raw.zVidBrightness);
  raw.zVidContrast = clamp01(raw.zVidContrast);
  raw.zVidGamma = clamp01(raw.zVidGamma);
  return raw;
  }

bool iosLinearHDRDeriveToneValues(
    IOSLinearHDRRawSettings raw,
    IOSLinearHDRToneValues& values) noexcept {
  if(!iosLinearHDRRawSettingsAreFinite(raw))
    return false;
  raw = iosLinearHDRClampRawSettings(raw);
  IOSLinearHDRToneValues candidate;
  candidate.brightness = (raw.zVidBrightness-0.5f)*0.1f;
  candidate.contrast = std::max(1.5f-raw.zVidContrast,0.01f);
  candidate.gamma = GammaBase/std::max(2.f*raw.zVidGamma,0.01f);
  candidate.exposure = 1.f;
  if(!iosLinearHDRToneValuesAreValid(candidate))
    return false;
  values = candidate;
  return true;
  }

bool iosLinearHDRToneValuesAreValid(
    IOSLinearHDRToneValues values) noexcept {
  return std::isfinite(values.brightness) &&
      std::isfinite(values.contrast) &&
      std::isfinite(values.gamma) &&
      std::isfinite(values.exposure) &&
      values.brightness>=MinimumBrightness &&
      values.brightness<=MaximumBrightness &&
      values.contrast>=MinimumContrast &&
      values.contrast<=MaximumContrast &&
      values.gamma>=MinimumGamma &&
      values.gamma<=MaximumGamma &&
      values.exposure==1.f;
  }

IOSLinearHDRSettingsLoadResult iosLinearHDRLoadSettings(
    IOSLinearHDRRawSettings raw) noexcept {
  IOSLinearHDRSettingsLoadResult result;
  IOSLinearHDRToneValues defaults;
  (void)iosLinearHDRDeriveToneValues(DefaultRawSettings,defaults);
  result.state.lastKnownGood = DefaultRawSettings;
  result.state.pending = defaults;
  result.state.committed = defaults;
  result.state.pendingDirty = true;

  IOSLinearHDRToneValues pending;
  if(!iosLinearHDRDeriveToneValues(raw,pending)) {
    result.usedDefaults = true;
    return result;
    }
  result.state.lastKnownGood = raw;
  result.state.pending = pending;
  result.usedDefaults = false;
  return result;
  }

IOSLinearHDRSettingsUpdateResult iosLinearHDRQueueSettingsUpdate(
    IOSLinearHDRSettingsState state,
    IOSLinearHDRRawSettings raw) noexcept {
  IOSLinearHDRSettingsUpdateResult result;
  result.state = state;
  IOSLinearHDRToneValues pending;
  if(!iosLinearHDRDeriveToneValues(raw,pending)) {
    result.acceptance =
        IOSLinearHDRSettingsAcceptance::RejectedNonFinite;
    return result;
    }
  result.state.lastKnownGood = raw;
  result.state.pending = pending;
  result.state.pendingDirty = true;
  result.acceptance = IOSLinearHDRSettingsAcceptance::Accepted;
  return result;
  }

IOSLinearHDRSettingsCommitResult iosLinearHDRCommitSettingsAtFrameBoundary(
    IOSLinearHDRSettingsState state) noexcept {
  IOSLinearHDRSettingsCommitResult result;
  result.state = state;
  if(!state.pendingDirty)
    return result;
  if(!iosLinearHDRToneValuesAreValid(state.pending))
    return result;
  result.state.committed = state.pending;
  result.state.pendingDirty = false;
  result.committedPending = true;
  return result;
  }

bool iosLinearHDRLift(
    IOSLinearHDRRGB currentLdrRgb,
    IOSLinearHDRRGB& sceneRgb) noexcept {
  if(!finite(currentLdrRgb))
    return false;
  IOSLinearHDRRGB candidate;
  candidate.r = acesTonemapInverse(
      std::pow(clamp01(currentLdrRgb.r),2.2f));
  candidate.g = acesTonemapInverse(
      std::pow(clamp01(currentLdrRgb.g),2.2f));
  candidate.b = acesTonemapInverse(
      std::pow(clamp01(currentLdrRgb.b),2.2f));
  if(!finite(candidate))
    return false;
  sceneRgb = candidate;
  return true;
  }

bool iosLinearHDRResolve(
    IOSLinearHDRRGB sceneRgb,
    IOSLinearHDRToneValues values,
    float dither,
    IOSLinearHDRRGB& resolvedRgb) noexcept {
  if(!finite(sceneRgb) || !iosLinearHDRToneValuesAreValid(values) ||
     !std::isfinite(dither) || dither<MinimumDither || dither>=MaximumDither)
    return false;
  IOSLinearHDRRGB candidate = {
      resolveComponent(sceneRgb.r,values,dither),
      resolveComponent(sceneRgb.g,values,dither),
      resolveComponent(sceneRgb.b,values,dither),
      };
  if(!finite(candidate))
    return false;
  resolvedRgb = candidate;
  return true;
  }

float iosLinearHDRDither(float pixelCenterX, float pixelCenterY) noexcept {
  if(!std::isfinite(pixelCenterX) || !std::isfinite(pixelCenterY))
    return std::numeric_limits<float>::quiet_NaN();
  const auto fract = [](float value) noexcept {
    return value-std::floor(value);
    };
  const float inner = fract(
      0.06711056f*pixelCenterX+0.00583715f*pixelCenterY);
  const float noise = fract(52.9829189f*inner);
  return (noise*2.f-1.f)/255.f;
  }

IOSLinearHDRRGB iosLinearHDRQuantizeRG11B10(
    IOSLinearHDRRGB sceneRgb) noexcept {
  return {
      quantizeUnsignedFloat(sceneRgb.r,6),
      quantizeUnsignedFloat(sceneRgb.g,6),
      quantizeUnsignedFloat(sceneRgb.b,5),
      };
  }

IOSLinearHDRRGB iosLinearHDRQuantizeBGRA8(
    IOSLinearHDRRGB resolvedRgb) noexcept {
  return {
      quantizeUnorm8(resolvedRgb.r),
      quantizeUnorm8(resolvedRgb.g),
      quantizeUnorm8(resolvedRgb.b),
      };
  }

float iosLinearHDRMaximumAbsoluteError(
    IOSLinearHDRRGB lhs,
    IOSLinearHDRRGB rhs) noexcept {
  return std::max({
      std::abs(lhs.r-rhs.r),
      std::abs(lhs.g-rhs.g),
      std::abs(lhs.b-rhs.b),
      });
  }

IOSLinearHDRPolicyState iosEvaluateLinearHDRPolicy(
    bool requested,
    IOSLinearHDRProbeResult probe,
    IOSLinearHDRActivationStatus activation) noexcept {
  IOSLinearHDRPolicyState state;
  state.requested = requested;
  if(!requested)
    return state;

  if(!validProbeReason(probe.reason()) ||
     probe.reason()==IOSLinearHDRProbeReason::FactoryFailed) {
    state.reason = IOSLinearHDRPolicyReason::ProbeFactoryFailed;
    return state;
    }
  if((probe.knownUsages()&IOSLinearHDRRequiredProbeUsages)!=
       IOSLinearHDRRequiredProbeUsages) {
    state.reason = IOSLinearHDRPolicyReason::ProbeUnknown;
    return state;
    }
  if((probe.supportedUsages()&IOSLinearHDRRequiredProbeUsages)!=
       IOSLinearHDRRequiredProbeUsages) {
    state.reason = IOSLinearHDRPolicyReason::ProbeUnsupported;
    return state;
    }

  state.probeReady = true;
  if(!activation.targetReady) {
    state.reason = IOSLinearHDRPolicyReason::TargetFactoryFailed;
    return state;
    }
  if(!activation.scenePipelineReady) {
    state.reason = IOSLinearHDRPolicyReason::ScenePipelineFailed;
    return state;
    }
  if(!activation.resolvePipelineReady) {
    state.reason = IOSLinearHDRPolicyReason::ResolvePipelineFailed;
    return state;
    }

  state.ready = true;
  state.reason = IOSLinearHDRPolicyReason::Ready;
  return state;
  }

IOSLinearHDRSafetyTransition iosAdvanceLinearHDRSafetyState(
    IOSLinearHDRSafetyState current,
    IOSLinearHDRActivationAttempt attempt,
    IOSLinearHDRPolicyState policy) noexcept {
  IOSLinearHDRSafetyTransition result;
  result.state = current;
  if(!validSafetyMode(current.mode)) {
    result.state.mode = IOSLinearHDRSafetyMode::SafeNoScene;
    result.enteredSafeNoScene = true;
    return result;
    }

  if(current.mode==IOSLinearHDRSafetyMode::SafeNoScene) {
    result.state.mode = IOSLinearHDRSafetyMode::SafeNoScene;
    result.protocolValid = validAttempt(attempt) && canonicalPolicy(policy);
    return result;
    }

  const bool expectedAttempt =
      (current.mode==IOSLinearHDRSafetyMode::AwaitingStartup &&
       attempt==IOSLinearHDRActivationAttempt::Startup) ||
      (current.mode==IOSLinearHDRSafetyMode::Ready &&
       attempt==IOSLinearHDRActivationAttempt::Recreate);
  if(!validAttempt(attempt) || !expectedAttempt || !canonicalPolicy(policy)) {
    result.state.mode = IOSLinearHDRSafetyMode::SafeNoScene;
    result.enteredSafeNoScene = true;
    return result;
    }

  result.protocolValid = true;
  if(policy.ready) {
    result.state.mode = IOSLinearHDRSafetyMode::Ready;
    return result;
    }
  result.state.mode = IOSLinearHDRSafetyMode::SafeNoScene;
  result.enteredSafeNoScene = true;
  return result;
  }

bool iosLinearHDRWorkIsAllowed(
    IOSLinearHDRSafetyState safety,
    IOSLinearHDRWork work,
    bool hasCurrentExtentDepth) noexcept {
  if(!validSafetyMode(safety.mode) || !validWork(work))
    return false;
  switch(work) {
    case IOSLinearHDRWork::NativeSceneHDR:
    case IOSLinearHDRWork::ToneResolve:
      return safety.mode==IOSLinearHDRSafetyMode::Ready;
    case IOSLinearHDRWork::DirectLdrScene:
      return false;
    case IOSLinearHDRWork::DrawableClear:
    case IOSLinearHDRWork::LdrUI:
    case IOSLinearHDRWork::LdrCounters:
    case IOSLinearHDRWork::Bink:
      return true;
    case IOSLinearHDRWork::Inventory3D:
      return hasCurrentExtentDepth;
    }
  return false;
  }

bool iosLinearHDRCheckedTargetByteSize(
    IOSLinearHDRExtent extent,
    uint64_t& byteSize) noexcept {
  if(extent.width==0u || extent.height==0u)
    return false;
  const uint64_t pixels =
      uint64_t(extent.width)*uint64_t(extent.height);
  if(pixels>std::numeric_limits<uint64_t>::max()/
                IOSLinearHDRBytesPerPixel)
    return false;
  byteSize = pixels*IOSLinearHDRBytesPerPixel;
  return true;
  }

IOSFramePlan iosLinearHDRStructuralFramePlan(
    IOSLinearHDRExtent extent,
    IOSPixelFormat depthFormat) {
  IOSFramePlan plan;
  if(extent.width==0u || extent.height==0u ||
     (depthFormat!=IOSPixelFormat::Depth16Unorm &&
      depthFormat!=IOSPixelFormat::Depth32Float))
    return plan;

  const IOSExtent2D frameExtent{extent.width,extent.height};
  plan.resources = {
    {
      IOSLinearHDRSceneColorResource,
      IOSResourceKind::Texture,
      IOSResourceLifetime::Persistent,
      IOSInitialContent::Undefined,
      false,false,{},
      {IOSPixelFormat::Rg11B10Float,frameExtent,1u,1u,0u},
      IOSResourceUsage::RenderAttachment|IOSResourceUsage::ShaderRead,
    },
    {
      IOSLinearHDRSceneDepthResource,
      IOSResourceKind::Texture,
      IOSResourceLifetime::Persistent,
      IOSInitialContent::Undefined,
      false,false,{},
      {depthFormat,frameExtent,1u,1u,0u},
      IOSResourceUsage::RenderAttachment,
    },
    {
      IOSLinearHDRDrawableResource,
      IOSResourceKind::Texture,
      IOSResourceLifetime::External,
      IOSInitialContent::Defined,
      false,false,{},
      {IOSPixelFormat::Bgra8Unorm,frameExtent,1u,1u,0u},
      IOSResourceUsage::RenderAttachment|IOSResourceUsage::Present,
    },
  };
  plan.passes = {
    {
      IOSLinearHDRScenePass,IOSPassKind::Render,
      {
        {IOSLinearHDRSceneColorResource,
         IOSUseSemantic::RenderAttachment,
         IOSLoadAction::Clear,IOSStoreAction::Store,
         IOSAttachmentWriteMode::FullOverwrite},
        {IOSLinearHDRSceneDepthResource,
         IOSUseSemantic::RenderAttachment,
         IOSLoadAction::Clear,IOSStoreAction::Discard,
         IOSAttachmentWriteMode::MayPreserve},
      },
    },
    {
      IOSLinearHDRToneResolvePass,IOSPassKind::Render,
      {
        {IOSLinearHDRSceneColorResource,
         IOSUseSemantic::Read,
         IOSLoadAction::NotApplicable,IOSStoreAction::NotApplicable,
         IOSAttachmentWriteMode::NotApplicable},
        {IOSLinearHDRDrawableResource,
         IOSUseSemantic::RenderAttachment,
         IOSLoadAction::Discard,IOSStoreAction::Store,
         IOSAttachmentWriteMode::FullOverwrite},
      },
    },
    {
      IOSLinearHDROverlayPass,IOSPassKind::Render,
      {
        {IOSLinearHDRDrawableResource,
         IOSUseSemantic::RenderAttachment,
         IOSLoadAction::Load,IOSStoreAction::Store,
         IOSAttachmentWriteMode::MayPreserve},
      },
    },
    {
      IOSLinearHDRPresentPass,IOSPassKind::Present,
      {
        {IOSLinearHDRDrawableResource,
         IOSUseSemantic::PresentSource,
         IOSLoadAction::NotApplicable,IOSStoreAction::NotApplicable,
         IOSAttachmentWriteMode::NotApplicable},
      },
    },
  };
  return plan;
  }

IOSLinearHDRFrameSequenceBeginResult iosBeginLinearHDRFrameSequence(
    IOSLinearHDRFrameRoute route,
    IOSLinearHDRFrameIdentity identity) noexcept {
  IOSLinearHDRFrameSequenceBeginResult result;
  if(!validRoute(route)) {
    result.error = IOSLinearHDRFrameError::InvalidRoute;
    return result;
    }
  if(identity.extent.width==0u || identity.extent.height==0u) {
    result.error = IOSLinearHDRFrameError::InvalidExtent;
    return result;
    }
  uint64_t unusedByteSize = 0u;
  if(!iosLinearHDRCheckedTargetByteSize(identity.extent,unusedByteSize)) {
    result.error = IOSLinearHDRFrameError::ByteSizeOverflow;
    return result;
    }
  if(route==IOSLinearHDRFrameRoute::Scene &&
     (identity.targetGeneration==0u || identity.snapshotSequence==0u)) {
    result.error = IOSLinearHDRFrameError::InvalidIdentity;
    return result;
    }

  result.sequence.identity_ = identity;
  result.sequence.route_ = route;
  result.sequence.stage_ = IOSLinearHDRFrameStage::Begun;
  result.sequence.failure_ = IOSLinearHDRFrameError::None;
  result.sequence.completedStages_ = 0u;
  result.sequence.overlayHasUI_ = false;
  result.sequence.valid_ = true;
  result.error = IOSLinearHDRFrameError::None;
  return result;
  }

IOSLinearHDRFrameError iosAdvanceLinearHDRFrameSequence(
    IOSLinearHDRFrameSequence& sequence,
    IOSLinearHDRFrameEvent event,
    IOSLinearHDRFrameIdentity identity,
    bool overlayHasUI) noexcept {
  const auto fail = [&sequence](IOSLinearHDRFrameError failure) noexcept {
    sequence.stage_ = IOSLinearHDRFrameStage::TerminalFailed;
    sequence.failure_ = failure;
    return failure;
    };
  if(!sequence.valid_ || sequence.stage_==IOSLinearHDRFrameStage::Invalid)
    return IOSLinearHDRFrameError::InvalidSequence;
  if(terminal(sequence.stage_))
    return IOSLinearHDRFrameError::AlreadyTerminal;
  if(!validEvent(event))
    return fail(IOSLinearHDRFrameError::InvalidEvent);
  if(identity.targetGeneration!=sequence.identity_.targetGeneration)
    return fail(IOSLinearHDRFrameError::TargetGenerationMismatch);
  if(identity.snapshotSequence!=sequence.identity_.snapshotSequence)
    return fail(IOSLinearHDRFrameError::SnapshotSequenceMismatch);
  if(identity.extent!=sequence.identity_.extent)
    return fail(IOSLinearHDRFrameError::ExtentMismatch);
  if(event!=IOSLinearHDRFrameEvent::LdrOverlay && overlayHasUI)
    return fail(IOSLinearHDRFrameError::InvalidEvent);

  if(event==IOSLinearHDRFrameEvent::TerminalFailed) {
    sequence.stage_ = IOSLinearHDRFrameStage::TerminalFailed;
    sequence.failure_ = IOSLinearHDRFrameError::TerminalFailure;
    return IOSLinearHDRFrameError::TerminalFailure;
    }

  const bool bypass = sequence.route_!=IOSLinearHDRFrameRoute::Scene;
  if(bypass &&
     (event==IOSLinearHDRFrameEvent::SceneHDR ||
      event==IOSLinearHDRFrameEvent::ToneResolve))
    return fail(IOSLinearHDRFrameError::BypassRejectsLinearStage);

  switch(event) {
    case IOSLinearHDRFrameEvent::SceneHDR:
      if(sequence.route_!=IOSLinearHDRFrameRoute::Scene ||
         sequence.stage_!=IOSLinearHDRFrameStage::Begun)
        return fail(IOSLinearHDRFrameError::WrongOrder);
      sequence.stage_ = IOSLinearHDRFrameStage::SceneHDR;
      sequence.completedStages_ |= IOSLinearHDRFrameSequence::SceneBit;
      return IOSLinearHDRFrameError::None;
    case IOSLinearHDRFrameEvent::ToneResolve:
      if(sequence.route_!=IOSLinearHDRFrameRoute::Scene ||
         sequence.stage_!=IOSLinearHDRFrameStage::SceneHDR)
        return fail(IOSLinearHDRFrameError::WrongOrder);
      sequence.stage_ = IOSLinearHDRFrameStage::ToneResolve;
      sequence.completedStages_ |= IOSLinearHDRFrameSequence::ResolveBit;
      return IOSLinearHDRFrameError::None;
    case IOSLinearHDRFrameEvent::LdrOverlay:
      if((!bypass && sequence.stage_!=IOSLinearHDRFrameStage::ToneResolve) ||
         (bypass && sequence.stage_!=IOSLinearHDRFrameStage::Begun))
        return fail(IOSLinearHDRFrameError::WrongOrder);
      sequence.stage_ = IOSLinearHDRFrameStage::LdrOverlay;
      sequence.completedStages_ |= IOSLinearHDRFrameSequence::OverlayBit;
      sequence.overlayHasUI_ = overlayHasUI;
      return IOSLinearHDRFrameError::None;
    case IOSLinearHDRFrameEvent::Present:
      if(sequence.stage_!=IOSLinearHDRFrameStage::LdrOverlay)
        return fail(IOSLinearHDRFrameError::WrongOrder);
      sequence.stage_ = IOSLinearHDRFrameStage::Present;
      sequence.completedStages_ |= IOSLinearHDRFrameSequence::PresentBit;
      return IOSLinearHDRFrameError::None;
    case IOSLinearHDRFrameEvent::TerminalCompleted:
      if(sequence.stage_!=IOSLinearHDRFrameStage::Present)
        return fail(IOSLinearHDRFrameError::WrongOrder);
      sequence.stage_ = IOSLinearHDRFrameStage::TerminalCompleted;
      return IOSLinearHDRFrameError::None;
    case IOSLinearHDRFrameEvent::TerminalFailed:
      break;
    }
  return fail(IOSLinearHDRFrameError::InvalidEvent);
  }

bool iosLinearHDRFrameSequenceCanProve(
    const IOSLinearHDRFrameSequence& sequence) noexcept {
  constexpr uint8_t AllStages =
      IOSLinearHDRFrameSequence::SceneBit |
      IOSLinearHDRFrameSequence::ResolveBit |
      IOSLinearHDRFrameSequence::OverlayBit |
      IOSLinearHDRFrameSequence::PresentBit;
  return sequence.valid_ &&
      sequence.failure_==IOSLinearHDRFrameError::None &&
      sequence.route_==IOSLinearHDRFrameRoute::Scene &&
      sequence.stage_==IOSLinearHDRFrameStage::TerminalCompleted &&
      sequence.completedStages_==AllStages;
  }

bool iosLinearHDRCommitProvenEvidence(
    bool policyWasReadyAtEncode,
    const IOSLinearHDRFrameSequence& sequence,
    IOSLinearHDRProvenEvidence& evidence) noexcept {
  if(evidence.proven || !policyWasReadyAtEncode ||
     !iosLinearHDRFrameSequenceCanProve(sequence))
    return false;
  evidence.identity = sequence.identity();
  evidence.proven = true;
  return true;
  }
