#include "iosmultiply2inputartifact.h"

#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <limits>
#include <new>
#include <sys/stat.h>
#include <unistd.h>

namespace {

constexpr std::array<uint8_t,8u> Magic = {
    uint8_t('R'),uint8_t('I'),uint8_t('O'),uint8_t('S'),
    uint8_t('M'),uint8_t('2'),uint8_t('9'),0u};
constexpr uint16_t SchemaVersion = 1u;
constexpr uint16_t LittleEndianMarker = 0x4c45u;
constexpr uint32_t VertexStride = 36u;
constexpr uint64_t IndexStride = 4u;

uint8_t byteAt(std::span<const std::byte> bytes, std::size_t offset) noexcept {
  return std::to_integer<uint8_t>(bytes[offset]);
  }

uint16_t loadLe16(std::span<const std::byte> bytes,
                  std::size_t offset) noexcept {
  return uint16_t(byteAt(bytes,offset)) |
      uint16_t(uint16_t(byteAt(bytes,offset+1u)) << 8u);
  }

uint32_t loadLe32(std::span<const std::byte> bytes,
                  std::size_t offset) noexcept {
  return uint32_t(byteAt(bytes,offset)) |
      (uint32_t(byteAt(bytes,offset+1u)) << 8u) |
      (uint32_t(byteAt(bytes,offset+2u)) << 16u) |
      (uint32_t(byteAt(bytes,offset+3u)) << 24u);
  }

uint64_t loadLe64(std::span<const std::byte> bytes,
                  std::size_t offset) noexcept {
  uint64_t value = 0u;
  for(uint32_t index=0u; index<8u; ++index)
    value |= uint64_t(byteAt(bytes,offset+std::size_t(index))) << (index*8u);
  return value;
  }

void storeLe16(std::span<std::byte> bytes, std::size_t offset,
               uint16_t value) noexcept {
  for(uint32_t index=0u; index<2u; ++index)
    bytes[offset+std::size_t(index)] =
        std::byte(uint8_t(value >> (index*8u)));
  }

void storeLe32(std::span<std::byte> bytes, std::size_t offset,
               uint32_t value) noexcept {
  for(uint32_t index=0u; index<4u; ++index)
    bytes[offset+std::size_t(index)] =
        std::byte(uint8_t(value >> (index*8u)));
  }

void storeLe64(std::span<std::byte> bytes, std::size_t offset,
               uint64_t value) noexcept {
  for(uint32_t index=0u; index<8u; ++index)
    bytes[offset+std::size_t(index)] =
        std::byte(uint8_t(value >> (index*8u)));
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

bool countsAndSize(uint64_t baseCount, uint64_t multiply2Count,
                   uint64_t& payloadBytes,
                   uint64_t& artifactBytes) noexcept {
  if(baseCount<IOSMultiply2InputV1MinimumBaseRecords ||
     baseCount>IOSMultiply2InputV1MaximumBaseRecords ||
     multiply2Count!=IOSMultiply2InputV1Multiply2Records)
    return false;
  uint64_t records = 0u;
  return checkedAdd(baseCount,multiply2Count,records) &&
      records<=IOSMultiply2InputV1MaximumRecords &&
      checkedMultiply(records,IOSMultiply2InputV1RecordBytes,payloadBytes) &&
      payloadBytes<=IOSMultiply2InputV1MaximumPayloadBytes &&
      checkedAdd(IOSMultiply2InputV1HeaderBytes,payloadBytes,artifactBytes);
  }

bool validKind(IOSMultiply2InputKind kind) noexcept {
  return kind==IOSMultiply2InputKind::Landscape ||
      kind==IOSMultiply2InputKind::Static ||
      kind==IOSMultiply2InputKind::Movable;
  }

bool validAnimation(IOSMultiply2InputAnimation animation) noexcept {
  return animation==IOSMultiply2InputAnimation::None ||
      animation==IOSMultiply2InputAnimation::FrameOnly ||
      animation==IOSMultiply2InputAnimation::UvOnly ||
      animation==IOSMultiply2InputAnimation::FrameAndUv;
  }

bool validFormat(IOSMultiply2InputTextureFormat format) noexcept {
  return format==IOSMultiply2InputTextureFormat::Rgba8Unorm ||
      format==IOSMultiply2InputTextureFormat::Bc1Rgba ||
      format==IOSMultiply2InputTextureFormat::Bc2Rgba ||
      format==IOSMultiply2InputTextureFormat::Bc3Rgba;
  }

void encodeRecord(const IOSMultiply2InputRecordV1& record,
                  std::span<std::byte> encoded) noexcept {
  storeLe64(encoded,0u,record.sourceId);
  storeLe64(encoded,8u,record.meshId);
  storeLe64(encoded,16u,record.materialId);
  storeLe64(encoded,24u,record.textureId);
  storeLe64(encoded,32u,record.indexByteOffset);
  storeLe64(encoded,40u,record.indexCount);
  storeLe64(encoded,48u,record.vertexBufferBytes);
  storeLe64(encoded,56u,record.indexBufferBytes);
  storeLe64(encoded,64u,record.materialFlags);
  storeLe32(encoded,72u,record.vertexStride);
  storeLe32(encoded,76u,record.textureWidth);
  storeLe32(encoded,80u,record.textureHeight);
  storeLe32(encoded,84u,record.textureMipCount);
  storeLe32(encoded,88u,static_cast<uint32_t>(record.textureFormat));
  encoded[92u] = std::byte(static_cast<uint8_t>(record.kind));
  encoded[93u] = std::byte(static_cast<uint8_t>(record.category));
  encoded[94u] = std::byte(static_cast<uint8_t>(record.animation));
  encoded[95u] = std::byte(static_cast<uint8_t>(record.phase));
  for(std::size_t index=0u; index<record.constants.size(); ++index)
    encoded[96u+index] = record.constants[index];
  }

bool safeLeaf(std::string_view value) noexcept {
  if(value.empty() || value=="." || value=="..")
    return false;
  for(const char character:value)
    if(character=='/' || character=='\0')
      return false;
  return true;
  }

bool safeTag(std::string_view value) noexcept {
  if(value.empty() || value.size()>64u)
    return false;
  for(const char character:value) {
    const bool valid = (character>='a' && character<='z') ||
        (character>='A' && character<='Z') ||
        (character>='0' && character<='9') || character=='-' ||
        character=='_';
    if(!valid)
      return false;
    }
  return true;
  }

bool unlinkRetry(int directory, const char* leaf) noexcept {
  for(;;) {
    if(::unlinkat(directory,leaf,0)==0)
      return true;
    if(errno!=EINTR)
      return false;
    }
  }

}

IOSMultiply2InputArtifactError iosValidateMultiply2InputRecordV1(
    const IOSMultiply2InputRecordV1& record) noexcept {
  if(!validKind(record.kind))
    return IOSMultiply2InputArtifactError::UnknownKind;
  if(record.category!=IOSMultiply2InputCategory::Opaque &&
     record.category!=IOSMultiply2InputCategory::AlphaTest &&
     record.category!=IOSMultiply2InputCategory::Multiply2)
    return IOSMultiply2InputArtifactError::UnknownCategory;
  if(!validAnimation(record.animation))
    return IOSMultiply2InputArtifactError::UnknownAnimation;
  if(!validFormat(record.textureFormat))
    return IOSMultiply2InputArtifactError::UnknownTextureFormat;
  if((record.materialFlags&~IOSMultiply2InputMaterialFlagStaticNone)!=0u)
    return IOSMultiply2InputArtifactError::UnknownMaterialFlags;
  if(record.phase==IOSMultiply2InputPhase::Base) {
    if((record.category!=IOSMultiply2InputCategory::Opaque &&
        record.category!=IOSMultiply2InputCategory::AlphaTest) ||
       record.materialFlags!=0u)
      return IOSMultiply2InputArtifactError::InvalidPhaseRecord;
    }
  else if(record.phase==IOSMultiply2InputPhase::Multiply2) {
    if(record.kind!=IOSMultiply2InputKind::Static ||
       record.category!=IOSMultiply2InputCategory::Multiply2 ||
       record.animation!=IOSMultiply2InputAnimation::None ||
       record.materialFlags!=IOSMultiply2InputMaterialFlagStaticNone)
      return IOSMultiply2InputArtifactError::InvalidPhaseRecord;
    }
  else {
    return IOSMultiply2InputArtifactError::InvalidPhaseRecord;
    }
  if(record.sourceId==0u || record.meshId==0u || record.materialId==0u ||
     record.textureId==0u || record.vertexStride!=VertexStride ||
     record.vertexBufferBytes<record.vertexStride ||
     record.vertexBufferBytes%record.vertexStride!=0u ||
     record.indexBufferBytes<IndexStride ||
     record.indexBufferBytes%IndexStride!=0u ||
     record.indexByteOffset%IndexStride!=0u || record.indexCount==0u ||
     record.indexCount%3u!=0u || record.textureWidth==0u ||
     record.textureHeight==0u || record.textureMipCount==0u)
    return IOSMultiply2InputArtifactError::InvalidRecord;
  uint64_t indexBytes = 0u;
  uint64_t rangeEnd = 0u;
  if(!checkedMultiply(record.indexCount,IndexStride,indexBytes) ||
     !checkedAdd(record.indexByteOffset,indexBytes,rangeEnd))
    return IOSMultiply2InputArtifactError::SizeOverflow;
  if(rangeEnd>record.indexBufferBytes)
    return IOSMultiply2InputArtifactError::InvalidRecord;
  uint32_t maximumMipCount = 1u;
  uint32_t maximumExtent = record.textureWidth>record.textureHeight
      ? record.textureWidth : record.textureHeight;
  while(maximumExtent>1u) {
    maximumExtent /= 2u;
    ++maximumMipCount;
    }
  return record.textureMipCount<=maximumMipCount
      ? IOSMultiply2InputArtifactError::None
      : IOSMultiply2InputArtifactError::InvalidRecord;
  }

IOSMultiply2InputArtifactError iosBuildMultiply2InputArtifactV1(
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::span<const IOSMultiply2InputRecordV1> base,
    std::span<const IOSMultiply2InputRecordV1> multiply2,
    std::vector<std::byte>& artifact) noexcept {
  if(targetGeneration==0u || snapshotSequence==0u)
    return IOSMultiply2InputArtifactError::InvalidIdentity;
  uint64_t payloadBytes = 0u;
  uint64_t artifactBytes = 0u;
  if(!countsAndSize(base.size(),multiply2.size(),payloadBytes,artifactBytes))
    return IOSMultiply2InputArtifactError::InvalidCounts;
  uint64_t previous = 0u;
  for(const auto& record:base) {
    if(record.phase!=IOSMultiply2InputPhase::Base)
      return IOSMultiply2InputArtifactError::InvalidPhaseRecord;
    const auto error = iosValidateMultiply2InputRecordV1(record);
    if(error!=IOSMultiply2InputArtifactError::None)
      return error;
    if(previous>=record.sourceId)
      return previous==record.sourceId
          ? IOSMultiply2InputArtifactError::DuplicateSource
          : IOSMultiply2InputArtifactError::SourceOrder;
    previous = record.sourceId;
    }
  previous = 0u;
  for(const auto& record:multiply2) {
    if(record.phase!=IOSMultiply2InputPhase::Multiply2)
      return IOSMultiply2InputArtifactError::InvalidPhaseRecord;
    const auto error = iosValidateMultiply2InputRecordV1(record);
    if(error!=IOSMultiply2InputArtifactError::None)
      return error;
    if(previous>=record.sourceId)
      return previous==record.sourceId
          ? IOSMultiply2InputArtifactError::DuplicateSource
          : IOSMultiply2InputArtifactError::SourceOrder;
    previous = record.sourceId;
    }
  for(const auto& left:base)
    for(const auto& right:multiply2)
      if(left.sourceId==right.sourceId)
        return IOSMultiply2InputArtifactError::DuplicateSource;
  try {
    std::vector<std::byte> candidate(static_cast<std::size_t>(artifactBytes));
    for(std::size_t index=0u; index<Magic.size(); ++index)
      candidate[index] = std::byte(Magic[index]);
    storeLe16(candidate,8u,SchemaVersion);
    storeLe16(candidate,10u,LittleEndianMarker);
    storeLe32(candidate,12u,IOSMultiply2InputV1HeaderBytes);
    storeLe64(candidate,16u,base.size());
    storeLe64(candidate,24u,multiply2.size());
    storeLe32(candidate,32u,IOSMultiply2InputV1RecordBytes);
    storeLe32(candidate,36u,IOSMultiply2InputV1ConstantsBytes);
    storeLe64(candidate,40u,targetGeneration);
    storeLe64(candidate,48u,snapshotSequence);
    storeLe32(candidate,56u,0u);
    storeLe32(candidate,60u,0u);
    std::size_t offset = IOSMultiply2InputV1HeaderBytes;
    for(const auto& record:base) {
      encodeRecord(record,std::span<std::byte>(candidate).subspan(
          offset,IOSMultiply2InputV1RecordBytes));
      offset += IOSMultiply2InputV1RecordBytes;
      }
    for(const auto& record:multiply2) {
      encodeRecord(record,std::span<std::byte>(candidate).subspan(
          offset,IOSMultiply2InputV1RecordBytes));
      offset += IOSMultiply2InputV1RecordBytes;
      }
    artifact.swap(candidate);
    return IOSMultiply2InputArtifactError::None;
    }
  catch(...) {
    return IOSMultiply2InputArtifactError::AllocationFailure;
    }
  }

IOSMultiply2InputArtifactError iosDecodeMultiply2InputRecordV1(
    std::span<const std::byte> encoded,
    IOSMultiply2InputRecordV1& record) noexcept {
  if(encoded.size()!=IOSMultiply2InputV1RecordBytes)
    return IOSMultiply2InputArtifactError::InvalidInputSize;
  IOSMultiply2InputRecordV1 candidate;
  candidate.sourceId = loadLe64(encoded,0u);
  candidate.meshId = loadLe64(encoded,8u);
  candidate.materialId = loadLe64(encoded,16u);
  candidate.textureId = loadLe64(encoded,24u);
  candidate.indexByteOffset = loadLe64(encoded,32u);
  candidate.indexCount = loadLe64(encoded,40u);
  candidate.vertexBufferBytes = loadLe64(encoded,48u);
  candidate.indexBufferBytes = loadLe64(encoded,56u);
  candidate.materialFlags = loadLe64(encoded,64u);
  candidate.vertexStride = loadLe32(encoded,72u);
  candidate.textureWidth = loadLe32(encoded,76u);
  candidate.textureHeight = loadLe32(encoded,80u);
  candidate.textureMipCount = loadLe32(encoded,84u);
  candidate.textureFormat =
      static_cast<IOSMultiply2InputTextureFormat>(loadLe32(encoded,88u));
  candidate.kind = static_cast<IOSMultiply2InputKind>(byteAt(encoded,92u));
  candidate.category =
      static_cast<IOSMultiply2InputCategory>(byteAt(encoded,93u));
  candidate.animation =
      static_cast<IOSMultiply2InputAnimation>(byteAt(encoded,94u));
  candidate.phase = static_cast<IOSMultiply2InputPhase>(byteAt(encoded,95u));
  for(std::size_t index=0u; index<candidate.constants.size(); ++index)
    candidate.constants[index] = encoded[96u+index];
  const auto error = iosValidateMultiply2InputRecordV1(candidate);
  if(error!=IOSMultiply2InputArtifactError::None)
    return error;
  record = candidate;
  return IOSMultiply2InputArtifactError::None;
  }

IOSMultiply2InputArtifactError iosParseMultiply2InputArtifactV1(
    std::span<const std::byte> input,
    IOSMultiply2InputArtifactViewV1& view) noexcept {
  if(input.size()<IOSMultiply2InputV1HeaderBytes)
    return IOSMultiply2InputArtifactError::InvalidInputSize;
  for(std::size_t index=0u; index<Magic.size(); ++index)
    if(byteAt(input,index)!=Magic[index])
      return IOSMultiply2InputArtifactError::InvalidMagic;
  if(loadLe16(input,8u)!=SchemaVersion)
    return IOSMultiply2InputArtifactError::UnsupportedSchema;
  if(loadLe16(input,10u)!=LittleEndianMarker)
    return IOSMultiply2InputArtifactError::InvalidEndian;
  if(loadLe32(input,12u)!=IOSMultiply2InputV1HeaderBytes)
    return IOSMultiply2InputArtifactError::InvalidHeaderSize;
  const uint64_t baseCount = loadLe64(input,16u);
  const uint64_t multiply2Count = loadLe64(input,24u);
  if(loadLe32(input,32u)!=IOSMultiply2InputV1RecordBytes)
    return IOSMultiply2InputArtifactError::InvalidRecordSize;
  if(loadLe32(input,36u)!=IOSMultiply2InputV1ConstantsBytes)
    return IOSMultiply2InputArtifactError::InvalidConstantsSize;
  const uint64_t generation = loadLe64(input,40u);
  const uint64_t sequence = loadLe64(input,48u);
  if(generation==0u || sequence==0u)
    return IOSMultiply2InputArtifactError::InvalidIdentity;
  if(loadLe32(input,56u)!=0u)
    return IOSMultiply2InputArtifactError::NonZeroHeaderFlags;
  if(loadLe32(input,60u)!=0u)
    return IOSMultiply2InputArtifactError::NonZeroHeaderReserved;
  uint64_t payloadBytes = 0u;
  uint64_t artifactBytes = 0u;
  if(!countsAndSize(baseCount,multiply2Count,payloadBytes,artifactBytes))
    return IOSMultiply2InputArtifactError::InvalidCounts;
  if(artifactBytes!=input.size())
    return IOSMultiply2InputArtifactError::InvalidInputSize;
  const std::size_t baseBytes =
      static_cast<std::size_t>(baseCount)*IOSMultiply2InputV1RecordBytes;
  const auto basePayload = input.subspan(
      IOSMultiply2InputV1HeaderBytes,baseBytes);
  const auto multiply2Payload = input.subspan(
      IOSMultiply2InputV1HeaderBytes+baseBytes,
      IOSMultiply2InputV1RecordBytes);
  uint64_t previous = 0u;
  for(uint64_t index=0u; index<baseCount; ++index) {
    IOSMultiply2InputRecordV1 record;
    const auto error = iosDecodeMultiply2InputRecordV1(
        basePayload.subspan(static_cast<std::size_t>(index)*
                                IOSMultiply2InputV1RecordBytes,
                            IOSMultiply2InputV1RecordBytes),record);
    if(error!=IOSMultiply2InputArtifactError::None)
      return error;
    if(record.phase!=IOSMultiply2InputPhase::Base)
      return IOSMultiply2InputArtifactError::InvalidPhaseRecord;
    if(previous>=record.sourceId)
      return previous==record.sourceId
          ? IOSMultiply2InputArtifactError::DuplicateSource
          : IOSMultiply2InputArtifactError::SourceOrder;
    previous = record.sourceId;
    }
  IOSMultiply2InputRecordV1 target;
  const auto targetError =
      iosDecodeMultiply2InputRecordV1(multiply2Payload,target);
  if(targetError!=IOSMultiply2InputArtifactError::None)
    return targetError;
  if(target.phase!=IOSMultiply2InputPhase::Multiply2)
    return IOSMultiply2InputArtifactError::InvalidPhaseRecord;
  for(uint64_t index=0u; index<baseCount; ++index)
    if(loadLe64(basePayload,static_cast<std::size_t>(index)*
                                IOSMultiply2InputV1RecordBytes)==
       target.sourceId)
      return IOSMultiply2InputArtifactError::DuplicateSource;
  view = {{baseCount,multiply2Count,generation,sequence},
          basePayload,multiply2Payload};
  return IOSMultiply2InputArtifactError::None;
  }

bool iosMultiply2InputArtifactV1Filename(
    char mode,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::string& filename) noexcept {
  if((mode!='a' && mode!='b') || targetGeneration==0u ||
     snapshotSequence==0u)
    return false;
  try {
    std::string candidate = "RendererIOS-multiply2-input-v1-";
    candidate.push_back(mode);
    candidate += "-g"+std::to_string(targetGeneration);
    candidate += "-s"+std::to_string(snapshotSequence)+".bin";
    filename.swap(candidate);
    return true;
    }
  catch(...) {
    return false;
    }
  }

IOSMultiply2InputPublishResult iosPublishMultiply2InputArtifactV1NoClobber(
    std::string_view directory,
    char mode,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::span<const std::byte> artifact,
    std::string_view temporaryTag,
    std::string& publishedPath,
    std::vector<std::byte>& publishedBytes) noexcept {
  IOSMultiply2InputArtifactViewV1 view;
  if(iosParseMultiply2InputArtifactV1(artifact,view)!=
         IOSMultiply2InputArtifactError::None ||
     view.header.targetGeneration!=targetGeneration ||
     view.header.snapshotSequence!=snapshotSequence)
    return IOSMultiply2InputPublishResult::InvalidArtifact;
  std::string filename;
  if(directory.empty() || directory.find('\0')!=std::string_view::npos ||
     !safeTag(temporaryTag) ||
     !iosMultiply2InputArtifactV1Filename(
         mode,targetGeneration,snapshotSequence,filename) ||
     !safeLeaf(filename))
    return IOSMultiply2InputPublishResult::InvalidArgument;
  std::string root;
  std::string temporary;
  std::string finalPath;
  try {
    root.assign(directory);
    temporary = "."+filename+".tmp."+std::string(temporaryTag);
    finalPath = root+(root.back()=='/' ? "" : "/")+filename;
    }
  catch(...) {
    return IOSMultiply2InputPublishResult::InvalidArgument;
    }
  const int directoryDescriptor =
      ::open(root.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  if(directoryDescriptor<0)
    return IOSMultiply2InputPublishResult::OpenDirectoryFailed;
  struct stat directoryStatus{};
  if(::fstat(directoryDescriptor,&directoryStatus)!=0 ||
     !S_ISDIR(directoryStatus.st_mode) ||
     (directoryStatus.st_mode&0777u)!=0700u ||
     directoryStatus.st_uid!=::getuid()) {
    (void)::close(directoryDescriptor);
    return IOSMultiply2InputPublishResult::DirectoryPolicyFailed;
    }
  const int descriptor = ::openat(
      directoryDescriptor,temporary.c_str(),
      O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
  if(descriptor<0) {
    const int error = errno;
    (void)::close(directoryDescriptor);
    return error==EEXIST ? IOSMultiply2InputPublishResult::TemporaryExists
                         : IOSMultiply2InputPublishResult::OpenTemporaryFailed;
    }
  IOSMultiply2InputPublishResult result =
      IOSMultiply2InputPublishResult::Published;
  if(::fchmod(descriptor,0600)!=0)
    result = IOSMultiply2InputPublishResult::OpenTemporaryFailed;
  std::size_t written = 0u;
  while(result==IOSMultiply2InputPublishResult::Published &&
        written<artifact.size()) {
    const auto* data = reinterpret_cast<const unsigned char*>(artifact.data());
    const ssize_t amount =
        ::write(descriptor,data+written,artifact.size()-written);
    if(amount<0 && errno==EINTR)
      continue;
    if(amount<=0) {
      result = IOSMultiply2InputPublishResult::WriteFailed;
      break;
      }
    written += static_cast<std::size_t>(amount);
    }
  if(result==IOSMultiply2InputPublishResult::Published &&
     ::fsync(descriptor)!=0)
    result = IOSMultiply2InputPublishResult::FileSyncFailed;
  if(::close(descriptor)!=0 &&
     result==IOSMultiply2InputPublishResult::Published)
    result = IOSMultiply2InputPublishResult::CloseFailed;
  if(result!=IOSMultiply2InputPublishResult::Published) {
    (void)unlinkRetry(directoryDescriptor,temporary.c_str());
    (void)::close(directoryDescriptor);
    return result;
    }
  if(::linkat(directoryDescriptor,temporary.c_str(),directoryDescriptor,
              filename.c_str(),0)!=0) {
    const int error = errno;
    (void)unlinkRetry(directoryDescriptor,temporary.c_str());
    (void)::close(directoryDescriptor);
    return error==EEXIST ? IOSMultiply2InputPublishResult::AlreadyExists
                         : IOSMultiply2InputPublishResult::PublishFailed;
    }
  if(!unlinkRetry(directoryDescriptor,temporary.c_str())) {
    (void)::close(directoryDescriptor);
    return IOSMultiply2InputPublishResult::TemporaryCleanupFailed;
    }
  if(::fsync(directoryDescriptor)!=0) {
    (void)::close(directoryDescriptor);
    return IOSMultiply2InputPublishResult::DirectorySyncFailed;
    }
  const int publishedDescriptor = ::openat(
      directoryDescriptor,filename.c_str(),
      O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
  if(publishedDescriptor<0) {
    (void)::close(directoryDescriptor);
    return IOSMultiply2InputPublishResult::ReadBackFailed;
    }
  struct stat publishedStatus{};
  if(::fstat(publishedDescriptor,&publishedStatus)!=0 ||
     !S_ISREG(publishedStatus.st_mode) || publishedStatus.st_nlink!=1u ||
     (publishedStatus.st_mode&0777u)!=0600u ||
     publishedStatus.st_uid!=::getuid() || publishedStatus.st_size<0 ||
     static_cast<uint64_t>(publishedStatus.st_size)!=artifact.size()) {
    (void)::close(publishedDescriptor);
    (void)::close(directoryDescriptor);
    return IOSMultiply2InputPublishResult::PublishedFilePolicyFailed;
    }
  std::vector<std::byte> verified;
  try {
    verified.resize(artifact.size());
    }
  catch(...) {
    (void)::close(publishedDescriptor);
    (void)::close(directoryDescriptor);
    return IOSMultiply2InputPublishResult::ReadBackFailed;
    }
  std::size_t readBytes = 0u;
  while(readBytes<verified.size()) {
    const ssize_t amount = ::read(
        publishedDescriptor,verified.data()+readBytes,
        verified.size()-readBytes);
    if(amount<0 && errno==EINTR)
      continue;
    if(amount<=0) {
      (void)::close(publishedDescriptor);
      (void)::close(directoryDescriptor);
      return IOSMultiply2InputPublishResult::ReadBackFailed;
      }
    readBytes += static_cast<std::size_t>(amount);
    }
  std::byte trailing{};
  ssize_t trailingBytes = 0;
  do {
    trailingBytes = ::read(publishedDescriptor,&trailing,1u);
    } while(trailingBytes<0 && errno==EINTR);
  if(trailingBytes!=0 || ::close(publishedDescriptor)!=0) {
    (void)::close(directoryDescriptor);
    return IOSMultiply2InputPublishResult::ReadBackFailed;
    }
  IOSMultiply2InputArtifactViewV1 verifiedView;
  if(!std::equal(verified.begin(),verified.end(),artifact.begin()) ||
     iosParseMultiply2InputArtifactV1(verified,verifiedView)!=
         IOSMultiply2InputArtifactError::None ||
     verifiedView.header.targetGeneration!=targetGeneration ||
     verifiedView.header.snapshotSequence!=snapshotSequence) {
    (void)::close(directoryDescriptor);
    return IOSMultiply2InputPublishResult::VerificationFailed;
    }
  if(::close(directoryDescriptor)!=0)
    return IOSMultiply2InputPublishResult::DirectorySyncFailed;
  publishedPath.swap(finalPath);
  publishedBytes.swap(verified);
  return IOSMultiply2InputPublishResult::Published;
  }
