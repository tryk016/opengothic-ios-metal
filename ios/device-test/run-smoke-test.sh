#!/usr/bin/env bash
#
# Sign, install and exercise a diagnostics-enabled RendererIOS build on one
# connected physical iOS device. The existing suffixed bundle identifier is
# preserved, so game assets and saves stay in the same data container.
#
# Usage:
#   ios/device-test/run-smoke-test.sh path/to/Gothic2Notr.app
#   OPENGOTHIC_IOS_DEVICE=<CoreDevice UUID> ... --duration 60 --save-slot 20 APP
#   ... --new-game APP
#   ... --require-bink-self-test APP
#   ... --pipeline-archive-test-mode cold APP
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
SAVE_SLOT_EXPLICIT=0
NEW_GAME=0
REQUIRE_BINK_SELF_TEST=0
PIPELINE_ARCHIVE_TEST_MODE=""
APP_INPUT=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="${2:?missing duration}"; shift 2 ;;
    --save-slot)
      SAVE_SLOT="${2:?missing save slot}"
      SAVE_SLOT_EXPLICIT=1
      shift 2
      ;;
    --new-game) NEW_GAME=1; shift ;;
    --require-bink-self-test) REQUIRE_BINK_SELF_TEST=1; shift ;;
    --pipeline-archive-test-mode)
      PIPELINE_ARCHIVE_TEST_MODE="${2:?missing pipeline archive test mode}"
      shift 2
      ;;
    -*) fail "usage: $0 [--duration seconds] [--save-slot number|--new-game] [--require-bink-self-test] [--pipeline-archive-test-mode cold|corrupt] path/to/Gothic2Notr.app" ;;
    *) [[ -z "$APP_INPUT" ]] || fail "only one app path may be supplied"; APP_INPUT="$1"; shift ;;
  esac
done

[[ "$DURATION" =~ ^[0-9]+$ ]] && ((DURATION >= 10 && DURATION <= 600)) ||
  fail "duration must be 10..600 seconds"
[[ "$SAVE_SLOT" =~ ^[0-9]+$ ]] || fail "save slot must be a non-negative integer"
((NEW_GAME == 0 || SAVE_SLOT_EXPLICIT == 0)) ||
  fail "--new-game and --save-slot are mutually exclusive"
[[ -z "$PIPELINE_ARCHIVE_TEST_MODE" ||
   "$PIPELINE_ARCHIVE_TEST_MODE" == cold ||
   "$PIPELINE_ARCHIVE_TEST_MODE" == corrupt ]] ||
  fail "pipeline archive test mode must be cold or corrupt"
[[ -n "$APP_INPUT" && -d "$APP_INPUT" ]] || fail "pass an existing .app directory"
[[ -f "$APP_INPUT/RendererIOS.metallib" ]] || fail "app has no RendererIOS.metallib"
SCENARIO=save
SCENARIO_SAVE_SLOT="$SAVE_SLOT"
if ((NEW_GAME != 0)); then
  SCENARIO=new-game
  SCENARIO_SAVE_SLOT=none
fi

WORK="$(mktemp -d -t opengothic-device-smoke)"
DEVICE=""
APP_EXECUTABLE=""
BUNDLE_ID=""
EXPECTED_SHA=""
RUNTIME_ARMED=0
PRE_CRASH_SHA=""
POST_CRASH_SHA=""
APP_EXECUTABLE="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP_INPUT/Info.plist" 2>/dev/null
)" || fail "app has no CFBundleExecutable"
[[ -n "$APP_EXECUTABLE" && "$APP_EXECUTABLE" != */* ]] ||
  fail "invalid CFBundleExecutable"
strings "$APP_INPUT/$APP_EXECUTABLE" |
  rg -Fx 'RendererIOS diagnostics: ON frames-in-flight=' >/dev/null ||
  fail "app is not a diagnostics-enabled RendererIOS build"

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
    echo "scenario=$SCENARIO"
    echo "save_slot=$SCENARIO_SAVE_SLOT"
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
  if [[ -n "$DEVICE" && -n "$APP_EXECUTABLE" ]]; then
    if ((RUNTIME_ARMED != 0)); then
      pull_runtime_logs before-cleanup
    fi
    if stop_running_app 0; then
      echo "phase=trap-cleanup game_processes=0" >>"$WORK/cleanup.log"
    else
      cleanup_status=1
    fi
    if ((RUNTIME_ARMED != 0)); then
      pull_runtime_logs after-cleanup
    fi
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
DEVICE_SELECTION_TEST_FAIL_FIRST="${OPENGOTHIC_IOS_DEVICE_SELECTION_TEST_FAIL_FIRST:-0}"
[[ "$DEVICE_SELECTION_TEST_FAIL_FIRST" =~ ^[01]$ ]] ||
  fail "OPENGOTHIC_IOS_DEVICE_SELECTION_TEST_FAIL_FIRST must be 0 or 1"
select_device_record() {
  local attempt json xcjson record selected_method

  for attempt in 1 2 3 4 5; do
    json="$WORK/devices-$attempt.json"
    xcjson="$WORK/xcdevices-$attempt.json"
    if ((DEVICE_SELECTION_TEST_FAIL_FIRST != 0 && attempt == 1)); then
      printf 'attempt=1 result=test-injected-enumeration-failure\n' \
        >>"$WORK/device-selection.log"
    elif xcrun devicectl list devices --json-output "$json" \
        >/dev/null 2>>"$WORK/device-selection.log"; then
      if [[ -n "$REQUESTED_DEVICE" ]]; then
        printf '[]\n' >"$xcjson"
      elif ! xcrun xcdevice list >"$xcjson" \
          2>>"$WORK/device-selection.log"; then
        printf 'attempt=%d result=xcdevice-enumeration-failure\n' "$attempt" \
          >>"$WORK/device-selection.log"
      fi
      if [[ -s "$xcjson" ]] &&
          record="$(python3 - "$json" "$REQUESTED_DEVICE" "$xcjson" \
          2>>"$WORK/device-selection.log" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
requested = sys.argv[2]
xcdevices = json.load(open(sys.argv[3]))
usb_udids = {
    d.get("identifier")
    for d in xcdevices
    if not d.get("simulator")
    and d.get("available")
    and d.get("interface") == "usb"
    and d.get("platform") == "com.apple.platform.iphoneos"
}
matches = [
    d for d in devices
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("hardwareProperties", {}).get("reality") == "physical"
    # An explicitly selected paired device may establish its CoreDevice/DDI
    # tunnel on the first device command after a transient disconnect. In
    # auto-selection mode, require a connected tunnel or an independent
    # xcdevice witness that this exact UDID is currently available over USB.
    and (requested or
         d.get("connectionProperties", {}).get("tunnelState") == "connected"
         or d.get("hardwareProperties", {}).get("udid") in usb_udids)
    and (not requested or requested in (
        d.get("identifier"), d.get("hardwareProperties", {}).get("udid")))
]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one connected physical iOS device, found {len(matches)}")
device = matches[0]
if requested:
    method = "explicit"
elif device.get("connectionProperties", {}).get("tunnelState") == "connected":
    method = "connected"
else:
    method = "usb-witness"
print(device["identifier"] + "\t" + device["hardwareProperties"]["udid"] +
      "\t" + method)
PY
      )"; then
        selected_method="${record##*$'\t'}"
        printf 'attempt=%d result=selected method=%s\n' \
          "$attempt" "$selected_method" \
          >>"$WORK/device-selection.log"
        printf '%s\n' "$record"
        return 0
      fi
    fi

    printf 'attempt=%d result=retry\n' "$attempt" \
      >>"$WORK/device-selection.log"
    ((attempt < 5)) && sleep 1
  done
  return 1
}

if ! DEVICE_RECORD="$(select_device_record)"; then
  tail -20 "$WORK/device-selection.log" >&2 || true
  fail "could not select a unique connected physical iOS device"
fi
DEVICE_SELECTION_ATTEMPTS_USED="$(
  grep -Ec 'result=(retry|selected)' "$WORK/device-selection.log"
)"
IFS=$'\t' read -r DEVICE DEVICE_UDID DEVICE_SELECTION_METHOD <<<"$DEVICE_RECORD"

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

echo "== stopping any previous $BUNDLE_ID process before preflight =="
stop_running_app 1 || fail "preflight application cleanup failed"

xcrun devicectl device info files --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --username mobile --subdirectory Documents --no-recurse \
  --json-output "$WORK/documents-preflight.json" >/dev/null ||
  fail "could not inspect the existing OpenGothic Documents container"
python3 - "$WORK/documents-preflight.json" <<'PY' ||
import json
import sys

files = json.load(open(sys.argv[1]))["result"]["files"]
required = {"Data", "_work", "system"}
entries = {entry.get("name"): entry for entry in files}
invalid = []
for name in sorted(required):
    entry = entries.get(name)
    resources = entry.get("resources", {}) if entry else {}
    if (
        entry is None
        or resources.get("isDirectory") is not True
        or resources.get("isSymbolicLink") is True
    ):
        invalid.append(name)
if invalid:
    raise SystemExit(
        "existing OpenGothic Documents container has missing/invalid directories: "
        + ", ".join(invalid)
    )
PY
  fail "existing game data preflight failed before install"
xcrun devicectl device info files --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --username mobile \
  --subdirectory "Documents/_work/Data/Scripts/_compiled" --no-recurse \
  --json-output "$WORK/scripts-preflight.json" >/dev/null ||
  fail "could not inspect compiled Gothic scripts before install"
xcrun devicectl device info files --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --username mobile --subdirectory "Documents/system" --no-recurse \
  --json-output "$WORK/system-preflight.json" >/dev/null ||
  fail "could not inspect the existing Gothic system directory"
python3 - "$WORK/scripts-preflight.json" "$WORK/system-preflight.json" <<'PY' ||
import json
import sys

def regular_file(entries, expected):
    matches = [
        entry for entry in entries
        if entry.get("name", "").lower() == expected
    ]
    if len(matches) != 1:
        return False
    resources = matches[0].get("resources", {})
    return (
        resources.get("isDirectory") is False
        and resources.get("isSymbolicLink") is False
    )

scripts = json.load(open(sys.argv[1]))["result"]["files"]
system = json.load(open(sys.argv[2]))["result"]["files"]
invalid = []
if not regular_file(scripts, "gothic.dat"):
    invalid.append("_work/Data/Scripts/_compiled/Gothic.dat")
if not regular_file(system, "gothic.ini"):
    invalid.append("system/Gothic.ini")
if invalid:
    raise SystemExit(
        "existing OpenGothic Documents container has missing/invalid files: "
        + ", ".join(invalid)
    )
PY
  fail "compiled scripts/system preflight failed before install"

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

LAUNCH_ARGS=(-nomenu)
if ((NEW_GAME == 0)); then
  LAUNCH_ARGS+=(-save "$SAVE_SLOT")
fi
if [[ -n "$PIPELINE_ARCHIVE_TEST_MODE" ]]; then
  LAUNCH_ARGS+=(
    "-renderer-ios-pipeline-archive-$PIPELINE_ARCHIVE_TEST_MODE"
  )
fi
if ((NEW_GAME != 0)); then
  echo "== unattended launch: new game, ${DURATION}s =="
else
  echo "== unattended launch: save slot $SAVE_SLOT, ${DURATION}s =="
fi
RUNTIME_ARMED=1
if ! xcrun devicectl device process launch --device "$DEVICE" \
    --terminate-existing -- "$BUNDLE_ID" "${LAUNCH_ARGS[@]}" \
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
python3 - "$WORK/log.txt" "$EXPECTED_SHA" <<'PY' ||
import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
source_sha = sys.argv[2]
allowed = {source_sha, source_sha + "-local"}
builds = re.findall(
    r"^RendererIOS shell: [^\r\n]* build=([^\s]+) gpu=",
    log,
    flags=re.MULTILINE,
)
if len(builds) != 1 or builds[0] not in allowed:
    raise SystemExit(
        "expected exactly one RendererIOS shell build in "
        + repr(sorted(allowed))
        + ", found "
        + repr(builds)
    )
PY
  fail "runtime log does not identify exact source SHA $EXPECTED_SHA"
rg -F 'RendererIOS diagnostics: ON' "$WORK/log.txt" >/dev/null ||
  fail "installed app is not a diagnostics-enabled RendererIOS build"
rg -F 'RendererIOS shader library: source=offline-metallib resource=RendererIOS.metallib abi=4' \
  "$WORK/log.txt" >/dev/null || fail "offline metallib marker is missing"
rg -F 'RendererIOS builtin shader library: source=offline-metallib resource=RendererIOS.metallib abi=4 manifest=1 fail-closed=1' \
  "$WORK/log.txt" >/dev/null || fail "offline Builtin manifest marker is missing"
rg -F 'RendererIOS inventory shader manifest: resource=RendererIOS.metallib abi=4 manifest=1 exact-spirv=1 configured=1 fail-closed=1' \
  "$WORK/log.txt" >/dev/null || fail "offline inventory manifest marker is missing"
rg -F 'RendererIOS inventory shader pipeline: source=offline-metallib resource=RendererIOS.metallib abi=4 manifest=1 exact-spirv=1 functions-resolved=2 pipeline-wrapper-created=1' \
  "$WORK/log.txt" >/dev/null || fail "offline inventory pipeline marker is missing"
rg -F 'RendererIOS native Bink pipeline: source=offline-metallib resource=RendererIOS.metallib abi=4 color=rgba8 sample-count=1 pipeline-created=1' \
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
rg -F 'RendererIOS legacy shader policy: profile=bridge-only eager-bridge-pipelines=inventory offline-native-pipelines=builtin,bink legacy-batch=disabled material-pipelines=source-metadata-only pfx-pipelines=disabled' \
  "$WORK/log.txt" >/dev/null || fail "RendererIOS bridge-only shader policy marker is missing"
if rg -F 'Shader compilation took:' "$WORK/log.txt" >/dev/null; then
  fail "legacy eager shader batch ran in RendererIOS"
fi
python3 - "$WORK/log.txt" "$WORK/runtime-compilation-summary.txt" \
  "$SCENARIO" "$PIPELINE_ARCHIVE_TEST_MODE" <<'PY' ||
import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
summary = pathlib.Path(sys.argv[2])
scenario = sys.argv[3]
pipeline_archive_test_mode = sys.argv[4]
if scenario not in ("save", "new-game"):
    raise SystemExit(f"unknown smoke scenario: {scenario}")
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
        0, 0, 0,
        0, 0, 0,
        0, 0, 0,
    ):
    raise SystemExit(
        "offline Builtin and inventory construction must not request source "
        "libraries or Tempest native PSOs"
    )

frames = [tuple(map(int, match.groups())) for match in frame_re.finditer(log)]
if len(frames) < 2 or frames[0][0] != 1 or frames[-1][0] < 300:
    raise SystemExit("runtime compilation frame markers do not cover presents 1 through 300")
previous = (0, source_after, compute_after, render_after)
first_frame_totals = None
expected_present = 1
render_transition_present = 0
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
    if source != 0 or compute != 0:
        raise SystemExit(
            f"{scenario} runtime source/compute must remain exact 0/0 at "
            f"present {present}, found {source}/{compute}"
        )
    if scenario == "save":
        if render != 2:
            raise SystemExit(
                "save runtime totals must remain exact 0/0/2: "
                f"present={present} current={(source, compute, render)}"
            )
    else:
        if render not in (2, 3):
            raise SystemExit(
                "new-game render total must be exact 2 or 3: "
                f"present={present} render={render}"
            )
        if present == 1 and render != 2:
            raise SystemExit("new-game first presented frame must have render=2")
        if present > 1 and render < previous[3]:
            raise SystemExit(
                f"new-game render total regressed at present {present}"
            )
        if present > 1 and render != previous[3]:
            if previous[3] != 2 or render != 3 or render_transition_present != 0:
                raise SystemExit(
                    "new-game runtime must have exactly one monotonic "
                    "render 2-to-3 transition"
                )
            render_transition_present = present
    previous = (present, source, compute, render)
    expected_present += 1

last_present, _, last_source, last_compute, last_render = frames[-1]
first_source, first_compute, first_render = first_frame_totals
if first_frame_totals != (0, 0, 2):
    raise SystemExit(
        "the first presented frame must have exact offline shader totals "
        f"(0, 0, 2), found {first_frame_totals}"
    )
if scenario == "new-game":
    if render_transition_present == 0:
        raise SystemExit(
            "new-game runtime never transitioned from render=2 to render=3"
        )
    if render_transition_present > 300:
        raise SystemExit(
            "new-game runtime render transition occurred after present 300: "
            f"{render_transition_present}"
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
if builtin_source_before != (0, 0, 0, 0):
    raise SystemExit(
        "offline Tempest Builtin construction must not request source libraries, "
        f"found {builtin_source_before}"
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
save_builtin_render = (0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0)
new_game_builtin_render = (0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0)
if builtin_frames[0][2] != (0, 0, 0, 0):
    raise SystemExit(
        "first frame performed an unexpected Tempest Builtin source request"
    )
if first_builtin_render != save_builtin_render:
    raise SystemExit(
        "the first frame must classify the exact two one-shot Builtin PSO "
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
    if source_counts != (0, 0, 0, 0):
        raise SystemExit(
            f"Tempest Builtin source role counts changed at present {present}"
        )
    expected_builtin_render = save_builtin_render
    if scenario == "new-game" and present >= 300:
        expected_builtin_render = new_game_builtin_render
    if render_counts != expected_builtin_render:
        raise SystemExit(
            f"{scenario} Tempest Builtin role vector is wrong: "
            f"present={present} expected={expected_builtin_render} "
            f"current={render_counts}"
        )
    previous_builtin_present = present
    expected_builtin_present = 300 if present == 1 else present + 300

final_builtin_render = builtin_frames[-1][3]
active_builtin_render_roles = tuple(
    role for role, count in zip(render_roles, final_builtin_render)
    if count != 0
)

if scenario == "new-game" and render_transition_present > 300:
    raise SystemExit("new-game Builtin transition was not bounded by present 300")

if scenario == "new-game" and pipeline_archive_test_mode:
    world_gate_re = re.compile(
        r"RendererIOS scene world gate: old-generation=(\d+) "
        r"new-generation=(\d+) retained-after=0 idle-confirmed=1"
    )
    snapshot_re = re.compile(
        r"RendererIOS scene snapshot: generation=(\d+) sequence=(\d+) "
        r"slot=(\d+) entities=(\d+) lights=(\d+) history-valid=(\d+)"
    )
    gates = [
        (match.start(), int(match.group(1)), int(match.group(2)))
        for match in world_gate_re.finditer(log)
    ]
    snapshots = [
        (match.start(), int(match.group(1)), int(match.group(4)))
        for match in snapshot_re.finditer(log)
    ]
    if not gates:
        raise SystemExit(
            "new-game pipeline archive mode has no confirmed scene world gate"
        )
    if not any(
        snapshot_position > gate_position
        and snapshot_generation == new_generation
        and entities > 0
        for gate_position, _old_generation, new_generation in gates
        for snapshot_position, snapshot_generation, entities in snapshots
    ):
        raise SystemExit(
            "new-game pipeline archive mode has no non-empty scene snapshot "
            "after its confirmed world gate"
        )

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
    f"runtime_compilation_render_transition_present={render_transition_present}\n"
    f"builtin_source_roles={','.join(source_roles)}\n"
    f"builtin_source_role_counts={','.join(map(str, builtin_frames[0][2]))}\n"
    f"builtin_render_active_roles={','.join(active_builtin_render_roles)}\n"
    f"builtin_render_initial_role_counts={','.join(map(str, first_builtin_render))}\n"
    f"builtin_render_role_counts={','.join(map(str, final_builtin_render))}\n"
)
PY
  fail "runtime compilation counter evidence is incomplete or inconsistent"
if [[ "$SCENARIO" != new-game || -z "$PIPELINE_ARCHIVE_TEST_MODE" ]]; then
  rg 'RendererIOS native Landscape: .*draws=[1-9][0-9]* textured=[1-9][0-9]*' \
    "$WORK/log.txt" >/dev/null ||
    fail "no native textured Landscape frame was proven"
fi
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
ditto "$WORK/device-selection.log" "$OUT/device-selection.log"
{
  echo "result=PASS"
  echo "source_sha=$EXPECTED_SHA"
  echo "bundle_id=$BUNDLE_ID"
  echo "scenario=$SCENARIO"
  echo "save_slot=$SCENARIO_SAVE_SLOT"
  echo "duration_seconds=$DURATION"
  echo "device_selection_attempts=$DEVICE_SELECTION_ATTEMPTS_USED"
  echo "device_selection_method=$DEVICE_SELECTION_METHOD"
  echo "device_selection_test_fail_first=$DEVICE_SELECTION_TEST_FAIL_FIRST"
  echo "bink_self_test_required=$REQUIRE_BINK_SELF_TEST"
  echo "bink_self_test_passed=$REQUIRE_BINK_SELF_TEST"
  echo "metallib_sha256=$METALLIB_SHA"
  echo "log_sha256=$(shasum -a 256 "$WORK/log.txt" | awk '{print $1}')"
  echo "device_process_stopped=1"
  cat "$WORK/runtime-compilation-summary.txt"
} >"$OUT/result.txt"

echo "PASS — offline metallib + scenario counters + scene/Bink gates proven; app stopped"
echo "evidence: $OUT"
