#pragma once

#include <Tempest/Vec>
#include <cstdint>

struct PfxParticle final {
  Tempest::Vec3 pos;
  uint32_t color = 0;
  Tempest::Vec3 size;
  uint32_t bits0 = 0;
  Tempest::Vec3 dir;
  uint32_t colorB = 0;
  };
