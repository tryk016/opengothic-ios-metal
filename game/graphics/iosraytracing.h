#pragma once

#include "iosscenesnapshot.h"
#include <memory>
#include <span>

namespace MTL { class Device; class Buffer; class Texture; class CommandBuffer; class ComputeCommandEncoder; }

// Static opaque geometry only. Buffer/range identities remain immutable within
// a world generation; the frame context pins the source scene until completion.
class IOSRayTracing final {
  public:
    struct Geometry final {
      uint64_t mesh = 0;
      MTL::Buffer* vertices = nullptr;
      MTL::Buffer* indices = nullptr;
      size_t stride = 0, firstIndex = 0, indexCount = 0;
      IOSMatrix4x4 transform;
      };

    class Frame final {
      public:
        Frame();
        ~Frame();
        Frame(Frame&&) noexcept;
        Frame& operator=(Frame&&) noexcept;
        void markSubmitted() noexcept;
        void completeConfirmed() noexcept;
        bool ready() const noexcept;
        uint32_t instanceCount() const noexcept;
        uint32_t buildCount() const noexcept;
        uint32_t compactionCount() const noexcept;

      private:
        friend class IOSRayTracing;
        struct Impl;
        std::unique_ptr<Impl> impl;
      };

    explicit IOSRayTracing(MTL::Device* device);
    ~IOSRayTracing();
    bool supported() const noexcept;
    // Reuse only after this slot's confirmed completion. Work is bounded per
    // frame; the raster path remains active while the static scene warms up.
    void prepare(Frame& frame, uint64_t generation, std::span<const Geometry> geometry);
    bool encodeBuilds(Frame& frame, MTL::CommandBuffer* command);
    void bind(const Frame& frame, MTL::ComputeCommandEncoder* encoder, unsigned index) const;
    bool encodeDebug(const Frame& frame, MTL::CommandBuffer* command, MTL::Texture* color,
                     const IOSCameraState& camera);
    bool encodeAmbientOcclusion(Frame& frame, MTL::CommandBuffer* command, MTL::Texture* color,
                                MTL::Texture* depth, MTL::Texture* motion, MTL::Texture* reactive,
                                const IOSSceneSnapshot& snapshot);
    void clearAfterConfirmedIdle() noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
  };
