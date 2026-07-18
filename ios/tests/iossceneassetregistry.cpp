#include "graphics/iossceneassetregistry.h"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace {

constexpr IOSWorldGeneration Generation{7};
constexpr IOSMeshHandle Mesh{Generation,11};
constexpr IOSBounds Bounds{{-1.f,-2.f,-3.f},{1.f,2.f,3.f}};

IOSSceneMeshValidation validate(
    std::size_t vertexBytes = 96,
    std::size_t indexBytes = 24,
    std::size_t stride = 32,
    std::size_t firstIndex = 0,
    std::size_t indexCount = 6,
    IOSBounds bounds = Bounds,
    IOSMeshHandle handle = Mesh,
    IOSWorldGeneration generation = Generation) {
  return IOSSceneAssetRegistry::validateMeshBinding(
    generation,handle,vertexBytes,indexBytes,stride,firstIndex,indexCount,bounds);
  }

void validatePublicContract() {
  using BindMesh = IOSSceneAssetBindResult (IOSSceneAssetRegistry::*)(
    const Tempest::Device&,IOSMeshHandle,const Tempest::StorageBuffer&,
    const Tempest::StorageBuffer&,std::size_t,std::size_t,std::size_t,
    IOSBounds);
  using BindTexture = IOSSceneAssetBindResult (IOSSceneAssetRegistry::*)(
    const Tempest::Device&,IOSTextureHandle,const Tempest::Texture2d&);
  using LookupMesh = const IOSSceneMeshAsset* (IOSSceneAssetRegistry::*)(
    IOSMeshHandle) const noexcept;
  using LookupTexture = const IOSSceneTextureAsset* (IOSSceneAssetRegistry::*)(
    IOSTextureHandle) const noexcept;
  using State = IOSSceneAssetRegistryState (IOSSceneAssetRegistry::*)()
      const noexcept;

  static_assert(std::is_same_v<decltype(&IOSSceneAssetRegistry::bindMesh),
                               BindMesh>);
  static_assert(std::is_same_v<decltype(&IOSSceneAssetRegistry::bindTexture),
                               BindTexture>);
  static_assert(std::is_same_v<decltype(&IOSSceneAssetRegistry::lookupMesh),
                               LookupMesh>);
  static_assert(std::is_same_v<decltype(&IOSSceneAssetRegistry::lookupTexture),
                               LookupTexture>);
  static_assert(std::is_same_v<decltype(&IOSSceneAssetRegistry::state),State>);
  static_assert(!std::is_copy_constructible_v<IOSSceneAssetRegistry>);
  static_assert(!std::is_copy_assignable_v<IOSSceneAssetRegistry>);
  static_assert(!std::is_move_constructible_v<IOSSceneAssetRegistry>);
  static_assert(!std::is_move_assignable_v<IOSSceneAssetRegistry>);
  static_assert(std::is_trivially_copyable_v<IOSSceneMeshMetadata>);
  static_assert(std::is_trivially_copyable_v<IOSSceneTextureMetadata>);
  }

void validateLifecycleContract() {
  IOSSceneAssetRegistry registry;
  assert(!registry.isInitialized());
  assert(registry.state()==IOSSceneAssetRegistryState::Uninitialized);
  registry.clearAfterConfirmedIdle();
  assert(registry.state()==IOSSceneAssetRegistryState::Uninitialized);

  static_assert(!IOSSceneAssetRegistry::canAdvanceGeneration({},{1}));
  static_assert(!IOSSceneAssetRegistry::canAdvanceGeneration({7},{7}));
  static_assert(!IOSSceneAssetRegistry::canAdvanceGeneration({7},{6}));
  static_assert(IOSSceneAssetRegistry::canAdvanceGeneration({7},{8}));
  }

void validateAcceptedLayout() {
  assert(validate()==IOSSceneMeshValidation::Valid);
  assert(validate(96,48,32,6,6)==IOSSceneMeshValidation::Valid);
  }

void validateGenerationAndHandle() {
  assert(validate(96,24,32,0,6,Bounds,Mesh,{})==
         IOSSceneMeshValidation::InvalidRegistryGeneration);
  assert(validate(96,24,32,0,6,Bounds,{})==
         IOSSceneMeshValidation::EmptyHandle);
  assert(validate(96,24,32,0,6,Bounds,{{8},11})==
         IOSSceneMeshValidation::GenerationMismatch);
  }

void validateBufferAndStrideRules() {
  assert(validate(0)==IOSSceneMeshValidation::EmptyVertexBuffer);
  assert(validate(96,0)==IOSSceneMeshValidation::EmptyIndexBuffer);
  assert(validate(96,24,0)==IOSSceneMeshValidation::InvalidVertexStride);
  assert(validate(95,24,32)==
         IOSSceneMeshValidation::VertexBufferSizeMismatch);
  assert(validate(16,24,32)==
         IOSSceneMeshValidation::VertexBufferSizeMismatch);
  assert(validate(96,22)==IOSSceneMeshValidation::IndexBufferSizeMismatch);
  }

void validateTriangleAndIndexRangeRules() {
  assert(validate(96,24,32,0,0)==
         IOSSceneMeshValidation::EmptyIndexCount);
  assert(validate(96,24,32,0,4)==
         IOSSceneMeshValidation::NonTriangleIndexCount);
  assert(validate(96,24,32,std::numeric_limits<std::size_t>::max()-2u,3)==
         IOSSceneMeshValidation::IndexRangeOverflow);
  assert(validate(96,24,32,4,3)==
         IOSSceneMeshValidation::IndexRangeOutOfBounds);
  assert(validate(96,24,32,6,3)==
         IOSSceneMeshValidation::IndexRangeOutOfBounds);
  assert(validate(96,24,32,3,3)==IOSSceneMeshValidation::Valid);
  }

void validateBoundsRules() {
  IOSBounds inverted = Bounds;
  inverted.minimum.x = 2.f;
  assert(validate(96,24,32,0,6,inverted)==
         IOSSceneMeshValidation::InvalidBounds);

  IOSBounds nonFinite = Bounds;
  nonFinite.maximum.z = std::numeric_limits<float>::infinity();
  assert(validate(96,24,32,0,6,nonFinite)==
         IOSSceneMeshValidation::InvalidBounds);
  }

}

int main() {
  validatePublicContract();
  validateLifecycleContract();
  validateAcceptedLayout();
  validateGenerationAndHandle();
  validateBufferAndStrideRules();
  validateTriangleAndIndexRangeRules();
  validateBoundsRules();
  return 0;
  }
