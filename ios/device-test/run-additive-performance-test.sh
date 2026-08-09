#!/usr/bin/env bash
# Attach Xcode 27 Instruments to one already-running iOS PID and publish a
# fail-closed P2.1e1b performance trace summary. This adapter never launches,
# installs, or terminates the target application.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$ROOT/ios/device-test/validate-additive-performance-trace.py"
XCTRACE=/usr/bin/xctrace
ROLE=""
EXPECTED_SHA=""
TEMPEST_SHA=""
BUNDLE_ID=""
TEAM_ID=""
DEVICE=""
PID=""
SAVE_SLOT=""
FPS_LIMIT=""
SETTLE_SECONDS=""
TRACE_SECONDS=""
EVIDENCE_DIR=""
LIVE_PID_FILE=""
APP=""
SELF_TEST=0
SEEN_OPTIONS=" "
WORK=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

seen_once() {
  [[ "$SEEN_OPTIONS" != *" $1 "* ]] || fail "duplicate option: $1"
  SEEN_OPTIONS+="$1 "
}

while (($#)); do
  case "$1" in
    --device) seen_once "$1"; (($# >= 2)) || fail "missing --device value"; DEVICE="$2"; shift 2 ;;
    --pid) seen_once "$1"; (($# >= 2)) || fail "missing --pid value"; PID="$2"; shift 2 ;;
    --role) seen_once "$1"; (($# >= 2)) || fail "missing --role value"; ROLE="$2"; shift 2 ;;
    --expected-sha) seen_once "$1"; (($# >= 2)) || fail "missing --expected-sha value"; EXPECTED_SHA="$2"; shift 2 ;;
    --tempest-sha) seen_once "$1"; (($# >= 2)) || fail "missing --tempest-sha value"; TEMPEST_SHA="$2"; shift 2 ;;
    --bundle-id) seen_once "$1"; (($# >= 2)) || fail "missing --bundle-id value"; BUNDLE_ID="$2"; shift 2 ;;
    --team-id) seen_once "$1"; (($# >= 2)) || fail "missing --team-id value"; TEAM_ID="$2"; shift 2 ;;
    --save-slot) seen_once "$1"; (($# >= 2)) || fail "missing --save-slot value"; SAVE_SLOT="$2"; shift 2 ;;
    --fps-limit) seen_once "$1"; (($# >= 2)) || fail "missing --fps-limit value"; FPS_LIMIT="$2"; shift 2 ;;
    --settle-seconds) seen_once "$1"; (($# >= 2)) || fail "missing --settle-seconds value"; SETTLE_SECONDS="$2"; shift 2 ;;
    --trace-seconds) seen_once "$1"; (($# >= 2)) || fail "missing --trace-seconds value"; TRACE_SECONDS="$2"; shift 2 ;;
    --evidence-dir) seen_once "$1"; (($# >= 2)) || fail "missing --evidence-dir value"; EVIDENCE_DIR="$2"; shift 2 ;;
    --live-pid-file) seen_once "$1"; (($# >= 2)) || fail "missing --live-pid-file value"; LIVE_PID_FILE="$2"; shift 2 ;;
    --self-test) seen_once "$1"; SELF_TEST=1; shift ;;
    -*) fail "unknown option: $1" ;;
    *) [[ -z "$APP" ]] || fail "only one app path may be supplied"; APP="$1"; shift ;;
  esac
done

[[ "$DEVICE" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
  fail "device UDID is invalid"
[[ "$PID" =~ ^[1-9][0-9]*$ ]] || fail "PID is invalid"
[[ "$ROLE" == base-off-performance || "$ROLE" == candidate-off-performance ]] ||
  fail "role is invalid"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "expected SHA is invalid"
[[ "$TEMPEST_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "Tempest SHA is invalid"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$ ]] ||
  fail "bundle ID is invalid"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{1,32}$ ]] || fail "team ID is invalid"
[[ "$SAVE_SLOT" == 4 && "$FPS_LIMIT" == 30 && "$SETTLE_SECONDS" == 12 ]] ||
  fail "settings differ from the frozen performance contract"
[[ "$TRACE_SECONDS" =~ ^[0-9]+$ ]] &&
  ((TRACE_SECONDS >= 30 && TRACE_SECONDS <= 600)) ||
  fail "trace seconds must be 30..600"
[[ "$EVIDENCE_DIR" == /* && "$LIVE_PID_FILE" == /* && -n "$APP" ]] ||
  fail "absolute evidence/live-PID paths and app path are required"
[[ "$LIVE_PID_FILE" != *[$'\001'-$'\037'$'\177']* &&
   "$(basename "$LIVE_PID_FILE")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$ ]] ||
  fail "live PID file path is invalid"

if ((SELF_TEST != 0)); then
  printf 'SELF-TEST PASS device=%s pid=%s role=%s trace=%s\n' \
    "$DEVICE" "$PID" "$ROLE" "$TRACE_SECONDS"
  exit 0
fi

[[ -x "$XCTRACE" && -f "$VALIDATOR" ]] || fail "Xcode trace tools are missing"
XCTRACE_IDENTITY="$("$XCTRACE" version)" || fail "xctrace identity query failed"
[[ "$XCTRACE_IDENTITY" =~ ^xctrace\ version\ (27\.[0-9]+(\.[0-9]+)?)\ \(([A-Za-z0-9]+)\)$ ]] ||
  fail "xctrace must be exact major version 27"
TOOL_VERSION="${BASH_REMATCH[1]}"; TOOL_BUILD="${BASH_REMATCH[3]}"
XCODE_IDENTITY="$(/usr/bin/xcodebuild -version)" || fail "Xcode identity query failed"
[[ "$XCODE_IDENTITY" == "Xcode $TOOL_VERSION"$'\n'"Build version $TOOL_BUILD" ]] ||
  fail "Xcode and xctrace version/build identities differ"
[[ -f "$LIVE_PID_FILE" && ! -L "$LIVE_PID_FILE" &&
   -d "$(dirname "$LIVE_PID_FILE")" && ! -L "$(dirname "$LIVE_PID_FILE")" ]] ||
  fail "live PID file is invalid"
[[ -d "$EVIDENCE_DIR" && ! -L "$EVIDENCE_DIR" ]] ||
  fail "evidence directory is invalid"
[[ -z "$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
  fail "evidence directory is not empty"
[[ -d "$APP" && ! -L "$APP" && -f "$APP/Info.plist" ]] ||
  fail "app bundle is invalid"
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$APP/Info.plist" 2>/dev/null)" || fail "app bundle ID is unavailable"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
  "$APP/Info.plist" 2>/dev/null)" || fail "app executable is unavailable"
[[ "$APP_BUNDLE_ID" == "$BUNDLE_ID" ]] || fail "app bundle ID differs"
[[ "$APP_EXECUTABLE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$ &&
   -x "$APP/$APP_EXECUTABLE" ]] || fail "app executable is invalid"
CODESIGN_DESCRIPTION="$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1)" ||
  fail "app signature cannot be inspected"
[[ "$(printf '%s\n' "$CODESIGN_DESCRIPTION" | /usr/bin/awk -F= \
  '$1 == "Identifier" { print $2 }')" == "$BUNDLE_ID" ]] ||
  fail "signed bundle identifier differs"
[[ "$(printf '%s\n' "$CODESIGN_DESCRIPTION" | /usr/bin/awk -F= \
  '$1 == "TeamIdentifier" { print $2 }')" == "$TEAM_ID" ]] ||
  fail "signed team identifier differs"

LIVE_PID_VALUE="$(python3 - "$LIVE_PID_FILE" "$DEVICE" "$BUNDLE_ID" "$APP_EXECUTABLE" "$PID" <<'PY'
import json, os, stat, sys

path, device, bundle, executable, expected_pid = sys.argv[1:]
def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise SystemExit("duplicate live PID JSON key")
        result[key] = value
    return result
descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= 4096:
        raise SystemExit("live PID file is not a bounded regular file")
    raw = os.read(descriptor, before.st_size + 1)
    if len(raw) != before.st_size or os.fstat(descriptor) != before:
        raise SystemExit("live PID file changed while read")
finally:
    os.close(descriptor)
try:
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"live PID file is invalid JSON: {error}")
keys = ("schemaVersion", "deviceUdid", "bundleId", "executable", "processId")
if type(value) is not dict or tuple(value) != keys:
    raise SystemExit("live PID JSON keys/order differ")
canonical = (json.dumps(value, separators=(",", ":")) + "\n").encode()
if raw != canonical:
    raise SystemExit("live PID JSON is not canonical LF JSON")
if (value["schemaVersion"] != 1 or value["deviceUdid"] != device or
        value["bundleId"] != bundle or value["executable"] != executable or
        type(value["processId"]) is not int or value["processId"] <= 0 or
        str(value["processId"]) != expected_pid):
    raise SystemExit("live PID identity differs from collector CLI")
print(value["processId"])
PY
)" || fail "live PID handshake validation failed"
[[ "$LIVE_PID_VALUE" == "$PID" ]] || fail "live PID handshake output differs"

RUN_ID="$(/usr/bin/openssl rand -hex 16)" || fail "could not create run ID"
[[ "$RUN_ID" =~ ^[0-9a-f]{32}$ ]] || fail "generated run ID is invalid"
WORK="$EVIDENCE_DIR/.performance-$RUN_ID.tmp"
/bin/mkdir "$WORK" || fail "could not create staging directory"
PAYLOAD="$WORK/payload"; /bin/mkdir "$PAYLOAD" || fail "could not create payload staging directory"
cleanup() {
  [[ -z "$WORK" || ! -e "$WORK" ]] || /bin/rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

TRACE_LEAF="performance-$ROLE-$RUN_ID.trace"
TOC_LEAF="performance-$ROLE-$RUN_ID-toc.xml"
METRICS_LEAF="performance-$ROLE-$RUN_ID-metrics.xml"
THERMAL_LEAF="performance-$ROLE-$RUN_ID-thermal.xml"
SUMMARY_LEAF="performance-trace-summary-v1.json"
COMMIT_LEAF="performance-evidence-commit-v1.json"
FINAL_LEAF="performance-evidence-$ROLE-$RUN_ID"
TRACE_PATH="$PAYLOAD/$TRACE_LEAF"
TOC_PATH="$PAYLOAD/$TOC_LEAF"
METRICS_PATH="$PAYLOAD/$METRICS_LEAF"
THERMAL_PATH="$PAYLOAD/$THERMAL_LEAF"
SUMMARY_PATH="$PAYLOAD/$SUMMARY_LEAF"
COMMIT_PATH="$PAYLOAD/$COMMIT_LEAF"
FINAL_PATH="$EVIDENCE_DIR/$FINAL_LEAF"

run_bounded_tool() {
  local timeout="$1"; shift
  python3 - "$timeout" "$@" <<'PY'
import os, signal, subprocess, sys
timeout = int(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
def terminate():
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
try:
    status = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    terminate()
    raise SystemExit(124)
except BaseException:
    terminate()
    raise
raise SystemExit(status)
PY
}

require_exact_process() {
  local label="$1"
  local output="$WORK/processes-$label.json"
  xcrun devicectl device info processes --device "$DEVICE" --timeout 15 \
    --json-output "$output" >/dev/null 2>"$WORK/processes-$label.stderr" ||
    return 1
  python3 - "$output" "$PID" "$APP_EXECUTABLE" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    root = json.load(source)
processes = root.get("result", {}).get("runningProcesses")
if not isinstance(processes, list):
    raise SystemExit("process provider returned no runningProcesses array")
expected_pid = int(sys.argv[2])
expected_executable = sys.argv[3]
matches = []
for process in processes:
    if not isinstance(process, dict):
        raise SystemExit("process provider returned a non-object")
    if process.get("processIdentifier") != expected_pid:
        continue
    executable = process.get("executable")
    if not isinstance(executable, str):
        raise SystemExit("target process lacks executable identity")
    if pathlib.PurePosixPath(executable).name != expected_executable:
        raise SystemExit("target PID executable differs")
    matches.append(process)
if len(matches) != 1:
    raise SystemExit(f"expected exact PID once, found {len(matches)}")
PY
}

require_exact_process before-settle || fail "exact target PID is not running"
/bin/sleep "$SETTLE_SECONDS"
require_exact_process after-settle || fail "exact target PID changed during settle"

run_bounded_tool "$((TRACE_SECONDS + 120))" "$XCTRACE" record --template 'Game Performance Overview' \
  --device "$DEVICE" --attach "$PID" --time-limit "${TRACE_SECONDS}s" \
  --run-name "$RUN_ID" --no-prompt --output "$TRACE_PATH" \
  >"$WORK/record.stdout" 2>"$WORK/record.stderr" ||
  fail "xctrace record failed"
[[ -d "$TRACE_PATH" && ! -L "$TRACE_PATH" ]] ||
  fail "xctrace did not create a trace bundle"
require_exact_process after-record || fail "exact target PID ended during trace"

run_bounded_tool 120 "$XCTRACE" export --input "$TRACE_PATH" --toc --output "$TOC_PATH" \
  >"$WORK/toc.stdout" 2>"$WORK/toc.stderr" || fail "xctrace TOC export failed"
run_bounded_tool 120 "$XCTRACE" export --input "$TRACE_PATH" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-perf-overview-layer-duration-metric"]' \
  --output "$METRICS_PATH" >"$WORK/metrics.stdout" 2>"$WORK/metrics.stderr" ||
  fail "xctrace metric export failed"
run_bounded_tool 120 "$XCTRACE" export --input "$TRACE_PATH" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="device-thermal-state-intervals"]' \
  --output "$THERMAL_PATH" >"$WORK/thermal.stdout" 2>"$WORK/thermal.stderr" ||
  fail "xctrace thermal export failed"

VALIDATOR_TERMINAL="$(run_bounded_tool 300 python3 "$VALIDATOR" \
  --trace "$TRACE_PATH" --toc "$TOC_PATH" \
  --metrics-export "$METRICS_PATH" --thermal-export "$THERMAL_PATH" \
  --output "$SUMMARY_PATH" --commit-output "$COMMIT_PATH" \
  --role "$ROLE" --run-id "$RUN_ID" \
  --parent-sha "$EXPECTED_SHA" --tempest-sha "$TEMPEST_SHA" \
  --bundle-id "$BUNDLE_ID" --team-id "$TEAM_ID" \
  --device-udid "$DEVICE" --process-id "$PID" --save-slot "$SAVE_SLOT" \
  --fps-limit "$FPS_LIMIT" --settle-seconds "$SETTLE_SECONDS" \
  --trace-seconds "$TRACE_SECONDS" --tool-version "$TOOL_VERSION" \
  --tool-build "$TOOL_BUILD" 2>"$WORK/validator.stderr")" ||
  fail "performance trace validation failed"
[[ "$VALIDATOR_TERMINAL" == 'PERFORMANCE PASS' ]] ||
  fail "performance validator terminal differs"

python3 - "$PAYLOAD" <<'PY' || fail "evidence durability flush failed"
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns)
root_before = root.lstat()
if not stat.S_ISDIR(root_before.st_mode) or stat.S_ISLNK(root_before.st_mode):
    raise SystemExit("payload root is not a non-symlink directory")
directories = []
for directory, names, files in os.walk(root, topdown=True,
                                        followlinks=False):
    directory_path = pathlib.Path(directory)
    directory_before = directory_path.lstat()
    if not stat.S_ISDIR(directory_before.st_mode) or stat.S_ISLNK(directory_before.st_mode):
        raise SystemExit("payload contains a symlink or special directory")
    directories.append((directory_path, identity(directory_before)))
    for name in names:
        child = directory_path / name
        metadata = child.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise SystemExit("payload contains a symlink or special directory")
    for name in files:
        child = directory_path / name
        metadata = child.lstat()
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise SystemExit("payload contains a symlink or special file")
        descriptor = os.open(child, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            before = os.fstat(descriptor)
            if identity(before) != identity(metadata):
                raise SystemExit("payload file changed before flush")
            os.fsync(descriptor)
            if identity(os.fstat(descriptor)) != identity(before):
                raise SystemExit("payload file changed during flush")
        finally:
            os.close(descriptor)
        if identity(child.lstat()) != identity(metadata):
            raise SystemExit("payload file changed after flush")
directories.sort(key=lambda item: len(item[0].parts), reverse=True)
for directory_path, expected in directories:
    descriptor = os.open(directory_path, os.O_RDONLY | os.O_DIRECTORY |
                         os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if identity(before) != expected:
            raise SystemExit("payload directory changed before flush")
        os.fsync(descriptor)
        if identity(os.fstat(descriptor)) != identity(before):
            raise SystemExit("payload directory changed during flush")
    finally:
        os.close(descriptor)
if identity(root.lstat()) != identity(root_before):
    raise SystemExit("payload root changed during flush")
PY
[[ ! -e "$FINAL_PATH" && ! -L "$FINAL_PATH" ]] || fail "evidence directory publication collided"
python3 - "$WORK" "$EVIDENCE_DIR" "$FINAL_LEAF" <<'PY' ||
  fail "evidence directory exclusive publication failed"
import ctypes
import os
import stat
import sys

source_parent, destination_parent, destination_leaf = sys.argv[1:]
if (not destination_leaf or "/" in destination_leaf or
        any(ord(character) < 32 or ord(character) == 127
            for character in destination_leaf)):
    raise SystemExit("destination leaf is unsafe")
source_fd = os.open(source_parent, os.O_RDONLY | os.O_DIRECTORY |
                    os.O_CLOEXEC | os.O_NOFOLLOW)
destination_fd = os.open(destination_parent, os.O_RDONLY | os.O_DIRECTORY |
                         os.O_CLOEXEC | os.O_NOFOLLOW)
payload_fd = -1
try:
    payload_fd = os.open("payload", os.O_RDONLY | os.O_DIRECTORY |
                         os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=source_fd)
    payload_before = os.fstat(payload_fd)
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renameatx_np
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                       ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(source_fd, b"payload", destination_fd,
              destination_leaf.encode("utf-8", "strict"), 0x4) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination_leaf)
    destination = os.stat(destination_leaf, dir_fd=destination_fd,
                          follow_symlinks=False)
    if (not stat.S_ISDIR(destination.st_mode) or
            (destination.st_dev, destination.st_ino) !=
            (payload_before.st_dev, payload_before.st_ino)):
        raise SystemExit("published directory identity differs")
    os.fsync(destination_fd)
finally:
    if payload_fd >= 0:
        os.close(payload_fd)
    os.close(destination_fd)
    os.close(source_fd)
PY
[[ ! -e "$PAYLOAD" && -d "$FINAL_PATH" && ! -L "$FINAL_PATH" ]] ||
  fail "evidence directory publication was not atomic/no-clobber"

/bin/rm -f "$WORK"/*.stdout "$WORK"/*.stderr "$WORK"/processes-*.json
/bin/rmdir "$WORK" || fail "staging directory did not become empty"
WORK=""
trap - EXIT INT TERM
printf '%s\n' 'PERFORMANCE PASS'
