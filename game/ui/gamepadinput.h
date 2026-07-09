#pragma once

#include <cstdint>

#include "utils/gamepad.h"
#include "utils/keycodec.h"

class PlayerControl;

// Maps a GamepadState snapshot to PlayerControl actions each tick, following
// the Gothic Classic (THQ Nordic) console control scheme. Owns edge-detection
// (press/release) and analog dead-zones.
class GamepadInput {
  public:
    explicit GamepadInput(PlayerControl& ctrl);

    void tick(uint64_t dt);

  private:
    PlayerControl& ctrl;
    GamepadState   prev;
    bool           prevRT = false;

    void edge(bool now, bool before, KeyCodec::Action a);

    static constexpr float DEAD = 0.25f;   // stick dead-zone
    static constexpr float TRIG = 0.50f;   // trigger press threshold
    static constexpr float LOOK = 0.20f;   // camera speed per ms
  };
