#include "graphics/ioslinearhdr.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace {

constexpr IOSLinearHDRRawSettings Defaults{};
constexpr IOSLinearHDRActivationStatus ActivationReady{true,true,true};
constexpr IOSLinearHDRFrameIdentity SceneIdentity{
    7u,19u,{1920u,1080u}};

bool close(float lhs, float rhs, float tolerance = 1.0e-6f) noexcept {
  return std::abs(lhs-rhs)<=tolerance;
  }

bool finite(IOSLinearHDRRGB value) noexcept {
  return std::isfinite(value.r) &&
      std::isfinite(value.g) &&
      std::isfinite(value.b);
  }

IOSLinearHDRToneValues defaultToneValues() {
  IOSLinearHDRToneValues values;
  assert(iosLinearHDRDeriveToneValues(Defaults,values));
  return values;
  }

IOSLinearHDRPolicyState readyPolicy() {
  return iosEvaluateLinearHDRPolicy(
      true,IOSLinearHDRProbeResult::success(),ActivationReady);
  }

IOSLinearHDRFrameSequence beginScene() {
  const IOSLinearHDRFrameSequenceBeginResult result =
      iosBeginLinearHDRFrameSequence(
          IOSLinearHDRFrameRoute::Scene,SceneIdentity);
  assert(result);
  return result.sequence;
  }

void advance(
    IOSLinearHDRFrameSequence& sequence,
    IOSLinearHDRFrameEvent event,
    IOSLinearHDRFrameIdentity identity = SceneIdentity,
    bool overlayHasUI = false) {
  assert(iosAdvanceLinearHDRFrameSequence(
             sequence,event,identity,overlayHasUI)==
         IOSLinearHDRFrameError::None);
  }

void testFrozenConstantsAndLayout() {
  static_assert(IOSLinearHDRContractVersion==1u);
  static_assert(IOSLinearHDRRequiredProbeUsages==0x03u);
  static_assert(IOSLinearHDRBytesPerPixel==4u);
  static_assert(IOSLinearHDRIdealTolerance==2.0e-5f);
  static_assert(IOSLinearHDRRG11B10Tolerance==2.0f/255.0f);
  static_assert(IOSLinearHDRFinalTolerance==3.0f/255.0f);
  static_assert(IOSLinearHDRTightRG11B10MutationTolerance==1.0f/255.0f);
  static_assert(IOSLinearHDRTightFinalMutationTolerance==2.0f/255.0f);
  static_assert(IOSLinearHDRB10BoundaryEncoded==0.643773f);

  static_assert(sizeof(IOSLinearHDRToneValues)==16u);
  static_assert(alignof(IOSLinearHDRToneValues)==alignof(float));
  static_assert(std::is_standard_layout_v<IOSLinearHDRToneValues>);
  static_assert(std::is_trivially_copyable_v<IOSLinearHDRToneValues>);
  static_assert(!std::is_aggregate_v<IOSLinearHDRProbeResult>);
  static_assert(std::is_standard_layout_v<IOSLinearHDRProbeResult>);
  static_assert(std::is_trivially_copyable_v<IOSLinearHDRProbeResult>);
  static_assert(std::is_standard_layout_v<IOSLinearHDRFrameSequence>);
  static_assert(std::is_trivially_copyable_v<IOSLinearHDRFrameSequence>);
  static_assert(std::is_trivially_destructible_v<IOSLinearHDRFrameSequence>);
  static_assert(sizeof(IOSLinearHDRFrameSequence)<=48u);
  }

void testSettingsContract() {
  struct DerivationCase final {
    IOSLinearHDRRawSettings raw;
    IOSLinearHDRToneValues expected;
    };
  constexpr std::array<DerivationCase,3u> Cases = {{
      {{0.f,0.f,0.f},{-0.05f,1.5f,(1.f/2.2f)/0.01f,1.f}},
      {{0.5f,0.5f,0.5f},{0.f,1.f,1.f/2.2f,1.f}},
      {{1.f,1.f,1.f},{0.05f,0.5f,(1.f/2.2f)/2.f,1.f}},
      }};
  for(const DerivationCase& test:Cases) {
    IOSLinearHDRToneValues values;
    assert(iosLinearHDRDeriveToneValues(test.raw,values));
    assert(close(values.brightness,test.expected.brightness));
    assert(close(values.contrast,test.expected.contrast));
    assert(close(values.gamma,test.expected.gamma));
    assert(std::bit_cast<uint32_t>(values.exposure)==
           std::bit_cast<uint32_t>(1.f));
    assert(iosLinearHDRToneValuesAreValid(values));
    }
  constexpr std::array<float,3u> Endpoints = {0.f,0.5f,1.f};
  for(const float brightness:Endpoints) {
    for(const float contrast:Endpoints) {
      for(const float gamma:Endpoints) {
        IOSLinearHDRToneValues values;
        assert(iosLinearHDRDeriveToneValues(
            {brightness,contrast,gamma},values));
        assert(iosLinearHDRToneValuesAreValid(values));
        assert(std::isfinite(values.brightness));
        assert(std::isfinite(values.contrast));
        assert(std::isfinite(values.gamma));
        assert(std::isfinite(values.exposure));
        }
      }
    }

  IOSLinearHDRToneValues clamped;
  assert(iosLinearHDRDeriveToneValues({-5.f,2.f,20.f},clamped));
  assert(close(clamped.brightness,-0.05f));
  assert(close(clamped.contrast,0.5f));
  assert(close(clamped.gamma,(1.f/2.2f)/2.f));

  const float nan = std::numeric_limits<float>::quiet_NaN();
  const float infinity = std::numeric_limits<float>::infinity();
  IOSLinearHDRToneValues untouched{11.f,12.f,13.f,14.f};
  assert(!iosLinearHDRDeriveToneValues({nan,0.5f,0.5f},untouched));
  assert((untouched==IOSLinearHDRToneValues{11.f,12.f,13.f,14.f}));
  assert(!iosLinearHDRDeriveToneValues({0.5f,infinity,0.5f},untouched));
  assert(!iosLinearHDRDeriveToneValues({0.5f,0.5f,-infinity},untouched));

  const IOSLinearHDRSettingsLoadResult invalidInitial =
      iosLinearHDRLoadSettings({nan,1.f,0.f});
  assert(invalidInitial.usedDefaults);
  assert(invalidInitial.state.lastKnownGood==Defaults);
  assert(invalidInitial.state.pending==defaultToneValues());
  assert(invalidInitial.state.committed==defaultToneValues());
  assert(invalidInitial.state.pendingDirty);

  const IOSLinearHDRRawSettings initialRaw{-4.f,0.25f,8.f};
  IOSLinearHDRSettingsLoadResult loaded =
      iosLinearHDRLoadSettings(initialRaw);
  assert(!loaded.usedDefaults);
  assert(loaded.state.lastKnownGood==initialRaw);
  assert(loaded.state.committed==defaultToneValues());
  assert(loaded.state.pendingDirty);
  assert(loaded.state.pending!=loaded.state.committed);

  IOSLinearHDRSettingsUpdateResult rejected =
      iosLinearHDRQueueSettingsUpdate(
          loaded.state,{0.1f,nan,0.9f});
  assert(rejected.acceptance==
         IOSLinearHDRSettingsAcceptance::RejectedNonFinite);
  assert(rejected.state==loaded.state);

  IOSLinearHDRSettingsUpdateResult accepted =
      iosLinearHDRQueueSettingsUpdate(
          loaded.state,{0.8f,0.2f,0.4f});
  assert(accepted.acceptance==IOSLinearHDRSettingsAcceptance::Accepted);
  assert((accepted.state.lastKnownGood==
          IOSLinearHDRRawSettings{0.8f,0.2f,0.4f}));
  assert(accepted.state.committed==loaded.state.committed);
  assert(accepted.state.pending!=accepted.state.committed);
  assert(accepted.state.pendingDirty);

  const IOSLinearHDRSettingsCommitResult committed =
      iosLinearHDRCommitSettingsAtFrameBoundary(accepted.state);
  assert(committed.committedPending);
  assert(!committed.state.pendingDirty);
  assert(committed.state.committed==accepted.state.pending);
  const IOSLinearHDRSettingsCommitResult noRefresh =
      iosLinearHDRCommitSettingsAtFrameBoundary(committed.state);
  assert(!noRefresh.committedPending);
  assert(noRefresh.state==committed.state);

  IOSLinearHDRSettingsState corrupted = committed.state;
  corrupted.pending.gamma = nan;
  corrupted.pendingDirty = true;
  const IOSLinearHDRSettingsCommitResult failClosed =
      iosLinearHDRCommitSettingsAtFrameBoundary(corrupted);
  assert(!failClosed.committedPending);
  assert(failClosed.state.lastKnownGood==corrupted.lastKnownGood);
  assert(failClosed.state.committed==corrupted.committed);
  assert(close(failClosed.state.pending.brightness,
               corrupted.pending.brightness));
  assert(close(failClosed.state.pending.contrast,
               corrupted.pending.contrast));
  assert(std::isnan(failClosed.state.pending.gamma));
  assert(close(failClosed.state.pending.exposure,
               corrupted.pending.exposure));
  assert(failClosed.state.pendingDirty);
  }

void testLiftResolveContract() {
  constexpr std::array<IOSLinearHDRRGB,9u> Colors = {{
      {0.f,0.f,0.f},
      {1.0e-6f,2.0e-5f,1.0e-4f},
      {0.02f,0.04f,0.08f},
      {0.18f,0.35f,0.5f},
      {0.643773f,0.643773f,0.643773f},
      {0.9f,0.95f,0.99f},
      {1.f,1.f,1.f},
      {1.f,0.25f,0.03f},
      {-1.f,0.5f,2.f},
      }};
  const IOSLinearHDRToneValues tone = defaultToneValues();
  bool sawSceneAboveOne = false;
  for(const IOSLinearHDRRGB source:Colors) {
    IOSLinearHDRRGB scene;
    IOSLinearHDRRGB resolved;
    assert(iosLinearHDRLift(source,scene));
    assert(finite(scene));
    sawSceneAboveOne = sawSceneAboveOne ||
        scene.r>1.f || scene.g>1.f || scene.b>1.f;
    assert(iosLinearHDRResolve(scene,tone,0.f,resolved));
    const IOSLinearHDRRGB clamped = {
        std::clamp(source.r,0.f,1.f),
        std::clamp(source.g,0.f,1.f),
        std::clamp(source.b,0.f,1.f),
        };
    assert(iosLinearHDRMaximumAbsoluteError(resolved,clamped)<=
           IOSLinearHDRIdealTolerance);
    }
  assert(sawSceneAboveOne);

  const float nan = std::numeric_limits<float>::quiet_NaN();
  IOSLinearHDRRGB untouched{7.f,8.f,9.f};
  assert(!iosLinearHDRLift({nan,0.f,0.f},untouched));
  assert((untouched==IOSLinearHDRRGB{7.f,8.f,9.f}));
  assert(!iosLinearHDRResolve({nan,0.f,0.f},tone,0.f,untouched));
  assert(!iosLinearHDRResolve({0.f,0.f,0.f},tone,nan,untouched));
  assert(!iosLinearHDRResolve(
      {0.f,0.f,0.f},tone,1.f/255.f,untouched));
  IOSLinearHDRToneValues invalidTone = tone;
  invalidTone.gamma = nan;
  assert(!iosLinearHDRResolve({0.f,0.f,0.f},invalidTone,0.f,untouched));
  invalidTone = tone;
  invalidTone.exposure = std::nextafter(1.f,2.f);
  assert(!iosLinearHDRResolve({0.f,0.f,0.f},invalidTone,0.f,untouched));
  assert((untouched==IOSLinearHDRRGB{7.f,8.f,9.f}));

  IOSLinearHDRRGB whiteScene;
  assert(iosLinearHDRLift({1.f,1.f,1.f},whiteScene));
  assert(whiteScene.r>1.f && whiteScene.g>1.f && whiteScene.b>1.f);
  assert(iosLinearHDRMaximumAbsoluteError(
             whiteScene,{1.f,1.f,1.f})>IOSLinearHDRIdealTolerance);

  IOSLinearHDRRGB clampedScene = {
      std::min(whiteScene.r,1.f),
      std::min(whiteScene.g,1.f),
      std::min(whiteScene.b,1.f),
      };
  IOSLinearHDRRGB clampedResolved;
  assert(iosLinearHDRResolve(clampedScene,tone,0.f,clampedResolved));
  assert(iosLinearHDRMaximumAbsoluteError(
             clampedResolved,{1.f,1.f,1.f})>
         IOSLinearHDRIdealTolerance);

  IOSLinearHDRRGB middleScene;
  assert(iosLinearHDRLift({0.5f,0.5f,0.5f},middleScene));
  assert(iosLinearHDRMaximumAbsoluteError(
             middleScene,{0.5f,0.5f,0.5f})>
         IOSLinearHDRIdealTolerance);
  assert(std::abs(middleScene.r-0.5f)>IOSLinearHDRIdealTolerance);

  constexpr std::array<float,3u> Endpoints = {0.f,0.5f,1.f};
  for(const float brightness:Endpoints) {
    for(const float contrast:Endpoints) {
      for(const float gamma:Endpoints) {
        IOSLinearHDRToneValues values;
        assert(iosLinearHDRDeriveToneValues(
            {brightness,contrast,gamma},values));
        for(const float dither:
            {-1.f/255.f,0.f,
             std::nextafter(1.f/255.f,-std::numeric_limits<float>::infinity())}) {
          IOSLinearHDRRGB endpointResolved;
          assert(iosLinearHDRResolve(
              {0.f,1.f,whiteScene.b},values,dither,endpointResolved));
          assert(finite(endpointResolved));
          }
        }
      }
    }
  }

void testDitherAndQuantizationContract() {
  constexpr std::array<std::array<float,2u>,8u> PixelCenters = {{
      {0.5f,0.5f},{1.5f,0.5f},{0.5f,1.5f},{23.5f,17.5f},
      {127.5f,63.5f},{511.5f,511.5f},{999.5f,3.5f},{1919.5f,1079.5f},
      }};
  for(const auto& pixel:PixelCenters) {
    const float inner =
        0.06711056f*pixel[0]+0.00583715f*pixel[1];
    const float innerFract = inner-std::floor(inner);
    const float noiseBase = 52.9829189f*innerFract;
    const float noise = noiseBase-std::floor(noiseBase);
    const float expected = (noise*2.f-1.f)/255.f;
    const float actual = iosLinearHDRDither(pixel[0],pixel[1]);
    assert(std::bit_cast<uint32_t>(actual)==
           std::bit_cast<uint32_t>(expected));
    assert(actual>=-1.f/255.f && actual<1.f/255.f);
    }
  assert(std::isnan(iosLinearHDRDither(
      std::numeric_limits<float>::quiet_NaN(),0.5f)));

  const IOSLinearHDRRGB encoded = {
      IOSLinearHDRB10BoundaryEncoded,
      IOSLinearHDRB10BoundaryEncoded,
      IOSLinearHDRB10BoundaryEncoded,
      };
  IOSLinearHDRRGB scene;
  assert(iosLinearHDRLift(encoded,scene));
  const IOSLinearHDRRGB quantized =
      iosLinearHDRQuantizeRG11B10(scene);
  assert(std::bit_cast<uint32_t>(quantized.b)==
         std::bit_cast<uint32_t>(0.25f));

  IOSLinearHDRRGB resolved;
  assert(iosLinearHDRResolve(
      quantized,defaultToneValues(),0.f,resolved));
  const float rg11b10Error =
      iosLinearHDRMaximumAbsoluteError(resolved,encoded);
  assert(rg11b10Error<=IOSLinearHDRRG11B10Tolerance);
  assert(rg11b10Error>IOSLinearHDRTightRG11B10MutationTolerance);

  float maximumFinalError = 0.f;
  for(uint32_t y=0u; y<64u; ++y) {
    for(uint32_t x=0u; x<64u; ++x) {
      IOSLinearHDRRGB dithered;
      assert(iosLinearHDRResolve(
          quantized,defaultToneValues(),
          iosLinearHDRDither(float(x)+0.5f,float(y)+0.5f),
          dithered));
      const IOSLinearHDRRGB final =
          iosLinearHDRQuantizeBGRA8(dithered);
      maximumFinalError = std::max(
          maximumFinalError,
          iosLinearHDRMaximumAbsoluteError(final,encoded));
      }
    }
  assert(maximumFinalError<=IOSLinearHDRFinalTolerance);
  assert(maximumFinalError>IOSLinearHDRTightFinalMutationTolerance);

  const IOSLinearHDRRGB bgra =
      iosLinearHDRQuantizeBGRA8({-1.f,0.5f,2.f});
  assert((bgra==IOSLinearHDRRGB{0.f,128.f/255.f,1.f}));
  }

void testProbeAndPolicyContract() {
  const IOSLinearHDRProbeResult success =
      IOSLinearHDRProbeResult::success();
  assert(success.reason()==IOSLinearHDRProbeReason::None);
  assert(success.knownUsages()==0x03u);
  assert(success.supportedUsages()==0x03u);

  const IOSLinearHDRProbeResult superset =
      IOSLinearHDRProbeResult::observed(0xFFu,0xFFu);
  assert(iosEvaluateLinearHDRPolicy(true,superset,ActivationReady).ready);
  const IOSLinearHDRProbeResult unsupported =
      IOSLinearHDRProbeResult::observed(0x03u,0x01u);
  const IOSLinearHDRProbeResult unknown =
      IOSLinearHDRProbeResult::observed(0x01u,0x03u);

  struct PolicyCase final {
    bool requested;
    IOSLinearHDRProbeResult probe;
    IOSLinearHDRActivationStatus activation;
    IOSLinearHDRPolicyReason reason;
    bool probeReady;
    bool ready;
    };
  const std::array<PolicyCase,8u> Cases = {{
      {false,IOSLinearHDRProbeResult::factoryFailed(),{false,false,false},
       IOSLinearHDRPolicyReason::NotRequested,false,false},
      {true,IOSLinearHDRProbeResult::factoryFailed(),{false,false,false},
       IOSLinearHDRPolicyReason::ProbeFactoryFailed,false,false},
      {true,unknown,{false,false,false},
       IOSLinearHDRPolicyReason::ProbeUnknown,false,false},
      {true,unsupported,{false,false,false},
       IOSLinearHDRPolicyReason::ProbeUnsupported,false,false},
      {true,success,{false,false,false},
       IOSLinearHDRPolicyReason::TargetFactoryFailed,true,false},
      {true,success,{true,false,false},
       IOSLinearHDRPolicyReason::ScenePipelineFailed,true,false},
      {true,success,{true,true,false},
       IOSLinearHDRPolicyReason::ResolvePipelineFailed,true,false},
      {true,success,{true,true,true},
       IOSLinearHDRPolicyReason::Ready,true,true},
      }};
  for(const PolicyCase& test:Cases) {
    const IOSLinearHDRPolicyState state = iosEvaluateLinearHDRPolicy(
        test.requested,test.probe,test.activation);
    assert(state.requested==test.requested);
    assert(state.probeReady==test.probeReady);
    assert(state.ready==test.ready);
    assert(state.reason==test.reason);
    }

  for(uint8_t bits=0u; bits<8u; ++bits) {
    const IOSLinearHDRActivationStatus activation = {
        (bits&0x01u)!=0u,(bits&0x02u)!=0u,(bits&0x04u)!=0u};
    const IOSLinearHDRPolicyState state =
        iosEvaluateLinearHDRPolicy(true,success,activation);
    const IOSLinearHDRPolicyReason expected = !activation.targetReady
        ? IOSLinearHDRPolicyReason::TargetFactoryFailed
        : !activation.scenePipelineReady
            ? IOSLinearHDRPolicyReason::ScenePipelineFailed
            : !activation.resolvePipelineReady
                ? IOSLinearHDRPolicyReason::ResolvePipelineFailed
                : IOSLinearHDRPolicyReason::Ready;
    assert(state.reason==expected);
    }

  IOSLinearHDRProvenEvidence evidence;
  assert(readyPolicy().ready);
  assert(!evidence.proven);
  }

void testSafeNoSceneContract() {
  const IOSLinearHDRPolicyState ready = readyPolicy();
  const IOSLinearHDRPolicyState failed = iosEvaluateLinearHDRPolicy(
      true,IOSLinearHDRProbeResult::success(),{true,false,true});
  assert(failed.reason==IOSLinearHDRPolicyReason::ScenePipelineFailed);
  const std::array<IOSLinearHDRPolicyState,8u> Policies = {
      iosEvaluateLinearHDRPolicy(
          false,IOSLinearHDRProbeResult::success(),ActivationReady),
      iosEvaluateLinearHDRPolicy(
          true,IOSLinearHDRProbeResult::factoryFailed(),ActivationReady),
      iosEvaluateLinearHDRPolicy(
          true,IOSLinearHDRProbeResult::observed(0x01u,0x03u),
          ActivationReady),
      iosEvaluateLinearHDRPolicy(
          true,IOSLinearHDRProbeResult::observed(0x03u,0x01u),
          ActivationReady),
      iosEvaluateLinearHDRPolicy(
          true,IOSLinearHDRProbeResult::success(),{false,true,true}),
      iosEvaluateLinearHDRPolicy(
          true,IOSLinearHDRProbeResult::success(),{true,false,true}),
      iosEvaluateLinearHDRPolicy(
          true,IOSLinearHDRProbeResult::success(),{true,true,false}),
      ready,
      };
  for(const IOSLinearHDRPolicyState policy:Policies) {
    for(const IOSLinearHDRSafetyMode origin:
        {IOSLinearHDRSafetyMode::AwaitingStartup,
         IOSLinearHDRSafetyMode::Ready}) {
      const IOSLinearHDRActivationAttempt attempt =
          origin==IOSLinearHDRSafetyMode::AwaitingStartup
              ? IOSLinearHDRActivationAttempt::Startup
              : IOSLinearHDRActivationAttempt::Recreate;
      const IOSLinearHDRSafetyTransition matrix =
          iosAdvanceLinearHDRSafetyState({origin},attempt,policy);
      assert(matrix.protocolValid);
      assert(matrix.state.mode==
             (policy.ready
                  ? IOSLinearHDRSafetyMode::Ready
                  : IOSLinearHDRSafetyMode::SafeNoScene));
      assert(matrix.enteredSafeNoScene==!policy.ready);
      }
    }

  IOSLinearHDRSafetyTransition transition = iosAdvanceLinearHDRSafetyState(
      {IOSLinearHDRSafetyMode::AwaitingStartup},
      IOSLinearHDRActivationAttempt::Startup,ready);
  assert(transition.protocolValid);
  assert(!transition.enteredSafeNoScene);
  assert(transition.state.mode==IOSLinearHDRSafetyMode::Ready);

  transition = iosAdvanceLinearHDRSafetyState(
      {IOSLinearHDRSafetyMode::AwaitingStartup},
      IOSLinearHDRActivationAttempt::Startup,failed);
  assert(transition.protocolValid);
  assert(transition.enteredSafeNoScene);
  assert(transition.state.mode==IOSLinearHDRSafetyMode::SafeNoScene);

  transition = iosAdvanceLinearHDRSafetyState(
      {IOSLinearHDRSafetyMode::Ready},
      IOSLinearHDRActivationAttempt::Recreate,ready);
  assert(transition.protocolValid);
  assert(transition.state.mode==IOSLinearHDRSafetyMode::Ready);
  transition = iosAdvanceLinearHDRSafetyState(
      {IOSLinearHDRSafetyMode::Ready},
      IOSLinearHDRActivationAttempt::Recreate,failed);
  assert(transition.protocolValid);
  assert(transition.enteredSafeNoScene);
  assert(transition.state.mode==IOSLinearHDRSafetyMode::SafeNoScene);

  for(const IOSLinearHDRSafetyMode mode:
      {IOSLinearHDRSafetyMode::AwaitingStartup,
       IOSLinearHDRSafetyMode::Ready}) {
    const IOSLinearHDRActivationAttempt wrong =
        mode==IOSLinearHDRSafetyMode::Ready
            ? IOSLinearHDRActivationAttempt::Startup
            : IOSLinearHDRActivationAttempt::Recreate;
    transition = iosAdvanceLinearHDRSafetyState({mode},wrong,ready);
    assert(!transition.protocolValid);
    assert(transition.enteredSafeNoScene);
    assert(transition.state.mode==IOSLinearHDRSafetyMode::SafeNoScene);
    }

  for(const IOSLinearHDRActivationAttempt attempt:
      {IOSLinearHDRActivationAttempt::Startup,
       IOSLinearHDRActivationAttempt::Recreate}) {
    transition = iosAdvanceLinearHDRSafetyState(
        {IOSLinearHDRSafetyMode::SafeNoScene},attempt,ready);
    assert(transition.protocolValid);
    assert(!transition.enteredSafeNoScene);
    assert(transition.state.mode==IOSLinearHDRSafetyMode::SafeNoScene);
    }

  for(const IOSLinearHDRSafetyMode mode:
      {IOSLinearHDRSafetyMode::AwaitingStartup,
       IOSLinearHDRSafetyMode::Ready,
       IOSLinearHDRSafetyMode::SafeNoScene}) {
    const IOSLinearHDRSafetyState safety{mode};
    assert(!iosLinearHDRWorkIsAllowed(
        safety,IOSLinearHDRWork::DirectLdrScene,false));
    assert(iosLinearHDRWorkIsAllowed(
        safety,IOSLinearHDRWork::DrawableClear,false));
    assert(iosLinearHDRWorkIsAllowed(
        safety,IOSLinearHDRWork::LdrUI,false));
    assert(iosLinearHDRWorkIsAllowed(
        safety,IOSLinearHDRWork::LdrCounters,false));
    assert(iosLinearHDRWorkIsAllowed(
        safety,IOSLinearHDRWork::Bink,false));
    assert(!iosLinearHDRWorkIsAllowed(
        safety,IOSLinearHDRWork::Inventory3D,false));
    assert(iosLinearHDRWorkIsAllowed(
        safety,IOSLinearHDRWork::Inventory3D,true));
    const bool sceneAllowed = mode==IOSLinearHDRSafetyMode::Ready;
    assert(iosLinearHDRWorkIsAllowed(
               safety,IOSLinearHDRWork::NativeSceneHDR,false)==sceneAllowed);
    assert(iosLinearHDRWorkIsAllowed(
               safety,IOSLinearHDRWork::ToneResolve,false)==sceneAllowed);
    }
  }

void testCheckedTargetByteSize() {
  uint64_t bytes = 0u;
  assert(iosLinearHDRCheckedTargetByteSize({1920u,1080u},bytes));
  assert(bytes==uint64_t(1920u)*1080u*4u);

  bytes = 0xA5A5u;
  assert(!iosLinearHDRCheckedTargetByteSize({0u,1080u},bytes));
  assert(bytes==0xA5A5u);
  assert(!iosLinearHDRCheckedTargetByteSize({1920u,0u},bytes));
  assert(bytes==0xA5A5u);
  assert(!iosLinearHDRCheckedTargetByteSize(
      {std::numeric_limits<uint32_t>::max(),
       std::numeric_limits<uint32_t>::max()},bytes));
  assert(bytes==0xA5A5u);
  }

void testStructuralFramePlanMirror() {
  IOSFramePlan plan = iosLinearHDRStructuralFramePlan(
      SceneIdentity.extent,IOSPixelFormat::Depth16Unorm);
  assert(plan.validate());
  assert(plan.resources.size()==3u);
  assert(plan.passes.size()==4u);
  assert(plan.resources[0].id==IOSLinearHDRSceneColorResource);
  assert(plan.resources[0].layout.format==IOSPixelFormat::Rg11B10Float);
  assert(plan.resources[1].id==IOSLinearHDRSceneDepthResource);
  assert(plan.resources[1].layout.format==IOSPixelFormat::Depth16Unorm);
  assert(plan.resources[2].id==IOSLinearHDRDrawableResource);
  assert(plan.resources[2].layout.format==IOSPixelFormat::Bgra8Unorm);
  assert(plan.passes[0].id==IOSLinearHDRScenePass);
  assert(plan.passes[1].id==IOSLinearHDRToneResolvePass);
  assert(plan.passes[2].id==IOSLinearHDROverlayPass);
  assert(plan.passes[3].id==IOSLinearHDRPresentPass);
  assert(plan.passes[0].uses[0].store==IOSStoreAction::Store);
  assert(plan.passes[1].uses[0].semantic==IOSUseSemantic::Read);
  assert(plan.passes[1].uses[1].load==IOSLoadAction::Discard);
  assert(plan.passes[2].uses[0].load==IOSLoadAction::Load);
  assert(plan.passes[3].uses[0].semantic==IOSUseSemantic::PresentSource);

  IOSFramePlan depth32 = iosLinearHDRStructuralFramePlan(
      SceneIdentity.extent,IOSPixelFormat::Depth32Float);
  assert(depth32.validate());
  assert(depth32.resources[1].layout.format==IOSPixelFormat::Depth32Float);

  IOSFramePlan invalidExtent = iosLinearHDRStructuralFramePlan(
      {0u,1080u},IOSPixelFormat::Depth16Unorm);
  assert(!invalidExtent.validate());
  IOSFramePlan invalidDepth = iosLinearHDRStructuralFramePlan(
      SceneIdentity.extent,IOSPixelFormat::Bgra8Unorm);
  assert(!invalidDepth.validate());

  IOSFramePlan uiBeforeResolve = plan;
  std::swap(uiBeforeResolve.passes[1],uiBeforeResolve.passes[2]);
  assert(!uiBeforeResolve.validate());
  }

void testSceneFrameSequenceAndEvidence() {
  IOSLinearHDRFrameSequence sequence = beginScene();
  assert(sequence.valid());
  assert(sequence.identity()==SceneIdentity);
  assert(sequence.route()==IOSLinearHDRFrameRoute::Scene);
  assert(sequence.stage()==IOSLinearHDRFrameStage::Begun);
  assert(!sequence.sceneEncoded());
  assert(!sequence.resolveEncoded());
  assert(!sequence.overlayEncoded());
  assert(!sequence.presentAccepted());
  assert(!iosLinearHDRFrameSequenceCanProve(sequence));

  IOSLinearHDRProvenEvidence evidence;
  assert(!iosLinearHDRCommitProvenEvidence(true,sequence,evidence));
  advance(sequence,IOSLinearHDRFrameEvent::SceneHDR);
  assert(sequence.sceneEncoded());
  assert(!iosLinearHDRFrameSequenceCanProve(sequence));
  advance(sequence,IOSLinearHDRFrameEvent::ToneResolve);
  assert(sequence.resolveEncoded());
  advance(sequence,IOSLinearHDRFrameEvent::LdrOverlay,SceneIdentity,true);
  assert(sequence.overlayEncoded());
  assert(sequence.overlayHasUI());
  advance(sequence,IOSLinearHDRFrameEvent::Present);
  assert(sequence.presentAccepted());
  assert(!iosLinearHDRFrameSequenceCanProve(sequence));
  advance(sequence,IOSLinearHDRFrameEvent::TerminalCompleted);
  assert(sequence.stage()==IOSLinearHDRFrameStage::TerminalCompleted);
  assert(iosLinearHDRFrameSequenceCanProve(sequence));
  assert(!iosLinearHDRCommitProvenEvidence(false,sequence,evidence));
  assert(!evidence.proven);
  assert(iosLinearHDRCommitProvenEvidence(true,sequence,evidence));
  assert(evidence.proven);
  assert(evidence.identity==SceneIdentity);
  assert(!iosLinearHDRCommitProvenEvidence(true,sequence,evidence));

  assert(iosAdvanceLinearHDRFrameSequence(
             sequence,IOSLinearHDRFrameEvent::TerminalCompleted,
             SceneIdentity)==IOSLinearHDRFrameError::AlreadyTerminal);
  }

void testFrameSequenceFailures() {
  IOSLinearHDRFrameSequenceBeginResult begin =
      iosBeginLinearHDRFrameSequence(
          static_cast<IOSLinearHDRFrameRoute>(0xFFu),SceneIdentity);
  assert(!begin);
  assert(begin.error==IOSLinearHDRFrameError::InvalidRoute);
  begin = iosBeginLinearHDRFrameSequence(
      IOSLinearHDRFrameRoute::Scene,{7u,19u,{0u,1080u}});
  assert(!begin && begin.error==IOSLinearHDRFrameError::InvalidExtent);
  begin = iosBeginLinearHDRFrameSequence(
      IOSLinearHDRFrameRoute::Scene,{0u,19u,{1920u,1080u}});
  assert(!begin && begin.error==IOSLinearHDRFrameError::InvalidIdentity);
  begin = iosBeginLinearHDRFrameSequence(
      IOSLinearHDRFrameRoute::Scene,{7u,0u,{1920u,1080u}});
  assert(!begin && begin.error==IOSLinearHDRFrameError::InvalidIdentity);
  begin = iosBeginLinearHDRFrameSequence(
      IOSLinearHDRFrameRoute::Scene,
      {7u,19u,{std::numeric_limits<uint32_t>::max(),
               std::numeric_limits<uint32_t>::max()}});
  assert(!begin && begin.error==IOSLinearHDRFrameError::ByteSizeOverflow);

  struct MismatchCase final {
    IOSLinearHDRFrameIdentity identity;
    IOSLinearHDRFrameError expected;
    };
  constexpr std::array<MismatchCase,3u> Mismatches = {{
      {{8u,19u,{1920u,1080u}},
       IOSLinearHDRFrameError::TargetGenerationMismatch},
      {{7u,20u,{1920u,1080u}},
       IOSLinearHDRFrameError::SnapshotSequenceMismatch},
      {{7u,19u,{1921u,1080u}},
       IOSLinearHDRFrameError::ExtentMismatch},
      }};
  for(const MismatchCase& test:Mismatches) {
    IOSLinearHDRFrameSequence sequence = beginScene();
    assert(iosAdvanceLinearHDRFrameSequence(
               sequence,IOSLinearHDRFrameEvent::SceneHDR,test.identity)==
           test.expected);
    assert(sequence.stage()==IOSLinearHDRFrameStage::TerminalFailed);
    assert(sequence.failure()==test.expected);
    assert(!iosLinearHDRFrameSequenceCanProve(sequence));
    }

  IOSLinearHDRFrameSequence wrongOrder = beginScene();
  assert(iosAdvanceLinearHDRFrameSequence(
             wrongOrder,IOSLinearHDRFrameEvent::LdrOverlay,
             SceneIdentity)==IOSLinearHDRFrameError::WrongOrder);
  assert(wrongOrder.stage()==IOSLinearHDRFrameStage::TerminalFailed);

  IOSLinearHDRFrameSequence duplicate = beginScene();
  advance(duplicate,IOSLinearHDRFrameEvent::SceneHDR);
  assert(iosAdvanceLinearHDRFrameSequence(
             duplicate,IOSLinearHDRFrameEvent::SceneHDR,
             SceneIdentity)==IOSLinearHDRFrameError::WrongOrder);

  IOSLinearHDRFrameSequence badUI = beginScene();
  assert(iosAdvanceLinearHDRFrameSequence(
             badUI,IOSLinearHDRFrameEvent::SceneHDR,
             SceneIdentity,true)==IOSLinearHDRFrameError::InvalidEvent);

  IOSLinearHDRFrameSequence terminalFailure = beginScene();
  advance(terminalFailure,IOSLinearHDRFrameEvent::SceneHDR);
  advance(terminalFailure,IOSLinearHDRFrameEvent::ToneResolve);
  advance(terminalFailure,IOSLinearHDRFrameEvent::LdrOverlay);
  advance(terminalFailure,IOSLinearHDRFrameEvent::Present);
  assert(iosAdvanceLinearHDRFrameSequence(
             terminalFailure,IOSLinearHDRFrameEvent::TerminalFailed,
             SceneIdentity)==IOSLinearHDRFrameError::TerminalFailure);
  assert(terminalFailure.stage()==IOSLinearHDRFrameStage::TerminalFailed);
  assert(!iosLinearHDRFrameSequenceCanProve(terminalFailure));
  }

void testBypassFrameSequences() {
  constexpr std::array<IOSLinearHDRFrameRoute,3u> Routes = {
      IOSLinearHDRFrameRoute::VideoBypass,
      IOSLinearHDRFrameRoute::NoWorldBypass,
      IOSLinearHDRFrameRoute::SafeNoSceneBypass,
      };
  constexpr IOSLinearHDRFrameIdentity BypassIdentity{0u,0u,{800u,600u}};
  for(const IOSLinearHDRFrameRoute route:Routes) {
    IOSLinearHDRFrameSequenceBeginResult begin =
        iosBeginLinearHDRFrameSequence(route,BypassIdentity);
    assert(begin);
    IOSLinearHDRFrameSequence linearRejected = begin.sequence;
    assert(iosAdvanceLinearHDRFrameSequence(
               linearRejected,IOSLinearHDRFrameEvent::SceneHDR,
               BypassIdentity)==
           IOSLinearHDRFrameError::BypassRejectsLinearStage);
    assert(linearRejected.stage()==IOSLinearHDRFrameStage::TerminalFailed);

    IOSLinearHDRFrameSequence sequence = begin.sequence;
    advance(sequence,IOSLinearHDRFrameEvent::LdrOverlay,
            BypassIdentity,true);
    advance(sequence,IOSLinearHDRFrameEvent::Present,BypassIdentity);
    advance(sequence,IOSLinearHDRFrameEvent::TerminalCompleted,
            BypassIdentity);
    assert(sequence.stage()==IOSLinearHDRFrameStage::TerminalCompleted);
    assert(!sequence.sceneEncoded());
    assert(!sequence.resolveEncoded());
    assert(sequence.overlayEncoded());
    assert(sequence.presentAccepted());
    assert(!iosLinearHDRFrameSequenceCanProve(sequence));
    IOSLinearHDRProvenEvidence evidence;
    assert(!iosLinearHDRCommitProvenEvidence(true,sequence,evidence));
    assert(!evidence.proven);
    }
  }

}

int main() {
  testFrozenConstantsAndLayout();
  testSettingsContract();
  testLiftResolveContract();
  testDitherAndQuantizationContract();
  testProbeAndPolicyContract();
  testSafeNoSceneContract();
  testCheckedTargetByteSize();
  testStructuralFramePlanMirror();
  testSceneFrameSequenceAndEvidence();
  testFrameSequenceFailures();
  testBypassFrameSequences();
  return 0;
  }
