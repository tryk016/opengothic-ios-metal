#include "graphics/iosmultiply2inputartifact.h"

#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

using Error = IOSMultiply2InputArtifactError;

IOSMultiply2InputRecordV1 record(
    uint64_t sourceId,
    IOSMultiply2InputPhase phase) {
  IOSMultiply2InputRecordV1 value;
  value.sourceId = sourceId;
  value.meshId = sourceId+10000u;
  value.materialId = sourceId+20000u;
  value.textureId = sourceId+30000u;
  value.indexCount = 30u;
  value.vertexBufferBytes = 360u;
  value.indexBufferBytes = 120u;
  value.materialFlags = phase==IOSMultiply2InputPhase::Multiply2
      ? IOSMultiply2InputMaterialFlagStaticNone : 0u;
  value.vertexStride = 36u;
  value.textureWidth = 4u;
  value.textureHeight = 4u;
  value.textureMipCount = 3u;
  value.kind = phase==IOSMultiply2InputPhase::Multiply2
      ? IOSMultiply2InputKind::Static : IOSMultiply2InputKind::Landscape;
  value.category = phase==IOSMultiply2InputPhase::Multiply2
      ? IOSMultiply2InputCategory::Multiply2
      : IOSMultiply2InputCategory::Opaque;
  value.phase = phase;
  for(std::size_t index=0u; index<value.constants.size(); ++index)
    value.constants[index] = std::byte(uint8_t((sourceId+index)&0xffu));
  return value;
  }

struct Fixture final {
  std::vector<IOSMultiply2InputRecordV1> base;
  std::vector<IOSMultiply2InputRecordV1> multiply2;
  std::vector<std::byte> bytes;
  };

Fixture fixture() {
  Fixture value;
  value.base.push_back(record(2u,IOSMultiply2InputPhase::Base));
  value.multiply2.push_back(
      record(7u,IOSMultiply2InputPhase::Multiply2));
  assert(iosBuildMultiply2InputArtifactV1(
      11u,1u,value.base,value.multiply2,value.bytes)==Error::None);
  return value;
  }

void storeLe64(std::vector<std::byte>& bytes,
               std::size_t offset,
               uint64_t value) {
  for(uint32_t index=0u; index<8u; ++index)
    bytes[offset+std::size_t(index)] =
        std::byte(uint8_t(value >> (index*8u)));
  }

void storeLe32(std::vector<std::byte>& bytes,
               std::size_t offset,
               uint32_t value) {
  for(uint32_t index=0u; index<4u; ++index)
    bytes[offset+std::size_t(index)] =
        std::byte(uint8_t(value >> (index*8u)));
  }

void expectError(const std::vector<std::byte>& bytes, Error expected) {
  IOSMultiply2InputArtifactViewV1 view;
  view.header = {91u,92u,93u,94u};
  const auto before = view.header;
  assert(iosParseMultiply2InputArtifactV1(bytes,view)==expected);
  assert(view.header==before);
  }

void validateLayoutAndRoundTrip() {
  static_assert(IOSMultiply2InputV1HeaderBytes==64u);
  static_assert(IOSMultiply2InputV1RecordBytes==256u);
  static_assert(IOSMultiply2InputV1ConstantsBytes==160u);
  static_assert(IOSMultiply2InputV1MaximumRecords==100001u);
  static_assert(IOSMultiply2InputV1MaximumPayloadBytes==25600256u);
  static_assert(static_cast<uint8_t>(IOSMultiply2InputCategory::Multiply2)==5u);
  static_assert(static_cast<uint8_t>(IOSMultiply2InputPhase::Base)==0u);
  static_assert(static_cast<uint8_t>(IOSMultiply2InputPhase::Multiply2)==1u);
  static_assert(IOSMultiply2InputMaterialFlagStaticNone==2u);

  const Fixture value = fixture();
  assert(value.bytes.size()==64u+2u*256u);
  const std::array<uint8_t,12u> prefix = {
      'R','I','O','S','M','2','9',0,1,0,0x45,0x4c};
  for(std::size_t index=0u; index<prefix.size(); ++index)
    assert(std::to_integer<uint8_t>(value.bytes[index])==prefix[index]);
  assert(std::to_integer<uint8_t>(value.bytes[64u+95u])==0u);
  assert(std::to_integer<uint8_t>(value.bytes[64u+256u+95u])==1u);

  IOSMultiply2InputArtifactViewV1 view;
  assert(iosParseMultiply2InputArtifactV1(value.bytes,view)==Error::None);
  assert((view.header==IOSMultiply2InputHeaderV1{1u,1u,11u,1u}));
  IOSMultiply2InputRecordV1 decoded;
  assert(iosDecodeMultiply2InputRecordV1(view.basePayload,decoded)==
         Error::None);
  assert(decoded==value.base.front());
  assert(iosDecodeMultiply2InputRecordV1(view.multiply2Payload,decoded)==
         Error::None);
  assert(decoded==value.multiply2.front());
  assert(iosMultiply2InputArtifactV1AcceptsPublication(
      view.header,5u,5u,true,true,true,true,11u,1u));
  assert(!iosMultiply2InputArtifactV1AcceptsPublication(
      view.header,5u,6u,true,true,true,true,11u,1u));
  }

void validateMutations() {
  const Fixture value = fixture();
  auto changed = value.bytes;
  changed[0u] = std::byte{'X'};
  expectError(changed,Error::InvalidMagic);
  changed = value.bytes;
  changed[8u] = std::byte{2u};
  expectError(changed,Error::UnsupportedSchema);
  changed = value.bytes;
  changed[10u] = std::byte{0u};
  expectError(changed,Error::InvalidEndian);
  changed = value.bytes;
  changed[12u] = std::byte{63u};
  expectError(changed,Error::InvalidHeaderSize);
  changed = value.bytes;
  changed[33u] = std::byte{0u};
  expectError(changed,Error::InvalidRecordSize);
  changed = value.bytes;
  changed[36u] = std::byte{0u};
  expectError(changed,Error::InvalidConstantsSize);
  changed = value.bytes;
  changed[56u] = std::byte{1u};
  expectError(changed,Error::NonZeroHeaderFlags);
  changed = value.bytes;
  changed[60u] = std::byte{1u};
  expectError(changed,Error::NonZeroHeaderReserved);
  changed = value.bytes;
  changed[95u+64u] = std::byte{1u};
  expectError(changed,Error::InvalidPhaseRecord);
  changed = value.bytes;
  changed[95u+64u+256u] = std::byte{0u};
  expectError(changed,Error::InvalidPhaseRecord);
  changed = value.bytes;
  changed[93u+64u+256u] = std::byte{3u};
  expectError(changed,Error::UnknownCategory);
  changed = value.bytes;
  changed[64u+92u] = std::byte{0xffu};
  expectError(changed,Error::UnknownKind);
  changed = value.bytes;
  changed[64u+94u] = std::byte{0xffu};
  expectError(changed,Error::UnknownAnimation);
  changed = value.bytes;
  storeLe32(changed,64u+88u,0xffffffffu);
  expectError(changed,Error::UnknownTextureFormat);
  changed = value.bytes;
  storeLe64(changed,64u+64u,4u);
  expectError(changed,Error::UnknownMaterialFlags);
  changed = value.bytes;
  storeLe64(changed,64u+32u,
            std::numeric_limits<uint64_t>::max()-3u);
  expectError(changed,Error::SizeOverflow);
  changed = value.bytes;
  storeLe64(changed,64u+256u,2u);
  expectError(changed,Error::DuplicateSource);
  changed = value.bytes;
  storeLe64(changed,16u,std::numeric_limits<uint64_t>::max());
  expectError(changed,Error::InvalidCounts);
  changed = value.bytes;
  changed.pop_back();
  expectError(changed,Error::InvalidInputSize);
  changed = value.bytes;
  changed.push_back(std::byte{0u});
  expectError(changed,Error::InvalidInputSize);

  std::vector<IOSMultiply2InputRecordV1> unorderedBase = {
      record(3u,IOSMultiply2InputPhase::Base),
      record(2u,IOSMultiply2InputPhase::Base)};
  std::vector<IOSMultiply2InputRecordV1> target = {
      record(7u,IOSMultiply2InputPhase::Multiply2)};
  std::vector<std::byte> output{std::byte{0x5au}};
  const auto before = output;
  assert(iosBuildMultiply2InputArtifactV1(
      11u,1u,unorderedBase,target,output)==Error::SourceOrder);
  assert(output==before);
  }

void validatePublication() {
  Fixture value = fixture();
  const std::filesystem::path root =
      std::filesystem::temp_directory_path()/
      ("iosmultiply2-"+std::to_string(static_cast<unsigned long long>(
          ::getpid())));
  std::filesystem::remove_all(root);
  std::filesystem::create_directory(root);
  assert(::chmod(root.c_str(),0700)==0);
  const mode_t previous = ::umask(077);
  std::string path;
  std::vector<std::byte> publishedBytes;
  assert(iosPublishMultiply2InputArtifactV1NoClobber(
      root.string(),'a',11u,1u,value.bytes,"fixture",path,publishedBytes)==
      IOSMultiply2InputPublishResult::Published);
  ::umask(previous);
  assert(std::filesystem::path(path).filename()==
         "RendererIOS-multiply2-input-v1-a-g11-s1.bin");
  struct stat status{};
  assert(::lstat(path.c_str(),&status)==0);
  assert((status.st_mode&0777u)==0600u);
  std::ifstream stream(path,std::ios::binary);
  const std::vector<char> raw(
      (std::istreambuf_iterator<char>(stream)),
      std::istreambuf_iterator<char>());
  assert(raw.size()==value.bytes.size());
  assert(publishedBytes==value.bytes);
  assert(status.st_nlink==1u);
  std::string ignored;
  std::vector<std::byte> ignoredBytes;
  assert(iosPublishMultiply2InputArtifactV1NoClobber(
      root.string(),'a',11u,1u,value.bytes,"again",ignored,ignoredBytes)==
      IOSMultiply2InputPublishResult::AlreadyExists);
  assert(!iosMultiply2InputArtifactV1Filename('x',11u,1u,ignored));
  assert(!iosMultiply2InputArtifactV1Filename('a',0u,1u,ignored));
  assert(!iosMultiply2InputArtifactV1Filename('a',11u,0u,ignored));
  assert(iosPublishMultiply2InputArtifactV1NoClobber(
      root.string(),'a',11u,1u,value.bytes,"../escape",ignored,ignoredBytes)==
      IOSMultiply2InputPublishResult::InvalidArgument);
  const auto publicRoot = root.string()+"-public";
  std::filesystem::create_directory(publicRoot);
  assert(::chmod(publicRoot.c_str(),0755)==0);
  assert(iosPublishMultiply2InputArtifactV1NoClobber(
      publicRoot,'a',11u,1u,value.bytes,"public",ignored,ignoredBytes)==
      IOSMultiply2InputPublishResult::DirectoryPolicyFailed);
  std::filesystem::remove_all(publicRoot);
  std::filesystem::remove_all(root);
  }

}

int main() {
  validateLayoutAndRoundTrip();
  validateMutations();
  validatePublication();
  }
