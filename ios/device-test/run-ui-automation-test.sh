#!/usr/bin/env bash
# Run the standalone RendererIOS coordinate-driven XCUITest against the exact
# diagnostics app already installed by run-smoke-test.sh. The game app is never
# uninstalled, so its suffixed bundle identifier and Documents container stay.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT/ios/device-test/ui-automation/RendererIOSUITests.xcodeproj"
VALIDATOR="$ROOT/ios/device-test/validate-ui-automation-log.py"
BASE_BUNDLE_ID="opengothic.gothic2"
SCENARIO="new-game"
SAVE_SLOT=20

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --new-game) SCENARIO="new-game"; shift ;;
    --save-slot) SCENARIO=save; SAVE_SLOT="${2:?missing save slot}"; shift 2 ;;
    -*) fail "usage: $0 [--new-game|--save-slot number]" ;;
    *) fail "unexpected positional argument: $1" ;;
  esac
done
[[ "$SAVE_SLOT" =~ ^[0-9]+$ ]] || fail "save slot must be numeric"
[[ -d "$PROJECT" ]] || fail "UI automation Xcode project is missing"
[[ -x "$VALIDATOR" ]] || fail "UI automation log validator is not executable"

EXPECTED_SHA="${OPENGOTHIC_IOS_EXPECTED_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  fail "expected source SHA must be exactly 40 lowercase hexadecimal characters"

WORK="$(mktemp -d -t opengothic-device-ui)"
DEVICE=""
BUNDLE_ID=""
APP_EXECUTABLE="Gothic2Notr"
RUNTIME_ARMED=0
PRE_CRASH_SHA="missing"
POST_CRASH_SHA="missing"

stop_running_app() {
  local strict="${1:-0}"
  local attempt json mode pid pids
  [[ -n "$DEVICE" ]] || return 0
  for attempt in 1 2 3 4 5; do
    json="$WORK/processes-$attempt.json"
    if ! xcrun devicectl device info processes --device "$DEVICE" \
        --json-output "$json" >/dev/null 2>>"$WORK/cleanup.log"; then
      [[ "$strict" == 0 ]] || echo "FAIL: process query failed" >&2
      return 1
    fi
    pids="$(python3 - "$json" "$APP_EXECUTABLE" <<'PY'
import json, pathlib, sys
for process in json.load(open(sys.argv[1]))["result"]["runningProcesses"]:
    if pathlib.PurePosixPath(process.get("executable", "")).name == sys.argv[2]:
        pid = process.get("processIdentifier")
        if not isinstance(pid, int):
            raise SystemExit("invalid process identifier")
        print(pid)
PY
    )" || return 1
    [[ -n "$pids" ]] || return 0
    ((attempt < 5)) || break
    mode=terminate
    ((attempt < 4)) || mode=kill
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      echo "attempt=$attempt mode=$mode executable=$APP_EXECUTABLE pid=$pid" \
        >>"$WORK/cleanup.log"
      if [[ "$mode" == kill ]]; then
        xcrun devicectl device process terminate --device "$DEVICE" --pid "$pid" \
          --kill --quiet >/dev/null 2>>"$WORK/cleanup.log" || true
      else
        xcrun devicectl device process terminate --device "$DEVICE" --pid "$pid" \
          --quiet >/dev/null 2>>"$WORK/cleanup.log" || true
      fi
    done <<<"$pids"
    sleep 1
  done
  [[ "$strict" == 0 ]] || echo "FAIL: game process is still running" >&2
  return 1
}

pull_logs() {
  local suffix="$1" name stem extension
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

preserve_evidence() {
  local result="$1" timestamp out candidate
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  out="$ROOT/build/device-ui-automation/$EXPECTED_SHA/$result-$timestamp-$$"
  mkdir -p "$out"
  for candidate in xcodebuild.log xcresult-summary.json cleanup.log \
      log-pre-test.txt stderr-pre-test.log crash-pre-test.log \
      log-final.txt stderr-final.log \
      crash-final.log log-before-cleanup.txt stderr-before-cleanup.log \
      crash-before-cleanup.log log-after-cleanup.txt \
      stderr-after-cleanup.log crash-after-cleanup.log; do
    [[ -f "$WORK/$candidate" ]] || continue
    ditto "$WORK/$candidate" "$out/$candidate"
  done
  [[ ! -d "$WORK/TestResults.xcresult" ]] ||
    ditto "$WORK/TestResults.xcresult" "$out/TestResults.xcresult"
  {
    echo "result=$result"
    echo "source_sha=$EXPECTED_SHA"
    echo "bundle_id=$BUNDLE_ID"
    echo "scenario=$SCENARIO"
    echo "save_slot=$([[ "$SCENARIO" == save ]] && echo "$SAVE_SLOT" || echo none)"
    echo "pre_crash_sha256=$PRE_CRASH_SHA"
    echo "post_crash_sha256=$POST_CRASH_SHA"
    echo "device_process_stopped=$([[ "$result" == PASS ]] && echo 1 || echo unknown)"
  } >"$out/result.txt"
  echo "evidence: $out"
}

cleanup() {
  local status=$? cleanup_status=0
  trap - EXIT INT TERM HUP
  set +e
  if ((RUNTIME_ARMED != 0)); then
    pull_logs before-cleanup
  fi
  stop_running_app 0 || cleanup_status=1
  if ((RUNTIME_ARMED != 0)); then
    pull_logs after-cleanup
  fi
  if ((status != 0 || cleanup_status != 0)); then
    preserve_evidence FAIL
  fi
  [[ "$WORK" == /var/folders/*/T/opengothic-device-ui.* ]] && rm -rf "$WORK"
  if ((status == 0 && cleanup_status != 0)); then
    exit 1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

xcrun xcdevice list >"$WORK/xcdevices.json"
DEVICE="$(python3 - "$WORK/xcdevices.json" "${OPENGOTHIC_IOS_DEVICE:-}" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))
requested = sys.argv[2]
matches = [
    device for device in devices
    if not device.get("simulator")
    and device.get("available")
    and device.get("interface") == "usb"
    and device.get("platform") == "com.apple.platform.iphoneos"
    and (not requested or requested == device.get("identifier"))
]
if len(matches) != 1:
    raise SystemExit(f"expected one available USB iPhone, found {len(matches)}")
print(matches[0]["identifier"])
PY
)" || fail "could not select a unique connected physical iPhone"

xcrun devicectl device info apps --device "$DEVICE" \
  --json-output "$WORK/apps.json" >/dev/null
BUNDLE_ID="$(python3 - "$WORK/apps.json" "$BASE_BUNDLE_ID" \
    "${OPENGOTHIC_IOS_BUNDLE_ID:-}" <<'PY'
import json, sys
apps = json.load(open(sys.argv[1]))["result"]["apps"]
prefix, requested = sys.argv[2] + ".", sys.argv[3]
matches = [app["bundleIdentifier"] for app in apps
           if app["bundleIdentifier"].startswith(prefix)]
if requested:
    matches = [bundle for bundle in matches if bundle == requested]
if len(matches) != 1:
    raise SystemExit(f"expected one installed {prefix}* app, found {len(matches)}")
print(matches[0])
PY
)" || fail "could not identify the existing OpenGothic container"
TEAM_ID="${OPENGOTHIC_IOS_TEAM_ID:-${BUNDLE_ID##*.}}"
[[ "$BUNDLE_ID" == "$BASE_BUNDLE_ID.$TEAM_ID" && "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] ||
  fail "bundle id must preserve the existing team-id suffix"

stop_running_app 1 || fail "pre-test application cleanup failed"
pull_logs pre-test
if [[ -f "$WORK/crash-pre-test.log" ]]; then
  PRE_CRASH_SHA="$(shasum -a 256 "$WORK/crash-pre-test.log" | awk '{print $1}')"
fi
RUNTIME_ARMED=1
if ! xcodebuild -project "$PROJECT" -scheme RendererIOSUITests \
    -destination "platform=iOS,id=$DEVICE" \
    -derivedDataPath "$WORK/DerivedData" \
    -resultBundlePath "$WORK/TestResults.xcresult" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID.RendererIOSUITests" \
    OPENGOTHIC_TARGET_BUNDLE_ID="$BUNDLE_ID" \
    OPENGOTHIC_UI_SCENARIO="$SCENARIO" \
    OPENGOTHIC_UI_SAVE_SLOT="$SAVE_SLOT" \
    test >"$WORK/xcodebuild.log" 2>&1; then
  tail -50 "$WORK/xcodebuild.log" >&2 || true
  fail "RendererIOS XCUITest failed"
fi

xcrun xcresulttool get test-results summary \
  --path "$WORK/TestResults.xcresult" --compact \
  >"$WORK/xcresult-summary.json"
python3 - "$WORK/xcresult-summary.json" <<'PY' ||
import json, sys
summary = json.load(open(sys.argv[1]))
expected = {
    "result": "Passed",
    "totalTestCount": 1,
    "passedTests": 1,
    "failedTests": 0,
    "skippedTests": 0,
    "expectedFailures": 0,
}
actual = {key: summary.get(key) for key in expected}
if actual != expected:
    raise SystemExit(f"unexpected XCTest summary: {actual}")
PY
  fail "XCTest did not execute exactly one passing, non-skipped test"

stop_running_app 1 || fail "post-test application cleanup failed"
pull_logs final
RUNTIME_ARMED=0
[[ -s "$WORK/log-final.txt" ]] || fail "device produced no log.txt"
if [[ -f "$WORK/crash-final.log" ]]; then
  POST_CRASH_SHA="$(shasum -a 256 "$WORK/crash-final.log" | awk '{print $1}')"
fi
[[ "$POST_CRASH_SHA" == "$PRE_CRASH_SHA" ]] ||
  fail "crash.log changed during the UI automation run"
python3 - "$WORK/log-final.txt" "$EXPECTED_SHA" <<'PY' ||
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
expected = {sys.argv[2], sys.argv[2] + "-local"}
builds = re.findall(r"^RendererIOS shell: [^\r\n]* build=([^\s]+) gpu=", log, re.MULTILINE)
if len(builds) != 1 or builds[0] not in expected:
    raise SystemExit(f"expected one exact build in {sorted(expected)}, found {builds}")
PY
  fail "runtime log does not identify exact source SHA $EXPECTED_SHA"
VALIDATOR_ARGS=("$WORK/log-final.txt")
[[ ! -f "$WORK/stderr-final.log" ]] ||
  VALIDATOR_ARGS+=(--stderr "$WORK/stderr-final.log")
[[ "$SCENARIO" != new-game ]] || VALIDATOR_ARGS+=(--require-bink)
[[ "$SCENARIO" != save ]] || VALIDATOR_ARGS+=(--require-ui-items)
"$VALIDATOR" "${VALIDATOR_ARGS[@]}" ||
  fail "terminal functional evidence is incomplete"

preserve_evidence PASS
echo "PASS — RendererIOS XCUITest UI/Bink/lifecycle gate; app stopped"
