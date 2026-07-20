#include "graphics/iosbinkshaderabi.h"

#include <array>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

int main(int argc, char** argv) {
  if(argc!=2 || RendererIOSShader::AbiVersion!=4u)
    return 1;

  std::ifstream input(argv[1],std::ios::binary);
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
  if(!input.good() && !input.eof())
    return 2;
  if(source.find(RendererIOSBinkShader::VertexFunction)==std::string::npos)
    return 3;
  if(source.find(RendererIOSBinkShader::FragmentFunction)==std::string::npos)
    return 4;

  const std::array<std::string_view,8> abiTokens = {
    "const device uint* planeY [[buffer(0)]]",
    "const device uint* planeU [[buffer(1)]]",
    "const device uint* planeV [[buffer(2)]]",
    "constant RendererIOSBinkConstants& constants [[buffer(3)]]",
    "uint strideY;",
    "uint strideU;",
    "uint strideV;",
    "uint reserved;",
  };
  for(const auto token:abiTokens)
    if(source.find(token)==std::string::npos)
      return 5;

  static_assert(RendererIOSBinkShader::PlaneYBufferIndex==0u);
  static_assert(RendererIOSBinkShader::PlaneUBufferIndex==1u);
  static_assert(RendererIOSBinkShader::PlaneVBufferIndex==2u);
  static_assert(RendererIOSBinkShader::ConstantsBufferIndex==3u);
  static_assert(sizeof(IOSBinkShaderConstants)==16u);
  return 0;
  }
