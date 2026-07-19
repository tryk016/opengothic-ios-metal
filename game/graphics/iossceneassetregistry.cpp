#include "iossceneassetregistry.h"

#include <Tempest/Device>
#include <Tempest/StorageBuffer>
#include <Tempest/Texture2d>

#include <stdexcept>

namespace {

bool sameBuffer(Tempest::BorrowedMetalBuffer lhs,
                Tempest::BorrowedMetalBuffer rhs) noexcept {
  return lhs.get()==rhs.get();
  }

bool sameTexture(Tempest::BorrowedMetalTexture lhs,
                 Tempest::BorrowedMetalTexture rhs) noexcept {
  return lhs.get()==rhs.get();
  }

IOSSceneTextureFormat textureFormat(Tempest::TextureFormat format) noexcept {
  switch(format) {
    case Tempest::TextureFormat::RGBA8:
      return IOSSceneTextureFormat::Rgba8Unorm;
    case Tempest::TextureFormat::DXT1:
      return IOSSceneTextureFormat::Bc1Rgba;
    case Tempest::TextureFormat::DXT3:
      return IOSSceneTextureFormat::Bc2Rgba;
    case Tempest::TextureFormat::DXT5:
      return IOSSceneTextureFormat::Bc3Rgba;
    default:
      return IOSSceneTextureFormat::Invalid;
    }
  }

}

IOSSceneAssetRegistry::IOSSceneAssetRegistry(
    const Tempest::Device& device,
    IOSWorldGeneration generation) {
  if(!initialize(device,generation))
    throw std::invalid_argument(
      "RendererIOS asset registry requires a Metal device and non-zero generation");
  }

bool IOSSceneAssetRegistry::initialize(
    const Tempest::Device& device,
    IOSWorldGeneration generation) noexcept {
  if(registryState!=IOSSceneAssetRegistryState::Uninitialized ||
     !generation || !meshes.empty() || !textures.empty())
    return false;

#if defined(__APPLE__)
  const auto borrowedDevice = Tempest::MetalApi::borrowDevice(device);
  if(!borrowedDevice)
    return false;

  worldGeneration = generation;
  deviceHandle     = borrowedDevice;
  registryState    = IOSSceneAssetRegistryState::Active;
  return true;
#else
  (void)device;
  return false;
#endif
  }

IOSWorldGeneration IOSSceneAssetRegistry::generation() const noexcept {
  return worldGeneration;
  }

Tempest::BorrowedMetalDevice IOSSceneAssetRegistry::nativeDevice() const noexcept {
  return deviceHandle;
  }

IOSSceneAssetBindResult IOSSceneAssetRegistry::bindMesh(
    const Tempest::Device& device,
    IOSMeshHandle handle,
    const Tempest::StorageBuffer& vertexBuffer,
    const Tempest::StorageBuffer& indexBuffer,
    std::size_t vertexStride,
    std::size_t firstIndex,
    std::size_t indexCount,
    IOSBounds bounds) {
  if(!isInitialized() || !matchesDevice(device))
    return IOSSceneAssetBindResult::InvalidDevice;
  if(registryState!=IOSSceneAssetRegistryState::Active)
    return IOSSceneAssetBindResult::ResetRequired;

  const IOSSceneMeshMetadata metadata = {
    vertexBuffer.byteSize(),
    indexBuffer.byteSize(),
    vertexStride,
    firstIndex,
    indexCount,
    bounds,
    };
  const auto validation = validateMeshBinding(
    worldGeneration,handle,metadata.vertexBufferByteSize,
    metadata.indexBufferByteSize,metadata.vertexStride,metadata.firstIndex,
    metadata.indexCount,metadata.bounds);
  if(validation==IOSSceneMeshValidation::EmptyHandle ||
     validation==IOSSceneMeshValidation::GenerationMismatch)
    return IOSSceneAssetBindResult::InvalidHandle;
  if(validation!=IOSSceneMeshValidation::Valid)
    return IOSSceneAssetBindResult::InvalidMetadata;

  Tempest::BorrowedMetalBuffer nativeVertex;
  Tempest::BorrowedMetalBuffer nativeIndex;
#if defined(__APPLE__)
  nativeVertex = Tempest::MetalApi::borrowBuffer(device,vertexBuffer);
  nativeIndex  = Tempest::MetalApi::borrowBuffer(device,indexBuffer);
  if(!nativeVertex || !nativeIndex)
    return IOSSceneAssetBindResult::NativeHandleUnavailable;
#else
  return IOSSceneAssetBindResult::NativeHandleUnavailable;
#endif

  const IOSSceneMeshAsset asset = {nativeVertex,nativeIndex,metadata};
  if(const auto found=meshes.find(handle.value); found!=meshes.end()) {
    const auto& current = found->second;
    if(sameBuffer(current.vertexBuffer,asset.vertexBuffer) &&
       sameBuffer(current.indexBuffer,asset.indexBuffer) &&
       current.metadata==asset.metadata)
      return IOSSceneAssetBindResult::AlreadyBound;
    return IOSSceneAssetBindResult::Conflict;
    }

  meshes.emplace(handle.value,asset);
  return IOSSceneAssetBindResult::Bound;
  }

IOSSceneAssetBindResult IOSSceneAssetRegistry::bindTexture(
    const Tempest::Device& device,
    IOSTextureHandle handle,
    const Tempest::Texture2d& texture) {
  if(!isInitialized() || !matchesDevice(device))
    return IOSSceneAssetBindResult::InvalidDevice;
  if(registryState!=IOSSceneAssetRegistryState::Active)
    return IOSSceneAssetBindResult::ResetRequired;

  const IOSSceneTextureMetadata metadata = {
    texture.w()>0 ? static_cast<uint32_t>(texture.w()) : 0u,
    texture.h()>0 ? static_cast<uint32_t>(texture.h()) : 0u,
    texture.mipCount(),
    textureFormat(texture.format()),
    };
  const auto validation = validateTextureBinding(
      worldGeneration,handle,metadata.width,metadata.height,
      metadata.mipCount,metadata.format);
  if(validation==IOSSceneTextureValidation::EmptyHandle ||
     validation==IOSSceneTextureValidation::GenerationMismatch)
    return IOSSceneAssetBindResult::InvalidHandle;
  if(validation!=IOSSceneTextureValidation::Valid)
    return IOSSceneAssetBindResult::InvalidMetadata;

  Tempest::BorrowedMetalTexture nativeTexture;
#if defined(__APPLE__)
  nativeTexture = Tempest::MetalApi::borrowTexture(device,texture);
  if(!nativeTexture)
    return IOSSceneAssetBindResult::NativeHandleUnavailable;
#else
  return IOSSceneAssetBindResult::NativeHandleUnavailable;
#endif

  const IOSSceneTextureAsset asset = {nativeTexture,metadata};
  if(const auto found=textures.find(handle.value); found!=textures.end()) {
    const auto& current = found->second;
    if(sameTexture(current.texture,asset.texture) &&
       current.metadata==asset.metadata)
      return IOSSceneAssetBindResult::AlreadyBound;
    return IOSSceneAssetBindResult::Conflict;
    }

  textures.emplace(handle.value,asset);
  return IOSSceneAssetBindResult::Bound;
  }

const IOSSceneMeshAsset* IOSSceneAssetRegistry::lookupMesh(
    IOSMeshHandle handle) const noexcept {
  if(!isInitialized() || !handle || handle.generation!=worldGeneration)
    return nullptr;
  const auto found = meshes.find(handle.value);
  return found!=meshes.end() ? &found->second : nullptr;
  }

const IOSSceneTextureAsset* IOSSceneAssetRegistry::lookupTexture(
    IOSTextureHandle handle) const noexcept {
  if(!isInitialized() || !handle || handle.generation!=worldGeneration)
    return nullptr;
  const auto found = textures.find(handle.value);
  return found!=textures.end() ? &found->second : nullptr;
  }

bool IOSSceneAssetRegistry::resetGeneration(
    const Tempest::Device& device,
    IOSWorldGeneration generation) noexcept {
  if(!isInitialized() ||
     registryState!=IOSSceneAssetRegistryState::ResetRequired ||
     !canAdvanceGeneration(worldGeneration,generation) ||
     !meshes.empty() || !textures.empty())
    return false;

#if defined(__APPLE__)
  const auto borrowedDevice = Tempest::MetalApi::borrowDevice(device);
  if(!borrowedDevice)
    return false;

  worldGeneration = generation;
  deviceHandle     = borrowedDevice;
  registryState    = IOSSceneAssetRegistryState::Active;
  return true;
#else
  (void)device;
  return false;
#endif
  }

bool IOSSceneAssetRegistry::matchesDevice(
    const Tempest::Device& device) const noexcept {
#if defined(__APPLE__)
  const auto borrowedDevice = Tempest::MetalApi::borrowDevice(device);
  return borrowedDevice && borrowedDevice.get()==deviceHandle.get();
#else
  (void)device;
  return false;
#endif
  }
