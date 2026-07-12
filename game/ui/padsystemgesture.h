#pragma once

#include <cstdint>

// Shared reducer for the physical and on-screen controller system buttons.
// Effects are emitted only after an unambiguous tap/hold/chord decision, so
// opening a UI page can never race a pending LB shortcut.
class PadSystemGesture final {
  public:
    enum class Button : uint8_t {
      Lb,
      View,
      Menu,
      };

    enum class Effect : uint8_t {
      None,
      Map,
      Inventory,
      QuestLog,
      Status,
      GameMenu,
      QuickLoad,
      QuickSave,
      };

    static constexpr uint64_t HoldMs = 600;

    constexpr PadSystemGesture() = default;

    constexpr void reset(bool lbHeld=false, bool viewHeld=false,
                         bool menuHeld=false) {
      reset(lb,lbHeld);
      reset(view,viewHeld);
      reset(menu,menuHeld);
      chord = Effect::None;
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
        if(button==Button::Lb) {
          // Accept either chord order. Delaying View/Menu until release makes
          // View->LB and Menu->LB as safe as modifier-first input.
          if(view.down && menu.down) {
            cancelChord();
            return Effect::None;
            }
          if(view.down) {
            if(view.phase==Phase::Pending)
              beginChord(Button::View);
            else
              cancelChord();
            return Effect::None;
            }
          if(menu.down) {
            if(menu.phase==Phase::Pending)
              beginChord(Button::Menu);
            else
              cancelChord();
            return Effect::None;
            }
          return Effect::None;
          }

        if(lb.down) {
          current.phase = Phase::Consumed;
          const State& other = button==Button::View ? menu : view;
          if(other.down) {
            cancelChord();
            return Effect::None;
            }
          if(lb.phase==Phase::Pending)
            beginChord(button);
          else if(chord!=Effect::None)
            cancelChord();
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

      // Chords fire on the first participating release. This short delay lets
      // an accidental LB+View+Menu triple chord cancel safely instead of
      // choosing quick-load and risking unsaved progress.
      const bool chordRelease =
          phase==Phase::Consumed && chord!=Effect::None &&
          (button==Button::Lb ||
           (button==Button::View && chord==Effect::QuickLoad) ||
           (button==Button::Menu && chord==Effect::QuickSave));
      if(chordRelease) {
        const Effect effect = chord;
        chord = Effect::None;
        return effect;
        }
      if(phase!=Phase::Pending)
        return Effect::None;
      if(button==Button::Lb)
        return Effect::Map;
      const bool held = now-current.since>=HoldMs;
      if(button==Button::View)
        return held ? Effect::QuestLog : Effect::Inventory;
      return held ? Effect::GameMenu : Effect::Status;
      }

    constexpr Effect tick(uint64_t now) {
      if(view.down && view.phase==Phase::Pending &&
         now-view.since>=HoldMs) {
        view.phase = Phase::Consumed;
        return Effect::QuestLog;
        }
      if(menu.down && menu.phase==Phase::Pending &&
         now-menu.since>=HoldMs) {
        menu.phase = Phase::Consumed;
        return Effect::GameMenu;
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

    static constexpr void reset(State& state, bool held) {
      state.down  = held;
      state.phase = held ? Phase::Suppressed : Phase::Idle;
      state.since = 0;
      }

    constexpr State& state(Button button) {
      if(button==Button::Lb)
        return lb;
      if(button==Button::View)
        return view;
      return menu;
      }

    constexpr const State& state(Button button) const {
      if(button==Button::Lb)
        return lb;
      if(button==Button::View)
        return view;
      return menu;
      }

    constexpr void beginChord(Button systemButton) {
      lb.phase = Phase::Consumed;
      state(systemButton).phase = Phase::Consumed;
      chord = systemButton==Button::View ? Effect::QuickLoad : Effect::QuickSave;
      }

    constexpr void cancelChord() {
      if(lb.down)
        lb.phase = Phase::Consumed;
      if(view.down)
        view.phase = Phase::Consumed;
      if(menu.down)
        menu.phase = Phase::Consumed;
      chord = Effect::None;
      }

    State lb;
    State view;
    State menu;
    Effect chord = Effect::None;
  };

constexpr bool padSystemGestureCompileTests() {
  using B = PadSystemGesture::Button;
  using E = PadSystemGesture::Effect;
  PadSystemGesture g;

  if(g.onButton(B::View,true,0)!=E::None ||
     g.onButton(B::View,false,1)!=E::Inventory)
    return false;
  if(g.onButton(B::Menu,true,10)!=E::None ||
     g.onButton(B::Menu,false,11)!=E::Status)
    return false;

  g.reset();
  if(g.onButton(B::View,true,100)!=E::None ||
     g.tick(699)!=E::None || g.tick(700)!=E::QuestLog ||
     g.onButton(B::View,false,701)!=E::None)
    return false;
  if(g.onButton(B::Menu,true,1000)!=E::None ||
     g.onButton(B::Menu,false,1599)!=E::Status)
    return false;
  if(g.onButton(B::Menu,true,2000)!=E::None ||
     g.onButton(B::Menu,false,2600)!=E::GameMenu)
    return false;

  g.reset();
  if(g.onButton(B::Lb,true,3000)!=E::None ||
     g.onButton(B::Lb,false,3001)!=E::Map)
    return false;

  // Both ordinary chord orders, and both possible release orders.
  g.reset();
  if(g.onButton(B::Lb,true,4000)!=E::None ||
     g.onButton(B::View,true,4001)!=E::None ||
     g.onButton(B::View,false,4002)!=E::QuickLoad ||
     g.onButton(B::Lb,false,4003)!=E::None)
    return false;
  g.reset();
  if(g.onButton(B::Menu,true,5000)!=E::None ||
     g.onButton(B::Lb,true,5001)!=E::None ||
     g.onButton(B::Lb,false,5002)!=E::QuickSave ||
     g.onButton(B::Menu,false,5003)!=E::None)
    return false;
  g.reset();
  if(g.onButton(B::View,true,6000)!=E::None ||
     g.onButton(B::Lb,true,6001)!=E::None ||
     g.onButton(B::View,false,6002)!=E::QuickLoad ||
     g.onButton(B::Lb,false,6003)!=E::None)
    return false;
  g.reset();
  if(g.onButton(B::Lb,true,7000)!=E::None ||
     g.onButton(B::Menu,true,7001)!=E::None ||
     g.onButton(B::Lb,false,7002)!=E::QuickSave ||
     g.onButton(B::Menu,false,7003)!=E::None)
    return false;

  // One LB hold can execute at most one shortcut.
  g.reset();
  if(g.onButton(B::Lb,true,8000)!=E::None ||
     g.onButton(B::View,true,8001)!=E::None ||
     g.onButton(B::View,false,8002)!=E::QuickLoad)
    return false;
  g.reset(true,false,false);
  if(g.onButton(B::Menu,true,8003)!=E::None ||
     g.onButton(B::Menu,false,8004)!=E::None ||
     g.onButton(B::Lb,false,8005)!=E::None)
    return false;

  // Ambiguous triples are consumed without a destructive effect.
  g.reset();
  if(g.onButton(B::Lb,true,9000)!=E::None ||
     g.onButton(B::View,true,9001)!=E::None ||
     g.onButton(B::Menu,true,9002)!=E::None ||
     g.onButton(B::View,false,9003)!=E::None ||
     g.onButton(B::Menu,false,9004)!=E::None ||
     g.onButton(B::Lb,false,9005)!=E::None)
    return false;
  g.reset();
  if(g.onButton(B::View,true,9100)!=E::None ||
     g.onButton(B::Menu,true,9101)!=E::None ||
     g.onButton(B::Lb,true,9102)!=E::None ||
     g.onButton(B::Lb,false,9103)!=E::None ||
     g.onButton(B::Menu,false,9104)!=E::None ||
     g.onButton(B::View,false,9105)!=E::None)
    return false;

  // A carried/suppressed third button still makes the chord ambiguous.
  g.reset(false,false,true);
  if(g.onButton(B::Lb,true,9200)!=E::None ||
     g.onButton(B::View,true,9201)!=E::None ||
     g.onButton(B::View,false,9202)!=E::None ||
     g.onButton(B::Lb,false,9203)!=E::None ||
     g.onButton(B::Menu,false,9204)!=E::None)
    return false;
  g.reset(false,true,false);
  if(g.onButton(B::Lb,true,9300)!=E::None ||
     g.onButton(B::Menu,true,9301)!=E::None ||
     g.onButton(B::Menu,false,9302)!=E::None ||
     g.onButton(B::Lb,false,9303)!=E::None ||
     g.onButton(B::View,false,9304)!=E::None)
    return false;

  // A carried system button also prevents LB from looking like a solo tap.
  g.reset(false,true,false);
  if(g.onButton(B::Lb,true,9400)!=E::None ||
     g.onButton(B::Lb,false,9401)!=E::None ||
     g.onButton(B::View,false,9402)!=E::None)
    return false;
  g.reset(false,false,true);
  if(g.onButton(B::Lb,true,9500)!=E::None ||
     g.onButton(B::Lb,false,9501)!=E::None ||
     g.onButton(B::Menu,false,9502)!=E::None)
    return false;

  g.reset(true,true,true);
  if(g.onButton(B::Lb,false,10000)!=E::None ||
     g.onButton(B::View,false,10000)!=E::None ||
     g.onButton(B::Menu,false,10000)!=E::None)
    return false;
  return true;
  }

static_assert(padSystemGestureCompileTests());
