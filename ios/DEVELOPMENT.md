# OpenGothic iOS — development notes & technical documentation

Full technical record of the iOS-port fork work: what was built, how it fits
together, the obstacles hit, and what remains. Companion to the running task list
in [`TODO.md`](TODO.md). Status as of 2026-07-10.

> **State:** compiles green on the CI iOS toolchain; **not yet verified on a
> device.** Everything below is "implemented + builds", not "tested".

---

## 1. Project overview

- **Goal:** a playable, sideloadable build of OpenGothic (Gothic II: NotR) for
  iPhone/iPad, controllable with a Bluetooth pad **or** a full on-screen virtual
  gamepad, installable with a **free Apple ID** (no Mac, no paid account).
- **Repo:** fork `github.com/tryk016/opengothic-ios` (remote `origin`);
  upstream `github.com/Try/OpenGothic` (`upstream`). Branch `master`.
- **Base engine:** OpenGothic + the **Tempest** engine (submodule `lib/Tempest`),
  which already shipped a Metal backend and a UIKit iOS platform layer
  (`lib/Tempest/Engine/system/api/iosapi.mm`). The port was ~70–80% present; this
  work finished and hardened it.
- **Source specs (in `C:\Users\pbaran\Downloads`, not in-repo):**
  `opengothic-ios-raport.md` (code review: bugs B1–B9, N1–N5 + a dialogue-voice
  diagnosis) and `opengothic-ios-sterowanie-spec*.md` (the "ideal gamepad"
  control spec §1–§9). All fixes below trace to those.

## 2. Environment & workflow (important)

- **Authoring = Windows** (this repo). **You cannot compile or run iOS on
  Windows.** All source is written here.
- **Build/verify = GitHub Actions** (`.github/workflows/ios.yml`) on a
  `macos-latest` runner. Push to `master`/`main`/`ios` → it checks out submodules
  recursively, runs `ios/patches/apply-patches.sh`, configures with CMake (Xcode
  generator, arm64, iOS 15), builds `RelWithDebInfo`, and uploads an **unsigned
  `.ipa`** artifact. `paths-ignore` skips `**.md` and `docs/**`, so doc-only
  pushes don't trigger a build.
- **The CI build is the verification step.** Loop: implement on Windows → commit
  (conventional `fix(ios):` / `feat(ios):` / `docs(ios):`) → push to `master` →
  watch CI (`gh run watch <id> -R tryk016/opengothic-ios --exit-status`) → next.
  A build is ~7–10 min. **Never claim "works"** before a green build; even then
  it's "compiles", not "tested on device".
- **Device:** user's is an iPhone 16 Pro Max (8 GB, A18 Pro).
- **Install:** unsigned `.ipa` → AltStore/SideStore/Sideloadly re-signs with a
  free Apple ID (7-day cert). Game data (`Data/`, `_work/`, `system/`) goes in the
  app's **Documents** folder.

## 3. Submodule patch mechanism (Tempest)

`lib/Tempest` is fetched fresh by CI, so **edits to it don't persist** — they must
be re-applied by `ios/patches/apply-patches.sh` (perl, idempotent, fail-loud; run
by CI and the Mac build). To change Tempest: add a guarded perl patch block there
(pattern: `grep` guard → `perl -0777 -pi -e 's/.../.../'` → verify or `exit 1`).
**Test it locally** before pushing (`bash ios/patches/apply-patches.sh`) — CI is
fail-loud so a bad regex wastes a whole build. Patches currently applied:

1. ViewController `[super init]` (pre-existing; fixes iOS 17/18 launch crash).
2. **B4** `-touchesCancelled:` → forwards to `-touchesEnded:` (no stuck keys on
   system touch-cancel).
3. **N3** fiber stack `1 MB → 8 MB` (deep VM/vob recursion headroom).
4. **N2** `implDestroyWindow` invalidates `displayLink` + nulls `owner`.
5. **Landscape lock** — both `supportedInterfaceOrientations` → `MaskLandscape`.
6. **Idle timer** — `application.idleTimerDisabled = YES` in
   `applicationDidBecomeActive` (keep screen awake).

## 4. Input architecture (the core of the work)

Everything routes through a **context dispatcher** so the same pad/touch works in
gameplay, menus, dialogue and inventory.

- **`PadCtx`** (`game/ui/gamepadinput.h`): `World / Dialog / Menu / Inventory /
  Loading`. **`MainWindow::padContext()`** picks one per frame from widget state
  (`dialogs`/`rootMenu`/`inventory`/`video`/`chapter`/`document`, loading flag).
- **`MainWindow::dispatchKey(KeyEvent&)`** routes a synthetic key to whichever UI
  widget is active (mirrors `keyDownEvent`). **`MainWindow::uiAction(Action)`**
  performs window-level Escape/Inventory/Log/Status (shared with the keyboard
  `keyUpEvent`, which was refactored to call it) — this is the **B1** fix: those
  actions live in `MainWindow`, not `PlayerControl`, so pad/touch must call here.
- **`GamepadInput`** (`game/ui/gamepadinput.*`) holds `MainWindow& owner` +
  `PlayerControl& ctrl`. Per tick: read pad, pick context, and
  `tickWorld/tickDialog/tickMenu/tickInvent`. World → `PlayerControl` actions +
  analog look; UI contexts → synthetic keys via `dispatchKey`. Owns the two
  rings; when a ring is open it captures input. Reads config in `loadConfig()`.
- **`TouchInput`** (`game/ui/touchinput.*`) is the on-screen fallback, also driven
  by `padContext()`. In World it draws a **full virtual gamepad** (16 glyph
  buttons + move pad + camera area); each button dispatches by `TAct` kind to
  `ctrl` / `uiAction` / `MainWindow::pad*` bridges. Hidden entirely when a
  physical pad is connected (`Gamepad::poll().connected`).
- **`PadGlyph`** (`game/ui/padglyph.*`) draws controller-style buttons. Prefers
  bundled **Xelu** textures (`PadGlyph::texture` in `padglyphtex.mm`), falls back
  to code-drawn glyphs (discs via triangle fans, pills, arrows) if a texture is
  missing.
- **`QuickRing`** (`game/ui/quickring.*`) — radial weapon/item quick-bar; content
  pulled from `Npc::inventory()`, activation via `Npc::useItem` (equips weapons /
  consumes items).

Key upstream hooks used: `PlayerControl::onKeyPressed/Released/onRotateMouse`,
`tickFocus`/`moveFocus`/`setTarget` (target-lock), `Inventory`/`Item` +
`Npc::useItem` (rings), `Gothic::save/load/settingsGet*/settingsSet*`,
`World::findWayPoint` + `Npc::setPosition` (stuck warp), `Npc::attribute(ATR_HITPOINTS)`
(damage haptic), `Resources::loadTexturePm`/`Pixmap(path)` (glyph textures).

## 5. Feature inventory (what was done)

**Critical bug cluster** (review B-ids):
- Dialogue voice-over: `resources.cpp` skipped every `Speech*.vdf` on iOS; now
  memory-gated (mount on ≥4 GB, skip on <4 GB). Root cause of "no dialogue voice".
- **B1** Escape/Inventory live on pad+touch via `uiAction`.
- **B2** context dispatcher (pad+touch work in menus/dialogue/inventory).
- **B3** gamepad quick save/load (LB+Menu / LB+View) with the F5/F9 guards.
- **B5** pad-disconnect releases held actions.
- **B6** camera Y unified with touch; `invertY` config.
- **B7** split fatal exception handling in `main.cpp` (data-not-found vs real
  crash; no second `Application` over a torn-down window).

**Lifecycle / audio hardening:** B4 touchesCancelled, B8 `AVAudioSession`
(`game/utils/audiosession.*` + AVFoundation link), N2/N3 (see patches), N5
Info.plist keys (`UIRequiresFullScreen`, encryption, GameController), landscape
lock, keep-screen-awake, Game Mode keys (`GCSupportsGameMode`,
`LSApplicationCategoryType`).

**"Ideal controls" (control spec §3–§8):**
- §3 **Target-lock:** R3 pins the npc focus (`PlayerControl::toggleTargetLock`);
  `tickFocus` keeps it (no aim-switching) and auto-releases on death/leave
  (`World::validateFocus` + `Npc::isDead`); D-pad ←/→ = `focusLeft/Right`; a
  corner-bracket **reticle** is drawn in `paintFocus`.
- §4 **Radial rings:** RB=weapons, LT=items; hold + right-stick aim, release to
  activate. `QuickRing` owned by `GamepadInput`, drawn by `MainWindow`.
- §5 **Overlays:** controls-help hint bar (flash on context change, glyph+label),
  reticle, touch-overlay auto-hide with a pad, and **controller glyphs**
  (drawn + real Xelu art).
- §6 **Rotating quick-saves:** `save_slot_1..N`, auto-named per world, index in
  `[GAMEPAD] padQuickSlot` (flushed).
- §7 **Haptics** (`game/utils/haptics.*`, `UIImpactFeedbackGenerator`): heavy on
  HP-drop (polled in `MainWindow::tick`, no combat-code edits), light on
  lock/ring-commit, medium on quick-save.
- §8 **Config + stuck-protection:** `[GAMEPAD]` in Gothic.ini
  (deadZone/triggerThreshold/lookSensitivity/invertY/saveSlots/noStuckProtect);
  hold L3+R3 ~2 s → warp to nearest waypoint.

**Xelu glyphs + full virtual pad:** 18 CC0 PNGs (Xbox Series) in
`assets/controller/`, bundled via CMake (`MACOSX_PACKAGE_LOCATION Resources`),
loaded from the app bundle (`padglyphtex.mm`). The World touch overlay is a full
16-button virtual gamepad with touch ring-selection (tap RB/LT → drag aims →
release commits, via `GamepadInput::ring*` + `MainWindow::pad*`).

**Device-test round-1 fixes:**
- **Save crash:** `MainWindow::saveGame` captured a GPU thumbnail
  (`screenshoot`+`submit`+`readPixels`) that **aborts in the Metal driver on
  iOS**. On iOS it now skips that and saves a placeholder preview; also guards the
  saving screen against an empty banner texture.
- **Cutscene skip:** output-only cutscene lines (`state==Idle`, `current.time>0`)
  ignored input; `DialogMenu::keyDownEvent` now lets Esc/Return call `skipPhrase`
  there (touch Skip / pad B / keyboard).
- **FPS counter:** the existing mobile overlay is toggled via
  `Gothic.ini [GAME] showFpsCounter` (read in `Gothic::setupSettings`). A real
  in-menu checkbox needs MENU.DAT (game-data) editing — not done from engine code.

## 6. Obstacles & gotchas (read before editing)

- **Build flags are strict:** `-Wall -Wconversion -Wshorten-64-to-32 -Werror`.
  Every float→int / 64→32 narrowing needs an **explicit cast**; include the full
  type before using it. Real failures we hit:
  - `quickring.cpp` used `GthFont` via `Resources::font()` but didn't
    `#include "utils/gthfont.h"` → "member access into incomplete type". Fix:
    include it.
  - `touchinput.cpp` wrote `using G = PadGlyph;` — **`PadGlyph` is a namespace**,
    not a type. Fix: `namespace G = PadGlyph;`.
- **Metal mid-frame readback aborts** (the save crash). Uploading textures during
  paint is fine (`drawSaving` loads `SAVING.TGA` lazily; glyph textures load
  lazily too), but GPU→CPU **readback** (`readPixels`) during a frame is not.
- **Apple source split pattern** (avoid duplicate symbols): a feature needing
  Objective-C gets `foo.mm` (`#if defined(__IOS__)`) + `foo.cpp`
  (`#if !defined(__IOS__)`), because `game/*.cpp` compiles everywhere but
  `game/*.mm` only on Apple. Used by `systemmsg`, `audiosession`, `haptics`,
  `padglyphtex`.
- **MRC (no ARC):** `.mm` files must balance `alloc`/`release` (see `haptics.mm`,
  `padglyphtex.mm`); `installdetect.mm` asserts non-ARC.
- **`settingsGetI/F` has no default-value overload** — treat `0`/absent as "use
  default" for numeric config; for a default-**true** bool use an opt-**out** key
  (e.g. `noStuckProtect`).
- **`.gitattributes`:** `* text=auto` would corrupt binaries — added
  `*.png/*.tga/*.ico binary`. The `LF will be replaced by CRLF` warnings on text
  files are harmless (git stores LF).
- **Dialogue states:** interactive dialogue is `state!=Idle` (has choices);
  cutscene output is `state==Idle` with `current.time>0`; skip = `K_ESCAPE`
  (`skipPhrase`), confirm = `K_Return`.
- **Deviations from the spec that are intentional:** item ring on **LT** (not LB,
  which stays the save modifier); target-switch on **D-pad** (not right-stick
  flick, to avoid camera conflict); rings are **single-ring v1** (no concentric
  multi-ring / centre-easing / world-pause / pulse / 3D icons); haptics via
  `UIImpactFeedbackGenerator` (not Core Haptics) and HP-polling (not combat
  callbacks).

## 7. Commit timeline (oldest → newest, `4083df05` = fork base)

```
37a12e33 fix(ios): mount Speech*.vdf on >=4GB devices for dialogue voice
6d0864da fix(ios): split fatal exception handling (B7)
d4eadff7 feat(ios): context-aware gamepad dispatcher + live UI actions (B1/B2/B3/B5/B6)
152af722 feat(ios): AVAudioSession + fullscreen/controller plist keys (B8, N5)
9ef27eb9 fix(ios): Tempest iosapi patches — touchesCancelled/fiber stack/destroy (B4/N3/N2)
8526ab0d feat(ios): gamepad target-lock via native focus (spec 3)
79aed0e0 feat(ios): context-aware touch overlay (dialogue skip, menu value edit) + landscape lock
c0f30e50 fix(ios): save crash, cutscene skip, screen-awake/Game Mode, FPS toggle
17258ca7 feat(ios): gamepad config + rotating saves + controls-help/reticle (spec 5,6,8)
a65f30b8 feat(ios): radial weapon/item quick-bars (spec 4)
a7f42507 feat(ios): haptics + stuck-protection; fix quickring GthFont include (spec 7,8)
c74662fd feat(ios): drawn controller glyphs (spec 5)
ad858ac2 feat(ios): bundle + load real Xelu controller glyphs (Xbox Series, CC0)
5009daa2 feat(ios): full on-screen virtual gamepad with all buttons (touch)
af20cf53 fix(ios): namespace alias for PadGlyph in touchinput
47dddb80 docs: refresh README
(+ docs(ios) status commits in between)
```
Two builds failed once each and were fixed forward: `quickring` GthFont include
(in `a7f42507`) and the `PadGlyph` namespace alias (`af20cf53`). All others green.

## 8. Remaining work / known gaps

Recorded in [`TODO.md`](TODO.md). Highlights:
- **On-device testing & tuning of everything** — virtual-pad button layout/sizes,
  ring feel (dead-zone/threshold), haptic intensity, glyph sizing, camera
  sensitivity, hint wording. This is the biggest remaining item.
- Verify the Xelu glyphs actually load from the bundle on-device (if you see the
  drawn fallbacks, the bundle-resource path is wrong — adjust
  `MACOSX_PACKAGE_LOCATION`).
- Spec simplifications to revisit: concentric multi-ring with centre-easing +
  world-pause + pulse + 3D item icons (§4.3–4.5); camera auto-pull to locked
  target (§3); Dead/Container/MapDoc pad contexts (§1.1); inventory tab-switch +
  3D preview (§2.4); overlay daylight tint (§5.5).
- **Deferred B9/N1:** pause the game tick (`onTimer`) + `displayLink` while
  backgrounded. Risky because of the manual setjmp/longjmp fiber loop in
  `implExec` (naively sleeping the main context starves the UIKit run loop);
  needs on-device testing. Rendering is already gated on `isApplicationActive`.
- **Distribution (action needed):** the README now advertises a
  **Releases + SideStore-source** flow — download the prebuilt unsigned `.ipa`
  from the Releases page, or add the SideStore source
  `…/releases/download/latest/apps.json`. **`.github/workflows/ios.yml` does not
  implement this yet** — it only uploads a CI *artifact*. To make the README true,
  extend the workflow to: create/update a GitHub **Release** (tag `latest`) with
  the `.ipa` attached as `OpenGothic-unsigned.ipa`, and generate/commit an
  `apps.json` (SideStore/AltStore source manifest pointing at that asset). Until
  then, the Releases links 404. (Free-account signing still can't produce a
  tap-to-install build for others; only a paid account + TestFlight/ad-hoc can.)

## 9. Config reference (`Documents/Gothic.ini`)

```ini
[GAME]
showFpsCounter=1        ; on-screen FPS counter (mobile)
language=2              ; force Polish if you have Polish data
useQuickSaveKeys=1      ; enable quick save/load (may default off)

[GAMEPAD]
deadZone=0.25
triggerThreshold=0.50
lookSensitivity=0.20
invertY=0
saveSlots=5             ; rotating quick-save slot count
; noStuckProtect=1      ; disable the L3+R3 unstuck warp
; padQuickSlot=<n>      ; managed automatically (rotating save index)
```
