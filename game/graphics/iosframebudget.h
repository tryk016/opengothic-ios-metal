#pragma once

#include <algorithm>
#include <cstdint>

// Called once per second while playing. It changes cadence, never image settings.
struct IOSFrameBudget final {
  uint32_t fpsLimit = 0;
  uint32_t overloaded = 0, healthy = 0, cooldown = 0;

  void update(double cpuMs, double gpuMs, uint32_t requestedFps, bool hot) noexcept {
    if(cooldown>0)
      --cooldown;
    const uint32_t target = effectiveFps(requestedFps);
    const double budget = 1000./double(target==0 ? 60 : target);
    const double load = std::max(cpuMs,gpuMs);
    const bool slow = hot || load>budget*1.1;
    const uint32_t recoveryFps = fpsLimit==30 && requestedFps==0 ? 60 : requestedFps;
    const double recoveryBudget = 1000./double(recoveryFps==0 ? 60 : recoveryFps);
    overloaded = slow ? std::min(overloaded+1,3u) : 0;
    healthy = !hot && load>0 && load<recoveryBudget*0.75 ? std::min(healthy+1,30u) : 0;
    if(cooldown!=0)
      return;
    uint32_t next = fpsLimit;
    if(overloaded==3 && (target==0 || target>30))
      next = target==0 ? 60 : 30;
    else if(healthy==30 && fpsLimit!=0)
      next = recoveryFps==requestedFps ? 0 : recoveryFps;
    if(next!=fpsLimit) {
      fpsLimit = next;
      overloaded = healthy = 0;
      cooldown = 5;
      }
    }

  uint32_t effectiveFps(uint32_t requestedFps) const noexcept {
    if(fpsLimit==0)
      return requestedFps;
    return requestedFps==0 ? fpsLimit : std::min(requestedFps,fpsLimit);
    }
  };
