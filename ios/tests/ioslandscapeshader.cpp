#include "graphics/ioslandscapeshaderabi.h"
#include "graphics/iosgpusceneplan.h"

#include <array>
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
  return float4(texel.rgb*in.color.rgb,1.0);
})";
}

bool validLandscapeSource(std::string_view rawSource) {
  const std::string source = stripComments(rawSource);
  if(source.empty() ||
     countWord(source,"vertex")!=1u ||
     countWord(source,"fragment")!=2u ||
     countWord(source,"kernel")!=0u ||
     countOccurrences(source,RendererIOSShader::VertexFunction)!=1u ||
     countOccurrences(source,RendererIOSShader::FragmentFunction)!=1u ||
     countOccurrences(source,RendererIOSShader::AlphaTestFragmentFunction)!=1u)
    return false;

  const auto vertex = extractFunction(
      source,"vertex",RendererIOSShader::VertexFunction);
  const auto fragment = extractFunction(
      source,"fragment",RendererIOSShader::FragmentFunction);
  const auto alphaTest = extractFunction(
      source,"fragment",RendererIOSShader::AlphaTestFragmentFunction);
  if(!vertex || !fragment || !alphaTest)
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
  out.uv = in.uv;
  return out;
})";
  constexpr std::string_view ExpectedFragment = R"(
fragment float4 riosLandscapeFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float, access::sample> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  return float4(texel.rgb*in.color.rgb,1.0);
})";
  if(compact(*vertex)!=compact(ExpectedVertex) ||
     compact(*fragment)!=compact(ExpectedFragment) ||
     compact(*alphaTest)!=compact(expectedAlphaTestFunction()))
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

std::string eraseAlphaTestFunction(std::string source) {
  const std::string declaration =
      std::string("fragment float4 ")+std::string(AlphaTestFunctionName);
  const size_t start = source.find(declaration);
  const size_t brace = source.find('{',start);
  if(start==std::string::npos || brace==std::string::npos)
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
  const std::array<std::string,17> mutations = {
    eraseAlphaTestFunction(source),
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
        "  return float4(texel.rgb*in.color.rgb,1.0);",
        "  return float4(texel.rgb*in.color.rgb,1.0);\n"
        "  if(texel.a<0.5)\n"
        "    discard_fragment();"),
    replaceLastOnce(
        source,
        "return float4(texel.rgb*in.color.rgb,1.0);",
        "return float4(texel.rgb+in.color.rgb,1.0);"),
    replaceLastOnce(
        source,
        "return float4(texel.rgb*in.color.rgb,1.0);",
        "return float4(texel.rgb*in.color.rgb,in.color.a);"),
    source+"\nnewLibraryWithSource\n",
    source+"\n"+*alphaTest+"\n",
    replaceOnce(source,"clip.y = -clip.y;","clip.y = clip.y;"),
    replaceLastOnce(
        source,
        "return float4(texel.rgb*in.color.rgb,1.0);",
        "return float4(texel.rgb*in.color.rgb,0.0);"),
  };
  for(const std::string& mutation:mutations)
    if(mutation.empty() || validLandscapeSource(mutation))
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
    {"ios/tests/ioslandscapeshader.cpp",4u},
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

}

int main(int argc, char** argv) {
  if(argc!=3 ||
     RendererIOSShader::AbiVersion!=6u ||
     RendererIOSShader::AlphaTestFragmentFunction!=AlphaTestFunctionName)
    return 1;

  const auto source = readFile(argv[1]);
  if(!source)
    return 2;
  if(!validLandscapeSource(*source))
    return 3;
  if(!mutationsAreRejected(*source))
    return 4;
  if(!symbolAllowlistMatches(argv[2]))
    return 5;

  static_assert(IOSLandscapeVertexStride==36u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,viewProjection)==0u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,model)==64u);
  static_assert(offsetof(IOSGPUSceneDrawConstants,baseColor)==128u);
  static_assert(sizeof(IOSGPUSceneDrawConstants)==144u);
  static_assert(alignof(IOSGPUSceneDrawConstants)==16u);
  return 0;
  }
