#include "iosdeviceintegritymanifest.h"

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)

#if defined(__APPLE__)

#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <limits>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace RendererIOSDeviceIntegrity {
namespace {

constexpr std::array<std::string_view,3> ResourceRoots = {
  "Data","_work/Data","system",
  };
constexpr std::string_view ExcludedResource = "system/Gothic.ini";
constexpr std::array<std::string_view,4> ProtectedSaves = {
  "save_slot_1.sav","save_slot_2.sav",
  "save_slot_3.sav","save_slot_4.sav",
  };
constexpr std::size_t HashChunkBytes = 64u*1024u;

int closeOnExecFlag() noexcept {
#if defined(O_CLOEXEC)
  return O_CLOEXEC;
#else
  return 0;
#endif
  }

class FileDescriptor final {
  public:
    FileDescriptor() = default;
    explicit FileDescriptor(int descriptor) noexcept : descriptor(descriptor) {}
    ~FileDescriptor() {
      reset();
      }

    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;

    FileDescriptor(FileDescriptor&& other) noexcept
      : descriptor(std::exchange(other.descriptor,-1)) {}
    FileDescriptor& operator=(FileDescriptor&& other) noexcept {
      if(this!=&other) {
        reset();
        descriptor = std::exchange(other.descriptor,-1);
        }
      return *this;
      }

    int get() const noexcept {
      return descriptor;
      }
    explicit operator bool() const noexcept {
      return descriptor>=0;
      }
    int release() noexcept {
      return std::exchange(descriptor,-1);
      }
    void reset(int replacement = -1) noexcept {
      if(descriptor>=0)
        (void)::close(descriptor);
      descriptor = replacement;
      }

  private:
    int descriptor = -1;
  };

struct Candidate final {
  std::string rawRelativePath;
  std::string normalizedRelativePath;
  struct stat identity{};
  uint64_t byteSize = 0u;
  std::array<char,65> sha256{};
  };

struct DirectoryIdentity final {
  std::string rawRelativePath;
  std::string normalizedRelativePath;
  struct stat identity{};
  };

struct Collection final {
  std::vector<Candidate> entries;
  std::vector<DirectoryIdentity> directories;
  uint64_t totalBytes = 0u;
  bool excludedSeen = false;
  };

struct PreparedManifest final {
  std::string temporaryName;
  struct stat identity{};
  std::array<char,65> sha256{};
  };

bool sameTimestamp(const timespec& lhs, const timespec& rhs) noexcept {
  return lhs.tv_sec==rhs.tv_sec && lhs.tv_nsec==rhs.tv_nsec;
  }

bool sameStableStat(const struct stat& lhs, const struct stat& rhs) noexcept {
  return lhs.st_dev==rhs.st_dev && lhs.st_ino==rhs.st_ino &&
      lhs.st_mode==rhs.st_mode && lhs.st_size==rhs.st_size &&
      sameTimestamp(lhs.st_mtimespec,rhs.st_mtimespec) &&
      sameTimestamp(lhs.st_ctimespec,rhs.st_ctimespec);
  }

bool sameIdentityAndSize(
    const struct stat& lhs, const struct stat& rhs) noexcept {
  return lhs.st_dev==rhs.st_dev && lhs.st_ino==rhs.st_ino &&
      lhs.st_mode==rhs.st_mode && lhs.st_size==rhs.st_size;
  }

bool byteLess(std::string_view lhs, std::string_view rhs) noexcept {
  return std::lexicographical_compare(
      lhs.begin(),lhs.end(),rhs.begin(),rhs.end(),
      [](char a, char b) {
        return static_cast<unsigned char>(a)<
            static_cast<unsigned char>(b);
      });
  }

bool normalizeNfc(std::string_view source, std::string& output) noexcept {
  output.clear();
  if(source.size()>static_cast<std::size_t>(
       std::numeric_limits<CFIndex>::max()))
    return false;
  CFStringRef immutable = CFStringCreateWithBytes(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8*>(source.data()),
      static_cast<CFIndex>(source.size()),
      kCFStringEncodingUTF8,false);
  if(immutable==nullptr)
    return false;
  CFMutableStringRef normalized =
      CFStringCreateMutableCopy(kCFAllocatorDefault,0,immutable);
  CFRelease(immutable);
  if(normalized==nullptr)
    return false;
  CFStringNormalize(normalized,kCFStringNormalizationFormC);
  const CFIndex length = CFStringGetLength(normalized);
  const CFIndex maximum =
      CFStringGetMaximumSizeForEncoding(length,kCFStringEncodingUTF8);
  if(maximum<0 || maximum==std::numeric_limits<CFIndex>::max()) {
    CFRelease(normalized);
    return false;
    }
  try {
    std::vector<char> encoded(static_cast<std::size_t>(maximum)+1u,'\0');
    const Boolean converted = CFStringGetCString(
        normalized,encoded.data(),maximum+1,kCFStringEncodingUTF8);
    CFRelease(normalized);
    normalized = nullptr;
    if(!converted)
      return false;
    output.assign(encoded.data());
    return output.find('\0')==std::string::npos;
    }
  catch(...) {
    if(normalized!=nullptr)
      CFRelease(normalized);
    return false;
    }
  }

std::vector<std::string_view> pathComponents(
    std::string_view relative) {
  std::vector<std::string_view> components;
  std::size_t begin = 0u;
  while(begin<relative.size()) {
    const std::size_t end = relative.find('/',begin);
    const std::size_t count = end==std::string_view::npos
        ? relative.size()-begin : end-begin;
    components.push_back(relative.substr(begin,count));
    if(end==std::string_view::npos)
      break;
    begin = end+1u;
    }
  return components;
  }

bool canonicalRelativePath(std::string_view relative) {
  if(relative.empty() || relative.front()=='/' || relative.back()=='/')
    return false;
  for(const std::string_view component:pathComponents(relative))
    if(component.empty() || component=="." || component=="..")
      return false;
  return true;
  }

Error openDirectoryAt(
    int parent, std::string_view name, FileDescriptor& output) {
  const std::string stableName(name);
  struct stat pathIdentity{};
  if(::fstatat(parent,stableName.c_str(),&pathIdentity,
               AT_SYMLINK_NOFOLLOW)!=0)
    return errno==ENOENT ? Error::MissingRoot : Error::OpenFailed;
  if(!S_ISDIR(pathIdentity.st_mode))
    return Error::NonRegularEntry;
  FileDescriptor opened(::openat(
      parent,stableName.c_str(),
      O_RDONLY|O_DIRECTORY|O_NOFOLLOW|closeOnExecFlag()));
  if(!opened)
    return Error::OpenFailed;
  struct stat openedIdentity{};
  if(::fstat(opened.get(),&openedIdentity)!=0 ||
     !sameStableStat(pathIdentity,openedIdentity))
    return Error::FileChanged;
  output = std::move(opened);
  return Error::None;
  }

Error openDirectoryPath(
    int root, std::string_view relative, FileDescriptor& output) {
  if(!canonicalRelativePath(relative))
    return Error::NonCanonicalPath;
  FileDescriptor current(::dup(root));
  if(!current)
    return Error::OpenFailed;
  for(const std::string_view component:pathComponents(relative)) {
    FileDescriptor next;
    const Error error = openDirectoryAt(current.get(),component,next);
    if(error!=Error::None)
      return error;
    current = std::move(next);
    }
  output = std::move(current);
  return Error::None;
  }

Error checkedCollectFile(
    std::string rawRelativePath,
    const struct stat& identity,
    Collection& collection) {
  if(identity.st_size<0)
    return Error::FileSizeLimit;
  const uint64_t byteSize = static_cast<uint64_t>(identity.st_size);
  if(byteSize>MaximumFileBytes)
    return Error::FileSizeLimit;
  if(collection.entries.size()>=MaximumFileCount)
    return Error::FileCountLimit;
  if(byteSize>MaximumTotalBytes-collection.totalBytes)
    return Error::TotalSizeLimit;
  std::string normalized;
  if(!normalizeNfc(rawRelativePath,normalized))
    return Error::InvalidUtf8;
  if(!canonicalRelativePath(normalized))
    return Error::NonCanonicalPath;
  Candidate candidate;
  candidate.rawRelativePath = std::move(rawRelativePath);
  candidate.normalizedRelativePath = std::move(normalized);
  candidate.identity = identity;
  candidate.byteSize = byteSize;
  collection.totalBytes += byteSize;
  collection.entries.push_back(std::move(candidate));
  return Error::None;
  }

Error collectDirectory(
    int directory,
    std::string_view rawPrefix,
    Collection& collection) {
  struct stat directoryBefore{};
  if(::fstat(directory,&directoryBefore)!=0 ||
     !S_ISDIR(directoryBefore.st_mode))
    return Error::OpenFailed;
  std::string normalizedPrefix;
  if(!normalizeNfc(rawPrefix,normalizedPrefix))
    return Error::InvalidUtf8;
  if(!canonicalRelativePath(normalizedPrefix))
    return Error::NonCanonicalPath;
  DirectoryIdentity directoryIdentity;
  try {
    directoryIdentity.rawRelativePath.assign(rawPrefix);
    directoryIdentity.normalizedRelativePath = std::move(normalizedPrefix);
    directoryIdentity.identity = directoryBefore;
    collection.directories.push_back(std::move(directoryIdentity));
    }
  catch(...) {
    return Error::OpenFailed;
    }
  FileDescriptor duplicate(::dup(directory));
  if(!duplicate)
    return Error::OpenFailed;
  DIR* stream = ::fdopendir(duplicate.release());
  if(stream==nullptr)
    return Error::OpenFailed;
  std::vector<std::string> names;
  errno = 0;
  while(dirent* entry = ::readdir(stream)) {
    const std::string_view name(entry->d_name);
    if(name=="." || name=="..")
      continue;
    try {
      names.emplace_back(name);
      }
    catch(...) {
      (void)::closedir(stream);
      return Error::OpenFailed;
      }
    errno = 0;
    }
  const int readError = errno;
  if(::closedir(stream)!=0 || readError!=0)
    return Error::ReadFailed;
  std::sort(names.begin(),names.end(),
            [](const std::string& lhs, const std::string& rhs) {
              return byteLess(lhs,rhs);
            });
  for(const std::string& name:names) {
    struct stat identity{};
    if(::fstatat(directory,name.c_str(),&identity,
                 AT_SYMLINK_NOFOLLOW)!=0)
      return Error::FileChanged;
    std::string relative;
    try {
      relative.reserve(rawPrefix.size()+1u+name.size());
      relative.assign(rawPrefix);
      relative.push_back('/');
      relative.append(name);
      }
    catch(...) {
      return Error::OpenFailed;
      }
    if(relative==ExcludedResource) {
      if(!S_ISREG(identity.st_mode))
        return Error::NonRegularEntry;
      collection.excludedSeen = true;
      continue;
      }
    if(S_ISREG(identity.st_mode)) {
      const Error error = checkedCollectFile(
          std::move(relative),identity,collection);
      if(error!=Error::None)
        return error;
      continue;
      }
    if(S_ISDIR(identity.st_mode)) {
      FileDescriptor child;
      const Error opened = openDirectoryAt(directory,name,child);
      if(opened!=Error::None)
        return opened;
      const Error nested = collectDirectory(
          child.get(),relative,collection);
      if(nested!=Error::None)
        return nested;
      struct stat pathAfter{};
      if(::fstatat(directory,name.c_str(),&pathAfter,
                   AT_SYMLINK_NOFOLLOW)!=0 ||
         !sameStableStat(identity,pathAfter))
        return Error::FileChanged;
      continue;
      }
    return Error::NonRegularEntry;
    }
  struct stat directoryAfter{};
  if(::fstat(directory,&directoryAfter)!=0 ||
     !sameStableStat(directoryBefore,directoryAfter))
    return Error::FileChanged;
  return Error::None;
  }

Error collectResources(int documentRoot, Collection& collection) {
  for(const std::string_view root:ResourceRoots) {
    FileDescriptor directory;
    const Error opened = openDirectoryPath(documentRoot,root,directory);
    if(opened!=Error::None)
      return opened;
    const Error collected = collectDirectory(
        directory.get(),root,collection);
    if(collected!=Error::None)
      return collected;
    }
  if(!collection.excludedSeen)
    return Error::MissingExcludedFile;
  std::sort(
      collection.entries.begin(),collection.entries.end(),
      [](const Candidate& lhs, const Candidate& rhs) {
        return byteLess(lhs.normalizedRelativePath,
                        rhs.normalizedRelativePath);
      });
  for(std::size_t index=1u; index<collection.entries.size(); ++index)
    if(collection.entries[index-1u].normalizedRelativePath==
       collection.entries[index].normalizedRelativePath)
      return Error::NormalizedPathCollision;
  std::sort(
      collection.directories.begin(),collection.directories.end(),
      [](const DirectoryIdentity& lhs, const DirectoryIdentity& rhs) {
        return byteLess(lhs.normalizedRelativePath,
                        rhs.normalizedRelativePath);
      });
  for(std::size_t index=1u; index<collection.directories.size(); ++index)
    if(collection.directories[index-1u].normalizedRelativePath==
       collection.directories[index].normalizedRelativePath)
      return Error::NormalizedPathCollision;
  return Error::None;
  }

Error collectProtectedSaves(
    int documentRoot, Collection& collection) {
  for(const std::string_view save:ProtectedSaves) {
    const std::string stableName(save);
    struct stat identity{};
    if(::fstatat(documentRoot,stableName.c_str(),&identity,
                 AT_SYMLINK_NOFOLLOW)!=0)
      return errno==ENOENT ? Error::MissingProtectedSave : Error::OpenFailed;
    if(!S_ISREG(identity.st_mode))
      return Error::NonRegularEntry;
    const Error collected = checkedCollectFile(
        stableName,identity,collection);
    if(collected!=Error::None)
      return collected;
  }
  return Error::None;
  }

Error openCandidate(
    int documentRoot,
    const Candidate& candidate,
    FileDescriptor& file,
    FileDescriptor& parent,
    std::string& leaf) {
  const auto components = pathComponents(candidate.rawRelativePath);
  if(components.empty())
    return Error::NonCanonicalPath;
  FileDescriptor current(::dup(documentRoot));
  if(!current)
    return Error::OpenFailed;
  for(std::size_t index=0u; index+1u<components.size(); ++index) {
    FileDescriptor next;
    const Error opened = openDirectoryAt(
        current.get(),components[index],next);
    if(opened!=Error::None)
      return Error::FileChanged;
    current = std::move(next);
    }
  try {
    leaf.assign(components.back());
    }
  catch(...) {
    return Error::OpenFailed;
    }
  struct stat pathBefore{};
  if(::fstatat(current.get(),leaf.c_str(),&pathBefore,
               AT_SYMLINK_NOFOLLOW)!=0 ||
     !sameStableStat(candidate.identity,pathBefore))
    return Error::FileChanged;
  FileDescriptor opened(::openat(
      current.get(),leaf.c_str(),
      O_RDONLY|O_NOFOLLOW|closeOnExecFlag()));
  if(!opened)
    return Error::OpenFailed;
  struct stat descriptorBefore{};
  if(::fstat(opened.get(),&descriptorBefore)!=0 ||
     !sameStableStat(candidate.identity,descriptorBefore))
    return Error::FileChanged;
  file = std::move(opened);
  parent = std::move(current);
  return Error::None;
  }

void encodeDigest(
    const unsigned char* digest, std::array<char,65>& output) noexcept {
  static constexpr char Hex[] = "0123456789abcdef";
  for(std::size_t index=0u; index<CC_SHA256_DIGEST_LENGTH; ++index) {
    output[index*2u] = Hex[(digest[index]>>4u)&0x0fu];
    output[index*2u+1u] = Hex[digest[index]&0x0fu];
    }
  output[64] = '\0';
  }

bool updateDigest(
    CC_SHA256_CTX& context, const char* data, std::size_t size) noexcept {
  std::size_t offset = 0u;
  while(offset<size) {
    const std::size_t remaining = size-offset;
    const CC_LONG chunk = static_cast<CC_LONG>(std::min<std::size_t>(
        remaining,std::numeric_limits<CC_LONG>::max()));
    if(CC_SHA256_Update(&context,data+offset,chunk)!=1)
      return false;
    offset += chunk;
    }
  return true;
  }

Error hashCandidate(
    int documentRoot, Candidate& candidate) {
  FileDescriptor file;
  FileDescriptor parent;
  std::string leaf;
  const Error opened = openCandidate(
      documentRoot,candidate,file,parent,leaf);
  if(opened!=Error::None)
    return opened;
  struct stat before{};
  if(::fstat(file.get(),&before)!=0 ||
     !sameStableStat(candidate.identity,before))
    return Error::FileChanged;
  CC_SHA256_CTX context{};
  if(CC_SHA256_Init(&context)!=1)
    return Error::ReadFailed;
  std::array<char,HashChunkBytes> buffer{};
  uint64_t bytesRead = 0u;
  for(;;) {
    const ssize_t count = ::read(file.get(),buffer.data(),buffer.size());
    if(count<0) {
      if(errno==EINTR)
        continue;
      return Error::ReadFailed;
      }
    if(count==0)
      break;
    const uint64_t unsignedCount = static_cast<uint64_t>(count);
    if(unsignedCount>candidate.byteSize-bytesRead)
      return Error::FileChanged;
    if(!updateDigest(context,buffer.data(),
                     static_cast<std::size_t>(count)))
      return Error::ReadFailed;
    bytesRead += unsignedCount;
    }
  if(bytesRead!=candidate.byteSize)
    return Error::FileChanged;
  struct stat after{};
  struct stat pathAfter{};
  if(::fstat(file.get(),&after)!=0 ||
     ::fstatat(parent.get(),leaf.c_str(),&pathAfter,
               AT_SYMLINK_NOFOLLOW)!=0 ||
     !sameStableStat(before,after) ||
     !sameStableStat(before,pathAfter))
    return Error::FileChanged;
  std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> digest{};
  if(CC_SHA256_Final(digest.data(),&context)!=1)
    return Error::ReadFailed;
  encodeDigest(digest.data(),candidate.sha256);
  return Error::None;
  }

Error hashCollection(int documentRoot, Collection& collection) {
  for(Candidate& candidate:collection.entries) {
    const Error error = hashCandidate(documentRoot,candidate);
    if(error!=Error::None)
      return error;
    }
  return Error::None;
  }

bool sameCollectionSnapshot(
    const Collection& before, const Collection& after) noexcept {
  if(before.totalBytes!=after.totalBytes ||
     before.excludedSeen!=after.excludedSeen ||
     before.entries.size()!=after.entries.size() ||
     before.directories.size()!=after.directories.size())
    return false;
  for(std::size_t index=0u; index<before.entries.size(); ++index) {
    const Candidate& lhs = before.entries[index];
    const Candidate& rhs = after.entries[index];
    if(lhs.rawRelativePath!=rhs.rawRelativePath ||
       lhs.normalizedRelativePath!=rhs.normalizedRelativePath ||
       lhs.byteSize!=rhs.byteSize ||
       !sameStableStat(lhs.identity,rhs.identity))
      return false;
    }
  for(std::size_t index=0u; index<before.directories.size(); ++index) {
    const DirectoryIdentity& lhs = before.directories[index];
    const DirectoryIdentity& rhs = after.directories[index];
    if(lhs.rawRelativePath!=rhs.rawRelativePath ||
       lhs.normalizedRelativePath!=rhs.normalizedRelativePath ||
       !sameStableStat(lhs.identity,rhs.identity))
      return false;
    }
  return true;
  }

std::string escapeJsonString(std::string_view source) {
  std::string escaped;
  escaped.reserve(source.size()+8u);
  static constexpr char Hex[] = "0123456789abcdef";
  for(const char rawValue:source) {
    const unsigned char value = static_cast<unsigned char>(rawValue);
    switch(value) {
      case '"': escaped += "\\\""; break;
      case '\\': escaped += "\\\\"; break;
      case '\b': escaped += "\\b"; break;
      case '\f': escaped += "\\f"; break;
      case '\n': escaped += "\\n"; break;
      case '\r': escaped += "\\r"; break;
      case '\t': escaped += "\\t"; break;
      default:
        if(value<0x20u) {
          escaped += "\\u00";
          escaped.push_back(Hex[(value>>4u)&0x0fu]);
          escaped.push_back(Hex[value&0x0fu]);
          }
        else {
          escaped.push_back(static_cast<char>(value));
          }
        break;
      }
    }
  return escaped;
  }

bool writeAll(int descriptor, std::string_view bytes) noexcept {
  std::size_t offset = 0u;
  while(offset<bytes.size()) {
    const ssize_t written = ::write(
        descriptor,bytes.data()+offset,bytes.size()-offset);
    if(written<0) {
      if(errno==EINTR)
        continue;
      return false;
      }
    if(written==0)
      return false;
    offset += static_cast<std::size_t>(written);
    }
  return true;
  }

class CanonicalWriter final {
  public:
    explicit CanonicalWriter(int descriptor) noexcept
      : descriptor(descriptor) {
      ready = CC_SHA256_Init(&digest)==1;
      }

    bool line(std::string_view value) noexcept {
      if(!ready || value.find('\n')!=std::string_view::npos)
        return false;
      if(!writeAll(descriptor,value) || !writeAll(descriptor,"\n"))
        return false;
      if(!updateDigest(digest,value.data(),value.size()) ||
         !updateDigest(digest,"\n",1u))
        return false;
      return true;
      }

    bool finish(std::array<char,65>& output) noexcept {
      if(!ready)
        return false;
      std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> encoded{};
      ready = false;
      if(CC_SHA256_Final(encoded.data(),&digest)!=1)
        return false;
      encodeDigest(encoded.data(),output);
      return true;
      }

  private:
    int descriptor = -1;
    CC_SHA256_CTX digest{};
    bool ready = false;
  };

Error createTemporary(
    int documentRoot,
    std::string_view leaf,
    FileDescriptor& descriptor,
    std::string& temporaryName) noexcept {
  for(unsigned attempt=0u; attempt<32u; ++attempt) {
    try {
      temporaryName = ".";
      temporaryName += leaf;
      temporaryName += ".tmp.";
      temporaryName += std::to_string(static_cast<uint64_t>(::getpid()));
      temporaryName += ".";
      temporaryName += std::to_string(attempt);
      }
    catch(...) {
      return Error::TemporaryFileFailed;
      }
    const int created = ::openat(
        documentRoot,temporaryName.c_str(),
        O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|closeOnExecFlag(),0600);
    if(created>=0) {
      descriptor.reset(created);
      return Error::None;
      }
    if(errno!=EEXIST)
      return Error::TemporaryFileFailed;
    }
  return Error::Collision;
  }

bool leafIsAbsent(int documentRoot, std::string_view leaf) {
  const std::string stableLeaf(leaf);
  struct stat identity{};
  if(::fstatat(documentRoot,stableLeaf.c_str(),&identity,
               AT_SYMLINK_NOFOLLOW)==0)
    return false;
  return errno==ENOENT;
  }

Error finishTemporary(
    FileDescriptor& descriptor,
    PreparedManifest& prepared) noexcept {
  if(::fchmod(descriptor.get(),0600)!=0 ||
     ::fsync(descriptor.get())!=0)
    return Error::SyncFailed;
  if(::fstat(descriptor.get(),&prepared.identity)!=0 ||
     !S_ISREG(prepared.identity.st_mode))
    return Error::TemporaryFileFailed;
  descriptor.reset();
  return Error::None;
  }

Error prepareResourceManifest(
    int documentRoot,
    const Collection& resources,
    PreparedManifest& prepared) noexcept {
  FileDescriptor descriptor;
  Error error = createTemporary(
      documentRoot,ResourceManifestFileName,
      descriptor,prepared.temporaryName);
  if(error!=Error::None)
    return error;
  CanonicalWriter writer(descriptor.get());
  try {
    const std::string header =
        "{\"schemaVersion\":1,\"roots\":[\"Data\",\"_work/Data\","
        "\"system\"],\"excluded\":[\"system/Gothic.ini\"],"
        "\"fileCount\":"+std::to_string(resources.entries.size())+
        ",\"totalBytes\":"+std::to_string(resources.totalBytes)+"}";
    if(!writer.line(header))
      return Error::WriteFailed;
    for(const Candidate& candidate:resources.entries) {
      const std::string line =
          "{\"relativePath\":\""+
          escapeJsonString(candidate.normalizedRelativePath)+
          "\",\"byteSize\":"+std::to_string(candidate.byteSize)+
          ",\"sha256\":\""+candidate.sha256.data()+"\"}";
      if(!writer.line(line))
        return Error::WriteFailed;
      }
    }
  catch(...) {
    return Error::WriteFailed;
    }
  if(!writer.finish(prepared.sha256))
    return Error::WriteFailed;
  return finishTemporary(descriptor,prepared);
  }

Error prepareProtectedSaveManifest(
    int documentRoot,
    const Collection& saves,
    PreparedManifest& prepared) noexcept {
  FileDescriptor descriptor;
  Error error = createTemporary(
      documentRoot,ProtectedSaveManifestFileName,
      descriptor,prepared.temporaryName);
  if(error!=Error::None)
    return error;
  CanonicalWriter writer(descriptor.get());
  try {
    const std::string header =
        "{\"schemaVersion\":1,\"protectedSlots\":[1,2,3,4],"
        "\"fileCount\":4,\"totalBytes\":"+
        std::to_string(saves.totalBytes)+"}";
    if(!writer.line(header))
      return Error::WriteFailed;
    for(std::size_t index=0u; index<saves.entries.size(); ++index) {
      const Candidate& candidate = saves.entries[index];
      const std::string line =
          "{\"slot\":"+std::to_string(index+1u)+
          ",\"fileName\":\""+
          escapeJsonString(candidate.normalizedRelativePath)+
          "\",\"byteSize\":"+std::to_string(candidate.byteSize)+
          ",\"sha256\":\""+candidate.sha256.data()+"\"}";
      if(!writer.line(line))
        return Error::WriteFailed;
      }
    }
  catch(...) {
    return Error::WriteFailed;
    }
  if(!writer.finish(prepared.sha256))
    return Error::WriteFailed;
  return finishTemporary(descriptor,prepared);
  }

void unlinkTemporary(
    int documentRoot, const PreparedManifest& prepared) noexcept {
  if(!prepared.temporaryName.empty())
    (void)::unlinkat(documentRoot,prepared.temporaryName.c_str(),0);
  }

Error verifyPublished(
    int documentRoot,
    std::string_view leaf,
    const PreparedManifest& prepared) {
  const std::string stableLeaf(leaf);
  struct stat published{};
  if(::fstatat(documentRoot,stableLeaf.c_str(),&published,
               AT_SYMLINK_NOFOLLOW)!=0 ||
     !S_ISREG(published.st_mode) ||
     !sameIdentityAndSize(prepared.identity,published))
    return Error::PublishFailed;
  if(published.st_size<0)
    return Error::PublishFailed;
  Candidate candidate;
  candidate.rawRelativePath = stableLeaf;
  candidate.normalizedRelativePath = stableLeaf;
  candidate.identity = published;
  candidate.byteSize = static_cast<uint64_t>(published.st_size);
  const Error hashed = hashCandidate(documentRoot,candidate);
  if(hashed!=Error::None ||
     std::strcmp(candidate.sha256.data(),prepared.sha256.data())!=0)
    return Error::PublishFailed;
  return Error::None;
  }

Error publishBoth(
    int documentRoot,
    PreparedManifest& resources,
    PreparedManifest& saves) {
  const std::string resourceLeaf(ResourceManifestFileName);
  const std::string saveLeaf(ProtectedSaveManifestFileName);
  if(::linkat(documentRoot,resources.temporaryName.c_str(),
              documentRoot,resourceLeaf.c_str(),0)!=0)
    return errno==EEXIST ? Error::Collision : Error::PublishFailed;
  if(::linkat(documentRoot,saves.temporaryName.c_str(),
              documentRoot,saveLeaf.c_str(),0)!=0) {
    const int publishError = errno;
    (void)::unlinkat(documentRoot,resourceLeaf.c_str(),0);
    (void)::fsync(documentRoot);
    return publishError==EEXIST ? Error::Collision : Error::PublishFailed;
    }
  if(::unlinkat(documentRoot,resources.temporaryName.c_str(),0)!=0 ||
     ::unlinkat(documentRoot,saves.temporaryName.c_str(),0)!=0) {
    (void)::unlinkat(documentRoot,resourceLeaf.c_str(),0);
    (void)::unlinkat(documentRoot,saveLeaf.c_str(),0);
    (void)::fsync(documentRoot);
    return Error::PublishFailed;
    }
  resources.temporaryName.clear();
  saves.temporaryName.clear();
  if(::fsync(documentRoot)!=0) {
    (void)::unlinkat(documentRoot,resourceLeaf.c_str(),0);
    (void)::unlinkat(documentRoot,saveLeaf.c_str(),0);
    (void)::fsync(documentRoot);
    return Error::SyncFailed;
    }
  Error error = verifyPublished(
      documentRoot,ResourceManifestFileName,resources);
  if(error==Error::None)
    error = verifyPublished(
        documentRoot,ProtectedSaveManifestFileName,saves);
  if(error!=Error::None) {
    (void)::unlinkat(documentRoot,resourceLeaf.c_str(),0);
    (void)::unlinkat(documentRoot,saveLeaf.c_str(),0);
    (void)::fsync(documentRoot);
    }
  return error;
  }

}

const char* errorName(Error error) noexcept {
  switch(error) {
    case Error::None: return "none";
    case Error::UnsupportedPlatform: return "unsupported-platform";
    case Error::InvalidDocumentRoot: return "invalid-document-root";
    case Error::MissingRoot: return "missing-root";
    case Error::MissingExcludedFile: return "missing-excluded-file";
    case Error::MissingProtectedSave: return "missing-protected-save";
    case Error::InvalidUtf8: return "invalid-utf8";
    case Error::NonCanonicalPath: return "non-canonical-path";
    case Error::NormalizedPathCollision: return "normalized-path-collision";
    case Error::NonRegularEntry: return "non-regular-entry";
    case Error::FileCountLimit: return "file-count-limit";
    case Error::FileSizeLimit: return "file-size-limit";
    case Error::TotalSizeLimit: return "total-size-limit";
    case Error::OpenFailed: return "open-failed";
    case Error::ReadFailed: return "read-failed";
    case Error::FileChanged: return "file-changed";
    case Error::Collision: return "collision";
    case Error::TemporaryFileFailed: return "temporary-file-failed";
    case Error::WriteFailed: return "write-failed";
    case Error::SyncFailed: return "sync-failed";
    case Error::PublishFailed: return "publish-failed";
    }
  return "unknown";
  }

namespace {

using RevalidationHook = bool (*)(
    const std::filesystem::path& documentRoot) noexcept;

Result createCanonicalManifestsImpl(
    const std::filesystem::path& documentRoot,
    RevalidationHook revalidationHook) noexcept {
  Result result;
  try {
    const std::string rootPath = documentRoot.string();
    FileDescriptor root(::open(
        rootPath.c_str(),
        O_RDONLY|O_DIRECTORY|O_NOFOLLOW|closeOnExecFlag()));
    if(!root) {
      result.error = Error::InvalidDocumentRoot;
      return result;
      }
    struct stat rootBefore{};
    if(::fstat(root.get(),&rootBefore)!=0 ||
       !S_ISDIR(rootBefore.st_mode)) {
      result.error = Error::InvalidDocumentRoot;
      return result;
      }
    if(!leafIsAbsent(root.get(),ResourceManifestFileName) ||
       !leafIsAbsent(root.get(),ProtectedSaveManifestFileName)) {
      result.error = Error::Collision;
      return result;
      }

    Collection resources;
    result.error = collectResources(root.get(),resources);
    result.resourceFileCount = resources.entries.size();
    result.resourceTotalBytes = resources.totalBytes;
    if(result.error!=Error::None)
      return result;
    Collection saves;
    result.error = collectProtectedSaves(root.get(),saves);
    result.protectedSaveFileCount = saves.entries.size();
    result.protectedSaveTotalBytes = saves.totalBytes;
    if(result.error!=Error::None)
      return result;
    result.error = hashCollection(root.get(),resources);
    if(result.error!=Error::None)
      return result;
    result.error = hashCollection(root.get(),saves);
    if(result.error!=Error::None)
      return result;
    if(revalidationHook!=nullptr && !revalidationHook(documentRoot)) {
      result.error = Error::FileChanged;
      return result;
      }

    Collection resourcesAfterHash;
    result.error = collectResources(root.get(),resourcesAfterHash);
    if(result.error!=Error::None)
      return result;
    Collection savesAfterHash;
    result.error = collectProtectedSaves(root.get(),savesAfterHash);
    if(result.error!=Error::None)
      return result;
    if(!sameCollectionSnapshot(resources,resourcesAfterHash) ||
       !sameCollectionSnapshot(saves,savesAfterHash)) {
      result.error = Error::FileChanged;
      return result;
      }

    struct stat rootAfterHash{};
    if(::fstat(root.get(),&rootAfterHash)!=0 ||
       !sameStableStat(rootBefore,rootAfterHash)) {
      result.error = Error::FileChanged;
      return result;
      }

    PreparedManifest resourceManifest;
    PreparedManifest saveManifest;
    result.error = prepareResourceManifest(
        root.get(),resources,resourceManifest);
    if(result.error!=Error::None) {
      unlinkTemporary(root.get(),resourceManifest);
      return result;
      }
    result.error = prepareProtectedSaveManifest(
        root.get(),saves,saveManifest);
    if(result.error!=Error::None) {
      unlinkTemporary(root.get(),resourceManifest);
      unlinkTemporary(root.get(),saveManifest);
      return result;
      }
    result.error = publishBoth(root.get(),resourceManifest,saveManifest);
    unlinkTemporary(root.get(),resourceManifest);
    unlinkTemporary(root.get(),saveManifest);
    if(result.error!=Error::None)
      return result;
    result.resourceManifestSha256 = resourceManifest.sha256;
    result.protectedSaveManifestSha256 = saveManifest.sha256;
    return result;
    }
  catch(...) {
    result.error = Error::OpenFailed;
    return result;
    }
  }

}

Result createCanonicalManifests(
    const std::filesystem::path& documentRoot) noexcept {
  return createCanonicalManifestsImpl(documentRoot,nullptr);
  }

Result removeCanonicalManifests(
    const std::filesystem::path& documentRoot) noexcept {
  Result result;
  try {
    if(documentRoot.empty()) {
      result.error = Error::InvalidDocumentRoot;
      return result;
      }
    const int descriptor = ::open(
        documentRoot.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|closeOnExecFlag());
    FileDescriptor root(descriptor);
    if(!root) {
      result.error = Error::OpenFailed;
      return result;
      }
    constexpr std::array<std::string_view,2> leaves = {
      ResourceManifestFileName,ProtectedSaveManifestFileName,
      };
    std::array<bool,2> present{};
    for(std::size_t index=0u; index<leaves.size(); ++index) {
      struct stat identity{};
      const std::string name(leaves[index]);
      if(::fstatat(root.get(),name.c_str(),&identity,AT_SYMLINK_NOFOLLOW)==0) {
        if(!S_ISREG(identity.st_mode) || identity.st_nlink!=1) {
          result.error = Error::NonRegularEntry;
          return result;
          }
        present[index] = true;
        continue;
        }
      if(errno!=ENOENT) {
        result.error = Error::OpenFailed;
        return result;
        }
      }
    for(std::size_t index=0u; index<leaves.size(); ++index) {
      if(!present[index])
        continue;
      const std::string name(leaves[index]);
      if(::unlinkat(root.get(),name.c_str(),0)!=0) {
        result.error = Error::WriteFailed;
        return result;
        }
      }
    for(const auto leaf:leaves) {
      struct stat identity{};
      const std::string name(leaf);
      if(::fstatat(root.get(),name.c_str(),&identity,AT_SYMLINK_NOFOLLOW)==0 ||
         errno!=ENOENT) {
        result.error = Error::FileChanged;
        return result;
        }
      }
    if(::fsync(root.get())!=0) {
      result.error = Error::SyncFailed;
      return result;
      }
    return result;
    }
  catch(...) {
    result.error = Error::OpenFailed;
    return result;
    }
  }

#if defined(OPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST)
Result createCanonicalManifestsForTest(
    const std::filesystem::path& documentRoot,
    RevalidationTestHook hook) noexcept {
  return createCanonicalManifestsImpl(documentRoot,hook);
  }
#endif

}

#else

namespace RendererIOSDeviceIntegrity {

const char* errorName(Error error) noexcept {
  return error==Error::UnsupportedPlatform
      ? "unsupported-platform" : "unavailable";
  }

Result createCanonicalManifests(
    const std::filesystem::path&) noexcept {
  Result result;
  result.error = Error::UnsupportedPlatform;
  return result;
  }

Result removeCanonicalManifests(
    const std::filesystem::path&) noexcept {
  Result result;
  result.error = Error::UnsupportedPlatform;
  return result;
  }

}

#endif
#endif
