#include "graphics/ioslandscapeshaderabi.h"
#include "graphics/iosgpusceneplan.h"

#include <array>
#include <bit>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <optional>
#include <string>
#include <string_view>

namespace {

constexpr std::string_view AlphaTestFunctionName =
    "riosLandscapeAlphaTestFragment";

std::optional<std::string> readFile(const std::filesystem::path& path) {
  std::ifstream input(path,std::ios::binary);
  if(!input)
    return std::nullopt;
  std::string contents((std::istreambuf_iterator<char>(input)),
                       std::istreambuf_iterator<char>());
  if(!input.good() && !input.eof())
    return std::nullopt;
  return contents;
}

std::string stripComments(std::string_view source) {
  enum class State : uint8_t {
    Source,
    LineComment,
    BlockComment,
    };
  State state = State::Source;
  std::string stripped;
  stripped.reserve(source.size());
  for(size_t i=0u; i<source.size(); ++i) {
    const char ch = source[i];
    const char next = i+1u<source.size() ? source[i+1u] : '\0';
    if(state==State::Source && ch=='/' && next=='/') {
      state = State::LineComment;
      stripped += "  ";
      ++i;
      continue;
      }
    if(state==State::Source && ch=='/' && next=='*') {
      state = State::BlockComment;
      stripped += "  ";
      ++i;
      continue;
      }
    if(state==State::LineComment) {
      if(ch=='\n') {
        state = State::Source;
        stripped += ch;
        }
      else {
        stripped += ' ';
        }
      continue;
      }
    if(state==State::BlockComment) {
      if(ch=='*' && next=='/') {
        state = State::Source;
        stripped += "  ";
        ++i;
        }
      else {
        stripped += ch=='\n' ? '\n' : ' ';
        }
      continue;
      }
    stripped += ch;
    }
  return state==State::BlockComment ? std::string() : stripped;
}

std::string compact(std::string_view text) {
  std::string normalized;
  normalized.reserve(text.size());
  for(const char ch:text)
    if(std::isspace(static_cast<unsigned char>(ch))==0)
      normalized += ch;
  return normalized;
}

size_t countOccurrences(std::string_view text, std::string_view token) {
  if(token.empty())
    return 0u;
  size_t count = 0u;
  size_t offset = 0u;
  while((offset=text.find(token,offset))!=std::string_view::npos) {
    ++count;
    offset += token.size();
    }
  return count;
}

bool isIdentifier(char ch) {
  const auto value = static_cast<unsigned char>(ch);
  return std::isalnum(value)!=0 || ch=='_';
}

size_t countWord(std::string_view text, std::string_view word) {
  size_t count = 0u;
  size_t offset = 0u;
  while((offset=text.find(word,offset))!=std::string_view::npos) {
    const bool left = offset==0u || !isIdentifier(text[offset-1u]);
    const size_t rightOffset = offset+word.size();
    const bool right =
        rightOffset==text.size() || !isIdentifier(text[rightOffset]);
    if(left && right)
      ++count;
    offset = rightOffset;
    }
  return count;
}

std::optional<std::string> extractFunction(
    std::string_view source, std::string_view stage,
    std::string_view functionName) {
  const size_t nameOffset = source.find(functionName);
  if(nameOffset==std::string_view::npos ||
     source.find(functionName,nameOffset+functionName.size())!=
       std::string_view::npos)
    return std::nullopt;
  const size_t start = source.rfind(stage,nameOffset);
  const size_t brace = source.find('{',nameOffset+functionName.size());
  if(start==std::string_view::npos || brace==std::string_view::npos)
    return std::nullopt;
  size_t depth = 0u;
  for(size_t offset=brace; offset<source.size(); ++offset) {
    if(source[offset]=='{')
      ++depth;
    else if(source[offset]=='}') {
      if(depth==0u)
        return std::nullopt;
      --depth;
      if(depth==0u)
        return std::string(source.substr(start,offset-start+1u));
      }
    }
  return std::nullopt;
}

std::string expectedAlphaTestFunction() {
  return std::string("fragment float4 ")+
      std::string(AlphaTestFunctionName)+R"(
(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float, access::sample> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  if(texel.a<0.5)
    discard_fragment();
  const float3 currentLdrRgb = texel.rgb*in.color.rgb;
  return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);
})";
}

bool validLandscapeSource(std::string_view rawSource) {
  const std::string source = stripComments(rawSource);
  if(source.empty() ||
     countWord(source,"vertex")!=2u ||
     countWord(source,"fragment")!=3u ||
     countWord(source,"kernel")!=0u ||
     countOccurrences(source,RendererIOSShader::VertexFunction)!=1u ||
     countOccurrences(source,RendererIOSShader::FragmentFunction)!=1u ||
     countOccurrences(source,RendererIOSShader::AlphaTestFragmentFunction)!=1u ||
     countOccurrences(source,RendererIOSShader::ToneResolveVertexFunction)!=1u ||
     countOccurrences(source,RendererIOSShader::ToneResolveFragmentFunction)!=1u)
    return false;

  const auto vertex = extractFunction(
      source,"vertex",RendererIOSShader::VertexFunction);
  const auto fragment = extractFunction(
      source,"fragment",RendererIOSShader::FragmentFunction);
  const auto alphaTest = extractFunction(
      source,"fragment",RendererIOSShader::AlphaTestFragmentFunction);
  const auto toneVertex = extractFunction(
      source,"vertex",RendererIOSShader::ToneResolveVertexFunction);
  const auto toneFragment = extractFunction(
      source,"fragment",RendererIOSShader::ToneResolveFragmentFunction);
  if(!vertex || !fragment || !alphaTest || !toneVertex || !toneFragment)
    return false;

  constexpr std::string_view ExpectedDrawConstants = R"(
struct IOSLandscapeDrawConstants {
  float4x4 viewProjection;
  float4x4 model;
  float4   baseColor;
  float2   uvOffset;
})";
  if(countOccurrences(compact(source),compact(ExpectedDrawConstants))!=1u)
    return false;

  constexpr std::string_view ExpectedToneConstants = R"(
struct alignas(16) IOSToneResolveConstants {
  float brightness;
  float contrast;
  float gamma;
  float exposure;
})";
  constexpr std::string_view ExpectedToneHelpers = R"(
static float3 riosInverseAcesToneMap(float3 color) {
  return (-0.59*color+0.03-
          sqrt(-1.0127*color*color+1.3702*color+0.0009))/
         (2.0*(2.43*color-2.51));
}

static float3 riosLiftLegacyLdrToScene(float3 color) {
  const float3 encoded = clamp(color,0.0,1.0);
  const float3 linear = pow(encoded,float3(2.2));
  return riosInverseAcesToneMap(linear);
}

static float3 riosAcesToneMap(float3 color) {
  return clamp(
      (color*(2.51*color+0.03))/(color*(2.43*color+0.59)+0.14),
      0.0,1.0);
}

static float riosInterleavedGradientNoise(float2 pixel) {
  return fract(52.9829189*fract(
      0.06711056*pixel.x+0.00583715*pixel.y));
})";
  if(countOccurrences(compact(source),compact(ExpectedToneConstants))!=1u ||
     countOccurrences(compact(source),compact(ExpectedToneHelpers))!=1u ||
     countOccurrences(
         compact(source),
         "static_assert(sizeof(IOSToneResolveConstants)==16,"
         "\"IOSToneResolveConstantssizedrifted\");")!=1u ||
     countOccurrences(
         compact(source),
         "static_assert(alignof(IOSToneResolveConstants)==16,"
         "\"IOSToneResolveConstantsalignmentdrifted\");")!=1u)
    return false;

  constexpr std::string_view ExpectedVertex = R"(
vertex IOSLandscapeVertexOut riosLandscapeVertex(
    IOSLandscapeVertexIn in [[stage_in]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]]) {
  IOSLandscapeVertexOut out;
  const float4 world = draw.model*float4(in.position,1.0);
  float4 clip = draw.viewProjection*world;
  clip.y = -clip.y;
  out.position = clip;
  out.color = in.color*draw.baseColor;
  out.uv = in.uv + draw.uvOffset;
  return out;
})";
  constexpr std::string_view ExpectedFragment = R"(
fragment float4 riosLandscapeFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float, access::sample> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  const float3 currentLdrRgb = texel.rgb*in.color.rgb;
  return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);
})";
  constexpr std::string_view ExpectedToneVertex = R"(
vertex IOSToneResolveVertexOut riosToneResolveVertex(
    uint vertexId [[vertex_id]]) {
  constexpr float2 positions[3] = {
    float2(-1.0,-1.0),
    float2( 3.0,-1.0),
    float2(-1.0, 3.0),
  };
  IOSToneResolveVertexOut out;
  out.position = float4(positions[vertexId],0.0,1.0);
  return out;
})";
  constexpr std::string_view ExpectedToneFragment = R"(
fragment float4 riosToneResolveFragment(
    IOSToneResolveVertexOut in [[stage_in]],
    texture2d<float, access::read> hdr [[texture(0)]],
    constant IOSToneResolveConstants& constants [[buffer(0)]]) {
  const uint2 pixel = uint2(in.position.xy);
  float3 color = hdr.read(pixel).rgb;
  color *= constants.exposure;
  color = max(float3(0.0),color+constants.brightness)*constants.contrast;
  color = riosAcesToneMap(color);
  color = pow(color,float3(constants.gamma));
  const float noise = riosInterleavedGradientNoise(in.position.xy);
  const float dither = ((noise*2.0)-1.0)/255.0;
  color += float3(dither);
  return float4(color,1.0);
})";
  if(compact(*vertex)!=compact(ExpectedVertex) ||
     compact(*fragment)!=compact(ExpectedFragment) ||
     compact(*alphaTest)!=compact(expectedAlphaTestFunction()) ||
     compact(*toneVertex)!=compact(ExpectedToneVertex) ||
     compact(*toneFragment)!=compact(ExpectedToneFragment))
    return false;

  constexpr std::array<std::string_view,3> RuntimeCompilationTokens = {
    "newLibraryWithSource","compileSource","MTLCompileOptions",
  };
  for(const std::string_view token:RuntimeCompilationTokens)
    if(source.find(token)!=std::string::npos)
      return false;
  return true;
}

std::string replaceOnce(
    std::string source, std::string_view from, std::string_view to) {
  const size_t offset = source.find(from);
  if(offset==std::string::npos ||
     source.find(from,offset+from.size())!=std::string::npos)
    return {};
  source.replace(offset,from.size(),to);
  return source;
}

std::string replaceLastOnce(
    std::string source, std::string_view from, std::string_view to) {
  const size_t offset = source.rfind(from);
  if(offset==std::string::npos)
    return {};
  source.replace(offset,from.size(),to);
  return source;
}

std::string eraseFunction(
    std::string source, std::string_view declaration) {
  const size_t start = source.find(declaration);
  if(start==std::string::npos ||
     source.find(declaration,start+declaration.size())!=std::string::npos)
    return {};
  const size_t brace = source.find('{',start);
  if(brace==std::string::npos)
    return {};
  size_t depth = 0u;
  for(size_t offset=brace; offset<source.size(); ++offset) {
    if(source[offset]=='{')
      ++depth;
    else if(source[offset]=='}') {
      --depth;
      if(depth==0u) {
        source.erase(start,offset-start+1u);
        return source;
        }
      }
    }
  return {};
}

bool mutationsAreRejected(const std::string& source) {
  const auto alphaTest = extractFunction(
      stripComments(source),"fragment",AlphaTestFunctionName);
  if(!alphaTest)
    return false;
  const std::string alphaDeclaration =
      std::string("fragment float4 ")+std::string(AlphaTestFunctionName);
  const std::array<std::string,19> landscapeMutations = {
    eraseFunction(source,alphaDeclaration),
    replaceOnce(source,"    discard_fragment();",""),
    replaceOnce(source,"if(texel.a<0.5)","if(texel.a<=0.5)"),
    replaceOnce(source,"if(texel.a<0.5)","if(texel.a<0.4)"),
    replaceOnce(
        source,"if(texel.a<0.5)","if(texel.a*in.color.a<0.5)"),
    replaceLastOnce(source,"[[texture(0)]]","[[texture(1)]]"),
    replaceLastOnce(source,"[[sampler(0)]]","[[sampler(1)]]"),
    replaceLastOnce(
        source,
        "  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);\n"
        "  if(texel.a<0.5)",
        "  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);\n"
        "  const float4 second = baseColorTexture.sample(baseColorSampler,in.uv);\n"
        "  if(texel.a+second.a<0.5)"),
    replaceOnce(
        source,
        "  if(texel.a<0.5)\n"
        "    discard_fragment();",
        "  discard_fragment();"),
    replaceOnce(
        source,"if(texel.a<0.5)","if(false && texel.a<0.5)"),
    replaceOnce(
        source,
        "  if(texel.a<0.5)\n"
        "    discard_fragment();\n"
        "  const float3 currentLdrRgb = texel.rgb*in.color.rgb;\n"
        "  return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);",
        "  const float3 currentLdrRgb = texel.rgb*in.color.rgb;\n"
        "  return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);\n"
        "  if(texel.a<0.5)\n"
        "    discard_fragment();"),
    replaceLastOnce(
        source,
        "return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);",
        "return float4(currentLdrRgb,1.0);"),
    replaceLastOnce(
        source,
        "return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);",
        "return float4(riosLiftLegacyLdrToScene(currentLdrRgb),in.color.a);"),
    source+"\nnewLibraryWithSource\n",
    source+"\n"+*alphaTest+"\n",
    replaceOnce(source,"clip.y = -clip.y;","clip.y = clip.y;"),
    replaceOnce(source,"  float2   uvOffset;","  float4   uvOffset;"),
    replaceOnce(
        source,"out.uv = in.uv + draw.uvOffset;","out.uv = in.uv;"),
    replaceLastOnce(
        source,
        "return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);",
        "return float4(riosLiftLegacyLdrToScene(currentLdrRgb),0.0);"),
  };
  for(const std::string& mutation:landscapeMutations)
    if(mutation.empty() || validLandscapeSource(mutation))
      return false;

  const std::array<std::string,26> toneMutations = {
    eraseFunction(source,"vertex IOSToneResolveVertexOut riosToneResolveVertex"),
    eraseFunction(source,"fragment float4 riosToneResolveFragment"),
    replaceOnce(source,"struct alignas(16) IOSToneResolveConstants",
                       "struct IOSToneResolveConstants"),
    replaceOnce(source,"  float brightness;","  half brightness;"),
    replaceOnce(source,"  float contrast;","  float exposure;"),
    replaceOnce(source,"alignof(IOSToneResolveConstants)==16",
                       "alignof(IOSToneResolveConstants)==4"),
    replaceOnce(source,"uint vertexId [[vertex_id]]",
                       "uint vertexId [[instance_id]]"),
    replaceOnce(source,"uint vertexId [[vertex_id]]) {",
                       "uint vertexId [[vertex_id]], "
                       "constant uint& forbidden [[buffer(0)]]) {"),
    replaceOnce(source,"float2(-1.0,-1.0)","float2(-1.0,1.0)"),
    replaceOnce(source,"float2( 3.0,-1.0)","float2(1.0,-1.0)"),
    replaceOnce(source,"float2(-1.0, 3.0)","float2(-1.0,1.0)"),
    replaceOnce(source,"float4(positions[vertexId],0.0,1.0)",
                       "float4(positions[vertexId],1.0,1.0)"),
    replaceOnce(source,"texture2d<float, access::read> hdr [[texture(0)]]",
                       "texture2d<float, access::sample> hdr [[texture(0)]]"),
    replaceOnce(source,
                       "constant IOSToneResolveConstants& constants "
                       "[[buffer(0)]]) {",
                       "constant IOSToneResolveConstants& constants "
                       "[[buffer(0)]], sampler forbidden [[sampler(0)]]) {"),
    replaceLastOnce(source,"[[texture(0)]]","[[texture(1)]]"),
    replaceOnce(source,"constants [[buffer(0)]]","constants [[buffer(1)]]"),
    replaceOnce(source,"const uint2 pixel = uint2(in.position.xy);",
                       "const uint2 pixel = uint2(in.position.yx);"),
    replaceOnce(source,"float3 color = hdr.read(pixel).rgb;",
                       "float3 color = hdr.read(pixel+1u).rgb;"),
    replaceOnce(source,"  color *= constants.exposure;",""),
    replaceOnce(source,"max(float3(0.0),color+constants.brightness)",
                       "max(float3(0.0),color-constants.brightness)"),
    replaceOnce(source,"2.51*color+0.03","2.50*color+0.03"),
    replaceOnce(source,"color = pow(color,float3(constants.gamma));",
                       "color = pow(color,float3(1.0));"),
    replaceOnce(source,"52.9829189","52.9829180"),
    replaceOnce(source,"0.00583715*pixel.y","0.00583715*pixel.x"),
    replaceOnce(source,"/255.0;","/256.0;"),
    replaceLastOnce(source,"return float4(color,1.0);",
                           "return float4(color,0.0);"),
  };
  for(const std::string& mutation:toneMutations)
    if(mutation.empty() || validLandscapeSource(mutation))
      return false;
  if(!validLandscapeSource(
       source+"\n// newLibraryWithSource MTLCompileOptions\n"))
    return false;
  return true;
}

bool symbolAllowlistMatches(const std::filesystem::path& repository) {
  const std::map<std::string,size_t> expectedSymbols = {
    {"shader/ios-metal/landscape.metal",1u},
    {"game/graphics/ioslandscapeshaderabi.h",1u},
    {"ios/tests/ioslandscapeshader.cpp",1u},
    {"scripts/verify-local-build.command",2u},
    {"scripts/ci_contracts.command",2u},
    {"scripts/ci_build_profile.command",1u},
    {"ios/tests/test_ci_verification.py",1u},
  };
  const std::map<std::string,size_t> expectedAbiReferences = {
    {"game/graphics/ioslandscapeshaderabi.h",1u},
    {"game/graphics/iosgpuscene.mm",2u},
    {"ios/tests/ioslandscapeshader.cpp",4u},
    {"scripts/verify-local-build.command",1u},
    {"scripts/ci_contracts.command",1u},
  };
  constexpr std::string_view AlphaTestAbiIdentifier =
      "AlphaTestFragmentFunction";
  std::map<std::string,size_t> actualSymbols;
  std::map<std::string,size_t> actualAbiReferences;
  constexpr std::array<std::string_view,4> PublicRoots = {
    "game","shader","ios","scripts",
  };
  for(const std::string_view root:PublicRoots) {
    std::error_code error;
    std::filesystem::recursive_directory_iterator iterator(
        repository/std::string(root),
        std::filesystem::directory_options::skip_permission_denied,
        error);
    const std::filesystem::recursive_directory_iterator end;
    if(error)
      return false;
    while(iterator!=end) {
      if(iterator->is_symlink(error)) {
        if(error)
          return false;
        if(iterator->is_directory(error))
          iterator.disable_recursion_pending();
        if(error)
          return false;
      }
      else if(iterator->is_regular_file(error)) {
        if(error)
          return false;
        const auto contents = readFile(iterator->path());
        if(!contents)
          return false;
        const size_t count =
            countOccurrences(*contents,AlphaTestFunctionName);
        if(count!=0u) {
          const auto relative =
              std::filesystem::relative(iterator->path(),repository,error);
          if(error)
            return false;
          actualSymbols[relative.generic_string()] = count;
          }
        const size_t abiReferenceCount =
            countOccurrences(*contents,AlphaTestAbiIdentifier);
        if(abiReferenceCount!=0u) {
          const auto relative =
              std::filesystem::relative(iterator->path(),repository,error);
          if(error)
            return false;
          actualAbiReferences[relative.generic_string()] = abiReferenceCount;
          }
      }
      else if(error) {
        return false;
      }
      iterator.increment(error);
      if(error)
        return false;
      }
    }
  return actualSymbols==expectedSymbols &&
         actualAbiReferences==expectedAbiReferences;
}

bool runtimeReflectionContractMatches(
    const std::filesystem::path& repository) {
  const auto runtime = readFile(
      repository/"game/graphics/iosgpuscene.mm");
  if(!runtime)
    return false;
  const std::string source = compact(stripComments(*runtime));
  if(source.empty())
    return false;

  constexpr std::string_view ReflectionOptions =
      "options:(MTLPipelineOptionBindingInfo|"
      "MTLPipelineOptionBufferTypeInfo)";
  return countOccurrences(source,ReflectionOptions)==2u &&
      countOccurrences(source,"reflection:&opaquePipelineReflection")==1u &&
      countOccurrences(source,"reflection:&alphaTestPipelineReflection")==1u &&
      countOccurrences(
          source,"drawConstantsReflectionMatches(opaquePipelineReflection)")==
          1u &&
      countOccurrences(
          source,
          "drawConstantsReflectionMatches(alphaTestPipelineReflection)")==1u &&
      countOccurrences(source,"binding.index!=NSUInteger(1u)")==1u &&
      countOccurrences(source,"!binding.used")==1u &&
      countOccurrences(source,"!binding.argument")==1u &&
      countOccurrences(source,"binding.type!=MTLBindingTypeBuffer")==1u &&
      countOccurrences(
          source,
          "buffer.bufferDataSize!=sizeof(IOSGPUSceneDrawConstants)")==1u &&
      countOccurrences(
          source,
          "buffer.bufferAlignment!=alignof(IOSGPUSceneDrawConstants)")==1u;
}

bool runtimeUVAnimationEvidenceContractMatchesSources(
    std::string_view sceneRuntime,
    std::string_view contextHeader,
    std::string_view contextRuntime) {
  const std::string scene = compact(stripComments(sceneRuntime));
  const std::string header = compact(stripComments(contextHeader));
  const std::string contextSource = stripComments(contextRuntime);
  const std::string context = compact(contextSource);
  const auto submitFrame = extractFunction(
      contextSource,"IOSMetalContext::SubmitResult",
      "IOSMetalContext::submitFrame(");
  if(scene.empty() || header.empty() || context.empty() || !submitFrame)
    return false;
  const std::string submit = compact(*submitFrame);
  constexpr std::string_view LegacyCompletionScopeEnd =
      "InventoryMenu*inventoryOwner=nullptr;";
  const size_t legacyCompletionScopeEnd =
      submit.find(LegacyCompletionScopeEnd);
  if(legacyCompletionScopeEnd==std::string::npos ||
     submit.find(LegacyCompletionScopeEnd,
                 legacyCompletionScopeEnd+LegacyCompletionScopeEnd.size())!=
       std::string::npos)
    return false;
  const std::string_view legacyCompletionScope(
      submit.data(),legacyCompletionScopeEnd);

  return countOccurrences(
             scene,
             "recordIOSGPUSceneUVAnimationDraw("
             "*context.uvAnimation,draw.plan)")==1u &&
      countOccurrences(
          scene,
          "recordIOSGPUSceneUVAnimationDraw("
          "*context.uvAnimation,plan)")==1u &&
      countOccurrences(
          scene,"finalizeIOSGPUSceneUVAnimationDrawReport(")==3u &&
      countOccurrences(
          scene,
          "context.uvAnimation="
          "trackUVAnimation?&uvAnimationTracker:nullptr;")==1u &&
      countOccurrences(
          header,
          "void*,bool,constIOSGPUSceneFrameAnimationDrawReport*,"
          "constIOSGPUSceneUVAnimationDrawReport*)noexcept;")==1u &&
      countOccurrences(
          legacyCompletionScope,
          "completeFrame(completion,false,nullptr,nullptr)")==4u &&
      countOccurrences(
          context,"frameAnimation,uvAnimation);")==1u &&
      countOccurrences(
          context,"uvAnimationDrawn=report.uvAnimation;")==1u &&
      countOccurrences(
          context,
          "uvAnimationDrawnReady?&uvAnimationDrawn:nullptr")==1u;
}

bool runtimeUVAnimationEvidenceContractMatches(
    const std::filesystem::path& repository) {
  const auto sceneRuntime = readFile(
      repository/"game/graphics/iosgpuscene.mm");
  const auto contextHeader = readFile(
      repository/"game/graphics/iosmetalcontext.h");
  const auto contextRuntime = readFile(
      repository/"game/graphics/iosmetalcontext.cpp");
  if(!sceneRuntime || !contextHeader || !contextRuntime ||
     !runtimeUVAnimationEvidenceContractMatchesSources(
       *sceneRuntime,*contextHeader,*contextRuntime))
    return false;

  constexpr std::string_view LegacyInactiveCompletion =
      "  if(impl->lifecycleState!=Impl::LifecycleState::Active) {\n"
      "    cancelFrame(frame.serial);\n"
      "    (void)completeFrame(completion,false,nullptr,nullptr);\n"
      "    return {};\n"
      "    }";
  constexpr std::string_view MutatedInactiveCompletion =
      "  if(impl->lifecycleState!=Impl::LifecycleState::Active) {\n"
      "    cancelFrame(frame.serial);\n"
      "    (void)completeFrame(completion,true,nullptr,nullptr);\n"
      "    return {};\n"
      "    }";
  constexpr std::string_view CommentOnlyInactiveCompletion =
      "  if(impl->lifecycleState!=Impl::LifecycleState::Active) {\n"
      "    cancelFrame(frame.serial);\n"
      "    // (void)completeFrame(completion,false,nullptr,nullptr);\n"
      "    return {};\n"
      "    }";
  const std::string semanticMutation = replaceOnce(
      *contextRuntime,LegacyInactiveCompletion,MutatedInactiveCompletion);
  const std::string commentOnlyMutation = replaceOnce(
      *contextRuntime,LegacyInactiveCompletion,CommentOnlyInactiveCompletion);
  return !semanticMutation.empty() && !commentOnlyMutation.empty() &&
      !runtimeUVAnimationEvidenceContractMatchesSources(
        *sceneRuntime,*contextHeader,semanticMutation) &&
      !runtimeUVAnimationEvidenceContractMatchesSources(
        *sceneRuntime,*contextHeader,commentOnlyMutation);
}

}

int main(int argc, char** argv) {
  if(argc!=3 ||
     RendererIOSShader::AbiVersion!=8u ||
     RendererIOSShader::AlphaTestFragmentFunction!=AlphaTestFunctionName ||
     RendererIOSShader::ToneResolveVertexFunction!=
         "riosToneResolveVertex" ||
     RendererIOSShader::ToneResolveFragmentFunction!=
         "riosToneResolveFragment")
    return 1;

  const auto source = readFile(argv[1]);
  if(!source)
    return 2;
  if(!validLandscapeSource(*source))
    return 3;
  if(!mutationsAreRejected(*source))
    return 4;
  if(!runtimeReflectionContractMatches(argv[2]))
    return 5;
  if(!runtimeUVAnimationEvidenceContractMatches(argv[2]))
    return 6;
  if(!symbolAllowlistMatches(argv[2]))
    return 7;

  static_assert(IOSLandscapeVertexStride==36u);
  static_assert(sizeof(IOSFloat2)==8u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,viewProjection)==0u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,model)==64u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,baseColor)==128u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,uvOffset)==144u);
  static_assert(sizeof(IOSGPUSceneDrawConstants)==160u);
  static_assert(alignof(IOSGPUSceneDrawConstants)==16u);
  static_assert(RendererIOSShader::ToneResolveTextureIndex==0u);
  static_assert(RendererIOSShader::ToneResolveConstantsBufferIndex==0u);
  static_assert(offsetof(IOSToneResolveConstants,brightness)==0u);
  static_assert(offsetof(IOSToneResolveConstants,contrast)==4u);
  static_assert(offsetof(IOSToneResolveConstants,gamma)==8u);
  static_assert(offsetof(IOSToneResolveConstants,exposure)==12u);
  static_assert(sizeof(IOSToneResolveConstants)==16u);
  static_assert(alignof(IOSToneResolveConstants)==16u);
  constexpr IOSToneResolveConstants DefaultToneResolveConstants;
  static_assert(DefaultToneResolveConstants.brightness==0.0f);
  static_assert(DefaultToneResolveConstants.contrast==1.0f);
  static_assert(DefaultToneResolveConstants.gamma==1.0f/2.2f);
  static_assert(std::bit_cast<uint32_t>(
                    DefaultToneResolveConstants.exposure)==0x3F800000u);
  return 0;
  }
