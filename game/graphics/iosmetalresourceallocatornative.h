#pragma once

namespace MTL {
class Texture;
}

class IOSMetalResourceTexture;

// Private Objective-C++ bridge. This header is not part of the public
// allocator contract and does not transfer ownership of the texture.
class IOSMetalResourceTextureNativeAccess final {
  public:
    [[nodiscard]] static MTL::Texture* borrow(
        const IOSMetalResourceTexture& texture) noexcept;
  };
