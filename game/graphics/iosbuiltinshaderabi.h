#pragma once

#include <array>
#include <cstdint>
#include <string_view>

namespace RendererIOSBuiltinShader {

inline constexpr uint32_t ManifestVersion = 1u;
inline constexpr std::array<std::string_view,4> FunctionNames = {
  "riosUiColorVertex",
  "riosUiColorFragment",
  "riosUiTextureVertex",
  "riosUiTextureFragment",
};

inline constexpr uint32_t PositionAttribute = 0u;
inline constexpr uint32_t UvAttribute       = 1u;
inline constexpr uint32_t ColorAttribute    = 2u;
inline constexpr uint32_t TextureBinding    = 0u;
inline constexpr uint32_t SamplerBinding    = 0u;
inline constexpr uint32_t VertexStride      = 36u;

static_assert(FunctionNames.size()==4u);

}
