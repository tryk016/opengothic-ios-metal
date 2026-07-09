#pragma once

#include <Tempest/Widget>
#include <array>
#include <unordered_map>

#include "utils/keycodec.h"

class PlayerControl;

// On-screen touch overlay used when no gamepad is connected. Active only while
// in game (not in menus). Left-bottom pad = movement, right side = camera look,
// right-column buttons = actions. Multitouch via MouseEvent::mouseID.
class TouchInput : public Tempest::Widget {
  public:
    TouchInput(PlayerControl& ctrl);

    void paintEvent(Tempest::PaintEvent& e);
    void mouseDownEvent(Tempest::MouseEvent& e);
    void mouseDragEvent(Tempest::MouseEvent& e);
    void mouseUpEvent(Tempest::MouseEvent& e);

  private:
    struct Btn { int x, y, s; KeyCodec::Action act; float r, g, b; };
    std::array<Btn,6> layout() const;
    bool active() const;

    PlayerControl& ctrl;

    int            moveId = -1;   // touch id driving movement
    int            lookId = -1;   // touch id driving camera
    Tempest::Point moveOrigin;
    Tempest::Point lookLast;
    bool           mv[4] = {};    // forward, back, left, right currently pressed
    std::unordered_map<int,KeyCodec::Action> btnDown;
  };
