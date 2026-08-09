#pragma once

#include <cstddef>
#include <cstdint>

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)

#include <array>
#include <filesystem>
#include <string_view>

namespace RendererIOSDeviceIntegrity {

inline constexpr uint32_t SchemaVersion = 1u;
inline constexpr uint64_t MaximumFileCount = 100000u;
inline constexpr uint64_t MaximumTotalBytes = 16ull*1024ull*1024ull*1024ull;
inline constexpr uint64_t MaximumFileBytes = 8ull*1024ull*1024ull*1024ull;

inline constexpr std::string_view ArgumentRoot =
    "-renderer-ios-device-integrity-";
inline constexpr std::string_view ManifestArgument =
    "-renderer-ios-device-integrity-manifest-v1";
inline constexpr std::string_view ResourceManifestFileName =
    "resource-manifest-v1.jsonl";
inline constexpr std::string_view ProtectedSaveManifestFileName =
    "protected-save-manifest-v1.jsonl";
inline constexpr std::string_view TerminalMarker =
    "RendererIOS device integrity manifest: schema=1 "
    "resources=resource-manifest-v1.jsonl "
    "saves=protected-save-manifest-v1.jsonl result=PASS terminal=C";

static_assert(TerminalMarker.size()<255u);

struct ArgumentParseResult final {
  bool requested = false;
  bool duplicate = false;
  bool unknown = false;
  bool invalidVector = false;

  constexpr bool valid() const noexcept {
    return !duplicate && !unknown && !invalidVector;
    }
  };

constexpr ArgumentParseResult parseArguments(
    int argc, const char* const* argv) noexcept {
  ArgumentParseResult result;
  if(argc<0 || (argc>0 && argv==nullptr)) {
    result.invalidVector = true;
    return result;
    }
  unsigned requested = 0u;
  for(int index=0; index<argc; ++index) {
    if(argv[index]==nullptr) {
      result.invalidVector = true;
      return result;
      }
    const std::string_view argument(argv[index]);
    if(argument==ManifestArgument) {
      ++requested;
      continue;
      }
    if(argument.starts_with(ArgumentRoot))
      result.unknown = true;
    }
  result.requested = requested==1u;
  result.duplicate = requested>1u;
  return result;
  }

enum class Error : uint8_t {
  None,
  UnsupportedPlatform,
  InvalidDocumentRoot,
  MissingRoot,
  MissingExcludedFile,
  MissingProtectedSave,
  InvalidUtf8,
  NonCanonicalPath,
  NormalizedPathCollision,
  NonRegularEntry,
  FileCountLimit,
  FileSizeLimit,
  TotalSizeLimit,
  OpenFailed,
  ReadFailed,
  FileChanged,
  Collision,
  TemporaryFileFailed,
  WriteFailed,
  SyncFailed,
  PublishFailed,
  };

struct Result final {
  Error error = Error::None;
  uint64_t resourceFileCount = 0u;
  uint64_t resourceTotalBytes = 0u;
  uint64_t protectedSaveFileCount = 0u;
  uint64_t protectedSaveTotalBytes = 0u;
  std::array<char,65> resourceManifestSha256{};
  std::array<char,65> protectedSaveManifestSha256{};

  constexpr bool success() const noexcept {
    return error==Error::None;
    }
  };

const char* errorName(Error error) noexcept;

// documentRoot is the application Documents directory. The function is
// host-testable and has no UIKit/Objective-C types in its public contract.
// Both output leaves are exclusive; an existing file, directory or symlink is
// a fail-closed collision and is never replaced.
Result createCanonicalManifests(
    const std::filesystem::path& documentRoot) noexcept;

#if defined(OPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST)
using RevalidationTestHook = bool (*)(
    const std::filesystem::path& documentRoot) noexcept;

// Runs the hook after all payload hashes and before the mandatory exact-tree
// revalidation. This entry point is absent from production builds.
Result createCanonicalManifestsForTest(
    const std::filesystem::path& documentRoot,
    RevalidationTestHook hook) noexcept;
#endif

}

#endif
