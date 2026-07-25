#include "graphics/iosshadingprototypeforwardpipeline.h"
#include "graphics/iosshadingprototypeshaderabi.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <type_traits>
#include <utility>

namespace {

using Report = IOSShadingPrototypeForwardPipelineReport;
using Status = IOSShadingPrototypeForwardPipelineStatus;
namespace Shader = RendererIOSShadingPrototypeShader;

template<class Mutate>
bool rejects(Mutate mutate, Status expected, uint32_t& mutations) {
  Report report = iosCanonicalShadingPrototypeForwardPipelineReport();
  mutate(report);
  ++mutations;
  return iosValidateShadingPrototypeForwardPipelineReport(report)==
         expected;
  }

template<class Mutate>
bool acceptsRuntimeTelemetry(Mutate mutate, uint32_t& mutations) {
  Report report = iosCanonicalShadingPrototypeForwardPipelineReport();
  mutate(report);
  ++mutations;
  return iosValidateShadingPrototypeForwardPipelineReport(report)==
         Status::Ready;
  }

template<class Select>
bool rejectsFunction(
    Select select,
    Status expected,
    uint32_t& mutations) {
  const auto reject = [&](auto mutate) {
    return rejects(
        [&](Report& report) { mutate(select(report)); },
        expected,mutations);
    };
  return reject([](auto& value) { value.available = !value.available; }) &&
         reject([](auto& value) {
           value.nameMatches = !value.nameMatches;
           }) &&
         reject([](auto& value) {
           value.sameDevice = !value.sameDevice;
           }) &&
         reject([](auto& value) {
           value.stage =
               IOSShadingPrototypeForwardFunctionStage::Unknown;
           }) &&
         reject([](auto& value) { ++value.functionConstantCount; }) &&
         reject([](auto& value) {
           value.alphaTest.available = !value.alphaTest.available;
           }) &&
         reject([](auto& value) {
           value.alphaTest.nameMatches =
               !value.alphaTest.nameMatches;
           }) &&
         reject([](auto& value) {
           value.alphaTest.indexMatches =
               !value.alphaTest.indexMatches;
           }) &&
         reject([](auto& value) {
           value.alphaTest.boolType = !value.alphaTest.boolType;
           }) &&
         reject([](auto& value) {
           value.alphaTest.required = !value.alphaTest.required;
           });
  }

template<class Select>
bool rejectsSpecialization(
    Select select,
    uint32_t& mutations) {
  const auto reject = [&](auto mutate) {
    return rejects(
        [&](Report& report) { mutate(select(report)); },
        Status::FunctionMismatch,mutations);
    };
  return reject([](auto& value) { value.available = !value.available; }) &&
         reject([](auto& value) {
           value.nameMatches = !value.nameMatches;
           }) &&
         reject([](auto& value) {
           value.sameDevice = !value.sameDevice;
           }) &&
         reject([](auto& value) {
           value.stage =
               IOSShadingPrototypeForwardFunctionStage::Unknown;
           }) &&
         reject([](auto& value) {
           value.alphaTestEnabled = !value.alphaTestEnabled;
           });
  }

template<class Select>
bool rejectsBindingList(
    Select select,
    uint32_t& mutations) {
  const auto reject = [&](auto mutate) {
    return rejects(
        [&](Report& report) { mutate(select(report)); },
        Status::ReflectionMismatch,mutations);
    };
  return reject([](auto& value) {
           value.bindings[0].stage =
               value.bindings[0].stage==
                       IOSShadingPrototypeForwardFunctionStage::Unknown
                   ? IOSShadingPrototypeForwardFunctionStage::Vertex
                   : IOSShadingPrototypeForwardFunctionStage::Unknown;
           }) &&
         reject([](auto& value) {
           value.bindings[0].semantic =
               value.bindings[0].semantic==
                       IOSShadingPrototypeForwardBindingSemantic::Unknown
                   ? IOSShadingPrototypeForwardBindingSemantic::
                         VertexBuffer
                   : IOSShadingPrototypeForwardBindingSemantic::Unknown;
           }) &&
         reject([](auto& value) {
           value.bindings[0].nativeType =
               value.bindings[0].nativeType==
                       IOSShadingPrototypeForwardBindingNativeType::Unknown
                   ? IOSShadingPrototypeForwardBindingNativeType::Buffer
                   : IOSShadingPrototypeForwardBindingNativeType::Unknown;
           }) &&
         reject([](auto& value) {
           value.bindings[0].access =
               value.bindings[0].access==
                       IOSShadingPrototypeForwardBindingAccess::Unknown
                   ? IOSShadingPrototypeForwardBindingAccess::ReadOnly
                   : IOSShadingPrototypeForwardBindingAccess::Unknown;
           }) &&
         reject([](auto& value) {
           value.bindings[0].used = !value.bindings[0].used;
           }) &&
         reject([](auto& value) { ++value.bindings[0].index; }) &&
         reject([](auto& value) { ++value.count; }) &&
         reject([](auto& value) {
           value.available = !value.available;
           }) &&
         reject([](auto& value) {
           value.overflow = !value.overflow;
           });
  }

bool rejectsTopLevel(uint32_t& mutations) {
  return rejects(
             [](Report& report) { report.deviceAvailable = false; },
             Status::DeviceUnavailable,mutations) &&
         rejects(
             [](Report& report) { report.supportsApple4 = false; },
             Status::UnsupportedCapability,mutations) &&
         rejects(
             [](Report& report) { ++report.contractVersion; },
             Status::LibraryUnavailable,mutations) &&
         rejects(
             [](Report& report) { ++report.offlineMetallibAbi; },
             Status::LibraryUnavailable,mutations) &&
         rejects(
             [](Report& report) { report.libraryAvailable = false; },
             Status::LibraryUnavailable,mutations) &&
         rejects(
             [](Report& report) { report.librarySameDevice = false; },
             Status::LibraryUnavailable,mutations) &&
         rejects(
             [](Report& report) { ++report.resolvedFunctionCount; },
             Status::FunctionMismatch,mutations) &&
         rejects(
             [](Report& report) { ++report.specializationCount; },
             Status::FunctionMismatch,mutations) &&
         rejectsFunction(
             [](Report& report) -> auto& {
               return report.functions[0];
               },
             Status::FunctionMismatch,mutations) &&
         rejectsFunction(
             [](Report& report) -> auto& {
               return report.functions[1];
               },
             Status::FunctionMismatch,mutations) &&
         rejectsFunction(
             [](Report& report) -> auto& {
               return report.functions[2];
               },
             Status::FunctionMismatch,mutations) &&
         rejectsSpecialization(
             [](Report& report) -> auto& {
               return report.fragmentSpecializations[0];
               },
             mutations) &&
         rejectsSpecialization(
             [](Report& report) -> auto& {
               return report.fragmentSpecializations[1];
               },
             mutations) &&
         rejects(
             [](Report& report) {
               ++report.createdComputePipelineCount;
               },
             Status::PipelineCreationFailed,mutations) &&
         rejects(
             [](Report& report) {
               ++report.createdRenderPipelineCount;
               },
             Status::PipelineCreationFailed,mutations);
  }

bool rejectsComputePipeline(uint32_t& mutations) {
  const auto rejectPipeline = [&](auto mutate) {
    return rejects(
        [&](Report& report) { mutate(report.computePipeline); },
        Status::PipelineMismatch,mutations);
    };
  const auto rejectReflection = [&](auto mutate) {
    return rejects(
        [&](Report& report) { mutate(report.computePipeline); },
        Status::ReflectionMismatch,mutations);
    };
  return rejectPipeline([](auto& value) {
           value.available = !value.available;
           }) &&
         rejectPipeline([](auto& value) {
           value.sameDevice = !value.sameDevice;
           }) &&
         rejectPipeline([](auto& value) {
           value.binaryArchivesNil = !value.binaryArchivesNil;
           }) &&
         rejectPipeline([](auto& value) {
           value.functionMatches = !value.functionMatches;
           }) &&
         rejectPipeline([](auto& value) {
           value.threadGroupSizeMultipleDisabled =
               !value.threadGroupSizeMultipleDisabled;
           }) &&
         rejectPipeline([](auto& value) {
           value.maxTotalThreadsPerThreadgroupZero =
               !value.maxTotalThreadsPerThreadgroupZero;
           }) &&
         rejectPipeline([](auto& value) {
           value.stageInputDescriptorEmpty =
               !value.stageInputDescriptorEmpty;
           }) &&
         rejectPipeline([](auto& value) {
           value.indirectCommandBuffersDisabled =
               !value.indirectCommandBuffersDisabled;
           }) &&
         rejectPipeline([](auto& value) {
           value.linkedFunctionsEmpty =
               !value.linkedFunctionsEmpty;
           }) &&
         rejectPipeline([](auto& value) {
           value.addingBinaryFunctionsDisabled =
               !value.addingBinaryFunctionsDisabled;
           }) &&
         rejectPipeline([](auto& value) {
           ++value.maxCallStackDepth;
           }) &&
         rejectReflection([](auto& value) {
           value.reflectionAvailable = !value.reflectionAvailable;
           }) &&
         rejectsBindingList(
             [](Report& report) -> auto& {
               return report.computePipeline.computeBindings;
               },
             mutations);
  }

bool respectsGlobalPipelineBeforeReflectionPrecedence() {
  Report report = iosCanonicalShadingPrototypeForwardPipelineReport();
  report.computePipeline.reflectionAvailable = false;
  report.renderPipelines[1].blendingDisabled = false;
  if(iosValidateShadingPrototypeForwardPipelineReport(report)!=
     Status::PipelineMismatch)
    return false;
  report.renderPipelines[1].blendingDisabled = true;
  if(iosValidateShadingPrototypeForwardPipelineReport(report)!=
     Status::ReflectionMismatch)
    return false;

  report = iosCanonicalShadingPrototypeForwardPipelineReport();
  report.renderPipelines[0].reflectionAvailable = false;
  report.renderPipelines[1].rasterizationEnabled = false;
  if(iosValidateShadingPrototypeForwardPipelineReport(report)!=
     Status::PipelineMismatch)
    return false;
  report.renderPipelines[1].rasterizationEnabled = true;
  return iosValidateShadingPrototypeForwardPipelineReport(report)==
         Status::ReflectionMismatch;
  }

bool respectsPartialNativeBuildPrecedence() {
  Report report = iosCanonicalShadingPrototypeForwardPipelineReport();
  report.createdRenderPipelineCount = 0u;
  report.computePipeline.reflectionAvailable = false;
  if(iosValidateShadingPrototypeForwardPipelineReport(report)!=
     Status::PipelineCreationFailed)
    return false;

  report = iosCanonicalShadingPrototypeForwardPipelineReport();
  report.createdRenderPipelineCount = 1u;
  report.renderPipelines[0].reflectionAvailable = false;
  if(iosValidateShadingPrototypeForwardPipelineReport(report)!=
     Status::PipelineCreationFailed)
    return false;

  report = iosCanonicalShadingPrototypeForwardPipelineReport();
  report.renderPipelines[1].reflectionAvailable = false;
  return iosValidateShadingPrototypeForwardPipelineReport(report)==
         Status::ReflectionMismatch;
  }

template<std::size_t Index>
bool rejectsRenderPipeline(uint32_t& mutations) {
  const auto rejectPipeline = [&](auto mutate) {
    return rejects(
        [&](Report& report) { mutate(report.renderPipelines[Index]); },
        Status::PipelineMismatch,mutations);
    };
  const auto rejectReflection = [&](auto mutate) {
    return rejects(
        [&](Report& report) { mutate(report.renderPipelines[Index]); },
        Status::ReflectionMismatch,mutations);
    };
  const auto selectVertex = [](Report& report) -> auto& {
    return report.renderPipelines[Index].vertexBindings;
    };
  const auto selectFragment = [](Report& report) -> auto& {
    return report.renderPipelines[Index].fragmentBindings;
    };
  const auto selectTile = [](Report& report) -> auto& {
    return report.renderPipelines[Index].tileBindings;
    };
  const auto selectObject = [](Report& report) -> auto& {
    return report.renderPipelines[Index].objectBindings;
    };
  const auto selectMesh = [](Report& report) -> auto& {
    return report.renderPipelines[Index].meshBindings;
    };
  return rejectPipeline([](auto& value) {
           value.available = !value.available;
           }) &&
         rejectPipeline([](auto& value) {
           value.sameDevice = !value.sameDevice;
           }) &&
         rejectPipeline([](auto& value) {
           value.binaryArchivesNil = !value.binaryArchivesNil;
           }) &&
         rejectPipeline([](auto& value) {
           value.vertexDescriptorMatches =
               !value.vertexDescriptorMatches;
           }) &&
         rejectPipeline([](auto& value) {
           value.colorAttachmentRgba8Unorm =
               !value.colorAttachmentRgba8Unorm;
           }) &&
         rejectPipeline([](auto& value) {
           value.unusedColorAttachmentsInvalid =
               !value.unusedColorAttachmentsInvalid;
           }) &&
         rejectPipeline([](auto& value) {
           value.colorWriteMaskAll = !value.colorWriteMaskAll;
           }) &&
         rejectPipeline([](auto& value) {
           value.blendingDisabled = !value.blendingDisabled;
           }) &&
         rejectPipeline([](auto& value) {
           value.depthStencilDisabled = !value.depthStencilDisabled;
           }) &&
         rejectPipeline([](auto& value) {
           value.triangleTopology = !value.triangleTopology;
           }) &&
         rejectPipeline([](auto& value) {
           value.alphaToCoverageDisabled =
               !value.alphaToCoverageDisabled;
           }) &&
         rejectPipeline([](auto& value) {
           value.alphaToOneDisabled = !value.alphaToOneDisabled;
           }) &&
         rejectPipeline([](auto& value) {
           value.rasterizationEnabled = !value.rasterizationEnabled;
           }) &&
         rejectPipeline([](auto& value) {
           value.indirectCommandBuffersDisabled =
               !value.indirectCommandBuffersDisabled;
           }) &&
         rejectPipeline([](auto& value) {
           value.alphaTestEnabled = !value.alphaTestEnabled;
           }) &&
         rejectPipeline([](auto& value) { ++value.sampleCount; }) &&
         rejectReflection([](auto& value) {
           value.reflectionAvailable = !value.reflectionAvailable;
           }) &&
         acceptsRuntimeTelemetry(
             [&](Report& report) {
               ++report.renderPipelines[Index].
                   imageblockBytesPerSample;
               },
             mutations) &&
         rejectsBindingList(selectVertex,mutations) &&
         rejectsBindingList(selectFragment,mutations) &&
         rejectsBindingList(selectTile,mutations) &&
         rejectsBindingList(selectObject,mutations) &&
         rejectsBindingList(selectMesh,mutations);
  }

}

int main() {
  using namespace RendererIOSShadingPrototypeForwardPipeline;

  static_assert(ContractVersion==1u);
  static_assert(OfflineMetallibAbi==5u);
  static_assert(MinimumAppleGPUFamily==4u);
  static_assert(ResolvedFunctionCount==3u);
  static_assert(SpecializationCount==2u);
  static_assert(ComputePipelineCount==1u);
  static_assert(RenderPipelineCount==2u);
  static_assert(PipelineImageblockBytesPerSample==0u);
  static_assert(AlphaTestFunctionConstantName==
                "riosShadingPrototypeAlphaTest");
  static_assert(Shader::FunctionNames.size()==5u);
  static_assert(Shader::VertexFunction==Shader::FunctionNames[0]);
  static_assert(
      Shader::ForwardLightListFunction==Shader::FunctionNames[3]);
  static_assert(
      Shader::ForwardFragmentFunction==Shader::FunctionNames[4]);
  static_assert(Shader::VertexFunction==
                "riosShadingPrototypeVertex");
  static_assert(Shader::ForwardLightListFunction==
                "riosForwardPlusBuildLightList");
  static_assert(Shader::ForwardFragmentFunction==
                "riosForwardPlusFragment");
  static_assert(Shader::AlphaTestFunctionConstant==
                AlphaTestFunctionConstant);
  static_assert(Shader::PositionAttribute==PositionAttribute);
  static_assert(Shader::ColorAttribute==ColorAttribute);
  static_assert(Shader::ForwardLightListBuffer==
                LightListBufferIndex);
  static_assert(Shader::TotalMetallibExportCount==15u);

  static_assert(static_cast<uint8_t>(Status::Ready)==0u);
  static_assert(static_cast<uint8_t>(Status::DeviceUnavailable)==1u);
  static_assert(
      static_cast<uint8_t>(Status::UnsupportedCapability)==2u);
  static_assert(static_cast<uint8_t>(Status::LibraryUnavailable)==3u);
  static_assert(static_cast<uint8_t>(Status::FunctionMismatch)==4u);
  static_assert(
      static_cast<uint8_t>(Status::PipelineCreationFailed)==5u);
  static_assert(static_cast<uint8_t>(Status::PipelineMismatch)==6u);
  static_assert(static_cast<uint8_t>(Status::ReflectionMismatch)==7u);
  static_assert(static_cast<uint8_t>(Status::InternalFailure)==8u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardFunctionStage::Unknown)==
                0u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardFunctionStage::Vertex)==
                1u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardFunctionStage::Fragment)==
                2u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardFunctionStage::Kernel)==
                3u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingSemantic::Unknown)==
                0u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingSemantic::
                        VertexBuffer)==1u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingSemantic::
                        LightListBuffer)==2u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingNativeType::
                        Unknown)==0u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingNativeType::
                        Buffer)==1u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingAccess::Unknown)==
                0u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingAccess::ReadOnly)==
                1u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingAccess::ReadWrite)==
                2u);
  static_assert(static_cast<uint8_t>(
                    IOSShadingPrototypeForwardBindingAccess::WriteOnly)==
                3u);

  static_assert(std::is_aggregate_v<Report>);
  static_assert(std::is_trivially_copyable_v<Report>);
  static_assert(std::is_standard_layout_v<Report>);
  static_assert(
      sizeof(IOSShadingPrototypeForwardFunctionConstantReport)==5u);
  static_assert(
      alignof(IOSShadingPrototypeForwardFunctionConstantReport)==1u);
  static_assert(
      sizeof(IOSShadingPrototypeForwardFunctionReport)==16u);
  static_assert(
      alignof(IOSShadingPrototypeForwardFunctionReport)==4u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardFunctionReport,
                    functionConstantCount)==4u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardFunctionReport,
                    alphaTest)==8u);
  static_assert(
      sizeof(IOSShadingPrototypeForwardSpecializationReport)==5u);
  static_assert(
      alignof(IOSShadingPrototypeForwardSpecializationReport)==1u);
  static_assert(
      sizeof(IOSShadingPrototypeForwardBindingReport)==12u);
  static_assert(
      alignof(IOSShadingPrototypeForwardBindingReport)==4u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardBindingReport,index)==8u);
  static_assert(
      sizeof(IOSShadingPrototypeForwardBindingListReport)==20u);
  static_assert(
      alignof(IOSShadingPrototypeForwardBindingListReport)==4u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardBindingListReport,count)==
                12u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardBindingListReport,
                    available)==16u);
  static_assert(
      sizeof(IOSShadingPrototypeForwardComputePipelineReport)==36u);
  static_assert(
      alignof(IOSShadingPrototypeForwardComputePipelineReport)==4u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardComputePipelineReport,
                    stageInputDescriptorEmpty)==7u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardComputePipelineReport,
                    linkedFunctionsEmpty)==9u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardComputePipelineReport,
                    maxCallStackDepth)==12u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardComputePipelineReport,
                    computeBindings)==16u);
  static_assert(
      sizeof(IOSShadingPrototypeForwardRenderPipelineReport)==124u);
  static_assert(
      alignof(IOSShadingPrototypeForwardRenderPipelineReport)==4u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardRenderPipelineReport,
                    sampleCount)==16u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardRenderPipelineReport,
                    imageblockBytesPerSample)==20u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardRenderPipelineReport,
                    vertexBindings)==24u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardRenderPipelineReport,
                    fragmentBindings)==44u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardRenderPipelineReport,
                    tileBindings)==64u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardRenderPipelineReport,
                    objectBindings)==84u);
  static_assert(offsetof(
                    IOSShadingPrototypeForwardRenderPipelineReport,
                    meshBindings)==104u);
  static_assert(sizeof(Report)==372u);
  static_assert(alignof(Report)==4u);
  static_assert(offsetof(Report,resolvedFunctionCount)==12u);
  static_assert(offsetof(Report,functions)==28u);
  static_assert(offsetof(Report,fragmentSpecializations)==76u);
  static_assert(offsetof(Report,computePipeline)==88u);
  static_assert(offsetof(Report,renderPipelines)==124u);

  static_assert(std::is_default_constructible_v<
                    IOSShadingPrototypeForwardPipeline>);
  static_assert(std::is_nothrow_default_constructible_v<
                    IOSShadingPrototypeForwardPipeline>);
  static_assert(!std::is_copy_constructible_v<
                    IOSShadingPrototypeForwardPipeline>);
  static_assert(!std::is_copy_assignable_v<
                    IOSShadingPrototypeForwardPipeline>);
  static_assert(std::is_nothrow_move_constructible_v<
                    IOSShadingPrototypeForwardPipeline>);
  static_assert(std::is_nothrow_move_assignable_v<
                    IOSShadingPrototypeForwardPipeline>);
  static_assert(std::is_nothrow_destructible_v<
                    IOSShadingPrototypeForwardPipeline>);

  const Report canonical =
      iosCanonicalShadingPrototypeForwardPipelineReport();
  if(iosValidateShadingPrototypeForwardPipelineReport(canonical)!=
     Status::Ready)
    return 1;

  uint32_t mutations = 0u;
  if(!rejectsTopLevel(mutations))
    return 2;
  if(!rejectsComputePipeline(mutations))
    return 3;
  if(!rejectsRenderPipeline<0u>(mutations))
    return 4;
  if(!rejectsRenderPipeline<1u>(mutations))
    return 5;
  if(mutations!=197u)
    return 6;
  if(!respectsGlobalPipelineBeforeReflectionPrecedence())
    return 7;
  if(!respectsPartialNativeBuildPrecedence())
    return 8;

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
    if(iosShadingPrototypeForwardPipelineStatusName(status)!=name)
      return 9;
    }
  if(iosShadingPrototypeForwardPipelineStatusName(
         static_cast<Status>(0xFFu))!=
     std::string_view("internal-failure"))
    return 10;
  return 0;
  }
