#include "iosshadingprototypeforwardpipeline.h"

#include <cstddef>

namespace {

using namespace RendererIOSShadingPrototypeForwardPipeline;

IOSShadingPrototypeForwardBindingListReport emptyBindings() noexcept {
  IOSShadingPrototypeForwardBindingListReport result;
  result.available = true;
  return result;
  }

IOSShadingPrototypeForwardBindingListReport singleBinding(
    IOSShadingPrototypeForwardFunctionStage stage,
    IOSShadingPrototypeForwardBindingSemantic semantic,
    IOSShadingPrototypeForwardBindingAccess access,
    uint32_t index) noexcept {
  IOSShadingPrototypeForwardBindingListReport result;
  result.available = true;
  result.count = 1u;
  result.bindings[0].stage = stage;
  result.bindings[0].semantic = semantic;
  result.bindings[0].nativeType =
      IOSShadingPrototypeForwardBindingNativeType::Buffer;
  result.bindings[0].access = access;
  result.bindings[0].used = true;
  result.bindings[0].index = index;
  return result;
  }

bool validFunction(
    const IOSShadingPrototypeForwardFunctionReport& function,
    IOSShadingPrototypeForwardFunctionStage expectedStage,
    bool expectsAlphaTest) noexcept {
  if(!function.available || !function.nameMatches ||
     !function.sameDevice || function.stage!=expectedStage)
    return false;
  if(!expectsAlphaTest)
    return function.functionConstantCount==0u &&
           function.alphaTest==
               IOSShadingPrototypeForwardFunctionConstantReport{};
  return function.functionConstantCount==1u &&
         function.alphaTest.available &&
         function.alphaTest.nameMatches &&
         function.alphaTest.indexMatches &&
         function.alphaTest.boolType &&
         function.alphaTest.required;
  }

bool validSpecialization(
    const IOSShadingPrototypeForwardSpecializationReport& specialization,
    bool alphaTestEnabled) noexcept {
  return specialization.available &&
         specialization.nameMatches &&
         specialization.sameDevice &&
         specialization.stage==
             IOSShadingPrototypeForwardFunctionStage::Fragment &&
         specialization.alphaTestEnabled==alphaTestEnabled;
  }

bool validComputePipeline(
    const IOSShadingPrototypeForwardComputePipelineReport& pipeline) noexcept {
  return pipeline.available &&
         pipeline.sameDevice &&
         pipeline.binaryArchivesNil &&
         pipeline.functionMatches &&
         pipeline.threadGroupSizeMultipleDisabled &&
         pipeline.maxTotalThreadsPerThreadgroupZero &&
         pipeline.stageInputDescriptorNil &&
         pipeline.indirectCommandBuffersDisabled &&
         pipeline.linkedFunctionsNil &&
         pipeline.addingBinaryFunctionsDisabled &&
         pipeline.maxCallStackDepth==1u;
  }

bool validComputeReflection(
    const IOSShadingPrototypeForwardComputePipelineReport& pipeline) noexcept {
  return pipeline.reflectionAvailable &&
         pipeline.computeBindings==
             singleBinding(
                 IOSShadingPrototypeForwardFunctionStage::Kernel,
                 IOSShadingPrototypeForwardBindingSemantic::
                     LightListBuffer,
                 IOSShadingPrototypeForwardBindingAccess::ReadWrite,
                 LightListBufferIndex);
  }

bool validRenderPipeline(
    const IOSShadingPrototypeForwardRenderPipelineReport& pipeline,
    bool alphaTestEnabled) noexcept {
  return pipeline.available &&
         pipeline.sameDevice &&
         pipeline.binaryArchivesNil &&
         pipeline.vertexDescriptorMatches &&
         pipeline.colorAttachmentRgba8Unorm &&
         pipeline.unusedColorAttachmentsInvalid &&
         pipeline.colorWriteMaskAll &&
         pipeline.blendingDisabled &&
         pipeline.depthStencilDisabled &&
         pipeline.triangleTopology &&
         pipeline.alphaToCoverageDisabled &&
         pipeline.alphaToOneDisabled &&
         pipeline.rasterizationEnabled &&
         pipeline.indirectCommandBuffersDisabled &&
         pipeline.alphaTestEnabled==alphaTestEnabled &&
         pipeline.sampleCount==1u;
  }

bool validRenderReflection(
    const IOSShadingPrototypeForwardRenderPipelineReport& pipeline) noexcept {
  return pipeline.reflectionAvailable &&
         pipeline.imageblockBytesPerSample==
             PipelineImageblockBytesPerSample &&
         pipeline.vertexBindings==
             singleBinding(
                 IOSShadingPrototypeForwardFunctionStage::Vertex,
                 IOSShadingPrototypeForwardBindingSemantic::VertexBuffer,
                 IOSShadingPrototypeForwardBindingAccess::ReadOnly,
                 VertexBufferIndex) &&
         pipeline.fragmentBindings==
             singleBinding(
                 IOSShadingPrototypeForwardFunctionStage::Fragment,
                 IOSShadingPrototypeForwardBindingSemantic::
                     LightListBuffer,
                 IOSShadingPrototypeForwardBindingAccess::ReadOnly,
                 LightListBufferIndex) &&
         pipeline.tileBindings==emptyBindings() &&
         pipeline.objectBindings==emptyBindings() &&
         pipeline.meshBindings==emptyBindings();
  }

}

IOSShadingPrototypeForwardPipelineReport
    iosCanonicalShadingPrototypeForwardPipelineReport() noexcept {
  using namespace RendererIOSShadingPrototypeForwardPipeline;

  IOSShadingPrototypeForwardPipelineReport report;
  report.contractVersion = ContractVersion;
  report.offlineMetallibAbi = OfflineMetallibAbi;
  report.deviceAvailable = true;
  report.supportsApple4 = true;
  report.libraryAvailable = true;
  report.librarySameDevice = true;
  report.resolvedFunctionCount = ResolvedFunctionCount;
  report.specializationCount = SpecializationCount;
  report.createdComputePipelineCount = ComputePipelineCount;
  report.createdRenderPipelineCount = RenderPipelineCount;

  report.functions[0].available = true;
  report.functions[0].nameMatches = true;
  report.functions[0].sameDevice = true;
  report.functions[0].stage =
      IOSShadingPrototypeForwardFunctionStage::Vertex;

  report.functions[1].available = true;
  report.functions[1].nameMatches = true;
  report.functions[1].sameDevice = true;
  report.functions[1].stage =
      IOSShadingPrototypeForwardFunctionStage::Kernel;

  report.functions[2].available = true;
  report.functions[2].nameMatches = true;
  report.functions[2].sameDevice = true;
  report.functions[2].stage =
      IOSShadingPrototypeForwardFunctionStage::Fragment;
  report.functions[2].functionConstantCount = 1u;
  report.functions[2].alphaTest.available = true;
  report.functions[2].alphaTest.nameMatches = true;
  report.functions[2].alphaTest.indexMatches = true;
  report.functions[2].alphaTest.boolType = true;
  report.functions[2].alphaTest.required = true;

  for(std::size_t i=0u;
      i<report.fragmentSpecializations.size(); ++i) {
    auto& specialization = report.fragmentSpecializations[i];
    specialization.available = true;
    specialization.nameMatches = true;
    specialization.sameDevice = true;
    specialization.stage =
        IOSShadingPrototypeForwardFunctionStage::Fragment;
    specialization.alphaTestEnabled = i==1u;
    }

  report.computePipeline.available = true;
  report.computePipeline.sameDevice = true;
  report.computePipeline.reflectionAvailable = true;
  report.computePipeline.binaryArchivesNil = true;
  report.computePipeline.functionMatches = true;
  report.computePipeline.threadGroupSizeMultipleDisabled = true;
  report.computePipeline.maxTotalThreadsPerThreadgroupZero = true;
  report.computePipeline.stageInputDescriptorNil = true;
  report.computePipeline.indirectCommandBuffersDisabled = true;
  report.computePipeline.linkedFunctionsNil = true;
  report.computePipeline.addingBinaryFunctionsDisabled = true;
  report.computePipeline.maxCallStackDepth = 1u;
  report.computePipeline.computeBindings =
      singleBinding(
          IOSShadingPrototypeForwardFunctionStage::Kernel,
          IOSShadingPrototypeForwardBindingSemantic::LightListBuffer,
          IOSShadingPrototypeForwardBindingAccess::ReadWrite,
          LightListBufferIndex);

  for(std::size_t i=0u; i<report.renderPipelines.size(); ++i) {
    auto& pipeline = report.renderPipelines[i];
    pipeline.available = true;
    pipeline.sameDevice = true;
    pipeline.reflectionAvailable = true;
    pipeline.binaryArchivesNil = true;
    pipeline.vertexDescriptorMatches = true;
    pipeline.colorAttachmentRgba8Unorm = true;
    pipeline.unusedColorAttachmentsInvalid = true;
    pipeline.colorWriteMaskAll = true;
    pipeline.blendingDisabled = true;
    pipeline.depthStencilDisabled = true;
    pipeline.triangleTopology = true;
    pipeline.alphaToCoverageDisabled = true;
    pipeline.alphaToOneDisabled = true;
    pipeline.rasterizationEnabled = true;
    pipeline.indirectCommandBuffersDisabled = true;
    pipeline.alphaTestEnabled = i==1u;
    pipeline.sampleCount = 1u;
    pipeline.imageblockBytesPerSample =
        PipelineImageblockBytesPerSample;
    pipeline.vertexBindings =
        singleBinding(
            IOSShadingPrototypeForwardFunctionStage::Vertex,
            IOSShadingPrototypeForwardBindingSemantic::VertexBuffer,
            IOSShadingPrototypeForwardBindingAccess::ReadOnly,
            VertexBufferIndex);
    pipeline.fragmentBindings =
        singleBinding(
            IOSShadingPrototypeForwardFunctionStage::Fragment,
            IOSShadingPrototypeForwardBindingSemantic::LightListBuffer,
            IOSShadingPrototypeForwardBindingAccess::ReadOnly,
            LightListBufferIndex);
    pipeline.tileBindings = emptyBindings();
    pipeline.objectBindings = emptyBindings();
    pipeline.meshBindings = emptyBindings();
    }
  return report;
  }

IOSShadingPrototypeForwardPipelineStatus
    iosValidateShadingPrototypeForwardPipelineReport(
        const IOSShadingPrototypeForwardPipelineReport& report) noexcept {
  using namespace RendererIOSShadingPrototypeForwardPipeline;
  using Status = IOSShadingPrototypeForwardPipelineStatus;

  if(!report.deviceAvailable)
    return Status::DeviceUnavailable;
  if(!report.supportsApple4)
    return Status::UnsupportedCapability;
  if(report.contractVersion!=ContractVersion ||
     report.offlineMetallibAbi!=OfflineMetallibAbi ||
     !report.libraryAvailable || !report.librarySameDevice)
    return Status::LibraryUnavailable;
  if(report.resolvedFunctionCount!=ResolvedFunctionCount ||
     report.specializationCount!=SpecializationCount ||
     !validFunction(
         report.functions[0],
         IOSShadingPrototypeForwardFunctionStage::Vertex,false) ||
     !validFunction(
         report.functions[1],
         IOSShadingPrototypeForwardFunctionStage::Kernel,false) ||
     !validFunction(
         report.functions[2],
         IOSShadingPrototypeForwardFunctionStage::Fragment,true) ||
     !validSpecialization(report.fragmentSpecializations[0],false) ||
     !validSpecialization(report.fragmentSpecializations[1],true))
    return Status::FunctionMismatch;
  if(report.createdComputePipelineCount!=ComputePipelineCount ||
     report.createdRenderPipelineCount!=RenderPipelineCount)
    return Status::PipelineCreationFailed;
  if(!validComputePipeline(report.computePipeline))
    return Status::PipelineMismatch;
  for(std::size_t i=0u; i<report.renderPipelines.size(); ++i) {
    if(!validRenderPipeline(report.renderPipelines[i],i==1u))
      return Status::PipelineMismatch;
    }
  if(!validComputeReflection(report.computePipeline))
    return Status::ReflectionMismatch;
  for(const auto& pipeline:report.renderPipelines) {
    if(!validRenderReflection(pipeline))
      return Status::ReflectionMismatch;
    }
  return Status::Ready;
  }

const char* iosShadingPrototypeForwardPipelineStatusName(
    IOSShadingPrototypeForwardPipelineStatus status) noexcept {
  using Status = IOSShadingPrototypeForwardPipelineStatus;
  switch(status) {
    case Status::Ready:
      return "ready";
    case Status::DeviceUnavailable:
      return "device-unavailable";
    case Status::UnsupportedCapability:
      return "unsupported-capability";
    case Status::LibraryUnavailable:
      return "library-unavailable";
    case Status::FunctionMismatch:
      return "function-mismatch";
    case Status::PipelineCreationFailed:
      return "pipeline-creation-failed";
    case Status::PipelineMismatch:
      return "pipeline-mismatch";
    case Status::ReflectionMismatch:
      return "reflection-mismatch";
    case Status::InternalFailure:
      return "internal-failure";
    }
  return "internal-failure";
  }
