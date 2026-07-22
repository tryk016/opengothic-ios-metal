#include "iosmetalresourceallocator.h"

IOSMetalResourcePreflight iosMetalResourcePreflight(
    const IOSResourceDesc& resource) noexcept {
  IOSMetalResourcePreflight result;
  result.storage = resource.memoryless
                 ? IOSMetalResourceStorage::Memoryless
                 : IOSMetalResourceStorage::Private;

  const auto& layout = resource.layout;
  if(resource.kind!=IOSResourceKind::Texture ||
     resource.lifetime!=IOSResourceLifetime::Transient ||
     resource.initialContent!=IOSInitialContent::Undefined ||
     resource.aliasable || bool(resource.aliasGroup) ||
     layout.format!=IOSPixelFormat::Rgba8Unorm ||
     layout.extent.width==0u || layout.extent.height==0u ||
     layout.mipLevels!=1u || layout.sampleCount!=1u ||
     layout.byteSize!=0u ||
     resource.usage!=IOSResourceUsage::RenderAttachment)
    return result;

  result.status = IOSMetalResourcePreflightStatus::Supported;
  return result;
  }

const char* iosMetalResourcePreflightStatusName(
    IOSMetalResourcePreflightStatus status) noexcept {
  switch(status) {
    case IOSMetalResourcePreflightStatus::Supported:
      return "supported";
    case IOSMetalResourcePreflightStatus::Unsupported:
      return "unsupported";
    }
  return "unsupported";
  }

const char* iosMetalResourceStorageName(
    IOSMetalResourceStorage storage) noexcept {
  switch(storage) {
    case IOSMetalResourceStorage::Private:
      return "private";
    case IOSMetalResourceStorage::Memoryless:
      return "memoryless";
    case IOSMetalResourceStorage::Unknown:
      return "unknown";
    }
  return "unknown";
  }

bool iosMetalTextureMatches(const IOSMetalTextureSnapshot& texture,
                            const IOSResourceDesc& resource,
                            IOSMetalResourceStorage storage) noexcept {
  const IOSMetalResourcePreflight preflight =
      iosMetalResourcePreflight(resource);
  return bool(preflight) && preflight.storage==storage &&
         texture.available &&
         texture.textureIdentity!=0u && texture.deviceIdentity!=0u &&
         texture.type==IOSMetalTextureType::Type2D &&
         texture.format==resource.layout.format &&
         texture.extent==resource.layout.extent &&
         texture.mipLevels==resource.layout.mipLevels &&
         texture.sampleCount==resource.layout.sampleCount &&
         texture.depth==1u && texture.arrayLength==1u &&
         texture.usageExactlyRepresented &&
         texture.usage==resource.usage &&
         texture.storage==storage;
  }
