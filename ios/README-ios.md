# OpenGothic on iOS — build & install guide

Play OpenGothic (Gothic II: Night of the Raven) on iPhone/iPad with a Bluetooth
controller. Two routes are documented: **no Mac** (recommended for you) and
**with a Mac**.

> You must legally own Gothic II: NotR. The game ships **no** assets; you supply
> them from your own installation.

---

## Route A — No Mac (GitHub Actions + AltStore on Windows)

### 1. Build an unsigned .ipa in the cloud
- Fork/push this repo to **your GitHub account**. A **public** repo gets free
  macOS runner minutes (private repos burn quota 10×).
- The workflow `.github/workflows/ios.yml` runs on `macos-latest`, installs
  `cmake`+`glslang`, builds for `iphoneos` (arm64) with signing disabled, and
  uploads `OpenGothic-unsigned.ipa` as a build artifact.
- Trigger it (push, or Actions tab → "iOS build" → Run workflow), wait for it to
  finish, then download the `OpenGothic-ipa` artifact and unzip to get the `.ipa`.

### 2. Install from Windows with AltStore
- Install **AltServer for Windows** (needs iTunes + iCloud from Apple's site —
  **not** the Microsoft Store versions) and **AltStore** on the iPhone. Sign in
  with a **free Apple ID**. See https://altstore.io.
- In AltStore/AltServer choose **Install .ipa** and pick `OpenGothic-unsigned.ipa`.
  AltServer **re-signs it with your Apple ID** and installs over USB/Wi‑Fi.
- On the phone: Settings → General → VPN & Device Management → **trust** your
  developer certificate.
- The free cert **expires after 7 days**. Keep AltServer running on the PC with
  the phone on the same Wi‑Fi and AltStore **auto-refreshes** it. Free accounts
  allow **3 sideloaded apps** at a time.

### 3. Copy game data (from Windows)
The app enables File Sharing (`Info.plist`: `UIFileSharingEnabled`,
`LSSupportsOpeningDocumentsInPlace`). Copy the **contents** of your Gothic II
folder into the app's Documents:
- Source: `C:\Program Files (x86)\Steam\steamapps\common\Gothic II`
- Copy the `Data/`, `_work/`, and `system/` folders in.
- Options: **iTunes for Windows** → device → File Sharing → OpenGothic → Add;
  or the **Files** app on the device (e.g. from a USB drive / iCloud Drive).

The game auto-detects data in Documents (`commandline.cpp`) and validates
`Data`, `_work/Data`, and compiled scripts. If data is missing you get an
on-screen alert instead of a crash.

---

## Route B — With a Mac (Xcode, free Apple ID)

1. `brew install cmake glslang`; install Xcode + `xcode-select --install`.
2. `./ios/build-ios.sh` then `open build-ios/Gothic2Notr.xcodeproj`.
3. Xcode → Settings → Accounts → add your **free** Apple ID (a "Personal Team"
   appears). Target → Signing & Capabilities → **Automatically manage signing**,
   pick the personal team, set a unique bundle id if needed.
4. If signing fails on `com.apple.developer.kernel.increased-memory-limit`,
   remove that key from `Info.plist.in` (see below) and rebuild.
5. Run on the device; trust the certificate as in Route A. Copy game data via
   Finder → device → Files. Same 7-day expiry (rebuild weekly, or use AltStore).

---

## Controls (Gothic Classic scheme)

| Function | Xbox | PS5 |
|---|---|---|
| Primary interact / attack | A | ✕ |
| Secondary / draw weapon | Y | △ |
| Jump / climb / swim up | B | ○ |
| Crouch / dive / sneak | X | □ |
| Move | Left stick | Left stick |
| Look | Right stick | Right stick |
| Toggle sprint | L3 | L3 |
| Lock-on target | R3 | R3 |
| Block / parry | RT | R2 |
| Quick-access items | D-pad | D-pad |
| Inventory | View | Touchpad |
| Pause menu | Menu | Options |
| Quick save | LB + Menu | L1 + Options |
| Quick load | LB + View | L1 + Touchpad |

---

## Known limitations / follow-ups
- **Quick save/load** combos are detected but not yet bound to an engine action
  (`KeyCodec::Action` has no save/load entry) — currently logged. Needs a hook.
- **Lock-on** is mapped provisionally to `LookBack`; revisit against Gothic's
  targeting.
- **Mesh shaders** are defaulted **off** on iOS for GPU compatibility; modern
  Apple GPUs (A17 Pro / M-series) could re-enable them.
- **No TestFlight / App Store** — requires a paid Apple Developer account and
  App Review (which would reject an engine reimplementation + copyrighted data).
  Sideloading for personal use avoids review entirely.
- `increased-memory-limit` entitlement may be stripped under free signing; large
  worlds rely on the device's default per-app limit (fine on modern devices).

## Disabling the increased-memory-limit entitlement
If free signing rejects it, delete these two lines from `Info.plist.in`:
```xml
  <key>com.apple.developer.kernel.increased-memory-limit</key>
  <true/>
```
