#pragma once

#include "iosscenesnapshot.h"

// Scene radiance is pre-exposed once here, before HDR blending. Emissive
// materials retain their legacy exposure-independent contribution.
struct alignas(16) IOSSceneLightingConstants final {
  std::array<IOSMatrix4x4,2> viewShadow;
  IOSFloat4 sunDirection;   // w: shadow caster enable
  IOSFloat4 sunColor;       // w: scene exposure
  IOSFloat4 ambientColor;   // w: point-light exposure scale
  IOSFloat4 cameraPosition; // w: altitude in meters
  IOSFloat4 shadowSlice;    // xy: close cascade range, zw: texel sizes
  IOSFloat4 skyParameters;  // cloud coverage, rain, night, pre-exposed sun intensity
  IOSFloat4 fogColor;
  IOSFloat4 fogParameters;  // near, far, reserved
  IOSMatrix4x4 inverseViewProjection;
  std::array<uint32_t,4> lightInfo = {};
  };

struct IOSPointLightConstants final {
  IOSFloat4 positionRange;
  IOSFloat4 color;
  };

static_assert(sizeof(IOSSceneLightingConstants)==336);
static_assert(offsetof(IOSSceneLightingConstants,inverseViewProjection)==256);
static_assert(offsetof(IOSSceneLightingConstants,lightInfo)==320);
static_assert(sizeof(IOSPointLightConstants)==32);

IOSFloat3 iosAtmosphereTransmittance(float sunY, float altitudeMeters) noexcept;
IOSSceneLightingConstants iosSceneLighting(const IOSSkyState& sky,
                                           const IOSCameraState& camera) noexcept;
