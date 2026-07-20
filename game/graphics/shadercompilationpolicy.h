#pragma once

#include <cstdint>
#include <limits>

enum class ShaderCompilationProfile : uint8_t {
  LegacyRenderer,
  RendererIOSBridge,
  };

constexpr bool shaderProfileAllowsMaterialPipelines(
    ShaderCompilationProfile profile) noexcept {
  return profile==ShaderCompilationProfile::LegacyRenderer;
  }

struct SourceOnlyDrawCommandKey final {
  uint8_t  type     = 0;
  uint8_t  alpha    = 0;
  uint32_t bucketId = 0;

  constexpr bool operator==(const SourceOnlyDrawCommandKey&) const = default;
  };

constexpr SourceOnlyDrawCommandKey sourceOnlyDrawCommandKey(
    uint8_t type, uint8_t alpha, bool bindless, uint32_t bucketId) noexcept {
  return {
    type,
    alpha,
    bindless ? std::numeric_limits<uint32_t>::max() : bucketId,
    };
  }
