#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

inline constexpr std::size_t IOSBinkSelfTestWidth         = 4u;
inline constexpr std::size_t IOSBinkSelfTestHeight        = 4u;
inline constexpr std::size_t IOSBinkSelfTestExpectedBytes =
    IOSBinkSelfTestWidth*IOSBinkSelfTestHeight*4u;

inline constexpr std::array<std::uint8_t,IOSBinkSelfTestExpectedBytes>
    IOSBinkSelfTestExpectedRgba = {
      0u,  0u,  0u,255u,   0u,  0u,  0u,255u,
      0u,  0u,255u,255u,   0u,  0u,255u,255u,
      0u,  0u,  0u,255u,   0u,  0u,  0u,255u,
      0u,  0u,255u,255u,   0u,  0u,255u,255u,
    255u,255u,255u,255u, 255u,255u,255u,255u,
    255u,  0u,  0u,255u, 255u,  0u,  0u,255u,
    255u,255u,255u,255u, 255u,255u,255u,255u,
    255u,  0u,  0u,255u, 255u,  0u,  0u,255u,
    };

namespace IOSBinkSelfTestDetail {

inline constexpr std::uint64_t Fnv1a64Offset =
    UINT64_C(14695981039346656037);
inline constexpr std::uint64_t Fnv1a64Prime = UINT64_C(1099511628211);

constexpr std::uint64_t fnv1a64(const std::uint8_t* bytes,
                                std::size_t size) noexcept {
  std::uint64_t value = Fnv1a64Offset;
  for(std::size_t i=0u; i<size; ++i) {
    value ^= static_cast<std::uint64_t>(bytes[i]);
    value *= Fnv1a64Prime;
    }
  return value;
  }

inline std::size_t alignUp(std::size_t value, std::size_t alignment) {
  if(alignment==0u || (alignment & (alignment-1u))!=0u)
    throw std::invalid_argument(
        "RendererIOS Bink self-test alignment must be a power of two");
  const std::size_t mask = alignment-1u;
  if(value>std::numeric_limits<std::size_t>::max()-mask)
    throw std::overflow_error(
        "RendererIOS Bink self-test plane layout overflow");
  return (value+mask) & ~mask;
  }

}

inline constexpr std::uint64_t IOSBinkSelfTestExpectedFnv1a64 =
    IOSBinkSelfTestDetail::fnv1a64(IOSBinkSelfTestExpectedRgba.data(),
                                   IOSBinkSelfTestExpectedRgba.size());

struct IOSBinkSelfTestCase final {
  std::vector<std::uint8_t> planes;
  std::size_t               offsetU = 0u;
  std::size_t               offsetV = 0u;
  std::uint32_t             strideY = 0u;
  std::uint32_t             strideU = 0u;
  std::uint32_t             strideV = 0u;
  };

inline IOSBinkSelfTestCase makeIOSBinkSelfTestCase(std::size_t alignment) {
  constexpr std::uint8_t Padding = 0xE1u;
  constexpr std::size_t ChromaHeight = IOSBinkSelfTestHeight/2u;
  constexpr std::array<std::array<std::uint8_t,IOSBinkSelfTestWidth>,
                       IOSBinkSelfTestHeight> PlaneY = {{
    {{ 16u, 16u, 16u, 16u}},
    {{ 16u, 16u, 16u, 16u}},
    {{255u,255u, 76u, 76u}},
    {{255u,255u, 76u, 76u}},
    }};
  constexpr std::array<std::array<std::uint8_t,IOSBinkSelfTestWidth/2u>,
                       ChromaHeight> PlaneU = {{
    {{128u,255u}},
    {{128u, 85u}},
    }};
  constexpr std::array<std::array<std::uint8_t,IOSBinkSelfTestWidth/2u>,
                       ChromaHeight> PlaneV = {{
    {{128u,128u}},
    {{128u,255u}},
    }};

  IOSBinkSelfTestCase result;
  result.strideY = 8u;
  result.strideU = 4u;
  result.strideV = 4u;

  const std::size_t yBytes =
      static_cast<std::size_t>(result.strideY)*IOSBinkSelfTestHeight;
  const std::size_t uBytes =
      static_cast<std::size_t>(result.strideU)*ChromaHeight;
  const std::size_t vBytes =
      static_cast<std::size_t>(result.strideV)*ChromaHeight;
  result.offsetU = IOSBinkSelfTestDetail::alignUp(yBytes,alignment);
  if(result.offsetU>std::numeric_limits<std::size_t>::max()-uBytes)
    throw std::overflow_error(
        "RendererIOS Bink self-test U plane layout overflow");
  result.offsetV =
      IOSBinkSelfTestDetail::alignUp(result.offsetU+uBytes,alignment);
  if(result.offsetV>std::numeric_limits<std::size_t>::max()-vBytes)
    throw std::overflow_error(
        "RendererIOS Bink self-test V plane layout overflow");
  result.planes.assign(result.offsetV+vBytes,Padding);

  for(std::size_t y=0u; y<IOSBinkSelfTestHeight; ++y)
    for(std::size_t x=0u; x<IOSBinkSelfTestWidth; ++x)
      result.planes[y*static_cast<std::size_t>(result.strideY)+x] =
          PlaneY[y][x];
  for(std::size_t y=0u; y<ChromaHeight; ++y)
    for(std::size_t x=0u; x<IOSBinkSelfTestWidth/2u; ++x) {
      result.planes[result.offsetU+
                    y*static_cast<std::size_t>(result.strideU)+x] =
          PlaneU[y][x];
      result.planes[result.offsetV+
                    y*static_cast<std::size_t>(result.strideV)+x] =
          PlaneV[y][x];
      }
  return result;
  }

struct IOSBinkSelfTestValidation final {
  bool          passed        = false;
  std::size_t   firstMismatch = IOSBinkSelfTestExpectedBytes;
  std::uint8_t  expected      = 0u;
  std::uint8_t  actual        = 0u;
  std::uint64_t fnv1a64       = IOSBinkSelfTestDetail::Fnv1a64Offset;
  };

inline IOSBinkSelfTestValidation validateIOSBinkSelfTestRgba(
    const void* rgba, std::size_t size) noexcept {
  IOSBinkSelfTestValidation result;
  const auto* bytes = static_cast<const std::uint8_t*>(rgba);
  if(bytes!=nullptr)
    result.fnv1a64 = IOSBinkSelfTestDetail::fnv1a64(bytes,size);

  const std::size_t comparable =
      size<IOSBinkSelfTestExpectedBytes ? size
                                       : IOSBinkSelfTestExpectedBytes;
  if(bytes!=nullptr) {
    for(std::size_t i=0u; i<comparable; ++i) {
      if(bytes[i]==IOSBinkSelfTestExpectedRgba[i])
        continue;
      result.firstMismatch = i;
      result.expected = IOSBinkSelfTestExpectedRgba[i];
      result.actual = bytes[i];
      return result;
      }
    }

  if(bytes==nullptr) {
    result.firstMismatch = 0u;
    result.expected = IOSBinkSelfTestExpectedRgba[0u];
    return result;
    }
  if(size<IOSBinkSelfTestExpectedBytes) {
    result.firstMismatch = size;
    result.expected = IOSBinkSelfTestExpectedRgba[size];
    return result;
    }
  if(size>IOSBinkSelfTestExpectedBytes) {
    result.firstMismatch = IOSBinkSelfTestExpectedBytes;
    result.actual = bytes[IOSBinkSelfTestExpectedBytes];
    return result;
    }

  result.passed = true;
  return result;
  }
