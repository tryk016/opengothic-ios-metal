#include "graphics/iosshadingprototypeforwardprobe.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string_view>
#include <type_traits>

namespace {

// Workflow evidence marker: mutations=all-report-fields.
using LightListReport =
    IOSShadingPrototypeForwardLightListReportV1;
using ProbeReport =
    IOSShadingPrototypeForwardProbeReportV1;
using TerminalReport =
    IOSShadingPrototypeForwardTerminalReportV1;
using Failure = IOSShadingPrototypeForwardFailureReason;
using Operation = IOSShadingPrototypeForwardProbeOperation;

template<class Report, class Validate>
bool rejectsEveryWord(const Report& canonical,
                      Validate validate) noexcept {
  static_assert(sizeof(Report)%sizeof(uint32_t)==0u);
  constexpr std::size_t WordCount =
      sizeof(Report)/sizeof(uint32_t);
  std::array<uint32_t,WordCount> words{};
  std::memcpy(words.data(),&canonical,sizeof(canonical));

  for(std::size_t index=0u; index<words.size(); ++index) {
    auto mutatedWords = words;
    mutatedWords[index] ^= 0x80000000u;
    Report mutated;
    std::memcpy(&mutated,mutatedWords.data(),sizeof(mutated));
    if(validate(mutated))
      return false;
    }
  return true;
  }

template<class Report, class Validate>
bool rejectsEveryKnownFlagAndReason(
    const Report& canonical,
    uint32_t knownFlags,
    Validate validate) noexcept {
  for(uint32_t bit=1u; bit!=0u; bit<<=1u) {
    if((knownFlags&bit)==0u)
      continue;
    Report mutated = canonical;
    mutated.flags &= ~bit;
    if(validate(mutated))
      return false;
    }

  for(uint32_t candidate=1u;
      candidate<static_cast<uint32_t>(Failure::Count);
      ++candidate) {
    Report mutated = canonical;
    mutated.failureReason = candidate;
    if(validate(mutated))
      return false;
    }

  Report unknownFlag = canonical;
  unknownFlag.flags |= 1u<<31u;
  Report outOfRangeReason = canonical;
  outOfRangeReason.failureReason =
      static_cast<uint32_t>(Failure::Count);
  return !validate(unknownFlag) &&
         !validate(outOfRangeReason);
  }

bool validatesBoundedFencePolls(
    uint32_t waits) noexcept {
  TerminalReport report =
      iosCanonicalShadingPrototypeForwardTerminalReportV1();
  report.terminalFenceWaitCalls = waits;
  report.terminalFenceZeroTimeoutCalls = waits;
  report.terminalFenceNonterminalPolls = waits-1u;
  return iosValidateShadingPrototypeForwardTerminalReportV1(
      report);
  }

bool rejectsFenceRelationMutations() noexcept {
  TerminalReport report =
      iosCanonicalShadingPrototypeForwardTerminalReportV1();
  report.terminalFenceWaitCalls = 2u;
  report.terminalFenceZeroTimeoutCalls = 1u;
  report.terminalFenceNonterminalPolls = 1u;
  if(iosValidateShadingPrototypeForwardTerminalReportV1(report))
    return false;

  report =
      iosCanonicalShadingPrototypeForwardTerminalReportV1();
  report.terminalFenceWaitCalls = 2u;
  report.terminalFenceZeroTimeoutCalls = 2u;
  report.terminalFenceNonterminalPolls = 0u;
  if(iosValidateShadingPrototypeForwardTerminalReportV1(report))
    return false;

  report =
      iosCanonicalShadingPrototypeForwardTerminalReportV1();
  report.terminalFenceMonotonic = 0u;
  return !iosValidateShadingPrototypeForwardTerminalReportV1(
      report);
  }

bool validatesContents() noexcept {
  namespace Shader = RendererIOSShadingPrototypeShader;
  std::array<uint32_t,Shader::ForwardLightListWordCount> words{};
  words.fill(Shader::ForwardLightListInactiveValue);
  words[0] = Shader::ForwardLightListActiveValue;
  if(!iosShadingPrototypeForwardLightListContentsMatch(words))
    return false;

  words[0] = Shader::ForwardLightListSentinel;
  if(iosShadingPrototypeForwardLightListContentsMatch(words))
    return false;
  words[0] = Shader::ForwardLightListActiveValue;
  words[1] = Shader::ForwardLightListActiveValue;
  if(iosShadingPrototypeForwardLightListContentsMatch(words))
    return false;
  words[1] = Shader::ForwardLightListSentinel;
  return !iosShadingPrototypeForwardLightListContentsMatch(words);
  }

}

int main() {
  using namespace RendererIOSShadingPrototypeForwardProbe;
  namespace Shader = RendererIOSShadingPrototypeShader;

  static_assert(ABIVersion==1u);
  static_assert(MinimumAppleGPUFamily==4u);
  static_assert(OutputWidth==4u);
  static_assert(OutputHeight==4u);
  static_assert(OutputMipLevels==1u);
  static_assert(OutputSampleCount==1u);
  static_assert(OutputAttachment==0u);
  static_assert(VertexStride==28u);
  static_assert(VertexCount==6u);
  static_assert(VertexBytes==168u);
  static_assert(OpaqueVertexStart==0u);
  static_assert(AlphaTestVertexStart==3u);
  static_assert(TriangleVertexCount==3u);
  static_assert(LightListOffset==0u);
  static_assert(TerminalFenceMaximumPolls==120u);
  static_assert(TerminalFenceDeadlineMilliseconds==30000u);
  static_assert(StorageModeShared==1u);
  static_assert(HazardTrackingModeTracked==1u);
  static_assert(ComputePipelineLabel==
                "RendererIOS Forward BuildLightList");
  static_assert(OpaquePipelineLabel==
                "RendererIOS Forward Opaque");
  static_assert(AlphaTestPipelineLabel==
                "RendererIOS Forward AlphaTest");
  static_assert(ComputeEncoderLabel==
                "RendererIOS Forward Compute Encoder");
  static_assert(RenderEncoderLabel==
                "RendererIOS Forward Render Encoder");
  static_assert(LightListBufferLabel==
                "RendererIOS Forward LightList 256B");
  static_assert(CommandBufferLabel==
                "RendererIOS Forward Prototype CB");
  static_assert(LightListKnownFlagsMask==0x1ffu);
  static_assert(ProbeKnownFlagsMask==0xffu);
  static_assert(TerminalKnownFlagsMask==0x27fu);

  static_assert(static_cast<uint32_t>(Failure::None)==0u);
  static_assert(static_cast<uint32_t>(
                    Failure::ForbiddenDeviceReadBytes)==25u);
  static_assert(static_cast<uint32_t>(Failure::Count)==26u);
  static_assert(static_cast<uint32_t>(
                    Operation::BuildLightList)==0u);
  static_assert(static_cast<uint32_t>(
                    Operation::DrawOpaque)==1u);
  static_assert(static_cast<uint32_t>(
                    Operation::DrawAlphaTest)==2u);
  static_assert(static_cast<uint32_t>(Operation::Count)==3u);

  static_assert(std::is_aggregate_v<LightListReport>);
  static_assert(std::is_aggregate_v<ProbeReport>);
  static_assert(std::is_aggregate_v<TerminalReport>);
  static_assert(std::is_trivially_copyable_v<LightListReport>);
  static_assert(std::is_trivially_copyable_v<ProbeReport>);
  static_assert(std::is_trivially_copyable_v<TerminalReport>);
  static_assert(std::is_standard_layout_v<LightListReport>);
  static_assert(std::is_standard_layout_v<ProbeReport>);
  static_assert(std::is_standard_layout_v<TerminalReport>);

  static_assert(sizeof(LightListReport)==164u);
  static_assert(alignof(LightListReport)==4u);
  static_assert(offsetof(LightListReport,abiVersion)==0u);
  static_assert(offsetof(LightListReport,structSize)==4u);
  static_assert(offsetof(LightListReport,flags)==8u);
  static_assert(offsetof(LightListReport,failureReason)==12u);
  static_assert(offsetof(LightListReport,bindingOffset)==36u);
  static_assert(offsetof(LightListReport,prefillAttempted)==52u);
  static_assert(offsetof(LightListReport,ownerCreatedDelta)==84u);
  static_assert(offsetof(LightListReport,reserved)==132u);

  static_assert(sizeof(ProbeReport)==468u);
  static_assert(alignof(ProbeReport)==4u);
  static_assert(offsetof(ProbeReport,abiVersion)==0u);
  static_assert(offsetof(ProbeReport,structSize)==4u);
  static_assert(offsetof(ProbeReport,flags)==8u);
  static_assert(offsetof(ProbeReport,failureReason)==12u);
  static_assert(offsetof(ProbeReport,factoryReady)==32u);
  static_assert(offsetof(ProbeReport,outputLoadClear)==104u);
  static_assert(offsetof(ProbeReport,lightListAvailable)==144u);
  static_assert(offsetof(ProbeReport,computePipelineBinds)==208u);
  static_assert(offsetof(ProbeReport,primitiveTriangle)==256u);
  static_assert(offsetof(ProbeReport,endEncodingCalls)==316u);
  static_assert(offsetof(ProbeReport,helperDeviceCreations)==348u);
  static_assert(offsetof(ProbeReport,operationCount)==420u);
  static_assert(offsetof(ProbeReport,operations)==424u);
  static_assert(offsetof(ProbeReport,reserved)==436u);

  static_assert(sizeof(TerminalReport)==268u);
  static_assert(alignof(TerminalReport)==4u);
  static_assert(offsetof(TerminalReport,abiVersion)==0u);
  static_assert(offsetof(TerminalReport,structSize)==4u);
  static_assert(offsetof(TerminalReport,flags)==8u);
  static_assert(offsetof(TerminalReport,failureReason)==12u);
  static_assert(offsetof(TerminalReport,
                         terminalFenceWaitCalls)==24u);
  static_assert(offsetof(TerminalReport,
                         terminalFenceZeroTimeoutCalls)==40u);
  static_assert(offsetof(TerminalReport,
                         directContentsAvailable)==64u);
  static_assert(offsetof(TerminalReport,exactResult)==104u);
  static_assert(offsetof(TerminalReport,
                         outputCreatedDelta)==120u);
  static_assert(offsetof(TerminalReport,
                         captureOwnerInitializedAtTerminal)==180u);
  static_assert(offsetof(TerminalReport,
                         captureAcquisitionCalls)==204u);
  static_assert(offsetof(TerminalReport,
                         runtimeShaderCompilationDelta)==224u);
  static_assert(offsetof(TerminalReport,reserved)==236u);

  static_assert(sizeof(LightListReport)/sizeof(uint32_t)==41u);
  static_assert(sizeof(ProbeReport)/sizeof(uint32_t)==117u);
  static_assert(sizeof(TerminalReport)/sizeof(uint32_t)==67u);

  const LightListReport lightList =
      iosCanonicalShadingPrototypeForwardLightListReportV1();
  const ProbeReport probe =
      iosCanonicalShadingPrototypeForwardProbeReportV1();
  const TerminalReport terminal =
      iosCanonicalShadingPrototypeForwardTerminalReportV1();

  const auto validateLightList =
      [](const LightListReport& report) noexcept {
        return iosValidateShadingPrototypeForwardLightListReportV1(
            report);
      };
  const auto validateProbe =
      [](const ProbeReport& report) noexcept {
        return iosValidateShadingPrototypeForwardProbeReportV1(
            report);
      };
  const auto validateTerminal =
      [](const TerminalReport& report) noexcept {
        return iosValidateShadingPrototypeForwardTerminalReportV1(
            report);
      };

  if(!validateLightList(lightList) ||
     !validateProbe(probe) ||
     !validateTerminal(terminal) ||
     lightList.structSize!=sizeof(LightListReport) ||
     probe.structSize!=sizeof(ProbeReport) ||
     terminal.structSize!=sizeof(TerminalReport) ||
     lightList.flags!=LightListKnownFlagsMask ||
     probe.flags!=ProbeKnownFlagsMask ||
     terminal.flags!=TerminalKnownFlagsMask ||
     lightList.failureReason!=
         static_cast<uint32_t>(Failure::None) ||
     probe.failureReason!=
         static_cast<uint32_t>(Failure::None) ||
     terminal.failureReason!=
         static_cast<uint32_t>(Failure::None) ||
     lightList.byteSize!=Shader::ForwardLightListByteSize ||
     lightList.wordCount!=Shader::ForwardLightListWordCount ||
     lightList.sentinelValue!=Shader::ForwardLightListSentinel ||
     probe.vertexBytes!=VertexBytes ||
     probe.operationCount!=
         static_cast<uint32_t>(Operation::Count) ||
     probe.operations!=
         std::array<uint32_t,3u>{
           static_cast<uint32_t>(Operation::BuildLightList),
           static_cast<uint32_t>(Operation::DrawOpaque),
           static_cast<uint32_t>(Operation::DrawAlphaTest),
         } ||
     terminal.readbackBytes!=
         Shader::ForwardLightListByteSize ||
     terminal.readbackWords!=
         Shader::ForwardLightListWordCount ||
     terminal.firstWord!=
         Shader::ForwardLightListActiveValue ||
     terminal.activeWords!=1u ||
     terminal.inactiveWords!=
         Shader::ForwardLightListWordCount-1u ||
     !rejectsEveryWord(lightList,validateLightList) ||
     !rejectsEveryWord(probe,validateProbe) ||
     !rejectsEveryWord(terminal,validateTerminal) ||
     !rejectsEveryKnownFlagAndReason(
         lightList,LightListKnownFlagsMask,validateLightList) ||
     !rejectsEveryKnownFlagAndReason(
         probe,ProbeKnownFlagsMask,validateProbe) ||
     !rejectsEveryKnownFlagAndReason(
         terminal,TerminalKnownFlagsMask,validateTerminal) ||
     validatesBoundedFencePolls(0u) ||
     !validatesBoundedFencePolls(1u) ||
     !validatesBoundedFencePolls(2u) ||
     !validatesBoundedFencePolls(
         TerminalFenceMaximumPolls) ||
     validatesBoundedFencePolls(
         TerminalFenceMaximumPolls+1u) ||
     !rejectsFenceRelationMutations() ||
     !validatesContents())
    return 1;

  return 0;
  }
