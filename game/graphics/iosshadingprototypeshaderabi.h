#pragma once

#include <array>
#include <cstdint>
#include <string_view>

namespace RendererIOSShadingPrototypeShader {

inline constexpr uint32_t ManifestVersion = 1u;
inline constexpr std::array<std::string_view,5> FunctionNames = {
  "riosShadingPrototypeVertex",
  "riosTileDeferredMaterialFragment",
  "riosTileDeferredLighting",
  "riosForwardPlusBuildLightList",
  "riosForwardPlusFragment",
};

inline constexpr std::string_view VertexFunction = FunctionNames[0];
inline constexpr std::string_view TileMaterialFragmentFunction =
    FunctionNames[1];
inline constexpr std::string_view TileLightingFunction = FunctionNames[2];
inline constexpr std::string_view ForwardLightListFunction = FunctionNames[3];
inline constexpr std::string_view ForwardFragmentFunction = FunctionNames[4];

inline constexpr uint32_t AlphaTestFunctionConstant = 0u;
inline constexpr uint32_t PositionAttribute = 0u;
inline constexpr uint32_t ColorAttribute = 1u;
inline constexpr uint32_t ForwardLightListBuffer = 0u;
inline constexpr uint32_t TileMaterialBytesPerSample = 4u;
inline constexpr uint32_t TileFinalColorAttachment = 0u;
inline constexpr uint32_t ExistingMetallibExportCount = 10u;
inline constexpr uint32_t TotalMetallibExportCount = 15u;

static_assert(FunctionNames.size()==5u);
static_assert(ExistingMetallibExportCount+FunctionNames.size()==
              TotalMetallibExportCount);

}
