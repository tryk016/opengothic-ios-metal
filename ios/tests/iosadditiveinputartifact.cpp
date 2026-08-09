#include "graphics/iosadditiveinputartifact.h"

#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <fcntl.h>
#include <fstream>
#include <iterator>
#include <span>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {

using Error = IOSAdditiveInputArtifactError;

IOSAdditiveInputRecordV1 record(
    uint64_t sourceId,
    IOSAdditiveInputPhase phase) {
  IOSAdditiveInputRecordV1 value;
  value.sourceId = sourceId;
  value.meshId = sourceId+10000u;
  value.materialId = sourceId+20000u;
  value.textureId = sourceId+30000u;
  value.indexByteOffset = 0u;
  value.indexCount = 30u;
  value.vertexBufferBytes = 360u;
  value.indexBufferBytes = 120u;
  value.materialFlags = phase==IOSAdditiveInputPhase::Additive
      ? IOSAdditiveInputMaterialFlagStaticAdditiveNone : 0u;
  value.vertexStride = 36u;
  value.textureWidth = 4u;
  value.textureHeight = 4u;
  value.textureMipCount = 3u;
  value.textureFormat = IOSAdditiveInputTextureFormat::Rgba8Unorm;
  value.kind = phase==IOSAdditiveInputPhase::Additive
      ? IOSAdditiveInputKind::Static : IOSAdditiveInputKind::Landscape;
  value.category = phase==IOSAdditiveInputPhase::Additive
      ? IOSAdditiveInputCategory::Additive
      : IOSAdditiveInputCategory::Opaque;
  value.animation = IOSAdditiveInputAnimation::None;
  for(std::size_t index=0u; index<value.constants.size(); ++index)
    value.constants[index] = std::byte(uint8_t((sourceId+index)&0xffu));
  return value;
  }

struct Fixture final {
  std::vector<IOSAdditiveInputRecordV1> base;
  std::vector<IOSAdditiveInputRecordV1> additive;
  std::vector<std::byte> bytes;
  };

Fixture fixture() {
  Fixture value;
  value.base.push_back(record(2u,IOSAdditiveInputPhase::Base));
  for(uint64_t index=0u; index<IOSAdditiveInputV1AdditiveRecords; ++index)
    value.additive.push_back(
        record(1000u+index,IOSAdditiveInputPhase::Additive));
  assert(iosBuildAdditiveInputArtifactV1(
      7u,9u,value.base,value.additive,value.bytes)==Error::None);
  return value;
  }

void storeLe32(std::vector<std::byte>& bytes, std::size_t offset,
               uint32_t value) {
  for(uint32_t index=0u; index<4u; ++index)
    bytes[offset+std::size_t(index)] =
        std::byte(uint8_t(value >> (index*8u)));
  }

void storeLe64(std::vector<std::byte>& bytes, std::size_t offset,
               uint64_t value) {
  for(uint32_t index=0u; index<8u; ++index)
    bytes[offset+std::size_t(index)] =
        std::byte(uint8_t(value >> (index*8u)));
  }

void expectError(const std::vector<std::byte>& bytes, Error error) {
  const std::array<std::byte,1u> sentinel = {std::byte{0x7fu}};
  IOSAdditiveInputArtifactViewV1 view;
  view.header = {91u,92u,93u,94u};
  view.basePayload = sentinel;
  const auto before = view.header;
  const auto actual = iosParseAdditiveInputArtifactV1(bytes,view);
  if(actual!=error)
    std::fprintf(stderr,"expected error %u, received %u\n",
                 unsigned(error),unsigned(actual));
  assert(actual==error);
  assert(view.header==before && view.basePayload.data()==sentinel.data());
  }

void validatePublicContract() {
  static_assert(IOSAdditiveInputV1HeaderBytes==64u);
  static_assert(IOSAdditiveInputV1RecordBytes==256u);
  static_assert(IOSAdditiveInputV1ConstantsBytes==160u);
  static_assert(IOSAdditiveInputV1MaximumRecords==100183u);
  static_assert(IOSAdditiveInputV1MaximumPayloadBytes==
                IOSAdditiveInputV1MaximumRecords*
                    IOSAdditiveInputV1RecordBytes);
  static_assert(IOSAdditiveInputMaterialFlagStaticAdditiveNone==1u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputKind::Landscape)==1u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputKind::Static)==2u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputKind::Movable)==3u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputCategory::Opaque)==0u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputCategory::AlphaTest)==1u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputCategory::Additive)==3u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputAnimation::None)==0u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputAnimation::FrameOnly)==1u);
  static_assert(static_cast<uint8_t>(IOSAdditiveInputAnimation::UvOnly)==2u);
  static_assert(static_cast<uint8_t>(
      IOSAdditiveInputAnimation::FrameAndUv)==3u);
  static_assert(noexcept(iosBuildAdditiveInputArtifactV1(
      uint64_t{},uint64_t{},
      std::declval<std::span<const IOSAdditiveInputRecordV1>>(),
      std::declval<std::span<const IOSAdditiveInputRecordV1>>(),
      std::declval<std::vector<std::byte>&>())));
  }

void validateRoundTrip() {
  Fixture value = fixture();
  assert(value.bytes.size()==IOSAdditiveInputV1HeaderBytes+
      (1u+IOSAdditiveInputV1AdditiveRecords)*
          IOSAdditiveInputV1RecordBytes);
  const std::array<uint8_t,12u> prefix = {
      'R','I','O','S','A','0','9',0,1,0,0x45,0x4c};
  for(std::size_t index=0u; index<prefix.size(); ++index)
    assert(std::to_integer<uint8_t>(value.bytes[index])==prefix[index]);

  IOSAdditiveInputArtifactViewV1 view;
  assert(iosParseAdditiveInputArtifactV1(value.bytes,view)==Error::None);
  assert((view.header==IOSAdditiveInputHeaderV1{1u,183u,7u,9u}));
  assert(view.basePayload.size()==256u);
  assert(view.additivePayload.size()==183u*256u);

  IOSAdditiveInputRecordV1 decoded;
  assert(iosDecodeAdditiveInputRecordV1(
      view.basePayload,IOSAdditiveInputPhase::Base,decoded)==Error::None);
  assert(decoded==value.base.front());
  assert(iosDecodeAdditiveInputRecordV1(
      view.additivePayload.first(256u),IOSAdditiveInputPhase::Additive,
      decoded)==Error::None);
  assert(decoded==value.additive.front());

  assert(iosAdditiveInputArtifactV1AcceptsPublication(
      view.header,11u,11u,true,true,true,true,7u,9u));
  for(const auto accepted:{
        iosAdditiveInputArtifactV1AcceptsPublication(
            view.header,0u,0u,true,true,true,true,7u,9u),
        iosAdditiveInputArtifactV1AcceptsPublication(
            view.header,11u,12u,true,true,true,true,7u,9u),
        iosAdditiveInputArtifactV1AcceptsPublication(
            view.header,11u,11u,false,true,true,true,7u,9u),
        iosAdditiveInputArtifactV1AcceptsPublication(
            view.header,11u,11u,true,false,true,true,7u,9u),
        iosAdditiveInputArtifactV1AcceptsPublication(
            view.header,11u,11u,true,true,false,true,7u,9u),
        iosAdditiveInputArtifactV1AcceptsPublication(
            view.header,11u,11u,true,true,true,false,7u,9u),
        iosAdditiveInputArtifactV1AcceptsPublication(
            view.header,11u,11u,true,true,true,true,8u,9u),
        iosAdditiveInputArtifactV1AcceptsPublication(
            view.header,11u,11u,true,true,true,true,7u,10u)})
    assert(!accepted);
  }

void validateRecordTable() {
  IOSAdditiveInputRecordV1 value = record(1u,IOSAdditiveInputPhase::Base);
  assert(iosValidateAdditiveInputRecordV1(
      value,IOSAdditiveInputPhase::Base)==Error::None);
  value.category = IOSAdditiveInputCategory::AlphaTest;
  value.kind = IOSAdditiveInputKind::Static;
  value.animation = IOSAdditiveInputAnimation::FrameOnly;
  value.textureFormat = IOSAdditiveInputTextureFormat::Bc3Rgba;
  assert(iosValidateAdditiveInputRecordV1(
      value,IOSAdditiveInputPhase::Base)==Error::None);
  value.animation = IOSAdditiveInputAnimation::UvOnly;
  assert(iosValidateAdditiveInputRecordV1(
      value,IOSAdditiveInputPhase::Base)==Error::None);

  value.animation = IOSAdditiveInputAnimation::FrameAndUv;
  assert(iosValidateAdditiveInputRecordV1(
      value,IOSAdditiveInputPhase::Base)==Error::None);
  value.animation = static_cast<IOSAdditiveInputAnimation>(255u);
  assert(iosValidateAdditiveInputRecordV1(
      value,IOSAdditiveInputPhase::Base)==Error::UnknownAnimation);

  IOSAdditiveInputRecordV1 additive =
      record(10u,IOSAdditiveInputPhase::Additive);
  assert(iosValidateAdditiveInputRecordV1(
      additive,IOSAdditiveInputPhase::Additive)==Error::None);
  for(const auto mutation:{
        IOSAdditiveInputKind::Landscape,IOSAdditiveInputKind::Movable}) {
    auto changed = additive;
    changed.kind = mutation;
    assert(iosValidateAdditiveInputRecordV1(
        changed,IOSAdditiveInputPhase::Additive)==
        Error::InvalidPhaseRecord);
    }
  auto changed = additive;
  changed.materialFlags = 0u;
  assert(iosValidateAdditiveInputRecordV1(
      changed,IOSAdditiveInputPhase::Additive)==Error::InvalidPhaseRecord);
  changed = additive;
  changed.materialFlags = 2u;
  assert(iosValidateAdditiveInputRecordV1(
      changed,IOSAdditiveInputPhase::Additive)==Error::UnknownMaterialFlags);
  changed = additive;
  changed.textureFormat = static_cast<IOSAdditiveInputTextureFormat>(5u);
  assert(iosValidateAdditiveInputRecordV1(
      changed,IOSAdditiveInputPhase::Additive)==Error::UnknownTextureFormat);
  changed = additive;
  changed.indexCount = UINT64_MAX;
  assert(iosValidateAdditiveInputRecordV1(
      changed,IOSAdditiveInputPhase::Additive)==Error::SizeOverflow);
  changed = additive;
  changed.textureMipCount = 4u;
  assert(iosValidateAdditiveInputRecordV1(
      changed,IOSAdditiveInputPhase::Additive)==Error::InvalidRecord);
  }

void validateBuilderAtomicFailures() {
  Fixture value = fixture();
  const std::vector<std::byte> sentinel = {
      std::byte{1u},std::byte{2u},std::byte{3u}};
  std::vector<std::byte> output = sentinel;
  assert(iosBuildAdditiveInputArtifactV1(
      0u,9u,value.base,value.additive,output)==Error::InvalidIdentity);
  assert(output==sentinel);

  output = sentinel;
  assert(iosBuildAdditiveInputArtifactV1(
      7u,9u,std::span<const IOSAdditiveInputRecordV1>{},
      value.additive,output)==Error::InvalidCounts);
  assert(output==sentinel);
  output = sentinel;
  assert(iosBuildAdditiveInputArtifactV1(
      7u,9u,value.base,
      std::span<const IOSAdditiveInputRecordV1>(value.additive).first(182u),
      output)==Error::InvalidCounts);
  assert(output==sentinel);

  std::swap(value.additive[0],value.additive[1]);
  output = sentinel;
  assert(iosBuildAdditiveInputArtifactV1(
      7u,9u,value.base,value.additive,output)==Error::SourceOrder);
  assert(output==sentinel);
  std::swap(value.additive[0],value.additive[1]);
  value.additive[0].sourceId = value.base[0].sourceId;
  output = sentinel;
  assert(iosBuildAdditiveInputArtifactV1(
      7u,9u,value.base,value.additive,output)==Error::DuplicateSource);
  assert(output==sentinel);
  }

void validateParserMutations() {
  const Fixture source = fixture();
  auto mutate = [&](std::size_t offset, std::byte value, Error error) {
    auto bytes = source.bytes;
    bytes[offset] = value;
    expectError(bytes,error);
  };
  mutate(0u,std::byte{'X'},Error::InvalidMagic);
  mutate(8u,std::byte{2u},Error::UnsupportedSchema);
  mutate(10u,std::byte{0u},Error::InvalidEndian);
  mutate(12u,std::byte{63u},Error::InvalidHeaderSize);
  mutate(33u,std::byte{0u},Error::InvalidRecordSize);
  mutate(36u,std::byte{0u},Error::InvalidConstantsSize);
  mutate(40u,std::byte{0u},Error::InvalidIdentity);
  mutate(48u,std::byte{0u},Error::InvalidIdentity);
  mutate(56u,std::byte{1u},Error::NonZeroHeaderFlags);
  mutate(60u,std::byte{1u},Error::NonZeroHeaderReserved);

  auto bytes = source.bytes;
  storeLe64(bytes,16u,0u);
  expectError(bytes,Error::InvalidCounts);
  bytes = source.bytes;
  storeLe64(bytes,24u,182u);
  expectError(bytes,Error::InvalidCounts);
  bytes = source.bytes;
  bytes.pop_back();
  expectError(bytes,Error::InvalidInputSize);
  bytes = source.bytes;
  bytes.push_back(std::byte{0u});
  expectError(bytes,Error::InvalidInputSize);

  constexpr std::size_t base = IOSAdditiveInputV1HeaderBytes;
  constexpr std::size_t additive = base+IOSAdditiveInputV1RecordBytes;
  mutate(additive+95u,std::byte{1u},Error::NonZeroRecordReserved);
  mutate(additive+92u,std::byte{255u},Error::UnknownKind);
  mutate(additive+93u,std::byte{255u},Error::UnknownCategory);
  mutate(additive+94u,std::byte{255u},Error::UnknownAnimation);
  bytes = source.bytes;
  storeLe32(bytes,additive+88u,5u);
  expectError(bytes,Error::UnknownTextureFormat);
  bytes = source.bytes;
  storeLe64(bytes,additive+64u,2u);
  expectError(bytes,Error::UnknownMaterialFlags);
  mutate(additive+93u,std::byte{0u},Error::InvalidPhaseRecord);
  bytes = source.bytes;
  storeLe64(bytes,additive+40u,0u);
  expectError(bytes,Error::InvalidRecord);

  bytes = source.bytes;
  for(std::size_t index=0u; index<IOSAdditiveInputV1RecordBytes; ++index)
    std::swap(bytes[additive+index],
              bytes[additive+IOSAdditiveInputV1RecordBytes+index]);
  expectError(bytes,Error::SourceOrder);
  bytes = source.bytes;
  storeLe64(bytes,additive,2u);
  expectError(bytes,Error::DuplicateSource);
  }

std::vector<std::byte> readBytes(const std::string& path) {
  std::ifstream input(path,std::ios::binary);
  assert(input);
  const std::vector<unsigned char> raw{
      std::istreambuf_iterator<char>(input),
      std::istreambuf_iterator<char>()};
  std::vector<std::byte> bytes(raw.size());
  for(std::size_t index=0u; index<raw.size(); ++index)
    bytes[index] = std::byte(raw[index]);
  return bytes;
  }

void validatePublication() {
  Fixture value = fixture();
  std::array<char,128u> directoryTemplate{};
  const std::string prefix = "/tmp/rios-additive-input-XXXXXX";
  assert(prefix.size()<directoryTemplate.size());
  for(std::size_t index=0u; index<prefix.size(); ++index)
    directoryTemplate[index] = prefix[index];
  char* directory = ::mkdtemp(directoryTemplate.data());
  assert(directory!=nullptr);

  std::string filename = "sentinel";
  assert(iosAdditiveInputArtifactV1Filename('a',7u,9u,filename));
  assert(filename=="RendererIOS-additive-input-v1-a-g7-s9.bin");
  const std::string beforeFilename = filename;
  assert(!iosAdditiveInputArtifactV1Filename('x',7u,9u,filename));
  assert(filename==beforeFilename);

  std::string published = "unchanged";
  assert(iosPublishAdditiveInputArtifactV1NoClobber(
      directory,'a',7u,9u,value.bytes,"first",published)==
      IOSAdditiveInputPublishResult::Published);
  const std::string expected = std::string(directory)+"/"+beforeFilename;
  assert(published==expected && readBytes(expected)==value.bytes);
  struct stat metadata{};
  assert(::lstat(expected.c_str(),&metadata)==0 && S_ISREG(metadata.st_mode));
  assert((metadata.st_mode&0777)==0600);

  published = "collision-sentinel";
  assert(iosPublishAdditiveInputArtifactV1NoClobber(
      directory,'a',7u,9u,value.bytes,"second",published)==
      IOSAdditiveInputPublishResult::AlreadyExists);
  assert(published=="collision-sentinel" && readBytes(expected)==value.bytes);

  const std::string bName =
      "RendererIOS-additive-input-v1-b-g7-s9.bin";
  const std::string temporary =
      std::string(directory)+"/."+bName+".tmp.busy";
  const int descriptor = ::open(
      temporary.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
  assert(descriptor>=0 && ::close(descriptor)==0);
  published = "temp-sentinel";
  assert(iosPublishAdditiveInputArtifactV1NoClobber(
      directory,'b',7u,9u,value.bytes,"busy",published)==
      IOSAdditiveInputPublishResult::TemporaryExists);
  assert(published=="temp-sentinel");
  const std::string bPath = std::string(directory)+"/"+bName;
  assert(::lstat(bPath.c_str(),&metadata)!=0);

  auto truncated = value.bytes;
  truncated.pop_back();
  published = "invalid-sentinel";
  assert(iosPublishAdditiveInputArtifactV1NoClobber(
      directory,'b',7u,9u,truncated,"invalid",published)==
      IOSAdditiveInputPublishResult::InvalidArtifact);
  assert(published=="invalid-sentinel");

  assert(::unlink(temporary.c_str())==0);
  assert(::unlink(expected.c_str())==0);
  assert(::rmdir(directory)==0);
  }

}

int main() {
  validatePublicContract();
  validateRoundTrip();
  validateRecordTable();
  validateBuilderAtomicFailures();
  validateParserMutations();
  validatePublication();
  return 0;
  }
