#include "graphics/iosshadingprototypepipeline.h"
#include "graphics/iosshadingprototypeshaderabi.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <type_traits>
#include <utility>

namespace {

using Report = IOSShadingPrototypePipelineReport;
using Status = IOSShadingPrototypePipelineStatus;
using Mutator = void (*)(Report&) noexcept;

void contractVersion(Report& report) noexcept {
  ++report.contractVersion;
  }
void metallibAbi(Report& report) noexcept {
  ++report.offlineMetallibAbi;
  }
void libraryAvailable(Report& report) noexcept {
  report.libraryAvailable = false;
  }
void librarySameDevice(Report& report) noexcept {
  report.librarySameDevice = false;
  }
void resolvedCount(Report& report) noexcept {
  ++report.resolvedTileFunctionCount;
  }
void vertexAvailable(Report& report) noexcept {
  report.functions[0].available = false;
  }
void vertexName(Report& report) noexcept {
  report.functions[0].nameMatches = false;
  }
void vertexDevice(Report& report) noexcept {
  report.functions[0].sameDevice = false;
  }
void vertexStage(Report& report) noexcept {
  report.functions[0].stage =
      IOSShadingPrototypeFunctionStage::Fragment;
  }
void vertexConstants(Report& report) noexcept {
  report.functions[0].functionConstantCount = 1u;
  }
void fragmentConstants(Report& report) noexcept {
  report.functions[1].functionConstantCount = 2u;
  }
void constantAvailable(Report& report) noexcept {
  report.functions[1].alphaTest.available = false;
  }
void constantName(Report& report) noexcept {
  report.functions[1].alphaTest.nameMatches = false;
  }
void constantIndex(Report& report) noexcept {
  report.functions[1].alphaTest.indexMatches = false;
  }
void constantType(Report& report) noexcept {
  report.functions[1].alphaTest.boolType = false;
  }
void constantRequired(Report& report) noexcept {
  report.functions[1].alphaTest.required = false;
  }
void lightingStage(Report& report) noexcept {
  report.functions[2].stage =
      IOSShadingPrototypeFunctionStage::Fragment;
  }
void specializationAvailable(Report& report) noexcept {
  report.materialSpecializations[0].available = false;
  }
void specializationName(Report& report) noexcept {
  report.materialSpecializations[0].nameMatches = false;
  }
void specializationDevice(Report& report) noexcept {
  report.materialSpecializations[0].sameDevice = false;
  }
void specializationStage(Report& report) noexcept {
  report.materialSpecializations[0].stage =
      IOSShadingPrototypeFunctionStage::Kernel;
  }
void specializationValue(Report& report) noexcept {
  report.materialSpecializations[1].alphaTestEnabled = false;
  }

constexpr std::array<Mutator,4u> LibraryMutators = {
  contractVersion,metallibAbi,libraryAvailable,librarySameDevice,
  };

constexpr std::array<Mutator,18u> FunctionMutators = {
  resolvedCount,vertexAvailable,vertexName,vertexDevice,vertexStage,
  vertexConstants,fragmentConstants,constantAvailable,constantName,
  constantIndex,constantType,constantRequired,lightingStage,
  specializationAvailable,specializationName,specializationDevice,
  specializationStage,specializationValue,
  };

void renderAvailable(Report& report) noexcept {
  report.materialPipelines[0].available = false;
  }
void renderDevice(Report& report) noexcept {
  report.materialPipelines[0].sameDevice = false;
  }
void renderArchives(Report& report) noexcept {
  report.materialPipelines[0].binaryArchivesNil = false;
  }
void renderVertexDescriptor(Report& report) noexcept {
  report.materialPipelines[0].vertexDescriptorMatches = false;
  }
void renderColor(Report& report) noexcept {
  report.materialPipelines[0].colorAttachmentRgba8Unorm = false;
  }
void renderUnusedColors(Report& report) noexcept {
  report.materialPipelines[0].unusedColorAttachmentsInvalid = false;
  }
void renderWriteMask(Report& report) noexcept {
  report.materialPipelines[0].colorWriteMaskAll = false;
  }
void renderBlend(Report& report) noexcept {
  report.materialPipelines[0].blendingDisabled = false;
  }
void renderDepth(Report& report) noexcept {
  report.materialPipelines[0].depthStencilDisabled = false;
  }
void renderTopology(Report& report) noexcept {
  report.materialPipelines[0].triangleTopology = false;
  }
void renderAlphaToCoverage(Report& report) noexcept {
  report.materialPipelines[0].alphaToCoverageDisabled = false;
  }
void renderAlphaToOne(Report& report) noexcept {
  report.materialPipelines[0].alphaToOneDisabled = false;
  }
void renderOpaqueMode(Report& report) noexcept {
  report.materialPipelines[0].alphaTestEnabled = true;
  }
void renderAlphaMode(Report& report) noexcept {
  report.materialPipelines[1].alphaTestEnabled = false;
  }
void renderSamples(Report& report) noexcept {
  ++report.materialPipelines[0].sampleCount;
  }
void tileAvailable(Report& report) noexcept {
  report.lightingPipeline.available = false;
  }
void tileDevice(Report& report) noexcept {
  report.lightingPipeline.sameDevice = false;
  }
void tileArchives(Report& report) noexcept {
  report.lightingPipeline.binaryArchivesNil = false;
  }
void tileColor(Report& report) noexcept {
  report.lightingPipeline.colorAttachmentRgba8Unorm = false;
  }
void tileUnusedColors(Report& report) noexcept {
  report.lightingPipeline.unusedColorAttachmentsInvalid = false;
  }
void tileThreadgroup(Report& report) noexcept {
  report.lightingPipeline.threadgroupSizeMatchesTileSize = false;
  }
void tileSamples(Report& report) noexcept {
  ++report.lightingPipeline.sampleCount;
  }

constexpr std::array<Mutator,22u> PipelineMutators = {
  renderAvailable,renderDevice,renderArchives,renderVertexDescriptor,
  renderColor,renderUnusedColors,renderWriteMask,renderBlend,renderDepth,
  renderTopology,renderAlphaToCoverage,renderAlphaToOne,renderOpaqueMode,
  renderAlphaMode,renderSamples,tileAvailable,tileDevice,tileArchives,
  tileColor,tileUnusedColors,tileThreadgroup,tileSamples,
  };

void renderReflection(Report& report) noexcept {
  report.materialPipelines[0].reflectionAvailable = false;
  }
void renderBytes(Report& report) noexcept {
  ++report.materialPipelines[0].imageblockBytesPerSample;
  }
void renderVertexBindingType(Report& report) noexcept {
  report.materialPipelines[0].vertexBindings.bindings[0].type =
      IOSShadingPrototypeBindingType::Imageblock;
  }
void renderVertexBindingUsed(Report& report) noexcept {
  report.materialPipelines[0].vertexBindings.bindings[0].used = false;
  }
void renderVertexBindingCount(Report& report) noexcept {
  report.materialPipelines[0].vertexBindings.count = 0u;
  }
void renderVertexBindingsUnavailable(Report& report) noexcept {
  report.materialPipelines[0].vertexBindings.available = false;
  }
void renderFragmentCount(Report& report) noexcept {
  report.materialPipelines[0].fragmentBindings.count = 1u;
  }
void renderFragmentType(Report& report) noexcept {
  report.materialPipelines[0].fragmentBindings.bindings[0].type =
      IOSShadingPrototypeBindingType::Imageblock;
  }
void renderFragmentUsed(Report& report) noexcept {
  report.materialPipelines[0].fragmentBindings.bindings[0].used = true;
  }
void renderFragmentOverflow(Report& report) noexcept {
  report.materialPipelines[0].fragmentBindings.overflow = true;
  }
void renderTileBinding(Report& report) noexcept {
  report.materialPipelines[0].tileBindings.count = 1u;
  report.materialPipelines[0].tileBindings.bindings[0].type =
      IOSShadingPrototypeBindingType::Imageblock;
  report.materialPipelines[0].tileBindings.bindings[0].used = true;
  }
void tileReflection(Report& report) noexcept {
  report.lightingPipeline.reflectionAvailable = false;
  }
void tileBytes(Report& report) noexcept {
  ++report.lightingPipeline.imageblockBytesPerSample;
  }
void tileVertexBinding(Report& report) noexcept {
  report.lightingPipeline.vertexBindings.count = 1u;
  }
void tileFragmentBinding(Report& report) noexcept {
  report.lightingPipeline.fragmentBindings.count = 1u;
  }
void tileBindingsUnavailable(Report& report) noexcept {
  report.lightingPipeline.tileBindings.available = false;
  }
void tileBindingCount(Report& report) noexcept {
  report.lightingPipeline.tileBindings.count = 1u;
  }
void tileBindingType(Report& report) noexcept {
  report.lightingPipeline.tileBindings.bindings[1].type =
      IOSShadingPrototypeBindingType::ImageblockData;
  }
void tileBindingUsed(Report& report) noexcept {
  report.lightingPipeline.tileBindings.bindings[1].used = false;
  }
void tileBindingOverflow(Report& report) noexcept {
  report.lightingPipeline.tileBindings.overflow = true;
  }

constexpr std::array<Mutator,20u> ReflectionMutators = {
  renderReflection,renderBytes,renderVertexBindingType,
  renderVertexBindingUsed,renderVertexBindingCount,
  renderVertexBindingsUnavailable,renderFragmentCount,
  renderFragmentType,renderFragmentUsed,renderFragmentOverflow,
  renderTileBinding,tileReflection,tileBytes,tileVertexBinding,
  tileFragmentBinding,tileBindingsUnavailable,tileBindingCount,
  tileBindingType,tileBindingUsed,
  tileBindingOverflow,
  };

bool rejects(const auto& mutators, Status expected) {
  for(const Mutator mutate:mutators) {
    Report report = iosCanonicalShadingPrototypePipelineReport();
    mutate(report);
    if(iosValidateShadingPrototypePipelineReport(report)!=expected)
      return false;
    }
  return true;
  }

bool rejectsSecondSpecializationMutations() {
  const auto rejectsMutation = [](auto mutate) {
    Report report = iosCanonicalShadingPrototypePipelineReport();
    mutate(report.materialSpecializations[1]);
    return iosValidateShadingPrototypePipelineReport(report)==
           Status::FunctionMismatch;
    };
  return rejectsMutation([](auto& value) { value.available = false; }) &&
         rejectsMutation([](auto& value) { value.nameMatches = false; }) &&
         rejectsMutation([](auto& value) { value.sameDevice = false; }) &&
         rejectsMutation([](auto& value) {
           value.stage = IOSShadingPrototypeFunctionStage::Kernel;
           }) &&
         rejectsMutation([](auto& value) {
           value.alphaTestEnabled = false;
           });
  }

bool rejectsSecondMaterialPipelineMutations() {
  const auto rejectsPipeline = [](auto mutate) {
    Report report = iosCanonicalShadingPrototypePipelineReport();
    mutate(report.materialPipelines[1]);
    return iosValidateShadingPrototypePipelineReport(report)==
           Status::PipelineMismatch;
    };
  const auto rejectsReflection = [](auto mutate) {
    Report report = iosCanonicalShadingPrototypePipelineReport();
    mutate(report.materialPipelines[1]);
    return iosValidateShadingPrototypePipelineReport(report)==
           Status::ReflectionMismatch;
    };
  return rejectsPipeline([](auto& value) { value.available = false; }) &&
         rejectsPipeline([](auto& value) { value.sameDevice = false; }) &&
         rejectsPipeline([](auto& value) {
           value.binaryArchivesNil = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.vertexDescriptorMatches = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.colorAttachmentRgba8Unorm = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.unusedColorAttachmentsInvalid = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.colorWriteMaskAll = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.blendingDisabled = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.depthStencilDisabled = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.triangleTopology = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.alphaToCoverageDisabled = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.alphaToOneDisabled = false;
           }) &&
         rejectsPipeline([](auto& value) {
           value.alphaTestEnabled = false;
           }) &&
         rejectsPipeline([](auto& value) { ++value.sampleCount; }) &&
         rejectsReflection([](auto& value) {
           value.reflectionAvailable = false;
           }) &&
         rejectsReflection([](auto& value) {
           ++value.imageblockBytesPerSample;
           }) &&
         rejectsReflection([](auto& value) {
           value.vertexBindings.available = false;
           }) &&
         rejectsReflection([](auto& value) {
           value.vertexBindings.bindings[0].type =
               IOSShadingPrototypeBindingType::Imageblock;
           }) &&
         rejectsReflection([](auto& value) {
           value.vertexBindings.bindings[0].used = false;
           }) &&
         rejectsReflection([](auto& value) {
           value.vertexBindings.count = 0u;
           }) &&
         rejectsReflection([](auto& value) {
           value.fragmentBindings.count = 1u;
           }) &&
         rejectsReflection([](auto& value) {
           value.fragmentBindings.bindings[0].type =
               IOSShadingPrototypeBindingType::Imageblock;
           }) &&
         rejectsReflection([](auto& value) {
           value.fragmentBindings.bindings[0].used = true;
           }) &&
         rejectsReflection([](auto& value) {
           value.fragmentBindings.overflow = true;
           }) &&
         rejectsReflection([](auto& value) {
           value.tileBindings.count = 1u;
           });
  }

}

int main() {
  using namespace RendererIOSShadingPrototypePipeline;
  static_assert(ContractVersion==1u);
  static_assert(OfflineMetallibAbi==5u);
  static_assert(MinimumAppleGPUFamily==4u);
  static_assert(TileFunctionCount==3u);
  static_assert(TilePipelineCount==3u);
  static_assert(ForwardRuntimeFunctionCount==0u);
  static_assert(AlphaTestFunctionConstantName==
                "riosShadingPrototypeAlphaTest");
  static_assert(RendererIOSShadingPrototypeShader::FunctionNames.size()==5u);
  static_assert(RendererIOSShadingPrototypeShader::VertexFunction==
                RendererIOSShadingPrototypeShader::FunctionNames[0]);
  static_assert(
      RendererIOSShadingPrototypeShader::TileMaterialFragmentFunction==
      RendererIOSShadingPrototypeShader::FunctionNames[1]);
  static_assert(RendererIOSShadingPrototypeShader::TileLightingFunction==
                RendererIOSShadingPrototypeShader::FunctionNames[2]);
  static_assert(RendererIOSShadingPrototypeShader::ForwardLightListFunction==
                RendererIOSShadingPrototypeShader::FunctionNames[3]);
  static_assert(RendererIOSShadingPrototypeShader::ForwardFragmentFunction==
                RendererIOSShadingPrototypeShader::FunctionNames[4]);
  static_assert(RendererIOSShadingPrototypeShader::AlphaTestFunctionConstant==
                AlphaTestFunctionConstant);
  static_assert(RendererIOSShadingPrototypeShader::PositionAttribute==
                PositionAttribute);
  static_assert(RendererIOSShadingPrototypeShader::ColorAttribute==
                ColorAttribute);
  static_assert(RendererIOSShadingPrototypeShader::TileFinalColorAttachment==
                FinalColorAttachment);
  static_assert(RendererIOSShadingPrototypeShader::TileMaterialBytesPerSample==
                ExplicitMaterialBytesPerSample);
  static_assert(ExplicitMaterialBytesPerSample==4u);
  static_assert(PipelineImageblockBytesPerSample==12u);
  static_assert(static_cast<uint8_t>(Status::Ready)==0u);
  static_assert(static_cast<uint8_t>(Status::DeviceUnavailable)==1u);
  static_assert(static_cast<uint8_t>(Status::UnsupportedCapability)==2u);
  static_assert(static_cast<uint8_t>(Status::LibraryUnavailable)==3u);
  static_assert(static_cast<uint8_t>(Status::FunctionMismatch)==4u);
  static_assert(static_cast<uint8_t>(Status::PipelineCreationFailed)==5u);
  static_assert(static_cast<uint8_t>(Status::PipelineMismatch)==6u);
  static_assert(static_cast<uint8_t>(Status::ReflectionMismatch)==7u);
  static_assert(static_cast<uint8_t>(Status::InternalFailure)==8u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeFunctionStage::Unknown)==0u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeFunctionStage::Vertex)==1u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeFunctionStage::Fragment)==2u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeFunctionStage::Kernel)==3u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeBindingType::Unknown)==0u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeBindingType::ImageblockData)==1u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeBindingType::Imageblock)==2u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeBindingType::VertexBuffer)==3u);
  static_assert(std::is_aggregate_v<Report>);
  static_assert(std::is_trivially_copyable_v<Report>);
  static_assert(std::is_standard_layout_v<Report>);
  static_assert(sizeof(IOSShadingPrototypeFunctionConstantReport)==5u);
  static_assert(alignof(IOSShadingPrototypeFunctionConstantReport)==1u);
  static_assert(sizeof(IOSShadingPrototypeFunctionReport)==16u);
  static_assert(alignof(IOSShadingPrototypeFunctionReport)==4u);
  static_assert(offsetof(IOSShadingPrototypeFunctionReport,alphaTest)==8u);
  static_assert(sizeof(IOSShadingPrototypeSpecializationReport)==5u);
  static_assert(alignof(IOSShadingPrototypeSpecializationReport)==1u);
  static_assert(sizeof(IOSShadingPrototypeBindingReport)==2u);
  static_assert(alignof(IOSShadingPrototypeBindingReport)==1u);
  static_assert(sizeof(IOSShadingPrototypeBindingListReport)==12u);
  static_assert(alignof(IOSShadingPrototypeBindingListReport)==4u);
  static_assert(
      offsetof(IOSShadingPrototypeBindingListReport,count)==4u);
  static_assert(
      offsetof(IOSShadingPrototypeBindingListReport,available)==8u);
  static_assert(sizeof(IOSShadingPrototypeMaterialPipelineReport)==60u);
  static_assert(alignof(IOSShadingPrototypeMaterialPipelineReport)==4u);
  static_assert(offsetof(
                    IOSShadingPrototypeMaterialPipelineReport,
                    sampleCount)==16u);
  static_assert(offsetof(
                    IOSShadingPrototypeMaterialPipelineReport,
                    vertexBindings)==24u);
  static_assert(offsetof(
                    IOSShadingPrototypeMaterialPipelineReport,
                    fragmentBindings)==36u);
  static_assert(offsetof(
                    IOSShadingPrototypeMaterialPipelineReport,
                    tileBindings)==48u);
  static_assert(sizeof(IOSShadingPrototypeTilePipelineReport)==52u);
  static_assert(alignof(IOSShadingPrototypeTilePipelineReport)==4u);
  static_assert(offsetof(
                    IOSShadingPrototypeTilePipelineReport,
                    sampleCount)==8u);
  static_assert(offsetof(
                    IOSShadingPrototypeTilePipelineReport,
                    vertexBindings)==16u);
  static_assert(offsetof(
                    IOSShadingPrototypeTilePipelineReport,
                    fragmentBindings)==28u);
  static_assert(offsetof(
                    IOSShadingPrototypeTilePipelineReport,
                    tileBindings)==40u);
  static_assert(sizeof(Report)==252u);
  static_assert(alignof(Report)==4u);
  static_assert(offsetof(Report,functions)==20u);
  static_assert(offsetof(Report,materialSpecializations)==68u);
  static_assert(offsetof(Report,materialPipelines)==80u);
  static_assert(offsetof(Report,lightingPipeline)==200u);
  static_assert(!std::is_copy_constructible_v<
                    IOSShadingPrototypePipeline>);
  static_assert(!std::is_copy_assignable_v<
                    IOSShadingPrototypePipeline>);
  static_assert(std::is_nothrow_move_constructible_v<
                    IOSShadingPrototypePipeline>);
  static_assert(std::is_nothrow_move_assignable_v<
                    IOSShadingPrototypePipeline>);

  const Report canonical =
      iosCanonicalShadingPrototypePipelineReport();
  if(iosValidateShadingPrototypePipelineReport(canonical)!=Status::Ready)
    return 1;

  Report report = canonical;
  report.deviceAvailable = false;
  if(iosValidateShadingPrototypePipelineReport(report)!=
     Status::DeviceUnavailable)
    return 2;
  report = canonical;
  report.supportsApple4 = false;
  if(iosValidateShadingPrototypePipelineReport(report)!=
     Status::UnsupportedCapability)
    return 3;
  if(!rejects(LibraryMutators,Status::LibraryUnavailable))
    return 4;
  if(!rejects(FunctionMutators,Status::FunctionMismatch))
    return 5;
  if(!rejectsSecondSpecializationMutations())
    return 6;
  report = canonical;
  report.createdTilePipelineCount = 2u;
  if(iosValidateShadingPrototypePipelineReport(report)!=
     Status::PipelineCreationFailed)
    return 7;
  if(!rejects(PipelineMutators,Status::PipelineMismatch))
    return 8;
  if(!rejectsSecondMaterialPipelineMutations())
    return 9;
  if(!rejects(ReflectionMutators,Status::ReflectionMismatch))
    return 10;

  const std::array<std::pair<Status,std::string_view>,9u> names = {{
    {Status::Ready,"ready"},
    {Status::DeviceUnavailable,"device-unavailable"},
    {Status::UnsupportedCapability,"unsupported-capability"},
    {Status::LibraryUnavailable,"library-unavailable"},
    {Status::FunctionMismatch,"function-mismatch"},
    {Status::PipelineCreationFailed,"pipeline-creation-failed"},
    {Status::PipelineMismatch,"pipeline-mismatch"},
    {Status::ReflectionMismatch,"reflection-mismatch"},
    {Status::InternalFailure,"internal-failure"},
  }};
  for(const auto& [status,name]:names) {
    if(iosShadingPrototypePipelineStatusName(status)!=name)
      return 11;
    }
  if(iosShadingPrototypePipelineStatusName(
         static_cast<Status>(0xFFu))!=
     std::string_view("internal-failure"))
    return 12;
  return 0;
  }
