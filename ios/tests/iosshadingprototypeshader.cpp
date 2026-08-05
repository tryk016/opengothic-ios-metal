#include "graphics/ioslandscapeshaderabi.h"
#include "graphics/iosshadingprototypeshaderabi.h"

#include <array>
#include <cassert>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <optional>
#include <regex>
#include <string>
#include <string_view>
#include <utility>

namespace Prototype = RendererIOSShadingPrototypeShader;

namespace {

constexpr size_t countToken(
    std::string_view source, std::string_view token) noexcept {
  size_t count = 0u;
  size_t offset = 0u;
  while((offset=source.find(token,offset))!=std::string_view::npos) {
    ++count;
    offset += token.size();
  }
  return count;
}

constexpr std::array<std::string_view,26> RequiredTokens = {
  "constant bool riosShadingPrototypeAlphaTest [[function_constant(0)]];",
  "float3 position [[attribute(0)]];",
  "float4 color    [[attribute(1)]];",
  "rgba8unorm<half4> compact [[raster_order_group(0)]];",
  "RendererIOSShadingPrototypeMaterial material [[imageblock_data]];",
  "half4 coverageColor [[color(0)]];",
  "half4 finalColor [[color(0)]];",
  "vertex RendererIOSShadingPrototypeVertexOut riosShadingPrototypeVertex(",
  "fragment RendererIOSShadingPrototypeMaterialStore",
  "riosTileDeferredMaterialFragment(",
  "out.material.compact = in.color;",
  "out.coverageColor = half4(in.color.rgb,half(1.0));",
  "kernel void riosTileDeferredLighting(",
  "imageblock<RendererIOSShadingPrototypeMaterial,",
  "imageblock_layout_explicit> materialBlock,",
  "imageblock<RendererIOSShadingPrototypeFinalColor,",
  "imageblock_layout_implicit> finalColorBlock,",
  "materialBlock.data(position);",
  "finalColorBlock.read(position);",
  "if(output.finalColor.a>half(0.0))",
  "half4(compact.rgb*light,half(1.0));",
  "output.finalColor = half4(0.0h);",
  "finalColorBlock.write(output,position);",
  "kernel void riosForwardPlusBuildLightList(",
  "fragment float4 riosForwardPlusFragment(",
  "const device uint* lightList [[buffer(0)]]",
};

constexpr std::array<std::string_view,8> ForbiddenTokens = {
  "newLibraryWithSource",
  "compileSource",
  "MTLCompileOptions",
  "newCommandQueue",
  "commandBufferWith",
  "presentDrawable",
  "#include \"",
  "riosShadingPrototypeAlphaTest(",
};

bool stripComments(std::string_view source, std::string& stripped) {
  stripped.clear();
  stripped.reserve(source.size());
  size_t offset = 0u;
  while(offset<source.size()) {
    if(offset+1u<source.size() &&
       source[offset]=='/' && source[offset+1u]=='/') {
      offset += 2u;
      while(offset<source.size() && source[offset]!='\n')
        ++offset;
      if(offset<source.size())
        stripped.push_back(source[offset++]);
      continue;
    }
    if(offset+1u<source.size() &&
       source[offset]=='/' && source[offset+1u]=='*') {
      offset += 2u;
      bool closed = false;
      while(offset+1u<source.size()) {
        if(source[offset]=='*' && source[offset+1u]=='/') {
          offset += 2u;
          closed = true;
          break;
        }
        ++offset;
      }
      if(!closed)
        return false;
      stripped.push_back(' ');
      continue;
    }
    stripped.push_back(source[offset++]);
  }
  return true;
}

std::optional<size_t> matchingDelimiter(
    std::string_view source, size_t opening, char open, char close) {
  if(opening>=source.size() || source[opening]!=open)
    return std::nullopt;
  size_t depth = 0u;
  for(size_t offset=opening; offset<source.size(); ++offset) {
    if(source[offset]==open)
      ++depth;
    else if(source[offset]==close) {
      if(depth==0u)
        return std::nullopt;
      --depth;
      if(depth==0u)
        return offset;
    }
  }
  return std::nullopt;
}

std::string compactWhitespace(std::string_view source) {
  std::string compact;
  compact.reserve(source.size());
  for(const char value:source)
    if(value!=' ' && value!='\t' && value!='\r' && value!='\n' &&
       value!='\f' && value!='\v')
      compact.push_back(value);
  return compact;
}

struct ForwardKernelContract final {
  uint32_t bufferIndex = 0u;
  uint32_t guardX = 0u;
  uint32_t guardY = 0u;
  uint32_t guardZ = 0u;
  uint32_t loopStart = 0u;
  uint32_t loopBound = 0u;
  uint32_t activeIndex = 0u;
  uint32_t activeValue = 0u;
  uint32_t inactiveValue = 0u;
};

std::optional<uint32_t> parseUint(std::string_view value) noexcept {
  uint32_t result = 0u;
  const auto parsed =
      std::from_chars(value.data(),value.data()+value.size(),result);
  if(parsed.ec!=std::errc{} || parsed.ptr!=value.data()+value.size())
    return std::nullopt;
  return result;
}

template<size_t MatchCount>
std::optional<ForwardKernelContract> contractFromMatches(
    const std::match_results<std::string::const_iterator>& signature,
    const std::match_results<std::string::const_iterator>& body) {
  static_assert(MatchCount==9u);
  const auto capture =
      [](const auto& match, size_t index) -> std::optional<uint32_t> {
    const std::string value = match[index].str();
    return parseUint(value);
  };
  const auto bufferIndex = capture(signature,1u);
  const auto guardX = capture(body,1u);
  const auto guardY = capture(body,2u);
  const auto guardZ = capture(body,3u);
  const auto loopStart = capture(body,4u);
  const auto loopBound = capture(body,5u);
  const auto activeIndex = capture(body,6u);
  const auto activeValue = capture(body,7u);
  const auto inactiveValue = capture(body,8u);
  if(!bufferIndex || !guardX || !guardY || !guardZ || !loopStart ||
     !loopBound || !activeIndex || !activeValue || !inactiveValue)
    return std::nullopt;
  return ForwardKernelContract{
    *bufferIndex,
    *guardX,
    *guardY,
    *guardZ,
    *loopStart,
    *loopBound,
    *activeIndex,
    *activeValue,
    *inactiveValue,
  };
}

std::optional<ForwardKernelContract> parseForwardKernel(
    std::string_view source) {
  std::string stripped;
  if(!stripComments(source,stripped))
    return std::nullopt;
  constexpr std::string_view marker =
      "kernel void riosForwardPlusBuildLightList";
  if(countToken(stripped,marker)!=1u)
    return std::nullopt;
  const size_t markerOffset = stripped.find(marker);
  const size_t openParenthesis = stripped.find('(',markerOffset+marker.size());
  if(openParenthesis==std::string::npos)
    return std::nullopt;
  const auto closeParenthesis =
      matchingDelimiter(stripped,openParenthesis,'(',')');
  if(!closeParenthesis)
    return std::nullopt;
  const size_t openBody = stripped.find_first_not_of(
      " \t\r\n\f\v",*closeParenthesis+1u);
  if(openBody==std::string::npos || stripped[openBody]!='{')
    return std::nullopt;
  const auto closeBody = matchingDelimiter(stripped,openBody,'{','}');
  if(!closeBody)
    return std::nullopt;

  const std::string signature = compactWhitespace(
      std::string_view(stripped).substr(
        markerOffset,*closeParenthesis-markerOffset+1u));
  const std::string body = compactWhitespace(
      std::string_view(stripped).substr(
        openBody+1u,*closeBody-openBody-1u));
  static const std::regex SignaturePattern(
      R"(kernelvoidriosForwardPlusBuildLightList\(deviceuint\*lightList\[\[buffer\(([0-9]+)\)\]\],uint3position\[\[thread_position_in_grid\]\]\))");
  static const std::regex BodyPattern(
      R"(if\(position\.x==([0-9]+)u&&position\.y==([0-9]+)u&&position\.z==([0-9]+)u\)\{for\(uintindex=([0-9]+)u;index<([0-9]+)u;\+\+index\)lightList\[index\]=index==([0-9]+)u\?([0-9]+)u:([0-9]+)u;\})");
  std::match_results<std::string::const_iterator> signatureMatches;
  std::match_results<std::string::const_iterator> bodyMatches;
  if(!std::regex_match(
       signature.cbegin(),signature.cend(),signatureMatches,
       SignaturePattern) ||
     !std::regex_match(body.cbegin(),body.cend(),bodyMatches,BodyPattern))
    return std::nullopt;
  return contractFromMatches<9u>(signatureMatches,bodyMatches);
}

struct ForwardEvaluation final {
  std::array<uint32_t,Prototype::ForwardLightListWordCount> values = {};
  std::array<uint32_t,Prototype::ForwardLightListWordCount> writes = {};
  bool outOfBounds = false;
};

ForwardEvaluation evaluate(
    const ForwardKernelContract& contract,
    uint32_t x, uint32_t y, uint32_t z) noexcept {
  ForwardEvaluation result;
  result.values.fill(Prototype::ForwardLightListSentinel);
  if(x!=contract.guardX || y!=contract.guardY || z!=contract.guardZ)
    return result;
  for(uint32_t index=contract.loopStart; index<contract.loopBound; ++index) {
    if(index>=result.values.size()) {
      result.outOfBounds = true;
      continue;
    }
    ++result.writes[index];
    result.values[index] =
        index==contract.activeIndex
          ? contract.activeValue
          : contract.inactiveValue;
  }
  return result;
}

bool validForwardKernel(std::string_view source) {
  const auto contract = parseForwardKernel(source);
  if(!contract ||
     contract->bufferIndex!=Prototype::ForwardLightListBuffer ||
     contract->guardX!=Prototype::ForwardLightListInactiveValue ||
     contract->guardY!=Prototype::ForwardLightListInactiveValue ||
     contract->guardZ!=Prototype::ForwardLightListInactiveValue ||
     contract->loopStart!=Prototype::ForwardLightListInactiveValue ||
     contract->loopBound!=Prototype::ForwardLightListWordCount ||
     contract->activeIndex!=Prototype::ForwardLightListInactiveValue ||
     contract->activeValue!=Prototype::ForwardLightListActiveValue ||
     contract->inactiveValue!=Prototype::ForwardLightListInactiveValue)
    return false;

  const ForwardEvaluation active = evaluate(*contract,0u,0u,0u);
  if(active.outOfBounds)
    return false;
  for(size_t index=0u; index<active.values.size(); ++index) {
    const uint32_t expected =
        index==0u
          ? Prototype::ForwardLightListActiveValue
          : Prototype::ForwardLightListInactiveValue;
    if(active.writes[index]!=1u || active.values[index]!=expected)
      return false;
  }
  constexpr std::array<std::array<uint32_t,3u>,3u> NonAuthorPositions = {{
    {1u,0u,0u},
    {0u,1u,0u},
    {0u,0u,1u},
  }};
  for(const auto& position:NonAuthorPositions) {
    const ForwardEvaluation inactive =
        evaluate(*contract,position[0],position[1],position[2]);
    if(inactive.outOfBounds)
      return false;
    for(size_t index=0u; index<inactive.values.size(); ++index)
      if(inactive.writes[index]!=0u ||
         inactive.values[index]!=Prototype::ForwardLightListSentinel)
        return false;
  }
  return true;
}

bool validSource(std::string_view source) {
  if(source.empty() ||
     countToken(source,"#include <metal_stdlib>")!=1u ||
     countToken(source,"vertex ")!=1u ||
     countToken(source,"fragment ")!=2u ||
     countToken(source,"kernel ")!=2u ||
     countToken(source,"[[function_constant(")!=1u ||
     countToken(source,
       "if(riosShadingPrototypeAlphaTest && in.color.a<half(0.5))")!=2u ||
     countToken(source,"imageblock_layout_explicit")!=1u ||
     countToken(source,"imageblock_layout_implicit")!=1u ||
     countToken(source,"[[imageblock_data]]")!=1u ||
     countToken(source,"[[color(0)]]")!=2u ||
     countToken(source,"[[buffer(")!=2u ||
     !validForwardKernel(source))
    return false;
  for(const auto function:Prototype::FunctionNames)
    if(countToken(source,function)!=1u)
      return false;
  for(const auto token:RequiredTokens)
    if(countToken(source,token)!=1u)
      return false;
  for(const auto token:ForbiddenTokens)
    if(source.find(token)!=std::string_view::npos)
      return false;
  return true;
}

std::string mutateOnce(
    std::string source, std::string_view from, std::string_view to) {
  const size_t offset = source.find(from);
  assert(offset!=std::string::npos);
  assert(source.find(from,offset+from.size())==std::string::npos);
  source.replace(offset,from.size(),to);
  return source;
}

void runForwardMutationTests() {
  const std::string canonical =
      "kernel void riosForwardPlusBuildLightList(\n"
      "    device uint* lightList [[buffer(0)]],\n"
      "    uint3 position [[thread_position_in_grid]]) {\n"
      "  if(position.x==0u && position.y==0u && position.z==0u) {\n"
      "    for(uint index=0u; index<64u; ++index)\n"
      "      lightList[index] = index==0u ? 1u : 0u;\n"
      "  }\n"
      "}\n";
  assert(validForwardKernel(canonical));
  assert(validForwardKernel(mutateOnce(
      canonical,"uint3 position","uint3 /* comment */ position")));

  constexpr std::array<std::pair<std::string_view,std::string_view>,26u>
      mutations = {{
        {
          "for(uint index=0u; index<64u; ++index)\n"
          "      lightList[index] = index==0u ? 1u : 0u;",
          "lightList[0] = 1u;",
        },
        {"uint index=0u","uint index=1u"},
        {
          "lightList[index] = index==0u ? 1u : 0u;",
          "if(index!=0u) lightList[index] = index==0u ? 1u : 0u;",
        },
        {"index<64u","index<63u"},
        {"index<64u","index<65u"},
        {"index<64u","index<=64u"},
        {"lightList[index]","lightList[64u]"},
        {
          "lightList[index] = index==0u ? 1u : 0u;",
          "lightList[index] = index==0u ? 1u : 0u;\n"
          "      lightList[index] = index==0u ? 1u : 0u;",
        },
        {
          "  }\n}",
          "  }\n  lightList[0] = 1u;\n}",
        },
        {
          "if(position.x==0u && position.y==0u && position.z==0u)",
          "if(true)",
        },
        {
          "  if(position.x==0u && position.y==0u && position.z==0u) {\n"
          "    for(uint index=0u; index<64u; ++index)\n"
          "      lightList[index] = index==0u ? 1u : 0u;\n"
          "  }",
          "  for(uint index=0u; index<64u; ++index)\n"
          "    lightList[index] = index==0u ? 1u : 0u;",
        },
        {"position.x==0u","position.x!=0u"},
        {"position.x==0u","position.x==1u"},
        {"position.y==0u","position.y==1u"},
        {"position.z==0u","position.z==1u"},
        {
          "if(position.x==0u && position.y==0u && position.z==0u)",
          "if(position==0u)",
        },
        {"uint3 position","uint position"},
        {"index==0u ? 1u : 0u","index==0u ? 0u : 1u"},
        {"device uint* lightList","device ushort* lightList"},
        {"[[buffer(0)]]","[[buffer(1)]]"},
        {
          "lightList[index] = index==0u ? 1u : 0u;",
          "device uint* alias = lightList;\n"
          "      alias[index] = index==0u ? 1u : 0u;",
        },
        {
          "lightList[index] = index==0u ? 1u : 0u;",
          "if(false) lightList[index] = index==0u ? 1u : 0u;",
        },
        {
          "lightList[index] = index==0u ? 1u : 0u;",
          "if(index==0u) lightList[index] = index==0u ? 1u : 0u;",
        },
        {
          "if(position.x==0u && position.y==0u && position.z==0u) {",
          "if(position.x==0u && position.y==0u && position.z==0u) {\n"
          "    return;",
        },
        {"++index","index++"},
        {
          "for(uint index=0u; index<64u; ++index)",
          "uint ignored = 0u;\n"
          "    for(uint index=0u; index<64u; ++index)",
        },
      }};
  for(const auto& mutation:mutations)
    assert(!validForwardKernel(
      mutateOnce(canonical,mutation.first,mutation.second)));
  assert(!validForwardKernel(canonical+"/* unterminated"));
}

void runMutationTests(const std::string& source) {
  assert(validSource(source));
  for(const auto token:RequiredTokens) {
    const std::string mutated = mutateOnce(source,token,"P2_5B0_MUTATED");
    assert(!validSource(mutated));
  }
  for(const auto function:Prototype::FunctionNames) {
    std::string duplicated = source;
    duplicated += "\n";
    duplicated += function;
    assert(!validSource(duplicated));
  }
  for(const auto token:ForbiddenTokens) {
    std::string injected = source;
    injected += "\n";
    injected += token;
    assert(!validSource(injected));
  }
  {
    std::string injected = source;
    injected +=
        "\nconstant uint& unexpectedBuffer [[buffer(7)]];\n";
    assert(!validSource(injected));
  }
  {
    constexpr std::string_view predicate =
        "if(riosShadingPrototypeAlphaTest && in.color.a<half(0.5))";
    std::string mutated = source;
    const size_t offset = mutated.find(predicate);
    assert(offset!=std::string::npos);
    mutated.replace(offset,predicate.size(),"if(false)");
    assert(!validSource(mutated));
  }
  constexpr std::array<std::pair<std::string_view,std::string_view>,9>
      semanticMutations = {{
        {"function_constant(0)","function_constant(1)"},
        {"attribute(0)","attribute(2)"},
        {"attribute(1)","attribute(3)"},
        {"rgba8unorm<half4>","half4"},
        {"raster_order_group(0)","raster_order_group(1)"},
        {"imageblock_layout_explicit","imageblock_layout_implicit"},
        {"[[imageblock_data]]","[[color(1)]]"},
        {"half4 finalColor [[color(0)]];",
         "half4 finalColor [[color(2)]];"},
        {"const device uint* lightList [[buffer(0)]]",
         "const device uint* lightList [[buffer(1)]]"},
      }};
  for(const auto& mutation:semanticMutations)
    assert(!validSource(mutateOnce(source,mutation.first,mutation.second)));
  runForwardMutationTests();
}

}

int main(int argc, char** argv) {
  if(argc!=2 ||
     RendererIOSShader::AbiVersion!=8u ||
     Prototype::ManifestVersion!=1u)
    return 1;
  std::ifstream input(argv[1],std::ios::binary);
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
  if(!input.good() && !input.eof())
    return 2;
  if(!validSource(source))
    return 3;
  runMutationTests(source);

  static_assert(Prototype::FunctionNames.size()==5u);
  static_assert(Prototype::AlphaTestFunctionConstant==0u);
  static_assert(Prototype::PositionAttribute==0u);
  static_assert(Prototype::ColorAttribute==1u);
  static_assert(Prototype::ForwardLightListBuffer==0u);
  static_assert(Prototype::ForwardLightListWordBytes==4u);
  static_assert(Prototype::ForwardLightListWordCount==64u);
  static_assert(Prototype::ForwardLightListByteSize==256u);
  static_assert(Prototype::ForwardLightListActiveValue==1u);
  static_assert(Prototype::ForwardLightListInactiveValue==0u);
  static_assert(Prototype::ForwardLightListSentinel==0xA5A5A5A5u);
  static_assert(Prototype::ForwardLightListGridWidth==1u);
  static_assert(Prototype::ForwardLightListGridHeight==1u);
  static_assert(Prototype::ForwardLightListGridDepth==1u);
  static_assert(Prototype::ForwardLightListThreadsPerThreadgroupWidth==1u);
  static_assert(Prototype::ForwardLightListThreadsPerThreadgroupHeight==1u);
  static_assert(Prototype::ForwardLightListThreadsPerThreadgroupDepth==1u);
  static_assert(Prototype::TileMaterialBytesPerSample==4u);
  static_assert(Prototype::TileFinalColorAttachment==0u);
  static_assert(Prototype::ExistingMetallibExportCount==13u);
  static_assert(Prototype::TotalMetallibExportCount==18u);
  return 0;
}
