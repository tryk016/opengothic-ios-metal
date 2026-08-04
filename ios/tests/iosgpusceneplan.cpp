#define OPENGOTHIC_RENDERER_IOS_FRAME_ANIMATION_HOST_TEST 1
#include "graphics/iosgpusceneplan.h"

#include <cassert>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string_view>
#include <utility>

namespace {

// Exact P2.1c2 compositional fixture, mirrored in iosscenecontract.cpp.
constexpr uint64_t MovableSourceId = 0x21C2u;

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
constexpr std::string_view CausalNonce =
    "0123456789abcdef0123456789abcdef";
constexpr const char* CausalNonceArgument =
    "-renderer-ios-native-alpha-test-causal-nonce="
    "0123456789abcdef0123456789abcdef";
constexpr const char* CausalSequenceArgument =
    "-renderer-ios-native-alpha-test-causal-sequence=300";

template<IOSGPUSceneMode Mode>
void testCausalArgumentsForMode(
    const char* modeArgument,
    const char* otherModeArgument) {
  const auto parse = [](
      const auto& arguments,
      IOSGPUSceneCausalArguments& output) {
    return iosGPUSceneParseCausalArgumentsForCompileMode<Mode>(
        static_cast<int>(arguments.size()),arguments.data(),output);
    };
  const IOSGPUSceneCausalArguments sentinel = {
    IOSGPUSceneMode::Production,
    {'s','e','n','t','i','n','e','l'},
    99u,
    };
  {
    const std::array arguments = {
      "Gothic2Notr",
      "-save",
      CausalSequenceArgument,
      "--unrelated",
      CausalNonceArgument,
      modeArgument,
      };
    IOSGPUSceneCausalArguments parsed = sentinel;
    assert(parse(arguments,parsed)==
           IOSGPUSceneCausalArgumentResult::Accepted);
    assert(parsed.mode==Mode);
    assert(std::string_view(parsed.nonce.data())==CausalNonce);
    assert(parsed.sequence==300u);
  }
  {
    const std::array arguments = {
      modeArgument,
      "-renderer-ios-native-alpha-test-causal-nonce="
      "ffffffffffffffffffffffffffffffff",
      "-renderer-ios-native-alpha-test-causal-sequence="
      "18446744073709551615",
      };
    IOSGPUSceneCausalArguments parsed = sentinel;
    assert(parse(arguments,parsed)==
           IOSGPUSceneCausalArgumentResult::Accepted);
    assert(parsed.mode==Mode);
    assert(std::string_view(parsed.nonce.data())==
           "ffffffffffffffffffffffffffffffff");
    assert(parsed.sequence==std::numeric_limits<uint64_t>::max());
  }

  const auto assertRejected = [&](
      const auto& arguments,
      IOSGPUSceneCausalArgumentResult expected) {
    IOSGPUSceneCausalArguments parsed = sentinel;
    assert(parse(arguments,parsed)==expected);
    assert(parsed==sentinel);
    };
  assertRejected(
      std::array{CausalNonceArgument,CausalSequenceArgument},
      IOSGPUSceneCausalArgumentResult::MissingMode);
  assertRejected(
      std::array{modeArgument,CausalSequenceArgument},
      IOSGPUSceneCausalArgumentResult::MissingNonce);
  assertRejected(
      std::array{modeArgument,CausalNonceArgument},
      IOSGPUSceneCausalArgumentResult::MissingSequence);
  assertRejected(
      std::array{
        modeArgument,modeArgument,
        CausalNonceArgument,CausalSequenceArgument},
      IOSGPUSceneCausalArgumentResult::DuplicateMode);
  assertRejected(
      std::array{
        modeArgument,CausalNonceArgument,CausalNonceArgument,
        CausalSequenceArgument},
      IOSGPUSceneCausalArgumentResult::DuplicateNonce);
  assertRejected(
      std::array{
        modeArgument,CausalNonceArgument,
        CausalSequenceArgument,CausalSequenceArgument},
      IOSGPUSceneCausalArgumentResult::DuplicateSequence);
  assertRejected(
      std::array{
        modeArgument,CausalNonceArgument,CausalSequenceArgument,
        "-renderer-ios-native-alpha-test-causal-extra=1"},
      IOSGPUSceneCausalArgumentResult::UnknownCausalArgument);
  assertRejected(
      std::array{
        otherModeArgument,CausalNonceArgument,CausalSequenceArgument},
      IOSGPUSceneCausalArgumentResult::ModeMismatch);
  assertRejected(
      std::array{
        "-renderer-ios-native-alpha-test-causal-mode=unknown",
        CausalNonceArgument,CausalSequenceArgument},
      IOSGPUSceneCausalArgumentResult::ModeMismatch);

  for(const char* nonceArgument:{
        "-renderer-ios-native-alpha-test-causal-nonce=",
        "-renderer-ios-native-alpha-test-causal-nonce=0",
        "-renderer-ios-native-alpha-test-causal-nonce="
        "0123456789abcdef0123456789abcde",
        "-renderer-ios-native-alpha-test-causal-nonce="
        "0123456789abcdef0123456789abcdef0",
        "-renderer-ios-native-alpha-test-causal-nonce="
        "0123456789abcdef0123456789abcdeF",
        "-renderer-ios-native-alpha-test-causal-nonce="
        "0123456789abcdef0123456789abcdeg"}) {
    assertRejected(
        std::array{modeArgument,nonceArgument,CausalSequenceArgument},
        IOSGPUSceneCausalArgumentResult::InvalidNonce);
  }
  for(const char* sequenceArgument:{
        "-renderer-ios-native-alpha-test-causal-sequence=",
        "-renderer-ios-native-alpha-test-causal-sequence=0",
        "-renderer-ios-native-alpha-test-causal-sequence=+1",
        "-renderer-ios-native-alpha-test-causal-sequence=-1",
        "-renderer-ios-native-alpha-test-causal-sequence=01",
        "-renderer-ios-native-alpha-test-causal-sequence=1x",
        "-renderer-ios-native-alpha-test-causal-sequence="
        "18446744073709551616",
        "-renderer-ios-native-alpha-test-causal-sequence="
        "9999999999999999999999999999999999999999"}) {
    assertRejected(
        std::array{modeArgument,CausalNonceArgument,sequenceArgument},
        IOSGPUSceneCausalArgumentResult::InvalidSequence);
  }

  IOSGPUSceneCausalArguments parsed = sentinel;
  assert(iosGPUSceneParseCausalArgumentsForCompileMode<Mode>(
             -1,nullptr,parsed)==
         IOSGPUSceneCausalArgumentResult::InvalidArgumentVector);
  assert(parsed==sentinel);
  assert(iosGPUSceneParseCausalArgumentsForCompileMode<Mode>(
             1,nullptr,parsed)==
         IOSGPUSceneCausalArgumentResult::InvalidArgumentVector);
  assert(parsed==sentinel);
  const std::array<const char*,1> nullArgument = {nullptr};
  assert(iosGPUSceneParseCausalArgumentsForCompileMode<Mode>(
             1,nullArgument.data(),parsed)==
         IOSGPUSceneCausalArgumentResult::InvalidArgumentVector);
  assert(parsed==sentinel);
  }

void assertMarkerParts(
    const IOSGPUSceneMarker& marker,
    std::string_view prefix,
    std::string_view mode,
    std::string_view suffix);

template<IOSGPUSceneMode Mode>
void testCausalRuntimeForMode(
    const char* modeArgument,
    std::string_view modeName) {
  const std::array arguments = {
    modeArgument,CausalNonceArgument,CausalSequenceArgument,
    };
  IOSGPUSceneCausalArguments parsed;
  assert(iosGPUSceneParseCausalArgumentsForCompileMode<Mode>(
      static_cast<int>(arguments.size()),arguments.data(),parsed)==
      IOSGPUSceneCausalArgumentResult::Accepted);

  IOSGPUSceneCausalRuntimeState initialized;
  initialized.generation = 91u;
  initialized.lastSequence = 92u;
  initialized.phase = IOSGPUSceneCausalRuntimePhase::Failed;
  assert(iosGPUSceneInitializeCausalRuntimeForCompileMode<Mode>(
      parsed,initialized));
  assert(initialized.arguments==parsed);
  assert(initialized.generation==0u);
  assert(initialized.lastSequence==0u);
  assert(initialized.phase==
         IOSGPUSceneCausalRuntimePhase::AwaitingTarget);

  assertMarkerParts(
      iosGPUSceneCausalArmedMarker(initialized),
      "RendererIOS native causal capture: ARMED mode=",modeName,
      " nonce=0123456789abcdef0123456789abcdef "
      "target-sequence=300");
  assertMarkerParts(
      iosGPUSceneCausalParseFailMarker(
          Mode,IOSGPUSceneCausalArgumentResult::MissingNonce),
      "RendererIOS native causal capture: FAIL mode=",modeName,
      " reason=parse-missing-nonce");
  assert(!iosGPUSceneCausalParseFailMarker(
      Mode,IOSGPUSceneCausalArgumentResult::Accepted));

  const auto makeCounts = [](
      IOSGPUSceneCausalFrameRoute selectedRoute) {
    IOSGPUSceneFrameCounts counts;
    for(const auto entry:{
          std::pair{IOSMaterialCategory::Opaque,
                    IOSSceneMeshKind::Landscape},
          std::pair{IOSMaterialCategory::AlphaTest,
                    IOSSceneMeshKind::Static},
          std::pair{IOSMaterialCategory::AlphaTest,
                    IOSSceneMeshKind::Movable}}) {
      assert(recordIOSGPUSceneDrawCount(
          entry.first,entry.second,false,false,counts.planned)==
          IOSGPUSceneCountResult::Recorded);
      IOSGPUSceneDrawDispatch dispatch;
      assert(recordIOSGPUSceneDrawDispatchForRouteForCompileMode<Mode>(
          selectedRoute,entry.first,entry.second,false,true,
          iosGPUScenePipelineSelector(entry.first),
          counts,dispatch)==IOSGPUSceneDrawDispatchResult::Recorded);
      assert(dispatch.logical==
             iosGPUScenePipelineSelector(entry.first));
      if(selectedRoute==IOSGPUSceneCausalFrameRoute::Production ||
         entry.first==IOSMaterialCategory::Opaque)
        assert(dispatch.effective==dispatch.logical);
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
      if constexpr(Mode==IOSGPUSceneMode::CausalB) {
        if(selectedRoute==IOSGPUSceneCausalFrameRoute::Target &&
           entry.first==IOSMaterialCategory::AlphaTest)
          assert(dispatch.effective==
                 IOSGPUScenePipelineSelector::Opaque);
        }
#endif
    }
    return counts;
    };
  const IOSGPUSceneFrameCounts productionCounts =
      makeCounts(IOSGPUSceneCausalFrameRoute::Production);
  const IOSGPUSceneFrameCounts targetCounts =
      makeCounts(IOSGPUSceneCausalFrameRoute::Target);
  assert(iosGPUSceneProductionFrameCountsAreConsistent(
      productionCounts));
  assert(iosGPUSceneFrameCountsAreConsistentForCompileMode<Mode>(
      targetCounts));
  {
    IOSGPUSceneFrameCounts invalidRouteCounts = productionCounts;
    IOSGPUSceneDrawDispatch invalidRouteDispatch = {
      IOSGPUScenePipelineSelector::AlphaTest,
      IOSGPUScenePipelineSelector::Opaque,
      };
    const auto countsBefore = invalidRouteCounts;
    const auto dispatchBefore = invalidRouteDispatch;
    assert(recordIOSGPUSceneDrawDispatchForRouteForCompileMode<Mode>(
        static_cast<IOSGPUSceneCausalFrameRoute>(255u),
        IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Static,
        false,true,IOSGPUScenePipelineSelector::AlphaTest,
        invalidRouteCounts,invalidRouteDispatch)==
        IOSGPUSceneDrawDispatchResult::InvalidMode);
    assert(invalidRouteCounts==countsBefore);
    assert(invalidRouteDispatch==dispatchBefore);
  }

  IOSGPUSceneCausalFrameRoute route =
      IOSGPUSceneCausalFrameRoute::Target;
  IOSGPUSceneCausalRuntimeState prepared = initialized;
  prepared.generation = 41u;
  prepared.lastSequence = 42u;
  prepared.phase = IOSGPUSceneCausalRuntimePhase::Failed;
  const auto assertObservationRejected = [&](
      const IOSGPUSceneCausalRuntimeState& current,
      uint64_t generation,
      uint64_t sequence,
      IOSGPUSceneCausalFrameResult expected) {
    route = IOSGPUSceneCausalFrameRoute::Target;
    prepared = initialized;
    prepared.generation = 41u;
    prepared.lastSequence = 42u;
    prepared.phase = IOSGPUSceneCausalRuntimePhase::Failed;
    const auto outputBefore = prepared;
    assert(iosGPUScenePrepareCausalObservationForCompileMode<Mode>(
        current,generation,sequence,route,prepared)==expected);
    assert(route==IOSGPUSceneCausalFrameRoute::Target);
    assert(prepared==outputBefore);
    };

  IOSGPUSceneCausalRuntimeState state = initialized;
  assert(iosGPUScenePrepareCausalObservationForCompileMode<Mode>(
      state,7u,290u,route,prepared)==
      IOSGPUSceneCausalFrameResult::Prepared);
  assert(route==IOSGPUSceneCausalFrameRoute::Production);
  assert(prepared.generation==7u);
  assert(prepared.lastSequence==290u);
  IOSGPUSceneCausalRuntimeState committed = initialized;
  assert(iosGPUSceneCommitCausalPreparationForCompileMode<Mode>(
      state,prepared,route,productionCounts,3u,0u,
      false,false,true,committed));
  state = committed;

  assert(iosGPUScenePrepareCausalObservationForCompileMode<Mode>(
      state,7u,299u,route,prepared)==
      IOSGPUSceneCausalFrameResult::Prepared);
  assert(route==IOSGPUSceneCausalFrameRoute::Production);
  assert(iosGPUSceneCommitCausalPreparationForCompileMode<Mode>(
      state,prepared,route,productionCounts,3u,0u,
      false,false,true,committed));
  state = committed;
  assert(state.lastSequence==299u);
  assertObservationRejected(
      state,7u,299u,
      IOSGPUSceneCausalFrameResult::SequenceNotIncreasing);
  assertObservationRejected(
      state,7u,298u,
      IOSGPUSceneCausalFrameResult::SequenceNotIncreasing);
  assertObservationRejected(
      state,8u,300u,
      IOSGPUSceneCausalFrameResult::GenerationChangedBeforeTarget);
  assertObservationRejected(
      state,7u,301u,
      IOSGPUSceneCausalFrameResult::TargetMissed);
  assertObservationRejected(
      state,0u,300u,
      IOSGPUSceneCausalFrameResult::InvalidGeneration);
  assertObservationRejected(
      state,7u,0u,
      IOSGPUSceneCausalFrameResult::InvalidSequence);

  assert(iosGPUScenePrepareCausalObservationForCompileMode<Mode>(
      state,7u,300u,route,prepared)==
      IOSGPUSceneCausalFrameResult::Prepared);
  assert(route==IOSGPUSceneCausalFrameRoute::Target);
  assert(prepared.phase==
         IOSGPUSceneCausalRuntimePhase::TargetPrepared);
  assert(!iosGPUSceneCausalPreparationIsValidForCompileMode<Mode>(
      prepared,route,targetCounts,3u,3u,false,true,true));
  assert(!iosGPUSceneCausalPreparationIsValidForCompileMode<Mode>(
      prepared,route,targetCounts,3u,3u,true,false,true));
  assert(!iosGPUSceneCausalPreparationIsValidForCompileMode<Mode>(
      prepared,route,targetCounts,3u,3u,true,true,false));
  assert(!iosGPUSceneCausalPreparationIsValidForCompileMode<Mode>(
      prepared,route,targetCounts,3u,2u,true,true,true));
  {
    IOSGPUSceneFrameCounts opaqueOnly;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,
        IOSSceneMeshKind::Landscape,false,false,
        opaqueOnly.planned)==IOSGPUSceneCountResult::Recorded);
    IOSGPUSceneDrawDispatch dispatch;
    assert(recordIOSGPUSceneDrawDispatchForRouteForCompileMode<Mode>(
        route,IOSMaterialCategory::Opaque,
        IOSSceneMeshKind::Landscape,false,true,
        IOSGPUScenePipelineSelector::Opaque,
        opaqueOnly,dispatch)==
        IOSGPUSceneDrawDispatchResult::Recorded);
    assert(!iosGPUSceneCausalPreparationIsValidForCompileMode<Mode>(
        prepared,route,opaqueOnly,1u,1u,true,true,true));
  }
  assert(iosGPUSceneCausalPreparationIsValidForCompileMode<Mode>(
      prepared,route,targetCounts,3u,3u,true,true,true));

  committed = initialized;
  const auto committedSentinel = committed;
  assert(!iosGPUSceneCommitCausalPreparationForCompileMode<Mode>(
      state,prepared,route,targetCounts,3u,3u,
      false,true,true,committed));
  assert(committed==committedSentinel);
  assert(iosGPUSceneCommitCausalPreparationForCompileMode<Mode>(
      state,prepared,route,targetCounts,3u,3u,
      true,true,true,committed));
  state = committed;
  assert(state.phase==IOSGPUSceneCausalRuntimePhase::TargetEncoded);
  assertMarkerParts(
      iosGPUSceneCausalEncodedMarker(state,3u,2u),
      "RendererIOS native causal capture: ENCODED mode=",modeName,
      " nonce=0123456789abcdef0123456789abcdef "
      "generation=7 sequence=300 draws=3 alpha=2");

  assertObservationRejected(
      state,7u,300u,IOSGPUSceneCausalFrameResult::TargetReused);
  assert(iosGPUScenePrepareCausalObservationForCompileMode<Mode>(
      state,7u,301u,route,prepared)==
      IOSGPUSceneCausalFrameResult::Prepared);
  assert(route==IOSGPUSceneCausalFrameRoute::Production);
  assert(prepared==state);
  assert(iosGPUScenePrepareCausalObservationForCompileMode<Mode>(
      state,8u,1u,route,prepared)==
      IOSGPUSceneCausalFrameResult::Prepared);
  assert(route==IOSGPUSceneCausalFrameRoute::Production);
  assert(prepared==state);

  {
    auto failed = initialized;
    assert(iosGPUSceneTransitionCausalFailure(
        failed,IOSGPUSceneCausalFailureReason::TargetNotObserved));
    assert(!iosGPUSceneTransitionCausalFailure(
        failed,IOSGPUSceneCausalFailureReason::NativeEncode));
    assertMarkerParts(
        iosGPUSceneCausalFailMarker(
            failed,0u,0u,
            IOSGPUSceneCausalFailureReason::TargetNotObserved),
        "RendererIOS native causal capture: FAIL mode=",modeName,
        " nonce=0123456789abcdef0123456789abcdef "
        "generation=0 sequence=0 reason=target-not-observed");
    assertObservationRejected(
        failed,7u,300u,IOSGPUSceneCausalFrameResult::InvalidPhase);
  }
  {
    auto targetPrepared = prepared;
    targetPrepared.phase =
        IOSGPUSceneCausalRuntimePhase::TargetPrepared;
    assert(iosGPUSceneTransitionCausalFailure(
        targetPrepared,
        IOSGPUSceneCausalFailureReason::MarkerPreflight));
  }
  {
    auto encoded = state;
    assert(!iosGPUSceneTransitionCausalFailure(
        encoded,IOSGPUSceneCausalFailureReason::NativeEncode));
    assert(iosGPUSceneTransitionCausalFailure(
        encoded,IOSGPUSceneCausalFailureReason::TargetReused));
    assert(encoded.phase==IOSGPUSceneCausalRuntimePhase::Failed);
  }

  for(const auto result:{
        IOSGPUSceneCausalFrameResult::Prepared,
        IOSGPUSceneCausalFrameResult::InvalidArguments,
        IOSGPUSceneCausalFrameResult::InvalidGeneration,
        IOSGPUSceneCausalFrameResult::InvalidSequence,
        IOSGPUSceneCausalFrameResult::InvalidPhase,
        IOSGPUSceneCausalFrameResult::GenerationChangedBeforeTarget,
        IOSGPUSceneCausalFrameResult::SequenceNotIncreasing,
        IOSGPUSceneCausalFrameResult::TargetMissed,
        IOSGPUSceneCausalFrameResult::TargetReused})
    assert(iosGPUSceneCausalFrameResultName(result)!=nullptr);
  }

template<IOSGPUSceneMode Mode>
IOSGPUSceneFrameCounts makeCausalDispatchCounts() {
  IOSGPUSceneFrameCounts counts;
  for(const auto entry:{
        std::pair{IOSMaterialCategory::Opaque,
                  IOSSceneMeshKind::Landscape},
        std::pair{IOSMaterialCategory::AlphaTest,
                  IOSSceneMeshKind::Static},
        std::pair{IOSMaterialCategory::AlphaTest,
                  IOSSceneMeshKind::Movable}}) {
    assert(recordIOSGPUSceneDrawCount(
        entry.first,entry.second,false,false,counts.planned)==
        IOSGPUSceneCountResult::Recorded);
    IOSGPUSceneDrawDispatch dispatch;
    assert(recordIOSGPUSceneDrawDispatchForCompileMode<Mode>(
        entry.first,entry.second,false,true,
        iosGPUScenePipelineSelector(entry.first),
        counts,dispatch)==IOSGPUSceneDrawDispatchResult::Recorded);
    assert(dispatch.logical==iosGPUScenePipelineSelector(entry.first));
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
    if constexpr(Mode==IOSGPUSceneMode::CausalB) {
      assert(dispatch.effective==IOSGPUScenePipelineSelector::Opaque);
      }
    else
#endif
    {
      assert(dispatch.effective==dispatch.logical);
    }
  }
  assert(iosGPUSceneFrameCountsAreConsistentForCompileMode<Mode>(
      counts));
  return counts;
  }

template<IOSGPUSceneMode Mode>
void testCausalDispatchForMode() {
  const auto valid = makeCausalDispatchCounts<Mode>();
  IOSGPUSceneFrameCounts counts = valid;
  IOSGPUSceneDrawDispatch dispatch = {
    IOSGPUScenePipelineSelector::AlphaTest,
    IOSGPUScenePipelineSelector::Opaque,
    };
  const IOSGPUSceneDrawDispatch sentinel = dispatch;
  const auto assertRejected = [&](
      IOSMaterialCategory category,
      IOSSceneMeshKind kind,
      IOSGPUScenePipelineSelector logical,
      IOSGPUSceneDrawDispatchResult expected) {
    counts = valid;
    dispatch = sentinel;
    assert(recordIOSGPUSceneDrawDispatchForCompileMode<Mode>(
        category,kind,false,true,logical,counts,dispatch)==expected);
    assert(counts==valid);
    assert(dispatch==sentinel);
    };
  assertRejected(
      IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
      IOSGPUScenePipelineSelector::AlphaTest,
      IOSGPUSceneDrawDispatchResult::SelectorMismatch);
  assertRejected(
      IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Static,
      IOSGPUScenePipelineSelector::Opaque,
      IOSGPUSceneDrawDispatchResult::SelectorMismatch);
  assertRejected(
      IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Static,
      IOSGPUScenePipelineSelector::Unsupported,
      IOSGPUSceneDrawDispatchResult::SelectorMismatch);
  assertRejected(
      IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Static,
      static_cast<IOSGPUScenePipelineSelector>(255u),
      IOSGPUSceneDrawDispatchResult::SelectorMismatch);
  assertRejected(
      static_cast<IOSMaterialCategory>(255u),
      IOSSceneMeshKind::Landscape,
      IOSGPUScenePipelineSelector::Opaque,
      IOSGPUSceneDrawDispatchResult::SelectorMismatch);
  assertRejected(
      IOSMaterialCategory::Opaque,
      static_cast<IOSSceneMeshKind>(255u),
      IOSGPUScenePipelineSelector::Opaque,
      IOSGPUSceneDrawDispatchResult::UnknownKind);

  counts = valid;
  ++counts.opaquePsoBinds;
  const auto corrupt = counts;
  dispatch = sentinel;
  assert(recordIOSGPUSceneDrawDispatchForCompileMode<Mode>(
      IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
      false,true,IOSGPUScenePipelineSelector::Opaque,
      counts,dispatch)==IOSGPUSceneDrawDispatchResult::InconsistentCounts);
  assert(counts==corrupt);
  assert(dispatch==sentinel);

  IOSGPUSceneFrameCounts overflow;
  overflow.drawn.material.total =
      std::numeric_limits<uint64_t>::max();
  overflow.drawn.material.opaque = overflow.drawn.material.total;
  overflow.drawn.kind.total = overflow.drawn.material.total;
  overflow.drawn.kind.landscape = overflow.drawn.kind.total;
  overflow.drawn.texturedDraws = overflow.drawn.material.total;
  overflow.opaquePsoBinds = overflow.drawn.material.total;
  const auto overflowBefore = overflow;
  dispatch = sentinel;
  assert(recordIOSGPUSceneDrawDispatchForCompileMode<Mode>(
      IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
      false,true,IOSGPUScenePipelineSelector::Opaque,
      overflow,dispatch)==IOSGPUSceneDrawDispatchResult::Overflow);
  assert(overflow==overflowBefore);
  assert(dispatch==sentinel);
  }

std::size_t countOccurrences(
    std::string_view text,
    std::string_view needle) {
  std::size_t count = 0u;
  std::size_t offset = 0u;
  while(offset<=text.size()) {
    const std::size_t found = text.find(needle,offset);
    if(found==std::string_view::npos)
      break;
    ++count;
    offset = found+needle.size();
  }
  return count;
  }

void assertMarkerParts(
    const IOSGPUSceneMarker& marker,
    std::string_view prefix,
    std::string_view mode,
    std::string_view suffix) {
  assert(marker);
  assert(marker.length<IOSGPUSceneMarkerCapacity);
  assert(marker.text[marker.length]=='\0');
  const std::string_view text(marker.text.data(),marker.length);
  assert(text.size()==prefix.size()+mode.size()+suffix.size());
  assert(text.starts_with(prefix));
  assert(text.substr(prefix.size(),mode.size())==mode);
  assert(text.ends_with(suffix));
  assert(countOccurrences(text,"mode=")==1u);
  }

void testSceneMarkerGrammar(
    std::string_view modeName,
    const IOSGPUSceneFrameCounts& counts,
    const IOSGPUSceneFailureCounts& failures,
    std::string_view alphaSuffix) {
  assertMarkerParts(
      iosGPUSceneIdentityMarker(7u,300u),
      "RendererIOS native scene identity: mode=",modeName,
      " generation=7 sequence=300");
  assertMarkerParts(
      iosGPUSceneMaterialPlannedMarker(counts),
      "RendererIOS native scene material-planned: mode=",modeName,
      " total=3 opaque=1 alpha=2");
  assertMarkerParts(
      iosGPUSceneMaterialDrawnMarker(counts),
      "RendererIOS native scene material-drawn: mode=",modeName,
      " total=3 opaque=1 alpha=2 textured=3");
  assertMarkerParts(
      iosGPUSceneKindPlannedMarker(counts),
      "RendererIOS native scene kind-planned: mode=",modeName,
      " total=3 landscape=1 static=1 movable=1");
  assertMarkerParts(
      iosGPUSceneKindDrawnMarker(counts),
      "RendererIOS native scene kind-drawn: mode=",modeName,
      " total=3 landscape=1 static=1 movable=1");
  assertMarkerParts(
      iosGPUSceneAlphaMarker(counts),
      "RendererIOS native scene alpha: mode=",modeName,
      alphaSuffix);
  assertMarkerParts(
      iosGPUSceneFailContractMarker(failures),
      "RendererIOS native scene fail-contract: mode=",modeName,
      " unknown-category=0 unknown-kind=0 invalid-cutoff=0 "
      "missing-alpha-texture=0");
  assertMarkerParts(
      iosGPUSceneFailSelectorMarker(failures),
      "RendererIOS native scene fail-selector: mode=",modeName,
      " selector-mismatch=0 pso-unavailable=0");
  assertMarkerParts(
      iosGPUSceneFailExecutionMarker(failures),
      "RendererIOS native scene fail-execution: mode=",modeName,
      " overflow=0 planned-drawn=0 native-encode=0");
  }

template<IOSGPUSceneMode Mode>
void testCausalDrawIdentityForMode(
    std::string_view modeName,
    std::string_view effectiveName) {
  IOSGPUScenePipelineSelector effective =
      IOSGPUScenePipelineSelector::Unsupported;
  assert(iosGPUSceneEffectivePipelineSelectorForCompileMode<Mode>(
      IOSMaterialCategory::AlphaTest,
      IOSGPUScenePipelineSelector::AlphaTest,effective));
  IOSGPUSceneDrawDispatch dispatch = {
    IOSGPUScenePipelineSelector::AlphaTest,
    effective,
    };
  IOSGPUSceneCausalDrawIdentity identity;
  assert(makeIOSGPUSceneCausalDrawIdentityForCompileMode<Mode>(
      CausalNonce,7u,300u,2u,dispatch,IOSSceneMeshKind::Static,
      11u,22u,36u,identity)==
      IOSGPUSceneCausalDrawIdentityResult::Created);
  assert(iosGPUSceneCausalDrawIdentityIsValidForCompileMode<Mode>(
      identity));
  assert(iosGPUSceneCausalDrawIdentityIsValid(identity));

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  constexpr IOSGPUSceneMode oppositeMode =
      Mode==IOSGPUSceneMode::CausalA
        ? IOSGPUSceneMode::CausalB
        : IOSGPUSceneMode::CausalA;
  for(const IOSGPUSceneMode invalidMode:{
        oppositeMode,static_cast<IOSGPUSceneMode>(255u)}) {
    auto wrongModeIdentity = identity;
    wrongModeIdentity.mode = invalidMode;
    assert(!iosGPUSceneCausalDrawIdentityIsValidForCompileMode<Mode>(
        wrongModeIdentity));
    assert(!iosGPUSceneCausalDrawIdSignpost(wrongModeIdentity));
    assert(!iosGPUSceneCausalDrawBindSignpost(wrongModeIdentity));
  }
#endif

  const IOSGPUSceneMarker id =
      iosGPUSceneCausalDrawIdSignpost(identity);
  assertMarkerParts(
      id,"RendererIOS native causal draw-id: mode=",modeName,
      " nonce=0123456789abcdef0123456789abcdef "
      "generation=7 sequence=300 ordinal=2");
  const IOSGPUSceneMarker bind =
      iosGPUSceneCausalDrawBindSignpost(identity);
  assert(bind);
  const std::string_view bindText(bind.text.data(),bind.length);
  assert(bindText.starts_with(
      "RendererIOS native causal draw-bind: ordinal=2 "
      "logical=alpha-test effective="));
  const std::string_view bindSuffix =
      " kind=static slot=0 texture=11 mesh=22 indices=36";
  const std::size_t effectiveOffset =
      std::string_view(
        "RendererIOS native causal draw-bind: ordinal=2 "
        "logical=alpha-test effective=").size();
  assert(bindText.substr(effectiveOffset,effectiveName.size())==
         effectiveName);
  assert(bindText.substr(effectiveOffset+effectiveName.size())==
         bindSuffix);
  assert(bind.length<IOSGPUSceneMarkerCapacity);
  assert(bind.text[bind.length]=='\0');
  for(const std::string_view field:{
        "ordinal=","logical=","effective=","kind=",
        "slot=","texture=","mesh=","indices="})
    assert(countOccurrences(bindText,field)==1u);
  const std::array orderedSignposts = {id,bind};
  assert(std::string_view(
      orderedSignposts[0].text.data(),
      orderedSignposts[0].length).starts_with(
          "RendererIOS native causal draw-id:"));
  assert(std::string_view(
      orderedSignposts[1].text.data(),
      orderedSignposts[1].length).starts_with(
          "RendererIOS native causal draw-bind:"));

  uint64_t counter = 0u;
  uint64_t ordinal = 99u;
  for(uint64_t expected=1u; expected<=3u; ++expected) {
    assert(iosGPUSceneTakeNextCausalDrawOrdinal(counter,ordinal));
    assert(counter==expected);
    assert(ordinal==expected);
  }
  counter = std::numeric_limits<uint64_t>::max();
  ordinal = 77u;
  assert(!iosGPUSceneTakeNextCausalDrawOrdinal(counter,ordinal));
  assert(counter==std::numeric_limits<uint64_t>::max());
  assert(ordinal==77u);

  const IOSGPUSceneCausalDrawIdentity sentinel = identity;
  const auto assertMakeRejected = [&](
      std::string_view nonce,
      uint64_t generation,
      uint64_t sequence,
      uint64_t ordinalValue,
      const IOSGPUSceneDrawDispatch& candidateDispatch,
      IOSSceneMeshKind kind,
      uint64_t texture,
      uint64_t mesh,
      uint64_t indices,
      IOSGPUSceneCausalDrawIdentityResult expected) {
    IOSGPUSceneCausalDrawIdentity output = sentinel;
    assert(makeIOSGPUSceneCausalDrawIdentityForCompileMode<Mode>(
        nonce,generation,sequence,ordinalValue,candidateDispatch,
        kind,texture,mesh,indices,output)==expected);
    assert(output==sentinel);
    };
  assertMakeRejected(
      "0123456789abcdef0123456789abcdeF",
      7u,300u,2u,dispatch,IOSSceneMeshKind::Static,
      11u,22u,36u,IOSGPUSceneCausalDrawIdentityResult::InvalidNonce);
  assertMakeRejected(
      CausalNonce,0u,300u,2u,dispatch,IOSSceneMeshKind::Static,
      11u,22u,36u,IOSGPUSceneCausalDrawIdentityResult::InvalidGeneration);
  assertMakeRejected(
      CausalNonce,7u,0u,2u,dispatch,IOSSceneMeshKind::Static,
      11u,22u,36u,IOSGPUSceneCausalDrawIdentityResult::InvalidSequence);
  assertMakeRejected(
      CausalNonce,7u,300u,0u,dispatch,IOSSceneMeshKind::Static,
      11u,22u,36u,IOSGPUSceneCausalDrawIdentityResult::InvalidOrdinal);
  auto wrongDispatch = dispatch;
  wrongDispatch.effective =
      effective==IOSGPUScenePipelineSelector::Opaque
        ? IOSGPUScenePipelineSelector::AlphaTest
        : IOSGPUScenePipelineSelector::Opaque;
  assertMakeRejected(
      CausalNonce,7u,300u,2u,wrongDispatch,IOSSceneMeshKind::Static,
      11u,22u,36u,IOSGPUSceneCausalDrawIdentityResult::InvalidDispatch);
  auto fabricatedDispatch = dispatch;
  fabricatedDispatch.effective =
      static_cast<IOSGPUScenePipelineSelector>(255u);
  assertMakeRejected(
      CausalNonce,7u,300u,2u,fabricatedDispatch,
      IOSSceneMeshKind::Static,11u,22u,36u,
      IOSGPUSceneCausalDrawIdentityResult::InvalidDispatch);
  assertMakeRejected(
      CausalNonce,7u,300u,2u,dispatch,
      static_cast<IOSSceneMeshKind>(255u),
      11u,22u,36u,IOSGPUSceneCausalDrawIdentityResult::InvalidKind);
  assertMakeRejected(
      CausalNonce,7u,300u,2u,dispatch,IOSSceneMeshKind::Static,
      0u,22u,36u,IOSGPUSceneCausalDrawIdentityResult::InvalidTexture);
  assertMakeRejected(
      CausalNonce,7u,300u,2u,dispatch,IOSSceneMeshKind::Static,
      11u,0u,36u,IOSGPUSceneCausalDrawIdentityResult::InvalidMesh);
  assertMakeRejected(
      CausalNonce,7u,300u,2u,dispatch,IOSSceneMeshKind::Static,
      11u,22u,0u,IOSGPUSceneCausalDrawIdentityResult::InvalidIndexCount);

  constexpr uint64_t maximum =
      std::numeric_limits<uint64_t>::max();
  IOSGPUSceneCausalDrawIdentity worst;
  assert(makeIOSGPUSceneCausalDrawIdentityForCompileMode<Mode>(
      CausalNonce,maximum,maximum,maximum,dispatch,
      IOSSceneMeshKind::Landscape,maximum,maximum,maximum,worst)==
      IOSGPUSceneCausalDrawIdentityResult::Created);
  const IOSGPUSceneMarker worstId =
      iosGPUSceneCausalDrawIdSignpost(worst);
  assert(worstId);
  assert(worstId.length<IOSGPUSceneMarkerCapacity);
  assert(worstId.text[worstId.length]=='\0');
  const IOSGPUSceneMarker worstBind =
      iosGPUSceneCausalDrawBindSignpost(worst);
  assert(worstBind);
  assert(worstBind.length<IOSGPUSceneMarkerCapacity);
  assert(worstBind.text[worstBind.length]=='\0');

  for(std::size_t mutation=0u; mutation<11u; ++mutation) {
    auto broken = identity;
    switch(mutation) {
      case 0u: broken.nonce[0] = 'F'; break;
      case 1u: broken.generation = 0u; break;
      case 2u: broken.sequence = 0u; break;
      case 3u: broken.ordinal = 0u; break;
      case 4u:
        broken.logical = IOSGPUScenePipelineSelector::Unsupported;
        break;
      case 5u:
        broken.effective = wrongDispatch.effective;
        break;
      case 6u:
        broken.kind = static_cast<IOSSceneMeshKind>(255u);
        break;
      case 7u: broken.texture = 0u; break;
      case 8u: broken.mesh = 0u; break;
      case 9u: broken.indices = 0u; break;
      case 10u:
        broken.nonce[IOSGPUSceneCausalNonceLength] = 'x';
        break;
    }
    assert(!iosGPUSceneCausalDrawIdentityIsValidForCompileMode<Mode>(
        broken));
    assert(!iosGPUSceneCausalDrawIdSignpost(broken));
    assert(!iosGPUSceneCausalDrawBindSignpost(broken));
  }
  }
#endif

IOSMatrix4x4 movableT1() {
  IOSMatrix4x4 transform;
  transform.set(0u,3u,44.f);
  transform.set(1u,3u,55.f);
  transform.set(2u,3u,66.f);
  return transform;
  }

IOSGPUSceneMeshCandidate validCandidate() {
  IOSGPUSceneMeshCandidate source;
  source.snapshotGeneration    = IOSWorldGeneration{7};
  source.registryGeneration    = IOSWorldGeneration{7};
  source.entity.id             = {source.snapshotGeneration,1};
  source.entity.mesh           = {source.snapshotGeneration,2};
  source.entity.material       = {source.snapshotGeneration,3};
  source.entity.kind           = IOSSceneMeshKind::Landscape;
  source.entity.visibilityMask = IOSSceneVisibilityMain;
  source.material.id           = source.entity.material;
  source.material.category     = IOSMaterialCategory::Opaque;
  source.material.baseColor    = {0.25f,0.5f,0.75f,1.f};
  source.material.uvOffset     = {0.125f,-0.25f};
  source.material.baseColorTexture = {source.snapshotGeneration,4};
  source.hasMaterial           = true;
  source.hasTexture            = true;
  source.hasNativeTexture      = true;
  source.hasSupportedTextureFormat = true;
  source.hasValidNativeTexture = true;
  source.textureWidth          = 512u;
  source.textureHeight         = 256u;
  source.textureMipCount       = 10u;
  source.hasMesh               = true;
  source.hasNativeVertexBuffer = true;
  source.hasNativeIndexBuffer  = true;
  source.vertexBufferByteSize  = IOSLandscapeVertexStride*4u;
  source.indexBufferByteSize   = IOSLandscapeIndexStride*12u;
  source.vertexStride          = IOSLandscapeVertexStride;
  source.firstIndex            = 3u;
  source.indexCount            = 6u;
  return source;
  }

IOSFrameAnimationEvidence frameAnimationEvidence(
    uint64_t firstOrdinal,
    uint64_t firstHandle,
    uint64_t secondOrdinal = 0u,
    uint64_t secondHandle = 22u,
    IOSWorldGeneration generation = {7u}) {
  IOSFrameAnimationEvidence evidence;
  evidence.selections = {
    {2u,secondOrdinal,{generation,secondHandle}},
    {1u,firstOrdinal,{generation,firstHandle}},
    };
  assert(finalizeIOSFrameAnimationEvidence(evidence));
  return evidence;
  }

void testFrameAnimationDownstreamEvidence() {
  const IOSWorldGeneration generation = {7u};
  const auto baseline = frameAnimationEvidence(0u,11u);

  IOSGPUSceneFrameAnimationTracker missing;
  assert(prepareIOSGPUSceneFrameAnimationTracker(
      baseline,generation,missing));
  assert(recordIOSGPUSceneFrameAnimationDraw(
      missing,{generation,99u})==
      IOSGPUSceneFrameAnimationRecordResult::IgnoredStatic);
  assert(recordIOSGPUSceneFrameAnimationDraw(
      missing,{generation,11u})==
      IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated);
  IOSGPUSceneFrameAnimationDrawReport missingReport;
  assert(!finalizeIOSGPUSceneFrameAnimationDrawReport(
      missing,missingReport));
  assert(!missingReport.valid);

  IOSGPUSceneFrameAnimationTracker complete;
  assert(prepareIOSGPUSceneFrameAnimationTracker(
      baseline,generation,complete));
  assert(recordIOSGPUSceneFrameAnimationDraw(
      complete,{generation,22u})==
      IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated);
  assert(recordIOSGPUSceneFrameAnimationDraw(
      complete,{generation,11u})==
      IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated);
  assert(recordIOSGPUSceneFrameAnimationDraw(
      complete,{generation,11u})==
      IOSGPUSceneFrameAnimationRecordResult::DuplicateAnimated);
  IOSGPUSceneFrameAnimationDrawReport baselineDrawn;
  assert(finalizeIOSGPUSceneFrameAnimationDrawReport(
      complete,baselineDrawn));
  assert(baselineDrawn.valid);
  assert(baselineDrawn.drawnAnimated==2u);
  uint64_t expectedDigest = IOSFrameAnimationFNV1aOffset;
  expectedDigest = iosFrameAnimationFNV1aAppendWord(expectedDigest,1u);
  expectedDigest = iosFrameAnimationFNV1aAppendWord(expectedDigest,11u);
  expectedDigest = iosFrameAnimationFNV1aAppendWord(expectedDigest,2u);
  expectedDigest = iosFrameAnimationFNV1aAppendWord(expectedDigest,22u);
  assert(baselineDrawn.drawnDigest==expectedDigest);

  auto duplicateHandle = baseline;
  duplicateHandle.selections[1].selectedHandle =
      duplicateHandle.selections[0].selectedHandle;
  assert(!finalizeIOSFrameAnimationEvidence(duplicateHandle));
  IOSGPUSceneFrameAnimationTracker rejected;
  assert(!prepareIOSGPUSceneFrameAnimationTracker(
      duplicateHandle,generation,rejected));
  assert(!prepareIOSGPUSceneFrameAnimationTracker(
      baseline,{8u},rejected));

  IOSFrameAnimationDiagnosticState state;
  const auto baselineCandidate =
      prepareIOSFrameAnimationDiagnosticCandidate(
          state,generation.value,1u,baseline);
  assert(baselineCandidate.valid);
  assert(baselineCandidate.phase==
         IOSFrameAnimationDiagnosticPhase::Baseline);
  assert(baselineCandidate.changedSource==0u);
  assert(baselineCandidate.fromOrdinal==0u);
  assert(baselineCandidate.toOrdinal==0u);
  assert(iosFrameAnimationDiagnosticCandidateAcceptsDrawn(
      state,baselineCandidate,baseline,baselineDrawn));

  const auto initialState = state;
  auto canceledEvidence = baseline;
  assert(!commitIOSFrameAnimationDiagnosticState(
      false,baselineCandidate,std::move(canceledEvidence),
      baselineDrawn,state));
  assert(state==initialState);
  auto acceptedEvidence = baseline;
  assert(commitIOSFrameAnimationDiagnosticState(
      true,baselineCandidate,std::move(acceptedEvidence),
      baselineDrawn,state));
  assert(state.generation==generation.value);
  assert(state.baseline==baseline);
  assert(state.baselineDrawnAnimated==baselineDrawn.drawnAnimated);
  assert(state.baselineDrawnDigest==baselineDrawn.drawnDigest);
  assert(state.baselineCommitted);
  assert(!state.transitionCommitted);

  const auto unchangedCandidate =
      prepareIOSFrameAnimationDiagnosticCandidate(
          state,generation.value,2u,baseline);
  assert(!unchangedCandidate.valid);

  const auto transition = frameAnimationEvidence(1u,12u);
  const auto transitionCandidate =
      prepareIOSFrameAnimationDiagnosticCandidate(
          state,generation.value,2u,transition);
  assert(transitionCandidate.valid);
  assert(transitionCandidate.phase==
         IOSFrameAnimationDiagnosticPhase::Transition);
  assert(transitionCandidate.changedSource==1u);
  assert(transitionCandidate.fromOrdinal==0u);
  assert(transitionCandidate.toOrdinal==1u);

  IOSGPUSceneFrameAnimationTracker transitionTracker;
  assert(prepareIOSGPUSceneFrameAnimationTracker(
      transition,generation,transitionTracker));
  assert(recordIOSGPUSceneFrameAnimationDraw(
      transitionTracker,{generation,12u})==
      IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated);
  assert(recordIOSGPUSceneFrameAnimationDraw(
      transitionTracker,{generation,22u})==
      IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated);
  IOSGPUSceneFrameAnimationDrawReport transitionDrawn;
  assert(finalizeIOSGPUSceneFrameAnimationDrawReport(
      transitionTracker,transitionDrawn));
  assert(transitionDrawn.drawnDigest!=baselineDrawn.drawnDigest);
  assert(iosFrameAnimationDiagnosticCandidateAcceptsDrawn(
      state,transitionCandidate,transition,transitionDrawn));
  const auto beforeRejectedTransition = state;
  auto constantDrawn = transitionDrawn;
  constantDrawn.drawnDigest = baselineDrawn.drawnDigest;
  assert(!iosFrameAnimationDiagnosticCandidateAcceptsDrawn(
      state,transitionCandidate,transition,constantDrawn));
  auto rejectedTransition = transition;
  assert(!commitIOSFrameAnimationDiagnosticState(
      true,transitionCandidate,std::move(rejectedTransition),
      constantDrawn,state));
  assert(state==beforeRejectedTransition);
  auto acceptedTransition = transition;
  assert(commitIOSFrameAnimationDiagnosticState(
      true,transitionCandidate,std::move(acceptedTransition),
      transitionDrawn,state));
  assert(state.transitionCommitted);
  const auto laterTransition = frameAnimationEvidence(2u,13u);
  assert(!prepareIOSFrameAnimationDiagnosticCandidate(
      state,generation.value,3u,laterTransition).valid);

  auto otherCohort = transition;
  otherCohort.selections[1].sourceId = 3u;
  assert(finalizeIOSFrameAnimationEvidence(otherCohort));
  assert(!prepareIOSFrameAnimationDiagnosticCandidate(
      state,generation.value,2u,otherCohort).valid);

  const IOSWorldGeneration nextGeneration = {8u};
  const auto nextBaseline = frameAnimationEvidence(
      0u,31u,0u,42u,nextGeneration);
  const auto nextBaselineCandidate =
      prepareIOSFrameAnimationDiagnosticCandidate(
          state,nextGeneration.value,1u,nextBaseline);
  assert(nextBaselineCandidate.valid);
  assert(nextBaselineCandidate.phase==
         IOSFrameAnimationDiagnosticPhase::Baseline);
  IOSGPUSceneFrameAnimationTracker nextTracker;
  assert(prepareIOSGPUSceneFrameAnimationTracker(
      nextBaseline,nextGeneration,nextTracker));
  assert(recordIOSGPUSceneFrameAnimationDraw(
      nextTracker,{nextGeneration,31u})==
      IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated);
  assert(recordIOSGPUSceneFrameAnimationDraw(
      nextTracker,{nextGeneration,42u})==
      IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated);
  IOSGPUSceneFrameAnimationDrawReport nextDrawn;
  assert(finalizeIOSGPUSceneFrameAnimationDrawReport(
      nextTracker,nextDrawn));
  auto nextAccepted = nextBaseline;
  assert(commitIOSFrameAnimationDiagnosticState(
      true,nextBaselineCandidate,std::move(nextAccepted),nextDrawn,state));
  assert(state.generation==nextGeneration.value);
  assert(state.baseline==nextBaseline);
  assert(state.baselineCommitted);
  assert(!state.transitionCommitted);

  const auto assertMarker = [](
      const IOSGPUSceneMarker& marker,
      std::string_view expected) {
    assert(marker);
    assert(marker.length==expected.size());
    assert(std::string_view(marker.text.data(),marker.length)==expected);
    };
  assertMarker(
      iosFrameAnimationMarker(
          baselineCandidate,baseline,"abc"),
      "RendererIOS frame animation: v=1 p=B b=abc g=7 s=1 "
      "a=2 n=0 sd=7717980363c8e066 pd=a5258921d0bee5a6");
  assertMarker(
      iosFrameAnimationDetailMarker(
          baselineCandidate,baselineDrawn),
      "RendererIOS frame animation detail: v=1 p=B g=7 s=1 "
      "d=2 dd=c4185a11410da49b c=0 f=0 t=0");
  assertMarker(
      iosFrameAnimationMarker(
          transitionCandidate,transition,"abc"),
      "RendererIOS frame animation: v=1 p=T b=abc g=7 s=2 "
      "a=2 n=1 sd=7717980363c8e066 pd=cbcd325d8e28d007");
  assertMarker(
      iosFrameAnimationDetailMarker(
          transitionCandidate,transitionDrawn),
      "RendererIOS frame animation detail: v=1 p=T g=7 s=2 "
      "d=2 dd=6d662cb38b39c57c c=1 f=0 t=1");

  constexpr uint64_t maximum = std::numeric_limits<uint64_t>::max();
  const auto worstPrimary = iosFrameAnimationFormatMarker(
      IOSFrameAnimationDiagnosticPhase::Transition,
      maximum,maximum,maximum,maximum,maximum,maximum,
      "0123456789abcdef0123456789abcdef01234567");
  const auto worstDetail = iosFrameAnimationFormatDetailMarker(
      IOSFrameAnimationDiagnosticPhase::Transition,
      maximum,maximum,maximum,maximum,maximum,maximum,maximum);
  assert(worstPrimary && worstPrimary.length==211u);
  assert(worstDetail && worstDetail.length==201u);
  assert(worstPrimary.length<=254u && worstDetail.length<=254u);
  }

IOSUVAnimationEvidence uvAnimationEvidence() {
  const IOSWorldGeneration generation = {7u};
  IOSUVAnimationEvidence evidence;
  evidence.selections = {
    {20u,IOSSceneTextureAnimationMode::FrameAndUv,3u,
     {generation,22u},{-0.5f,0.25f}},
    {10u,IOSSceneTextureAnimationMode::UvOnly,0u,
     {generation,11u},{0.125f,0.f}},
    };
  assert(finalizeIOSUVAnimationEvidence(evidence));
  return evidence;
  }

IOSGPUSceneDrawPlan uvAnimationPlan(
    IOSTextureHandle texture, IOSFloat2 offset) {
  IOSGPUSceneDrawPlan plan;
  plan.baseColorTexture = texture;
  plan.constants.uvOffset = offset;
  return plan;
  }

void testUVAnimationDownstreamEvidence() {
  const IOSWorldGeneration generation = {7u};
  const auto evidence = uvAnimationEvidence();
  assert(evidence.admittedUvOnly==1u);
  assert(evidence.admittedFrameAndUv==1u);

  IOSUVAnimationEvidence emptyEvidence;
  assert(finalizeIOSUVAnimationEvidence(emptyEvidence));
  IOSGPUSceneUVAnimationTracker emptyTracker;
  assert(prepareIOSGPUSceneUVAnimationTracker(
      emptyEvidence,generation,emptyTracker));
  IOSGPUSceneUVAnimationDrawReport emptyReport;
  assert(finalizeIOSGPUSceneUVAnimationDrawReport(
      emptyTracker,emptyReport));
  assert(emptyReport.valid && emptyReport.encodedCount==0u);
  assert(emptyReport.encodedTextureDigest==IOSUVAnimationFNV1aOffset);
  assert(emptyReport.encodedUVDigest==IOSUVAnimationFNV1aOffset);

  IOSGPUSceneUVAnimationTracker rejected;
  assert(!prepareIOSGPUSceneUVAnimationTracker(
      evidence,{8u},rejected));
  auto duplicateHandle = evidence;
  duplicateHandle.selections[1].selectedHandle =
      duplicateHandle.selections[0].selectedHandle;
  assert(!prepareIOSGPUSceneUVAnimationTracker(
      duplicateHandle,generation,rejected));

  IOSGPUSceneUVAnimationTracker missing;
  assert(prepareIOSGPUSceneUVAnimationTracker(
      evidence,generation,missing));
  assert(recordIOSGPUSceneUVAnimationDraw(
      missing,uvAnimationPlan({generation,99u},{0.f,0.f}))==
      IOSGPUSceneUVAnimationRecordResult::IgnoredStatic);
  assert(recordIOSGPUSceneUVAnimationDraw(
      missing,uvAnimationPlan({generation,11u},{0.125f,0.f}))==
      IOSGPUSceneUVAnimationRecordResult::RecordedUvOnly);
  IOSGPUSceneUVAnimationDrawReport unchanged;
  unchanged.valid = true;
  unchanged.encodedCount = 99u;
  const auto unchangedBefore = unchanged;
  assert(!finalizeIOSGPUSceneUVAnimationDrawReport(missing,unchanged));
  assert(unchanged==unchangedBefore);

  IOSGPUSceneUVAnimationTracker mismatch;
  assert(prepareIOSGPUSceneUVAnimationTracker(
      evidence,generation,mismatch));
  assert(recordIOSGPUSceneUVAnimationDraw(
      mismatch,
      uvAnimationPlan(
          {generation,11u},{std::nextafter(0.125f,1.f),0.f}))==
      IOSGPUSceneUVAnimationRecordResult::InvalidEvidence);
  assert(recordIOSGPUSceneUVAnimationDraw(
      mismatch,
      uvAnimationPlan(
          {generation,11u},
          {0.125f,std::numeric_limits<float>::infinity()}))==
      IOSGPUSceneUVAnimationRecordResult::InvalidEvidence);
  assert(recordIOSGPUSceneUVAnimationDraw(
      mismatch,
      uvAnimationPlan({generation,11u},{0.125f,-0.f}))==
      IOSGPUSceneUVAnimationRecordResult::InvalidEvidence);
  assert(recordIOSGPUSceneUVAnimationDraw(
      mismatch,uvAnimationPlan({generation,22u},{0.125f,0.f}))==
      IOSGPUSceneUVAnimationRecordResult::InvalidEvidence);

  IOSGPUSceneUVAnimationTracker complete;
  assert(prepareIOSGPUSceneUVAnimationTracker(
      evidence,generation,complete));
  assert(recordIOSGPUSceneUVAnimationDraw(
      complete,uvAnimationPlan({generation,22u},{-0.5f,0.25f}))==
      IOSGPUSceneUVAnimationRecordResult::RecordedFrameAndUv);
  assert(recordIOSGPUSceneUVAnimationDraw(
      complete,uvAnimationPlan({generation,11u},{0.125f,0.f}))==
      IOSGPUSceneUVAnimationRecordResult::RecordedUvOnly);
  assert(recordIOSGPUSceneUVAnimationDraw(
      complete,uvAnimationPlan({generation,11u},{0.125f,0.f}))==
      IOSGPUSceneUVAnimationRecordResult::DuplicateAnimated);

  IOSGPUSceneUVAnimationDrawReport encoded;
  assert(finalizeIOSGPUSceneUVAnimationDrawReport(complete,encoded));
  assert(encoded.valid);
  assert(encoded.drawnUvOnly==1u);
  assert(encoded.drawnFrameAndUv==1u);
  assert(encoded.encodedCount==2u);
  assert(encoded.encodedEntries==evidence.selections);
  assert(encoded.encodedEntries[0].sourceId==10u);
  assert(encoded.encodedEntries[1].sourceId==20u);
  assert(encoded.encodedTextureDigest==
         evidence.textureSelectionDigest);
  assert(encoded.encodedUVDigest==evidence.plannedUVDigest);

  auto corrupted = complete;
  corrupted.actuallyEncodedOffsets[0].x = 0.25f;
  IOSGPUSceneUVAnimationDrawReport corruptedReport;
  assert(!finalizeIOSGPUSceneUVAnimationDrawReport(
      corrupted,corruptedReport));
  assert(!corruptedReport.valid);
  corrupted = complete;
  corrupted.actuallyEncodedHandles[0].value = 99u;
  assert(!finalizeIOSGPUSceneUVAnimationDrawReport(
      corrupted,corruptedReport));
  assert(!corruptedReport.valid);
  }

}

int main() {
  testFrameAnimationDownstreamEvidence();
  testUVAnimationDownstreamEvidence();
  IOSCameraState camera;
  camera.viewProjection.set(1u,2u,3.f);

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  {
    static_assert(
        iosGPUSceneCompiledMode()==IOSGPUSceneMode::CausalA);
    assert(std::string_view(
        iosGPUSceneModeName(iosGPUSceneCompiledMode()))=="causal-a");
    assert(iosGPUSceneModeName(IOSGPUSceneMode::Production)==nullptr);
    testCausalArgumentsForMode<IOSGPUSceneMode::CausalA>(
        "-renderer-ios-native-alpha-test-causal-mode=causal-a",
        "-renderer-ios-native-alpha-test-causal-mode=unknown");
    testCausalRuntimeForMode<IOSGPUSceneMode::CausalA>(
        "-renderer-ios-native-alpha-test-causal-mode=causal-a",
        "causal-a");
    testCausalDispatchForMode<IOSGPUSceneMode::CausalA>();
    testCausalDrawIdentityForMode<IOSGPUSceneMode::CausalA>(
        "causal-a","alpha-test");
    const std::array arguments = {
      "-renderer-ios-native-alpha-test-causal-mode=causal-a",
      CausalNonceArgument,
      CausalSequenceArgument,
      };
    IOSGPUSceneCausalArguments parsed;
    assert(iosGPUSceneParseCausalArguments(
        static_cast<int>(arguments.size()),arguments.data(),parsed)==
        IOSGPUSceneCausalArgumentResult::Accepted);
    assert(parsed.mode==IOSGPUSceneMode::CausalA);
    IOSGPUSceneCausalDrawIdentity identity;
    assert(makeIOSGPUSceneCausalDrawIdentity(
        CausalNonce,7u,300u,1u,
        {IOSGPUScenePipelineSelector::AlphaTest,
         IOSGPUScenePipelineSelector::AlphaTest},
        IOSSceneMeshKind::Landscape,11u,22u,36u,identity)==
        IOSGPUSceneCausalDrawIdentityResult::Created);
  }
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  {
    static_assert(
        iosGPUSceneCompiledMode()==IOSGPUSceneMode::CausalB);
    assert(std::string_view(
        iosGPUSceneModeName(iosGPUSceneCompiledMode()))=="causal-b");
    assert(iosGPUSceneModeName(IOSGPUSceneMode::Production)==nullptr);
    testCausalArgumentsForMode<IOSGPUSceneMode::CausalB>(
        "-renderer-ios-native-alpha-test-causal-mode=causal-b",
        "-renderer-ios-native-alpha-test-causal-mode=unknown");
    testCausalRuntimeForMode<IOSGPUSceneMode::CausalB>(
        "-renderer-ios-native-alpha-test-causal-mode=causal-b",
        "causal-b");
    testCausalDispatchForMode<IOSGPUSceneMode::CausalB>();
    testCausalDrawIdentityForMode<IOSGPUSceneMode::CausalB>(
        "causal-b","opaque");
    const std::array arguments = {
      "-renderer-ios-native-alpha-test-causal-mode=causal-b",
      CausalNonceArgument,
      CausalSequenceArgument,
      };
    IOSGPUSceneCausalArguments parsed;
    assert(iosGPUSceneParseCausalArguments(
        static_cast<int>(arguments.size()),arguments.data(),parsed)==
        IOSGPUSceneCausalArgumentResult::Accepted);
    assert(parsed.mode==IOSGPUSceneMode::CausalB);
    IOSGPUSceneCausalDrawIdentity identity;
    assert(makeIOSGPUSceneCausalDrawIdentity(
        CausalNonce,7u,300u,1u,
        {IOSGPUScenePipelineSelector::AlphaTest,
         IOSGPUScenePipelineSelector::Opaque},
        IOSSceneMeshKind::Landscape,11u,22u,36u,identity)==
        IOSGPUSceneCausalDrawIdentityResult::Created);
  }
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  {
    static_assert(
        iosGPUSceneCompiledMode()==IOSGPUSceneMode::Production);
    assert(std::string_view(
        iosGPUSceneModeName(IOSGPUSceneMode::Production))=="production");
    assert(std::string_view(
        iosGPUSceneModeName(IOSGPUSceneMode::CausalA))=="causal-a");
    assert(std::string_view(
        iosGPUSceneModeName(IOSGPUSceneMode::CausalB))=="causal-b");
    assert(iosGPUSceneModeName(
        static_cast<IOSGPUSceneMode>(255u))==nullptr);
    testCausalArgumentsForMode<IOSGPUSceneMode::CausalA>(
        "-renderer-ios-native-alpha-test-causal-mode=causal-a",
        "-renderer-ios-native-alpha-test-causal-mode=causal-b");
    testCausalArgumentsForMode<IOSGPUSceneMode::CausalB>(
        "-renderer-ios-native-alpha-test-causal-mode=causal-b",
        "-renderer-ios-native-alpha-test-causal-mode=causal-a");
    testCausalRuntimeForMode<IOSGPUSceneMode::CausalA>(
        "-renderer-ios-native-alpha-test-causal-mode=causal-a",
        "causal-a");
    testCausalRuntimeForMode<IOSGPUSceneMode::CausalB>(
        "-renderer-ios-native-alpha-test-causal-mode=causal-b",
        "causal-b");
    testCausalDispatchForMode<IOSGPUSceneMode::Production>();
    testCausalDispatchForMode<IOSGPUSceneMode::CausalA>();
    testCausalDispatchForMode<IOSGPUSceneMode::CausalB>();
    testCausalDrawIdentityForMode<IOSGPUSceneMode::CausalA>(
        "causal-a","alpha-test");
    testCausalDrawIdentityForMode<IOSGPUSceneMode::CausalB>(
        "causal-b","opaque");

    IOSGPUScenePipelineSelector effective =
        IOSGPUScenePipelineSelector::AlphaTest;
    assert(!iosGPUSceneEffectivePipelineSelectorForMode(
        static_cast<IOSGPUSceneMode>(255u),
        IOSMaterialCategory::AlphaTest,
        IOSGPUScenePipelineSelector::AlphaTest,effective));
    assert(effective==IOSGPUScenePipelineSelector::AlphaTest);
    IOSGPUSceneFrameCounts counts;
    IOSGPUSceneDrawDispatch dispatch = {
      IOSGPUScenePipelineSelector::AlphaTest,
      IOSGPUScenePipelineSelector::Opaque,
      };
    IOSGPUSceneCausalDrawIdentity identitySentinel;
    identitySentinel.mode = IOSGPUSceneMode::CausalB;
    for(std::size_t index=0u; index<CausalNonce.size(); ++index)
      identitySentinel.nonce[index] = CausalNonce[index];
    identitySentinel.generation = 17u;
    identitySentinel.sequence = 18u;
    identitySentinel.ordinal = 19u;
    identitySentinel.logical = IOSGPUScenePipelineSelector::AlphaTest;
    identitySentinel.effective = IOSGPUScenePipelineSelector::Opaque;
    identitySentinel.kind = IOSSceneMeshKind::Movable;
    identitySentinel.texture = 20u;
    identitySentinel.mesh = 21u;
    identitySentinel.indices = 22u;
    for(const IOSGPUSceneMode invalidMode:{
          IOSGPUSceneMode::Production,
          static_cast<IOSGPUSceneMode>(255u)}) {
      IOSGPUSceneCausalDrawIdentity output = identitySentinel;
      std::array<std::byte,sizeof(output)> bytesBefore = {};
      std::memcpy(bytesBefore.data(),&output,sizeof(output));
      assert(makeIOSGPUSceneCausalDrawIdentityForMode(
          invalidMode,CausalNonce,7u,300u,1u,dispatch,
          IOSSceneMeshKind::Landscape,11u,22u,36u,output)==
          IOSGPUSceneCausalDrawIdentityResult::InvalidMode);
      assert(output==identitySentinel);
      std::array<std::byte,sizeof(output)> bytesAfter = {};
      std::memcpy(bytesAfter.data(),&output,sizeof(output));
      assert(bytesAfter==bytesBefore);
    }
    const auto countsBefore = counts;
    const auto dispatchBefore = dispatch;
    assert(recordIOSGPUSceneDrawDispatchForMode(
        static_cast<IOSGPUSceneMode>(255u),
        IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Landscape,
        false,true,IOSGPUScenePipelineSelector::AlphaTest,
        counts,dispatch)==IOSGPUSceneDrawDispatchResult::InvalidMode);
    assert(counts==countsBefore);
    assert(dispatch==dispatchBefore);
    IOSGPUSceneCausalArguments parsed;
    assert(iosGPUSceneParseCausalArguments(
        0,nullptr,parsed)==
        IOSGPUSceneCausalArgumentResult::InvalidCompileMode);
  }
#endif

  {
    auto source = validCandidate();
    source.entity.id.value = MovableSourceId;
    source.entity.kind = IOSSceneMeshKind::Movable;
    source.entity.currentTransform = movableT1();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::Draw);
    assert(plan.indexBufferOffset==3u*sizeof(uint32_t));
    assert(plan.indexCount==6u);
    assert(plan.constants.viewProjection.at(1u,2u)==3.f);
    assert(plan.constants.model==movableT1());
    assert(plan.constants.baseColor==source.material.baseColor);
    assert(plan.constants.uvOffset==source.material.uvOffset);
    assert(plan.baseColorTexture==source.material.baseColorTexture);
    assert(plan.materialCategory==IOSMaterialCategory::Opaque);
    assert(plan.kind==IOSSceneMeshKind::Movable);
    assert(plan.pipeline==IOSGPUScenePipelineSelector::Opaque);
    assert(!plan.usesFallbackTexture);
    assert(iosGPUSceneFailingHandle(
               IOSGPUSceneDrawPlanResult::Draw,source)==0u);
  }

  {
    auto source = validCandidate();
    source.entity.visibilityMask = IOSSceneVisibilityShadow;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::SkippedVisibility);
  }

  {
    auto source = validCandidate();
    source.registryGeneration = IOSWorldGeneration{8};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::GenerationMismatch);
  }

  {
    auto source = validCandidate();
    source.hasMaterial = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingMaterial);
  }

  {
    auto source = validCandidate();
    source.material.id.value += 1u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingMaterial);
  }

  {
    assert(iosGPUScenePipelineSelector(IOSMaterialCategory::Opaque)==
           IOSGPUScenePipelineSelector::Opaque);
    assert(iosGPUScenePipelineSelector(IOSMaterialCategory::AlphaTest)==
           IOSGPUScenePipelineSelector::AlphaTest);
    assert(iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::Opaque,
        IOSGPUScenePipelineSelector::Opaque));
    assert(iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::AlphaTest,
        IOSGPUScenePipelineSelector::AlphaTest));
    assert(!iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::Opaque,
        IOSGPUScenePipelineSelector::AlphaTest));
    assert(!iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::AlphaTest,
        IOSGPUScenePipelineSelector::Opaque));
    assert(!iosGPUScenePipelineSelectionMatches(
        IOSMaterialCategory::Opaque,
        IOSGPUScenePipelineSelector::Unsupported));
    for(unsigned mask=0u; mask<8u; ++mask) {
      const bool vertex = (mask&1u)!=0u;
      const bool opaqueFragment = (mask&2u)!=0u;
      const bool alphaTestFragment = (mask&4u)!=0u;
      assert(iosGPUSceneRequiredShaderFunctionsAreAvailable(
                 vertex,opaqueFragment,alphaTestFragment)==
             (mask==7u));
      }
    for(unsigned mask=0u; mask<4u; ++mask) {
      const bool opaque = (mask&1u)!=0u;
      const bool alphaTest = (mask&2u)!=0u;
      assert(iosGPUSceneProductionPipelineStatesAreAvailable(
                 opaque,alphaTest)==
             (mask==3u));
      }
    for(const auto category:{
          IOSMaterialCategory::Transparent,
          IOSMaterialCategory::Additive,
          IOSMaterialCategory::Water,
          static_cast<IOSMaterialCategory>(255u)}) {
      assert(iosGPUScenePipelineSelector(category)==
             IOSGPUScenePipelineSelector::Unsupported);
      auto source = validCandidate();
      source.material.category = category;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::UnsupportedMaterial);
      }
    for(const auto kind:{
          IOSSceneMeshKind::Landscape,
          IOSSceneMeshKind::Static,
          IOSSceneMeshKind::Movable}) {
      auto source = validCandidate();
      source.entity.kind = kind;
      source.material.category = IOSMaterialCategory::AlphaTest;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::Draw);
      assert(plan.kind==kind);
      assert(plan.materialCategory==IOSMaterialCategory::AlphaTest);
      assert(plan.pipeline==IOSGPUScenePipelineSelector::AlphaTest);
      assert(!plan.usesFallbackTexture);
      }
  }

  {
    for(const auto kind:{
          IOSSceneMeshKind::Landscape,
          IOSSceneMeshKind::Static,
          IOSSceneMeshKind::Movable}) {
      auto source = validCandidate();
      source.entity.kind = kind;
      source.material.usesFallbackTexture =
          kind==IOSSceneMeshKind::Static;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::Draw);
      assert(plan.kind==kind);
      assert(plan.materialCategory==IOSMaterialCategory::Opaque);
      assert(plan.pipeline==IOSGPUScenePipelineSelector::Opaque);
      assert(plan.usesFallbackTexture==
             source.material.usesFallbackTexture);
      }
  }

  {
    for(const auto kind:{
          IOSSceneMeshKind::Unsupported,
          static_cast<IOSSceneMeshKind>(255u)}) {
      auto source = validCandidate();
      source.entity.kind = kind;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::InvalidMesh);
      }
  }

  {
    auto source = validCandidate();
    source.material.baseColorTexture = {};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingTexture);
    assert(iosGPUSceneFailingHandle(
               IOSGPUSceneDrawPlanResult::MissingTexture,source)==
           source.entity.material.value);
  }

  {
    for(const bool removeHandle:{false,true}) {
      auto source = validCandidate();
      source.material.category = IOSMaterialCategory::AlphaTest;
      if(removeHandle)
        source.material.baseColorTexture = {};
      else
        source.hasTexture = false;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::MissingAlphaTexture);
      assert(iosGPUSceneFailingHandle(
                 IOSGPUSceneDrawPlanResult::MissingAlphaTexture,source)!=0u);
      }

    auto fallback = validCandidate();
    fallback.material.category = IOSMaterialCategory::AlphaTest;
    fallback.material.usesFallbackTexture = true;
    IOSGPUSceneDrawPlan fallbackPlan;
    assert(planIOSGPUSceneDraw(camera,fallback,fallbackPlan)==
           IOSGPUSceneDrawPlanResult::MissingAlphaTexture);

    for(const float cutoff:{
          0.f,0.499f,0.501f,1.f,
          std::numeric_limits<float>::quiet_NaN()}) {
      auto source = validCandidate();
      source.material.category = IOSMaterialCategory::AlphaTest;
      source.material.alphaCutoff = cutoff;
      IOSGPUSceneDrawPlan plan;
      assert(planIOSGPUSceneDraw(camera,source,plan)==
             IOSGPUSceneDrawPlanResult::InvalidAlphaCutoff);
      assert(iosGPUSceneFailingHandle(
                 IOSGPUSceneDrawPlanResult::InvalidAlphaCutoff,source)==
             source.entity.material.value);
      }
  }

  {
    auto source = validCandidate();
    source.material.baseColorTexture.generation = IOSWorldGeneration{8};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::GenerationMismatch);
    assert(iosGPUSceneFailingHandle(
               IOSGPUSceneDrawPlanResult::GenerationMismatch,source)==
           source.material.baseColorTexture.value);
  }

  {
    auto source = validCandidate();
    source.hasTexture = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingTexture);
  }

  {
    auto source = validCandidate();
    source.hasNativeTexture = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
    assert(iosGPUSceneFailingHandle(
               IOSGPUSceneDrawPlanResult::InvalidTexture,source)==
           source.material.baseColorTexture.value);
  }

  {
    auto source = validCandidate();
    source.hasSupportedTextureFormat = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.hasValidNativeTexture = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.textureWidth = 0u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.textureHeight = 0u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.textureMipCount = 0u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.textureMipCount = 11u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidTexture);
  }

  {
    auto source = validCandidate();
    source.hasMesh = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingMesh);
  }

  {
    auto source = validCandidate();
    source.entity.mesh.generation = IOSWorldGeneration{8};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::GenerationMismatch);
  }

  {
    auto source = validCandidate();
    source.entity.material.generation = IOSWorldGeneration{8};
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::GenerationMismatch);
  }

  {
    auto source = validCandidate();
    source.hasNativeVertexBuffer = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.hasNativeIndexBuffer = false;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.vertexStride = IOSLandscapeVertexStride+4u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.vertexBufferByteSize = IOSLandscapeVertexStride+1u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.indexBufferByteSize -= 1u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.indexCount = 0u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.indexCount = 5u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.firstIndex = 10u;
    source.indexCount = 6u;
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    IOSGPUSceneDrawPlan plan;
    plan.indexBufferOffset = 99u;
    plan.indexCount        = 88u;
    plan.constants.baseColor = {1.f,1.f,1.f,1.f};
    plan.constants.uvOffset = {1.f,1.f};
    source.hasMesh = false;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::MissingMesh);
    assert(plan.indexBufferOffset==0u);
    assert(plan.indexCount==0u);
    assert(plan.constants.baseColor==IOSFloat4{});
    assert(plan.constants.uvOffset==IOSFloat2{});
    assert(plan.baseColorTexture==IOSTextureHandle{});
    assert(plan.materialCategory==IOSMaterialCategory::Opaque);
    assert(plan.kind==IOSSceneMeshKind::Unsupported);
    assert(plan.pipeline==IOSGPUScenePipelineSelector::Unsupported);
    assert(!plan.usesFallbackTexture);
  }

  {
    auto invalidCamera = camera;
    invalidCamera.viewProjection.elements[0] =
        std::numeric_limits<float>::infinity();
    auto source = validCandidate();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(invalidCamera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.entity.currentTransform.elements[0] =
        std::numeric_limits<float>::quiet_NaN();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  {
    auto source = validCandidate();
    source.material.baseColor.x =
        std::numeric_limits<float>::infinity();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
  }

  for(const bool invalidateX:{false,true}) {
    auto source = validCandidate();
    if(invalidateX)
      source.material.uvOffset.x =
          std::numeric_limits<float>::quiet_NaN();
    else
      source.material.uvOffset.y =
          std::numeric_limits<float>::infinity();
    IOSGPUSceneDrawPlan plan;
    assert(planIOSGPUSceneDraw(camera,source,plan)==
           IOSGPUSceneDrawPlanResult::InvalidMesh);
    assert(plan.constants.uvOffset==IOSFloat2{});
  }

  {
    IOSGPUSceneDrawCounts counts;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
        true,true,counts)==IOSGPUSceneCountResult::Recorded);
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Static,
        false,true,counts)==IOSGPUSceneCountResult::Recorded);
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::AlphaTest,IOSSceneMeshKind::Movable,
        true,false,counts)==IOSGPUSceneCountResult::Recorded);
    assert(counts.material.total==3u);
    assert(counts.material.opaque==1u);
    assert(counts.material.alphaTest==2u);
    assert(counts.kind.total==3u);
    assert(counts.kind.landscape==1u);
    assert(counts.kind.staticMeshes==1u);
    assert(counts.kind.movable==1u);
    assert(counts.texturedDraws==2u);
    assert(counts.alphaFallback==1u);
    assert(iosGPUSceneCountsAreConsistent(counts));

    const IOSGPUSceneDrawCounts before = counts;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Water,IOSSceneMeshKind::Landscape,
        false,true,counts)==IOSGPUSceneCountResult::UnknownCategory);
    assert(counts==before);
    assert(recordIOSGPUSceneDrawCount(
        static_cast<IOSMaterialCategory>(255u),
        IOSSceneMeshKind::Landscape,
        false,true,counts)==IOSGPUSceneCountResult::UnknownCategory);
    assert(counts==before);
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Unsupported,
        false,true,counts)==IOSGPUSceneCountResult::UnknownKind);
    assert(counts==before);
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,
        static_cast<IOSSceneMeshKind>(255u),
        false,true,counts)==IOSGPUSceneCountResult::UnknownKind);
    assert(counts==before);

    for(std::size_t mutation=0u; mutation<8u; ++mutation) {
      auto broken = before;
      switch(mutation) {
        case 0u: ++broken.material.total; break;
        case 1u: ++broken.material.opaque; break;
        case 2u: ++broken.material.alphaTest; break;
        case 3u: ++broken.kind.total; break;
        case 4u: ++broken.kind.landscape; break;
        case 5u: ++broken.kind.staticMeshes; break;
        case 6u: ++broken.kind.movable; break;
        case 7u: broken.alphaFallback =
            broken.material.alphaTest+1u; break;
      }
      assert(!iosGPUSceneCountsAreConsistent(broken));
      const auto brokenBefore = broken;
      assert(recordIOSGPUSceneDrawCount(
          IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
          false,true,broken)==
          IOSGPUSceneCountResult::InconsistentCounts);
      assert(broken==brokenBefore);
      }
    auto excessiveTextured = before;
    excessiveTextured.texturedDraws =
        excessiveTextured.material.total+1u;
    assert(!iosGPUSceneCountsAreConsistent(excessiveTextured));
    const auto excessiveTexturedBefore = excessiveTextured;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
        false,true,excessiveTextured)==
        IOSGPUSceneCountResult::InconsistentCounts);
    assert(excessiveTextured==excessiveTexturedBefore);

    IOSGPUSceneDrawCounts overflow;
    overflow.material.total = std::numeric_limits<uint64_t>::max();
    overflow.material.opaque = overflow.material.total;
    overflow.kind.total = overflow.material.total;
    overflow.kind.landscape = overflow.kind.total;
    overflow.texturedDraws = overflow.material.total;
    assert(iosGPUSceneCountsAreConsistent(overflow));
    const auto overflowBefore = overflow;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
        false,true,overflow)==IOSGPUSceneCountResult::Overflow);
    assert(overflow==overflowBefore);

    auto corrupted = before;
    ++corrupted.kind.total;
    const auto corruptedBefore = corrupted;
    assert(recordIOSGPUSceneDrawCount(
        IOSMaterialCategory::Opaque,IOSSceneMeshKind::Landscape,
        false,true,corrupted)==
        IOSGPUSceneCountResult::InconsistentCounts);
    assert(corrupted==corruptedBefore);
  }

  {
    IOSGPUSceneFrameCounts counts;
    for(const auto entry:{
          std::pair{IOSMaterialCategory::Opaque,
                    IOSSceneMeshKind::Landscape},
          std::pair{IOSMaterialCategory::AlphaTest,
                    IOSSceneMeshKind::Static},
          std::pair{IOSMaterialCategory::AlphaTest,
                    IOSSceneMeshKind::Movable}}) {
      assert(recordIOSGPUSceneDrawCount(
          entry.first,entry.second,false,false,counts.planned)==
          IOSGPUSceneCountResult::Recorded);
      assert(recordIOSGPUSceneDrawCount(
          entry.first,entry.second,false,true,counts.drawn)==
          IOSGPUSceneCountResult::Recorded);
      }
    counts.opaquePsoBinds = 1u;
    counts.alphaPsoBinds = 2u;
    assert(iosGPUSceneProductionFrameCountsAreConsistent(counts));
    IOSGPUSceneFailureCounts failures;
    assert(iosGPUSceneFailureCountsAreClear(failures));
    assert(iosGPUSceneProductionReportCountsAreConsistent(
        counts,failures));

    for(std::size_t mutation=0u; mutation<9u; ++mutation) {
      auto broken = failures;
      switch(mutation) {
        case 0u: ++broken.unknownCategory; break;
        case 1u: ++broken.unknownKind; break;
        case 2u: ++broken.invalidCutoff; break;
        case 3u: ++broken.missingAlphaTexture; break;
        case 4u: ++broken.selectorMismatch; break;
        case 5u: ++broken.psoUnavailable; break;
        case 6u: ++broken.overflow; break;
        case 7u: ++broken.plannedDrawn; break;
        case 8u: ++broken.nativeEncode; break;
        }
      assert(!iosGPUSceneFailureCountsAreClear(broken));
      assert(!iosGPUSceneProductionReportCountsAreConsistent(
          counts,broken));
      }

    for(std::size_t mutation=0u; mutation<23u; ++mutation) {
      auto broken = counts;
      switch(mutation) {
        case 0u: ++broken.planned.material.total; break;
        case 1u: ++broken.planned.material.opaque; break;
        case 2u: ++broken.planned.material.alphaTest; break;
        case 3u: ++broken.planned.kind.total; break;
        case 4u: ++broken.planned.kind.landscape; break;
        case 5u: ++broken.planned.kind.staticMeshes; break;
        case 6u: ++broken.planned.kind.movable; break;
        case 7u: ++broken.planned.texturedDraws; break;
        case 8u: ++broken.planned.alphaFallback; break;
        case 9u: ++broken.drawn.material.total; break;
        case 10u: ++broken.drawn.material.opaque; break;
        case 11u: ++broken.drawn.material.alphaTest; break;
        case 12u: ++broken.drawn.kind.total; break;
        case 13u: ++broken.drawn.kind.landscape; break;
        case 14u: ++broken.drawn.kind.staticMeshes; break;
        case 15u: ++broken.drawn.kind.movable; break;
        case 16u: --broken.drawn.texturedDraws; break;
        case 17u: ++broken.drawn.alphaFallback; break;
        case 18u: ++broken.opaquePsoBinds; break;
        case 19u: ++broken.alphaPsoBinds; break;
        case 20u: ++broken.controlAlphaToOpaqueBinds; break;
        case 21u: --broken.planned.material.total; break;
        case 22u: --broken.drawn.kind.total; break;
        }
      assert(!iosGPUSceneProductionFrameCountsAreConsistent(broken));
      }

    auto alphaFallback = counts;
    alphaFallback.drawn.alphaFallback = 1u;
    assert(!iosGPUSceneProductionFrameCountsAreConsistent(alphaFallback));

    auto causalB = counts;
    causalB.opaquePsoBinds = causalB.drawn.material.total;
    causalB.alphaPsoBinds = 0u;
    causalB.controlAlphaToOpaqueBinds =
        causalB.drawn.material.alphaTest;
    assert(iosGPUSceneCausalBFrameCountsAreConsistent(causalB));
    assert(!iosGPUSceneProductionFrameCountsAreConsistent(causalB));
    assert(!iosGPUSceneCausalBFrameCountsAreConsistent(counts));

    for(std::size_t mutation=0u; mutation<3u; ++mutation) {
      auto broken = causalB;
      switch(mutation) {
        case 0u: ++broken.opaquePsoBinds; break;
        case 1u: ++broken.alphaPsoBinds; break;
        case 2u: ++broken.controlAlphaToOpaqueBinds; break;
        }
      assert(!iosGPUSceneCausalBFrameCountsAreConsistent(broken));
      }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
    assert(iosGPUSceneFrameCountsAreConsistentForMode(counts));
    assert(iosGPUSceneReportCountsAreConsistentForMode(
        counts,failures));
    assert(!iosGPUSceneFrameCountsAreConsistentForMode(causalB));
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    assert(!iosGPUSceneFrameCountsAreConsistentForMode(counts));
    assert(iosGPUSceneFrameCountsAreConsistentForMode(causalB));
    assert(iosGPUSceneReportCountsAreConsistentForMode(
        causalB,failures));
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
    assert(iosGPUSceneFrameCountsAreConsistentForMode(
        IOSGPUSceneMode::Production,counts));
    assert(iosGPUSceneFrameCountsAreConsistentForMode(
        IOSGPUSceneMode::CausalA,counts));
    assert(iosGPUSceneFrameCountsAreConsistentForMode(
        IOSGPUSceneMode::CausalB,causalB));
    assert(!iosGPUSceneFrameCountsAreConsistentForMode(
        IOSGPUSceneMode::CausalB,counts));
    assert(!iosGPUSceneFrameCountsAreConsistentForMode(
        static_cast<IOSGPUSceneMode>(255u),counts));
    assert(iosGPUSceneReportCountsAreConsistentForMode(
        IOSGPUSceneMode::CausalB,causalB,failures));
    auto failure = failures;
    failure.selectorMismatch = 1u;
    assert(!iosGPUSceneReportCountsAreConsistentForMode(
        IOSGPUSceneMode::CausalB,causalB,failure));
#endif
  }

  {
    IOSGPUSceneFrameCounts counts;
    counts.planned.material = {3u,1u,2u};
    counts.planned.kind = {3u,1u,1u,1u};
    counts.drawn.material = {3u,1u,2u};
    counts.drawn.kind = {3u,1u,1u,1u};
    counts.drawn.texturedDraws = 3u;
    counts.opaquePsoBinds = 1u;
    counts.alphaPsoBinds = 2u;
    IOSGPUSceneFailureCounts failures;

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
    testSceneMarkerGrammar(
        "causal-a",counts,failures,
        " opaque-pso=1 alpha-pso=2 control-alpha-to-opaque=0 "
        "alpha-fallback=0");
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
    counts.opaquePsoBinds = 3u;
    counts.alphaPsoBinds = 0u;
    counts.controlAlphaToOpaqueBinds = 2u;
    testSceneMarkerGrammar(
        "causal-b",counts,failures,
        " opaque-pso=3 alpha-pso=0 control-alpha-to-opaque=2 "
        "alpha-fallback=0");
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
    testSceneMarkerGrammar(
        "production",counts,failures,
        " opaque-pso=1 alpha-pso=2 control-alpha-to-opaque=0 "
        "alpha-fallback=0");
#else
    const auto assertMarker = [](
        const IOSGPUSceneMarker& marker,
        std::string_view expected) {
      assert(marker);
      assert(marker.length==expected.size());
      assert(marker.length<IOSGPUSceneMarkerCapacity);
      assert(marker.text[marker.length]=='\0');
      assert(std::string_view(marker.text.data(),marker.length)==expected);
      };
    assertMarker(
        iosGPUSceneIdentityMarker(7u,300u),
        "RendererIOS native scene identity: mode=production "
        "generation=7 sequence=300");
    assertMarker(
        iosGPUSceneMaterialPlannedMarker(counts),
        "RendererIOS native scene material-planned: mode=production "
        "total=3 opaque=1 alpha=2");
    assertMarker(
        iosGPUSceneMaterialDrawnMarker(counts),
        "RendererIOS native scene material-drawn: mode=production "
        "total=3 opaque=1 alpha=2 textured=3");
    assertMarker(
        iosGPUSceneKindPlannedMarker(counts),
        "RendererIOS native scene kind-planned: mode=production "
        "total=3 landscape=1 static=1 movable=1");
    assertMarker(
        iosGPUSceneKindDrawnMarker(counts),
        "RendererIOS native scene kind-drawn: mode=production "
        "total=3 landscape=1 static=1 movable=1");
    assertMarker(
        iosGPUSceneAlphaMarker(counts),
        "RendererIOS native scene alpha: mode=production "
        "opaque-pso=1 alpha-pso=2 control-alpha-to-opaque=0 "
        "alpha-fallback=0");
    assertMarker(
        iosGPUSceneFailContractMarker(failures),
        "RendererIOS native scene fail-contract: mode=production "
        "unknown-category=0 unknown-kind=0 invalid-cutoff=0 "
        "missing-alpha-texture=0");
    assertMarker(
        iosGPUSceneFailSelectorMarker(failures),
        "RendererIOS native scene fail-selector: mode=production "
        "selector-mismatch=0 pso-unavailable=0");
    assertMarker(
        iosGPUSceneFailExecutionMarker(failures),
        "RendererIOS native scene fail-execution: mode=production "
        "overflow=0 planned-drawn=0 native-encode=0");
#endif

    constexpr uint64_t maximum =
        std::numeric_limits<uint64_t>::max();
    IOSGPUSceneFrameCounts worstFrame;
    worstFrame.planned.material = {maximum,maximum,maximum};
    worstFrame.planned.kind = {maximum,maximum,maximum,maximum};
    worstFrame.drawn.material = {maximum,maximum,maximum};
    worstFrame.drawn.kind = {maximum,maximum,maximum,maximum};
    worstFrame.drawn.texturedDraws = maximum;
    worstFrame.drawn.alphaFallback = maximum;
    worstFrame.opaquePsoBinds = maximum;
    worstFrame.alphaPsoBinds = maximum;
    worstFrame.controlAlphaToOpaqueBinds = maximum;
    IOSGPUSceneFailureCounts worstFailure = {
      maximum,maximum,maximum,maximum,maximum,
      maximum,maximum,maximum,maximum,
      };
    const IOSGPUSceneMarker worstMarkers[] = {
      iosGPUSceneIdentityMarker(maximum,maximum),
      iosGPUSceneMaterialPlannedMarker(worstFrame),
      iosGPUSceneMaterialDrawnMarker(worstFrame),
      iosGPUSceneKindPlannedMarker(worstFrame),
      iosGPUSceneKindDrawnMarker(worstFrame),
      iosGPUSceneAlphaMarker(worstFrame),
      iosGPUSceneFailContractMarker(worstFailure),
      iosGPUSceneFailSelectorMarker(worstFailure),
      iosGPUSceneFailExecutionMarker(worstFailure),
      };
    for(const auto& marker:worstMarkers) {
      assert(marker);
      assert(marker.length<IOSGPUSceneMarkerCapacity);
      assert(marker.text[marker.length]=='\0');
      }
  }
  return 0;
  }
