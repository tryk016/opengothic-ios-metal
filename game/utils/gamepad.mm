#include "gamepad.h"

#include <Tempest/Platform>

#if defined(__IOS__)

#import <GameController/GameController.h>

namespace Gamepad {

GamepadState poll() {
  GamepadState s;

  GCController* c = nil;
  for(GCController* it in [GCController controllers])
    if(it.extendedGamepad!=nil) { c = it; break; }
  if(c==nil)
    return s;

  s.connected = true;
  GCExtendedGamepad* g = c.extendedGamepad;

  s.lx = g.leftThumbstick.xAxis.value;
  s.ly = g.leftThumbstick.yAxis.value;
  s.rx = g.rightThumbstick.xAxis.value;
  s.ry = g.rightThumbstick.yAxis.value;
  s.lt = g.leftTrigger.value;
  s.rt = g.rightTrigger.value;

  s.a = g.buttonA.isPressed;
  s.b = g.buttonB.isPressed;
  s.x = g.buttonX.isPressed;
  s.y = g.buttonY.isPressed;

  s.lb = g.leftShoulder.isPressed;
  s.rb = g.rightShoulder.isPressed;
  s.l3 = g.leftThumbstickButton.isPressed;
  s.r3 = g.rightThumbstickButton.isPressed;

  s.dup    = g.dpad.up.isPressed;
  s.ddown  = g.dpad.down.isPressed;
  s.dleft  = g.dpad.left.isPressed;
  s.dright = g.dpad.right.isPressed;

  s.menu    = g.buttonMenu.isPressed;
  s.options = (g.buttonOptions!=nil) ? g.buttonOptions.isPressed : false;

  return s;
  }

}

#endif
