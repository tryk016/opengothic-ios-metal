#pragma once

#include <cstdint>

struct IOSFrameStats final {
  uint64_t gpuFrames = 0;
  double   gpuTimeMs = 0;
  };
