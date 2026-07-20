#pragma once

#include <array>
#include <cstdint>
#include <string_view>

namespace RendererIOSInventoryShader {

inline constexpr uint32_t ManifestVersion = 1u;
inline constexpr std::array<std::string_view,2> FunctionNames = {
  "riosInventoryVertex",
  "riosInventoryFragment",
};

inline constexpr uint32_t PositionAttribute = 0u;
inline constexpr uint32_t NormalAttribute   = 1u;
inline constexpr uint32_t UvAttribute       = 2u;
inline constexpr uint32_t ColorAttribute    = 3u;
inline constexpr uint32_t PushBufferBinding = 0u;
inline constexpr uint32_t VertexBufferBinding = 1u;
inline constexpr uint32_t TextureBinding    = 0u;
inline constexpr uint32_t SamplerBinding    = 0u;
inline constexpr uint32_t PushSize          = 64u;
inline constexpr uint32_t VertexStride      = 36u;

static_assert(FunctionNames.size()==2u);

}
