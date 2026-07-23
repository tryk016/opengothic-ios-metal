#!/usr/bin/env bash
# Drive the diagnostics-only in-app semantic UI script, then use public
# CoreDevice activation to prove a real background/foreground cycle.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$ROOT/ios/device-test/validate-semantic-ui-lifecycle-log.py"
PIPELINE_VALIDATOR="$ROOT/ios/device-test/validate-pipeline-archive-log.py"
CONSOLE_SUPERVISOR="$ROOT/ios/device-test/semantic-console-supervisor.py"
BASE_BUNDLE_ID="opengothic.gothic2"
APP_EXECUTABLE="Gothic2Notr"
SAVE_SLOT=""
SCRIPT_MODE="save-ui-lifecycle-v1"
PIPELINE_ARCHIVE_PHASE=""
METALLIB_SHA256=""
EVIDENCE_PATH_FILE=""
ARCHIVE_DIR="Library/Caches/RendererIOS/PipelineArchives/schema-1"
ARCHIVE_NAME="RendererIOS-abi-5.binaryarchive"
PROVENANCE_NAME="RendererIOS-abi-5.provenance"
readonly DOCUMENT_COPY_MAX_ATTEMPTS=3
readonly CONSOLE_REAP_GRACE_SECONDS=10
readonly GAME_PID_DISCOVERY_SECONDS=30
readonly PROCESS_QUERY_TIMEOUT_SECONDS=5
readonly DURABLE_ZERO_MAX_CYCLES=3
readonly DURABLE_ZERO_SCANS_PER_CYCLE=10
readonly DURABLE_ZERO_INTERVAL_SECONDS=10
readonly DURABLE_ZERO_REQUIRED_STABLE_SECONDS=90

if [[ -z "${DEVELOPER_DIR:-}" && -d "$HOME/Applications/Xcode-26.5.app/Contents/Developer" ]]; then
  DEVELOPER_DIR="$HOME/Applications/Xcode-26.5.app/Contents/Developer"
fi
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

publish_evidence_path() {
  local path="$1"
  [[ -n "$EVIDENCE_PATH_FILE" ]] || return 0
  printf '%s\n' "$path" >"$EVIDENCE_PATH_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --save-slot)
      [[ -z "$SAVE_SLOT" ]] || fail "--save-slot was specified twice"
      SAVE_SLOT="${2:?missing save slot}"
      shift 2
      ;;
    --pipeline-archive-phase)
      [[ -z "$PIPELINE_ARCHIVE_PHASE" ]] ||
        fail "--pipeline-archive-phase was specified twice"
      PIPELINE_ARCHIVE_PHASE="${2:?missing pipeline archive phase}"
      shift 2
      ;;
    --metallib-sha256)
      [[ -z "$METALLIB_SHA256" ]] || fail "--metallib-sha256 was specified twice"
      METALLIB_SHA256="${2:?missing metallib SHA-256}"
      shift 2
      ;;
    --evidence-path-file)
      [[ -z "$EVIDENCE_PATH_FILE" ]] || fail "--evidence-path-file was specified twice"
      EVIDENCE_PATH_FILE="${2:?missing evidence path file}"
      shift 2
      ;;
    -*) fail "usage: $0 --save-slot number [--pipeline-archive-phase inventory-cold|inventory-warm --metallib-sha256 hex] [--evidence-path-file absolute-path]" ;;
    *) fail "unexpected positional argument: $1" ;;
  esac
done
[[ "$SAVE_SLOT" =~ ^[1-9][0-9]*$ ]] || fail "one positive numeric --save-slot is required"
[[ -z "$PIPELINE_ARCHIVE_PHASE" ||
   "$PIPELINE_ARCHIVE_PHASE" == inventory-cold ||
   "$PIPELINE_ARCHIVE_PHASE" == inventory-warm ]] ||
  fail "pipeline archive phase must be inventory-cold or inventory-warm"
if [[ -n "$PIPELINE_ARCHIVE_PHASE" ]]; then
  [[ "$SAVE_SLOT" == 1 ]] || fail "inventory archive phases require --save-slot 1"
  [[ "$METALLIB_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    fail "inventory archive phases require exact metallib SHA-256"
else
  [[ -z "$METALLIB_SHA256" ]] ||
    fail "--metallib-sha256 requires --pipeline-archive-phase"
fi
if [[ -n "$EVIDENCE_PATH_FILE" ]]; then
  [[ "$EVIDENCE_PATH_FILE" == /* ]] || fail "evidence path file must be absolute"
  [[ -d "$(dirname "$EVIDENCE_PATH_FILE")" ]] ||
    fail "evidence path file parent does not exist"
fi
[[ -x "$VALIDATOR" ]] || fail "semantic log validator is not executable"
[[ -x "$PIPELINE_VALIDATOR" ]] || fail "pipeline archive log validator is not executable"
[[ -x "$CONSOLE_SUPERVISOR" ]] || fail "semantic console supervisor is not executable"
command -v xcrun >/dev/null || fail "xcrun is not available"
xcrun --find devicectl >/dev/null || fail "DEVELOPER_DIR has no devicectl"

EXPECTED_SHA="${OPENGOTHIC_IOS_EXPECTED_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  fail "expected source SHA must be 40 lowercase hexadecimal characters"
NONCE="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
[[ "$NONCE" =~ ^[0-9a-f]{32}$ ]] || fail "could not generate run nonce"

WORK="$(mktemp -d -t opengothic-device-semantic)"
DEVICE=""
DEVICE_UDID=""
DEVICE_SELECTION_METHOD=""
DEVICE_SELECTION_ATTEMPTS_USED=0
BUNDLE_ID=""
GAME_PID=""
RUNTIME_ARMED=0
FINALIZED=0
DEVICE_PROCESS_STOPPED=0
DEVICE_FOREGROUND_PARKED=0
STOP_RUNNING_APP_QUERY_FAILED=0
DURABLE_ZERO_CYCLES_USED=0
DURABLE_ZERO_SCANS_COMPLETED=0
DURABLE_ZERO_RESPAWNS_DETECTED=0
DURABLE_ZERO_QUERY_FAILURES=0
DURABLE_ZERO_STOP_FAILURES=0
DURABLE_ZERO_PARK_FAILURES=0
DURABLE_ZERO_STABLE=0
DURABLE_ZERO_STABLE_SECONDS=0
DURABLE_ZERO_FINAL_ZERO=0
DURABLE_ZERO_EMERGENCY_ZERO=0
DURABLE_ZERO_STARTED_EPOCH=0
DURABLE_ZERO_STARTED_AT_UTC=""
DURABLE_ZERO_FINISHED_AT_UTC=""
DURABLE_ZERO_ELAPSED_SECONDS=0
SETTINGS_AVAILABLE=0
PRE_CRASH_STATE="missing"
POST_CRASH_STATE="missing"
PID_AFTER_BACKGROUND=""
PID_AFTER_FOREGROUND=""
CONSOLE_LAUNCHER_PID=""
CONSOLE_STARTUP_PID=""
CONSOLE_STARTUP_SIGNAL_STATUS=0
CONSOLE_LAUNCHER_STATUS="not-started"
CONSOLE_LAUNCHER_EXIT_CODE=""
CONSOLE_SUPERVISOR_EXIT_CODE=""
CONSOLE_DEVICECTL_PID=""
CONSOLE_STREAM_STATE="not-started"
CONSOLE_INSTANCE_TOKEN="$NONCE"
CONSOLE_PARENT_PID="$$"
CONSOLE_OBSERVER_STATE="OBSERVER_ERROR"
CONSOLE_OBSERVER_ERRORS=0
CONSOLE_STATUS_FORCED_KILL=0
CONSOLE_LAUNCHER_REAPED=0
CONSOLE_SUPERVISOR_REAPED=0
CONSOLE_LAUNCHER_PREMATURE_EXIT=0
CONSOLE_LAUNCHER_FORCED_KILL=0
CONSOLE_STOP_REQUESTED=0
CONSOLE_PRESTOP_LIVENESS=0
CONSOLE_LAUNCHER_STARTED_AT_UTC=""
CONSOLE_LAUNCHER_FINISHED_AT_UTC=""
CONSOLE_RAW_BYTES_BEFORE_STOP=0
CONSOLE_MARKER_HITS=0
GAME_PID_DISCOVERY_ATTEMPTS=0

list_game_pids() {
  local output="$1"
  xcrun devicectl device info processes --device "$DEVICE" \
    --timeout "$PROCESS_QUERY_TIMEOUT_SECONDS" \
    --json-output "$output" >/dev/null 2>>"$WORK/cleanup.log" || return 1
  python3 - "$output" "$APP_EXECUTABLE" <<'PY'
import json, pathlib, sys
processes = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
for process in processes:
    if pathlib.PurePosixPath(process.get("executable", "")).name == sys.argv[2]:
        pid = process.get("processIdentifier")
        if not isinstance(pid, int):
            raise SystemExit("invalid game process identifier")
        print(pid)
PY
}

require_same_game_pid() {
  local label="$1" file pids
  file="$WORK/processes-$label.json"
  pids="$(list_game_pids "$file")" || return 1
  [[ "$pids" == "$GAME_PID" ]] || {
    echo "FAIL: game PID changed at $label" >&2
    return 1
  }
}

stop_running_app() {
  local strict="${1:-0}" attempt pids pid mode
  STOP_RUNNING_APP_QUERY_FAILED=0
  [[ -n "$DEVICE" ]] || return 0
  for attempt in 1 2 3 4 5; do
    pids="$(list_game_pids "$WORK/processes-stop-$attempt.json")" || {
      STOP_RUNNING_APP_QUERY_FAILED=1
      [[ "$strict" == 0 ]] || echo "FAIL: process query failed" >&2
      return 1
    }
    [[ -n "$pids" ]] || return 0
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

park_settings_foreground() {
  [[ -n "$DEVICE" && "$SETTINGS_AVAILABLE" == 1 ]] || return 1
  xcrun devicectl device process launch --device "$DEVICE" \
    --terminate-existing --activate com.apple.Preferences \
    >>"$WORK/park-settings.log" 2>&1 || return 1
  DEVICE_FOREGROUND_PARKED=1
}

read_console_status() {
  local record state child returncode supervisor token forced started finished
  [[ -f "$WORK/console-status.json" ]] || return 1
  record="$("$CONSOLE_SUPERVISOR" status \
    --status "$WORK/console-status.json" 2>>"$WORK/console-launcher.log")" || return 1
  IFS='|' read -r state child returncode supervisor token forced started finished \
    <<<"$record"
  [[ "$state" == starting || "$state" == running || "$state" == exited ]] || return 1
  [[ "$supervisor" == "$CONSOLE_LAUNCHER_PID" ]] || return 1
  [[ "$token" == "$CONSOLE_INSTANCE_TOKEN" ]] || return 1
  [[ -z "$child" || "$child" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -z "$returncode" || "$returncode" =~ ^-?[0-9]+$ ]] || return 1
  [[ "$forced" =~ ^[01]$ ]] || return 1
  CONSOLE_STREAM_STATE="$state"
  CONSOLE_DEVICECTL_PID="$child"
  CONSOLE_LAUNCHER_EXIT_CODE="$returncode"
  CONSOLE_STATUS_FORCED_KILL="$forced"
  [[ -z "$started" ]] || CONSOLE_LAUNCHER_STARTED_AT_UTC="$started"
  [[ -z "$finished" ]] || CONSOLE_LAUNCHER_FINISHED_AT_UTC="$finished"
}

observe_console_launcher() {
  local record process_state process_parent process_command
  CONSOLE_OBSERVER_STATE="OBSERVER_ERROR"
  [[ "$CONSOLE_LAUNCHER_PID" =~ ^[1-9][0-9]*$ ]] || return 0
  if ! record="$(ps -ww -p "$CONSOLE_LAUNCHER_PID" \
      -o stat= -o ppid= -o command= 2>/dev/null)"; then
    if kill -0 "$CONSOLE_LAUNCHER_PID" 2>/dev/null; then
      return 0
    fi
    CONSOLE_OBSERVER_STATE="EXITED"
    return 0
  fi
  read -r process_state process_parent process_command <<<"$record"
  [[ -n "$process_state" && "$process_parent" =~ ^[0-9]+$ ]] || return 0
  if [[ "${process_state:0:1}" == Z ]]; then
    CONSOLE_OBSERVER_STATE="EXITED"
    return 0
  fi
  [[ "$process_parent" == "$CONSOLE_PARENT_PID" &&
     "$process_command" == *"$CONSOLE_SUPERVISOR"* &&
     "$process_command" == *" supervise "* &&
     "$process_command" == *"--instance-token $CONSOLE_INSTANCE_TOKEN"* &&
     "$process_command" == *"--status $WORK/console-status.json"* &&
     "$process_command" == *"--stop-request $WORK/console-stop-request"* ]] || return 0
  read_console_status || return 0
  if [[ "$CONSOLE_STREAM_STATE" == starting ||
        "$CONSOLE_STREAM_STATE" == running ||
        "$CONSOLE_STREAM_STATE" == exited ]]; then
    CONSOLE_OBSERVER_STATE="RUNNING"
  fi
}

require_console_running() {
  local label="$1"
  observe_console_launcher
  case "$CONSOLE_OBSERVER_STATE" in
    RUNNING)
      if [[ "$CONSOLE_STREAM_STATE" == exited ]]; then
        CONSOLE_LAUNCHER_PREMATURE_EXIT=1
        echo "FAIL: console launcher published terminal status at $label; refusing wait while its process is still live" >&2
        return 1
      fi
      return 0
      ;;
    EXITED)
      CONSOLE_LAUNCHER_PREMATURE_EXIT=1
      capture_console_launcher_exit "premature-exit-$label" || true
      echo "FAIL: console launcher ended at $label (exit $CONSOLE_LAUNCHER_EXIT_CODE)" >&2
      return 1
      ;;
    OBSERVER_ERROR)
      CONSOLE_OBSERVER_ERRORS=$((CONSOLE_OBSERVER_ERRORS+1))
      echo "FAIL: console launcher observer error at $label; refusing wait or PID action" >&2
      return 1
      ;;
  esac
  return 1
}

capture_console_launcher_exit() {
  local context="$1" supervisor_exit
  ((CONSOLE_SUPERVISOR_REAPED == 0)) || return 0
  [[ "$CONSOLE_LAUNCHER_PID" =~ ^[1-9][0-9]*$ ]] || return 1
  observe_console_launcher
  [[ "$CONSOLE_OBSERVER_STATE" == EXITED ]] || {
    echo "FAIL: refusing to wait for console supervisor in state $CONSOLE_OBSERVER_STATE" >&2
    return 1
  }
  if wait "$CONSOLE_LAUNCHER_PID"; then
    supervisor_exit=0
  else
    supervisor_exit=$?
  fi
  CONSOLE_SUPERVISOR_EXIT_CODE="$supervisor_exit"
  CONSOLE_SUPERVISOR_REAPED=1
  if ! read_console_status || [[ "$CONSOLE_STREAM_STATE" != exited ]]; then
    CONSOLE_LAUNCHER_STATUS="$context-unproven-child-exit"
    return 1
  fi
  CONSOLE_LAUNCHER_REAPED=1
  CONSOLE_LAUNCHER_FORCED_KILL="$CONSOLE_STATUS_FORCED_KILL"
  CONSOLE_LAUNCHER_STATUS="$context"
  [[ -n "$CONSOLE_LAUNCHER_FINISHED_AT_UTC" ]] ||
    CONSOLE_LAUNCHER_FINISHED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "console-launcher timestamp=$CONSOLE_LAUNCHER_FINISHED_AT_UTC supervisor-pid=$CONSOLE_LAUNCHER_PID devicectl-pid=$CONSOLE_DEVICECTL_PID status=$context returncode=$CONSOLE_LAUNCHER_EXIT_CODE supervisor-exit=$CONSOLE_SUPERVISOR_EXIT_CODE" \
    >>"$WORK/console-launcher.log"
}

request_console_stop() {
  local temporary="$WORK/.console-stop-request.$$"
  printf '%s\n' "$CONSOLE_INSTANCE_TOKEN" >"$temporary" || return 1
  mv -f "$temporary" "$WORK/console-stop-request" || return 1
  CONSOLE_STOP_REQUESTED=1
  echo "console-launcher timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') phase=post-device-zero action=request-supervisor-stop" \
    >>"$WORK/console-launcher.log"
}

defer_console_startup_signal() {
  local status="$1"
  if ((CONSOLE_STARTUP_SIGNAL_STATUS == 0)); then
    CONSOLE_STARTUP_SIGNAL_STATUS="$status"
  fi
}

begin_console_startup_critical_section() {
  CONSOLE_STARTUP_SIGNAL_STATUS=0
  trap 'defer_console_startup_signal 130' INT
  trap 'defer_console_startup_signal 143' TERM
  trap 'defer_console_startup_signal 129' HUP
}

finish_console_startup_critical_section() {
  CONSOLE_LAUNCHER_PID="$CONSOLE_STARTUP_PID"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  [[ "$CONSOLE_LAUNCHER_PID" =~ ^[1-9][0-9]*$ ]] || return 1
  if ((CONSOLE_STARTUP_SIGNAL_STATUS != 0)); then
    exit "$CONSOLE_STARTUP_SIGNAL_STATUS"
  fi
}

reap_console_launcher() {
  local deadline
  ((CONSOLE_LAUNCHER_REAPED == 0)) || return 0
  if [[ ! "$CONSOLE_LAUNCHER_PID" =~ ^[1-9][0-9]*$ ]]; then
    request_console_stop || true
    echo "FAIL: console supervisor PID was not persisted; published authenticated stop request" >&2
    return 1
  fi

  deadline=$((SECONDS+CONSOLE_REAP_GRACE_SECONDS))
  while ((SECONDS < deadline)); do
    observe_console_launcher
    if [[ "$CONSOLE_OBSERVER_STATE" == EXITED ]]; then
      capture_console_launcher_exit reaped-after-device-zero
      return
    fi
    sleep 1
  done

  request_console_stop || return 1

  deadline=$((SECONDS+CONSOLE_REAP_GRACE_SECONDS))
  while ((SECONDS < deadline)); do
    observe_console_launcher
    if [[ "$CONSOLE_OBSERVER_STATE" == EXITED ]]; then
      capture_console_launcher_exit reaped-after-supervisor-stop-request
      return
    fi
    sleep 1
  done
  echo "FAIL: console supervisor did not exit after its authenticated stop request; refusing unsafe PID kill" >&2
  return 1
}

snapshot_console_before_stop() {
  [[ -f "$WORK/console-raw.log" ]] || {
    : >"$WORK/console-before-stop.missing"
    return 1
  }
  ditto "$WORK/console-raw.log" "$WORK/console-before-stop.log" || return 1
  CONSOLE_RAW_BYTES_BEFORE_STOP="$(wc -c <"$WORK/console-before-stop.log" | tr -d '[:space:]')"
  [[ "$CONSOLE_RAW_BYTES_BEFORE_STOP" =~ ^[0-9]+$ ]]
}

ensure_durable_zero() {
  local cycle scan pids stable cycle_started cycle_elapsed timestamp now result
  if ((DURABLE_ZERO_STABLE != 0 &&
       DURABLE_ZERO_STABLE_SECONDS >= DURABLE_ZERO_REQUIRED_STABLE_SECONDS &&
       DURABLE_ZERO_FINAL_ZERO != 0)); then
    DEVICE_PROCESS_STOPPED=1
    return 0
  fi
  if ((DURABLE_ZERO_STARTED_EPOCH == 0)); then
    DURABLE_ZERO_STARTED_EPOCH="$(date +%s)"
    DURABLE_ZERO_STARTED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi
  DEVICE_PROCESS_STOPPED=0

  while ((DURABLE_ZERO_CYCLES_USED < DURABLE_ZERO_MAX_CYCLES)); do
    cycle=$((DURABLE_ZERO_CYCLES_USED+1))
    DURABLE_ZERO_CYCLES_USED=$cycle
    DURABLE_ZERO_STABLE=0
    DURABLE_ZERO_STABLE_SECONDS=0
    DURABLE_ZERO_FINAL_ZERO=0
    DEVICE_FOREGROUND_PARKED=0
    if ! stop_running_app 1; then
      timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      result="failure"
      if ((STOP_RUNNING_APP_QUERY_FAILED != 0)); then
        ((DURABLE_ZERO_QUERY_FAILURES+=1))
        result="query-failure"
      else
        ((DURABLE_ZERO_STOP_FAILURES+=1))
      fi
      echo "durable-zero timestamp=$timestamp cycle=$cycle phase=stop result=$result" \
        >>"$WORK/cleanup.log"
      continue
    fi
    if ! park_settings_foreground; then
      ((DURABLE_ZERO_PARK_FAILURES+=1))
      timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      echo "durable-zero timestamp=$timestamp cycle=$cycle phase=park result=failure" \
        >>"$WORK/cleanup.log"
      continue
    fi
    stable=1
    cycle_started=$SECONDS
    for ((scan=1; scan<=DURABLE_ZERO_SCANS_PER_CYCLE; ++scan)); do
      ((scan == 1)) || sleep "$DURABLE_ZERO_INTERVAL_SECONDS"
      cycle_elapsed=$((SECONDS-cycle_started))
      timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      if ! pids="$(list_game_pids \
          "$WORK/processes-durable-zero-cycle-$cycle-scan-$scan.json")"; then
        ((DURABLE_ZERO_QUERY_FAILURES+=1))
        stable=0
        echo "durable-zero timestamp=$timestamp cycle=$cycle scan=$scan elapsed-seconds=$cycle_elapsed result=query-failure" \
          >>"$WORK/cleanup.log"
        break
      fi
      ((DURABLE_ZERO_SCANS_COMPLETED+=1))
      if [[ -n "$pids" ]]; then
        ((DURABLE_ZERO_RESPAWNS_DETECTED+=1))
        DEVICE_FOREGROUND_PARKED=0
        stable=0
        echo "durable-zero timestamp=$timestamp cycle=$cycle scan=$scan elapsed-seconds=$cycle_elapsed result=respawn" \
          >>"$WORK/cleanup.log"
        break
      fi
      echo "durable-zero timestamp=$timestamp cycle=$cycle scan=$scan elapsed-seconds=$cycle_elapsed result=zero" \
        >>"$WORK/cleanup.log"
    done
    if ((stable != 0)); then
      DURABLE_ZERO_STABLE_SECONDS=$((SECONDS-cycle_started))
      timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      if ((DURABLE_ZERO_STABLE_SECONDS < DURABLE_ZERO_REQUIRED_STABLE_SECONDS)); then
        stable=0
        echo "durable-zero timestamp=$timestamp cycle=$cycle phase=stable-window elapsed-seconds=$DURABLE_ZERO_STABLE_SECONDS result=too-short" \
          >>"$WORK/cleanup.log"
      elif pids="$(list_game_pids \
          "$WORK/processes-durable-zero-cycle-$cycle-final.json")"; then
        if [[ -z "$pids" ]]; then
          DURABLE_ZERO_STABLE=1
          DURABLE_ZERO_FINAL_ZERO=1
          DEVICE_PROCESS_STOPPED=1
          now="$(date +%s)"
          DURABLE_ZERO_FINISHED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
          DURABLE_ZERO_ELAPSED_SECONDS=$((now-DURABLE_ZERO_STARTED_EPOCH))
          echo "durable-zero timestamp=$DURABLE_ZERO_FINISHED_AT_UTC cycle=$cycle stable-seconds=$DURABLE_ZERO_STABLE_SECONDS final-zero=1 elapsed-seconds=$DURABLE_ZERO_ELAPSED_SECONDS result=pass" \
            >>"$WORK/cleanup.log"
          return 0
        fi
        ((DURABLE_ZERO_RESPAWNS_DETECTED+=1))
        DEVICE_FOREGROUND_PARKED=0
        echo "durable-zero timestamp=$timestamp cycle=$cycle stable-seconds=$DURABLE_ZERO_STABLE_SECONDS final-zero=0 result=respawn" \
          >>"$WORK/cleanup.log"
      else
        ((DURABLE_ZERO_QUERY_FAILURES+=1))
        echo "durable-zero timestamp=$timestamp cycle=$cycle stable-seconds=$DURABLE_ZERO_STABLE_SECONDS final-zero=0 result=query-failure" \
          >>"$WORK/cleanup.log"
      fi
    fi
  done

  # Exhaustion remains FAIL, but leave the device in an immediately verified
  # battery-safe state rather than returning while the last respawn is alive.
  DEVICE_FOREGROUND_PARKED=0
  DURABLE_ZERO_EMERGENCY_ZERO=0
  if ! stop_running_app 1; then
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if ((STOP_RUNNING_APP_QUERY_FAILED != 0)); then
      ((DURABLE_ZERO_QUERY_FAILURES+=1))
      result="query-failure"
    else
      ((DURABLE_ZERO_STOP_FAILURES+=1))
      result="failure"
    fi
    echo "durable-zero timestamp=$timestamp phase=emergency-stop result=$result" \
      >>"$WORK/cleanup.log"
  elif ! park_settings_foreground; then
    ((DURABLE_ZERO_PARK_FAILURES+=1))
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "durable-zero timestamp=$timestamp phase=emergency-park result=failure" \
      >>"$WORK/cleanup.log"
  elif ! pids="$(list_game_pids \
      "$WORK/processes-durable-zero-emergency-final.json")"; then
    ((DURABLE_ZERO_QUERY_FAILURES+=1))
    DEVICE_FOREGROUND_PARKED=0
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "durable-zero timestamp=$timestamp phase=emergency-final result=query-failure" \
      >>"$WORK/cleanup.log"
  elif [[ -n "$pids" ]]; then
    ((DURABLE_ZERO_RESPAWNS_DETECTED+=1))
    DEVICE_FOREGROUND_PARKED=0
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "durable-zero timestamp=$timestamp phase=emergency-final result=respawn" \
      >>"$WORK/cleanup.log"
  else
    DURABLE_ZERO_EMERGENCY_ZERO=1
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "durable-zero timestamp=$timestamp phase=emergency-final result=zero" \
      >>"$WORK/cleanup.log"
  fi
  now="$(date +%s)"
  DURABLE_ZERO_FINISHED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  DURABLE_ZERO_ELAPSED_SECONDS=$((now-DURABLE_ZERO_STARTED_EPOCH))
  DEVICE_PROCESS_STOPPED=0
  return 1
}

document_file_exists() {
  local name="$1" listing="$2"
  xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$listing" >/dev/null 2>>"$WORK/copy.log" || return 2
  python3 - "$listing" "$name" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1]))["result"]["files"]
matches = [entry for entry in entries if entry.get("name") == sys.argv[2]]
if not matches:
    raise SystemExit(1)
if len(matches) != 1:
    raise SystemExit(2)
resources = matches[0].get("resources", {})
if resources.get("isDirectory") is not False or resources.get("isSymbolicLink") is True:
    raise SystemExit(2)
PY
}

copy_document_file() {
  local name="$1" destination="$2" tag="$3"
  local attempt existence listed_once=0 provider_failed=0
  for ((attempt=1; attempt<=DOCUMENT_COPY_MAX_ATTEMPTS; ++attempt)); do
    rm -f "$destination"
    if document_file_exists \
        "$name" "$WORK/documents-$tag-attempt-$attempt.json"; then
      listed_once=1
      if xcrun devicectl device copy from --device "$DEVICE" \
          --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
          --user mobile --source "Documents/$name" --destination "$destination" \
          >/dev/null 2>>"$WORK/copy.log"; then
        return 0
      fi
      provider_failed=1
      echo "copy-retry file=$name attempt=$attempt/$DOCUMENT_COPY_MAX_ATTEMPTS result=provider-failure" \
        >>"$WORK/copy.log"
    else
      existence=$?
      if [[ "$existence" == 1 && "$listed_once" == 0 && "$provider_failed" == 0 ]]; then
        return 1
      fi
      provider_failed=1
      echo "copy-retry file=$name attempt=$attempt/$DOCUMENT_COPY_MAX_ATTEMPTS result=$([[ "$existence" == 1 ]] && echo ambiguous-missing || echo listing-provider-failure)" \
        >>"$WORK/copy.log"
    fi
    ((attempt == DOCUMENT_COPY_MAX_ATTEMPTS)) || sleep 1
  done
  rm -f "$destination"
  if ((listed_once != 0)); then
    echo "FAIL: provider listed Documents/$name but copy failed after $DOCUMENT_COPY_MAX_ATTEMPTS attempts" >&2
  else
    echo "FAIL: could not distinguish missing Documents/$name from provider failure after $DOCUMENT_COPY_MAX_ATTEMPTS attempts" >&2
  fi
  return 2
}

copy_container_file() {
  local remote="$1" destination="$2" tag="$3" attempt
  for ((attempt=1; attempt<=DOCUMENT_COPY_MAX_ATTEMPTS; ++attempt)); do
    rm -f "$destination"
    if xcrun devicectl device copy from --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --user mobile --source "$remote" --destination "$destination" \
        >"$WORK/copy-container-$tag-$attempt.log" 2>&1; then
      return 0
    fi
    ((attempt == DOCUMENT_COPY_MAX_ATTEMPTS)) || sleep 1
  done
  rm -f "$destination"
  return 1
}

copy_pipeline_cache_evidence() {
  [[ -n "$PIPELINE_ARCHIVE_PHASE" ]] || return 0
  copy_container_file "$ARCHIVE_DIR/$ARCHIVE_NAME" \
    "$WORK/$ARCHIVE_NAME" "$PIPELINE_ARCHIVE_PHASE-archive" || return 1
  copy_container_file "$ARCHIVE_DIR/$PROVENANCE_NAME" \
    "$WORK/$PROVENANCE_NAME" "$PIPELINE_ARCHIVE_PHASE-provenance" || return 1
  [[ -s "$WORK/$ARCHIVE_NAME" && -s "$WORK/$PROVENANCE_NAME" ]] || return 1
  rg -Fx "metallib-sha256=$METALLIB_SHA256" \
    "$WORK/$PROVENANCE_NAME" >/dev/null || return 1
  {
    echo "archive_sha256=$(shasum -a 256 "$WORK/$ARCHIVE_NAME" | awk '{print $1}')"
    echo "archive_bytes=$(stat -f '%z' "$WORK/$ARCHIVE_NAME")"
    echo "provenance_sha256=$(shasum -a 256 "$WORK/$PROVENANCE_NAME" | awk '{print $1}')"
  } >"$WORK/cache-after.txt"
}

snapshot_logs() {
  local suffix="$1" name stem extension status
  for name in log.txt stderr.log crash.log; do
    stem="${name%.*}"
    extension="${name##*.}"
    if copy_document_file "$name" "$WORK/$stem-$suffix.$extension" "$suffix-$stem"; then
      :
    else
      status=$?
      [[ "$status" == 1 ]] || return 1
      : >"$WORK/$stem-$suffix.missing"
    fi
  done
}

wait_for_game_pid() {
  local deadline pids
  deadline=$((SECONDS+GAME_PID_DISCOVERY_SECONDS))
  while ((SECONDS < deadline)); do
    GAME_PID_DISCOVERY_ATTEMPTS=$((GAME_PID_DISCOVERY_ATTEMPTS+1))
    if pids="$(list_game_pids \
        "$WORK/processes-launched-$GAME_PID_DISCOVERY_ATTEMPTS.json")"; then
      if [[ "$pids" =~ ^[1-9][0-9]*$ ]]; then
        require_console_running game-pid-discovery || return 1
        GAME_PID="$pids"
        return 0
      fi
      [[ -z "$pids" ]] || {
        echo "FAIL: expected exactly one launched game process" >&2
        return 1
      }
    fi
    require_console_running game-pid-discovery || return 1
    sleep 1
  done
  echo "FAIL: timed out discovering the launched game PID" >&2
  return 1
}

wait_for_marker() {
  local label="$1" literal="$2" timeout="$3" deadline marker_state
  deadline=$((SECONDS+timeout))
  while ((SECONDS < deadline)); do
    require_same_game_pid "$label" || return 1
    marker_state="$("$CONSOLE_SUPERVISOR" probe \
      --raw "$WORK/console-raw.log" --marker "$literal" \
      --mode "$SCRIPT_MODE" --nonce "$NONCE")" || return 1
    case "$marker_state" in
      script-fail)
        echo "FAIL: semantic script reported FAIL while waiting for $label" >&2
        return 1
        ;;
      duplicate)
        echo "FAIL: duplicate current-nonce marker while waiting for $label" >&2
        return 1
        ;;
      marker|pending) ;;
      *)
        echo "FAIL: invalid console marker probe state: $marker_state" >&2
        return 1
        ;;
    esac
    require_console_running "marker-$label" || return 1
    if [[ "$marker_state" == marker ]]; then
      CONSOLE_MARKER_HITS=$((CONSOLE_MARKER_HITS+1))
      echo "console-marker timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') label=$label nonce=$NONCE result=exact-hit" \
        >>"$WORK/console-launcher.log"
      return 0
    fi
    sleep 1
  done
  echo "FAIL: timed out waiting for $label" >&2
  return 1
}

preserve_evidence() {
  local result="$1" timestamp out candidate
  if ((DURABLE_ZERO_STABLE == 0 || DURABLE_ZERO_FINAL_ZERO == 0 ||
       DURABLE_ZERO_STABLE_SECONDS < DURABLE_ZERO_REQUIRED_STABLE_SECONDS)); then
    DEVICE_PROCESS_STOPPED=0
  fi
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  out="$ROOT/build/device-semantic-ui-lifecycle/$EXPECTED_SHA/$result-$timestamp-$$"
  mkdir -p "$out"
  for candidate in apps.json settings-app.json device-selection.log cleanup.log \
      copy.log console-raw.log console-before-stop.log \
      console-before-stop.missing console-launch.json console-launcher.log \
      console-status.json console-stop-request console-supervisor.log \
      activate-settings.log activate-game.log \
      park-settings.log \
      processes-launched.json processes-background-proof.json \
      processes-foreground-proof.json processes-final-zero.json \
      processes-cleanup-final-zero.json log-final.txt \
      stderr-final.log stderr-final.missing crash-final.log crash-final.missing \
      "$ARCHIVE_NAME" "$PROVENANCE_NAME" cache-after.txt archive-summary.txt; do
    [[ -f "$WORK/$candidate" ]] || continue
    ditto "$WORK/$candidate" "$out/$candidate"
  done
  for candidate in "$WORK"/devices-*.json "$WORK"/xcdevices-*.json; do
    [[ -f "$candidate" ]] || continue
    ditto "$candidate" "$out/$(basename "$candidate")"
  done
  for candidate in "$WORK"/processes-launched-*.json \
      "$WORK"/processes-durable-zero-*.json; do
    [[ -f "$candidate" ]] || continue
    ditto "$candidate" "$out/$(basename "$candidate")"
  done
  {
    echo "result=$result"
    echo "source_sha=$EXPECTED_SHA"
    echo "device_udid=$DEVICE_UDID"
    echo "device_selection_method=$DEVICE_SELECTION_METHOD"
    echo "device_selection_attempts=$DEVICE_SELECTION_ATTEMPTS_USED"
    echo "bundle_id=$BUNDLE_ID"
    echo "save_slot=$SAVE_SLOT"
    echo "script_mode=$SCRIPT_MODE"
    echo "pipeline_archive_phase=${PIPELINE_ARCHIVE_PHASE:-none}"
    echo "nonce=$NONCE"
    echo "pre_crash_state=$PRE_CRASH_STATE"
    echo "post_crash_state=$POST_CRASH_STATE"
    echo "game_pid=$GAME_PID"
    echo "pid_after_background=$PID_AFTER_BACKGROUND"
    echo "pid_after_foreground=$PID_AFTER_FOREGROUND"
    echo "console_launcher_pid=$CONSOLE_LAUNCHER_PID"
    echo "console_startup_pid=$CONSOLE_STARTUP_PID"
    echo "console_startup_signal_status=$CONSOLE_STARTUP_SIGNAL_STATUS"
    echo "console_launcher_status=$CONSOLE_LAUNCHER_STATUS"
    echo "console_launcher_exit_code=$CONSOLE_LAUNCHER_EXIT_CODE"
    echo "console_supervisor_exit_code=$CONSOLE_SUPERVISOR_EXIT_CODE"
    echo "console_devicectl_pid=$CONSOLE_DEVICECTL_PID"
    echo "console_parent_pid=$CONSOLE_PARENT_PID"
    echo "console_stream_state=$CONSOLE_STREAM_STATE"
    echo "console_observer_state=$CONSOLE_OBSERVER_STATE"
    echo "console_observer_errors=$CONSOLE_OBSERVER_ERRORS"
    echo "console_status_forced_kill=$CONSOLE_STATUS_FORCED_KILL"
    echo "console_launcher_reaped=$CONSOLE_LAUNCHER_REAPED"
    echo "console_supervisor_reaped=$CONSOLE_SUPERVISOR_REAPED"
    echo "console_launcher_premature_exit=$CONSOLE_LAUNCHER_PREMATURE_EXIT"
    echo "console_launcher_forced_kill=$CONSOLE_LAUNCHER_FORCED_KILL"
    echo "console_stop_requested=$CONSOLE_STOP_REQUESTED"
    echo "console_prestop_liveness=$CONSOLE_PRESTOP_LIVENESS"
    echo "console_launcher_started_at_utc=$CONSOLE_LAUNCHER_STARTED_AT_UTC"
    echo "console_launcher_finished_at_utc=$CONSOLE_LAUNCHER_FINISHED_AT_UTC"
    echo "console_raw_bytes_before_stop=$CONSOLE_RAW_BYTES_BEFORE_STOP"
    echo "console_marker_hits=$CONSOLE_MARKER_HITS"
    echo "game_pid_discovery_attempts=$GAME_PID_DISCOVERY_ATTEMPTS"
    echo "same_pid_background=$([[ -n "$GAME_PID" && "$PID_AFTER_BACKGROUND" == "$GAME_PID" ]] && echo 1 || echo 0)"
    echo "same_pid_foreground=$([[ -n "$GAME_PID" && "$PID_AFTER_FOREGROUND" == "$GAME_PID" ]] && echo 1 || echo 0)"
    echo "device_process_stopped=$DEVICE_PROCESS_STOPPED"
    echo "device_foreground_parked=$DEVICE_FOREGROUND_PARKED"
    echo "durable_zero_max_cycles=$DURABLE_ZERO_MAX_CYCLES"
    echo "durable_zero_scans_per_cycle=$DURABLE_ZERO_SCANS_PER_CYCLE"
    echo "durable_zero_interval_seconds=$DURABLE_ZERO_INTERVAL_SECONDS"
    echo "durable_zero_required_stable_seconds=$DURABLE_ZERO_REQUIRED_STABLE_SECONDS"
    echo "durable_zero_cycles_used=$DURABLE_ZERO_CYCLES_USED"
    echo "durable_zero_scans_completed=$DURABLE_ZERO_SCANS_COMPLETED"
    echo "durable_zero_respawns_detected=$DURABLE_ZERO_RESPAWNS_DETECTED"
    echo "durable_zero_query_failures=$DURABLE_ZERO_QUERY_FAILURES"
    echo "durable_zero_stop_failures=$DURABLE_ZERO_STOP_FAILURES"
    echo "durable_zero_park_failures=$DURABLE_ZERO_PARK_FAILURES"
    echo "durable_zero_stable=$DURABLE_ZERO_STABLE"
    echo "durable_zero_stable_seconds=$DURABLE_ZERO_STABLE_SECONDS"
    echo "durable_zero_final_zero=$DURABLE_ZERO_FINAL_ZERO"
    echo "durable_zero_emergency_zero=$DURABLE_ZERO_EMERGENCY_ZERO"
    echo "durable_zero_started_at_utc=$DURABLE_ZERO_STARTED_AT_UTC"
    echo "durable_zero_finished_at_utc=$DURABLE_ZERO_FINISHED_AT_UTC"
    echo "durable_zero_elapsed_seconds=$DURABLE_ZERO_ELAPSED_SECONDS"
  } >"$out/result.txt"
  publish_evidence_path "$out"
  echo "evidence: $out"
}

finalize_runtime() {
  local require_alive="${1:-0}" status=0 durable_zero=0
  snapshot_console_before_stop || status=1
  if ((require_alive != 0)); then
    require_same_game_pid before-cleanup || status=1
    if require_console_running before-stop; then
      CONSOLE_PRESTOP_LIVENESS=1
    else
      status=1
    fi
  fi
  if ensure_durable_zero; then
    durable_zero=1
  else
    status=1
  fi
  reap_console_launcher || status=1
  ((CONSOLE_LAUNCHER_REAPED != 0)) || status=1
  if ((durable_zero != 0 && CONSOLE_LAUNCHER_REAPED != 0)); then
    snapshot_logs final || status=1
  else
    status=1
  fi
  if ((status == 0)); then
    FINALIZED=1
  fi
  return "$status"
}

cleanup() {
  local status=$? cleanup_status=0 remaining=""
  trap - EXIT INT TERM HUP
  set +e
  if ((RUNTIME_ARMED != 0 && FINALIZED == 0)); then
    finalize_runtime || cleanup_status=1
  elif [[ -n "$DEVICE" && "$FINALIZED" == 0 ]]; then
    stop_running_app 1 || cleanup_status=1
    if ((SETTINGS_AVAILABLE != 0)); then
      park_settings_foreground || cleanup_status=1
    fi
    if remaining="$(list_game_pids "$WORK/processes-cleanup-final-zero.json")" &&
       [[ -z "$remaining" ]]; then
      DURABLE_ZERO_EMERGENCY_ZERO=1
    else
      DEVICE_FOREGROUND_PARKED=0
      cleanup_status=1
    fi
  fi
  if ((status != 0 || cleanup_status != 0)); then
    preserve_evidence FAIL
  fi
  [[ "$WORK" == /var/folders/*/T/opengothic-device-semantic.* ]] && rm -rf "$WORK"
  if ((status == 0 && cleanup_status != 0)); then
    exit 1
  fi
  exit "$status"
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
    device.get("identifier")
    for device in xcdevices
    if not device.get("simulator")
    and device.get("available")
    and device.get("interface") == "usb"
    and device.get("platform") == "com.apple.platform.iphoneos"
}
matches = [
    device for device in devices
    if device.get("hardwareProperties", {}).get("platform") == "iOS"
    and device.get("hardwareProperties", {}).get("reality") == "physical"
    and (requested
         or device.get("connectionProperties", {}).get("tunnelState") == "connected"
         or device.get("hardwareProperties", {}).get("udid") in usb_udids)
    and (not requested or requested in (
        device.get("identifier"),
        device.get("hardwareProperties", {}).get("udid")))
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
print(device["identifier"] + "\t" + device["hardwareProperties"]["udid"]
      + "\t" + method)
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
BUNDLE_ID="$(python3 - "$WORK/apps.json" "$BASE_BUNDLE_ID" \
    "${OPENGOTHIC_IOS_BUNDLE_ID:-}" <<'PY'
import json, re, sys
apps = json.load(open(sys.argv[1]))["result"]["apps"]
base, requested = sys.argv[2], sys.argv[3]
pattern = re.compile(re.escape(base) + r"\.[A-Z0-9]{10}$")
matches = [app["bundleIdentifier"] for app in apps
           if pattern.fullmatch(app["bundleIdentifier"])]
if requested:
    matches = [bundle for bundle in matches if bundle == requested]
if len(matches) != 1:
    raise SystemExit(f"expected one installed {base}.<TeamID> app, found {len(matches)}")
print(matches[0])
PY
)" || fail "could not identify the existing OpenGothic container"
TEAM_ID="${OPENGOTHIC_IOS_TEAM_ID:-${BUNDLE_ID##*.}}"
[[ "$BUNDLE_ID" == "$BASE_BUNDLE_ID.$TEAM_ID" && "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] ||
  fail "bundle id must preserve the existing team-id suffix"

xcrun devicectl device info apps --device "$DEVICE" --include-default-apps \
  --bundle-id com.apple.Preferences --json-output "$WORK/settings-app.json" >/dev/null ||
  fail "could not query the Settings app"
python3 - "$WORK/settings-app.json" <<'PY' || fail "Settings is not available for activation"
import json, sys
apps = json.load(open(sys.argv[1]))["result"]["apps"]
if [app.get("bundleIdentifier") for app in apps] != ["com.apple.Preferences"]:
    raise SystemExit(1)
PY
SETTINGS_AVAILABLE=1

stop_running_app 1 || fail "pre-test game cleanup failed"
snapshot_logs pre-test || fail "could not snapshot pre-test logs"
if [[ -f "$WORK/crash-pre-test.log" ]]; then
  PRE_CRASH_STATE="sha256:$(shasum -a 256 "$WORK/crash-pre-test.log" | awk '{print $1}')"
elif [[ ! -f "$WORK/crash-pre-test.missing" ]]; then
  fail "pre-test crash sentinel has unknown state"
fi

begin_console_startup_critical_section
RUNTIME_ARMED=1
CONSOLE_LAUNCHER_STARTED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
CONSOLE_LAUNCHER_STATUS="running"
CONSOLE_STREAM_STATE="starting"
"$CONSOLE_SUPERVISOR" supervise \
  --raw "$WORK/console-raw.log" --status "$WORK/console-status.json" \
  --stop-request "$WORK/console-stop-request" \
  --instance-token "$CONSOLE_INSTANCE_TOKEN" -- \
  xcrun devicectl device process launch --device "$DEVICE" \
  --terminate-existing --console --json-output "$WORK/console-launch.json" -- \
  "$BUNDLE_ID" -nomenu -save "$SAVE_SLOT" \
  "-renderer-ios-semantic-script=$SCRIPT_MODE" \
  "-renderer-ios-semantic-nonce=$NONCE" \
  >"$WORK/console-supervisor.log" 2>&1 &
CONSOLE_STARTUP_PID=$!
finish_console_startup_critical_section || fail "could not persist console supervisor PID"
echo "console-launcher timestamp=$CONSOLE_LAUNCHER_STARTED_AT_UTC supervisor-pid=$CONSOLE_LAUNCHER_PID status=started" \
  >>"$WORK/console-launcher.log"
wait_for_game_pid || fail "could not discover launched game process"

ARMED="RendererIOS semantic script: ARMED mode=$SCRIPT_MODE nonce=$NONCE"
READY="RendererIOS semantic script: state=READY_FOR_LIFECYCLE nonce=$NONCE"
WAIT_FOREGROUND="RendererIOS semantic script: state=WAIT_WILL_ENTER_FOREGROUND nonce=$NONCE"
PASS_MARKER="RendererIOS semantic script: SCRIPT PASS mode=$SCRIPT_MODE nonce=$NONCE"
wait_for_marker armed "$ARMED" 30 || fail "current nonce did not arm"
python3 - "$WORK/console-raw.log" "$EXPECTED_SHA" <<'PY' ||
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
expected = {sys.argv[2], sys.argv[2] + "-local"}
builds = re.findall(r"^RendererIOS shell: [^\r\n]* build=([^\s]+) gpu=", log, re.MULTILINE)
if len(builds) != 1 or builds[0] not in expected:
    raise SystemExit(f"expected one exact build in {sorted(expected)}, found {builds}")
PY
  fail "armed runtime does not identify exact source SHA $EXPECTED_SHA"
wait_for_marker ready "$READY" 180 || fail "semantic UI sequence did not become lifecycle-ready"

xcrun devicectl device process launch --device "$DEVICE" --activate \
  com.apple.Preferences >"$WORK/activate-settings.log" 2>&1 ||
  fail "Settings activation failed"
wait_for_marker background "$WAIT_FOREGROUND" 30 ||
  fail "game did not enter background with the same PID"
PID_AFTER_BACKGROUND="$(list_game_pids "$WORK/processes-background-proof.json")"
[[ "$PID_AFTER_BACKGROUND" == "$GAME_PID" ]] || fail "game PID changed in background"

xcrun devicectl device process launch --device "$DEVICE" --activate \
  "$BUNDLE_ID" >"$WORK/activate-game.log" 2>&1 ||
  fail "existing game activation failed"
require_same_game_pid foreground-activation || fail "game PID changed on foreground activation"
PID_AFTER_FOREGROUND="$(list_game_pids "$WORK/processes-foreground-proof.json")"
[[ "$PID_AFTER_FOREGROUND" == "$GAME_PID" ]] || fail "game PID changed in foreground"
wait_for_marker pass "$PASS_MARKER" 45 || fail "terminal resume evidence did not reach SCRIPT PASS"
if [[ -n "$PIPELINE_ARCHIVE_PHASE" ]]; then
  if [[ "$PIPELINE_ARCHIVE_PHASE" == inventory-cold ]]; then
    ARCHIVE_POST="RendererIOS pipeline archive snapshot-flush: point=post presents=300 attempt=1 success=1 fail=0 invoked=1 result=1 bounded=1 settled=1"
  else
    ARCHIVE_POST="RendererIOS pipeline archive snapshot-flush: point=post presents=300 attempt=0 success=0 fail=0 invoked=0 result=0 bounded=0 settled=1"
  fi
  wait_for_marker archive-post "$ARCHIVE_POST" 180 ||
    fail "exact $PIPELINE_ARCHIVE_PHASE archive POST at present 300 was not observed"
fi

finalize_runtime 1 || fail "battery-safe final cleanup/evidence pull failed"
RUNTIME_ARMED=0
copy_pipeline_cache_evidence || fail "could not preserve pipeline archive cache evidence"
if [[ -f "$WORK/crash-final.log" ]]; then
  POST_CRASH_STATE="sha256:$(shasum -a 256 "$WORK/crash-final.log" | awk '{print $1}')"
elif [[ ! -f "$WORK/crash-final.missing" ]]; then
  fail "final crash sentinel has unknown state"
fi
[[ "$POST_CRASH_STATE" == "$PRE_CRASH_STATE" ]] || fail "crash.log changed during semantic run"
[[ -s "$WORK/log-final.txt" ]] || fail "device produced no final log.txt"
python3 - "$WORK/log-final.txt" "$EXPECTED_SHA" <<'PY' ||
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
expected = {sys.argv[2], sys.argv[2] + "-local"}
builds = re.findall(r"^RendererIOS shell: [^\r\n]* build=([^\s]+) gpu=", log, re.MULTILINE)
if len(builds) != 1 or builds[0] not in expected:
    raise SystemExit(f"expected one exact build in {sorted(expected)}, found {builds}")
PY
  fail "runtime log does not identify exact source SHA $EXPECTED_SHA"
VALIDATOR_ARGS=("$WORK/log-final.txt" --nonce "$NONCE")
[[ ! -f "$WORK/stderr-final.log" ]] ||
  VALIDATOR_ARGS+=(--stderr "$WORK/stderr-final.log")
"$VALIDATOR" "${VALIDATOR_ARGS[@]}" || fail "semantic evidence validation failed"
if [[ -n "$PIPELINE_ARCHIVE_PHASE" ]]; then
  python3 "$PIPELINE_VALIDATOR" \
    --phase "$PIPELINE_ARCHIVE_PHASE" \
    --scenario save \
    --log "$WORK/log-final.txt" \
    --source-sha "$EXPECTED_SHA" \
    --metallib-sha256 "$METALLIB_SHA256" \
    --summary "$WORK/archive-summary.txt" ||
    fail "$PIPELINE_ARCHIVE_PHASE pipeline archive evidence validation failed"
fi

preserve_evidence PASS
echo "SEMANTIC FALLBACK PASS — Inventory/QuickRings/lifecycle; app stopped"
