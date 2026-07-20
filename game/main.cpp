#include <Tempest/Window>
#include <Tempest/Application>
#include <Tempest/Log>

#include <zenkit/Logger.hh>

#include <Tempest/VulkanApi>

#if defined(_MSC_VER)
#include <Tempest/DirectX12Api>
#endif

#if defined(__APPLE__)
#include <Tempest/MetalApi>
#endif

#if defined(__IOS__)
#include "utils/installdetect.h"
#include "graphics/iosbuiltinshaderabi.h"
#include "graphics/iosinventoryshaderabi.h"
#include "graphics/ioslandscapeshaderabi.h"
#include "graphics/iospipelinearchivepolicy.h"
#include "graphics/rendereriosplatform.h"
#include "shader.h"
#endif

#include <cstdio>

#include "utils/crashlog.h"
#include "utils/systemmsg.h"
#include "utils/audiosession.h"
#include "mainwindow.h"
#include "gothic.h"
#include "build.h"
#include "commandline.h"

#include <dmusic.h>

namespace {

constexpr bool shouldFlushLogLine(Tempest::Log::Mode mode) noexcept {
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  (void)mode;
  return true;
#else
  return mode==Tempest::Log::Error;
#endif
  }

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
static_assert(shouldFlushLogLine(Tempest::Log::Info));
#else
static_assert(!shouldFlushLogLine(Tempest::Log::Info));
#endif
static_assert(shouldFlushLogLine(Tempest::Log::Error));

}

std::string_view selectDevice(const Tempest::AbstractGraphicsApi& api) {
  auto d = api.devices();

  static Tempest::Device::Props p;
  for(auto& i:d)
    // if(i.type==Tempest::DeviceType::Integrated) {
    if(i.type==Tempest::DeviceType::Discrete) {
      p = i;
      return p.name;
      }
  if(d.size()>0) {
    p = d[0];
    return p.name;
    }
  return "";
  }

std::unique_ptr<Tempest::AbstractGraphicsApi> mkApi(
    const CommandLine& g
#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    , RendererIOSPipelineArchive::TestMode pipelineArchiveTestMode
#endif
    ) {
  Tempest::ApiFlags flg = g.isValidationMode() ? Tempest::ApiFlags::Validation : Tempest::ApiFlags::NoFlags;
  switch(g.graphicsApi()) {
    case CommandLine::DirectX12:
#if defined(_MSC_VER)
      return std::make_unique<Tempest::DirectX12Api>(flg);
#else
      break;
#endif
    case CommandLine::Vulkan:
#if !defined(__APPLE__)
      return std::make_unique<Tempest::VulkanApi>(flg);
#else
      break;
#endif
    }

#if defined(__APPLE__)
#if defined(__IOS__)
  static_assert(Tempest::MetalPipelineArchiveConfig::AbiVersion==1u);
  static_assert(
    RendererIOSPipelineArchive::MetallibAbiVersion==
    RendererIOSShader::AbiVersion);
  const std::string metallibPath = rendererIOSMetalLibraryPath();
#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  if(pipelineArchiveTestMode!=RendererIOSPipelineArchive::TestMode::None) {
    const RendererIOSPipelineArchiveTestModeResult result =
      rendererIOSApplyPipelineArchiveTestMode(
        metallibPath,pipelineArchiveTestMode);
    Tempest::Log::i(
      RendererIOSPipelineArchive::TestModeLogPrefix.data(),
      RendererIOSPipelineArchive::testModeName(
        pipelineArchiveTestMode).data(),
      " applied=1 abi=",RendererIOSPipelineArchive::TestModeAbiVersion,
      " bytes=",result.bytes,
      " removed-verified=",result.removedVerified ? 1 : 0,
      " write-verified=",result.writeVerified ? 1 : 0,
      " sha256=",result.writeVerified
        ? RendererIOSPipelineArchive::CorruptArchivePayloadSha256.data()
        : "none");
    }
#endif
  const RendererIOSPipelineArchiveDescriptor pipelineArchive =
    rendererIOSPipelineArchiveDescriptor(metallibPath);
  Tempest::MetalBuiltinOfflineManifest manifest;
  manifest.metallibPath = metallibPath.c_str();
  manifest.colorVertexFunction =
      RendererIOSBuiltinShader::FunctionNames[0].data();
  manifest.colorFragmentFunction =
      RendererIOSBuiltinShader::FunctionNames[1].data();
  manifest.textureVertexFunction =
      RendererIOSBuiltinShader::FunctionNames[2].data();
  manifest.textureFragmentFunction =
      RendererIOSBuiltinShader::FunctionNames[3].data();
  const auto inventoryVertex =
      GothicShader::get("item.vert.sprv");
  const auto inventoryFragment =
      GothicShader::get("item.frag.sprv");
  manifest.inventoryVertexSpirv = inventoryVertex.data;
  manifest.inventoryVertexSpirvSize = inventoryVertex.len;
  manifest.inventoryVertexFunction =
      RendererIOSInventoryShader::FunctionNames[0].data();
  manifest.inventoryFragmentSpirv = inventoryFragment.data;
  manifest.inventoryFragmentSpirvSize = inventoryFragment.len;
  manifest.inventoryFragmentFunction =
      RendererIOSInventoryShader::FunctionNames[1].data();
  try {
    Tempest::Log::i(
      RendererIOSPipelineArchive::ProvenancePolicyLogPrefix.data(),
      pipelineArchive.archivePath.empty() ? 0 : 1,
      " schema=",
      RendererIOSPipelineArchive::CacheSchemaVersion,
      " key=",
      RendererIOSPipelineArchive::PipelineKeyAbiVersion,
      " metallib=",
      RendererIOSPipelineArchive::MetallibAbiVersion,
      " digest=",
      pipelineArchive.metallibSha256.empty()
        ? "unavailable"
        : pipelineArchive.metallibSha256.c_str(),
      " stale-reset=",
      pipelineArchive.invalidatedStaleArchive ? 1 : 0);
    }
  catch(...) {
    }
  if(pipelineArchive.archivePath.empty())
    return std::make_unique<Tempest::MetalApi>(flg,manifest);
  Tempest::MetalPipelineArchiveConfig archiveConfig;
  archiveConfig.archivePath = pipelineArchive.archivePath.c_str();
  return std::make_unique<Tempest::MetalApi>(
    flg,manifest,archiveConfig);
#else
  return std::make_unique<Tempest::MetalApi>(flg);
#endif
#else
  return std::make_unique<Tempest::VulkanApi>(flg);
#endif
  }

int main(int argc,const char** argv) {
#if defined(__IOS__)
  {
    auto appdir = InstallDetect::applicationSupportDirectory();
    std::filesystem::current_path(appdir);
    // Capture the runtime's last words: libobjc/libc++abi/libmalloc print their
    // fatal reason to stderr before abort(). CWD is the user-visible Documents
    // folder, so the file can be pulled via the Files app. Unbuffered, so the
    // message survives the crash.
    if(std::freopen("stderr.log","w",stderr)!=nullptr)
      std::setvbuf(stderr,nullptr,_IONBF,0);
  }
#endif

  try {
    static Tempest::WFile logFile("log.txt");
    Tempest::Log::setOutputCallback([](Tempest::Log::Mode mode, const char* text) {
      logFile.write(text,std::strlen(text));
      logFile.write("\n",1);
      // Diagnostic device runs are evidence-producing builds: make every
      // marker visible while the app is still alive. Production keeps the
      // cheaper error-only flush policy.
      if(shouldFlushLogLine(mode))
        logFile.flush();
      });
    }
  catch(...) {
    Tempest::Log::e("unable to setup logfile - fallback to console log");
    }
  CrashLog::setup();

  zenkit::Logger::set(zenkit::LogLevel::INFO, [] (zenkit::LogLevel lvl, const char* cat, const char* message) {
    (void)cat;
    switch (lvl) {
      case zenkit::LogLevel::ERROR:
        Tempest::Log::e("[zenkit] ", message);
        break;
      case zenkit::LogLevel::WARNING:
        Tempest::Log::e("[zenkit] ", message);
        break;
      case zenkit::LogLevel::INFO:
        Tempest::Log::i("[zenkit] ", message);
        break;
      case zenkit::LogLevel::DEBUG:
      case zenkit::LogLevel::TRACE:
        Tempest::Log::d("[zenkit] ", message); // unused
        break;
      }
    });
  Dm_setLogger(DmLogLevel_INFO, [](void* ctx, DmLogLevel lvl, char const* msg) {
    switch (lvl) {
      case DmLogLevel_FATAL:
      case DmLogLevel_ERROR:
      case DmLogLevel_WARN:
        Tempest::Log::e("[dmusic] ", msg);
        break;
      case DmLogLevel_INFO:
        Tempest::Log::i("[dmusic] ", msg);
        break;
      case DmLogLevel_DEBUG:
      case DmLogLevel_TRACE:
        Tempest::Log::d("[dmusic] ", msg);
        break;
      }
    }, nullptr);

  Tempest::Log::i(appBuild);
  Workers::setThreadName("Main thread");

  try {
    AudioSession::activate();   // configure the iOS audio session before any SoundDevice

    CommandLine          cmd{argc,argv};
#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    const auto pipelineArchiveTestMode =
      RendererIOSPipelineArchive::parseTestMode(argc,argv);
    if(pipelineArchiveTestMode.conflict)
      throw std::runtime_error(
        "conflicting RendererIOS pipeline archive test modes");
    if(pipelineArchiveTestMode.duplicate)
      throw std::runtime_error(
        "duplicate RendererIOS pipeline archive test mode");
    if(pipelineArchiveTestMode.unknown)
      throw std::runtime_error(
        "unknown RendererIOS pipeline archive test mode");
#endif
    auto                 api     = mkApi(
      cmd
#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      ,pipelineArchiveTestMode.mode
#endif
      );
    const auto           gpuName = selectDevice(*api);
    CrashLog::setGpu(gpuName);

    Tempest::Device      device{*api,gpuName};
    CrashLog::setGpu(device.properties().name);
#if defined(__IOS__)
    Tempest::Log::i(
        "RendererIOS builtin shader library: source=offline-metallib resource=",
        RendererIOSShader::LibraryName,".metallib abi=",
        RendererIOSShader::AbiVersion,
        " manifest=",RendererIOSBuiltinShader::ManifestVersion,
        " fail-closed=1");
    Tempest::Log::i(
        "RendererIOS inventory shader manifest: resource=",
        RendererIOSShader::LibraryName,".metallib abi=",
        RendererIOSShader::AbiVersion,
        " manifest=",RendererIOSInventoryShader::ManifestVersion,
        " exact-spirv=1 configured=1 fail-closed=1");
#endif

    Resources            resources{device};
    Gothic               gothic;
    GameMusic            music;
    gothic.setupGlobalScripts();

    MainWindow           wx(device);
    Tempest::Application app;
    return app.exec();
    }
  catch(const GothicNotFoundException& e) {
    // Missing game data: this is thrown from CommandLine, before the window
    // exists, so it is safe to keep a run-loop alive for the alert on iOS.
    Tempest::Log::e("fatal: ", e.what());
    SystemMsg::fatal("Gothic II data not found",
                     "Copy your Gothic II: NotR files (Data/, _work/, system/) "
                     "into this app's Documents folder, then relaunch.");
#if defined(__IOS__)
    // Keep the process alive so the alert stays visible on screen.
    Tempest::Application app;
    return app.exec();
#else
    return 1;
#endif
    }
  catch(const std::exception& e) {
    // Any other failure may have happened after the window was created and is
    // being torn down by stack-unwinding. Do NOT spin up a second Application
    // over a half-destroyed window (would drive render on a dangling pointer —
    // see review B7); just report and exit.
    Tempest::Log::e("fatal: ", e.what());
    SystemMsg::fatal("Fatal error", e.what());
    return 1;
    }
  }
