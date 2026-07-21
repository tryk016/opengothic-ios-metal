#pragma once

#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)

#include <cstdint>

// Read-only, diagnostics-only terminal evidence consumed by the autonomous
// semantic UI script. Values are published only after an accepted present and
// a terminal frame fence (or confirmed device idle).
struct IOSFunctionalEvidenceSnapshot final {
  uint64_t inventorySerial         = 0;
  uint64_t inventoryItemDrawCount  = 0;
  uint64_t itemRingSerial          = 0;
  uint64_t itemRingItemDrawCount   = 0;
  uint64_t weaponRingSerial        = 0;
  uint64_t weaponRingItemDrawCount = 0;
  uint64_t resumeSerial            = 0;
  uint64_t resumeCycle             = 0;
  };

#endif
