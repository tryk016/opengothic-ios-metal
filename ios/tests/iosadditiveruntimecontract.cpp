#include "iosadditiveinputartifact.h"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

struct Sources final {
  std::string header;
  std::string scene;
  std::string context;
  };

struct OneShot final {
  enum class Claim : uint8_t {
    Owner,
    Discard,
    };

  Claim claim(uint64_t serial) noexcept {
    if(claimed)
      return Claim::Discard;
    claimed = true;
    ownerSerial = serial;
    return Claim::Owner;
    }

  void fail(uint64_t serial) noexcept {
    if(!terminal && claimed && serial==ownerSerial) {
      terminal = true;
      terminalKind = 'F';
      ++terminalCount;
      }
    }

  void complete(uint64_t serial, bool admitted) noexcept {
    if(terminal || !claimed || serial!=ownerSerial)
      return;
    terminal = true;
    terminalKind = admitted ? 'C' : 'F';
    ++terminalCount;
    }

  bool     claimed = false;
  bool     terminal = false;
  uint64_t ownerSerial = 0u;
  uint64_t terminalCount = 0u;
  char     terminalKind = '\0';
  };

std::string readFile(const std::filesystem::path& path) {
  std::ifstream input(path,std::ios::binary);
  if(!input)
    throw std::runtime_error("cannot open "+path.string());
  return std::string(std::istreambuf_iterator<char>(input),{});
  }

std::size_t countOf(std::string_view text, std::string_view token) noexcept {
  if(token.empty())
    return 0u;
  std::size_t count = 0u;
  std::size_t position = 0u;
  while((position=text.find(token,position))!=std::string_view::npos) {
    ++count;
    position += token.size();
    }
  return count;
  }

std::string_view slice(std::string_view text,
                       std::string_view begin,
                       std::string_view end) noexcept {
  const std::size_t first = text.find(begin);
  if(first==std::string_view::npos)
    return {};
  const std::size_t last = text.find(end,first+begin.size());
  if(last==std::string_view::npos || last<=first)
    return {};
  return text.substr(first,last-first);
  }

bool ordered(std::string_view text,
             const std::vector<std::string_view>& tokens) noexcept {
  std::size_t cursor = 0u;
  for(const std::string_view token:tokens) {
    const std::size_t position = text.find(token,cursor);
    if(position==std::string_view::npos)
      return false;
    cursor = position+token.size();
    }
  return true;
  }

bool validateSources(const Sources& sources,
                     std::vector<std::string>& failures) {
  const auto expect = [&](bool condition, const char* reason) {
    if(!condition)
      failures.emplace_back(reason);
    };

  expect(sources.header.find(
      "Report prepareFrame(PreparedFrame& prepared,\n"
      "                        uint64_t targetGeneration,")!=
          std::string::npos,
      "prepareFrame must receive the SceneHDR target generation");
  expect(sources.header.find(
      "AdditiveInputArtifact takeAdditiveInputArtifact() noexcept;")!=
          std::string::npos,
      "PreparedFrame must expose its frozen artifact before encoding");

  const std::string_view take = slice(
      sources.scene,
      "IOSGPUScene::PreparedFrame::takeAdditiveInputArtifact() noexcept",
      "IOSGPUScene::Report IOSGPUScene::prepareFrame(");
  expect(!take.empty(),"frozen artifact take implementation is missing");
  expect(take.find("!impl->ready")!=std::string_view::npos,
         "artifact take must require successful preparation");
  expect(take.find("!impl->nativeCompleted")==std::string_view::npos,
         "artifact take must not wait until native encoding");

  const std::string_view prepare = slice(
      sources.scene,
      "IOSGPUScene::Report IOSGPUScene::prepareFrame(",
      "IOSGPUScene::Report IOSGPUScene::encodePrepared(");
  expect(!prepare.empty(),"prepareFrame source body is missing");
  expect(ordered(prepare,{
      "iosGPUSceneProductionPipelineStatesAreAvailable(",
      "iosGPUSceneProductionDepthStatesAreAvailable(",
      "assets.isInitialized()",
      "snapshot.generation!=assets.generation()",
      "assets.lookupMesh(entity.mesh)",
      "assets.lookupTexture(plan.baseColorTexture)",
      "materializeReportMarkers(",
      "iosBuildAdditiveInputArtifactV1(",
      "targetGeneration,snapshot.sequence.value",
      "candidateFrame->ready = true",
      }),"prepareFrame must freeze all preflight state and the artifact");
  expect(prepare.find("candidateFrame->base.emplace_back")!=
             std::string_view::npos &&
         prepare.find("candidateFrame->additive.emplace_back")!=
             std::string_view::npos,
         "prepareFrame must freeze separate base and additive lists");
  expect(prepare.find("startEncoding")==std::string_view::npos,
         "prepareFrame must finish before encoder creation");

  const std::string_view encode = slice(
      sources.scene,
      "void IOSGPUScene::Impl::encodeLandscape(",
      "IOSGPUScene::IOSGPUScene(");
  expect(!encode.empty(),"native frozen encode source body is missing");
  expect(ordered(encode,{
      "encodePhase(context.prepared->base,context.scene->baseDepthState);",
      "encodePhase(context.prepared->multiply2,",
      "context.scene->multiply2DepthState);",
      "encodePhase(context.prepared->additive,",
      "context.scene->additiveDepthState);",
      }),"one SceneHDR encoder must encode base and Multiply2 before additive");
  expect(countOf(encode,"encodePhase(context.prepared->base")==1u &&
         countOf(encode,"encodePhase(context.prepared->multiply2")==1u &&
         countOf(encode,"encodePhase(context.prepared->additive")==1u,
         "frozen encoder must contain exactly three phases");
  expect(encode.find("lookupMesh")==std::string_view::npos &&
         encode.find("lookupTexture")==std::string_view::npos &&
         encode.find("snapshot")==std::string_view::npos &&
         encode.find("recordIOSGPUSceneDrawDispatch")==
             std::string_view::npos,
         "encodePrepared path must not repeat deterministic lookups");

  const std::string_view additivePso = slice(
      sources.scene,
      "pipelineDesc.fragmentFunction =\n"
      "          (id<MTLFunction>)additiveFragmentFunction.get();",
      "NSError* additivePipelineError");
  expect(!additivePso.empty(),"additive PSO configuration is missing");
  expect(ordered(additivePso,{
      "additiveColor.blendingEnabled = YES;",
      "#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)",
      "additiveColor.sourceRGBBlendFactor = MTLBlendFactorZero;",
      "#else",
      "additiveColor.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;",
      "#endif",
      "additiveColor.destinationRGBBlendFactor = MTLBlendFactorOne;",
      "additiveColor.rgbBlendOperation = MTLBlendOperationAdd;",
      "additiveColor.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;",
      "additiveColor.destinationAlphaBlendFactor = MTLBlendFactorOne;",
      "additiveColor.alphaBlendOperation = MTLBlendOperationAdd;",
      }),"A/B may differ only in additive RGB source factor");
  expect(countOf(sources.scene,
      "#if defined(OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B)")==1u,
      "B-only rendering conditional must be unique");
  expect(ordered(sources.scene,{
      "depthDesc.depthCompareFunction = MTLCompareFunctionLessEqual;",
      "depthDesc.depthWriteEnabled    = YES;",
      "OwnedObjectiveC depthOwner(",
      "depthDesc.depthWriteEnabled = NO;",
      "OwnedObjectiveC additiveDepthOwner(",
      }),"base/additive depth states must be LEqual with write ON/OFF");
  expect(sources.scene.find(
      "case IOSGPUScenePipelineSelector::Additive:\n"
      "          pipelineState =\n"
      "              (id<MTLRenderPipelineState>)"
      "impl->additivePipelineState;")!=std::string::npos,
      "Additive dispatch must bind the additive PSO");
  expect(sources.scene.find(
      "target.color!=IOSGPUScene::ColorFormat::Rg11B10Float ||\n"
      "       target.sampleCount!=1u")!=std::string::npos,
      "native scene PSOs must require RG11B10Float sample 1");
  expect(sources.scene.find(
      "\"RIOS_ADDITIVE_CAUSAL_MODE=additive-a-hdr\"")!=
          std::string::npos &&
         sources.scene.find(
      "\"RIOS_ADDITIVE_CAUSAL_MODE=additive-b-hdr\"")!=
          std::string::npos,
      "A/B objects must retain their exact binary mode marker");
  expect(ordered(sources.scene,{
      "\"-renderer-ios-additive-causal-mode=\"",
      "if(!argument.starts_with(IOSGPUSceneAdditiveArgumentPrefix))",
      "argument.substr(IOSGPUSceneAdditiveArgumentPrefix.size())!=",
      "IOSGPUSceneAdditiveMode)",
      "++matching;",
      "return matching==1u;",
      }),"launch parser must require exactly one compile-matching argument");

  const std::size_t prepareCall = sources.context.find(
      "preparedSceneReport = impl->gpuScene->prepareFrame(");
  const std::size_t artifactTake = sources.context.find(
      "preparedScene.takeAdditiveInputArtifact()");
  const std::size_t encoderStart = sources.context.find(
      "auto encoder = command.startEncoding(impl->device);");
  const std::size_t sceneEncode = sources.context.find(
      "impl->gpuScene->encodePrepared(encoder,preparedScene)");
  const std::size_t toneResolve = sources.context.find(
      "impl->linearHDRMetal->encodeToneResolve(");
  expect(prepareCall!=std::string::npos &&
         artifactTake!=std::string::npos &&
         encoderStart!=std::string::npos &&
         sceneEncode!=std::string::npos &&
         toneResolve!=std::string::npos &&
         prepareCall<artifactTake && artifactTake<encoderStart &&
         encoderStart<sceneEncode && sceneEncode<toneResolve,
         "prepare/freeze must precede SceneHDR and additive must precede resolve");
  expect(sources.context.find(
      "preparedScene,impl->linearHDRTargets.generation,\n"
      "          *input.snapshot")!=std::string::npos,
      "artifact identity must use the current SceneHDR target generation");
  expect(sources.context.find(
      "impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;\n"
      "        linearHDRSceneActive = false;")!=std::string::npos,
      "deterministic prepare failure must latch SafeNoScene");
  expect(sources.context.find(
      "if(report.result!=IOSGPUScene::Result::Success) {\n"
      "          impl->linearHDRSafety.mode = "
      "IOSLinearHDRSafetyMode::SafeNoScene;\n"
      "          throw std::runtime_error(")!=std::string::npos,
      "native encode failure must latch SafeNoScene before throwing");
  expect(sources.context.find(
      "else if(!impl->emissiveProfileClaimed) {\n"
      "          impl->emissiveProfileClaimed = true;\n"
      "          frameContext.emissiveInput = std::move(frozenEmissiveInput);\n"
      "          frameContext.emissivePreparedSerial = frame.serial;")!=
          std::string::npos,
      "first frozen artifact must be claimed before submit");

  const std::string_view oneShot = slice(
      sources.context,
      "void failEmissiveInput(",
      "static std::array<char,CC_SHA256_DIGEST_LENGTH*2u+1u>");
  expect(!oneShot.empty(),"one-shot terminal helpers are missing");
  expect(oneShot.find(
      "if(frame.emissiveInput && !frame.emissiveTerminalReported &&\n"
      "       !emissiveProfileTerminalReported)")!=
          std::string_view::npos,
      "owned artifact failure must emit at most one terminal");
  expect(oneShot.find(
      "if(emissiveProfileClaimed || emissiveProfileTerminalReported)\n"
      "      return;")!=std::string_view::npos,
      "later frames must not replace the claimed one-shot path");
  expect(oneShot.find(
      "emissiveProfileClaimed = true;\n"
      "    emissiveProfileTerminalReported = true;\n"
      "    logEmissiveTerminalFailure(")!=std::string_view::npos,
      "pre-artifact failure must atomically claim terminal F");
  expect(sources.context.find(
      "for(auto& frame:frames)\n"
      "      failEmissiveInput(frame,\"gpu\",\"forced-termination\");")!=
          std::string::npos,
      "forced termination must close a claimed artifact with terminal F");

  const std::string_view publication = slice(
      sources.context,
      "bool publishEmissiveInputAfterTerminal(FrameContext& frame) noexcept",
      "void discardUnsubmittedCommand(");
  expect(!publication.empty(),"terminal publication source body is missing");
  expect(ordered(publication,{
      "iosParseAdditiveInputArtifactV1(",
      "if(!frame.emissivePresentAccepted ||",
      "!iosAdditiveInputArtifactV1AcceptsPublication(",
      "view.header,frame.emissivePreparedSerial,",
      "frame.emissiveSubmittedSerial,frame.submitted,",
      "frame.emissiveSubmitAccepted,true,true,",
      "frame.linearHDRSequence.identity().targetGeneration,",
      "frame.linearHDRSequence.identity().snapshotSequence",
      "terminal += \" terminal=C\";",
      "iosPublishAdditiveInputArtifactV1NoClobber(",
      "Log::i(terminal);",
      }),"publication must follow accepted terminal identity admission");
  expect(countOf(publication,
      "iosPublishAdditiveInputArtifactV1NoClobber(")==1u,
      "publication must have one no-clobber path");

  const std::string_view beginFrame = slice(
      sources.context,
      "std::optional<IOSMetalContext::FrameLease> IOSMetalContext::beginFrame()",
      "bool IOSMetalContext::frameAdmissionActive() const noexcept");
  expect(!beginFrame.empty(),"beginFrame terminal path is missing");
  expect(ordered(beginFrame,{
      "materializeLinearHDRProofAfterTerminal(",
      "materializeLinearHDREvidenceAfterTerminal(",
      "publishEmissiveInputAfterTerminal(frameContext)",
      }),"per-slot publication must follow GPU proof and HDR terminal success");
  const std::string_view settle = slice(
      sources.context,
      "bool settleGpu(SettleReason reason, const char* operation,",
      "bool confirmGpuIdle(");
  expect(!settle.empty(),"confirmed-idle terminal path is missing");
  expect(ordered(settle,{
      "materializeLinearHDREvidenceAfterTerminal(frame,true)",
      "if(presentHealthy)",
      "publishEmissiveInputAfterTerminal(frame)",
      }),"confirmed-idle publication must follow terminal success");

  expect(sources.context.find(
      "Log::e(\"RendererIOS additive causal: v=1 mode=\",emissiveModeName(),\n"
      "             \" terminal=F class=\",failureClass,\" reason=\",reason);")!=
          std::string::npos,
      "failure terminal must use the exact fail-closed grammar");
  expect(publication.find("terminal += \" terminal=C\";")!=
             std::string_view::npos,
         "success terminal must use exact terminal=C suffix");
  expect(sources.scene.find(
      "\" terminal=F class=contract reason=launch-argument\"")!=
          std::string::npos,
      "launch failure must include class=contract");

  return failures.empty();
  }

bool replaceOnce(std::string& text,
                 std::string_view from,
                 std::string_view to) {
  const std::size_t position = text.find(from);
  if(position==std::string::npos ||
     text.find(from,position+from.size())!=std::string::npos)
    return false;
  text.replace(position,from.size(),to);
  return true;
  }

void require(bool condition, const char* message) {
  if(!condition)
    throw std::runtime_error(message);
  }

void testPublicationPredicate() {
  IOSAdditiveInputHeaderV1 header;
  header.baseCount = 7u;
  header.additiveCount = IOSAdditiveInputV1AdditiveRecords;
  header.targetGeneration = 19u;
  header.snapshotSequence = 23u;
  require(iosAdditiveInputArtifactV1AcceptsPublication(
      header,41u,41u,true,true,true,true,19u,23u),
      "valid accepted terminal publication was rejected");
  require(!iosAdditiveInputArtifactV1AcceptsPublication(
      header,41u,42u,true,true,true,true,19u,23u),
      "serial mismatch was admitted");
  require(!iosAdditiveInputArtifactV1AcceptsPublication(
      header,41u,41u,false,true,true,true,19u,23u),
      "unsubmitted artifact was admitted");
  require(!iosAdditiveInputArtifactV1AcceptsPublication(
      header,41u,41u,true,false,true,true,19u,23u),
      "unaccepted submit was admitted");
  require(!iosAdditiveInputArtifactV1AcceptsPublication(
      header,41u,41u,true,true,false,true,19u,23u),
      "unterminated GPU work was admitted");
  require(!iosAdditiveInputArtifactV1AcceptsPublication(
      header,41u,41u,true,true,true,false,19u,23u),
      "failed GPU work was admitted");
  require(!iosAdditiveInputArtifactV1AcceptsPublication(
      header,41u,41u,true,true,true,true,20u,23u),
      "target generation mismatch was admitted");
  require(!iosAdditiveInputArtifactV1AcceptsPublication(
      header,41u,41u,true,true,true,true,19u,24u),
      "snapshot sequence mismatch was admitted");
  }

void testOneShot() {
  OneShot success;
  require(success.claim(7u)==OneShot::Claim::Owner,
          "first frozen artifact did not become owner");
  require(success.claim(8u)==OneShot::Claim::Discard,
          "later frozen artifact was not discarded");
  success.fail(8u);
  require(success.terminalCount==0u,
          "later frame emitted the one-shot terminal");
  success.complete(7u,true);
  success.fail(7u);
  success.complete(7u,false);
  require(success.terminalCount==1u && success.terminalKind=='C',
          "success path did not emit exactly one C terminal");

  OneShot failure;
  require(failure.claim(11u)==OneShot::Claim::Owner,
          "failure path did not claim first artifact");
  failure.fail(11u);
  require(failure.claim(12u)==OneShot::Claim::Discard,
          "claimed failure path retried");
  failure.complete(11u,true);
  failure.fail(11u);
  require(failure.terminalCount==1u && failure.terminalKind=='F',
          "pre-submit failure did not remain exactly one F terminal");
  }

void testSourceMutations(const Sources& original) {
  const auto rejected = [&](const char* name,
                            Sources mutated,
                            std::string Sources::* member,
                            std::string_view from,
                            std::string_view to) {
    require(replaceOnce(mutated.*member,from,to),name);
    std::vector<std::string> failures;
    if(validateSources(mutated,failures))
      throw std::runtime_error(std::string("source mutation survived: ")+name);
    };

  rejected("missing-preflight",original,&Sources::context,
      "preparedSceneReport = impl->gpuScene->prepareFrame(",
      "preparedSceneReport = removedPrepareFrame(");
  rejected("artifact-after-start-encoding",original,&Sources::context,
      "preparedScene.takeAdditiveInputArtifact()",
      "preparedScene.deferAdditiveInputArtifactUntilAfterEncoding()");
  rejected("encode-failure-without-sticky-safe-mode",original,
      &Sources::context,
      "if(report.result!=IOSGPUScene::Result::Success) {\n"
      "          impl->linearHDRSafety.mode = "
      "IOSLinearHDRSafetyMode::SafeNoScene;\n"
      "          throw std::runtime_error(",
      "if(report.result!=IOSGPUScene::Result::Success) {\n"
      "          throw std::runtime_error(");
  rejected("additive-before-base",original,&Sources::scene,
      "encodePhase(context.prepared->base,context.scene->baseDepthState);",
      "encodePhase(context.prepared->additive,context.scene->baseDepthState);");
  rejected("additive-after-resolve",original,&Sources::context,
      "impl->gpuScene->encodePrepared(encoder,preparedScene)",
      "impl->gpuScene->encodePreparedAfterToneResolve(encoder,preparedScene)");
  rejected("wrong-additive-pso",original,&Sources::scene,
      "(id<MTLRenderPipelineState>)impl->additivePipelineState;",
      "(id<MTLRenderPipelineState>)impl->opaquePipelineState;");
  rejected("wrong-additive-depth",original,&Sources::scene,
      "depthDesc.depthWriteEnabled = NO;",
      "depthDesc.depthWriteEnabled = YES;");
  rejected("wrong-additive-blend",original,&Sources::scene,
      "additiveColor.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;",
      "additiveColor.sourceRGBBlendFactor = MTLBlendFactorZero;");
  rejected("partial-publication",original,&Sources::context,
      "!iosAdditiveInputArtifactV1AcceptsPublication(",
      "iosAdditiveInputArtifactV1AcceptsPublication(");
  rejected("publication-without-present",original,&Sources::context,
      "if(!frame.emissivePresentAccepted ||",
      "if(false ||");
  rejected("publication-wrong-identity",original,&Sources::context,
      "frame.linearHDRSequence.identity().targetGeneration,",
      "frame.emissiveInput.generation,");
  rejected("one-shot-retry",original,&Sources::context,
      "else if(!impl->emissiveProfileClaimed) {",
      "else if(true) {");
  rejected("wrong-success-terminal",original,&Sources::context,
      "terminal += \" terminal=C\";",
      "terminal += \" terminal=F\";");
  }

} // namespace

int main(int argc, char** argv) {
  try {
    if(argc!=2 || argv[1]==nullptr || argv[1][0]=='\0')
      throw std::runtime_error("usage: iosadditiveruntimecontract <repo-root>");
    const std::filesystem::path root(argv[1]);
    Sources sources{
      readFile(root/"game/graphics/iosgpuscene.h"),
      readFile(root/"game/graphics/iosgpuscene.mm"),
      readFile(root/"game/graphics/iosmetalcontext.cpp"),
      };
    std::vector<std::string> failures;
    if(!validateSources(sources,failures)) {
      for(const std::string& failure:failures)
        std::cerr << "iosadditiveruntimecontract: " << failure << '\n';
      return 1;
      }
    testPublicationPredicate();
    testOneShot();
    testSourceMutations(sources);
    return 0;
    }
  catch(const std::exception& exception) {
    std::cerr << "iosadditiveruntimecontract: "
              << exception.what() << '\n';
    return 2;
    }
  }
