#pragma once

#include "iosscenesnapshot.h"

#include <Tempest/Size>
#include <memory>

namespace MTL { class Texture; class CommandBuffer; }
namespace Tempest {
class Device;
class Texture2d;
class CommandBuffer;
template<class T> class Encoder;
}
class IOSDeviceFacts;
struct IOSToneResolveConstants;

enum class IOSUpscalerMode : uint8_t { Auto, Temporal, Spatial, Fsr1, Native };

struct IOSUpscalerSettings final {
  IOSUpscalerMode mode = IOSUpscalerMode::Auto;
  float scale = 1.f;
  bool operator==(const IOSUpscalerSettings&) const noexcept = default;
  };

struct IOSUpscalerTemporalInputs final {
  // Borrowed from IOSGPUScene for the current command buffer only.
  MTL::Texture* depth = nullptr;
  MTL::Texture* motion = nullptr;
  MTL::Texture* reactive = nullptr;
  };

class IOSUpscaler final {
  public:
    explicit IOSUpscaler(Tempest::Device& device);
    ~IOSUpscaler();
    void configure(IOSUpscalerSettings settings, Tempest::Size output, const IOSDeviceFacts& facts, bool motionAvailable);
    Tempest::Size inputSize() const noexcept;
    IOSUpscalerMode activeMode() const noexcept;
    bool outputIsLdr() const noexcept;
    bool encodingFailed() const noexcept;
    void prepareCamera(IOSSceneFrameState& scene) const noexcept;
    void resetHistory() noexcept;
    bool encodeNative(MTL::CommandBuffer* command, MTL::Texture* source,
                IOSUpscalerTemporalInputs temporal,
                const IOSSceneSnapshot& snapshot, const IOSToneResolveConstants& tone);
    const Tempest::Texture2d& output() const noexcept;
    bool encodeLdrOutput(Tempest::Encoder<Tempest::CommandBuffer>& encoder);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
  };
