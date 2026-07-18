#include "iosscenesnapshot.h"

#include <type_traits>

namespace {

template<class Handle>
bool validHandle(const Handle& handle, IOSWorldGeneration generation,
                 bool allowEmpty = false) noexcept {
  if(!handle)
    return allowEmpty && handle.generation.value==0 && handle.value==0;
  return handle.generation==generation;
  }

bool validRange(IOSIndexRange range, std::size_t size) noexcept {
  const std::size_t offset = std::size_t(range.offset);
  const std::size_t count  = std::size_t(range.count);
  return offset<=size && count<=size-offset;
  }

template<class T, class Id>
bool idsStrictlyIncrease(const std::vector<T>& values,
                         Id T::*member) noexcept {
  for(std::size_t i=1; i<values.size(); ++i) {
    if((values[i-1].*member).value>=(values[i].*member).value)
      return false;
    }
  return true;
  }

static_assert(std::is_standard_layout_v<IOSFloat2>);
static_assert(std::is_standard_layout_v<IOSFloat3>);
static_assert(std::is_standard_layout_v<IOSFloat4>);
static_assert(std::is_standard_layout_v<IOSMatrix4x4>);
static_assert(std::is_trivially_copyable_v<IOSMatrix4x4>);
static_assert(std::is_trivially_copyable_v<IOSRenderEntityId>);
static_assert(std::is_trivially_copyable_v<IOSMeshHandle>);
static_assert(std::is_trivially_copyable_v<IOSMaterialHandle>);
static_assert(std::is_trivially_copyable_v<IOSTextureHandle>);
static_assert(std::is_trivially_copyable_v<IOSLightHandle>);
static_assert(std::is_trivially_copyable_v<IOSParticleHandle>);
static_assert(std::is_same_v<IOSSceneSnapshotPtr,
                             std::shared_ptr<const IOSSceneSnapshot>>);

}

bool IOSSceneSnapshot::isStructurallyValid() const noexcept {
  if(!generation || !sequence)
    return false;
  if(currentCamera.viewport.width==0 || currentCamera.viewport.height==0 ||
     currentCamera.nearPlane<=0.f ||
     currentCamera.farPlane<=currentCamera.nearPlane)
    return false;
  if(currentBones.size()!=previousBones.size() ||
     currentMorphWeights.size()!=previousMorphWeights.size())
    return false;

  for(const auto& entity:entities) {
    if(!validHandle(entity.id,generation) ||
       !validHandle(entity.mesh,generation) ||
       !validHandle(entity.material,generation) ||
       !validRange(entity.boneRange,currentBones.size()) ||
       !validRange(entity.morphRange,currentMorphWeights.size()))
      return false;
    if(!historyValid && entity.currentTransform!=entity.previousTransform)
      return false;
    }
  if(!idsStrictlyIncrease(entities,&IOSRenderEntity::id))
    return false;

  for(const auto& material:materials) {
    if(!validHandle(material.id,generation) ||
       !validHandle(material.baseColorTexture,generation,true) ||
       !validHandle(material.normalTexture,generation,true) ||
       !validHandle(material.emissiveTexture,generation,true))
      return false;
    }
  if(!idsStrictlyIncrease(materials,&IOSMaterial::id))
    return false;

  for(const auto& light:lights) {
    if(!validHandle(light.id,generation))
      return false;
    }
  if(!idsStrictlyIncrease(lights,&IOSLight::id))
    return false;

  for(const auto& particle:particles) {
    if(!validHandle(particle.id,generation) ||
       !validHandle(particle.texture,generation,true))
      return false;
    if(!historyValid && particle.currentPosition!=particle.previousPosition)
      return false;
    }
  if(!idsStrictlyIncrease(particles,&IOSParticleSnapshot::id))
    return false;

  if(!historyValid) {
    if(currentCamera!=previousCamera || currentSky!=previousSky ||
       currentBones!=previousBones ||
       currentMorphWeights!=previousMorphWeights)
      return false;
    }
  return true;
  }
