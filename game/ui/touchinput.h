#pragma once

#include <Tempest/Widget>
#include <array>
#include <unordered_map>

#include "utils/keycodec.h"

class PlayerControl;
class MainWindow;

// On-screen touch overlay for when no gamepad is connected. Context-aware via
// MainWindow::padContext():
//  * World     — left-bottom movement pad, right side = camera, action buttons.
//  * Menu/Inv  — on-screen D-pad (Up/Down/Left/Right) + OK/Back drive the UI.
//  * Dialogue  — Up/Down pick a choice, Select confirms, Skip skips the line.
// Multitouch via MouseEvent::mouseID.
class TouchInput : public Tempest::Widget {
  public:
    TouchInput(MainWindow& owner, PlayerControl& ctrl);

    void paintEvent(Tempest::PaintEvent& e);
    void mouseDownEvent(Tempest::MouseEvent& e);
    void mouseDragEvent(Tempest::MouseEvent& e);
    void mouseUpEvent(Tempest::MouseEvent& e);

  private:
    struct Btn  { int x, y, s; KeyCodec::Action        act; float r, g, b; };
    struct MBtn { int x, y, s; Tempest::Event::KeyType key; float r, g, b; };
    std::array<Btn,6>  layout()       const;   // gameplay action buttons
    std::array<MBtn,6> menuLayout()   const;   // menu / inventory: dpad + ok/back
    std::array<MBtn,4> dialogLayout() const;   // dialogue: up/down/select/skip

    MainWindow&    owner;
    PlayerControl& ctrl;

    int            moveId = -1;   // touch id driving movement
    int            lookId = -1;   // touch id driving camera
    Tempest::Point moveOrigin;
    Tempest::Point lookLast;
    bool           mv[4] = {};    // forward, back, left, right currently pressed
    std::unordered_map<int,KeyCodec::Action> btnDown;
  };
