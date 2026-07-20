#include "graphics/iosbinkselftest.h"

#include <array>
#include <cstddef>
#include <cstdint>

namespace {

constexpr std::uint8_t Padding = 0xE1u;

std::uint8_t toUnormByte(double value) {
  if(value<=0.0)
    return 0u;
  if(value>=255.0)
    return 255u;
  return static_cast<std::uint8_t>(value+0.5);
  }

std::array<std::uint8_t,4u> referenceRgba(
    const IOSBinkSelfTestCase& testCase,
    std::size_t x,
    std::size_t y) {
  const std::size_t strideY = static_cast<std::size_t>(testCase.strideY);
  const std::size_t strideU = static_cast<std::size_t>(testCase.strideU);
  const std::size_t strideV = static_cast<std::size_t>(testCase.strideV);
  const double sampleY =
      static_cast<double>(testCase.planes[y*strideY+x]);
  const double sampleU =
      static_cast<double>(
          testCase.planes[testCase.offsetU+(y/2u)*strideU+x/2u]);
  const double sampleV =
      static_cast<double>(
          testCase.planes[testCase.offsetV+(y/2u)*strideV+x/2u]);
  const double red =
      1.164*(sampleY-16.0)+1.596*(sampleV-128.0);
  const double green =
      1.164*(sampleY-16.0)-0.813*(sampleV-128.0)
                           -0.391*(sampleU-128.0);
  const double blue =
      1.164*(sampleY-16.0)+2.018*(sampleU-128.0);
  return {toUnormByte(red),toUnormByte(green),toUnormByte(blue),255u};
  }

bool verifyPlanePadding(const IOSBinkSelfTestCase& testCase) {
  constexpr std::size_t ChromaWidth  = IOSBinkSelfTestWidth/2u;
  constexpr std::size_t ChromaHeight = IOSBinkSelfTestHeight/2u;
  const std::size_t strideY = static_cast<std::size_t>(testCase.strideY);
  const std::size_t strideU = static_cast<std::size_t>(testCase.strideU);
  const std::size_t strideV = static_cast<std::size_t>(testCase.strideV);

  for(std::size_t y=0u; y<IOSBinkSelfTestHeight; ++y)
    for(std::size_t x=IOSBinkSelfTestWidth; x<strideY; ++x)
      if(testCase.planes[y*strideY+x]!=Padding)
        return false;
  for(std::size_t i=strideY*IOSBinkSelfTestHeight;
      i<testCase.offsetU; ++i)
    if(testCase.planes[i]!=Padding)
      return false;
  for(std::size_t y=0u; y<ChromaHeight; ++y)
    for(std::size_t x=ChromaWidth; x<strideU; ++x)
      if(testCase.planes[testCase.offsetU+y*strideU+x]!=Padding)
        return false;
  for(std::size_t i=testCase.offsetU+strideU*ChromaHeight;
      i<testCase.offsetV; ++i)
    if(testCase.planes[i]!=Padding)
      return false;
  for(std::size_t y=0u; y<ChromaHeight; ++y)
    for(std::size_t x=ChromaWidth; x<strideV; ++x)
      if(testCase.planes[testCase.offsetV+y*strideV+x]!=Padding)
        return false;
  return true;
  }

int verifyCase(std::size_t alignment,
               std::size_t expectedOffsetU,
               std::size_t expectedOffsetV,
               std::size_t expectedSize) {
  const IOSBinkSelfTestCase testCase =
      makeIOSBinkSelfTestCase(alignment);
  if(testCase.strideY!=8u || testCase.strideU!=4u ||
     testCase.strideV!=4u)
    return 1;
  if(testCase.offsetU!=expectedOffsetU ||
     testCase.offsetV!=expectedOffsetV ||
     testCase.planes.size()!=expectedSize)
    return 2;
  if(testCase.offsetU%alignment!=0u || testCase.offsetV%alignment!=0u)
    return 3;

  constexpr std::size_t YBytes = 8u*IOSBinkSelfTestHeight;
  constexpr std::size_t UBytes = 4u*(IOSBinkSelfTestHeight/2u);
  constexpr std::size_t VBytes = 4u*(IOSBinkSelfTestHeight/2u);
  if(YBytes>testCase.offsetU ||
     testCase.offsetU+UBytes>testCase.offsetV ||
     testCase.offsetV+VBytes>testCase.planes.size())
    return 4;
  if(!verifyPlanePadding(testCase))
    return 5;

  constexpr std::array<std::uint8_t,16u> ExpectedY = {
     16u, 16u, 16u, 16u,
     16u, 16u, 16u, 16u,
    255u,255u, 76u, 76u,
    255u,255u, 76u, 76u,
    };
  constexpr std::array<std::uint8_t,4u> ExpectedU = {
    128u,255u,128u,85u,
    };
  constexpr std::array<std::uint8_t,4u> ExpectedV = {
    128u,128u,128u,255u,
    };
  for(std::size_t y=0u; y<IOSBinkSelfTestHeight; ++y)
    for(std::size_t x=0u; x<IOSBinkSelfTestWidth; ++x)
      if(testCase.planes[y*8u+x] !=
         ExpectedY[y*IOSBinkSelfTestWidth+x])
        return 6;
  for(std::size_t y=0u; y<IOSBinkSelfTestHeight/2u; ++y)
    for(std::size_t x=0u; x<IOSBinkSelfTestWidth/2u; ++x) {
      const std::size_t at = y*(IOSBinkSelfTestWidth/2u)+x;
      if(testCase.planes[testCase.offsetU+y*4u+x]!=ExpectedU[at] ||
         testCase.planes[testCase.offsetV+y*4u+x]!=ExpectedV[at])
        return 7;
      }
  for(std::size_t y=0u; y<IOSBinkSelfTestHeight; ++y)
    for(std::size_t x=0u; x<IOSBinkSelfTestWidth; ++x) {
      const auto pixel = referenceRgba(testCase,x,y);
      const std::size_t at = (y*IOSBinkSelfTestWidth+x)*4u;
      for(std::size_t channel=0u; channel<pixel.size(); ++channel)
        if(pixel[channel]!=IOSBinkSelfTestExpectedRgba[at+channel])
          return 8;
      }
  return 0;
  }

}

int main() {
  static_assert(IOSBinkSelfTestWidth==4u);
  static_assert(IOSBinkSelfTestHeight==4u);
  static_assert(IOSBinkSelfTestExpectedBytes==64u);
  static_assert(IOSBinkSelfTestExpectedRgba.size()==64u);
  static_assert(IOSBinkSelfTestExpectedFnv1a64==
                UINT64_C(0xeb48c2c0c3cea445));

  if(const int result=verifyCase(16u,32u,48u,56u); result!=0)
    return result;
  if(const int result=verifyCase(256u,256u,512u,520u); result!=0)
    return 20+result;

  constexpr std::array<std::uint8_t,16u> BlackBlackBlueBlue = {
    0u,0u,0u,255u, 0u,0u,0u,255u,
    0u,0u,255u,255u, 0u,0u,255u,255u,
    };
  constexpr std::array<std::uint8_t,16u> WhiteWhiteRedRed = {
    255u,255u,255u,255u, 255u,255u,255u,255u,
    255u,0u,0u,255u, 255u,0u,0u,255u,
    };
  for(std::size_t row=0u; row<2u; ++row) {
    for(std::size_t i=0u; i<BlackBlackBlueBlue.size(); ++i)
      if(IOSBinkSelfTestExpectedRgba[row*16u+i]!=
         BlackBlackBlueBlue[i])
        return 3;
    for(std::size_t i=0u; i<WhiteWhiteRedRed.size(); ++i)
      if(IOSBinkSelfTestExpectedRgba[(row+2u)*16u+i]!=
         WhiteWhiteRedRed[i])
        return 4;
    }

  const IOSBinkSelfTestValidation pass =
      validateIOSBinkSelfTestRgba(IOSBinkSelfTestExpectedRgba.data(),
                                  IOSBinkSelfTestExpectedRgba.size());
  if(!pass.passed ||
     pass.firstMismatch!=IOSBinkSelfTestExpectedBytes ||
     pass.fnv1a64!=IOSBinkSelfTestExpectedFnv1a64)
    return 5;

  auto mismatched = IOSBinkSelfTestExpectedRgba;
  constexpr std::size_t MismatchAt = 37u;
  mismatched[MismatchAt] = 7u;
  const IOSBinkSelfTestValidation mismatch =
      validateIOSBinkSelfTestRgba(mismatched.data(),mismatched.size());
  if(mismatch.passed || mismatch.firstMismatch!=MismatchAt ||
     mismatch.expected!=IOSBinkSelfTestExpectedRgba[MismatchAt] ||
     mismatch.actual!=mismatched[MismatchAt] ||
     mismatch.fnv1a64==IOSBinkSelfTestExpectedFnv1a64)
    return 6;

  const IOSBinkSelfTestValidation shortInput =
      validateIOSBinkSelfTestRgba(IOSBinkSelfTestExpectedRgba.data(),63u);
  if(shortInput.passed || shortInput.firstMismatch!=63u ||
     shortInput.expected!=IOSBinkSelfTestExpectedRgba[63u])
    return 7;
  return 0;
  }
