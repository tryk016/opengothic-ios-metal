# iOS port — polish backlog

Tracked items beyond the core "build + run + control" milestone.

## UI / readability
- [x] Scale up UI on iOS so text is legible on high-DPI screens (`MainWindow::uiScale`).
- [ ] Dialogue subtitle window is small — enlarge / reflow for phone screens.
- [ ] Dialogue **choice** list is small — enlarge and make touch-friendly.
- [ ] Verify main-menu text size after the uiScale change; tune the factor if needed.

## Input
- [x] Gamepad (GameController) mapping — Gothic Classic scheme.
- [x] Touch overlay: movement pad, camera area, action buttons (in-game).
- [x] Touch menu navigation: on-screen Up / Down / OK / Back drive `MenuRoot`.
- [ ] Touch navigation for **inventory** and other non-`MenuRoot` screens.
- [ ] Nicer controller-style overlay skin (vector A/B/X/Y + d-pad + sticks).
      NOTE: prefer drawing our own (no asset licensing); avoid bundling found images.
- [ ] Gamepad quick save/load binding (currently logged only).
- [ ] Revisit gamepad lock-on (provisional `LookBack`).
- [ ] Tune overlay dead-zones / camera sensitivity on-device.

## Audio
- [ ] Dialogue has no voice-over (SFX + music work). Suspect missing/using
      output-units (`_work/Data/Scripts/content/CUTSCENE/OU.BIN`/`OU.CSL`) or
      speech-volume lookup. Needs a log captured *during* a dialogue.

## Language
- [ ] Polish requires Polish game data (e.g. GOG Gold Edition or a PL install);
      then it's automatic, or force via `[GAME] language=2` in Documents/Gothic.ini.
