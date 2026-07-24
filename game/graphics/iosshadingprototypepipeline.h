#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <string_view>

namespace Tempest {
class Device;
}

class IOSShadingPrototypePipelineNativeAccess;

namespace RendererIOSShadingPrototypePipeline {

inline constexpr uint32_t ContractVersion = 1u;
inline constexpr uint32_t OfflineMetallibAbi = 5u;
inline constexpr uint32_t MinimumAppleGPUFamily = 4u;
inline constexpr uint32_t TileFunctionCount = 3u;
inline constexpr uint32_t TilePipelineCount = 3u;
inline constexpr uint32_t ForwardRuntimeFunctionCount = 0u;
inline constexpr std::string_view AlphaTestFunctionConstantName =
    "riosShadingPrototypeAlphaTest";
inline constexpr uint32_t AlphaTestFunctionConstant = 0u;
inline constexpr uint32_t PositionAttribute = 0u;
inline constexpr uint32_t ColorAttribute = 1u;
inline constexpr uint32_t VertexBuffer = 0u;
inline constexpr uint32_t ColorAttachmentCount = 8u;
inline constexpr uint32_t FinalColorAttachment = 0u;
inline constexpr uint32_t VertexStride = 28u;
inline constexpr uint32_t PositionOffset = 0u;
inline constexpr uint32_t ColorOffset = 12u;
// The explicit MSL material payload is 4 B, while Metal reports the complete
// mixed explicit+implicit imageblock footprint through imageblockSampleLength.
inline constexpr uint32_t ExplicitMaterialBytesPerSample = 4u;
inline constexpr uint32_t PipelineImageblockBytesPerSample = 12u;

}

enum class IOSShadingPrototypePipelineStatus : uint8_t {
  Ready                 = 0,
  DeviceUnavailable     = 1,
  UnsupportedCapability = 2,
  LibraryUnavailable    = 3,
  FunctionMismatch      = 4,
  PipelineCreationFailed = 5,
  PipelineMismatch      = 6,
  ReflectionMismatch    = 7,
  InternalFailure       = 8,
  };

enum class IOSShadingPrototypeFunctionStage : uint8_t {
  Unknown  = 0,
  Vertex   = 1,
  Fragment = 2,
  Kernel   = 3,
  };

enum class IOSShadingPrototypeBindingType : uint8_t {
  Unknown        = 0,
  ImageblockData = 1,
  Imageblock     = 2,
  VertexBuffer   = 3,
  };

struct IOSShadingPrototypeFunctionConstantReport final {
  bool available = false;
  bool nameMatches = false;
  bool indexMatches = false;
  bool boolType = false;
  bool required = false;

  friend bool operator==(IOSShadingPrototypeFunctionConstantReport,
                         IOSShadingPrototypeFunctionConstantReport) = default;
  };

struct IOSShadingPrototypeFunctionReport final {
  bool available = false;
  bool nameMatches = false;
  bool sameDevice = false;
  IOSShadingPrototypeFunctionStage stage =
      IOSShadingPrototypeFunctionStage::Unknown;
  uint32_t functionConstantCount = 0u;
  IOSShadingPrototypeFunctionConstantReport alphaTest;

  friend bool operator==(IOSShadingPrototypeFunctionReport,
                         IOSShadingPrototypeFunctionReport) = default;
  };

struct IOSShadingPrototypeSpecializationReport final {
  bool available = false;
  bool nameMatches = false;
  bool sameDevice = false;
  IOSShadingPrototypeFunctionStage stage =
      IOSShadingPrototypeFunctionStage::Unknown;
  bool alphaTestEnabled = false;

  friend bool operator==(IOSShadingPrototypeSpecializationReport,
                         IOSShadingPrototypeSpecializationReport) = default;
  };

struct IOSShadingPrototypeBindingReport final {
  IOSShadingPrototypeBindingType type =
      IOSShadingPrototypeBindingType::Unknown;
  bool used = false;

  friend bool operator==(IOSShadingPrototypeBindingReport,
                         IOSShadingPrototypeBindingReport) = default;
  };

struct IOSShadingPrototypeBindingListReport final {
  std::array<IOSShadingPrototypeBindingReport,2u> bindings{};
  uint32_t count = 0u;
  bool available = false;
  bool overflow = false;

  friend bool operator==(IOSShadingPrototypeBindingListReport,
                         IOSShadingPrototypeBindingListReport) = default;
  };

struct IOSShadingPrototypeMaterialPipelineReport final {
  bool available = false;
  bool sameDevice = false;
  bool reflectionAvailable = false;
  bool binaryArchivesNil = false;
  bool vertexDescriptorMatches = false;
  bool colorAttachmentRgba8Unorm = false;
  bool unusedColorAttachmentsInvalid = false;
  bool colorWriteMaskAll = false;
  bool blendingDisabled = false;
  bool depthStencilDisabled = false;
  bool triangleTopology = false;
  bool alphaToCoverageDisabled = false;
  bool alphaToOneDisabled = false;
  bool alphaTestEnabled = false;
  uint32_t sampleCount = 0u;
  uint32_t imageblockBytesPerSample = 0u;
  IOSShadingPrototypeBindingListReport vertexBindings;
  IOSShadingPrototypeBindingListReport fragmentBindings;
  IOSShadingPrototypeBindingListReport tileBindings;

  friend bool operator==(IOSShadingPrototypeMaterialPipelineReport,
                         IOSShadingPrototypeMaterialPipelineReport) = default;
  };

struct IOSShadingPrototypeTilePipelineReport final {
  bool available = false;
  bool sameDevice = false;
  bool reflectionAvailable = false;
  bool binaryArchivesNil = false;
  bool colorAttachmentRgba8Unorm = false;
  bool unusedColorAttachmentsInvalid = false;
  bool threadgroupSizeMatchesTileSize = false;
  uint32_t sampleCount = 0u;
  uint32_t imageblockBytesPerSample = 0u;
  IOSShadingPrototypeBindingListReport vertexBindings;
  IOSShadingPrototypeBindingListReport fragmentBindings;
  IOSShadingPrototypeBindingListReport tileBindings;

  friend bool operator==(IOSShadingPrototypeTilePipelineReport,
                         IOSShadingPrototypeTilePipelineReport) = default;
  };

struct IOSShadingPrototypePipelineReport final {
  uint32_t contractVersion = 0u;
  uint32_t offlineMetallibAbi = 0u;
  bool deviceAvailable = false;
  bool supportsApple4 = false;
  bool libraryAvailable = false;
  bool librarySameDevice = false;
  uint32_t resolvedTileFunctionCount = 0u;
  uint32_t createdTilePipelineCount = 0u;
  std::array<IOSShadingPrototypeFunctionReport,3u> functions{};
  std::array<IOSShadingPrototypeSpecializationReport,2u>
      materialSpecializations{};
  std::array<IOSShadingPrototypeMaterialPipelineReport,2u>
      materialPipelines{};
  IOSShadingPrototypeTilePipelineReport lightingPipeline;

  friend bool operator==(IOSShadingPrototypePipelineReport,
                         IOSShadingPrototypePipelineReport) = default;
  };

[[nodiscard]] IOSShadingPrototypePipelineReport
    iosCanonicalShadingPrototypePipelineReport() noexcept;

[[nodiscard]] IOSShadingPrototypePipelineStatus
    iosValidateShadingPrototypePipelineReport(
        const IOSShadingPrototypePipelineReport& report) noexcept;

const char* iosShadingPrototypePipelineStatusName(
    IOSShadingPrototypePipelineStatus status) noexcept;

class IOSShadingPrototypePipeline final {
  public:
    IOSShadingPrototypePipeline() noexcept;
    ~IOSShadingPrototypePipeline();

    IOSShadingPrototypePipeline(
        const IOSShadingPrototypePipeline&) = delete;
    IOSShadingPrototypePipeline& operator=(
        const IOSShadingPrototypePipeline&) = delete;

    IOSShadingPrototypePipeline(
        IOSShadingPrototypePipeline&& other) noexcept;
    IOSShadingPrototypePipeline& operator=(
        IOSShadingPrototypePipeline&& other) noexcept;

    explicit operator bool() const noexcept;
    [[nodiscard]] IOSShadingPrototypePipelineStatus status() const noexcept;
    [[nodiscard]] const IOSShadingPrototypePipelineReport&
        report() const noexcept;

  private:
    struct Impl;

    IOSShadingPrototypePipeline(
        IOSShadingPrototypePipelineStatus status,
        IOSShadingPrototypePipelineReport report,
        std::unique_ptr<Impl>&& impl) noexcept;

    IOSShadingPrototypePipelineStatus pipelineStatus =
        IOSShadingPrototypePipelineStatus::InternalFailure;
    IOSShadingPrototypePipelineReport pipelineReport;
    std::unique_ptr<Impl> impl;

  friend IOSShadingPrototypePipeline
      iosCreateShadingPrototypePipeline(Tempest::Device&) noexcept;
  friend class IOSShadingPrototypePipelineNativeAccess;
  };

// P2.5b1 only builds and reflects three Tile Deferred pipeline states.
// It is deliberately not invoked by production runtime code before P2.5b2.
[[nodiscard]] IOSShadingPrototypePipeline
    iosCreateShadingPrototypePipeline(Tempest::Device& device) noexcept;
