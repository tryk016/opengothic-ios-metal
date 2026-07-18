#include "iosscenesnapshot.h"

#include <algorithm>
#include <cmath>
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

bool isFinite(float value) noexcept {
  return std::isfinite(value);
  }

bool isFinite(const IOSFloat2& value) noexcept {
  return isFinite(value.x) && isFinite(value.y);
  }

bool isFinite(const IOSFloat3& value) noexcept {
  return isFinite(value.x) && isFinite(value.y) && isFinite(value.z);
  }

bool isFinite(const IOSFloat4& value) noexcept {
  return isFinite(value.x) && isFinite(value.y) &&
         isFinite(value.z) && isFinite(value.w);
  }

bool isFinite(const IOSMatrix4x4& value) noexcept {
  return std::all_of(value.elements.begin(),value.elements.end(),
                     [](float component) {
                       return isFinite(component);
                       });
  }

bool validBounds(const IOSBounds& bounds) noexcept {
  return isFinite(bounds.minimum) && isFinite(bounds.maximum) &&
         bounds.minimum.x<=bounds.maximum.x &&
         bounds.minimum.y<=bounds.maximum.y &&
         bounds.minimum.z<=bounds.maximum.z;
  }

bool validCamera(const IOSCameraState& camera) noexcept {
  return isFinite(camera.view) && isFinite(camera.projection) &&
         isFinite(camera.viewProjection) && isFinite(camera.position) &&
         isFinite(camera.jitter) && isFinite(camera.nearPlane) &&
         isFinite(camera.farPlane) &&
         camera.viewport.width!=0 && camera.viewport.height!=0 &&
         camera.nearPlane>0.f && camera.farPlane>camera.nearPlane;
  }

bool validSky(const IOSSkyState& sky) noexcept {
  return isFinite(sky.sunDirection) && isFinite(sky.sunColor) &&
         isFinite(sky.ambientColor) && isFinite(sky.fogColor) &&
         isFinite(sky.fogNear) && isFinite(sky.fogFar) &&
         isFinite(sky.cloudCoverage) && isFinite(sky.rainIntensity) &&
         isFinite(sky.timeOfDay) &&
         sky.fogNear>=0.f && sky.fogFar>=sky.fogNear &&
         sky.cloudCoverage>=0.f && sky.cloudCoverage<=1.f &&
         sky.rainIntensity>=0.f && sky.rainIntensity<=1.f;
  }

bool validMaterialCategory(IOSMaterialCategory category) noexcept {
  switch(category) {
    case IOSMaterialCategory::Opaque:
    case IOSMaterialCategory::AlphaTest:
    case IOSMaterialCategory::Transparent:
    case IOSMaterialCategory::Additive:
    case IOSMaterialCategory::Water:
      return true;
    }
  return false;
  }

bool validLightType(IOSLightType type) noexcept {
  switch(type) {
    case IOSLightType::Directional:
    case IOSLightType::Point:
    case IOSLightType::Spot:
      return true;
    }
  return false;
  }

bool validEffectKind(IOSEffectKind kind) noexcept {
  switch(kind) {
    case IOSEffectKind::None:
    case IOSEffectKind::Fog:
    case IOSEffectKind::Underwater:
    case IOSEffectKind::ScreenFade:
    case IOSEffectKind::ScreenBlend:
      return true;
    }
  return false;
  }

bool validVisibility(uint64_t visibility) noexcept {
  constexpr uint64_t known =
    IOSSceneVisibilityMain |
    IOSSceneVisibilityShadow |
    IOSSceneVisibilityReflection |
    IOSSceneVisibilityRayTracing;
  return visibility!=IOSSceneVisibilityNone && (visibility&~known)==0;
  }

bool validFeatureMask(uint64_t features) noexcept {
  constexpr uint64_t known =
    IOSSceneFeatureSky |
    IOSSceneFeatureFog |
    IOSSceneFeatureLights |
    IOSSceneFeatureParticles |
    IOSSceneFeatureReactiveMask |
    IOSSceneFeatureTranslucentMask |
    IOSSceneFeatureRayTracing;
  return (features&~known)==0;
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

bool containsMaterial(const std::vector<IOSMaterial>& materials,
                      IOSMaterialHandle handle) noexcept {
  const auto found = std::lower_bound(
    materials.begin(),materials.end(),handle.value,
    [](const IOSMaterial& material, uint64_t value) {
      return material.id.value<value;
      });
  return found!=materials.end() && found->id==handle;
  }

static_assert(std::is_standard_layout_v<IOSFloat2>);
static_assert(std::is_standard_layout_v<IOSFloat3>);
static_assert(std::is_standard_layout_v<IOSFloat4>);
static_assert(std::is_standard_layout_v<IOSMatrix4x4>);
static_assert(std::is_trivially_copyable_v<IOSMatrix4x4>);
static_assert(sizeof(IOSMatrix4x4)==sizeof(float)*16u);
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
  if(!validFeatureMask(featureMask) ||
     !validCamera(currentCamera) || !validCamera(previousCamera) ||
     !validSky(currentSky) || !validSky(previousSky))
    return false;
  if(currentBones.size()!=previousBones.size() ||
     currentMorphWeights.size()!=previousMorphWeights.size())
    return false;

  for(const auto& material:materials) {
    if(!validHandle(material.id,generation) ||
       !validHandle(material.baseColorTexture,generation,true) ||
       !validHandle(material.normalTexture,generation,true) ||
       !validHandle(material.emissiveTexture,generation,true) ||
       !isFinite(material.baseColor) || !isFinite(material.emissive) ||
       !isFinite(material.roughness) || !isFinite(material.metallic) ||
       !isFinite(material.alphaCutoff) ||
       material.roughness<0.f || material.roughness>1.f ||
       material.metallic<0.f || material.metallic>1.f ||
       material.alphaCutoff<0.f || material.alphaCutoff>1.f ||
       !validMaterialCategory(material.category))
      return false;
    }
  if(!idsStrictlyIncrease(materials,&IOSMaterial::id))
    return false;

  for(const auto& entity:entities) {
    if(!validHandle(entity.id,generation) ||
       !validHandle(entity.mesh,generation) ||
       !validHandle(entity.material,generation) ||
       !containsMaterial(materials,entity.material) ||
       !isFinite(entity.currentTransform) ||
       !isFinite(entity.previousTransform) ||
       !validBounds(entity.bounds) ||
       !validRange(entity.boneRange,currentBones.size()) ||
       !validRange(entity.morphRange,currentMorphWeights.size()) ||
       !validVisibility(entity.visibilityMask))
      return false;
    if(!historyValid && entity.currentTransform!=entity.previousTransform)
      return false;
    }
  if(!idsStrictlyIncrease(entities,&IOSRenderEntity::id))
    return false;

  for(const auto& light:lights) {
    if(!validHandle(light.id,generation) ||
       !validLightType(light.type) ||
       !isFinite(light.position) || !isFinite(light.direction) ||
       !isFinite(light.color) || !isFinite(light.intensity) ||
       !isFinite(light.range) || !isFinite(light.innerConeRadians) ||
       !isFinite(light.outerConeRadians) ||
       light.intensity<0.f || light.range<0.f ||
       light.innerConeRadians<0.f ||
       light.outerConeRadians<light.innerConeRadians ||
       light.outerConeRadians>3.14159265358979323846f ||
       !validVisibility(light.visibilityMask))
      return false;
    }
  if(!idsStrictlyIncrease(lights,&IOSLight::id))
    return false;

  for(const auto& particle:particles) {
    if(!validHandle(particle.id,generation) ||
       !validHandle(particle.texture,generation,true) ||
       !isFinite(particle.currentPosition) ||
       !isFinite(particle.previousPosition) ||
       !isFinite(particle.velocity) || !isFinite(particle.color) ||
       !isFinite(particle.size) || !isFinite(particle.rotation) ||
       particle.size.x<0.f || particle.size.y<0.f)
      return false;
    if(!historyValid && particle.currentPosition!=particle.previousPosition)
      return false;
    }
  if(!idsStrictlyIncrease(particles,&IOSParticleSnapshot::id))
    return false;

  if(!std::all_of(currentBones.begin(),currentBones.end(),
                  [](const IOSMatrix4x4& bone) {
                    return isFinite(bone);
                    }) ||
     !std::all_of(previousBones.begin(),previousBones.end(),
                  [](const IOSMatrix4x4& bone) {
                    return isFinite(bone);
                    }) ||
     !std::all_of(currentMorphWeights.begin(),currentMorphWeights.end(),
                  [](float weight) {
                    return isFinite(weight);
                    }) ||
     !std::all_of(previousMorphWeights.begin(),previousMorphWeights.end(),
                  [](float weight) {
                    return isFinite(weight);
                    }))
    return false;

  for(const auto& effect:effects) {
    if(!validEffectKind(effect.kind) ||
       !isFinite(effect.color) || !isFinite(effect.parameters))
      return false;
    }

  if(!lights.empty() && (featureMask&IOSSceneFeatureLights)==0)
    return false;
  if(!particles.empty() && (featureMask&IOSSceneFeatureParticles)==0)
    return false;
  if(historyValid &&
     previousCamera.viewport!=currentCamera.viewport)
    return false;

  if(!historyValid) {
    if(currentCamera!=previousCamera || currentSky!=previousSky ||
       currentBones!=previousBones ||
       currentMorphWeights!=previousMorphWeights)
      return false;
    }
  return true;
  }
