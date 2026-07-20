#!/usr/bin/env bash
#
# Sign, install and exercise a diagnostics-enabled RendererIOS build on one
# connected physical iOS device. The existing suffixed bundle identifier is
# preserved, so game assets and saves stay in the same data container.
#
# Usage:
#   ios/device-test/run-smoke-test.sh path/to/Gothic2Notr.app
#   OPENGOTHIC_IOS_DEVICE=<CoreDevice UUID> ... --duration 60 --save-slot 20 APP
#   ... --require-bink-self-test APP
#
# The phone must be unlocked when the app is launched. No screen interaction is
# needed: OpenGothic's own -nomenu/-save arguments load the selected save.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
STUB="$ROOT/ios/device-test/provisioning-stub/Probe.xcodeproj"
BASE_BUNDLE_ID="opengothic.gothic2"
DURATION=45
SAVE_SLOT=20
REQUIRE_BINK_SELF_TEST=0
APP_INPUT=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="${2:?missing duration}"; shift 2 ;;
    --save-slot) SAVE_SLOT="${2:?missing save slot}"; shift 2 ;;
    --require-bink-self-test) REQUIRE_BINK_SELF_TEST=1; shift ;;
    -*) fail "usage: $0 [--duration seconds] [--save-slot number] [--require-bink-self-test] path/to/Gothic2Notr.app" ;;
    *) [[ -z "$APP_INPUT" ]] || fail "only one app path may be supplied"; APP_INPUT="$1"; shift ;;
  esac
done

[[ "$DURATION" =~ ^[0-9]+$ ]] && ((DURATION >= 10 && DURATION <= 600)) ||
  fail "duration must be 10..600 seconds"
[[ "$SAVE_SLOT" =~ ^[0-9]+$ ]] || fail "save slot must be a non-negative integer"
[[ -n "$APP_INPUT" && -d "$APP_INPUT" ]] || fail "pass an existing .app directory"
[[ -f "$APP_INPUT/RendererIOS.metallib" ]] || fail "app has no RendererIOS.metallib"

WORK="$(mktemp -d -t opengothic-device-smoke)"
DEVICE=""
APP_EXECUTABLE=""
BUNDLE_ID=""
EXPECTED_SHA=""
RUNTIME_ARMED=0
PRE_CRASH_SHA=""
POST_CRASH_SHA=""

stop_running_app() {
  local strict="${1:-0}"
  local attempt json mode pid pids

  [[ -n "$DEVICE" && -n "$APP_EXECUTABLE" ]] || return 0
  for attempt in 1 2 3 4 5; do
    json="$WORK/processes-stop-$(uuidgen).json"
    if ! xcrun devicectl device info processes --device "$DEVICE" \
        --json-output "$json" >/dev/null 2>>"$WORK/cleanup.log"; then
      [[ "$strict" == 0 ]] ||
        echo "FAIL: could not query processes while stopping $APP_EXECUTABLE" >&2
      return 1
    fi
    if ! pids="$(python3 - "$json" "$APP_EXECUTABLE" <<'PY'
import json, pathlib, sys
processes = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
expected = sys.argv[2]
for process in processes:
    if pathlib.PurePosixPath(process.get("executable", "")).name == expected:
        pid = process.get("processIdentifier")
        if not isinstance(pid, int):
            raise SystemExit("non-numeric process identifier")
        print(pid)
PY
    )"; then
      [[ "$strict" == 0 ]] ||
        echo "FAIL: invalid process list while stopping $APP_EXECUTABLE" >&2
      return 1
    fi
    [[ -n "$pids" ]] || return 0
    ((attempt < 5)) || break

    mode="terminate"
    ((attempt < 4)) || mode="kill"
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      echo "attempt=$attempt mode=$mode executable=$APP_EXECUTABLE pid=$pid" \
        >>"$WORK/cleanup.log"
      if [[ "$mode" == "kill" ]]; then
        xcrun devicectl device process terminate --device "$DEVICE" --pid "$pid" \
          --kill --quiet >/dev/null 2>>"$WORK/cleanup.log" || true
      else
        xcrun devicectl device process terminate --device "$DEVICE" --pid "$pid" \
          --quiet >/dev/null 2>>"$WORK/cleanup.log" || true
      fi
    done <<<"$pids"
    sleep 1
  done

  [[ "$strict" == 0 ]] ||
    echo "FAIL: $APP_EXECUTABLE is still running on the device" >&2
  return 1
}

pull_runtime_logs() {
  local suffix="$1"
  local name stem extension

  [[ -n "$DEVICE" && -n "$BUNDLE_ID" ]] || return 0
  for name in log.txt stderr.log crash.log; do
    stem="${name%.*}"
    extension="${name##*.}"
    xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
      --source "Documents/$name" \
      --destination "$WORK/$stem-$suffix.$extension" >/dev/null 2>&1 || true
  done
}

preserve_failure_evidence() {
  local original_status="$1"
  local cleanup_status="$2"
  local candidate failure_dir timestamp

  [[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || return 0
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  failure_dir="$ROOT/build/device-smoke/$EXPECTED_SHA/failure-$timestamp-$$"
  mkdir -p "$failure_dir"
  for candidate in \
      launch.log cleanup.log \
      log.txt stderr.log crash.log crash-before.log \
      log-before-cleanup.txt stderr-before-cleanup.log crash-before-cleanup.log \
      log-after-cleanup.txt stderr-after-cleanup.log crash-after-cleanup.log; do
    [[ -f "$WORK/$candidate" ]] || continue
    ditto "$WORK/$candidate" "$failure_dir/$candidate"
  done
  {
    echo "result=FAIL"
    echo "source_sha=$EXPECTED_SHA"
    echo "original_exit_status=$original_status"
    echo "cleanup_status=$cleanup_status"
    echo "pre_crash_sha256=$PRE_CRASH_SHA"
    echo "post_crash_sha256=$POST_CRASH_SHA"
  } >"$failure_dir/result.txt"
  echo "failure evidence: $failure_dir" >&2
}

cleanup() {
  local status=$?
  local cleanup_status=0 final_status="$status"
  trap - EXIT INT TERM HUP
  set +e
  if ((RUNTIME_ARMED != 0)); then
    pull_runtime_logs before-cleanup
    stop_running_app 0 || cleanup_status=1
    pull_runtime_logs after-cleanup
  fi
  if ((status != 0 || cleanup_status != 0)); then
    preserve_failure_evidence "$status" "$cleanup_status"
  fi
  if ((status == 0 && cleanup_status != 0)); then
    final_status=1
  fi
  if ((cleanup_status != 0)); then
    echo "WARNING: could not confirm device app cleanup" >&2
  fi
  [[ "$WORK" == /var/folders/*/T/opengothic-device-smoke.* ]] && rm -rf "$WORK"
  exit "$final_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

REQUESTED_DEVICE="${OPENGOTHIC_IOS_DEVICE:-}"
xcrun devicectl list devices --json-output "$WORK/devices.json" >/dev/null
DEVICE_RECORD="$(python3 - "$WORK/devices.json" "$REQUESTED_DEVICE" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
requested = sys.argv[2]
matches = [
    d for d in devices
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("hardwareProperties", {}).get("reality") == "physical"
    # An explicitly selected paired device may establish its CoreDevice/DDI
    # tunnel on the first device command after a transient disconnect. In
    # auto-selection mode, still require an already connected tunnel.
    and (requested or
         d.get("connectionProperties", {}).get("tunnelState") == "connected")
    and (not requested or requested in (
        d.get("identifier"), d.get("hardwareProperties", {}).get("udid")))
]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one connected physical iOS device, found {len(matches)}")
device = matches[0]
print(device["identifier"] + "\t" + device["hardwareProperties"]["udid"])
PY
)" || fail "could not select a unique connected physical iOS device"
IFS=$'\t' read -r DEVICE DEVICE_UDID <<<"$DEVICE_RECORD"

BUNDLE_ID="${OPENGOTHIC_IOS_BUNDLE_ID:-}"
xcrun devicectl device info apps --device "$DEVICE" \
  --json-output "$WORK/apps.json" >/dev/null
BUNDLE_ID="$(python3 - "$WORK/apps.json" "$BASE_BUNDLE_ID" "$BUNDLE_ID" <<'PY'
import json, sys
apps = json.load(open(sys.argv[1]))["result"]["apps"]
base = sys.argv[2] + "."
requested = sys.argv[3]
matches = [a["bundleIdentifier"] for a in apps if a["bundleIdentifier"].startswith(base)]
if requested:
    matches = [bundle for bundle in matches if bundle == requested]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one installed {base}* app, found {len(matches)}")
print(matches[0])
PY
)" || fail "bundle id must identify the existing installed OpenGothic container"

TEAM_ID="${OPENGOTHIC_IOS_TEAM_ID:-${BUNDLE_ID##*.}}"
[[ "$BUNDLE_ID" == "$BASE_BUNDLE_ID.$TEAM_ID" ]] ||
  fail "bundle id must preserve the existing team-id suffix"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "could not derive a valid team id"

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null |
  awk '/Apple Development/ {print $2}')"
[[ -n "$IDENTITIES" ]] || fail "no Apple Development identity with a private key"

find_profile() {
  local profile app_id identity expiry epoch now
  now="$(date +%s)"
  shopt -s nullglob
  for profile in "$PROFILE_DIR"/*.mobileprovision; do
    security cms -D -i "$profile" >"$WORK/profile.plist" 2>/dev/null || continue
    app_id="$(plutil -extract Entitlements.application-identifier raw \
      -o - "$WORK/profile.plist" 2>/dev/null || true)"
    [[ "$app_id" == "$TEAM_ID.$BUNDLE_ID" ]] || continue
    identity="$(python3 - "$WORK/profile.plist" "$IDENTITIES" "$DEVICE_UDID" <<'PY'
import hashlib, plistlib, sys
with open(sys.argv[1], "rb") as source:
    profile = plistlib.load(source)
identities = [identity.upper() for identity in sys.argv[2].splitlines()]
device = sys.argv[3]
certificates = {
    hashlib.sha1(certificate).hexdigest().upper()
    for certificate in profile.get("DeveloperCertificates", [])
}
matches = [identity for identity in identities if identity in certificates]
if not matches or device not in profile.get("ProvisionedDevices", []):
    raise SystemExit(1)
print(matches[0])
PY
    )" || continue
    expiry="$(plutil -extract ExpirationDate raw -o - "$WORK/profile.plist" 2>/dev/null || true)"
    epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" +%s 2>/dev/null || echo 0)"
    if ((epoch > now)); then
      printf '%s\t%s\n' "$profile" "$identity"
      return 0
    fi
  done
  return 1
}

PROFILE_RECORD="$(find_profile || true)"
if [[ -z "$PROFILE_RECORD" ]]; then
  echo "== provisioning existing App ID =="
  if ! xcodebuild -project "$STUB" -scheme Probe \
      -destination 'generic/platform=iOS' -allowProvisioningUpdates \
      PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
      build >"$WORK/provisioning.log" 2>&1; then
    rg 'error:|maximum App ID|limit reached' "$WORK/provisioning.log" | head -20 || true
    fail "Xcode could not obtain a provisioning profile"
  fi
  PROFILE_RECORD="$(find_profile || true)"
fi
[[ -n "$PROFILE_RECORD" ]] || fail "no valid profile and signing identity for $BUNDLE_ID"
IFS=$'\t' read -r PROFILE IDENTITY <<<"$PROFILE_RECORD"

APP="$WORK/Gothic2Notr.app"
ditto "$APP_INPUT" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
  "$APP/Info.plist")"
cp "$PROFILE" "$APP/embedded.mobileprovision"
security cms -D -i "$PROFILE" >"$WORK/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' \
  "$WORK/profile.plist" >"$WORK/entitlements.plist"
codesign -f -s "$IDENTITY" --entitlements "$WORK/entitlements.plist" \
  --generate-entitlement-der "$APP"
codesign -vv --deep --strict "$APP"

EXPECTED_SHA="${OPENGOTHIC_IOS_EXPECTED_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  fail "expected source SHA must be exactly 40 lowercase hexadecimal characters"
METALLIB_SHA="$(shasum -a 256 "$APP/RendererIOS.metallib" | awk '{print $1}')"
if xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source Documents/crash.log --destination "$WORK/crash-before.log" >/dev/null 2>&1; then
  PRE_CRASH_SHA="$(shasum -a 256 "$WORK/crash-before.log" | awk '{print $1}')"
fi

echo "== stopping any previous $BUNDLE_ID process =="
stop_running_app 1 || fail "pre-launch application cleanup failed"

echo "== installing $BUNDLE_ID =="
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null

echo "== unattended launch: save slot $SAVE_SLOT, ${DURATION}s =="
RUNTIME_ARMED=1
if ! xcrun devicectl device process launch --device "$DEVICE" \
    --terminate-existing -- "$BUNDLE_ID" -nomenu -save "$SAVE_SLOT" \
    >"$WORK/launch.log" 2>&1; then
  if rg -q 'Locked|could not be unlocked' "$WORK/launch.log"; then
    fail "device is locked; unlock it once and rerun (no in-app interaction is needed)"
  fi
  tail -30 "$WORK/launch.log" >&2
  fail "application launch failed"
fi
sleep "$DURATION"

xcrun devicectl device info processes --device "$DEVICE" \
  --json-output "$WORK/processes.json" >/dev/null
python3 - "$WORK/processes.json" "$APP_EXECUTABLE" <<'PY' ||
import json, pathlib, sys
processes = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
expected = sys.argv[2]
if not any(pathlib.PurePosixPath(p.get("executable", "")).name == expected
           for p in processes):
    raise SystemExit(1)
PY
  fail "application process did not survive the smoke window"

echo "== stopping $BUNDLE_ID after smoke window =="
stop_running_app 1 || fail "application cleanup failed"
RUNTIME_ARMED=0

for name in log.txt stderr.log crash.log; do
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "Documents/$name" --destination "$WORK/$name" >/dev/null 2>&1 || true
done

[[ -s "$WORK/log.txt" ]] || fail "device produced no log.txt"
rg -F "build=$EXPECTED_SHA" "$WORK/log.txt" >/dev/null ||
  fail "runtime log does not identify exact source SHA $EXPECTED_SHA"
rg -F 'RendererIOS diagnostics: ON' "$WORK/log.txt" >/dev/null ||
  fail "installed app is not a diagnostics-enabled RendererIOS build"
rg -F 'RendererIOS shader library: source=offline-metallib resource=RendererIOS.metallib abi=2' \
  "$WORK/log.txt" >/dev/null || fail "offline metallib marker is missing"
rg -F 'RendererIOS native Bink pipeline: source=offline-metallib resource=RendererIOS.metallib abi=2 color=rgba8 sample-count=1 pipeline-created=1' \
  "$WORK/log.txt" >/dev/null || fail "offline native Bink pipeline marker is missing"
if ((REQUIRE_BINK_SELF_TEST != 0)); then
  BINK_ARMED_COUNT="$(grep -Fc \
    'RendererIOS Bink self-test: ARMED case=yuv420p-4x4-padded-v1' \
    "$WORK/log.txt" || true)"
  BINK_PASS_COUNT="$(grep -Fc \
    'RendererIOS Bink self-test: PASS case=yuv420p-4x4-padded-v1' \
    "$WORK/log.txt" || true)"
  BINK_FAIL_COUNT="$(grep -Fc \
    'RendererIOS Bink self-test: FAIL case=yuv420p-4x4-padded-v1' \
    "$WORK/log.txt" || true)"
  [[ "$BINK_ARMED_COUNT" -eq 1 ]] ||
    fail "expected exactly one Bink self-test ARMED marker"
  [[ "$BINK_PASS_COUNT" -eq 1 ]] ||
    fail "expected exactly one Bink self-test PASS marker"
  [[ "$BINK_FAIL_COUNT" -eq 0 ]] ||
    fail "Bink self-test reported FAIL"
  rg -F 'fence-terminal=1 bytes=64 rgba-fnv1a64=eb48c2c0c3cea445' \
    "$WORK/log.txt" >/dev/null ||
    fail "Bink self-test readback evidence is incomplete"
  rg -F 'encoded-frames-delta=1' "$WORK/log.txt" >/dev/null ||
    fail "Bink self-test did not encode exactly one frame"
fi
rg -F 'RendererIOS legacy shader policy: profile=bridge-only eager-bridge-pipelines=inventory offline-native-pipelines=bink legacy-batch=disabled material-pipelines=source-metadata-only pfx-pipelines=disabled' \
  "$WORK/log.txt" >/dev/null || fail "RendererIOS bridge-only shader policy marker is missing"
if rg -F 'Shader compilation took:' "$WORK/log.txt" >/dev/null; then
  fail "legacy eager shader batch ran in RendererIOS"
fi
python3 - "$WORK/log.txt" "$WORK/runtime-compilation-summary.txt" <<'PY' ||
import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
summary = pathlib.Path(sys.argv[2])
bridge_re = re.compile(
    r"RendererIOS runtime compilation: point=legacy-bridge available=(\d+) "
    r"source-before=(\d+) source-after=(\d+) source-delta=(\d+) "
    r"compute-before=(\d+) compute-after=(\d+) compute-delta=(\d+) "
    r"render-before=(\d+) render-after=(\d+) render-delta=(\d+)"
)
frame_re = re.compile(
    r"RendererIOS runtime compilation: point=frame presents=(\d+) available=(\d+) "
    r"source=(\d+) compute=(\d+) render=(\d+)"
)
source_roles = (
    "color-vertex",
    "color-fragment",
    "texture-vertex",
    "texture-fragment",
)
render_roles = (
    "color-lines-opaque",
    "color-triangles-opaque",
    "color-lines-alpha",
    "color-triangles-alpha",
    "color-lines-additive",
    "color-triangles-additive",
    "texture-lines-opaque",
    "texture-triangles-opaque",
    "texture-lines-alpha",
    "texture-triangles-alpha",
    "texture-lines-additive",
    "texture-triangles-additive",
)
builtin_bridge_re = re.compile(
    r"RendererIOS builtin runtime attribution: point=legacy-bridge role-abi=1 "
    + r"available=(\d+) "
    + r"source-before=([0-9]+(?:,[0-9]+){3}) "
    + r"source-after=([0-9]+(?:,[0-9]+){3}) "
    + r"render-before=([0-9]+(?:,[0-9]+){11}) "
    + r"render-after=([0-9]+(?:,[0-9]+){11})"
)
builtin_frame_re = re.compile(
    r"RendererIOS builtin runtime attribution: point=frame presents=(\d+) "
    + r"role-abi=1 available=(\d+) "
    + r"source=([0-9]+(?:,[0-9]+){3}) "
    + r"render=([0-9]+(?:,[0-9]+){11})"
)

bridges = [tuple(map(int, match.groups())) for match in bridge_re.finditer(log)]
if len(bridges) != 1:
    raise SystemExit(f"expected one runtime compilation bridge marker, found {len(bridges)}")

(available, source_before, source_after, source_delta,
 compute_before, compute_after, compute_delta,
 render_before, render_after, render_delta) = bridges[0]
if available != 1:
    raise SystemExit("Metal runtime compilation counters are unavailable")
if source_after < source_before or source_delta != source_after-source_before:
    raise SystemExit("source-library bridge counters are inconsistent")
if compute_after < compute_before or compute_delta != compute_after-compute_before:
    raise SystemExit("compute-PSO bridge counters are inconsistent")
if render_after < render_before or render_delta != render_after-render_before:
    raise SystemExit("render-PSO bridge counters are inconsistent")
if (source_before, source_after, source_delta,
    compute_before, compute_after, compute_delta,
    render_before, render_after, render_delta) != (
        4, 6, 2,
        0, 0, 0,
        0, 0, 0,
    ):
    raise SystemExit(
        "offline-Bink bridge construction must preserve four Builtin requests, "
        "request exactly two inventory source libraries and no Tempest native PSO"
    )

frames = [tuple(map(int, match.groups())) for match in frame_re.finditer(log)]
if len(frames) < 2 or frames[0][0] != 1 or frames[-1][0] < 300:
    raise SystemExit("runtime compilation frame markers do not cover presents 1 through 300")
previous = (0, source_after, compute_after, render_after)
first_frame_totals = None
expected_present = 1
for present, frame_available, source, compute, render in frames:
    if frame_available != 1:
        raise SystemExit("Metal runtime compilation counters disappeared during frames")
    if present <= previous[0]:
        raise SystemExit("runtime compilation frame markers are not strictly ordered")
    if present != expected_present:
        raise SystemExit(
            "runtime compilation frame markers are not contiguous: "
            f"expected {expected_present}, found {present}"
        )
    if (source < previous[1] or
        compute < previous[2] or
        render < previous[3]):
        raise SystemExit("runtime compilation counters are not monotonic")
    if first_frame_totals is None:
        first_frame_totals = (source, compute, render)
    elif (source, compute, render) != first_frame_totals:
        raise SystemExit(
            "runtime compilation grew after the first presented frame: "
            f"first={first_frame_totals} present={present} "
            f"current={(source, compute, render)}"
        )
    previous = (present, source, compute, render)
    expected_present += 1

last_present, _, last_source, last_compute, last_render = frames[-1]
first_source, first_compute, first_render = first_frame_totals
if first_frame_totals != (6, 0, 2):
    raise SystemExit(
        "the first presented frame must have exact offline-Bink totals "
        f"(6, 0, 2), found {first_frame_totals}"
    )

def csv_counts(value):
    return tuple(map(int, value.split(",")))

builtin_bridges = [
    (
        int(match.group(1)),
        csv_counts(match.group(2)),
        csv_counts(match.group(3)),
        csv_counts(match.group(4)),
        csv_counts(match.group(5)),
    )
    for match in builtin_bridge_re.finditer(log)
]
if len(builtin_bridges) != 1:
    raise SystemExit(
        "expected one builtin runtime attribution bridge marker, "
        f"found {len(builtin_bridges)}"
    )
(builtin_available, builtin_source_before, builtin_source_after,
 builtin_render_before, builtin_render_after) = builtin_bridges[0]
if builtin_available != 1:
    raise SystemExit("Metal Builtin runtime attribution is unavailable")
if builtin_source_before != (1, 1, 1, 1):
    raise SystemExit(
        "Tempest Builtin construction must classify exactly one request for "
        f"each source role, found {builtin_source_before}"
    )
if builtin_source_after != builtin_source_before:
    raise SystemExit(
        "parent inventory source requests must not be classified as Tempest Builtin"
    )
if builtin_render_before != (0,) * len(render_roles):
    raise SystemExit(
        "Tempest Builtin native PSO was created before legacy bridge construction"
    )
if builtin_render_after != builtin_render_before:
    raise SystemExit(
        "legacy bridge construction must not create a Tempest Builtin native PSO"
    )

builtin_frames = [
    (
        int(match.group(1)),
        int(match.group(2)),
        csv_counts(match.group(3)),
        csv_counts(match.group(4)),
    )
    for match in builtin_frame_re.finditer(log)
]
if (len(builtin_frames) < 2 or builtin_frames[0][0] != 1 or
        builtin_frames[-1][0] < 300):
    raise SystemExit(
        "builtin runtime attribution markers do not cover presents 1 through 300"
    )
first_builtin_render = builtin_frames[0][3]
active_builtin_render_roles = tuple(
    role for role, count in zip(render_roles, first_builtin_render)
    if count != 0
)
if builtin_frames[0][2] != (1, 1, 1, 1):
    raise SystemExit(
        "first frame lost one or more exact Tempest Builtin source roles"
    )
if (sum(first_builtin_render) != first_render or
        len(active_builtin_render_roles) != 2 or
        any(count not in (0, 1) for count in first_builtin_render)):
    raise SystemExit(
        "the first frame must classify the exact two one-shot Builtin PSO "
        f"requests, roles={active_builtin_render_roles} "
        f"counts={first_builtin_render}"
    )
previous_builtin_present = 0
expected_builtin_present = 1
for (present, frame_available, source_counts,
     render_counts) in builtin_frames:
    if frame_available != 1:
        raise SystemExit("Metal Builtin runtime attribution disappeared")
    if present <= previous_builtin_present:
        raise SystemExit(
            "builtin runtime attribution markers are not strictly ordered"
        )
    if present != expected_builtin_present:
        raise SystemExit(
            "builtin runtime attribution markers are not contiguous: "
            f"expected {expected_builtin_present}, found {present}"
        )
    if source_counts != (1, 1, 1, 1):
        raise SystemExit(
            f"Tempest Builtin source role counts changed at present {present}"
        )
    if render_counts != first_builtin_render:
        raise SystemExit(
            "Tempest Builtin per-role PSO requests grew after the first frame: "
            f"first={first_builtin_render} present={present} "
            f"current={render_counts}"
        )
    previous_builtin_present = present
    expected_builtin_present = 300 if present == 1 else present + 300

summary.write_text(
    f"runtime_compilation_bridge_source_delta={source_delta}\n"
    f"runtime_compilation_bridge_compute_delta={compute_delta}\n"
    f"runtime_compilation_bridge_render_delta={render_delta}\n"
    f"runtime_compilation_last_present={last_present}\n"
    f"runtime_compilation_last_source={last_source}\n"
    f"runtime_compilation_last_compute={last_compute}\n"
    f"runtime_compilation_last_render={last_render}\n"
    f"runtime_compilation_frame_source_growth={last_source-first_source}\n"
    f"runtime_compilation_frame_compute_growth={last_compute-first_compute}\n"
    f"runtime_compilation_frame_render_growth={last_render-first_render}\n"
    f"builtin_source_roles={','.join(source_roles)}\n"
    f"builtin_render_active_roles={','.join(active_builtin_render_roles)}\n"
    f"builtin_render_role_counts={','.join(map(str, first_builtin_render))}\n"
)
PY
  fail "runtime compilation counter evidence is incomplete or inconsistent"
rg 'RendererIOS native Landscape: .*draws=[1-9][0-9]* textured=[1-9][0-9]*' \
  "$WORK/log.txt" >/dev/null || fail "no native textured Landscape frame was proven"
if rg -i 'RendererIOS (fatal|GPU shutdown failed|native Landscape encode failed|IOSGPUScene metallib loading failed)|libc\\+\\+abi: terminating|SIGABRT' \
    "$WORK/log.txt" "$WORK/stderr.log" >/dev/null 2>&1; then
  fail "fatal RendererIOS/runtime signature found in device logs"
fi

[[ -s "$WORK/crash.log" ]] &&
  POST_CRASH_SHA="$(shasum -a 256 "$WORK/crash.log" | awk '{print $1}')"
if [[ -n "$POST_CRASH_SHA" && "$POST_CRASH_SHA" != "$PRE_CRASH_SHA" ]]; then
  fail "crash.log changed during the smoke run"
fi

OUT="$ROOT/build/device-smoke/$EXPECTED_SHA"
mkdir -p "$OUT"
ditto "$WORK/log.txt" "$OUT/log.txt"
[[ ! -f "$WORK/stderr.log" ]] || ditto "$WORK/stderr.log" "$OUT/stderr.log"
{
  echo "result=PASS"
  echo "source_sha=$EXPECTED_SHA"
  echo "bundle_id=$BUNDLE_ID"
  echo "save_slot=$SAVE_SLOT"
  echo "duration_seconds=$DURATION"
  echo "bink_self_test_required=$REQUIRE_BINK_SELF_TEST"
  echo "bink_self_test_passed=$REQUIRE_BINK_SELF_TEST"
  echo "metallib_sha256=$METALLIB_SHA"
  echo "log_sha256=$(shasum -a 256 "$WORK/log.txt" | awk '{print $1}')"
  echo "device_process_stopped=1"
  cat "$WORK/runtime-compilation-summary.txt"
} >"$OUT/result.txt"

echo "PASS — offline metallib + counters + native Landscape/Bink gates proven; app stopped"
echo "evidence: $OUT"
