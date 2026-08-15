#include <cassert>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

namespace {

std::string read(const std::filesystem::path& path) {
  std::ifstream stream(path,std::ios::binary);
  assert(stream);
  return std::string(std::istreambuf_iterator<char>(stream),{});
  }

std::size_t count(std::string_view text, std::string_view token) {
  std::size_t total = 0u;
  std::size_t offset = 0u;
  while((offset=text.find(token,offset))!=std::string_view::npos) {
    ++total;
    offset += token.size();
    }
  return total;
  }

bool ordered(std::string_view text,
             std::initializer_list<std::string_view> tokens) {
  std::size_t offset = 0u;
  for(const auto token:tokens) {
    offset = text.find(token,offset);
    if(offset==std::string_view::npos)
      return false;
    offset += token.size();
    }
  return true;
  }

}

int main(int argc, char** argv) {
  assert(argc==2);
  const std::filesystem::path root(argv[1]);
  const std::string header = read(root/"game/graphics/iosgpuscene.h");
  const std::string plan = read(root/"game/graphics/iosgpusceneplan.h");
  const std::string scene = read(root/"game/graphics/iosgpuscene.mm");
  const std::string context = read(root/"game/graphics/iosmetalcontext.cpp");
  const std::string cmake = read(root/"CMakeLists.txt");
  const std::string presets = read(root/"CMakePresets.json");

  assert(scene.find("RIOS_MULTIPLY2_CAUSAL_MODE=multiply2-a-hdr")!=
         std::string::npos);
  assert(scene.find("RIOS_MULTIPLY2_CAUSAL_MODE=multiply2-b-hdr")!=
         std::string::npos);
  assert(header.find("using Multiply2InputArtifact =")==std::string::npos);
  assert(header.find("struct Multiply2InputArtifact final")!=
         std::string::npos);
  assert(plan.find(
      "defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A)\n"
      "  return \"multiply2-a\";")!=std::string::npos);
  assert(plan.find(
      "defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)\n"
      "  return \"multiply2-b\";")!=std::string::npos);
  assert(context.find(
      "#define OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_A 1")==
         std::string::npos);
  assert(context.find(
      "#define OPENGOTHIC_RENDERER_IOS_ADDITIVE_CAUSAL_B 1")==
         std::string::npos);
  assert(context.find(
      "#define OPENGOTHIC_RENDERER_IOS_EMISSIVE_CAUSAL 1")!=
         std::string::npos);
  assert(context.find(
      "IOSGPUScene::Multiply2InputArtifact emissiveInput;")!=
         std::string::npos);
  assert(count(scene,"#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B)\n"
                     "      additiveColor.sourceRGBBlendFactor") == 1u);
  assert(ordered(scene,{
      "additiveColor.sourceRGBBlendFactor = MTLBlendFactorZero;",
      "#else",
      "additiveColor.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;",
      "#endif",
      "additiveColor.destinationRGBBlendFactor = MTLBlendFactorSourceColor;",
      "additiveColor.sourceAlphaBlendFactor = MTLBlendFactorDestinationColor;",
      "additiveColor.destinationAlphaBlendFactor = MTLBlendFactorSourceColor;",
      "OwnedObjectiveC multiply2PipelineOwner("}));
  assert(ordered(scene,{
      "encodePhase(context.prepared->base,context.scene->baseDepthState);",
      "encodePhase(context.prepared->multiply2,",
      "context.scene->multiply2DepthState);",
      "encodePhase(context.prepared->additive,",
      "context.scene->additiveDepthState);"}));
  assert(scene.find(
      "(phase==0u && prepared.impl!=nullptr &&\n"
      "      (prepared.impl->nativeBaseMultiplyCompleted ||\n"
      "       prepared.impl->nativeAdditiveCompleted))")!=
         std::string::npos);
  assert(scene.find("++context.report.encodedPhaseDrawCount;")!=
         std::string::npos);
  assert(scene.find("++context.report.encodedPhaseTexturedDrawCount;")!=
         std::string::npos);
  assert(scene.find(
      "entity,plan,*mesh,*texture,frameAnimation,uvAnimation,\n"
      "               artifactRecord")!=std::string::npos);
  assert(scene.find(
      "emissiveArtifactAnimation(\n"
      "       plan.baseColorTexture,frameAnimation,uvAnimation,record.animation)")!=
         std::string::npos);
  assert(scene.find("iosGPUSceneMultiply2DrawIdSignpost(identity)")!=
         std::string::npos);
  assert(scene.find("iosGPUSceneMultiply2DrawBindSignpost(identity)")!=
         std::string::npos);
  assert(scene.find("insertDebugSignpost:(NSString*)draw.drawId.get()")!=
         std::string::npos);
  assert(ordered(context,{
      "encodePreparedThroughMultiply2(",
      "const auto failMultiply2SplitPhase =",
      "RendererIOS native scene markers were not prepared",
      "RendererIOS native Landscape texture coverage failed",
      "RendererIOS native Landscape frame-animation evidence was not finalized",
      "RendererIOS native Landscape UV-animation evidence was not finalized",
      "encoder.setFramebuffer({});",
      "impl->linearHDRProof->encodeCopy(",
      "encodePreparedAdditive(encoder,preparedScene)",
      "impl->linearHDRMetal->encodeToneResolve("}));
  assert(count(context,"failMultiply2SplitPhase(")>=9u);
  assert(ordered(context,{
      "bool multiply2SplitPhaseStarted = false;",
      "const auto latchMultiply2SplitPhasePreSubmitFailure =",
      "multiply2SplitPhaseStarted = true;",
      "encodePreparedThroughMultiply2("}));
  assert(count(context,"latchMultiply2SplitPhasePreSubmitFailure();")==3u);
  assert(context.find(
      "impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;\n"
      "          throw std::runtime_error(std::move(message));")!=
         std::string::npos);
  assert(context.find(
      "{{impl->linearHDRTargets.color,Tempest::Vec4(0.f),Tempest::Preserve}},\n"
      "          {impl->linearHDRTargets.depth,1.f,Tempest::Preserve}")!=
         std::string::npos);
  assert(context.find(
      "{impl->linearHDRTargets.depth,\n"
      "            Tempest::Preserve,Tempest::Preserve}")!=
         std::string::npos);
  assert(context.find(
      "report.encodedPhaseDrawCount!=baseMultiply2Planned")!=
         std::string::npos);
  assert(context.find(
      "additiveReport.encodedPhaseDrawCount!=additivePlanned")!=
         std::string::npos);
  assert(scene.find(
      "const uint64_t encodedPhaseDrawCount =\n"
      "        context.report.encodedPhaseDrawCount;")!=
         std::string::npos);
  assert(scene.find(
      "context.report.encodedPhaseDrawCount = encodedPhaseDrawCount;")!=
         std::string::npos);
  assert(scene.find(
      "additiveColor.rgbBlendOperation = MTLBlendOperationAdd;\n"
      "      additiveColor.sourceAlphaBlendFactor = "
      "MTLBlendFactorDestinationColor;")!=std::string::npos);
  assert(scene.find(
      "reason=multiply2-draw-constants-reflection\");\n"
      "#if defined(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A)")!=
         std::string::npos);
  assert(scene.find(
      "IOSGPUSceneMultiply2Mode,\n"
      "          \" terminal=F class=contract reason=launch-argument\");\n"
      "      initializationResult = IOSGPUScene::Result::NativeEncodingFailed;\n"
      "      emissiveTerminalReported = true;")!=std::string::npos);
  assert(context.find("iosParseMultiply2InputArtifactV1(")!=
         std::string::npos);
  assert(context.find("iosMultiply2InputArtifactV1AcceptsPublication(")!=
         std::string::npos);
  assert(context.find("iosPublishMultiply2InputArtifactV1NoClobber(")!=
         std::string::npos);
  assert(context.find("/Documents/RendererIOS-multiply2-evidence")!=
         std::string::npos);
  assert(context.find("const auto sha = emissiveArtifactSha256(")!=
         std::string::npos);
  assert(context.find("materializeEmissiveTerminal(publishedBytes)")!=
         std::string::npos);
  assert(cmake.find("OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1")!=
         std::string::npos);
  assert(cmake.find("OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B=1")!=
         std::string::npos);
  assert(presets.find("renderer-ios-multiply2-a-hdr")!=std::string::npos);
  assert(presets.find("renderer-ios-multiply2-b-hdr")!=std::string::npos);
  }
