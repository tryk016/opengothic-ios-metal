# RendererIOS stable candidate

Status: implementation has passed host validation; the final device campaign
is pending. Product commit `a4425f26` with Tempest `e2da30c2` passed all nine local
profiles, all 11 required CI jobs, Simulator world loading and Home/resume.
No stable release has been published. These results do not establish iPhone/iPad
performance, thermal behavior or final visual acceptance.

## Build

Use the pinned submodules and a current Xcode SDK. The deployment target is
still iOS 16.4. Metal 4 additionally needs an SDK exposing its API; Simulator
builds use Metal 3 because the Simulator SDK omits that API. The build script
enables three frame slots. Native Temporal/Spatial support is runtime-selected
and does not require the legacy `OPENGOTHIC_METALFX_*` flags.

```sh
git submodule update --init --recursive
./ios/build-ios.sh \
  -DOPENGOTHIC_RENDERER_IOS_METAL4=ON \
  -DOPENGOTHIC_RENDERER_IOS_RAYTRACING=ON
cmake --build build-ios --config Release --parallel 4 -- CODE_SIGNING_ALLOWED=NO
```

This creates an unsigned app. Signing and installation belong to the final
device campaign and must preserve the existing application identifier and
Documents container. Record the exact source commit, Tempest gitlink, executable
and metallib hashes, build flags, OS, device and effective settings with results.
Performance and visual runs use the unrestricted app with fault injection,
Simulator scene limits and GPU validation disabled. Diagnostic captures use
separate runs and retain their own flags and timing limitations.

## Image-quality baseline

Inspect both `Documents/system/Gothic.ini` and the writable
`Documents/Gothic.ini` overlay. The overlay wins; an old reduced-resolution
setting can survive an update. Use this explicit baseline for visual comparison:

```ini
[INTERNAL]
vidResIndex=0

[PERFORMANCE]
sightValue=14

[ENGINE]
zUpscaler=4
zMaxFpsMode=0
zMaxFPS=0
zAdaptiveFps=0
zMetal4=0
zRayTracing=0
```

This is Native 100%, maximum 300% drawing distance and no fixed FPS cap. On
iOS, mode 0 uses display pacing with a requested ProMotion range of 30–120 Hz;
it is not unrestricted rendering, and `zMaxFPS` does not control this cadence. Native
ignores a reduced scene-scale selection. Keep these settings fixed when comparing
Metal 3 with Metal 4 or raster with ray tracing, changing only the feature under
test. Verify the effective route: a requested feature may fall back.

The native sampler uses 16× anisotropy and fixed 2048/1024 shadow maps.
Legacy `shadowResolution`, `zCloudShadowScale`, `zTexAnisotropicFiltering` and
`texDetailIndex` do not control those native paths. Do not infer their quality
from those INI keys. Simulator smoke limits scene submissions and cannot supply
final image-quality evidence even with this INI.

Temporal receives current/previous geometry, skin, morph and instance motion,
scene depth, camera jitter and reactive masks; no optical-flow estimator is used.
Check disocclusion, cutouts, water, particles, camera cuts and world reloads on
the device. Measure the motion pass and total Temporal cost separately. Missing
or invalid history must recover cleanly; selecting Temporal is not proof of
acceptable ghosting or a performance benefit.

## Reproducible quality scenarios

These are named test configurations using existing video-menu controls, not
hardware recommendations or automatic quality changes. Keep native shadow maps and image controls fixed, Adaptive FPS off and the
30 FPS cap on for pacing comparisons. Use mode 0 separately for timing;
Adaptive FPS on is a separate thermal/soak case.

| Scenario | Upscaling | Scene scale | Drawing distance |
|---|---|---|---|
| Low | Auto | 50% | 60% |
| Balanced | Auto | 75% | 100% |
| High / visual baseline | Native | 100% | 300% |

Exercise explicit Temporal, Spatial and FSR 1 selections as well as Auto;
record each actual mode and fallback. Run optional RT with `zRayTracing=1` and
Metal 4 with `zMetal4=1` independently and together. Unsupported, warming or
thermally limited RT uses SSAO. The effect traces static opaque occluders only;
dynamic casters and general reflections are outside this limited RT scope.

## Final device acceptance

All rows below remain pending until evidence from the final candidate exists.
One continuous run may provide several kinds of evidence, with a separate
verdict for each requirement.

| Area | Required evidence |
|---|---|
| Recovery and installation | Finish retained recovery under its original identity if needed; fresh candidate identity, valid signing, same container, preserved game data and saves. |
| Content and hardware | Gothic 1 and Gothic 2, low-memory and mid-tier hardware, A17 Pro or newer, and iPad/aspect coverage. Record unavailable combinations rather than claiming coverage. |
| Scene and materials | All retained material/capture scenarios: opaque, cutout, skin/morph/instances, Multiply/Multiply2/Additive, transparent, water, ghost, particles, sky/fog/weather, lights and shadows; exact draw/resource evidence where required. |
| Application | New game, dialogue, combat, inventory/QuickRings, touch/controller, Bink video, save overwrite/load/preview, world changes, pause, Home/resume and interruption recovery. |
| GPU and fallback | Native/Auto/Temporal/Spatial/FSR 1, motion/reactive/history resets, Metal 3/4 comparison, RT0 geometry and RT1 AO, unsupported/error/thermal fallback, clean terminal ownership and rollback. |
| Performance | Heavy/light scene timing, CPU/GPU percentiles and pacing; sustained 30 FPS, optional 60 FPS; sustained improvement in at least two heavy scenes and no >3% regression in a light scene after at least 20 minutes against the agreed baseline. |
| Thermal | At least 30 minutes under recorded ambient, case and charging conditions; sustained budget and time to throttling, Adaptive FPS transitions/recovery and immediate serious-heat RT fallback. |
| Memory and lifecycle | One-hour soak, 50 lifecycle cycles, 20 world changes, save/menu repeated reads, memory warnings and bounded completion failures; no growing unreleased owners or corrupt saves. |
| Visual and release | User gameplay/image acceptance, zero unresolved S0/S1 issues, S2 issues fixed or explicitly disabled; measured Metal 4 and one RT1 adoption, reviewed release notes and rollout/rollback. |

Terminate the app after every unattended scenario, on success and failure.
Ordinary smoke accepts up to 3660 seconds; allow about 4500 seconds in the
device guard for installation, validation and cleanup. A long smoke alone
does not prove an uninterrupted soak: retain the original live PID, ordered
engine performance windows and raw trace segments. Report window percentiles
as windows, not as whole-run percentiles. The older Additive trace adapter's
FPS/slot arguments are metadata; verify the actual settings separately.
Preserve failing logs and label superseding results explicitly. Mobile Metal 4
or RT rejection requires an explicit scope decision before declaring the full
roadmap complete. Publishing remains a separate approval after the candidate
and its results are reviewable.
