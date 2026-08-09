#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROJECT="$ROOT/ios/simulator-test/AdditiveCensusAdapter.xcodeproj"
SPEC="$ROOT/ios/simulator-test/specs/p21e1a-additive-census-v1.json"
VALIDATOR="$ROOT/ios/device-test/validate-additive-source-census-log.py"
BUILD_SHA=${OPENGOTHIC_RENDERER_IOS_BUILD_SHA:-$(git -C "$ROOT" rev-parse HEAD)}
RUN_STAMP=$(date -u +%Y%m%d%H%M%S)
RUN_ID="${RUN_STAMP}-$$"
BUNDLE_ID="opengothic.rendererios.additive-census-adapter.r${RUN_STAMP}p$$"
DERIVED_DATA=${ADDITIVE_CENSUS_DERIVED_DATA:-"${TMPDIR:-/tmp}/opengothic-additive-census-derived/$RUN_ID"}
OUTPUT_DIR=${ADDITIVE_CENSUS_OUTPUT_DIR:-"$ROOT/build/simulator-test/additive-census/$RUN_ID"}
LOG="$OUTPUT_DIR/log.txt"
ARTIFACT="$OUTPUT_DIR/additive-source-census-v1.bin"
CRASH_BEFORE="$OUTPUT_DIR/crashes-before.json"
CRASH_AFTER="$OUTPUT_DIR/crashes-after.json"
PROCESS_STATE="$OUTPUT_DIR/process-state.txt"
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/AdditiveCensusAdapter.app"
SIMULATOR_UDID=${SIMULATOR_UDID:-}
LAUNCH_TIMEOUT_SECONDS=${ADDITIVE_CENSUS_LAUNCH_TIMEOUT_SECONDS:-30}
REQUIRED_SIMULATOR_RUNTIME_MAJOR=27
installed=0
cleanup_done=0

case "$BUILD_SHA" in
  *[!0-9a-f]*|'')
    echo "BLOCKED: expected lowercase hexadecimal build SHA" >&2
    exit 2
    ;;
esac
if [ "${#BUILD_SHA}" -ne 40 ]; then
  echo "BLOCKED: expected 40-character build SHA" >&2
  exit 2
fi
case "$LAUNCH_TIMEOUT_SECONDS" in
  *[!0-9]*|'')
    echo "BLOCKED: launch timeout must be a canonical integer" >&2
    exit 2
    ;;
esac
if [ "$LAUNCH_TIMEOUT_SECONDS" -lt 1 ] ||
   [ "$LAUNCH_TIMEOUT_SECONDS" -gt 120 ]; then
  echo "BLOCKED: launch timeout must be within 1..120 seconds" >&2
  exit 2
fi

cleanup() {
  status=$?
  if [ "$cleanup_done" -eq 0 ] && [ -n "$SIMULATOR_UDID" ]; then
    set +e
    xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1
    if [ "$installed" -eq 1 ]; then
      xcrun simctl uninstall "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1
      uninstall_status=$?
      if [ "$uninstall_status" -ne 0 ]; then
        echo "BLOCKED: simulator adapter uninstall failed during cleanup" >&2
        if [ "$status" -eq 0 ]; then
          status=1
        fi
      fi
      if xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" app \
          >/dev/null 2>&1; then
        echo "BLOCKED: simulator adapter remains installed after cleanup" >&2
        status=1
      fi
    fi
    set -e
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in xcodebuild xcrun python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "BLOCKED: required tool is unavailable: $tool" >&2
    exit 2
  fi
done
if [ ! -f "$PROJECT/project.pbxproj" ] || [ ! -f "$SPEC" ]; then
  echo "BLOCKED: simulator adapter project/spec is incomplete" >&2
  exit 2
fi

create_exclusive_directory() {
  python3 - "$1" <<'PY'
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_absolute():
    raise SystemExit("directory must be absolute")
if os.path.lexists(path):
    raise SystemExit(f"directory already exists or is a symlink: {path}")
parent = path.parent
parent.mkdir(mode=0o700, parents=True, exist_ok=True)
os.mkdir(path, 0o700)
mode = os.lstat(path).st_mode
if not stat.S_ISDIR(mode) or stat.S_ISLNK(mode) or any(path.iterdir()):
    raise SystemExit("directory is not new, empty, and nonsymlink")
PY
}

record_crashes() {
  python3 - "$SIMULATOR_UDID" "$1" <<'PY'
import json
import os
import pathlib
import sys

udid, destination = sys.argv[1:]
roots = (
    pathlib.Path.home() / "Library/Logs/DiagnosticReports",
    pathlib.Path.home() / "Library/Developer/CoreSimulator/Devices" / udid /
        "data/Library/Logs/CrashReporter",
)
records = []
for root in roots:
    if not root.is_dir():
        continue
    for path in root.rglob("AdditiveCensusAdapter*"):
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if path.is_symlink() or not path.is_file():
            continue
        records.append([str(path.resolve()), info.st_mtime_ns, info.st_size])
with open(destination, "x", encoding="utf-8", newline="\n") as stream:
    json.dump(sorted(records), stream, separators=(",", ":"))
    stream.write("\n")
PY
}

set +e
SIMULATOR_SELECTION=$(xcrun simctl list devices -j | python3 -c '
import json
import sys

required_major = int(sys.argv[1])
requested = sys.argv[2]
prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"

def runtime_major(identifier):
    if not isinstance(identifier, str) or not identifier.startswith(prefix):
        return None
    component = identifier[len(prefix):].split("-", 1)[0]
    return int(component) if component.isdigit() else None

def select(data, requested_udid):
    found = None
    for runtime, devices in data.get("devices", {}).items():
        if not isinstance(devices, list):
            continue
        for device in devices:
            if not isinstance(device, dict):
                continue
            if requested_udid and device.get("udid") == requested_udid:
                found = (runtime, device)
            if (not requested_udid and runtime_major(runtime) == required_major
                    and device.get("state") == "Booted"
                    and device.get("isAvailable", True) is True):
                return runtime, device
    if not requested_udid:
        return None
    if found is None:
        raise ValueError("selected simulator UDID is missing from CoreSimulator")
    runtime, device = found
    if runtime_major(runtime) != required_major:
        raise ValueError(
            f"selected simulator runtime is not exact iOS {required_major}: {runtime}"
        )
    if device.get("isAvailable", True) is not True:
        raise ValueError("selected iOS 27 simulator is unavailable")
    if device.get("state") != "Booted":
        raise ValueError("selected iOS 27 simulator is not booted")
    return runtime, device

def fixture(runtime, udid="fixture", state="Booted", available=True):
    return {"devices": {runtime: [{
        "udid": udid, "state": state, "isAvailable": available,
    }]}}

valid_runtime = prefix + str(required_major) + "-0"
valid = select(fixture(valid_runtime), "fixture")
assert valid is not None and valid[0] == valid_runtime
blocked = (
    (fixture(prefix + str(required_major - 1) + "-9"), "fixture"),
    (fixture(prefix + str(required_major + 1) + "-0"), "fixture"),
    (fixture("com.apple.CoreSimulator.SimRuntime.watchOS-27-0"), "fixture"),
    ({"devices": {}}, "missing"),
)
for data, udid in blocked:
    try:
        select(data, udid)
    except ValueError:
        pass
    else:
        raise SystemExit("runtime selector mutation survived")
assert select(fixture(prefix + str(required_major - 1) + "-9"), "") is None
assert select(fixture(prefix + str(required_major + 1) + "-0"), "") is None
assert select(fixture("com.apple.CoreSimulator.SimRuntime.watchOS-27-0"), "") is None

try:
    selected = select(json.load(sys.stdin), requested)
except (TypeError, ValueError) as error:
    print(f"runtime selection failed: {error}", file=sys.stderr)
    raise SystemExit(1)
if selected is not None:
    runtime, device = selected
    print("{}|{}".format(device["udid"], runtime))
' "$REQUIRED_SIMULATOR_RUNTIME_MAJOR" "$SIMULATOR_UDID")
selection_status=$?
set -e
if [ "$selection_status" -ne 0 ]; then
  echo "BLOCKED: simulator runtime contract rejected selection" >&2
  exit 2
fi

destination="generic/platform=iOS Simulator"
SIMULATOR_RUNTIME=
if [ -n "$SIMULATOR_SELECTION" ]; then
  SIMULATOR_UDID=${SIMULATOR_SELECTION%%|*}
  SIMULATOR_RUNTIME=${SIMULATOR_SELECTION#*|}
  destination="id=$SIMULATOR_UDID"
fi

SIMULATOR_SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)
case "$SIMULATOR_SDK_VERSION" in
  "$REQUIRED_SIMULATOR_RUNTIME_MAJOR"|"$REQUIRED_SIMULATOR_RUNTIME_MAJOR".*)
    ;;
  *)
    echo "BLOCKED: iphonesimulator SDK is not iOS $REQUIRED_SIMULATOR_RUNTIME_MAJOR: $SIMULATOR_SDK_VERSION" >&2
    exit 2
    ;;
esac

umask 077
if [ "$DERIVED_DATA" = "$OUTPUT_DIR" ] ||
   [ -e "$DERIVED_DATA" ] || [ -L "$DERIVED_DATA" ]; then
  echo "BLOCKED: derived-data directory collides or already exists: $DERIVED_DATA" >&2
  exit 2
fi
if [ -e "$OUTPUT_DIR" ] || [ -L "$OUTPUT_DIR" ]; then
  echo "BLOCKED: output directory collides or already exists: $OUTPUT_DIR" >&2
  exit 2
fi
if ! create_exclusive_directory "$DERIVED_DATA"; then
  echo "BLOCKED: derived-data directory is not new/empty/nonsymlink: $DERIVED_DATA" >&2
  exit 2
fi
if ! create_exclusive_directory "$OUTPUT_DIR"; then
  echo "BLOCKED: output directory is not new/empty/nonsymlink: $OUTPUT_DIR" >&2
  exit 2
fi
xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme AdditiveCensusAdapter \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "$destination" \
  -derivedDataPath "$DERIVED_DATA" \
  OPENGOTHIC_RENDERER_IOS_BUILD_SHA="$BUILD_SHA" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [ ! -d "$APP" ]; then
  echo "BLOCKED: iphonesimulator build produced no adapter app" >&2
  exit 2
fi
if [ -z "$SIMULATOR_UDID" ]; then
  echo "scope=host-neutral-adapter,no-product-save-runtime"
  echo "HOST ADAPTER PASS / SIMULATOR BLOCKED / DEVICE NOT RUN"
  exit 2
fi
if [ ! -f "$VALIDATOR" ]; then
  echo "BLOCKED: additive census validator is unavailable: $VALIDATOR" >&2
  exit 2
fi

installed=1
xcrun simctl install "$SIMULATOR_UDID" "$APP"
record_crashes "$CRASH_BEFORE"
set +e
python3 - "$LOG" "$SIMULATOR_UDID" "$BUNDLE_ID" \
    "$LAUNCH_TIMEOUT_SECONDS" <<'PY'
import pathlib
import subprocess
import sys

log_path, udid, bundle_id, timeout_text = sys.argv[1:]
with open(log_path, "xb") as log:
    process = subprocess.Popen(
        ["xcrun", "simctl", "launch", "--console",
         "--terminate-running-process", udid, bundle_id],
        stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        status = process.wait(timeout=int(timeout_text))
    except subprocess.TimeoutExpired:
        subprocess.run(
            ["xcrun", "simctl", "terminate", udid, bundle_id],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False,
        )
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        raise SystemExit(124)
raise SystemExit(status)
PY
launch_status=$?
set -e

set +e
xcrun simctl spawn "$SIMULATOR_UDID" launchctl list >"$PROCESS_STATE" 2>/dev/null
process_query_status=$?
set -e
if [ "$process_query_status" -ne 0 ]; then
  echo "BLOCKED: unable to join simulator process state" >&2
  exit 2
fi
if ! python3 - "$PROCESS_STATE" "$BUNDLE_ID" <<'PY'
import pathlib
import sys

for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[1:]:
    fields = line.split("\t", 2)
    if len(fields) == 3 and sys.argv[2] in fields[2] and fields[0] != "-":
        raise SystemExit(1)
PY
then
  echo "BLOCKED: adapter process remains alive after collector terminal" >&2
  exit 2
fi

python3 -c 'import time; time.sleep(1)'
record_crashes "$CRASH_AFTER"
if ! python3 - "$CRASH_BEFORE" "$CRASH_AFTER" <<'PY'
import json
import sys

before = {tuple(value) for value in json.load(open(sys.argv[1], encoding="utf-8"))}
after = {tuple(value) for value in json.load(open(sys.argv[2], encoding="utf-8"))}
new = sorted(after - before)
if new:
    for value in new:
        print(f"new crash report: {value[0]}", file=sys.stderr)
    raise SystemExit(1)
PY
then
  echo "BLOCKED: simulator adapter produced a crash report" >&2
  exit 2
fi
if [ "$launch_status" -eq 124 ]; then
  echo "BLOCKED: simulator adapter exceeded ${LAUNCH_TIMEOUT_SECONDS}s runtime timeout" >&2
  exit 2
fi
if [ "$launch_status" -ne 0 ]; then
  echo "BLOCKED: simulator adapter exited abnormally with status $launch_status" >&2
  exit 2
fi

if ! python3 - "$LOG" "$BUILD_SHA" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
terminal = (
    "AdditiveCensusAdapter terminal: v=1 b=" + sys.argv[2] +
    " g=1 s=1 result=PASS"
)
if lines.count(terminal) != 1:
    raise SystemExit(1)
terminal_index = lines.index(terminal)
row_indices = [index for index, line in enumerate(lines)
               if line.startswith("RendererIOS additive source census row:")]
if len(row_indices) != 7 or terminal_index <= row_indices[-1]:
    raise SystemExit(1)
if any(line.startswith("AdditiveCensusAdapter FAIL:") for line in lines):
    raise SystemExit(1)
PY
then
  echo "BLOCKED: exact normal collector terminal proof is missing" >&2
  exit 2
fi

python3 "$VALIDATOR" simulator-artifact \
  --log "$LOG" \
  --spec "$SPEC" \
  --expected-build "$BUILD_SHA" \
  --expected-generation 1 \
  --expected-sequence 1 \
  --artifact "$ARTIFACT" \
  --write | tee "$OUTPUT_DIR/validator.txt"
if ! python3 -c '
import json,sys
value=json.load(open(sys.argv[1], "r", encoding="utf-8"))
if (value.get("status")!="ARTIFACT PASS" or value.get("scope")!="simulator"
        or value.get("deviceDecision")!="NOT EVALUATED"
        or value.get("artifactBytes")!=304):
    raise SystemExit(1)
' "$OUTPUT_DIR/validator.txt"; then
  echo "BLOCKED: validator did not return exact simulator ARTIFACT PASS" >&2
  exit 2
fi

xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIMULATOR_UDID" "$BUNDLE_ID"
if xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" app \
    >/dev/null 2>&1; then
  echo "BLOCKED: simulator adapter remains installed after cleanup" >&2
  exit 2
fi
installed=0
cleanup_done=1

echo "scope=host-neutral-adapter,no-product-save-runtime"
echo "SIMULATOR PASS / DEVICE PENDING"
