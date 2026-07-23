#include "iosmetalresourceclearpassprobe.h"

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
#include <algorithm>
#include <array>
#include <cerrno>
#include <dirent.h>
#include <filesystem>
#include <fcntl.h>
#include <limits>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>
#endif

namespace {

IOSResourceDesc presentResource() noexcept {
  IOSResourceDesc resource;
  resource.id = IOSResourceId{1u};
  resource.kind = IOSResourceKind::Texture;
  resource.lifetime = IOSResourceLifetime::External;
  resource.initialContent = IOSInitialContent::Defined;
  resource.memoryless = false;
  resource.aliasable = false;
  resource.aliasGroup = {};
  resource.layout = {
    IOSPixelFormat::Bgra8Unorm,{4u,4u},1u,1u,0u,
    };
  resource.usage = IOSResourceUsage::Present;
  return resource;
  }

IOSResourceDesc transientResource(uint32_t id, bool memoryless) noexcept {
  IOSResourceDesc resource;
  resource.id = IOSResourceId{id};
  resource.kind = IOSResourceKind::Texture;
  resource.lifetime = IOSResourceLifetime::Transient;
  resource.initialContent = IOSInitialContent::Undefined;
  resource.memoryless = memoryless;
  resource.aliasable = false;
  resource.aliasGroup = {};
  resource.layout = {
    IOSPixelFormat::Rgba8Unorm,{4u,4u},1u,1u,0u,
    };
  resource.usage = IOSResourceUsage::RenderAttachment;
  return resource;
  }

IOSResourceUse attachmentUse(uint32_t resource, IOSStoreAction store) noexcept {
  return {
    IOSResourceId{resource},IOSUseSemantic::RenderAttachment,
    IOSLoadAction::Clear,store,IOSAttachmentWriteMode::FullOverwrite,
    };
  }

bool exactResource(const IOSResourceDesc& lhs,
                   const IOSResourceDesc& rhs) noexcept {
  return lhs.id==rhs.id && lhs.kind==rhs.kind &&
         lhs.lifetime==rhs.lifetime &&
         lhs.initialContent==rhs.initialContent &&
         lhs.memoryless==rhs.memoryless && lhs.aliasable==rhs.aliasable &&
         lhs.aliasGroup==rhs.aliasGroup && lhs.layout==rhs.layout &&
         lhs.usage==rhs.usage;
  }

bool exactUse(const IOSResourceUse& lhs,
              const IOSResourceUse& rhs) noexcept {
  return lhs.resource==rhs.resource && lhs.semantic==rhs.semantic &&
         lhs.load==rhs.load && lhs.store==rhs.store &&
         lhs.attachmentWriteMode==rhs.attachmentWriteMode;
  }

bool exactSingleUsePass(const IOSPassDesc& pass,
                        IOSPassId id,
                        IOSPassKind kind,
                        const IOSResourceUse& use) noexcept {
  return pass.id==id && pass.kind==kind && pass.uses.size()==1u &&
         exactUse(pass.uses[0],use);
  }

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
constexpr uint64_t MaxCaptureArtifactBytes = 512u*1024u*1024u;
constexpr uint64_t MaxCaptureArtifactEntries = 65536u;
constexpr std::size_t MaxCaptureLinkTargetLength = 4096u;
constexpr char MaterializingSuffix[] = ".rendererios-materializing";
constexpr char RollbackSuffix[] = ".rendererios-rollback";

class ScopedFileDescriptor final {
  public:
    ScopedFileDescriptor() noexcept = default;

    explicit ScopedFileDescriptor(int value) noexcept
      : value(value) {
      }

    ~ScopedFileDescriptor() {
      reset();
      }

    ScopedFileDescriptor(const ScopedFileDescriptor&) = delete;
    ScopedFileDescriptor& operator=(const ScopedFileDescriptor&) = delete;

    ScopedFileDescriptor(ScopedFileDescriptor&& other) noexcept
      : value(other.release()) {
      }

    ScopedFileDescriptor& operator=(ScopedFileDescriptor&& other) noexcept {
      if(this==&other)
        return *this;
      reset(other.release());
      return *this;
      }

    int get() const noexcept {
      return value;
      }

    explicit operator bool() const noexcept {
      return value>=0;
      }

    void reset(int next = -1) noexcept {
      if(value>=0)
        (void)::close(value);
      value = next;
      }

    int release() noexcept {
      const int released = value;
      value = -1;
      return released;
      }

  private:
    int value = -1;
  };

struct CaptureLinkPlan final {
  std::filesystem::path relativeLink;
  std::filesystem::path relativeTarget;
  std::string rawTarget;
  struct stat targetStat = {};
  struct stat temporaryStat = {};
  bool temporaryPrepared = false;
  };

enum class CaptureDirectoryScanStatus : uint8_t {
  Success,
  EntryLimit,
  UnsafeEntry,
  SpecialNode,
  TooLarge,
  Symlink,
  };

class ScopedDirectoryStream final {
  public:
    ScopedDirectoryStream() noexcept = default;

    ~ScopedDirectoryStream() {
      if(value!=nullptr)
        (void)::closedir(value);
      }

    ScopedDirectoryStream(const ScopedDirectoryStream&) = delete;
    ScopedDirectoryStream& operator=(const ScopedDirectoryStream&) = delete;

    bool openDuplicate(int descriptor) noexcept {
      const int duplicate = ::fcntl(descriptor,F_DUPFD_CLOEXEC,0);
      if(duplicate<0)
        return false;
      value = ::fdopendir(duplicate);
      if(value==nullptr) {
        (void)::close(duplicate);
        return false;
        }
      ::rewinddir(value);
      return true;
      }

    DIR* get() const noexcept {
      return value;
      }

  private:
    DIR* value = nullptr;
  };

bool safeRelativeCapturePath(const std::filesystem::path& path,
                             bool allowEmpty) {
  if(path.has_root_path() || path.is_absolute())
    return false;
  if(path.empty())
    return allowEmpty;
  for(const auto& component:path) {
    const std::string& value = component.native();
    if(value.empty() || value=="." || value==".." ||
       value.find('\n')!=std::string::npos ||
       value.find('\r')!=std::string::npos)
      return false;
    }
  return true;
  }

bool safeRelativeLinkTargetPath(const std::filesystem::path& path) {
  if(path.empty() || path.has_root_path() || path.is_absolute())
    return false;
  for(const auto& component:path) {
    const std::string& value = component.native();
    if(value.empty() || value==".." ||
       value.find('\n')!=std::string::npos ||
       value.find('\r')!=std::string::npos)
      return false;
    }
  return true;
  }

bool safeCaptureEntryName(const std::string& name) noexcept {
  return !name.empty() && name!="." && name!=".." &&
         name.find('/')==std::string::npos &&
         name.find('\n')==std::string::npos &&
         name.find('\r')==std::string::npos;
  }

bool addCaptureBytes(uint64_t& total, uint64_t addition) noexcept {
  if(addition>MaxCaptureArtifactBytes ||
     total>MaxCaptureArtifactBytes-addition)
    return false;
  total += addition;
  return true;
  }

bool statSize(const struct stat& value, uint64_t& size) noexcept {
  if(value.st_size<0)
    return false;
  size = static_cast<uint64_t>(value.st_size);
  return size<=MaxCaptureArtifactBytes;
  }

bool sameNodeIdentity(const struct stat& lhs,
                      const struct stat& rhs) noexcept {
  return lhs.st_dev==rhs.st_dev && lhs.st_ino==rhs.st_ino &&
         (lhs.st_mode&S_IFMT)==(rhs.st_mode&S_IFMT);
  }

bool sameFileIdentity(const struct stat& lhs,
                      const struct stat& rhs) noexcept {
  return sameNodeIdentity(lhs,rhs) && lhs.st_size==rhs.st_size &&
         lhs.st_mode==rhs.st_mode;
  }

bool rootDirectoryEntryIdentityMatches(
    int rootParentDescriptor,
    const std::string& rootName,
    const struct stat& openedRootStat) noexcept {
  struct stat currentRootStat = {};
  return ::fstatat(rootParentDescriptor,rootName.c_str(),&currentRootStat,
                   AT_SYMLINK_NOFOLLOW)==0 &&
         !S_ISLNK(currentRootStat.st_mode) &&
         sameNodeIdentity(currentRootStat,openedRootStat);
  }

bool duplicateRootDescriptor(int rootDescriptor,
                             ScopedFileDescriptor& result) noexcept {
  const int duplicate = ::fcntl(rootDescriptor,F_DUPFD_CLOEXEC,0);
  if(duplicate<0)
    return false;
  result.reset(duplicate);
  return true;
  }

bool openRootedDirectory(int rootDescriptor,
                         const std::filesystem::path& relative,
                         ScopedFileDescriptor& result) {
  if(!safeRelativeCapturePath(relative,true) ||
     !duplicateRootDescriptor(rootDescriptor,result))
    return false;
  for(const auto& component:relative) {
    const std::string& name = component.native();
    const int opened = ::openat(
        result.get(),name.c_str(),
        O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(opened<0)
      return false;
    result.reset(opened);
    }
  return true;
  }

bool openRootedRegular(int rootDescriptor,
                       const std::filesystem::path& relative,
                       ScopedFileDescriptor& result,
                       struct stat& resultStat) {
  if(!safeRelativeCapturePath(relative,false))
    return false;
  ScopedFileDescriptor parent;
  if(!openRootedDirectory(rootDescriptor,relative.parent_path(),parent))
    return false;
  const std::string name = relative.filename().native();
  const int opened = ::openat(
      parent.get(),name.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
  if(opened<0)
    return false;
  result.reset(opened);
  if(::fstat(result.get(),&resultStat)!=0 || !S_ISREG(resultStat.st_mode))
    return false;
  uint64_t ignored = 0u;
  return statSize(resultStat,ignored);
  }

bool readRelativeLinkAt(int parentDescriptor,
                        const std::string& name,
                        std::string& target) {
  std::array<char,MaxCaptureLinkTargetLength+1u> buffer = {};
  const ssize_t count = ::readlinkat(
      parentDescriptor,name.c_str(),buffer.data(),MaxCaptureLinkTargetLength);
  if(count<=0 || static_cast<std::size_t>(count)>=MaxCaptureLinkTargetLength)
    return false;
  target.assign(buffer.data(),static_cast<std::size_t>(count));
  return target.find('\0')==std::string::npos;
  }

bool temporarySiblingAbsent(int parentDescriptor,
                            const std::string& name) noexcept {
  struct stat existing = {};
  if(::fstatat(parentDescriptor,name.c_str(),&existing,
               AT_SYMLINK_NOFOLLOW)==0)
    return false;
  return errno==ENOENT;
  }

CaptureDirectoryScanStatus scanCaptureDirectory(
    int directoryDescriptor,
    const std::filesystem::path& relativeDirectory,
    std::vector<std::filesystem::path>* relativeLinks,
    uint64_t& entries,
    uint64_t& regularFiles,
    uint64_t& totalBytes) {
  ScopedDirectoryStream stream;
  if(!stream.openDuplicate(directoryDescriptor))
    return CaptureDirectoryScanStatus::UnsafeEntry;
  while(true) {
    errno = 0;
    const struct dirent* const entry = ::readdir(stream.get());
    if(entry==nullptr)
      return errno==0 ? CaptureDirectoryScanStatus::Success :
                        CaptureDirectoryScanStatus::UnsafeEntry;
    const std::string name(entry->d_name);
    if(name=="." || name=="..")
      continue;
    ++entries;
    if(entries>MaxCaptureArtifactEntries)
      return CaptureDirectoryScanStatus::EntryLimit;
    if(!safeCaptureEntryName(name))
      return CaptureDirectoryScanStatus::UnsafeEntry;
    const std::filesystem::path relative = relativeDirectory/name;
    if(!safeRelativeCapturePath(relative,false))
      return CaptureDirectoryScanStatus::UnsafeEntry;

    struct stat entryStat = {};
    if(::fstatat(directoryDescriptor,name.c_str(),&entryStat,
                 AT_SYMLINK_NOFOLLOW)!=0)
      return CaptureDirectoryScanStatus::UnsafeEntry;
    if(S_ISLNK(entryStat.st_mode)) {
      if(relativeLinks==nullptr)
        return CaptureDirectoryScanStatus::Symlink;
      relativeLinks->push_back(relative);
      continue;
      }
    if(S_ISDIR(entryStat.st_mode)) {
      const int childRaw = ::openat(
          directoryDescriptor,name.c_str(),
          O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
      if(childRaw<0)
        return CaptureDirectoryScanStatus::UnsafeEntry;
      ScopedFileDescriptor child(childRaw);
      struct stat openedStat = {};
      if(::fstat(child.get(),&openedStat)!=0 ||
         !S_ISDIR(openedStat.st_mode) ||
         !sameNodeIdentity(entryStat,openedStat))
        return CaptureDirectoryScanStatus::UnsafeEntry;
      const CaptureDirectoryScanStatus nested = scanCaptureDirectory(
          child.get(),relative,relativeLinks,entries,regularFiles,totalBytes);
      if(nested!=CaptureDirectoryScanStatus::Success)
        return nested;
      continue;
      }
    if(!S_ISREG(entryStat.st_mode))
      return CaptureDirectoryScanStatus::SpecialNode;

    const int regularRaw = ::openat(
        directoryDescriptor,name.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(regularRaw<0)
      return CaptureDirectoryScanStatus::UnsafeEntry;
    ScopedFileDescriptor regular(regularRaw);
    struct stat openedStat = {};
    if(::fstat(regular.get(),&openedStat)!=0 ||
       !S_ISREG(openedStat.st_mode) ||
       !sameFileIdentity(entryStat,openedStat))
      return CaptureDirectoryScanStatus::UnsafeEntry;
    uint64_t size = 0u;
    if(!statSize(openedStat,size) || !addCaptureBytes(totalBytes,size))
      return CaptureDirectoryScanStatus::TooLarge;
    ++regularFiles;
    }
  }

bool prepareCaptureLinkPlan(int rootDescriptor,
                            const std::filesystem::path& relativeLink,
                            CaptureLinkPlan& plan) {
  if(!safeRelativeCapturePath(relativeLink,false))
    return false;
  ScopedFileDescriptor parent;
  if(!openRootedDirectory(
       rootDescriptor,relativeLink.parent_path(),parent))
    return false;
  const std::string linkName = relativeLink.filename().native();
  std::string rawTarget;
  if(!readRelativeLinkAt(parent.get(),linkName,rawTarget))
    return false;
  const std::filesystem::path targetPath(rawTarget);
  // Reject every ".." traversal, including paths that would normalize back
  // inside the package. A harmless leading "./" remains compatible with
  // platform-generated sibling aliases.
  if(!safeRelativeLinkTargetPath(targetPath))
    return false;
  const std::filesystem::path relativeTarget =
      (relativeLink.parent_path()/targetPath).lexically_normal();
  if(!safeRelativeCapturePath(relativeTarget,false) ||
     relativeTarget==relativeLink)
    return false;
  ScopedFileDescriptor target;
  struct stat targetStat = {};
  if(!openRootedRegular(
       rootDescriptor,relativeTarget,target,targetStat))
    return false;
  const std::string temporaryName = linkName+MaterializingSuffix;
  const std::string rollbackName = linkName+RollbackSuffix;
  if(!temporarySiblingAbsent(parent.get(),temporaryName) ||
     !temporarySiblingAbsent(parent.get(),rollbackName))
    return false;
  plan.relativeLink = relativeLink;
  plan.relativeTarget = relativeTarget;
  plan.rawTarget = std::move(rawTarget);
  plan.targetStat = targetStat;
  return true;
  }

bool writeAll(int descriptor,
              const uint8_t* data,
              std::size_t size) noexcept {
  std::size_t offset = 0u;
  while(offset<size) {
    const ssize_t written = ::write(descriptor,data+offset,size-offset);
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

bool copyRegularFile(int source,
                     int destination,
                     uint64_t expectedBytes) noexcept {
  std::array<uint8_t,64u*1024u> buffer = {};
  uint64_t copied = 0u;
  while(true) {
    const ssize_t count = ::read(source,buffer.data(),buffer.size());
    if(count<0) {
      if(errno==EINTR)
        continue;
      return false;
      }
    if(count==0)
      break;
    const uint64_t converted = static_cast<uint64_t>(count);
    if(copied>expectedBytes || converted>expectedBytes-copied ||
       !writeAll(destination,buffer.data(),
                 static_cast<std::size_t>(count)))
      return false;
    copied += converted;
    }
  return copied==expectedBytes && ::fsync(destination)==0;
  }

bool removeExpectedNodeAt(int parentDescriptor,
                          const std::string& name,
                          const struct stat& expected) noexcept {
  struct stat current = {};
  if(::fstatat(parentDescriptor,name.c_str(),&current,
               AT_SYMLINK_NOFOLLOW)!=0)
    return errno==ENOENT;
  return sameFileIdentity(current,expected) &&
         ::unlinkat(parentDescriptor,name.c_str(),0)==0;
  }

bool verifyOriginalCaptureLink(int rootDescriptor,
                               const CaptureLinkPlan& plan) {
  ScopedFileDescriptor parent;
  if(!openRootedDirectory(
       rootDescriptor,plan.relativeLink.parent_path(),parent))
    return false;
  const std::string linkName = plan.relativeLink.filename().native();
  std::string currentTarget;
  return readRelativeLinkAt(parent.get(),linkName,currentTarget) &&
         currentTarget==plan.rawTarget;
  }

bool verifyPreparedTemporaryAt(int parentDescriptor,
                               const std::string& temporaryName,
                               const CaptureLinkPlan& plan) noexcept {
  struct stat current = {};
  return plan.temporaryPrepared &&
         ::fstatat(parentDescriptor,temporaryName.c_str(),&current,
                   AT_SYMLINK_NOFOLLOW)==0 &&
         S_ISREG(current.st_mode) &&
         sameFileIdentity(current,plan.temporaryStat);
  }

bool prepareCaptureLinkTemporary(int rootDescriptor,
                                 CaptureLinkPlan& plan) {
  ScopedFileDescriptor parent;
  if(!openRootedDirectory(
       rootDescriptor,plan.relativeLink.parent_path(),parent))
    return false;
  const std::string linkName = plan.relativeLink.filename().native();
  std::string currentTarget;
  if(!readRelativeLinkAt(parent.get(),linkName,currentTarget) ||
     currentTarget!=plan.rawTarget)
    return false;

  ScopedFileDescriptor source;
  struct stat sourceStat = {};
  if(!openRootedRegular(
       rootDescriptor,plan.relativeTarget,source,sourceStat) ||
     !sameFileIdentity(sourceStat,plan.targetStat))
    return false;
  uint64_t sourceBytes = 0u;
  if(!statSize(sourceStat,sourceBytes))
    return false;

  const std::string temporaryName = linkName+MaterializingSuffix;
  const int temporaryRaw = ::openat(
      parent.get(),temporaryName.c_str(),
      O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if(temporaryRaw<0)
    return false;
  ScopedFileDescriptor temporary(temporaryRaw);
  struct stat temporaryIdentity = {};
  if(::fstat(temporary.get(),&temporaryIdentity)!=0) {
    temporary.reset();
    (void)::unlinkat(parent.get(),temporaryName.c_str(),0);
    return false;
    }
  plan.temporaryStat = temporaryIdentity;
  plan.temporaryPrepared = true;
  const auto removeTemporary = [&]() noexcept {
    struct stat current = {};
    if(temporary && ::fstat(temporary.get(),&current)==0)
      plan.temporaryStat = current;
    temporary.reset();
    const bool removed = removeExpectedNodeAt(
        parent.get(),temporaryName,plan.temporaryStat);
    if(removed)
      plan.temporaryPrepared = false;
    return removed;
    };
  if(!copyRegularFile(source.get(),temporary.get(),sourceBytes)) {
    (void)removeTemporary();
    return false;
    }
  struct stat copiedStat = {};
  struct stat finalSourceStat = {};
  if(::fstat(temporary.get(),&copiedStat)!=0 ||
     ::fstat(source.get(),&finalSourceStat)!=0 ||
     !S_ISREG(copiedStat.st_mode) ||
     !sameFileIdentity(finalSourceStat,plan.targetStat) ||
     copiedStat.st_size!=sourceStat.st_size) {
    (void)removeTemporary();
    return false;
    }
  plan.temporaryStat = copiedStat;
  temporary.reset();

  std::string finalTarget;
  if(!readRelativeLinkAt(parent.get(),linkName,finalTarget) ||
     finalTarget!=plan.rawTarget) {
    (void)removeTemporary();
    return false;
    }
  if(!verifyPreparedTemporaryAt(parent.get(),temporaryName,plan)) {
    (void)removeTemporary();
    return false;
    }
  return true;
  }

bool cleanupCaptureLinkTemporary(int rootDescriptor,
                                 CaptureLinkPlan& plan) {
  if(!plan.temporaryPrepared)
    return true;
  ScopedFileDescriptor parent;
  if(!openRootedDirectory(
       rootDescriptor,plan.relativeLink.parent_path(),parent))
    return false;
  const std::string temporaryName =
      plan.relativeLink.filename().native()+MaterializingSuffix;
  const bool removed = removeExpectedNodeAt(
      parent.get(),temporaryName,plan.temporaryStat);
  if(removed)
    plan.temporaryPrepared = false;
  return removed;
  }

bool cleanupCaptureLinkTemporaries(
    int rootDescriptor,
    std::vector<CaptureLinkPlan>& plans) {
  bool complete = true;
  for(auto& plan:plans) {
    if(!cleanupCaptureLinkTemporary(rootDescriptor,plan))
      complete = false;
    }
  return complete;
  }

bool cleanupCaptureLinkTemporariesNoThrow(
    int rootDescriptor,
    std::vector<CaptureLinkPlan>& plans) noexcept {
  try {
    return cleanupCaptureLinkTemporaries(rootDescriptor,plans);
    }
  catch(...) {
    return false;
    }
  }

#if defined(OPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS)
std::size_t CaptureCommitFailureIndexForTesting =
    std::numeric_limits<std::size_t>::max();
using CaptureBeforeRootCheckHookForTesting = void(*)(const char*) noexcept;
CaptureBeforeRootCheckHookForTesting CaptureBeforeRootCheckForTesting = nullptr;

bool failCaptureCommitForTesting(std::size_t index) noexcept {
  if(index!=CaptureCommitFailureIndexForTesting)
    return false;
  CaptureCommitFailureIndexForTesting =
      std::numeric_limits<std::size_t>::max();
  return true;
  }

void runCaptureBeforeRootCheckHookForTesting(const char* rootPath) noexcept {
  const CaptureBeforeRootCheckHookForTesting hook =
      CaptureBeforeRootCheckForTesting;
  CaptureBeforeRootCheckForTesting = nullptr;
  if(hook!=nullptr)
    hook(rootPath);
  }
#endif

bool commitPreparedCaptureLink(int rootDescriptor,
                               CaptureLinkPlan& plan,
                               bool& renamed) {
  renamed = false;
  ScopedFileDescriptor parent;
  if(!openRootedDirectory(
       rootDescriptor,plan.relativeLink.parent_path(),parent))
    return false;
  const std::string linkName = plan.relativeLink.filename().native();
  const std::string temporaryName = linkName+MaterializingSuffix;
  std::string currentTarget;
  if(!readRelativeLinkAt(parent.get(),linkName,currentTarget) ||
     currentTarget!=plan.rawTarget ||
     !verifyPreparedTemporaryAt(parent.get(),temporaryName,plan))
    return false;
  if(::renameat(parent.get(),temporaryName.c_str(),
                parent.get(),linkName.c_str())!=0)
    return false;
  renamed = true;
  plan.temporaryPrepared = false;
  struct stat materialized = {};
  return ::fstatat(parent.get(),linkName.c_str(),&materialized,
                   AT_SYMLINK_NOFOLLOW)==0 &&
         S_ISREG(materialized.st_mode) &&
         sameFileIdentity(materialized,plan.temporaryStat);
  }

bool rollbackCaptureLink(int rootDescriptor,
                         const CaptureLinkPlan& plan) {
  ScopedFileDescriptor parent;
  if(!openRootedDirectory(
       rootDescriptor,plan.relativeLink.parent_path(),parent))
    return false;
  const std::string linkName = plan.relativeLink.filename().native();
  const std::string rollbackName = linkName+RollbackSuffix;
  struct stat materialized = {};
  if(::fstatat(parent.get(),linkName.c_str(),&materialized,
               AT_SYMLINK_NOFOLLOW)!=0 ||
     !S_ISREG(materialized.st_mode) ||
     !sameFileIdentity(materialized,plan.temporaryStat) ||
     !temporarySiblingAbsent(parent.get(),rollbackName) ||
     ::symlinkat(plan.rawTarget.c_str(),parent.get(),
                 rollbackName.c_str())!=0)
    return false;
  const auto removeRollback = [&]() {
    std::string target;
    if(readRelativeLinkAt(parent.get(),rollbackName,target) &&
       target==plan.rawTarget)
      (void)::unlinkat(parent.get(),rollbackName.c_str(),0);
    };
  std::string rollbackTarget;
  if(!readRelativeLinkAt(parent.get(),rollbackName,rollbackTarget) ||
     rollbackTarget!=plan.rawTarget ||
     ::renameat(parent.get(),rollbackName.c_str(),
                parent.get(),linkName.c_str())!=0) {
    removeRollback();
    return false;
    }
  std::string restoredTarget;
  return readRelativeLinkAt(parent.get(),linkName,restoredTarget) &&
         restoredTarget==plan.rawTarget;
  }

bool rollbackCaptureLinks(int rootDescriptor,
                          std::vector<CaptureLinkPlan>& plans,
                          const std::vector<std::size_t>& committed) {
  bool complete = true;
  for(auto index=committed.rbegin();index!=committed.rend();++index) {
    if(!rollbackCaptureLink(rootDescriptor,plans[*index]))
      complete = false;
    }
  if(!cleanupCaptureLinkTemporaries(rootDescriptor,plans))
    complete = false;
  for(const auto& plan:plans) {
    if(!verifyOriginalCaptureLink(rootDescriptor,plan))
      complete = false;
    }
  return complete;
  }

bool rollbackCaptureLinksNoThrow(
    int rootDescriptor,
    std::vector<CaptureLinkPlan>& plans,
    const std::vector<std::size_t>& committed) noexcept {
  try {
    return rollbackCaptureLinks(rootDescriptor,plans,committed);
    }
  catch(...) {
    return false;
    }
  }

bool inspectNormalizedDirectory(int rootDescriptor,
                                uint64_t expectedBytes,
                                IOSMetalCaptureArtifact& artifact) {
  uint64_t entries = 0u;
  uint64_t regularFiles = 0u;
  uint64_t totalBytes = 0u;
  const CaptureDirectoryScanStatus status = scanCaptureDirectory(
      rootDescriptor,{},nullptr,entries,regularFiles,totalBytes);
  if(status!=CaptureDirectoryScanStatus::Success)
    return false;
  if(regularFiles==0u || totalBytes==0u || totalBytes!=expectedBytes)
    return false;
  artifact = {};
  artifact.kind = IOSMetalCaptureArtifactKind::Directory;
  artifact.bytes = totalBytes;
  return true;
  }
#endif

}

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)
bool iosMetalNormalizeAndInspectCaptureArtifact(
    const char* rootPath,
    IOSMetalCaptureArtifact& artifact,
    const char*& reason) noexcept {
  artifact = {};
  reason = "capture-artifact-root-invalid";
  if(rootPath==nullptr || rootPath[0]=='\0')
    return false;
  try {
    const std::filesystem::path requestedRoot(rootPath);
    const std::string rootName = requestedRoot.filename().native();
    std::filesystem::path rootParent = requestedRoot.parent_path();
    if(!safeCaptureEntryName(rootName))
      return false;
    if(rootParent.empty())
      rootParent = ".";
    ScopedFileDescriptor rootParentDescriptor(::open(
        rootParent.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));
    if(!rootParentDescriptor)
      return false;
    struct stat requestedStat = {};
    if(::fstatat(rootParentDescriptor.get(),rootName.c_str(),&requestedStat,
                 AT_SYMLINK_NOFOLLOW)!=0 || S_ISLNK(requestedStat.st_mode))
      return false;
    if(!S_ISREG(requestedStat.st_mode) && !S_ISDIR(requestedStat.st_mode))
      return false;
    int rootFlags = O_RDONLY|O_NOFOLLOW|O_CLOEXEC;
    if(S_ISDIR(requestedStat.st_mode))
      rootFlags |= O_DIRECTORY;
    else
      rootFlags |= O_NONBLOCK;
    ScopedFileDescriptor rootDescriptor(::openat(
        rootParentDescriptor.get(),rootName.c_str(),rootFlags));
    if(!rootDescriptor)
      return false;
    struct stat openedRootStat = {};
    if(::fstat(rootDescriptor.get(),&openedRootStat)!=0 ||
       !sameNodeIdentity(requestedStat,openedRootStat))
      return false;
    if(S_ISREG(openedRootStat.st_mode)) {
      uint64_t size = 0u;
      if(!statSize(openedRootStat,size) || size==0u) {
        reason = "capture-artifact-empty-or-too-large";
        return false;
        }
      artifact.kind = IOSMetalCaptureArtifactKind::File;
      artifact.bytes = size;
#if defined(OPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS)
      runCaptureBeforeRootCheckHookForTesting(rootPath);
#endif
      if(!rootDirectoryEntryIdentityMatches(
           rootParentDescriptor.get(),rootName,openedRootStat)) {
        artifact = {};
        reason = "capture-artifact-root-changed";
        return false;
        }
      reason = nullptr;
      return true;
      }
    if(!S_ISDIR(openedRootStat.st_mode))
      return false;

    std::vector<std::filesystem::path> relativeLinks;
    uint64_t entries = 0u;
    uint64_t regularFiles = 0u;
    uint64_t plannedBytes = 0u;
    const CaptureDirectoryScanStatus initialScan = scanCaptureDirectory(
        rootDescriptor.get(),{},&relativeLinks,entries,regularFiles,
        plannedBytes);
    switch(initialScan) {
      case CaptureDirectoryScanStatus::Success:
        break;
      case CaptureDirectoryScanStatus::EntryLimit:
        reason = "capture-package-entry-limit";
        return false;
      case CaptureDirectoryScanStatus::SpecialNode:
        reason = "capture-package-special-node";
        return false;
      case CaptureDirectoryScanStatus::TooLarge:
        reason = "capture-artifact-empty-or-too-large";
        return false;
      case CaptureDirectoryScanStatus::UnsafeEntry:
      case CaptureDirectoryScanStatus::Symlink:
        reason = "capture-package-unsafe-entry";
        return false;
      }

    std::vector<CaptureLinkPlan> linkPlans;
    std::sort(relativeLinks.begin(),relativeLinks.end());
    linkPlans.reserve(relativeLinks.size());
    for(const auto& relativeLink:relativeLinks) {
      CaptureLinkPlan plan;
      if(!prepareCaptureLinkPlan(
           rootDescriptor.get(),relativeLink,plan)) {
        reason = "capture-package-unsafe-symlink";
        return false;
        }
      uint64_t targetSize = 0u;
      if(!statSize(plan.targetStat,targetSize) ||
         !addCaptureBytes(plannedBytes,targetSize)) {
        reason = "capture-artifact-empty-or-too-large";
        return false;
        }
      linkPlans.push_back(std::move(plan));
      }
    if(plannedBytes==0u) {
      reason = "capture-artifact-empty-or-too-large";
      return false;
      }

    for(auto& plan:linkPlans) {
      bool prepared = false;
      try {
        prepared = prepareCaptureLinkTemporary(rootDescriptor.get(),plan);
        }
      catch(...) {
        reason = cleanupCaptureLinkTemporariesNoThrow(
                     rootDescriptor.get(),linkPlans) ?
                   "capture-artifact-normalization-exception" :
                   "capture-package-cleanup-failed";
        return false;
        }
      if(!prepared) {
        reason = cleanupCaptureLinkTemporariesNoThrow(
                     rootDescriptor.get(),linkPlans) ?
                   "capture-package-materialization-failed" :
                   "capture-package-cleanup-failed";
        return false;
        }
      }

#if defined(OPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS)
    runCaptureBeforeRootCheckHookForTesting(rootPath);
#endif

    std::vector<std::size_t> committed;
    committed.reserve(linkPlans.size());
    for(std::size_t index=0u;index<linkPlans.size();++index) {
      bool renamed = false;
      bool committedLink = false;
      bool commitException = false;
      try {
#if defined(OPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS)
        if(!failCaptureCommitForTesting(index))
#endif
          committedLink = commitPreparedCaptureLink(
              rootDescriptor.get(),linkPlans[index],renamed);
        }
      catch(...) {
        commitException = true;
        }
      if(renamed)
        committed.push_back(index);
      if(!committedLink) {
        const bool restored = rollbackCaptureLinksNoThrow(
            rootDescriptor.get(),linkPlans,committed);
        reason = restored ?
                   (commitException ?
                      "capture-artifact-normalization-exception" :
                      "capture-package-materialization-failed") :
                   "capture-package-rollback-failed";
        return false;
        }
      }
    bool normalized = false;
    bool inspectionException = false;
    try {
      normalized = inspectNormalizedDirectory(
          rootDescriptor.get(),plannedBytes,artifact);
      }
    catch(...) {
      inspectionException = true;
      }
    if(!normalized) {
      const bool restored = rollbackCaptureLinksNoThrow(
          rootDescriptor.get(),linkPlans,committed);
      reason = "capture-package-post-normalization-invalid";
      if(inspectionException)
        reason = "capture-artifact-normalization-exception";
      if(!restored)
        reason = "capture-package-rollback-failed";
      return false;
      }
    if(!rootDirectoryEntryIdentityMatches(
         rootParentDescriptor.get(),rootName,openedRootStat)) {
      artifact = {};
      reason = rollbackCaptureLinksNoThrow(
                   rootDescriptor.get(),linkPlans,committed) ?
                 "capture-artifact-root-changed" :
                 "capture-package-rollback-failed";
      return false;
      }
    reason = nullptr;
    return true;
    }
  catch(...) {
    reason = "capture-artifact-normalization-exception";
    return false;
    }
  }

#if defined(OPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS)
void iosMetalCaptureNormalizerFailCommitForTesting(
    std::size_t index) noexcept {
  CaptureCommitFailureIndexForTesting = index;
  }

void iosMetalCaptureNormalizerSetBeforeRootCheckHookForTesting(
    void (*hook)(const char*) noexcept) noexcept {
  CaptureBeforeRootCheckForTesting = hook;
  }
#endif
#endif

IOSFramePlan iosMetalResourceClearPassPlan() {
  IOSFramePlan plan;
  plan.resources = {
    presentResource(),
    transientResource(2u,false),
    transientResource(3u,true),
    };
  plan.passes = {
    {IOSPassId{1u},IOSPassKind::Render,
      {attachmentUse(2u,IOSStoreAction::Store)}},
    {IOSPassId{2u},IOSPassKind::Render,
      {attachmentUse(3u,IOSStoreAction::Discard)}},
    {IOSPassId{3u},IOSPassKind::Present,
      {{IOSResourceId{1u},IOSUseSemantic::PresentSource,
        IOSLoadAction::NotApplicable,IOSStoreAction::NotApplicable,
        IOSAttachmentWriteMode::NotApplicable}}},
    };
  return plan;
  }

IOSMetalResourceClearPassSelection iosMetalResourceSelectClearPassPlan(
    const IOSFramePlan& plan) noexcept {
  IOSMetalResourceClearPassSelection result;
  if(!plan.validate()) {
    result.status = IOSMetalResourceClearPassPlanStatus::Invalid;
    return result;
    }

  if(plan.resources.size()!=3u || plan.passes.size()!=3u)
    return result;
  const IOSResourceUse presentUse = {
    IOSResourceId{1u},IOSUseSemantic::PresentSource,
    IOSLoadAction::NotApplicable,IOSStoreAction::NotApplicable,
    IOSAttachmentWriteMode::NotApplicable,
    };
  if(!exactResource(plan.resources[0],presentResource()) ||
     !exactResource(plan.resources[1],transientResource(2u,false)) ||
     !exactResource(plan.resources[2],transientResource(3u,true)) ||
     !exactSingleUsePass(
       plan.passes[0],IOSPassId{1u},IOSPassKind::Render,
       attachmentUse(2u,IOSStoreAction::Store)) ||
     !exactSingleUsePass(
       plan.passes[1],IOSPassId{2u},IOSPassKind::Render,
       attachmentUse(3u,IOSStoreAction::Discard)) ||
     !exactSingleUsePass(
       plan.passes[2],IOSPassId{3u},IOSPassKind::Present,presentUse))
    return result;

  result.status = IOSMetalResourceClearPassPlanStatus::Supported;
  result.presentResource = 0u;
  result.privateResource = 1u;
  result.memorylessResource = 2u;
  result.privatePass = 0u;
  result.memorylessPass = 1u;
  result.presentPass = 2u;
  return result;
  }

const char* iosMetalResourceClearPassPlanStatusName(
    IOSMetalResourceClearPassPlanStatus status) noexcept {
  switch(status) {
    case IOSMetalResourceClearPassPlanStatus::Supported:
      return "supported";
    case IOSMetalResourceClearPassPlanStatus::Invalid:
      return "invalid";
    case IOSMetalResourceClearPassPlanStatus::Unsupported:
      return "unsupported";
    }
  return "unsupported";
  }

bool iosMetalResourceClearPassNativeReportMatches(
    const IOSMetalResourceClearPassNativeReport& report) noexcept {
  return report.encoded && report.physicalPasses==2u &&
         report.commandBuffers==1u && report.renderEncoders==2u &&
         report.submits==0u && report.draws==0u && report.pipelines==0u &&
         report.drawable==0u && report.present==0u &&
         report.privateLoad==IOSLoadAction::Clear &&
         report.privateStore==IOSStoreAction::Store &&
         report.memorylessLoad==IOSLoadAction::Clear &&
         report.memorylessStore==IOSStoreAction::Discard;
  }
