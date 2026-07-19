#include "graphics/ioslandscapeshader.h"

#include <cstdio>

int main() {
  const auto source = RendererIOSShader::Landscape;
  const std::size_t written =
      std::fwrite(source.data(),1u,source.size(),stdout);
  return written==source.size() ? 0 : 1;
  }
