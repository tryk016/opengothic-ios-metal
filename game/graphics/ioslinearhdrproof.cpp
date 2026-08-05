#include "ioslinearhdrproof.h"

#include <cmath>
#include <limits>

namespace {

constexpr size_t HeaderBytes = 160u;
constexpr uint32_t MaximumExtent = 16384u;
constexpr uint64_t MaximumPayloadBytes = 256u*1024u*1024u;

uint8_t byteAt(std::span<const std::byte> bytes, size_t offset) noexcept {
  return std::to_integer<uint8_t>(bytes[offset]);
  }

uint16_t loadLe16(std::span<const std::byte> bytes, size_t offset) noexcept {
  return uint16_t(byteAt(bytes,offset)) |
      uint16_t(uint16_t(byteAt(bytes,offset+1u)) << 8u);
  }

uint32_t loadLe32(std::span<const std::byte> bytes, size_t offset) noexcept {
  return uint32_t(byteAt(bytes,offset)) |
      (uint32_t(byteAt(bytes,offset+1u)) << 8u) |
      (uint32_t(byteAt(bytes,offset+2u)) << 16u) |
      (uint32_t(byteAt(bytes,offset+3u)) << 24u);
  }

uint64_t loadLe64(std::span<const std::byte> bytes, size_t offset) noexcept {
  uint64_t value = 0u;
  for(uint32_t index=0u; index<8u; ++index)
    value |= uint64_t(byteAt(bytes,offset+size_t(index))) << (index*8u);
  return value;
  }

bool checkedAdd(uint64_t lhs, uint64_t rhs, uint64_t& result) noexcept {
  if(lhs>std::numeric_limits<uint64_t>::max()-rhs)
    return false;
  result = lhs+rhs;
  return true;
  }

bool checkedMultiply(uint64_t lhs, uint64_t rhs, uint64_t& result) noexcept {
  if(lhs!=0u && rhs>std::numeric_limits<uint64_t>::max()/lhs)
    return false;
  result = lhs*rhs;
  return true;
  }

bool allZero(std::span<const std::byte> bytes, size_t offset, size_t count) noexcept {
  for(size_t index=0u; index<count; ++index) {
    if(byteAt(bytes,offset+index)!=0u)
      return false;
    }
  return true;
  }

bool validLabel(std::span<const std::byte> input) noexcept {
  constexpr char Prefix[] = "RendererIOS.SceneHDR.";
  constexpr char Hex[] = "0123456789abcdef";
  for(size_t index=0u; index<sizeof(Prefix)-1u; ++index) {
    if(byteAt(input,104u+index)!=uint8_t(Prefix[index]))
      return false;
    }
  for(size_t index=0u; index<16u; ++index) {
    const uint8_t value = byteAt(input,64u+index);
    const size_t labelOffset = 104u+(sizeof(Prefix)-1u)+index*2u;
    if(byteAt(input,labelOffset)!=uint8_t(Hex[value >> 4u]) ||
       byteAt(input,labelOffset+1u)!=uint8_t(Hex[value&0x0fu]))
      return false;
    }
  return byteAt(input,157u)==0u &&
      byteAt(input,158u)==0u && byteAt(input,159u)==0u;
  }

bool validView(const IOSLinearHDRProofView& view) noexcept {
  if(view.width==0u || view.height==0u ||
     view.width>MaximumExtent || view.height>MaximumExtent ||
     view.targetGeneration==0u || view.snapshotSequence==0u ||
     view.logicalBytes>MaximumPayloadBytes)
    return false;

  bool proofIsZero = true;
  for(uint8_t value : view.proofId)
    proofIsZero = proofIsZero && value==0u;
  bool shaIsZero = true;
  for(uint8_t value : view.buildSha)
    shaIsZero = shaIsZero && value==0u;
  if(proofIsZero || shaIsZero)
    return false;

  uint64_t expectedRowPitch = 0u;
  uint64_t expectedLogicalBytes = 0u;
  if(!checkedMultiply(uint64_t(view.width),4u,expectedRowPitch) ||
     expectedRowPitch!=view.bytesPerRow ||
     !checkedMultiply(uint64_t(view.height),expectedRowPitch,
                      expectedLogicalBytes) ||
     expectedLogicalBytes!=view.logicalBytes ||
     view.payload.size()!=view.logicalBytes)
    return false;
  return true;
  }

bool decodeComponent(
    uint32_t encoded,
    uint32_t mantissaBits,
    float& component) noexcept {
  const uint32_t exponent = encoded >> mantissaBits;
  const uint32_t mantissa = encoded & ((uint32_t(1u) << mantissaBits)-1u);
  if(exponent==31u)
    return false;
  if(exponent==0u) {
    component = std::ldexp(static_cast<float>(mantissa),
                           -14-static_cast<int>(mantissaBits));
    return true;
    }
  component = std::ldexp(
      1.f+static_cast<float>(mantissa)/
          static_cast<float>(uint32_t(1u) << mantissaBits),
      static_cast<int>(exponent)-15);
  return true;
  }

}

bool iosDecodeLinearHDRRG11B10(
    uint32_t word,
    IOSLinearHDRRGB& decoded) noexcept {
  const uint32_t red = word&0x7ffu;
  const uint32_t green = (word >> 11u)&0x7ffu;
  const uint32_t blue = (word >> 22u)&0x3ffu;
  IOSLinearHDRRGB candidate;
  if(!decodeComponent(red,6u,candidate.r) ||
     !decodeComponent(green,6u,candidate.g) ||
     !decodeComponent(blue,5u,candidate.b))
    return false;
  decoded = candidate;
  return true;
  }

IOSLinearHDRProofError iosParseLinearHDRProofV1(
    std::span<const std::byte> input,
    IOSLinearHDRProofView& view) noexcept {
  if(input.size()<HeaderBytes)
    return IOSLinearHDRProofError::InvalidInputSize;

  constexpr char Magic[] = "RIOSR11";
  for(size_t index=0u; index<sizeof(Magic)-1u; ++index) {
    if(byteAt(input,index)!=uint8_t(Magic[index]))
      return IOSLinearHDRProofError::InvalidMagic;
    }
  if(byteAt(input,7u)!=0u)
    return IOSLinearHDRProofError::InvalidMagic;
  if(loadLe16(input,8u)!=1u)
    return IOSLinearHDRProofError::UnsupportedSchema;
  if(loadLe16(input,10u)!=HeaderBytes)
    return IOSLinearHDRProofError::InvalidHeaderSize;
  if(loadLe32(input,12u)!=1u)
    return IOSLinearHDRProofError::UnsupportedProducerVersion;
  if(loadLe32(input,16u)!=1u)
    return IOSLinearHDRProofError::UnsupportedPixelFormat;

  const uint32_t width = loadLe32(input,20u);
  const uint32_t height = loadLe32(input,24u);
  const uint32_t bytesPerRow = loadLe32(input,28u);
  const uint64_t logicalBytes = loadLe64(input,32u);
  const uint64_t targetGeneration = loadLe64(input,40u);
  const uint64_t snapshotSequence = loadLe64(input,48u);
  const uint32_t mipLevel = loadLe32(input,56u);
  const uint32_t arraySlice = loadLe32(input,60u);

  if(targetGeneration==0u || snapshotSequence==0u ||
     allZero(input,64u,16u) || allZero(input,80u,20u))
    return IOSLinearHDRProofError::InvalidIdentity;
  if(mipLevel!=0u || arraySlice!=0u)
    return IOSLinearHDRProofError::InvalidSubresource;
  if(loadLe32(input,100u)!=0u)
    return IOSLinearHDRProofError::NonZeroReserved;
  if(!validLabel(input))
    return IOSLinearHDRProofError::InvalidResourceLabel;

  uint64_t expectedInputSize = 0u;
  if(!checkedAdd(uint64_t(HeaderBytes),logicalBytes,expectedInputSize))
    return IOSLinearHDRProofError::SizeOverflow;
  if(width==0u || height==0u ||
     width>MaximumExtent || height>MaximumExtent)
    return IOSLinearHDRProofError::InvalidExtent;
  if(logicalBytes>MaximumPayloadBytes)
    return IOSLinearHDRProofError::InvalidLogicalBytes;

  uint64_t expectedRowPitch = 0u;
  if(!checkedMultiply(uint64_t(width),4u,expectedRowPitch))
    return IOSLinearHDRProofError::SizeOverflow;
  if(bytesPerRow!=expectedRowPitch)
    return IOSLinearHDRProofError::InvalidRowPitch;
  uint64_t expectedLogicalBytes = 0u;
  if(!checkedMultiply(uint64_t(height),expectedRowPitch,
                      expectedLogicalBytes))
    return IOSLinearHDRProofError::SizeOverflow;
  if(logicalBytes!=expectedLogicalBytes)
    return IOSLinearHDRProofError::InvalidLogicalBytes;
  if(expectedInputSize!=input.size())
    return IOSLinearHDRProofError::InvalidInputSize;

  IOSLinearHDRProofView candidate;
  candidate.payload = input.subspan(HeaderBytes,
                                    static_cast<size_t>(logicalBytes));
  candidate.width = width;
  candidate.height = height;
  candidate.bytesPerRow = bytesPerRow;
  candidate.logicalBytes = logicalBytes;
  candidate.targetGeneration = targetGeneration;
  candidate.snapshotSequence = snapshotSequence;
  for(size_t index=0u; index<candidate.proofId.size(); ++index)
    candidate.proofId[index] = byteAt(input,64u+index);
  for(size_t index=0u; index<candidate.buildSha.size(); ++index)
    candidate.buildSha[index] = byteAt(input,80u+index);
  view = candidate;
  return IOSLinearHDRProofError::None;
  }

IOSLinearHDRProofError iosScanLinearHDRProofV1(
    const IOSLinearHDRProofView& view,
    IOSLinearHDRProofScan& scan) noexcept {
  if(!validView(view))
    return IOSLinearHDRProofError::InvalidView;

  IOSLinearHDRProofScan candidate;
  bool haveMaximum = false;
  float maximumComponent = 0.f;
  for(uint32_t y=0u; y<view.height; ++y) {
    for(uint32_t x=0u; x<view.width; ++x) {
      const size_t offset = size_t(y)*size_t(view.bytesPerRow)+size_t(x)*4u;
      IOSLinearHDRRGB rgb;
      if(!iosDecodeLinearHDRRG11B10(loadLe32(view.payload,offset),rgb))
        return IOSLinearHDRProofError::InvalidPackedValue;
      if(!std::isfinite(rgb.r) || !std::isfinite(rgb.g) || !std::isfinite(rgb.b) ||
         rgb.r<0.f || rgb.g<0.f || rgb.b<0.f)
        return IOSLinearHDRProofError::InvalidPackedValue;
      const float components[] = {rgb.r,rgb.g,rgb.b};
      for(uint32_t component=0u; component<3u; ++component) {
        if(!haveMaximum || components[component]>maximumComponent) {
          candidate.maximum = rgb;
          candidate.x = x;
          candidate.y = y;
          candidate.channel = static_cast<IOSLinearHDRProofChannel>(component);
          maximumComponent = components[component];
          haveMaximum = true;
          }
        }
      }
    }
  if(!haveMaximum)
    return IOSLinearHDRProofError::InvalidView;
  scan = candidate;
  return IOSLinearHDRProofError::None;
  }
