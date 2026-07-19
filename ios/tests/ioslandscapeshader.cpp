#include "graphics/ioslandscapeshaderabi.h"
#include "graphics/iosgpusceneplan.h"

#include <array>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

int main(int argc, char** argv) {
  if(argc!=2 || RendererIOSShader::AbiVersion!=1u)
    return 1;

  std::ifstream input(argv[1],std::ios::binary);
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
  if(!input.good() && !input.eof())
    return 2;
  if(source.find(RendererIOSShader::VertexFunction)==std::string::npos)
    return 3;
  if(source.find(RendererIOSShader::FragmentFunction)==std::string::npos)
    return 4;
  const std::array<std::string_view,8> abiTokens = {
    "float3 position [[attribute(0)]]",
    "float3 normal   [[attribute(1)]]",
    "float2 uv       [[attribute(2)]]",
    "float4 color    [[attribute(3)]]",
    "constant IOSLandscapeDrawConstants& draw [[buffer(1)]]",
    "texture2d<float, access::sample> baseColorTexture [[texture(0)]]",
    "sampler baseColorSampler [[sampler(0)]]",
    "float4   baseColor;",
  };
  for(const auto token:abiTokens)
    if(source.find(token)==std::string::npos)
      return 5;

  static_assert(IOSLandscapeVertexStride==36u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,viewProjection)==0u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,model)==64u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,baseColor)==128u);
  static_assert(sizeof(IOSGPUSceneDrawConstants)==144u);
  static_assert(alignof(IOSGPUSceneDrawConstants)==16u);
  return 0;
  }
