#pragma once

#include <array>
#include <string>

struct RendererIOSPlatformInfo final {
  std::array<char,64> osVersion    = {};
  std::array<char,64> deviceFamily = {};
  };

RendererIOSPlatformInfo rendererIOSPlatformInfo() noexcept;

#if defined(__IOS__)
std::string rendererIOSMetalLibraryPath();
#endif
