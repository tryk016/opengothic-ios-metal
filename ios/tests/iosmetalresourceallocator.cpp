#include "graphics/iosmetalresourceallocator.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <type_traits>
#include <utility>

namespace {

IOSResourceDesc supportedResource(bool memoryless = false) {
  IOSResourceDesc resource;
  resource.id = {7u};
  resource.kind = IOSResourceKind::Texture;
  resource.lifetime = IOSResourceLifetime::Transient;
  resource.initialContent = IOSInitialContent::Undefined;
  resource.memoryless = memoryless;
  resource.aliasable = false;
  resource.aliasGroup = {};
  resource.layout.format = IOSPixelFormat::Rgba8Unorm;
  resource.layout.extent = {64u,32u};
  resource.layout.mipLevels = 1u;
  resource.layout.sampleCount = 1u;
  resource.layout.byteSize = 0u;
  resource.usage = IOSResourceUsage::RenderAttachment;
  return resource;
  }

using Mutator = void (*)(IOSResourceDesc&) noexcept;

void kind(IOSResourceDesc& r) noexcept {
  r.kind = IOSResourceKind::Buffer;
  }
void lifetime(IOSResourceDesc& r) noexcept {
  r.lifetime = IOSResourceLifetime::PerFrame;
  }
void initialContent(IOSResourceDesc& r) noexcept {
  r.initialContent = IOSInitialContent::Defined;
  }
void aliasable(IOSResourceDesc& r) noexcept {
  r.aliasable = true;
  }
void aliasGroup(IOSResourceDesc& r) noexcept {
  r.aliasGroup = {1u};
  }
void format(IOSResourceDesc& r) noexcept {
  r.layout.format = IOSPixelFormat::Bgra8Unorm;
  }
void width(IOSResourceDesc& r) noexcept {
  r.layout.extent.width = 0u;
  }
void height(IOSResourceDesc& r) noexcept {
  r.layout.extent.height = 0u;
  }
void mipLevels(IOSResourceDesc& r) noexcept {
  r.layout.mipLevels = 2u;
  }
void sampleCount(IOSResourceDesc& r) noexcept {
  r.layout.sampleCount = 2u;
  }
void byteSize(IOSResourceDesc& r) noexcept {
  r.layout.byteSize = 4u;
  }
void usageMissing(IOSResourceDesc& r) noexcept {
  r.usage = IOSResourceUsage::ShaderRead;
  }
void usageSuperset(IOSResourceDesc& r) noexcept {
  r.usage = IOSResourceUsage::RenderAttachment|
            IOSResourceUsage::ShaderRead;
  }

constexpr std::array<Mutator,13u> NegativeMutators = {
  kind,lifetime,initialContent,aliasable,aliasGroup,format,width,height,
  mipLevels,sampleCount,byteSize,usageMissing,usageSuperset,
  };

IOSMetalTextureSnapshot matchingSnapshot(
    const IOSResourceDesc& resource,
    IOSMetalResourceStorage storage) {
  IOSMetalTextureSnapshot texture;
  texture.available = true;
  texture.textureIdentity = 0x100u;
  texture.deviceIdentity = 0x200u;
  texture.type = IOSMetalTextureType::Type2D;
  texture.format = resource.layout.format;
  texture.extent = resource.layout.extent;
  texture.mipLevels = resource.layout.mipLevels;
  texture.sampleCount = resource.layout.sampleCount;
  texture.depth = 1u;
  texture.arrayLength = 1u;
  texture.usage = resource.usage;
  texture.usageExactlyRepresented = true;
  texture.storage = storage;
  return texture;
  }

bool rejectsSnapshotMutations(const IOSResourceDesc& resource) {
  const IOSMetalResourceStorage storage = IOSMetalResourceStorage::Private;
  IOSMetalTextureSnapshot texture = matchingSnapshot(resource,storage);

  texture.available = false;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.textureIdentity = 0u;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.deviceIdentity = 0u;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.type = IOSMetalTextureType::Unknown;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.format = IOSPixelFormat::Bgra8Unorm;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.extent.width += 1u;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.extent.height += 1u;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.mipLevels += 1u;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.sampleCount += 1u;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.depth += 1u;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.arrayLength += 1u;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.usage = IOSResourceUsage::ShaderRead;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.usageExactlyRepresented = false;
  if(iosMetalTextureMatches(texture,resource,storage))
    return false;
  texture = matchingSnapshot(resource,storage);
  texture.storage = IOSMetalResourceStorage::Memoryless;
  return !iosMetalTextureMatches(texture,resource,storage);
  }

}

int main() {
#if defined(OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST)
  static_assert(std::is_aggregate_v<IOSMetalResourceLifetimeSnapshot>);
  static_assert(std::is_trivially_copyable_v<
                    IOSMetalResourceLifetimeSnapshot>);
  static_assert(std::is_same_v<
                    decltype(&iosMetalResourceLifetimeSnapshot),
                    IOSMetalResourceLifetimeSnapshot (*)() noexcept>);
#endif
  static_assert(static_cast<uint8_t>(
                    IOSMetalResourcePreflightStatus::Supported)==0u);
  static_assert(static_cast<uint8_t>(
                    IOSMetalResourcePreflightStatus::Unsupported)==1u);
  static_assert(static_cast<uint8_t>(IOSMetalResourceStorage::Private)==0u);
  static_assert(static_cast<uint8_t>(IOSMetalResourceStorage::Memoryless)==1u);
  static_assert(static_cast<uint8_t>(IOSMetalResourceStorage::Unknown)==0xFFu);
  static_assert(!std::is_copy_constructible_v<IOSMetalResourceTexture>);
  static_assert(!std::is_copy_assignable_v<IOSMetalResourceTexture>);
  static_assert(std::is_nothrow_move_constructible_v<IOSMetalResourceTexture>);
  static_assert(std::is_nothrow_move_assignable_v<IOSMetalResourceTexture>);
  static_assert(!std::is_copy_constructible_v<IOSMetalResourceAllocator>);
  static_assert(!std::is_move_constructible_v<IOSMetalResourceAllocator>);

  const IOSResourceDesc privateResource = supportedResource(false);
  const IOSMetalResourcePreflight privatePreflight =
      iosMetalResourcePreflight(privateResource);
  if(!privatePreflight ||
     privatePreflight.status!=IOSMetalResourcePreflightStatus::Supported ||
     privatePreflight.storage!=IOSMetalResourceStorage::Private)
    return 1;

  const IOSResourceDesc memorylessResource = supportedResource(true);
  const IOSMetalResourcePreflight memorylessPreflight =
      iosMetalResourcePreflight(memorylessResource);
  if(!memorylessPreflight ||
     memorylessPreflight.storage!=IOSMetalResourceStorage::Memoryless)
    return 2;

  IOSResourceDesc differentId = privateResource;
  differentId.id = {99u};
  if(!iosMetalResourcePreflight(differentId))
    return 3;

  for(std::size_t i=0u; i<NegativeMutators.size(); ++i) {
    IOSResourceDesc mutated = privateResource;
    NegativeMutators[i](mutated);
    const IOSMetalResourcePreflight result =
        iosMetalResourcePreflight(mutated);
    if(result.status!=IOSMetalResourcePreflightStatus::Unsupported)
      return static_cast<int>(10u+i);
    }

  const IOSMetalTextureSnapshot privateSnapshot =
      matchingSnapshot(privateResource,IOSMetalResourceStorage::Private);
  if(!iosMetalTextureMatches(privateSnapshot,privateResource,
                             IOSMetalResourceStorage::Private))
    return 30;
  const IOSMetalTextureSnapshot memorylessSnapshot =
      matchingSnapshot(memorylessResource,IOSMetalResourceStorage::Memoryless);
  if(!iosMetalTextureMatches(memorylessSnapshot,memorylessResource,
                             IOSMetalResourceStorage::Memoryless))
    return 31;
  if(iosMetalTextureMatches(privateSnapshot,privateResource,
                            IOSMetalResourceStorage::Memoryless))
    return 32;
  if(!rejectsSnapshotMutations(privateResource))
    return 33;

  if(iosMetalResourcePreflightStatusName(
         IOSMetalResourcePreflightStatus::Supported)!=
         std::string_view("supported") ||
     iosMetalResourcePreflightStatusName(
         IOSMetalResourcePreflightStatus::Unsupported)!=
         std::string_view("unsupported") ||
     iosMetalResourcePreflightStatusName(
         static_cast<IOSMetalResourcePreflightStatus>(0xFFu))!=
         std::string_view("unsupported"))
    return 34;
  if(iosMetalResourceStorageName(IOSMetalResourceStorage::Private)!=
         std::string_view("private") ||
     iosMetalResourceStorageName(IOSMetalResourceStorage::Memoryless)!=
         std::string_view("memoryless") ||
     iosMetalResourceStorageName(IOSMetalResourceStorage::Unknown)!=
         std::string_view("unknown") ||
     iosMetalResourceStorageName(
         static_cast<IOSMetalResourceStorage>(0x7Fu))!=
         std::string_view("unknown"))
    return 35;
  return 0;
  }
