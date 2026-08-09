#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>
#include <type_traits>

struct alignas(16) IOSToneResolveConstants final {
  float brightness = 0.0f;
  float contrast   = 1.0f;
  float gamma      = 1.0f/2.2f;
  float exposure   = 1.0f;
  };

static_assert(std::is_aggregate_v<IOSToneResolveConstants>);
static_assert(std::is_trivially_copyable_v<IOSToneResolveConstants>);
static_assert(std::is_standard_layout_v<IOSToneResolveConstants>);
static_assert(offsetof(IOSToneResolveConstants,brightness)==0u);
static_assert(offsetof(IOSToneResolveConstants,contrast)==4u);
static_assert(offsetof(IOSToneResolveConstants,gamma)==8u);
static_assert(offsetof(IOSToneResolveConstants,exposure)==12u);
static_assert(sizeof(IOSToneResolveConstants)==16u);
static_assert(alignof(IOSToneResolveConstants)==16u);

namespace RendererIOSShader {

inline constexpr uint32_t AbiVersion = 9u;
inline constexpr std::string_view LibraryName = "RendererIOS";
inline constexpr std::string_view VertexFunction = "riosLandscapeVertex";
inline constexpr std::string_view FragmentFunction = "riosLandscapeFragment";
inline constexpr std::string_view AlphaTestFragmentFunction =
    "riosLandscapeAlphaTestFragment";
inline constexpr std::string_view AdditiveFragmentFunction =
    "riosLandscapeAdditiveFragment";
inline constexpr std::string_view ToneResolveVertexFunction =
    "riosToneResolveVertex";
inline constexpr std::string_view ToneResolveFragmentFunction =
    "riosToneResolveFragment";
inline constexpr uint32_t ToneResolveTextureIndex = 0u;
inline constexpr uint32_t ToneResolveConstantsBufferIndex = 0u;

}
