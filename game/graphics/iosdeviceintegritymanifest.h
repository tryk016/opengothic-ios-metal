#pragma once

#include <cstddef>
#include <cstdint>

#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)

#include <array>
#include <filesystem>
#include <string>
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
inline constexpr std::string_view CleanupArgument =
    "-renderer-ios-device-integrity-cleanup-v1";
inline constexpr std::string_view ResourceManifestFileName =
    "resource-manifest-v1.jsonl";
inline constexpr std::string_view ProtectedSaveManifestFileName =
    "protected-save-manifest-v1.jsonl";
inline constexpr std::string_view TerminalMarker =
    "RendererIOS device integrity manifest: schema=1 "
    "resources=resource-manifest-v1.jsonl "
    "saves=protected-save-manifest-v1.jsonl result=PASS terminal=C";
inline constexpr std::string_view CleanupTerminalMarker =
    "RendererIOS device integrity cleanup: schema=1 "
    "resources=absent saves=absent result=PASS terminal=C";

static_assert(TerminalMarker.size()<255u);

struct ArgumentParseResult final {
  bool requested = false;
  bool cleanupRequested = false;
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
  unsigned cleanupRequested = 0u;
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
    if(argument==CleanupArgument) {
      ++cleanupRequested;
      continue;
      }
    if(argument.starts_with(ArgumentRoot))
      result.unknown = true;
    }
  result.requested = requested==1u;
  result.cleanupRequested = cleanupRequested==1u;
  result.duplicate = requested>1u || cleanupRequested>1u ||
                     (requested!=0u && cleanupRequested!=0u);
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

// Diagnostics-only detail for the fail-closed FileChanged result. This is
// intentionally broad: it identifies the integrity phase without exposing
// filesystem-specific internals or changing the manifest format.
enum class FailureStage : uint8_t {
  None,
  InitialResourceCollection,
  InitialSaveCollection,
  ResourceHashing,
  SaveHashing,
  RevalidationHook,
  PostHashResourceRecollection,
  PostHashSaveRecollection,
  ResourceSnapshotComparison,
  SaveSnapshotComparison,
  DocumentRootComparison,
  };

struct Result final {
  Error error = Error::None;
  FailureStage failureStage = FailureStage::None;
  uint64_t candidateOrdinal = 0u;
  std::array<char,65> candidatePathSha256{};
  uint64_t resourceFileCount = 0u;
  uint64_t resourceTotalBytes = 0u;
  uint64_t protectedSaveFileCount = 0u;
  uint64_t protectedSaveTotalBytes = 0u;
  std::array<char,65> resourceManifestSha256{};
  std::array<char,65> protectedSaveManifestSha256{};

  constexpr bool success() const noexcept {
    return error==Error::None;
    }

  constexpr bool hasHashingCandidateIdentity() const noexcept {
    if(error!=Error::FileChanged ||
       (failureStage!=FailureStage::ResourceHashing &&
        failureStage!=FailureStage::SaveHashing) ||
       candidateOrdinal==0u || candidateOrdinal>MaximumFileCount ||
       candidatePathSha256[64]!='\0')
      return false;
    const uint64_t collectionFileCount =
        failureStage==FailureStage::ResourceHashing
        ? resourceFileCount : protectedSaveFileCount;
    if(candidateOrdinal>collectionFileCount)
      return false;
    for(std::size_t index=0u; index<64u; ++index) {
      const char value = candidatePathSha256[index];
      if(!((value>='0' && value<='9') || (value>='a' && value<='f')))
        return false;
      }
    return true;
    }
  };

const char* errorName(Error error) noexcept;
const char* failureStageName(FailureStage stage) noexcept;
std::string formatFailureMessage(const Result& result);

// documentRoot is the application Documents directory. The function is
// host-testable and has no UIKit/Objective-C types in its public contract.
// Both output leaves are exclusive; an existing file, directory or symlink is
// a fail-closed collision and is never replaced.
Result createCanonicalManifests(
    const std::filesystem::path& documentRoot) noexcept;

// Removes only the two diagnostics-owned manifest leaves. Missing leaves are
// accepted so cleanup is idempotent; directories, symlinks and all unrelated
// Documents members are untouched. Success guarantees both leaves are absent
// and the Documents directory has been synchronized.
Result removeCanonicalManifests(
    const std::filesystem::path& documentRoot) noexcept;

#if defined(OPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST)
using RevalidationTestHook = bool (*)(
    const std::filesystem::path& documentRoot) noexcept;
enum class CandidateHashTestHookResult : uint8_t {
  NotSelected,
  Mutated,
  Failed,
  };
using CandidateHashTestHook = CandidateHashTestHookResult (*)(
    const std::filesystem::path& documentRoot,
    std::string_view normalizedRelativePath,
    uint64_t candidateOrdinal,
    FailureStage stage) noexcept;

// Runs the hook after all payload hashes and before the mandatory exact-tree
// revalidation. The candidate hook runs immediately before the selected
// candidate's stable open/read. Ordinals restart at one for each collection.
// NotSelected advances to the next candidate, Mutated consumes the hook for
// that collection, and Failed returns OpenFailed without hashing or detail.
// This entry point and hook domain are absent from production builds.
Result createCanonicalManifestsForTest(
    const std::filesystem::path& documentRoot,
    RevalidationTestHook hook,
    CandidateHashTestHook candidateHashHook = nullptr) noexcept;
#endif

}

#endif
