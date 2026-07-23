#pragma once

namespace MTL {
class Device;
class RenderPipelineState;
}

class IOSShadingPrototypePipeline;

struct IOSShadingPrototypePipelineNativeView final {
  MTL::Device* device = nullptr;
  MTL::RenderPipelineState* opaque = nullptr;
  MTL::RenderPipelineState* alphaTest = nullptr;
  MTL::RenderPipelineState* tileLighting = nullptr;
  };

// Private Objective-C++ bridge. It borrows exactly the three already-created
// Tile pipeline states and their device; it never transfers ownership.
class IOSShadingPrototypePipelineNativeAccess final {
  public:
    [[nodiscard]] static bool borrow(
        const IOSShadingPrototypePipeline& pipeline,
        IOSShadingPrototypePipelineNativeView& view) noexcept;
  };
