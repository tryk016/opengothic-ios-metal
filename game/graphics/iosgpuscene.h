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
template<class T>
class Encoder;
}

class IOSSceneAssetRegistry;
struct IOSSceneSnapshot;

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

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
  };

const char* iosGPUSceneResultName(IOSGPUScene::Result result) noexcept;
