#pragma once

#include "ioslinearhdr.h"
#include "ioslandscapeshaderabi.h"

#include <cstdint>
#include <memory>

namespace Tempest {
class Attachment;
class CommandBuffer;
class Device;
template<class T>
class Encoder;
}

enum class IOSLinearHDRMetalEncodeResult : uint8_t {
  Success,
  PipelineUnavailable,
  InvalidSource,
  NoActiveRenderEncoder,
  NativeEncodingFailed,
  };

class IOSLinearHDRMetal final {
  public:
    explicit IOSLinearHDRMetal(Tempest::Device& device);
    ~IOSLinearHDRMetal();

    IOSLinearHDRMetal(const IOSLinearHDRMetal&) = delete;
    IOSLinearHDRMetal& operator=(const IOSLinearHDRMetal&) = delete;

    IOSLinearHDRProbeResult probe() const noexcept;
    bool resolvePipelineReady() const noexcept;
    bool exactTarget(const Tempest::Attachment& target,
                     uint32_t width, uint32_t height) const noexcept;
    IOSLinearHDRMetalEncodeResult encodeToneResolve(
        Tempest::Encoder<Tempest::CommandBuffer>& encoder,
        const Tempest::Attachment& source,
        const IOSToneResolveConstants& constants) noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
  };

const char* iosLinearHDRMetalEncodeResultName(
    IOSLinearHDRMetalEncodeResult result) noexcept;
