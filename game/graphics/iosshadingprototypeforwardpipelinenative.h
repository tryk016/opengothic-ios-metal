#pragma once

namespace MTL {
class ComputePipelineState;
class Device;
class RenderPipelineState;
}

class IOSShadingPrototypeForwardPipeline;

struct IOSShadingPrototypeForwardPipelineNativeView final {
  MTL::Device* device = nullptr;
  MTL::ComputePipelineState* buildLightList = nullptr;
  MTL::RenderPipelineState* opaque = nullptr;
  MTL::RenderPipelineState* alphaTest = nullptr;
  };

// Private Objective-C++ bridge. It borrows the already-created Forward
// pipeline states and their device; ownership never crosses this boundary.
class IOSShadingPrototypeForwardPipelineNativeAccess final {
  public:
    [[nodiscard]] static bool borrow(
        const IOSShadingPrototypeForwardPipeline& pipeline,
        IOSShadingPrototypeForwardPipelineNativeView& view) noexcept;
  };
