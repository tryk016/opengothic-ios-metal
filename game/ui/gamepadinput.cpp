#include "gamepadinput.h"

#include <Tempest/Event>
#include <Tempest/Log>
#include <cmath>

#include "game/playercontrol.h"

using A = KeyCodec::Action;
using M = KeyCodec::Mapping;

GamepadInput::GamepadInput(PlayerControl& ctrl) : ctrl(ctrl) {
  }

void GamepadInput::edge(bool now, bool before, A a) {
  if(now && !before)
    ctrl.onKeyPressed(a, Tempest::Event::K_NoKey, M::Primary);
  else if(!now && before)
    ctrl.onKeyReleased(a, M::Primary);
  }

void GamepadInput::tick(uint64_t dt) {
  GamepadState s = Gamepad::poll();
  if(!s.connected) {
    prev = s;
    return;
    }

  // Left stick -> movement (digital, dead-zoned). Forward == stick up (ly>0).
  const bool fwd   = s.ly >  DEAD, back  = s.ly < -DEAD;
  const bool left  = s.lx < -DEAD, right = s.lx >  DEAD;
  edge(fwd,   prev.ly >  DEAD, A::Forward);
  edge(back,  prev.ly < -DEAD, A::Back);
  edge(left,  prev.lx < -DEAD, A::Left);
  edge(right, prev.lx >  DEAD, A::Right);

  // Right stick -> analog camera look.
  if(std::abs(s.rx) > DEAD || std::abs(s.ry) > DEAD) {
    const float scale = float(dt) * LOOK;
    ctrl.onRotateMouse(-s.rx * scale, -s.ry * scale);
    }

  // Face buttons (Gothic Classic):
  //   A = primary interact / attack, B = jump, X = crouch/sneak, Y = draw weapon.
  edge(s.a, prev.a, A::ActionGeneric);
  edge(s.b, prev.b, A::Jump);
  edge(s.x, prev.x, A::Sneak);
  edge(s.y, prev.y, A::Weapon);

  // Right trigger -> block/parry (analog, thresholded).
  const bool rtDown = s.rt > TRIG;
  edge(rtDown, prevRT, A::Parade);
  prevRT = rtDown;

  // Stick presses: R3 = target (provisional: LookBack), L3 = toggle walk/run.
  edge(s.r3, prev.r3, A::LookBack);
  edge(s.l3, prev.l3, A::Walk);

  // D-pad -> quick-access items (Heal / Potion as a start).
  edge(s.dup,   prev.dup,   A::Heal);
  edge(s.ddown, prev.ddown, A::Potion);

  // Menus. LB is the modifier for quick save/load; bare presses open menus.
  if(!s.lb) {
    edge(s.options, prev.options, A::Inventory);
    edge(s.menu,    prev.menu,    A::Escape);
    }
  else {
    // Quick save/load have no dedicated KeyCodec::Action yet; log rather than
    // fake a binding. See ios/README-ios.md "Known limitations".
    if(s.menu && !prev.menu)
      Tempest::Log::i("[pad] quick-save combo (bind pending)");
    if(s.options && !prev.options)
      Tempest::Log::i("[pad] quick-load combo (bind pending)");
    }

  prev = s;
  }
