#pragma once

#include "ioslandscapeshaderabi.h"

#include <cstddef>
#include <cstdint>
#include <string_view>

struct IOSBinkShaderConstants final {
  uint32_t strideY = 0;
  uint32_t strideU = 0;
  uint32_t strideV = 0;
  uint32_t reserved = 0;
  };

namespace RendererIOSBinkShader {

inline constexpr std::string_view VertexFunction = "riosBinkVertex";
inline constexpr std::string_view FragmentFunction = "riosBinkFragment";

inline constexpr uint32_t PlaneYBufferIndex = 0u;
inline constexpr uint32_t PlaneUBufferIndex = 1u;
inline constexpr uint32_t PlaneVBufferIndex = 2u;
inline constexpr uint32_t ConstantsBufferIndex = 3u;

}

static_assert(offsetof(IOSBinkShaderConstants,strideY)==0u);
static_assert(offsetof(IOSBinkShaderConstants,strideU)==4u);
static_assert(offsetof(IOSBinkShaderConstants,strideV)==8u);
static_assert(offsetof(IOSBinkShaderConstants,reserved)==12u);
static_assert(sizeof(IOSBinkShaderConstants)==16u);
static_assert(alignof(IOSBinkShaderConstants)==alignof(uint32_t));
