## OpenGothic for iOS

An **unofficial iOS port** of [OpenGothic](https://github.com/Try/OpenGothic) — the open-source
re-implementation of *Gothic II: Night of the Raven*. This fork adds the plumbing to build, sideload,
and play OpenGothic on iPhone/iPad with a Bluetooth controller **or** a full on-screen virtual gamepad.

> ### ⚠️ Work in progress — not yet fully tested
> This fork is under **active development** and has **not been verified end-to-end on a device** yet.
> The code compiles on the CI iOS toolchain, but gameplay, the controller mapping, the on-screen
> virtual gamepad, save/load, haptics and the graphics/controller glyphs still need on-device testing
> and tuning. Expect rough edges and bugs. See [`ios/TODO.md`](ios/TODO.md) for current status and
> known gaps.

> ### Credit
> **The entire engine is the work of [Try](https://github.com/Try) and the OpenGothic contributors.**
> OpenGothic and its rendering engine [Tempest](https://github.com/Try/Tempest) are what make this
> possible — this fork only finishes and wires up the iOS path. Please support the upstream project:
> ⭐ [Try/OpenGothic](https://github.com/Try/OpenGothic) · 💬 [Discord](https://discord.gg/G9XvcFQnn6).
> Not affiliated with or endorsed by the original authors; distributed under the same [license](LICENSE).
>
> Controller glyphs are **[Xelu's Free Controller & Keyboard Prompts](https://thoseawesomeguys.com/prompts)**
> by Nicolae "Xelu" Berbece (CC0).

![Screenshot](scr0.png)

---

### Prerequisites

*Gothic II: Night of the Raven* is required — OpenGothic ships **no** game assets or scripts. You must
legally own the game and supply its data yourself (see *Language & voices* below for edition notes).

Target: iPhone/iPad on **iOS 15+**, arm64. Best on modern GPUs (A-series / M-series). Locked to landscape.

### Install — just download, no build, no Mac

You do **not** need to fork this repo or compile anything. A prebuilt **unsigned `.ipa`** is published
on every update. Full walkthrough: **[ios/README-ios.md](ios/README-ios.md)**. In short:

1. **Download** — grab the latest **unsigned `.ipa`** from the
   **[Releases page](https://github.com/tryk016/opengothic-ios/releases/latest)**
   (asset `OpenGothic-unsigned.ipa`). No login or fork required.
2. **Install** — sign & install the `.ipa` with your **own free Apple ID** using **SideStore**,
   **AltStore**, or **Sideloadly**. No paid Apple Developer account, no App Store, no Mac. The free
   certificate expires every 7 days; **SideStore/AltStore auto-refresh it over Wi-Fi** so you don't have
   to reinstall manually.
   - **Easiest — add the SideStore source** (one-tap install + auto-updates): in SideStore go to
     **Sources → +** and paste
     `https://github.com/tryk016/opengothic-ios/releases/download/latest/apps.json`,
     then install OpenGothic from that source.
3. **Add game data** — copy the `Data/`, `_work/`, and `system/` folders from your Gothic II install into
   the app's **Documents** folder (Files app on iOS, or iTunes/Apple Devices File Sharing on Windows).
   Data persists across launches and app updates.

Want to build it yourself? Maintainers can trigger the [`iOS build`](.github/workflows/ios.yml) Action
(it publishes the Release automatically), or use [`ios/build-ios.sh`](ios/build-ios.sh) + Xcode on a Mac —
both are covered in the guide. **Regular users don't need this.**

### Sharing the build with other people

The CI publishes an **unsigned** `.ipa` to the **[Releases page](https://github.com/tryk016/opengothic-ios/releases/latest)**
on every update, so anyone can download it directly — no fork, no build, no account. There is no *free*
way to hand someone a *ready-to-run, tap-to-install* build, because signing with a free Apple ID is tied
to **their** Apple ID **and** device and expires after **7 days**. So each person signs it themselves;
the options, cheapest first:

- **Send them the Release link / SideStore source (free, recommended).** They add the source
  `https://github.com/tryk016/opengothic-ios/releases/download/latest/apps.json` in SideStore, or just
  download the `.ipa` and sideload with their **own** free Apple ID via SideStore/AltStore/Sideloadly —
  exactly like you do. The source gives them one-tap install **and** auto-updates when a new build ships.
- **Paid Apple Developer account ($99/yr)** — the only way to distribute a *signed* build others just
  tap to install: **TestFlight** (up to 10,000 testers, no per-device registration) or **ad-hoc**
  (a signed `.ipa` that runs on up to 100 UDIDs you register). This fork otherwise avoids App Review
  entirely by not using the store.

You **cannot** legally bundle Gothic II data into a shared build — recipients must own and supply their own.

### Controls

Two input modes; the on-screen overlay hides automatically when a controller is connected.

**Bluetooth controller (Gothic Classic scheme — Xbox / PS5 buttons):**

| Function | Xbox / PS5 | | Function | Xbox / PS5 |
|---|---|---|---|---|
| Interact / attack | A / ✕ | | Move | Left stick |
| Jump / climb | B / ○ | | Look | Right stick |
| Sneak / crouch | X / □ | | Block / parry | RT / R2 |
| Draw weapon | Y / △ | | Weapon quick-ring | RB / R1 (hold) |
| Walk/run toggle | L3 | | Item quick-ring | LT / L2 (hold) |
| Target lock-on | R3 | | Heal / Potion | D-pad ↑ / ↓ |
| Switch target (locked) | D-pad ← / → | | Inventory | View / Touchpad |
| Pause / menu | Menu / Options | | Quick save / load | LB + Menu / LB + View |
| Warp to nearest waypoint (unstuck) | hold L3 + R3 ~2 s | | | |

- **Quick-rings:** hold RB (weapons) or LT (items), aim with the right stick, release to equip/use.
- Config lives in `Documents/Gothic.ini` under `[GAMEPAD]` — `deadZone`, `lookSensitivity`, `invertY`,
  `triggerThreshold`, `saveSlots`, `noStuckProtect`.

**On-screen virtual gamepad (no controller):** a full pad is drawn during play — move pad + camera area,
A/B/X/Y, shoulders/triggers, sticks, D-pad, View/Menu — using the Xelu glyphs. Tap a quick-ring button,
drag to aim, release to activate. Menus and dialogues get on-screen D-pad + OK/Back/Skip.

### Language & voices

Language — and whether dialogue has voice-over — comes entirely from **your game data**, not the app.
The Steam release is usually English. For Polish (text + voices) you need Polish game data (e.g. the GOG
*Gold Edition*, which is multi-language, or a Polish install/localization). Once Polish data is in place
it is used automatically; you can also force it with `[GAME] language=2` in a `Gothic.ini` placed in the
app's Documents folder.

Dialogue voice-over lives in `Speech.vdf` / `Speech_Addon.vdf` — these are mounted on devices with ≥4 GB
RAM (skipped on iPhone 7/8 to avoid running out of memory, leaving subtitles only).

### Optional settings (`Documents/Gothic.ini`)

```ini
[GAME]
showFpsCounter=1        ; on-screen FPS counter

[GAMEPAD]
deadZone=0.25
lookSensitivity=0.20
invertY=0
saveSlots=5             ; rotating quick-save slots
; noStuckProtect=1      ; disable the L3+R3 unstuck warp
```

### Known limitations

- **Not fully tested on-device yet** — this is a work in progress (see the notice above and `ios/TODO.md`).
- Sideload certificate expires weekly (auto-refresh via AltStore/SideStore).
- No TestFlight / App Store without a paid account (both require App Review).
- Mesh shaders are disabled on iOS for GPU compatibility.
- On-screen virtual-pad button layout is a first pass and still needs on-device tuning.
- Radial rings are a single-ring first version; some smaller items in `ios/TODO.md` are not done yet.

### What this fork adds on top of upstream

- **Build/distribution:** cloud build of an unsigned `.ipa` (`.github/workflows/ios.yml`); `ios/` build
  script, sideload/data guide, and submodule patches (`ios/patches/apply-patches.sh`).
- **Controller:** GameController support (`game/utils/gamepad.*`), a context-aware dispatcher that also
  drives menus/dialogues (`game/ui/gamepadinput.*`), native target lock-on, radial weapon/item rings
  (`game/ui/quickring.*`), rotating quick-saves, haptics (`game/utils/haptics.*`), stuck-protection,
  and a `[GAMEPAD]` config section.
- **On-screen input:** a full virtual gamepad + menu/dialogue/inventory controls with controller glyphs
  (`game/ui/touchinput.*`, `game/ui/padglyph.*`, `assets/controller/`), a controls-help hint bar and a
  lock-on reticle.
- **iOS lifecycle/robustness:** graceful "data not found" message instead of a crash
  (`game/utils/systemmsg.*`), audio-session setup (`game/utils/audiosession.*`), landscape lock, keep
  the screen awake, Game Mode keys, a save-crash fix, and dialogue voice-over on ≥4 GB devices.

---

*For the engine itself — Windows/Linux/macOS builds, features, mods, command-line arguments, graphics
options, and the contribution guide — see the upstream project:*
**[Try/OpenGothic](https://github.com/Try/OpenGothic)**.
