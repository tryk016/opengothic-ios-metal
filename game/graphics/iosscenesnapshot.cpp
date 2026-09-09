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

bool isCanonicalUVOffset(const IOSFloat2& value) noexcept {
  return isFinite(value) &&
         (value.x!=0.f || !std::signbit(value.x)) &&
         (value.y!=0.f || !std::signbit(value.y));
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

bool validMorphLayer(const IOSMorphLayer& layer) noexcept {
  return isFinite(layer.alpha) && layer.alpha>=0.f && layer.alpha<=1.f &&
         isFinite(layer.intensity) && layer.intensity>=0.f && layer.intensity<=1.f;
  }

bool validBounds(const IOSBounds& bounds) noexcept {
  return isFinite(bounds.minimum) && isFinite(bounds.maximum) &&
         bounds.minimum.x<=bounds.maximum.x &&
         bounds.minimum.y<=bounds.maximum.y &&
         bounds.minimum.z<=bounds.maximum.z;
  }

bool validCamera(const IOSCameraState& camera) noexcept {
  return isFinite(camera.inverseViewProjection) && isFinite(camera.view) && isFinite(camera.projection) &&
         isFinite(camera.viewProjection) && isFinite(camera.position) &&
         isFinite(camera.jitter) && isFinite(camera.nearPlane) &&
         isFinite(camera.farPlane) &&
         camera.viewport.width!=0 && camera.viewport.height!=0 &&
         camera.nearPlane>0.f && camera.farPlane>camera.nearPlane;
  }

bool validSky(const IOSSkyState& sky) noexcept {
  return isFinite(sky.cloudOffsets) && isFinite(sky.viewShadow[0]) && isFinite(sky.viewShadow[1]) &&
         isFinite(sky.closeupShadowSlice) && isFinite(sky.altitudeMeters) &&
         isFinite(sky.sunIntensity) && sky.sunIntensity>=0.f &&
         sky.altitudeMeters>=0.f && sky.altitudeMeters<=1000.f &&
         isFinite(sky.sunDirection) && isFinite(sky.sunColor) &&
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
    case IOSMaterialCategory::Ghost:
    case IOSMaterialCategory::Multiply:
    case IOSMaterialCategory::Water:
    case IOSMaterialCategory::Multiply2:
      return true;
    }
  return false;
  }

bool validNativeSceneMaterial(const IOSMaterial& material) noexcept {
  constexpr uint64_t knownFlags = IOSMaterialFlagStaticAdditiveNone |
      IOSMaterialFlagStaticMultiply2None;
  if((material.flags&~knownFlags)!=0)
    return false;
  switch(material.category) {
    case IOSMaterialCategory::Opaque:
      return material.flags==IOSMaterialFlagNone;
    case IOSMaterialCategory::AlphaTest:
      return bool(material.baseColorTexture) &&
             !material.usesFallbackTexture &&
             material.alphaCutoff==0.5f &&
             material.baseColor.w>=0.f && material.baseColor.w<=1.f &&
             material.flags==IOSMaterialFlagNone;
    case IOSMaterialCategory::Additive:
      return bool(material.baseColorTexture) &&
             !material.usesFallbackTexture &&
             material.baseColor.w>=0.f && material.baseColor.w<=1.f &&
             (material.flags==IOSMaterialFlagNone || material.flags==IOSMaterialFlagStaticAdditiveNone);
    case IOSMaterialCategory::Multiply2:
      return bool(material.baseColorTexture) &&
             !material.usesFallbackTexture &&
             material.baseColor.w>=0.f && material.baseColor.w<=1.f &&
             (material.flags==IOSMaterialFlagNone || material.flags==IOSMaterialFlagStaticMultiply2None);
    case IOSMaterialCategory::Transparent:
      return bool(material.baseColorTexture) && material.flags==IOSMaterialFlagNone &&
             material.baseColor.w>=0.f && material.baseColor.w<=1.f;
    case IOSMaterialCategory::Water:
    case IOSMaterialCategory::Ghost:
    case IOSMaterialCategory::Multiply:
      return bool(material.baseColorTexture) && material.flags==IOSMaterialFlagNone;
    }
  return false;
  }

bool validSceneMeshKind(IOSSceneMeshKind kind) noexcept {
  switch(kind) {
    case IOSSceneMeshKind::Landscape:
    case IOSSceneMeshKind::Static:
    case IOSSceneMeshKind::Movable:
    case IOSSceneMeshKind::Animated:
    case IOSSceneMeshKind::Morph:
      return true;
    case IOSSceneMeshKind::Unsupported:
      return false;
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

const IOSMaterial* findMaterial(
    const std::vector<IOSMaterial>& materials,
    IOSMaterialHandle handle) noexcept {
  const auto found = std::lower_bound(
    materials.begin(),materials.end(),handle.value,
    [](const IOSMaterial& material, uint64_t value) {
      return material.id.value<value;
      });
  return found!=materials.end() && found->id==handle ? &*found : nullptr;
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
static_assert(std::is_trivially_copyable_v<IOSParticleVertex>);
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
     currentMorphLayers.size()!=previousMorphLayers.size())
    return false;

  for(const auto* sky:{&currentSky,&previousSky})
    for(const auto handle:sky->textures)
      if(!validHandle(handle,generation,true))
        return false;
  for(const auto& material:materials) {
    if(!validHandle(material.id,generation) ||
       !validHandle(material.baseColorTexture,generation,true) ||
       !validHandle(material.normalTexture,generation,true) ||
       !validHandle(material.emissiveTexture,generation,true) ||
       !isFinite(material.baseColor) ||
       !isCanonicalUVOffset(material.uvOffset) ||
       !isFinite(material.emissive) ||
       !isFinite(material.roughness) || !isFinite(material.metallic) ||
       !isFinite(material.alphaCutoff) || !isFinite(material.waveMaxAmplitude) ||
       material.roughness<0.f || material.roughness>1.f ||
       material.metallic<0.f || material.metallic>1.f ||
       material.alphaCutoff<0.f || material.alphaCutoff>1.f ||
       !validMaterialCategory(material.category) ||
       !validNativeSceneMaterial(material))
      return false;
    }
  if(!idsStrictlyIncrease(materials,&IOSMaterial::id))
    return false;

  for(const auto& entity:entities) {
    const IOSMaterial* const material =
        findMaterial(materials,entity.material);
    if(!validHandle(entity.id,generation) ||
       !validHandle(entity.mesh,generation) ||
       !validHandle(entity.material,generation) ||
       material==nullptr ||
       !validSceneMeshKind(entity.kind) ||
       !isFinite(entity.currentTransform) ||
       !isFinite(entity.previousTransform) ||
       !isFinite(entity.fatness) ||
       !isFinite(entity.previousFatness) ||
       !validBounds(entity.bounds) ||
       !validRange(entity.boneRange,currentBones.size()) ||
       !validRange(entity.morphRange,currentMorphLayers.size()) ||
       !validVisibility(entity.visibilityMask))
      return false;
    if((material->flags!=IOSMaterialFlagNone) &&
       entity.kind!=IOSSceneMeshKind::Static)
      return false;
    if(!historyValid && (entity.currentTransform!=entity.previousTransform ||
                         entity.fatness!=entity.previousFatness))
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
    if(!isFinite(particle.position) || !isFinite(particle.size) ||
       !isFinite(particle.direction))
      return false;
    }
  size_t particleEnd = 0;
  for(const auto& batch:particleBatches) {
    if(batch.vertices.offset!=particleEnd || batch.vertices.count==0 ||
       batch.vertices.count>particles.size()-particleEnd ||
       !validHandle(batch.texture,generation) ||
       !validMaterialCategory(batch.material) || batch.material==IOSMaterialCategory::Water)
      return false;
    particleEnd += batch.vertices.count;
    }
  if(particleEnd!=particles.size())
    return false;

  if(!std::all_of(currentBones.begin(),currentBones.end(),
                  [](const IOSMatrix4x4& bone) {
                    return isFinite(bone);
                    }) ||
     !std::all_of(previousBones.begin(),previousBones.end(),
                  [](const IOSMatrix4x4& bone) {
                    return isFinite(bone);
                    }) ||
     !std::all_of(currentMorphLayers.begin(),currentMorphLayers.end(),
                  validMorphLayer) ||
     !std::all_of(previousMorphLayers.begin(),previousMorphLayers.end(),
                  validMorphLayer))
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
       currentMorphLayers!=previousMorphLayers)
      return false;
    }
  return true;
  }
