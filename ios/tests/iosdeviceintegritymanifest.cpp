#include "graphics/iosdeviceintegritymanifest.h"

#if !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "device integrity manifest tests require diagnostics"
#endif
#if !defined(OPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST)
#error "device integrity manifest race tests require host-test hook"
#endif

#include <CommonCrypto/CommonDigest.h>

#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
namespace Integrity = RendererIOSDeviceIntegrity;

namespace {

class Fixture final {
  public:
    Fixture() {
      std::array<char,128> pattern{};
      const std::string value =
          (fs::temp_directory_path()/
           "rendererios-device-integrity.XXXXXX").string();
      assert(value.size()+1u<=pattern.size());
      std::copy(value.begin(),value.end(),pattern.begin());
      const char* created = ::mkdtemp(pattern.data());
      assert(created!=nullptr);
      root = created;
      }

    ~Fixture() {
      std::error_code error;
      fs::remove_all(root,error);
      }

    Fixture(const Fixture&) = delete;
    Fixture& operator=(const Fixture&) = delete;

    fs::path root;
  };

void writeBytes(const fs::path& path, std::string_view bytes) {
  std::ofstream output(path,std::ios::binary|std::ios::trunc);
  assert(output);
  output.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));
  output.close();
  assert(output);
  }

std::string readBytes(const fs::path& path) {
  std::ifstream input(path,std::ios::binary);
  assert(input);
  return std::string(
      std::istreambuf_iterator<char>(input),
      std::istreambuf_iterator<char>());
  }

std::string sha256Bytes(std::string_view bytes) {
  CC_SHA256_CTX context{};
  assert(CC_SHA256_Init(&context)==1);
  assert(CC_SHA256_Update(
      &context,bytes.data(),static_cast<CC_LONG>(bytes.size()))==1);
  std::array<unsigned char,CC_SHA256_DIGEST_LENGTH> digest{};
  assert(CC_SHA256_Final(digest.data(),&context)==1);
  static constexpr char hex[] = "0123456789abcdef";
  std::string encoded(64u,'\0');
  for(std::size_t index=0u; index<digest.size(); ++index) {
    encoded[index*2u] = hex[(digest[index]>>4u)&0x0fu];
    encoded[index*2u+1u] = hex[digest[index]&0x0fu];
    }
  return encoded;
  }

void createBaseFixture(const fs::path& root) {
  fs::create_directories(root/"Data");
  fs::create_directories(root/"_work"/"Data");
  fs::create_directories(root/"system");
  writeBytes(root/"Data"/"a.txt","alpha");
  writeBytes(root/"_work"/"Data"/"b.bin",std::string("\0\xff",2u));
  writeBytes(root/"system"/std::string("cafe\xcc\x81.txt"),"accent");
  writeBytes(root/"system"/std::string("control\nfile"),"control");
  writeBytes(root/"system"/"Gothic.ini","mutable-and-excluded");
  for(unsigned slot=1u; slot<=4u; ++slot)
    writeBytes(
        root/("save_slot_"+std::to_string(slot)+".sav"),
        "save-"+std::to_string(slot));
  }

void requireMode0600(const fs::path& path) {
  struct stat identity{};
  assert(::lstat(path.c_str(),&identity)==0);
  assert(S_ISREG(identity.st_mode));
  assert((identity.st_mode&0777)==0600);
  }

void requireNoCandidateIdentity(const Integrity::Result& result) {
  assert(result.candidateOrdinal==0u);
  for(const char value:result.candidatePathSha256)
    assert(value=='\0');
  assert(!result.hasHashingCandidateIdentity());
  }

void requireNoFailureStage(const Integrity::Result& result) {
  assert(result.failureStage==Integrity::FailureStage::None);
  requireNoCandidateIdentity(result);
  }

void testArguments() {
  constexpr const char* none[] = {"Gothic2Notr"};
  constexpr const char* valid[] = {
    "Gothic2Notr","-renderer-ios-device-integrity-manifest-v1",
    };
  constexpr const char* duplicate[] = {
    "Gothic2Notr","-renderer-ios-device-integrity-manifest-v1",
    "-renderer-ios-device-integrity-manifest-v1",
    };
  constexpr const char* cleanup[] = {
    "Gothic2Notr","-renderer-ios-device-integrity-cleanup-v1",
    };
  constexpr const char* mixed[] = {
    "Gothic2Notr","-renderer-ios-device-integrity-manifest-v1",
    "-renderer-ios-device-integrity-cleanup-v1",
    };
  constexpr const char* unknown[] = {
    "Gothic2Notr","-renderer-ios-device-integrity-manifest-v2",
    };
  static_assert(Integrity::parseArguments(1,none).valid());
  static_assert(!Integrity::parseArguments(1,none).requested);
  static_assert(Integrity::parseArguments(2,valid).valid());
  static_assert(Integrity::parseArguments(2,valid).requested);
  static_assert(!Integrity::parseArguments(3,duplicate).valid());
  static_assert(Integrity::parseArguments(3,duplicate).duplicate);
  static_assert(Integrity::parseArguments(2,cleanup).valid());
  static_assert(Integrity::parseArguments(2,cleanup).cleanupRequested);
  static_assert(!Integrity::parseArguments(3,mixed).valid());
  static_assert(Integrity::parseArguments(3,mixed).duplicate);
  static_assert(!Integrity::parseArguments(2,unknown).valid());
  static_assert(Integrity::parseArguments(2,unknown).unknown);
  static_assert(!Integrity::parseArguments(-1,nullptr).valid());
  static_assert(!Integrity::parseArguments(1,nullptr).valid());
  constexpr const char* const invalidVector[] = {nullptr};
  static_assert(!Integrity::parseArguments(1,invalidVector).valid());
  }

void testFailureStageNames() {
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::None))=="none");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::InitialResourceCollection))==
      "initial-resource-collection");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::InitialSaveCollection))==
      "initial-save-collection");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::ResourceHashing))=="resource-hashing");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::SaveHashing))=="save-hashing");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::RevalidationHook))=="revalidation-hook");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::PostHashResourceRecollection))==
      "post-hash-resource-recollection");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::PostHashSaveRecollection))==
      "post-hash-save-recollection");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::ResourceSnapshotComparison))==
      "resource-snapshot-comparison");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::SaveSnapshotComparison))==
      "save-snapshot-comparison");
  assert(std::string_view(Integrity::failureStageName(
      Integrity::FailureStage::DocumentRootComparison))==
      "document-root-comparison");
  }

void testCandidateIdentityAdmissionAndFormatting() {
  constexpr std::string_view pathSha =
      "7c5f5ae02b576c00748471a0a9c5cce6bc3320359b6cf378b417df39fa54a467";
  Integrity::Result valid;
  valid.error = Integrity::Error::FileChanged;
  valid.failureStage = Integrity::FailureStage::ResourceHashing;
  valid.resourceFileCount = 4u;
  valid.candidateOrdinal = 1u;
  std::copy(pathSha.begin(),pathSha.end(),
            valid.candidatePathSha256.begin());
  assert(valid.hasHashingCandidateIdentity());
  assert(Integrity::formatFailureMessage(valid)==
      "RendererIOS device integrity manifest failed: file-changed "
      "stage=resource-hashing candidate-ordinal=1 "
      "candidate-path-sha256="+std::string(pathSha));
  Integrity::Result validSave = valid;
  validSave.failureStage = Integrity::FailureStage::SaveHashing;
  validSave.resourceFileCount = 0u;
  validSave.protectedSaveFileCount = 1u;
  assert(validSave.hasHashingCandidateIdentity());
  assert(Integrity::formatFailureMessage(validSave)==
      "RendererIOS device integrity manifest failed: file-changed "
      "stage=save-hashing candidate-ordinal=1 "
      "candidate-path-sha256="+std::string(pathSha));

  const auto requireFormatterRedacted = [](const Integrity::Result& rejected) {
    assert(!rejected.hasHashingCandidateIdentity());
    const std::string formatted = Integrity::formatFailureMessage(rejected);
    assert(formatted.find("candidate-ordinal=")==std::string::npos);
    assert(formatted.find("candidate-path-sha256=")==std::string::npos);
    };

  constexpr std::array<Integrity::FailureStage,9> nonHashingStages = {{
    Integrity::FailureStage::None,
    Integrity::FailureStage::InitialResourceCollection,
    Integrity::FailureStage::InitialSaveCollection,
    Integrity::FailureStage::RevalidationHook,
    Integrity::FailureStage::PostHashResourceRecollection,
    Integrity::FailureStage::PostHashSaveRecollection,
    Integrity::FailureStage::ResourceSnapshotComparison,
    Integrity::FailureStage::SaveSnapshotComparison,
    Integrity::FailureStage::DocumentRootComparison,
    }};
  for(const auto stage:nonHashingStages) {
    Integrity::Result rejected = valid;
    rejected.failureStage = stage;
    requireFormatterRedacted(rejected);
    }
  {
    Integrity::Result rejected = valid;
    rejected.failureStage = static_cast<Integrity::FailureStage>(0xffu);
    requireFormatterRedacted(rejected);
  }
  {
    Integrity::Result rejected = valid;
    rejected.error = Integrity::Error::ReadFailed;
    requireFormatterRedacted(rejected);
    assert(Integrity::formatFailureMessage(rejected)==
        "RendererIOS device integrity manifest failed: read-failed");
  }
  constexpr std::array<uint64_t,3> invalidOrdinals = {{
    0u,5u,Integrity::MaximumFileCount+1u,
    }};
  for(const uint64_t ordinal:invalidOrdinals) {
    Integrity::Result rejected = valid;
    rejected.candidateOrdinal = ordinal;
    requireFormatterRedacted(rejected);
  }
  {
    Integrity::Result rejected = valid;
    rejected.candidatePathSha256[0] = 'A';
    requireFormatterRedacted(rejected);
  }
  {
    Integrity::Result rejected = valid;
    rejected.candidatePathSha256[64] = 'x';
    requireFormatterRedacted(rejected);
  }
  {
    Integrity::Result rejected = valid;
    rejected.candidatePathSha256 = {};
    requireFormatterRedacted(rejected);
  }
  {
    Integrity::Result rejected = validSave;
    rejected.protectedSaveFileCount = 0u;
    requireFormatterRedacted(rejected);
  }
  }

void testCleanup() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  writeBytes(fixture.root/"unrelated.txt","keep");
  const auto created = Integrity::createCanonicalManifests(fixture.root);
  assert(created.success());
  requireNoFailureStage(created);
  const auto removed = Integrity::removeCanonicalManifests(fixture.root);
  assert(removed.success());
  requireNoFailureStage(removed);
  assert(!fs::exists(fixture.root/Integrity::ResourceManifestFileName));
  assert(!fs::exists(fixture.root/Integrity::ProtectedSaveManifestFileName));
  assert(readBytes(fixture.root/"unrelated.txt")=="keep");
  const auto removedAgain = Integrity::removeCanonicalManifests(fixture.root);
  assert(removedAgain.success());
  requireNoFailureStage(removedAgain);

  writeBytes(fixture.root/Integrity::ResourceManifestFileName,"owned");
  assert(::symlink("unrelated.txt",
      (fixture.root/Integrity::ProtectedSaveManifestFileName).c_str())==0);
  const auto collision = Integrity::removeCanonicalManifests(fixture.root);
  assert(collision.error==Integrity::Error::NonRegularEntry);
  requireNoFailureStage(collision);
  assert(readBytes(fixture.root/Integrity::ResourceManifestFileName)=="owned");
  assert(fs::is_symlink(fixture.root/Integrity::ProtectedSaveManifestFileName));
  }

void testCanonicalFixture() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  const Integrity::Result result =
      Integrity::createCanonicalManifests(fixture.root);
  assert(result.success());
  requireNoFailureStage(result);
  assert(result.resourceFileCount==4u);
  assert(result.resourceTotalBytes==20u);
  assert(result.protectedSaveFileCount==4u);
  assert(result.protectedSaveTotalBytes==24u);

  const std::string expectedResources =
      "{\"schemaVersion\":1,\"roots\":[\"Data\",\"_work/Data\","
      "\"system\"],\"excluded\":[\"system/Gothic.ini\"],"
      "\"fileCount\":4,\"totalBytes\":20}\n"
      "{\"relativePath\":\"Data/a.txt\",\"byteSize\":5,"
      "\"sha256\":\"8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8\"}\n"
      "{\"relativePath\":\"_work/Data/b.bin\",\"byteSize\":2,"
      "\"sha256\":\"06eb7d6a69ee19e5fbdf749018d3d2abfa04bcbd1365db312eb86dc7169389b8\"}\n"
      "{\"relativePath\":\"system/caf\xc3\xa9.txt\",\"byteSize\":6,"
      "\"sha256\":\"a3a7f053ae2eadb1fb93bcbd4a39b00985b64ede4f337d64025982f9efb97f54\"}\n"
      "{\"relativePath\":\"system/control\\nfile\",\"byteSize\":7,"
      "\"sha256\":\"0fcd568a5cb9bdb4677b69354b11ee415af8f784519cff3da49a26f84eaee7f2\"}\n";
  const std::string expectedSaves =
      "{\"schemaVersion\":1,\"protectedSlots\":[1,2,3,4],"
      "\"fileCount\":4,\"totalBytes\":24}\n"
      "{\"slot\":1,\"fileName\":\"save_slot_1.sav\",\"byteSize\":6,"
      "\"sha256\":\"c767736efe5cb2bca8016f47a878b9f6ecbf4c05f87809ce6076593e16cf1f98\"}\n"
      "{\"slot\":2,\"fileName\":\"save_slot_2.sav\",\"byteSize\":6,"
      "\"sha256\":\"c3593089e8881a50c19fbd648071a0b738705621d2023773dde5bc24d8f8b7a1\"}\n"
      "{\"slot\":3,\"fileName\":\"save_slot_3.sav\",\"byteSize\":6,"
      "\"sha256\":\"a23d58ff477e8f0760d589f28cd84d4c367baa6542aa04aed7b71cfaa6bcc9f5\"}\n"
      "{\"slot\":4,\"fileName\":\"save_slot_4.sav\",\"byteSize\":6,"
      "\"sha256\":\"ce60b7e336b14de107ac72f2118d4d0d53053f4cf098e3d76614ab4cbc241f9b\"}\n";
  const fs::path resource = fixture.root/Integrity::ResourceManifestFileName;
  const fs::path saves = fixture.root/Integrity::ProtectedSaveManifestFileName;
  assert(readBytes(resource)==expectedResources);
  assert(readBytes(saves)==expectedSaves);
  assert(std::string(result.resourceManifestSha256.data())==
      "375fbe9b88b68112b9f065543b6fa1a3527197ce9d83e13a1473ffe5df9f2f67");
  assert(std::string(result.protectedSaveManifestSha256.data())==
      "139ce1c01a395151999f885c8d7f333097e0191817949efee5456cbfd415a124");
  requireMode0600(resource);
  requireMode0600(saves);

  const std::string resourceBefore = readBytes(resource);
  const std::string savesBefore = readBytes(saves);
  const Integrity::Result collision =
      Integrity::createCanonicalManifests(fixture.root);
  assert(collision.error==Integrity::Error::Collision);
  requireNoFailureStage(collision);
  assert(readBytes(resource)==resourceBefore);
  assert(readBytes(saves)==savesBefore);
  }

void testMissingExcludedFile() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  assert(fs::remove(fixture.root/"system"/"Gothic.ini"));
  const auto result = Integrity::createCanonicalManifests(fixture.root);
  assert(result.error==Integrity::Error::MissingExcludedFile);
  requireNoFailureStage(result);
  }

void testMissingSave() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  assert(fs::remove(fixture.root/"save_slot_4.sav"));
  const auto result = Integrity::createCanonicalManifests(fixture.root);
  assert(result.error==Integrity::Error::MissingProtectedSave);
  requireNoFailureStage(result);
  }

void testSingleLeafCollisionPublishesNothing() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  const fs::path saveManifest =
      fixture.root/Integrity::ProtectedSaveManifestFileName;
  writeBytes(saveManifest,"sentinel");
  const auto result = Integrity::createCanonicalManifests(fixture.root);
  assert(result.error==Integrity::Error::Collision);
  requireNoFailureStage(result);
  assert(!fs::exists(fixture.root/Integrity::ResourceManifestFileName));
  assert(readBytes(saveManifest)=="sentinel");
  }

void testSymlinksFailClosed() {
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    assert(::symlink("a.txt",(fixture.root/"Data"/"link").c_str())==0);
    const auto result = Integrity::createCanonicalManifests(fixture.root);
    assert(result.error==Integrity::Error::NonRegularEntry);
    requireNoFailureStage(result);
  }
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    assert(fs::remove(fixture.root/"save_slot_2.sav"));
    assert(::symlink("save_slot_1.sav",
                     (fixture.root/"save_slot_2.sav").c_str())==0);
    const auto result = Integrity::createCanonicalManifests(fixture.root);
    assert(result.error==Integrity::Error::NonRegularEntry);
    requireNoFailureStage(result);
  }
  }

void testMissingRoot() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  assert(fs::remove(fixture.root/"_work"/"Data"/"b.bin"));
  assert(fs::remove(fixture.root/"_work"/"Data"));
  const auto result = Integrity::createCanonicalManifests(fixture.root);
  assert(result.error==Integrity::Error::MissingRoot);
  requireNoFailureStage(result);
  }

void testSparseLimitsBeforeHashing() {
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    const fs::path huge = fixture.root/"Data"/"huge.bin";
    const int descriptor = ::open(huge.c_str(),O_WRONLY|O_CREAT|O_EXCL,0600);
    assert(descriptor>=0);
    assert(::ftruncate(
        descriptor,static_cast<off_t>(Integrity::MaximumFileBytes+1u))==0);
    assert(::close(descriptor)==0);
    const auto result = Integrity::createCanonicalManifests(fixture.root);
    assert(result.error==Integrity::Error::FileSizeLimit);
    requireNoFailureStage(result);
  }
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    for(unsigned index=0u; index<3u; ++index) {
      const fs::path huge = fixture.root/"Data"/
          ("total-"+std::to_string(index)+".bin");
      const int descriptor = ::open(
          huge.c_str(),O_WRONLY|O_CREAT|O_EXCL,0600);
      assert(descriptor>=0);
      assert(::ftruncate(descriptor,6ll*1024ll*1024ll*1024ll)==0);
      assert(::close(descriptor)==0);
      }
    const auto result = Integrity::createCanonicalManifests(fixture.root);
    assert(result.error==Integrity::Error::TotalSizeLimit);
    requireNoFailureStage(result);
  }
  }

bool HookMutationSucceeded = false;

enum class CandidateMutation : uint8_t {
  Grow,
  RewriteSameSize,
  ReplaceInode,
  ChangeMode,
  RenameAway,
  GrowSave,
  };

struct CandidateMutationState final {
  CandidateMutation mutation = CandidateMutation::Grow;
  Integrity::FailureStage stage = Integrity::FailureStage::None;
  uint64_t ordinal = 0u;
  std::string_view normalizedRelativePath;
  std::string_view rawRelativePath;
  uint64_t callbackCount = 0u;
  uint64_t mutationCount = 0u;
  bool invoked = false;
  bool succeeded = false;
  };

CandidateMutationState CandidateState;
bool CandidateStableStatChanged = false;

bool appendByte(const fs::path& path) noexcept {
  const int descriptor = ::open(
      path.c_str(),O_WRONLY|O_APPEND|O_NOFOLLOW);
  if(descriptor<0)
    return false;
  const char byte = 'x';
  const bool changed = ::write(descriptor,&byte,1u)==1 &&
      ::fsync(descriptor)==0;
  return ::close(descriptor)==0 && changed;
  }

bool rewriteSameSize(const fs::path& path) noexcept {
  const int descriptor = ::open(path.c_str(),O_WRONLY|O_NOFOLLOW);
  if(descriptor<0)
    return false;
  struct stat before{};
  const char replacement[] = "omega";
  const bool wrote = ::fstat(descriptor,&before)==0 &&
      before.st_size==5 && ::pwrite(descriptor,replacement,5u,0)==5 &&
      ::fsync(descriptor)==0;
  timespec changed[2] = {
    {0,UTIME_OMIT},
    {before.st_mtimespec.tv_sec+1,before.st_mtimespec.tv_nsec},
    };
  const bool timestamped = wrote && ::futimens(descriptor,changed)==0;
  struct stat after{};
  const bool restated = timestamped && ::fstat(descriptor,&after)==0;
  CandidateStableStatChanged = restated &&
      before.st_dev==after.st_dev && before.st_ino==after.st_ino &&
      before.st_mode==after.st_mode && before.st_size==after.st_size &&
      (before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec ||
       before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec ||
       before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec ||
       before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec);
  return ::close(descriptor)==0 && CandidateStableStatChanged;
  }

bool replaceInode(const fs::path& path) noexcept {
  try {
    fs::path replacement = path;
    replacement += ".replacement";
    const int descriptor = ::open(
        replacement.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(descriptor<0)
      return false;
    const char bytes[] = "zz";
    const bool wrote = ::write(descriptor,bytes,2u)==2 &&
        ::fsync(descriptor)==0;
    const bool closed = ::close(descriptor)==0;
    return wrote && closed && ::rename(replacement.c_str(),path.c_str())==0;
    }
  catch(...) {
    return false;
    }
  }

bool changeMode(const fs::path& path) noexcept {
  struct stat identity{};
  return ::lstat(path.c_str(),&identity)==0 &&
      ::chmod(path.c_str(),identity.st_mode^S_IXUSR)==0;
  }

bool renameAway(const fs::path& path) noexcept {
  try {
    fs::path moved = path;
    moved += ".moved";
    return ::rename(path.c_str(),moved.c_str())==0;
    }
  catch(...) {
    return false;
    }
  }

Integrity::CandidateHashTestHookResult mutateCandidateBeforeHash(
    const fs::path& root,
    std::string_view normalizedRelativePath,
    uint64_t candidateOrdinal,
    Integrity::FailureStage stage) noexcept {
  ++CandidateState.callbackCount;
  if(stage!=CandidateState.stage || candidateOrdinal!=CandidateState.ordinal ||
     normalizedRelativePath!=CandidateState.normalizedRelativePath)
    return Integrity::CandidateHashTestHookResult::NotSelected;
  if(CandidateState.invoked)
    return Integrity::CandidateHashTestHookResult::Failed;
  CandidateState.invoked = true;
  ++CandidateState.mutationCount;
  try {
    const fs::path target = root/std::string(CandidateState.rawRelativePath);
    switch(CandidateState.mutation) {
      case CandidateMutation::Grow:
      case CandidateMutation::GrowSave:
        CandidateState.succeeded = appendByte(target);
        break;
      case CandidateMutation::RewriteSameSize:
        CandidateState.succeeded = rewriteSameSize(target);
        break;
      case CandidateMutation::ReplaceInode:
        CandidateState.succeeded = replaceInode(target);
        break;
      case CandidateMutation::ChangeMode:
        CandidateState.succeeded = changeMode(target);
        break;
      case CandidateMutation::RenameAway:
        CandidateState.succeeded = renameAway(target);
        break;
      }
    }
  catch(...) {
    CandidateState.succeeded = false;
    }
  return CandidateState.succeeded
      ? Integrity::CandidateHashTestHookResult::Mutated
      : Integrity::CandidateHashTestHookResult::Failed;
  }

bool replaceAlreadyHashedFileWithSameSize(
    const fs::path& root) noexcept {
  try {
    const fs::path target = root/"Data"/"a.txt";
    const int descriptor = ::open(
        target.c_str(),O_WRONLY|O_TRUNC|O_NOFOLLOW);
    if(descriptor<0)
      return false;
    struct stat before{};
    const char replacement[] = "omega";
    const bool wrote = ::fstat(descriptor,&before)==0 &&
        ::write(descriptor,replacement,5u)==5 &&
        ::fsync(descriptor)==0;
    timespec changed[2] = {
      {0,UTIME_OMIT},
      {before.st_mtimespec.tv_sec+1,before.st_mtimespec.tv_nsec},
      };
    const bool timestamped = wrote && ::futimens(descriptor,changed)==0;
    const bool closed = ::close(descriptor)==0;
    HookMutationSucceeded = timestamped && closed;
    return HookMutationSucceeded;
    }
  catch(...) {
    return false;
    }
  }

bool addLateResourceFile(const fs::path& root) noexcept {
  try {
    const fs::path target = root/"system"/"late.cfg";
    const int descriptor = ::open(
        target.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(descriptor<0)
      return false;
    const char contents[] = "late";
    const bool wrote = ::write(descriptor,contents,4u)==4 &&
        ::fsync(descriptor)==0;
    const bool closed = ::close(descriptor)==0;
    HookMutationSucceeded = wrote && closed;
    return HookMutationSucceeded;
    }
  catch(...) {
    return false;
    }
  }

bool replaceAlreadyHashedSaveWithSameSize(
    const fs::path& root) noexcept {
  try {
    const fs::path target = root/"save_slot_1.sav";
    const int descriptor = ::open(
        target.c_str(),O_WRONLY|O_TRUNC|O_NOFOLLOW);
    if(descriptor<0)
      return false;
    struct stat before{};
    const char replacement[] = "omega!";
    const bool wrote = ::fstat(descriptor,&before)==0 &&
        ::write(descriptor,replacement,6u)==6 &&
        ::fsync(descriptor)==0;
    timespec changed[2] = {
      {0,UTIME_OMIT},
      {before.st_mtimespec.tv_sec+1,before.st_mtimespec.tv_nsec},
      };
    const bool timestamped = wrote && ::futimens(descriptor,changed)==0;
    const bool closed = ::close(descriptor)==0;
    HookMutationSucceeded = timestamped && closed;
    return HookMutationSucceeded;
    }
  catch(...) {
    return false;
    }
  }

bool rejectRevalidation(const fs::path&) noexcept {
  HookMutationSucceeded = true;
  return false;
  }

void requireNoPublishedManifests(const fs::path& root) {
  assert(!fs::exists(root/Integrity::ResourceManifestFileName));
  assert(!fs::exists(root/Integrity::ProtectedSaveManifestFileName));
  }

struct CandidateMutationCase final {
  CandidateMutation mutation;
  Integrity::FailureStage stage;
  uint64_t ordinal;
  uint64_t expectedCallbackCount;
  std::string_view normalizedRelativePath;
  std::string_view rawRelativePath;
  std::string_view expectedPathSha256;
  };

void testHashingCandidateIdentity() {
  constexpr std::array<CandidateMutationCase,6> cases = {{
    {CandidateMutation::Grow,Integrity::FailureStage::ResourceHashing,1u,1u,
     "Data/a.txt","Data/a.txt",
     "7c5f5ae02b576c00748471a0a9c5cce6bc3320359b6cf378b417df39fa54a467"},
    {CandidateMutation::RewriteSameSize,
     Integrity::FailureStage::ResourceHashing,1u,
     1u,
     "Data/a.txt","Data/a.txt",
     "7c5f5ae02b576c00748471a0a9c5cce6bc3320359b6cf378b417df39fa54a467"},
    {CandidateMutation::ReplaceInode,
     Integrity::FailureStage::ResourceHashing,2u,
     2u,
     "_work/Data/b.bin","_work/Data/b.bin",
     "7014ac0ea8098c5edaf91377bf2774b0c17f24d101b2cf88eaec86f13c3701ee"},
    {CandidateMutation::ChangeMode,
     Integrity::FailureStage::ResourceHashing,3u,
     3u,
     "system/caf\xc3\xa9.txt","system/cafe\xcc\x81.txt",
     "64d6b05d679a8dd7b9ce3a7766b8b7bee81417f61920991ef6b1abfc06fb8e2b"},
    {CandidateMutation::RenameAway,
     Integrity::FailureStage::ResourceHashing,4u,
     4u,
     "system/control\nfile","system/control\nfile",
     "49cba090601d71264d7090facfe674bb4eed86da53497a2797b77248efbbf848"},
    {CandidateMutation::GrowSave,Integrity::FailureStage::SaveHashing,3u,7u,
     "save_slot_3.sav","save_slot_3.sav",
     "cc130e9b1d1628aca7598b2a6ea865230a51c2f0489d2d5ae50dbcac81aba99b"},
    }};
  for(const CandidateMutationCase& testCase:cases) {
    Fixture fixture;
    createBaseFixture(fixture.root);
    CandidateState = {
      testCase.mutation,testCase.stage,testCase.ordinal,
      testCase.normalizedRelativePath,testCase.rawRelativePath,0u,0u,
      false,false,
      };
    CandidateStableStatChanged = false;
    const Integrity::Result result =
        Integrity::createCanonicalManifestsForTest(
            fixture.root,nullptr,mutateCandidateBeforeHash);
    assert(CandidateState.invoked);
    assert(CandidateState.succeeded);
    assert(CandidateState.callbackCount==testCase.expectedCallbackCount);
    assert(CandidateState.mutationCount==1u);
    if(testCase.mutation==CandidateMutation::RewriteSameSize)
      assert(CandidateStableStatChanged);
    if(testCase.mutation==CandidateMutation::ChangeMode)
      assert(sha256Bytes(testCase.rawRelativePath)==
          "1e4dc3dabdc13664f4d965f9e1060e3a201a26b9c0317453787381dda1cc25c4");
    assert(result.error==Integrity::Error::FileChanged);
    assert(result.failureStage==testCase.stage);
    assert(result.candidateOrdinal==testCase.ordinal);
    assert(std::string_view(result.candidatePathSha256.data())==
        testCase.expectedPathSha256);
    if(testCase.mutation==CandidateMutation::ChangeMode)
      assert(sha256Bytes(testCase.rawRelativePath)!=
          std::string(result.candidatePathSha256.data()));
    assert(result.hasHashingCandidateIdentity());
    const std::string message = Integrity::formatFailureMessage(result);
    assert(message==
        "RendererIOS device integrity manifest failed: file-changed stage="+
        std::string(Integrity::failureStageName(testCase.stage))+
        " candidate-ordinal="+std::to_string(testCase.ordinal)+
        " candidate-path-sha256="+std::string(testCase.expectedPathSha256));
    assert(message.find(testCase.rawRelativePath)==std::string::npos);
    assert(message.find(testCase.normalizedRelativePath)==std::string::npos);
    assert(message.find(fixture.root.string())==std::string::npos);
    assert(message.find('\n')==std::string::npos);
    requireNoPublishedManifests(fixture.root);
    }
  }

std::array<unsigned,2> OneShotHookCalls{};

Integrity::CandidateHashTestHookResult selectFirstCandidateOnce(
    const fs::path&,
    std::string_view,
    uint64_t candidateOrdinal,
    Integrity::FailureStage stage) noexcept {
  assert(candidateOrdinal==1u);
  if(stage==Integrity::FailureStage::ResourceHashing)
    ++OneShotHookCalls[0];
  else if(stage==Integrity::FailureStage::SaveHashing)
    ++OneShotHookCalls[1];
  else
    return Integrity::CandidateHashTestHookResult::Failed;
  return Integrity::CandidateHashTestHookResult::Mutated;
  }

unsigned FailedHookCalls = 0u;

Integrity::CandidateHashTestHookResult failSecondResourceCandidate(
    const fs::path&,
    std::string_view,
    uint64_t candidateOrdinal,
    Integrity::FailureStage stage) noexcept {
  if(stage!=Integrity::FailureStage::ResourceHashing)
    return Integrity::CandidateHashTestHookResult::Failed;
  ++FailedHookCalls;
  return candidateOrdinal==2u
      ? Integrity::CandidateHashTestHookResult::Failed
      : Integrity::CandidateHashTestHookResult::NotSelected;
  }

void testCandidateHookDomain() {
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    OneShotHookCalls = {};
    const auto result = Integrity::createCanonicalManifestsForTest(
        fixture.root,nullptr,selectFirstCandidateOnce);
    assert(result.success());
    assert(OneShotHookCalls[0]==1u);
    assert(OneShotHookCalls[1]==1u);
    assert(!result.hasHashingCandidateIdentity());
  }
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    FailedHookCalls = 0u;
    const auto result = Integrity::createCanonicalManifestsForTest(
        fixture.root,nullptr,failSecondResourceCandidate);
    assert(FailedHookCalls==2u);
    assert(result.error==Integrity::Error::OpenFailed);
    requireNoFailureStage(result);
    requireNoPublishedManifests(fixture.root);
  }
  }

void testPostHashExactTreeRevalidation() {
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    HookMutationSucceeded = false;
    const auto result = Integrity::createCanonicalManifestsForTest(
        fixture.root,replaceAlreadyHashedFileWithSameSize);
    assert(HookMutationSucceeded);
    assert(result.error==Integrity::Error::FileChanged);
    assert(result.failureStage==
        Integrity::FailureStage::ResourceSnapshotComparison);
    requireNoCandidateIdentity(result);
    requireNoPublishedManifests(fixture.root);
  }
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    HookMutationSucceeded = false;
    const auto result = Integrity::createCanonicalManifestsForTest(
        fixture.root,addLateResourceFile);
    assert(HookMutationSucceeded);
    assert(result.error==Integrity::Error::FileChanged);
    assert(result.failureStage==
        Integrity::FailureStage::ResourceSnapshotComparison);
    requireNoCandidateIdentity(result);
    requireNoPublishedManifests(fixture.root);
  }
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    HookMutationSucceeded = false;
    const auto result = Integrity::createCanonicalManifestsForTest(
        fixture.root,replaceAlreadyHashedSaveWithSameSize);
    assert(HookMutationSucceeded);
    assert(result.error==Integrity::Error::FileChanged);
    assert(result.failureStage==
        Integrity::FailureStage::SaveSnapshotComparison);
    requireNoCandidateIdentity(result);
    requireNoPublishedManifests(fixture.root);
  }
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    HookMutationSucceeded = false;
    const auto result = Integrity::createCanonicalManifestsForTest(
        fixture.root,rejectRevalidation);
    assert(HookMutationSucceeded);
    assert(result.error==Integrity::Error::FileChanged);
    assert(result.failureStage==Integrity::FailureStage::RevalidationHook);
    requireNoCandidateIdentity(result);
    requireNoPublishedManifests(fixture.root);
  }
  }

std::string readSource(const fs::path& path) {
  std::ifstream input(path,std::ios::binary);
  assert(input);
  return std::string(
      std::istreambuf_iterator<char>(input),
      std::istreambuf_iterator<char>());
  }

struct SourceAnchor final {
  std::string_view file;
  std::string_view snippet;
  };

static constexpr std::array<SourceAnchor,78> SourceAnchors = {{
  {"header","MaximumFileCount = 100000u"},
  {"header","MaximumTotalBytes = 16ull*1024ull*1024ull*1024ull"},
  {"header","MaximumFileBytes = 8ull*1024ull*1024ull*1024ull"},
  {"header","-renderer-ios-device-integrity-manifest-v1"},
  {"header","-renderer-ios-device-integrity-cleanup-v1"},
  {"header","inline constexpr std::string_view ResourceManifestFileName =\n    \"resource-manifest-v1.jsonl\";"},
  {"header","inline constexpr std::string_view ProtectedSaveManifestFileName =\n    \"protected-save-manifest-v1.jsonl\";"},
  {"header","using RevalidationTestHook = bool (*)(\n    const std::filesystem::path& documentRoot) noexcept;"},
  {"header","#if defined(OPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST)\nusing RevalidationTestHook = bool (*)"},
  {"header","uint64_t candidateOrdinal = 0u;\n  std::array<char,65> candidatePathSha256{};"},
  {"header","if(error!=Error::FileChanged ||"},
  {"header","(failureStage!=FailureStage::ResourceHashing &&\n        failureStage!=FailureStage::SaveHashing)"},
  {"header","candidatePathSha256[64]!='\\0'"},
  {"header","if(!((value>='0' && value<='9') || (value>='a' && value<='f')))"},
  {"header","const uint64_t collectionFileCount =\n        failureStage==FailureStage::ResourceHashing\n        ? resourceFileCount : protectedSaveFileCount;\n    if(candidateOrdinal>collectionFileCount)"},
  {"header","enum class CandidateHashTestHookResult : uint8_t {\n  NotSelected,\n  Mutated,\n  Failed,"},
  {"header","using CandidateHashTestHook = CandidateHashTestHookResult (*)(\n    const std::filesystem::path& documentRoot,\n    std::string_view normalizedRelativePath,\n    uint64_t candidateOrdinal,\n    FailureStage stage) noexcept;"},
  {"implementation","CFStringNormalize(normalized,kCFStringNormalizationFormC);"},
  {"implementation","CC_SHA256_Update(&context,data+offset,chunk)"},
  {"implementation","bool hashNormalizedPath(\n    std::string_view normalizedRelativePath,\n    std::array<char,65>& output) noexcept {"},
  {"implementation","constexpr std::array<std::string_view,3> ResourceRoots = {\n  \"Data\",\"_work/Data\",\"system\","},
  {"implementation","constexpr std::string_view ExcludedResource = \"system/Gothic.ini\";"},
  {"implementation","constexpr std::array<std::string_view,4> ProtectedSaves = {"},
  {"implementation","O_RDONLY|O_NOFOLLOW|closeOnExecFlag()"},
  {"implementation","::fstat(file.get(),&before)"},
  {"implementation","::fstat(file.get(),&after)"},
  {"implementation","::fstatat(parent,stableName.c_str(),&pathIdentity,\n               AT_SYMLINK_NOFOLLOW)!=0"},
  {"implementation","MaximumTotalBytes-collection.totalBytes"},
  {"implementation","if(collection.entries.size()>=MaximumFileCount)"},
  {"implementation","if(byteSize>MaximumFileBytes)"},
  {"implementation","collection.entries[index].normalizedRelativePath)\n      return Error::NormalizedPathCollision;"},
  {"implementation","if(!collection.excludedSeen)\n    return Error::MissingExcludedFile;"},
  {"implementation","for(const std::string_view save:ProtectedSaves)"},
  {"implementation","std::vector<DirectoryIdentity> directories;"},
  {"implementation","Collection resourcesAfterHash;\n    result.error = collectResources(root.get(),resourcesAfterHash);"},
  {"implementation","if(!sameCollectionSnapshot(resources,resourcesAfterHash)) {"},
  {"implementation",R"anchor("{\"schemaVersion\":1,\"roots\":[\"Data\",\"_work/Data\",")anchor"},
  {"implementation",R"anchor("{\"relativePath\":\"")anchor"},
  {"implementation",R"anchor("{\"schemaVersion\":1,\"protectedSlots\":[1,2,3,4],")anchor"},
  {"implementation",R"anchor("{\"slot\":"+std::to_string(index+1u)+)anchor"},
  {"implementation","::linkat(documentRoot,resources.temporaryName.c_str(),"},
  {"implementation","::fsync(documentRoot)!=0"},
  {"implementation","::fchmod(descriptor.get(),0600)!=0 ||\n     ::fsync(descriptor.get())!=0"},
  {"implementation","std::strcmp(candidate.sha256.data(),prepared.sha256.data())!=0"},
  {"implementation","O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW"},
  {"implementation","if(!leafIsAbsent(root.get(),ResourceManifestFileName) ||\n       !leafIsAbsent(root.get(),ProtectedSaveManifestFileName))"},
  {"implementation","result.error = collectResources(root.get(),resources);\n    if(result.error==Error::FileChanged)\n      result.failureStage = FailureStage::InitialResourceCollection;"},
  {"implementation","result.error = collectProtectedSaves(root.get(),saves);\n    if(result.error==Error::FileChanged)\n      result.failureStage = FailureStage::InitialSaveCollection;"},
  {"implementation","#if defined(OPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST)\n  bool candidateHashHookConsumed = false;\n#endif"},
  {"implementation","const CandidateHashTestHookResult hookResult = candidateHashHook(\n        *documentRootPath,candidate.normalizedRelativePath,\n        candidateOrdinal,stage);"},
  {"implementation","if(hookResult==CandidateHashTestHookResult::Failed)\n      return Error::OpenFailed;"},
  {"implementation","hookResult==CandidateHashTestHookResult::Mutated;\n    }\n#endif\n  const Error opened = openCandidate(\n      documentRoot,candidate,file,parent,leaf);"},
  {"implementation","const uint64_t ordinal = static_cast<uint64_t>(index)+1u;\n      std::array<char,65> normalizedPathSha256{};\n      if(ordinal<=MaximumFileCount &&\n         hashNormalizedPath(\n             candidate.normalizedRelativePath,normalizedPathSha256))"},
  {"implementation","result.candidateOrdinal = ordinal;\n        result.candidatePathSha256 = normalizedPathSha256;"},
  {"implementation","result.error = hashCollection(\n        root.get(),resources,result,FailureStage::ResourceHashing"},
  {"implementation","result.error = hashCollection(\n        root.get(),saves,result,FailureStage::SaveHashing"},
  {"implementation","result.error = collectResources(root.get(),resourcesAfterHash);\n    if(result.error==Error::FileChanged)\n      result.failureStage = FailureStage::PostHashResourceRecollection;"},
  {"implementation","result.error = collectProtectedSaves(root.get(),savesAfterHash);\n    if(result.error==Error::FileChanged)\n      result.failureStage = FailureStage::PostHashSaveRecollection;"},
  {"implementation","if(::fstat(root.get(),&rootAfterHash)!=0 ||\n       !sameStableStat(rootBefore,rootAfterHash)) {\n      setResultError(\n          result,Error::FileChanged,FailureStage::DocumentRootComparison);"},
  {"implementation","Result removeCanonicalManifests(\n    const std::filesystem::path& documentRoot) noexcept {\n  Result result;\n  try {"},
  {"implementation","#if defined(OPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST)\nResult createCanonicalManifestsForTest("},
  {"implementation","::unlinkat(root.get(),name.c_str(),0)"},
  {"implementation","::fsync(root.get())!=0"},
  {"main","#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n#include \"graphics/iosdeviceintegritymanifest.h\"\n#endif"},
  {"main","RendererIOSDeviceIntegrity::createCanonicalManifests(\".\")"},
  {"main","RendererIOSDeviceIntegrity::removeCanonicalManifests(\".\")"},
  {"main","RendererIOSDeviceIntegrity::CleanupTerminalMarker.data()"},
  {"main","std::fprintf(stdout,\"%s\\n\","},
  {"main","std::fflush(stdout)!=0"},
  {"main","throw std::runtime_error(\n            \"RendererIOS device integrity cleanup terminal write failed\");\n      return 0;"},
  {"main","if(integrityArguments.cleanupRequested) {\n      const auto integrity =\n          RendererIOSDeviceIntegrity::removeCanonicalManifests(\".\");\n      if(!integrity.success())\n        throw std::runtime_error(\n            std::string(\"RendererIOS device integrity cleanup failed: \")+\n            RendererIOSDeviceIntegrity::errorName(integrity.error));\n      if(std::fprintf(stdout,\"%s\\n\",\n                      RendererIOSDeviceIntegrity::CleanupTerminalMarker.data())<0 ||\n         std::fflush(stdout)!=0)\n        throw std::runtime_error(\n            \"RendererIOS device integrity cleanup terminal write failed\");\n      return 0;\n      }"},
  {"implementation","if(result.hasHashingCandidateIdentity()) {\n      message += \" candidate-ordinal=\"+std::to_string(result.candidateOrdinal);"},
  {"implementation","message += std::string(\" candidate-path-sha256=\")+\n          result.candidatePathSha256.data();"},
  {"main","if(!integrity.success())\n        throw std::runtime_error(\n            RendererIOSDeviceIntegrity::formatFailureMessage(integrity));"},
  {"main","RendererIOSDeviceIntegrity::TerminalMarker.data()"},
  {"cmake","    \"game/*.cpp\")"},
  {"cmake","\"-framework CoreFoundation\""},
  {"cmake","  if(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n    target_link_libraries(${PROJECT_NAME} \"-framework CoreFoundation\")\n  endif()"},
}};

bool sourceContractValid(
    const std::string& header,
    const std::string& implementation,
    const std::string& mainSource,
    const std::string& cmake) {
  for(const SourceAnchor& anchor:SourceAnchors) {
    const std::string& source = anchor.file=="header" ? header :
        anchor.file=="implementation" ? implementation :
        anchor.file=="main" ? mainSource : cmake;
    if(source.find(anchor.snippet)==std::string::npos ||
       source.find(anchor.snippet)!=source.rfind(anchor.snippet))
      return false;
    }
  if(mainSource.find("RendererIOS device integrity manifest failed:")!=
         std::string::npos ||
     mainSource.find("candidate-ordinal=")!=std::string::npos ||
     mainSource.find("candidate-path-sha256=")!=std::string::npos ||
     mainSource.find("rawRelativePath")!=std::string::npos ||
     mainSource.find("failureStageName")!=std::string::npos)
    return false;
  const std::string formatterCall =
      "RendererIOSDeviceIntegrity::formatFailureMessage(integrity)";
  if(mainSource.find(formatterCall)==std::string::npos ||
     mainSource.find(formatterCall)!=mainSource.rfind(formatterCall))
    return false;
  const std::size_t create = mainSource.find(
      "RendererIOSDeviceIntegrity::createCanonicalManifests(\".\")");
  const std::size_t terminal = mainSource.find(
      "RendererIOSDeviceIntegrity::TerminalMarker.data()");
  const std::size_t audio = mainSource.find("AudioSession::activate();");
  return create<terminal && terminal<audio;
  }

void testSourceMutationOracle() {
  const fs::path root = fs::current_path();
  const fs::path headerPath =
      root/"game/graphics/iosdeviceintegritymanifest.h";
  const fs::path implementationPath =
      root/"game/graphics/iosdeviceintegritymanifest.cpp";
  const fs::path mainPath = root/"game/main.cpp";
  const fs::path cmakePath = root/"CMakeLists.txt";
  const std::string header = readSource(headerPath);
  const std::string implementation = readSource(implementationPath);
  const std::string mainSource = readSource(mainPath);
  const std::string cmake = readSource(cmakePath);
  assert(sourceContractValid(header,implementation,mainSource,cmake));

  std::size_t mutationsKilled = 0u;
  for(const SourceAnchor& anchor:SourceAnchors) {
    for(const std::string_view replacement:{std::string_view(),
                                             std::string_view("MUTANT")}) {
      std::string mutantHeader = header;
      std::string mutantImplementation = implementation;
      std::string mutantMain = mainSource;
      std::string mutantCMake = cmake;
      std::string* target = anchor.file=="header" ? &mutantHeader :
          anchor.file=="implementation" ? &mutantImplementation :
          anchor.file=="main" ? &mutantMain : &mutantCMake;
      target->replace(target->find(anchor.snippet),
                      anchor.snippet.size(),replacement);
      assert(!sourceContractValid(
          mutantHeader,mutantImplementation,mutantMain,mutantCMake));
      ++mutationsKilled;
      }
    }
  for(const std::string_view forbidden:{
        std::string_view("RendererIOS device integrity manifest failed:"),
        std::string_view("candidate-ordinal="),
        std::string_view("candidate-path-sha256="),
        std::string_view("rawRelativePath"),
        }) {
    std::string mutantMain = mainSource;
    mutantMain.append(forbidden);
    assert(!sourceContractValid(header,implementation,mutantMain,cmake));
    ++mutationsKilled;
    }
  assert(mutationsKilled==160u);
  }

}

int main() {
  testArguments();
  testFailureStageNames();
  testCandidateIdentityAdmissionAndFormatting();
  testCanonicalFixture();
  testCleanup();
  testMissingExcludedFile();
  testMissingSave();
  testSingleLeafCollisionPublishesNothing();
  testSymlinksFailClosed();
  testMissingRoot();
  testSparseLimitsBeforeHashing();
  testHashingCandidateIdentity();
  testCandidateHookDomain();
  testPostHashExactTreeRevalidation();
  testSourceMutationOracle();
  std::printf(
      "RendererIOS device integrity manifest host oracle: "
      "PASS mutations-killed=160\n");
  return 0;
  }
