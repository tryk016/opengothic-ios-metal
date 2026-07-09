## OpenGothic for iOS

An **unofficial iOS port** of [OpenGothic](https://github.com/Try/OpenGothic) — the open-source
re-implementation of *Gothic II: Night of the Raven*. This fork adds the plumbing to build, sideload,
and play OpenGothic on iPhone/iPad with a Bluetooth controller (or an on-screen touch overlay).

> ### Credit
> **The entire engine is the work of [Try](https://github.com/Try) and the OpenGothic contributors.**
> OpenGothic and its rendering engine [Tempest](https://github.com/Try/Tempest) are what make this
> possible — this fork only finishes and wires up the iOS path that already lived in the codebase.
> Please support the upstream project: ⭐ [Try/OpenGothic](https://github.com/Try/OpenGothic) ·
> 💬 [Discord](https://discord.gg/G9XvcFQnn6). This fork is not affiliated with or endorsed by the
> original authors and is distributed under the same [license](LICENSE).

![Screenshot](scr0.png)

---

### Prerequisites

*Gothic II: Night of the Raven* is required — OpenGothic ships **no** game assets or scripts. You must
legally own the game and supply its data yourself (see *Language & voices* below for edition notes).

Target: iPhone/iPad on **iOS 15+**, arm64. Best on modern GPUs (A-series / M-series).

### Build & install — no Mac required

Full walkthrough: **[ios/README-ios.md](ios/README-ios.md)**. In short:

1. **Build** — push this repo to your own GitHub. The [`iOS build`](.github/workflows/ios.yml) Action
   compiles an **unsigned `.ipa`** on a macOS runner and uploads it as an artifact. (A public fork gets
   free macOS runner minutes.)
2. **Install (from Windows)** — sign & install the `.ipa` with your **free Apple ID** using
   **Sideloadly** or **AltStore/SideStore**. No paid Apple Developer account, no App Store, no Mac.
   The free certificate expires every 7 days (AltStore/SideStore can auto-refresh it).
3. **Add game data** — copy the `Data/`, `_work/`, and `system/` folders from your Gothic II install into
   the app's **Documents** folder (iTunes/Apple Devices File Sharing on Windows, or the Files app). Data
   persists across launches and app updates.

With a Mac, use [`ios/build-ios.sh`](ios/build-ios.sh) + Xcode instead (also covered in the guide).

### Controls (gamepad — Gothic Classic scheme)

| Function | Xbox / PS5 | | Function | Xbox / PS5 |
|---|---|---|---|---|
| Interact / attack | A / ✕ | | Move | Left stick |
| Draw weapon / secondary | Y / △ | | Look | Right stick |
| Jump / climb | B / ○ | | Sprint | L3 |
| Crouch / sneak | X / □ | | Lock-on | R3 |
| Block / parry | RT / R2 | | Quick items | D-pad |
| Inventory | View / Touchpad | | Pause | Menu / Options |

A basic **on-screen touch overlay** is available when no controller is connected.

### Language & voices

Language — and whether dialogue has voice-over — comes entirely from **your game data**, not the app.
The Steam release is usually English. For Polish (text + voices) you need Polish game data (e.g. the GOG
*Gold Edition*, which is multi-language, or a Polish install/localization). Once Polish data is in place
it is used automatically; you can also force it with `[GAME] language=2` in a `Gothic.ini` placed in the
app's Documents folder.

### Known limitations

- Sideload certificate expires weekly (auto-refresh via AltStore/SideStore).
- No TestFlight / App Store (both require a paid account + App Review).
- Mesh shaders are disabled on iOS for GPU compatibility.
- Gamepad quick save/load and lock-on are provisional — see [ios/README-ios.md](ios/README-ios.md).

### iOS-specific changes in this fork

- `.github/workflows/ios.yml` — cloud build of an unsigned `.ipa`.
- `ios/` — build script, sideload/data guide, and submodule patches (`apply-patches.sh`).
- `game/utils/gamepad.*`, `game/ui/gamepadinput.*` — GameController support.
- `game/ui/touchinput.*` — on-screen overlay.
- `game/utils/systemmsg.*` — friendly "data not found" message instead of a crash.
- Small fixes in `game/main.cpp`, `game/commandline.*`, `game/mainwindow.*`, `CMakeLists.txt`.

---

*For the engine itself — Windows/Linux/macOS builds, features, mods, command-line arguments, graphics
options, and the contribution guide — see the upstream project:*
**[Try/OpenGothic](https://github.com/Try/OpenGothic)**.
