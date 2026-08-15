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
  const std::string coverageHeader =
      read(root/"game/graphics/iosmultiply2coverageproof.h");
  const std::string coverageModel =
      read(root/"game/graphics/iosmultiply2coverageproof.cpp");
  const std::string coverageProducer =
      read(root/"game/graphics/iosmultiply2coverageproof.mm");
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
  assert(context.find("IOSMultiply2CoverageFrame multiply2Coverage;")!=
         std::string::npos);
  assert(context.find("IOSMultiply2CoverageProofProducer")!=
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
      "depthDesc.depthWriteEnabled    = YES;",
      "OwnedObjectiveC depthOwner(",
      "depthDesc.depthWriteEnabled = NO;",
      "OwnedObjectiveC additiveDepthOwner(",
      "OwnedObjectiveC stencilDescriptor(",
      "depthDesc.frontFaceStencil = stencilDesc;",
      "OwnedObjectiveC multiply2DepthOwner("}));
  assert(scene.find("stencilDesc.stencilCompareFunction = MTLCompareFunctionAlways;")!=
         std::string::npos);
  assert(scene.find("stencilDesc.stencilFailureOperation = MTLStencilOperationKeep;")!=
         std::string::npos);
  assert(scene.find("stencilDesc.depthFailureOperation = MTLStencilOperationKeep;")!=
         std::string::npos);
  assert(scene.find("stencilDesc.depthStencilPassOperation = MTLStencilOperationReplace;")!=
         std::string::npos);
  assert(scene.find("stencilDesc.readMask = 0xffu;")!=std::string::npos);
  assert(scene.find("stencilDesc.writeMask = 0xffu;")!=std::string::npos);
  assert(scene.find("pipelineDesc.stencilAttachmentPixelFormat    = depthFormat;")!=
         std::string::npos);
  assert(scene.find("target.depth!=IOSGPUScene::DepthFormat::Depth32FloatStencil8")!=
         std::string::npos);
  assert(scene.find("context.prepared->markNativeException();")!=
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
  assert(count(scene,"Tempest::MetalApi::withActiveCommandBuffer(")==1u);
  assert(ordered(scene,{
      "first.colorAttachments[0].texture = sceneHDR;",
      "first.depthAttachment.texture = depthStencil;",
      "first.stencilAttachment.texture = depthStencil;",
      "first.stencilAttachment.clearStencil = 0u;",
      "@\"RendererIOS.Multiply2.BaseAndCausal.v1\"",
      "context.scene->baseDepthState,0u",
      "context.scene->multiply2DepthState,1u",
      "context.prepared->markNativeBaseMultiplyCompleted();",
      "@\"RendererIOS.HDRProofCopy.Multiply2.v1\"",
      "copyFromTexture:sceneHDR",
      "@\"RendererIOS.Multiply2.CoverageStencilCopy.v1\"",
      "copyFromTexture:depthStencil",
      "options:MTLBlitOptionStencilFromDepthStencil",
      "second.colorAttachments[0].loadAction = MTLLoadActionLoad;",
      "second.depthAttachment.loadAction = MTLLoadActionLoad;",
      "second.stencilAttachment.loadAction = MTLLoadActionLoad;",
      "@\"RendererIOS.Multiply2.AdditiveAfterProof.v1\"",
      "context.scene->additiveDepthState,0u",
      "context.prepared->markNativeAdditiveCompleted();",
      "context.prepared->nativeCompleted = true;"}));
  assert(ordered(context,{
      "impl->linearHDRProof->nativeCopyView(",
      "impl->gpuScene->multiply2CoverageMetadata(",
      "impl->multiply2Coverage->prepareFrame(",
      "impl->multiply2Coverage->nativeView(",
      "impl->gpuScene->encodePreparedMultiply2Causal(",
      "impl->linearHDRProof->markNativeCopyEncoded(",
      "impl->multiply2Coverage->markEncoded(",
      "impl->linearHDRMetal->encodeToneResolve("}));
  assert(context.find(
      "impl->linearHDRSafety.mode = IOSLinearHDRSafetyMode::SafeNoScene;\n"
      "          throw std::runtime_error(std::move(message));")!=
         std::string::npos);
  assert(context.find(
      "IOSGPUScene::DepthFormat::Depth32FloatStencil8")!=
         std::string::npos);
  assert(context.find(
      "return !color.isEmpty() && !depth.isEmpty() &&")!=
         std::string::npos);
  assert(context.find(
      "next.depth = device.zbuffer(depthFormat,w,h);")!=
         std::string::npos);
  assert(ordered(context,{
      "const bool currentInventoryDepth =",
      "if(currentInventoryDepth) {",
      "{impl->linearHDRTargets.depth,1.f,Tempest::Discard}",
      "inventory.draw(encoder)"}));
  assert(context.find(
      "report.encodedPhaseDrawCount!=report.drawCount")!=
         std::string::npos);
  assert(context.find(
      "report.encodedPhaseTexturedDrawCount!=report.texturedDrawCount")!=
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
  assert(coverageHeader.find(
      "IOSMultiply2CoverageProofV1HeaderBytes = 160u")!=std::string::npos);
  assert(coverageModel.find(
      "std::byte{'M'},std::byte{'C'},std::byte{'9'},std::byte{0}")!=
         std::string::npos);
  assert(coverageModel.find("writeU16(candidate,10u,0x4c45u);")!=
         std::string::npos);
  assert(coverageModel.find("metadata.bytesPerRow!=metadata.width")!=
         std::string::npos);
  assert(coverageModel.find("metadata.sampleCount!=1u")!=
         std::string::npos);
  assert(coverageModel.find("byte>1u")!=std::string::npos);
  assert(coverageModel.find("IOSMultiply2CoverageProofError::MissingCoverage")!=
         std::string::npos);
  assert(coverageProducer.find(
      "RendererIOS-multiply2-coverage-v1.bin")!=std::string::npos);
  assert(coverageProducer.find(
      "MTLPixelFormatDepth32Float_Stencil8")!=std::string::npos);
  assert(coverageProducer.find(
      "RendererIOS.Multiply2.CausalStencil.v1")!=std::string::npos);
  assert(coverageProducer.find("RENAME_EXCL")!=std::string::npos);
  assert(cmake.find("OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1")!=
         std::string::npos);
  assert(cmake.find("OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B=1")!=
         std::string::npos);
  assert(presets.find("renderer-ios-multiply2-a-hdr")!=std::string::npos);
  assert(presets.find("renderer-ios-multiply2-b-hdr")!=std::string::npos);
  }
