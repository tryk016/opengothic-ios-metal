#pragma once

#include <cstdint>
#include <memory>

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
    enum class ColorFormat : uint8_t {
      Bgra8Unorm,
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
      MissingMesh,
      InvalidMesh,
      NoActiveRenderEncoder,
      PipelineUnavailable,
      NativeEncodingFailed,
      };

    struct Report final {
      Result   result = Result::Empty;
      uint32_t drawCount = 0;
      uint64_t failingHandle = 0;
      };

    IOSGPUScene(Tempest::Device& device, TargetLayout target);
    ~IOSGPUScene();

    IOSGPUScene(const IOSGPUScene&) = delete;
    IOSGPUScene& operator=(const IOSGPUScene&) = delete;

    // The encoder must own an active render pass whose color, depth and sample
    // layout exactly matches the TargetLayout used to construct this scene.
    Report encode(Tempest::Encoder<Tempest::CommandBuffer>& encoder,
                  const IOSSceneSnapshot& snapshot,
                  const IOSSceneAssetRegistry& assets) noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
  };

const char* iosGPUSceneResultName(IOSGPUScene::Result result) noexcept;
