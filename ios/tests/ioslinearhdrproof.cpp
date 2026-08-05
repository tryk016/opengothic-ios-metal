#include "graphics/ioslinearhdrproof.h"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <span>

namespace {

constexpr size_t HeaderBytes = 160u;
using Fixture = std::array<std::byte,HeaderBytes+16u>;

[[noreturn]] void fail() {
  std::abort();
  }

void require(bool condition) {
  if(!condition)
    fail();
  }

void storeLe32(Fixture& bytes, size_t offset, uint32_t value) {
  for(uint32_t index=0u; index<4u; ++index)
    bytes[offset+index] = std::byte((value >> (index*8u))&0xffu);
  }

void storeLe64(Fixture& bytes, size_t offset, uint64_t value) {
  for(uint32_t index=0u; index<8u; ++index)
    bytes[offset+index] = std::byte((value >> (index*8u))&0xffu);
  }

uint32_t component(uint32_t exponent, uint32_t mantissa, uint32_t bits) {
  return (exponent << bits)|mantissa;
  }

uint32_t pack(
    uint32_t redExponent, uint32_t redMantissa,
    uint32_t greenExponent, uint32_t greenMantissa,
    uint32_t blueExponent, uint32_t blueMantissa) {
  return component(redExponent,redMantissa,6u) |
      (component(greenExponent,greenMantissa,6u) << 11u) |
      (component(blueExponent,blueMantissa,5u) << 22u);
  }

Fixture validFixture() {
  Fixture bytes{};
  constexpr char Magic[] = "RIOSR11";
  for(size_t index=0u; index<sizeof(Magic)-1u; ++index)
    bytes[index] = std::byte(Magic[index]);
  bytes[7u] = std::byte{0};
  bytes[8u] = std::byte{1};
  bytes[10u] = std::byte{160u};
  bytes[12u] = std::byte{1};
  bytes[16u] = std::byte{1};
  storeLe32(bytes,20u,2u);
  storeLe32(bytes,24u,2u);
  storeLe32(bytes,28u,8u);
  storeLe64(bytes,32u,16u);
  storeLe64(bytes,40u,7u);
  storeLe64(bytes,48u,9u);
  for(size_t index=0u; index<16u; ++index)
    bytes[64u+index] = std::byte(index+1u);
  for(size_t index=0u; index<20u; ++index)
    bytes[80u+index] = std::byte(index+1u);
  constexpr char Prefix[] = "RendererIOS.SceneHDR.";
  constexpr char Hex[] = "0123456789abcdef";
  for(size_t index=0u; index<sizeof(Prefix)-1u; ++index)
    bytes[104u+index] = std::byte(Prefix[index]);
  for(size_t index=0u; index<16u; ++index) {
    const uint8_t value = uint8_t(index+1u);
    bytes[104u+(sizeof(Prefix)-1u)+index*2u] = std::byte(Hex[value >> 4u]);
    bytes[105u+(sizeof(Prefix)-1u)+index*2u] = std::byte(Hex[value&0x0fu]);
    }
  storeLe32(bytes,160u,0x882003c0u);
  storeLe32(bytes,164u,pack(15u,0u,17u,0u,15u,0u));
  storeLe32(bytes,168u,0u);
  storeLe32(bytes,172u,pack(0u,1u,0u,1u,0u,1u));
  return bytes;
  }

IOSLinearHDRProofView parsed(Fixture& bytes) {
  IOSLinearHDRProofView view;
  require(iosParseLinearHDRProofV1(bytes,view)==IOSLinearHDRProofError::None);
  return view;
  }

bool sameView(
    const IOSLinearHDRProofView& lhs,
    const IOSLinearHDRProofView& rhs) {
  return lhs.payload.data()==rhs.payload.data() &&
      lhs.payload.size()==rhs.payload.size() &&
      lhs.width==rhs.width && lhs.height==rhs.height &&
      lhs.bytesPerRow==rhs.bytesPerRow &&
      lhs.logicalBytes==rhs.logicalBytes &&
      lhs.targetGeneration==rhs.targetGeneration &&
      lhs.snapshotSequence==rhs.snapshotSequence &&
      lhs.proofId==rhs.proofId && lhs.buildSha==rhs.buildSha;
  }

void requireError(
    std::span<const std::byte> bytes,
    IOSLinearHDRProofError expected) {
  IOSLinearHDRProofView sentinel;
  const std::array<std::byte,1u> sentinelPayload{std::byte{0xa5u}};
  sentinel.payload = sentinelPayload;
  sentinel.width = 77u;
  sentinel.height = 88u;
  sentinel.bytesPerRow = 99u;
  sentinel.logicalBytes = 101u;
  sentinel.targetGeneration = 102u;
  sentinel.snapshotSequence = 103u;
  for(size_t index=0u; index<sentinel.proofId.size(); ++index)
    sentinel.proofId[index] = uint8_t(index+1u);
  for(size_t index=0u; index<sentinel.buildSha.size(); ++index)
    sentinel.buildSha[index] = uint8_t(index+17u);
  const IOSLinearHDRProofView before = sentinel;
  require(iosParseLinearHDRProofV1(bytes,sentinel)==expected);
  require(sameView(sentinel,before));
  }

void testDecoder() {
  IOSLinearHDRRGB decoded{9.f,8.f,7.f};
  require(iosDecodeLinearHDRRG11B10(0x882003c0u,decoded));
  require(decoded==IOSLinearHDRRGB{1.f,2.f,4.f});
  require(iosDecodeLinearHDRRG11B10(0u,decoded));
  require(decoded==IOSLinearHDRRGB{0.f,0.f,0.f});
  require(iosDecodeLinearHDRRG11B10(pack(0u,1u,0u,1u,0u,1u),decoded));
  require(decoded.r==std::ldexp(1.f,-20) &&
          decoded.g==std::ldexp(1.f,-20) && decoded.b==std::ldexp(1.f,-19));

  for(uint32_t invalid : {
      pack(31u,0u,15u,0u,15u,0u),
      pack(15u,0u,31u,0u,15u,0u),
      pack(15u,0u,15u,0u,31u,0u),
      pack(31u,1u,15u,0u,15u,0u),
      pack(15u,0u,31u,1u,15u,0u),
      pack(15u,0u,15u,0u,31u,1u),
      }) {
    const IOSLinearHDRRGB before{9.f,8.f,7.f};
    decoded = before;
    require(!iosDecodeLinearHDRRG11B10(invalid,decoded));
    require(decoded==before);
    }
  }

void testParserAndScan() {
  Fixture bytes = validFixture();
  IOSLinearHDRProofView view = parsed(bytes);
  require(view.width==2u && view.height==2u && view.bytesPerRow==8u &&
          view.logicalBytes==16u && view.payload.size()==16u);

  IOSLinearHDRProofScan scan;
  require(iosScanLinearHDRProofV1(view,scan)==IOSLinearHDRProofError::None);
  require(scan.maximum==IOSLinearHDRRGB{1.f,2.f,4.f});
  require(scan.x==0u && scan.y==0u &&
          scan.channel==IOSLinearHDRProofChannel::B);

  IOSLinearHDRProofScan sentinel;
  sentinel.maximum = {9.f,8.f,7.f};
  sentinel.x = 10u;
  sentinel.y = 11u;
  sentinel.channel = IOSLinearHDRProofChannel::G;
  const IOSLinearHDRProofScan before = sentinel;
  IOSLinearHDRProofView forged = view;
  forged.payload = forged.payload.first(forged.payload.size()-1u);
  require(iosScanLinearHDRProofV1(forged,sentinel)==
          IOSLinearHDRProofError::InvalidView);
  require(sentinel.maximum==before.maximum && sentinel.x==before.x &&
          sentinel.y==before.y && sentinel.channel==before.channel);

  IOSLinearHDRProofView manual;
  manual.width = 1u;
  manual.height = 1u;
  manual.bytesPerRow = 4u;
  manual.logicalBytes = 4u;
  manual.targetGeneration = 1u;
  manual.snapshotSequence = 1u;
  manual.proofId[0] = 1u;
  manual.buildSha[0] = 1u;
  require(iosScanLinearHDRProofV1(manual,sentinel)==
          IOSLinearHDRProofError::InvalidView);

  storeLe32(bytes,160u,pack(31u,0u,15u,0u,15u,0u));
  view = parsed(bytes);
  require(iosScanLinearHDRProofV1(view,sentinel)==
          IOSLinearHDRProofError::InvalidPackedValue);
  require(sentinel.maximum==before.maximum && sentinel.x==before.x &&
          sentinel.y==before.y && sentinel.channel==before.channel);
  }

void testParserFailures() {
  Fixture bytes = validFixture();
  requireError(std::span<const std::byte>(bytes).first(HeaderBytes-1u),
               IOSLinearHDRProofError::InvalidInputSize);

  bytes = validFixture(); bytes[0u] = std::byte{'X'};
  requireError(bytes,IOSLinearHDRProofError::InvalidMagic);
  bytes = validFixture(); bytes[8u] = std::byte{0}; bytes[9u] = std::byte{1};
  requireError(bytes,IOSLinearHDRProofError::UnsupportedSchema);
  bytes = validFixture(); bytes[10u] = std::byte{0};
  requireError(bytes,IOSLinearHDRProofError::InvalidHeaderSize);
  bytes = validFixture(); bytes[12u] = std::byte{2};
  requireError(bytes,IOSLinearHDRProofError::UnsupportedProducerVersion);
  bytes = validFixture(); bytes[16u] = std::byte{2};
  requireError(bytes,IOSLinearHDRProofError::UnsupportedPixelFormat);
  bytes = validFixture(); storeLe32(bytes,20u,0u);
  requireError(bytes,IOSLinearHDRProofError::InvalidExtent);
  bytes = validFixture(); storeLe32(bytes,28u,4u);
  requireError(bytes,IOSLinearHDRProofError::InvalidRowPitch);
  bytes = validFixture(); storeLe64(bytes,32u,8u);
  requireError(bytes,IOSLinearHDRProofError::InvalidLogicalBytes);
  bytes = validFixture(); storeLe64(bytes,40u,0u);
  requireError(bytes,IOSLinearHDRProofError::InvalidIdentity);
  bytes = validFixture(); storeLe64(bytes,48u,0u);
  requireError(bytes,IOSLinearHDRProofError::InvalidIdentity);
  bytes = validFixture(); bytes[64u] = std::byte{0};
  for(size_t index=1u; index<16u; ++index) bytes[64u+index] = std::byte{0};
  requireError(bytes,IOSLinearHDRProofError::InvalidIdentity);
  bytes = validFixture(); bytes[80u] = std::byte{0};
  for(size_t index=1u; index<20u; ++index) bytes[80u+index] = std::byte{0};
  requireError(bytes,IOSLinearHDRProofError::InvalidIdentity);
  bytes = validFixture(); bytes[56u] = std::byte{1};
  requireError(bytes,IOSLinearHDRProofError::InvalidSubresource);
  bytes = validFixture(); bytes[60u] = std::byte{1};
  requireError(bytes,IOSLinearHDRProofError::InvalidSubresource);
  bytes = validFixture(); bytes[100u] = std::byte{1};
  requireError(bytes,IOSLinearHDRProofError::NonZeroReserved);
  bytes = validFixture(); bytes[104u] = std::byte{'X'};
  requireError(bytes,IOSLinearHDRProofError::InvalidResourceLabel);
  bytes = validFixture(); bytes[64u] = std::byte{2};
  requireError(bytes,IOSLinearHDRProofError::InvalidResourceLabel);
  bytes = validFixture(); bytes[157u] = std::byte{'0'};
  requireError(bytes,IOSLinearHDRProofError::InvalidResourceLabel);
  bytes = validFixture(); storeLe64(bytes,32u,UINT64_MAX);
  requireError(bytes,IOSLinearHDRProofError::SizeOverflow);
  bytes = validFixture(); storeLe64(bytes,32u,256u*1024u*1024u+4u);
  requireError(bytes,IOSLinearHDRProofError::InvalidLogicalBytes);
  bytes = validFixture();
  requireError(std::span<const std::byte>(bytes).first(bytes.size()-1u),
               IOSLinearHDRProofError::InvalidInputSize);
  std::array<std::byte,HeaderBytes+17u> trailing{};
  bytes = validFixture();
  for(size_t index=0u; index<bytes.size(); ++index)
    trailing[index] = bytes[index];
  requireError(trailing,IOSLinearHDRProofError::InvalidInputSize);
  }

}

int main() {
  testDecoder();
  testParserAndScan();
  testParserFailures();
  return 0;
  }
