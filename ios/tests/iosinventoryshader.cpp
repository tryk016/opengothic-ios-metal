#include "graphics/iosinventoryshaderabi.h"

#include <array>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

int main(int argc, char** argv) {
  if(argc!=2 || RendererIOSInventoryShader::ManifestVersion!=1u)
    return 1;

  std::ifstream input(argv[1],std::ios::binary);
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
  if(!input.good() && !input.eof())
    return 2;
  for(const auto function:RendererIOSInventoryShader::FunctionNames)
    if(source.find(function)==std::string::npos)
      return 3;

  const std::array<std::string_view,14> abiTokens = {
    "float3 position [[attribute(0)]]",
    "float3 normal   [[attribute(1)]]",
    "float2 uv       [[attribute(2)]]",
    "uint   color    [[attribute(3)]]",
    "float2 uv       [[user(locn0)]]",
    "constant float4x4& viewProject [[buffer(0)]]",
    "viewProject*float4(in.position,1.0f)",
    "out.position.y = -out.position.y;",
    "texture2d<float,access::sample> texture [[texture(0)]]",
    "sampler textureSampler [[sampler(0)]]",
    "texture.sample(textureSampler,in.uv)",
    "texel.a<0.5f",
    "discard_fragment()",
    "return texel;",
  };
  for(const auto token:abiTokens)
    if(source.find(token)==std::string::npos)
      return 4;

  static_assert(RendererIOSInventoryShader::PositionAttribute==0u);
  static_assert(RendererIOSInventoryShader::NormalAttribute==1u);
  static_assert(RendererIOSInventoryShader::UvAttribute==2u);
  static_assert(RendererIOSInventoryShader::ColorAttribute==3u);
  static_assert(RendererIOSInventoryShader::PushBufferBinding==0u);
  static_assert(RendererIOSInventoryShader::VertexBufferBinding==1u);
  static_assert(RendererIOSInventoryShader::TextureBinding==0u);
  static_assert(RendererIOSInventoryShader::SamplerBinding==0u);
  static_assert(RendererIOSInventoryShader::PushSize==64u);
  static_assert(RendererIOSInventoryShader::VertexStride==36u);
  return 0;
}
