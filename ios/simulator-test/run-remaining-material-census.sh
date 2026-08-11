#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROJECT="$ROOT/ios/simulator-test/RemainingMaterialCensusAdapter.xcodeproj"
SPEC="$ROOT/ios/simulator-test/specs/p21e2a-remaining-material-census-v1.json"
VALIDATOR="$ROOT/ios/device-test/validate-remaining-material-census-log.py"
BUILD_SHA=${OPENGOTHIC_RENDERER_IOS_BUILD_SHA:-$(git -C "$ROOT" rev-parse HEAD)}
RUN_STAMP=$(date -u +%Y%m%d%H%M%S)
RUN_ID="${RUN_STAMP}-$$"
BUNDLE_ID="opengothic.rendererios.remaining-material-census-adapter.r${RUN_STAMP}p$$"
DERIVED_DATA=${REMAINING_CENSUS_DERIVED_DATA:-"${TMPDIR:-/tmp}/opengothic-remaining-census-derived/$RUN_ID"}
OUTPUT_DIR=${REMAINING_CENSUS_OUTPUT_DIR:-"$ROOT/build/simulator-test/remaining-material-census/$RUN_ID"}
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/RemainingMaterialCensusAdapter.app"
LOG="$OUTPUT_DIR/log.txt"
RESULT="$OUTPUT_DIR/result.txt"
ARTIFACT="$OUTPUT_DIR/remaining-material-census-v1.bin"
SIMULATOR_UDID=${SIMULATOR_UDID:-}
REQUIRED_RUNTIME_MAJOR=27
installed=0
booted_here=0
cleanup_done=0
selection_json=
selection_value_file=
container_value_file=
active_supervisor_pid=
outer_signal_status=0
outer_signal_name=
outer_signal_generation=0
last_outer_signal_name=
in_cleanup=0
unset REMAINING_CENSUS_BOUNDED_CONSTRUCTION_MARKER
unset REMAINING_CENSUS_BOUNDED_CLEANUP_MARKER
unset REMAINING_CENSUS_OUTER_ASSIGNMENT_MARKER

forward_outer_signal() {
  number=$1
  status=$2
  outer_signal_generation=$((outer_signal_generation + 1))
  last_outer_signal_name=$number
  if [ "$outer_signal_status" -eq 0 ]; then
    outer_signal_status=$status
    outer_signal_name=$number
  fi
  if [ -n "$active_supervisor_pid" ]; then
    kill -"$number" "$active_supervisor_pid" 2>/dev/null || true
  fi
}

run_bounded() {
  timeout=$1
  shift
  if [ "$outer_signal_status" -ne 0 ] && [ "$in_cleanup" -eq 0 ]; then
    return "$outer_signal_status"
  fi
  signal_generation_before=$outer_signal_generation
  python3 - "$timeout" "$@" <<'PY' &
import os
import signal
import subprocess
import sys
import time

timeout = int(sys.argv[1])
argv = sys.argv[2:]
if not 1 <= timeout <= 3600 or not argv:
    raise SystemExit(2)
process = None
owned_pgid = None
caught = None
cleaning = False
signals_blocked = False
watched = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}

class CaughtSignal(Exception):
    pass

def handle(number, _frame):
    global caught, cleaning
    if caught is not None:
        return
    caught = number
    if cleaning:
        return
    raise CaughtSignal()

def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # macOS can report EPERM for a just-reaped orphaned group. Resolve the
        # ambiguity with a bounded exact PGID census; any census failure is
        # still fail-closed.
        census = subprocess.run(
            ["/bin/ps", "-axo", "pgid="], check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1.0,
        )
        if census.returncode != 0 or len(census.stdout) > 4 * 1024 * 1024:
            raise RuntimeError("bounded process-group census failed")
        try:
            return pgid in {int(value) for value in census.stdout.split()}
        except ValueError as error:
            raise RuntimeError("bounded process-group census malformed") from error

def stop_group(proc, pgid):
    global cleaning
    cleaning = True
    marker = os.environ.get("REMAINING_CENSUS_BOUNDED_CLEANUP_MARKER")
    if marker:
        with open(marker, "w", encoding="ascii") as stream:
            stream.write(str(os.getpid()))
    for number, grace in ((signal.SIGTERM, 2.0), (signal.SIGKILL, 2.0)):
        proc.poll()
        if not group_exists(pgid):
            break
        try:
            os.killpg(pgid, number)
        except ProcessLookupError:
            break
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            proc.poll()
            if not group_exists(pgid):
                break
            time.sleep(0.05)
    try:
        proc.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        pass
    if group_exists(pgid):
        raise RuntimeError("bounded child process group survived cleanup")

previous = {}
for number in watched:
    previous[number] = signal.getsignal(number)
timed_out = False
unexpected_group = False
previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, watched)
signals_blocked = True
for number in watched:
    signal.signal(number, handle)

def child_restore_mask():
    marker = os.environ.get("REMAINING_CENSUS_BOUNDED_CONSTRUCTION_MARKER")
    if marker:
        with open(marker, "w", encoding="ascii") as stream:
            stream.write(str(os.getpid()))
        time.sleep(0.5)
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

try:
    process = subprocess.Popen(argv, start_new_session=True,
                               preexec_fn=child_restore_mask)
    owned_pgid = process.pid
    try:
        actual_pgid = os.getpgid(process.pid)
    except ProcessLookupError:
        actual_pgid = process.pid
    if actual_pgid != process.pid:
        raise RuntimeError("bounded child is not its process-group leader")
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    signals_blocked = False
    deadline = time.monotonic() + timeout
    while process.poll() is None:
        if time.monotonic() >= deadline:
            timed_out = True
            break
        time.sleep(0.05)
except CaughtSignal:
    pass
finally:
    cleaning = True
    leader_done = process is not None and process.poll() is not None
    if signals_blocked:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        signals_blocked = False
    if process is not None and owned_pgid is not None:
        group_live = group_exists(owned_pgid)
        if leader_done and group_live:
            unexpected_group = True
        if process.poll() is None or group_live:
            stop_group(process, owned_pgid)
    for number, handler in previous.items():
        signal.signal(number, handler)
if caught is not None:
    raise SystemExit(128 + caught)
if timed_out:
    raise SystemExit(124)
if unexpected_group:
    raise SystemExit(1)
if process is None or process.returncode is None:
    raise SystemExit(1)
raise SystemExit(process.returncode)
PY
  supervisor=$!
  if [ -n "${REMAINING_CENSUS_OUTER_ASSIGNMENT_MARKER:-}" ]; then
    printf '%s' "$supervisor" >"$REMAINING_CENSUS_OUTER_ASSIGNMENT_MARKER"
    sleep 0.5
  fi
  active_supervisor_pid=$supervisor
  if [ "$outer_signal_generation" -ne "$signal_generation_before" ]; then
    kill -"$last_outer_signal_name" "$supervisor" 2>/dev/null || true
  fi
  supervisor_status=1
  while kill -0 "$supervisor" 2>/dev/null; do
    if wait "$supervisor"; then
      supervisor_status=0
    else
      supervisor_status=$?
    fi
  done
  active_supervisor_pid=
  if [ "$outer_signal_status" -ne 0 ] && [ "$in_cleanup" -eq 0 ]; then
    return "$outer_signal_status"
  fi
  return "$supervisor_status"
}

trap 'forward_outer_signal HUP 129' HUP
trap 'forward_outer_signal INT 130' INT
trap 'forward_outer_signal TERM 143' TERM

if [ "${1:-}" = "--self-test" ]; then
  fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/remaining-census-runner-selftest.XXXXXX")
  trap 'rm -rf "$fixture_root"' EXIT
  fixture="$fixture_root/ignore-term.py"
  cat >"$fixture" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

root = pathlib.Path(sys.argv[1])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen(
    [sys.executable, "-c",
     "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"],
)
(root / "leader.pid").write_text(str(os.getpid()), encoding="ascii")
(root / "child.pid").write_text(str(child.pid), encoding="ascii")
while True:
    time.sleep(0.1)
PY
  exit_fixture="$fixture_root/leader-exit.py"
  cat >"$exit_fixture" <<'PY'
import pathlib
import subprocess
import sys
import time

root = pathlib.Path(sys.argv[1])
ready = root / "descendant.ready"
child = subprocess.Popen([
    sys.executable, "-c",
    "import pathlib,signal,sys,time; "
    "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
    "pathlib.Path(sys.argv[1]).write_text('ready', encoding='ascii'); "
    "time.sleep(30)", str(ready),
])
(root / "descendant.pid").write_text(str(child.pid), encoding="ascii")
for _ in range(100):
    if ready.exists():
        raise SystemExit(0)
    time.sleep(0.01)
raise SystemExit(2)
PY
  assert_gone() {
    label=$1
    pid=$2
    if kill -0 "$pid" 2>/dev/null; then
      echo "FAIL: $label survived bounded cleanup: $pid" >&2
      exit 1
    fi
  }

  set +e
  run_bounded 1 python3 "$fixture" "$fixture_root"
  timeout_status=$?
  set -e
  [ "$timeout_status" -eq 124 ] || {
    echo "FAIL: bounded timeout status differs: $timeout_status" >&2
    exit 1
  }
  assert_gone "timeout leader" "$(cat "$fixture_root/leader.pid")"
  assert_gone "timeout child" "$(cat "$fixture_root/child.pid")"

  rm -f "$fixture_root/leader.pid" "$fixture_root/child.pid"
  set +e
  run_bounded 30 python3 "$fixture" "$fixture_root" &
  bounded_job=$!
  set -e
  count=0
  while [ ! -s "$fixture_root/leader.pid" ] || [ ! -s "$fixture_root/child.pid" ]; do
    count=$((count + 1))
    [ "$count" -lt 100 ] || {
      echo "FAIL: signal fixture did not start" >&2
      kill -KILL "$bounded_job" 2>/dev/null || true
      wait "$bounded_job" 2>/dev/null || true
      exit 1
    }
    sleep 0.02
  done
  leader_pid=$(cat "$fixture_root/leader.pid")
  supervisor_pid=$(ps -o ppid= -p "$leader_pid" | tr -d ' ')
  [ -n "$supervisor_pid" ] || {
    echo "FAIL: bounded supervisor PID is unavailable" >&2
    exit 1
  }
  kill -TERM "$supervisor_pid"
  set +e
  wait "$bounded_job"
  signal_status=$?
  set -e
  [ "$signal_status" -eq 143 ] || {
    echo "FAIL: bounded signal status differs: $signal_status" >&2
    exit 1
  }
  assert_gone "signal leader" "$leader_pid"
  assert_gone "signal child" "$(cat "$fixture_root/child.pid")"

  construction_marker="$fixture_root/construction.pid"
  set +e
  REMAINING_CENSUS_BOUNDED_CONSTRUCTION_MARKER="$construction_marker" \
    run_bounded 30 python3 -c \
      'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' &
  construction_job=$!
  set -e
  count=0
  while [ ! -s "$construction_marker" ]; do
    count=$((count + 1))
    [ "$count" -lt 100 ] || {
      echo "FAIL: construction fixture did not enter Popen" >&2
      kill -KILL "$construction_job" 2>/dev/null || true
      wait "$construction_job" 2>/dev/null || true
      exit 1
    }
    sleep 0.01
  done
  construction_child=$(cat "$construction_marker")
  construction_supervisor=$(ps -o ppid= -p "$construction_child" | tr -d ' ')
  kill -TERM "$construction_supervisor"
  set +e
  wait "$construction_job"
  construction_status=$?
  set -e
  [ "$construction_status" -eq 143 ] || {
    echo "FAIL: construction signal status differs: $construction_status" >&2
    exit 1
  }
  assert_gone "construction child" "$construction_child"

  rm -f "$fixture_root/leader.pid" "$fixture_root/child.pid"
  cleanup_marker="$fixture_root/cleanup.pid"
  set +e
  REMAINING_CENSUS_BOUNDED_CLEANUP_MARKER="$cleanup_marker" \
    run_bounded 30 python3 "$fixture" "$fixture_root" &
  late_job=$!
  set -e
  count=0
  while [ ! -s "$fixture_root/leader.pid" ] || [ ! -s "$fixture_root/child.pid" ]; do
    count=$((count + 1))
    [ "$count" -lt 100 ] || {
      echo "FAIL: late-signal fixture did not start" >&2
      kill -KILL "$late_job" 2>/dev/null || true
      wait "$late_job" 2>/dev/null || true
      exit 1
    }
    sleep 0.02
  done
  late_leader=$(cat "$fixture_root/leader.pid")
  late_child=$(cat "$fixture_root/child.pid")
  late_supervisor=$(ps -o ppid= -p "$late_leader" | tr -d ' ')
  kill -TERM "$late_supervisor"
  count=0
  while [ ! -s "$cleanup_marker" ]; do
    count=$((count + 1))
    [ "$count" -lt 100 ] || {
      echo "FAIL: late-signal fixture did not enter cleanup" >&2
      kill -KILL "$late_job" 2>/dev/null || true
      wait "$late_job" 2>/dev/null || true
      exit 1
    }
    sleep 0.01
  done
  kill -HUP "$late_supervisor"
  set +e
  wait "$late_job"
  late_status=$?
  set -e
  [ "$late_status" -eq 143 ] || {
    echo "FAIL: late-signal status differs: $late_status" >&2
    exit 1
  }
  assert_gone "late-signal leader" "$late_leader"
  assert_gone "late-signal child" "$late_child"

  set +e
  run_bounded 5 python3 "$exit_fixture" "$fixture_root"
  descendant_status=$?
  set -e
  [ "$descendant_status" -eq 1 ] || {
    echo "FAIL: leader-exit descendant status differs: $descendant_status" >&2
    exit 1
  }
  assert_gone "leader-exit descendant" "$(cat "$fixture_root/descendant.pid")"

  rm -f "$fixture_root/leader.pid" "$fixture_root/child.pid"
  outer_pid=$$
  assignment_marker="$fixture_root/outer-assignment.pid"
  (
    count=0
    while [ ! -s "$assignment_marker" ]; do
      count=$((count + 1))
      [ "$count" -lt 100 ] || exit 2
      sleep 0.01
    done
    kill -TERM "$outer_pid"
  ) &
  sender_pid=$!
  set +e
  REMAINING_CENSUS_OUTER_ASSIGNMENT_MARKER="$assignment_marker" \
    run_bounded 30 python3 "$fixture" "$fixture_root"
  assignment_status=$?
  wait "$sender_pid"
  set -e
  [ "$assignment_status" -eq 143 ] || {
    echo "FAIL: outer assignment signal status differs: $assignment_status" >&2
    exit 1
  }
  if [ -s "$fixture_root/leader.pid" ]; then
    assert_gone "outer-assignment leader" "$(cat "$fixture_root/leader.pid")"
  fi
  if [ -s "$fixture_root/child.pid" ]; then
    assert_gone "outer-assignment child" "$(cat "$fixture_root/child.pid")"
  fi
  outer_signal_status=0
  outer_signal_name=
  unset REMAINING_CENSUS_OUTER_ASSIGNMENT_MARKER

  rm -f "$fixture_root/leader.pid" "$fixture_root/child.pid"
  (sleep 0.2; kill -TERM "$outer_pid") &
  sender_pid=$!
  set +e
  run_bounded 30 python3 "$fixture" "$fixture_root"
  outer_status=$?
  wait "$sender_pid"
  set -e
  [ "$outer_status" -eq 143 ] || {
    echo "FAIL: outer-shell signal status differs: $outer_status" >&2
    exit 1
  }
  assert_gone "outer-shell leader" "$(cat "$fixture_root/leader.pid")"
  assert_gone "outer-shell child" "$(cat "$fixture_root/child.pid")"
  outer_signal_status=0
  outer_signal_name=

  rm -f "$fixture_root/leader.pid" "$fixture_root/child.pid"
  in_cleanup=1
  (sleep 0.2; kill -HUP "$outer_pid") &
  sender_pid=$!
  set +e
  run_bounded 30 python3 "$fixture" "$fixture_root"
  cleanup_signal_status=$?
  wait "$sender_pid"
  set -e
  [ "$cleanup_signal_status" -eq 129 ] || {
    echo "FAIL: cleanup signal status differs: $cleanup_signal_status" >&2
    exit 1
  }
  assert_gone "cleanup-signal leader" "$(cat "$fixture_root/leader.pid")"
  assert_gone "cleanup-signal child" "$(cat "$fixture_root/child.pid")"
  cleanup_continued="$fixture_root/cleanup-continued"
  run_bounded 5 python3 -c \
    'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("done", encoding="ascii")' \
    "$cleanup_continued"
  [ "$(cat "$cleanup_continued")" = "done" ] || {
    echo "FAIL: cleanup did not continue after signal" >&2
    exit 1
  }
  in_cleanup=0
  outer_signal_status=0
  outer_signal_name=
  run_bounded 5 /usr/bin/true
  echo "remaining-material simulator runner self-test: PASS timeout=1 signal=1 construction=1 late-signal=1 leader-exit=1 outer-assignment=1 outer-shell=1 cleanup-signal=1 cleanup-continued=1 group-empty=1"
  exit 0
fi

case "$BUILD_SHA" in
  *[!0-9a-f]*|'') echo "BLOCKED: build SHA is not lowercase hexadecimal" >&2; exit 2 ;;
esac
[ "${#BUILD_SHA}" -eq 40 ] || {
  echo "BLOCKED: build SHA is not exact h40" >&2
  exit 2
}

cleanup() {
  status=$?
  trap - EXIT
  in_cleanup=1
  if [ -n "$selection_json" ]; then
    rm -f "$selection_json"
  fi
  if [ -n "$selection_value_file" ]; then
    rm -f "$selection_value_file"
  fi
  if [ -n "$container_value_file" ]; then
    rm -f "$container_value_file"
  fi
  if [ "$cleanup_done" -eq 0 ] && [ -n "$SIMULATOR_UDID" ]; then
    set +e
    run_bounded 20 xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" \
      >/dev/null 2>&1
    if [ "$installed" -eq 1 ]; then
      run_bounded 30 xcrun simctl uninstall "$SIMULATOR_UDID" "$BUNDLE_ID" \
        >/dev/null 2>&1
      uninstall_status=$?
      if [ "$uninstall_status" -ne 0 ]; then
        status=1
      fi
      if run_bounded 15 xcrun simctl get_app_container "$SIMULATOR_UDID" \
          "$BUNDLE_ID" app >/dev/null 2>&1; then
        status=1
      fi
    fi
    if [ "$booted_here" -eq 1 ]; then
      run_bounded 30 xcrun simctl shutdown "$SIMULATOR_UDID" \
        >/dev/null 2>&1
      [ "$?" -eq 0 ] || status=1
    fi
    set -e
  fi
  if [ "$outer_signal_status" -ne 0 ]; then
    status=$outer_signal_status
  fi
  trap - HUP INT TERM
  exit "$status"
}
trap cleanup EXIT

for tool in xcodebuild xcrun python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "BLOCKED: required tool unavailable: $tool" >&2
    exit 2
  }
done
[ -f "$PROJECT/project.pbxproj" ] && [ -f "$SPEC" ] && [ -f "$VALIDATOR" ] || {
  echo "BLOCKED: simulator project/spec/validator is incomplete" >&2
  exit 2
}

selection_json=$(mktemp "${TMPDIR:-/tmp}/remaining-census-simulators.XXXXXX")
selection_value_file=$(mktemp "${TMPDIR:-/tmp}/remaining-census-selection.XXXXXX")
run_bounded 30 xcrun simctl list devices -j >"$selection_json"
run_bounded 15 python3 -c '
import json, pathlib, sys
major, requested, source = int(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
choices = []
for runtime, devices in json.loads(source.read_text(encoding="utf-8")).get("devices", {}).items():
    if not runtime.startswith(prefix + str(major) + "-"):
        continue
    for device in devices:
        if device.get("isAvailable", True) is not True:
            continue
        if requested and device.get("udid") != requested:
            continue
        choices.append((device.get("state") != "Booted", device.get("name", ""),
                        device.get("udid"), device.get("state")))
if not choices:
    raise SystemExit("no exact available iOS 27 simulator")
_, _, udid, state = sorted(choices)[0]
print(f"{udid}|{state}")
' "$REQUIRED_RUNTIME_MAJOR" "$SIMULATOR_UDID" "$selection_json" \
  >"$selection_value_file"
IFS= read -r selection <"$selection_value_file"
rm -f "$selection_json"
rm -f "$selection_value_file"
selection_json=
selection_value_file=
SIMULATOR_UDID=${selection%%|*}
simulator_state=${selection#*|}

umask 077
python3 - "$DERIVED_DATA" "$OUTPUT_DIR" <<'PY'
import os, pathlib, sys
for text in sys.argv[1:]:
    path = pathlib.Path(text)
    if not path.is_absolute() or os.path.lexists(path):
        raise SystemExit(f"output path is not absent absolute: {path}")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.mkdir(path, 0o700)
PY

run_bounded 30 python3 "$VALIDATOR" validate-simulator-spec --spec "$SPEC"
run_bounded 1800 xcodebuild -quiet \
  -project "$PROJECT" \
  -scheme RemainingMaterialCensusAdapter \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=$SIMULATOR_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  OPENGOTHIC_RENDERER_IOS_BUILD_SHA="$BUILD_SHA" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  build
[ -d "$APP" ] || { echo "BLOCKED: adapter app missing" >&2; exit 2; }

if [ "$simulator_state" != "Booted" ]; then
  run_bounded 60 xcrun simctl boot "$SIMULATOR_UDID"
  booted_here=1
fi
run_bounded 120 xcrun simctl bootstatus "$SIMULATOR_UDID" -b
run_bounded 120 xcrun simctl install "$SIMULATOR_UDID" "$APP"
installed=1
run_bounded 30 xcrun simctl launch --terminate-running-process \
  "$SIMULATOR_UDID" "$BUNDLE_ID"
container_value_file=$(mktemp "${TMPDIR:-/tmp}/remaining-census-container.XXXXXX")
run_bounded 30 xcrun simctl get_app_container \
  "$SIMULATOR_UDID" "$BUNDLE_ID" data >"$container_value_file"
IFS= read -r container <"$container_value_file"
rm -f "$container_value_file"
container_value_file=

ready=0
count=0
while [ "$count" -lt 120 ]; do
  if [ -f "$container/Documents/result.txt" ]; then
    ready=1
    break
  fi
  count=$((count + 1))
  sleep 0.25
done
[ "$ready" -eq 1 ] || {
  echo "BLOCKED: adapter did not publish result within 30 seconds" >&2
  exit 2
}

run_bounded 15 cp "$container/Documents/result.txt" "$RESULT"
run_bounded 15 cp "$container/Documents/remaining-material-census.log" "$LOG"
chmod 0600 "$RESULT" "$LOG"
python3 - "$RESULT" "$BUILD_SHA" <<'PY'
import pathlib, sys
expected = ("RemainingMaterialCensusAdapter terminal: v=1 b=" + sys.argv[2] +
            " g=1 s=1 result=PASS\n").encode()
if pathlib.Path(sys.argv[1]).read_bytes() != expected:
    raise SystemExit("adapter terminal differs")
PY
run_bounded 30 python3 "$VALIDATOR" validate-log --log "$LOG" --build "$BUILD_SHA" \
  --generation 1 --sequence 1
run_bounded 30 python3 "$VALIDATOR" build-artifact --log "$LOG" --build "$BUILD_SHA" \
  --generation 1 --sequence 1 --output "$ARTIFACT"
run_bounded 30 python3 "$VALIDATOR" validate-artifact --artifact "$ARTIFACT"

run_bounded 20 xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" \
  >/dev/null 2>&1 || true
run_bounded 30 xcrun simctl uninstall "$SIMULATOR_UDID" "$BUNDLE_ID"
installed=0
if run_bounded 15 xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" app \
    >/dev/null 2>&1; then
  echo "BLOCKED: adapter remains installed after cleanup" >&2
  exit 2
fi
if [ "$booted_here" -eq 1 ]; then
  run_bounded 30 xcrun simctl shutdown "$SIMULATOR_UDID"
  booted_here=0
fi
cleanup_done=1
echo "scope=host-neutral-adapter,no-product-save-runtime"
echo "SIMULATOR PASS / DEVICE PENDING"
