#include "rendereriosplatform.h"
#include "iospipelinearchivepolicy.h"
#include "ioslandscapeshaderabi.h"

#include <Tempest/Platform>

#if defined(__IOS__)

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#include <array>
#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <limits>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <utility>
#include <vector>

static_assert(
  RendererIOSPipelineArchive::MetallibAbiVersion==
  RendererIOSShader::AbiVersion);

namespace {

std::string fileSystemPath(NSString* path) {
  if(path==nil)
    return {};
  const char* raw = [path fileSystemRepresentation];
  return raw==nullptr ? std::string{} : std::string{raw};
  }

std::string metallibSha256(NSString* path) {
  NSError* error = nil;
  NSData* bytes =
    [NSData dataWithContentsOfFile:path
                          options:NSDataReadingMappedIfSafe
                            error:&error];
  if(bytes==nil || error!=nil ||
     bytes.length>std::numeric_limits<CC_LONG>::max())
    return {};

  std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> digest = {};
  if(CC_SHA256(bytes.bytes,static_cast<CC_LONG>(bytes.length),
               digest.data())==nullptr)
    return {};

  static constexpr char Hex[] = "0123456789abcdef";
  std::string encoded;
  encoded.resize(digest.size()*2u);
  for(size_t i=0u; i<digest.size(); ++i) {
    encoded[i*2u]     = Hex[(digest[i]>>4u)&0x0fu];
    encoded[i*2u+1u] = Hex[digest[i]&0x0fu];
    }
  return encoded;
  }

struct ResolvedPipelineArchive final {
  RendererIOSPipelineArchiveDescriptor descriptor;
  std::string                          cacheRoot;
  };

ResolvedPipelineArchive resolvePipelineArchiveDescriptor(
    const std::string& metallibPath) {
  ResolvedPipelineArchive resolved;
  if(metallibPath.empty())
    return resolved;

  NSString* libraryPath =
    [NSString stringWithUTF8String:metallibPath.c_str()];
  if(libraryPath==nil)
    return {};
  resolved.descriptor.metallibSha256 = metallibSha256(libraryPath);
  if(!RendererIOSPipelineArchive::isLowercaseSha256(
       resolved.descriptor.metallibSha256))
    return {};

  NSArray<NSString*>* cacheRoots =
    NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory,NSUserDomainMask,YES);
  NSString* cacheRoot = cacheRoots.firstObject;
  NSString* relativeDirectory =
    [NSString stringWithUTF8String:
      RendererIOSPipelineArchive::RelativeDirectory.data()];
  NSString* archiveFile =
    [NSString stringWithUTF8String:
      RendererIOSPipelineArchive::ArchiveFileName.data()];
  NSString* provenanceFile =
    [NSString stringWithUTF8String:
      RendererIOSPipelineArchive::ProvenanceFileName.data()];
  if(cacheRoot==nil || relativeDirectory==nil ||
     archiveFile==nil || provenanceFile==nil)
    return {};
  resolved.cacheRoot = fileSystemPath(cacheRoot);
  if(resolved.cacheRoot.empty())
    return {};

  NSString* archiveDirectory =
    [cacheRoot stringByAppendingPathComponent:relativeDirectory];
  NSString* archivePath =
    [archiveDirectory stringByAppendingPathComponent:archiveFile];
  NSString* provenancePath =
    [archiveDirectory stringByAppendingPathComponent:provenanceFile];
  resolved.descriptor.archivePath    = fileSystemPath(archivePath);
  resolved.descriptor.provenancePath = fileSystemPath(provenancePath);
  if(resolved.descriptor.archivePath.empty() ||
     resolved.descriptor.provenancePath.empty())
    return {};
  return resolved;
  }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)

class FileDescriptor final {
  public:
    explicit FileDescriptor(int value = -1) noexcept : value(value) {
      }

    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;

    FileDescriptor(FileDescriptor&& other) noexcept : value(other.value) {
      other.value = -1;
      }

    FileDescriptor& operator=(FileDescriptor&& other) noexcept {
      if(this==&other)
        return *this;
      if(value>=0)
        (void)::close(value);
      value = other.value;
      other.value = -1;
      return *this;
      }

    ~FileDescriptor() {
      if(value>=0)
        (void)::close(value);
      }

    int get() const noexcept {
      return value;
      }

    void closeChecked(const char* failure) {
      const int closing = value;
      value = -1;
      if(closing<0 || ::close(closing)!=0)
        throw std::runtime_error(failure);
      }

  private:
    int value = -1;
  };

FileDescriptor openPipelineArchiveDirectory(
    const std::string& cacheRoot) {
  FileDescriptor directory(::open(
    cacheRoot.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW));
  if(directory.get()<0)
    throw std::runtime_error(
      "RendererIOS pipeline archive test cache root open failed");

  for(const std::string_view component:
      RendererIOSPipelineArchive::TestModeDirectoryComponents) {
    if(::mkdirat(directory.get(),component.data(),0700)!=0 &&
       errno!=EEXIST)
      throw std::runtime_error(
        "RendererIOS pipeline archive test directory creation failed");
    FileDescriptor child(::openat(
      directory.get(),component.data(),
      O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW));
    if(child.get()<0)
      throw std::runtime_error(
        "RendererIOS pipeline archive test directory open failed");
    directory = std::move(child);
    }
  return directory;
  }

bool exactLeafAbsentAt(
    int directory, const char* leaf, const char* failure) {
  struct stat info = {};
  if(::fstatat(directory,leaf,&info,AT_SYMLINK_NOFOLLOW)==0)
    return false;
  if(errno==ENOENT)
    return true;
  throw std::runtime_error(failure);
  }

void unlinkExactLeafAt(
    int directory, const char* leaf, const char* failure) {
  if(::unlinkat(directory,leaf,0)==0 || errno==ENOENT)
    return;
  throw std::runtime_error(failure);
  }

std::vector<uint8_t> readExactRegularFileAt(
    int directory, const char* leaf, const char* failure) {
  FileDescriptor file(::openat(
    directory,leaf,O_RDONLY|O_CLOEXEC|O_NOFOLLOW));
  if(file.get()<0)
    throw std::runtime_error(failure);

  struct stat info = {};
  if(::fstat(file.get(),&info)!=0 || !S_ISREG(info.st_mode) ||
     info.st_size<0 ||
     static_cast<uintmax_t>(info.st_size)>
       std::numeric_limits<size_t>::max())
    throw std::runtime_error(failure);
  std::vector<uint8_t> bytes(static_cast<size_t>(info.st_size));
  size_t offset = 0u;
  while(offset<bytes.size()) {
    const ssize_t count = ::read(
      file.get(),bytes.data()+offset,bytes.size()-offset);
    if(count<0 && errno==EINTR)
      continue;
    if(count<=0)
      throw std::runtime_error(failure);
    offset += static_cast<size_t>(count);
    }
  file.closeChecked(failure);
  return bytes;
  }

void writeAll(int file, std::string_view bytes, const char* failure) {
  size_t offset = 0u;
  while(offset<bytes.size()) {
    const ssize_t count = ::write(
      file,bytes.data()+offset,bytes.size()-offset);
    if(count<0 && errno==EINTR)
      continue;
    if(count<=0)
      throw std::runtime_error(failure);
    offset += static_cast<size_t>(count);
    }
  }

void fsyncChecked(int descriptor, const char* failure) {
  while(::fsync(descriptor)!=0) {
    if(errno==EINTR)
      continue;
    throw std::runtime_error(failure);
    }
  }

#endif

}

RendererIOSPlatformInfo rendererIOSPlatformInfo() noexcept {
  RendererIOSPlatformInfo info;
  std::snprintf(info.osVersion.data(),info.osVersion.size(),"unknown");
  std::snprintf(info.deviceFamily.data(),info.deviceFamily.size(),"unknown");

  // The game runs on Tempest's hand-swapped main-thread fiber. Do not push an
  // Objective-C autorelease pool here; UIKit's run-loop pool owns autoreleased
  // objects created by this short synchronous query.
  @try {
    const NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    std::snprintf(info.osVersion.data(),info.osVersion.size(),"%ld.%ld.%ld",
                  long(version.majorVersion),long(version.minorVersion),long(version.patchVersion));
    }
  @catch(NSException* exception) {
    (void)exception;
    }

  size_t size = info.deviceFamily.size();
  if(sysctlbyname("hw.machine",info.deviceFamily.data(),&size,nullptr,0)!=0 || size==0u)
    std::snprintf(info.deviceFamily.data(),info.deviceFamily.size(),"unknown");
  else
    info.deviceFamily.back() = '\0';
  return info;
  }

std::string rendererIOSMetalLibraryPath() {
  // This runs on Tempest's game fiber. UIKit's run-loop pool owns these short
  // autoreleased Foundation values; do not create a nested autorelease pool.
  NSString* libraryName =
      [NSString stringWithUTF8String:RendererIOSShader::LibraryName.data()];
  if(libraryName==nil)
    return {};
  NSURL* libraryUrl =
      [[NSBundle mainBundle] URLForResource:libraryName
                             withExtension:@"metallib"];
  if(libraryUrl==nil)
    return {};
  NSString* libraryPath = [libraryUrl path];
  if(libraryPath==nil)
    return {};
  const char* path = [libraryPath fileSystemRepresentation];
  return path==nullptr ? std::string{} : std::string{path};
  }

RendererIOSPipelineArchiveDescriptor
rendererIOSPipelineArchiveDescriptor(const std::string& metallibPath) {
  // Archive discovery runs once, before Tempest creates the Metal device. The
  // sidecar is an exact provenance record for the metallib digest. If it is
  // missing or stale, discard the archive before Tempest can load it, then
  // replace the sidecar atomically. Any filesystem/hash failure disables the
  // optional cache for this launch without blocking renderer startup.
  try {
    @try {
      const ResolvedPipelineArchive resolved =
        resolvePipelineArchiveDescriptor(metallibPath);
      RendererIOSPipelineArchiveDescriptor descriptor = resolved.descriptor;
      if(descriptor.archivePath.empty() ||
         descriptor.provenancePath.empty())
        return {};

      NSString* archivePath = [NSString
        stringWithUTF8String:descriptor.archivePath.c_str()];
      NSString* provenancePath = [NSString
        stringWithUTF8String:descriptor.provenancePath.c_str()];
      NSString* archiveDirectory =
        [archivePath stringByDeletingLastPathComponent];
      if(archivePath==nil || provenancePath==nil || archiveDirectory==nil)
        return {};

      NSFileManager* manager = NSFileManager.defaultManager;
      NSError* error = nil;
      if(![manager createDirectoryAtPath:archiveDirectory
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:&error] || error!=nil)
        return {};

      const std::string expectedRecord =
        RendererIOSPipelineArchive::provenanceRecord(
          descriptor.metallibSha256);
      NSData* expectedData =
        [NSData dataWithBytes:expectedRecord.data()
                       length:expectedRecord.size()];
      error = nil;
      NSData* existingData =
        [NSData dataWithContentsOfFile:provenancePath
                              options:NSDataReadingMappedIfSafe
                                error:&error];
      const bool provenanceMatches =
        existingData!=nil && [existingData isEqualToData:expectedData];
      if(!provenanceMatches) {
        if([manager fileExistsAtPath:archivePath]) {
          error = nil;
          if(![manager removeItemAtPath:archivePath error:&error] ||
             error!=nil)
            return {};
          descriptor.invalidatedStaleArchive = true;
          }
        error = nil;
        if(![expectedData writeToFile:provenancePath
                             options:NSDataWritingAtomic
                               error:&error] || error!=nil)
          return {};
        }

      return descriptor;
      }
    @catch(NSException* exception) {
      (void)exception;
      return {};
      }
    }
  catch(...) {
    return {};
    }
  }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)

RendererIOSPipelineArchiveTestModeResult
rendererIOSApplyPipelineArchiveTestMode(
    const std::string& metallibPath,
    RendererIOSPipelineArchive::TestMode mode) {
  // Test mutation is app-owned and runs before MetalApi construction. Resolve
  // the same paths/digest as production without invoking descriptor repair,
  // and never enumerate or clear a cache directory.
  @try {
    if(mode==RendererIOSPipelineArchive::TestMode::None)
      throw std::invalid_argument(
        "RendererIOS pipeline archive test mode must be active");

    const ResolvedPipelineArchive resolved =
      resolvePipelineArchiveDescriptor(metallibPath);
    const RendererIOSPipelineArchiveDescriptor& descriptor =
      resolved.descriptor;
    if(descriptor.archivePath.empty() ||
       descriptor.provenancePath.empty() ||
       resolved.cacheRoot.empty() ||
       !RendererIOSPipelineArchive::isLowercaseSha256(
         descriptor.metallibSha256))
      throw std::runtime_error(
        "RendererIOS pipeline archive test descriptor unavailable");

    FileDescriptor archiveDirectory =
      openPipelineArchiveDirectory(resolved.cacheRoot);
    const int directory = archiveDirectory.get();
    const char* archiveLeaf =
      RendererIOSPipelineArchive::ArchiveFileName.data();
    const char* provenanceLeaf =
      RendererIOSPipelineArchive::ProvenanceFileName.data();
    const char* temporaryLeaf =
      RendererIOSPipelineArchive::TestModeTemporaryFileName.data();

    if(mode==RendererIOSPipelineArchive::TestMode::Cold) {
      unlinkExactLeafAt(
        directory,archiveLeaf,
        "RendererIOS pipeline archive cold archive removal failed");
      unlinkExactLeafAt(
        directory,provenanceLeaf,
        "RendererIOS pipeline archive cold provenance removal failed");
      const bool archiveAbsent = exactLeafAbsentAt(
        directory,archiveLeaf,
        "RendererIOS pipeline archive cold archive verification failed");
      const bool provenanceAbsent = exactLeafAbsentAt(
        directory,provenanceLeaf,
        "RendererIOS pipeline archive cold provenance verification failed");
      if(!archiveAbsent || !provenanceAbsent)
        throw std::runtime_error(
          "RendererIOS pipeline archive cold removal verification failed");
      return {0u,true,false};
      }
    if(mode!=RendererIOSPipelineArchive::TestMode::Corrupt)
      throw std::invalid_argument(
        "RendererIOS pipeline archive test mode is invalid");

    const std::string canonicalRecord =
      RendererIOSPipelineArchive::provenanceRecord(
        descriptor.metallibSha256);
    const std::vector<uint8_t> expectedProvenance(
      canonicalRecord.begin(),canonicalRecord.end());
    const std::vector<uint8_t> provenanceBefore =
      readExactRegularFileAt(
        directory,provenanceLeaf,
        "RendererIOS pipeline archive corrupt provenance read failed");
    if(provenanceBefore!=expectedProvenance)
      throw std::runtime_error(
        "RendererIOS pipeline archive corrupt provenance is not canonical");

    const std::vector<uint8_t> archiveBefore =
      readExactRegularFileAt(
        directory,archiveLeaf,
        "RendererIOS pipeline archive corrupt archive read failed");
    if(archiveBefore.empty())
      throw std::runtime_error(
        "RendererIOS pipeline archive corrupt archive is empty");

    const std::string_view payload =
      RendererIOSPipelineArchive::CorruptArchivePayload;
    unlinkExactLeafAt(
      directory,temporaryLeaf,
      "RendererIOS pipeline archive corrupt temp cleanup failed");
    if(!exactLeafAbsentAt(
         directory,temporaryLeaf,
         "RendererIOS pipeline archive corrupt temp verification failed"))
      throw std::runtime_error(
        "RendererIOS pipeline archive corrupt temp still exists");

    try {
      FileDescriptor temporary(::openat(
        directory,temporaryLeaf,
        O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600));
      if(temporary.get()<0)
        throw std::runtime_error(
          "RendererIOS pipeline archive corrupt temp creation failed");
      writeAll(
        temporary.get(),payload,
        "RendererIOS pipeline archive corrupt payload write failed");
      fsyncChecked(
        temporary.get(),
        "RendererIOS pipeline archive corrupt payload sync failed");
      temporary.closeChecked(
        "RendererIOS pipeline archive corrupt payload close failed");
      if(::renameat(directory,temporaryLeaf,directory,archiveLeaf)!=0)
        throw std::runtime_error(
          "RendererIOS pipeline archive corrupt payload rename failed");
      if(!exactLeafAbsentAt(
           directory,temporaryLeaf,
           "RendererIOS pipeline archive corrupt temp post-rename failed"))
        throw std::runtime_error(
          "RendererIOS pipeline archive corrupt temp survived rename");
      fsyncChecked(
        directory,
        "RendererIOS pipeline archive corrupt directory sync failed");
      }
    catch(...) {
      if(::unlinkat(directory,temporaryLeaf,0)!=0 && errno!=ENOENT)
        throw std::runtime_error(
          "RendererIOS pipeline archive corrupt temp error cleanup failed");
      throw;
      }

    const std::vector<uint8_t> writtenData =
      readExactRegularFileAt(
        directory,archiveLeaf,
        "RendererIOS pipeline archive corrupt payload readback failed");
    const std::vector<uint8_t> expectedPayload(
      payload.begin(),payload.end());
    if(writtenData!=expectedPayload)
      throw std::runtime_error(
        "RendererIOS pipeline archive corrupt payload verification failed");

    const std::vector<uint8_t> provenanceAfter =
      readExactRegularFileAt(
        directory,provenanceLeaf,
        "RendererIOS pipeline archive corrupt provenance re-read failed");
    if(provenanceAfter!=provenanceBefore ||
       provenanceAfter!=expectedProvenance)
      throw std::runtime_error(
        "RendererIOS pipeline archive corrupt provenance changed");
    return {payload.size(),false,true};
    }
  @catch(NSException* exception) {
    (void)exception;
    throw std::runtime_error(
      "RendererIOS pipeline archive test mode raised an Objective-C exception");
    }
  }

#endif

#endif
