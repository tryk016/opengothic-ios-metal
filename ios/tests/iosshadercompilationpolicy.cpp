#include "graphics/shadercompilationpolicy.h"

#include <cassert>
#include <cstdint>
#include <limits>
#include <type_traits>

int main() {
  static_assert(std::is_enum_v<ShaderCompilationProfile>);
  static_assert(shaderProfileAllowsMaterialPipelines(
      ShaderCompilationProfile::LegacyRenderer));
  static_assert(!shaderProfileAllowsMaterialPipelines(
      ShaderCompilationProfile::RendererIOSBridge));
  static_assert(std::is_trivially_copyable_v<SourceOnlyDrawCommandKey>);

  constexpr auto first =
    sourceOnlyDrawCommandKey(1u,2u,false,17u);
  constexpr auto same =
    sourceOnlyDrawCommandKey(1u,2u,false,17u);
  constexpr auto otherType =
    sourceOnlyDrawCommandKey(2u,2u,false,17u);
  constexpr auto otherAlpha =
    sourceOnlyDrawCommandKey(1u,3u,false,17u);
  constexpr auto otherBucket =
    sourceOnlyDrawCommandKey(1u,2u,false,18u);
  static_assert(first==same);
  static_assert(first!=otherType);
  static_assert(first!=otherAlpha);
  static_assert(first!=otherBucket);

  constexpr auto bindlessA =
    sourceOnlyDrawCommandKey(1u,2u,true,17u);
  constexpr auto bindlessB =
    sourceOnlyDrawCommandKey(1u,2u,true,18u);
  static_assert(bindlessA==bindlessB);
  static_assert(bindlessA.bucketId==
                std::numeric_limits<uint32_t>::max());

  assert(first.bucketId==17u);
  return 0;
  }
