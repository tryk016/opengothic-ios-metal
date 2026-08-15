#pragma once

#include "iosgpusceneplan.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace Tempest {
class CommandBuffer;
class Device;
class Attachment;
template<class T>
class Encoder;
}

class IOSSceneAssetRegistry;
struct IOSSceneSnapshot;
struct IOSLinearHDRProofMetadata;
struct IOSLinearHDRProofNativeView;
struct IOSMultiply2CoverageProofMetadata;
struct IOSMultiply2CoverageNativeView;

class IOSGPUScene final {
  public:
    static constexpr std::size_t ReportMarkerCount = 10u;

    enum class ColorFormat : uint8_t {
      Bgra8Unorm,
      Rg11B10Float,
      };

    enum class DepthFormat : uint8_t {
      Depth16Unorm,
      Depth32Float,
      Depth32FloatStencil8,
      };

    struct TargetLayout final {
      ColorFormat color = ColorFormat::Bgra8Unorm;
      DepthFormat depth = DepthFormat::Depth16Unorm;
      uint8_t     sampleCount = 1;
      };

    enum class Result : uint8_t {
      Success,
      Empty,
      UnsupportedTarget,
      RegistryUnavailable,
      GenerationMismatch,
      MissingMaterial,
      UnsupportedMaterial,
      InvalidAlphaCutoff,
      MissingAlphaTexture,
      MissingTexture,
      InvalidTexture,
      MissingMesh,
      InvalidMesh,
      NoActiveRenderEncoder,
      PipelineUnavailable,
      SelectorMismatch,
      CountOverflow,
      CountMismatch,
      AnimationEvidenceMismatch,
      NativeEncodingFailed,
      };

    struct Report final {
      Result                       result = Result::Empty;
      uint64_t                     drawCount = 0;
      uint64_t                     texturedDrawCount = 0;
      uint64_t                     encodedPhaseDrawCount = 0;
      uint64_t                     encodedPhaseTexturedDrawCount = 0;
      uint64_t                     failingHandle = 0;
      IOSGPUSceneFrameCounts       counts;
      IOSGPUSceneFailureCounts     failures;
      IOSGPUSceneFrameAnimationDrawReport frameAnimation;
      IOSGPUSceneUVAnimationDrawReport uvAnimation;
      std::array<IOSGPUSceneMarker,ReportMarkerCount> markers;
      bool                         markersReady = false;
      };

    struct AdditiveInputArtifact final {
      std::vector<std::byte> bytes;
      uint64_t               generation = 0;
      uint64_t               sequence = 0;
      char                   mode = '\0';

      explicit operator bool() const noexcept {
        return !bytes.empty() && generation!=0u && sequence!=0u &&
               (mode=='a' || mode=='b');
        }
      };

    struct Multiply2InputArtifact final {
      std::vector<std::byte> bytes;
      uint64_t               generation = 0;
      uint64_t               sequence = 0;
      char                   mode = '\0';

      explicit operator bool() const noexcept {
        return !bytes.empty() && generation!=0u && sequence!=0u &&
               (mode=='a' || mode=='b');
        }
      };

    class PreparedFrame final {
      public:
        struct Impl;

        PreparedFrame() noexcept;
        ~PreparedFrame();
        PreparedFrame(const PreparedFrame&) = delete;
        PreparedFrame& operator=(const PreparedFrame&) = delete;
        PreparedFrame(PreparedFrame&&) noexcept;
        PreparedFrame& operator=(PreparedFrame&&) noexcept;

        bool ready() const noexcept;
        AdditiveInputArtifact takeAdditiveInputArtifact() noexcept;
        Multiply2InputArtifact takeMultiply2InputArtifact() noexcept;

      private:
        friend class IOSGPUScene;
        std::unique_ptr<Impl> impl;
      };

    IOSGPUScene(Tempest::Device& device, TargetLayout target);
    ~IOSGPUScene();

    IOSGPUScene(const IOSGPUScene&) = delete;
    IOSGPUScene& operator=(const IOSGPUScene&) = delete;

    bool pipelinesReady() const noexcept;
    bool additiveTerminalFailureReported() const noexcept;

    // Preparation is synchronous and must complete before the SceneHDR render
    // encoder is created. It freezes every native binding and deterministic
    // decision consumed by encodePrepared().
    Report prepareFrame(PreparedFrame& prepared,
                        uint64_t targetGeneration,
                        const IOSSceneSnapshot& snapshot,
                        const IOSSceneAssetRegistry& assets,
                        const IOSFrameAnimationEvidence* frameAnimation,
                        const IOSUVAnimationEvidence* uvAnimation = nullptr) noexcept;

    // The encoder must own an active render pass whose color, depth and sample
    // layout exactly matches the TargetLayout used to construct this scene.
    Report encodePrepared(
        Tempest::Encoder<Tempest::CommandBuffer>& encoder,
        PreparedFrame& prepared) noexcept;
    Report encodePreparedThroughMultiply2(
        Tempest::Encoder<Tempest::CommandBuffer>& encoder,
        PreparedFrame& prepared) noexcept;
    Report encodePreparedAdditive(
        Tempest::Encoder<Tempest::CommandBuffer>& encoder,
        PreparedFrame& prepared) noexcept;
    bool multiply2CoverageMetadata(
        const PreparedFrame& prepared,
        const IOSLinearHDRProofMetadata& hdrProof,
        uint32_t width,
        uint32_t height,
        IOSMultiply2CoverageProofMetadata& metadata) const noexcept;
    Report encodePreparedMultiply2Causal(
        Tempest::Encoder<Tempest::CommandBuffer>& encoder,
        PreparedFrame& prepared,
        const Tempest::Attachment& sceneHDR,
        const IOSLinearHDRProofNativeView& hdrProof,
        const IOSMultiply2CoverageNativeView& coverage) noexcept;

  private:
    Report encodePreparedPhase(
        Tempest::Encoder<Tempest::CommandBuffer>& encoder,
        PreparedFrame& prepared,
        uint8_t phase) noexcept;
    struct Impl;
    std::unique_ptr<Impl> impl;
  };

const char* iosGPUSceneResultName(IOSGPUScene::Result result) noexcept;
