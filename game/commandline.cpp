#include "commandline.h"

#include <Tempest/Log>
#include <Tempest/TextCodec>
#include <cstring>
#include <cassert>

#if defined(__APPLE__)
#include <filesystem>
#endif

#include <algorithm>

#include "utils/installdetect.h"
#include "utils/fileutil.h"
#include "utils/string_frm.h"

using namespace Tempest;
using namespace FileUtil;

static CommandLine* instance = nullptr;

static const char16_t* toString(ScriptLang lang) {
  switch(lang) {
    case ScriptLang::EN: return u"Scripts_EN";
    case ScriptLang::DE: return u"Scripts_DE";
    case ScriptLang::PL: return u"Scripts_PL";
    case ScriptLang::RU: return u"Scripts_RU";
    case ScriptLang::FR: return u"Scripts_FR";
    case ScriptLang::ES: return u"Scripts_ES";
    case ScriptLang::IT: return u"Scripts_IT";
    case ScriptLang::CZ: return u"Scripts_CZ";
    case ScriptLang::NONE:
      break;
    }
  return u"Scripts";
  }

static bool boolArg(std::string_view v) {
  return std::string_view(v)!="0" && std::string_view(v)!="false";
  }

static int intArg(std::string_view v) {
  if(v=="false")
    return 0;
  return (std::stoi(std::string(v)));
  }

CommandLine::CommandLine(int argc, const char** argv) {
  instance = this;
  if(argc<1)
    return;

#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  size_t iosSemanticSaveArgumentCount = 0;
  bool   iosSemanticSaveArgumentValid = false;
#endif
  std::string_view mod;
  for(int i=1;i<argc;++i) {
    std::string_view arg = argv[i];
    if(arg.find("-game:")==0) {
      if(!mod.empty())
        Log::e("-game specified twice");
      mod = arg.substr(6);
      }
    else if(arg=="-g") {
      ++i;
      if(i<argc)
        gpath.assign(argv[i],argv[i]+std::strlen(argv[i]));
      }
    else if(arg=="-devmode") {
      // http://www.gothic-library.ru/publ/marvin/1-1-0-547
      devmode = true;
      }
    else if(arg=="-save") {
#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      ++iosSemanticSaveArgumentCount;
#endif
      ++i;
      if(i<argc){
#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
        const std::string_view value = argv[i];
        iosSemanticSaveArgumentValid =
          !value.empty() && value.front()>='1' && value.front()<='9' &&
          std::all_of(value.begin()+1,value.end(),[](char ch) {
            return ch>='0' && ch<='9';
            });
#endif
        if(std::strcmp(argv[i],"q")==0) {
          saveDef = "save_slot_0.sav";
          } else {
          saveDef = string_frm("save_slot_",argv[i],".sav");
          }
        }
      }
    else if(arg=="-w") {
      ++i;
      if(i<argc)
        wrldDef = argv[i];
      }
    else if(arg=="-window") {
      isWindow = true;
      }
    else if(arg=="-nomenu") {
      noMenu = true;
      }
    else if(arg=="-benchmark") {
      isBenchmark = Benchmark::Normal;
      if(i+1<argc && argv[i+1][0]!='-') {
        ++i;
        isBenchmark = std::string_view(argv[i])=="ci" ? Benchmark::CiTooling : isBenchmark;
        }
      }
    else if(arg=="-g1") {
      forceG1 = true;
      }
    else if(arg=="-g2c") {
      forceG2 = true;
      }
    else if(arg=="-g2") {
      forceG2NR = true;
      }
    else if(arg=="-dx12") {
      graphics = GraphicBackend::DirectX12;
      }
    else if(arg=="-validation" || arg=="-v") {
      isDebug  = true;
      }
    else if(arg=="-rt") {
      ++i;
      if(i<argc)
        isRQuery = boolArg(argv[i]);
      }
    else if(arg=="-aa") {
      ++i;
      if(i<argc) {
        try {
          const int arg = std::max(0, intArg(argv[i]));
          aaPresetId = std::clamp(uint32_t(arg), 0u, uint32_t(AaPreset::PRESETS_COUNT)-1u);
          }
        catch (const std::exception& e) {
          Log::i("failed to read cmaa2 preset: \"", std::string(argv[i]), "\"");
          }
        }
      }
    else if(arg=="-gi") {
      ++i;
      if(i<argc) {
        const int arg = std::max(0, intArg(argv[i]));
        isGi = GiMethod(std::clamp(arg, 0, GiMethod::Count-1));
        }
      }
    else if(arg=="-ms") {
      ++i;
      if(i<argc)
        isMeshSh = boolArg(argv[i]);
      }
    else if(arg=="-bl") {
      // not to document - debug only
      ++i;
      if(i<argc)
        isBindlessSh = boolArg(argv[i]);
      }
    else if(arg=="-vsm") {
      // not to document - debug only
      ++i;
      if(i<argc)
        isVsm = boolArg(argv[i]);
      }
    else if(arg=="-rtsm") {
      // not to document - debug only
      ++i;
      if(i<argc)
        isRtSm = boolArg(argv[i]);
      }
#if defined(__IOS__)
    else if(arg.find("-renderer-ios-pipeline-archive-")==0u) {
#if !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      throw std::invalid_argument(
        "RendererIOS pipeline archive test mode requires diagnostics");
#endif
      // Diagnostics validates exact values, duplicates and conflicts only
      // after Gothic data validation, before Metal/cache construction.
      }
#endif
#if defined(__IOS__)
    else if(arg.find("-renderer-ios-semantic-script")==0u) {
#if !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      throw std::invalid_argument(
        "RendererIOS semantic script requires diagnostics");
#else
      constexpr std::string_view uiLifecycle =
        "-renderer-ios-semantic-script=save-ui-lifecycle-v1";
      constexpr std::string_view previewFenceSave =
        "-renderer-ios-semantic-script=preview-fence-save-v1";
      if(iosSemanticScript || iosPreviewFenceSaveScript)
        throw std::invalid_argument(
          "duplicate RendererIOS semantic script argument");
      if(arg==uiLifecycle) {
        iosSemanticScript = true;
        }
      else if(arg==previewFenceSave) {
#if !defined(OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID) || \
    OPENGOTHIC_RENDERER_IOS_FAULT_MODE_ID != 3
        throw std::invalid_argument(
          "RendererIOS preview fence save script requires fault mode ID3");
#else
        iosPreviewFenceSaveScript = true;
#endif
        }
      else {
        throw std::invalid_argument(
          "unknown RendererIOS semantic script argument");
        }
#endif
      }
    else if(arg.find("-renderer-ios-semantic-nonce")==0u) {
#if !defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
      throw std::invalid_argument(
        "RendererIOS semantic nonce requires diagnostics");
#else
      constexpr std::string_view prefix = "-renderer-ios-semantic-nonce=";
      if(arg.find(prefix)!=0u)
        throw std::invalid_argument(
          "unknown RendererIOS semantic nonce argument");
      if(!iosSemanticNonce.empty())
        throw std::invalid_argument(
          "duplicate RendererIOS semantic nonce argument");
      const std::string_view value = arg.substr(prefix.size());
      const bool valid = value.size()==32u &&
        std::all_of(value.begin(),value.end(),[](char ch) {
          return (ch>='0' && ch<='9') || (ch>='a' && ch<='f');
          });
      if(!valid)
        throw std::invalid_argument(
          "invalid RendererIOS semantic nonce argument");
      iosSemanticNonce.assign(value);
#endif
      }
#endif
    else {
      Log::i("unreacognized commandline option: \"", arg, "\"");
      }
    }

#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
  if(iosSemanticScript || iosPreviewFenceSaveScript) {
    if(iosSemanticNonce.empty())
      throw std::invalid_argument("missing RendererIOS semantic nonce argument");
    if(iosSemanticSaveArgumentCount!=1u ||
       !iosSemanticSaveArgumentValid || saveDef.empty())
      throw std::invalid_argument(
        "RendererIOS semantic script requires one numeric save argument");
    }
  else if(!iosSemanticNonce.empty()) {
    throw std::invalid_argument(
      "RendererIOS semantic nonce requires semantic script argument");
    }
#endif

#if defined(__IOS__)
  // Most iOS GPUs lack Metal mesh shaders; use the raster fallback by default.
  isMeshSh = false;
#endif

  if(gpath.empty()) {
    InstallDetect inst;
    gpath = inst.detectG2();
#if defined(__APPLE__)
    if(!gpath.empty() && gpath==inst.applicationSupportDirectory()) {
      std::filesystem::current_path(gpath);
      }
#endif
    }

  for(auto& i:gpath)
    if(i=='\\')
      i='/';

  if(gpath.size()>0 && gpath.back()!='/')
    gpath.push_back('/');

  gscript   = nestedPath({u"_work",u"Data",u"Scripts",   u"_compiled"},Dir::FT_Dir);
  gcutscene = nestedPath({u"_work",u"Data",u"Scripts",   u"content",u"CUTSCENE"},Dir::FT_Dir);

  gmod    = TextCodec::toUtf16(mod);
  if(!gmod.empty())
    gmod = nestedPath({u"system",gmod.c_str()},Dir::FT_File);

  if(!validateGothicPath()) {
    if(gpath.empty()) {
      Log::e("Gothic path is not provided. Please use command line argument -g <path>");
      } else {
      Log::e("Invalid gothic path: \"",TextCodec::toUtf8(gpath),"\"");
      }
    throw GothicNotFoundException("gothic not found!"); // TODO: user-friendly message-box
    }
  }

const CommandLine& CommandLine::inst() {
  assert(instance!=nullptr);
  return *instance;
  }

CommandLine::GraphicBackend CommandLine::graphicsApi() const {
  return graphics;
  }

std::u16string_view CommandLine::rootPath() const {
  return gpath;
  }

std::u16string CommandLine::scriptPath() const {
  return gscript;
  }

std::u16string CommandLine::scriptPath(ScriptLang lang) const {
  const char16_t* scripts = toString(lang);
  return nestedPath({u"_work",u"Data",scripts,u"_compiled"},Dir::FT_Dir);
  }

std::u16string CommandLine::cutscenePath() const {
  return gcutscene;
  }

std::u16string CommandLine::cutscenePath(ScriptLang lang) const {
  const char16_t* scripts = toString(lang);
  return nestedPath({u"_work",u"Data",scripts},Dir::FT_Dir);
  }

std::u16string CommandLine::nestedPath(const std::initializer_list<const char16_t*>& name, Tempest::Dir::FileType type) const {
  return FileUtil::nestedPath(gpath, name, type);
  }

bool CommandLine::validateGothicPath() const {
  if(gpath.empty())
    return false;
  if(!FileUtil::exists(gscript))
    return false;
  if(!FileUtil::exists(nestedPath({u"Data"},Dir::FT_Dir)))
    return false;
  if(!FileUtil::exists(nestedPath({u"_work",u"Data"},Dir::FT_Dir)))
    return false;
  return true;
  }
