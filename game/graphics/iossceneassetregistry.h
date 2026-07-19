#pragma once

#include "iosscenesnapshot.h"

#include <Tempest/MetalApi>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <unordered_map>

namespace Tempest {
class Device;
class StorageBuffer;
class Texture2d;
}

enum class IOSSceneMeshValidation : uint8_t {
  Valid,
  InvalidRegistryGeneration,
  EmptyHandle,
  GenerationMismatch,
  EmptyVertexBuffer,
  EmptyIndexBuffer,
  InvalidVertexStride,
  VertexBufferSizeMismatch,
  EmptyIndexCount,
  NonTriangleIndexCount,
  IndexRangeOverflow,
  IndexBufferSizeMismatch,
  IndexRangeOutOfBounds,
  InvalidBounds,
  };

enum class IOSSceneTextureFormat : uint8_t {
  Invalid,
  Rgba8Unorm,
  Bc1Rgba,
  Bc2Rgba,
  Bc3Rgba,
  };

enum class IOSSceneTextureValidation : uint8_t {
  Valid,
  InvalidRegistryGeneration,
  EmptyHandle,
  GenerationMismatch,
  EmptyWidth,
  EmptyHeight,
  EmptyMipCount,
  ExcessiveMipCount,
  UnsupportedFormat,
  };

enum class IOSSceneAssetBindResult : uint8_t {
  Bound,
  AlreadyBound,
  InvalidDevice,
  ResetRequired,
  InvalidHandle,
  InvalidMetadata,
  NativeHandleUnavailable,
  Conflict,
  };

enum class IOSSceneAssetRegistryState : uint8_t {
  Uninitialized,
  Active,
  ResetRequired,
  };

struct IOSSceneMeshMetadata final {
  std::size_t vertexBufferByteSize = 0;
  std::size_t indexBufferByteSize  = 0;
  std::size_t vertexStride         = 0;
  // Index data is uint32_t in this first slice. firstIndex is an element
  // offset, never a byte offset.
  std::size_t firstIndex           = 0;
  std::size_t indexCount           = 0;
  IOSBounds   bounds;

  constexpr bool operator==(const IOSSceneMeshMetadata&) const noexcept = default;
  };

struct IOSSceneTextureMetadata final {
  uint32_t              width    = 0;
  uint32_t              height   = 0;
  uint32_t              mipCount = 0;
  IOSSceneTextureFormat format   = IOSSceneTextureFormat::Invalid;

  constexpr bool operator==(const IOSSceneTextureMetadata&) const noexcept = default;
  };

struct IOSSceneMeshAsset final {
  Tempest::BorrowedMetalBuffer vertexBuffer;
  Tempest::BorrowedMetalBuffer indexBuffer;
  IOSSceneMeshMetadata         metadata;
  };

struct IOSSceneTextureAsset final {
  Tempest::BorrowedMetalTexture texture;
  IOSSceneTextureMetadata       metadata;
  };

class IOSSceneAssetRegistry final {
  public:
    IOSSceneAssetRegistry() noexcept = default;
    IOSSceneAssetRegistry(const Tempest::Device& device,
                          IOSWorldGeneration generation);
    IOSSceneAssetRegistry(const IOSSceneAssetRegistry&) = delete;
    IOSSceneAssetRegistry& operator=(const IOSSceneAssetRegistry&) = delete;
    IOSSceneAssetRegistry(IOSSceneAssetRegistry&&) = delete;
    IOSSceneAssetRegistry& operator=(IOSSceneAssetRegistry&&) = delete;

    [[nodiscard]]
    bool initialize(const Tempest::Device& device,
                    IOSWorldGeneration generation) noexcept;

    [[nodiscard]]
    bool isInitialized() const noexcept {
      return registryState!=IOSSceneAssetRegistryState::Uninitialized &&
             bool(worldGeneration) && bool(deviceHandle);
      }
    [[nodiscard]]
    IOSSceneAssetRegistryState state() const noexcept {
      return registryState;
      }
    [[nodiscard]]
    IOSWorldGeneration generation() const noexcept;
    [[nodiscard]]
    Tempest::BorrowedMetalDevice nativeDevice() const noexcept;

    [[nodiscard]]
    IOSSceneAssetBindResult bindMesh(const Tempest::Device& device,
                                     IOSMeshHandle handle,
                                     const Tempest::StorageBuffer& vertexBuffer,
                                     const Tempest::StorageBuffer& indexBuffer,
                                     std::size_t vertexStride,
                                     std::size_t firstIndex,
                                     std::size_t indexCount,
                                     IOSBounds bounds);

    [[nodiscard]]
    IOSSceneAssetBindResult bindTexture(const Tempest::Device& device,
                                        IOSTextureHandle handle,
                                        const Tempest::Texture2d& texture);

    [[nodiscard]]
    const IOSSceneMeshAsset* lookupMesh(IOSMeshHandle handle) const noexcept;
    [[nodiscard]]
    const IOSSceneTextureAsset* lookupTexture(
        IOSTextureHandle handle) const noexcept;

    // The caller promises that the RendererIOS confirmed-idle gate completed.
    // This method releases only borrowed views and neutral metadata.
    void clearAfterConfirmedIdle() noexcept {
      meshes.clear();
      textures.clear();
      if(isInitialized())
        registryState = IOSSceneAssetRegistryState::ResetRequired;
      }

    // Deliberately does not clear assets. A generation can change only after
    // clearAfterConfirmedIdle() established the lifecycle ordering.
    [[nodiscard]]
    bool resetGeneration(const Tempest::Device& device,
                         IOSWorldGeneration generation) noexcept;

    [[nodiscard]]
    static IOSSceneMeshValidation validateMeshBinding(
        IOSWorldGeneration registryGeneration,
        IOSMeshHandle handle,
        std::size_t vertexBufferByteSize,
        std::size_t indexBufferByteSize,
        std::size_t vertexStride,
        std::size_t firstIndex,
        std::size_t indexCount,
        IOSBounds bounds) noexcept;

    [[nodiscard]]
    static IOSSceneTextureValidation validateTextureBinding(
        IOSWorldGeneration registryGeneration,
        IOSTextureHandle handle,
        uint32_t width,
        uint32_t height,
        uint32_t mipCount,
        IOSSceneTextureFormat format) noexcept;

    [[nodiscard]]
    static constexpr bool canAdvanceGeneration(
        IOSWorldGeneration current,
        IOSWorldGeneration next) noexcept {
      return bool(current) && next.value>current.value;
      }

  private:
    [[nodiscard]]
    bool matchesDevice(const Tempest::Device& device) const noexcept;

    IOSWorldGeneration           worldGeneration;
    Tempest::BorrowedMetalDevice deviceHandle;
    std::unordered_map<uint64_t,IOSSceneMeshAsset>    meshes;
    std::unordered_map<uint64_t,IOSSceneTextureAsset> textures;
    IOSSceneAssetRegistryState registryState =
        IOSSceneAssetRegistryState::Uninitialized;
  };

inline IOSSceneMeshValidation IOSSceneAssetRegistry::validateMeshBinding(
    IOSWorldGeneration registryGeneration,
    IOSMeshHandle handle,
    std::size_t vertexBufferByteSize,
    std::size_t indexBufferByteSize,
    std::size_t vertexStride,
    std::size_t firstIndex,
    std::size_t indexCount,
    IOSBounds bounds) noexcept {
  if(!registryGeneration)
    return IOSSceneMeshValidation::InvalidRegistryGeneration;
  if(!handle)
    return IOSSceneMeshValidation::EmptyHandle;
  if(handle.generation!=registryGeneration)
    return IOSSceneMeshValidation::GenerationMismatch;
  if(vertexBufferByteSize==0)
    return IOSSceneMeshValidation::EmptyVertexBuffer;
  if(indexBufferByteSize==0)
    return IOSSceneMeshValidation::EmptyIndexBuffer;
  if(vertexStride==0)
    return IOSSceneMeshValidation::InvalidVertexStride;

  if(vertexBufferByteSize<vertexStride ||
     vertexBufferByteSize%vertexStride!=0)
    return IOSSceneMeshValidation::VertexBufferSizeMismatch;
  if(indexCount==0)
    return IOSSceneMeshValidation::EmptyIndexCount;
  if(indexCount%std::size_t(3)!=0)
    return IOSSceneMeshValidation::NonTriangleIndexCount;
  if(indexCount>std::numeric_limits<std::size_t>::max()-firstIndex)
    return IOSSceneMeshValidation::IndexRangeOverflow;

  constexpr std::size_t IndexSize = sizeof(uint32_t);
  if(indexBufferByteSize%IndexSize!=0)
    return IOSSceneMeshValidation::IndexBufferSizeMismatch;

  const std::size_t availableIndices = indexBufferByteSize/IndexSize;
  if(firstIndex>availableIndices ||
     indexCount>availableIndices-firstIndex)
    return IOSSceneMeshValidation::IndexRangeOutOfBounds;

  const bool finiteBounds =
    std::isfinite(bounds.minimum.x) &&
    std::isfinite(bounds.minimum.y) &&
    std::isfinite(bounds.minimum.z) &&
    std::isfinite(bounds.maximum.x) &&
    std::isfinite(bounds.maximum.y) &&
    std::isfinite(bounds.maximum.z);
  const bool orderedBounds =
    bounds.minimum.x<=bounds.maximum.x &&
    bounds.minimum.y<=bounds.maximum.y &&
    bounds.minimum.z<=bounds.maximum.z;
  if(!finiteBounds || !orderedBounds)
    return IOSSceneMeshValidation::InvalidBounds;
  return IOSSceneMeshValidation::Valid;
  }

inline IOSSceneTextureValidation IOSSceneAssetRegistry::validateTextureBinding(
    IOSWorldGeneration registryGeneration,
    IOSTextureHandle handle,
    uint32_t width,
    uint32_t height,
    uint32_t mipCount,
    IOSSceneTextureFormat format) noexcept {
  if(!registryGeneration)
    return IOSSceneTextureValidation::InvalidRegistryGeneration;
  if(!handle)
    return IOSSceneTextureValidation::EmptyHandle;
  if(handle.generation!=registryGeneration)
    return IOSSceneTextureValidation::GenerationMismatch;
  if(width==0u)
    return IOSSceneTextureValidation::EmptyWidth;
  if(height==0u)
    return IOSSceneTextureValidation::EmptyHeight;
  if(mipCount==0u)
    return IOSSceneTextureValidation::EmptyMipCount;

  uint32_t maximumMipCount = 1u;
  uint32_t maximumExtent = width>height ? width : height;
  while(maximumExtent>1u) {
    maximumExtent /= 2u;
    ++maximumMipCount;
    }
  if(mipCount>maximumMipCount)
    return IOSSceneTextureValidation::ExcessiveMipCount;
  switch(format) {
    case IOSSceneTextureFormat::Rgba8Unorm:
    case IOSSceneTextureFormat::Bc1Rgba:
    case IOSSceneTextureFormat::Bc2Rgba:
    case IOSSceneTextureFormat::Bc3Rgba:
      break;
    case IOSSceneTextureFormat::Invalid:
      return IOSSceneTextureValidation::UnsupportedFormat;
    }
  if(format!=IOSSceneTextureFormat::Rgba8Unorm &&
     format!=IOSSceneTextureFormat::Bc1Rgba &&
     format!=IOSSceneTextureFormat::Bc2Rgba &&
     format!=IOSSceneTextureFormat::Bc3Rgba)
    return IOSSceneTextureValidation::UnsupportedFormat;
  return IOSSceneTextureValidation::Valid;
  }
