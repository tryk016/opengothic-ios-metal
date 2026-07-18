#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

class IOSMetalContext;
class IOSRenderWorld;

struct IOSWorldGeneration final {
  uint64_t value = 0;

  constexpr explicit operator bool() const noexcept {
    return value!=0;
    }

  constexpr bool operator==(const IOSWorldGeneration&) const noexcept = default;
  };

struct IOSSceneSequence final {
  uint64_t value = 0;

  constexpr explicit operator bool() const noexcept {
    return value!=0;
    }

  constexpr bool operator==(const IOSSceneSequence&) const noexcept = default;
  };

struct IOSFloat2 final {
  float x = 0.f;
  float y = 0.f;

  constexpr bool operator==(const IOSFloat2&) const noexcept = default;
  };

struct IOSFloat3 final {
  float x = 0.f;
  float y = 0.f;
  float z = 0.f;

  constexpr bool operator==(const IOSFloat3&) const noexcept = default;
  };

struct IOSFloat4 final {
  float x = 0.f;
  float y = 0.f;
  float z = 0.f;
  float w = 0.f;

  constexpr bool operator==(const IOSFloat4&) const noexcept = default;
  };

struct IOSMatrix4x4 final {
  // Column-major storage with conventional logical (row,column) access.
  std::array<float,16> elements = {
    1.f,0.f,0.f,0.f,
    0.f,1.f,0.f,0.f,
    0.f,0.f,1.f,0.f,
    0.f,0.f,0.f,1.f,
    };

  constexpr float at(std::size_t row, std::size_t column) const noexcept {
    return elements[column*4u+row];
    }

  constexpr void set(std::size_t row, std::size_t column, float value) noexcept {
    elements[column*4u+row] = value;
    }

  constexpr bool operator==(const IOSMatrix4x4&) const noexcept = default;
  };

struct IOSViewport final {
  uint32_t x      = 0;
  uint32_t y      = 0;
  uint32_t width  = 0;
  uint32_t height = 0;

  constexpr bool operator==(const IOSViewport&) const noexcept = default;
  };

struct IOSBounds final {
  IOSFloat3 minimum;
  IOSFloat3 maximum;

  constexpr bool operator==(const IOSBounds&) const noexcept = default;
  };

struct IOSIndexRange final {
  uint32_t offset = 0;
  uint32_t count  = 0;

  constexpr bool operator==(const IOSIndexRange&) const noexcept = default;
  };

struct IOSRenderEntityId final {
  IOSWorldGeneration generation;
  uint64_t            value = 0;

  constexpr explicit operator bool() const noexcept {
    return bool(generation) && value!=0;
    }

  constexpr bool operator==(const IOSRenderEntityId&) const noexcept = default;
  };

struct IOSMeshHandle final {
  IOSWorldGeneration generation;
  uint64_t            value = 0;

  constexpr explicit operator bool() const noexcept {
    return bool(generation) && value!=0;
    }

  constexpr bool operator==(const IOSMeshHandle&) const noexcept = default;
  };

struct IOSMaterialHandle final {
  IOSWorldGeneration generation;
  uint64_t            value = 0;

  constexpr explicit operator bool() const noexcept {
    return bool(generation) && value!=0;
    }

  constexpr bool operator==(const IOSMaterialHandle&) const noexcept = default;
  };

struct IOSTextureHandle final {
  IOSWorldGeneration generation;
  uint64_t            value = 0;

  constexpr explicit operator bool() const noexcept {
    return bool(generation) && value!=0;
    }

  constexpr bool operator==(const IOSTextureHandle&) const noexcept = default;
  };

struct IOSLightHandle final {
  IOSWorldGeneration generation;
  uint64_t            value = 0;

  constexpr explicit operator bool() const noexcept {
    return bool(generation) && value!=0;
    }

  constexpr bool operator==(const IOSLightHandle&) const noexcept = default;
  };

struct IOSParticleHandle final {
  IOSWorldGeneration generation;
  uint64_t            value = 0;

  constexpr explicit operator bool() const noexcept {
    return bool(generation) && value!=0;
    }

  constexpr bool operator==(const IOSParticleHandle&) const noexcept = default;
  };

enum class IOSMaterialCategory : uint8_t {
  Opaque,
  AlphaTest,
  Transparent,
  Additive,
  Water,
  };

enum class IOSLightType : uint8_t {
  Directional,
  Point,
  Spot,
  };

enum class IOSEffectKind : uint8_t {
  None,
  Fog,
  Underwater,
  ScreenFade,
  ScreenBlend,
  };

enum IOSSceneFeature : uint64_t {
  IOSSceneFeatureNone      = 0,
  IOSSceneFeatureSky       = uint64_t(1) << 0u,
  IOSSceneFeatureFog       = uint64_t(1) << 1u,
  IOSSceneFeatureLights    = uint64_t(1) << 2u,
  IOSSceneFeatureParticles = uint64_t(1) << 3u,
  IOSSceneFeatureReactiveMask    = uint64_t(1) << 4u,
  IOSSceneFeatureTranslucentMask = uint64_t(1) << 5u,
  IOSSceneFeatureRayTracing      = uint64_t(1) << 6u,
  };

enum IOSSceneVisibility : uint64_t {
  IOSSceneVisibilityNone       = 0,
  IOSSceneVisibilityMain       = uint64_t(1) << 0u,
  IOSSceneVisibilityShadow     = uint64_t(1) << 1u,
  IOSSceneVisibilityReflection = uint64_t(1) << 2u,
  IOSSceneVisibilityRayTracing = uint64_t(1) << 3u,
  };

struct IOSCameraState final {
  IOSMatrix4x4 view;
  IOSMatrix4x4 projection;
  IOSMatrix4x4 viewProjection;
  IOSFloat3    position;
  IOSFloat2    jitter;
  IOSViewport  viewport;
  float        nearPlane = 0.1f;
  float        farPlane  = 1.f;

  constexpr bool operator==(const IOSCameraState&) const noexcept = default;
  };

struct IOSRenderEntityState final {
  IOSRenderEntityId id;
  IOSMeshHandle     mesh;
  IOSMaterialHandle material;
  IOSMatrix4x4      transform;
  IOSBounds         bounds;
  IOSIndexRange     boneRange;
  IOSIndexRange     morphRange;
  uint64_t          visibilityMask = IOSSceneVisibilityMain;

  constexpr bool operator==(const IOSRenderEntityState&) const noexcept = default;
  };

struct IOSRenderEntity final {
  IOSRenderEntityId id;
  IOSMeshHandle     mesh;
  IOSMaterialHandle material;
  IOSMatrix4x4      currentTransform;
  IOSMatrix4x4      previousTransform;
  IOSBounds         bounds;
  IOSIndexRange     boneRange;
  IOSIndexRange     morphRange;
  uint64_t          visibilityMask = IOSSceneVisibilityMain;

  constexpr bool operator==(const IOSRenderEntity&) const noexcept = default;
  };

struct IOSMaterial final {
  IOSMaterialHandle  id;
  IOSTextureHandle   baseColorTexture;
  IOSTextureHandle   normalTexture;
  IOSTextureHandle   emissiveTexture;
  IOSFloat4          baseColor = {1.f,1.f,1.f,1.f};
  IOSFloat3          emissive;
  float              roughness  = 1.f;
  float              metallic   = 0.f;
  float              alphaCutoff = 0.5f;
  IOSMaterialCategory category  = IOSMaterialCategory::Opaque;
  uint64_t            flags     = 0;

  constexpr bool operator==(const IOSMaterial&) const noexcept = default;
  };

struct IOSLight final {
  IOSLightHandle id;
  IOSLightType   type = IOSLightType::Point;
  IOSFloat3      position;
  IOSFloat3      direction = {0.f,-1.f,0.f};
  IOSFloat3      color     = {1.f,1.f,1.f};
  float          intensity = 1.f;
  float          range     = 0.f;
  float          innerConeRadians = 0.f;
  float          outerConeRadians = 0.f;
  uint64_t       visibilityMask = IOSSceneVisibilityMain;

  constexpr bool operator==(const IOSLight&) const noexcept = default;
  };

struct IOSParticleState final {
  IOSParticleHandle id;
  IOSFloat3         position;
  IOSFloat3         velocity;
  IOSFloat4         color = {1.f,1.f,1.f,1.f};
  IOSFloat2         size;
  float             rotation = 0.f;
  IOSTextureHandle  texture;

  constexpr bool operator==(const IOSParticleState&) const noexcept = default;
  };

struct IOSParticleSnapshot final {
  IOSParticleHandle id;
  IOSFloat3         currentPosition;
  IOSFloat3         previousPosition;
  IOSFloat3         velocity;
  IOSFloat4         color = {1.f,1.f,1.f,1.f};
  IOSFloat2         size;
  float             rotation = 0.f;
  IOSTextureHandle  texture;

  constexpr bool operator==(const IOSParticleSnapshot&) const noexcept = default;
  };

struct IOSSkyState final {
  IOSFloat3 sunDirection = {0.f,-1.f,0.f};
  IOSFloat3 sunColor;
  IOSFloat3 ambientColor;
  IOSFloat3 fogColor;
  float     fogNear       = 0.f;
  float     fogFar        = 0.f;
  float     cloudCoverage = 0.f;
  float     rainIntensity = 0.f;
  float     timeOfDay     = 0.f;

  constexpr bool operator==(const IOSSkyState&) const noexcept = default;
  };

struct IOSEffectRequest final {
  IOSEffectKind kind = IOSEffectKind::None;
  IOSFloat4     color;
  IOSFloat4     parameters;
  uint64_t      id = 0;

  constexpr bool operator==(const IOSEffectRequest&) const noexcept = default;
  };

struct IOSSceneFrameState final {
  IOSCameraState                   camera;
  IOSSkyState                      sky;
  std::vector<IOSRenderEntityState> entities;
  std::vector<IOSMaterial>          materials;
  std::vector<IOSLight>             lights;
  std::vector<IOSMatrix4x4>         bones;
  std::vector<float>                morphWeights;
  std::vector<IOSParticleState>     particles;
  std::vector<IOSEffectRequest>     effects;
  uint64_t                          featureMask = IOSSceneFeatureNone;
  bool                              resetHistory = false;
  };

struct IOSSceneSnapshot final {
  IOSWorldGeneration              generation;
  IOSSceneSequence                sequence;
  IOSCameraState                  currentCamera;
  IOSCameraState                  previousCamera;
  IOSSkyState                     currentSky;
  IOSSkyState                     previousSky;
  std::vector<IOSRenderEntity>    entities;
  std::vector<IOSMaterial>        materials;
  std::vector<IOSLight>           lights;
  std::vector<IOSMatrix4x4>       currentBones;
  std::vector<IOSMatrix4x4>       previousBones;
  std::vector<float>              currentMorphWeights;
  std::vector<float>              previousMorphWeights;
  std::vector<IOSParticleSnapshot> particles;
  std::vector<IOSEffectRequest>   effects;
  uint64_t                        featureMask = IOSSceneFeatureNone;
  bool                            historyValid = false;

  bool isStructurallyValid() const noexcept;

  private:
    bool readyForSubmit() const noexcept {
      return structurallyValidated;
      }

    bool structurallyValidated = false;

  friend class IOSMetalContext;
  friend class IOSRenderWorld;
  };

using IOSSceneSnapshotPtr = std::shared_ptr<const IOSSceneSnapshot>;
