#include "iosmultiply2coverageproof.h"

#include <algorithm>
#include <limits>

namespace {

constexpr std::array<std::byte,8u> Magic = {
    std::byte{'R'},std::byte{'I'},std::byte{'O'},std::byte{'S'},
    std::byte{'M'},std::byte{'C'},std::byte{'9'},std::byte{0},
};

bool allZero(std::span<const uint8_t> bytes) noexcept {
  return std::all_of(bytes.begin(),bytes.end(),[](uint8_t value) {
    return value==0u;
  });
}

bool checkedAdd(std::size_t lhs, std::size_t rhs,
                std::size_t& output) noexcept {
  if(lhs>std::numeric_limits<std::size_t>::max()-rhs)
    return false;
  output = lhs+rhs;
  return true;
}

void writeU16(std::vector<std::byte>& bytes, std::size_t offset,
              uint16_t value) noexcept {
  bytes[offset] = std::byte(value&0xffu);
  bytes[offset+1u] = std::byte((value>>8u)&0xffu);
}

void writeU32(std::vector<std::byte>& bytes, std::size_t offset,
              uint32_t value) noexcept {
  for(std::size_t index=0u; index<4u; ++index)
    bytes[offset+index] = std::byte((value>>(index*8u))&0xffu);
}

void writeU64(std::vector<std::byte>& bytes, std::size_t offset,
              uint64_t value) noexcept {
  for(std::size_t index=0u; index<8u; ++index)
    bytes[offset+index] = std::byte((value>>(index*8u))&0xffu);
}

uint16_t readU16(std::span<const std::byte> bytes,
                 std::size_t offset) noexcept {
  return uint16_t(std::to_integer<uint8_t>(bytes[offset])) |
         uint16_t(uint16_t(std::to_integer<uint8_t>(bytes[offset+1u]))<<8u);
}

uint32_t readU32(std::span<const std::byte> bytes,
                 std::size_t offset) noexcept {
  uint32_t value = 0u;
  for(std::size_t index=0u; index<4u; ++index)
    value |= uint32_t(std::to_integer<uint8_t>(bytes[offset+index])) <<
             (index*8u);
  return value;
}

uint64_t readU64(std::span<const std::byte> bytes,
                 std::size_t offset) noexcept {
  uint64_t value = 0u;
  for(std::size_t index=0u; index<8u; ++index)
    value |= uint64_t(std::to_integer<uint8_t>(bytes[offset+index])) <<
             (index*8u);
  return value;
}

IOSMultiply2CoverageProofError validateMetadata(
    const IOSMultiply2CoverageProofMetadata& metadata) noexcept {
  if(metadata.width==0u || metadata.height==0u ||
     metadata.width>IOSMultiply2CoverageProofV1MaximumExtent ||
     metadata.height>IOSMultiply2CoverageProofV1MaximumExtent)
    return IOSMultiply2CoverageProofError::InvalidExtent;
  if(metadata.bytesPerRow!=metadata.width)
    return IOSMultiply2CoverageProofError::InvalidRowPitch;
  if(metadata.sampleCount!=1u)
    return IOSMultiply2CoverageProofError::InvalidSampleCount;
  const uint64_t expected =
      uint64_t(metadata.width)*uint64_t(metadata.height);
  if(metadata.payloadBytes!=expected ||
     expected>IOSMultiply2CoverageProofV1MaximumPayloadBytes)
    return IOSMultiply2CoverageProofError::InvalidPayloadSize;
  if(metadata.targetGeneration==0u || metadata.snapshotSequence==0u ||
     metadata.sourceId==0u || metadata.indexCount==0u ||
     allZero(metadata.proofId) || allZero(metadata.buildSha))
    return IOSMultiply2CoverageProofError::InvalidIdentity;
  const IOSMultiply2CoverageRect exact = {
      0u,0u,metadata.width,metadata.height};
  if(metadata.viewport!=exact || metadata.scissor!=exact)
    return IOSMultiply2CoverageProofError::InvalidViewport;
  return IOSMultiply2CoverageProofError::None;
}

IOSMultiply2CoverageProofError validatePayload(
    std::span<const std::byte> payload) noexcept {
  bool covered = false;
  for(const std::byte value:payload) {
    const uint8_t byte = std::to_integer<uint8_t>(value);
    if(byte>1u)
      return IOSMultiply2CoverageProofError::InvalidPayload;
    covered = covered || byte==1u;
  }
  return covered ? IOSMultiply2CoverageProofError::None
                 : IOSMultiply2CoverageProofError::MissingCoverage;
}

}

bool iosBuildMultiply2CoverageProofV1(
    const IOSMultiply2CoverageProofMetadata& metadata,
    std::span<const std::byte> payload,
    std::vector<std::byte>& artifact) noexcept {
  artifact.clear();
  if(validateMetadata(metadata)!=IOSMultiply2CoverageProofError::None ||
     payload.size()!=metadata.payloadBytes ||
     validatePayload(payload)!=IOSMultiply2CoverageProofError::None)
    return false;
  std::size_t bytes = 0u;
  if(!checkedAdd(IOSMultiply2CoverageProofV1HeaderBytes,payload.size(),bytes))
    return false;
  try {
    std::vector<std::byte> candidate(bytes,std::byte{0});
    std::copy(Magic.begin(),Magic.end(),candidate.begin());
    writeU16(candidate,8u,1u);
    writeU16(candidate,10u,0x4c45u);
    writeU32(candidate,12u,
             static_cast<uint32_t>(IOSMultiply2CoverageProofV1HeaderBytes));
    writeU32(candidate,16u,metadata.width);
    writeU32(candidate,20u,metadata.height);
    writeU32(candidate,24u,metadata.bytesPerRow);
    writeU32(candidate,28u,metadata.sampleCount);
    writeU64(candidate,32u,metadata.payloadBytes);
    writeU64(candidate,40u,metadata.targetGeneration);
    writeU64(candidate,48u,metadata.snapshotSequence);
    writeU64(candidate,56u,metadata.sourceId);
    writeU64(candidate,64u,metadata.indexByteOffset);
    writeU64(candidate,72u,metadata.indexCount);
    writeU32(candidate,80u,metadata.viewport.x);
    writeU32(candidate,84u,metadata.viewport.y);
    writeU32(candidate,88u,metadata.viewport.width);
    writeU32(candidate,92u,metadata.viewport.height);
    writeU32(candidate,96u,metadata.scissor.x);
    writeU32(candidate,100u,metadata.scissor.y);
    writeU32(candidate,104u,metadata.scissor.width);
    writeU32(candidate,108u,metadata.scissor.height);
    for(std::size_t index=0u; index<metadata.proofId.size(); ++index)
      candidate[112u+index] = std::byte(metadata.proofId[index]);
    for(std::size_t index=0u; index<metadata.buildSha.size(); ++index)
      candidate[128u+index] = std::byte(metadata.buildSha[index]);
    std::copy(payload.begin(),payload.end(),
              candidate.begin()+
                  static_cast<std::ptrdiff_t>(
                      IOSMultiply2CoverageProofV1HeaderBytes));
    artifact = std::move(candidate);
    return true;
  }
  catch(...) {
    artifact.clear();
    return false;
  }
}

IOSMultiply2CoverageProofError iosParseMultiply2CoverageProofV1(
    std::span<const std::byte> artifact,
    IOSMultiply2CoverageProofView& view) noexcept {
  view = {};
  if(artifact.size()<IOSMultiply2CoverageProofV1HeaderBytes)
    return IOSMultiply2CoverageProofError::InvalidInputSize;
  if(!std::equal(Magic.begin(),Magic.end(),artifact.begin()))
    return IOSMultiply2CoverageProofError::InvalidMagic;
  if(readU16(artifact,8u)!=1u || readU16(artifact,10u)!=0x4c45u)
    return IOSMultiply2CoverageProofError::UnsupportedSchema;
  if(readU32(artifact,12u)!=IOSMultiply2CoverageProofV1HeaderBytes)
    return IOSMultiply2CoverageProofError::InvalidHeaderSize;
  IOSMultiply2CoverageProofMetadata metadata;
  metadata.width = readU32(artifact,16u);
  metadata.height = readU32(artifact,20u);
  metadata.bytesPerRow = readU32(artifact,24u);
  metadata.sampleCount = readU32(artifact,28u);
  metadata.payloadBytes = readU64(artifact,32u);
  metadata.targetGeneration = readU64(artifact,40u);
  metadata.snapshotSequence = readU64(artifact,48u);
  metadata.sourceId = readU64(artifact,56u);
  metadata.indexByteOffset = readU64(artifact,64u);
  metadata.indexCount = readU64(artifact,72u);
  metadata.viewport = {
      readU32(artifact,80u),readU32(artifact,84u),
      readU32(artifact,88u),readU32(artifact,92u)};
  metadata.scissor = {
      readU32(artifact,96u),readU32(artifact,100u),
      readU32(artifact,104u),readU32(artifact,108u)};
  for(std::size_t index=0u; index<metadata.proofId.size(); ++index)
    metadata.proofId[index] =
        std::to_integer<uint8_t>(artifact[112u+index]);
  for(std::size_t index=0u; index<metadata.buildSha.size(); ++index)
    metadata.buildSha[index] =
        std::to_integer<uint8_t>(artifact[128u+index]);
  if(readU32(artifact,148u)!=0u || readU64(artifact,152u)!=0u)
    return IOSMultiply2CoverageProofError::NonZeroReserved;
  const auto metadataError = validateMetadata(metadata);
  if(metadataError!=IOSMultiply2CoverageProofError::None)
    return metadataError;
  if(metadata.payloadBytes>std::numeric_limits<std::size_t>::max())
    return IOSMultiply2CoverageProofError::SizeOverflow;
  std::size_t expected = 0u;
  if(!checkedAdd(IOSMultiply2CoverageProofV1HeaderBytes,
                 static_cast<std::size_t>(metadata.payloadBytes),expected))
    return IOSMultiply2CoverageProofError::SizeOverflow;
  if(artifact.size()!=expected)
    return IOSMultiply2CoverageProofError::InvalidInputSize;
  const auto payload = artifact.subspan(
      IOSMultiply2CoverageProofV1HeaderBytes,
      static_cast<std::size_t>(metadata.payloadBytes));
  const auto payloadError = validatePayload(payload);
  if(payloadError!=IOSMultiply2CoverageProofError::None)
    return payloadError;
  view.metadata = metadata;
  view.payload = payload;
  return IOSMultiply2CoverageProofError::None;
}
