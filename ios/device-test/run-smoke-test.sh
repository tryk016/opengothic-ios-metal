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
#   ... --require-resource-allocator-self-test APP
#   ... --pipeline-archive-test-mode cold APP
#   ... --expected-fault post-submit-suboptimal APP
#   ... --expected-fault preview-fence-error-after-terminal APP
#   ... --expected-fault frame-fence-error-after-terminal APP
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
REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=0
PIPELINE_ARCHIVE_TEST_MODE=""
EXPECTED_FAULT="none"
EVIDENCE_PATH_FILE=""
SELF_TEST=0
APP_INPUT=""
readonly DURABLE_ZERO_MAX_CYCLES=3
readonly DURABLE_ZERO_SCANS_PER_CYCLE=10
readonly DURABLE_ZERO_INTERVAL_SECONDS=10
readonly DURABLE_ZERO_REQUIRED_STABLE_SECONDS=90
readonly RESOURCE_ALLOCATOR_SELF_TEST_PREFIX='RendererIOS resource allocator self-test:'
readonly RESOURCE_ALLOCATOR_SELF_TEST_ARMED='RendererIOS resource allocator self-test: ARMED case=private-memoryless-4x4-rgba8-v1'
readonly RESOURCE_ALLOCATOR_SELF_TEST_PASS='RendererIOS resource allocator self-test: PASS case=private-memoryless-4x4-rgba8-v1 allocation-only=1 encoded=0 render-pass=0 submitted=0 created=2 live=0 released=2'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

smoke_evidence_path() {
  local outcome="$1"
  local timestamp="$2"
  local process_id="$3"
  local expected_sha="$4"
  local expected_build="$5"
  local expected_fault="$6"
  local evidence_root

  [[ "$outcome" == pass || "$outcome" == failure ]] || return 1
  if ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST != 0)); then
    printf '%s/build/device-self-test/%s/resource-allocator/%s-%s-%s\n' \
      "$ROOT" "$expected_build" "$outcome" "$timestamp" "$process_id"
    return 0
  fi
  if [[ "$expected_fault" == none && "$expected_build" == "$expected_sha" ]]; then
    evidence_root="$ROOT/build/device-smoke/$expected_sha"
    if [[ "$outcome" == pass ]]; then
      printf '%s\n' "$evidence_root"
    else
      printf '%s/failure-%s-%s\n' "$evidence_root" "$timestamp" "$process_id"
    fi
  else
    printf '%s/build/device-fault/%s/%s/%s-%s-%s\n' \
      "$ROOT" "$expected_build" "$expected_fault" \
      "$outcome" "$timestamp" "$process_id"
  fi
}

publish_evidence_path() {
  local path="$1"

  [[ -n "$EVIDENCE_PATH_FILE" ]] || return 0
  [[ "$EVIDENCE_PATH_FILE" == /* ]] ||
    fail "evidence path file must be absolute"
  [[ -d "$(dirname "$EVIDENCE_PATH_FILE")" ]] ||
    fail "evidence path file parent does not exist"
  printf '%s\n' "$path" >"$EVIDENCE_PATH_FILE"
}

crash_listing_state() {
  local listing="$1"

  python3 - "$listing" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
files = payload.get("result", {}).get("files")
if not isinstance(files, list):
    raise SystemExit("crash listing provider returned no files array")
matches = [entry for entry in files if entry.get("name") == "crash.log"]
if len(matches) > 1:
    raise SystemExit("crash listing contains duplicate crash.log entries")
if not matches:
    print("missing")
    raise SystemExit(0)
resources = matches[0].get("resources", {})
if (
    resources.get("isDirectory") is not False
    or resources.get("isSymbolicLink") is not False
):
    raise SystemExit("crash.log listing is not a regular non-symlink file")
print("present")
PY
}

validate_resource_allocator_binary_profile() {
  local strings_file="$1"

  [[ -f "$strings_file" ]] || return 1
  if ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST != 0)); then
    [[ "$(grep -Fxc "$RESOURCE_ALLOCATOR_SELF_TEST_ARMED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$RESOURCE_ALLOCATOR_SELF_TEST_PASS" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    return 0
  fi
  ! grep -Fq "$RESOURCE_ALLOCATOR_SELF_TEST_PREFIX" "$strings_file"
}

run_host_contract_self_test() {
  local expected_sha="${OPENGOTHIC_IOS_EXPECTED_SHA:-0123456789abcdef0123456789abcdef01234567}"
  local expected_build="${OPENGOTHIC_IOS_EXPECTED_BUILD:-${expected_sha}-local}"
  local expected_fault="${OPENGOTHIC_IOS_EXPECTED_FAULT:-none}"
  local timestamp="${OPENGOTHIC_IOS_EVIDENCE_TIMESTAMP:-20000101T000000Z}"
  local process_id="${OPENGOTHIC_IOS_EVIDENCE_PID:-4242}"
  local self_test_work evidence_file actual expected expected_plain expected_resource
  local plain_path resource_path resource_failure_path resource_committed_path
  local plain_binary self_test_binary duplicate_binary
  local requested_resource_allocator_self_test="$REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST"

  [[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] ||
    fail "self-test expected SHA is invalid"
  [[ "$expected_build" == "$expected_sha" ||
     "$expected_build" == "$expected_sha-local" ]] ||
    fail "self-test expected build is not source-bound"
  [[ "$expected_fault" == none ||
     "$expected_fault" == post-submit-suboptimal ||
     "$expected_fault" == preview-fence-error-after-terminal ||
     "$expected_fault" == frame-fence-error-after-terminal ]] ||
    fail "self-test expected fault is invalid"
  [[ "$timestamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
    fail "self-test evidence timestamp is invalid"
  [[ "$process_id" =~ ^[0-9]+$ ]] ||
    fail "self-test evidence process id is invalid"
  ((requested_resource_allocator_self_test == 0)) || [[ "$expected_fault" == none ]] ||
    fail "resource allocator host contract self-test requires expected fault none"

  self_test_work="$(mktemp -d -t opengothic-smoke-contract)"
  evidence_file="$EVIDENCE_PATH_FILE"
  [[ -n "$evidence_file" ]] || evidence_file="$self_test_work/evidence-path.txt"
  EVIDENCE_PATH_FILE="$evidence_file"
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=0
  plain_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" "$expected_fault")"
  if [[ "$expected_fault" == none && "$expected_build" == "$expected_sha" ]]; then
    expected_plain="$ROOT/build/device-smoke/$expected_sha"
  else
    expected_plain="$ROOT/build/device-fault/$expected_build/$expected_fault/pass-$timestamp-$process_id"
  fi
  [[ "$plain_path" == "$expected_plain" ]] ||
    fail "SHA-local smoke evidence path self-test failed"
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=1
  resource_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  expected_resource="$ROOT/build/device-self-test/$expected_build/resource-allocator/pass-$timestamp-$process_id"
  [[ "$resource_path" == "$expected_resource" ]] ||
    fail "resource allocator smoke evidence path self-test failed"
  [[ "$resource_path" != "$plain_path" ]] ||
    fail "resource allocator and plain smoke evidence paths overlap"
  resource_failure_path="$(smoke_evidence_path failure "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  [[ "$resource_failure_path" == \
     "$ROOT/build/device-self-test/$expected_build/resource-allocator/failure-$timestamp-$process_id" ]] ||
    fail "resource allocator failure evidence path self-test failed"
  resource_committed_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_sha" none)"
  [[ "$resource_committed_path" == \
     "$ROOT/build/device-self-test/$expected_sha/resource-allocator/pass-$timestamp-$process_id" ]] ||
    fail "committed resource allocator evidence path self-test failed"
  [[ "$resource_committed_path" != "$ROOT/build/device-smoke/$expected_sha" ]] ||
    fail "committed resource allocator evidence overlaps plain committed smoke"
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST="$requested_resource_allocator_self_test"
  actual="$plain_path"
  expected="$expected_plain"
  if ((requested_resource_allocator_self_test != 0)); then
    actual="$resource_path"
    expected="$expected_resource"
  fi
  publish_evidence_path "$actual"
  [[ "$(cat "$evidence_file")" == "$expected" ]] ||
    fail "smoke evidence path publication self-test failed"

  plain_binary="$self_test_work/plain-binary.txt"
  self_test_binary="$self_test_work/resource-allocator-binary.txt"
  duplicate_binary="$self_test_work/resource-allocator-duplicate-binary.txt"
  printf '%s\n' 'RendererIOS diagnostics: ON' >"$plain_binary"
  printf '%s\n%s\n%s\n' \
    "$RESOURCE_ALLOCATOR_SELF_TEST_ARMED" \
    "$RESOURCE_ALLOCATOR_SELF_TEST_PASS" \
    "$RESOURCE_ALLOCATOR_SELF_TEST_PREFIX FAIL case=fixture" \
    >"$self_test_binary"
  printf '%s\n%s\n%s\n' \
    "$RESOURCE_ALLOCATOR_SELF_TEST_ARMED" \
    "$RESOURCE_ALLOCATOR_SELF_TEST_ARMED" \
    "$RESOURCE_ALLOCATOR_SELF_TEST_PASS" \
    >"$duplicate_binary"
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=0
  validate_resource_allocator_binary_profile "$plain_binary" ||
    fail "plain binary profile self-test failed"
  if validate_resource_allocator_binary_profile "$self_test_binary"; then
    fail "unrequested resource allocator binary profile survived"
  fi
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=1
  validate_resource_allocator_binary_profile "$self_test_binary" ||
    fail "resource allocator binary profile self-test failed"
  if validate_resource_allocator_binary_profile "$plain_binary"; then
    fail "resource allocator binary profile accepted a plain artifact"
  fi
  if validate_resource_allocator_binary_profile "$duplicate_binary"; then
    fail "duplicate resource allocator binary marker survived"
  fi
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST="$requested_resource_allocator_self_test"

  printf '%s\n' '{"result":{"files":[]}}' >"$self_test_work/missing.json"
  printf '%s\n' \
    '{"result":{"files":[{"name":"crash.log","resources":{"isDirectory":false,"isSymbolicLink":false}}]}}' \
    >"$self_test_work/present.json"
  printf '%s\n' '{"providerError":"unavailable"}' \
    >"$self_test_work/provider-error.json"
  [[ "$(crash_listing_state "$self_test_work/missing.json")" == missing ]] ||
    fail "missing crash state self-test failed"
  [[ "$(crash_listing_state "$self_test_work/present.json")" == present ]] ||
    fail "present crash state self-test failed"
  if crash_listing_state "$self_test_work/provider-error.json" >/dev/null 2>&1; then
    fail "provider-error crash state self-test survived"
  fi

  find "$self_test_work" -type f -delete
  rmdir "$self_test_work"
  echo "smoke host contract self-test passed: fault=$expected_fault build=$expected_build profiles=plain,resource-allocator crash-states=3"
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
    --require-resource-allocator-self-test)
      REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=1
      shift
      ;;
    --pipeline-archive-test-mode)
      PIPELINE_ARCHIVE_TEST_MODE="${2:?missing pipeline archive test mode}"
      shift 2
      ;;
    --expected-fault)
      EXPECTED_FAULT="${2:?missing expected fault}"
      shift 2
      ;;
    --evidence-path-file)
      EVIDENCE_PATH_FILE="${2:?missing evidence path file}"
      shift 2
      ;;
    --self-test) SELF_TEST=1; shift ;;
    -*) fail "usage: $0 [--duration seconds] [--save-slot number|--new-game] [--require-bink-self-test|--require-resource-allocator-self-test] [--pipeline-archive-test-mode cold|corrupt] [--expected-fault none|post-submit-suboptimal|preview-fence-error-after-terminal|frame-fence-error-after-terminal] [--evidence-path-file absolute-path] path/to/Gothic2Notr.app | $0 --self-test [--evidence-path-file absolute-path]" ;;
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
[[ "$EXPECTED_FAULT" == none ||
   "$EXPECTED_FAULT" == post-submit-suboptimal ||
   "$EXPECTED_FAULT" == preview-fence-error-after-terminal ||
   "$EXPECTED_FAULT" == frame-fence-error-after-terminal ]] ||
  fail "expected fault must be none, post-submit-suboptimal, preview-fence-error-after-terminal, or frame-fence-error-after-terminal"
[[ "$EXPECTED_FAULT" != preview-fence-error-after-terminal ]] ||
  ((NEW_GAME == 0)) ||
  fail "preview-fence-error-after-terminal requires one numeric load save"
[[ "$EXPECTED_FAULT" != preview-fence-error-after-terminal ]] ||
  ((SAVE_SLOT_EXPLICIT == 1 && SAVE_SLOT == 1)) ||
  fail "preview-fence-error-after-terminal requires explicit --save-slot 1"
[[ "$EXPECTED_FAULT" != preview-fence-error-after-terminal ]] ||
  ((DURATION <= 45)) ||
  fail "preview-fence-error-after-terminal duration must be 10..45 seconds"
[[ "$EXPECTED_FAULT" != frame-fence-error-after-terminal ]] ||
  ((DURATION <= 45)) ||
  fail "frame-fence-error-after-terminal duration must be 10..45 seconds"
((REQUIRE_BINK_SELF_TEST == 0)) || [[ "$EXPECTED_FAULT" == none ]] ||
  fail "Bink self-test requires expected fault none"
((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0)) || [[ "$EXPECTED_FAULT" == none ]] ||
  fail "resource allocator self-test requires expected fault none"
((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0 || REQUIRE_BINK_SELF_TEST == 0)) ||
  fail "resource allocator and Bink self-tests are mutually exclusive"
if ((SELF_TEST != 0)); then
  [[ -z "$APP_INPUT" ]] || fail "--self-test does not accept an app"
  run_host_contract_self_test
  exit 0
fi
if [[ -n "$EVIDENCE_PATH_FILE" ]]; then
  [[ "$EVIDENCE_PATH_FILE" == /* ]] ||
    fail "evidence path file must be absolute"
  [[ -d "$(dirname "$EVIDENCE_PATH_FILE")" ]] ||
    fail "evidence path file parent does not exist"
fi
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
EXPECTED_BUILD=""
RUNTIME_ARMED=0
DEVICE_FOREGROUND_PARKED=0
DEVICE_PROCESS_STOPPED=0
DURABLE_ZERO_CYCLES_USED=0
DURABLE_ZERO_SCANS_ATTEMPTED=0
DURABLE_ZERO_SCANS_COMPLETED=0
DURABLE_ZERO_RESPAWNS_DETECTED=0
DURABLE_ZERO_QUERY_FAILURES=0
DURABLE_ZERO_STABLE=0
DURABLE_ZERO_STABLE_SECONDS=0
DURABLE_ZERO_FINAL_ZERO=0
DURABLE_ZERO_ACTIVE_CYCLE=0
DURABLE_ZERO_ACTIVE_CYCLE_STARTED=0
BATTERY_FALLBACK_ATTEMPTS=0
BATTERY_FALLBACK_FINAL_ZERO=0
STOP_RUNNING_APP_QUERY_FAILED=0
PRE_CRASH_SHA="unqueried"
POST_CRASH_SHA="unqueried"
FAULT_LOG_VALIDATION="not-required"
RESOURCE_ALLOCATOR_SELF_TEST_VALIDATION="not-required"
RESOURCE_ALLOCATOR_SELF_TEST_PID="none"
RESOURCE_ALLOCATOR_SELF_TEST_PID_DISCOVERY_ATTEMPTS=0
RESOURCE_ALLOCATOR_SELF_TEST_PROCESS_SURVIVED=0
PROCESS_SURVIVED_FAULT_WINDOW=0
ID3_SEMANTIC_NONCE="none"
ID3_SAVE_PREFLIGHT_CAPTURED=0
ID3_SAVE_POSTFLIGHT_CAPTURED=0
ID3_SAVE_INTEGRITY_VERIFIED=0
ID3_PROTECTED_SAVES_MATCH=0
ID3_DESTINATION_BYTES=0
ID3_DESTINATION_SHA256="missing"
ID3_DESTINATION_EXISTED=0
ID3_DESTINATION_BEFORE_SHA256="missing"
ID3_DESTINATION_RESTORED=0
ID3_RECOVERY_PATH="none"
ID3_RECOVERY_PRESERVED=0
ID3_FAULT_WINDOW_PID="none"
ID3_PID_DISCOVERY_ATTEMPTS=0
ID3_COMPLETION_OBSERVED=0
ID3_POST_COMPLETION_STABLE_SECONDS=0
PASS_EVIDENCE_DIR=""
APP_EXECUTABLE="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP_INPUT/Info.plist" 2>/dev/null
)" || fail "app has no CFBundleExecutable"
[[ -n "$APP_EXECUTABLE" && "$APP_EXECUTABLE" != */* ]] ||
  fail "invalid CFBundleExecutable"
strings "$APP_INPUT/$APP_EXECUTABLE" |
  rg -Fx 'RendererIOS diagnostics: ON frames-in-flight=' >/dev/null ||
  fail "app is not a diagnostics-enabled RendererIOS build"

list_game_pids() {
  local output="$1"

  xcrun devicectl device info processes --device "$DEVICE" \
    --json-output "$output" >/dev/null 2>>"$WORK/cleanup.log" || return 1
  python3 - "$output" "$APP_EXECUTABLE" 2>>"$WORK/cleanup.log" <<'PY'
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
}

stop_running_app() {
  local strict="${1:-0}"
  local attempt json mode pid pids

  STOP_RUNNING_APP_QUERY_FAILED=0
  [[ -n "$DEVICE" && -n "$APP_EXECUTABLE" ]] || return 0
  for attempt in 1 2 3 4 5; do
    json="$WORK/processes-stop-$(uuidgen).json"
    if ! pids="$(list_game_pids "$json")"; then
      STOP_RUNNING_APP_QUERY_FAILED=1
      [[ "$strict" == 0 ]] ||
        echo "FAIL: could not query processes while stopping $APP_EXECUTABLE" >&2
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

park_settings_foreground() {
  [[ -n "$DEVICE" ]] || return 0
  xcrun devicectl device process launch --device "$DEVICE" \
    --terminate-existing --activate com.apple.Preferences \
    >>"$WORK/park-settings.log" 2>&1 || return 1
  DEVICE_FOREGROUND_PARKED=1
}

write_durable_event_json() {
  local output="$1" cycle="$2" scan="$3" scheduled="$4"
  local elapsed="$5" result="$6" pids="${7:-}"

  python3 - "$output" "$cycle" "$scan" "$scheduled" "$elapsed" \
      "$result" "$pids" <<'PY'
import datetime
import json
import pathlib
import sys

output, cycle, scan, scheduled, elapsed, result, pids = sys.argv[1:]
payload = {
    "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    ),
    "cycle": int(cycle),
    "scan": None if scan == "none" else int(scan),
    "scheduled_elapsed_seconds": (
        None if scheduled == "none" else int(scheduled)
    ),
    "elapsed_seconds": int(elapsed),
    "result": result,
    "process_count": len([pid for pid in pids.splitlines() if pid]),
}
pathlib.Path(output).write_text(json.dumps(payload, sort_keys=True) + "\n")
PY
}

write_durable_cycle_json() {
  local cycle="$1" elapsed="$2" result="$3"

  python3 - "$WORK/durable-zero-cycle-$cycle-summary.json" \
      "$cycle" "$elapsed" "$result" "$DURABLE_ZERO_STABLE_SECONDS" \
      "$DURABLE_ZERO_FINAL_ZERO" <<'PY'
import datetime
import json
import pathlib
import sys

output, cycle, elapsed, result, stable_seconds, final_zero = sys.argv[1:]
payload = {
    "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    ),
    "cycle": int(cycle),
    "elapsed_seconds": int(elapsed),
    "result": result,
    "stable_seconds": int(stable_seconds),
    "final_zero": int(final_zero),
}
pathlib.Path(output).write_text(json.dumps(payload, sort_keys=True) + "\n")
PY
}

run_battery_safety_fallback() {
  local attempt elapsed fallback_started park_ok=0 pids result stop_ok=0

  BATTERY_FALLBACK_ATTEMPTS=$((BATTERY_FALLBACK_ATTEMPTS+1))
  attempt="$BATTERY_FALLBACK_ATTEMPTS"
  fallback_started=$SECONDS
  BATTERY_FALLBACK_FINAL_ZERO=0
  DEVICE_PROCESS_STOPPED=0
  DEVICE_FOREGROUND_PARKED=0
  result=stop-failure
  if stop_running_app 1; then
    stop_ok=1
  elif ((STOP_RUNNING_APP_QUERY_FAILED != 0)); then
    DURABLE_ZERO_QUERY_FAILURES=$((DURABLE_ZERO_QUERY_FAILURES+1))
    result=query-failure
  fi
  if park_settings_foreground; then
    park_ok=1
  else
    result=park-failure
  fi
  if pids="$(list_game_pids \
      "$WORK/processes-durable-zero-battery-fallback-$attempt-final.json")"; then
    if [[ -z "$pids" ]]; then
      BATTERY_FALLBACK_FINAL_ZERO=1
      result=zero
    elif [[ -n "$pids" ]]; then
      DURABLE_ZERO_RESPAWNS_DETECTED=$((DURABLE_ZERO_RESPAWNS_DETECTED+1))
      DEVICE_FOREGROUND_PARKED=0
      result=respawn
    fi
  else
    DURABLE_ZERO_QUERY_FAILURES=$((DURABLE_ZERO_QUERY_FAILURES+1))
    DEVICE_FOREGROUND_PARKED=0
    result=query-failure
  fi
  elapsed=$((SECONDS-fallback_started))
  write_durable_event_json \
    "$WORK/durable-zero-battery-fallback-$attempt-final.json" \
    0 none none "$elapsed" "$result" "${pids:-}" || true
  echo "durable-zero battery-fallback=$attempt stop-ok=$stop_ok park-ok=$park_ok elapsed-seconds=$elapsed result=$result" \
    >>"$WORK/cleanup.log"
  [[ "$BATTERY_FALLBACK_FINAL_ZERO" == 1 ]]
}

ensure_durable_zero() {
  local cycle scan scheduled_elapsed wait_seconds cycle_attempt_started
  local cycle_started elapsed
  local pids result stable

  if ((DURABLE_ZERO_STABLE != 0 &&
       DURABLE_ZERO_STABLE_SECONDS >= DURABLE_ZERO_REQUIRED_STABLE_SECONDS &&
       DURABLE_ZERO_FINAL_ZERO != 0)); then
    DEVICE_PROCESS_STOPPED=1
    return 0
  fi
  [[ -n "$DEVICE" && -n "$APP_EXECUTABLE" ]] || return 1
  DEVICE_PROCESS_STOPPED=0

  while ((DURABLE_ZERO_CYCLES_USED < DURABLE_ZERO_MAX_CYCLES)); do
    cycle=$((DURABLE_ZERO_CYCLES_USED+1))
    DURABLE_ZERO_CYCLES_USED=$cycle
    DURABLE_ZERO_STABLE=0
    DURABLE_ZERO_STABLE_SECONDS=0
    DURABLE_ZERO_FINAL_ZERO=0
    DEVICE_FOREGROUND_PARKED=0
    cycle_attempt_started=$SECONDS
    DURABLE_ZERO_ACTIVE_CYCLE=$cycle
    DURABLE_ZERO_ACTIVE_CYCLE_STARTED=$cycle_attempt_started
    write_durable_cycle_json "$cycle" 0 started || true

    if ! stop_running_app 1; then
      result=stop-failure
      if ((STOP_RUNNING_APP_QUERY_FAILED != 0)); then
        DURABLE_ZERO_QUERY_FAILURES=$((DURABLE_ZERO_QUERY_FAILURES+1))
        result=query-failure
      fi
      elapsed=$((SECONDS-cycle_attempt_started))
      write_durable_cycle_json "$cycle" "$elapsed" "$result" || true
      DURABLE_ZERO_ACTIVE_CYCLE=0
      echo "durable-zero cycle=$cycle phase=stop elapsed-seconds=$elapsed result=$result" \
        >>"$WORK/cleanup.log"
      continue
    fi
    if ! park_settings_foreground; then
      elapsed=$((SECONDS-cycle_attempt_started))
      write_durable_cycle_json "$cycle" "$elapsed" park-failure || true
      DURABLE_ZERO_ACTIVE_CYCLE=0
      echo "durable-zero cycle=$cycle phase=park elapsed-seconds=$elapsed result=failure" \
        >>"$WORK/cleanup.log"
      continue
    fi

    # The durable window starts only after strict stop and Settings activation.
    # Its ten scans are scheduled at t=0,10,...,90 seconds from this point.
    cycle_started=$SECONDS
    DURABLE_ZERO_ACTIVE_CYCLE_STARTED=$cycle_started
    stable=1
    for ((scan=1; scan<=DURABLE_ZERO_SCANS_PER_CYCLE; ++scan)); do
      scheduled_elapsed=$(((scan-1)*DURABLE_ZERO_INTERVAL_SECONDS))
      wait_seconds=$((scheduled_elapsed-(SECONDS-cycle_started)))
      ((wait_seconds <= 0)) || sleep "$wait_seconds"
      elapsed=$((SECONDS-cycle_started))
      DURABLE_ZERO_SCANS_ATTEMPTED=$((DURABLE_ZERO_SCANS_ATTEMPTED+1))
      if ! pids="$(list_game_pids \
          "$WORK/processes-durable-zero-cycle-$cycle-scan-$scan.json")"; then
        DURABLE_ZERO_QUERY_FAILURES=$((DURABLE_ZERO_QUERY_FAILURES+1))
        DEVICE_FOREGROUND_PARKED=0
        stable=0
        write_durable_event_json \
          "$WORK/durable-zero-cycle-$cycle-scan-$scan.json" \
          "$cycle" "$scan" "$scheduled_elapsed" "$elapsed" \
          query-failure || true
        result=query-failure
        break
      fi
      DURABLE_ZERO_SCANS_COMPLETED=$((DURABLE_ZERO_SCANS_COMPLETED+1))
      if [[ -n "$pids" ]]; then
        DURABLE_ZERO_RESPAWNS_DETECTED=$((DURABLE_ZERO_RESPAWNS_DETECTED+1))
        DEVICE_FOREGROUND_PARKED=0
        stable=0
        write_durable_event_json \
          "$WORK/durable-zero-cycle-$cycle-scan-$scan.json" \
          "$cycle" "$scan" "$scheduled_elapsed" "$elapsed" respawn "$pids" || true
        result=respawn
        break
      fi
      DURABLE_ZERO_STABLE_SECONDS=$elapsed
      write_durable_event_json \
        "$WORK/durable-zero-cycle-$cycle-scan-$scan.json" \
        "$cycle" "$scan" "$scheduled_elapsed" "$elapsed" zero || {
          DEVICE_FOREGROUND_PARKED=0
          stable=0
          result=evidence-write-failure
          break
        }
      echo "durable-zero cycle=$cycle scan=$scan scheduled-seconds=$scheduled_elapsed elapsed-seconds=$elapsed result=zero" \
        >>"$WORK/cleanup.log"
    done

    if ((stable == 0)); then
      elapsed=$((SECONDS-cycle_started))
      write_durable_cycle_json "$cycle" "$elapsed" "$result" || true
      DURABLE_ZERO_ACTIVE_CYCLE=0
      echo "durable-zero cycle=$cycle elapsed-seconds=$elapsed result=$result" \
        >>"$WORK/cleanup.log"
      continue
    fi

    wait_seconds=$((DURABLE_ZERO_REQUIRED_STABLE_SECONDS-(SECONDS-cycle_started)))
    ((wait_seconds <= 0)) || sleep "$wait_seconds"
    elapsed=$((SECONDS-cycle_started))
    DURABLE_ZERO_STABLE_SECONDS=$elapsed
    if ! pids="$(list_game_pids \
        "$WORK/processes-durable-zero-cycle-$cycle-final.json")"; then
      DURABLE_ZERO_QUERY_FAILURES=$((DURABLE_ZERO_QUERY_FAILURES+1))
      DEVICE_FOREGROUND_PARKED=0
      result=query-failure
    elif [[ -n "$pids" ]]; then
      DURABLE_ZERO_RESPAWNS_DETECTED=$((DURABLE_ZERO_RESPAWNS_DETECTED+1))
      DEVICE_FOREGROUND_PARKED=0
      result=respawn
    else
      result=zero
    fi
    if [[ "$result" == zero ]] &&
       ((elapsed < DURABLE_ZERO_REQUIRED_STABLE_SECONDS)); then
      result=stable-window-too-short
    fi
    write_durable_event_json \
      "$WORK/durable-zero-cycle-$cycle-final.json" \
      "$cycle" none none "$elapsed" "$result" "${pids:-}" || {
        DEVICE_FOREGROUND_PARKED=0
        result=evidence-write-failure
      }
    if [[ "$result" == zero ]]; then
      DURABLE_ZERO_STABLE=1
      DURABLE_ZERO_FINAL_ZERO=1
      DEVICE_PROCESS_STOPPED=1
      write_durable_cycle_json "$cycle" "$elapsed" pass || true
      DURABLE_ZERO_ACTIVE_CYCLE=0
      echo "durable-zero cycle=$cycle stable-seconds=$DURABLE_ZERO_STABLE_SECONDS final-zero=1 result=pass" \
        >>"$WORK/cleanup.log"
      return 0
    fi
    write_durable_cycle_json "$cycle" "$elapsed" "$result" || true
    DURABLE_ZERO_ACTIVE_CYCLE=0
    echo "durable-zero cycle=$cycle stable-seconds=$DURABLE_ZERO_STABLE_SECONDS final-zero=0 result=$result" \
      >>"$WORK/cleanup.log"
  done

  DURABLE_ZERO_STABLE=0
  DURABLE_ZERO_FINAL_ZERO=0
  DEVICE_PROCESS_STOPPED=0
  run_battery_safety_fallback || true
  return 1
}

write_durable_result_fields() {
  echo "device_process_stopped=$DEVICE_PROCESS_STOPPED"
  echo "device_foreground_parked=$DEVICE_FOREGROUND_PARKED"
  echo "durable_zero_max_cycles=$DURABLE_ZERO_MAX_CYCLES"
  echo "durable_zero_scans_per_cycle=$DURABLE_ZERO_SCANS_PER_CYCLE"
  echo "durable_zero_interval_seconds=$DURABLE_ZERO_INTERVAL_SECONDS"
  echo "durable_zero_required_stable_seconds=$DURABLE_ZERO_REQUIRED_STABLE_SECONDS"
  echo "durable_zero_cycles_used=$DURABLE_ZERO_CYCLES_USED"
  echo "durable_zero_scans_attempted=$DURABLE_ZERO_SCANS_ATTEMPTED"
  echo "durable_zero_scans_completed=$DURABLE_ZERO_SCANS_COMPLETED"
  echo "durable_zero_respawns_detected=$DURABLE_ZERO_RESPAWNS_DETECTED"
  echo "durable_zero_query_failures=$DURABLE_ZERO_QUERY_FAILURES"
  echo "durable_zero_stable=$DURABLE_ZERO_STABLE"
  echo "durable_zero_stable_seconds=$DURABLE_ZERO_STABLE_SECONDS"
  echo "durable_zero_final_zero=$DURABLE_ZERO_FINAL_ZERO"
  echo "battery_fallback_attempts=$BATTERY_FALLBACK_ATTEMPTS"
  echo "battery_fallback_final_zero=$BATTERY_FALLBACK_FINAL_ZERO"
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

capture_crash_state() {
  local label="$1"
  local destination="$2"
  local variable="$3"
  local listing="$WORK/crash-listing-$label.json"
  local state sha

  rm -f "$listing" "$destination"
  if ! xcrun devicectl device info files --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --username mobile --subdirectory Documents --no-recurse \
      --json-output "$listing" >/dev/null; then
    printf -v "$variable" '%s' "query-error"
    return 1
  fi
  if ! state="$(crash_listing_state "$listing")"; then
    printf -v "$variable" '%s' "provider-error"
    return 1
  fi
  if [[ "$state" == missing ]]; then
    printf -v "$variable" '%s' "missing"
    return 0
  fi
  [[ "$state" == present ]] || {
    printf -v "$variable" '%s' "provider-error"
    return 1
  }
  if ! xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
      --source Documents/crash.log --destination "$destination" >/dev/null; then
    printf -v "$variable" '%s' "copy-error"
    return 1
  fi
  [[ -f "$destination" ]] || {
    printf -v "$variable" '%s' "copy-error"
    return 1
  }
  sha="$(shasum -a 256 "$destination" | awk '{print $1}')"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || {
    printf -v "$variable" '%s' "hash-error"
    return 1
  }
  printf -v "$variable" '%s' "$sha"
}

create_id3_recovery_path() {
  local recovery_root timestamp

  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  [[ "$ID3_RECOVERY_PATH" == none ]] || return 0
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  recovery_root="$ROOT/build/private-device-recovery/id3/$EXPECTED_BUILD"
  (umask 077 && mkdir -p "$recovery_root") || return 1
  ID3_RECOVERY_PATH="$(mktemp -d "$recovery_root/$timestamp-$$.XXXXXX")" || return 1
  [[ "$ID3_RECOVERY_PATH" == "$recovery_root"/* &&
     "$ID3_RECOVERY_PATH" != "$WORK"* ]] || return 1
  chmod 700 "$ID3_RECOVERY_PATH" || return 1
}

sync_id3_recovery_artifacts() {
  local candidate destination manifest="$WORK/id3-recovery-files.sha256"

  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  [[ "$ID3_RECOVERY_PATH" != none && -d "$ID3_RECOVERY_PATH" ]] || return 1
  for candidate in \
      id3-saves-before.json id3-protected-before.sha256 \
      id3-before-save_slot_1.sav id3-before-save_slot_2.sav \
      id3-before-save_slot_3.sav id3-before-save_slot_4.sav \
      id3-destination-before.sav \
      id3-saves-after.json id3-protected-after.sha256 \
      id3-after-save_slot_1.sav id3-after-save_slot_2.sav \
      id3-after-save_slot_3.sav id3-after-save_slot_4.sav \
      save_slot_20.sav id3-destination-restore-check.sav; do
    [[ -f "$WORK/$candidate" ]] || continue
    destination="$ID3_RECOVERY_PATH/$candidate"
    ditto "$WORK/$candidate" "$destination" || return 1
    chmod 600 "$destination" || return 1
  done
  : >"$manifest"
  for candidate in "$ID3_RECOVERY_PATH"/*; do
    [[ -f "$candidate" && "$(basename "$candidate")" != recovery-files.sha256 ]] ||
      continue
    printf '%s  %s\n' \
      "$(shasum -a 256 "$candidate" | awk '{print $1}')" \
      "$(basename "$candidate")" >>"$manifest"
  done
  [[ -s "$manifest" ]] || return 1
  ditto "$manifest" "$ID3_RECOVERY_PATH/recovery-files.sha256" || return 1
  chmod 600 "$ID3_RECOVERY_PATH/recovery-files.sha256" || return 1
}

preserve_id3_recovery_if_present() {
  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  if [[ "$ID3_RECOVERY_PATH" != none && -d "$ID3_RECOVERY_PATH" ]]; then
    ID3_RECOVERY_PRESERVED=1
    return 0
  fi
  return 1
}

release_id3_recovery_if_safe() {
  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  ((ID3_SAVE_POSTFLIGHT_CAPTURED == 1 &&
    ID3_SAVE_INTEGRITY_VERIFIED == 1 &&
    ID3_PROTECTED_SAVES_MATCH == 1 &&
    ID3_DESTINATION_EXISTED == ID3_DESTINATION_RESTORED)) || return 1
  [[ "$ID3_RECOVERY_PATH" != none &&
     "$ID3_RECOVERY_PATH" == "$ROOT"/build/private-device-recovery/id3/* &&
     -d "$ID3_RECOVERY_PATH" ]] || return 1
  find "$ID3_RECOVERY_PATH" -type f -delete || return 1
  rmdir "$ID3_RECOVERY_PATH" || return 1
  ID3_RECOVERY_PATH="none"
  ID3_RECOVERY_PRESERVED=0
}

capture_id3_save_preflight() {
  local listing="$WORK/id3-saves-before.json"
  local slot destination manifest="$WORK/id3-protected-before.sha256"

  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$listing" >/dev/null || return 1
  ID3_DESTINATION_EXISTED="$(python3 - "$listing" <<'PY'
import json, re, sys
files = json.load(open(sys.argv[1]))["result"]["files"]
save_entries = [
    entry for entry in files
    if re.fullmatch(r"save_slot_[0-9]+\.sav", str(entry.get("name", "")))
]
by_name = {entry.get("name"): entry for entry in save_entries}
if len(by_name) != len(save_entries):
    raise SystemExit("duplicate save slot entry before ID3")
expected = {f"save_slot_{slot}.sav" for slot in range(1, 5)}
allowed = expected | ({"save_slot_20.sav"} if "save_slot_20.sav" in by_name else set())
if set(by_name) != allowed:
    raise SystemExit("pre-ID3 save set is not exactly slots 1..4 plus optional slot 20")
for name in allowed:
    resources = by_name[name].get("resources", {})
    if resources.get("isDirectory") is not False or resources.get("isSymbolicLink") is not False:
        raise SystemExit(f"ID3 preflight save is not a regular file: {name}")
print(1 if "save_slot_20.sav" in by_name else 0)
PY
  )" || return 1
  [[ "$ID3_DESTINATION_EXISTED" == 0 || "$ID3_DESTINATION_EXISTED" == 1 ]] || return 1
  if ((ID3_DESTINATION_EXISTED == 1)); then
    xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
      --source Documents/save_slot_20.sav \
      --destination "$WORK/id3-destination-before.sav" >/dev/null || return 1
    [[ -s "$WORK/id3-destination-before.sav" ]] || return 1
    ID3_DESTINATION_BEFORE_SHA256="$(
      shasum -a 256 "$WORK/id3-destination-before.sav" | awk '{print $1}'
    )"
    [[ "$ID3_DESTINATION_BEFORE_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  : >"$manifest"
  for slot in 1 2 3 4; do
    destination="$WORK/id3-before-save_slot_$slot.sav"
    xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
      --source "Documents/save_slot_$slot.sav" --destination "$destination" \
      >/dev/null || return 1
    [[ -s "$destination" ]] || return 1
    printf '%s  save_slot_%s.sav\n' \
      "$(shasum -a 256 "$destination" | awk '{print $1}')" "$slot" >>"$manifest"
  done
  create_id3_recovery_path || return 1
  sync_id3_recovery_artifacts || return 1
  ID3_SAVE_PREFLIGHT_CAPTURED=1
}

restore_id3_destination_if_needed() {
  local backup backup_sha restored_sha

  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  ((ID3_SAVE_PREFLIGHT_CAPTURED == 1)) || return 1
  ((ID3_SAVE_POSTFLIGHT_CAPTURED == 1)) || return 1
  ((ID3_DESTINATION_EXISTED == 1)) || return 0
  ((ID3_DESTINATION_RESTORED == 0)) || return 0
  [[ "$ID3_RECOVERY_PATH" != none ]] || return 1
  backup="$ID3_RECOVERY_PATH/id3-destination-before.sav"
  [[ -s "$backup" ]] || return 1
  backup_sha="$(
    shasum -a 256 "$backup" | awk '{print $1}'
  )"
  [[ "$backup_sha" == "$ID3_DESTINATION_BEFORE_SHA256" ]] || return 1
  xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "$backup" \
    --destination Documents/save_slot_20.sav >/dev/null || return 1
  rm -f "$WORK/id3-destination-restore-check.sav"
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source Documents/save_slot_20.sav \
    --destination "$WORK/id3-destination-restore-check.sav" >/dev/null || return 1
  restored_sha="$(
    shasum -a 256 "$WORK/id3-destination-restore-check.sav" | awk '{print $1}'
  )"
  [[ "$restored_sha" == "$ID3_DESTINATION_BEFORE_SHA256" ]] || return 1
  ID3_DESTINATION_RESTORED=1
  sync_id3_recovery_artifacts || return 1
}

capture_id3_save_postflight_raw() {
  local listing="$WORK/id3-saves-after.json"
  local slot destination manifest="$WORK/id3-protected-after.sha256"

  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  ((ID3_SAVE_PREFLIGHT_CAPTURED == 1)) || return 1
  ((ID3_SAVE_POSTFLIGHT_CAPTURED == 0)) || return 0
  ((ID3_DESTINATION_EXISTED == 0 || ID3_DESTINATION_RESTORED == 0)) || return 1
  rm -f "$listing" "$manifest" "$WORK/save_slot_20.sav" \
    "$WORK"/id3-after-save_slot_*.sav
  xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$listing" >/dev/null || return 1
  sync_id3_recovery_artifacts || return 1
  python3 - "$listing" <<'PY' || return 1
import json, re, sys
files = json.load(open(sys.argv[1]))["result"]["files"]
save_entries = [
    entry for entry in files
    if re.fullmatch(r"save_slot_[0-9]+\.sav", str(entry.get("name", "")))
]
by_name = {entry.get("name"): entry for entry in save_entries}
if len(by_name) != len(save_entries):
    raise SystemExit("duplicate save slot entry after ID3")
expected = {f"save_slot_{slot}.sav" for slot in (1, 2, 3, 4, 20)}
if set(by_name) != expected:
    raise SystemExit("post-ID3 save set is not exactly slots 1..4 and slot 20")
for slot in (1, 2, 3, 4, 20):
    name = f"save_slot_{slot}.sav"
    entry = by_name.get(name)
    if entry is None:
        raise SystemExit(f"required post-ID3 save is missing: {name}")
    resources = entry.get("resources", {})
    if resources.get("isDirectory") is not False or resources.get("isSymbolicLink") is not False:
        raise SystemExit(f"post-ID3 save is not a regular file: {name}")
PY
  : >"$manifest"
  for slot in 1 2 3 4; do
    destination="$WORK/id3-after-save_slot_$slot.sav"
    xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
      --source "Documents/save_slot_$slot.sav" --destination "$destination" \
      >/dev/null || return 1
    [[ -s "$destination" ]] || return 1
    printf '%s  save_slot_%s.sav\n' \
      "$(shasum -a 256 "$destination" | awk '{print $1}')" "$slot" >>"$manifest"
    sync_id3_recovery_artifacts || return 1
  done
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source Documents/save_slot_20.sav --destination "$WORK/save_slot_20.sav" \
    >/dev/null || return 1
  [[ -s "$WORK/save_slot_20.sav" ]] || return 1
  ID3_DESTINATION_BYTES="$(stat -f '%z' "$WORK/save_slot_20.sav")"
  ID3_DESTINATION_SHA256="$(shasum -a 256 "$WORK/save_slot_20.sav" | awk '{print $1}')"
  [[ "$ID3_DESTINATION_BYTES" =~ ^[1-9][0-9]*$ &&
     "$ID3_DESTINATION_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
  sync_id3_recovery_artifacts || return 1
  ID3_SAVE_POSTFLIGHT_CAPTURED=1
}

verify_id3_save_integrity() {
  local manifest="$WORK/id3-protected-after.sha256"

  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  ((ID3_SAVE_POSTFLIGHT_CAPTURED == 1)) || return 1
  cmp -s "$WORK/id3-protected-before.sha256" "$manifest" || return 1
  ID3_PROTECTED_SAVES_MATCH=1
  ID3_SAVE_INTEGRITY_VERIFIED=1
}

write_id3_result_fields() {
  [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] || return 0
  echo "id3_semantic_nonce=$ID3_SEMANTIC_NONCE"
  echo "id3_save_preflight_captured=$ID3_SAVE_PREFLIGHT_CAPTURED"
  echo "id3_save_postflight_captured=$ID3_SAVE_POSTFLIGHT_CAPTURED"
  echo "id3_save_integrity_verified=$ID3_SAVE_INTEGRITY_VERIFIED"
  echo "id3_protected_saves_1_4_match=$ID3_PROTECTED_SAVES_MATCH"
  echo "id3_destination_slot=20"
  echo "id3_destination_bytes=$ID3_DESTINATION_BYTES"
  echo "id3_destination_sha256=$ID3_DESTINATION_SHA256"
  echo "id3_destination_existed=$ID3_DESTINATION_EXISTED"
  echo "id3_destination_before_sha256=$ID3_DESTINATION_BEFORE_SHA256"
  echo "id3_destination_restored=$ID3_DESTINATION_RESTORED"
  echo "id3_recovery_path=$ID3_RECOVERY_PATH"
  echo "id3_recovery_preserved=$ID3_RECOVERY_PRESERVED"
  echo "id3_fault_window_pid=$ID3_FAULT_WINDOW_PID"
  echo "id3_pid_discovery_attempts=$ID3_PID_DISCOVERY_ATTEMPTS"
  echo "id3_completion_observed=$ID3_COMPLETION_OBSERVED"
  echo "id3_post_completion_stable_seconds=$ID3_POST_COMPLETION_STABLE_SECONDS"
}

discover_id3_fault_window_pid() {
  local attempt output pids

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    output="$WORK/processes-id3-window-start-attempt-$attempt.json"
    if pids="$(list_game_pids "$output")" && [[ "$pids" =~ ^[0-9]+$ ]]; then
      ID3_FAULT_WINDOW_PID="$pids"
      ID3_PID_DISCOVERY_ATTEMPTS="$attempt"
      ditto "$output" "$WORK/processes-id3-window-start.json" || return 1
      return 0
    fi
    ((attempt == 10)) || sleep 1
  done
  ID3_PID_DISCOVERY_ATTEMPTS=10
  return 1
}

write_resource_allocator_self_test_result_fields() {
  ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST != 0)) || return 0
  echo "resource_allocator_self_test_required=1"
  echo "resource_allocator_self_test_validation=$RESOURCE_ALLOCATOR_SELF_TEST_VALIDATION"
  echo "resource_allocator_self_test_pid=$RESOURCE_ALLOCATOR_SELF_TEST_PID"
  echo "resource_allocator_self_test_pid_discovery_attempts=$RESOURCE_ALLOCATOR_SELF_TEST_PID_DISCOVERY_ATTEMPTS"
  echo "resource_allocator_self_test_process_survived=$RESOURCE_ALLOCATOR_SELF_TEST_PROCESS_SURVIVED"
}

discover_resource_allocator_self_test_pid() {
  local attempt output pids

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    output="$WORK/processes-resource-allocator-window-start-attempt-$attempt.json"
    if pids="$(list_game_pids "$output")" && [[ "$pids" =~ ^[0-9]+$ ]]; then
      RESOURCE_ALLOCATOR_SELF_TEST_PID="$pids"
      RESOURCE_ALLOCATOR_SELF_TEST_PID_DISCOVERY_ATTEMPTS="$attempt"
      ditto "$output" "$WORK/processes-resource-allocator-window-start.json" || return 1
      return 0
    fi
    ((attempt == 10)) || sleep 1
  done
  RESOURCE_ALLOCATOR_SELF_TEST_PID_DISCOVERY_ATTEMPTS=10
  return 1
}

wait_for_id3_completion() {
  local attempt log="$WORK/log-id3-completion-check.txt"

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    rm -f "$log"
    if xcrun devicectl device copy from --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
        --source Documents/log.txt --destination "$log" >/dev/null 2>&1 &&
       python3 - "$log" "$ID3_SEMANTIC_NONCE" <<'PY'
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
nonce = re.escape(sys.argv[2])
requested = re.findall(
    rf"^RendererIOS preview fence save script: REQUESTED "
    rf"mode=preview-fence-save-v1 nonce={nonce} "
    rf"slot=save_slot_20\.sav request=1$",
    log,
    re.MULTILINE,
)
completed = re.findall(
    r"^\[save\] RendererIOS save completed: source=placeholder "
    r"slot=save_slot_20\.sav request=1 serialize-us=\d+ "
    r"request-to-complete-us=\d+$",
    log,
    re.MULTILINE,
)
if len(requested) != 1 or len(completed) != 1:
    raise SystemExit(1)
PY
    then
      ID3_COMPLETION_OBSERVED=1
      return 0
    fi
    ((attempt == 10)) || sleep 1
  done
  return 1
}

preserve_failure_evidence() {
  local original_status="$1"
  local cleanup_status="$2"
  local candidate failure_dir timestamp

  [[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || return 0
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  if [[ ! "$EXPECTED_BUILD" =~ ^[0-9a-f]{40}(-local)?$ ]]; then
    failure_dir="$ROOT/build/device-fault/$EXPECTED_SHA/invalid-build/failure-$timestamp-$$"
  else
    failure_dir="$(smoke_evidence_path failure "$timestamp" "$$" \
      "$EXPECTED_SHA" "$EXPECTED_BUILD" "$EXPECTED_FAULT")" || return 0
  fi
  mkdir -p "$failure_dir"
  publish_evidence_path "$failure_dir"
  for candidate in \
      launch.log cleanup.log \
      park-settings.log \
      fault-log-summary.txt \
      resource-allocator-self-test-summary.txt \
      id3-protected-before.sha256 id3-protected-after.sha256 \
      id3-saves-before.json id3-saves-after.json save_slot_20.sav \
      processes-id3-window-start.json \
      processes-resource-allocator-window-start.json \
      processes.json \
      log-id3-completion-check.txt \
      log.txt stderr.log crash.log crash-before.log \
      log-before-cleanup.txt stderr-before-cleanup.log crash-before-cleanup.log \
      log-after-cleanup.txt stderr-after-cleanup.log crash-after-cleanup.log; do
    [[ -f "$WORK/$candidate" ]] || continue
    ditto "$WORK/$candidate" "$failure_dir/$candidate"
  done
  for candidate in "$WORK"/processes-durable-zero-*.json \
      "$WORK"/processes-id3-window-start-attempt-*.json \
      "$WORK"/processes-resource-allocator-window-start-attempt-*.json \
      "$WORK"/durable-zero-*.json \
      "$WORK"/crash-listing-*.json; do
    [[ -f "$candidate" ]] || continue
    ditto "$candidate" "$failure_dir/$(basename "$candidate")"
  done
  {
    echo "result=FAIL"
    echo "source_sha=$EXPECTED_SHA"
    echo "expected_build=$EXPECTED_BUILD"
    echo "expected_fault=$EXPECTED_FAULT"
    echo "fault_log_validation=$FAULT_LOG_VALIDATION"
    echo "process_survived_fault_window=$PROCESS_SURVIVED_FAULT_WINDOW"
    write_resource_allocator_self_test_result_fields
    echo "scenario=$SCENARIO"
    echo "save_slot=$SCENARIO_SAVE_SLOT"
    echo "original_exit_status=$original_status"
    echo "cleanup_status=$cleanup_status"
    echo "pre_crash_sha256=$PRE_CRASH_SHA"
    echo "post_crash_sha256=$POST_CRASH_SHA"
    write_id3_result_fields
    write_durable_result_fields
    [[ ! -f "$WORK/fault-log-summary.txt" ]] ||
      cat "$WORK/fault-log-summary.txt"
    [[ ! -f "$WORK/resource-allocator-self-test-summary.txt" ]] ||
      cat "$WORK/resource-allocator-self-test-summary.txt"
  } >"$failure_dir/result.txt"
  echo "failure evidence: $failure_dir" >&2
}

cleanup() {
  local status=$?
  local cleanup_status=0 elapsed=0 final_status="$status"
  trap - EXIT INT TERM HUP
  set +e
  if ((DURABLE_ZERO_ACTIVE_CYCLE != 0)); then
    elapsed=$((SECONDS-DURABLE_ZERO_ACTIVE_CYCLE_STARTED))
    write_durable_cycle_json \
      "$DURABLE_ZERO_ACTIVE_CYCLE" "$elapsed" interrupted || true
    echo "durable-zero cycle=$DURABLE_ZERO_ACTIVE_CYCLE elapsed-seconds=$elapsed result=interrupted" \
      >>"$WORK/cleanup.log"
    DURABLE_ZERO_ACTIVE_CYCLE=0
  fi
  if [[ -n "$DEVICE" && -n "$APP_EXECUTABLE" ]]; then
    if ((RUNTIME_ARMED != 0)); then
      pull_runtime_logs before-cleanup
    fi
    if ensure_durable_zero; then
      echo "phase=trap-cleanup game_processes=0" >>"$WORK/cleanup.log"
    else
      cleanup_status=1
    fi
    if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] &&
       ((ID3_SAVE_PREFLIGHT_CAPTURED == 1 && ID3_SAVE_POSTFLIGHT_CAPTURED == 0)); then
      if ! capture_id3_save_postflight_raw; then
        echo "phase=trap-cleanup id3-save-raw-capture=failed" >>"$WORK/cleanup.log"
        cleanup_status=1
      fi
    fi
    if ! restore_id3_destination_if_needed; then
      echo "phase=trap-cleanup id3-destination-restore=failed" >>"$WORK/cleanup.log"
      cleanup_status=1
    fi
    if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] &&
       ((ID3_SAVE_POSTFLIGHT_CAPTURED == 1 && ID3_SAVE_INTEGRITY_VERIFIED == 0)); then
      if ! verify_id3_save_integrity; then
        echo "phase=trap-cleanup id3-save-integrity=failed" >>"$WORK/cleanup.log"
        cleanup_status=1
      fi
    fi
    if ((RUNTIME_ARMED != 0)); then
      pull_runtime_logs after-cleanup
    fi
    if [[ -n "$BUNDLE_ID" ]]; then
      if capture_crash_state cleanup "$WORK/crash-after-cleanup.log" \
          POST_CRASH_SHA; then
        if ((status == 0)) && [[ "$POST_CRASH_SHA" != "$PRE_CRASH_SHA" ]]; then
          cleanup_status=1
        fi
      else
        cleanup_status=1
      fi
    fi
  fi
  if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]] &&
     [[ "$ID3_RECOVERY_PATH" != none ]]; then
    if ((ID3_PROTECTED_SAVES_MATCH == 0 ||
         ID3_DESTINATION_EXISTED != ID3_DESTINATION_RESTORED ||
         status != 0 || cleanup_status != 0)); then
      preserve_id3_recovery_if_present || cleanup_status=1
    fi
  fi
  if ((status != 0 || cleanup_status != 0)); then
    preserve_failure_evidence "$status" "$cleanup_status"
  fi
  if ((status == 0 && cleanup_status != 0)) &&
      [[ -n "$PASS_EVIDENCE_DIR" && -d "$PASS_EVIDENCE_DIR" ]]; then
    {
      echo "result=FAIL"
      echo "source_sha=$EXPECTED_SHA"
      echo "expected_build=$EXPECTED_BUILD"
      echo "expected_fault=$EXPECTED_FAULT"
      echo "process_survived_fault_window=$PROCESS_SURVIVED_FAULT_WINDOW"
      write_resource_allocator_self_test_result_fields
      echo "failure_reason=exit-cleanup-invalidated-provisional-pass"
      echo "cleanup_status=$cleanup_status"
      echo "pre_crash_sha256=$PRE_CRASH_SHA"
      echo "post_crash_sha256=$POST_CRASH_SHA"
      write_id3_result_fields
      write_durable_result_fields
      [[ ! -f "$WORK/fault-log-summary.txt" ]] ||
        cat "$WORK/fault-log-summary.txt"
      [[ ! -f "$WORK/resource-allocator-self-test-summary.txt" ]] ||
        cat "$WORK/resource-allocator-self-test-summary.txt"
    } >"$PASS_EVIDENCE_DIR/result.txt"
    echo "FAIL: final cleanup invalidated provisional PASS: $PASS_EVIDENCE_DIR" >&2
  fi
  if ((status == 0 && cleanup_status != 0)); then
    final_status=1
  fi
  if ((status == 0 && cleanup_status == 0)) && [[ -n "$PASS_EVIDENCE_DIR" ]]; then
    if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
      echo "PASS — ID3 terminal preview-fence placeholder save gate proven; app stopped"
    elif [[ "$EXPECTED_FAULT" == frame-fence-error-after-terminal ]]; then
      echo "PASS — ID4 terminal frame-fence fatal gate proven; app stopped"
    else
      echo "PASS — offline metallib + scenario counters + scene/Bink gates proven; app stopped"
    fi
    echo "evidence: $PASS_EVIDENCE_DIR"
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

EXPECTED_SHA="${OPENGOTHIC_IOS_EXPECTED_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  fail "expected source SHA must be exactly 40 lowercase hexadecimal characters"
EXPECTED_BUILD="${OPENGOTHIC_IOS_EXPECTED_BUILD:-$EXPECTED_SHA}"
[[ "$EXPECTED_BUILD" =~ ^[0-9a-f]{40}(-local)?$ ]] ||
  fail "expected build must be a lowercase source SHA, optionally suffixed -local"
[[ "$EXPECTED_BUILD" == "$EXPECTED_SHA" ||
   "$EXPECTED_BUILD" == "$EXPECTED_SHA-local" ]] ||
  fail "expected build must identify the expected source SHA"
strings "$APP_INPUT/$APP_EXECUTABLE" >"$WORK/app-strings.txt"
grep -Fxq "$EXPECTED_BUILD" "$WORK/app-strings.txt" ||
  fail "app binary does not contain exact expected RendererIOS build"
validate_resource_allocator_binary_profile "$WORK/app-strings.txt" ||
  fail "app binary resource allocator self-test profile does not match the request"
[[ "$(grep -Ec '^RendererIOS configured fault mode=' "$WORK/app-strings.txt" || true)" -eq 1 ]] ||
  fail "app binary does not contain exactly one configured fault marker"
grep -Fxq "RendererIOS configured fault mode=$EXPECTED_FAULT" \
    "$WORK/app-strings.txt" ||
  fail "app binary configured fault mode does not match expected fault"

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
park_settings_foreground || fail "could not park Settings after preflight cleanup"

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

METALLIB_SHA="$(shasum -a 256 "$APP/RendererIOS.metallib" | awk '{print $1}')"
echo "== stopping any previous $BUNDLE_ID process =="
stop_running_app 1 || fail "pre-launch application cleanup failed"
park_settings_foreground || fail "could not park Settings before install"
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
  capture_id3_save_preflight ||
    fail "ID3 preflight did not prove exact protected saves 1..4 and optional slot 20"
fi
capture_crash_state before "$WORK/crash-before.log" PRE_CRASH_SHA ||
  fail "could not establish pre-run crash.log state"

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
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
  ID3_SEMANTIC_NONCE="$(/usr/bin/openssl rand -hex 16)" ||
    fail "could not generate ID3 semantic nonce"
  [[ "$ID3_SEMANTIC_NONCE" =~ ^[0-9a-f]{32}$ ]] ||
    fail "generated ID3 semantic nonce is invalid"
  LAUNCH_ARGS+=(
    "-renderer-ios-semantic-script=preview-fence-save-v1"
    "-renderer-ios-semantic-nonce=$ID3_SEMANTIC_NONCE"
  )
fi
if ((NEW_GAME != 0)); then
  echo "== unattended launch: new game, ${DURATION}s =="
else
  echo "== unattended launch: save slot $SAVE_SLOT, ${DURATION}s =="
fi
DEVICE_FOREGROUND_PARKED=0
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
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
  discover_id3_fault_window_pid ||
    fail "ID3 fault-window start did not discover exactly one process within 10 seconds"
fi
if ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST != 0)); then
  discover_resource_allocator_self_test_pid ||
    fail "resource allocator self-test did not establish exactly one bounded process within 10 seconds"
fi
sleep "$DURATION"
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
  wait_for_id3_completion ||
    fail "ID3 nonce-scoped placeholder save did not complete after the base window"
  sleep 10
  ID3_POST_COMPLETION_STABLE_SECONDS=10
fi

xcrun devicectl device info processes --device "$DEVICE" \
  --json-output "$WORK/processes.json" >/dev/null
python3 - "$WORK/processes.json" "$APP_EXECUTABLE" "$EXPECTED_FAULT" \
    "$ID3_FAULT_WINDOW_PID" "$REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST" \
    "$RESOURCE_ALLOCATOR_SELF_TEST_PID" <<'PY' ||
import json, pathlib, sys
processes = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
expected = sys.argv[2]
expected_fault = sys.argv[3]
expected_id3_pid = sys.argv[4]
require_resource_allocator_self_test = sys.argv[5] == "1"
expected_resource_allocator_pid = sys.argv[6]
matches = [
    p for p in processes
    if pathlib.PurePosixPath(p.get("executable", "")).name == expected
]
if expected_fault in (
    "preview-fence-error-after-terminal",
    "frame-fence-error-after-terminal",
) and len(matches) != 1:
    raise SystemExit(1)
if expected_fault == "preview-fence-error-after-terminal" and str(
    matches[0].get("processIdentifier")
) != expected_id3_pid:
    raise SystemExit(1)
if require_resource_allocator_self_test and (
    len(matches) != 1
    or str(matches[0].get("processIdentifier")) != expected_resource_allocator_pid
):
    raise SystemExit(1)
if expected_fault not in (
    "preview-fence-error-after-terminal",
    "frame-fence-error-after-terminal",
) and not matches:
    raise SystemExit(1)
PY
  fail "application process did not survive the smoke window"
if ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST != 0)); then
  RESOURCE_ALLOCATOR_SELF_TEST_PROCESS_SURVIVED=1
fi
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ||
      "$EXPECTED_FAULT" == frame-fence-error-after-terminal ]]; then
  PROCESS_SURVIVED_FAULT_WINDOW=1
fi

echo "== stopping $BUNDLE_ID after smoke window =="
stop_running_app 1 || fail "application cleanup failed"
park_settings_foreground || fail "could not park Settings after smoke window"
RUNTIME_ARMED=0

for name in log.txt stderr.log; do
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "Documents/$name" --destination "$WORK/$name" >/dev/null 2>&1 || true
done
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
  capture_id3_save_postflight_raw ||
    fail "ID3 did not capture raw saves 1..4 and a non-empty fault slot 20 artifact"
  restore_id3_destination_if_needed ||
    fail "ID3 pre-existing destination slot 20 restore was not confirmed"
  verify_id3_save_integrity ||
    fail "ID3 protected saves 1..4 changed during the fault run"
  ((ID3_COMPLETION_OBSERVED == 1 &&
    ID3_POST_COMPLETION_STABLE_SECONDS >= 10 &&
    ID3_SAVE_PREFLIGHT_CAPTURED == 1 &&
    ID3_SAVE_POSTFLIGHT_CAPTURED == 1 &&
    ID3_SAVE_INTEGRITY_VERIFIED == 1 &&
    ID3_PROTECTED_SAVES_MATCH == 1 &&
    ID3_DESTINATION_BYTES > 0)) ||
    fail "ID3 completion/stability/save-integrity invariants are incomplete"
  ((ID3_DESTINATION_EXISTED == ID3_DESTINATION_RESTORED)) ||
    fail "ID3 pre-existing destination was not restored exactly"
  release_id3_recovery_if_safe ||
    fail "ID3 private recovery could not be released after confirmed integrity"
fi

[[ -s "$WORK/log.txt" ]] || fail "device produced no log.txt"
python3 - "$WORK/log.txt" "$EXPECTED_BUILD" "$EXPECTED_FAULT" <<'PY' ||
import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
expected_build = sys.argv[2]
expected_fault = sys.argv[3]
builds = re.findall(
    r"^RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*$",
    log,
    flags=re.MULTILINE,
)
configured_faults = re.findall(
    r"^RendererIOS configured fault mode=([^\s]+)$",
    log,
    flags=re.MULTILINE,
)
shell_count = sum(
    line.startswith("RendererIOS shell: version=") for line in log.splitlines()
)
configured_count = sum(
    line.startswith("RendererIOS configured fault mode=")
    for line in log.splitlines()
)
if shell_count != 1 or builds != [expected_build]:
    raise SystemExit(
        "expected exactly one physical RendererIOS shell line with exact build "
        + repr(expected_build)
        + ", found "
        + repr(builds)
    )
if configured_count != 1 or configured_faults != [expected_fault]:
    raise SystemExit(
        "expected exactly one short configured fault marker "
        + repr(expected_fault)
        + ", found "
        + repr(configured_faults)
    )
PY
  fail "runtime log does not identify exact build/fault configuration"
if ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0)); then
  python3 "$ROOT/ios/device-test/validate-resource-allocator-self-test-log.py" \
    --log "$WORK/log.txt" --expect-absent ||
    fail "unrequested resource allocator self-test marker appeared at runtime"
fi
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
if ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST != 0)); then
  RESOURCE_ALLOCATOR_VALIDATOR_ARGS=(
    --log "$WORK/log.txt"
    --expected-build "$EXPECTED_BUILD"
    --summary "$WORK/resource-allocator-self-test-summary.txt"
  )
  [[ ! -f "$WORK/stderr.log" ]] ||
    RESOURCE_ALLOCATOR_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
  RESOURCE_ALLOCATOR_SELF_TEST_VALIDATION="failed"
  python3 "$ROOT/ios/device-test/validate-resource-allocator-self-test-log.py" \
    "${RESOURCE_ALLOCATOR_VALIDATOR_ARGS[@]}" ||
    fail "resource allocator self-test log validation failed"
  RESOURCE_ALLOCATOR_SELF_TEST_VALIDATION="passed"
fi
rg -F 'RendererIOS legacy shader policy: profile=bridge-only eager-bridge-pipelines=inventory offline-native-pipelines=builtin,bink legacy-batch=disabled material-pipelines=source-metadata-only pfx-pipelines=disabled' \
  "$WORK/log.txt" >/dev/null || fail "RendererIOS bridge-only shader policy marker is missing"
if rg -F 'Shader compilation took:' "$WORK/log.txt" >/dev/null; then
  fail "legacy eager shader batch ran in RendererIOS"
fi

# ID3 is fatal only after its nonce-scoped save request has queued a GPU preview.
# Its absolute counters are dynamic, so keep it outside both the healthy parser
# and ID4's exact frames-in-flight counter oracle.
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
  ((PROCESS_SURVIVED_FAULT_WINDOW == 1)) ||
    fail "ID3 process did not survive its controlled fault/save observation window"
  ID3_VALIDATOR_ARGS=(
    --log "$WORK/log.txt"
    --expected-build "$EXPECTED_BUILD"
    --expected-fault "$EXPECTED_FAULT"
    --nonce "$ID3_SEMANTIC_NONCE"
    --summary "$WORK/fault-log-summary.txt"
  )
  [[ ! -f "$WORK/stderr.log" ]] ||
    ID3_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
  FAULT_LOG_VALIDATION="failed"
  python3 "$ROOT/ios/device-test/validate-preview-fence-fault-log.py" \
    "${ID3_VALIDATOR_ARGS[@]}" ||
    fail "ID3 terminal preview-fence fault/save log validation failed"
  python3 - "$WORK/fault-log-summary.txt" "$EXPECTED_BUILD" \
      "$ID3_SEMANTIC_NONCE" <<'PY' ||
import pathlib
import sys

summary = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.count("=") != 1:
        raise SystemExit(f"invalid ID3 summary line: {line!r}")
    key, value = line.split("=", 1)
    if key in summary:
        raise SystemExit(f"duplicate ID3 summary key: {key}")
    summary[key] = value
expected = {
    "id3_expected_build",
    "id3_expected_fault",
    "id3_nonce",
    "id3_frames_in_flight",
    "id3_pre_request_presents",
    "id3_fatal_present",
    "id3_post_request_presents",
    "id3_request",
    "id3_queued_count",
    "id3_fired_count",
    "id3_fatal_count",
    "id3_scene_retained",
    "id3_scene_released",
    "id3_scene_live",
    "id3_fatal_settled_idle_confirmed",
    "id3_post_delta_submit_attempts",
    "id3_post_delta_submit_accepted",
    "id3_post_delta_present_attempts",
    "id3_post_delta_present_accepted",
    "id3_placeholder_accepted_count",
    "id3_placeholder_completed_count",
    "id3_placeholder_accepted_us",
    "id3_placeholder_serialize_us",
    "id3_placeholder_complete_us",
}
if summary.keys() != expected:
    raise SystemExit(f"ID3 summary key mismatch: {sorted(summary.keys() ^ expected)}")
if summary["id3_expected_build"] != sys.argv[2]:
    raise SystemExit("ID3 summary build mismatch")
if summary["id3_expected_fault"] != "preview-fence-error-after-terminal":
    raise SystemExit("ID3 summary fault mismatch")
if summary["id3_nonce"] != sys.argv[3]:
    raise SystemExit("ID3 summary nonce mismatch")
n = int(summary["id3_frames_in_flight"])
k = int(summary["id3_pre_request_presents"])
m = int(summary["id3_fatal_present"])
post = int(summary["id3_post_request_presents"])
if n not in (2, 3) or k < 0 or m <= k or post != m - k or not 1 <= post <= n:
    raise SystemExit("ID3 dynamic present window is inconsistent")
exact_one = (
    "id3_request",
    "id3_queued_count",
    "id3_fired_count",
    "id3_fatal_count",
    "id3_fatal_settled_idle_confirmed",
    "id3_placeholder_accepted_count",
    "id3_placeholder_completed_count",
)
if any(summary[key] != "1" for key in exact_one):
    raise SystemExit("ID3 summary lost an exact-one invariant")
if int(summary["id3_scene_retained"]) != m or int(summary["id3_scene_released"]) != m:
    raise SystemExit("ID3 scene counters do not equal fatal M")
exact_zero = (
    "id3_scene_live",
    "id3_post_delta_submit_attempts",
    "id3_post_delta_submit_accepted",
    "id3_post_delta_present_attempts",
    "id3_post_delta_present_accepted",
)
if any(summary[key] != "0" for key in exact_zero):
    raise SystemExit("ID3 summary lost a zero invariant")
accepted = int(summary["id3_placeholder_accepted_us"])
serialized = int(summary["id3_placeholder_serialize_us"])
completed = int(summary["id3_placeholder_complete_us"])
if accepted < 0 or serialized < 0 or serialized > completed:
    raise SystemExit("ID3 summary timings are inconsistent")
PY
    fail "ID3 terminal preview-fence summary validation failed"
  FAULT_LOG_VALIDATION="passed"
# ID4 is intentionally fatal after exactly one full frames-in-flight rotation.
# Keep it outside the healthy 300/Landscape parser and its fatal denylist.
elif [[ "$EXPECTED_FAULT" == frame-fence-error-after-terminal ]]; then
  ((PROCESS_SURVIVED_FAULT_WINDOW == 1)) ||
    fail "ID4 process did not survive its controlled fault observation window"
  FRAME_FENCE_VALIDATOR_ARGS=(
    --log "$WORK/log.txt"
    --expected-build "$EXPECTED_BUILD"
    --expected-fault "$EXPECTED_FAULT"
    --summary "$WORK/fault-log-summary.txt"
  )
  [[ ! -f "$WORK/stderr.log" ]] ||
    FRAME_FENCE_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
  FAULT_LOG_VALIDATION="failed"
  python3 "$ROOT/ios/device-test/validate-frame-fence-fault-log.py" \
    "${FRAME_FENCE_VALIDATOR_ARGS[@]}" ||
    fail "ID4 terminal frame-fence fault log validation failed"
  python3 - "$WORK/fault-log-summary.txt" "$EXPECTED_BUILD" <<'PY' ||
import pathlib
import sys

summary = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.count("=") != 1:
        raise SystemExit(f"invalid ID4 summary line: {line!r}")
    key, value = line.split("=", 1)
    if key in summary:
        raise SystemExit(f"duplicate ID4 summary key: {key}")
    summary[key] = value
expected = {
    "id4_expected_build",
    "id4_expected_fault",
    "id4_frames_in_flight",
    "id4_configured_count",
    "id4_armed_count",
    "id4_fired_count",
    "id4_first_present",
    "id4_last_present",
    "id4_present_count",
    "id4_post_fault_present_count",
    "id4_fatal_count",
    "id4_fatal_snapshot_submit_attempts",
    "id4_fatal_snapshot_submit_accepted",
    "id4_fatal_snapshot_present_attempts",
    "id4_fatal_snapshot_present_accepted",
    "id4_stopped_loop_count",
    "id4_scene_retained",
    "id4_scene_released",
    "id4_scene_live",
    "id4_fatal_settled_idle_confirmed",
    "id4_fatal_settled_submit_attempts",
    "id4_fatal_settled_submit_accepted",
    "id4_fatal_settled_present_attempts",
    "id4_fatal_settled_present_accepted",
    "id4_post_delta_submit_attempts",
    "id4_post_delta_submit_accepted",
    "id4_post_delta_present_attempts",
    "id4_post_delta_present_accepted",
    "id4_resume_settled_count",
    "id4_resumed_one_count",
}
if summary.keys() != expected:
    raise SystemExit(
        f"ID4 summary key mismatch: {sorted(summary.keys() ^ expected)}"
    )
if summary["id4_expected_build"] != sys.argv[2]:
    raise SystemExit("ID4 summary build mismatch")
if summary["id4_expected_fault"] != "frame-fence-error-after-terminal":
    raise SystemExit("ID4 summary fault mismatch")
n = int(summary["id4_frames_in_flight"])
if n not in (2, 3):
    raise SystemExit("ID4 summary has invalid frames-in-flight")
exact_one = (
    "id4_configured_count",
    "id4_armed_count",
    "id4_fired_count",
    "id4_first_present",
    "id4_fatal_count",
    "id4_stopped_loop_count",
    "id4_fatal_settled_idle_confirmed",
)
if any(summary[key] != "1" for key in exact_one):
    raise SystemExit("ID4 summary lost an exact-one invariant")
n_values = (
    "id4_last_present",
    "id4_present_count",
    "id4_fatal_snapshot_submit_attempts",
    "id4_fatal_snapshot_submit_accepted",
    "id4_fatal_snapshot_present_attempts",
    "id4_fatal_snapshot_present_accepted",
    "id4_scene_retained",
    "id4_scene_released",
    "id4_fatal_settled_submit_attempts",
    "id4_fatal_settled_submit_accepted",
    "id4_fatal_settled_present_attempts",
    "id4_fatal_settled_present_accepted",
)
if any(int(summary[key]) != n for key in n_values):
    raise SystemExit("ID4 summary counters do not equal frames-in-flight")
exact_zero = (
    "id4_scene_live",
    "id4_post_delta_submit_attempts",
    "id4_post_delta_submit_accepted",
    "id4_post_delta_present_attempts",
    "id4_post_delta_present_accepted",
    "id4_post_fault_present_count",
    "id4_resume_settled_count",
    "id4_resumed_one_count",
)
if any(summary[key] != "0" for key in exact_zero):
    raise SystemExit("ID4 summary lost a zero invariant")
PY
    fail "ID4 terminal frame-fence summary validation failed"
  FAULT_LOG_VALIDATION="passed"
else
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

if [[ "$EXPECTED_FAULT" == post-submit-suboptimal ]]; then
  FAULT_VALIDATOR_ARGS=(
    --log "$WORK/log.txt"
    --expected-build "$EXPECTED_BUILD"
    --expected-fault "$EXPECTED_FAULT"
    --summary "$WORK/fault-log-summary.txt"
  )
  [[ ! -f "$WORK/stderr.log" ]] ||
    FAULT_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
  FAULT_LOG_VALIDATION="failed"
  python3 "$ROOT/ios/device-test/validate-fault-log.py" \
    "${FAULT_VALIDATOR_ARGS[@]}" ||
    fail "ID5 post-submit fault log validation failed"
  python3 - "$WORK/fault-log-summary.txt" "$EXPECTED_BUILD" <<'PY' ||
import pathlib
import sys

summary = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.count("=") != 1:
        raise SystemExit(f"invalid ID5 summary line: {line!r}")
    key, value = line.split("=", 1)
    if key in summary:
        raise SystemExit(f"duplicate ID5 summary key: {key}")
    summary[key] = value
expected = {
    "id5_expected_build",
    "id5_expected_fault",
    "id5_armed_count",
    "id5_fired_count",
    "id5_reset_attempt_count",
    "id5_resize_settled_count",
    "id5_reset_idle_confirmed",
    "id5_reset_submit_attempts",
    "id5_reset_submit_accepted",
    "id5_reset_present_attempts",
    "id5_reset_present_accepted",
    "id5_reset_present_baseline",
    "id5_post_reset_first_present",
    "id5_post_reset_max_present",
    "id5_post_reset_present_delta",
    "id5_post_reset_contiguous_presents",
}
if summary.keys() != expected:
    raise SystemExit(
        f"ID5 summary key mismatch: {sorted(summary.keys() ^ expected)}"
    )
if summary["id5_expected_build"] != sys.argv[2]:
    raise SystemExit("ID5 summary build mismatch")
if summary["id5_expected_fault"] != "post-submit-suboptimal":
    raise SystemExit("ID5 summary fault mismatch")
exact_one = (
    "id5_armed_count",
    "id5_fired_count",
    "id5_reset_attempt_count",
    "id5_resize_settled_count",
    "id5_reset_idle_confirmed",
    "id5_reset_submit_attempts",
    "id5_reset_submit_accepted",
    "id5_post_reset_first_present",
)
if any(summary[key] != "1" for key in exact_one):
    raise SystemExit("ID5 summary lost an exact-one invariant")
exact_zero = (
    "id5_reset_present_attempts",
    "id5_reset_present_accepted",
    "id5_reset_present_baseline",
)
if any(summary[key] != "0" for key in exact_zero):
    raise SystemExit("ID5 summary lost its zero-present reset baseline")
maximum = int(summary["id5_post_reset_max_present"])
delta = int(summary["id5_post_reset_present_delta"])
contiguous = int(summary["id5_post_reset_contiguous_presents"])
if maximum < 300 or delta != maximum or contiguous != maximum:
    raise SystemExit("ID5 summary does not prove 300 contiguous post-reset presents")
PY
    fail "ID5 post-submit fault summary validation failed"
  FAULT_LOG_VALIDATION="passed"
fi
fi

capture_crash_state after "$WORK/crash.log" POST_CRASH_SHA ||
  fail "could not establish post-run crash.log state"
if [[ "$POST_CRASH_SHA" != "$PRE_CRASH_SHA" ]]; then
  fail "crash.log changed during the smoke run"
fi

# Validation can take long enough for SpringBoard to recreate a still-active
# foreground scene after process termination. Reassert both conditions at the
# final PASS boundary so the unattended harness leaves the game durably off.
stop_running_app 1 || fail "final application cleanup failed"
park_settings_foreground || fail "could not park Settings at PASS boundary"
ensure_durable_zero || fail "durable final application cleanup failed"
((DEVICE_PROCESS_STOPPED == 1 && DURABLE_ZERO_STABLE == 1 &&
  DURABLE_ZERO_STABLE_SECONDS >= DURABLE_ZERO_REQUIRED_STABLE_SECONDS &&
  DURABLE_ZERO_FINAL_ZERO == 1)) ||
  fail "durable final application cleanup did not establish stable zero"
((DEVICE_FOREGROUND_PARKED == 1)) ||
  fail "Settings was not parked at the durable PASS boundary"
capture_crash_state final "$WORK/crash-final.log" POST_CRASH_SHA ||
  fail "could not establish final crash.log state"
[[ "$POST_CRASH_SHA" == "$PRE_CRASH_SHA" ]] ||
  fail "crash.log changed before the durable PASS boundary"

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT="$(smoke_evidence_path pass "$timestamp" "$$" \
  "$EXPECTED_SHA" "$EXPECTED_BUILD" "$EXPECTED_FAULT")" ||
  fail "could not resolve smoke evidence path"
mkdir -p "$OUT"
PASS_EVIDENCE_DIR="$OUT"
publish_evidence_path "$OUT"
ditto "$WORK/log.txt" "$OUT/log.txt"
[[ ! -f "$WORK/stderr.log" ]] || ditto "$WORK/stderr.log" "$OUT/stderr.log"
ditto "$WORK/device-selection.log" "$OUT/device-selection.log"
[[ ! -f "$WORK/cleanup.log" ]] || ditto "$WORK/cleanup.log" "$OUT/cleanup.log"
[[ ! -f "$WORK/park-settings.log" ]] ||
  ditto "$WORK/park-settings.log" "$OUT/park-settings.log"
[[ ! -f "$WORK/fault-log-summary.txt" ]] ||
  ditto "$WORK/fault-log-summary.txt" "$OUT/fault-log-summary.txt"
[[ ! -f "$WORK/resource-allocator-self-test-summary.txt" ]] ||
  ditto "$WORK/resource-allocator-self-test-summary.txt" \
    "$OUT/resource-allocator-self-test-summary.txt"
for candidate in id3-protected-before.sha256 id3-protected-after.sha256 \
    id3-saves-before.json id3-saves-after.json save_slot_20.sav \
    processes.json processes-id3-window-start.json \
    processes-resource-allocator-window-start.json \
    log-id3-completion-check.txt; do
  [[ -f "$WORK/$candidate" ]] || continue
  ditto "$WORK/$candidate" "$OUT/$candidate"
done
for candidate in crash-before.log crash.log crash-final.log \
    crash-listing-before.json crash-listing-after.json crash-listing-final.json; do
  [[ -f "$WORK/$candidate" ]] || continue
  ditto "$WORK/$candidate" "$OUT/$candidate"
done
rm -f "$OUT"/processes-durable-zero-*.json "$OUT"/durable-zero-*.json
for candidate in "$WORK"/processes-durable-zero-*.json \
    "$WORK"/processes-resource-allocator-window-start-attempt-*.json \
    "$WORK"/durable-zero-*.json; do
  [[ -f "$candidate" ]] || continue
  ditto "$candidate" "$OUT/$(basename "$candidate")"
done
{
  echo "result=PASS"
  echo "source_sha=$EXPECTED_SHA"
  echo "expected_build=$EXPECTED_BUILD"
  echo "expected_fault=$EXPECTED_FAULT"
  echo "fault_log_validation=$FAULT_LOG_VALIDATION"
  echo "process_survived_fault_window=$PROCESS_SURVIVED_FAULT_WINDOW"
  write_resource_allocator_self_test_result_fields
  echo "pre_crash_sha256=$PRE_CRASH_SHA"
  echo "post_crash_sha256=$POST_CRASH_SHA"
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
  write_id3_result_fields
  # device_process_stopped=1 is emitted only after the durable stable window
  # and its independent final process query both prove zero.
  write_durable_result_fields
  [[ ! -f "$WORK/runtime-compilation-summary.txt" ]] ||
    cat "$WORK/runtime-compilation-summary.txt"
  [[ ! -f "$WORK/fault-log-summary.txt" ]] ||
    cat "$WORK/fault-log-summary.txt"
  [[ ! -f "$WORK/resource-allocator-self-test-summary.txt" ]] ||
    cat "$WORK/resource-allocator-self-test-summary.txt"
} >"$OUT/result.txt"
