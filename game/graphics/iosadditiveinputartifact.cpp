#include "iosadditiveinputartifact.h"

#include <cerrno>
#include <fcntl.h>
#include <limits>
#include <new>
#include <sys/stat.h>
#include <unistd.h>

namespace {

constexpr std::array<uint8_t,8u> Magic = {
    uint8_t('R'),uint8_t('I'),uint8_t('O'),uint8_t('S'),
    uint8_t('A'),uint8_t('0'),uint8_t('9'),0u};
constexpr uint16_t SchemaVersion = 1u;
constexpr uint16_t LittleEndianMarker = 0x4c45u;
constexpr uint32_t LandscapeVertexStride = 36u;
constexpr uint64_t IndexStride = 4u;

uint8_t byteAt(std::span<const std::byte> bytes, std::size_t offset) noexcept {
  return std::to_integer<uint8_t>(bytes[offset]);
  }

uint16_t loadLe16(std::span<const std::byte> bytes, std::size_t offset) noexcept {
  return uint16_t(byteAt(bytes,offset)) |
      uint16_t(uint16_t(byteAt(bytes,offset+1u)) << 8u);
  }

uint32_t loadLe32(std::span<const std::byte> bytes, std::size_t offset) noexcept {
  return uint32_t(byteAt(bytes,offset)) |
      (uint32_t(byteAt(bytes,offset+1u)) << 8u) |
      (uint32_t(byteAt(bytes,offset+2u)) << 16u) |
      (uint32_t(byteAt(bytes,offset+3u)) << 24u);
  }

uint64_t loadLe64(std::span<const std::byte> bytes, std::size_t offset) noexcept {
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

bool validKind(IOSAdditiveInputKind kind) noexcept {
  switch(kind) {
    case IOSAdditiveInputKind::Landscape:
    case IOSAdditiveInputKind::Static:
    case IOSAdditiveInputKind::Movable:
      return true;
    }
  return false;
  }

bool validBaseCategory(IOSAdditiveInputCategory category) noexcept {
  return category==IOSAdditiveInputCategory::Opaque ||
      category==IOSAdditiveInputCategory::AlphaTest;
  }

bool validAnimation(IOSAdditiveInputAnimation animation) noexcept {
  switch(animation) {
    case IOSAdditiveInputAnimation::None:
    case IOSAdditiveInputAnimation::FrameOnly:
    case IOSAdditiveInputAnimation::UvOnly:
    case IOSAdditiveInputAnimation::FrameAndUv:
      return true;
    }
  return false;
  }

bool validTextureFormat(IOSAdditiveInputTextureFormat format) noexcept {
  switch(format) {
    case IOSAdditiveInputTextureFormat::Rgba8Unorm:
    case IOSAdditiveInputTextureFormat::Bc1Rgba:
    case IOSAdditiveInputTextureFormat::Bc2Rgba:
    case IOSAdditiveInputTextureFormat::Bc3Rgba:
      return true;
    }
  return false;
  }

bool countsAndSize(uint64_t baseCount, uint64_t additiveCount,
                   uint64_t& payloadBytes, uint64_t& artifactBytes) noexcept {
  if(baseCount<IOSAdditiveInputV1MinimumBaseRecords ||
     baseCount>IOSAdditiveInputV1MaximumBaseRecords ||
     additiveCount!=IOSAdditiveInputV1AdditiveRecords)
    return false;
  uint64_t records = 0u;
  if(!checkedAdd(baseCount,additiveCount,records) ||
     records>IOSAdditiveInputV1MaximumRecords ||
     !checkedMultiply(records,IOSAdditiveInputV1RecordBytes,payloadBytes) ||
     payloadBytes>IOSAdditiveInputV1MaximumPayloadBytes ||
     !checkedAdd(IOSAdditiveInputV1HeaderBytes,payloadBytes,artifactBytes))
    return false;
  return true;
  }

IOSAdditiveInputArtifactError validateSourceDomains(
    std::span<const IOSAdditiveInputRecordV1> base,
    std::span<const IOSAdditiveInputRecordV1> additive) noexcept {
  for(std::size_t index=0u; index<base.size(); ++index) {
    const auto error = iosValidateAdditiveInputRecordV1(
        base[index],IOSAdditiveInputPhase::Base);
    if(error!=IOSAdditiveInputArtifactError::None)
      return error;
    if(index!=0u && base[index-1u].sourceId>=base[index].sourceId)
      return base[index-1u].sourceId==base[index].sourceId
          ? IOSAdditiveInputArtifactError::DuplicateSource
          : IOSAdditiveInputArtifactError::SourceOrder;
    }
  for(std::size_t index=0u; index<additive.size(); ++index) {
    const auto error = iosValidateAdditiveInputRecordV1(
        additive[index],IOSAdditiveInputPhase::Additive);
    if(error!=IOSAdditiveInputArtifactError::None)
      return error;
    if(index!=0u && additive[index-1u].sourceId>=additive[index].sourceId)
      return additive[index-1u].sourceId==additive[index].sourceId
          ? IOSAdditiveInputArtifactError::DuplicateSource
          : IOSAdditiveInputArtifactError::SourceOrder;
    }

  std::size_t baseIndex = 0u;
  std::size_t additiveIndex = 0u;
  while(baseIndex<base.size() && additiveIndex<additive.size()) {
    const uint64_t baseId = base[baseIndex].sourceId;
    const uint64_t additiveId = additive[additiveIndex].sourceId;
    if(baseId==additiveId)
      return IOSAdditiveInputArtifactError::DuplicateSource;
    if(baseId<additiveId)
      ++baseIndex;
    else
      ++additiveIndex;
    }
  return IOSAdditiveInputArtifactError::None;
  }

void encodeRecord(const IOSAdditiveInputRecordV1& record,
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
  encoded[95u] = std::byte{0u};
  for(std::size_t index=0u; index<record.constants.size(); ++index)
    encoded[96u+index] = record.constants[index];
  }

bool safeLeaf(std::string_view value) noexcept {
  if(value.empty() || value=="." || value=="..")
    return false;
  for(char character:value) {
    if(character=='/' || character=='\0')
      return false;
    }
  return true;
  }

bool safeTemporaryTag(std::string_view value) noexcept {
  if(value.empty() || value.size()>64u)
    return false;
  for(char character:value) {
    const bool valid = (character>='a' && character<='z') ||
        (character>='A' && character<='Z') ||
        (character>='0' && character<='9') || character=='-' ||
        character=='_';
    if(!valid)
      return false;
    }
  return true;
  }

bool unlinkAtRetry(int directory, const char* leaf) noexcept {
  for(;;) {
    if(::unlinkat(directory,leaf,0)==0)
      return true;
    if(errno!=EINTR)
      return false;
    }
  }

}

IOSAdditiveInputArtifactError iosValidateAdditiveInputRecordV1(
    const IOSAdditiveInputRecordV1& record,
    IOSAdditiveInputPhase phase) noexcept {
  if(!validKind(record.kind))
    return IOSAdditiveInputArtifactError::UnknownKind;
  if(record.category!=IOSAdditiveInputCategory::Opaque &&
     record.category!=IOSAdditiveInputCategory::AlphaTest &&
     record.category!=IOSAdditiveInputCategory::Additive)
    return IOSAdditiveInputArtifactError::UnknownCategory;
  if(record.animation!=IOSAdditiveInputAnimation::None &&
     record.animation!=IOSAdditiveInputAnimation::FrameOnly &&
     record.animation!=IOSAdditiveInputAnimation::UvOnly &&
     record.animation!=IOSAdditiveInputAnimation::FrameAndUv)
    return IOSAdditiveInputArtifactError::UnknownAnimation;
  if(!validTextureFormat(record.textureFormat))
    return IOSAdditiveInputArtifactError::UnknownTextureFormat;
  if((record.materialFlags&~IOSAdditiveInputMaterialFlagStaticAdditiveNone)!=0u)
    return IOSAdditiveInputArtifactError::UnknownMaterialFlags;
  if(!validAnimation(record.animation))
    return IOSAdditiveInputArtifactError::InvalidPhaseRecord;

  if(phase==IOSAdditiveInputPhase::Base) {
    if(!validBaseCategory(record.category) || record.materialFlags!=0u)
      return IOSAdditiveInputArtifactError::InvalidPhaseRecord;
    }
  else if(phase==IOSAdditiveInputPhase::Additive) {
    if(record.kind!=IOSAdditiveInputKind::Static ||
       record.category!=IOSAdditiveInputCategory::Additive ||
       record.animation!=IOSAdditiveInputAnimation::None ||
       record.materialFlags!=IOSAdditiveInputMaterialFlagStaticAdditiveNone)
      return IOSAdditiveInputArtifactError::InvalidPhaseRecord;
    }
  else {
    return IOSAdditiveInputArtifactError::InvalidPhaseRecord;
    }

  if(record.sourceId==0u || record.meshId==0u || record.materialId==0u ||
     record.textureId==0u || record.vertexStride!=LandscapeVertexStride ||
     record.vertexBufferBytes<record.vertexStride ||
     record.vertexBufferBytes%record.vertexStride!=0u ||
     record.indexBufferBytes<IndexStride ||
     record.indexBufferBytes%IndexStride!=0u ||
     record.indexByteOffset%IndexStride!=0u || record.indexCount==0u ||
     record.indexCount%3u!=0u || record.textureWidth==0u ||
     record.textureHeight==0u || record.textureMipCount==0u)
    return IOSAdditiveInputArtifactError::InvalidRecord;

  uint64_t indexBytes = 0u;
  uint64_t rangeEnd = 0u;
  if(!checkedMultiply(record.indexCount,IndexStride,indexBytes) ||
     !checkedAdd(record.indexByteOffset,indexBytes,rangeEnd))
    return IOSAdditiveInputArtifactError::SizeOverflow;
  if(rangeEnd>record.indexBufferBytes)
    return IOSAdditiveInputArtifactError::InvalidRecord;

  uint32_t maximumMipCount = 1u;
  uint32_t maximumExtent = record.textureWidth>record.textureHeight
      ? record.textureWidth : record.textureHeight;
  while(maximumExtent>1u) {
    maximumExtent /= 2u;
    ++maximumMipCount;
    }
  if(record.textureMipCount>maximumMipCount)
    return IOSAdditiveInputArtifactError::InvalidRecord;
  return IOSAdditiveInputArtifactError::None;
  }

IOSAdditiveInputArtifactError iosBuildAdditiveInputArtifactV1(
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::span<const IOSAdditiveInputRecordV1> base,
    std::span<const IOSAdditiveInputRecordV1> additive,
    std::vector<std::byte>& artifact) noexcept {
  if(targetGeneration==0u || snapshotSequence==0u)
    return IOSAdditiveInputArtifactError::InvalidIdentity;
  uint64_t payloadBytes = 0u;
  uint64_t artifactBytes = 0u;
  if(!countsAndSize(base.size(),additive.size(),payloadBytes,artifactBytes))
    return IOSAdditiveInputArtifactError::InvalidCounts;
  const auto validation = validateSourceDomains(base,additive);
  if(validation!=IOSAdditiveInputArtifactError::None)
    return validation;

  try {
    std::vector<std::byte> candidate(static_cast<std::size_t>(artifactBytes));
    for(std::size_t index=0u; index<Magic.size(); ++index)
      candidate[index] = std::byte(Magic[index]);
    storeLe16(candidate,8u,SchemaVersion);
    storeLe16(candidate,10u,LittleEndianMarker);
    storeLe32(candidate,12u,IOSAdditiveInputV1HeaderBytes);
    storeLe64(candidate,16u,base.size());
    storeLe64(candidate,24u,additive.size());
    storeLe32(candidate,32u,IOSAdditiveInputV1RecordBytes);
    storeLe32(candidate,36u,IOSAdditiveInputV1ConstantsBytes);
    storeLe64(candidate,40u,targetGeneration);
    storeLe64(candidate,48u,snapshotSequence);
    storeLe32(candidate,56u,0u);
    storeLe32(candidate,60u,0u);

    std::size_t offset = IOSAdditiveInputV1HeaderBytes;
    for(const auto& record:base) {
      encodeRecord(record,std::span<std::byte>(candidate).subspan(
          offset,IOSAdditiveInputV1RecordBytes));
      offset += IOSAdditiveInputV1RecordBytes;
      }
    for(const auto& record:additive) {
      encodeRecord(record,std::span<std::byte>(candidate).subspan(
          offset,IOSAdditiveInputV1RecordBytes));
      offset += IOSAdditiveInputV1RecordBytes;
      }
    artifact.swap(candidate);
    return IOSAdditiveInputArtifactError::None;
    }
  catch(const std::bad_alloc&) {
    return IOSAdditiveInputArtifactError::AllocationFailure;
    }
  catch(...) {
    return IOSAdditiveInputArtifactError::AllocationFailure;
    }
  }

IOSAdditiveInputArtifactError iosDecodeAdditiveInputRecordV1(
    std::span<const std::byte> encoded,
    IOSAdditiveInputPhase phase,
    IOSAdditiveInputRecordV1& record) noexcept {
  if(encoded.size()!=IOSAdditiveInputV1RecordBytes)
    return IOSAdditiveInputArtifactError::InvalidInputSize;
  if(byteAt(encoded,95u)!=0u)
    return IOSAdditiveInputArtifactError::NonZeroRecordReserved;

  IOSAdditiveInputRecordV1 candidate;
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
      static_cast<IOSAdditiveInputTextureFormat>(loadLe32(encoded,88u));
  candidate.kind = static_cast<IOSAdditiveInputKind>(byteAt(encoded,92u));
  candidate.category =
      static_cast<IOSAdditiveInputCategory>(byteAt(encoded,93u));
  candidate.animation =
      static_cast<IOSAdditiveInputAnimation>(byteAt(encoded,94u));
  for(std::size_t index=0u; index<candidate.constants.size(); ++index)
    candidate.constants[index] = encoded[96u+index];
  const auto validation = iosValidateAdditiveInputRecordV1(candidate,phase);
  if(validation!=IOSAdditiveInputArtifactError::None)
    return validation;
  record = candidate;
  return IOSAdditiveInputArtifactError::None;
  }

IOSAdditiveInputArtifactError iosParseAdditiveInputArtifactV1(
    std::span<const std::byte> input,
    IOSAdditiveInputArtifactViewV1& view) noexcept {
  if(input.size()<IOSAdditiveInputV1HeaderBytes)
    return IOSAdditiveInputArtifactError::InvalidInputSize;
  for(std::size_t index=0u; index<Magic.size(); ++index) {
    if(byteAt(input,index)!=Magic[index])
      return IOSAdditiveInputArtifactError::InvalidMagic;
    }
  if(loadLe16(input,8u)!=SchemaVersion)
    return IOSAdditiveInputArtifactError::UnsupportedSchema;
  if(loadLe16(input,10u)!=LittleEndianMarker)
    return IOSAdditiveInputArtifactError::InvalidEndian;
  if(loadLe32(input,12u)!=IOSAdditiveInputV1HeaderBytes)
    return IOSAdditiveInputArtifactError::InvalidHeaderSize;
  const uint64_t baseCount = loadLe64(input,16u);
  const uint64_t additiveCount = loadLe64(input,24u);
  if(loadLe32(input,32u)!=IOSAdditiveInputV1RecordBytes)
    return IOSAdditiveInputArtifactError::InvalidRecordSize;
  if(loadLe32(input,36u)!=IOSAdditiveInputV1ConstantsBytes)
    return IOSAdditiveInputArtifactError::InvalidConstantsSize;
  const uint64_t generation = loadLe64(input,40u);
  const uint64_t sequence = loadLe64(input,48u);
  if(generation==0u || sequence==0u)
    return IOSAdditiveInputArtifactError::InvalidIdentity;
  if(loadLe32(input,56u)!=0u)
    return IOSAdditiveInputArtifactError::NonZeroHeaderFlags;
  if(loadLe32(input,60u)!=0u)
    return IOSAdditiveInputArtifactError::NonZeroHeaderReserved;

  uint64_t payloadBytes = 0u;
  uint64_t artifactBytes = 0u;
  if(!countsAndSize(baseCount,additiveCount,payloadBytes,artifactBytes))
    return IOSAdditiveInputArtifactError::InvalidCounts;
  if(artifactBytes!=input.size())
    return IOSAdditiveInputArtifactError::InvalidInputSize;

  const std::size_t baseBytes =
      static_cast<std::size_t>(baseCount)*IOSAdditiveInputV1RecordBytes;
  const std::size_t additiveBytes =
      static_cast<std::size_t>(additiveCount)*IOSAdditiveInputV1RecordBytes;
  const auto basePayload = input.subspan(IOSAdditiveInputV1HeaderBytes,baseBytes);
  const auto additivePayload = input.subspan(
      IOSAdditiveInputV1HeaderBytes+baseBytes,additiveBytes);

  IOSAdditiveInputRecordV1 previous;
  bool havePrevious = false;
  for(uint64_t index=0u; index<baseCount; ++index) {
    IOSAdditiveInputRecordV1 current;
    const auto error = iosDecodeAdditiveInputRecordV1(
        basePayload.subspan(static_cast<std::size_t>(index)*
                                IOSAdditiveInputV1RecordBytes,
                            IOSAdditiveInputV1RecordBytes),
        IOSAdditiveInputPhase::Base,current);
    if(error!=IOSAdditiveInputArtifactError::None)
      return error;
    if(havePrevious && previous.sourceId>=current.sourceId)
      return previous.sourceId==current.sourceId
          ? IOSAdditiveInputArtifactError::DuplicateSource
          : IOSAdditiveInputArtifactError::SourceOrder;
    previous = current;
    havePrevious = true;
    }

  IOSAdditiveInputRecordV1 additivePrevious;
  havePrevious = false;
  for(uint64_t index=0u; index<additiveCount; ++index) {
    IOSAdditiveInputRecordV1 current;
    const auto error = iosDecodeAdditiveInputRecordV1(
        additivePayload.subspan(static_cast<std::size_t>(index)*
                                    IOSAdditiveInputV1RecordBytes,
                                IOSAdditiveInputV1RecordBytes),
        IOSAdditiveInputPhase::Additive,current);
    if(error!=IOSAdditiveInputArtifactError::None)
      return error;
    if(havePrevious && additivePrevious.sourceId>=current.sourceId)
      return additivePrevious.sourceId==current.sourceId
          ? IOSAdditiveInputArtifactError::DuplicateSource
          : IOSAdditiveInputArtifactError::SourceOrder;
    additivePrevious = current;
    havePrevious = true;
    }

  std::size_t baseIndex = 0u;
  std::size_t additiveIndex = 0u;
  while(baseIndex<baseCount && additiveIndex<additiveCount) {
    const uint64_t baseId = loadLe64(
        basePayload,baseIndex*IOSAdditiveInputV1RecordBytes);
    const uint64_t additiveId = loadLe64(
        additivePayload,additiveIndex*IOSAdditiveInputV1RecordBytes);
    if(baseId==additiveId)
      return IOSAdditiveInputArtifactError::DuplicateSource;
    if(baseId<additiveId)
      ++baseIndex;
    else
      ++additiveIndex;
    }

  IOSAdditiveInputArtifactViewV1 candidate;
  candidate.header = {baseCount,additiveCount,generation,sequence};
  candidate.basePayload = basePayload;
  candidate.additivePayload = additivePayload;
  view = candidate;
  return IOSAdditiveInputArtifactError::None;
  }

bool iosAdditiveInputArtifactV1Filename(
    char mode,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::string& filename) noexcept {
  if((mode!='a' && mode!='b') || targetGeneration==0u ||
     snapshotSequence==0u)
    return false;
  try {
    std::string candidate = "RendererIOS-additive-input-v1-";
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

IOSAdditiveInputPublishResult iosPublishAdditiveInputArtifactV1NoClobber(
    std::string_view directory,
    char mode,
    uint64_t targetGeneration,
    uint64_t snapshotSequence,
    std::span<const std::byte> artifact,
    std::string_view temporaryTag,
    std::string& publishedPath) noexcept {
  IOSAdditiveInputArtifactViewV1 view;
  if(iosParseAdditiveInputArtifactV1(artifact,view)!=
         IOSAdditiveInputArtifactError::None ||
     view.header.targetGeneration!=targetGeneration ||
     view.header.snapshotSequence!=snapshotSequence)
    return IOSAdditiveInputPublishResult::InvalidArtifact;

  std::string filename;
  if(directory.empty() || directory.find('\0')!=std::string_view::npos ||
     !safeTemporaryTag(temporaryTag) ||
     !iosAdditiveInputArtifactV1Filename(
         mode,targetGeneration,snapshotSequence,filename) ||
     !safeLeaf(filename))
    return IOSAdditiveInputPublishResult::InvalidArgument;

  std::string directoryString;
  std::string temporary;
  std::string pathCandidate;
  try {
    directoryString.assign(directory);
    temporary = "."+filename+".tmp."+std::string(temporaryTag);
    pathCandidate = directoryString;
    if(!pathCandidate.empty() && pathCandidate.back()!='/')
      pathCandidate.push_back('/');
    pathCandidate += filename;
    }
  catch(...) {
    return IOSAdditiveInputPublishResult::InvalidArgument;
    }

  const int directoryFlags = O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW;
  int directoryDescriptor = ::open(directoryString.c_str(),directoryFlags);
  if(directoryDescriptor<0)
    return IOSAdditiveInputPublishResult::OpenDirectoryFailed;
  int temporaryDescriptor = ::openat(
      directoryDescriptor,temporary.c_str(),
      O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
  if(temporaryDescriptor<0) {
    const int error = errno;
    (void)::close(directoryDescriptor);
    return error==EEXIST ? IOSAdditiveInputPublishResult::TemporaryExists
                         : IOSAdditiveInputPublishResult::OpenTemporaryFailed;
    }

  IOSAdditiveInputPublishResult result = IOSAdditiveInputPublishResult::Published;
  if(::fchmod(temporaryDescriptor,0600)!=0)
    result = IOSAdditiveInputPublishResult::OpenTemporaryFailed;
  std::size_t written = 0u;
  while(result==IOSAdditiveInputPublishResult::Published &&
        written<artifact.size()) {
    const auto* data = reinterpret_cast<const unsigned char*>(artifact.data());
    const ssize_t amount = ::write(
        temporaryDescriptor,data+written,artifact.size()-written);
    if(amount<0 && errno==EINTR)
      continue;
    if(amount<=0) {
      result = IOSAdditiveInputPublishResult::WriteFailed;
      break;
      }
    written += static_cast<std::size_t>(amount);
    }
  if(result==IOSAdditiveInputPublishResult::Published &&
     ::fsync(temporaryDescriptor)!=0)
    result = IOSAdditiveInputPublishResult::FileSyncFailed;
  if(::close(temporaryDescriptor)!=0 &&
     result==IOSAdditiveInputPublishResult::Published)
    result = IOSAdditiveInputPublishResult::CloseFailed;

  if(result!=IOSAdditiveInputPublishResult::Published) {
    (void)unlinkAtRetry(directoryDescriptor,temporary.c_str());
    (void)::close(directoryDescriptor);
    return result;
    }

  if(::linkat(directoryDescriptor,temporary.c_str(),directoryDescriptor,
              filename.c_str(),0)!=0) {
    const int error = errno;
    (void)unlinkAtRetry(directoryDescriptor,temporary.c_str());
    (void)::close(directoryDescriptor);
    return error==EEXIST ? IOSAdditiveInputPublishResult::AlreadyExists
                         : IOSAdditiveInputPublishResult::PublishFailed;
    }
  if(!unlinkAtRetry(directoryDescriptor,temporary.c_str())) {
    (void)::close(directoryDescriptor);
    return IOSAdditiveInputPublishResult::TemporaryCleanupFailed;
    }
  if(::fsync(directoryDescriptor)!=0) {
    (void)::close(directoryDescriptor);
    return IOSAdditiveInputPublishResult::DirectorySyncFailed;
    }
  if(::close(directoryDescriptor)!=0)
    return IOSAdditiveInputPublishResult::DirectorySyncFailed;
  publishedPath.swap(pathCandidate);
  return IOSAdditiveInputPublishResult::Published;
  }
