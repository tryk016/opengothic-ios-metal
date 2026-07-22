#include "iosmetalresourceallocator.h"
#include "iosmetalresourceallocatornative.h"

#include <Tempest/Device>
#include <Tempest/MetalApi>

#import <Metal/Metal.h>
#import <TargetConditionals.h>

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
#include <atomic>
#endif
#include <cstdint>
#include <memory>
#include <new>
#include <utility>

#if __has_feature(objc_arc)
#error "IOSMetalResourceAllocator requires the project's non-ARC Objective-C++ mode"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) && !TARGET_OS_IOS
#error "The IOSMetalResourceAllocator self-test is available only for iOS"
#endif

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) && !TARGET_OS_IOS
#error "The RendererIOS clear-only pass self-test is available only for iOS"
#endif

namespace {

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
struct ResourceLifetimeCounters final {
  std::atomic<uint64_t> created{0u};
  std::atomic<uint64_t> live{0u};
  std::atomic<uint64_t> released{0u};
  };

ResourceLifetimeCounters ResourceLifetime;
#endif

template<class T>
class OwnedObjectiveC final {
  public:
    explicit OwnedObjectiveC(T value = nil) noexcept
      : value(value) {
      }

    ~OwnedObjectiveC() {
      [value release];
      }

    OwnedObjectiveC(const OwnedObjectiveC&) = delete;
    OwnedObjectiveC& operator=(const OwnedObjectiveC&) = delete;

    T get() const noexcept {
      return value;
      }

    T relinquish() noexcept {
      const T result = value;
      value = nil;
      return result;
      }

  private:
    T value = nil;
  };

bool nativeStorage(IOSMetalResourceStorage storage,
                   MTLStorageMode& result) noexcept {
  switch(storage) {
    case IOSMetalResourceStorage::Private:
      result = MTLStorageModePrivate;
      return true;
    case IOSMetalResourceStorage::Memoryless:
#if TARGET_OS_IOS
      result = MTLStorageModeMemoryless;
      return true;
#else
      return false;
#endif
    case IOSMetalResourceStorage::Unknown:
      break;
    }
  return false;
  }

IOSMetalResourceStorage neutralStorage(MTLStorageMode storage) noexcept {
  switch(storage) {
    case MTLStorageModePrivate:
      return IOSMetalResourceStorage::Private;
#if TARGET_OS_IOS
    case MTLStorageModeMemoryless:
      return IOSMetalResourceStorage::Memoryless;
#endif
    default:
      return IOSMetalResourceStorage::Unknown;
    }
  }

IOSMetalTextureSnapshot snapshotFor(id<MTLTexture> texture) noexcept {
  IOSMetalTextureSnapshot result;
  if(texture==nil)
    return result;

  result.available = true;
  result.textureIdentity = reinterpret_cast<uintptr_t>((void*)texture);
  result.deviceIdentity =
      reinterpret_cast<uintptr_t>((void*)texture.device);
  result.type = texture.textureType==MTLTextureType2D
              ? IOSMetalTextureType::Type2D
              : IOSMetalTextureType::Unknown;
  result.format = texture.pixelFormat==MTLPixelFormatRGBA8Unorm
                ? IOSPixelFormat::Rgba8Unorm
                : IOSPixelFormat::Undefined;
  result.extent = {static_cast<uint32_t>(texture.width),
                   static_cast<uint32_t>(texture.height)};
  result.mipLevels = static_cast<uint32_t>(texture.mipmapLevelCount);
  result.sampleCount = static_cast<uint32_t>(texture.sampleCount);
  result.depth = static_cast<uint32_t>(texture.depth);
  result.arrayLength = static_cast<uint32_t>(texture.arrayLength);
  result.usageExactlyRepresented =
      texture.usage==MTLTextureUsageRenderTarget;
  if(result.usageExactlyRepresented)
    result.usage = IOSResourceUsage::RenderAttachment;
  result.storage = neutralStorage(texture.storageMode);
  return result;
  }

}

struct IOSMetalResourceTexture::Impl final {
  explicit Impl(id<MTLTexture> texture) noexcept
    : texture(texture) {
#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
    ResourceLifetime.created.fetch_add(1u,std::memory_order_relaxed);
    ResourceLifetime.live.fetch_add(1u,std::memory_order_relaxed);
#endif
    }

  ~Impl() {
    [texture release];
#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
    ResourceLifetime.live.fetch_sub(1u,std::memory_order_relaxed);
    ResourceLifetime.released.fetch_add(1u,std::memory_order_relaxed);
#endif
    }

  Impl(const Impl&) = delete;
  Impl& operator=(const Impl&) = delete;

  id<MTLTexture> texture = nil;
  };

#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)
IOSMetalResourceLifetimeSnapshot iosMetalResourceLifetimeSnapshot() noexcept {
  IOSMetalResourceLifetimeSnapshot result;
  result.created = ResourceLifetime.created.load(std::memory_order_relaxed);
  result.live = ResourceLifetime.live.load(std::memory_order_relaxed);
  result.released = ResourceLifetime.released.load(std::memory_order_relaxed);
  return result;
  }
#endif

MTL::Texture* IOSMetalResourceTextureNativeAccess::borrow(
    const IOSMetalResourceTexture& texture) noexcept {
  if(texture.impl==nullptr || texture.impl->texture==nil)
    return nullptr;
  return reinterpret_cast<MTL::Texture*>((void*)texture.impl->texture);
  }

IOSMetalResourceTexture::IOSMetalResourceTexture() noexcept = default;
IOSMetalResourceTexture::~IOSMetalResourceTexture() = default;
IOSMetalResourceTexture::IOSMetalResourceTexture(
    IOSMetalResourceTexture&& other) noexcept = default;
IOSMetalResourceTexture& IOSMetalResourceTexture::operator=(
    IOSMetalResourceTexture&& other) noexcept = default;

IOSMetalResourceTexture::IOSMetalResourceTexture(
    std::unique_ptr<Impl>&& impl) noexcept
  : impl(std::move(impl)) {
  }

IOSMetalResourceTexture::operator bool() const noexcept {
  return impl!=nullptr && impl->texture!=nil;
  }

IOSMetalTextureSnapshot IOSMetalResourceTexture::snapshot() const noexcept {
  return impl!=nullptr ? snapshotFor(impl->texture)
                       : IOSMetalTextureSnapshot{};
  }

IOSMetalResourceAllocator::IOSMetalResourceAllocator(
    Tempest::Device& device) noexcept
  : device(&device) {
  }

IOSMetalResourceTexture IOSMetalResourceAllocator::allocate(
    const IOSResourceDesc& resource) const noexcept {
  const IOSMetalResourcePreflight preflight =
      iosMetalResourcePreflight(resource);
  if(!preflight || device==nullptr)
    return {};

  const Tempest::BorrowedMetalDevice borrowed =
      Tempest::MetalApi::borrowDevice(*device);
  if(!borrowed)
    return {};
  id<MTLDevice> nativeDevice = (id<MTLDevice>)(void*)borrowed.get();
  if(nativeDevice==nil)
    return {};

  OwnedObjectiveC<MTLTextureDescriptor*> descriptor(
      [[MTLTextureDescriptor alloc] init]);
  if(descriptor.get()==nil)
    return {};
  descriptor.get().textureType = MTLTextureType2D;
  descriptor.get().pixelFormat = MTLPixelFormatRGBA8Unorm;
  descriptor.get().width = static_cast<NSUInteger>(resource.layout.extent.width);
  descriptor.get().height = static_cast<NSUInteger>(resource.layout.extent.height);
  descriptor.get().depth = NSUInteger(1u);
  descriptor.get().mipmapLevelCount = NSUInteger(1u);
  descriptor.get().sampleCount = NSUInteger(1u);
  descriptor.get().arrayLength = NSUInteger(1u);
  descriptor.get().usage = MTLTextureUsageRenderTarget;
  MTLStorageMode storage = MTLStorageModePrivate;
  if(!nativeStorage(preflight.storage,storage))
    return {};
  descriptor.get().storageMode = storage;

  OwnedObjectiveC<id<MTLTexture>> texture(
      [nativeDevice newTextureWithDescriptor:descriptor.get()]);
  if(texture.get()==nil)
    return {};

  const IOSMetalTextureSnapshot snapshot = snapshotFor(texture.get());
  if(snapshot.deviceIdentity!=
         reinterpret_cast<uintptr_t>((void*)nativeDevice) ||
     !iosMetalTextureMatches(snapshot,resource,preflight.storage))
    return {};

  try {
    std::unique_ptr<IOSMetalResourceTexture::Impl> impl(
        new IOSMetalResourceTexture::Impl(texture.relinquish()));
    return IOSMetalResourceTexture(std::move(impl));
  } catch(...) {
    return {};
    }
  }
