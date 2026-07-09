#include "touchinput.h"

#include <Tempest/Painter>

#include "game/playercontrol.h"
#include "gothic.h"

using namespace Tempest;
using A = KeyCodec::Action;
using M = KeyCodec::Mapping;

TouchInput::TouchInput(PlayerControl& ctrl) : ctrl(ctrl) {
  }

bool TouchInput::active() const {
  return Gothic::inst().isInGame() && !Gothic::inst().isPause();
  }

std::array<TouchInput::Btn,6> TouchInput::layout() const {
  const int W = w(), H = h();
  const int s  = H/8;             // button size
  const int m  = H/40;            // margin
  const int bx = W - s - m;       // right column x
  const int by = H - s - m;       // bottom row y
  return {{
    { bx,          by,          s, A::ActionGeneric, 0.90f, 0.30f, 0.30f }, // interact/attack
    { bx,          by-(s+m),    s, A::Jump,          0.30f, 0.60f, 0.90f }, // jump
    { bx-(s+m),    by,          s, A::Weapon,        0.90f, 0.80f, 0.30f }, // draw weapon
    { bx-(s+m),    by-(s+m),    s, A::Sneak,         0.50f, 0.90f, 0.40f }, // sneak/crouch
    { W-s-m,       m,           s, A::Inventory,     0.85f, 0.85f, 0.85f }, // inventory
    { W-2*(s+m),   m,           s, A::Escape,        0.85f, 0.85f, 0.85f }, // menu/escape
  }};
  }

void TouchInput::paintEvent(PaintEvent& e) {
  if(!active())
    return;
  Painter p(e);

  const int H  = h();
  const int ms = H/3, mm = H/20;
  p.setBrush(Color(1.f, 1.f, 1.f, 0.10f));            // movement pad (bottom-left)
  p.drawRect(mm, H-ms-mm, ms, ms);

  for(auto& b:layout()) {
    p.setBrush(Color(b.r, b.g, b.b, 0.22f));
    p.drawRect(b.x, b.y, b.s, b.s);
    }
  }

void TouchInput::mouseDownEvent(MouseEvent& e) {
  if(!active()) { e.ignore(); return; }

  const Point pos = e.pos();
  const int   id  = e.mouseID;

  for(auto& b:layout())
    if(pos.x>=b.x && pos.x<b.x+b.s && pos.y>=b.y && pos.y<b.y+b.s) {
      ctrl.onKeyPressed(b.act, Event::K_NoKey, M::Primary);
      btnDown[id] = b.act;
      return;
      }

  const int H = h(), ms = H/3, mm = H/20;
  const bool inMove = pos.x>=mm && pos.x<mm+ms && pos.y>=H-ms-mm && pos.y<H-mm;
  if(inMove) {
    moveId = id; moveOrigin = pos;
    return;
    }
  if(pos.x > w()/2) {            // right side (not a button) -> camera
    lookId = id; lookLast = pos;
    return;
    }
  e.ignore();                    // leave the rest for menus/HUD
  }

void TouchInput::mouseDragEvent(MouseEvent& e) {
  if(!active()) { e.ignore(); return; }

  const Point pos = e.pos();
  const int   id  = e.mouseID;

  if(id==lookId) {
    const Point d = pos - lookLast;
    lookLast = pos;
    ctrl.onRotateMouse(float(-d.x)*4.f, float(-d.y)*2.f);
    return;
    }

  if(id==moveId) {
    const int H  = h();
    const int dz = H/16;         // dead-zone
    const int dx = pos.x - moveOrigin.x;
    const int dy = pos.y - moveOrigin.y;
    auto set = [&](int idx, bool on, A a){
      if(on && !mv[idx])       { ctrl.onKeyPressed(a, Event::K_NoKey, M::Primary); mv[idx]=true;  }
      else if(!on && mv[idx])  { ctrl.onKeyReleased(a, M::Primary);                mv[idx]=false; }
      };
    set(0, dy < -dz, A::Forward);
    set(1, dy >  dz, A::Back);
    set(2, dx < -dz, A::Left);
    set(3, dx >  dz, A::Right);
    return;
    }
  e.ignore();
  }

void TouchInput::mouseUpEvent(MouseEvent& e) {
  const int id = e.mouseID;

  auto it = btnDown.find(id);
  if(it!=btnDown.end()) {
    ctrl.onKeyReleased(it->second, M::Primary);
    btnDown.erase(it);
    return;
    }

  if(id==moveId) {
    if(mv[0]) ctrl.onKeyReleased(A::Forward, M::Primary);
    if(mv[1]) ctrl.onKeyReleased(A::Back,    M::Primary);
    if(mv[2]) ctrl.onKeyReleased(A::Left,    M::Primary);
    if(mv[3]) ctrl.onKeyReleased(A::Right,   M::Primary);
    mv[0]=mv[1]=mv[2]=mv[3]=false;
    moveId = -1;
    return;
    }

  if(id==lookId) { lookId = -1; return; }

  e.ignore();
  }
