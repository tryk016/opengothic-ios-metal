#include "graphics/iosmetalresourceclearpassprobe.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iterator>
#include <string_view>
#include <string>
#include <sys/stat.h>
#include <tuple>
#include <type_traits>
#include <unistd.h>
#include <utility>

namespace {

template<class Mutation>
bool rejects(Mutation&& mutation) {
  IOSFramePlan plan = iosMetalResourceClearPassPlan();
  std::forward<Mutation>(mutation)(plan);
  return !iosMetalResourceSelectClearPassPlan(plan);
  }

IOSMetalResourceClearPassNativeReport exactReport() noexcept {
  IOSMetalResourceClearPassNativeReport report;
  report.physicalPasses = 2u;
  report.commandBuffers = 1u;
  report.renderEncoders = 2u;
  report.submits = 0u;
  report.draws = 0u;
  report.pipelines = 0u;
  report.drawable = 0u;
  report.present = 0u;
  report.privateLoad = IOSLoadAction::Clear;
  report.privateStore = IOSStoreAction::Store;
  report.memorylessLoad = IOSLoadAction::Clear;
  report.memorylessStore = IOSStoreAction::Discard;
  report.encoded = true;
  return report;
  }

template<class Mutation>
bool rejectsReport(Mutation&& mutation) {
  IOSMetalResourceClearPassNativeReport report = exactReport();
  std::forward<Mutation>(mutation)(report);
  return !iosMetalResourceClearPassNativeReportMatches(report);
  }

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
class TemporaryDirectory final {
  public:
    TemporaryDirectory() {
      std::array<char,64> pattern = {};
      constexpr char Prefix[] = "/tmp/rendererios-capture-normalize.XXXXXX";
      static_assert(sizeof(Prefix)<=std::tuple_size_v<decltype(pattern)>);
      std::copy(std::begin(Prefix),std::end(Prefix),pattern.begin());
      char* const created = ::mkdtemp(pattern.data());
      if(created!=nullptr)
        path = created;
      }

    ~TemporaryDirectory() {
      std::error_code error;
      std::filesystem::remove_all(path,error);
      }

    explicit operator bool() const noexcept {
      return !path.empty();
      }

    std::filesystem::path path;
  };

bool writeBytes(const std::filesystem::path& path,
                std::string_view bytes) {
  std::ofstream output(path,std::ios::binary);
  output.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));
  return bool(output);
  }

std::string readBytes(const std::filesystem::path& path) {
  std::ifstream input(path,std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
  }

bool isSymlink(const std::filesystem::path& path) {
  std::error_code error;
  return std::filesystem::is_symlink(
      std::filesystem::symlink_status(path,error));
  }

bool normalizeRejects(const std::filesystem::path& path,
                      std::string_view expectedReason) {
  IOSMetalCaptureArtifact artifact;
  const char* reason = nullptr;
  return !iosMetalNormalizeAndInspectCaptureArtifact(
            path.c_str(),artifact,reason) && reason!=nullptr &&
         std::string_view(reason)==expectedReason;
  }

#if defined(OPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS)
bool hasSymlinkTarget(const std::filesystem::path& path,
                      std::string_view expected) {
  std::error_code error;
  const std::filesystem::path target =
      std::filesystem::read_symlink(path,error);
  return !error && target.native()==expected;
  }

std::string RootSwapMovedPath;
std::string RootSwapUnsafePath;
std::string RootSwapFirstTemporaryPath;
std::string RootSwapSecondTemporaryPath;
bool RootSwapHookSucceeded = false;
std::string RegularRootSwapMovedPath;
bool RegularRootSwapHookSucceeded = false;

void swapCaptureRootBeforeCommit(const char* rootPath) noexcept {
  struct stat firstTemporary = {};
  struct stat secondTemporary = {};
  if(::lstat(RootSwapFirstTemporaryPath.c_str(),&firstTemporary)!=0 ||
     ::lstat(RootSwapSecondTemporaryPath.c_str(),&secondTemporary)!=0 ||
     !S_ISREG(firstTemporary.st_mode) ||
     !S_ISREG(secondTemporary.st_mode) ||
     ::rename(rootPath,RootSwapMovedPath.c_str())!=0 ||
     ::mkdir(rootPath,0700)!=0 ||
     ::symlink("../outside",RootSwapUnsafePath.c_str())!=0)
    return;
  RootSwapHookSucceeded = true;
  }

void swapRegularCaptureRootBeforeCheck(const char* rootPath) noexcept {
  constexpr char Replacement[] = "replacement";
  if(::rename(rootPath,RegularRootSwapMovedPath.c_str())!=0)
    return;
  const int replacement = ::open(
      rootPath,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
  if(replacement<0)
    return;
  const ssize_t written = ::write(
      replacement,Replacement,sizeof(Replacement)-1u);
  const bool synced = ::fsync(replacement)==0;
  const bool closed = ::close(replacement)==0;
  RegularRootSwapHookSucceeded =
      written==static_cast<ssize_t>(sizeof(Replacement)-1u) &&
      synced && closed;
  }
#endif

int testCapturePackageNormalization() {
  constexpr char CaptureName[] = "RendererIOS-pm-clear-v1.gputrace";
  constexpr char TargetName[] = "MTLTexture-28-0-mipmap0-slice0";
  constexpr char Alias26[] = "MTLTexture-26-0-mipmap0-slice0";
  constexpr char Alias27[] = "MTLTexture-27-0-mipmap0-slice0";
  constexpr std::string_view Payload = "apple-shared-resource";

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 240;
    const auto capture = temporary.path/CaptureName;
    std::filesystem::create_directory(capture);
    std::filesystem::create_directory(capture/"metadata");
    if(!writeBytes(capture/TargetName,Payload) ||
       !writeBytes(capture/"capture","meta") ||
       !writeBytes(capture/"metadata"/"index","nested"))
      return 241;
    std::filesystem::create_symlink(TargetName,capture/Alias26);
    std::filesystem::create_symlink(
        std::string("./")+TargetName,capture/Alias27);
    IOSMetalCaptureArtifact artifact;
    const char* reason = "not-cleared";
    if(!iosMetalNormalizeAndInspectCaptureArtifact(
       capture.c_str(),artifact,reason) || reason!=nullptr ||
       artifact.kind!=IOSMetalCaptureArtifactKind::Directory ||
       artifact.bytes!=Payload.size()*3u+10u ||
       isSymlink(capture/Alias26) || isSymlink(capture/Alias27) ||
       readBytes(capture/Alias26)!=Payload ||
       readBytes(capture/Alias27)!=Payload)
      return 242;
    for(const auto& entry:std::filesystem::recursive_directory_iterator(capture)) {
      if(isSymlink(entry.path()))
        return 243;
      }
    }

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 244;
    const auto capture = temporary.path/CaptureName;
    std::filesystem::create_directory(capture);
    if(!writeBytes(temporary.path/"outside",Payload))
      return 245;
    std::filesystem::create_symlink("../outside",capture/Alias26);
    if(!normalizeRejects(capture,"capture-package-unsafe-symlink") ||
       !isSymlink(capture/Alias26))
      return 246;
    }

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 247;
    const auto capture = temporary.path/CaptureName;
    std::filesystem::create_directory(capture);
    if(!writeBytes(capture/TargetName,Payload))
      return 248;
    std::filesystem::create_symlink(TargetName,capture/Alias26);
    std::filesystem::create_symlink("../outside",capture/Alias27);
    if(!normalizeRejects(capture,"capture-package-unsafe-symlink") ||
       !isSymlink(capture/Alias26) || !isSymlink(capture/Alias27))
      return 249;
    }

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 250;
    const auto capture = temporary.path/CaptureName;
    std::filesystem::create_directory(capture);
    if(!writeBytes(capture/TargetName,Payload))
      return 251;
    std::filesystem::create_symlink(TargetName,capture/Alias27);
    std::filesystem::create_symlink(Alias27,capture/Alias26);
    if(!normalizeRejects(capture,"capture-package-unsafe-symlink") ||
       !isSymlink(capture/Alias26) || !isSymlink(capture/Alias27))
      return 252;
    }

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 253;
    const auto capture = temporary.path/CaptureName;
    std::filesystem::create_directory(capture);
    if(!writeBytes(capture/TargetName,Payload) ||
       ::mkfifo((capture/"special").c_str(),0600)!=0)
      return 254;
    if(!normalizeRejects(capture,"capture-package-special-node"))
      return 255;
    }

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 256;
    const auto capture = temporary.path/CaptureName;
    std::filesystem::create_directory(capture);
    if(!writeBytes(capture/TargetName,Payload) ||
       !writeBytes(capture/(std::string(Alias26)+
                            ".rendererios-materializing"),"collision"))
      return 257;
    std::filesystem::create_symlink(TargetName,capture/Alias26);
    if(!normalizeRejects(capture,"capture-package-unsafe-symlink") ||
       !isSymlink(capture/Alias26))
      return 258;
    }

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 259;
    const auto capture = temporary.path/CaptureName;
    std::filesystem::create_directory(capture);
    if(!normalizeRejects(capture,"capture-artifact-empty-or-too-large"))
      return 260;
    }

#if defined(OPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS)
  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 264;
    const auto capture = temporary.path/CaptureName;
    std::filesystem::create_directory(capture);
    if(!writeBytes(capture/TargetName,Payload) ||
       !writeBytes(capture/"capture","meta"))
      return 265;
    std::filesystem::create_symlink(TargetName,capture/Alias26);
    std::filesystem::create_symlink(
        std::string("./")+TargetName,capture/Alias27);
    iosMetalCaptureNormalizerFailCommitForTesting(1u);
    if(!normalizeRejects(capture,"capture-package-materialization-failed") ||
       !hasSymlinkTarget(capture/Alias26,TargetName) ||
       !hasSymlinkTarget(capture/Alias27,
                         std::string("./")+TargetName) ||
       std::filesystem::exists(
           capture/(std::string(Alias26)+
                    ".rendererios-materializing")) ||
       std::filesystem::exists(
           capture/(std::string(Alias27)+
                    ".rendererios-materializing")) ||
       std::filesystem::exists(
           capture/(std::string(Alias26)+".rendererios-rollback")) ||
       std::filesystem::exists(
           capture/(std::string(Alias27)+".rendererios-rollback")) ||
       readBytes(capture/TargetName)!=Payload)
      return 266;
    }

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 267;
    const auto capture = temporary.path/CaptureName;
    const auto moved = temporary.path/"moved.gputrace";
    std::filesystem::create_directory(capture);
    if(!writeBytes(capture/TargetName,Payload) ||
       !writeBytes(capture/"capture","meta"))
      return 268;
    std::filesystem::create_symlink(TargetName,capture/Alias26);
    std::filesystem::create_symlink(
        std::string("./")+TargetName,capture/Alias27);
    RootSwapMovedPath = moved.native();
    RootSwapUnsafePath = (capture/"unsafe").native();
    RootSwapFirstTemporaryPath =
        (capture/(std::string(Alias26)+
                  ".rendererios-materializing")).native();
    RootSwapSecondTemporaryPath =
        (capture/(std::string(Alias27)+
                  ".rendererios-materializing")).native();
    RootSwapHookSucceeded = false;
    iosMetalCaptureNormalizerSetBeforeRootCheckHookForTesting(
        swapCaptureRootBeforeCommit);
    if(!normalizeRejects(capture,"capture-artifact-root-changed") ||
       !RootSwapHookSucceeded ||
       !isSymlink(capture/"unsafe") ||
       !hasSymlinkTarget(moved/Alias26,TargetName) ||
       !hasSymlinkTarget(moved/Alias27,
                         std::string("./")+TargetName) ||
       std::filesystem::exists(
           moved/(std::string(Alias26)+
                  ".rendererios-materializing")) ||
       std::filesystem::exists(
           moved/(std::string(Alias27)+
                  ".rendererios-materializing")) ||
       std::filesystem::exists(
           moved/(std::string(Alias26)+".rendererios-rollback")) ||
       std::filesystem::exists(
           moved/(std::string(Alias27)+".rendererios-rollback")) ||
       readBytes(moved/TargetName)!=Payload)
      return 269;
    }

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 270;
    const auto capture = temporary.path/"flat.gputrace";
    const auto moved = temporary.path/"flat-moved.gputrace";
    if(!writeBytes(capture,Payload))
      return 271;
    RegularRootSwapMovedPath = moved.native();
    RegularRootSwapHookSucceeded = false;
    iosMetalCaptureNormalizerSetBeforeRootCheckHookForTesting(
        swapRegularCaptureRootBeforeCheck);
    if(!normalizeRejects(capture,"capture-artifact-root-changed") ||
       !RegularRootSwapHookSucceeded ||
       readBytes(moved)!=Payload || readBytes(capture)!="replacement")
      return 272;
    }
#endif

  {
    TemporaryDirectory temporary;
    if(!temporary)
      return 261;
    const auto capture = temporary.path/CaptureName;
    if(!writeBytes(capture,Payload))
      return 262;
    IOSMetalCaptureArtifact artifact;
    const char* reason = "not-cleared";
    if(!iosMetalNormalizeAndInspectCaptureArtifact(
         capture.c_str(),artifact,reason) || reason!=nullptr ||
       artifact.kind!=IOSMetalCaptureArtifactKind::File ||
       artifact.bytes!=Payload.size())
      return 263;
    }
  return 0;
  }
#endif

}

int main() {
  static_assert(IOSFramePlanABIVersion==4u);
  static_assert(std::is_aggregate_v<IOSMetalResourceClearPassSelection>);
  static_assert(std::is_trivially_copyable_v<
                    IOSMetalResourceClearPassSelection>);
  static_assert(std::is_aggregate_v<
                    IOSMetalResourceClearPassNativeReport>);
  static_assert(std::is_trivially_copyable_v<
                    IOSMetalResourceClearPassNativeReport>);
  static_assert(static_cast<uint8_t>(
                    IOSMetalResourceClearPassPlanStatus::Supported)==0u);
  static_assert(static_cast<uint8_t>(
                    IOSMetalResourceClearPassPlanStatus::Invalid)==1u);
  static_assert(static_cast<uint8_t>(
                    IOSMetalResourceClearPassPlanStatus::Unsupported)==2u);

  const IOSFramePlan plan = iosMetalResourceClearPassPlan();
  const IOSFramePlanValidation validation = plan.validate();
  if(!validation || plan.resources.size()!=3u || plan.passes.size()!=3u)
    return 1;
  const IOSMetalResourceClearPassSelection selection =
      iosMetalResourceSelectClearPassPlan(plan);
  if(!selection || selection.presentResource!=0u ||
     selection.privateResource!=1u || selection.memorylessResource!=2u ||
     selection.privatePass!=0u || selection.memorylessPass!=1u ||
     selection.presentPass!=2u)
    return 2;

  const auto& present = plan.resources[selection.presentResource];
  const auto& privateResource = plan.resources[selection.privateResource];
  const auto& memorylessResource =
      plan.resources[selection.memorylessResource];
  if(present.id!=IOSResourceId{1u} ||
     present.kind!=IOSResourceKind::Texture ||
     present.lifetime!=IOSResourceLifetime::External ||
     present.initialContent!=IOSInitialContent::Defined ||
     present.memoryless || present.aliasable || bool(present.aliasGroup) ||
     present.layout!=IOSResourceLayout{
       IOSPixelFormat::Bgra8Unorm,{4u,4u},1u,1u,0u} ||
     present.usage!=IOSResourceUsage::Present)
    return 3;
  if(privateResource.id!=IOSResourceId{2u} ||
     privateResource.kind!=IOSResourceKind::Texture ||
     privateResource.lifetime!=IOSResourceLifetime::Transient ||
     privateResource.initialContent!=IOSInitialContent::Undefined ||
     privateResource.memoryless || privateResource.aliasable ||
     bool(privateResource.aliasGroup) ||
     privateResource.layout!=IOSResourceLayout{
       IOSPixelFormat::Rgba8Unorm,{4u,4u},1u,1u,0u} ||
     privateResource.usage!=IOSResourceUsage::RenderAttachment)
    return 4;
  IOSResourceDesc expectedMemoryless = privateResource;
  expectedMemoryless.id = IOSResourceId{3u};
  expectedMemoryless.memoryless = true;
  if(memorylessResource.id!=expectedMemoryless.id ||
     memorylessResource.kind!=expectedMemoryless.kind ||
     memorylessResource.lifetime!=expectedMemoryless.lifetime ||
     memorylessResource.initialContent!=expectedMemoryless.initialContent ||
     memorylessResource.memoryless!=expectedMemoryless.memoryless ||
     memorylessResource.aliasable!=expectedMemoryless.aliasable ||
     memorylessResource.aliasGroup!=expectedMemoryless.aliasGroup ||
     memorylessResource.layout!=expectedMemoryless.layout ||
     memorylessResource.usage!=expectedMemoryless.usage)
    return 5;

  IOSFramePlan invalidPlan = plan;
  invalidPlan.passes.pop_back();
  if(iosMetalResourceSelectClearPassPlan(invalidPlan).status!=
       IOSMetalResourceClearPassPlanStatus::Invalid)
    return 9;
  IOSFramePlan unsupportedPlan = plan;
  unsupportedPlan.resources[0].layout.extent.width = 8u;
  if(!unsupportedPlan.validate() ||
     iosMetalResourceSelectClearPassPlan(unsupportedPlan).status!=
       IOSMetalResourceClearPassPlanStatus::Unsupported)
    return 10;

  const auto& privatePass = plan.passes[selection.privatePass];
  const auto& memorylessPass = plan.passes[selection.memorylessPass];
  const auto& presentPass = plan.passes[selection.presentPass];
  if(privatePass.id!=IOSPassId{1u} ||
     privatePass.kind!=IOSPassKind::Render ||
     privatePass.uses.size()!=1u ||
     privatePass.uses[0].resource!=IOSResourceId{2u} ||
     privatePass.uses[0].semantic!=IOSUseSemantic::RenderAttachment ||
     privatePass.uses[0].load!=IOSLoadAction::Clear ||
     privatePass.uses[0].store!=IOSStoreAction::Store ||
     privatePass.uses[0].attachmentWriteMode!=
       IOSAttachmentWriteMode::FullOverwrite)
    return 6;
  if(memorylessPass.id!=IOSPassId{2u} ||
     memorylessPass.kind!=IOSPassKind::Render ||
     memorylessPass.uses.size()!=1u ||
     memorylessPass.uses[0].resource!=IOSResourceId{3u} ||
     memorylessPass.uses[0].semantic!=IOSUseSemantic::RenderAttachment ||
     memorylessPass.uses[0].load!=IOSLoadAction::Clear ||
     memorylessPass.uses[0].store!=IOSStoreAction::Discard ||
     memorylessPass.uses[0].attachmentWriteMode!=
       IOSAttachmentWriteMode::FullOverwrite)
    return 7;
  if(presentPass.id!=IOSPassId{3u} ||
     presentPass.kind!=IOSPassKind::Present ||
     presentPass.uses.size()!=1u ||
     presentPass.uses[0].resource!=IOSResourceId{1u} ||
     presentPass.uses[0].semantic!=IOSUseSemantic::PresentSource ||
     presentPass.uses[0].load!=IOSLoadAction::NotApplicable ||
     presentPass.uses[0].store!=IOSStoreAction::NotApplicable ||
     presentPass.uses[0].attachmentWriteMode!=
       IOSAttachmentWriteMode::NotApplicable)
    return 8;

  uint32_t mutation = 0u;
#define EXPECT_REJECTED(expression)                                      \
  do {                                                                   \
    ++mutation;                                                          \
    if(!rejects([](IOSFramePlan& p) { expression; }))                    \
      return static_cast<int>(100u+mutation);                            \
  } while(false);

  EXPECT_REJECTED(p.resources.pop_back())
  EXPECT_REJECTED(p.resources.push_back(p.resources.back()))
  EXPECT_REJECTED(std::swap(p.resources[0],p.resources[1]))
  EXPECT_REJECTED(p.passes.pop_back())
  EXPECT_REJECTED(p.passes.push_back(p.passes.back()))
  EXPECT_REJECTED(std::swap(p.passes[0],p.passes[1]))

  EXPECT_REJECTED(p.resources[0].id = IOSResourceId{9u})
  EXPECT_REJECTED(p.resources[0].kind = IOSResourceKind::Buffer)
  EXPECT_REJECTED(p.resources[0].lifetime = IOSResourceLifetime::Persistent)
  EXPECT_REJECTED(p.resources[0].initialContent = IOSInitialContent::Undefined)
  EXPECT_REJECTED(p.resources[0].memoryless = true)
  EXPECT_REJECTED(p.resources[0].aliasable = true)
  EXPECT_REJECTED(p.resources[0].aliasGroup = IOSAliasGroupId{1u})
  EXPECT_REJECTED(p.resources[0].layout.format = IOSPixelFormat::Rgba8Unorm)
  EXPECT_REJECTED(p.resources[0].layout.extent.width = 8u)
  EXPECT_REJECTED(p.resources[0].layout.extent.height = 8u)
  EXPECT_REJECTED(p.resources[0].layout.mipLevels = 2u)
  EXPECT_REJECTED(p.resources[0].layout.sampleCount = 2u)
  EXPECT_REJECTED(p.resources[0].layout.byteSize = 16u)
  EXPECT_REJECTED(p.resources[0].usage = IOSResourceUsage::RenderAttachment |
                                         IOSResourceUsage::Present)

  EXPECT_REJECTED(p.resources[1].id = IOSResourceId{8u})
  EXPECT_REJECTED(p.resources[1].kind = IOSResourceKind::Buffer)
  EXPECT_REJECTED(p.resources[1].lifetime = IOSResourceLifetime::PerFrame)
  EXPECT_REJECTED(p.resources[1].initialContent = IOSInitialContent::Defined)
  EXPECT_REJECTED(p.resources[1].memoryless = true)
  EXPECT_REJECTED(p.resources[1].aliasable = true)
  EXPECT_REJECTED(p.resources[1].aliasGroup = IOSAliasGroupId{2u})
  EXPECT_REJECTED(p.resources[1].layout.format = IOSPixelFormat::Bgra8Unorm)
  EXPECT_REJECTED(p.resources[1].layout.extent.width = 8u)
  EXPECT_REJECTED(p.resources[1].layout.extent.height = 8u)
  EXPECT_REJECTED(p.resources[1].layout.mipLevels = 2u)
  EXPECT_REJECTED(p.resources[1].layout.sampleCount = 2u)
  EXPECT_REJECTED(p.resources[1].layout.byteSize = 16u)
  EXPECT_REJECTED(p.resources[1].usage = IOSResourceUsage::RenderAttachment |
                                         IOSResourceUsage::ShaderRead)

  EXPECT_REJECTED(p.resources[2].id = IOSResourceId{8u})
  EXPECT_REJECTED(p.resources[2].kind = IOSResourceKind::Buffer)
  EXPECT_REJECTED(p.resources[2].lifetime = IOSResourceLifetime::PerFrame)
  EXPECT_REJECTED(p.resources[2].initialContent = IOSInitialContent::Defined)
  EXPECT_REJECTED(p.resources[2].memoryless = false)
  EXPECT_REJECTED(p.resources[2].aliasable = true)
  EXPECT_REJECTED(p.resources[2].aliasGroup = IOSAliasGroupId{3u})
  EXPECT_REJECTED(p.resources[2].layout.format = IOSPixelFormat::Bgra8Unorm)
  EXPECT_REJECTED(p.resources[2].layout.extent.width = 8u)
  EXPECT_REJECTED(p.resources[2].layout.extent.height = 8u)
  EXPECT_REJECTED(p.resources[2].layout.mipLevels = 2u)
  EXPECT_REJECTED(p.resources[2].layout.sampleCount = 2u)
  EXPECT_REJECTED(p.resources[2].layout.byteSize = 16u)
  EXPECT_REJECTED(p.resources[2].usage = IOSResourceUsage::RenderAttachment |
                                         IOSResourceUsage::ShaderRead)

  EXPECT_REJECTED(p.passes[0].id = IOSPassId{9u})
  EXPECT_REJECTED(p.passes[0].kind = IOSPassKind::Blit)
  EXPECT_REJECTED(p.passes[0].uses.clear())
  EXPECT_REJECTED(p.passes[0].uses.push_back(p.passes[0].uses[0]))
  EXPECT_REJECTED(p.passes[0].uses[0].resource = IOSResourceId{3u})
  EXPECT_REJECTED(p.passes[0].uses[0].semantic = IOSUseSemantic::Read)
  EXPECT_REJECTED(p.passes[0].uses[0].load = IOSLoadAction::Load)
  EXPECT_REJECTED(p.passes[0].uses[0].store = IOSStoreAction::Discard)
  EXPECT_REJECTED(p.passes[0].uses[0].attachmentWriteMode =
                      IOSAttachmentWriteMode::MayPreserve)

  EXPECT_REJECTED(p.passes[1].id = IOSPassId{9u})
  EXPECT_REJECTED(p.passes[1].kind = IOSPassKind::Compute)
  EXPECT_REJECTED(p.passes[1].uses.clear())
  EXPECT_REJECTED(p.passes[1].uses.push_back(p.passes[1].uses[0]))
  EXPECT_REJECTED(p.passes[1].uses[0].resource = IOSResourceId{2u})
  EXPECT_REJECTED(p.passes[1].uses[0].semantic = IOSUseSemantic::Read)
  EXPECT_REJECTED(p.passes[1].uses[0].load = IOSLoadAction::Discard)
  EXPECT_REJECTED(p.passes[1].uses[0].store = IOSStoreAction::Store)
  EXPECT_REJECTED(p.passes[1].uses[0].attachmentWriteMode =
                      IOSAttachmentWriteMode::MayPreserve)

  EXPECT_REJECTED(p.passes[2].id = IOSPassId{9u})
  EXPECT_REJECTED(p.passes[2].kind = IOSPassKind::External)
  EXPECT_REJECTED(p.passes[2].uses.clear())
  EXPECT_REJECTED(p.passes[2].uses.push_back(p.passes[2].uses[0]))
  EXPECT_REJECTED(p.passes[2].uses[0].resource = IOSResourceId{2u})
  EXPECT_REJECTED(p.passes[2].uses[0].semantic = IOSUseSemantic::Read)
  EXPECT_REJECTED(p.passes[2].uses[0].load = IOSLoadAction::Clear)
  EXPECT_REJECTED(p.passes[2].uses[0].store = IOSStoreAction::Store)
  EXPECT_REJECTED(p.passes[2].uses[0].attachmentWriteMode =
                      IOSAttachmentWriteMode::FullOverwrite)
#undef EXPECT_REJECTED

  if(mutation!=75u)
    return 200;

  if(!iosMetalResourceClearPassNativeReportMatches(exactReport()))
    return 201;
  uint32_t reportMutation = 0u;
#define EXPECT_REPORT_REJECTED(expression)                               \
  do {                                                                   \
    ++reportMutation;                                                    \
    if(!rejectsReport([](IOSMetalResourceClearPassNativeReport& r) {     \
         expression;                                                     \
       }))                                                               \
      return static_cast<int>(210u+reportMutation);                      \
  } while(false);
  EXPECT_REPORT_REJECTED(r.physicalPasses = 1u)
  EXPECT_REPORT_REJECTED(r.commandBuffers = 2u)
  EXPECT_REPORT_REJECTED(r.renderEncoders = 1u)
  EXPECT_REPORT_REJECTED(r.submits = 1u)
  EXPECT_REPORT_REJECTED(r.draws = 1u)
  EXPECT_REPORT_REJECTED(r.pipelines = 1u)
  EXPECT_REPORT_REJECTED(r.drawable = 1u)
  EXPECT_REPORT_REJECTED(r.present = 1u)
  EXPECT_REPORT_REJECTED(r.privateLoad = IOSLoadAction::Load)
  EXPECT_REPORT_REJECTED(r.privateStore = IOSStoreAction::Discard)
  EXPECT_REPORT_REJECTED(r.memorylessLoad = IOSLoadAction::Discard)
  EXPECT_REPORT_REJECTED(r.memorylessStore = IOSStoreAction::Store)
  EXPECT_REPORT_REJECTED(r.encoded = false)
#undef EXPECT_REPORT_REJECTED
  if(reportMutation!=13u)
    return 230;

  if(iosMetalResourceClearPassPlanStatusName(
         IOSMetalResourceClearPassPlanStatus::Supported)!=
         std::string_view("supported") ||
     iosMetalResourceClearPassPlanStatusName(
         IOSMetalResourceClearPassPlanStatus::Invalid)!=
         std::string_view("invalid") ||
     iosMetalResourceClearPassPlanStatusName(
         IOSMetalResourceClearPassPlanStatus::Unsupported)!=
         std::string_view("unsupported") ||
     iosMetalResourceClearPassPlanStatusName(
         static_cast<IOSMetalResourceClearPassPlanStatus>(0xFFu))!=
         std::string_view("unsupported"))
    return 231;
#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
  if(const int normalization = testCapturePackageNormalization();
     normalization!=0)
    return normalization;
#endif
  return 0;
  }
