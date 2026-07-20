#pragma once

#include "iospipelinearchivepolicy.h"

#include <Tempest/Platform>

#include <array>
#include <cstddef>
#include <string>

struct RendererIOSPlatformInfo final {
  std::array<char,64> osVersion    = {};
  std::array<char,64> deviceFamily = {};
  };

struct RendererIOSPipelineArchiveDescriptor final {
  std::string archivePath;
  std::string provenancePath;
  std::string metallibSha256;
  bool        invalidatedStaleArchive = false;
  };

RendererIOSPlatformInfo rendererIOSPlatformInfo() noexcept;

#if defined(__IOS__)
std::string rendererIOSMetalLibraryPath();
RendererIOSPipelineArchiveDescriptor
  rendererIOSPipelineArchiveDescriptor(const std::string& metallibPath);
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
struct RendererIOSPipelineArchiveTestModeResult final {
  std::size_t bytes           = 0u;
  bool        removedVerified = false;
  bool        writeVerified   = false;
  };

RendererIOSPipelineArchiveTestModeResult
rendererIOSApplyPipelineArchiveTestMode(
  const std::string& metallibPath,
  RendererIOSPipelineArchive::TestMode mode);
#endif
#endif
