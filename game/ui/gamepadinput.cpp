#include "gamepadinput.h"

#include <Tempest/Event>
#include <cmath>

#include "game/playercontrol.h"
#include "mainwindow.h"
#include "gothic.h"

using A = KeyCodec::Action;
using M = KeyCodec::Mapping;
using Tempest::Event;

GamepadInput::GamepadInput(MainWindow& owner, PlayerControl& ctrl)
  : owner(owner), ctrl(ctrl) {
  }

void GamepadInput::edge(bool now, bool before, A a) {
  if(now && !before)
    ctrl.onKeyPressed(a, Event::K_NoKey, M::Primary);
  else if(!now && before)
    ctrl.onKeyReleased(a, M::Primary);
  }

void GamepadInput::uiEdge(bool now, bool before, A a) {
  if(now && !before)
    owner.uiAction(a);
  }

void GamepadInput::key(bool now, bool before, Event::KeyType k) {
  if(now && !before) {
    Tempest::KeyEvent ev(k);
    owner.dispatchKey(ev);
    }
  }

void GamepadInput::releaseAllWorld() {
  for(A a : { A::Forward, A::Back, A::Left, A::Right,
              A::ActionGeneric, A::Jump, A::Sneak, A::Weapon,
              A::Parade, A::Walk, A::LookBack, A::Heal, A::Potion })
    ctrl.onKeyReleased(a, M::Primary);   // releasing a non-held action is harmless
  prevRT = false;
  }

void GamepadInput::tick(uint64_t dt) {
  GamepadState s = Gamepad::poll();
  if(!s.connected) {                 // pad vanished mid-hold -> release everything (B5)
    if(prev.connected)
      releaseAllWorld();
    prev    = GamepadState{};
    prevCtx = PadCtx::Loading;
    return;
    }

  const PadCtx ctx = owner.padContext();

  // Leaving gameplay for any UI: release held world actions so the character
  // doesn't keep walking/attacking while a menu or dialogue is open.
  if(ctx!=PadCtx::World && prevCtx==PadCtx::World)
    releaseAllWorld();
  // Entering gameplay: neutralize prev so still-held inputs re-fire as presses.
  if(ctx==PadCtx::World && prevCtx!=PadCtx::World) {
    prev = GamepadState{};
    prev.connected = true;
    }

  switch(ctx) {
    case PadCtx::World:     tickWorld(dt, s); break;
    case PadCtx::Dialog:    tickDialog(s);    break;
    case PadCtx::Inventory: tickInvent(s);    break;
    case PadCtx::Menu:      tickMenu(s);      break;
    case PadCtx::Loading:                     break;
    }

  prevCtx = ctx;
  prev    = s;
  }

void GamepadInput::tickWorld(uint64_t dt, const GamepadState& s) {
  // Left stick -> movement (digital, dead-zoned). Forward == stick up (ly>0).
  const bool fwd   = s.ly >  DEAD, back  = s.ly < -DEAD;
  const bool left  = s.lx < -DEAD, right = s.lx >  DEAD;
  edge(fwd,   prev.ly >  DEAD, A::Forward);
  edge(back,  prev.ly < -DEAD, A::Back);
  edge(left,  prev.lx < -DEAD, A::Left);
  edge(right, prev.lx >  DEAD, A::Right);

  // Right stick -> analog camera look. Y is unified with the touch overlay
  // convention (stick up == look up); invertY flips it (review B6).
  if(std::abs(s.rx) > DEAD || std::abs(s.ry) > DEAD) {
    const float scale = float(dt) * LOOK;
    const float yDir  = invertY ? -1.f : 1.f;
    ctrl.onRotateMouse(-s.rx * scale, s.ry * scale * yDir);
    }

  // Face buttons: A = interact/attack, B = jump, X = sneak, Y = draw weapon.
  edge(s.a, prev.a, A::ActionGeneric);
  edge(s.b, prev.b, A::Jump);
  edge(s.x, prev.x, A::Sneak);
  edge(s.y, prev.y, A::Weapon);

  // Right trigger -> block/parry (analog, thresholded).
  const bool rtDown = s.rt > TRIG;
  edge(rtDown, prevRT, A::Parade);
  prevRT = rtDown;

  // Stick presses: R3 = target (provisional LookBack), L3 = toggle walk/run.
  edge(s.r3, prev.r3, A::LookBack);
  edge(s.l3, prev.l3, A::Walk);

  // D-pad up/down -> quick items (Heal / Potion as a start).
  edge(s.dup,   prev.dup,   A::Heal);
  edge(s.ddown, prev.ddown, A::Potion);

  // LB modifier: bare View/Menu open inventory/menu (routed to the window, B1);
  // LB + View/Menu = quick load/save, mirroring the F5/F9 keyboard guards (B3).
  if(!s.lb) {
    uiEdge(s.options, prev.options, A::Inventory);
    uiEdge(s.menu,    prev.menu,    A::Escape);
    }
  else {
    const bool useQuickSaveKeys = Gothic::settingsGetI("GAME","useQuickSaveKeys")!=0;
    if(useQuickSaveKeys) {
      auto& g = Gothic::inst();
      if(s.menu    && !prev.menu    && g.isInGameAndAlive() && !g.isPause())
        g.quickSave();
      if(s.options && !prev.options && !g.isPause())
        g.quickLoad();
      }
    }
  }

void GamepadInput::tickDialog(const GamepadState& s) {
  const bool up   = s.ly >  DEAD || s.dup;
  const bool down = s.ly < -DEAD || s.ddown;
  key(up,   (prev.ly >  DEAD || prev.dup),   Event::K_Up);
  key(down, (prev.ly < -DEAD || prev.ddown), Event::K_Down);
  key(s.a,  prev.a, Event::K_Return);
  key(s.b,  prev.b, Event::K_ESCAPE);
  }

void GamepadInput::tickMenu(const GamepadState& s) {
  const bool up    = s.ly >  DEAD || s.dup;
  const bool down  = s.ly < -DEAD || s.ddown;
  const bool left  = s.lx < -DEAD || s.dleft;
  const bool right = s.lx >  DEAD || s.dright;
  key(up,    (prev.ly >  DEAD || prev.dup),    Event::K_Up);
  key(down,  (prev.ly < -DEAD || prev.ddown),  Event::K_Down);
  key(left,  (prev.lx < -DEAD || prev.dleft),  Event::K_Left);
  key(right, (prev.lx >  DEAD || prev.dright), Event::K_Right);
  key(s.a,    prev.a,    Event::K_Return);
  key(s.b,    prev.b,    Event::K_ESCAPE);
  key(s.menu, prev.menu, Event::K_ESCAPE);
  }

void GamepadInput::tickInvent(const GamepadState& s) {
  // Grid navigation like a menu; View (options) also closes.
  tickMenu(s);
  key(s.options, prev.options, Event::K_ESCAPE);
  }
