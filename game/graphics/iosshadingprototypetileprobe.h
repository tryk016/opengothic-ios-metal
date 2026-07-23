#pragma once

#include <array>
#include <cstdint>

namespace Tempest {
class CommandBuffer;
class Device;
template<class T>
class Encoder;
}

class IOSMetalResourceTexture;
class IOSShadingPrototypePipeline;

namespace RendererIOSShadingPrototypeTileProbe {

inline constexpr uint32_t ContractVersion = 1u;
inline constexpr uint32_t MinimumAppleGPUFamily = 4u;
inline constexpr uint32_t OutputWidth = 4u;
inline constexpr uint32_t OutputHeight = 4u;
inline constexpr uint32_t OutputAttachment = 0u;
inline constexpr uint32_t ImageblockBytesPerSample = 4u;
inline constexpr uint32_t ThreadgroupMemoryLength = 0u;
inline constexpr uint32_t TileWidth = 16u;
inline constexpr uint32_t TileHeight = 16u;
inline constexpr uint32_t DispatchWidth = 16u;
inline constexpr uint32_t DispatchHeight = 16u;
inline constexpr uint32_t DispatchDepth = 1u;
inline constexpr uint32_t VertexStride = 28u;
inline constexpr uint32_t VertexCount = 6u;
inline constexpr uint32_t VertexBytes = VertexStride*VertexCount;

}

enum class IOSShadingPrototypeTileProbeOperation : uint8_t {
  DrawOpaque           = 0,
  DrawAlphaTest        = 1,
  DispatchTileLighting = 2,
  };

// Host-neutral evidence contract for the compile-only P2.5b2a0 encoder.
// The report separates the one borrowed command buffer and output texture
// from resources that the helper itself is forbidden to create.
struct IOSShadingPrototypeTileProbeReport final {
  uint32_t contractVersion = 0u;
  bool borrowedExistingDevice = false;
  bool borrowedVirginCommandBuffer = false;
  bool supportsApple4 = false;
  bool pipelineReady = false;
  bool pipelineSameDevice = false;
  bool outputAvailable = false;
  bool outputSameDevice = false;
  bool outputType2D = false;
  bool outputRgba8Unorm = false;
  bool outputPrivate = false;
  bool outputExtentMatches = false;
  bool transparentBlackClear = false;
  bool encoded = false;
  uint32_t physicalPasses = 0u;
  uint32_t commandBuffers = 0u;
  uint32_t withActiveCommandBufferCalls = 0u;
  uint32_t renderEncoders = 0u;
  uint32_t outputAttachments = 0u;
  uint32_t outputAttachmentIndex = 0u;
  uint32_t materialTextures = 0u;
  uint32_t pipelineStates = 0u;
  uint32_t vertexByteBindings = 0u;
  uint32_t vertices = 0u;
  uint32_t vertexBytes = 0u;
  uint32_t draws = 0u;
  uint32_t opaqueDraws = 0u;
  uint32_t alphaTestDraws = 0u;
  uint32_t tileDispatches = 0u;
  uint32_t imageblockBytesPerSample = 0u;
  uint32_t threadgroupMemoryLength = 0u;
  uint32_t tileWidth = 0u;
  uint32_t tileHeight = 0u;
  uint32_t dispatchWidth = 0u;
  uint32_t dispatchHeight = 0u;
  uint32_t dispatchDepth = 0u;
  uint32_t endEncodingCalls = 0u;
  uint32_t computeEncoders = 0u;
  uint32_t blitEncoders = 0u;
  uint32_t helperDeviceCreations = 0u;
  uint32_t helperQueueCreations = 0u;
  uint32_t helperCommandBufferCreations = 0u;
  uint32_t helperFenceCreations = 0u;
  uint32_t helperResourceCreations = 0u;
  uint32_t captureStarts = 0u;
  uint32_t helperSubmits = 0u;
  uint32_t helperCommits = 0u;
  uint32_t helperWaits = 0u;
  uint32_t drawableAcquisitions = 0u;
  uint32_t presents = 0u;
  uint32_t operationCount = 0u;
  std::array<IOSShadingPrototypeTileProbeOperation,3u> operations{};

  friend bool operator==(IOSShadingPrototypeTileProbeReport,
                         IOSShadingPrototypeTileProbeReport) = default;
  };

[[nodiscard]] IOSShadingPrototypeTileProbeReport
    iosCanonicalShadingPrototypeTileProbeReport() noexcept;

[[nodiscard]] bool iosShadingPrototypeTileProbeReportMatches(
    const IOSShadingPrototypeTileProbeReport& report) noexcept;

// P2.5b2a0 compiles this narrow helper but deliberately has no production
// caller. A later opt-in device slice will supply a context-owned output
// texture and a virgin active Tempest command buffer, then own submission and
// terminal fence handling outside this function.
[[nodiscard]] bool iosEncodeShadingPrototypeTileProbe(
    Tempest::Device& device,
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const IOSShadingPrototypePipeline& pipeline,
    const IOSMetalResourceTexture& output,
    IOSShadingPrototypeTileProbeReport& report) noexcept;
