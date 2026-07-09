#pragma once

#include <Tempest/Widget>
#include <array>
#include <unordered_map>

#include "utils/keycodec.h"

class PlayerControl;
class MenuRoot;

// On-screen touch overlay for when no gamepad is connected.
//  * In game: left-bottom pad = movement, right side = camera, right-column
//    buttons = actions. Multitouch via MouseEvent::mouseID.
//  * In a menu: on-screen Up / Down / OK / Back buttons drive MenuRoot.
class TouchInput : public Tempest::Widget {
  public:
    TouchInput(PlayerControl& ctrl, MenuRoot& menu);

    void paintEvent(Tempest::PaintEvent& e);
    void mouseDownEvent(Tempest::MouseEvent& e);
    void mouseDragEvent(Tempest::MouseEvent& e);
    void mouseUpEvent(Tempest::MouseEvent& e);

  private:
    struct Btn  { int x, y, s; KeyCodec::Action        act; float r, g, b; };
    struct MBtn { int x, y, s; Tempest::Event::KeyType key; float r, g, b; };
    std::array<Btn,6>  layout()     const;
    std::array<MBtn,4> menuLayout() const;
    bool active() const;   // true while in gameplay (not menu, not paused)

    PlayerControl& ctrl;
    MenuRoot&      menu;

    int            moveId = -1;   // touch id driving movement
    int            lookId = -1;   // touch id driving camera
    Tempest::Point moveOrigin;
    Tempest::Point lookLast;
    bool           mv[4] = {};    // forward, back, left, right currently pressed
    std::unordered_map<int,KeyCodec::Action> btnDown;
  };
