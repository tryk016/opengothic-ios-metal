#include "ioslinearhdrproofproducer.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <limits>

namespace {

constexpr char Hex[] = "0123456789abcdef";
constexpr char LabelPrefix[] = "RendererIOS.SceneHDR.";

bool checkedMultiply(uint64_t lhs, uint64_t rhs, uint64_t& result) noexcept {
  if(lhs!=0u && rhs>std::numeric_limits<uint64_t>::max()/lhs)
    return false;
  result = lhs*rhs;
  return true;
  }

bool allZero(std::span<const uint8_t> bytes) noexcept {
  return std::all_of(bytes.begin(),bytes.end(),
                     [](uint8_t value) { return value==0u; });
  }

void storeLe16(std::span<std::byte> bytes, size_t offset,
               uint16_t value) noexcept {
  bytes[offset] = std::byte(value&0xffu);
  bytes[offset+1u] = std::byte((value >> 8u)&0xffu);
  }

void storeLe32(std::span<std::byte> bytes, size_t offset,
               uint32_t value) noexcept {
  for(uint32_t index=0u; index<4u; ++index)
    bytes[offset+size_t(index)] =
        std::byte((value >> (index*8u))&0xffu);
  }

void storeLe64(std::span<std::byte> bytes, size_t offset,
               uint64_t value) noexcept {
  for(uint32_t index=0u; index<8u; ++index)
    bytes[offset+size_t(index)] =
        std::byte((value >> (index*8u))&0xffu);
  }

bool validMetadataShape(
    const IOSLinearHDRProofMetadata& metadata) noexcept {
  if(metadata.width==0u || metadata.height==0u ||
     metadata.width>IOSLinearHDRProofV1MaximumExtent ||
     metadata.height>IOSLinearHDRProofV1MaximumExtent ||
     metadata.targetGeneration==0u || metadata.snapshotSequence==0u ||
     metadata.logicalBytes>IOSLinearHDRProofV1MaximumPayloadBytes ||
     allZero(metadata.proofId) || allZero(metadata.buildSha))
    return false;
  uint64_t row = 0u;
  uint64_t logical = 0u;
  return checkedMultiply(uint64_t(metadata.width),4u,row) &&
         row==metadata.bytesPerRow &&
         checkedMultiply(row,uint64_t(metadata.height),logical) &&
         logical==metadata.logicalBytes;
  }

bool validMetadata(const IOSLinearHDRProofMetadata& metadata,
                   size_t payloadSize) noexcept {
  return validMetadataShape(metadata) &&
         metadata.logicalBytes==payloadSize;
  }

}

bool iosAdvanceLinearHDRProofProducerState(
    IOSLinearHDRProofProducerState& state,
    IOSLinearHDRProofProducerEvent event) noexcept {
  IOSLinearHDRProofProducerState next = state;
  switch(event) {
    case IOSLinearHDRProofProducerEvent::Arm:
      if(state!=IOSLinearHDRProofProducerState::Disabled)
        return false;
      next = IOSLinearHDRProofProducerState::Armed;
      break;
    case IOSLinearHDRProofProducerEvent::Encode:
      if(state!=IOSLinearHDRProofProducerState::Armed)
        return false;
      next = IOSLinearHDRProofProducerState::Encoded;
      break;
    case IOSLinearHDRProofProducerEvent::Submit:
      if(state!=IOSLinearHDRProofProducerState::Encoded)
        return false;
      next = IOSLinearHDRProofProducerState::Submitted;
      break;
    case IOSLinearHDRProofProducerEvent::Complete:
      if(state!=IOSLinearHDRProofProducerState::Submitted)
        return false;
      next = IOSLinearHDRProofProducerState::Completed;
      break;
    case IOSLinearHDRProofProducerEvent::Publish:
      if(state!=IOSLinearHDRProofProducerState::Completed)
        return false;
      next = IOSLinearHDRProofProducerState::Published;
      break;
    case IOSLinearHDRProofProducerEvent::Fail:
      if(state==IOSLinearHDRProofProducerState::Published ||
         state==IOSLinearHDRProofProducerState::Failed)
        return false;
      next = IOSLinearHDRProofProducerState::Failed;
      break;
    }
  state = next;
  return true;
  }

IOSLinearHDRProofFailureClass iosLinearHDRProofFailureClass(
    IOSLinearHDRProofFailureReason reason) noexcept {
  switch(reason) {
    case IOSLinearHDRProofFailureReason::CopyEncode:
    case IOSLinearHDRProofFailureReason::SubmitAmbiguous:
    case IOSLinearHDRProofFailureReason::Fence:
    case IOSLinearHDRProofFailureReason::Idle:
    case IOSLinearHDRProofFailureReason::Present:
      return IOSLinearHDRProofFailureClass::Gpu;
    case IOSLinearHDRProofFailureReason::Open:
    case IOSLinearHDRProofFailureReason::Write:
    case IOSLinearHDRProofFailureReason::FileFsync:
    case IOSLinearHDRProofFailureReason::Close:
    case IOSLinearHDRProofFailureReason::Rename:
    case IOSLinearHDRProofFailureReason::DirFsync:
    case IOSLinearHDRProofFailureReason::Cleanup:
      return IOSLinearHDRProofFailureClass::Io;
    default:
      return IOSLinearHDRProofFailureClass::Contract;
    }
  }

const char* iosLinearHDRProofFailureClassName(
    IOSLinearHDRProofFailureClass value) noexcept {
  switch(value) {
    case IOSLinearHDRProofFailureClass::Contract: return "contract";
    case IOSLinearHDRProofFailureClass::Gpu:      return "gpu";
    case IOSLinearHDRProofFailureClass::Io:       return "io";
    }
  return "contract";
  }

const char* iosLinearHDRProofFailureReasonName(
    IOSLinearHDRProofFailureReason value) noexcept {
  switch(value) {
    case IOSLinearHDRProofFailureReason::Rng:             return "rng";
    case IOSLinearHDRProofFailureReason::RngZero:         return "rng-zero";
    case IOSLinearHDRProofFailureReason::Sha:             return "sha";
    case IOSLinearHDRProofFailureReason::Layout:          return "layout";
    case IOSLinearHDRProofFailureReason::State:           return "state";
    case IOSLinearHDRProofFailureReason::Target:          return "target";
    case IOSLinearHDRProofFailureReason::Label:           return "label";
    case IOSLinearHDRProofFailureReason::BufferAlloc:     return "buffer-alloc";
    case IOSLinearHDRProofFailureReason::BufferMap:       return "buffer-map";
    case IOSLinearHDRProofFailureReason::CopyEncode:      return "copy-encode";
    case IOSLinearHDRProofFailureReason::SubmitAmbiguous: return "submit-ambiguous";
    case IOSLinearHDRProofFailureReason::Fence:           return "fence";
    case IOSLinearHDRProofFailureReason::Idle:            return "idle";
    case IOSLinearHDRProofFailureReason::Present:         return "present";
    case IOSLinearHDRProofFailureReason::Stale:           return "stale";
    case IOSLinearHDRProofFailureReason::Parse:           return "parse";
    case IOSLinearHDRProofFailureReason::Open:            return "open";
    case IOSLinearHDRProofFailureReason::Write:           return "write";
    case IOSLinearHDRProofFailureReason::FileFsync:       return "file-fsync";
    case IOSLinearHDRProofFailureReason::Close:           return "close";
    case IOSLinearHDRProofFailureReason::Rename:          return "rename";
    case IOSLinearHDRProofFailureReason::DirFsync:        return "dir-fsync";
    case IOSLinearHDRProofFailureReason::Cleanup:         return "cleanup";
    }
  return "state";
  }

bool iosLinearHDRProofParseBuildSha(
    std::string_view text,
    std::array<uint8_t,20u>& bytes) noexcept {
  if(text.size()!=40u)
    return false;
  std::array<uint8_t,20u> parsed{};
  for(size_t index=0u; index<parsed.size(); ++index) {
    const auto nibble = [](char value, uint8_t& result) noexcept {
      if(value>='0' && value<='9') {
        result = uint8_t(value-'0');
        return true;
        }
      if(value>='a' && value<='f') {
        result = uint8_t(value-'a'+10);
        return true;
        }
      return false;
      };
    uint8_t high = 0u;
    uint8_t low = 0u;
    if(!nibble(text[index*2u],high) ||
       !nibble(text[index*2u+1u],low))
      return false;
    parsed[index] = uint8_t((high << 4u)|low);
    }
  if(allZero(parsed))
    return false;
  bytes = parsed;
  return true;
  }

bool iosLinearHDRProofFormatIdentity(
    const std::array<uint8_t,16u>& bytes,
    std::array<char,33u>& text) noexcept {
  if(allZero(bytes))
    return false;
  for(size_t index=0u; index<bytes.size(); ++index) {
    text[index*2u] = Hex[bytes[index] >> 4u];
    text[index*2u+1u] = Hex[bytes[index]&0x0fu];
    }
  text[32u] = '\0';
  return true;
  }

bool iosLinearHDRProofBuildArtifactV1(
    const IOSLinearHDRProofMetadata& metadata,
    std::span<const std::byte> payload,
    std::vector<std::byte>& artifact) noexcept {
  if(!validMetadata(metadata,payload.size()))
    return false;
  if(metadata.logicalBytes>
     std::numeric_limits<size_t>::max()-IOSLinearHDRProofV1HeaderBytes)
    return false;
  std::array<char,33u> id{};
  if(!iosLinearHDRProofFormatIdentity(metadata.proofId,id))
    return false;
  try {
    std::vector<std::byte> candidate(
        IOSLinearHDRProofV1HeaderBytes+payload.size());
    constexpr char Magic[] = "RIOSR11";
    for(size_t index=0u; index<sizeof(Magic)-1u; ++index)
      candidate[index] = std::byte(Magic[index]);
    storeLe16(candidate,8u,1u);
    storeLe16(candidate,10u,
              static_cast<uint16_t>(IOSLinearHDRProofV1HeaderBytes));
    storeLe32(candidate,12u,1u);
    storeLe32(candidate,16u,1u);
    storeLe32(candidate,20u,metadata.width);
    storeLe32(candidate,24u,metadata.height);
    storeLe32(candidate,28u,metadata.bytesPerRow);
    storeLe64(candidate,32u,metadata.logicalBytes);
    storeLe64(candidate,40u,metadata.targetGeneration);
    storeLe64(candidate,48u,metadata.snapshotSequence);
    storeLe32(candidate,56u,0u);
    storeLe32(candidate,60u,0u);
    for(size_t index=0u; index<metadata.proofId.size(); ++index)
      candidate[64u+index] = std::byte(metadata.proofId[index]);
    for(size_t index=0u; index<metadata.buildSha.size(); ++index)
      candidate[80u+index] = std::byte(metadata.buildSha[index]);
    const size_t prefixBytes = sizeof(LabelPrefix)-1u;
    for(size_t index=0u; index<prefixBytes; ++index)
      candidate[104u+index] = std::byte(LabelPrefix[index]);
    for(size_t index=0u; index<32u; ++index)
      candidate[104u+prefixBytes+index] = std::byte(id[index]);
    std::copy(payload.begin(),payload.end(),
              candidate.begin()+
                static_cast<std::ptrdiff_t>(IOSLinearHDRProofV1HeaderBytes));
    artifact = std::move(candidate);
    return true;
    }
  catch(...) {
    return false;
    }
  }

bool iosLinearHDRProofFormatSuccessLine(
    const IOSLinearHDRProofMetadata& metadata,
    std::array<char,255u>& line) noexcept {
  if(!validMetadataShape(metadata))
    return false;
  std::array<char,33u> id{};
  if(!iosLinearHDRProofFormatIdentity(metadata.proofId,id))
    return false;
  std::array<char,41u> sha{};
  for(size_t index=0u; index<metadata.buildSha.size(); ++index) {
    sha[index*2u] = Hex[metadata.buildSha[index] >> 4u];
    sha[index*2u+1u] = Hex[metadata.buildSha[index]&0x0fu];
    }
  const int length = std::snprintf(
      line.data(),line.size(),
      "RendererIOS HDR proof: v=1 id=%s b=%s g=%llu s=%llu w=%u h=%u row=%u bytes=%llu f=r11 m=0 a=0 terminal=C",
      id.data(),sha.data(),
      static_cast<unsigned long long>(metadata.targetGeneration),
      static_cast<unsigned long long>(metadata.snapshotSequence),
      unsigned(metadata.width),unsigned(metadata.height),
      unsigned(metadata.bytesPerRow),
      static_cast<unsigned long long>(metadata.logicalBytes));
  return length>0 && size_t(length)<line.size() && length<255;
  }
