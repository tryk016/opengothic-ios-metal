# iOS port — status & backlog

Tracked work beyond the core "build + run + control" milestone.
Bug ids (B1–B9, N1–N5) refer to the code-review report; phases refer to the
"ideal gamepad" control spec.

## ✅ Done — critical bugfix cluster (2026-07-10)
- [x] **Dialogue voice-over** — root cause was iOS unconditionally skipping
      `Speech*.vdf` (OOM guard for iPhone 7). Now mounted on ≥4 GB devices,
      skipped only on <4 GB. ZenKit mmaps archives → low resident cost.
      (`resources.cpp`)
- [x] **B7** — split fatal exception handling: `GothicNotFoundException` shows the
      "data not found" alert + keeps a run-loop (safe, pre-window); any other
      exception logs + exits without spinning a second `Application` over a
      half-torn-down window. (`main.cpp`)
- [x] **B1** — Escape / Inventory now live on pad **and** touch: window-level
      `MainWindow::uiAction()` (shared with the keyboard path), called instead of
      the no-op `PlayerControl::onKeyPressed`. (`mainwindow.*`, `touchinput.cpp`)
- [x] **B2** — context-aware pad dispatcher (`PadCtx` + `padContext()` +
      `dispatchKey()`): pad drives menus / dialogue / inventory via synthetic
      key events, not just gameplay. (`gamepadinput.*`, `mainwindow.*`)
- [x] **B3** — gamepad quick save/load wired to `Gothic::quickSave/quickLoad`
      with the F5/F9 guards (LB+Menu / LB+View). (`gamepadinput.cpp`)
- [x] **B5** — pad disconnect mid-hold releases all world actions (no stuck keys).
- [x] **B6** — camera Y sign unified with the touch overlay; `invertY` field added.
- [x] Touch navigation for **inventory** — resolved by the same dispatcher.

## ✅ Done — iOS lifecycle & audio hardening (2026-07-10)
- [x] **B4** — `touchesCancelled` handled in Tempest `iosapi.mm` (forwards to
      `touchesEnded`); fixes stuck movement + leaked touch id on system touch
      cancel. Applied via `ios/patches/apply-patches.sh`.
- [x] **B8** — `AVAudioSession` (Playback category, activated before any
      SoundDevice); linked `-framework AVFoundation`.
      (`game/utils/audiosession.{h,mm,cpp}`, `main.cpp`, `CMakeLists.txt`)
- [x] **N2** — `implDestroyWindow` invalidates `displayLink` + nulls `owner`
      (pairs with B7). Applied via `apply-patches.sh`.
- [x] **N3** — fiber stack 1 MB → 8 MB (deep VM/vob recursion headroom).
      Applied via `apply-patches.sh`.
- [x] **N5** — `Info.plist.in`: `UIRequiresFullScreen`, `ITSAppUsesNonExempt-
      Encryption=false`, `GCSupportsControllerUserInteraction`,
      `UIApplicationSupportsIndirectInputEvents`.

## ✅ Done — input coverage + landscape (2026-07-10)
- [x] **Touch dialogue controls** — the overlay is now context-aware
      (`MainWindow::padContext`): in dialogue it shows Up/Down (pick choice),
      Select (K_Return) and **Skip** (K_ESCAPE → `skipPhrase`), so lines can be
      skipped and choices confirmed from touch. (Pad already did this via B2.)
- [x] **Touch menu value editing** — menu/inventory overlay gained a full D-pad
      incl. **◀ ▶** (K_Left/K_Right), so sliders/options can be changed, plus
      OK/Back. Routed through `dispatchKey` to the active widget.
- [x] **Landscape orientation lock** — `Info.plist` landscape-only (iPhone+iPad)
      and both `supportedInterfaceOrientations` in `iosapi.mm` restricted to
      `MaskLandscape` (via `apply-patches.sh`); still rotates Left/Right.

## ⏳ To do — deferred (needs on-device iteration)
- [ ] **B9 / N1** — pause game tick (`onTimer`) + `displayLink` while
      backgrounded. Deferred: the manual setjmp/longjmp fiber loop in `implExec`
      means naively sleeping the main context starves the UIKit run loop; needs
      careful on-device testing. (Render is already gated on `isApplicationActive`.)

## ✅ Done — ideal controls, phase 3 (2026-07-10)
- [x] **Target-lock via native focus** (spec §3) — R3 pins the current npc focus
      (`PlayerControl::toggleTargetLock`); `tickFocus` keeps it instead of
      re-finding by aim, and auto-releases when the target dies/leaves
      (`World::validateFocus` + `Npc::isDead`). D-pad ←/→ switch target
      (`focusLeft/focusRight` → `moveFocus`). Existing focus highlight shows it.
      Replaces the provisional R3→`LookBack`.

## ⏳ To do — "ideal controls" (bigger, self-contained; control spec §4–§8)
- [ ] Radial rings: weapons (RB) + items (LB) quick-bars. (spec §4)
- [ ] Controls-help overlay + button glyphs (Xelu CC0) + target reticle. (spec §5)
- [ ] Rotating quick-saves with auto-names. (spec §6)
- [ ] Haptics via `GCController.haptics` / Core Haptics. (spec §7)
- [ ] Stuck-protection + `[GAMEPAD]` config in `Gothic.ini` (dead-zones,
      sensitivity, invert-Y, save slots). (spec §8) — wires the `invertY` field.

## ✅ Done — UI / readability
- [x] Scale up UI on iOS for high-DPI legibility (`MainWindow::uiScale`).
- [x] Dialogue subtitle window enlarged / reflowed for phone screens.
- [x] Dialogue **choice** list enlarged and made touch-friendly.
- [x] Main-menu text size verified after the uiScale change.

## ⏳ To do — Language
- [ ] Polish requires Polish game data (e.g. GOG Gold Edition or a PL install);
      then automatic, or force via `[GAME] language=2` in Documents/Gothic.ini.
