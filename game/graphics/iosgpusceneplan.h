#pragma once

#include "iosframeanimationevidence.h"
#include "iosscenesnapshot.h"
#include "iosuvanimationevidence.h"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdint>
#include <limits>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) && \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
#error "RendererIOS native AlphaTest causal A and B are mutually exclusive"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST) && \
    (defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
     defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B))
#error "RendererIOS native AlphaTest causal host test is mutually exclusive with A and B"
#endif

inline constexpr std::size_t IOSLandscapeVertexStride = 36u;
inline constexpr std::size_t IOSLandscapeIndexStride  = sizeof(uint32_t);

enum class IOSGPUSceneDrawPlanResult : uint8_t {
  Draw,
  SkippedVisibility,
  GenerationMismatch,
  MissingMaterial,
  UnsupportedMaterial,
  InvalidAlphaCutoff,
  MissingAlphaTexture,
  MissingTexture,
  InvalidTexture,
  MissingMesh,
  InvalidMesh,
  };

enum class IOSGPUScenePipelineSelector : uint8_t {
  Unsupported,
  Opaque,
  AlphaTest,
  };

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
enum class IOSGPUSceneMode : uint8_t {
  Production,
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  CausalA,
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  CausalB,
#endif
  };

inline constexpr IOSGPUSceneMode iosGPUSceneCompiledMode() noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  return IOSGPUSceneMode::CausalA;
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  return IOSGPUSceneMode::CausalB;
#else
  return IOSGPUSceneMode::Production;
#endif
  }

inline constexpr const char* iosGPUSceneModeName(
    IOSGPUSceneMode mode) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  return mode==IOSGPUSceneMode::CausalA ? "causal-a" : nullptr;
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  return mode==IOSGPUSceneMode::CausalB ? "causal-b" : nullptr;
#else
  switch(mode) {
    case IOSGPUSceneMode::Production:
      return "production";
    case IOSGPUSceneMode::CausalA:
      return "causal-a";
    case IOSGPUSceneMode::CausalB:
      return "causal-b";
    }
  return nullptr;
#endif
  }

inline constexpr std::string_view IOSGPUSceneCausalArgumentRoot =
    "-renderer-ios-native-alpha-test-causal-";
inline constexpr std::string_view IOSGPUSceneCausalModeArgument =
    "-renderer-ios-native-alpha-test-causal-mode=";
inline constexpr std::string_view IOSGPUSceneCausalNonceArgument =
    "-renderer-ios-native-alpha-test-causal-nonce=";
inline constexpr std::string_view IOSGPUSceneCausalSequenceArgument =
    "-renderer-ios-native-alpha-test-causal-sequence=";
inline constexpr std::size_t IOSGPUSceneCausalNonceLength = 32u;

enum class IOSGPUSceneCausalArgumentResult : uint8_t {
  Accepted,
  InvalidArgumentVector,
  InvalidCompileMode,
  MissingMode,
  MissingNonce,
  MissingSequence,
  DuplicateMode,
  DuplicateNonce,
  DuplicateSequence,
  UnknownCausalArgument,
  ModeMismatch,
  InvalidNonce,
  InvalidSequence,
  };

struct IOSGPUSceneCausalArguments final {
  IOSGPUSceneMode             mode = IOSGPUSceneMode::Production;
  std::array<char,IOSGPUSceneCausalNonceLength+1u> nonce = {};
  uint64_t                    sequence = 0;

  constexpr bool operator==(
      const IOSGPUSceneCausalArguments&) const noexcept = default;
  };

inline constexpr bool iosGPUSceneCausalNonceIsValid(
    std::string_view nonce) noexcept {
  if(nonce.size()!=IOSGPUSceneCausalNonceLength)
    return false;
  for(const char value:nonce)
    if(!((value>='0' && value<='9') ||
         (value>='a' && value<='f')))
      return false;
  return true;
  }

inline constexpr bool iosGPUSceneCausalNonceArrayIsValid(
    const std::array<char,IOSGPUSceneCausalNonceLength+1u>& nonce) noexcept {
  if(nonce[IOSGPUSceneCausalNonceLength]!='\0')
    return false;
  for(std::size_t index=0u;
      index<IOSGPUSceneCausalNonceLength;
      ++index) {
    const char value = nonce[index];
    if(!((value>='0' && value<='9') ||
         (value>='a' && value<='f')))
      return false;
    }
  return true;
  }

inline constexpr bool iosGPUSceneParseCanonicalSequence(
    std::string_view value,
    uint64_t& sequence) noexcept {
  if(value.empty() || value.front()<'1' || value.front()>'9')
    return false;
  uint64_t parsed = 0;
  for(const char digit:value) {
    if(digit<'0' || digit>'9')
      return false;
    const uint64_t component =
        static_cast<uint64_t>(digit-'0');
    if(parsed>(std::numeric_limits<uint64_t>::max()-component)/10u)
      return false;
    parsed = parsed*10u+component;
    }
  sequence = parsed;
  return true;
  }

template<IOSGPUSceneMode ExpectedMode>
inline IOSGPUSceneCausalArgumentResult
    iosGPUSceneParseCausalArgumentsForCompileMode(
        int argc,
        const char* const* argv,
        IOSGPUSceneCausalArguments& output) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  static_assert(ExpectedMode==IOSGPUSceneMode::CausalA);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  static_assert(ExpectedMode==IOSGPUSceneMode::CausalB);
#else
  static_assert(
      ExpectedMode==IOSGPUSceneMode::CausalA ||
      ExpectedMode==IOSGPUSceneMode::CausalB);
#endif
  const char* const expectedModeName = iosGPUSceneModeName(ExpectedMode);
  if(expectedModeName==nullptr)
    return IOSGPUSceneCausalArgumentResult::InvalidCompileMode;
  if(argc<0 || (argc>0 && argv==nullptr))
    return IOSGPUSceneCausalArgumentResult::InvalidArgumentVector;

  std::string_view modeValue;
  std::string_view nonceValue;
  std::string_view sequenceValue;
  bool modeSeen = false;
  bool nonceSeen = false;
  bool sequenceSeen = false;
  for(int index=0; index<argc; ++index) {
    if(argv[index]==nullptr)
      return IOSGPUSceneCausalArgumentResult::InvalidArgumentVector;
    const std::string_view argument(argv[index]);
    if(argument.starts_with(IOSGPUSceneCausalModeArgument)) {
      if(modeSeen)
        return IOSGPUSceneCausalArgumentResult::DuplicateMode;
      modeSeen = true;
      modeValue = argument.substr(IOSGPUSceneCausalModeArgument.size());
      continue;
      }
    if(argument.starts_with(IOSGPUSceneCausalNonceArgument)) {
      if(nonceSeen)
        return IOSGPUSceneCausalArgumentResult::DuplicateNonce;
      nonceSeen = true;
      nonceValue = argument.substr(IOSGPUSceneCausalNonceArgument.size());
      continue;
      }
    if(argument.starts_with(IOSGPUSceneCausalSequenceArgument)) {
      if(sequenceSeen)
        return IOSGPUSceneCausalArgumentResult::DuplicateSequence;
      sequenceSeen = true;
      sequenceValue =
          argument.substr(IOSGPUSceneCausalSequenceArgument.size());
      continue;
      }
    if(argument.starts_with(IOSGPUSceneCausalArgumentRoot))
      return IOSGPUSceneCausalArgumentResult::UnknownCausalArgument;
    }
  if(!modeSeen)
    return IOSGPUSceneCausalArgumentResult::MissingMode;
  if(!nonceSeen)
    return IOSGPUSceneCausalArgumentResult::MissingNonce;
  if(!sequenceSeen)
    return IOSGPUSceneCausalArgumentResult::MissingSequence;
  if(modeValue!=expectedModeName)
    return IOSGPUSceneCausalArgumentResult::ModeMismatch;
  if(!iosGPUSceneCausalNonceIsValid(nonceValue))
    return IOSGPUSceneCausalArgumentResult::InvalidNonce;

  IOSGPUSceneCausalArguments parsed;
  parsed.mode = ExpectedMode;
  if(!iosGPUSceneParseCanonicalSequence(
         sequenceValue,parsed.sequence))
    return IOSGPUSceneCausalArgumentResult::InvalidSequence;
  for(std::size_t index=0u; index<nonceValue.size(); ++index)
    parsed.nonce[index] = nonceValue[index];
  output = parsed;
  return IOSGPUSceneCausalArgumentResult::Accepted;
  }

inline IOSGPUSceneCausalArgumentResult iosGPUSceneParseCausalArguments(
    int argc,
    const char* const* argv,
    IOSGPUSceneCausalArguments& output) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  return iosGPUSceneParseCausalArgumentsForCompileMode<
      IOSGPUSceneMode::CausalA>(argc,argv,output);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  return iosGPUSceneParseCausalArgumentsForCompileMode<
      IOSGPUSceneMode::CausalB>(argc,argv,output);
#else
  (void)argc;
  (void)argv;
  (void)output;
  return IOSGPUSceneCausalArgumentResult::InvalidCompileMode;
#endif
  }

inline constexpr const char* iosGPUSceneCausalArgumentResultName(
    IOSGPUSceneCausalArgumentResult result) noexcept {
  switch(result) {
    case IOSGPUSceneCausalArgumentResult::Accepted:
      return "accepted";
    case IOSGPUSceneCausalArgumentResult::InvalidArgumentVector:
      return "invalid-argument-vector";
    case IOSGPUSceneCausalArgumentResult::InvalidCompileMode:
      return "invalid-compile-mode";
    case IOSGPUSceneCausalArgumentResult::MissingMode:
      return "missing-mode";
    case IOSGPUSceneCausalArgumentResult::MissingNonce:
      return "missing-nonce";
    case IOSGPUSceneCausalArgumentResult::MissingSequence:
      return "missing-sequence";
    case IOSGPUSceneCausalArgumentResult::DuplicateMode:
      return "duplicate-mode";
    case IOSGPUSceneCausalArgumentResult::DuplicateNonce:
      return "duplicate-nonce";
    case IOSGPUSceneCausalArgumentResult::DuplicateSequence:
      return "duplicate-sequence";
    case IOSGPUSceneCausalArgumentResult::UnknownCausalArgument:
      return "unknown-causal-argument";
    case IOSGPUSceneCausalArgumentResult::ModeMismatch:
      return "mode-mismatch";
    case IOSGPUSceneCausalArgumentResult::InvalidNonce:
      return "invalid-nonce";
    case IOSGPUSceneCausalArgumentResult::InvalidSequence:
      return "invalid-sequence";
    }
  return nullptr;
  }

enum class IOSGPUSceneCausalRuntimePhase : uint8_t {
  AwaitingTarget,
  TargetPrepared,
  TargetEncoded,
  Failed,
  };

enum class IOSGPUSceneCausalFrameRoute : uint8_t {
  Production,
  Target,
  };

enum class IOSGPUSceneCausalFrameResult : uint8_t {
  Prepared,
  InvalidArguments,
  InvalidGeneration,
  InvalidSequence,
  InvalidPhase,
  GenerationChangedBeforeTarget,
  SequenceNotIncreasing,
  TargetMissed,
  TargetReused,
  };

enum class IOSGPUSceneCausalFailureReason : uint8_t {
  InvalidArguments,
  InvalidGeneration,
  InvalidSequence,
  InvalidPhase,
  GenerationChangedBeforeTarget,
  SequenceNotIncreasing,
  TargetMissed,
  TargetReused,
  TargetNotObserved,
  PlanPreflight,
  AssetPreflight,
  DispatchPreflight,
  PipelinePreflight,
  OrdinalPreflight,
  IdentityPreflight,
  MarkerPreflight,
  EquationsPreflight,
  MissingAlphaTestDraw,
  NoActiveRenderEncoder,
  NativeException,
  NativeEncode,
  };

struct IOSGPUSceneCausalRuntimeState final {
  IOSGPUSceneCausalArguments arguments;
  uint64_t                   generation = 0;
  uint64_t                   lastSequence = 0;
  IOSGPUSceneCausalRuntimePhase phase =
      IOSGPUSceneCausalRuntimePhase::AwaitingTarget;

  constexpr bool operator==(
      const IOSGPUSceneCausalRuntimeState&) const noexcept = default;
  };

template<IOSGPUSceneMode Mode>
inline constexpr bool iosGPUSceneInitializeCausalRuntimeForCompileMode(
    const IOSGPUSceneCausalArguments& arguments,
    IOSGPUSceneCausalRuntimeState& output) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  static_assert(Mode==IOSGPUSceneMode::CausalA);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  static_assert(Mode==IOSGPUSceneMode::CausalB);
#else
  static_assert(
      Mode==IOSGPUSceneMode::CausalA ||
      Mode==IOSGPUSceneMode::CausalB);
#endif
  if(arguments.mode!=Mode ||
     !iosGPUSceneCausalNonceArrayIsValid(arguments.nonce) ||
     arguments.sequence==0u)
    return false;
  IOSGPUSceneCausalRuntimeState initialized;
  initialized.arguments = arguments;
  output = initialized;
  return true;
  }

inline constexpr bool iosGPUSceneInitializeCausalRuntime(
    const IOSGPUSceneCausalArguments& arguments,
    IOSGPUSceneCausalRuntimeState& output) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  return iosGPUSceneInitializeCausalRuntimeForCompileMode<
      IOSGPUSceneMode::CausalA>(arguments,output);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  return iosGPUSceneInitializeCausalRuntimeForCompileMode<
      IOSGPUSceneMode::CausalB>(arguments,output);
#else
  (void)arguments;
  (void)output;
  return false;
#endif
  }

template<IOSGPUSceneMode Mode>
inline constexpr IOSGPUSceneCausalFrameResult
    iosGPUScenePrepareCausalObservationForCompileMode(
        const IOSGPUSceneCausalRuntimeState& current,
        uint64_t generation,
        uint64_t sequence,
        IOSGPUSceneCausalFrameRoute& route,
        IOSGPUSceneCausalRuntimeState& prepared) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  static_assert(Mode==IOSGPUSceneMode::CausalA);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  static_assert(Mode==IOSGPUSceneMode::CausalB);
#else
  static_assert(
      Mode==IOSGPUSceneMode::CausalA ||
      Mode==IOSGPUSceneMode::CausalB);
#endif
  if(current.arguments.mode!=Mode ||
     !iosGPUSceneCausalNonceArrayIsValid(current.arguments.nonce) ||
     current.arguments.sequence==0u)
    return IOSGPUSceneCausalFrameResult::InvalidArguments;
  if(generation==0u)
    return IOSGPUSceneCausalFrameResult::InvalidGeneration;
  if(sequence==0u)
    return IOSGPUSceneCausalFrameResult::InvalidSequence;
  if(current.phase==IOSGPUSceneCausalRuntimePhase::Failed ||
     current.phase==IOSGPUSceneCausalRuntimePhase::TargetPrepared)
    return IOSGPUSceneCausalFrameResult::InvalidPhase;

  IOSGPUSceneCausalRuntimeState candidate = current;
  IOSGPUSceneCausalFrameRoute selected =
      IOSGPUSceneCausalFrameRoute::Production;
  const uint64_t target = current.arguments.sequence;
  if(current.phase==IOSGPUSceneCausalRuntimePhase::TargetEncoded) {
    if(generation==current.generation && sequence==target)
      return IOSGPUSceneCausalFrameResult::TargetReused;
    route = selected;
    prepared = candidate;
    return IOSGPUSceneCausalFrameResult::Prepared;
    }

  if(candidate.generation==0u)
    candidate.generation = generation;
  else if(candidate.generation!=generation)
    return IOSGPUSceneCausalFrameResult::GenerationChangedBeforeTarget;
  if(candidate.lastSequence!=0u && sequence<=candidate.lastSequence)
    return IOSGPUSceneCausalFrameResult::SequenceNotIncreasing;
  if(sequence>target)
    return IOSGPUSceneCausalFrameResult::TargetMissed;
  if(sequence==target) {
    selected = IOSGPUSceneCausalFrameRoute::Target;
    candidate.phase = IOSGPUSceneCausalRuntimePhase::TargetPrepared;
    }
  candidate.lastSequence = sequence;
  route = selected;
  prepared = candidate;
  return IOSGPUSceneCausalFrameResult::Prepared;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
inline constexpr IOSGPUSceneCausalFrameResult
    iosGPUScenePrepareCausalObservation(
    const IOSGPUSceneCausalRuntimeState& current,
    uint64_t generation,
    uint64_t sequence,
    IOSGPUSceneCausalFrameRoute& route,
    IOSGPUSceneCausalRuntimeState& prepared) noexcept {
  return iosGPUScenePrepareCausalObservationForCompileMode<
      iosGPUSceneCompiledMode()>(
          current,generation,sequence,route,prepared);
  }
#endif

inline constexpr bool iosGPUSceneTransitionCausalFailure(
    IOSGPUSceneCausalRuntimeState& state,
    IOSGPUSceneCausalFailureReason reason) noexcept {
  if(state.phase==IOSGPUSceneCausalRuntimePhase::Failed)
    return false;
  if(state.phase==IOSGPUSceneCausalRuntimePhase::TargetEncoded &&
     reason!=IOSGPUSceneCausalFailureReason::TargetReused)
    return false;
  state.phase = IOSGPUSceneCausalRuntimePhase::Failed;
  return true;
  }

inline constexpr const char* iosGPUSceneCausalFrameResultName(
    IOSGPUSceneCausalFrameResult result) noexcept {
  switch(result) {
    case IOSGPUSceneCausalFrameResult::Prepared:
      return "prepared";
    case IOSGPUSceneCausalFrameResult::InvalidArguments:
      return "invalid-arguments";
    case IOSGPUSceneCausalFrameResult::InvalidGeneration:
      return "invalid-generation";
    case IOSGPUSceneCausalFrameResult::InvalidSequence:
      return "invalid-sequence";
    case IOSGPUSceneCausalFrameResult::InvalidPhase:
      return "invalid-phase";
    case IOSGPUSceneCausalFrameResult::GenerationChangedBeforeTarget:
      return "generation-changed-before-target";
    case IOSGPUSceneCausalFrameResult::SequenceNotIncreasing:
      return "sequence-not-increasing";
    case IOSGPUSceneCausalFrameResult::TargetMissed:
      return "target-missed";
    case IOSGPUSceneCausalFrameResult::TargetReused:
      return "target-reused";
    }
  return nullptr;
  }

inline constexpr IOSGPUSceneCausalFailureReason
    iosGPUSceneCausalFailureReasonForFrameResult(
        IOSGPUSceneCausalFrameResult result) noexcept {
  switch(result) {
    case IOSGPUSceneCausalFrameResult::InvalidArguments:
      return IOSGPUSceneCausalFailureReason::InvalidArguments;
    case IOSGPUSceneCausalFrameResult::InvalidGeneration:
      return IOSGPUSceneCausalFailureReason::InvalidGeneration;
    case IOSGPUSceneCausalFrameResult::InvalidSequence:
      return IOSGPUSceneCausalFailureReason::InvalidSequence;
    case IOSGPUSceneCausalFrameResult::InvalidPhase:
      return IOSGPUSceneCausalFailureReason::InvalidPhase;
    case IOSGPUSceneCausalFrameResult::GenerationChangedBeforeTarget:
      return IOSGPUSceneCausalFailureReason::GenerationChangedBeforeTarget;
    case IOSGPUSceneCausalFrameResult::SequenceNotIncreasing:
      return IOSGPUSceneCausalFailureReason::SequenceNotIncreasing;
    case IOSGPUSceneCausalFrameResult::TargetMissed:
      return IOSGPUSceneCausalFailureReason::TargetMissed;
    case IOSGPUSceneCausalFrameResult::TargetReused:
      return IOSGPUSceneCausalFailureReason::TargetReused;
    case IOSGPUSceneCausalFrameResult::Prepared:
      break;
    }
  return IOSGPUSceneCausalFailureReason::InvalidPhase;
  }

inline constexpr const char* iosGPUSceneCausalFailureReasonName(
    IOSGPUSceneCausalFailureReason reason) noexcept {
  switch(reason) {
    case IOSGPUSceneCausalFailureReason::InvalidArguments:
      return "invalid-arguments";
    case IOSGPUSceneCausalFailureReason::InvalidGeneration:
      return "invalid-generation";
    case IOSGPUSceneCausalFailureReason::InvalidSequence:
      return "invalid-sequence";
    case IOSGPUSceneCausalFailureReason::InvalidPhase:
      return "invalid-phase";
    case IOSGPUSceneCausalFailureReason::GenerationChangedBeforeTarget:
      return "generation-changed-before-target";
    case IOSGPUSceneCausalFailureReason::SequenceNotIncreasing:
      return "sequence-not-increasing";
    case IOSGPUSceneCausalFailureReason::TargetMissed:
      return "target-missed";
    case IOSGPUSceneCausalFailureReason::TargetReused:
      return "target-reused";
    case IOSGPUSceneCausalFailureReason::TargetNotObserved:
      return "target-not-observed";
    case IOSGPUSceneCausalFailureReason::PlanPreflight:
      return "plan-preflight";
    case IOSGPUSceneCausalFailureReason::AssetPreflight:
      return "asset-preflight";
    case IOSGPUSceneCausalFailureReason::DispatchPreflight:
      return "dispatch-preflight";
    case IOSGPUSceneCausalFailureReason::PipelinePreflight:
      return "pipeline-preflight";
    case IOSGPUSceneCausalFailureReason::OrdinalPreflight:
      return "ordinal-preflight";
    case IOSGPUSceneCausalFailureReason::IdentityPreflight:
      return "identity-preflight";
    case IOSGPUSceneCausalFailureReason::MarkerPreflight:
      return "marker-preflight";
    case IOSGPUSceneCausalFailureReason::EquationsPreflight:
      return "equations-preflight";
    case IOSGPUSceneCausalFailureReason::MissingAlphaTestDraw:
      return "missing-alpha-test-draw";
    case IOSGPUSceneCausalFailureReason::NoActiveRenderEncoder:
      return "no-active-render-encoder";
    case IOSGPUSceneCausalFailureReason::NativeException:
      return "native-exception";
    case IOSGPUSceneCausalFailureReason::NativeEncode:
      return "native-encode";
    }
  return nullptr;
  }
#endif

inline constexpr IOSGPUScenePipelineSelector iosGPUScenePipelineSelector(
    IOSMaterialCategory category) noexcept {
  switch(category) {
    case IOSMaterialCategory::Opaque:
      return IOSGPUScenePipelineSelector::Opaque;
    case IOSMaterialCategory::AlphaTest:
      return IOSGPUScenePipelineSelector::AlphaTest;
    case IOSMaterialCategory::Transparent:
    case IOSMaterialCategory::Additive:
    case IOSMaterialCategory::Water:
      return IOSGPUScenePipelineSelector::Unsupported;
    }
  return IOSGPUScenePipelineSelector::Unsupported;
  }

inline constexpr bool iosGPUScenePipelineSelectionMatches(
    IOSMaterialCategory category,
    IOSGPUScenePipelineSelector selected) noexcept {
  const IOSGPUScenePipelineSelector expected =
      iosGPUScenePipelineSelector(category);
  return expected!=IOSGPUScenePipelineSelector::Unsupported &&
      selected==expected;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
template<IOSGPUSceneMode Mode>
inline constexpr bool iosGPUSceneEffectivePipelineSelectorForCompileMode(
    IOSMaterialCategory category,
    IOSGPUScenePipelineSelector logical,
    IOSGPUScenePipelineSelector& effective) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  static_assert(Mode==IOSGPUSceneMode::CausalA);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  static_assert(Mode==IOSGPUSceneMode::CausalB);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  static_assert(
      Mode==IOSGPUSceneMode::Production ||
      Mode==IOSGPUSceneMode::CausalA ||
      Mode==IOSGPUSceneMode::CausalB);
#endif
  if(!iosGPUScenePipelineSelectionMatches(category,logical))
    return false;
  IOSGPUScenePipelineSelector selected = logical;
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  if constexpr(Mode==IOSGPUSceneMode::CausalB) {
    if(logical==IOSGPUScenePipelineSelector::AlphaTest)
      selected = IOSGPUScenePipelineSelector::Opaque;
    }
#endif
  effective = selected;
  return true;
  }

inline constexpr bool iosGPUSceneEffectivePipelineSelector(
    IOSMaterialCategory category,
    IOSGPUScenePipelineSelector logical,
    IOSGPUScenePipelineSelector& effective) noexcept {
  return iosGPUSceneEffectivePipelineSelectorForCompileMode<
      iosGPUSceneCompiledMode()>(category,logical,effective);
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
inline constexpr bool iosGPUSceneEffectivePipelineSelectorForMode(
    IOSGPUSceneMode mode,
    IOSMaterialCategory category,
    IOSGPUScenePipelineSelector logical,
    IOSGPUScenePipelineSelector& effective) noexcept {
  switch(mode) {
    case IOSGPUSceneMode::Production:
      return iosGPUSceneEffectivePipelineSelectorForCompileMode<
          IOSGPUSceneMode::Production>(category,logical,effective);
    case IOSGPUSceneMode::CausalA:
      return iosGPUSceneEffectivePipelineSelectorForCompileMode<
          IOSGPUSceneMode::CausalA>(category,logical,effective);
    case IOSGPUSceneMode::CausalB:
      return iosGPUSceneEffectivePipelineSelectorForCompileMode<
          IOSGPUSceneMode::CausalB>(category,logical,effective);
    }
  return false;
  }
#endif
#endif

inline constexpr bool iosGPUSceneRequiredShaderFunctionsAreAvailable(
    bool vertex,
    bool opaqueFragment,
    bool alphaTestFragment) noexcept {
  return vertex && opaqueFragment && alphaTestFragment;
  }

inline constexpr bool iosGPUSceneProductionPipelineStatesAreAvailable(
    bool opaque,
    bool alphaTest) noexcept {
  return opaque && alphaTest;
  }

struct IOSGPUSceneMaterialCounts final {
  uint64_t total = 0;
  uint64_t opaque = 0;
  uint64_t alphaTest = 0;

  constexpr bool operator==(const IOSGPUSceneMaterialCounts&) const noexcept =
      default;
  };

struct IOSGPUSceneKindCounts final {
  uint64_t total = 0;
  uint64_t landscape = 0;
  uint64_t staticMeshes = 0;
  uint64_t movable = 0;

  constexpr bool operator==(const IOSGPUSceneKindCounts&) const noexcept =
      default;
  };

struct IOSGPUSceneDrawCounts final {
  IOSGPUSceneMaterialCounts material;
  IOSGPUSceneKindCounts     kind;
  uint64_t                  texturedDraws = 0;
  uint64_t                  alphaFallback = 0;

  constexpr bool operator==(const IOSGPUSceneDrawCounts&) const noexcept =
      default;
  };

struct IOSGPUSceneFrameCounts final {
  IOSGPUSceneDrawCounts planned;
  IOSGPUSceneDrawCounts drawn;
  uint64_t              opaquePsoBinds = 0;
  uint64_t              alphaPsoBinds = 0;
  uint64_t              controlAlphaToOpaqueBinds = 0;

  constexpr bool operator==(const IOSGPUSceneFrameCounts&) const noexcept =
      default;
  };

struct IOSGPUSceneFailureCounts final {
  uint64_t unknownCategory = 0;
  uint64_t unknownKind = 0;
  uint64_t invalidCutoff = 0;
  uint64_t missingAlphaTexture = 0;
  uint64_t selectorMismatch = 0;
  uint64_t psoUnavailable = 0;
  uint64_t overflow = 0;
  uint64_t plannedDrawn = 0;
  uint64_t nativeEncode = 0;

  constexpr bool operator==(const IOSGPUSceneFailureCounts&) const noexcept =
      default;
  };

enum class IOSGPUSceneFrameAnimationRecordResult : uint8_t {
  IgnoredStatic,
  RecordedAnimated,
  InvalidEvidence,
  DuplicateAnimated,
  CountOverflow,
  };

struct IOSGPUSceneFrameAnimationDrawReport final {
  std::size_t drawnAnimated = 0;
  uint64_t    drawnDigest = IOSFrameAnimationFNV1aOffset;
  bool        valid = false;

  constexpr bool operator==(
      const IOSGPUSceneFrameAnimationDrawReport&) const noexcept = default;
  };

struct IOSGPUSceneFrameAnimationTracker final {
  const IOSFrameAnimationEvidence* evidence = nullptr;
  std::vector<uint64_t>             actuallyDrawnHandles;
  std::size_t                       drawnAnimated = 0;
  bool                              valid = false;
  };

inline bool prepareIOSGPUSceneFrameAnimationTracker(
    const IOSFrameAnimationEvidence& evidence,
    IOSWorldGeneration expectedGeneration,
    IOSGPUSceneFrameAnimationTracker& output) noexcept {
  if(!expectedGeneration ||
     !isCanonicalIOSFrameAnimationEvidence(evidence))
    return false;
  for(std::size_t lhs=0; lhs<evidence.selections.size(); ++lhs) {
    if(evidence.selections[lhs].selectedHandle.generation!=
       expectedGeneration)
      return false;
    for(std::size_t rhs=lhs+1u; rhs<evidence.selections.size(); ++rhs)
      if(evidence.selections[lhs].selectedHandle==
         evidence.selections[rhs].selectedHandle)
        return false;
    }

  try {
    IOSGPUSceneFrameAnimationTracker prepared;
    prepared.evidence = &evidence;
    prepared.actuallyDrawnHandles.assign(
        evidence.selections.size(),uint64_t(0u));
    prepared.valid = true;
    output = std::move(prepared);
    return true;
    }
  catch(...) {
    return false;
    }
  }

inline IOSGPUSceneFrameAnimationRecordResult
    recordIOSGPUSceneFrameAnimationDraw(
        IOSGPUSceneFrameAnimationTracker& tracker,
        IOSTextureHandle actuallyDrawnHandle) noexcept {
  if(!tracker.valid || tracker.evidence==nullptr ||
     tracker.actuallyDrawnHandles.size()!=
         tracker.evidence->selections.size() ||
     !actuallyDrawnHandle)
    return IOSGPUSceneFrameAnimationRecordResult::InvalidEvidence;

  const auto& selections = tracker.evidence->selections;
  std::size_t selected = selections.size();
  for(std::size_t index=0; index<selections.size(); ++index) {
    if(selections[index].selectedHandle!=actuallyDrawnHandle)
      continue;
    if(selected!=selections.size())
      return IOSGPUSceneFrameAnimationRecordResult::InvalidEvidence;
    selected = index;
    }
  if(selected==selections.size())
    return IOSGPUSceneFrameAnimationRecordResult::IgnoredStatic;
  if(tracker.actuallyDrawnHandles[selected]!=0u)
    return IOSGPUSceneFrameAnimationRecordResult::DuplicateAnimated;
  if(tracker.drawnAnimated==std::numeric_limits<std::size_t>::max())
    return IOSGPUSceneFrameAnimationRecordResult::CountOverflow;
  tracker.actuallyDrawnHandles[selected] = actuallyDrawnHandle.value;
  ++tracker.drawnAnimated;
  return IOSGPUSceneFrameAnimationRecordResult::RecordedAnimated;
  }

inline bool finalizeIOSGPUSceneFrameAnimationDrawReport(
    const IOSGPUSceneFrameAnimationTracker& tracker,
    IOSGPUSceneFrameAnimationDrawReport& output) noexcept {
  if(!tracker.valid || tracker.evidence==nullptr ||
     !isCanonicalIOSFrameAnimationEvidence(*tracker.evidence) ||
     tracker.actuallyDrawnHandles.size()!=
         tracker.evidence->selections.size() ||
     tracker.drawnAnimated!=tracker.evidence->admittedFrameOnly ||
     tracker.drawnAnimated!=tracker.actuallyDrawnHandles.size())
    return false;

  uint64_t digest = IOSFrameAnimationFNV1aOffset;
  for(std::size_t index=0;
      index<tracker.actuallyDrawnHandles.size();
      ++index) {
    if(tracker.actuallyDrawnHandles[index]==0u)
      return false;
    const auto& selection = tracker.evidence->selections[index];
    digest = iosFrameAnimationFNV1aAppendWord(digest,selection.sourceId);
    digest = iosFrameAnimationFNV1aAppendWord(
        digest,tracker.actuallyDrawnHandles[index]);
    }

  output.drawnAnimated = tracker.drawnAnimated;
  output.drawnDigest = digest;
  output.valid = true;
  return true;
  }

enum class IOSGPUSceneCountResult : uint8_t {
  Recorded,
  UnknownCategory,
  UnknownKind,
  InconsistentCounts,
  Overflow,
  };

inline constexpr bool iosGPUSceneCheckedIncrement(uint64_t& value) noexcept {
  if(value==std::numeric_limits<uint64_t>::max())
    return false;
  ++value;
  return true;
  }

inline constexpr bool iosGPUSceneCountsAreConsistent(
    const IOSGPUSceneDrawCounts& counts) noexcept {
  const bool materialSumValid =
      counts.material.opaque<=
        std::numeric_limits<uint64_t>::max()-counts.material.alphaTest;
  const bool firstKindSumValid =
      counts.kind.landscape<=
        std::numeric_limits<uint64_t>::max()-counts.kind.staticMeshes;
  const uint64_t firstKindSum =
      firstKindSumValid
        ? counts.kind.landscape+counts.kind.staticMeshes
        : 0u;
  const bool kindSumValid =
      firstKindSumValid &&
      firstKindSum<=std::numeric_limits<uint64_t>::max()-counts.kind.movable;
  return materialSumValid && kindSumValid &&
      counts.material.total==
        counts.material.opaque+counts.material.alphaTest &&
      counts.kind.total==firstKindSum+counts.kind.movable &&
      counts.material.total==counts.kind.total &&
      counts.texturedDraws<=counts.material.total &&
      counts.alphaFallback<=counts.material.alphaTest;
  }

inline constexpr bool iosGPUSceneFrameDrawCountsAreConsistent(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneCountsAreConsistent(counts.planned) &&
      iosGPUSceneCountsAreConsistent(counts.drawn) &&
      counts.planned.material==counts.drawn.material &&
      counts.planned.kind==counts.drawn.kind &&
      counts.planned.texturedDraws==0u &&
      counts.planned.alphaFallback==0u &&
      counts.drawn.texturedDraws==counts.drawn.material.total &&
      counts.drawn.alphaFallback==0u;
  }

inline constexpr bool iosGPUSceneProductionFrameCountsAreConsistent(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFrameDrawCountsAreConsistent(counts) &&
      counts.opaquePsoBinds==counts.drawn.material.opaque &&
      counts.alphaPsoBinds==counts.drawn.material.alphaTest &&
      counts.controlAlphaToOpaqueBinds==0u;
  }

inline constexpr bool iosGPUSceneCausalBFrameCountsAreConsistent(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFrameDrawCountsAreConsistent(counts) &&
      counts.opaquePsoBinds==counts.drawn.material.total &&
      counts.alphaPsoBinds==0u &&
      counts.controlAlphaToOpaqueBinds==counts.drawn.material.alphaTest;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
template<IOSGPUSceneMode Mode>
inline constexpr bool iosGPUSceneFrameCountsAreConsistentForCompileMode(
    const IOSGPUSceneFrameCounts& counts) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  static_assert(Mode==IOSGPUSceneMode::CausalA);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  static_assert(Mode==IOSGPUSceneMode::CausalB);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  static_assert(
      Mode==IOSGPUSceneMode::Production ||
      Mode==IOSGPUSceneMode::CausalA ||
      Mode==IOSGPUSceneMode::CausalB);
#endif
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  if constexpr(Mode==IOSGPUSceneMode::CausalB)
    return iosGPUSceneCausalBFrameCountsAreConsistent(counts);
#endif
  return iosGPUSceneProductionFrameCountsAreConsistent(counts);
  }

inline constexpr bool iosGPUSceneFrameCountsAreConsistentForMode(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFrameCountsAreConsistentForCompileMode<
      iosGPUSceneCompiledMode()>(counts);
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
inline constexpr bool iosGPUSceneFrameCountsAreConsistentForMode(
    IOSGPUSceneMode mode,
    const IOSGPUSceneFrameCounts& counts) noexcept {
  switch(mode) {
    case IOSGPUSceneMode::Production:
      return iosGPUSceneFrameCountsAreConsistentForCompileMode<
          IOSGPUSceneMode::Production>(counts);
    case IOSGPUSceneMode::CausalA:
      return iosGPUSceneFrameCountsAreConsistentForCompileMode<
          IOSGPUSceneMode::CausalA>(counts);
    case IOSGPUSceneMode::CausalB:
      return iosGPUSceneFrameCountsAreConsistentForCompileMode<
          IOSGPUSceneMode::CausalB>(counts);
    }
  return false;
  }
#endif
#endif

inline constexpr bool iosGPUSceneFailureCountsAreClear(
    const IOSGPUSceneFailureCounts& counts) noexcept {
  return counts==IOSGPUSceneFailureCounts{};
  }

inline constexpr bool iosGPUSceneProductionReportCountsAreConsistent(
    const IOSGPUSceneFrameCounts& frame,
    const IOSGPUSceneFailureCounts& failure) noexcept {
  return iosGPUSceneProductionFrameCountsAreConsistent(frame) &&
      iosGPUSceneFailureCountsAreClear(failure);
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
inline constexpr bool iosGPUSceneReportCountsAreConsistentForMode(
    const IOSGPUSceneFrameCounts& frame,
    const IOSGPUSceneFailureCounts& failure) noexcept {
  return iosGPUSceneFrameCountsAreConsistentForMode(frame) &&
      iosGPUSceneFailureCountsAreClear(failure);
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
inline constexpr bool iosGPUSceneReportCountsAreConsistentForMode(
    IOSGPUSceneMode mode,
    const IOSGPUSceneFrameCounts& frame,
    const IOSGPUSceneFailureCounts& failure) noexcept {
  return iosGPUSceneFrameCountsAreConsistentForMode(mode,frame) &&
      iosGPUSceneFailureCountsAreClear(failure);
  }
#endif
#endif

inline constexpr std::size_t IOSGPUSceneMarkerCapacity = 255u;

struct IOSGPUSceneMarker final {
  std::array<char,IOSGPUSceneMarkerCapacity> text = {};
  std::size_t                                length = 0;
  bool                                       valid = false;

  constexpr explicit operator bool() const noexcept {
    return valid;
    }
  };

template<class... Args>
inline IOSGPUSceneMarker iosGPUSceneFormatMarker(
    const char* format,
    Args... args) noexcept {
  IOSGPUSceneMarker marker;
  const int written = std::snprintf(
      marker.text.data(),marker.text.size(),format,args...);
  if(written<0 ||
     std::size_t(written)>=marker.text.size())
    return marker;
  marker.length = std::size_t(written);
  marker.valid  = true;
  return marker;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS) || \
    defined(OPENGOTHIC_RENDERER_IOS_FRAME_ANIMATION_HOST_TEST)
enum class IOSFrameAnimationDiagnosticPhase : uint8_t {
  Baseline,
  Transition,
  };

struct IOSFrameAnimationDiagnosticState final {
  uint64_t                  generation = 0;
  IOSFrameAnimationEvidence baseline;
  std::size_t               baselineDrawnAnimated = 0;
  uint64_t                  baselineDrawnDigest =
      IOSFrameAnimationFNV1aOffset;
  bool                      baselineCommitted = false;
  bool                      transitionCommitted = false;

  bool operator==(
      const IOSFrameAnimationDiagnosticState&) const = default;
  };

struct IOSFrameAnimationDiagnosticCandidate final {
  IOSFrameAnimationDiagnosticPhase phase =
      IOSFrameAnimationDiagnosticPhase::Baseline;
  uint64_t generation = 0;
  uint64_t sequence = 0;
  uint64_t changedSource = 0;
  uint64_t fromOrdinal = 0;
  uint64_t toOrdinal = 0;
  bool     valid = false;
  };

inline bool iosFrameAnimationEvidenceHasSameCohort(
    const IOSFrameAnimationEvidence& lhs,
    const IOSFrameAnimationEvidence& rhs) noexcept {
  if(!isCanonicalIOSFrameAnimationEvidence(lhs) ||
     !isCanonicalIOSFrameAnimationEvidence(rhs) ||
     lhs.sourceDigest!=rhs.sourceDigest ||
     lhs.selections.size()!=rhs.selections.size())
    return false;
  for(std::size_t index=0; index<lhs.selections.size(); ++index)
    if(lhs.selections[index].sourceId!=rhs.selections[index].sourceId)
      return false;
  return true;
  }

inline IOSFrameAnimationDiagnosticCandidate
    prepareIOSFrameAnimationDiagnosticCandidate(
        const IOSFrameAnimationDiagnosticState& state,
        uint64_t generation,
        uint64_t sequence,
        const IOSFrameAnimationEvidence& evidence) noexcept {
  IOSFrameAnimationDiagnosticCandidate candidate;
  if(generation==0u || sequence==0u ||
     !isCanonicalIOSFrameAnimationEvidence(evidence) ||
     evidence.selections.empty())
    return candidate;

  candidate.generation = generation;
  candidate.sequence = sequence;
  if(state.generation!=generation || !state.baselineCommitted) {
    candidate.phase = IOSFrameAnimationDiagnosticPhase::Baseline;
    candidate.valid = true;
    return candidate;
    }
  if(state.transitionCommitted || state.baseline.selections.empty() ||
     !iosFrameAnimationEvidenceHasSameCohort(
         state.baseline,evidence) ||
     state.baseline.pairDigest==evidence.pairDigest)
    return candidate;

  for(std::size_t index=0; index<evidence.selections.size(); ++index) {
    const auto& before = state.baseline.selections[index];
    const auto& after = evidence.selections[index];
    if(before.frameOrdinal==after.frameOrdinal)
      continue;
    candidate.phase = IOSFrameAnimationDiagnosticPhase::Transition;
    candidate.changedSource = after.sourceId;
    candidate.fromOrdinal = before.frameOrdinal;
    candidate.toOrdinal = after.frameOrdinal;
    candidate.valid = true;
    return candidate;
    }
  return {};
  }

inline bool iosFrameAnimationDiagnosticCandidateAcceptsDrawn(
    const IOSFrameAnimationDiagnosticState& state,
    const IOSFrameAnimationDiagnosticCandidate& candidate,
    const IOSFrameAnimationEvidence& evidence,
    const IOSGPUSceneFrameAnimationDrawReport& drawn) noexcept {
  if(!candidate.valid || !drawn.valid ||
     !isCanonicalIOSFrameAnimationEvidence(evidence) ||
     evidence.selections.empty() ||
     candidate.generation==0u || candidate.sequence==0u ||
     drawn.drawnAnimated!=evidence.admittedFrameOnly ||
     drawn.drawnAnimated!=evidence.selections.size())
    return false;
  if(candidate.phase==IOSFrameAnimationDiagnosticPhase::Baseline)
    return state.generation!=candidate.generation ||
           !state.baselineCommitted;
  return state.generation==candidate.generation &&
         state.baselineCommitted && !state.transitionCommitted &&
         iosFrameAnimationEvidenceHasSameCohort(
             state.baseline,evidence) &&
         candidate.changedSource!=0u &&
         candidate.fromOrdinal!=candidate.toOrdinal &&
         drawn.drawnDigest!=state.baselineDrawnDigest;
  }

inline bool commitIOSFrameAnimationDiagnosticState(
    bool submitAccepted,
    const IOSFrameAnimationDiagnosticCandidate& candidate,
    IOSFrameAnimationEvidence&& evidence,
    const IOSGPUSceneFrameAnimationDrawReport& drawn,
    IOSFrameAnimationDiagnosticState& state) noexcept {
  if(!submitAccepted ||
     !iosFrameAnimationDiagnosticCandidateAcceptsDrawn(
         state,candidate,evidence,drawn))
    return false;
  if(candidate.phase==IOSFrameAnimationDiagnosticPhase::Baseline) {
    state.generation = candidate.generation;
    state.baseline = std::move(evidence);
    state.baselineDrawnAnimated = drawn.drawnAnimated;
    state.baselineDrawnDigest = drawn.drawnDigest;
    state.baselineCommitted = true;
    state.transitionCommitted = false;
    }
  else {
    state.transitionCommitted = true;
    }
  return true;
  }

inline constexpr char iosFrameAnimationDiagnosticPhaseName(
    IOSFrameAnimationDiagnosticPhase phase) noexcept {
  return phase==IOSFrameAnimationDiagnosticPhase::Baseline ? 'B' : 'T';
  }

inline IOSGPUSceneMarker iosFrameAnimationFormatMarker(
    IOSFrameAnimationDiagnosticPhase phase,
    uint64_t generation,
    uint64_t sequence,
    std::size_t admitted,
    std::size_t nonzero,
    uint64_t sourceDigest,
    uint64_t pairDigest,
    const char* buildSha) noexcept {
  if(generation==0u || sequence==0u || admitted==0u ||
     nonzero>admitted || buildSha==nullptr || buildSha[0]=='\0')
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS frame animation: v=1 p=%c b=%s g=%llu s=%llu "
      "a=%llu n=%llu sd=%016llx pd=%016llx",
      iosFrameAnimationDiagnosticPhaseName(phase),buildSha,
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence),
      static_cast<unsigned long long>(admitted),
      static_cast<unsigned long long>(nonzero),
      static_cast<unsigned long long>(sourceDigest),
      static_cast<unsigned long long>(pairDigest));
  }

inline IOSGPUSceneMarker iosFrameAnimationFormatDetailMarker(
    IOSFrameAnimationDiagnosticPhase phase,
    uint64_t generation,
    uint64_t sequence,
    std::size_t drawnAnimated,
    uint64_t drawnDigest,
    uint64_t changedSource,
    uint64_t fromOrdinal,
    uint64_t toOrdinal) noexcept {
  if(generation==0u || sequence==0u || drawnAnimated==0u)
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS frame animation detail: v=1 p=%c g=%llu s=%llu "
      "d=%llu dd=%016llx c=%llu f=%llu t=%llu",
      iosFrameAnimationDiagnosticPhaseName(phase),
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence),
      static_cast<unsigned long long>(drawnAnimated),
      static_cast<unsigned long long>(drawnDigest),
      static_cast<unsigned long long>(changedSource),
      static_cast<unsigned long long>(fromOrdinal),
      static_cast<unsigned long long>(toOrdinal));
  }

inline IOSGPUSceneMarker iosFrameAnimationMarker(
    const IOSFrameAnimationDiagnosticCandidate& candidate,
    const IOSFrameAnimationEvidence& evidence,
    const char* buildSha) noexcept {
  if(!candidate.valid ||
     !isCanonicalIOSFrameAnimationEvidence(evidence) ||
     evidence.selections.empty())
    return {};
  return iosFrameAnimationFormatMarker(
      candidate.phase,candidate.generation,candidate.sequence,
      evidence.admittedFrameOnly,evidence.nonzeroFrameOrdinals,
      evidence.sourceDigest,evidence.pairDigest,buildSha);
  }

inline IOSGPUSceneMarker iosFrameAnimationDetailMarker(
    const IOSFrameAnimationDiagnosticCandidate& candidate,
    const IOSGPUSceneFrameAnimationDrawReport& drawn) noexcept {
  if(!candidate.valid || !drawn.valid)
    return {};
  return iosFrameAnimationFormatDetailMarker(
      candidate.phase,candidate.generation,candidate.sequence,
      drawn.drawnAnimated,drawn.drawnDigest,
      candidate.changedSource,candidate.fromOrdinal,candidate.toOrdinal);
  }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
inline IOSGPUSceneMarker iosGPUSceneCausalParseFailMarker(
    IOSGPUSceneMode mode,
    IOSGPUSceneCausalArgumentResult result) noexcept {
  const char* const modeName = iosGPUSceneModeName(mode);
  const char* const resultName =
      iosGPUSceneCausalArgumentResultName(result);
  if(modeName==nullptr || resultName==nullptr ||
     result==IOSGPUSceneCausalArgumentResult::Accepted)
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS native causal capture: FAIL mode=%s reason=parse-%s",
      modeName,resultName);
  }

inline IOSGPUSceneMarker iosGPUSceneCausalArmedMarker(
    const IOSGPUSceneCausalRuntimeState& state) noexcept {
  const char* const mode = iosGPUSceneModeName(state.arguments.mode);
  if(mode==nullptr ||
     !iosGPUSceneCausalNonceArrayIsValid(state.arguments.nonce) ||
     state.arguments.sequence==0u ||
     state.phase!=IOSGPUSceneCausalRuntimePhase::AwaitingTarget)
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS native causal capture: ARMED mode=%s nonce=%s "
      "target-sequence=%llu",
      mode,state.arguments.nonce.data(),
      static_cast<unsigned long long>(state.arguments.sequence));
  }

inline IOSGPUSceneMarker iosGPUSceneCausalEncodedMarker(
    const IOSGPUSceneCausalRuntimeState& state,
    uint64_t drawCount,
    uint64_t alphaTestDrawCount) noexcept {
  const char* const mode = iosGPUSceneModeName(state.arguments.mode);
  if(mode==nullptr ||
     !iosGPUSceneCausalNonceArrayIsValid(state.arguments.nonce) ||
     state.generation==0u ||
     state.lastSequence!=state.arguments.sequence ||
     state.phase!=IOSGPUSceneCausalRuntimePhase::TargetEncoded ||
     drawCount==0u || alphaTestDrawCount==0u ||
     alphaTestDrawCount>drawCount)
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS native causal capture: ENCODED mode=%s nonce=%s "
      "generation=%llu sequence=%llu draws=%llu alpha=%llu",
      mode,state.arguments.nonce.data(),
      static_cast<unsigned long long>(state.generation),
      static_cast<unsigned long long>(state.lastSequence),
      static_cast<unsigned long long>(drawCount),
      static_cast<unsigned long long>(alphaTestDrawCount));
  }

inline IOSGPUSceneMarker iosGPUSceneCausalFailMarker(
    const IOSGPUSceneCausalRuntimeState& state,
    uint64_t generation,
    uint64_t sequence,
    IOSGPUSceneCausalFailureReason reason) noexcept {
  const char* const mode = iosGPUSceneModeName(state.arguments.mode);
  const char* const reasonName =
      iosGPUSceneCausalFailureReasonName(reason);
  if(mode==nullptr || reasonName==nullptr ||
     !iosGPUSceneCausalNonceArrayIsValid(state.arguments.nonce) ||
     state.arguments.sequence==0u ||
     state.phase!=IOSGPUSceneCausalRuntimePhase::Failed)
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS native causal capture: FAIL mode=%s nonce=%s "
      "generation=%llu sequence=%llu reason=%s",
      mode,state.arguments.nonce.data(),
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence),reasonName);
  }
#endif

inline constexpr const char* iosGPUSceneMarkerModeName() noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  return "causal-a";
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  return "causal-b";
#else
  return "production";
#endif
  }

inline IOSGPUSceneMarker iosGPUSceneIdentityMarker(
    uint64_t generation,
    uint64_t sequence) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene identity: mode=%s "
      "generation=%llu sequence=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence));
  }

inline IOSGPUSceneMarker iosGPUSceneMaterialPlannedMarker(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene material-planned: mode=%s "
      "total=%llu opaque=%llu alpha=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(counts.planned.material.total),
      static_cast<unsigned long long>(counts.planned.material.opaque),
      static_cast<unsigned long long>(counts.planned.material.alphaTest));
  }

inline IOSGPUSceneMarker iosGPUSceneMaterialDrawnMarker(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene material-drawn: mode=%s "
      "total=%llu opaque=%llu alpha=%llu textured=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(counts.drawn.material.total),
      static_cast<unsigned long long>(counts.drawn.material.opaque),
      static_cast<unsigned long long>(counts.drawn.material.alphaTest),
      static_cast<unsigned long long>(counts.drawn.texturedDraws));
  }

inline IOSGPUSceneMarker iosGPUSceneKindPlannedMarker(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene kind-planned: mode=%s "
      "total=%llu landscape=%llu static=%llu movable=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(counts.planned.kind.total),
      static_cast<unsigned long long>(counts.planned.kind.landscape),
      static_cast<unsigned long long>(counts.planned.kind.staticMeshes),
      static_cast<unsigned long long>(counts.planned.kind.movable));
  }

inline IOSGPUSceneMarker iosGPUSceneKindDrawnMarker(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene kind-drawn: mode=%s "
      "total=%llu landscape=%llu static=%llu movable=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(counts.drawn.kind.total),
      static_cast<unsigned long long>(counts.drawn.kind.landscape),
      static_cast<unsigned long long>(counts.drawn.kind.staticMeshes),
      static_cast<unsigned long long>(counts.drawn.kind.movable));
  }

inline IOSGPUSceneMarker iosGPUSceneAlphaMarker(
    const IOSGPUSceneFrameCounts& counts) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene alpha: mode=%s "
      "opaque-pso=%llu alpha-pso=%llu control-alpha-to-opaque=%llu "
      "alpha-fallback=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(counts.opaquePsoBinds),
      static_cast<unsigned long long>(counts.alphaPsoBinds),
      static_cast<unsigned long long>(
          counts.controlAlphaToOpaqueBinds),
      static_cast<unsigned long long>(counts.drawn.alphaFallback));
  }

inline IOSGPUSceneMarker iosGPUSceneFailContractMarker(
    const IOSGPUSceneFailureCounts& failure) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene fail-contract: mode=%s "
      "unknown-category=%llu unknown-kind=%llu invalid-cutoff=%llu "
      "missing-alpha-texture=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(failure.unknownCategory),
      static_cast<unsigned long long>(failure.unknownKind),
      static_cast<unsigned long long>(failure.invalidCutoff),
      static_cast<unsigned long long>(failure.missingAlphaTexture));
  }

inline IOSGPUSceneMarker iosGPUSceneFailSelectorMarker(
    const IOSGPUSceneFailureCounts& failure) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene fail-selector: mode=%s "
      "selector-mismatch=%llu pso-unavailable=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(failure.selectorMismatch),
      static_cast<unsigned long long>(failure.psoUnavailable));
  }

inline IOSGPUSceneMarker iosGPUSceneFailExecutionMarker(
    const IOSGPUSceneFailureCounts& failure) noexcept {
  return iosGPUSceneFormatMarker(
      "RendererIOS native scene fail-execution: mode=%s "
      "overflow=%llu planned-drawn=%llu native-encode=%llu",
      iosGPUSceneMarkerModeName(),
      static_cast<unsigned long long>(failure.overflow),
      static_cast<unsigned long long>(failure.plannedDrawn),
      static_cast<unsigned long long>(failure.nativeEncode));
  }

inline constexpr IOSGPUSceneCountResult recordIOSGPUSceneDrawCount(
    IOSMaterialCategory category,
    IOSSceneMeshKind kind,
    bool usesFallbackTexture,
    bool textured,
    IOSGPUSceneDrawCounts& counts) noexcept {
  const IOSGPUScenePipelineSelector selector =
      iosGPUScenePipelineSelector(category);
  if(selector==IOSGPUScenePipelineSelector::Unsupported)
    return IOSGPUSceneCountResult::UnknownCategory;
  switch(kind) {
    case IOSSceneMeshKind::Landscape:
    case IOSSceneMeshKind::Static:
    case IOSSceneMeshKind::Movable:
      break;
    case IOSSceneMeshKind::Unsupported:
      return IOSGPUSceneCountResult::UnknownKind;
    }
  if(kind!=IOSSceneMeshKind::Landscape &&
     kind!=IOSSceneMeshKind::Static &&
     kind!=IOSSceneMeshKind::Movable)
    return IOSGPUSceneCountResult::UnknownKind;
  if(!iosGPUSceneCountsAreConsistent(counts))
    return IOSGPUSceneCountResult::InconsistentCounts;

  IOSGPUSceneDrawCounts next = counts;
  if(!iosGPUSceneCheckedIncrement(next.material.total) ||
     !iosGPUSceneCheckedIncrement(next.kind.total))
    return IOSGPUSceneCountResult::Overflow;
  if(selector==IOSGPUScenePipelineSelector::Opaque) {
    if(!iosGPUSceneCheckedIncrement(next.material.opaque))
      return IOSGPUSceneCountResult::Overflow;
    }
  else if(!iosGPUSceneCheckedIncrement(next.material.alphaTest)) {
    return IOSGPUSceneCountResult::Overflow;
    }
  switch(kind) {
    case IOSSceneMeshKind::Landscape:
      if(!iosGPUSceneCheckedIncrement(next.kind.landscape))
        return IOSGPUSceneCountResult::Overflow;
      break;
    case IOSSceneMeshKind::Static:
      if(!iosGPUSceneCheckedIncrement(next.kind.staticMeshes))
        return IOSGPUSceneCountResult::Overflow;
      break;
    case IOSSceneMeshKind::Movable:
      if(!iosGPUSceneCheckedIncrement(next.kind.movable))
        return IOSGPUSceneCountResult::Overflow;
      break;
    case IOSSceneMeshKind::Unsupported:
      return IOSGPUSceneCountResult::UnknownKind;
    }
  if(textured && !iosGPUSceneCheckedIncrement(next.texturedDraws))
    return IOSGPUSceneCountResult::Overflow;
  if(selector==IOSGPUScenePipelineSelector::AlphaTest &&
     usesFallbackTexture &&
     !iosGPUSceneCheckedIncrement(next.alphaFallback))
    return IOSGPUSceneCountResult::Overflow;
  if(!iosGPUSceneCountsAreConsistent(next))
    return IOSGPUSceneCountResult::InconsistentCounts;
  counts = next;
  return IOSGPUSceneCountResult::Recorded;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
enum class IOSGPUSceneDrawDispatchResult : uint8_t {
  Recorded,
  InvalidMode,
  SelectorMismatch,
  UnknownCategory,
  UnknownKind,
  InconsistentCounts,
  Overflow,
  };

struct IOSGPUSceneDrawDispatch final {
  IOSGPUScenePipelineSelector logical =
      IOSGPUScenePipelineSelector::Unsupported;
  IOSGPUScenePipelineSelector effective =
      IOSGPUScenePipelineSelector::Unsupported;

  constexpr bool operator==(
      const IOSGPUSceneDrawDispatch&) const noexcept = default;
  };

template<IOSGPUSceneMode Mode>
inline constexpr bool iosGPUScenePipelineBindCountsMatchDrawnForCompileMode(
    const IOSGPUSceneFrameCounts& counts) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  if constexpr(Mode==IOSGPUSceneMode::CausalB) {
    return counts.opaquePsoBinds==counts.drawn.material.total &&
        counts.alphaPsoBinds==0u &&
        counts.controlAlphaToOpaqueBinds==
            counts.drawn.material.alphaTest;
    }
#endif
  return counts.opaquePsoBinds==counts.drawn.material.opaque &&
      counts.alphaPsoBinds==counts.drawn.material.alphaTest &&
      counts.controlAlphaToOpaqueBinds==0u;
  }

template<IOSGPUSceneMode Mode>
inline constexpr IOSGPUSceneDrawDispatchResult
    recordIOSGPUSceneDrawDispatchForCompileMode(
        IOSMaterialCategory category,
        IOSSceneMeshKind kind,
        bool usesFallbackTexture,
        bool textured,
        IOSGPUScenePipelineSelector logical,
        IOSGPUSceneFrameCounts& counts,
        IOSGPUSceneDrawDispatch& dispatch) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  static_assert(Mode==IOSGPUSceneMode::CausalA);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  static_assert(Mode==IOSGPUSceneMode::CausalB);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  static_assert(
      Mode==IOSGPUSceneMode::Production ||
      Mode==IOSGPUSceneMode::CausalA ||
      Mode==IOSGPUSceneMode::CausalB);
#endif
  IOSGPUScenePipelineSelector effective =
      IOSGPUScenePipelineSelector::Unsupported;
  if(!iosGPUSceneEffectivePipelineSelectorForCompileMode<Mode>(
         category,logical,effective))
    return IOSGPUSceneDrawDispatchResult::SelectorMismatch;
  if(!iosGPUSceneCountsAreConsistent(counts.drawn) ||
     !iosGPUScenePipelineBindCountsMatchDrawnForCompileMode<Mode>(counts))
    return IOSGPUSceneDrawDispatchResult::InconsistentCounts;

  IOSGPUSceneFrameCounts next = counts;
  const IOSGPUSceneCountResult countResult =
      recordIOSGPUSceneDrawCount(
          category,kind,usesFallbackTexture,textured,next.drawn);
  switch(countResult) {
    case IOSGPUSceneCountResult::Recorded:
      break;
    case IOSGPUSceneCountResult::UnknownCategory:
      return IOSGPUSceneDrawDispatchResult::UnknownCategory;
    case IOSGPUSceneCountResult::UnknownKind:
      return IOSGPUSceneDrawDispatchResult::UnknownKind;
    case IOSGPUSceneCountResult::InconsistentCounts:
      return IOSGPUSceneDrawDispatchResult::InconsistentCounts;
    case IOSGPUSceneCountResult::Overflow:
      return IOSGPUSceneDrawDispatchResult::Overflow;
    }

  if(effective==IOSGPUScenePipelineSelector::Opaque) {
    if(!iosGPUSceneCheckedIncrement(next.opaquePsoBinds))
      return IOSGPUSceneDrawDispatchResult::Overflow;
    }
  else if(effective==IOSGPUScenePipelineSelector::AlphaTest) {
    if(!iosGPUSceneCheckedIncrement(next.alphaPsoBinds))
      return IOSGPUSceneDrawDispatchResult::Overflow;
    }
  else {
    return IOSGPUSceneDrawDispatchResult::SelectorMismatch;
    }
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
  if constexpr(Mode==IOSGPUSceneMode::CausalB) {
    if(logical==IOSGPUScenePipelineSelector::AlphaTest &&
       !iosGPUSceneCheckedIncrement(
           next.controlAlphaToOpaqueBinds))
      return IOSGPUSceneDrawDispatchResult::Overflow;
    }
#endif
  if(!iosGPUScenePipelineBindCountsMatchDrawnForCompileMode<Mode>(next))
    return IOSGPUSceneDrawDispatchResult::InconsistentCounts;

  IOSGPUSceneDrawDispatch nextDispatch;
  nextDispatch.logical = logical;
  nextDispatch.effective = effective;
  counts = next;
  dispatch = nextDispatch;
  return IOSGPUSceneDrawDispatchResult::Recorded;
  }

inline constexpr IOSGPUSceneDrawDispatchResult
    recordIOSGPUSceneProductionDrawDispatch(
        IOSMaterialCategory category,
        IOSSceneMeshKind kind,
        bool usesFallbackTexture,
        bool textured,
        IOSGPUScenePipelineSelector logical,
        IOSGPUSceneFrameCounts& counts,
        IOSGPUSceneDrawDispatch& dispatch) noexcept {
  if(!iosGPUScenePipelineSelectionMatches(category,logical))
    return IOSGPUSceneDrawDispatchResult::SelectorMismatch;
  if(!iosGPUSceneCountsAreConsistent(counts.drawn) ||
     counts.opaquePsoBinds!=counts.drawn.material.opaque ||
     counts.alphaPsoBinds!=counts.drawn.material.alphaTest ||
     counts.controlAlphaToOpaqueBinds!=0u)
    return IOSGPUSceneDrawDispatchResult::InconsistentCounts;

  IOSGPUSceneFrameCounts next = counts;
  const IOSGPUSceneCountResult countResult =
      recordIOSGPUSceneDrawCount(
          category,kind,usesFallbackTexture,textured,next.drawn);
  switch(countResult) {
    case IOSGPUSceneCountResult::Recorded:
      break;
    case IOSGPUSceneCountResult::UnknownCategory:
      return IOSGPUSceneDrawDispatchResult::UnknownCategory;
    case IOSGPUSceneCountResult::UnknownKind:
      return IOSGPUSceneDrawDispatchResult::UnknownKind;
    case IOSGPUSceneCountResult::InconsistentCounts:
      return IOSGPUSceneDrawDispatchResult::InconsistentCounts;
    case IOSGPUSceneCountResult::Overflow:
      return IOSGPUSceneDrawDispatchResult::Overflow;
    }
  if(logical==IOSGPUScenePipelineSelector::Opaque) {
    if(!iosGPUSceneCheckedIncrement(next.opaquePsoBinds))
      return IOSGPUSceneDrawDispatchResult::Overflow;
    }
  else if(logical==IOSGPUScenePipelineSelector::AlphaTest) {
    if(!iosGPUSceneCheckedIncrement(next.alphaPsoBinds))
      return IOSGPUSceneDrawDispatchResult::Overflow;
    }
  else {
    return IOSGPUSceneDrawDispatchResult::SelectorMismatch;
    }
  if(next.opaquePsoBinds!=next.drawn.material.opaque ||
     next.alphaPsoBinds!=next.drawn.material.alphaTest ||
     next.controlAlphaToOpaqueBinds!=0u)
    return IOSGPUSceneDrawDispatchResult::InconsistentCounts;

  IOSGPUSceneDrawDispatch nextDispatch;
  nextDispatch.logical = logical;
  nextDispatch.effective = logical;
  counts = next;
  dispatch = nextDispatch;
  return IOSGPUSceneDrawDispatchResult::Recorded;
  }

template<IOSGPUSceneMode Mode>
inline constexpr IOSGPUSceneDrawDispatchResult
    recordIOSGPUSceneDrawDispatchForRouteForCompileMode(
        IOSGPUSceneCausalFrameRoute route,
        IOSMaterialCategory category,
        IOSSceneMeshKind kind,
        bool usesFallbackTexture,
        bool textured,
        IOSGPUScenePipelineSelector logical,
        IOSGPUSceneFrameCounts& counts,
        IOSGPUSceneDrawDispatch& dispatch) noexcept {
  switch(route) {
    case IOSGPUSceneCausalFrameRoute::Production:
      return recordIOSGPUSceneProductionDrawDispatch(
          category,kind,usesFallbackTexture,textured,
          logical,counts,dispatch);
    case IOSGPUSceneCausalFrameRoute::Target:
      return recordIOSGPUSceneDrawDispatchForCompileMode<Mode>(
          category,kind,usesFallbackTexture,textured,
          logical,counts,dispatch);
    }
  return IOSGPUSceneDrawDispatchResult::InvalidMode;
  }

inline constexpr IOSGPUSceneDrawDispatchResult
    recordIOSGPUSceneDrawDispatch(
        IOSMaterialCategory category,
        IOSSceneMeshKind kind,
        bool usesFallbackTexture,
        bool textured,
        IOSGPUScenePipelineSelector logical,
        IOSGPUSceneFrameCounts& counts,
        IOSGPUSceneDrawDispatch& dispatch) noexcept {
  return recordIOSGPUSceneDrawDispatchForCompileMode<
      iosGPUSceneCompiledMode()>(
          category,kind,usesFallbackTexture,textured,
          logical,counts,dispatch);
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
inline constexpr IOSGPUSceneDrawDispatchResult
    recordIOSGPUSceneDrawDispatchForRoute(
        IOSGPUSceneCausalFrameRoute route,
        IOSMaterialCategory category,
        IOSSceneMeshKind kind,
        bool usesFallbackTexture,
        bool textured,
        IOSGPUScenePipelineSelector logical,
        IOSGPUSceneFrameCounts& counts,
        IOSGPUSceneDrawDispatch& dispatch) noexcept {
  return recordIOSGPUSceneDrawDispatchForRouteForCompileMode<
      iosGPUSceneCompiledMode()>(
          route,category,kind,usesFallbackTexture,textured,
          logical,counts,dispatch);
  }
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
inline constexpr IOSGPUSceneDrawDispatchResult
    recordIOSGPUSceneDrawDispatchForMode(
        IOSGPUSceneMode mode,
        IOSMaterialCategory category,
        IOSSceneMeshKind kind,
        bool usesFallbackTexture,
        bool textured,
        IOSGPUScenePipelineSelector logical,
        IOSGPUSceneFrameCounts& counts,
        IOSGPUSceneDrawDispatch& dispatch) noexcept {
  switch(mode) {
    case IOSGPUSceneMode::Production:
      return recordIOSGPUSceneDrawDispatchForCompileMode<
          IOSGPUSceneMode::Production>(
              category,kind,usesFallbackTexture,textured,
              logical,counts,dispatch);
    case IOSGPUSceneMode::CausalA:
      return recordIOSGPUSceneDrawDispatchForCompileMode<
          IOSGPUSceneMode::CausalA>(
              category,kind,usesFallbackTexture,textured,
              logical,counts,dispatch);
    case IOSGPUSceneMode::CausalB:
      return recordIOSGPUSceneDrawDispatchForCompileMode<
          IOSGPUSceneMode::CausalB>(
              category,kind,usesFallbackTexture,textured,
              logical,counts,dispatch);
    }
  return IOSGPUSceneDrawDispatchResult::InvalidMode;
  }

inline constexpr IOSGPUSceneDrawDispatchResult
    recordIOSGPUSceneDrawDispatchForRouteForMode(
        IOSGPUSceneMode mode,
        IOSGPUSceneCausalFrameRoute route,
        IOSMaterialCategory category,
        IOSSceneMeshKind kind,
        bool usesFallbackTexture,
        bool textured,
        IOSGPUScenePipelineSelector logical,
        IOSGPUSceneFrameCounts& counts,
        IOSGPUSceneDrawDispatch& dispatch) noexcept {
  switch(mode) {
    case IOSGPUSceneMode::CausalA:
      return recordIOSGPUSceneDrawDispatchForRouteForCompileMode<
          IOSGPUSceneMode::CausalA>(
              route,category,kind,usesFallbackTexture,textured,
              logical,counts,dispatch);
    case IOSGPUSceneMode::CausalB:
      return recordIOSGPUSceneDrawDispatchForRouteForCompileMode<
          IOSGPUSceneMode::CausalB>(
              route,category,kind,usesFallbackTexture,textured,
              logical,counts,dispatch);
    case IOSGPUSceneMode::Production:
      if(route==IOSGPUSceneCausalFrameRoute::Production)
        return recordIOSGPUSceneProductionDrawDispatch(
            category,kind,usesFallbackTexture,textured,
            logical,counts,dispatch);
      break;
    }
  return IOSGPUSceneDrawDispatchResult::InvalidMode;
  }
#endif
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
enum class IOSGPUSceneCausalDrawIdentityResult : uint8_t {
  Created,
  InvalidMode,
  InvalidNonce,
  InvalidGeneration,
  InvalidSequence,
  InvalidOrdinal,
  InvalidDispatch,
  InvalidKind,
  InvalidTexture,
  InvalidMesh,
  InvalidIndexCount,
  };

inline constexpr bool iosGPUSceneTakeNextCausalDrawOrdinal(
    uint64_t& counter,
    uint64_t& ordinal) noexcept {
  uint64_t next = counter;
  if(!iosGPUSceneCheckedIncrement(next))
    return false;
  counter = next;
  ordinal = next;
  return true;
  }

struct IOSGPUSceneCausalDrawIdentity final {
  IOSGPUSceneMode mode = IOSGPUSceneMode::Production;
  std::array<char,IOSGPUSceneCausalNonceLength+1u> nonce = {};
  uint64_t generation = 0;
  uint64_t sequence = 0;
  uint64_t ordinal = 0;
  IOSGPUScenePipelineSelector logical =
      IOSGPUScenePipelineSelector::Unsupported;
  IOSGPUScenePipelineSelector effective =
      IOSGPUScenePipelineSelector::Unsupported;
  IOSSceneMeshKind kind = IOSSceneMeshKind::Unsupported;
  uint64_t texture = 0;
  uint64_t mesh = 0;
  uint64_t indices = 0;

  constexpr bool operator==(
      const IOSGPUSceneCausalDrawIdentity&) const noexcept = default;
  };

inline constexpr const char* iosGPUScenePipelineSelectorName(
    IOSGPUScenePipelineSelector selector) noexcept {
  switch(selector) {
    case IOSGPUScenePipelineSelector::Opaque:
      return "opaque";
    case IOSGPUScenePipelineSelector::AlphaTest:
      return "alpha-test";
    case IOSGPUScenePipelineSelector::Unsupported:
      break;
    }
  return nullptr;
  }

inline constexpr const char* iosGPUSceneMeshKindName(
    IOSSceneMeshKind kind) noexcept {
  switch(kind) {
    case IOSSceneMeshKind::Landscape:
      return "landscape";
    case IOSSceneMeshKind::Static:
      return "static";
    case IOSSceneMeshKind::Movable:
      return "movable";
    case IOSSceneMeshKind::Unsupported:
      break;
    }
  return nullptr;
  }

template<IOSGPUSceneMode Mode>
inline constexpr IOSGPUSceneCausalDrawIdentityResult
    makeIOSGPUSceneCausalDrawIdentityForCompileMode(
        std::string_view nonce,
        uint64_t generation,
        uint64_t sequence,
        uint64_t ordinal,
        const IOSGPUSceneDrawDispatch& dispatch,
        IOSSceneMeshKind kind,
        uint64_t texture,
        uint64_t mesh,
        uint64_t indices,
        IOSGPUSceneCausalDrawIdentity& output) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  static_assert(Mode==IOSGPUSceneMode::CausalA);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  static_assert(Mode==IOSGPUSceneMode::CausalB);
#else
  static_assert(
      Mode==IOSGPUSceneMode::CausalA ||
      Mode==IOSGPUSceneMode::CausalB);
#endif
  if(iosGPUSceneModeName(Mode)==nullptr)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidMode;
  if(!iosGPUSceneCausalNonceIsValid(nonce))
    return IOSGPUSceneCausalDrawIdentityResult::InvalidNonce;
  if(generation==0u)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidGeneration;
  if(sequence==0u)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidSequence;
  if(ordinal==0u)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidOrdinal;
  IOSGPUScenePipelineSelector expected =
      IOSGPUScenePipelineSelector::Unsupported;
  const IOSMaterialCategory category =
      dispatch.logical==IOSGPUScenePipelineSelector::Opaque
        ? IOSMaterialCategory::Opaque
        : IOSMaterialCategory::AlphaTest;
  if(dispatch.logical==IOSGPUScenePipelineSelector::Unsupported ||
     !iosGPUSceneEffectivePipelineSelectorForCompileMode<Mode>(
         category,dispatch.logical,expected) ||
     dispatch.effective!=expected)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidDispatch;
  if(iosGPUSceneMeshKindName(kind)==nullptr)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidKind;
  if(texture==0u)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidTexture;
  if(mesh==0u)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidMesh;
  if(indices==0u)
    return IOSGPUSceneCausalDrawIdentityResult::InvalidIndexCount;

  IOSGPUSceneCausalDrawIdentity identity;
  identity.mode = Mode;
  for(std::size_t index=0u; index<nonce.size(); ++index)
    identity.nonce[index] = nonce[index];
  identity.generation = generation;
  identity.sequence = sequence;
  identity.ordinal = ordinal;
  identity.logical = dispatch.logical;
  identity.effective = dispatch.effective;
  identity.kind = kind;
  identity.texture = texture;
  identity.mesh = mesh;
  identity.indices = indices;
  output = identity;
  return IOSGPUSceneCausalDrawIdentityResult::Created;
  }

inline constexpr IOSGPUSceneCausalDrawIdentityResult
    makeIOSGPUSceneCausalDrawIdentity(
        std::string_view nonce,
        uint64_t generation,
        uint64_t sequence,
        uint64_t ordinal,
        const IOSGPUSceneDrawDispatch& dispatch,
        IOSSceneMeshKind kind,
        uint64_t texture,
        uint64_t mesh,
        uint64_t indices,
        IOSGPUSceneCausalDrawIdentity& output) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  return makeIOSGPUSceneCausalDrawIdentityForCompileMode<
      IOSGPUSceneMode::CausalA>(
          nonce,generation,sequence,ordinal,dispatch,
          kind,texture,mesh,indices,output);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  return makeIOSGPUSceneCausalDrawIdentityForCompileMode<
      IOSGPUSceneMode::CausalB>(
          nonce,generation,sequence,ordinal,dispatch,
          kind,texture,mesh,indices,output);
#else
  (void)nonce;
  (void)generation;
  (void)sequence;
  (void)ordinal;
  (void)dispatch;
  (void)kind;
  (void)texture;
  (void)mesh;
  (void)indices;
  (void)output;
  return IOSGPUSceneCausalDrawIdentityResult::InvalidMode;
#endif
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST)
inline constexpr IOSGPUSceneCausalDrawIdentityResult
    makeIOSGPUSceneCausalDrawIdentityForMode(
        IOSGPUSceneMode mode,
        std::string_view nonce,
        uint64_t generation,
        uint64_t sequence,
        uint64_t ordinal,
        const IOSGPUSceneDrawDispatch& dispatch,
        IOSSceneMeshKind kind,
        uint64_t texture,
        uint64_t mesh,
        uint64_t indices,
        IOSGPUSceneCausalDrawIdentity& output) noexcept {
  switch(mode) {
    case IOSGPUSceneMode::CausalA:
      return makeIOSGPUSceneCausalDrawIdentityForCompileMode<
          IOSGPUSceneMode::CausalA>(
              nonce,generation,sequence,ordinal,dispatch,
              kind,texture,mesh,indices,output);
    case IOSGPUSceneMode::CausalB:
      return makeIOSGPUSceneCausalDrawIdentityForCompileMode<
          IOSGPUSceneMode::CausalB>(
              nonce,generation,sequence,ordinal,dispatch,
              kind,texture,mesh,indices,output);
    case IOSGPUSceneMode::Production:
      break;
    }
  return IOSGPUSceneCausalDrawIdentityResult::InvalidMode;
  }
#endif

template<IOSGPUSceneMode Mode>
inline constexpr bool iosGPUSceneCausalDrawIdentityIsValidForCompileMode(
    const IOSGPUSceneCausalDrawIdentity& identity) noexcept {
  if(identity.mode!=Mode ||
     !iosGPUSceneCausalNonceArrayIsValid(identity.nonce) ||
     identity.generation==0u || identity.sequence==0u ||
     identity.ordinal==0u ||
     iosGPUSceneMeshKindName(identity.kind)==nullptr ||
     identity.texture==0u || identity.mesh==0u ||
     identity.indices==0u)
    return false;
  IOSGPUScenePipelineSelector expected =
      IOSGPUScenePipelineSelector::Unsupported;
  const IOSMaterialCategory category =
      identity.logical==IOSGPUScenePipelineSelector::Opaque
        ? IOSMaterialCategory::Opaque
        : IOSMaterialCategory::AlphaTest;
  return identity.logical!=IOSGPUScenePipelineSelector::Unsupported &&
      iosGPUSceneEffectivePipelineSelectorForCompileMode<Mode>(
          category,identity.logical,expected) &&
      identity.effective==expected;
  }

inline constexpr bool iosGPUSceneCausalDrawIdentityIsValid(
    const IOSGPUSceneCausalDrawIdentity& identity) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  return iosGPUSceneCausalDrawIdentityIsValidForCompileMode<
      IOSGPUSceneMode::CausalA>(identity);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  return iosGPUSceneCausalDrawIdentityIsValidForCompileMode<
      IOSGPUSceneMode::CausalB>(identity);
#else
  switch(identity.mode) {
    case IOSGPUSceneMode::CausalA:
      return iosGPUSceneCausalDrawIdentityIsValidForCompileMode<
          IOSGPUSceneMode::CausalA>(identity);
    case IOSGPUSceneMode::CausalB:
      return iosGPUSceneCausalDrawIdentityIsValidForCompileMode<
          IOSGPUSceneMode::CausalB>(identity);
    case IOSGPUSceneMode::Production:
      break;
    }
  return false;
#endif
  }

inline IOSGPUSceneMarker iosGPUSceneCausalDrawIdSignpost(
    const IOSGPUSceneCausalDrawIdentity& identity) noexcept {
  const char* const modeName = iosGPUSceneModeName(identity.mode);
  if(modeName==nullptr ||
     !iosGPUSceneCausalDrawIdentityIsValid(identity))
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS native causal draw-id: mode=%s nonce=%s "
      "generation=%llu sequence=%llu ordinal=%llu",
      modeName,identity.nonce.data(),
      static_cast<unsigned long long>(identity.generation),
      static_cast<unsigned long long>(identity.sequence),
      static_cast<unsigned long long>(identity.ordinal));
  }

inline IOSGPUSceneMarker iosGPUSceneCausalDrawBindSignpost(
    const IOSGPUSceneCausalDrawIdentity& identity) noexcept {
  const char* const logical =
      iosGPUScenePipelineSelectorName(identity.logical);
  const char* const effective =
      iosGPUScenePipelineSelectorName(identity.effective);
  const char* const kind = iosGPUSceneMeshKindName(identity.kind);
  if(logical==nullptr || effective==nullptr || kind==nullptr ||
     !iosGPUSceneCausalDrawIdentityIsValid(identity))
    return {};
  return iosGPUSceneFormatMarker(
      "RendererIOS native causal draw-bind: ordinal=%llu "
      "logical=%s effective=%s kind=%s slot=0 "
      "texture=%llu mesh=%llu indices=%llu",
      static_cast<unsigned long long>(identity.ordinal),
      logical,effective,kind,
      static_cast<unsigned long long>(identity.texture),
      static_cast<unsigned long long>(identity.mesh),
      static_cast<unsigned long long>(identity.indices));
  }

template<IOSGPUSceneMode Mode>
inline constexpr bool
    iosGPUSceneCausalPreparationIsValidForCompileMode(
        const IOSGPUSceneCausalRuntimeState& prepared,
        IOSGPUSceneCausalFrameRoute route,
        const IOSGPUSceneFrameCounts& counts,
        uint64_t recordCount,
        uint64_t ordinal,
        bool identitiesValid,
        bool markersValid,
        bool reportIsClear) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)
  static_assert(Mode==IOSGPUSceneMode::CausalA);
#elif defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
  static_assert(Mode==IOSGPUSceneMode::CausalB);
#else
  static_assert(
      Mode==IOSGPUSceneMode::CausalA ||
      Mode==IOSGPUSceneMode::CausalB);
#endif
  if(prepared.arguments.mode!=Mode ||
     !iosGPUSceneCausalNonceArrayIsValid(prepared.arguments.nonce) ||
     prepared.arguments.sequence==0u ||
     prepared.generation==0u ||
     counts.planned.material.total!=recordCount ||
     counts.drawn.material.total!=recordCount ||
     !reportIsClear)
    return false;
  switch(route) {
    case IOSGPUSceneCausalFrameRoute::Production:
      return (prepared.phase==
                  IOSGPUSceneCausalRuntimePhase::AwaitingTarget ||
              prepared.phase==
                  IOSGPUSceneCausalRuntimePhase::TargetEncoded) &&
          ordinal==0u && !identitiesValid && !markersValid &&
          iosGPUSceneProductionFrameCountsAreConsistent(counts);
    case IOSGPUSceneCausalFrameRoute::Target:
      return prepared.phase==
                 IOSGPUSceneCausalRuntimePhase::TargetPrepared &&
          prepared.lastSequence==prepared.arguments.sequence &&
          counts.drawn.material.alphaTest>0u &&
          ordinal==recordCount && recordCount!=0u &&
          identitiesValid && markersValid &&
          iosGPUSceneFrameCountsAreConsistentForCompileMode<Mode>(
              counts);
    }
  return false;
  }

template<IOSGPUSceneMode Mode>
inline constexpr bool
    iosGPUSceneCommitCausalPreparationForCompileMode(
        const IOSGPUSceneCausalRuntimeState& current,
        const IOSGPUSceneCausalRuntimeState& prepared,
        IOSGPUSceneCausalFrameRoute route,
        const IOSGPUSceneFrameCounts& counts,
        uint64_t recordCount,
        uint64_t ordinal,
        bool identitiesValid,
        bool markersValid,
        bool reportIsClear,
        IOSGPUSceneCausalRuntimeState& committed) noexcept {
  if(current.arguments!=prepared.arguments ||
     !iosGPUSceneCausalPreparationIsValidForCompileMode<Mode>(
         prepared,route,counts,recordCount,ordinal,
         identitiesValid,markersValid,reportIsClear))
    return false;

  IOSGPUSceneCausalRuntimeState next = prepared;
  switch(route) {
    case IOSGPUSceneCausalFrameRoute::Production:
      if(current.phase==IOSGPUSceneCausalRuntimePhase::AwaitingTarget) {
        if(prepared.phase!=IOSGPUSceneCausalRuntimePhase::AwaitingTarget ||
           prepared.generation==0u ||
           (current.generation!=0u &&
            prepared.generation!=current.generation) ||
           prepared.lastSequence<=current.lastSequence ||
           prepared.lastSequence>=prepared.arguments.sequence)
          return false;
        }
      else if(current.phase==
                  IOSGPUSceneCausalRuntimePhase::TargetEncoded) {
        if(prepared!=current)
          return false;
        }
      else {
        return false;
        }
      break;
    case IOSGPUSceneCausalFrameRoute::Target:
      if(current.phase!=IOSGPUSceneCausalRuntimePhase::AwaitingTarget ||
         prepared.phase!=IOSGPUSceneCausalRuntimePhase::TargetPrepared ||
         prepared.generation==0u ||
         (current.generation!=0u &&
          prepared.generation!=current.generation) ||
         prepared.lastSequence!=prepared.arguments.sequence)
        return false;
      next.phase = IOSGPUSceneCausalRuntimePhase::TargetEncoded;
      break;
    default:
      return false;
    }
  committed = next;
  return true;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A) || \
    defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B)
inline constexpr bool iosGPUSceneCausalPreparationIsValid(
    const IOSGPUSceneCausalRuntimeState& prepared,
    IOSGPUSceneCausalFrameRoute route,
    const IOSGPUSceneFrameCounts& counts,
    uint64_t recordCount,
    uint64_t ordinal,
    bool identitiesValid,
    bool markersValid,
    bool reportIsClear) noexcept {
  return iosGPUSceneCausalPreparationIsValidForCompileMode<
      iosGPUSceneCompiledMode()>(
          prepared,route,counts,recordCount,ordinal,
          identitiesValid,markersValid,reportIsClear);
  }

inline constexpr bool iosGPUSceneCommitCausalPreparation(
    const IOSGPUSceneCausalRuntimeState& current,
    const IOSGPUSceneCausalRuntimeState& prepared,
    IOSGPUSceneCausalFrameRoute route,
    const IOSGPUSceneFrameCounts& counts,
    uint64_t recordCount,
    uint64_t ordinal,
    bool identitiesValid,
    bool markersValid,
    bool reportIsClear,
    IOSGPUSceneCausalRuntimeState& committed) noexcept {
  return iosGPUSceneCommitCausalPreparationForCompileMode<
      iosGPUSceneCompiledMode()>(
          current,prepared,route,counts,recordCount,ordinal,
          identitiesValid,markersValid,reportIsClear,committed);
  }
#endif
#endif

struct IOSGPUSceneMeshCandidate final {
  IOSWorldGeneration snapshotGeneration;
  IOSWorldGeneration registryGeneration;
  IOSRenderEntity     entity;
  IOSMaterial         material;
  bool                hasMaterial = false;
  bool                hasTexture = false;
  bool                hasNativeTexture = false;
  bool                hasSupportedTextureFormat = false;
  bool                hasValidNativeTexture = false;
  uint32_t            textureWidth = 0;
  uint32_t            textureHeight = 0;
  uint32_t            textureMipCount = 0;
  bool                hasMesh = false;
  bool                hasNativeVertexBuffer = false;
  bool                hasNativeIndexBuffer = false;
  std::size_t         vertexBufferByteSize = 0;
  std::size_t         indexBufferByteSize = 0;
  std::size_t         vertexStride = 0;
  std::size_t         firstIndex = 0;
  std::size_t         indexCount = 0;
  };

inline uint64_t iosGPUSceneFailingHandle(
    IOSGPUSceneDrawPlanResult result,
    const IOSGPUSceneMeshCandidate& source) noexcept {
  switch(result) {
    case IOSGPUSceneDrawPlanResult::MissingMaterial:
    case IOSGPUSceneDrawPlanResult::UnsupportedMaterial:
    case IOSGPUSceneDrawPlanResult::InvalidAlphaCutoff:
      return source.entity.material.value;
    case IOSGPUSceneDrawPlanResult::MissingAlphaTexture:
    case IOSGPUSceneDrawPlanResult::MissingTexture:
      return source.material.baseColorTexture
          ? source.material.baseColorTexture.value
          : source.entity.material.value;
    case IOSGPUSceneDrawPlanResult::InvalidTexture:
      return source.material.baseColorTexture.value;
    case IOSGPUSceneDrawPlanResult::GenerationMismatch:
      if(source.material.baseColorTexture &&
         source.material.baseColorTexture.generation!=
             source.snapshotGeneration)
        return source.material.baseColorTexture.value;
      if(source.entity.material.generation!=source.snapshotGeneration)
        return source.entity.material.value;
      return source.entity.mesh.value;
    case IOSGPUSceneDrawPlanResult::MissingMesh:
    case IOSGPUSceneDrawPlanResult::InvalidMesh:
      return source.entity.mesh.value;
    case IOSGPUSceneDrawPlanResult::Draw:
    case IOSGPUSceneDrawPlanResult::SkippedVisibility:
      return 0;
    }
  return 0;
  }

struct alignas(16) IOSGPUSceneDrawConstants final {
  IOSMatrix4x4 viewProjection;
  IOSMatrix4x4 model;
  IOSFloat4    baseColor;
  IOSFloat2    uvOffset;
  };

struct IOSGPUSceneDrawPlan final {
  IOSGPUSceneDrawConstants constants;
  IOSTextureHandle         baseColorTexture;
  IOSMaterialCategory      materialCategory = IOSMaterialCategory::Opaque;
  IOSSceneMeshKind         kind = IOSSceneMeshKind::Unsupported;
  IOSGPUScenePipelineSelector pipeline =
      IOSGPUScenePipelineSelector::Unsupported;
  bool                     usesFallbackTexture = false;
  std::size_t              indexBufferOffset = 0;
  std::size_t              indexCount = 0;
  };

inline IOSGPUSceneDrawPlanResult planIOSGPUSceneDraw(
    const IOSCameraState& camera,
    const IOSGPUSceneMeshCandidate& source,
    IOSGPUSceneDrawPlan& out) noexcept {
  out = IOSGPUSceneDrawPlan();
  if((source.entity.visibilityMask&IOSSceneVisibilityMain)==0)
    return IOSGPUSceneDrawPlanResult::SkippedVisibility;
  if(!source.snapshotGeneration || !source.registryGeneration ||
     source.snapshotGeneration!=source.registryGeneration ||
     source.entity.mesh.generation!=source.snapshotGeneration ||
     source.entity.material.generation!=source.snapshotGeneration ||
     (source.material.baseColorTexture &&
      source.material.baseColorTexture.generation!=source.snapshotGeneration))
    return IOSGPUSceneDrawPlanResult::GenerationMismatch;
  if(!source.hasMaterial || source.material.id!=source.entity.material)
    return IOSGPUSceneDrawPlanResult::MissingMaterial;
  const IOSGPUScenePipelineSelector pipeline =
      iosGPUScenePipelineSelector(source.material.category);
  if(pipeline==IOSGPUScenePipelineSelector::Unsupported)
    return IOSGPUSceneDrawPlanResult::UnsupportedMaterial;
  switch(source.entity.kind) {
    case IOSSceneMeshKind::Landscape:
    case IOSSceneMeshKind::Static:
    case IOSSceneMeshKind::Movable:
      break;
    case IOSSceneMeshKind::Unsupported:
      return IOSGPUSceneDrawPlanResult::InvalidMesh;
    }
  if(source.entity.kind!=IOSSceneMeshKind::Landscape &&
     source.entity.kind!=IOSSceneMeshKind::Static &&
     source.entity.kind!=IOSSceneMeshKind::Movable)
    return IOSGPUSceneDrawPlanResult::InvalidMesh;
  if(pipeline==IOSGPUScenePipelineSelector::AlphaTest) {
    if(!source.material.baseColorTexture || !source.hasTexture ||
       source.material.usesFallbackTexture)
      return IOSGPUSceneDrawPlanResult::MissingAlphaTexture;
    if(source.material.alphaCutoff!=0.5f)
      return IOSGPUSceneDrawPlanResult::InvalidAlphaCutoff;
    }
  else if(!source.material.baseColorTexture || !source.hasTexture) {
    return IOSGPUSceneDrawPlanResult::MissingTexture;
    }
  if(!source.hasNativeTexture || !source.hasSupportedTextureFormat ||
     !source.hasValidNativeTexture || source.textureWidth==0u ||
     source.textureHeight==0u || source.textureMipCount==0u)
    return IOSGPUSceneDrawPlanResult::InvalidTexture;

  uint32_t maximumTextureMipCount = 1u;
  uint32_t maximumTextureExtent =
      source.textureWidth>source.textureHeight
        ? source.textureWidth
        : source.textureHeight;
  while(maximumTextureExtent>1u) {
    maximumTextureExtent /= 2u;
    ++maximumTextureMipCount;
    }
  if(source.textureMipCount>maximumTextureMipCount)
    return IOSGPUSceneDrawPlanResult::InvalidTexture;
  if(!source.hasMesh)
    return IOSGPUSceneDrawPlanResult::MissingMesh;

  const bool validVertexBuffer =
      source.hasNativeVertexBuffer &&
      source.vertexStride==IOSLandscapeVertexStride &&
      source.vertexBufferByteSize>=source.vertexStride &&
      source.vertexBufferByteSize%source.vertexStride==0;
  const bool validIndexBuffer =
      source.hasNativeIndexBuffer &&
      source.indexBufferByteSize>=IOSLandscapeIndexStride &&
      source.indexBufferByteSize%IOSLandscapeIndexStride==0;
  const std::size_t availableIndices =
      validIndexBuffer
        ? source.indexBufferByteSize/IOSLandscapeIndexStride
        : 0u;
  const bool validIndexRange =
      source.indexCount!=0 &&
      source.indexCount%std::size_t(3)==0 &&
      source.firstIndex<=availableIndices &&
      source.indexCount<=availableIndices-source.firstIndex;
  if(!validVertexBuffer || !validIndexBuffer || !validIndexRange)
    return IOSGPUSceneDrawPlanResult::InvalidMesh;

  for(const float component:camera.viewProjection.elements)
    if(!std::isfinite(component))
      return IOSGPUSceneDrawPlanResult::InvalidMesh;
  for(const float component:source.entity.currentTransform.elements)
    if(!std::isfinite(component))
      return IOSGPUSceneDrawPlanResult::InvalidMesh;
  if(!std::isfinite(source.material.baseColor.x) ||
     !std::isfinite(source.material.baseColor.y) ||
     !std::isfinite(source.material.baseColor.z) ||
     !std::isfinite(source.material.baseColor.w) ||
     !std::isfinite(source.material.uvOffset.x) ||
     !std::isfinite(source.material.uvOffset.y))
    return IOSGPUSceneDrawPlanResult::InvalidMesh;

  out.constants.viewProjection = camera.viewProjection;
  out.constants.model          = source.entity.currentTransform;
  out.constants.baseColor      = source.material.baseColor;
  out.constants.uvOffset       = source.material.uvOffset;
  out.baseColorTexture         = source.material.baseColorTexture;
  out.materialCategory         = source.material.category;
  out.kind                     = source.entity.kind;
  out.pipeline                 = pipeline;
  out.usesFallbackTexture      = source.material.usesFallbackTexture;
  out.indexBufferOffset =
      source.firstIndex*IOSLandscapeIndexStride;
  out.indexCount = source.indexCount;
  return IOSGPUSceneDrawPlanResult::Draw;
  }

static_assert(sizeof(IOSMatrix4x4)==64u);
static_assert(sizeof(IOSFloat2)==8u);
static_assert(sizeof(IOSFloat4)==16u);
static_assert(offsetof(IOSGPUSceneDrawConstants,viewProjection)==0u);
static_assert(offsetof(IOSGPUSceneDrawConstants,model)==64u);
static_assert(offsetof(IOSGPUSceneDrawConstants,baseColor)==128u);
static_assert(offsetof(IOSGPUSceneDrawConstants,uvOffset)==144u);
static_assert(sizeof(IOSGPUSceneDrawConstants)==160u);
static_assert(alignof(IOSGPUSceneDrawConstants)==16u);
static_assert(std::is_trivially_copyable_v<IOSGPUSceneDrawConstants>);

enum class IOSGPUSceneUVAnimationRecordResult : uint8_t {
  IgnoredStatic,
  RecordedUvOnly,
  RecordedFrameAndUv,
  InvalidEvidence,
  DuplicateAnimated,
  CountOverflow,
  };

struct IOSGPUSceneUVAnimationDrawReport final {
  std::vector<IOSUVAnimationSelection> encodedEntries;
  std::size_t                          drawnUvOnly = 0;
  std::size_t                          drawnFrameAndUv = 0;
  std::size_t                          encodedCount = 0;
  uint64_t encodedTextureDigest = IOSUVAnimationFNV1aOffset;
  uint64_t encodedUVDigest = IOSUVAnimationFNV1aOffset;
  bool     valid = false;

  bool operator==(const IOSGPUSceneUVAnimationDrawReport&) const = default;
  };

struct IOSGPUSceneUVAnimationTracker final {
  const IOSUVAnimationEvidence* evidence = nullptr;
  std::vector<IOSTextureHandle> actuallyEncodedHandles;
  std::vector<IOSFloat2>        actuallyEncodedOffsets;
  std::vector<uint8_t>          recorded;
  std::size_t                   drawnUvOnly = 0;
  std::size_t                   drawnFrameAndUv = 0;
  bool                          valid = false;
  };

inline bool prepareIOSGPUSceneUVAnimationTracker(
    const IOSUVAnimationEvidence& evidence,
    IOSWorldGeneration expectedGeneration,
    IOSGPUSceneUVAnimationTracker& output) noexcept {
  if(!expectedGeneration || !isCanonicalIOSUVAnimationEvidence(evidence))
    return false;
  for(const auto& selection:evidence.selections)
    if(selection.selectedHandle.generation!=expectedGeneration)
      return false;

  try {
    IOSGPUSceneUVAnimationTracker prepared;
    prepared.evidence = &evidence;
    prepared.actuallyEncodedHandles.assign(
        evidence.selections.size(),IOSTextureHandle{});
    prepared.actuallyEncodedOffsets.assign(
        evidence.selections.size(),IOSFloat2{});
    prepared.recorded.assign(evidence.selections.size(),uint8_t(0u));
    prepared.valid = true;
    output = std::move(prepared);
    return true;
    }
  catch(...) {
    return false;
    }
  }

inline IOSGPUSceneUVAnimationRecordResult recordIOSGPUSceneUVAnimationDraw(
    IOSGPUSceneUVAnimationTracker& tracker,
    const IOSGPUSceneDrawPlan& plan) noexcept {
  if(!tracker.valid || tracker.evidence==nullptr ||
     tracker.actuallyEncodedHandles.size()!=
         tracker.evidence->selections.size() ||
     tracker.actuallyEncodedOffsets.size()!=
         tracker.evidence->selections.size() ||
     tracker.recorded.size()!=tracker.evidence->selections.size() ||
     !plan.baseColorTexture ||
     !isCanonicalIOSUVAnimationOffset(plan.constants.uvOffset))
    return IOSGPUSceneUVAnimationRecordResult::InvalidEvidence;

  const auto& selections = tracker.evidence->selections;
  std::size_t selected = selections.size();
  for(std::size_t index=0; index<selections.size(); ++index) {
    if(selections[index].selectedHandle!=plan.baseColorTexture)
      continue;
    if(selected!=selections.size())
      return IOSGPUSceneUVAnimationRecordResult::InvalidEvidence;
    selected = index;
    }
  if(selected==selections.size())
    return IOSGPUSceneUVAnimationRecordResult::IgnoredStatic;
  if(tracker.recorded[selected]!=0u ||
     tracker.actuallyEncodedHandles[selected])
    return IOSGPUSceneUVAnimationRecordResult::DuplicateAnimated;

  const auto& expected = selections[selected];
  if(iosUVAnimationFloatBits(plan.constants.uvOffset.x)!=
         iosUVAnimationFloatBits(expected.uvOffset.x) ||
     iosUVAnimationFloatBits(plan.constants.uvOffset.y)!=
         iosUVAnimationFloatBits(expected.uvOffset.y))
    return IOSGPUSceneUVAnimationRecordResult::InvalidEvidence;

  IOSGPUSceneUVAnimationRecordResult result;
  if(expected.mode==IOSSceneTextureAnimationMode::UvOnly) {
    if(tracker.drawnUvOnly==std::numeric_limits<std::size_t>::max())
      return IOSGPUSceneUVAnimationRecordResult::CountOverflow;
    ++tracker.drawnUvOnly;
    result = IOSGPUSceneUVAnimationRecordResult::RecordedUvOnly;
    }
  else if(expected.mode==IOSSceneTextureAnimationMode::FrameAndUv) {
    if(tracker.drawnFrameAndUv==std::numeric_limits<std::size_t>::max())
      return IOSGPUSceneUVAnimationRecordResult::CountOverflow;
    ++tracker.drawnFrameAndUv;
    result = IOSGPUSceneUVAnimationRecordResult::RecordedFrameAndUv;
    }
  else {
    return IOSGPUSceneUVAnimationRecordResult::InvalidEvidence;
    }

  tracker.actuallyEncodedHandles[selected] = plan.baseColorTexture;
  tracker.actuallyEncodedOffsets[selected] = plan.constants.uvOffset;
  tracker.recorded[selected] = uint8_t(1u);
  return result;
  }

inline bool finalizeIOSGPUSceneUVAnimationDrawReport(
    const IOSGPUSceneUVAnimationTracker& tracker,
    IOSGPUSceneUVAnimationDrawReport& output) noexcept {
  if(!tracker.valid || tracker.evidence==nullptr ||
     !isCanonicalIOSUVAnimationEvidence(*tracker.evidence) ||
     tracker.actuallyEncodedHandles.size()!=
         tracker.evidence->selections.size() ||
     tracker.actuallyEncodedOffsets.size()!=
         tracker.evidence->selections.size() ||
     tracker.recorded.size()!=tracker.evidence->selections.size() ||
     tracker.drawnUvOnly!=tracker.evidence->admittedUvOnly ||
     tracker.drawnFrameAndUv!=tracker.evidence->admittedFrameAndUv ||
     tracker.evidence->plannedCount!=tracker.evidence->selections.size() ||
     tracker.drawnUvOnly>tracker.evidence->selections.size() ||
     tracker.drawnFrameAndUv>
         tracker.evidence->selections.size()-tracker.drawnUvOnly)
    return false;

  try {
    IOSGPUSceneUVAnimationDrawReport finalized;
    finalized.encodedEntries.reserve(tracker.evidence->selections.size());
    uint64_t textureDigest = IOSUVAnimationFNV1aOffset;
    uint64_t uvDigest = IOSUVAnimationFNV1aOffset;
    for(std::size_t index=0;
        index<tracker.evidence->selections.size();
        ++index) {
      if(tracker.recorded[index]!=uint8_t(1u) ||
         !tracker.actuallyEncodedHandles[index] ||
         !isCanonicalIOSUVAnimationOffset(
             tracker.actuallyEncodedOffsets[index]))
        return false;
      const auto& expected = tracker.evidence->selections[index];
      if(tracker.actuallyEncodedHandles[index]!=expected.selectedHandle ||
         iosUVAnimationFloatBits(
             tracker.actuallyEncodedOffsets[index].x)!=
             iosUVAnimationFloatBits(expected.uvOffset.x) ||
         iosUVAnimationFloatBits(
             tracker.actuallyEncodedOffsets[index].y)!=
             iosUVAnimationFloatBits(expected.uvOffset.y))
        return false;
      IOSUVAnimationSelection encoded = expected;
      encoded.selectedHandle = tracker.actuallyEncodedHandles[index];
      encoded.uvOffset = tracker.actuallyEncodedOffsets[index];
      finalized.encodedEntries.emplace_back(encoded);
      textureDigest = iosUVAnimationFNV1aAppendUint64(
          textureDigest,encoded.sourceId);
      textureDigest = iosUVAnimationFNV1aAppendUint32(
          textureDigest,static_cast<uint32_t>(encoded.mode));
      textureDigest = iosUVAnimationFNV1aAppendUint64(
          textureDigest,encoded.frameOrdinal);
      textureDigest = iosUVAnimationFNV1aAppendUint64(
          textureDigest,encoded.selectedHandle.generation.value);
      textureDigest = iosUVAnimationFNV1aAppendUint64(
          textureDigest,encoded.selectedHandle.value);
      uvDigest = iosUVAnimationFNV1aAppendUint64(
          uvDigest,encoded.sourceId);
      uvDigest = iosUVAnimationFNV1aAppendUint32(
          uvDigest,iosUVAnimationFloatBits(encoded.uvOffset.x));
      uvDigest = iosUVAnimationFNV1aAppendUint32(
          uvDigest,iosUVAnimationFloatBits(encoded.uvOffset.y));
      }
    if(finalized.encodedEntries.size()!=tracker.evidence->plannedCount ||
       textureDigest!=tracker.evidence->textureSelectionDigest ||
       uvDigest!=tracker.evidence->plannedUVDigest)
      return false;
    finalized.drawnUvOnly = tracker.drawnUvOnly;
    finalized.drawnFrameAndUv = tracker.drawnFrameAndUv;
    finalized.encodedCount = finalized.encodedEntries.size();
    finalized.encodedTextureDigest = textureDigest;
    finalized.encodedUVDigest = uvDigest;
    finalized.valid = true;
    output = std::move(finalized);
    return true;
    }
  catch(...) {
    return false;
    }
  }
