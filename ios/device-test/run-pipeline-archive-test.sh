#!/usr/bin/env bash
#
# Deterministic physical-device D-041 protocol:
#   cold -> warm -> corrupt -> recovery-warm
#
# The existing smoke harness owns signing, the single install, and the cold
# launch.  Every later phase launches the already-installed bundle directly.
# The suffixed bundle identifier and its data container are never removed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_SMOKE="$ROOT/ios/device-test/run-smoke-test.sh"
VALIDATOR="$ROOT/ios/device-test/validate-pipeline-archive-log.py"
BASE_BUNDLE_ID="opengothic.gothic2"

ARCHIVE_DIR="Library/Caches/RendererIOS/PipelineArchives/schema-1"
ARCHIVE_NAME="RendererIOS-abi-5.binaryarchive"
PROVENANCE_NAME="RendererIOS-abi-5.provenance"
ARCHIVE_PATH="$ARCHIVE_DIR/$ARCHIVE_NAME"
PROVENANCE_PATH="$ARCHIVE_DIR/$PROVENANCE_NAME"

DURATION=45
SAVE_SLOT=20
SAVE_SLOT_EXPLICIT=0
NEW_GAME=0
APP_INPUT=""
SELF_TEST=0
BASELINE_ONLY=0
EVIDENCE_PATH_FILE=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

publish_evidence_path() {
  local path="$1"
  [[ -n "$EVIDENCE_PATH_FILE" ]] || return 0
  printf '%s\n' "$path" >"$EVIDENCE_PATH_FILE"
}

read_base_smoke_evidence() {
  local path_file="$1"
  local expected_sha="$2"
  local expected_build="$3"

  python3 - "$path_file" "$ROOT" "$expected_sha" "$expected_build" <<'PY'
import pathlib
import re
import sys

path_file = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
source_sha = sys.argv[3]
expected_build = sys.argv[4]
lines = path_file.read_text().splitlines()
if len(lines) != 1:
    raise SystemExit("base smoke evidence path file must contain exactly one line")
actual = lines[0]
if expected_build == source_sha:
    expected = str(root / "build" / "device-smoke" / source_sha)
    if actual != expected:
        raise SystemExit("clean base smoke evidence path is not canonical")
else:
    prefix = str(root / "build" / "device-fault" / expected_build / "none")
    if re.fullmatch(re.escape(prefix) + r"/pass-[0-9]{8}T[0-9]{6}Z-[0-9]+", actual) is None:
        raise SystemExit("local base smoke evidence path is not canonical")
print(actual)
PY
}

resolve_expected_build() {
  local app_strings="$1"
  local expected_sha="$2"

  if [[ -n "${OPENGOTHIC_IOS_EXPECTED_BUILD:-}" ]]; then
    EXPECTED_BUILD="$OPENGOTHIC_IOS_EXPECTED_BUILD"
  else
    EXPECTED_BUILD="$(
      python3 - "$app_strings" "$expected_sha" <<'PY'
import pathlib
import sys

lines = set(pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines())
source_sha = sys.argv[2]
allowed = {source_sha, source_sha + "-local"}
matches = sorted(lines & allowed)
if len(matches) != 1:
    raise SystemExit(
        "app must contain exactly one source-bound RendererIOS build, found "
        + repr(matches)
    )
print(matches[0])
PY
    )" || return 1
  fi
}

usage() {
  echo "usage: $0 [--duration seconds] [--save-slot number|--new-game] [--baseline-only] [--evidence-path-file absolute-path] path/to/Gothic2Notr.app"
  echo "       $0 --self-test"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      DURATION="${2:?missing duration}"
      shift 2
      ;;
    --save-slot)
      SAVE_SLOT="${2:?missing save slot}"
      SAVE_SLOT_EXPLICIT=1
      shift 2
      ;;
    --new-game)
      NEW_GAME=1
      shift
      ;;
    --baseline-only)
      BASELINE_ONLY=1
      shift
      ;;
    --evidence-path-file)
      [[ -z "$EVIDENCE_PATH_FILE" ]] || fail "--evidence-path-file was specified twice"
      EVIDENCE_PATH_FILE="${2:?missing evidence path file}"
      shift 2
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$APP_INPUT" ]] || fail "only one app path may be supplied"
      APP_INPUT="$1"
      shift
      ;;
  esac
done

if ((SELF_TEST != 0)); then
  self_test_work="$(mktemp -d -t opengothic-pipeline-wrapper-contract)"
  self_test_sha="0123456789abcdef0123456789abcdef01234567"
  self_test_build="$self_test_sha-local"
  self_test_path_file="$self_test_work/base-smoke-evidence-path.txt"
  self_test_strings="$self_test_work/app-strings.txt"
  [[ -z "$APP_INPUT" ]] || fail "--self-test does not accept an app"
  python3 "$VALIDATOR" --self-test
  printf '%s\n' "$self_test_build" >"$self_test_strings"
  unset OPENGOTHIC_IOS_EXPECTED_BUILD
  resolve_expected_build "$self_test_strings" "$self_test_sha" ||
    fail "Bash build inference contract self-test failed"
  [[ "$EXPECTED_BUILD" == "$self_test_build" ]] ||
    fail "Bash build inference did not preserve SHA-local semantics"
  printf '%s\n' "$self_test_sha" >"$self_test_strings"
  OPENGOTHIC_IOS_EXPECTED_BUILD="$self_test_sha"
  resolve_expected_build "$self_test_strings" "$self_test_sha" ||
    fail "Bash explicit build contract self-test failed"
  [[ "$EXPECTED_BUILD" == "$self_test_sha" ]] ||
    fail "Bash explicit build did not preserve clean SHA semantics"
  OPENGOTHIC_IOS_EXPECTED_SHA="$self_test_sha" \
  OPENGOTHIC_IOS_EXPECTED_BUILD="$self_test_build" \
  OPENGOTHIC_IOS_EXPECTED_FAULT=none \
  OPENGOTHIC_IOS_EVIDENCE_TIMESTAMP=20000101T000000Z \
  OPENGOTHIC_IOS_EVIDENCE_PID=4242 \
    "$BASE_SMOKE" --self-test \
      --evidence-path-file "$self_test_path_file"
  self_test_actual="$(read_base_smoke_evidence \
    "$self_test_path_file" "$self_test_sha" "$self_test_build")" ||
    fail "wrapper could not consume SHA-local smoke evidence path"
  [[ "$self_test_actual" == \
     "$ROOT/build/device-fault/$self_test_build/none/pass-20000101T000000Z-4242" ]] ||
    fail "wrapper/smoke SHA-local evidence contract self-test failed"
  find "$self_test_work" -type f -delete
  rmdir "$self_test_work"
  echo "pipeline archive Bash build resolution contract self-test passed"
  echo "pipeline archive wrapper/smoke SHA-local contract self-test passed"
  exit 0
fi

[[ "$DURATION" =~ ^[0-9]+$ ]] &&
  ((DURATION >= 10 && DURATION <= 600)) ||
  fail "duration must be 10..600 seconds"
[[ "$SAVE_SLOT" =~ ^[0-9]+$ ]] ||
  fail "save slot must be a non-negative integer"
((NEW_GAME == 0 || SAVE_SLOT_EXPLICIT == 0)) ||
  fail "--new-game and --save-slot are mutually exclusive"
if [[ -n "$EVIDENCE_PATH_FILE" ]]; then
  [[ "$EVIDENCE_PATH_FILE" == /* ]] || fail "evidence path file must be absolute"
  [[ -d "$(dirname "$EVIDENCE_PATH_FILE")" ]] ||
    fail "evidence path file parent does not exist"
fi
[[ -n "$APP_INPUT" && -d "$APP_INPUT" ]] ||
  fail "pass an existing .app directory"
[[ -x "$BASE_SMOKE" ]] || fail "base smoke harness is not executable"
[[ -x "$VALIDATOR" ]] || fail "archive log validator is not executable"
[[ -f "$APP_INPUT/RendererIOS.metallib" ]] ||
  fail "app has no RendererIOS.metallib"
SCENARIO=save
SCENARIO_SAVE_SLOT="$SAVE_SLOT"
if ((NEW_GAME != 0)); then
  SCENARIO=new-game
  SCENARIO_SAVE_SLOT=none
fi

APP_EXECUTABLE="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP_INPUT/Info.plist" 2>/dev/null
)" || fail "app has no CFBundleExecutable"
[[ -n "$APP_EXECUTABLE" && "$APP_EXECUTABLE" != */* ]] ||
  fail "invalid CFBundleExecutable"

EXPECTED_SHA="${OPENGOTHIC_IOS_EXPECTED_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  fail "expected source SHA must be exactly 40 lowercase hexadecimal characters"
APP_STRINGS="$(mktemp -t opengothic-pipeline-app-strings)"
strings "$APP_INPUT/$APP_EXECUTABLE" >"$APP_STRINGS"
resolve_expected_build "$APP_STRINGS" "$EXPECTED_SHA" ||
  fail "app does not identify one exact source-bound RendererIOS build"
[[ "$EXPECTED_BUILD" == "$EXPECTED_SHA" ||
   "$EXPECTED_BUILD" == "$EXPECTED_SHA-local" ]] ||
  fail "expected build must identify the expected source SHA"
grep -Fxq "$EXPECTED_BUILD" "$APP_STRINGS" ||
  fail "app binary does not contain exact expected RendererIOS build"
rm -f "$APP_STRINGS"
METALLIB_SHA="$(shasum -a 256 "$APP_INPUT/RendererIOS.metallib" | awk '{print $1}')"
[[ "$METALLIB_SHA" =~ ^[0-9a-f]{64}$ ]] ||
  fail "could not compute RendererIOS.metallib SHA-256"

WORK="$(mktemp -d -t opengothic-pipeline-archive)"
TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT="$ROOT/build/device-pipeline-archive/$EXPECTED_SHA/run-$TIMESTAMP-$$"
mkdir -p "$OUT"

DEVICE=""
DEVICE_UDID=""
DEVICE_SELECTION_METHOD=""
DEVICE_SELECTION_ATTEMPTS_USED=0
BUNDLE_ID=""
CURRENT_PHASE="setup"
PROTOCOL_PASSED=0

process_count() {
  local label="$1"
  local json="$WORK/processes-$label-$(uuidgen).json"

  [[ -n "$DEVICE" ]] || return 1
  xcrun devicectl device info processes --device "$DEVICE" \
    --json-output "$json" >/dev/null 2>>"$WORK/cleanup.log" || return 1
  python3 - "$json" "$APP_EXECUTABLE" <<'PY'
import json
import pathlib
import sys

processes = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
expected = sys.argv[2]
count = sum(
    pathlib.PurePosixPath(process.get("executable", "")).name == expected
    for process in processes
)
print(count)
PY
}

stop_running_app() {
  local strict="${1:-0}"
  local attempt count json mode pid pids

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
import json
import pathlib
import sys

processes = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
expected = sys.argv[2]
for process in processes:
    if pathlib.PurePosixPath(process.get("executable", "")).name != expected:
        continue
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
      echo "phase=$CURRENT_PHASE attempt=$attempt mode=$mode executable=$APP_EXECUTABLE" \
        >>"$WORK/cleanup.log"
      if [[ "$mode" == "kill" ]]; then
        xcrun devicectl device process terminate --device "$DEVICE" \
          --pid "$pid" --kill --quiet >/dev/null 2>>"$WORK/cleanup.log" || true
      else
        xcrun devicectl device process terminate --device "$DEVICE" \
          --pid "$pid" --quiet >/dev/null 2>>"$WORK/cleanup.log" || true
      fi
    done <<<"$pids"
    sleep 1
  done

  [[ "$strict" == 0 ]] ||
    echo "FAIL: $APP_EXECUTABLE is still running on the device" >&2
  return 1
}

record_zero_scan() {
  local label="$1"
  local destination="$2"
  local count

  count="$(process_count "$label")" ||
    fail "could not scan processes for $label"
  [[ "$count" == 0 ]] ||
    fail "expected zero $APP_EXECUTABLE processes for $label, found $count"
  {
    echo "scan=$label"
    echo "game_processes=0"
  } >>"$destination"
}

assert_stopped() {
  local label="$1"
  local destination="$2"

  CURRENT_PHASE="$label"
  stop_running_app 1 || fail "application cleanup failed before $label"
  record_zero_scan "$label" "$destination"
}

cleanup() {
  local status=$?
  local cleanup_status=0
  local final_status="$status"
  local failure_phase="$CURRENT_PHASE"
  local count=""

  trap - EXIT INT TERM HUP
  set +e
  if [[ -n "$DEVICE" && -n "$APP_EXECUTABLE" ]]; then
    CURRENT_PHASE="trap-cleanup"
    stop_running_app 0 || cleanup_status=1
    if [[ "$cleanup_status" == 0 ]]; then
      count="$(process_count trap-final)"
      [[ "$count" == 0 ]] || cleanup_status=1
    fi
  fi
  if [[ -f "$WORK/cleanup.log" ]]; then
    ditto "$WORK/cleanup.log" "$OUT/cleanup.log"
  fi
  if ((PROTOCOL_PASSED == 0)); then
    {
      echo "result=FAIL"
      echo "source_sha=$EXPECTED_SHA"
      echo "scenario=$SCENARIO"
      echo "save_slot=$SCENARIO_SAVE_SLOT"
      echo "phase=$failure_phase"
      echo "original_exit_status=$status"
      echo "cleanup_status=$cleanup_status"
      [[ "$cleanup_status" == 0 ]] && echo "device_process_stopped=1"
    } >"$OUT/result.txt"
    echo "failure evidence: $OUT" >&2
  elif ((cleanup_status != 0)); then
    {
      echo "result=FAIL"
      echo "source_sha=$EXPECTED_SHA"
      echo "scenario=$SCENARIO"
      echo "save_slot=$SCENARIO_SAVE_SLOT"
      echo "phase=trap-cleanup"
      echo "original_exit_status=$status"
      echo "cleanup_status=$cleanup_status"
      echo "device_process_stopped=0"
    } >"$OUT/result.txt"
    echo "final cleanup invalidated protocol PASS: $OUT" >&2
  fi
  if ((status == 0 && cleanup_status != 0)); then
    final_status=1
  fi
  if ((cleanup_status != 0)); then
    echo "WARNING: could not confirm final device app cleanup" >&2
  fi
  case "$WORK" in
    /var/folders/*/T/opengothic-pipeline-archive.*)
      rm -rf "$WORK"
      ;;
  esac
  exit "$final_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

REQUESTED_DEVICE="${OPENGOTHIC_IOS_DEVICE:-}"

select_device_record() {
  local attempt json xcjson record selected_method

  for attempt in 1 2 3 4 5; do
    json="$WORK/devices-$attempt.json"
    xcjson="$WORK/xcdevices-$attempt.json"
    if xcrun devicectl list devices --json-output "$json" \
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
import json
import sys

devices = json.load(open(sys.argv[1]))["result"]["devices"]
requested = sys.argv[2]
xcdevices = json.load(open(sys.argv[3]))
usb_udids = {
    device.get("identifier")
    for device in xcdevices
    if not device.get("simulator")
    and device.get("available")
    and device.get("interface") == "usb"
    and device.get("platform") == "com.apple.platform.iphoneos"
}
matches = [
    device
    for device in devices
    if device.get("hardwareProperties", {}).get("platform") == "iOS"
    and device.get("hardwareProperties", {}).get("reality") == "physical"
    and (
        requested
        or device.get("connectionProperties", {}).get("tunnelState")
        == "connected"
        or device.get("hardwareProperties", {}).get("udid") in usb_udids
    )
    and (
        not requested
        or requested
        in (
            device.get("identifier"),
            device.get("hardwareProperties", {}).get("udid"),
        )
    )
]
if len(matches) != 1:
    raise SystemExit(
        f"expected exactly one connected physical iOS device, found {len(matches)}"
    )
device = matches[0]
if requested:
    method = "explicit"
elif device.get("connectionProperties", {}).get("tunnelState") == "connected":
    method = "connected"
else:
    method = "usb-witness"
print(
    device["identifier"]
    + "\t"
    + device["hardwareProperties"]["udid"]
    + "\t"
    + method
)
PY
      )"; then
        selected_method="${record##*$'\t'}"
        printf 'attempt=%d result=selected method=%s\n' \
          "$attempt" "$selected_method" >>"$WORK/device-selection.log"
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

xcrun devicectl device info apps --device "$DEVICE" \
  --json-output "$WORK/apps.json" >/dev/null
BUNDLE_ID="${OPENGOTHIC_IOS_BUNDLE_ID:-}"
BUNDLE_ID="$(python3 - "$WORK/apps.json" "$BASE_BUNDLE_ID" "$BUNDLE_ID" <<'PY'
import json
import sys

apps = json.load(open(sys.argv[1]))["result"]["apps"]
base = sys.argv[2] + "."
requested = sys.argv[3]
matches = [
    app["bundleIdentifier"]
    for app in apps
    if app["bundleIdentifier"].startswith(base)
]
if requested:
    matches = [bundle for bundle in matches if bundle == requested]
if len(matches) != 1:
    raise SystemExit(
        f"expected exactly one installed {base}* app, found {len(matches)}"
    )
print(matches[0])
PY
)" || fail "could not identify the existing OpenGothic data container"

TEAM_ID="${OPENGOTHIC_IOS_TEAM_ID:-${BUNDLE_ID##*.}}"
[[ "$BUNDLE_ID" == "$BASE_BUNDLE_ID.$TEAM_ID" ]] ||
  fail "bundle id must preserve the existing team-id suffix"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] ||
  fail "could not derive a valid team id"

copy_from_optional() {
  local remote="$1"
  local local_path="$2"
  local label="$3"

  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --user mobile --source "$remote" --destination "$local_path" \
    --json-output "$WORK/copy-from-$label-$(uuidgen).json" \
    >/dev/null 2>&1
}

copy_from_required() {
  local remote="$1"
  local local_path="$2"
  local label="$3"

  copy_from_optional "$remote" "$local_path" "$label" ||
    fail "could not copy required device file $remote for $label"
}

verify_existing_game_data() {
  local label="$1"
  local destination="$2"
  local documents="$WORK/game-data-$label-documents.json"
  local scripts="$WORK/game-data-$label-scripts.json"
  local system="$WORK/game-data-$label-system.json"

  xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$documents" >/dev/null ||
    fail "could not inspect OpenGothic Documents during $label"
  xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile \
    --subdirectory "Documents/_work/Data/Scripts/_compiled" --no-recurse \
    --json-output "$scripts" >/dev/null ||
    fail "could not inspect compiled Gothic scripts during $label"
  xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory "Documents/system" --no-recurse \
    --json-output "$system" >/dev/null ||
    fail "could not inspect Gothic system data during $label"
  python3 - "$documents" "$scripts" "$system" <<'PY' ||
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

documents = json.load(open(sys.argv[1]))["result"]["files"]
scripts = json.load(open(sys.argv[2]))["result"]["files"]
system = json.load(open(sys.argv[3]))["result"]["files"]
document_entries = {
    entry.get("name", "").lower(): entry
    for entry in documents
}
invalid = []
for required in ("data", "_work", "system"):
    entry = document_entries.get(required)
    resources = entry.get("resources", {}) if entry else {}
    if (
        entry is None
        or resources.get("isDirectory") is not True
        or resources.get("isSymbolicLink") is True
    ):
        invalid.append(required)
if not regular_file(scripts, "gothic.dat"):
    invalid.append("_work/Data/Scripts/_compiled/Gothic.dat")
if not regular_file(system, "gothic.ini"):
    invalid.append("system/Gothic.ini")
if invalid:
    raise SystemExit(
        "existing OpenGothic data preflight has missing/invalid entries: "
        + ", ".join(invalid)
    )
PY
    fail "existing game data preflight failed during $label"
  {
    echo "game_data_preflight=$label"
    echo "required_directories=Data,_work,system"
    echo "compiled_script=Gothic.dat"
    echo "configuration=Gothic.ini"
    echo "result=PASS"
  } >"$destination"
}

pull_runtime_logs() {
  local phase_dir="$1"
  local name

  for name in log.txt stderr.log crash.log; do
    copy_from_optional "Documents/$name" "$phase_dir/$name" \
      "$(basename "$phase_dir")-${name%.*}" || true
  done
}

crash_sha() {
  local path="$1"

  if [[ -s "$path" ]]; then
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

validate_phase_log() {
  local phase="$1"
  local phase_dir="$2"

  [[ -s "$phase_dir/log.txt" ]] ||
    fail "$phase produced no log.txt"
  python3 "$VALIDATOR" \
    --phase "$phase" \
    --scenario "$SCENARIO" \
    --log "$phase_dir/log.txt" \
    --source-sha "$EXPECTED_SHA" \
    --metallib-sha256 "$METALLIB_SHA" \
    --summary "$phase_dir/archive-summary.txt" ||
    fail "$phase pipeline archive log contract failed"
  if rg -i \
      'RendererIOS (fatal|GPU shutdown failed|native Landscape encode failed|IOSGPUScene metallib loading failed)|libc\\+\\+abi: terminating|SIGABRT' \
      "$phase_dir/log.txt" "$phase_dir/stderr.log" >/dev/null 2>&1; then
    fail "$phase contains a fatal RendererIOS/runtime signature"
  fi
}

copy_cache_evidence() {
  local phase_dir="$1"
  local label="$2"

  copy_from_required "$ARCHIVE_PATH" \
    "$phase_dir/$ARCHIVE_NAME" "$label-archive"
  copy_from_required "$PROVENANCE_PATH" \
    "$phase_dir/$PROVENANCE_NAME" "$label-provenance"
  [[ -s "$phase_dir/$ARCHIVE_NAME" ]] ||
    fail "$label produced an empty pipeline archive"
  [[ -s "$phase_dir/$PROVENANCE_NAME" ]] ||
    fail "$label produced no pipeline archive provenance"
  rg -Fx "metallib-sha256=$METALLIB_SHA" \
    "$phase_dir/$PROVENANCE_NAME" >/dev/null ||
    fail "$label provenance does not match RendererIOS.metallib"
  {
    echo "archive_sha256=$(shasum -a 256 "$phase_dir/$ARCHIVE_NAME" | awk '{print $1}')"
    echo "archive_bytes=$(stat -f '%z' "$phase_dir/$ARCHIVE_NAME")"
    echo "provenance_sha256=$(shasum -a 256 "$phase_dir/$PROVENANCE_NAME" | awk '{print $1}')"
  } >"$phase_dir/cache-after.txt"
}

echo "== D-041 setup: selected physical device by $DEVICE_SELECTION_METHOD =="
mkdir -p "$OUT/cold"
assert_stopped "cold-before-cache-reset" "$OUT/cold/process-state.txt"
verify_existing_game_data before "$OUT/cold/game-data-preflight.txt"

echo "== D-041 cold: one sign/install and first launch =="
CURRENT_PHASE="cold-base-smoke"
BASE_EVIDENCE_PATH_FILE="$WORK/base-smoke-evidence-path.txt"
BASE_SMOKE_SCENARIO_ARGS=(--save-slot "$SAVE_SLOT")
if ((NEW_GAME != 0)); then
  BASE_SMOKE_SCENARIO_ARGS=(--new-game)
fi
OPENGOTHIC_IOS_DEVICE="$DEVICE" \
OPENGOTHIC_IOS_BUNDLE_ID="$BUNDLE_ID" \
OPENGOTHIC_IOS_TEAM_ID="$TEAM_ID" \
OPENGOTHIC_IOS_EXPECTED_SHA="$EXPECTED_SHA" \
OPENGOTHIC_IOS_EXPECTED_BUILD="$EXPECTED_BUILD" \
  "$BASE_SMOKE" --duration "$DURATION" \
    "${BASE_SMOKE_SCENARIO_ARGS[@]}" \
    --pipeline-archive-test-mode cold \
    --evidence-path-file "$BASE_EVIDENCE_PATH_FILE" "$APP_INPUT"

BASE_EVIDENCE="$(read_base_smoke_evidence \
  "$BASE_EVIDENCE_PATH_FILE" "$EXPECTED_SHA" "$EXPECTED_BUILD")" ||
  fail "base smoke did not return canonical cold evidence path"
[[ -f "$BASE_EVIDENCE/result.txt" ]] ||
  fail "base smoke did not produce cold result evidence"
rg -Fx 'result=PASS' "$BASE_EVIDENCE/result.txt" >/dev/null ||
  fail "base cold smoke did not pass"
ditto "$BASE_EVIDENCE_PATH_FILE" "$OUT/cold/base-smoke-evidence-path.txt"
for name in log.txt stderr.log device-selection.log result.txt; do
  [[ -f "$BASE_EVIDENCE/$name" ]] || continue
  ditto "$BASE_EVIDENCE/$name" "$OUT/cold/$name"
done
assert_stopped "cold-after-base-smoke" "$OUT/cold/process-state.txt"
validate_phase_log cold "$OUT/cold"
copy_cache_evidence "$OUT/cold" cold
{
  echo "result=PASS"
  echo "phase=cold"
  echo "scenario=$SCENARIO"
  echo "save_slot=$SCENARIO_SAVE_SLOT"
  echo "device_process_stopped=1"
  echo "log_sha256=$(shasum -a 256 "$OUT/cold/log.txt" | awk '{print $1}')"
} >"$OUT/cold/phase-result.txt"

if ((BASELINE_ONLY != 0)); then
  CURRENT_PHASE="baseline-final-scan"
  stop_running_app 1 || fail "baseline final application cleanup failed"
  record_zero_scan baseline-final "$OUT/final-process-state.txt"
  verify_existing_game_data after "$OUT/final-game-data-preflight.txt"
  ditto "$WORK/device-selection.log" "$OUT/device-selection.log"
  {
    echo "result=PASS"
    echo "source_sha=$EXPECTED_SHA"
    echo "bundle_id=$BUNDLE_ID"
    echo "scenario=$SCENARIO"
    echo "save_slot=$SCENARIO_SAVE_SLOT"
    echo "baseline=PASS"
    echo "install_count=1"
    echo "uninstall_count=0"
    echo "remote_mutating_copy_count=0"
    echo "device_process_stopped=1"
    echo "timing_used_as_pass_criterion=0"
  } >"$OUT/result.txt"
  PROTOCOL_PASSED=1
  publish_evidence_path "$OUT"
  echo "PASS — D-041 save baseline archive; app stopped"
  echo "evidence: $OUT"
  exit 0
fi

run_direct_phase() {
  local phase="$1"
  local test_mode="${2:-}"
  local phase_dir="$OUT/$phase"
  local before_crash_sha=""
  local after_crash_sha=""
  local count
  local launch_args=(-nomenu)

  if ((NEW_GAME == 0)); then
    launch_args+=(-save "$SAVE_SLOT")
  fi
  if [[ -n "$test_mode" ]]; then
    launch_args+=("-renderer-ios-pipeline-archive-$test_mode")
  fi

  mkdir -p "$phase_dir"
  assert_stopped "$phase-before-launch" "$phase_dir/process-state.txt"
  copy_from_optional Documents/crash.log \
    "$phase_dir/crash-before.log" "$phase-crash-before" || true
  before_crash_sha="$(crash_sha "$phase_dir/crash-before.log")"

  echo "== D-041 $phase: direct launch, no install =="
  CURRENT_PHASE="$phase-running"
  if ! xcrun devicectl device process launch --device "$DEVICE" \
      --terminate-existing -- "$BUNDLE_ID" "${launch_args[@]}" \
      >"$phase_dir/launch.log" 2>&1; then
    if rg -q 'Locked|could not be unlocked' "$phase_dir/launch.log"; then
      fail "device is locked during $phase"
    fi
    fail "$phase application launch failed"
  fi
  sleep "$DURATION"

  count="$(process_count "$phase-alive")" ||
    fail "could not scan live process during $phase"
  [[ "$count" == 1 ]] ||
    fail "$phase did not keep exactly one application process alive"
  echo "game_processes_during_window=1" >>"$phase_dir/process-state.txt"

  stop_running_app 1 || fail "$phase application cleanup failed"
  record_zero_scan "$phase-after-window" "$phase_dir/process-state.txt"
  pull_runtime_logs "$phase_dir"
  after_crash_sha="$(crash_sha "$phase_dir/crash.log")"
  if [[ -n "$after_crash_sha" && "$after_crash_sha" != "$before_crash_sha" ]]; then
    fail "crash.log changed during $phase"
  fi

  validate_phase_log "$phase" "$phase_dir"
  copy_cache_evidence "$phase_dir" "$phase"
  {
    echo "result=PASS"
    echo "phase=$phase"
    echo "test_mode=${test_mode:-none}"
    echo "duration_seconds=$DURATION"
    echo "scenario=$SCENARIO"
    echo "save_slot=$SCENARIO_SAVE_SLOT"
    echo "device_process_stopped=1"
    echo "pre_crash_sha256=$before_crash_sha"
    echo "post_crash_sha256=$after_crash_sha"
    echo "log_sha256=$(shasum -a 256 "$phase_dir/log.txt" | awk '{print $1}')"
  } >"$phase_dir/phase-result.txt"
}

run_direct_phase warm
cmp "$OUT/cold/$ARCHIVE_NAME" "$OUT/warm/$ARCHIVE_NAME" >/dev/null ||
  fail "warm launch unexpectedly changed the serialized cold archive"
echo "archive_unchanged_from_cold=1" >>"$OUT/warm/cache-after.txt"

echo "== D-041 corrupt: app-owned exact invalid payload =="
run_direct_phase corrupt corrupt

run_direct_phase recovery-warm
cmp "$OUT/corrupt/$ARCHIVE_NAME" \
  "$OUT/recovery-warm/$ARCHIVE_NAME" >/dev/null ||
  fail "recovery warm launch unexpectedly changed the rebuilt archive"
echo "archive_unchanged_from_corrupt_rebuild=1" \
  >>"$OUT/recovery-warm/cache-after.txt"

CURRENT_PHASE="final-scan"
stop_running_app 1 || fail "final application cleanup failed"
record_zero_scan final "$OUT/final-process-state.txt"
verify_existing_game_data after "$OUT/final-game-data-preflight.txt"
ditto "$WORK/device-selection.log" "$OUT/device-selection.log"

{
  echo "result=PASS"
  echo "source_sha=$EXPECTED_SHA"
  echo "bundle_id=$BUNDLE_ID"
  echo "scenario=$SCENARIO"
  echo "save_slot=$SCENARIO_SAVE_SLOT"
  echo "duration_seconds_per_phase=$DURATION"
  echo "device_selection_attempts=$DEVICE_SELECTION_ATTEMPTS_USED"
  echo "device_selection_method=$DEVICE_SELECTION_METHOD"
  echo "metallib_sha256=$METALLIB_SHA"
  echo "cold=PASS"
  echo "warm=PASS"
  echo "corrupt=PASS"
  echo "recovery_warm=PASS"
  echo "install_count=1"
  echo "uninstall_count=0"
  echo "remote_mutating_copy_count=0"
  echo "app_owned_cache_test_modes=2"
  echo "device_process_stopped=1"
  echo "timing_used_as_pass_criterion=0"
} >"$OUT/result.txt"

PROTOCOL_PASSED=1
publish_evidence_path "$OUT"
echo "PASS — D-041 cold/warm/corrupt/recovery-warm; app stopped"
echo "evidence: $OUT"
