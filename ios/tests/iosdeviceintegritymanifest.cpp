#include "graphics/iosdeviceintegritymanifest.h"

#if !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
#error "device integrity manifest tests require diagnostics"
#endif
#if !defined(OPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST)
#error "device integrity manifest race tests require host-test hook"
#endif

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

void testCleanup() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  writeBytes(fixture.root/"unrelated.txt","keep");
  assert(Integrity::createCanonicalManifests(fixture.root).success());
  assert(Integrity::removeCanonicalManifests(fixture.root).success());
  assert(!fs::exists(fixture.root/Integrity::ResourceManifestFileName));
  assert(!fs::exists(fixture.root/Integrity::ProtectedSaveManifestFileName));
  assert(readBytes(fixture.root/"unrelated.txt")=="keep");
  assert(Integrity::removeCanonicalManifests(fixture.root).success());

  writeBytes(fixture.root/Integrity::ResourceManifestFileName,"owned");
  assert(::symlink("unrelated.txt",
      (fixture.root/Integrity::ProtectedSaveManifestFileName).c_str())==0);
  const auto collision = Integrity::removeCanonicalManifests(fixture.root);
  assert(collision.error==Integrity::Error::NonRegularEntry);
  assert(readBytes(fixture.root/Integrity::ResourceManifestFileName)=="owned");
  assert(fs::is_symlink(fixture.root/Integrity::ProtectedSaveManifestFileName));
  }

void testCanonicalFixture() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  const Integrity::Result result =
      Integrity::createCanonicalManifests(fixture.root);
  assert(result.success());
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
  assert(readBytes(resource)==resourceBefore);
  assert(readBytes(saves)==savesBefore);
  }

void testMissingExcludedFile() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  assert(fs::remove(fixture.root/"system"/"Gothic.ini"));
  const auto result = Integrity::createCanonicalManifests(fixture.root);
  assert(result.error==Integrity::Error::MissingExcludedFile);
  }

void testMissingSave() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  assert(fs::remove(fixture.root/"save_slot_4.sav"));
  const auto result = Integrity::createCanonicalManifests(fixture.root);
  assert(result.error==Integrity::Error::MissingProtectedSave);
  }

void testSingleLeafCollisionPublishesNothing() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  const fs::path saveManifest =
      fixture.root/Integrity::ProtectedSaveManifestFileName;
  writeBytes(saveManifest,"sentinel");
  const auto result = Integrity::createCanonicalManifests(fixture.root);
  assert(result.error==Integrity::Error::Collision);
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
  }
  {
    Fixture fixture;
    createBaseFixture(fixture.root);
    assert(fs::remove(fixture.root/"save_slot_2.sav"));
    assert(::symlink("save_slot_1.sav",
                     (fixture.root/"save_slot_2.sav").c_str())==0);
    const auto result = Integrity::createCanonicalManifests(fixture.root);
    assert(result.error==Integrity::Error::NonRegularEntry);
  }
  }

void testMissingRoot() {
  Fixture fixture;
  createBaseFixture(fixture.root);
  assert(fs::remove(fixture.root/"_work"/"Data"/"b.bin"));
  assert(fs::remove(fixture.root/"_work"/"Data"));
  const auto result = Integrity::createCanonicalManifests(fixture.root);
  assert(result.error==Integrity::Error::MissingRoot);
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
  }
  }

bool HookMutationSucceeded = false;

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

void requireNoPublishedManifests(const fs::path& root) {
  assert(!fs::exists(root/Integrity::ResourceManifestFileName));
  assert(!fs::exists(root/Integrity::ProtectedSaveManifestFileName));
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

static constexpr std::array<SourceAnchor,47> SourceAnchors = {{
  {"header","MaximumFileCount = 100000u"},
  {"header","MaximumTotalBytes = 16ull*1024ull*1024ull*1024ull"},
  {"header","MaximumFileBytes = 8ull*1024ull*1024ull*1024ull"},
  {"header","-renderer-ios-device-integrity-manifest-v1"},
  {"header","-renderer-ios-device-integrity-cleanup-v1"},
  {"header","inline constexpr std::string_view ResourceManifestFileName =\n    \"resource-manifest-v1.jsonl\";"},
  {"header","inline constexpr std::string_view ProtectedSaveManifestFileName =\n    \"protected-save-manifest-v1.jsonl\";"},
  {"header","using RevalidationTestHook = bool (*)(\n    const std::filesystem::path& documentRoot) noexcept;"},
  {"implementation","CFStringNormalize(normalized,kCFStringNormalizationFormC);"},
  {"implementation","CC_SHA256_Update(&context,data+offset,chunk)"},
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
  {"implementation","if(!sameCollectionSnapshot(resources,resourcesAfterHash) ||\n       !sameCollectionSnapshot(saves,savesAfterHash))"},
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
  {"implementation","Result removeCanonicalManifests(\n    const std::filesystem::path& documentRoot) noexcept {\n  Result result;\n  try {"},
  {"implementation","::unlinkat(root.get(),name.c_str(),0)"},
  {"implementation","::fsync(root.get())!=0"},
  {"main","#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n#include \"graphics/iosdeviceintegritymanifest.h\"\n#endif"},
  {"main","RendererIOSDeviceIntegrity::createCanonicalManifests(\".\")"},
  {"main","RendererIOSDeviceIntegrity::removeCanonicalManifests(\".\")"},
  {"main","RendererIOSDeviceIntegrity::CleanupTerminalMarker.data()"},
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
  assert(mutationsKilled==94u);
  }

}

int main() {
  testArguments();
  testCanonicalFixture();
  testCleanup();
  testMissingExcludedFile();
  testMissingSave();
  testSingleLeafCollisionPublishesNothing();
  testSymlinksFailClosed();
  testMissingRoot();
  testSparseLimitsBeforeHashing();
  testPostHashExactTreeRevalidation();
  testSourceMutationOracle();
  std::printf(
      "RendererIOS device integrity manifest host oracle: "
      "PASS mutations-killed=94\n");
  return 0;
  }
