#pragma once

#include <cstdint>
#include <string_view>

namespace RendererIOSShader {

inline constexpr uint32_t AbiVersion = 1u;
inline constexpr std::string_view LibraryName = "RendererIOS";
inline constexpr std::string_view VertexFunction = "riosLandscapeVertex";
inline constexpr std::string_view FragmentFunction = "riosLandscapeFragment";

}
