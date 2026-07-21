#!/usr/bin/env bash
# Host-neutral mocks for semantic console finalization and early-exit handling.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$ROOT/ios/device-test/run-semantic-ui-lifecycle-test.sh"
CONSOLE_SUPERVISOR="$ROOT/ios/device-test/semantic-console-supervisor.py"
WORK="$(mktemp -d -t opengothic-semantic-console-mock)"
trap '[[ "$WORK" == /var/folders/*/T/opengothic-semantic-console-mock.* ]] && rm -rf "$WORK"' EXIT

extract_function() {
  local name="$1"
  sed -n "/^$name() {$/,/^}$/p" "$HARNESS"
}

fail_test() {
  echo "FAIL: semantic console harness mock: $*" >&2
  exit 1
}

ORDER=""
MOCK_DURABLE_RESULT=0
CONSOLE_LAUNCHER_REAPED=0
FINALIZED=0
snapshot_console_before_stop() { ORDER+="raw,"; }
require_same_game_pid() { [[ "$1" == before-cleanup ]]; ORDER+="pid,"; }
require_console_running() { [[ "$1" == before-stop ]]; ORDER+="live,"; }
ensure_durable_zero() { ORDER+="durable,"; return "$MOCK_DURABLE_RESULT"; }
reap_console_launcher() { ORDER+="reap,"; CONSOLE_LAUNCHER_REAPED=1; }
snapshot_logs() { [[ "$1" == final ]]; ORDER+="final,"; }
eval "$(extract_function finalize_runtime)"

finalize_runtime 1 || fail_test "successful finalize mock failed"
[[ "$ORDER" == "raw,pid,live,durable,reap,final," ]] ||
  fail_test "successful finalize order is $ORDER"
[[ "$FINALIZED" == 1 ]] || fail_test "successful finalize was not committed"

ORDER=""
MOCK_DURABLE_RESULT=1
CONSOLE_LAUNCHER_REAPED=0
FINALIZED=0
if finalize_runtime 1; then
  fail_test "durable failure unexpectedly finalized"
fi
[[ "$ORDER" == "raw,pid,live,durable,reap," ]] ||
  fail_test "failure finalize order is $ORDER"
[[ "$FINALIZED" == 0 ]] || fail_test "failure finalize was committed"

eval "$(extract_function wait_for_marker)"
NONCE="0123456789abcdef0123456789abcdef"
SCRIPT_MODE="save-ui-lifecycle-v1"
GAME_PID=77
CONSOLE_LAUNCHER_EXIT_CODE=23
CONSOLE_LAUNCHER_PREMATURE_EXIT=0
CONSOLE_MARKER_HITS=0
CAPTURE_CONTEXT=""
require_same_game_pid() { return 0; }
capture_console_launcher_exit() { CAPTURE_CONTEXT="$1"; }
require_console_running() {
  CONSOLE_LAUNCHER_PREMATURE_EXIT=1
  capture_console_launcher_exit premature-exit
  return 1
}
printf 'unrelated complete line\n' >"$WORK/console-raw.log"
if wait_for_marker early-exit "missing marker" 5 2>/dev/null; then
  fail_test "premature console exit was accepted"
fi
[[ "$CONSOLE_LAUNCHER_PREMATURE_EXIT" == 1 ]] ||
  fail_test "premature console exit was not recorded"
[[ "$CAPTURE_CONTEXT" == premature-exit ]] ||
  fail_test "premature console exit status was not captured"

require_console_running() { return 0; }
MARKER="RendererIOS semantic script: state=READY_FOR_LIFECYCLE nonce=$NONCE"
printf '%s\n' "$MARKER" >"$WORK/console-raw.log"
wait_for_marker exact "$MARKER" 5 || fail_test "exact console marker was rejected"
[[ "$CONSOLE_MARKER_HITS" == 1 ]] || fail_test "exact marker hit was not recorded"

printf '%s\n%s\n' "$MARKER" "$MARKER" >"$WORK/console-raw.log"
if wait_for_marker duplicate "$MARKER" 5 2>/dev/null; then
  fail_test "duplicate console marker was accepted"
fi

printf '%s\n' \
  "RendererIOS semantic script: SCRIPT FAIL mode=$SCRIPT_MODE nonce=$NONCE state=WAIT_WORLD reason=mock" \
  >"$WORK/console-raw.log"
if wait_for_marker script-fail "$MARKER" 5 2>/dev/null; then
  fail_test "current-nonce SCRIPT FAIL was accepted"
fi

for name in request_console_stop defer_console_startup_signal \
    begin_console_startup_critical_section \
    finish_console_startup_critical_section; do
  eval "$(extract_function "$name")"
  export -f "$name"
done
startup_signal_work="$WORK/startup-signal"
mkdir -p "$startup_signal_work"
startup_signal_status=0
if STARTUP_SIGNAL_WORK="$startup_signal_work" bash -c '
  set -euo pipefail
  WORK="$STARTUP_SIGNAL_WORK"
  CONSOLE_INSTANCE_TOKEN="startup-signal-token"
  CONSOLE_STOP_REQUESTED=0
  CONSOLE_STARTUP_PID=""
  CONSOLE_STARTUP_SIGNAL_STATUS=0
  CONSOLE_LAUNCHER_PID=""
  RUNTIME_ARMED=0
  startup_signal_cleanup() {
    if ((RUNTIME_ARMED != 0)); then
      request_console_stop || true
      printf "%s\n" "$CONSOLE_LAUNCHER_PID" >"$WORK/startup-cleanup-pid"
    fi
  }
  trap startup_signal_cleanup EXIT
  trap "exit 130" INT
  trap "exit 143" TERM
  trap "exit 129" HUP
  begin_console_startup_critical_section
  RUNTIME_ARMED=1
  kill -TERM "$$"
  CONSOLE_STARTUP_PID=4242
  finish_console_startup_critical_section
'; then
  fail_test "deferred startup TERM unexpectedly returned success"
else
  startup_signal_status=$?
fi
[[ "$startup_signal_status" == 143 ]] ||
  fail_test "deferred startup TERM returned $startup_signal_status"
[[ "$(<"$startup_signal_work/console-stop-request")" == startup-signal-token ]] ||
  fail_test "startup TERM cleanup did not publish the authenticated stop token"
[[ "$(<"$startup_signal_work/startup-cleanup-pid")" == 4242 ]] ||
  fail_test "startup TERM cleanup ran before the supervisor PID handoff"

(
  readonly CONSOLE_REAP_GRACE_SECONDS=3
  CONSOLE_INSTANCE_TOKEN="fedcba9876543210fedcba9876543210"
  CONSOLE_PARENT_PID=""
  CONSOLE_LAUNCHER_PID=""
  CONSOLE_LAUNCHER_STATUS="running"
  CONSOLE_LAUNCHER_EXIT_CODE=""
  CONSOLE_SUPERVISOR_EXIT_CODE=""
  CONSOLE_DEVICECTL_PID=""
  CONSOLE_STREAM_STATE="starting"
  CONSOLE_OBSERVER_STATE="OBSERVER_ERROR"
  CONSOLE_OBSERVER_ERRORS=0
  CONSOLE_STATUS_FORCED_KILL=0
  CONSOLE_LAUNCHER_REAPED=0
  CONSOLE_SUPERVISOR_REAPED=0
  CONSOLE_LAUNCHER_PREMATURE_EXIT=0
  CONSOLE_LAUNCHER_FORCED_KILL=0
  CONSOLE_STOP_REQUESTED=0
  CONSOLE_LAUNCHER_FINISHED_AT_UTC=""

  for name in read_console_status observe_console_launcher \
      capture_console_launcher_exit request_console_stop \
      reap_console_launcher require_console_running; do
    eval "$(extract_function "$name")"
  done

  "$CONSOLE_SUPERVISOR" supervise \
    --raw "$WORK/observer-console-raw.log" \
    --status "$WORK/console-status.json" \
    --stop-request "$WORK/console-stop-request" \
    --instance-token "$CONSOLE_INSTANCE_TOKEN" -- \
    /bin/sh -c 'while :; do sleep 1; done' \
    >"$WORK/observer-supervisor.log" 2>&1 &
  CONSOLE_LAUNCHER_PID=$!
  CONSOLE_PARENT_PID="$(ps -p "$CONSOLE_LAUNCHER_PID" -o ppid= | tr -d '[:space:]')"
  cleanup_observer_mock() {
    if kill -0 "$CONSOLE_LAUNCHER_PID" 2>/dev/null; then
      printf '%s\n' "$CONSOLE_INSTANCE_TOKEN" >"$WORK/console-stop-request"
      sleep 1
      kill -KILL "$CONSOLE_LAUNCHER_PID" 2>/dev/null || true
    fi
    wait "$CONSOLE_LAUNCHER_PID" 2>/dev/null || true
  }
  trap cleanup_observer_mock EXIT

  for _ in 1 2 3 4 5; do
    if read_console_status && [[ "$CONSOLE_STREAM_STATE" == running ]]; then
      break
    fi
    sleep 1
  done
  [[ "$CONSOLE_STREAM_STATE" == running ]] ||
    fail_test "observer mock supervisor did not start"
  observe_console_launcher
  [[ "$CONSOLE_OBSERVER_STATE" == RUNNING ]] ||
    fail_test "live supervisor was not observed as RUNNING"

  original_status="$(<"$WORK/console-status.json")"
  python3 - "$WORK/console-status.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text())
payload["state"] = "exited"
payload["returncode"] = 0
payload["finished_at_utc"] = "2026-07-22T00:00:00Z"
path.write_text(json.dumps(payload) + "\n")
PY
  if require_console_running terminal-status-live 2>/dev/null; then
    fail_test "terminal status from a still-live supervisor was accepted"
  fi
  [[ "$CONSOLE_OBSERVER_STATE" == RUNNING &&
     "$CONSOLE_SUPERVISOR_REAPED" == 0 ]] ||
    fail_test "terminal-status-live race performed an unsafe wait"
  printf '%s\n' "$original_status" >"$WORK/console-status.json"

  original_parent="$CONSOLE_PARENT_PID"
  CONSOLE_PARENT_PID=1
  if require_console_running identity-mismatch 2>/dev/null; then
    fail_test "supervisor parent identity mismatch was accepted"
  fi
  [[ "$CONSOLE_OBSERVER_STATE" == OBSERVER_ERROR &&
     "$CONSOLE_SUPERVISOR_REAPED" == 0 ]] ||
    fail_test "identity mismatch performed an unsafe wait"
  CONSOLE_PARENT_PID="$original_parent"

  printf '{injected-corrupt-status\n' >"$WORK/console-status.json"
  observer_started=$SECONDS
  if require_console_running injected-status 2>/dev/null; then
    fail_test "corrupt live-supervisor status was accepted"
  fi
  ((SECONDS-observer_started < 2)) ||
    fail_test "corrupt status triggered a blocking supervisor wait"
  [[ "$CONSOLE_OBSERVER_STATE" == OBSERVER_ERROR ]] ||
    fail_test "corrupt live status was not classified OBSERVER_ERROR"
  [[ "$CONSOLE_SUPERVISOR_REAPED" == 0 ]] ||
    fail_test "observer error performed an unsafe wait"

  reap_console_launcher || fail_test "authenticated supervisor stop/reap failed"
  [[ "$CONSOLE_STOP_REQUESTED" == 1 && "$CONSOLE_LAUNCHER_REAPED" == 1 ]] ||
    fail_test "observer-error cleanup did not complete bounded reap"
  [[ "$CONSOLE_LAUNCHER_FORCED_KILL" == 1 ]] ||
    fail_test "supervisor did not record its owned-child kill"
  trap - EXIT
)

echo "PASS — semantic console harness mocks"
