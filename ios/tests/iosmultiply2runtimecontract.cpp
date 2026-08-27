#include <cassert>
#include <array>
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
  assert(count(header,"Report encodePreparedMultiply2Causal(")==1u);
  assert(count(header,"Report encodePreparedMultiply2Continuation(")==1u);
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
  assert(count(scene,"&Impl::encodeMultiply2")==1u);
  assert(ordered(scene,{
      "enum class NativeMultiply2EncodeMode : uint8_t {",
      "CaptureProof,",
      "Continuation,",
      "explicit NativeMultiply2Context(",
      "const NativeMultiply2EncodeMode mode;",
      "Impl::NativeMultiply2EncodeMode::CaptureProof",
      "Impl::NativeMultiply2EncodeMode::Continuation"}));
  assert(scene.find(
      "continuation && context.hdrProofBuffer==nil &&\n"
      "          context.coverageBuffer==nil && context.hdrBytesPerRow==0u &&\n"
      "          context.coverageBytesPerRow==0u && context.sceneMarker.empty() &&\n"
      "          context.proofMarker.empty()")!=std::string::npos);
  assert(ordered(scene,{
      "first.colorAttachments[0].texture = sceneHDR;",
      "first.depthAttachment.texture = depthStencil;",
      "first.stencilAttachment.texture = depthStencil;",
      "first.stencilAttachment.clearStencil = 0u;",
      "@\"RendererIOS.Multiply2.BaseAndCausal.v1\"",
      "context.scene->baseDepthState,0u",
      "context.scene->multiply2DepthState,1u",
      "context.prepared->markNativeBaseMultiplyCompleted();",
      "if(captureProof) {",
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
  assert(count(scene,"@\"RendererIOS.Multiply2.BaseAndCausal.v1\"")==1u);
  assert(count(scene,"@\"RendererIOS.HDRProofCopy.Multiply2.v1\"")==1u);
  assert(count(scene,
               "@\"RendererIOS.Multiply2.CoverageStencilCopy.v1\"")==2u);
  assert(count(scene,
               "@\"RendererIOS.Multiply2.AdditiveAfterProof.v1\"")==2u);
  assert(count(scene,
               "@\"RendererIOS.Multiply2.BaseAndContinuation.v1\"")==3u);
  assert(count(scene,
               "@\"RendererIOS.Multiply2.AdditiveContinuation.v1\"")==3u);
  assert(ordered(scene,{
      "bool IOSGPUScene::Impl::continuationDepthStencilForSceneHDR(",
      "sceneHDR.device!=device",
      "sceneHDR.pixelFormat!=MTLPixelFormatRG11B10Float",
      "target.device==device",
      "target.pixelFormat==MTLPixelFormatDepth32Float_Stencil8",
      "target.width==sceneHDR.width",
      "target.height==sceneHDR.height",
      "target.sampleCount==1u",
      "target.storageMode==MTLStorageModePrivate",
      "target.cpuCacheMode==MTLCPUCacheModeDefaultCache",
      "target.hazardTrackingMode==MTLHazardTrackingModeTracked",
      "target.usage==MTLTextureUsageRenderTarget",
      "if(target==nil) {",
      "textureDescriptor.pixelFormat =\n"
      "            MTLPixelFormatDepth32Float_Stencil8;",
      "textureDescriptor.width = sceneHDR.width;",
      "textureDescriptor.height = sceneHDR.height;",
      "textureDescriptor.sampleCount = 1u;",
      "MTLResourceCPUCacheModeDefaultCache |",
      "MTLResourceStorageModePrivate |",
      "MTLResourceHazardTrackingModeTracked;",
      "textureDescriptor.usage = MTLTextureUsageRenderTarget;",
      "[device newTextureWithDescriptor:textureDescriptor]",
      "multiply2ContinuationDepthStencil = allocated.relinquish();",
      "else if(!validContinuationTarget(target)) {",
      "return false;"}));
  assert(count(scene,
               "multiply2ContinuationDepthStencil = allocated.relinquish();")==
         1u);
  assert(count(scene,"[multiply2ContinuationDepthStencil release];")==1u);
  assert(scene.find(
      "depthStencil==\n"
      "                  (id<MTLTexture>)context.scene->\n"
      "                      multiply2ContinuationDepthStencil")!=
         std::string::npos);
  assert(scene.find(
      "context.report.encodedPhaseDrawCount!=context.report.drawCount")!=
         std::string::npos);
  assert(scene.find(
      "context.report.encodedPhaseTexturedDrawCount!=\n"
      "           context.report.texturedDrawCount")!=std::string::npos);
  assert(scene.find(
      "recordPlannedDrawnFailure(context.report);\n"
      "      if(context.prepared!=nullptr)\n"
      "        context.prepared->ready = false;")!=std::string::npos);

  const std::array<std::string_view,7u> hdrStates = {
      "Disabled","Armed","Encoded","Submitted","Completed","Published",
      "Failed"};
  const std::array<std::string_view,7u> coverageStates = {
      "Disabled","Armed","Prepared","Encoded","Submitted","Published",
      "Failed"};
  std::size_t capturePairs = 0u;
  std::size_t continuationPairs = 0u;
  std::size_t rejectedPairs = 0u;
  for(const auto hdr:hdrStates) {
    for(const auto coverage:coverageStates) {
      if(hdr=="Armed" && coverage=="Armed")
        ++capturePairs;
      else if((hdr=="Submitted" && coverage=="Submitted") ||
              (hdr=="Published" && coverage=="Published"))
        ++continuationPairs;
      else
        ++rejectedPairs;
      }
    }
  assert(capturePairs==1u);
  assert(continuationPairs==2u);
  assert(rejectedPairs==46u);
  assert(count(context,
               "return IOSMultiply2SceneAdmission::CaptureProof;")==1u);
  assert(count(context,
               "return IOSMultiply2SceneAdmission::Continuation;")==1u);
  assert(count(context,
               "return IOSMultiply2SceneAdmission::Reject;")==1u);
  assert(ordered(context,{
      "const bool multiply2CausalProducersPresent =",
      "? impl->linearHDRProof->state()\n"
      "              : IOSLinearHDRProofProducerState::Disabled;",
      "? impl->multiply2Coverage->state()\n"
      "              : IOSMultiply2CoverageProducerState::Disabled;",
      "const IOSMultiply2SceneAdmission multiply2Admission =",
      "multiply2Admission==IOSMultiply2SceneAdmission::CaptureProof;",
      "if(multiply2Admission==IOSMultiply2SceneAdmission::Reject)"}));
  assert(ordered(context,{
      "constexpr IOSMultiply2SceneAdmission iosMultiply2SceneAdmission(",
      "hdr==IOSLinearHDRProofProducerState::Armed",
      "coverage==IOSMultiply2CoverageProducerState::Armed",
      "return IOSMultiply2SceneAdmission::CaptureProof;",
      "hdr==IOSLinearHDRProofProducerState::Submitted",
      "coverage==IOSMultiply2CoverageProducerState::Submitted",
      "hdr==IOSLinearHDRProofProducerState::Published",
      "coverage==IOSMultiply2CoverageProducerState::Published",
      "return IOSMultiply2SceneAdmission::Continuation;",
      "return IOSMultiply2SceneAdmission::Reject;",
      "iosMultiply2SceneAdmission(\n"
      "                linearHDRProofState,multiply2CoverageState);",
      "if(multiply2Admission==IOSMultiply2SceneAdmission::Reject)",
      "impl->gpuScene->encodePreparedMultiply2Causal(",
      "impl->gpuScene->encodePreparedMultiply2Continuation("}));
  const std::string_view lifecycleStartToken =
      "#if defined(OPENGOTHIC_RENDERER_IOS_MULTIPLY2_LIFECYCLE)\n"
      "        IOSGPUScene::Report report;";
  const std::size_t lifecycleStart = context.find(lifecycleStartToken);
  assert(lifecycleStart!=std::string::npos);
  const std::size_t lifecycleEnd = context.find("#else",lifecycleStart);
  assert(lifecycleEnd!=std::string::npos);
  const std::string_view lifecycleEncoding(
      context.data()+lifecycleStart,lifecycleEnd-lifecycleStart);
  assert(lifecycleEncoding.find("encodePreparedMultiply2Causal(")!=
         std::string_view::npos);
  assert(lifecycleEncoding.find("encodePreparedMultiply2Continuation(")!=
         std::string_view::npos);
  assert(lifecycleEncoding.find("encodePrepared(encoder,preparedScene)")==
         std::string_view::npos);
  assert(lifecycleEncoding.find("linearHDRTargets.depth")==
         std::string_view::npos);
  assert(lifecycleEncoding.find("setFramebuffer(")==std::string_view::npos);
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
  assert(coverageProducer.find("fail(\"payload-invalid-byte\");")!=
         std::string::npos);
  assert(coverageProducer.find("fail(\"payload-missing-coverage\");")!=
         std::string::npos);
  assert(coverageProducer.find("fail(\"payload-build\");")!=
         std::string::npos);
  assert(cmake.find("OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_A=1")!=
         std::string::npos);
  assert(cmake.find("OPENGOTHIC_RENDERER_IOS_MULTIPLY2_CAUSAL_B=1")!=
         std::string::npos);
  assert(presets.find("renderer-ios-multiply2-a-hdr")!=std::string::npos);
  assert(presets.find("renderer-ios-multiply2-b-hdr")!=std::string::npos);
  }
