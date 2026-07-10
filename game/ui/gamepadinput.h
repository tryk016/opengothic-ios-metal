#pragma once

#include <cstdint>

#include <Tempest/Event>

#include "utils/gamepad.h"
#include "utils/keycodec.h"

class PlayerControl;
class MainWindow;

// Active pad-routing context, chosen once per tick. The dispatcher sends the
// pad either to gameplay (PlayerControl) or, for any UI, to synthetic key
// events on the active widget — mirroring how the keyboard drives menus.
enum class PadCtx : uint8_t {
  World,      // normal gameplay
  Dialog,     // NPC dialogue choice
  Menu,       // main / pause / save menu, video, chapter, document
  Inventory,  // inventory / container
  Loading,    // world loading — ignore input
  };

// Maps a GamepadState snapshot to the game each tick, following the Gothic
// Classic (THQ Nordic) console scheme. Owns edge-detection and dead-zones, and
// routes per-context so the pad works in menus and dialogues, not just world.
class GamepadInput {
  public:
    GamepadInput(MainWindow& owner, PlayerControl& ctrl);

    void tick(uint64_t dt);

  private:
    MainWindow&    owner;
    PlayerControl& ctrl;
    GamepadState   prev;
    PadCtx         prevCtx = PadCtx::Loading;
    bool           prevRT  = false;

    void tickWorld (uint64_t dt, const GamepadState& s);
    void tickDialog(const GamepadState& s);
    void tickMenu  (const GamepadState& s);
    void tickInvent(const GamepadState& s);

    void edge  (bool now, bool before, KeyCodec::Action a);       // -> PlayerControl
    void uiEdge(bool now, bool before, KeyCodec::Action a);       // -> MainWindow::uiAction
    void key   (bool now, bool before, Tempest::Event::KeyType k);// synthetic KeyEvent
    void releaseAllWorld();                                       // drop held world actions

    static constexpr float DEAD = 0.25f;   // stick dead-zone
    static constexpr float TRIG = 0.50f;   // trigger press threshold
    static constexpr float LOOK = 0.20f;   // camera speed per ms
    bool  invertY = false;                 // camera Y invert (see review B6)
  };
