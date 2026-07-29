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
inline constexpr uint32_t ForwardLightListWordBytes = 4u;
inline constexpr uint32_t ForwardLightListWordCount = 64u;
inline constexpr uint32_t ForwardLightListByteSize =
    ForwardLightListWordBytes*ForwardLightListWordCount;
inline constexpr uint32_t ForwardLightListActiveValue = 1u;
inline constexpr uint32_t ForwardLightListInactiveValue = 0u;
inline constexpr uint32_t ForwardLightListSentinel = 0xA5A5A5A5u;
inline constexpr uint32_t ForwardLightListGridWidth = 1u;
inline constexpr uint32_t ForwardLightListGridHeight = 1u;
inline constexpr uint32_t ForwardLightListGridDepth = 1u;
inline constexpr uint32_t ForwardLightListThreadsPerThreadgroupWidth = 1u;
inline constexpr uint32_t ForwardLightListThreadsPerThreadgroupHeight = 1u;
inline constexpr uint32_t ForwardLightListThreadsPerThreadgroupDepth = 1u;
inline constexpr uint32_t TileMaterialBytesPerSample = 4u;
inline constexpr uint32_t TileFinalColorAttachment = 0u;
inline constexpr uint32_t ExistingMetallibExportCount = 11u;
inline constexpr uint32_t TotalMetallibExportCount = 16u;

static_assert(FunctionNames.size()==5u);
static_assert(ForwardLightListWordBytes==4u);
static_assert(sizeof(uint32_t)==ForwardLightListWordBytes);
static_assert(ForwardLightListWordCount==64u);
static_assert(ForwardLightListByteSize==256u);
static_assert(ForwardLightListActiveValue==1u);
static_assert(ForwardLightListInactiveValue==0u);
static_assert(ForwardLightListSentinel==0xA5A5A5A5u);
static_assert(ForwardLightListActiveValue!=ForwardLightListInactiveValue);
static_assert(ForwardLightListSentinel!=ForwardLightListActiveValue);
static_assert(ForwardLightListSentinel!=ForwardLightListInactiveValue);
static_assert(ForwardLightListGridWidth==1u);
static_assert(ForwardLightListGridHeight==1u);
static_assert(ForwardLightListGridDepth==1u);
static_assert(ForwardLightListThreadsPerThreadgroupWidth==1u);
static_assert(ForwardLightListThreadsPerThreadgroupHeight==1u);
static_assert(ForwardLightListThreadsPerThreadgroupDepth==1u);
static_assert(ExistingMetallibExportCount+FunctionNames.size()==
              TotalMetallibExportCount);

}
