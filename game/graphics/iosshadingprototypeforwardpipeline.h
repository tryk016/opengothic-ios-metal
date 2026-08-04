#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <string_view>

namespace Tempest {
class Device;
}

namespace RendererIOSShadingPrototypeForwardPipeline {

inline constexpr uint32_t ContractVersion = 1u;
inline constexpr uint32_t OfflineMetallibAbi = 7u;
inline constexpr uint32_t MinimumAppleGPUFamily = 4u;
inline constexpr uint32_t ResolvedFunctionCount = 3u;
inline constexpr uint32_t SpecializationCount = 2u;
inline constexpr uint32_t ComputePipelineCount = 1u;
inline constexpr uint32_t RenderPipelineCount = 2u;
inline constexpr std::string_view AlphaTestFunctionConstantName =
    "riosShadingPrototypeAlphaTest";
inline constexpr uint32_t AlphaTestFunctionConstant = 0u;
inline constexpr uint32_t PositionAttribute = 0u;
inline constexpr uint32_t ColorAttribute = 1u;
inline constexpr uint32_t VertexBufferIndex = 0u;
inline constexpr uint32_t LightListBufferIndex = 0u;
inline constexpr uint32_t ColorAttachmentCount = 8u;
inline constexpr uint32_t FinalColorAttachment = 0u;
inline constexpr uint32_t VertexStride = 28u;
inline constexpr uint32_t PositionOffset = 0u;
inline constexpr uint32_t ColorOffset = 12u;
inline constexpr uint32_t PipelineImageblockBytesPerSample = 0u;
inline constexpr std::string_view ComputePipelineLabel =
    "RendererIOS Forward BuildLightList";
inline constexpr std::string_view OpaquePipelineLabel =
    "RendererIOS Forward Opaque";
inline constexpr std::string_view AlphaTestPipelineLabel =
    "RendererIOS Forward AlphaTest";

}

enum class IOSShadingPrototypeForwardPipelineStatus : uint8_t {
  Ready                  = 0,
  DeviceUnavailable      = 1,
  UnsupportedCapability  = 2,
  LibraryUnavailable     = 3,
  FunctionMismatch       = 4,
  PipelineCreationFailed = 5,
  PipelineMismatch       = 6,
  ReflectionMismatch     = 7,
  InternalFailure        = 8,
  };

enum class IOSShadingPrototypeForwardFunctionStage : uint8_t {
  Unknown  = 0,
  Vertex   = 1,
  Fragment = 2,
  Kernel   = 3,
  };

enum class IOSShadingPrototypeForwardBindingSemantic : uint8_t {
  Unknown         = 0,
  VertexBuffer    = 1,
  LightListBuffer = 2,
  };

enum class IOSShadingPrototypeForwardBindingNativeType : uint8_t {
  Unknown = 0,
  Buffer  = 1,
  };

enum class IOSShadingPrototypeForwardBindingAccess : uint8_t {
  Unknown   = 0,
  ReadOnly  = 1,
  ReadWrite = 2,
  WriteOnly = 3,
  };

struct IOSShadingPrototypeForwardFunctionConstantReport final {
  bool available = false;
  bool nameMatches = false;
  bool indexMatches = false;
  bool boolType = false;
  bool required = false;

  friend bool operator==(
      IOSShadingPrototypeForwardFunctionConstantReport,
      IOSShadingPrototypeForwardFunctionConstantReport) = default;
  };

struct IOSShadingPrototypeForwardFunctionReport final {
  bool available = false;
  bool nameMatches = false;
  bool sameDevice = false;
  IOSShadingPrototypeForwardFunctionStage stage =
      IOSShadingPrototypeForwardFunctionStage::Unknown;
  uint32_t functionConstantCount = 0u;
  IOSShadingPrototypeForwardFunctionConstantReport alphaTest;

  friend bool operator==(
      IOSShadingPrototypeForwardFunctionReport,
      IOSShadingPrototypeForwardFunctionReport) = default;
  };

struct IOSShadingPrototypeForwardSpecializationReport final {
  bool available = false;
  bool nameMatches = false;
  bool sameDevice = false;
  IOSShadingPrototypeForwardFunctionStage stage =
      IOSShadingPrototypeForwardFunctionStage::Unknown;
  bool alphaTestEnabled = false;

  friend bool operator==(
      IOSShadingPrototypeForwardSpecializationReport,
      IOSShadingPrototypeForwardSpecializationReport) = default;
  };

struct IOSShadingPrototypeForwardBindingReport final {
  IOSShadingPrototypeForwardFunctionStage stage =
      IOSShadingPrototypeForwardFunctionStage::Unknown;
  IOSShadingPrototypeForwardBindingSemantic semantic =
      IOSShadingPrototypeForwardBindingSemantic::Unknown;
  IOSShadingPrototypeForwardBindingNativeType nativeType =
      IOSShadingPrototypeForwardBindingNativeType::Unknown;
  IOSShadingPrototypeForwardBindingAccess access =
      IOSShadingPrototypeForwardBindingAccess::Unknown;
  bool used = false;
  uint32_t index = 0u;

  friend bool operator==(
      IOSShadingPrototypeForwardBindingReport,
      IOSShadingPrototypeForwardBindingReport) = default;
  };

struct IOSShadingPrototypeForwardBindingListReport final {
  std::array<IOSShadingPrototypeForwardBindingReport,1u> bindings{};
  uint32_t count = 0u;
  bool available = false;
  bool overflow = false;

  friend bool operator==(
      IOSShadingPrototypeForwardBindingListReport,
      IOSShadingPrototypeForwardBindingListReport) = default;
  };

struct IOSShadingPrototypeForwardComputePipelineReport final {
  bool available = false;
  bool sameDevice = false;
  bool reflectionAvailable = false;
  bool binaryArchivesNil = false;
  bool functionMatches = false;
  bool threadGroupSizeMultipleDisabled = false;
  bool maxTotalThreadsPerThreadgroupZero = false;
  // These retain their ABI slots while reporting semantic emptiness: Metal
  // may materialize a non-nil owner after a nil setter.
  bool stageInputDescriptorEmpty = false;
  bool indirectCommandBuffersDisabled = false;
  bool linkedFunctionsEmpty = false;
  bool addingBinaryFunctionsDisabled = false;
  uint32_t maxCallStackDepth = 0u;
  IOSShadingPrototypeForwardBindingListReport computeBindings;

  friend bool operator==(
      IOSShadingPrototypeForwardComputePipelineReport,
      IOSShadingPrototypeForwardComputePipelineReport) = default;
  };

struct IOSShadingPrototypeForwardRenderPipelineReport final {
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
  bool rasterizationEnabled = false;
  bool indirectCommandBuffersDisabled = false;
  bool alphaTestEnabled = false;
  uint32_t sampleCount = 0u;
  // Device telemetry only. Metal defines this as native per-sample memory
  // usage; it does not promise zero when no explicit imageblock is declared.
  uint32_t imageblockBytesPerSample = 0u;
  IOSShadingPrototypeForwardBindingListReport vertexBindings;
  IOSShadingPrototypeForwardBindingListReport fragmentBindings;
  IOSShadingPrototypeForwardBindingListReport tileBindings;
  IOSShadingPrototypeForwardBindingListReport objectBindings;
  IOSShadingPrototypeForwardBindingListReport meshBindings;

  friend bool operator==(
      IOSShadingPrototypeForwardRenderPipelineReport,
      IOSShadingPrototypeForwardRenderPipelineReport) = default;
  };

struct IOSShadingPrototypeForwardPipelineReport final {
  uint32_t contractVersion = 0u;
  uint32_t offlineMetallibAbi = 0u;
  bool deviceAvailable = false;
  bool supportsApple4 = false;
  bool libraryAvailable = false;
  bool librarySameDevice = false;
  uint32_t resolvedFunctionCount = 0u;
  uint32_t specializationCount = 0u;
  uint32_t createdComputePipelineCount = 0u;
  uint32_t createdRenderPipelineCount = 0u;
  std::array<IOSShadingPrototypeForwardFunctionReport,3u> functions{};
  std::array<IOSShadingPrototypeForwardSpecializationReport,2u>
      fragmentSpecializations{};
  IOSShadingPrototypeForwardComputePipelineReport computePipeline;
  std::array<IOSShadingPrototypeForwardRenderPipelineReport,2u>
      renderPipelines{};

  friend bool operator==(
      IOSShadingPrototypeForwardPipelineReport,
      IOSShadingPrototypeForwardPipelineReport) = default;
  };

[[nodiscard]] IOSShadingPrototypeForwardPipelineReport
    iosCanonicalShadingPrototypeForwardPipelineReport() noexcept;

[[nodiscard]] IOSShadingPrototypeForwardPipelineStatus
    iosValidateShadingPrototypeForwardPipelineReport(
        const IOSShadingPrototypeForwardPipelineReport& report) noexcept;

const char* iosShadingPrototypeForwardPipelineStatusName(
    IOSShadingPrototypeForwardPipelineStatus status) noexcept;

class IOSShadingPrototypeForwardPipeline final {
  public:
    IOSShadingPrototypeForwardPipeline() noexcept;
    ~IOSShadingPrototypeForwardPipeline();

    IOSShadingPrototypeForwardPipeline(
        const IOSShadingPrototypeForwardPipeline&) = delete;
    IOSShadingPrototypeForwardPipeline& operator=(
        const IOSShadingPrototypeForwardPipeline&) = delete;

    IOSShadingPrototypeForwardPipeline(
        IOSShadingPrototypeForwardPipeline&& other) noexcept;
    IOSShadingPrototypeForwardPipeline& operator=(
        IOSShadingPrototypeForwardPipeline&& other) noexcept;

    explicit operator bool() const noexcept;
    [[nodiscard]] IOSShadingPrototypeForwardPipelineStatus
        status() const noexcept;
    [[nodiscard]] const IOSShadingPrototypeForwardPipelineReport&
        report() const noexcept;

  private:
    struct Impl;

    IOSShadingPrototypeForwardPipeline(
        IOSShadingPrototypeForwardPipelineStatus status,
        IOSShadingPrototypeForwardPipelineReport report,
        std::unique_ptr<Impl>&& impl) noexcept;

    IOSShadingPrototypeForwardPipelineStatus pipelineStatus =
        IOSShadingPrototypeForwardPipelineStatus::InternalFailure;
    IOSShadingPrototypeForwardPipelineReport pipelineReport;
    std::unique_ptr<Impl> impl;

  friend IOSShadingPrototypeForwardPipeline
      iosCreateShadingPrototypeForwardPipeline(
          Tempest::Device&) noexcept;
  friend class IOSShadingPrototypeForwardPipelineNativeAccess;
  };

// P2.5c0 is an isolated construction/reflection-only Forward+ control factory.
[[nodiscard]] IOSShadingPrototypeForwardPipeline
    iosCreateShadingPrototypeForwardPipeline(
        Tempest::Device& device) noexcept;
