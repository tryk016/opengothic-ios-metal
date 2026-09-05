#include "iosscenelighting.h"

#include <algorithm>
#include <cmath>

namespace {
constexpr float Pi = 3.14159265358979323846f;
constexpr float PlanetRadius = 6360.f; // kilometers; same media as sky_common.glsl
constexpr float AtmosphereRadius = 6460.f;

float smoothstep(float low, float high, float x) {
  const float t = std::clamp((x-low)/(high-low),0.f,1.f);
  return t*t*(3.f-2.f*t);
  }
}

IOSFloat3 iosAtmosphereTransmittance(float sunY, float altitudeMeters) noexcept {
  const double r = PlanetRadius+double(altitudeMeters)*0.001;
  const double y = std::clamp(double(sunY),-1.0,1.0);
  const double ground = r*r*(y*y-1.0)+double(PlanetRadius)*PlanetRadius;
  if(y<0.0 && ground>=0.0)
    return {}; // planet occludes the sun
  const double distance = -r*y+std::sqrt(r*r*(y*y-1.0)+double(AtmosphereRadius)*AtmosphereRadius);
  double rayleigh = 0, mie = 0, ozone = 0;
  // Quadratic intervals resolve the dense atmosphere near the ground.
  for(int i=0; i<32; ++i) {
    const double a = double(i)/32, b = double(i+1)/32;
    const double start = a*a*distance, end = b*b*distance;
    const double t = (start+end)*0.5;
    const double altitude = std::max(0.0,std::sqrt(r*r+t*t+2*r*y*t)-PlanetRadius);
    const double step = (end-start)*1000;
    rayleigh += std::exp(-altitude/8.0)*step;
    mie += std::exp(-altitude/1.2)*step;
    ozone += std::max(0.0,1.0-std::abs(altitude-25.0)/15.0)*step;
    }
  const auto channel = [&](double ray, double absorption) {
    return float(std::exp(-(ray*33.1*rayleigh+8.396*mie+absorption*ozone)/1e6));
    };
  return {channel(0.175,0.650),channel(0.409,1.881),channel(1.0,0.085)};
  }

IOSSceneLightingConstants iosSceneLighting(const IOSSkyState& sky,
                                           const IOSCameraState& camera) noexcept {
  const auto tr = iosAtmosphereTransmittance(sky.sunDirection.y,1.f);
  const float clouds = 1.f-std::pow(sky.cloudCoverage,4.f);
  const float occlusion = smoothstep(0.f,0.01f,sky.sunDirection.y);
  const IOSFloat3 sun = {sky.sunColor.x*tr.x,sky.sunColor.y*tr.y,sky.sunColor.z*tr.z};
  const IOSFloat3 ambient = {sky.ambientColor.x*tr.x,sky.ambientColor.y*tr.y,sky.ambientColor.z*tr.z};
  const float luminance =
      0.2125f*(sun.x/Pi+ambient.x)+0.7154f*(sun.y/Pi+ambient.y)+
      0.0721f*(sun.z/Pi+ambient.z);
  // Analytical daylight metering. The 1.5 floor preserves legacy night exposure;
  // unlike the legacy renderer, this path does not meter its sky texture LUT.
  const float exposure = 1.f/(luminance*2.5f*1.25f+1.5f);
  const float directScale = clouds*occlusion*exposure;
  const float ambientScale = clouds*exposure;
  IOSSceneLightingConstants result;
  result.viewShadow = sky.viewShadow;
  result.sunDirection = {sky.sunDirection.x,sky.sunDirection.y,sky.sunDirection.z,
                         sky.shadowsEnabled ? 1.f : 0.f};
  result.sunColor = {sun.x*directScale,sun.y*directScale,sun.z*directScale,exposure};
  result.ambientColor = {ambient.x*ambientScale,ambient.y*ambientScale,
                         ambient.z*ambientScale,std::max(1.f,exposure)};
  result.cameraPosition = {camera.position.x,camera.position.y,camera.position.z,sky.altitudeMeters};
  result.shadowSlice = {sky.closeupShadowSlice.x,sky.closeupShadowSlice.y,1.f/2048.f,1.f/1024.f};
  result.skyParameters = {sky.cloudCoverage,sky.rainIntensity,
                          1.f-smoothstep(-0.18f,0.f,sky.sunDirection.y),sky.sunIntensity*exposure};
  const float night = 0.36f/Pi*exposure;
  result.fogColor = {
    sky.fogColor.x*(result.ambientColor.x+result.sunColor.x/Pi+0.3f*night),
    sky.fogColor.y*(result.ambientColor.y+result.sunColor.y/Pi+0.26f*night),
    sky.fogColor.z*(result.ambientColor.z+result.sunColor.z/Pi+night),0.f};
  result.fogParameters = {sky.fogNear,sky.fogFar,0.f,0.f};
  result.inverseViewProjection = camera.inverseViewProjection;
  return result;
  }
