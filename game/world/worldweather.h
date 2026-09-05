#pragma once

#include "game/gametime.h"

#include <algorithm>
#include <cstdint>

struct WorldWeather final {
  float clouds = 0.15f;
  float rain = 0.f;
  };

// World time makes the same saved day reproduce its weather without save fields.
inline WorldWeather worldWeather(gtime time, uint32_t worldSeed, float rainOverride = -1.f) {
  if(rainOverride>=0.f)
    return {0.15f+0.7f*rainOverride,rainOverride};
  uint32_t day = uint32_t(time.day())*747796405u+worldSeed;
  day ^= day>>16;
  day *= 2246822519u;
  if(day%3u!=0u)
    return {};
  const float hour = float(time.timeInDay().toInt())/3600000.f;
  const float start = 4.f+float((day>>8)%12u);
  const auto ramp = [](float t) { t = std::clamp(t,0.f,1.f); return t*t*(3.f-2.f*t); };
  const float rain = ramp((hour-start)*2.f)*ramp((start+3.f-hour)*2.f);
  const float cloud = ramp((hour-start+1.5f)/1.5f)*ramp((start+4.5f-hour)/1.5f);
  return {0.15f+0.7f*cloud,rain};
  }
