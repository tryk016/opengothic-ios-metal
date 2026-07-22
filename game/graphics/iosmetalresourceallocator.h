#pragma once

#include "iosframeplan.h"

#include <cstdint>
#include <memory>

namespace Tempest {
class Device;
}

enum class IOSMetalResourcePreflightStatus : uint8_t {
  Supported   = 0,
  Unsupported = 1,
  };

enum class IOSMetalResourceStorage : uint8_t {
  Private    = 0,
  Memoryless = 1,
  Unknown    = 0xFF,
  };

struct IOSMetalResourcePreflight final {
  IOSMetalResourcePreflightStatus status =
      IOSMetalResourcePreflightStatus::Unsupported;
  IOSMetalResourceStorage storage = IOSMetalResourceStorage::Private;

  explicit operator bool() const noexcept {
    return status==IOSMetalResourcePreflightStatus::Supported;
    }
  };

// The descriptor is expected to come from an already validated ABI 4 plan.
// Descriptors outside this allocation-only slice are Unsupported, not invalid.
[[nodiscard]] IOSMetalResourcePreflight iosMetalResourcePreflight(
    const IOSResourceDesc& resource) noexcept;

const char* iosMetalResourcePreflightStatusName(
    IOSMetalResourcePreflightStatus status) noexcept;
const char* iosMetalResourceStorageName(
    IOSMetalResourceStorage storage) noexcept;

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
// Diagnostic-only process counters. The API and native atomic accounting are
// compiled out unless one of the two allocator lifetime probes is enabled.
struct IOSMetalResourceLifetimeSnapshot final {
  uint64_t created = 0u;
  uint64_t live = 0u;
  uint64_t released = 0u;

  friend bool operator==(IOSMetalResourceLifetimeSnapshot,
                         IOSMetalResourceLifetimeSnapshot) = default;
  };

[[nodiscard]] IOSMetalResourceLifetimeSnapshot
    iosMetalResourceLifetimeSnapshot() noexcept;
#endif

enum class IOSMetalTextureType : uint8_t {
  Unknown = 0,
  Type2D  = 1,
  };

// Host-neutral diagnostic view. uintptr_t values are identity-only and never
// confer ownership or permission to dereference/release a native object.
struct IOSMetalTextureSnapshot final {
  bool                    available = false;
  uintptr_t               textureIdentity = 0u;
  uintptr_t               deviceIdentity = 0u;
  IOSMetalTextureType     type = IOSMetalTextureType::Unknown;
  IOSPixelFormat          format = IOSPixelFormat::Undefined;
  IOSExtent2D             extent;
  uint32_t                mipLevels = 0u;
  uint32_t                sampleCount = 0u;
  uint32_t                depth = 0u;
  uint32_t                arrayLength = 0u;
  IOSResourceUsage        usage = IOSResourceUsage::None;
  bool                    usageExactlyRepresented = false;
  IOSMetalResourceStorage storage = IOSMetalResourceStorage::Unknown;
  };

[[nodiscard]] bool iosMetalTextureMatches(
    const IOSMetalTextureSnapshot& texture,
    const IOSResourceDesc& resource,
    IOSMetalResourceStorage storage) noexcept;

class IOSMetalResourceTexture final {
  public:
    IOSMetalResourceTexture() noexcept;
    ~IOSMetalResourceTexture();

    IOSMetalResourceTexture(const IOSMetalResourceTexture&) = delete;
    IOSMetalResourceTexture& operator=(const IOSMetalResourceTexture&) = delete;

    IOSMetalResourceTexture(IOSMetalResourceTexture&& other) noexcept;
    IOSMetalResourceTexture& operator=(IOSMetalResourceTexture&& other) noexcept;

    explicit operator bool() const noexcept;
    [[nodiscard]] IOSMetalTextureSnapshot snapshot() const noexcept;

  private:
    struct Impl;
    explicit IOSMetalResourceTexture(std::unique_ptr<Impl>&& impl) noexcept;

    std::unique_ptr<Impl> impl;

  friend class IOSMetalResourceAllocator;
  friend class IOSMetalResourceTextureNativeAccess;
  };

class IOSMetalResourceAllocator final {
  public:
    explicit IOSMetalResourceAllocator(Tempest::Device& device) noexcept;

    IOSMetalResourceAllocator(const IOSMetalResourceAllocator&) = delete;
    IOSMetalResourceAllocator& operator=(const IOSMetalResourceAllocator&) = delete;
    IOSMetalResourceAllocator(IOSMetalResourceAllocator&&) = delete;
    IOSMetalResourceAllocator& operator=(IOSMetalResourceAllocator&&) = delete;

    [[nodiscard]] IOSMetalResourceTexture allocate(
        const IOSResourceDesc& resource) const noexcept;

  private:
    Tempest::Device* device = nullptr;
  };
