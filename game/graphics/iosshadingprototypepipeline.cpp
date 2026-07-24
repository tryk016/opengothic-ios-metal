#include "iosshadingprototypepipeline.h"

#include <cstddef>

namespace {

using namespace RendererIOSShadingPrototypePipeline;

IOSShadingPrototypeBindingListReport emptyBindings() noexcept {
  IOSShadingPrototypeBindingListReport result;
  result.available = true;
  return result;
  }

IOSShadingPrototypeBindingListReport singleBinding(
    IOSShadingPrototypeBindingType type) noexcept {
  IOSShadingPrototypeBindingListReport result;
  result.available = true;
  result.count = 1u;
  result.bindings[0].type = type;
  result.bindings[0].used = true;
  return result;
  }

IOSShadingPrototypeBindingListReport imageblockBindings() noexcept {
  IOSShadingPrototypeBindingListReport result;
  result.available = true;
  result.count = 2u;
  for(auto& binding:result.bindings) {
    binding.type = IOSShadingPrototypeBindingType::Imageblock;
    binding.used = true;
    }
  return result;
  }

bool validFunction(
    const IOSShadingPrototypeFunctionReport& function,
    IOSShadingPrototypeFunctionStage expectedStage,
    bool expectsAlphaTest) noexcept {
  if(!function.available || !function.nameMatches ||
     !function.sameDevice || function.stage!=expectedStage)
    return false;

  if(!expectsAlphaTest)
    return function.functionConstantCount==0u &&
           function.alphaTest==
               IOSShadingPrototypeFunctionConstantReport{};

  return function.functionConstantCount==1u &&
         function.alphaTest.available &&
         function.alphaTest.nameMatches &&
         function.alphaTest.indexMatches &&
         function.alphaTest.boolType &&
         function.alphaTest.required;
  }

bool validSpecialization(
    const IOSShadingPrototypeSpecializationReport& specialization,
    bool alphaTestEnabled) noexcept {
  return specialization.available &&
         specialization.nameMatches &&
         specialization.sameDevice &&
         specialization.stage==
             IOSShadingPrototypeFunctionStage::Fragment &&
         specialization.alphaTestEnabled==alphaTestEnabled;
  }

bool validBindingList(
    const IOSShadingPrototypeBindingListReport& actual,
    const IOSShadingPrototypeBindingListReport& expected) noexcept {
  return actual==expected;
  }

bool validMaterialPipeline(
    const IOSShadingPrototypeMaterialPipelineReport& pipeline,
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
         pipeline.alphaTestEnabled==alphaTestEnabled &&
         pipeline.sampleCount==1u;
  }

bool validMaterialReflection(
    const IOSShadingPrototypeMaterialPipelineReport& pipeline) noexcept {
  return pipeline.reflectionAvailable &&
         pipeline.imageblockBytesPerSample==
             PipelineImageblockBytesPerSample &&
         validBindingList(
             pipeline.vertexBindings,
             singleBinding(
                 IOSShadingPrototypeBindingType::VertexBuffer)) &&
         validBindingList(pipeline.fragmentBindings,emptyBindings()) &&
         validBindingList(pipeline.tileBindings,emptyBindings());
  }

bool validTilePipeline(
    const IOSShadingPrototypeTilePipelineReport& pipeline) noexcept {
  return pipeline.available &&
         pipeline.sameDevice &&
         pipeline.binaryArchivesNil &&
         pipeline.colorAttachmentRgba8Unorm &&
         pipeline.unusedColorAttachmentsInvalid &&
         pipeline.threadgroupSizeMatchesTileSize &&
         pipeline.sampleCount==1u;
  }

bool validTileReflection(
    const IOSShadingPrototypeTilePipelineReport& pipeline) noexcept {
  return pipeline.reflectionAvailable &&
         pipeline.imageblockBytesPerSample==
             PipelineImageblockBytesPerSample &&
         validBindingList(pipeline.vertexBindings,emptyBindings()) &&
         validBindingList(pipeline.fragmentBindings,emptyBindings()) &&
         validBindingList(
             pipeline.tileBindings,imageblockBindings());
  }

}

IOSShadingPrototypePipelineReport
    iosCanonicalShadingPrototypePipelineReport() noexcept {
  IOSShadingPrototypePipelineReport report;
  report.contractVersion = ContractVersion;
  report.offlineMetallibAbi = OfflineMetallibAbi;
  report.deviceAvailable = true;
  report.supportsApple4 = true;
  report.libraryAvailable = true;
  report.librarySameDevice = true;
  report.resolvedTileFunctionCount = TileFunctionCount;
  report.createdTilePipelineCount = TilePipelineCount;

  report.functions[0].available = true;
  report.functions[0].nameMatches = true;
  report.functions[0].sameDevice = true;
  report.functions[0].stage =
      IOSShadingPrototypeFunctionStage::Vertex;

  report.functions[1].available = true;
  report.functions[1].nameMatches = true;
  report.functions[1].sameDevice = true;
  report.functions[1].stage =
      IOSShadingPrototypeFunctionStage::Fragment;
  report.functions[1].functionConstantCount = 1u;
  report.functions[1].alphaTest.available = true;
  report.functions[1].alphaTest.nameMatches = true;
  report.functions[1].alphaTest.indexMatches = true;
  report.functions[1].alphaTest.boolType = true;
  report.functions[1].alphaTest.required = true;

  report.functions[2].available = true;
  report.functions[2].nameMatches = true;
  report.functions[2].sameDevice = true;
  report.functions[2].stage =
      IOSShadingPrototypeFunctionStage::Kernel;

  report.materialSpecializations[0].available = true;
  report.materialSpecializations[0].nameMatches = true;
  report.materialSpecializations[0].sameDevice = true;
  report.materialSpecializations[0].stage =
      IOSShadingPrototypeFunctionStage::Fragment;
  report.materialSpecializations[0].alphaTestEnabled = false;
  report.materialSpecializations[1] =
      report.materialSpecializations[0];
  report.materialSpecializations[1].alphaTestEnabled = true;

  for(std::size_t i=0u; i<report.materialPipelines.size(); ++i) {
    auto& pipeline = report.materialPipelines[i];
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
    pipeline.alphaTestEnabled = i==1u;
    pipeline.sampleCount = 1u;
    pipeline.imageblockBytesPerSample =
        PipelineImageblockBytesPerSample;
    pipeline.vertexBindings =
        singleBinding(
            IOSShadingPrototypeBindingType::VertexBuffer);
    pipeline.fragmentBindings = emptyBindings();
    pipeline.tileBindings = emptyBindings();
    }

  report.lightingPipeline.available = true;
  report.lightingPipeline.sameDevice = true;
  report.lightingPipeline.reflectionAvailable = true;
  report.lightingPipeline.binaryArchivesNil = true;
  report.lightingPipeline.colorAttachmentRgba8Unorm = true;
  report.lightingPipeline.unusedColorAttachmentsInvalid = true;
  report.lightingPipeline.threadgroupSizeMatchesTileSize = true;
  report.lightingPipeline.sampleCount = 1u;
  report.lightingPipeline.imageblockBytesPerSample =
      PipelineImageblockBytesPerSample;
  report.lightingPipeline.vertexBindings = emptyBindings();
  report.lightingPipeline.fragmentBindings = emptyBindings();
  report.lightingPipeline.tileBindings = imageblockBindings();
  return report;
  }

IOSShadingPrototypePipelineStatus
    iosValidateShadingPrototypePipelineReport(
        const IOSShadingPrototypePipelineReport& report) noexcept {
  if(!report.deviceAvailable)
    return IOSShadingPrototypePipelineStatus::DeviceUnavailable;
  if(!report.supportsApple4)
    return IOSShadingPrototypePipelineStatus::UnsupportedCapability;
  if(report.contractVersion!=ContractVersion ||
     report.offlineMetallibAbi!=OfflineMetallibAbi ||
     !report.libraryAvailable || !report.librarySameDevice)
    return IOSShadingPrototypePipelineStatus::LibraryUnavailable;
  if(report.resolvedTileFunctionCount!=TileFunctionCount ||
     !validFunction(
         report.functions[0],
         IOSShadingPrototypeFunctionStage::Vertex,false) ||
     !validFunction(
         report.functions[1],
         IOSShadingPrototypeFunctionStage::Fragment,true) ||
     !validFunction(
         report.functions[2],
         IOSShadingPrototypeFunctionStage::Kernel,false) ||
     !validSpecialization(report.materialSpecializations[0],false) ||
     !validSpecialization(report.materialSpecializations[1],true))
    return IOSShadingPrototypePipelineStatus::FunctionMismatch;
  if(report.createdTilePipelineCount!=TilePipelineCount)
    return IOSShadingPrototypePipelineStatus::PipelineCreationFailed;
  for(std::size_t i=0u; i<report.materialPipelines.size(); ++i) {
    const auto& pipeline = report.materialPipelines[i];
    if(!validMaterialPipeline(pipeline,i==1u))
      return IOSShadingPrototypePipelineStatus::PipelineMismatch;
    if(!validMaterialReflection(pipeline))
      return IOSShadingPrototypePipelineStatus::ReflectionMismatch;
    }
  if(!validTilePipeline(report.lightingPipeline))
    return IOSShadingPrototypePipelineStatus::PipelineMismatch;
  if(!validTileReflection(report.lightingPipeline))
    return IOSShadingPrototypePipelineStatus::ReflectionMismatch;
  return IOSShadingPrototypePipelineStatus::Ready;
  }

const char* iosShadingPrototypePipelineStatusName(
    IOSShadingPrototypePipelineStatus status) noexcept {
  switch(status) {
    case IOSShadingPrototypePipelineStatus::Ready:
      return "ready";
    case IOSShadingPrototypePipelineStatus::DeviceUnavailable:
      return "device-unavailable";
    case IOSShadingPrototypePipelineStatus::UnsupportedCapability:
      return "unsupported-capability";
    case IOSShadingPrototypePipelineStatus::LibraryUnavailable:
      return "library-unavailable";
    case IOSShadingPrototypePipelineStatus::FunctionMismatch:
      return "function-mismatch";
    case IOSShadingPrototypePipelineStatus::PipelineCreationFailed:
      return "pipeline-creation-failed";
    case IOSShadingPrototypePipelineStatus::PipelineMismatch:
      return "pipeline-mismatch";
    case IOSShadingPrototypePipelineStatus::ReflectionMismatch:
      return "reflection-mismatch";
    case IOSShadingPrototypePipelineStatus::InternalFailure:
      return "internal-failure";
    }
  return "internal-failure";
  }
