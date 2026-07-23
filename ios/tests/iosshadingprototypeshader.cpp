#include "graphics/ioslandscapeshaderabi.h"
#include "graphics/iosshadingprototypeshaderabi.h"

#include <array>
#include <cassert>
#include <cstddef>
#include <fstream>
#include <iterator>
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

bool validSource(std::string_view source) noexcept {
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
     countToken(source,"[[color(0)]]")!=2u)
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
}

}

int main(int argc, char** argv) {
  if(argc!=2 ||
     RendererIOSShader::AbiVersion!=5u ||
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
  static_assert(Prototype::TileMaterialBytesPerSample==4u);
  static_assert(Prototype::TileFinalColorAttachment==0u);
  static_assert(Prototype::ExistingMetallibExportCount==10u);
  static_assert(Prototype::TotalMetallibExportCount==15u);
  return 0;
}
