#!/usr/bin/env bash
#
# Sign, install and exercise a diagnostics-enabled RendererIOS build on one
# connected physical iOS device. The existing suffixed bundle identifier is
# preserved, so game assets and saves stay in the same data container.
#
# Usage:
#   ios/device-test/run-smoke-test.sh path/to/Gothic2Notr.app
#   OPENGOTHIC_IOS_DEVICE=<CoreDevice UUID> ... --duration 60 --save-slot 20 APP
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
APP_INPUT=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="${2:?missing duration}"; shift 2 ;;
    --save-slot) SAVE_SLOT="${2:?missing save slot}"; shift 2 ;;
    -*) fail "usage: $0 [--duration seconds] [--save-slot number] path/to/Gothic2Notr.app" ;;
    *) [[ -z "$APP_INPUT" ]] || fail "only one app path may be supplied"; APP_INPUT="$1"; shift ;;
  esac
done

[[ "$DURATION" =~ ^[0-9]+$ ]] && ((DURATION >= 10 && DURATION <= 600)) ||
  fail "duration must be 10..600 seconds"
[[ "$SAVE_SLOT" =~ ^[0-9]+$ ]] || fail "save slot must be a non-negative integer"
[[ -n "$APP_INPUT" && -d "$APP_INPUT" ]] || fail "pass an existing .app directory"
[[ -f "$APP_INPUT/RendererIOS.metallib" ]] || fail "app has no RendererIOS.metallib"

WORK="$(mktemp -d -t opengothic-device-smoke)"
cleanup() {
  [[ "$WORK" == /var/folders/*/T/opengothic-device-smoke.* ]] && rm -rf "$WORK"
}
trap cleanup EXIT

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
    and d.get("connectionProperties", {}).get("tunnelState") == "connected"
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
PRE_CRASH_SHA=""
if xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source Documents/crash.log --destination "$WORK/crash-before.log" >/dev/null 2>&1; then
  PRE_CRASH_SHA="$(shasum -a 256 "$WORK/crash-before.log" | awk '{print $1}')"
fi

echo "== installing $BUNDLE_ID =="
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null

echo "== unattended launch: save slot $SAVE_SLOT, ${DURATION}s =="
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
python3 - "$WORK/processes.json" \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")" <<'PY' ||
import json, pathlib, sys
processes = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
expected = sys.argv[2]
if not any(pathlib.PurePosixPath(p.get("executable", "")).name == expected
           for p in processes):
    raise SystemExit(1)
PY
  fail "application process did not survive the smoke window"

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
rg -F 'RendererIOS shader library: source=offline-metallib resource=RendererIOS.metallib abi=1' \
  "$WORK/log.txt" >/dev/null || fail "offline metallib marker is missing"
rg 'RendererIOS native Landscape: .*draws=[1-9][0-9]* textured=[1-9][0-9]*' \
  "$WORK/log.txt" >/dev/null || fail "no native textured Landscape frame was proven"
if rg -i 'RendererIOS (fatal|GPU shutdown failed|native Landscape encode failed|IOSGPUScene metallib loading failed)|libc\\+\\+abi: terminating|SIGABRT' \
    "$WORK/log.txt" "$WORK/stderr.log" >/dev/null 2>&1; then
  fail "fatal RendererIOS/runtime signature found in device logs"
fi

POST_CRASH_SHA=""
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
  echo "metallib_sha256=$METALLIB_SHA"
  echo "log_sha256=$(shasum -a 256 "$WORK/log.txt" | awk '{print $1}')"
} >"$OUT/result.txt"

echo "PASS — offline metallib + native textured Landscape runtime proven"
echo "evidence: $OUT"
