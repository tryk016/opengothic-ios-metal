#include "graphics/iosbuiltinshaderabi.h"

#include <array>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

int main(int argc, char** argv) {
  if(argc!=2 || RendererIOSBuiltinShader::ManifestVersion!=1u)
    return 1;

  std::ifstream input(argv[1],std::ios::binary);
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
  if(!input.good() && !input.eof())
    return 2;
  for(const auto function:RendererIOSBuiltinShader::FunctionNames)
    if(source.find(function)==std::string::npos)
      return 3;

  const std::array<std::string_view,9> abiTokens = {
    "float3 position [[attribute(0)]]",
    "float2 uv       [[attribute(1)]]",
    "float4 color    [[attribute(2)]]",
    "float4 color    [[user(locn0)]]",
    "float2 uv       [[user(locn1)]]",
    "out.position.y = -out.position.y;",
    "texture2d<float,access::sample> texture [[texture(0)]]",
    "sampler textureSampler [[sampler(0)]]",
    "in.color*texture.sample(textureSampler,in.uv)",
  };
  for(const auto token:abiTokens)
    if(source.find(token)==std::string::npos)
      return 4;

  static_assert(RendererIOSBuiltinShader::PositionAttribute==0u);
  static_assert(RendererIOSBuiltinShader::UvAttribute==1u);
  static_assert(RendererIOSBuiltinShader::ColorAttribute==2u);
  static_assert(RendererIOSBuiltinShader::TextureBinding==0u);
  static_assert(RendererIOSBuiltinShader::SamplerBinding==0u);
  static_assert(RendererIOSBuiltinShader::VertexStride==36u);
  return 0;
}
