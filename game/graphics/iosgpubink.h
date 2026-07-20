#pragma once

#include "iosbinkshaderabi.h"

#include <Tempest/CommandBuffer>
#include <Tempest/Encoder>
#include <Tempest/StorageBuffer>

#include <cstddef>
#include <cstdint>
#include <memory>

namespace Tempest {
class Device;
}

class IOSGPUBink final {
  public:
    struct PlaneLayout final {
      size_t   offsetU = 0;
      size_t   offsetV = 0;
      uint32_t strideY = 0;
      uint32_t strideU = 0;
      uint32_t strideV = 0;
      };

    explicit IOSGPUBink(Tempest::Device& device);
    ~IOSGPUBink();

    IOSGPUBink(const IOSGPUBink&) = delete;
    IOSGPUBink& operator=(const IOSGPUBink&) = delete;

    void encode(Tempest::Encoder<Tempest::CommandBuffer>& encoder,
                const Tempest::StorageBuffer& planes,
                const PlaneLayout& layout);

    uint64_t encodedFrames() const noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
  };
