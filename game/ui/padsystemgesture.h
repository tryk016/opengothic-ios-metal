#pragma once

#include <cstdint>

// Shared reducer for the physical and on-screen controller system buttons.
// View uses an unambiguous tap/hold split; Menu fires immediately.  A held
// button carried from another UI context is suppressed until it is released.
class PadSystemGesture final {
  public:
    enum class Button : uint8_t {
      View,
      Menu,
      };

    enum class Effect : uint8_t {
      None,
      Inventory,
      Map,
      GameMenu,
      };

    static constexpr uint64_t HoldMs = 600;

    constexpr PadSystemGesture() = default;

    constexpr void reset(bool viewHeld=false, bool menuHeld=false) {
      reset(view,viewHeld);
      reset(menu,menuHeld);
      }

    constexpr bool down(Button button) const {
      return state(button).down;
      }

    constexpr Effect onButton(Button button, bool pressed, uint64_t now) {
      State& current = state(button);
      if(pressed) {
        if(current.down)
          return Effect::None;
        current.down = true;
        if(current.phase==Phase::Suppressed)
          return Effect::None;
        current.phase = Phase::Pending;
        current.since = now;
        if(button==Button::Menu) {
          current.phase = Phase::Consumed;
          return Effect::GameMenu;
          }
        return Effect::None;
        }

      if(!current.down) {
        if(current.phase==Phase::Suppressed)
          current.phase = Phase::Idle;
        return Effect::None;
        }

      current.down = false;
      const Phase phase = current.phase;
      current.phase = Phase::Idle;
      if(phase!=Phase::Pending)
        return Effect::None;
      return now-current.since>=HoldMs ? Effect::Map : Effect::Inventory;
      }

    constexpr Effect tick(uint64_t now) {
      if(view.down && view.phase==Phase::Pending &&
         now-view.since>=HoldMs) {
        view.phase = Phase::Consumed;
        return Effect::Map;
        }
      return Effect::None;
      }

  private:
    enum class Phase : uint8_t {
      Idle,
      Pending,
      Consumed,
      Suppressed,
      };

    struct State {
      bool     down  = false;
      Phase    phase = Phase::Idle;
      uint64_t since = 0;
      };

    static constexpr void reset(State& value, bool held) {
      value.down  = held;
      value.phase = held ? Phase::Suppressed : Phase::Idle;
      value.since = 0;
      }

    constexpr State& state(Button button) {
      return button==Button::View ? view : menu;
      }

    constexpr const State& state(Button button) const {
      return button==Button::View ? view : menu;
      }

    State view;
    State menu;
  };

constexpr bool padSystemGestureCompileTests() {
  using B = PadSystemGesture::Button;
  using E = PadSystemGesture::Effect;
  PadSystemGesture g;

  if(g.onButton(B::View,true,0)!=E::None ||
     g.onButton(B::View,false,1)!=E::Inventory)
    return false;

  g.reset();
  if(g.onButton(B::View,true,100)!=E::None ||
     g.tick(699)!=E::None || g.tick(700)!=E::Map ||
     g.onButton(B::View,false,701)!=E::None)
    return false;

  g.reset();
  if(g.onButton(B::Menu,true,1000)!=E::GameMenu ||
     g.onButton(B::Menu,false,1001)!=E::None)
    return false;

  // A system button carried back from another context cannot immediately
  // reopen a page; it has to return to neutral first.
  g.reset(true,true);
  if(g.onButton(B::View,false,2000)!=E::None ||
     g.onButton(B::Menu,false,2000)!=E::None)
    return false;
  if(g.onButton(B::View,true,2100)!=E::None ||
     g.onButton(B::View,false,2101)!=E::Inventory)
    return false;
  return true;
  }

static_assert(padSystemGestureCompileTests());
