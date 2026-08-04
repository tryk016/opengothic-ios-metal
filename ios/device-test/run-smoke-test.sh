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
#   ... --require-clear-only-pass-self-test APP
#   ... --require-shading-prototype-tile-self-test APP
#   ... --require-shading-prototype-forward-self-test APP
#   ... --require-device-facts-reference-a17 APP
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
REQUIRE_CLEAR_ONLY_PASS_SELF_TEST=0
REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST=0
REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST=0
REQUIRE_DEVICE_FACTS_REFERENCE_A17=0
PIPELINE_ARCHIVE_TEST_MODE=""
EXPECTED_FAULT="none"
EXPECTED_FAULT_SEEN=0
EVIDENCE_PATH_FILE=""
SELF_TEST=0
APP_INPUT=""
NATIVE_ALPHA_TEST_CAUSAL_MODE=""
NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE=""
NATIVE_ALPHA_TEST_CAUSAL_MODE_SEEN=0
NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_SEEN=0
NATIVE_ALPHA_TEST_CAUSAL_FINALIZER_TEST_FAULT=""
readonly DURABLE_ZERO_MAX_CYCLES=3
readonly DURABLE_ZERO_SCANS_PER_CYCLE=10
readonly DURABLE_ZERO_INTERVAL_SECONDS=10
readonly DURABLE_ZERO_REQUIRED_STABLE_SECONDS=90
readonly DEVICECTL_PROCESS_QUERY_TIMEOUT_SECONDS=30
readonly DEVICECTL_TERMINATE_TIMEOUT_SECONDS=30
readonly DEVICECTL_FILE_QUERY_TIMEOUT_SECONDS=30
readonly RESOURCE_ALLOCATOR_SELF_TEST_PREFIX='RendererIOS resource allocator self-test:'
readonly RESOURCE_ALLOCATOR_SELF_TEST_ARMED='RendererIOS resource allocator self-test: ARMED case=private-memoryless-4x4-rgba8-v1'
readonly RESOURCE_ALLOCATOR_SELF_TEST_PASS='RendererIOS resource allocator self-test: PASS case=private-memoryless-4x4-rgba8-v1 allocation-only=1 encoded=0 render-pass=0 submitted=0 created=2 live=0 released=2'
readonly CLEAR_ONLY_PASS_SELF_TEST_PREFIX='RendererIOS clear-only pass self-test:'
readonly CLEAR_ONLY_PASS_SELF_TEST_ARMED='RendererIOS clear-only pass self-test: ARMED case=pm-clear-v1 abi=4 resources=3 logical-passes=3 private=1 memoryless=1'
readonly CLEAR_ONLY_PASS_SELF_TEST_ENCODED='RendererIOS clear-only pass self-test: ENCODED case=pm-clear-v1 physical-passes=2 command-buffers=1 render-encoders=2 private-load=clear private-store=store memoryless-load=clear memoryless-store=dont-care draws=0 pipelines=0 drawable=0 present=0'
readonly CLEAR_ONLY_PASS_SELF_TEST_SUBMITTED='RendererIOS clear-only pass self-test: SUBMITTED case=pm-clear-v1 command-buffers=1 submits=1'
readonly CLEAR_ONLY_PASS_SELF_TEST_PASS='RendererIOS clear-only pass self-test: PASS case=pm-clear-v1 terminal=completed created=2 live=0 released=2 wait-idle=0'
readonly CLEAR_ONLY_CAPTURE_PREFIX='RendererIOS clear-only capture:'
readonly CLEAR_ONLY_CAPTURE_ACQUIRED='RendererIOS clear-only capture: ACQUIRED'
readonly CLEAR_ONLY_CAPTURE_NAME='RendererIOS-pm-clear-v1.gputrace'
readonly SHADING_PROTOTYPE_TILE_SELF_TEST_PREFIX='RendererIOS shading prototype tile self-test:'
readonly SHADING_PROTOTYPE_TILE_SELF_TEST_ARMED='RendererIOS shading prototype tile self-test: ARMED case=tile-prototype-v1 contract=1 metallib-abi=7 minimum-apple=4 output=4x4 rgba8-private=1'
readonly SHADING_PROTOTYPE_TILE_SELF_TEST_FACTORY_READY='RendererIOS shading prototype tile self-test: FACTORY READY case=tile-prototype-v1 pipelines=3 forward=0 runtime-delta=0 builtin-delta=0 archive-delta=0'
readonly SHADING_PROTOTYPE_TILE_SELF_TEST_ENCODED='RendererIOS shading prototype tile self-test: ENCODED case=tile-prototype-v1 pass=1 encoder=1 draws=2 opaque=1 alpha=1 tdispatch=1 vb=168 output=1 mat=0 ib=4 clear-a=0 tgmem=0 size=16 dispatch=16x16x1 order=opaque,alpha,tile drawable=0 present=0'
readonly SHADING_PROTOTYPE_TILE_SELF_TEST_SUBMITTED='RendererIOS shading prototype tile self-test: SUBMITTED case=tile-prototype-v1 command-buffers=1 submits=1'
readonly SHADING_PROTOTYPE_TILE_SELF_TEST_PASS='RendererIOS shading prototype tile self-test: PASS case=tile-prototype-v1 terminal=completed created=1 live=0 released=1 wait-idle=0 runtime-delta=0 builtin-delta=0 archive-delta=0'
readonly SHADING_PROTOTYPE_TILE_SELF_TEST_UNSUPPORTED='RendererIOS shading prototype tile self-test: UNSUPPORTED case=tile-prototype-v1 reason=apple4-required side-effects=0'
readonly SHADING_PROTOTYPE_TILE_CAPTURE_PREFIX='RendererIOS shading prototype tile capture:'
readonly SHADING_PROTOTYPE_TILE_CAPTURE_ACQUIRED='RendererIOS shading prototype tile capture: ACQUIRED'
readonly SHADING_PROTOTYPE_TILE_CAPTURE_NAME='RendererIOS-tile-prototype-v1.gputrace'
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_PREFIX='RendererIOS shading prototype forward self-test:'
readonly SHADING_PROTOTYPE_FORWARD_CAPTURE_PREFIX='RendererIOS shading prototype forward capture:'
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_ARMED_TEMPLATE='RendererIOS shading prototype forward self-test: ARMED case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_FACTORY_READY_TEMPLATE='RendererIOS shading prototype forward self-test: FACTORY READY case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_ENCODED_TEMPLATE='RendererIOS shading prototype forward self-test: ENCODED case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_SUBMITTED_TEMPLATE='RendererIOS shading prototype forward self-test: SUBMITTED case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_TERMINAL_TEMPLATE='RendererIOS shading prototype forward self-test: TERMINAL case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_READBACK_TEMPLATE='RendererIOS shading prototype forward self-test: READBACK case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_PASS_TEMPLATE='RendererIOS shading prototype forward self-test: PASS case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_UNSUPPORTED_TEMPLATE='RendererIOS shading prototype forward self-test: UNSUPPORTED case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_SELF_TEST_FAIL_TEMPLATE='RendererIOS shading prototype forward self-test: FAIL case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_CAPTURE_ACQUIRED_TEMPLATE='RendererIOS shading prototype forward capture: ACQUIRED case=forward-prototype-v1 nonce='
readonly SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME='RendererIOS-forward-prototype-v1.gputrace'
readonly SHADING_PROTOTYPE_FORWARD_NONCE_ARGUMENT='-renderer-ios-forward-self-test-nonce='
readonly NATIVE_ALPHA_TEST_CAUSAL_PREFIX='RendererIOS native causal capture:'
readonly NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT='-renderer-ios-native-alpha-test-causal-mode='
readonly NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT='-renderer-ios-native-alpha-test-causal-nonce='
readonly NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT='-renderer-ios-native-alpha-test-causal-sequence='

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_bounded_command() {
  local timeout_seconds="$1"
  shift

  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ && $# -gt 0 ]] || return 2
  python3 - "$timeout_seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]
process = None
process_group = None
cleanup_latched = False
first_signal = None

class ForwardedSignal(Exception):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum

def forward_signal(signum, _frame):
    global first_signal
    if first_signal is None:
        first_signal = signum
    if cleanup_latched:
        return
    raise ForwardedSignal(first_signal)

def group_exists():
    if process_group is None:
        return False
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True

def bounded_leader_wait(deadline):
    if process is None or process.poll() is not None:
        return
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return
    try:
        process.wait(timeout=min(0.1, remaining))
    except subprocess.TimeoutExpired:
        pass

def terminate_group():
    global cleanup_latched
    cleanup_latched = True
    if process_group is None:
        return True
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        bounded_leader_wait(time.monotonic() + 0.1)
        return True
    term_deadline = time.monotonic() + 2
    while group_exists() and time.monotonic() < term_deadline:
        bounded_leader_wait(term_deadline)
        if process is None or process.poll() is not None:
            time.sleep(0.05)
    if not group_exists():
        bounded_leader_wait(time.monotonic() + 0.1)
        return True
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass
    kill_deadline = time.monotonic() + 5
    while group_exists() and time.monotonic() < kill_deadline:
        bounded_leader_wait(kill_deadline)
        if process is None or process.poll() is not None:
            time.sleep(0.05)
    bounded_leader_wait(kill_deadline)
    return not group_exists() and (
        process is None or process.poll() is not None
    )

for handled_signal in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(handled_signal, forward_signal)

try:
    process = subprocess.Popen(command, start_new_session=True)
    process_group = process.pid
    returncode = process.wait(timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    if not terminate_group():
        print("timed-out command process group could not be reaped", file=sys.stderr)
        raise SystemExit(125)
    print(
        f"command timed out after {timeout_seconds} seconds",
        file=sys.stderr,
    )
    raise SystemExit(124)
except ForwardedSignal as received:
    if not terminate_group():
        print("signalled command process group could not be reaped", file=sys.stderr)
        raise SystemExit(125)
    raise SystemExit(128 + received.signum)
except BaseException:
    if not terminate_group():
        print("failed command process group could not be reaped", file=sys.stderr)
        raise SystemExit(125)
    raise
if group_exists() and not terminate_group():
    print("completed command process group could not be reaped", file=sys.stderr)
    raise SystemExit(125)
raise SystemExit(returncode)
PY
}
run_bounded_device_file_query() {
  run_bounded_command "$DEVICECTL_FILE_QUERY_TIMEOUT_SECONDS" \
    xcrun devicectl device info files "$@"
}
secure_private_evidence() {
  local directory="$1"

  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  find "$directory" -type d -exec chmod 700 {} + || return 1
  find "$directory" -type f -exec chmod 600 {} + || return 1
}

create_private_evidence_directory() {
  local directory="$1"
  local allowed_root="$2"

  python3 - "$directory" "$allowed_root" <<'PY'
import os
import sys

directory_arg, allowed_root_arg = sys.argv[1:]
if not os.path.isabs(directory_arg) or not os.path.isabs(allowed_root_arg):
    raise SystemExit(1)

directory = os.path.abspath(directory_arg)
allowed_root = os.path.abspath(allowed_root_arg)
if directory != directory_arg or allowed_root != allowed_root_arg:
    raise SystemExit(1)

try:
    relative = os.path.relpath(directory, allowed_root)
except ValueError:
    raise SystemExit(1)
if relative in ("", ".") or relative == os.pardir or relative.startswith(
    os.pardir + os.sep
):
    raise SystemExit(1)

components = [component for component in relative.split(os.sep) if component]
if not components or any(component in (".", os.pardir) for component in components):
    raise SystemExit(1)

flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
opened = []

def open_or_create(parent_fd, component):
    try:
        return os.open(component, flags, dir_fd=parent_fd)
    except FileNotFoundError:
        os.mkdir(component, 0o700, dir_fd=parent_fd)
        return os.open(component, flags, dir_fd=parent_fd)

try:
    current_fd = os.open(os.sep, flags)
    opened.append(current_fd)
    for component in [
        component for component in allowed_root.split(os.sep) if component
    ]:
        current_fd = open_or_create(current_fd, component)
        opened.append(current_fd)

    allowed_real = os.path.realpath(allowed_root)
    if allowed_real != allowed_root:
        raise OSError("allowed evidence root contains a symlink")

    for component in components[:-1]:
        current_fd = open_or_create(current_fd, component)
        opened.append(current_fd)

    leaf = components[-1]
    os.mkdir(leaf, 0o700, dir_fd=current_fd)
    leaf_fd = os.open(leaf, flags, dir_fd=current_fd)
    opened.append(leaf_fd)
    os.fchmod(leaf_fd, 0o700)

    directory_real = os.path.realpath(directory)
    if directory_real != directory or os.path.commonpath(
        (allowed_real, directory_real)
    ) != allowed_real:
        raise OSError("evidence leaf escaped its allowed root")
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    for descriptor in reversed(opened):
        try:
            os.close(descriptor)
        except OSError:
            pass
PY
}

copy_private_evidence_path() {
  local source="$1"
  local destination="$2"

  [[ -e "$source" && ! -L "$source" &&
     ! -e "$destination" && ! -L "$destination" ]] || return 1
  ditto "$source" "$destination" || return 1
  if [[ -d "$destination" ]]; then
    secure_private_evidence "$destination"
  else
    chmod 600 "$destination"
  fi
}

smoke_evidence_root() {
  local expected_sha="$1"
  local expected_build="$2"
  local expected_fault="$3"

  if ((REQUIRE_DEVICE_FACTS_REFERENCE_A17 != 0)); then
    printf '%s/build/device-facts/%s/reference-a17\n' \
      "$ROOT" "$expected_build"
    return 0
  fi
  if [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
    printf '%s/build/device-self-test/%s/native-alpha-test-%s\n' \
      "$ROOT" "$expected_build" "$NATIVE_ALPHA_TEST_CAUSAL_MODE"
    return 0
  fi
  if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
    printf '%s/build/device-self-test/%s/shading-prototype-forward\n' \
      "$ROOT" "$expected_build"
    return 0
  fi
  if ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)); then
    printf '%s/build/device-self-test/%s/shading-prototype-tile\n' \
      "$ROOT" "$expected_build"
    return 0
  fi
  if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then
    printf '%s/build/device-self-test/%s/clear-only-pass\n' \
      "$ROOT" "$expected_build"
    return 0
  fi
  if ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST != 0)); then
    printf '%s/build/device-self-test/%s/resource-allocator\n' \
      "$ROOT" "$expected_build"
    return 0
  fi
  if [[ "$expected_fault" == none && "$expected_build" == "$expected_sha" ]]; then
    printf '%s/build/device-smoke/%s\n' "$ROOT" "$expected_sha"
  else
    printf '%s/build/device-fault/%s/%s\n' \
      "$ROOT" "$expected_build" "$expected_fault"
  fi
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
  evidence_root="$(smoke_evidence_root \
    "$expected_sha" "$expected_build" "$expected_fault")" || return 1
  printf '%s/%s-%s-%s\n' \
    "$evidence_root" "$outcome" "$timestamp" "$process_id"
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

validate_clear_only_pass_binary_profile() {
  local strings_file="$1"

  [[ -f "$strings_file" ]] || return 1
  if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then
    [[ "$(grep -Fxc "$CLEAR_ONLY_PASS_SELF_TEST_ARMED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$CLEAR_ONLY_PASS_SELF_TEST_ENCODED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$CLEAR_ONLY_PASS_SELF_TEST_SUBMITTED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$CLEAR_ONLY_PASS_SELF_TEST_PASS" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$CLEAR_ONLY_CAPTURE_ACQUIRED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    return 0
  fi
  ! grep -Fq "$CLEAR_ONLY_PASS_SELF_TEST_PREFIX" "$strings_file" &&
    ! grep -Fq "$CLEAR_ONLY_CAPTURE_PREFIX" "$strings_file"
}

validate_shading_prototype_tile_binary_profile() {
  local strings_file="$1"

  [[ -f "$strings_file" ]] || return 1
  if ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)); then
    [[ "$(grep -Fxc "$SHADING_PROTOTYPE_TILE_SELF_TEST_ARMED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$SHADING_PROTOTYPE_TILE_SELF_TEST_FACTORY_READY" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$SHADING_PROTOTYPE_TILE_SELF_TEST_ENCODED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$SHADING_PROTOTYPE_TILE_SELF_TEST_SUBMITTED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$SHADING_PROTOTYPE_TILE_SELF_TEST_PASS" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$SHADING_PROTOTYPE_TILE_SELF_TEST_UNSUPPORTED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    [[ "$(grep -Fxc "$SHADING_PROTOTYPE_TILE_CAPTURE_ACQUIRED" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    return 0
  fi
  ! grep -Fq "$SHADING_PROTOTYPE_TILE_SELF_TEST_PREFIX" "$strings_file" &&
    ! grep -Fq "$SHADING_PROTOTYPE_TILE_CAPTURE_PREFIX" "$strings_file"
}

validate_shading_prototype_forward_binary_profile() {
  local strings_file="$1"
  local template

  [[ -f "$strings_file" ]] || return 1
  if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
    for template in \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_ARMED_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_FACTORY_READY_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_ENCODED_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_SUBMITTED_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_TERMINAL_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_READBACK_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PASS_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_UNSUPPORTED_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_FAIL_TEMPLATE" \
        "$SHADING_PROTOTYPE_FORWARD_CAPTURE_ACQUIRED_TEMPLATE"; do
      [[ "$(grep -Fxc -- "$template" "$strings_file" || true)" -eq 1 ]] ||
        return 1
    done
    [[ "$(grep -Fxc -- "$SHADING_PROTOTYPE_FORWARD_NONCE_ARGUMENT" \
      "$strings_file" || true)" -eq 1 ]] || return 1
    return 0
  fi
  ! grep -Fq -- "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PREFIX" "$strings_file" &&
    ! grep -Fq -- "$SHADING_PROTOTYPE_FORWARD_CAPTURE_PREFIX" "$strings_file" &&
    ! grep -Fq -- "$SHADING_PROTOTYPE_FORWARD_NONCE_ARGUMENT" "$strings_file"
}

generate_shading_prototype_forward_nonce() {
  local nonce

  nonce="$(openssl rand -hex 16)" || return 1
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s\n' "$nonce"
}

is_canonical_positive_uint64() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import re
import sys

value = sys.argv[1]
if not re.fullmatch(r"[1-9][0-9]*", value):
    raise SystemExit(1)
if int(value) > 0xFFFFFFFFFFFFFFFF:
    raise SystemExit(1)
PY
}

generate_native_alpha_test_causal_nonce() {
  local nonce

  nonce="$(openssl rand -hex 16)" || return 1
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s\n' "$nonce"
}

validate_native_alpha_test_causal_binary_profile() {
  local strings_file="$1"
  local expected_build="$2"
  local opposite_mode

  [[ -f "$strings_file" ]] || return 1
  [[ "$NATIVE_ALPHA_TEST_CAUSAL_MODE" == causal-a ||
     "$NATIVE_ALPHA_TEST_CAUSAL_MODE" == causal-b ]] || return 1
  if [[ "$NATIVE_ALPHA_TEST_CAUSAL_MODE" == causal-a ]]; then
    opposite_mode=causal-b
  else
    opposite_mode=causal-a
  fi
  [[ "$(grep -Fxc -- "$expected_build" "$strings_file" || true)" -eq 1 ]] ||
    return 1
  [[ "$(grep -Fxc -- "$NATIVE_ALPHA_TEST_CAUSAL_MODE" \
    "$strings_file" || true)" -eq 1 ]] || return 1
  [[ "$(grep -Fxc -- "$opposite_mode" "$strings_file" || true)" -eq 0 ]] ||
    return 1
  [[ "$(grep -Fxc -- production "$strings_file" || true)" -eq 0 ]]
}

write_native_alpha_test_causal_contract() {
  local result="$1"
  local cleanup_result="$2"

  [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" && -n "${WORK:-}" ]] || return 0
  python3 - "$WORK/causal-contract.json" "$result" "$cleanup_result" \
      "$EXPECTED_SHA" "$NATIVE_ALPHA_TEST_CAUSAL_MODE" \
      "${NATIVE_ALPHA_TEST_CAUSAL_NONCE:-uncomputed}" \
      "$NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE" \
      "$CAUSAL_BINARY_SHA256" "$CAUSAL_METALLIB_SHA256" <<'PY'
import json
import os
import pathlib
import re
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
result, cleanup = sys.argv[2:4]
parent_sha, mode, nonce, sequence = sys.argv[4:8]
binary_sha, metallib_sha = sys.argv[8:10]
keys = {
    "schemaVersion",
    "result",
    "parentSha",
    "mode",
    "nonce",
    "targetSequence",
    "launchBoundary",
    "armedLine",
    "encodedLine",
    "draws",
    "alpha",
    "binarySha256",
    "metallibSha256",
    "cleanupResult",
}
payload = {}
if path.is_symlink():
    raise SystemExit("causal contract path must not be a symlink")
if path.exists():
    with path.open(encoding="utf-8") as source:
        payload = json.load(source)
    if set(payload) != keys:
        raise SystemExit("causal contract has an unexpected schema")
    if (
        type(payload["schemaVersion"]) is not int
        or payload["schemaVersion"] != 1
        or payload["result"] not in {"PENDING", "PASS", "FAIL"}
        or not isinstance(payload["parentSha"], str)
        or not isinstance(payload["mode"], str)
        or not isinstance(payload["nonce"], str)
        or type(payload["targetSequence"]) is not int
        or payload["targetSequence"] <= 0
        or payload["targetSequence"] > 0xFFFFFFFFFFFFFFFF
        or not isinstance(payload["binarySha256"], str)
        or not isinstance(payload["metallibSha256"], str)
        or payload["cleanupResult"] not in {"pending", "passed", "failed"}
    ):
        raise SystemExit("existing causal contract scalar type is invalid")
payload.update(
    {
        "schemaVersion": 1,
        "result": result,
        "parentSha": parent_sha,
        "mode": mode,
        "nonce": nonce,
        "targetSequence": int(sequence),
        "binarySha256": binary_sha,
        "metallibSha256": metallib_sha,
        "cleanupResult": cleanup,
    }
)
payload.setdefault("launchBoundary", None)
payload.setdefault("armedLine", None)
payload.setdefault("encodedLine", None)
payload.setdefault("draws", None)
payload.setdefault("alpha", None)
if set(payload) != keys:
    raise SystemExit("causal contract is incomplete")
if result not in {"PASS", "FAIL"}:
    raise SystemExit("causal contract result is invalid")
if cleanup not in {"passed", "failed"}:
    raise SystemExit("causal contract cleanup result is invalid")
if result == "PASS" and cleanup != "passed":
    raise SystemExit("causal PASS requires successful cleanup")
if (
    type(payload["schemaVersion"]) is not int
    or payload["schemaVersion"] != 1
    or payload["result"] != result
    or payload["parentSha"] != parent_sha
    or payload["mode"] != mode
    or payload["nonce"] != nonce
    or type(payload["targetSequence"]) is not int
    or payload["targetSequence"] <= 0
    or payload["targetSequence"] > 0xFFFFFFFFFFFFFFFF
    or payload["binarySha256"] != binary_sha
    or payload["metallibSha256"] != metallib_sha
    or payload["cleanupResult"] != cleanup
):
    raise SystemExit("causal contract identity or scalar type is invalid")
boundary = payload["launchBoundary"]
if boundary is not None and (
    not isinstance(boundary, dict)
    or set(boundary) != {
        "kind", "byteOffset", "preLaunchBytes", "preLaunchSha256"
    }
    or boundary["kind"] not in {
        "append-offset", "empty-prelaunch", "replaced-log"
    }
    or type(boundary["byteOffset"]) is not int
    or boundary["byteOffset"] < 0
    or type(boundary["preLaunchBytes"]) is not int
    or boundary["preLaunchBytes"] < 0
    or not isinstance(boundary["preLaunchSha256"], str)
    or not re.fullmatch(r"[0-9a-f]{64}", boundary["preLaunchSha256"])
):
    raise SystemExit("causal contract launch boundary is invalid")
if not all(
    value is None or isinstance(value, str)
    for value in (payload["armedLine"], payload["encodedLine"])
):
    raise SystemExit("causal contract marker type is invalid")
if (payload["draws"] is None) != (payload["alpha"] is None):
    raise SystemExit("causal contract draw counters are incomplete")
if payload["draws"] is not None and (
    type(payload["draws"]) is not int
    or type(payload["alpha"]) is not int
    or payload["alpha"] <= 0
    or payload["draws"] < payload["alpha"]
):
    raise SystemExit("causal contract draw counters are invalid")
if result == "PASS":
    target = payload["targetSequence"]
    expected_armed = (
        f"RendererIOS native causal capture: ARMED mode={mode} "
        f"nonce={nonce} target-sequence={target}"
    )
    encoded = re.fullmatch(
        rf"RendererIOS native causal capture: ENCODED mode={re.escape(mode)} "
        rf"nonce={re.escape(nonce)} generation=([1-9][0-9]*) "
        rf"sequence={target} draws=([1-9][0-9]*) alpha=([1-9][0-9]*)",
        payload["encodedLine"] if isinstance(payload["encodedLine"], str) else "",
    )
    if (
        cleanup != "passed"
        or not re.fullmatch(r"[0-9a-f]{40}", parent_sha)
        or mode not in {"causal-a", "causal-b"}
        or not re.fullmatch(r"[0-9a-f]{32}", nonce)
        or type(target) is not int
        or target <= 0
        or target > 0xFFFFFFFFFFFFFFFF
        or not isinstance(payload["launchBoundary"], dict)
        or set(payload["launchBoundary"]) != {
            "kind", "byteOffset", "preLaunchBytes", "preLaunchSha256"
        }
        or payload["launchBoundary"]["kind"] not in {
            "append-offset", "empty-prelaunch", "replaced-log"
        }
        or type(payload["launchBoundary"]["byteOffset"]) is not int
        or payload["launchBoundary"]["byteOffset"] < 0
        or type(payload["launchBoundary"]["preLaunchBytes"]) is not int
        or payload["launchBoundary"]["preLaunchBytes"] < 0
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            payload["launchBoundary"]["preLaunchSha256"],
        )
        or payload["armedLine"] != expected_armed
        or encoded is None
        or type(payload["draws"]) is not int
        or type(payload["alpha"]) is not int
        or payload["alpha"] <= 0
        or payload["draws"] < payload["alpha"]
        or int(encoded.group(2)) != payload["draws"]
        or int(encoded.group(3)) != payload["alpha"]
        or not re.fullmatch(r"[0-9a-f]{64}", binary_sha)
        or not re.fullmatch(r"[0-9a-f]{64}", metallib_sha)
    ):
        raise SystemExit("causal PASS contract is inconsistent")
fd, temporary = tempfile.mkstemp(
    prefix=".causal-contract.", suffix=".json", dir=str(path.parent)
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    with path.open(encoding="utf-8") as source:
        if json.load(source) != payload:
            raise SystemExit("causal contract readback mismatch")
    if path.stat().st_mode & 0o777 != 0o600:
        raise SystemExit("causal contract permissions mismatch")
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

install_native_alpha_test_causal_contract() {
  local source="$1"
  local destination="$2"
  local expected_result="$3"
  local expected_cleanup="$4"

  python3 - "$source" "$destination" "$expected_result" "$expected_cleanup" \
      "$NATIVE_ALPHA_TEST_CAUSAL_FINALIZER_TEST_FAULT" <<'PY'
import json
import os
import pathlib
import stat
import sys
import tempfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
expected_result, expected_cleanup, injected_fault = sys.argv[3:6]
expected_keys = {
    "schemaVersion", "result", "parentSha", "mode", "nonce",
    "targetSequence", "launchBoundary", "armedLine", "encodedLine",
    "draws", "alpha", "binarySha256", "metallibSha256", "cleanupResult",
}
if (
    not source.is_file()
    or source.is_symlink()
    or destination.is_symlink()
    or not destination.parent.is_dir()
    or destination.parent.is_symlink()
):
    raise SystemExit("causal contract install paths are invalid")
payload = json.loads(source.read_text(encoding="utf-8"))
if (
    set(payload) != expected_keys
    or payload["result"] != expected_result
    or payload["cleanupResult"] != expected_cleanup
    or type(payload["schemaVersion"]) is not int
    or payload["schemaVersion"] != 1
):
    raise SystemExit("causal contract install identity is invalid")
if injected_fault == "copy":
    raise SystemExit("causal contract injected copy failure")
source_bytes = source.read_bytes()
descriptor, temporary = tempfile.mkstemp(
    prefix=".causal-contract.", suffix=".json", dir=str(destination.parent)
)
try:
    with os.fdopen(descriptor, "wb") as output:
        output.write(source_bytes)
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, destination)
    if injected_fault == "readback":
        raise SystemExit("causal contract injected readback failure")
    if destination.read_bytes() != source_bytes:
        raise SystemExit("causal contract destination readback mismatch")
    if json.loads(destination.read_text(encoding="utf-8")) != payload:
        raise SystemExit("causal contract destination JSON mismatch")
    if stat.S_IMODE(destination.stat().st_mode) != 0o600:
        raise SystemExit("causal contract destination permissions mismatch")
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

commit_native_alpha_test_causal_pass_evidence() {
  local pending_directory="$1"
  local final_directory="$2"

  python3 - "$pending_directory" "$final_directory" <<'PY'
import json
import os
import pathlib
import stat
import sys

pending = pathlib.Path(sys.argv[1])
final = pathlib.Path(sys.argv[2])
if (
    not pending.is_dir()
    or pending.is_symlink()
    or final.exists()
    or final.is_symlink()
    or pending.parent != final.parent
):
    raise SystemExit("causal PASS evidence commit paths are invalid")
contract = pending / "causal-contract.json"
result = pending / "result.txt"
if (
    not contract.is_file()
    or contract.is_symlink()
    or not result.is_file()
    or result.is_symlink()
):
    raise SystemExit("causal PASS evidence is incomplete")
payload = json.loads(contract.read_text(encoding="utf-8"))
if (
    payload.get("result") != "PASS"
    or payload.get("cleanupResult") != "passed"
    or stat.S_IMODE(contract.stat().st_mode) != 0o600
    or "result=PASS" not in result.read_text(encoding="utf-8").splitlines()
):
    raise SystemExit("causal PASS evidence is not final")
os.rename(pending, final)
PY
}

retract_native_alpha_test_causal_pass_evidence() {
  local final_directory="$1"
  local pending_directory="$2"

  python3 - "$final_directory" "$pending_directory" <<'PY'
import os
import pathlib
import sys

final = pathlib.Path(sys.argv[1])
pending = pathlib.Path(sys.argv[2])
if (
    not final.is_dir()
    or final.is_symlink()
    or os.path.lexists(pending)
    or final.parent != pending.parent
):
    raise SystemExit("causal PASS evidence retraction paths are invalid")
os.rename(final, pending)
if (
    os.path.lexists(final)
    or not pending.is_dir()
    or pending.is_symlink()
):
    raise SystemExit("causal PASS evidence retraction readback failed")
PY
}

invalidate_native_alpha_test_causal_result() {
  local evidence_directory="$1"
  local cleanup_status="$2"

  python3 - "$evidence_directory/result.txt" "$cleanup_status" <<'PY'
import os
import pathlib
import stat
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
cleanup_status = sys.argv[2]
if (
    cleanup_status not in {"0", "1"}
    or not path.parent.is_dir()
    or path.parent.is_symlink()
    or path.is_symlink()
    or (path.exists() and not path.is_file())
):
    raise SystemExit("causal result invalidation paths are invalid")
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
preserved = [
    line
    for line in lines
    if not line.startswith("result=")
    and not line.startswith("failure_reason=")
    and not line.startswith("cleanup_status=")
]
rewritten = "\n".join(
    [
        "result=FAIL",
        *preserved,
        "failure_reason=causal-finalizer-fail-closed",
        f"cleanup_status={cleanup_status}",
    ]
) + "\n"
descriptor, temporary = tempfile.mkstemp(
    prefix=".result.", suffix=".txt", dir=str(path.parent)
)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(rewritten)
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    readback = path.read_text(encoding="utf-8").splitlines()
    if (
        readback.count("result=FAIL") != 1
        or "result=PASS" in readback
        or stat.S_IMODE(path.stat().st_mode) != 0o600
    ):
        raise SystemExit("causal result invalidation readback failed")
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

finalize_native_alpha_test_causal_cleanup() {
  local original_status="$1"
  local initial_cleanup_status="$2"
  local cleanup_result=passed
  local pending_evidence_dir=""
  local publication_failed=0

  CAUSAL_FINALIZER_CLEANUP_STATUS="$initial_cleanup_status"
  CAUSAL_FINALIZER_PUBLISHED=0
  if ((original_status != 0 || CAUSAL_FINALIZER_CLEANUP_STATUS != 0)); then
    :
  else
    if write_native_alpha_test_causal_contract PASS passed &&
       [[ -n "$PASS_EVIDENCE_DIR" &&
          -d "$PASS_EVIDENCE_DIR" &&
          -n "$PASS_EVIDENCE_FINAL_DIR" ]] &&
       install_native_alpha_test_causal_contract \
         "$WORK/causal-contract.json" \
         "$PASS_EVIDENCE_DIR/causal-contract.json" PASS passed &&
       secure_private_evidence "$PASS_EVIDENCE_DIR" &&
       pending_evidence_dir="$PASS_EVIDENCE_DIR" &&
       commit_native_alpha_test_causal_pass_evidence \
         "$pending_evidence_dir" "$PASS_EVIDENCE_FINAL_DIR"; then
      PASS_EVIDENCE_DIR="$PASS_EVIDENCE_FINAL_DIR"
      if publish_evidence_path "$PASS_EVIDENCE_DIR"; then
        CAUSAL_FINALIZER_PUBLISHED=1
        return 0
      fi
      publication_failed=1
      CAUSAL_FINALIZER_CLEANUP_STATUS=1
      NATIVE_ALPHA_TEST_CAUSAL_FINALIZER_TEST_FAULT=""
      if retract_native_alpha_test_causal_pass_evidence \
          "$PASS_EVIDENCE_DIR" "$pending_evidence_dir"; then
        PASS_EVIDENCE_DIR="$pending_evidence_dir"
      fi
    fi
    CAUSAL_FINALIZER_CLEANUP_STATUS=1
    NATIVE_ALPHA_TEST_CAUSAL_FINALIZER_TEST_FAULT=""
  fi

  if ((CAUSAL_FINALIZER_CLEANUP_STATUS != 0)); then
    cleanup_result=failed
  fi
  write_native_alpha_test_causal_contract FAIL "$cleanup_result" || return 1
  if [[ -n "$PASS_EVIDENCE_DIR" && -d "$PASS_EVIDENCE_DIR" ]]; then
    install_native_alpha_test_causal_contract \
      "$WORK/causal-contract.json" \
      "$PASS_EVIDENCE_DIR/causal-contract.json" FAIL "$cleanup_result" ||
      return 1
    invalidate_native_alpha_test_causal_result \
      "$PASS_EVIDENCE_DIR" "$CAUSAL_FINALIZER_CLEANUP_STATUS" || return 1
  fi
  ((publication_failed == 0)) || return 1
  return 0
}

validate_native_alpha_test_causal_log() {
  local log_file="$1"
  local prelaunch_log="$2"
  local stderr_file="$3"
  local prelaunch_stderr="$4"

  python3 - "$log_file" "$prelaunch_log" "$stderr_file" "$prelaunch_stderr" \
      "$NATIVE_ALPHA_TEST_CAUSAL_MODE" "$NATIVE_ALPHA_TEST_CAUSAL_NONCE" \
      "$NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE" "$EXPECTED_BUILD" \
      "$EXPECTED_SHA" "$CAUSAL_BINARY_SHA256" "$CAUSAL_METALLIB_SHA256" \
      "$WORK/causal-contract.json" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile

(
    log_path,
    prelaunch_path,
    stderr_path,
    prelaunch_stderr_path,
    mode,
    nonce,
    sequence_text,
    expected_build,
    parent_sha,
    binary_sha,
    metallib_sha,
    output_path,
) = sys.argv[1:]
full = pathlib.Path(log_path).read_bytes()
pre = pathlib.Path(prelaunch_path).read_bytes()
stderr_full = (
    pathlib.Path(stderr_path).read_bytes()
    if pathlib.Path(stderr_path).is_file()
    else b""
)
stderr_pre = pathlib.Path(prelaunch_stderr_path).read_bytes()
prefix = "RendererIOS native causal capture:"
if pre and full.startswith(pre):
    offset = len(pre)
    boundary_kind = "append-offset"
elif not pre:
    offset = 0
    boundary_kind = "empty-prelaunch"
else:
    offset = 0
    boundary_kind = "replaced-log"
segment = full[offset:].decode(errors="replace")
if stderr_pre and stderr_full.startswith(stderr_pre):
    stderr_offset = len(stderr_pre)
elif not stderr_pre:
    stderr_offset = 0
else:
    stderr_offset = 0
stderr_segment = stderr_full[stderr_offset:].decode(errors="replace")
lines = segment.splitlines()
causal = [(index, line) for index, line in enumerate(lines)
          if line.startswith(prefix)]
armed_pattern = re.compile(
    rf"^{re.escape(prefix)} ARMED mode={re.escape(mode)} "
    rf"nonce={re.escape(nonce)} target-sequence={re.escape(sequence_text)}$"
)
encoded_pattern = re.compile(
    rf"^{re.escape(prefix)} ENCODED mode={re.escape(mode)} "
    rf"nonce={re.escape(nonce)} generation=([1-9][0-9]*) "
    rf"sequence={re.escape(sequence_text)} draws=([1-9][0-9]*) "
    rf"alpha=([1-9][0-9]*)$"
)
armed = [(index, line) for index, line in causal if armed_pattern.fullmatch(line)]
encoded = []
for index, line in causal:
    match = encoded_pattern.fullmatch(line)
    if match:
        encoded.append((index, line, int(match.group(2)), int(match.group(3))))
if len(causal) != 2 or len(armed) != 1 or len(encoded) != 1:
    raise SystemExit("causal marker count or identity mismatch")
shell = [
    (index, match.group(1))
    for index, line in enumerate(lines)
    if (match := re.fullmatch(
        r"RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*",
        line,
    ))
]
fault = [
    (index, match.group(1))
    for index, line in enumerate(lines)
    if (match := re.fullmatch(
        r"RendererIOS configured fault mode=([^\s]+)",
        line,
    ))
]
if len(shell) != 1 or shell[0][1] != expected_build:
    raise SystemExit("current launch shell identity is missing or inconsistent")
if len(fault) != 1 or fault[0][1] != "none":
    raise SystemExit("current launch fault identity is missing or inconsistent")
if not (
    armed[0][0] < encoded[0][0]
    and shell[0][0] < encoded[0][0]
    and fault[0][0] < encoded[0][0]
):
    raise SystemExit("current launch identity or ARMED follows ENCODED")
draws, alpha = encoded[0][2:4]
if alpha <= 0 or draws < alpha:
    raise SystemExit("causal draw counts are invalid")
competing_prefixes = (
    "RendererIOS Bink self-test:",
    "RendererIOS resource allocator self-test:",
    "RendererIOS clear-only pass self-test:",
    "RendererIOS shading prototype tile self-test:",
    "RendererIOS shading prototype forward self-test:",
)
if any(line.startswith(competing_prefixes) for line in lines):
    raise SystemExit("competing self-test marker appeared in causal segment")
fatal = re.compile(
    r"RendererIOS (?:fatal|GPU shutdown failed|native Landscape encode failed|"
    r"IOSGPUScene metallib loading failed)|libc\+\+abi:|SIGABRT",
    re.IGNORECASE,
)
if fatal.search(segment) or fatal.search(stderr_segment):
    raise SystemExit("fatal or crash marker appeared in causal segment")
payload = {
    "schemaVersion": 1,
    "result": "PENDING",
    "parentSha": parent_sha,
    "mode": mode,
    "nonce": nonce,
    "targetSequence": int(sequence_text),
    "launchBoundary": {
        "kind": boundary_kind,
        "byteOffset": offset,
        "preLaunchBytes": len(pre),
        "preLaunchSha256": hashlib.sha256(pre).hexdigest(),
    },
    "armedLine": armed[0][1],
    "encodedLine": encoded[0][1],
    "draws": draws,
    "alpha": alpha,
    "binarySha256": binary_sha,
    "metallibSha256": metallib_sha,
    "cleanupResult": "pending",
}
final_path = pathlib.Path(output_path)
if final_path.is_symlink():
    raise SystemExit("causal contract path must not be a symlink")
fd, temporary = tempfile.mkstemp(
    prefix=".causal-contract.", suffix=".json",
    dir=str(final_path.parent),
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, output_path)
    with final_path.open(encoding="utf-8") as source:
        if json.load(source) != payload:
            raise SystemExit("causal contract readback mismatch")
    if final_path.stat().st_mode & 0o777 != 0o600:
        raise SystemExit("causal contract permissions mismatch")
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

run_native_alpha_test_causal_host_self_test() {
  local directory="$1"
  local expected_sha="$2"
  local candidate
  local caller_evidence_path_file="$EVIDENCE_PATH_FILE"
  local prelaunch="$directory/causal-prelaunch.log"
  local prelaunch_stderr="$directory/causal-prelaunch-stderr.log"
  local good="$directory/causal-good.log"
  local good_replaced="$directory/causal-good-replaced.log"
  local good_stderr="$directory/causal-good-stderr.log"
  local binary="$directory/causal-binary.txt"

  EVIDENCE_PATH_FILE="$directory/causal-finalizer-evidence-path.txt"
  is_canonical_positive_uint64 1 ||
    fail "causal uint64 parser rejected one"
  is_canonical_positive_uint64 18446744073709551615 ||
    fail "causal uint64 parser rejected uint64 max"
  if is_canonical_positive_uint64 0 ||
     is_canonical_positive_uint64 01 ||
     is_canonical_positive_uint64 +1 ||
     is_canonical_positive_uint64 18446744073709551616; then
    fail "causal uint64 parser accepted a non-canonical or overflowing value"
  fi

  WORK="$directory"
  EXPECTED_SHA="$expected_sha"
  EXPECTED_BUILD="$expected_sha"
  EXPECTED_FAULT=none
  NATIVE_ALPHA_TEST_CAUSAL_MODE=causal-a
  NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE=18446744073709551615
  NATIVE_ALPHA_TEST_CAUSAL_NONCE=0123456789abcdef0123456789abcdef
  CAUSAL_BINARY_SHA256="$(printf 'causal-binary\n' | shasum -a 256 | awk '{print $1}')"
  CAUSAL_METALLIB_SHA256="$(printf 'causal-metallib\n' | shasum -a 256 | awk '{print $1}')"
  APP_EXECUTABLE_SHA256="$CAUSAL_BINARY_SHA256"
  METALLIB_SHA="$CAUSAL_METALLIB_SHA256"

  printf '%s\n%s\n' "$expected_sha" causal-a >"$binary"
  validate_native_alpha_test_causal_binary_profile "$binary" "$expected_sha" ||
    fail "causal binary profile rejected its exact mode and SHA"
  for candidate in wrong-sha missing-mode duplicate-mode opposite-mode production; do
    case "$candidate" in
      wrong-sha)
        printf '%s\n%s\n' 1111111111111111111111111111111111111111 causal-a \
          >"$directory/causal-$candidate.txt"
        ;;
      missing-mode)
        printf '%s\n' "$expected_sha" >"$directory/causal-$candidate.txt"
        ;;
      duplicate-mode)
        printf '%s\n%s\n%s\n' "$expected_sha" causal-a causal-a \
          >"$directory/causal-$candidate.txt"
        ;;
      opposite-mode)
        printf '%s\n%s\n%s\n' "$expected_sha" causal-a causal-b \
          >"$directory/causal-$candidate.txt"
        ;;
      production)
        printf '%s\n%s\n%s\n' "$expected_sha" causal-a production \
          >"$directory/causal-$candidate.txt"
        ;;
    esac
    if validate_native_alpha_test_causal_binary_profile \
        "$directory/causal-$candidate.txt" "$expected_sha"; then
      fail "causal binary profile mutation survived: $candidate"
    fi
  done
  NATIVE_ALPHA_TEST_CAUSAL_MODE=causal-b
  printf '%s\n%s\n' "$expected_sha" causal-b >"$directory/causal-valid-b.txt"
  validate_native_alpha_test_causal_binary_profile \
      "$directory/causal-valid-b.txt" "$expected_sha" ||
    fail "causal binary profile rejected valid causal-b"
  printf '%s\n%s\n%s\n' "$expected_sha" causal-b causal-a \
    >"$directory/causal-b-opposite.txt"
  if validate_native_alpha_test_causal_binary_profile \
      "$directory/causal-b-opposite.txt" "$expected_sha"; then
    fail "causal-b binary profile accepted its opposite token"
  fi
  NATIVE_ALPHA_TEST_CAUSAL_MODE=causal-a

  python3 - "$prelaunch" "$prelaunch_stderr" "$good" "$good_replaced" \
      "$good_stderr" "$expected_sha" \
      "$NATIVE_ALPHA_TEST_CAUSAL_NONCE" \
      "$NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE" <<'PY'
import pathlib
import sys

(
    pre_path,
    pre_stderr_path,
    good_path,
    good_replaced_path,
    good_stderr_path,
    build,
    nonce,
    sequence,
) = sys.argv[1:]
old_armed = (
    "RendererIOS native causal capture: ARMED mode=causal-a "
    "nonce=ffffffffffffffffffffffffffffffff target-sequence=1\n"
)
pre = ("old launch\n" + old_armed).encode()
armed_line = (
    f"RendererIOS native causal capture: ARMED mode=causal-a "
    f"nonce={nonce} target-sequence={sequence}\n"
)
encoded_line = (
    f"RendererIOS native causal capture: ENCODED mode=causal-a "
    f"nonce={nonce} generation=7 sequence={sequence} draws=9 alpha=3\n"
)
fault_line = "RendererIOS configured fault mode=none\n"
shell_line = f"RendererIOS shell: version=fixture build={build} gpu=fixture\n"
identity_lines = fault_line + shell_line
current = armed_line + identity_lines + encoded_line
pathlib.Path(pre_path).write_bytes(pre)
pathlib.Path(good_path).write_bytes(pre + current.encode())
pathlib.Path(good_replaced_path).write_text(current)
stderr_pre = b"old launch: SIGABRT libc++abi: terminating\n"
pathlib.Path(pre_stderr_path).write_bytes(stderr_pre)
pathlib.Path(good_stderr_path).write_bytes(stderr_pre + b"current warning only\n")
mutations = {
    "missing-armed": current.replace(armed_line, ""),
    "missing-encoded": current.replace(encoded_line, ""),
    "duplicate-armed": current.replace(armed_line, armed_line + armed_line),
    "duplicate-encoded": current + encoded_line,
    "wrong-armed-mode": current.replace("mode=causal-a", "mode=causal-b", 1),
    "wrong-armed-nonce": current.replace(nonce, "f" * 32, 1),
    "wrong-armed-sequence": current.replace(
        f"target-sequence={sequence}", "target-sequence=1", 1
    ),
    "wrong-encoded-mode": current.replace(
        "ENCODED mode=causal-a", "ENCODED mode=causal-b", 1
    ),
    "wrong-encoded-nonce": current.replace(
        f"ENCODED mode=causal-a nonce={nonce}",
        f"ENCODED mode=causal-a nonce={'e' * 32}",
        1,
    ),
    "wrong-encoded-sequence": current.replace(
        f"generation=7 sequence={sequence}",
        "generation=7 sequence=1",
        1,
    ),
    "missing-shell": current.replace(shell_line, ""),
    "duplicate-shell": current.replace(shell_line, shell_line + shell_line),
    "wrong-shell": current.replace(build, "f" * 40),
    "missing-fault": current.replace(fault_line, ""),
    "duplicate-fault": current.replace(fault_line, fault_line + fault_line),
    "wrong-fault": current.replace("fault mode=none", "fault mode=unexpected"),
    "shell-after-encoded": armed_line + fault_line + encoded_line + shell_line,
    "fault-after-encoded": armed_line + shell_line + encoded_line + fault_line,
    "encoded-before-armed": identity_lines + encoded_line + armed_line,
    "encoded-before-identity": armed_line + encoded_line + identity_lines,
    "extra": current + "RendererIOS native causal capture: ACQUIRED\n",
    "post-encoded": current + (
        f"RendererIOS native causal capture: FAIL mode=causal-a nonce={nonce} "
        f"generation=7 sequence={sequence} reason=duplicate-target\n"
    ),
    "alpha-zero": current.replace("alpha=3", "alpha=0"),
    "draws-less-alpha": current.replace("draws=9 alpha=3", "draws=2 alpha=3"),
    "competing": current + "RendererIOS Bink self-test: PASS fixture\n",
    "fatal": current + "RendererIOS fatal fixture\n",
}
directory = pathlib.Path(good_path).parent
for name, text in mutations.items():
    (directory / f"causal-log-{name}.txt").write_bytes(pre + text.encode())
(directory / "causal-log-replaced-markers-before-shell.txt").write_text(
    armed_line + encoded_line + identity_lines
)
for name, text in {
    "sigabrt": "current SIGABRT\n",
    "libcxxabi": "libc++abi: terminating due to exception\n",
    "renderer-fatal": "RendererIOS fatal fixture\n",
}.items():
    (directory / f"causal-stderr-{name}.log").write_bytes(
        stderr_pre + text.encode()
    )
PY

  validate_native_alpha_test_causal_log \
      "$good" "$prelaunch" "$good_stderr" "$prelaunch_stderr" ||
    fail "causal current-launch log self-test rejected a valid contract"
  validate_native_alpha_test_causal_log \
      "$good_replaced" "$prelaunch" "$good_stderr" "$prelaunch_stderr" ||
    fail "causal replaced-log self-test rejected a valid current launch"
  for candidate in "$directory"/causal-log-*.txt; do
    if validate_native_alpha_test_causal_log \
        "$candidate" "$prelaunch" "$good_stderr" "$prelaunch_stderr" \
        >/dev/null 2>&1; then
      fail "causal log mutation survived: $(basename "$candidate")"
    fi
  done
  for candidate in "$directory"/causal-stderr-*.log; do
    if validate_native_alpha_test_causal_log \
        "$good" "$prelaunch" "$candidate" "$prelaunch_stderr" \
        >/dev/null 2>&1; then
      fail "causal stderr mutation survived: $(basename "$candidate")"
    fi
  done
  write_native_alpha_test_causal_contract PASS passed ||
    fail "causal PASS contract finalization failed"
  python3 - "$WORK/causal-contract.json" "$expected_sha" <<'PY' ||
import json
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text())
expected_keys = {
    "schemaVersion", "result", "parentSha", "mode", "nonce",
    "targetSequence", "launchBoundary", "armedLine", "encodedLine",
    "draws", "alpha", "binarySha256", "metallibSha256", "cleanupResult",
}
if (
    set(payload) != expected_keys
    or payload["schemaVersion"] != 1
    or payload["result"] != "PASS"
    or payload["cleanupResult"] != "passed"
    or payload["parentSha"] != sys.argv[2]
    or payload["targetSequence"] != 18446744073709551615
    or payload["draws"] != 9
    or payload["alpha"] != 3
    or stat.S_IMODE(path.stat().st_mode) != 0o600
):
    raise SystemExit(1)
PY
    fail "causal PASS contract schema/readback self-test failed"
  cp "$WORK/causal-contract.json" "$directory/causal-contract-valid.json"
  python3 - "$directory/causal-contract-valid.json" "$directory" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text())
directory = pathlib.Path(sys.argv[2])
mutations = {
    "missing-key": lambda value: value.pop("armedLine"),
    "bool-schema": lambda value: value.__setitem__("schemaVersion", True),
    "bool-sequence": lambda value: value.__setitem__("targetSequence", True),
    "bool-draws": lambda value: value.__setitem__("draws", True),
    "bool-boundary": lambda value: value["launchBoundary"].__setitem__(
        "byteOffset", True
    ),
    "wrong-result": lambda value: value.__setitem__("result", "BROKEN"),
    "wrong-mode-type": lambda value: value.__setitem__("mode", False),
    "zero-alpha": lambda value: value.__setitem__("alpha", 0),
}
for name, mutate in mutations.items():
    candidate = json.loads(json.dumps(payload))
    mutate(candidate)
    (directory / f"causal-contract-{name}.json").write_text(
        json.dumps(candidate) + "\n"
    )
PY
  for candidate in "$directory"/causal-contract-{missing-key,bool-schema,bool-sequence,bool-draws,bool-boundary,wrong-result,wrong-mode-type,zero-alpha}.json; do
    cp "$candidate" "$WORK/causal-contract.json"
    if write_native_alpha_test_causal_contract PASS passed >/dev/null 2>&1; then
      fail "causal JSON mutation survived: $(basename "$candidate")"
    fi
  done

  prepare_causal_finalizer_fixture() {
    local name="$1"

    validate_native_alpha_test_causal_log \
        "$good" "$prelaunch" "$good_stderr" "$prelaunch_stderr" ||
      fail "causal finalizer fixture log validation failed: $name"
    PASS_EVIDENCE_DIR="$directory/.pending-$name"
    PASS_EVIDENCE_FINAL_DIR="$directory/pass-$name"
    mkdir -m 700 "$PASS_EVIDENCE_DIR" ||
      fail "could not create causal finalizer fixture: $name"
    printf 'result=PASS\n' >"$PASS_EVIDENCE_DIR/result.txt"
    chmod 600 "$PASS_EVIDENCE_DIR/result.txt"
  }
  verify_causal_finalizer_contract() {
    local path="$1"
    local result="$2"
    local cleanup_result="$3"

    python3 - "$path" "$result" "$cleanup_result" <<'PY'
import json
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text())
if (
    payload["result"] != sys.argv[2]
    or payload["cleanupResult"] != sys.argv[3]
    or type(payload["targetSequence"]) is not int
    or type(payload["draws"]) is not int
    or type(payload["alpha"]) is not int
    or stat.S_IMODE(path.stat().st_mode) != 0o600
):
    raise SystemExit(1)
PY
  }

  prepare_causal_finalizer_fixture pass
  finalize_native_alpha_test_causal_cleanup 0 0 ||
    fail "causal atomic PASS finalizer self-test failed"
  ((CAUSAL_FINALIZER_PUBLISHED == 1 &&
    CAUSAL_FINALIZER_CLEANUP_STATUS == 0)) ||
    fail "causal atomic PASS finalizer state is invalid"
  [[ -d "$directory/pass-pass" &&
     ! -e "$directory/.pending-pass" ]] ||
    fail "causal PASS evidence was not committed by atomic rename"
  verify_causal_finalizer_contract \
      "$directory/pass-pass/causal-contract.json" PASS passed ||
    fail "causal committed PASS contract is invalid"

  prepare_causal_finalizer_fixture ordinary-fail
  finalize_native_alpha_test_causal_cleanup 1 0 ||
    fail "causal ordinary FAIL finalizer self-test failed"
  ((CAUSAL_FINALIZER_PUBLISHED == 0 &&
    CAUSAL_FINALIZER_CLEANUP_STATUS == 0)) ||
    fail "causal ordinary FAIL cleanup state is invalid"
  verify_causal_finalizer_contract \
      "$directory/.pending-ordinary-fail/causal-contract.json" FAIL passed ||
    fail "causal ordinary FAIL did not preserve successful cleanup"
  [[ "$(grep -Fxc result=FAIL \
      "$directory/.pending-ordinary-fail/result.txt" || true)" -eq 1 &&
     "$(grep -Fxc result=PASS \
      "$directory/.pending-ordinary-fail/result.txt" || true)" -eq 0 ]] ||
    fail "causal ordinary FAIL left a provisional PASS result"
  verify_causal_finalizer_contract \
      "$WORK/causal-contract.json" FAIL passed ||
    fail "causal ordinary FAIL work contract is invalid"

  prepare_causal_finalizer_fixture cleanup-fail
  write_native_alpha_test_causal_contract PASS passed ||
    fail "causal provisional PASS fixture could not be finalized"
  install_native_alpha_test_causal_contract \
      "$WORK/causal-contract.json" \
      "$PASS_EVIDENCE_DIR/causal-contract.json" PASS passed ||
    fail "causal provisional PASS fixture could not be installed"
  finalize_native_alpha_test_causal_cleanup 0 1 ||
    fail "causal cleanup-invalidated PASS finalizer self-test failed"
  ((CAUSAL_FINALIZER_PUBLISHED == 0 &&
    CAUSAL_FINALIZER_CLEANUP_STATUS == 1)) ||
    fail "causal cleanup-invalidated PASS state is invalid"
  verify_causal_finalizer_contract \
      "$directory/.pending-cleanup-fail/causal-contract.json" FAIL failed ||
    fail "causal cleanup failure did not overwrite provisional PASS"

  for candidate in copy readback; do
    prepare_causal_finalizer_fixture "$candidate-fail"
    NATIVE_ALPHA_TEST_CAUSAL_FINALIZER_TEST_FAULT="$candidate"
    finalize_native_alpha_test_causal_cleanup 0 0 ||
      fail "causal $candidate failure recovery did not finalize FAIL"
    ((CAUSAL_FINALIZER_PUBLISHED == 0 &&
      CAUSAL_FINALIZER_CLEANUP_STATUS == 1)) ||
      fail "causal $candidate failure did not invalidate PASS"
    [[ ! -e "$directory/pass-$candidate-fail" ]] ||
      fail "causal $candidate failure published a PASS directory"
    verify_causal_finalizer_contract \
        "$directory/.pending-$candidate-fail/causal-contract.json" \
        FAIL failed ||
      fail "causal $candidate failure did not preserve final FAIL"
  done
  NATIVE_ALPHA_TEST_CAUSAL_FINALIZER_TEST_FAULT=""

  prepare_causal_finalizer_fixture publish-fail
  mkdir "$directory/evidence-path-directory" ||
    fail "could not create causal publication failure fixture"
  EVIDENCE_PATH_FILE="$directory/evidence-path-directory"
  if finalize_native_alpha_test_causal_cleanup 0 0 >/dev/null 2>&1; then
    fail "causal evidence-path publication failure returned success"
  fi
  ((CAUSAL_FINALIZER_PUBLISHED == 0 &&
    CAUSAL_FINALIZER_CLEANUP_STATUS == 1)) ||
    fail "causal evidence-path publication failure state is invalid"
  [[ ! -e "$directory/pass-publish-fail" &&
     -d "$directory/.pending-publish-fail" ]] ||
    fail "causal evidence-path publication failure left public PASS evidence"
  verify_causal_finalizer_contract \
      "$directory/.pending-publish-fail/causal-contract.json" FAIL failed ||
    fail "causal evidence-path publication failure left a PASS contract"
  [[ "$(grep -Fxc result=FAIL \
      "$directory/.pending-publish-fail/result.txt" || true)" -eq 1 &&
     "$(grep -Fxc result=PASS \
      "$directory/.pending-publish-fail/result.txt" || true)" -eq 0 ]] ||
    fail "causal evidence-path publication failure left a PASS result"
  EVIDENCE_PATH_FILE="$caller_evidence_path_file"
  PASS_EVIDENCE_DIR=""
  PASS_EVIDENCE_FINAL_DIR=""
}

select_bundle_id_from_apps() {
  local apps_json="$1"
  local requested="${2:-}"

  python3 - "$apps_json" "$BASE_BUNDLE_ID" "$requested" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
apps = payload.get("result", {}).get("apps")
if not isinstance(apps, list):
    raise SystemExit("installed app provider returned no apps array")
base = sys.argv[2] + "."
requested = sys.argv[3]
candidates = []
for app in apps:
    if not isinstance(app, dict):
        raise SystemExit("installed app entry is not an object")
    bundle = app.get("bundleIdentifier")
    if not isinstance(bundle, str):
        continue
    if not bundle.startswith(base) or bundle.endswith(".xctrunner"):
        continue
    if requested and bundle != requested:
        continue
    candidates.append(bundle)
if len(candidates) != 1:
    raise SystemExit(
        f"expected exactly one installed non-xctrunner {base}* app, "
        f"found {len(candidates)}"
    )
print(candidates[0])
PY
}

verify_game_container_resources() {
  local phase="$1"
  local documents="$WORK/documents-$phase.json"
  local scripts="$WORK/scripts-$phase.json"
  local system="$WORK/system-$phase.json"

  [[ "$phase" == preinstall || "$phase" == postinstall ||
     "$phase" == postruntime ]] || return 1
  [[ -n "$DEVICE" && -n "$BUNDLE_ID" ]] || return 1
  run_bounded_device_file_query --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$documents" >/dev/null || return 1
  run_bounded_device_file_query --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile \
    --subdirectory "Documents/_work/Data/Scripts/_compiled" --no-recurse \
    --json-output "$scripts" >/dev/null || return 1
  run_bounded_device_file_query --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory "Documents/system" --no-recurse \
    --json-output "$system" >/dev/null || return 1
  python3 - "$documents" "$scripts" "$system" <<'PY'
import json
import sys


def files(path):
    value = json.load(open(path, encoding="utf-8")).get("result", {}).get("files")
    if not isinstance(value, list):
        raise SystemExit(f"file provider returned no files array: {path}")
    return value


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


documents = files(sys.argv[1])
entries = {entry.get("name"): entry for entry in documents}
invalid = []
for name in ("Data", "_work", "system"):
    entry = entries.get(name)
    resources = entry.get("resources", {}) if entry else {}
    if (
        entry is None
        or resources.get("isDirectory") is not True
        or resources.get("isSymbolicLink") is not False
    ):
        invalid.append(name)
if not regular_file(files(sys.argv[2]), "gothic.dat"):
    invalid.append("_work/Data/Scripts/_compiled/Gothic.dat")
if not regular_file(files(sys.argv[3]), "gothic.ini"):
    invalid.append("system/Gothic.ini")
if invalid:
    raise SystemExit(
        "OpenGothic container has missing/invalid resources: "
        + ", ".join(invalid)
    )
PY
}

run_host_contract_self_test() {
  local expected_sha="${OPENGOTHIC_IOS_EXPECTED_SHA:-0123456789abcdef0123456789abcdef01234567}"
  local expected_build="${OPENGOTHIC_IOS_EXPECTED_BUILD:-${expected_sha}-local}"
  local expected_fault="${OPENGOTHIC_IOS_EXPECTED_FAULT:-none}"
  local timestamp="${OPENGOTHIC_IOS_EVIDENCE_TIMESTAMP:-20000101T000000Z}"
  local process_id="${OPENGOTHIC_IOS_EVIDENCE_PID:-4242}"
  local self_test_work evidence_file actual expected expected_plain expected_resource
  local expected_committed
  local expected_clear clear_path clear_failure_path clear_committed_path
  local expected_tile tile_path tile_failure_path tile_committed_path
  local expected_forward forward_path forward_failure_path forward_committed_path
  local expected_causal causal_path causal_failure_path
  local expected_device_facts device_facts_path device_facts_failure_path
  local plain_path plain_repeat_path committed_path committed_repeat_path
  local resource_path resource_failure_path
  local resource_committed_path
  local plain_binary self_test_binary duplicate_binary clear_binary duplicate_clear_binary
  local tile_binary duplicate_tile_binary missing_tile_unsupported_binary
  local duplicate_tile_unsupported_binary
  local forward_binary duplicate_forward_binary
  local requested_resource_allocator_self_test="$REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST"
  local requested_clear_only_pass_self_test="$REQUIRE_CLEAR_ONLY_PASS_SELF_TEST"
  local requested_shading_prototype_tile_self_test="$REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST"
  local requested_shading_prototype_forward_self_test="$REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST"
  local requested_device_facts_reference_a17="$REQUIRE_DEVICE_FACTS_REFERENCE_A17"
  local requested_native_alpha_test_causal_mode="$NATIVE_ALPHA_TEST_CAUSAL_MODE"
  local requested_native_alpha_test_causal_sequence="$NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE"

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
  ((requested_clear_only_pass_self_test == 0)) || [[ "$expected_fault" == none ]] ||
    fail "clear-only pass host contract self-test requires expected fault none"
  ((requested_shading_prototype_tile_self_test == 0)) || [[ "$expected_fault" == none ]] ||
    fail "shading prototype Tile host contract self-test requires expected fault none"
  ((requested_shading_prototype_forward_self_test == 0)) || [[ "$expected_fault" == none ]] ||
    fail "shading prototype Forward host contract self-test requires expected fault none"

  self_test_work="$(mktemp -d -t opengothic-smoke-contract)"
  self_test_work="$(cd "$self_test_work" && pwd -P)"
  evidence_file="$EVIDENCE_PATH_FILE"
  [[ -n "$evidence_file" ]] || evidence_file="$self_test_work/evidence-path.txt"
  EVIDENCE_PATH_FILE="$evidence_file"
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=0
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST=0
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST=0
  REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST=0
  REQUIRE_DEVICE_FACTS_REFERENCE_A17=0
  NATIVE_ALPHA_TEST_CAUSAL_MODE=""
  NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE=""
  plain_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" "$expected_fault")"
  if [[ "$expected_fault" == none && "$expected_build" == "$expected_sha" ]]; then
    expected_plain="$ROOT/build/device-smoke/$expected_sha/pass-$timestamp-$process_id"
  else
    expected_plain="$ROOT/build/device-fault/$expected_build/$expected_fault/pass-$timestamp-$process_id"
  fi
  [[ "$plain_path" == "$expected_plain" ]] ||
    fail "SHA-local smoke evidence path self-test failed"
  plain_repeat_path="$(smoke_evidence_path pass "$timestamp" \
    "$((process_id + 1))" "$expected_sha" "$expected_build" "$expected_fault")"
  [[ "$plain_repeat_path" != "$plain_path" ]] ||
    fail "repeat smoke evidence path collides with an earlier PASS"
  committed_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_sha" none)"
  expected_committed="$ROOT/build/device-smoke/$expected_sha/pass-$timestamp-$process_id"
  [[ "$committed_path" == "$expected_committed" &&
     "$committed_path" != "$ROOT/build/device-smoke/$expected_sha" ]] ||
    fail "committed clean smoke evidence path is not an immutable run leaf"
  committed_repeat_path="$(smoke_evidence_path pass "$timestamp" \
    "$((process_id + 1))" "$expected_sha" "$expected_sha" none)"
  [[ "$committed_repeat_path" != "$committed_path" &&
     "$committed_repeat_path" == \
       "$ROOT/build/device-smoke/$expected_sha/pass-$timestamp-$((process_id + 1))" ]] ||
    fail "repeated committed clean smoke evidence path collides"
  REQUIRE_DEVICE_FACTS_REFERENCE_A17=1
  device_facts_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  expected_device_facts="$ROOT/build/device-facts/$expected_build/reference-a17/pass-$timestamp-$process_id"
  [[ "$device_facts_path" == "$expected_device_facts" ]] ||
    fail "device-facts A17 reference evidence path self-test failed"
  [[ "$device_facts_path" != "$plain_path" ]] ||
    fail "device-facts A17 reference and plain smoke evidence paths overlap"
  device_facts_failure_path="$(smoke_evidence_path failure "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  [[ "$device_facts_failure_path" == \
     "$ROOT/build/device-facts/$expected_build/reference-a17/failure-$timestamp-$process_id" ]] ||
    fail "device-facts A17 failure evidence path self-test failed"
  REQUIRE_DEVICE_FACTS_REFERENCE_A17=0
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
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=0
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST=1
  clear_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  expected_clear="$ROOT/build/device-self-test/$expected_build/clear-only-pass/pass-$timestamp-$process_id"
  [[ "$clear_path" == "$expected_clear" ]] ||
    fail "clear-only pass smoke evidence path self-test failed"
  [[ "$clear_path" != "$plain_path" && "$clear_path" != "$resource_path" ]] ||
    fail "clear-only pass smoke evidence path overlaps another profile"
  clear_failure_path="$(smoke_evidence_path failure "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  [[ "$clear_failure_path" == \
     "$ROOT/build/device-self-test/$expected_build/clear-only-pass/failure-$timestamp-$process_id" ]] ||
    fail "clear-only pass failure evidence path self-test failed"
  clear_committed_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_sha" none)"
  [[ "$clear_committed_path" == \
     "$ROOT/build/device-self-test/$expected_sha/clear-only-pass/pass-$timestamp-$process_id" ]] ||
    fail "committed clear-only pass evidence path self-test failed"
  [[ "$clear_committed_path" != "$ROOT/build/device-smoke/$expected_sha" ]] ||
    fail "committed clear-only pass evidence overlaps plain committed smoke"
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST=0
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST=1
  tile_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  expected_tile="$ROOT/build/device-self-test/$expected_build/shading-prototype-tile/pass-$timestamp-$process_id"
  [[ "$tile_path" == "$expected_tile" ]] ||
    fail "shading prototype Tile smoke evidence path self-test failed"
  [[ "$tile_path" != "$plain_path" && "$tile_path" != "$resource_path" &&
     "$tile_path" != "$clear_path" ]] ||
    fail "shading prototype Tile smoke evidence path overlaps another profile"
  tile_failure_path="$(smoke_evidence_path failure "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  [[ "$tile_failure_path" == \
     "$ROOT/build/device-self-test/$expected_build/shading-prototype-tile/failure-$timestamp-$process_id" ]] ||
    fail "shading prototype Tile failure evidence path self-test failed"
  tile_committed_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_sha" none)"
  [[ "$tile_committed_path" == \
     "$ROOT/build/device-self-test/$expected_sha/shading-prototype-tile/pass-$timestamp-$process_id" ]] ||
    fail "committed shading prototype Tile evidence path self-test failed"
  [[ "$tile_committed_path" != "$ROOT/build/device-smoke/$expected_sha" ]] ||
    fail "committed shading prototype Tile evidence overlaps plain committed smoke"
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST=0
  REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1
  forward_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  expected_forward="$ROOT/build/device-self-test/$expected_build/shading-prototype-forward/pass-$timestamp-$process_id"
  [[ "$forward_path" == "$expected_forward" ]] ||
    fail "shading prototype Forward smoke evidence path self-test failed"
  [[ "$forward_path" != "$plain_path" && "$forward_path" != "$resource_path" &&
     "$forward_path" != "$clear_path" && "$forward_path" != "$tile_path" ]] ||
    fail "shading prototype Forward smoke evidence path overlaps another profile"
  forward_failure_path="$(smoke_evidence_path failure "$timestamp" "$process_id" \
    "$expected_sha" "$expected_build" none)"
  [[ "$forward_failure_path" == \
     "$ROOT/build/device-self-test/$expected_build/shading-prototype-forward/failure-$timestamp-$process_id" ]] ||
    fail "shading prototype Forward failure evidence path self-test failed"
  forward_committed_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_sha" none)"
  [[ "$forward_committed_path" == \
    "$ROOT/build/device-self-test/$expected_sha/shading-prototype-forward/pass-$timestamp-$process_id" ]] ||
    fail "committed shading prototype Forward evidence path self-test failed"
  NATIVE_ALPHA_TEST_CAUSAL_MODE=causal-a
  causal_path="$(smoke_evidence_path pass "$timestamp" "$process_id" \
    "$expected_sha" "$expected_sha" none)"
  expected_causal="$ROOT/build/device-self-test/$expected_sha/native-alpha-test-causal-a/pass-$timestamp-$process_id"
  [[ "$causal_path" == "$expected_causal" ]] ||
    fail "native alpha-test causal smoke evidence path self-test failed"
  causal_failure_path="$(smoke_evidence_path failure "$timestamp" "$process_id" \
    "$expected_sha" "$expected_sha" none)"
  [[ "$causal_failure_path" == \
    "$ROOT/build/device-self-test/$expected_sha/native-alpha-test-causal-a/failure-$timestamp-$process_id" ]] ||
    fail "native alpha-test causal failure evidence path self-test failed"
  NATIVE_ALPHA_TEST_CAUSAL_MODE=""
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST="$requested_resource_allocator_self_test"
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST="$requested_clear_only_pass_self_test"
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST="$requested_shading_prototype_tile_self_test"
  REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST="$requested_shading_prototype_forward_self_test"
  REQUIRE_DEVICE_FACTS_REFERENCE_A17="$requested_device_facts_reference_a17"
  actual="$plain_path"
  expected="$expected_plain"
  if ((requested_device_facts_reference_a17 != 0)); then
    actual="$device_facts_path"
    expected="$expected_device_facts"
  elif ((requested_resource_allocator_self_test != 0)); then
    actual="$resource_path"
    expected="$expected_resource"
  elif ((requested_clear_only_pass_self_test != 0)); then
    actual="$clear_path"
    expected="$expected_clear"
  elif ((requested_shading_prototype_tile_self_test != 0)); then
    actual="$tile_path"
    expected="$expected_tile"
  elif ((requested_shading_prototype_forward_self_test != 0)); then
    actual="$forward_path"
    expected="$expected_forward"
  fi
  plain_binary="$self_test_work/plain-binary.txt"
  self_test_binary="$self_test_work/resource-allocator-binary.txt"
  duplicate_binary="$self_test_work/resource-allocator-duplicate-binary.txt"
  clear_binary="$self_test_work/clear-only-pass-binary.txt"
  duplicate_clear_binary="$self_test_work/clear-only-pass-duplicate-binary.txt"
  tile_binary="$self_test_work/shading-prototype-tile-binary.txt"
  duplicate_tile_binary="$self_test_work/shading-prototype-tile-duplicate-binary.txt"
  missing_tile_unsupported_binary="$self_test_work/shading-prototype-tile-missing-unsupported.txt"
  duplicate_tile_unsupported_binary="$self_test_work/shading-prototype-tile-duplicate-unsupported.txt"
  forward_binary="$self_test_work/shading-prototype-forward-binary.txt"
  duplicate_forward_binary="$self_test_work/shading-prototype-forward-duplicate-binary.txt"
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
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$CLEAR_ONLY_PASS_SELF_TEST_ARMED" \
    "$CLEAR_ONLY_PASS_SELF_TEST_ENCODED" \
    "$CLEAR_ONLY_PASS_SELF_TEST_SUBMITTED" \
    "$CLEAR_ONLY_PASS_SELF_TEST_PASS" \
    "$CLEAR_ONLY_CAPTURE_ACQUIRED" \
    >"$clear_binary"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$CLEAR_ONLY_PASS_SELF_TEST_ARMED" \
    "$CLEAR_ONLY_PASS_SELF_TEST_ENCODED" \
    "$CLEAR_ONLY_PASS_SELF_TEST_SUBMITTED" \
    "$CLEAR_ONLY_PASS_SELF_TEST_PASS" \
    "$CLEAR_ONLY_CAPTURE_ACQUIRED" \
    "$CLEAR_ONLY_CAPTURE_ACQUIRED" \
    >"$duplicate_clear_binary"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_ARMED" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_FACTORY_READY" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_ENCODED" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_SUBMITTED" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_PASS" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_UNSUPPORTED" \
    "$SHADING_PROTOTYPE_TILE_CAPTURE_ACQUIRED" \
    >"$tile_binary"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_ARMED" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_FACTORY_READY" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_ENCODED" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_SUBMITTED" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_PASS" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_UNSUPPORTED" \
    "$SHADING_PROTOTYPE_TILE_CAPTURE_ACQUIRED" \
    "$SHADING_PROTOTYPE_TILE_CAPTURE_ACQUIRED" \
    >"$duplicate_tile_binary"
  grep -Fv "$SHADING_PROTOTYPE_TILE_SELF_TEST_UNSUPPORTED" \
    "$tile_binary" >"$missing_tile_unsupported_binary"
  {
    cat "$tile_binary"
    printf '%s\n' "$SHADING_PROTOTYPE_TILE_SELF_TEST_UNSUPPORTED"
  } >"$duplicate_tile_unsupported_binary"
  printf '%s\n' \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_ARMED_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_FACTORY_READY_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_ENCODED_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_SUBMITTED_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_TERMINAL_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_READBACK_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PASS_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_UNSUPPORTED_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_FAIL_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_CAPTURE_ACQUIRED_TEMPLATE" \
    "$SHADING_PROTOTYPE_FORWARD_NONCE_ARGUMENT" \
    >"$forward_binary"
  {
    cat "$forward_binary"
    printf '%s\n' "$SHADING_PROTOTYPE_FORWARD_CAPTURE_ACQUIRED_TEMPLATE"
  } >"$duplicate_forward_binary"
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=0
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST=0
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST=0
  REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST=0
  validate_resource_allocator_binary_profile "$plain_binary" ||
    fail "plain binary profile self-test failed"
  if validate_resource_allocator_binary_profile "$self_test_binary"; then
    fail "unrequested resource allocator binary profile survived"
  fi
  validate_clear_only_pass_binary_profile "$plain_binary" ||
    fail "plain clear-only pass binary profile self-test failed"
  if validate_clear_only_pass_binary_profile "$clear_binary"; then
    fail "unrequested clear-only pass binary profile survived"
  fi
  validate_shading_prototype_tile_binary_profile "$plain_binary" ||
    fail "plain shading prototype Tile binary profile self-test failed"
  if validate_shading_prototype_tile_binary_profile "$tile_binary"; then
    fail "unrequested shading prototype Tile binary profile survived"
  fi
  validate_shading_prototype_forward_binary_profile "$plain_binary" ||
    fail "plain shading prototype Forward binary profile self-test failed"
  if validate_shading_prototype_forward_binary_profile "$forward_binary"; then
    fail "unrequested shading prototype Forward binary profile survived"
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
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST=0
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST=1
  validate_clear_only_pass_binary_profile "$clear_binary" ||
    fail "clear-only pass binary profile self-test failed"
  if validate_clear_only_pass_binary_profile "$plain_binary"; then
    fail "clear-only pass binary profile accepted a plain artifact"
  fi
  if validate_clear_only_pass_binary_profile "$duplicate_clear_binary"; then
    fail "duplicate clear-only pass binary marker survived"
  fi
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST=0
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST=1
  validate_shading_prototype_tile_binary_profile "$tile_binary" ||
    fail "shading prototype Tile binary profile self-test failed"
  if validate_shading_prototype_tile_binary_profile "$plain_binary"; then
    fail "shading prototype Tile binary profile accepted a plain artifact"
  fi
  if validate_shading_prototype_tile_binary_profile "$duplicate_tile_binary"; then
    fail "duplicate shading prototype Tile binary marker survived"
  fi
  if validate_shading_prototype_tile_binary_profile \
      "$missing_tile_unsupported_binary"; then
    fail "missing shading prototype Tile UNSUPPORTED binary marker survived"
  fi
  if validate_shading_prototype_tile_binary_profile \
      "$duplicate_tile_unsupported_binary"; then
    fail "duplicate shading prototype Tile UNSUPPORTED binary marker survived"
  fi
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST=0
  REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1
  validate_shading_prototype_forward_binary_profile "$forward_binary" ||
    fail "shading prototype Forward binary profile self-test failed"
  if validate_shading_prototype_forward_binary_profile "$plain_binary"; then
    fail "shading prototype Forward binary profile accepted a plain artifact"
  fi
  if validate_shading_prototype_forward_binary_profile "$duplicate_forward_binary"; then
    fail "duplicate shading prototype Forward binary marker survived"
  fi
  PYTHONDONTWRITEBYTECODE=1 python3 \
    "$ROOT/ios/device-test/validate-device-facts-log.py" \
    --self-test || fail "device-facts app marker validator self-test failed"
  python3 "$ROOT/ios/device-test/validate-metal-capture-artifact.py" \
    --self-test || fail "Metal capture artifact validator self-test failed"
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST="$requested_resource_allocator_self_test"
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST="$requested_clear_only_pass_self_test"
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST="$requested_shading_prototype_tile_self_test"
  REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST="$requested_shading_prototype_forward_self_test"
  REQUIRE_DEVICE_FACTS_REFERENCE_A17="$requested_device_facts_reference_a17"

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

  local game_bundle="${BASE_BUNDLE_ID}.RMJWWPF379"
  local runner_bundle="${game_bundle}.RendererIOSUITests.xctrunner"
  printf '%s\n' \
    "{\"result\":{\"apps\":[{\"bundleIdentifier\":\"$game_bundle\"},{\"bundleIdentifier\":\"$runner_bundle\"}]}}" \
    >"$self_test_work/apps-game-runner.json"
  [[ "$(select_bundle_id_from_apps "$self_test_work/apps-game-runner.json")" == \
     "$game_bundle" ]] ||
    fail "bundle selector did not exclude .xctrunner"
  [[ "$(select_bundle_id_from_apps "$self_test_work/apps-game-runner.json" \
    "$game_bundle")" == "$game_bundle" ]] ||
    fail "bundle selector did not preserve an exact requested game id"
  if select_bundle_id_from_apps "$self_test_work/apps-game-runner.json" \
      "$runner_bundle" >/dev/null 2>&1; then
    fail "bundle selector admitted an explicitly requested .xctrunner"
  fi
  printf '%s\n' \
    "{\"result\":{\"apps\":[{\"bundleIdentifier\":\"$runner_bundle\"}]}}" \
    >"$self_test_work/apps-runner-only.json"
  if select_bundle_id_from_apps "$self_test_work/apps-runner-only.json" \
      >/dev/null 2>&1; then
    fail "bundle selector admitted an .xctrunner-only fixture"
  fi
  printf '%s\n' \
    "{\"result\":{\"apps\":[{\"bundleIdentifier\":\"$game_bundle\"},{\"bundleIdentifier\":\"${BASE_BUNDLE_ID}.ABCDEFGHIJ\"}]}}" \
    >"$self_test_work/apps-ambiguous.json"
  if select_bundle_id_from_apps "$self_test_work/apps-ambiguous.json" \
      >/dev/null 2>&1; then
    fail "bundle selector admitted two game candidates"
  fi

  local nonce_one nonce_two
  nonce_one="$(generate_shading_prototype_forward_nonce)" ||
    fail "could not generate first Forward nonce"
  nonce_two="$(generate_shading_prototype_forward_nonce)" ||
    fail "could not generate second Forward nonce"
  [[ "$nonce_one" =~ ^[0-9a-f]{32}$ && "$nonce_two" =~ ^[0-9a-f]{32}$ &&
     "$nonce_one" != "$nonce_two" ]] ||
    fail "Forward nonce generator is not random 32 lowercase hex"

  local evidence_parent="$self_test_work/evidence"
  local evidence_leaf="$evidence_parent/pass-$timestamp-$process_id"
  local evidence_symlink="$evidence_parent/pass-$timestamp-$((process_id + 1))"
  local evidence_escape_root="$self_test_work/evidence-escape"
  local evidence_symlink_parent="$evidence_parent/symlink-parent"
  local evidence_escaped_leaf="$evidence_symlink_parent/pass-$timestamp-$process_id"
  local evidence_traversal_leaf="$evidence_parent/../escaped-pass-$timestamp-$process_id"
  local copy_source="$self_test_work/copy-source.txt"
  local copy_destination="$self_test_work/copy-destination.txt"
  local timeout_descendant_pid="$self_test_work/timeout-descendant.pid"
  local timeout_group_pid="$self_test_work/timeout-group.pid"
  local success_descendant_pid="$self_test_work/success-descendant.pid"
  local success_group_pid="$self_test_work/success-group.pid"
  local timeout_descendant timeout_group timeout_started timeout_elapsed
  local success_descendant success_group
  local timeout_status=0 success_status=0 nonzero_status=0
  create_private_evidence_directory "$evidence_leaf" "$evidence_parent" ||
    fail "private evidence directory creation self-test failed"
  [[ -d "$evidence_leaf" && ! -L "$evidence_leaf" ]] ||
    fail "private evidence directory is not a real directory"
  if create_private_evidence_directory "$evidence_leaf" "$evidence_parent"; then
    fail "existing private evidence directory survived collision check"
  fi
  ln -s "$evidence_leaf" "$evidence_symlink"
  if create_private_evidence_directory "$evidence_symlink" "$evidence_parent"; then
    fail "private evidence directory admitted a symlink leaf"
  fi
  mkdir "$evidence_escape_root"
  ln -s "$evidence_escape_root" "$evidence_symlink_parent"
  if create_private_evidence_directory \
      "$evidence_escaped_leaf" "$evidence_parent"; then
    fail "private evidence directory admitted a symlink parent"
  fi
  [[ ! -e "$evidence_escape_root/pass-$timestamp-$process_id" ]] ||
    fail "private evidence directory escaped through a symlink parent"
  if create_private_evidence_directory \
      "$evidence_traversal_leaf" "$evidence_parent"; then
    fail "private evidence directory admitted parent traversal"
  fi
  [[ ! -e "$self_test_work/escaped-pass-$timestamp-$process_id" ]] ||
    fail "private evidence directory escaped through parent traversal"
  printf '%s\n' source >"$copy_source"
  printf '%s\n' original >"$copy_destination"
  if copy_private_evidence_path "$copy_source" "$copy_destination"; then
    fail "private evidence copy overwrote an existing destination"
  fi
  [[ "$(cat "$copy_destination")" == original ]] ||
    fail "private evidence collision changed existing bytes"
  timeout_started=$SECONDS
  run_bounded_command 1 /bin/sh -c \
    'echo "$$" >"$1"; /bin/sh -c '"'"'trap "" TERM; sleep 30'"'"' & echo "$!" >"$2"; wait' \
    _ "$timeout_group_pid" "$timeout_descendant_pid" \
    >/dev/null 2>&1 || timeout_status=$?
  timeout_elapsed=$((SECONDS - timeout_started))
  [[ "$timeout_status" == 124 ]] ||
    fail "bounded command timeout did not return exact status 124"
  [[ "$timeout_elapsed" -ge 1 && "$timeout_elapsed" -le 8 ]] ||
    fail "bounded command timeout exceeded its cleanup deadline"
  [[ -s "$timeout_group_pid" && -s "$timeout_descendant_pid" ]] ||
    fail "bounded command timeout did not create process-group witnesses"
  timeout_group="$(cat "$timeout_group_pid")"
  timeout_descendant="$(cat "$timeout_descendant_pid")"
  [[ "$timeout_group" =~ ^[0-9]+$ &&
     "$timeout_descendant" =~ ^[0-9]+$ ]] ||
    fail "bounded command process-group witnesses are invalid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$timeout_descendant" 2>/dev/null &&
       ! kill -0 "-$timeout_group" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$timeout_descendant" 2>/dev/null ||
     kill -0 "-$timeout_group" 2>/dev/null; then
    kill -KILL "$timeout_descendant" 2>/dev/null || true
    kill -KILL "-$timeout_group" 2>/dev/null || true
    fail "bounded command timeout left a live descendant"
  fi
  run_bounded_command 5 python3 -c '
import os
import sys
import time

with open(sys.argv[1], "w") as stream:
    stream.write(str(os.getpid()))
child = os.fork()
if child:
    with open(sys.argv[2], "w") as stream:
        stream.write(str(child))
    os._exit(0)
time.sleep(30)
' "$success_group_pid" "$success_descendant_pid" \
    >/dev/null 2>&1 || success_status=$?
  [[ "$success_status" == 0 ]] ||
    fail "bounded command did not preserve normal leader success"
  [[ -s "$success_group_pid" && -s "$success_descendant_pid" ]] ||
    fail "bounded command normal success did not create orphan witnesses"
  success_group="$(cat "$success_group_pid")"
  success_descendant="$(cat "$success_descendant_pid")"
  [[ "$success_group" =~ ^[0-9]+$ &&
     "$success_descendant" =~ ^[0-9]+$ ]] ||
    fail "bounded command normal-success orphan witnesses are invalid"
  if kill -0 "$success_descendant" 2>/dev/null ||
     kill -0 "-$success_group" 2>/dev/null; then
    kill -KILL "$success_descendant" 2>/dev/null || true
    kill -KILL "-$success_group" 2>/dev/null || true
    fail "bounded command normal success left a live descendant"
  fi
  run_bounded_command 1 /usr/bin/true ||
    fail "bounded command rejected a successful command"
  run_bounded_command 1 /usr/bin/false >/dev/null 2>&1 ||
    nonzero_status=$?
  [[ "$nonzero_status" == 1 ]] ||
    fail "bounded command did not propagate an ordinary nonzero status"

  run_native_alpha_test_causal_host_self_test \
    "$self_test_work" "$expected_sha"
  NATIVE_ALPHA_TEST_CAUSAL_MODE="$requested_native_alpha_test_causal_mode"
  NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE="$requested_native_alpha_test_causal_sequence"
  publish_evidence_path "$actual"
  [[ "$(cat "$evidence_file")" == "$expected" ]] ||
    fail "smoke final evidence path publication self-test failed"
  find "$self_test_work" -type l -delete
  find "$self_test_work" -type f -delete
  find "$self_test_work" -depth -type d ! -path "$self_test_work" \
    -exec rmdir {} +
  rmdir "$self_test_work"
  echo "smoke bounded-command normal-success orphan cleanup self-test passed"
  echo "smoke host contract self-test passed: fault=$expected_fault build=$expected_build profiles=plain,resource-allocator,clear-only-pass,shading-prototype-tile,shading-prototype-forward,native-alpha-test-causal bundle-selector=xctrunner-safe nonce=32hex crash-states=3"
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
    --require-clear-only-pass-self-test)
      REQUIRE_CLEAR_ONLY_PASS_SELF_TEST=1
      shift
      ;;
    --require-shading-prototype-tile-self-test)
      REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST=1
      shift
      ;;
    --require-shading-prototype-forward-self-test)
      REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1
      shift
      ;;
    --require-device-facts-reference-a17)
      REQUIRE_DEVICE_FACTS_REFERENCE_A17=1
      shift
      ;;
    --native-alpha-test-causal-mode)
      ((NATIVE_ALPHA_TEST_CAUSAL_MODE_SEEN == 0)) ||
        fail "native alpha-test causal mode may be supplied exactly once"
      NATIVE_ALPHA_TEST_CAUSAL_MODE="${2:?missing native alpha-test causal mode}"
      NATIVE_ALPHA_TEST_CAUSAL_MODE_SEEN=1
      shift 2
      ;;
    --native-alpha-test-causal-sequence)
      ((NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_SEEN == 0)) ||
        fail "native alpha-test causal sequence may be supplied exactly once"
      NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE="${2:?missing native alpha-test causal sequence}"
      NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_SEEN=1
      shift 2
      ;;
    --pipeline-archive-test-mode)
      PIPELINE_ARCHIVE_TEST_MODE="${2:?missing pipeline archive test mode}"
      shift 2
      ;;
    --expected-fault)
      ((EXPECTED_FAULT_SEEN == 0)) ||
        fail "expected fault may be supplied exactly once"
      EXPECTED_FAULT="${2:?missing expected fault}"
      EXPECTED_FAULT_SEEN=1
      shift 2
      ;;
    --evidence-path-file)
      EVIDENCE_PATH_FILE="${2:?missing evidence path file}"
      shift 2
      ;;
    --self-test) SELF_TEST=1; shift ;;
    -*) fail "usage: $0 [--duration seconds] [--save-slot number|--new-game] [--require-bink-self-test|--require-resource-allocator-self-test|--require-clear-only-pass-self-test|--require-shading-prototype-tile-self-test|--require-shading-prototype-forward-self-test|--require-device-facts-reference-a17] [--native-alpha-test-causal-mode causal-a|causal-b --native-alpha-test-causal-sequence canonical-positive-uint64] [--pipeline-archive-test-mode cold|corrupt] [--expected-fault none|post-submit-suboptimal|preview-fence-error-after-terminal|frame-fence-error-after-terminal] [--evidence-path-file absolute-path] path/to/Gothic2Notr.app | $0 --self-test [--evidence-path-file absolute-path]" ;;
    *) [[ -z "$APP_INPUT" ]] || fail "only one app path may be supplied"; APP_INPUT="$1"; shift ;;
  esac
done

[[ "$DURATION" =~ ^[0-9]+$ ]] && ((DURATION >= 10 && DURATION <= 600)) ||
  fail "duration must be 10..600 seconds"
[[ "$SAVE_SLOT" =~ ^[0-9]+$ ]] || fail "save slot must be a non-negative integer"
((NEW_GAME == 0 || SAVE_SLOT_EXPLICIT == 0)) ||
  fail "--new-game and --save-slot are mutually exclusive"
((NATIVE_ALPHA_TEST_CAUSAL_MODE_SEEN ==
  NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_SEEN)) ||
  fail "native alpha-test causal mode and sequence must be supplied together"
if ((NATIVE_ALPHA_TEST_CAUSAL_MODE_SEEN != 0)); then
  [[ "$NATIVE_ALPHA_TEST_CAUSAL_MODE" == causal-a ||
     "$NATIVE_ALPHA_TEST_CAUSAL_MODE" == causal-b ]] ||
    fail "native alpha-test causal mode must be causal-a or causal-b"
  is_canonical_positive_uint64 "$NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE" ||
    fail "native alpha-test causal sequence must be a canonical positive uint64"
fi
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
((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0)) || [[ "$EXPECTED_FAULT" == none ]] ||
  fail "clear-only pass self-test requires expected fault none"
((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0)) || [[ "$EXPECTED_FAULT" == none ]] ||
  fail "shading prototype Tile self-test requires expected fault none"
((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0 || REQUIRE_BINK_SELF_TEST == 0)) ||
  fail "resource allocator and Bink self-tests are mutually exclusive"
((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0 || REQUIRE_BINK_SELF_TEST == 0)) ||
  fail "clear-only pass and Bink self-tests are mutually exclusive"
((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0 || REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0)) ||
  fail "clear-only pass and resource allocator self-tests are mutually exclusive"
((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0)) || [[ -z "$PIPELINE_ARCHIVE_TEST_MODE" ]] ||
  fail "clear-only pass self-test requires an empty pipeline archive profile"
((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0 || REQUIRE_BINK_SELF_TEST == 0)) ||
  fail "shading prototype Tile and Bink self-tests are mutually exclusive"
((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0 ||
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0)) ||
  fail "shading prototype Tile and resource allocator self-tests are mutually exclusive"
((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0 ||
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0)) ||
  fail "shading prototype Tile and clear-only pass self-tests are mutually exclusive"
((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0)) ||
  [[ -z "$PIPELINE_ARCHIVE_TEST_MODE" ]] ||
  fail "shading prototype Tile self-test requires an empty pipeline archive profile"
((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0)) || [[ "$EXPECTED_FAULT" == none ]] ||
  fail "shading prototype Forward self-test requires expected fault none"
((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0 || REQUIRE_BINK_SELF_TEST == 0)) ||
  fail "shading prototype Forward and Bink self-tests are mutually exclusive"
((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0 ||
  REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0)) ||
  fail "shading prototype Forward and resource allocator self-tests are mutually exclusive"
((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0 ||
  REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0)) ||
  fail "shading prototype Forward and clear-only pass self-tests are mutually exclusive"
((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0 ||
  REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0)) ||
  fail "shading prototype Forward and Tile self-tests are mutually exclusive"
((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0)) ||
  [[ -z "$PIPELINE_ARCHIVE_TEST_MODE" ]] ||
  fail "shading prototype Forward self-test requires an empty pipeline archive profile"
((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0 || DURATION >= 35)) ||
  fail "shading prototype Forward self-test duration must be 35..600 seconds"
((REQUIRE_DEVICE_FACTS_REFERENCE_A17 == 0)) || [[ "$EXPECTED_FAULT" == none ]] ||
  fail "device-facts A17 reference gate requires expected fault none"
((REQUIRE_DEVICE_FACTS_REFERENCE_A17 == 0 ||
  (REQUIRE_BINK_SELF_TEST == 0 &&
   REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0 &&
   REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0 &&
   REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0 &&
   REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0))) ||
  fail "device-facts A17 reference gate requires an ordinary smoke profile"
((REQUIRE_DEVICE_FACTS_REFERENCE_A17 == 0)) ||
  [[ -z "$PIPELINE_ARCHIVE_TEST_MODE" ]] ||
  fail "device-facts A17 reference gate requires an empty pipeline archive profile"
if [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
  [[ "$EXPECTED_FAULT" == none ]] ||
    fail "native alpha-test causal mode requires expected fault none"
  ((REQUIRE_BINK_SELF_TEST == 0 &&
    REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0 &&
    REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0 &&
    REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0 &&
    REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0 &&
    REQUIRE_DEVICE_FACTS_REFERENCE_A17 == 0)) ||
    fail "native alpha-test causal mode is mutually exclusive with all other self-tests"
  [[ -z "$PIPELINE_ARCHIVE_TEST_MODE" ]] ||
    fail "native alpha-test causal mode requires an empty pipeline archive profile"
fi
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
umask 077
chmod 700 "$WORK" || fail "could not secure smoke work directory"
DEVICE=""
APP_EXECUTABLE=""
APP_EXECUTABLE_SHA256="uncomputed"
CAUSAL_BINARY_SHA256="uncomputed"
CAUSAL_METALLIB_SHA256="uncomputed"
NATIVE_ALPHA_TEST_CAUSAL_NONCE="uncomputed"
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
CLEAR_ONLY_PASS_SELF_TEST_VALIDATION="not-required"
CLEAR_ONLY_PASS_SELF_TEST_PID="none"
CLEAR_ONLY_PASS_SELF_TEST_PID_DISCOVERY_ATTEMPTS=0
CLEAR_ONLY_PASS_SELF_TEST_PROCESS_SURVIVED=0
CLEAR_ONLY_CAPTURE_ATTEMPTED=0
CLEAR_ONLY_CAPTURE_STATUS="not-required"
CLEAR_ONLY_CAPTURE_KIND="missing"
CLEAR_ONLY_CAPTURE_BYTES=0
CLEAR_ONLY_CAPTURE_MANIFEST_SHA256="missing"
SHADING_PROTOTYPE_TILE_SELF_TEST_VALIDATION="not-required"
SHADING_PROTOTYPE_TILE_SELF_TEST_PID="none"
SHADING_PROTOTYPE_TILE_SELF_TEST_PID_DISCOVERY_ATTEMPTS=0
SHADING_PROTOTYPE_TILE_SELF_TEST_PROCESS_SURVIVED=0
SHADING_PROTOTYPE_TILE_CAPTURE_ATTEMPTED=0
SHADING_PROTOTYPE_TILE_CAPTURE_STATUS="not-required"
SHADING_PROTOTYPE_TILE_CAPTURE_KIND="missing"
SHADING_PROTOTYPE_TILE_CAPTURE_BYTES=0
SHADING_PROTOTYPE_TILE_CAPTURE_MANIFEST_SHA256="missing"
SHADING_PROTOTYPE_FORWARD_SELF_TEST_VALIDATION="not-required"
SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE="none"
SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID="none"
SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID_DISCOVERY_ATTEMPTS=0
SHADING_PROTOTYPE_FORWARD_SELF_TEST_PROCESS_SURVIVED=0
SHADING_PROTOTYPE_FORWARD_CAPTURE_ATTEMPTED=0
SHADING_PROTOTYPE_FORWARD_CAPTURE_STATUS="not-required"
SHADING_PROTOTYPE_FORWARD_CAPTURE_KIND="missing"
SHADING_PROTOTYPE_FORWARD_CAPTURE_BYTES=0
SHADING_PROTOTYPE_FORWARD_CAPTURE_MANIFEST_SHA256="missing"
SHADING_PROTOTYPE_FORWARD_SAVES_BEFORE_CAPTURED=0
SHADING_PROTOTYPE_FORWARD_SAVES_AFTER_CAPTURED=0
SHADING_PROTOTYPE_FORWARD_SAVES_MATCH=0
SHADING_PROTOTYPE_FORWARD_SAME_PID_STABLE_SECONDS=0
SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH="none"
SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND="none"
SHADING_PROTOTYPE_FORWARD_FAILURE_REASON="none"
GAME_CONTAINER_POSTRUNTIME_VALIDATION="not-attempted"
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
PASS_EVIDENCE_FINAL_DIR=""
CAUSAL_FINALIZER_CLEANUP_STATUS=0
CAUSAL_FINALIZER_PUBLISHED=0
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

  run_bounded_command "$DEVICECTL_PROCESS_QUERY_TIMEOUT_SECONDS" \
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
        run_bounded_command "$DEVICECTL_TERMINATE_TIMEOUT_SECONDS" \
          xcrun devicectl device process terminate --device "$DEVICE" \
          --pid "$pid" --kill --quiet \
          >/dev/null 2>>"$WORK/cleanup.log" || true
      else
        run_bounded_command "$DEVICECTL_TERMINATE_TIMEOUT_SECONDS" \
          xcrun devicectl device process terminate --device "$DEVICE" \
          --pid "$pid" --quiet \
          >/dev/null 2>>"$WORK/cleanup.log" || true
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
  if ! run_bounded_device_file_query --device "$DEVICE" \
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

capture_clear_only_capture_artifact() {
  local listing="$WORK/clear-only-capture-listing.json"
  local destination="$WORK/$CLEAR_ONLY_CAPTURE_NAME"
  local summary="$WORK/clear-only-capture-summary.txt"
  local listed_kind values

  ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)) || return 0
  if ((CLEAR_ONLY_CAPTURE_ATTEMPTED != 0)); then
    [[ "$CLEAR_ONLY_CAPTURE_STATUS" == acquired ]]
    return
  fi
  CLEAR_ONLY_CAPTURE_ATTEMPTED=1
  CLEAR_ONLY_CAPTURE_STATUS="failed"
  [[ -n "$DEVICE" && -n "$BUNDLE_ID" ]] || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1

  run_bounded_device_file_query --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$listing" >/dev/null || return 1
  listed_kind="$(python3 - "$listing" "$CLEAR_ONLY_CAPTURE_NAME" <<'PY'
import json
import sys

files = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("files")
if not isinstance(files, list):
    raise SystemExit("capture listing provider returned no files array")
matches = [entry for entry in files if entry.get("name") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one flat capture artifact, found {len(matches)}")
resources = matches[0].get("resources", {})
if resources.get("isSymbolicLink") is not False:
    raise SystemExit("capture artifact listing is a symlink or has unknown link state")
is_directory = resources.get("isDirectory")
if is_directory is True:
    print("directory")
elif is_directory is False:
    print("file")
else:
    raise SystemExit("capture artifact listing has unknown file kind")
PY
  )" || return 1
  [[ "$listed_kind" == file || "$listed_kind" == directory ]] || return 1

  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "Documents/$CLEAR_ONLY_CAPTURE_NAME" \
    --destination "$destination" >/dev/null || return 1
  [[ -e "$destination" && ! -L "$destination" ]] || return 1
  python3 "$ROOT/ios/device-test/validate-metal-capture-artifact.py" \
    --artifact "$destination" --summary "$summary" || return 1
  values="$(python3 - "$summary" <<'PY'
import pathlib
import re
import sys

values = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.count("=") != 1:
        raise SystemExit("invalid capture summary line")
    key, value = line.split("=", 1)
    if key in values:
        raise SystemExit("duplicate capture summary key")
    values[key] = value
expected = {
    "capture_name",
    "capture_kind",
    "capture_bytes",
    "capture_manifest_sha256",
}
if set(values) != expected:
    raise SystemExit("capture summary key set is not exact")
if values["capture_name"] != "RendererIOS-pm-clear-v1.gputrace":
    raise SystemExit("capture summary name mismatch")
if values["capture_kind"] not in ("file", "directory"):
    raise SystemExit("capture summary kind mismatch")
if re.fullmatch(r"[1-9][0-9]*", values["capture_bytes"]) is None:
    raise SystemExit("capture summary byte count mismatch")
if re.fullmatch(r"[0-9a-f]{64}", values["capture_manifest_sha256"]) is None:
    raise SystemExit("capture summary digest mismatch")
print("\t".join((
    values["capture_kind"],
    values["capture_bytes"],
    values["capture_manifest_sha256"],
)))
PY
  )" || return 1
  IFS=$'\t' read -r CLEAR_ONLY_CAPTURE_KIND CLEAR_ONLY_CAPTURE_BYTES \
    CLEAR_ONLY_CAPTURE_MANIFEST_SHA256 <<<"$values"
  [[ "$CLEAR_ONLY_CAPTURE_KIND" == "$listed_kind" ]] || return 1
  [[ "$CLEAR_ONLY_CAPTURE_BYTES" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$CLEAR_ONLY_CAPTURE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
  CLEAR_ONLY_CAPTURE_STATUS="acquired"
}

capture_shading_prototype_tile_artifact() {
  local listing="$WORK/shading-prototype-tile-capture-listing.json"
  local destination="$WORK/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME"
  local summary="$WORK/shading-prototype-tile-capture-summary.txt"
  local listed_kind values

  ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)) || return 0
  if ((SHADING_PROTOTYPE_TILE_CAPTURE_ATTEMPTED != 0)); then
    [[ "$SHADING_PROTOTYPE_TILE_CAPTURE_STATUS" == acquired ]]
    return
  fi
  SHADING_PROTOTYPE_TILE_CAPTURE_ATTEMPTED=1
  SHADING_PROTOTYPE_TILE_CAPTURE_STATUS="failed"
  [[ -n "$DEVICE" && -n "$BUNDLE_ID" ]] || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1

  run_bounded_device_file_query --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$listing" >/dev/null || return 1
  listed_kind="$(python3 - "$listing" "$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" <<'PY'
import json
import sys

files = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("files")
if not isinstance(files, list):
    raise SystemExit("capture listing provider returned no files array")
matches = [entry for entry in files if entry.get("name") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one flat Tile capture artifact, found {len(matches)}")
resources = matches[0].get("resources", {})
if resources.get("isSymbolicLink") is not False:
    raise SystemExit("Tile capture listing is a symlink or has unknown link state")
is_directory = resources.get("isDirectory")
if is_directory is True:
    print("directory")
elif is_directory is False:
    print("file")
else:
    raise SystemExit("Tile capture listing has unknown file kind")
PY
  )" || return 1
  [[ "$listed_kind" == file || "$listed_kind" == directory ]] || return 1

  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "Documents/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" \
    --destination "$destination" >/dev/null || return 1
  [[ -e "$destination" && ! -L "$destination" ]] || return 1
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/ios/device-test/validate-shading-prototype-tile-self-test-log.py" \
      --capture-only --artifact "$destination" --summary "$summary" || return 1
  values="$(python3 - "$summary" "$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" <<'PY'
import pathlib
import re
import sys

values = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.count("=") != 1:
        raise SystemExit("invalid Tile capture summary line")
    key, value = line.split("=", 1)
    if key in values:
        raise SystemExit("duplicate Tile capture summary key")
    values[key] = value
expected = {
    "capture_name",
    "capture_kind",
    "capture_bytes",
    "capture_manifest_sha256",
}
if set(values) != expected:
    raise SystemExit("Tile capture summary key set is not exact")
if values["capture_name"] != sys.argv[2]:
    raise SystemExit("Tile capture summary name mismatch")
if values["capture_kind"] not in ("file", "directory"):
    raise SystemExit("Tile capture summary kind mismatch")
if re.fullmatch(r"[1-9][0-9]*", values["capture_bytes"]) is None:
    raise SystemExit("Tile capture summary byte count mismatch")
if re.fullmatch(r"[0-9a-f]{64}", values["capture_manifest_sha256"]) is None:
    raise SystemExit("Tile capture summary digest mismatch")
print("\t".join((
    values["capture_kind"],
    values["capture_bytes"],
    values["capture_manifest_sha256"],
)))
PY
  )" || return 1
  IFS=$'\t' read -r SHADING_PROTOTYPE_TILE_CAPTURE_KIND \
    SHADING_PROTOTYPE_TILE_CAPTURE_BYTES \
    SHADING_PROTOTYPE_TILE_CAPTURE_MANIFEST_SHA256 <<<"$values"
  [[ "$SHADING_PROTOTYPE_TILE_CAPTURE_KIND" == "$listed_kind" ]] || return 1
  [[ "$SHADING_PROTOTYPE_TILE_CAPTURE_BYTES" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$SHADING_PROTOTYPE_TILE_CAPTURE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    return 1
  SHADING_PROTOTYPE_TILE_CAPTURE_STATUS="acquired"
}

capture_shading_prototype_forward_artifact() {
  local listing="$WORK/shading-prototype-forward-capture-listing.json"
  local destination="$WORK/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME"
  local summary="$WORK/shading-prototype-forward-capture-summary.txt"
  local listed_kind values

  ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)) || return 0
  if ((SHADING_PROTOTYPE_FORWARD_CAPTURE_ATTEMPTED != 0)); then
    [[ "$SHADING_PROTOTYPE_FORWARD_CAPTURE_STATUS" == acquired ]]
    return
  fi
  SHADING_PROTOTYPE_FORWARD_CAPTURE_ATTEMPTED=1
  SHADING_PROTOTYPE_FORWARD_CAPTURE_STATUS="failed"
  [[ -n "$DEVICE" && -n "$BUNDLE_ID" ]] || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1

  run_bounded_device_file_query --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$listing" >/dev/null || return 1
  listed_kind="$(python3 - "$listing" "$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" <<'PY'
import json
import sys

files = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("files")
if not isinstance(files, list):
    raise SystemExit("capture listing provider returned no files array")
matches = [entry for entry in files if entry.get("name") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one flat Forward capture artifact, found {len(matches)}")
resources = matches[0].get("resources", {})
if resources.get("isSymbolicLink") is not False:
    raise SystemExit("Forward capture listing is a symlink or has unknown link state")
is_directory = resources.get("isDirectory")
if is_directory is True:
    print("directory")
elif is_directory is False:
    print("file")
else:
    raise SystemExit("Forward capture listing has unknown file kind")
PY
  )" || return 1
  [[ "$listed_kind" == file || "$listed_kind" == directory ]] || return 1

  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "Documents/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" \
    --destination "$destination" >/dev/null || return 1
  [[ -e "$destination" && ! -L "$destination" ]] || return 1
  if [[ -d "$destination" ]]; then
    secure_private_evidence "$destination" || return 1
  else
    chmod 600 "$destination" || return 1
  fi
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/ios/device-test/validate-shading-prototype-forward-self-test-log.py" \
      --capture-only --artifact "$destination" --summary "$summary" || return 1
  values="$(python3 - "$summary" "$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" <<'PY'
import pathlib
import re
import sys

values = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.count("=") != 1:
        raise SystemExit("invalid Forward capture summary line")
    key, value = line.split("=", 1)
    if key in values:
        raise SystemExit("duplicate Forward capture summary key")
    values[key] = value
expected = {
    "capture_name",
    "capture_kind",
    "capture_bytes",
    "capture_manifest_sha256",
}
if set(values) != expected:
    raise SystemExit("Forward capture summary key set is not exact")
if values["capture_name"] != sys.argv[2]:
    raise SystemExit("Forward capture summary name mismatch")
if values["capture_kind"] not in ("file", "directory"):
    raise SystemExit("Forward capture summary kind mismatch")
if re.fullmatch(r"[1-9][0-9]*", values["capture_bytes"]) is None:
    raise SystemExit("Forward capture summary byte count mismatch")
if re.fullmatch(r"[0-9a-f]{64}", values["capture_manifest_sha256"]) is None:
    raise SystemExit("Forward capture summary digest mismatch")
print("\t".join((
    values["capture_kind"],
    values["capture_bytes"],
    values["capture_manifest_sha256"],
)))
PY
  )" || return 1
  IFS=$'\t' read -r SHADING_PROTOTYPE_FORWARD_CAPTURE_KIND \
    SHADING_PROTOTYPE_FORWARD_CAPTURE_BYTES \
    SHADING_PROTOTYPE_FORWARD_CAPTURE_MANIFEST_SHA256 <<<"$values"
  [[ "$SHADING_PROTOTYPE_FORWARD_CAPTURE_KIND" == "$listed_kind" ]] || return 1
  [[ "$SHADING_PROTOTYPE_FORWARD_CAPTURE_BYTES" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$SHADING_PROTOTYPE_FORWARD_CAPTURE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    return 1
  SHADING_PROTOTYPE_FORWARD_CAPTURE_STATUS="acquired"
}

capture_shading_prototype_forward_saves() {
  local phase="$1"
  local listing="$WORK/shading-prototype-forward-saves-$phase.json"
  local names="$WORK/shading-prototype-forward-saves-$phase.names"
  local manifest="$WORK/shading-prototype-forward-saves-$phase.sha256"
  local name destination bytes sha

  [[ "$phase" == before || "$phase" == after ]] || return 1
  ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)) || return 0
  [[ -n "$DEVICE" && -n "$BUNDLE_ID" ]] || return 1
  run_bounded_device_file_query --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$listing" >/dev/null || return 1
  python3 - "$listing" "$names" <<'PY' || return 1
import json
import pathlib
import re
import sys

files = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("files")
if not isinstance(files, list):
    raise SystemExit("save listing provider returned no files array")
names = []
for entry in files:
    name = entry.get("name")
    if not isinstance(name, str) or re.fullmatch(r"save_slot_[0-9]+\.sav", name) is None:
        continue
    resources = entry.get("resources", {})
    if (
        resources.get("isDirectory") is not False
        or resources.get("isSymbolicLink") is not False
    ):
        raise SystemExit(f"save is not a regular non-symlink file: {name}")
    names.append(name)
required = {
    "save_slot_1.sav",
    "save_slot_2.sav",
    "save_slot_3.sav",
    "save_slot_4.sav",
    "save_slot_20.sav",
}
if set(names) != required or len(names) != len(required):
    raise SystemExit(
        "Forward save set must be exactly save slots 1,2,3,4,20; found "
        + repr(sorted(names))
    )
names.sort(key=lambda value: int(value.removeprefix("save_slot_").removesuffix(".sav")))
pathlib.Path(sys.argv[2]).write_text("".join(name + "\n" for name in names))
PY
  : >"$manifest"
  while IFS= read -r name; do
    [[ "$name" =~ ^save_slot_[0-9]+\.sav$ ]] || return 1
    destination="$WORK/shading-prototype-forward-$phase-$name"
    [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
    xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
      --source "Documents/$name" --destination "$destination" \
      >/dev/null || return 1
    [[ -s "$destination" && ! -L "$destination" ]] || return 1
    chmod 600 "$destination" || return 1
    bytes="$(wc -c <"$destination" | tr -d '[:space:]')" || return 1
    sha="$(shasum -a 256 "$destination" | awk '{print $1}')" || return 1
    [[ "$bytes" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'bytes=%s sha256=%s name=%s\n' "$bytes" "$sha" "$name" \
      >>"$manifest"
  done <"$names"
  [[ -s "$manifest" ]] || return 1
  chmod 600 "$listing" "$names" "$manifest" \
    "$WORK"/shading-prototype-forward-"$phase"-save_slot_*.sav || return 1
  sync_shading_prototype_forward_recovery "$phase" || return 1
  if [[ "$phase" == before ]]; then
    SHADING_PROTOTYPE_FORWARD_SAVES_BEFORE_CAPTURED=1
  else
    SHADING_PROTOTYPE_FORWARD_SAVES_AFTER_CAPTURED=1
  fi
}

verify_shading_prototype_forward_save_integrity() {
  ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)) || return 0
  ((SHADING_PROTOTYPE_FORWARD_SAVES_BEFORE_CAPTURED == 1)) || return 1
  capture_shading_prototype_forward_saves after || return 1
  cmp -s "$WORK/shading-prototype-forward-saves-before.names" \
    "$WORK/shading-prototype-forward-saves-after.names" || return 1
  cmp -s "$WORK/shading-prototype-forward-saves-before.sha256" \
    "$WORK/shading-prototype-forward-saves-after.sha256" || return 1
  SHADING_PROTOTYPE_FORWARD_SAVES_MATCH=1
}

create_shading_prototype_forward_recovery_path() {
  local recovery_root timestamp

  ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)) || return 0
  [[ "$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH" == none ]] || return 0
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  recovery_root="$ROOT/build/private-device-recovery/shading-prototype-forward/$EXPECTED_BUILD"
  (umask 077 && mkdir -p "$recovery_root") || return 1
  SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH="$(
    mktemp -d "$recovery_root/$timestamp-$$.XXXXXX"
  )" || return 1
  [[ "$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH" == "$recovery_root"/* &&
     "$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH" != "$WORK"* ]] || return 1
  chmod 700 "$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH" || return 1
}

sync_shading_prototype_forward_recovery() {
  local phase="$1"
  local candidate destination

  [[ "$phase" == before || "$phase" == after ]] || return 1
  create_shading_prototype_forward_recovery_path || return 1
  [[ "$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH" != none &&
     -d "$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH" ]] || return 1
  for candidate in \
      "shading-prototype-forward-saves-$phase.json" \
      "shading-prototype-forward-saves-$phase.names" \
      "shading-prototype-forward-saves-$phase.sha256" \
      "shading-prototype-forward-$phase-save_slot_1.sav" \
      "shading-prototype-forward-$phase-save_slot_2.sav" \
      "shading-prototype-forward-$phase-save_slot_3.sav" \
      "shading-prototype-forward-$phase-save_slot_4.sav" \
      "shading-prototype-forward-$phase-save_slot_20.sav"; do
    [[ -f "$WORK/$candidate" && ! -L "$WORK/$candidate" ]] || return 1
    destination="$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH/$candidate"
    ditto "$WORK/$candidate" "$destination" || return 1
    chmod 600 "$destination" || return 1
  done
  chmod 700 "$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH" || return 1
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
  run_bounded_device_file_query --device "$DEVICE" \
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
  run_bounded_device_file_query --device "$DEVICE" \
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

write_clear_only_pass_self_test_result_fields() {
  ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)) || return 0
  echo "self_test_profile=clear-only-pass"
  echo "clear_only_pass_self_test_required=1"
  echo "clear_only_pass_self_test_validation=$CLEAR_ONLY_PASS_SELF_TEST_VALIDATION"
  echo "clear_only_pass_self_test_pid=$CLEAR_ONLY_PASS_SELF_TEST_PID"
  echo "clear_only_pass_self_test_pid_discovery_attempts=$CLEAR_ONLY_PASS_SELF_TEST_PID_DISCOVERY_ATTEMPTS"
  echo "clear_only_pass_self_test_process_survived=$CLEAR_ONLY_PASS_SELF_TEST_PROCESS_SURVIVED"
  echo "clear_only_capture_attempted=$CLEAR_ONLY_CAPTURE_ATTEMPTED"
  echo "clear_only_capture_status=$CLEAR_ONLY_CAPTURE_STATUS"
  echo "clear_only_capture_name=$CLEAR_ONLY_CAPTURE_NAME"
  echo "clear_only_capture_kind=$CLEAR_ONLY_CAPTURE_KIND"
  echo "clear_only_capture_bytes=$CLEAR_ONLY_CAPTURE_BYTES"
  echo "clear_only_capture_manifest_sha256=$CLEAR_ONLY_CAPTURE_MANIFEST_SHA256"
}

discover_clear_only_pass_self_test_pid() {
  local attempt output pids

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    output="$WORK/processes-clear-only-pass-window-start-attempt-$attempt.json"
    if pids="$(list_game_pids "$output")" && [[ "$pids" =~ ^[0-9]+$ ]]; then
      CLEAR_ONLY_PASS_SELF_TEST_PID="$pids"
      CLEAR_ONLY_PASS_SELF_TEST_PID_DISCOVERY_ATTEMPTS="$attempt"
      ditto "$output" "$WORK/processes-clear-only-pass-window-start.json" || return 1
      return 0
    fi
    ((attempt == 10)) || sleep 1
  done
  CLEAR_ONLY_PASS_SELF_TEST_PID_DISCOVERY_ATTEMPTS=10
  return 1
}

write_shading_prototype_tile_self_test_result_fields() {
  ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)) || return 0
  echo "self_test_profile=shading-prototype-tile"
  echo "shading_prototype_tile_self_test_required=1"
  echo "shading_prototype_tile_self_test_validation=$SHADING_PROTOTYPE_TILE_SELF_TEST_VALIDATION"
  echo "shading_prototype_tile_self_test_pid=$SHADING_PROTOTYPE_TILE_SELF_TEST_PID"
  echo "shading_prototype_tile_self_test_pid_discovery_attempts=$SHADING_PROTOTYPE_TILE_SELF_TEST_PID_DISCOVERY_ATTEMPTS"
  echo "shading_prototype_tile_self_test_process_survived=$SHADING_PROTOTYPE_TILE_SELF_TEST_PROCESS_SURVIVED"
  echo "shading_prototype_tile_capture_attempted=$SHADING_PROTOTYPE_TILE_CAPTURE_ATTEMPTED"
  echo "shading_prototype_tile_capture_status=$SHADING_PROTOTYPE_TILE_CAPTURE_STATUS"
  echo "shading_prototype_tile_capture_name=$SHADING_PROTOTYPE_TILE_CAPTURE_NAME"
  echo "shading_prototype_tile_capture_kind=$SHADING_PROTOTYPE_TILE_CAPTURE_KIND"
  echo "shading_prototype_tile_capture_bytes=$SHADING_PROTOTYPE_TILE_CAPTURE_BYTES"
  echo "shading_prototype_tile_capture_manifest_sha256=$SHADING_PROTOTYPE_TILE_CAPTURE_MANIFEST_SHA256"
}

discover_shading_prototype_tile_self_test_pid() {
  local attempt output pids

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    output="$WORK/processes-shading-prototype-tile-window-start-attempt-$attempt.json"
    if pids="$(list_game_pids "$output")" && [[ "$pids" =~ ^[0-9]+$ ]]; then
      SHADING_PROTOTYPE_TILE_SELF_TEST_PID="$pids"
      SHADING_PROTOTYPE_TILE_SELF_TEST_PID_DISCOVERY_ATTEMPTS="$attempt"
      ditto "$output" \
        "$WORK/processes-shading-prototype-tile-window-start.json" || return 1
      return 0
    fi
    ((attempt == 10)) || sleep 1
  done
  SHADING_PROTOTYPE_TILE_SELF_TEST_PID_DISCOVERY_ATTEMPTS=10
  return 1
}

write_shading_prototype_forward_self_test_result_fields() {
  ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)) || return 0
  echo "self_test_profile=shading-prototype-forward"
  echo "shading_prototype_forward_self_test_required=1"
  echo "shading_prototype_forward_self_test_nonce=$SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE"
  echo "shading_prototype_forward_self_test_validation=$SHADING_PROTOTYPE_FORWARD_SELF_TEST_VALIDATION"
  echo "shading_prototype_forward_terminal_kind=$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND"
  echo "shading_prototype_forward_failure_reason=$SHADING_PROTOTYPE_FORWARD_FAILURE_REASON"
  echo "shading_prototype_forward_self_test_pid=$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID"
  echo "shading_prototype_forward_self_test_pid_discovery_attempts=$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID_DISCOVERY_ATTEMPTS"
  echo "shading_prototype_forward_self_test_process_survived=$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PROCESS_SURVIVED"
  echo "shading_prototype_forward_capture_attempted=$SHADING_PROTOTYPE_FORWARD_CAPTURE_ATTEMPTED"
  echo "shading_prototype_forward_capture_status=$SHADING_PROTOTYPE_FORWARD_CAPTURE_STATUS"
  echo "shading_prototype_forward_capture_name=$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME"
  echo "shading_prototype_forward_capture_kind=$SHADING_PROTOTYPE_FORWARD_CAPTURE_KIND"
  echo "shading_prototype_forward_capture_bytes=$SHADING_PROTOTYPE_FORWARD_CAPTURE_BYTES"
  echo "shading_prototype_forward_capture_manifest_sha256=$SHADING_PROTOTYPE_FORWARD_CAPTURE_MANIFEST_SHA256"
  echo "shading_prototype_forward_saves_before_captured=$SHADING_PROTOTYPE_FORWARD_SAVES_BEFORE_CAPTURED"
  echo "shading_prototype_forward_saves_after_captured=$SHADING_PROTOTYPE_FORWARD_SAVES_AFTER_CAPTURED"
  echo "shading_prototype_forward_saves_match=$SHADING_PROTOTYPE_FORWARD_SAVES_MATCH"
  echo "shading_prototype_forward_same_pid_stable_seconds=$SHADING_PROTOTYPE_FORWARD_SAME_PID_STABLE_SECONDS"
  echo "shading_prototype_forward_recovery_path=$SHADING_PROTOTYPE_FORWARD_RECOVERY_PATH"
  echo "game_container_postruntime_validation=$GAME_CONTAINER_POSTRUNTIME_VALIDATION"
}

discover_shading_prototype_forward_self_test_pid() {
  local attempt output pids

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    output="$WORK/processes-shading-prototype-forward-window-start-attempt-$attempt.json"
    if pids="$(list_game_pids "$output")" && [[ "$pids" =~ ^[0-9]+$ ]]; then
      SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID="$pids"
      SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID_DISCOVERY_ATTEMPTS="$attempt"
      ditto "$output" \
        "$WORK/processes-shading-prototype-forward-window-start.json" || return 1
      return 0
    fi
    ((attempt == 10)) || sleep 1
  done
  SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID_DISCOVERY_ATTEMPTS=10
  return 1
}

wait_for_shading_prototype_forward_terminal() {
  local attempt terminal_values
  local log="$WORK/log-shading-prototype-forward-terminal-check.txt"

  for ((attempt=1; attempt<=DURATION; attempt++)); do
    rm -f "$log"
    if xcrun devicectl device copy from --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
        --source Documents/log.txt --destination "$log" >/dev/null 2>&1 &&
       terminal_values="$(python3 - "$log" \
         "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE" <<'PY'
import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
nonce = re.escape(sys.argv[2])
prefix = "RendererIOS shading prototype forward self-test:"
matches = [
    line for line in log.splitlines()
    if re.match(
        rf"^{re.escape(prefix)} (?:PASS|UNSUPPORTED|FAIL) "
        rf"case=forward-prototype-v1 nonce={nonce}(?: |$)",
        line,
    )
]
if len(matches) != 1:
    raise SystemExit(1)
line = matches[0]
if re.fullmatch(
    rf"{re.escape(prefix)} PASS case=forward-prototype-v1 nonce={nonce} "
    r"wait-idle=0 output=1/0/1 light-list=1/0/1 capture=1/0/1",
    line,
):
    print("pass\tnone")
elif re.fullmatch(
    rf"{re.escape(prefix)} UNSUPPORTED case=forward-prototype-v1 nonce={nonce} "
    r"reason=apple4-required side-effects=0",
    line,
):
    print("unsupported\tapple4-required")
else:
    failed = re.fullmatch(
        rf"{re.escape(prefix)} FAIL case=forward-prototype-v1 nonce={nonce} "
        r"reason=([a-z0-9-]+)",
        line,
    )
    if failed is None:
        raise SystemExit(1)
    print("fail\t" + failed.group(1))
PY
       )"; then
      IFS=$'\t' read -r SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND \
        SHADING_PROTOTYPE_FORWARD_FAILURE_REASON <<<"$terminal_values"
      [[ "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == pass ||
         "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == unsupported ||
         "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == fail ]] || return 1
      printf 'terminal_marker_wait_attempts=%d\n' "$attempt" \
        >"$WORK/shading-prototype-forward-terminal-wait.txt"
      printf 'terminal_kind=%s\nterminal_reason=%s\n' \
        "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" \
        "$SHADING_PROTOTYPE_FORWARD_FAILURE_REASON" \
        >>"$WORK/shading-prototype-forward-terminal-wait.txt"
      return 0
    fi
    ((attempt == DURATION)) || sleep 1
  done
  return 1
}

verify_shading_prototype_forward_same_pid_stability() {
  local second output pids

  ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)) || return 0
  [[ "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID" =~ ^[0-9]+$ ]] || return 1
  for second in 0 1 2 3 4 5 6 7 8 9 10; do
    output="$WORK/processes-shading-prototype-forward-stability-$second.json"
    pids="$(list_game_pids "$output")" || return 1
    [[ "$pids" == "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID" ]] || return 1
    ((second == 10)) || sleep 1
  done
  SHADING_PROTOTYPE_FORWARD_SAME_PID_STABLE_SECONDS=10
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
  local candidate failure_dir failure_root timestamp

  [[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || return 0
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  if [[ ! "$EXPECTED_BUILD" =~ ^[0-9a-f]{40}(-local)?$ ]]; then
    failure_root="$ROOT/build/device-fault/$EXPECTED_SHA/invalid-build"
    failure_dir="$failure_root/failure-$timestamp-$$"
  else
    failure_root="$(smoke_evidence_root \
      "$EXPECTED_SHA" "$EXPECTED_BUILD" "$EXPECTED_FAULT")" || return 1
    failure_dir="$(smoke_evidence_path failure "$timestamp" "$$" \
      "$EXPECTED_SHA" "$EXPECTED_BUILD" "$EXPECTED_FAULT")" || return 0
  fi
  create_private_evidence_directory "$failure_dir" "$failure_root" || return 1
  publish_evidence_path "$failure_dir"
  for candidate in \
      launch.log cleanup.log \
      park-settings.log \
      device-facts-summary.txt \
      fault-log-summary.txt \
      resource-allocator-self-test-summary.txt \
      clear-only-pass-self-test-summary.txt \
      clear-only-capture-summary.txt clear-only-capture-listing.json \
      shading-prototype-tile-self-test-summary.txt \
      shading-prototype-tile-capture-summary.txt \
      shading-prototype-tile-capture-listing.json \
      shading-prototype-forward-self-test-summary.txt \
      shading-prototype-forward-capture-summary.txt \
      shading-prototype-forward-capture-listing.json \
      shading-prototype-forward-saves-before.json \
      shading-prototype-forward-saves-after.json \
      shading-prototype-forward-saves-before.names \
      shading-prototype-forward-saves-after.names \
      shading-prototype-forward-saves-before.sha256 \
      shading-prototype-forward-saves-after.sha256 \
      shading-prototype-forward-terminal-wait.txt \
      causal-contract.json log-native-alpha-test-causal-prelaunch.txt \
      stderr-native-alpha-test-causal-prelaunch.log \
      documents-preinstall.json scripts-preinstall.json system-preinstall.json \
      documents-postinstall.json scripts-postinstall.json system-postinstall.json \
      documents-postruntime.json scripts-postruntime.json system-postruntime.json \
      id3-protected-before.sha256 id3-protected-after.sha256 \
      id3-saves-before.json id3-saves-after.json save_slot_20.sav \
      processes-id3-window-start.json \
      processes-resource-allocator-window-start.json \
      processes-clear-only-pass-window-start.json \
      processes-shading-prototype-tile-window-start.json \
      processes-shading-prototype-forward-window-start.json \
      processes.json \
      log-id3-completion-check.txt \
      log.txt stderr.log crash.log crash-before.log \
      log-before-cleanup.txt stderr-before-cleanup.log crash-before-cleanup.log \
      log-after-cleanup.txt stderr-after-cleanup.log crash-after-cleanup.log; do
    [[ -f "$WORK/$candidate" ]] || continue
    copy_private_evidence_path "$WORK/$candidate" \
      "$failure_dir/$candidate" || return 1
  done
  if [[ -e "$WORK/$CLEAR_ONLY_CAPTURE_NAME" &&
        ! -L "$WORK/$CLEAR_ONLY_CAPTURE_NAME" ]]; then
    copy_private_evidence_path "$WORK/$CLEAR_ONLY_CAPTURE_NAME" \
      "$failure_dir/$CLEAR_ONLY_CAPTURE_NAME" || return 1
  fi
  if [[ -e "$WORK/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" &&
        ! -L "$WORK/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" ]]; then
    copy_private_evidence_path "$WORK/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" \
      "$failure_dir/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" || return 1
  fi
  if [[ -e "$WORK/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" &&
        ! -L "$WORK/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" ]]; then
    copy_private_evidence_path "$WORK/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" \
      "$failure_dir/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" || return 1
  fi
  for candidate in "$WORK"/processes-durable-zero-*.json \
      "$WORK"/processes-id3-window-start-attempt-*.json \
      "$WORK"/processes-resource-allocator-window-start-attempt-*.json \
      "$WORK"/processes-clear-only-pass-window-start-attempt-*.json \
      "$WORK"/processes-shading-prototype-tile-window-start-attempt-*.json \
      "$WORK"/processes-shading-prototype-forward-window-start-attempt-*.json \
      "$WORK"/processes-shading-prototype-forward-stability-*.json \
      "$WORK"/shading-prototype-forward-before-save_slot_*.sav \
      "$WORK"/shading-prototype-forward-after-save_slot_*.sav \
      "$WORK"/durable-zero-*.json \
      "$WORK"/crash-listing-*.json; do
    [[ -f "$candidate" ]] || continue
    copy_private_evidence_path "$candidate" \
      "$failure_dir/$(basename "$candidate")" || return 1
  done
  {
    echo "result=FAIL"
    echo "source_sha=$EXPECTED_SHA"
    echo "expected_build=$EXPECTED_BUILD"
    echo "signed_executable_sha256=$APP_EXECUTABLE_SHA256"
    echo "expected_fault=$EXPECTED_FAULT"
    echo "device_facts_reference_a17_required=$REQUIRE_DEVICE_FACTS_REFERENCE_A17"
    echo "fault_log_validation=$FAULT_LOG_VALIDATION"
    echo "process_survived_fault_window=$PROCESS_SURVIVED_FAULT_WINDOW"
    write_resource_allocator_self_test_result_fields
    write_clear_only_pass_self_test_result_fields
    write_shading_prototype_tile_self_test_result_fields
    write_shading_prototype_forward_self_test_result_fields
    echo "scenario=$SCENARIO"
    echo "save_slot=$SCENARIO_SAVE_SLOT"
    echo "original_exit_status=$original_status"
    echo "cleanup_status=$cleanup_status"
    echo "pre_crash_sha256=$PRE_CRASH_SHA"
    echo "post_crash_sha256=$POST_CRASH_SHA"
    write_id3_result_fields
    write_durable_result_fields
    [[ ! -f "$WORK/device-facts-summary.txt" ]] ||
      cat "$WORK/device-facts-summary.txt"
    [[ ! -f "$WORK/fault-log-summary.txt" ]] ||
      cat "$WORK/fault-log-summary.txt"
    [[ ! -f "$WORK/resource-allocator-self-test-summary.txt" ]] ||
      cat "$WORK/resource-allocator-self-test-summary.txt"
    [[ ! -f "$WORK/clear-only-pass-self-test-summary.txt" ]] ||
      cat "$WORK/clear-only-pass-self-test-summary.txt"
    [[ ! -f "$WORK/shading-prototype-tile-self-test-summary.txt" ]] ||
      cat "$WORK/shading-prototype-tile-self-test-summary.txt"
    [[ ! -f "$WORK/shading-prototype-forward-self-test-summary.txt" ]] ||
      cat "$WORK/shading-prototype-forward-self-test-summary.txt"
  } >"$failure_dir/result.txt"
  chmod 600 "$failure_dir/result.txt" || return 1
  secure_private_evidence "$failure_dir" || return 1
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
    if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0 &&
         CLEAR_ONLY_CAPTURE_ATTEMPTED == 0)); then
      if ! capture_clear_only_capture_artifact; then
        echo "phase=trap-cleanup clear-only-capture=failed" >>"$WORK/cleanup.log"
        cleanup_status=1
      fi
    fi
    if ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0 &&
         SHADING_PROTOTYPE_TILE_CAPTURE_ATTEMPTED == 0)); then
      if ! capture_shading_prototype_tile_artifact; then
        echo "phase=trap-cleanup shading-prototype-tile-capture=failed" \
          >>"$WORK/cleanup.log"
        cleanup_status=1
      fi
    fi
    if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0 &&
         SHADING_PROTOTYPE_FORWARD_CAPTURE_ATTEMPTED == 0)) &&
       [[ "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == pass ]]; then
      if ! capture_shading_prototype_forward_artifact; then
        echo "phase=trap-cleanup shading-prototype-forward-capture=failed" \
          >>"$WORK/cleanup.log"
        cleanup_status=1
      fi
    fi
    if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0 &&
         SHADING_PROTOTYPE_FORWARD_SAVES_BEFORE_CAPTURED == 1 &&
         SHADING_PROTOTYPE_FORWARD_SAVES_AFTER_CAPTURED == 0)); then
      if ! verify_shading_prototype_forward_save_integrity; then
        echo "phase=trap-cleanup shading-prototype-forward-saves=changed-or-unavailable" \
          >>"$WORK/cleanup.log"
        cleanup_status=1
      fi
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
      if [[ "$GAME_CONTAINER_POSTRUNTIME_VALIDATION" != passed ]]; then
        if verify_game_container_resources postruntime; then
          GAME_CONTAINER_POSTRUNTIME_VALIDATION="passed"
          echo "phase=trap-cleanup postruntime-resources=passed" \
            >>"$WORK/cleanup.log"
        else
          GAME_CONTAINER_POSTRUNTIME_VALIDATION="failed"
          echo "phase=trap-cleanup postruntime-resources=failed" \
            >>"$WORK/cleanup.log"
          cleanup_status=1
        fi
      fi
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
  if [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
    if finalize_native_alpha_test_causal_cleanup "$status" "$cleanup_status"; then
      cleanup_status="$CAUSAL_FINALIZER_CLEANUP_STATUS"
    else
      cleanup_status=1
      CAUSAL_FINALIZER_CLEANUP_STATUS=1
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
      echo "signed_executable_sha256=$APP_EXECUTABLE_SHA256"
      echo "expected_fault=$EXPECTED_FAULT"
      echo "device_facts_reference_a17_required=$REQUIRE_DEVICE_FACTS_REFERENCE_A17"
      echo "process_survived_fault_window=$PROCESS_SURVIVED_FAULT_WINDOW"
      write_resource_allocator_self_test_result_fields
      write_clear_only_pass_self_test_result_fields
      write_shading_prototype_tile_self_test_result_fields
      write_shading_prototype_forward_self_test_result_fields
      echo "failure_reason=exit-cleanup-invalidated-provisional-pass"
      echo "cleanup_status=$cleanup_status"
      echo "pre_crash_sha256=$PRE_CRASH_SHA"
      echo "post_crash_sha256=$POST_CRASH_SHA"
      write_id3_result_fields
      write_durable_result_fields
      [[ ! -f "$WORK/device-facts-summary.txt" ]] ||
        cat "$WORK/device-facts-summary.txt"
      [[ ! -f "$WORK/fault-log-summary.txt" ]] ||
        cat "$WORK/fault-log-summary.txt"
      [[ ! -f "$WORK/resource-allocator-self-test-summary.txt" ]] ||
        cat "$WORK/resource-allocator-self-test-summary.txt"
      [[ ! -f "$WORK/clear-only-pass-self-test-summary.txt" ]] ||
        cat "$WORK/clear-only-pass-self-test-summary.txt"
      [[ ! -f "$WORK/shading-prototype-tile-self-test-summary.txt" ]] ||
        cat "$WORK/shading-prototype-tile-self-test-summary.txt"
      [[ ! -f "$WORK/shading-prototype-forward-self-test-summary.txt" ]] ||
        cat "$WORK/shading-prototype-forward-self-test-summary.txt"
    } >"$PASS_EVIDENCE_DIR/result.txt"
    echo "FAIL: final cleanup invalidated provisional PASS: $PASS_EVIDENCE_DIR" >&2
  fi
  if ((status == 0 && cleanup_status != 0)); then
    final_status=1
  fi
  if ((status == 0 && cleanup_status == 0)) && [[ -n "$PASS_EVIDENCE_DIR" ]]; then
    if [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
      echo "PASS — native alpha-test causal ARMED→ENCODED contract proven; app stopped"
    elif ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
      echo "PASS — shading prototype Forward execution/readback/capture acquired; app stopped"
    elif ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)); then
      echo "PASS — shading prototype Tile execution and capture acquired; app stopped"
    elif ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then
      echo "PASS — clear-only capture acquired for later GPU semantic inspection; app stopped"
    elif [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
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
[[ -z "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ||
   "$EXPECTED_BUILD" == "$EXPECTED_SHA" ]] ||
  fail "native alpha-test causal mode requires an exact-SHA build"
strings "$APP_INPUT/$APP_EXECUTABLE" >"$WORK/app-strings.txt"
grep -Fxq "$EXPECTED_BUILD" "$WORK/app-strings.txt" ||
  fail "app binary does not contain exact expected RendererIOS build"
CAUSAL_BINARY_SHA256="$(
  shasum -a 256 "$APP_INPUT/$APP_EXECUTABLE" | awk '{print $1}'
)"
CAUSAL_METALLIB_SHA256="$(
  shasum -a 256 "$APP_INPUT/RendererIOS.metallib" | awk '{print $1}'
)"
[[ "$CAUSAL_BINARY_SHA256" =~ ^[0-9a-f]{64}$ &&
   "$CAUSAL_METALLIB_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "could not fingerprint the unsigned causal input artifacts"
if [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
  validate_native_alpha_test_causal_binary_profile \
      "$WORK/app-strings.txt" "$EXPECTED_BUILD" ||
    fail "app binary native alpha-test causal profile does not match the request"
  NATIVE_ALPHA_TEST_CAUSAL_NONCE="$(
    generate_native_alpha_test_causal_nonce
  )" || fail "could not generate native alpha-test causal nonce"
  [[ "$NATIVE_ALPHA_TEST_CAUSAL_NONCE" =~ ^[0-9a-f]{32}$ ]] ||
    fail "generated native alpha-test causal nonce is invalid"
fi
validate_resource_allocator_binary_profile "$WORK/app-strings.txt" ||
  fail "app binary resource allocator self-test profile does not match the request"
validate_clear_only_pass_binary_profile "$WORK/app-strings.txt" ||
  fail "app binary clear-only pass self-test profile does not match the request"
validate_shading_prototype_tile_binary_profile "$WORK/app-strings.txt" ||
  fail "app binary shading prototype Tile self-test profile does not match the request"
validate_shading_prototype_forward_binary_profile "$WORK/app-strings.txt" ||
  fail "app binary shading prototype Forward self-test profile does not match the request"
if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0 ||
     REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0 ||
     REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
      "$APP_INPUT/Info.plist" 2>/dev/null || true)" == true ]] ||
    fail "capture self-test app does not enable programmatic Metal capture"
else
  if /usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
      "$APP_INPUT/Info.plist" >/dev/null 2>&1; then
    fail "unrequested profile enables programmatic Metal capture"
  fi
fi
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
BUNDLE_ID="$(select_bundle_id_from_apps "$WORK/apps.json" "$BUNDLE_ID")" ||
  fail "bundle id must identify the exact existing non-xctrunner OpenGothic container"

TEAM_ID="${OPENGOTHIC_IOS_TEAM_ID:-${BUNDLE_ID##*.}}"
[[ "$BUNDLE_ID" == "$BASE_BUNDLE_ID.$TEAM_ID" ]] ||
  fail "bundle id must preserve the existing team-id suffix"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "could not derive a valid team id"

echo "== stopping any previous $BUNDLE_ID process before preflight =="
stop_running_app 1 || fail "preflight application cleanup failed"
park_settings_foreground || fail "could not park Settings after preflight cleanup"

verify_game_container_resources preinstall ||
  fail "game Data/_work/system or Gothic.dat/Gothic.ini preflight failed before install"

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

APP_EXECUTABLE_SHA256="$(
  shasum -a 256 "$APP/$APP_EXECUTABLE" | awk '{print $1}'
)"
[[ "$APP_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "could not fingerprint the signed app executable"
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
if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
  capture_shading_prototype_forward_saves before ||
    fail "could not fingerprint pre-run saves for Forward self-test"
fi

echo "== installing $BUNDLE_ID =="
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
verify_game_container_resources postinstall ||
  fail "install changed game Data/_work/system or Gothic.dat/Gothic.ini"

LAUNCH_ARGS=(-nomenu)
if ((NEW_GAME == 0)); then
  LAUNCH_ARGS+=(-save "$SAVE_SLOT")
fi
if [[ -n "$PIPELINE_ARCHIVE_TEST_MODE" ]]; then
  LAUNCH_ARGS+=(
    "-renderer-ios-pipeline-archive-$PIPELINE_ARCHIVE_TEST_MODE"
  )
fi
if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
  SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE="$(
    generate_shading_prototype_forward_nonce
  )" || fail "could not generate shading prototype Forward nonce"
  [[ "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE" =~ ^[0-9a-f]{32}$ ]] ||
    fail "generated shading prototype Forward nonce is invalid"
  LAUNCH_ARGS+=(
    "${SHADING_PROTOTYPE_FORWARD_NONCE_ARGUMENT}${SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE}"
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
if [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
  LAUNCH_ARGS+=(
    "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}${NATIVE_ALPHA_TEST_CAUSAL_MODE}"
    "${NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT}${NATIVE_ALPHA_TEST_CAUSAL_NONCE}"
    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"
  )
  pull_runtime_logs native-alpha-test-causal-prelaunch
  [[ -f "$WORK/log-native-alpha-test-causal-prelaunch.txt" ]] ||
    : >"$WORK/log-native-alpha-test-causal-prelaunch.txt"
  [[ -f "$WORK/stderr-native-alpha-test-causal-prelaunch.log" ]] ||
    : >"$WORK/stderr-native-alpha-test-causal-prelaunch.log"
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
if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then
  discover_clear_only_pass_self_test_pid ||
    fail "clear-only pass self-test did not establish exactly one bounded process within 10 seconds"
fi
if ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)); then
  discover_shading_prototype_tile_self_test_pid ||
    fail "shading prototype Tile self-test did not establish exactly one bounded process within 10 seconds"
fi
if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
  discover_shading_prototype_forward_self_test_pid ||
    fail "shading prototype Forward self-test did not establish exactly one bounded process within 10 seconds"
  wait_for_shading_prototype_forward_terminal ||
    fail "shading prototype Forward self-test produced no nonce-bound terminal marker"
  if [[ "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == pass ]]; then
    verify_shading_prototype_forward_same_pid_stability ||
      fail "shading prototype Forward process did not remain the exact same PID for 10 seconds after terminal"
  fi
else
  sleep "$DURATION"
fi
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ]]; then
  wait_for_id3_completion ||
    fail "ID3 nonce-scoped placeholder save did not complete after the base window"
  sleep 10
  ID3_POST_COMPLETION_STABLE_SECONDS=10
fi

run_bounded_command "$DEVICECTL_PROCESS_QUERY_TIMEOUT_SECONDS" \
  xcrun devicectl device info processes --device "$DEVICE" \
  --json-output "$WORK/processes.json" >/dev/null 2>>"$WORK/cleanup.log" ||
  fail "could not query processes after launch"
python3 - "$WORK/processes.json" "$APP_EXECUTABLE" "$EXPECTED_FAULT" \
    "$ID3_FAULT_WINDOW_PID" "$REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST" \
    "$RESOURCE_ALLOCATOR_SELF_TEST_PID" \
    "$REQUIRE_CLEAR_ONLY_PASS_SELF_TEST" \
    "$CLEAR_ONLY_PASS_SELF_TEST_PID" \
    "$REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST_PID" \
    "$REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_PID" <<'PY' ||
import json, pathlib, sys
processes = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
expected = sys.argv[2]
expected_fault = sys.argv[3]
expected_id3_pid = sys.argv[4]
require_resource_allocator_self_test = sys.argv[5] == "1"
expected_resource_allocator_pid = sys.argv[6]
require_clear_only_pass_self_test = sys.argv[7] == "1"
expected_clear_only_pass_pid = sys.argv[8]
require_shading_prototype_tile_self_test = sys.argv[9] == "1"
expected_shading_prototype_tile_pid = sys.argv[10]
require_shading_prototype_forward_self_test = sys.argv[11] == "1"
expected_shading_prototype_forward_pid = sys.argv[12]
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
if require_clear_only_pass_self_test and (
    len(matches) != 1
    or str(matches[0].get("processIdentifier")) != expected_clear_only_pass_pid
):
    raise SystemExit(1)
if require_shading_prototype_tile_self_test and (
    len(matches) != 1
    or str(matches[0].get("processIdentifier"))
    != expected_shading_prototype_tile_pid
):
    raise SystemExit(1)
if require_shading_prototype_forward_self_test and (
    len(matches) != 1
    or str(matches[0].get("processIdentifier"))
    != expected_shading_prototype_forward_pid
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
if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then
  CLEAR_ONLY_PASS_SELF_TEST_PROCESS_SURVIVED=1
fi
if ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)); then
  SHADING_PROTOTYPE_TILE_SELF_TEST_PROCESS_SURVIVED=1
fi
if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
  SHADING_PROTOTYPE_FORWARD_SELF_TEST_PROCESS_SURVIVED=1
fi
if [[ "$EXPECTED_FAULT" == preview-fence-error-after-terminal ||
      "$EXPECTED_FAULT" == frame-fence-error-after-terminal ]]; then
  PROCESS_SURVIVED_FAULT_WINDOW=1
fi

echo "== stopping $BUNDLE_ID after smoke window =="
stop_running_app 1 || fail "application cleanup failed"
park_settings_foreground || fail "could not park Settings after smoke window"
RUNTIME_ARMED=0
if verify_game_container_resources postruntime; then
  GAME_CONTAINER_POSTRUNTIME_VALIDATION="passed"
else
  GAME_CONTAINER_POSTRUNTIME_VALIDATION="failed"
  fail "runtime changed game Data/_work/system or Gothic.dat/Gothic.ini"
fi

for name in log.txt stderr.log; do
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "Documents/$name" --destination "$WORK/$name" >/dev/null 2>&1 || true
done
if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then
  capture_clear_only_capture_artifact ||
    fail "clear-only pass programmatic Metal capture was not copied and validated"
fi
if ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)); then
  capture_shading_prototype_tile_artifact ||
    fail "shading prototype Tile Metal capture was not copied and validated"
fi
if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
  if [[ "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == pass ]]; then
    capture_shading_prototype_forward_artifact ||
      fail "shading prototype Forward Metal capture was not copied and validated"
  else
    SHADING_PROTOTYPE_FORWARD_CAPTURE_STATUS="not-acquired-at-stage"
  fi
  verify_shading_prototype_forward_save_integrity ||
    fail "shading prototype Forward run changed the save set or contents"
fi
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
if [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
  validate_native_alpha_test_causal_log \
      "$WORK/log.txt" \
      "$WORK/log-native-alpha-test-causal-prelaunch.txt" \
      "$WORK/stderr.log" \
      "$WORK/stderr-native-alpha-test-causal-prelaunch.log" ||
    fail "native alpha-test causal current-launch log validation failed"
else
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
device_facts_validator_args=(
  --log "$WORK/log.txt"
  --expected-build "$EXPECTED_BUILD"
  --summary "$WORK/device-facts-summary.txt"
)
if ((REQUIRE_DEVICE_FACTS_REFERENCE_A17 != 0)); then
  device_facts_validator_args+=(--require-reference-a17)
fi
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$ROOT/ios/device-test/validate-device-facts-log.py" \
  "${device_facts_validator_args[@]}" ||
  fail "runtime device-facts gate failed"
if ((REQUIRE_RESOURCE_ALLOCATOR_SELF_TEST == 0)); then
  python3 "$ROOT/ios/device-test/validate-resource-allocator-self-test-log.py" \
    --log "$WORK/log.txt" --expect-absent ||
    fail "unrequested resource allocator self-test marker appeared at runtime"
fi
if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST == 0)); then
  python3 "$ROOT/ios/device-test/validate-clear-only-pass-self-test-log.py" \
    --log "$WORK/log.txt" --expect-absent ||
    fail "unrequested clear-only pass self-test marker appeared at runtime"
fi
if ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST == 0)); then
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/ios/device-test/validate-shading-prototype-tile-self-test-log.py" \
      --log "$WORK/log.txt" --expect-absent ||
    fail "unrequested shading prototype Tile marker appeared at runtime"
fi
if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST == 0)); then
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/ios/device-test/validate-shading-prototype-forward-self-test-log.py" \
      --log "$WORK/log.txt" --expect-absent ||
    fail "unrequested shading prototype Forward marker appeared at runtime"
fi
rg -F 'RendererIOS diagnostics: ON' "$WORK/log.txt" >/dev/null ||
  fail "installed app is not a diagnostics-enabled RendererIOS build"
if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
  ((SHADING_PROTOTYPE_FORWARD_SELF_TEST_PROCESS_SURVIVED == 1)) ||
    fail "shading prototype Forward process did not survive its exact same-PID observation window"
  if [[ "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == fail ]]; then
    SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS=(
      --log "$WORK/log.txt"
      --expected-build "$EXPECTED_BUILD"
      --nonce "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE"
      --expect-failure-reason "$SHADING_PROTOTYPE_FORWARD_FAILURE_REASON"
    )
    [[ ! -f "$WORK/stderr.log" ]] ||
      SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
    SHADING_PROTOTYPE_FORWARD_SELF_TEST_VALIDATION="failed"
    PYTHONDONTWRITEBYTECODE=1 \
      python3 "$ROOT/ios/device-test/validate-shading-prototype-forward-self-test-log.py" \
        "${SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS[@]}" ||
      fail "shading prototype Forward FAIL terminal validation failed"
    SHADING_PROTOTYPE_FORWARD_SELF_TEST_VALIDATION="passed-failure-terminal"
    fail "shading prototype Forward core FAIL: $SHADING_PROTOTYPE_FORWARD_FAILURE_REASON"
  elif [[ "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == unsupported ]]; then
    SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS=(
      --log "$WORK/log.txt"
      --expected-build "$EXPECTED_BUILD"
      --nonce "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE"
      --expect-unsupported
    )
    [[ ! -f "$WORK/stderr.log" ]] ||
      SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
    SHADING_PROTOTYPE_FORWARD_SELF_TEST_VALIDATION="failed"
    PYTHONDONTWRITEBYTECODE=1 \
      python3 "$ROOT/ios/device-test/validate-shading-prototype-forward-self-test-log.py" \
        "${SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS[@]}" ||
      fail "shading prototype Forward UNSUPPORTED terminal validation failed"
    SHADING_PROTOTYPE_FORWARD_SELF_TEST_VALIDATION="passed-unsupported-terminal"
    fail "shading prototype Forward is unsupported on this device"
  fi
  [[ "$SHADING_PROTOTYPE_FORWARD_TERMINAL_KIND" == pass ]] ||
    fail "shading prototype Forward terminal kind is invalid"
  ((SHADING_PROTOTYPE_FORWARD_SAME_PID_STABLE_SECONDS >= 10)) ||
    fail "shading prototype Forward same-PID post-terminal stability was shorter than 10 seconds"
  [[ "$SHADING_PROTOTYPE_FORWARD_CAPTURE_STATUS" == acquired ]] ||
    fail "shading prototype Forward capture was not acquired"
  SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS=(
    --log "$WORK/log.txt"
    --expected-build "$EXPECTED_BUILD"
    --nonce "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE"
    --artifact "$WORK/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME"
    --summary "$WORK/shading-prototype-forward-self-test-summary.txt"
  )
  [[ ! -f "$WORK/stderr.log" ]] ||
    SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
  SHADING_PROTOTYPE_FORWARD_SELF_TEST_VALIDATION="failed"
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/ios/device-test/validate-shading-prototype-forward-self-test-log.py" \
      "${SHADING_PROTOTYPE_FORWARD_VALIDATOR_ARGS[@]}" ||
    fail "shading prototype Forward self-test log validation failed"
  python3 - "$WORK/shading-prototype-forward-self-test-summary.txt" \
      "$EXPECTED_BUILD" "$SHADING_PROTOTYPE_FORWARD_SELF_TEST_NONCE" \
      "$SHADING_PROTOTYPE_FORWARD_CAPTURE_KIND" \
      "$SHADING_PROTOTYPE_FORWARD_CAPTURE_BYTES" \
      "$SHADING_PROTOTYPE_FORWARD_CAPTURE_MANIFEST_SHA256" <<'PY' ||
import pathlib
import re
import sys

summary = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.count("=") != 1:
        raise SystemExit(f"invalid Forward summary line: {line!r}")
    key, value = line.split("=", 1)
    if key in summary:
        raise SystemExit(f"duplicate Forward summary key: {key}")
    summary[key] = value
expected = {
    "shading_prototype_forward_expected_build": sys.argv[2],
    "shading_prototype_forward_nonce": sys.argv[3],
    "shading_prototype_forward_armed_count": "1",
    "shading_prototype_forward_factory_ready_count": "1",
    "shading_prototype_forward_encoded_count": "1",
    "shading_prototype_forward_submitted_count": "1",
    "shading_prototype_forward_capture_acquired_count": "1",
    "shading_prototype_forward_terminal_count": "1",
    "shading_prototype_forward_readback_count": "1",
    "shading_prototype_forward_pass_count": "1",
    "shading_prototype_forward_unsupported_count": "0",
    "shading_prototype_forward_fail_count": "0",
    "shading_prototype_forward_wait_idle": "0",
    "shading_prototype_forward_readback_bytes": "256",
    "shading_prototype_forward_readback_words": "64",
    "shading_prototype_forward_readback_sha256":
        "d577b6dfa736657f93c3223b466c256c988d5eb5f02cc27ad47f92c1406f7dd2",
    "capture_name": "RendererIOS-forward-prototype-v1.gputrace",
    "capture_kind": sys.argv[4],
    "capture_bytes": sys.argv[5],
    "capture_manifest_sha256": sys.argv[6],
}
waits = summary.pop("shading_prototype_forward_wait_calls", "")
if re.fullmatch(r"(?:[1-9]|[1-9][0-9]|1[01][0-9]|120)", waits) is None:
    raise SystemExit("Forward summary wait count is not bounded 1..120")
if summary != expected:
    raise SystemExit("shading prototype Forward summary schema/value mismatch")
PY
    fail "shading prototype Forward self-test summary validation failed"
  SHADING_PROTOTYPE_FORWARD_SELF_TEST_VALIDATION="passed"
elif ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)); then
  ((SHADING_PROTOTYPE_TILE_SELF_TEST_PROCESS_SURVIVED == 1)) ||
    fail "shading prototype Tile process did not survive its exact same-PID observation window"
  [[ "$SHADING_PROTOTYPE_TILE_CAPTURE_STATUS" == acquired ]] ||
    fail "shading prototype Tile capture was not acquired"
  SHADING_PROTOTYPE_TILE_VALIDATOR_ARGS=(
    --log "$WORK/log.txt"
    --expected-build "$EXPECTED_BUILD"
    --artifact "$WORK/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME"
    --summary "$WORK/shading-prototype-tile-self-test-summary.txt"
  )
  [[ ! -f "$WORK/stderr.log" ]] ||
    SHADING_PROTOTYPE_TILE_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
  SHADING_PROTOTYPE_TILE_SELF_TEST_VALIDATION="failed"
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/ios/device-test/validate-shading-prototype-tile-self-test-log.py" \
      "${SHADING_PROTOTYPE_TILE_VALIDATOR_ARGS[@]}" ||
    fail "shading prototype Tile self-test log validation failed"
  python3 - "$WORK/shading-prototype-tile-self-test-summary.txt" \
      "$EXPECTED_BUILD" "$SHADING_PROTOTYPE_TILE_CAPTURE_KIND" \
      "$SHADING_PROTOTYPE_TILE_CAPTURE_BYTES" \
      "$SHADING_PROTOTYPE_TILE_CAPTURE_MANIFEST_SHA256" <<'PY' ||
import pathlib
import sys

summary = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.count("=") != 1:
        raise SystemExit(f"invalid shading prototype Tile summary line: {line!r}")
    key, value = line.split("=", 1)
    if key in summary:
        raise SystemExit(f"duplicate shading prototype Tile summary key: {key}")
    summary[key] = value
expected = {
    "shading_prototype_tile_expected_build": sys.argv[2],
    "shading_prototype_tile_armed_count": "1",
    "shading_prototype_tile_factory_ready_count": "1",
    "shading_prototype_tile_encoded_count": "1",
    "shading_prototype_tile_submitted_count": "1",
    "shading_prototype_tile_capture_acquired_count": "1",
    "shading_prototype_tile_pass_count": "1",
    "shading_prototype_tile_unsupported_count": "0",
    "shading_prototype_tile_fail_count": "0",
    "shading_prototype_tile_contract": "1",
    "shading_prototype_tile_metallib_abi": "7",
    "shading_prototype_tile_pipelines": "3",
    "shading_prototype_tile_forward": "0",
    "shading_prototype_tile_passes": "1",
    "shading_prototype_tile_encoders": "1",
    "shading_prototype_tile_draws": "2",
    "shading_prototype_tile_tile_dispatches": "1",
    "shading_prototype_tile_vertex_bytes": "168",
    "shading_prototype_tile_created": "1",
    "shading_prototype_tile_live": "0",
    "shading_prototype_tile_released": "1",
    "shading_prototype_tile_wait_idle": "0",
    "shading_prototype_tile_runtime_delta": "0",
    "shading_prototype_tile_builtin_delta": "0",
    "shading_prototype_tile_archive_delta": "0",
    "capture_name": "RendererIOS-tile-prototype-v1.gputrace",
    "capture_kind": sys.argv[3],
    "capture_bytes": sys.argv[4],
    "capture_manifest_sha256": sys.argv[5],
}
if summary != expected:
    missing = sorted(expected.keys() - summary.keys())
    extra = sorted(summary.keys() - expected.keys())
    wrong = sorted(
        key for key in expected.keys() & summary.keys()
        if summary[key] != expected[key]
    )
    raise SystemExit(
        f"shading prototype Tile summary mismatch: missing={missing} "
        f"extra={extra} wrong={wrong}"
    )
PY
    fail "shading prototype Tile self-test summary validation failed"
  SHADING_PROTOTYPE_TILE_SELF_TEST_VALIDATION="passed"
elif ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then
  ((CLEAR_ONLY_PASS_SELF_TEST_PROCESS_SURVIVED == 1)) ||
    fail "clear-only pass process did not survive its exact same-PID observation window"
  CLEAR_ONLY_PASS_VALIDATOR_ARGS=(
    --log "$WORK/log.txt"
    --expected-build "$EXPECTED_BUILD"
    --expected-capture-kind "$CLEAR_ONLY_CAPTURE_KIND"
    --expected-capture-bytes "$CLEAR_ONLY_CAPTURE_BYTES"
    --summary "$WORK/clear-only-pass-self-test-summary.txt"
  )
  [[ ! -f "$WORK/stderr.log" ]] ||
    CLEAR_ONLY_PASS_VALIDATOR_ARGS+=(--stderr "$WORK/stderr.log")
  CLEAR_ONLY_PASS_SELF_TEST_VALIDATION="failed"
  python3 "$ROOT/ios/device-test/validate-clear-only-pass-self-test-log.py" \
    "${CLEAR_ONLY_PASS_VALIDATOR_ARGS[@]}" ||
    fail "clear-only pass self-test log validation failed"
  python3 - "$WORK/clear-only-pass-self-test-summary.txt" \
      "$EXPECTED_BUILD" <<'PY' ||
import pathlib
import sys

summary = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.count("=") != 1:
        raise SystemExit(f"invalid clear-only pass summary line: {line!r}")
    key, value = line.split("=", 1)
    if key in summary:
        raise SystemExit(f"duplicate clear-only pass summary key: {key}")
    summary[key] = value
expected = {
    "clear_only_pass_self_test_expected_build": sys.argv[2],
    "clear_only_pass_self_test_armed_count": "1",
    "clear_only_pass_self_test_encoded_count": "1",
    "clear_only_pass_self_test_submitted_count": "1",
    "clear_only_pass_self_test_pass_count": "1",
    "clear_only_pass_self_test_fail_count": "0",
    "clear_only_pass_self_test_abi": "4",
    "clear_only_pass_self_test_resources": "3",
    "clear_only_pass_self_test_logical_passes": "3",
    "clear_only_pass_self_test_physical_passes": "2",
    "clear_only_pass_self_test_command_buffers": "1",
    "clear_only_pass_self_test_render_encoders": "2",
    "clear_only_pass_self_test_submits": "1",
    "clear_only_pass_self_test_private": "clear-store",
    "clear_only_pass_self_test_memoryless": "clear-dont-care",
    "clear_only_pass_self_test_draws": "0",
    "clear_only_pass_self_test_pipelines": "0",
    "clear_only_pass_self_test_drawable": "0",
    "clear_only_pass_self_test_present": "0",
    "clear_only_pass_self_test_terminal_completed": "1",
    "clear_only_pass_self_test_created": "2",
    "clear_only_pass_self_test_live": "0",
    "clear_only_pass_self_test_released": "2",
    "clear_only_pass_self_test_wait_idle": "0",
}
if summary != expected:
    missing = sorted(expected.keys() - summary.keys())
    extra = sorted(summary.keys() - expected.keys())
    wrong = sorted(
        key for key in expected.keys() & summary.keys()
        if summary[key] != expected[key]
    )
    raise SystemExit(
        f"clear-only pass summary mismatch: missing={missing} extra={extra} "
        f"wrong={wrong}"
    )
PY
    fail "clear-only pass self-test summary validation failed"
  CLEAR_ONLY_PASS_SELF_TEST_VALIDATION="passed"
else
rg -F 'RendererIOS shader library: source=offline-metallib resource=RendererIOS.metallib abi=7' \
  "$WORK/log.txt" >/dev/null || fail "offline metallib marker is missing"
rg -F 'RendererIOS builtin shader library: source=offline-metallib resource=RendererIOS.metallib abi=7 manifest=1 fail-closed=1' \
  "$WORK/log.txt" >/dev/null || fail "offline Builtin manifest marker is missing"
rg -F 'RendererIOS inventory shader manifest: resource=RendererIOS.metallib abi=7 manifest=1 exact-spirv=1 configured=1 fail-closed=1' \
  "$WORK/log.txt" >/dev/null || fail "offline inventory manifest marker is missing"
rg -F 'RendererIOS inventory shader pipeline: source=offline-metallib resource=RendererIOS.metallib abi=7 manifest=1 exact-spirv=1 functions-resolved=2 pipeline-wrapper-created=1' \
  "$WORK/log.txt" >/dev/null || fail "offline inventory pipeline marker is missing"
rg -F 'RendererIOS native Bink pipeline: source=offline-metallib resource=RendererIOS.metallib abi=7 color=rgba8 sample-count=1 pipeline-created=1' \
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
  python3 "$ROOT/ios/device-test/validate-native-textured-draw-log.py" --log "$WORK/log.txt" >/dev/null || fail "no native textured draw was proven"
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
OUT_ROOT="$(smoke_evidence_root \
  "$EXPECTED_SHA" "$EXPECTED_BUILD" "$EXPECTED_FAULT")" ||
  fail "could not resolve smoke evidence root"
OUT="$(smoke_evidence_path pass "$timestamp" "$$" \
  "$EXPECTED_SHA" "$EXPECTED_BUILD" "$EXPECTED_FAULT")" ||
  fail "could not resolve smoke evidence path"
if [[ -n "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
  PASS_EVIDENCE_FINAL_DIR="$OUT"
  OUT="$OUT_ROOT/.pending-pass-$timestamp-$$"
fi
create_private_evidence_directory "$OUT" "$OUT_ROOT" ||
  fail "could not create private PASS evidence directory"
PASS_EVIDENCE_DIR="$OUT"
if [[ -z "$NATIVE_ALPHA_TEST_CAUSAL_MODE" ]]; then
  publish_evidence_path "$OUT"
fi
copy_private_evidence_path "$WORK/log.txt" "$OUT/log.txt" ||
  fail "could not preserve private log evidence"
[[ ! -f "$WORK/stderr.log" ]] ||
  copy_private_evidence_path "$WORK/stderr.log" "$OUT/stderr.log" ||
  fail "could not preserve private stderr evidence"
copy_private_evidence_path "$WORK/device-selection.log" \
  "$OUT/device-selection.log" ||
  fail "could not preserve private device-selection evidence"
[[ ! -f "$WORK/cleanup.log" ]] ||
  copy_private_evidence_path "$WORK/cleanup.log" "$OUT/cleanup.log" ||
  fail "could not preserve private cleanup evidence"
[[ ! -f "$WORK/park-settings.log" ]] ||
  copy_private_evidence_path "$WORK/park-settings.log" \
    "$OUT/park-settings.log" ||
  fail "could not preserve private park-settings evidence"
[[ ! -f "$WORK/log-native-alpha-test-causal-prelaunch.txt" ]] ||
  copy_private_evidence_path "$WORK/log-native-alpha-test-causal-prelaunch.txt" \
    "$OUT/log-native-alpha-test-causal-prelaunch.txt" ||
  fail "could not preserve private causal pre-launch log evidence"
[[ ! -f "$WORK/stderr-native-alpha-test-causal-prelaunch.log" ]] ||
  copy_private_evidence_path \
    "$WORK/stderr-native-alpha-test-causal-prelaunch.log" \
    "$OUT/stderr-native-alpha-test-causal-prelaunch.log" ||
  fail "could not preserve private causal pre-launch stderr evidence"
[[ ! -f "$WORK/fault-log-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/fault-log-summary.txt" \
    "$OUT/fault-log-summary.txt" ||
  fail "could not preserve private fault summary"
[[ ! -f "$WORK/device-facts-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/device-facts-summary.txt" \
    "$OUT/device-facts-summary.txt" ||
  fail "could not preserve private device-facts summary"
[[ ! -f "$WORK/resource-allocator-self-test-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/resource-allocator-self-test-summary.txt" \
    "$OUT/resource-allocator-self-test-summary.txt" ||
  fail "could not preserve private allocator summary"
[[ ! -f "$WORK/clear-only-pass-self-test-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/clear-only-pass-self-test-summary.txt" \
    "$OUT/clear-only-pass-self-test-summary.txt" ||
  fail "could not preserve private clear-only summary"
[[ ! -f "$WORK/clear-only-capture-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/clear-only-capture-summary.txt" \
    "$OUT/clear-only-capture-summary.txt" ||
  fail "could not preserve private clear capture summary"
[[ ! -f "$WORK/clear-only-capture-listing.json" ]] ||
  copy_private_evidence_path "$WORK/clear-only-capture-listing.json" \
    "$OUT/clear-only-capture-listing.json" ||
  fail "could not preserve private clear capture listing"
[[ ! -f "$WORK/shading-prototype-tile-self-test-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/shading-prototype-tile-self-test-summary.txt" \
    "$OUT/shading-prototype-tile-self-test-summary.txt" ||
  fail "could not preserve private Tile summary"
[[ ! -f "$WORK/shading-prototype-tile-capture-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/shading-prototype-tile-capture-summary.txt" \
    "$OUT/shading-prototype-tile-capture-summary.txt" ||
  fail "could not preserve private Tile capture summary"
[[ ! -f "$WORK/shading-prototype-tile-capture-listing.json" ]] ||
  copy_private_evidence_path "$WORK/shading-prototype-tile-capture-listing.json" \
    "$OUT/shading-prototype-tile-capture-listing.json" ||
  fail "could not preserve private Tile capture listing"
[[ ! -f "$WORK/shading-prototype-forward-self-test-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/shading-prototype-forward-self-test-summary.txt" \
    "$OUT/shading-prototype-forward-self-test-summary.txt" ||
  fail "could not preserve private Forward summary"
[[ ! -f "$WORK/shading-prototype-forward-capture-summary.txt" ]] ||
  copy_private_evidence_path "$WORK/shading-prototype-forward-capture-summary.txt" \
    "$OUT/shading-prototype-forward-capture-summary.txt" ||
  fail "could not preserve private Forward capture summary"
[[ ! -f "$WORK/shading-prototype-forward-capture-listing.json" ]] ||
  copy_private_evidence_path "$WORK/shading-prototype-forward-capture-listing.json" \
    "$OUT/shading-prototype-forward-capture-listing.json" ||
  fail "could not preserve private Forward capture listing"
[[ ! -f "$WORK/shading-prototype-forward-terminal-wait.txt" ]] ||
  copy_private_evidence_path "$WORK/shading-prototype-forward-terminal-wait.txt" \
    "$OUT/shading-prototype-forward-terminal-wait.txt" ||
  fail "could not preserve private Forward terminal evidence"
if [[ -e "$WORK/$CLEAR_ONLY_CAPTURE_NAME" &&
      ! -L "$WORK/$CLEAR_ONLY_CAPTURE_NAME" ]]; then
  copy_private_evidence_path "$WORK/$CLEAR_ONLY_CAPTURE_NAME" \
    "$OUT/$CLEAR_ONLY_CAPTURE_NAME" ||
    fail "could not preserve private clear capture"
fi
if [[ -e "$WORK/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" &&
      ! -L "$WORK/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" ]]; then
  copy_private_evidence_path "$WORK/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" \
    "$OUT/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" ||
    fail "could not preserve private Tile capture"
fi
if [[ -e "$WORK/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" &&
      ! -L "$WORK/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" ]]; then
  copy_private_evidence_path "$WORK/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" \
    "$OUT/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" ||
    fail "could not preserve private Forward capture"
fi
if ((REQUIRE_CLEAR_ONLY_PASS_SELF_TEST != 0)); then
  [[ "$CLEAR_ONLY_CAPTURE_STATUS" == acquired ]] ||
    fail "clear-only capture was not acquired at the PASS evidence boundary"
  python3 "$ROOT/ios/device-test/validate-metal-capture-artifact.py" \
    --artifact "$OUT/$CLEAR_ONLY_CAPTURE_NAME" \
    --summary "$WORK/clear-only-capture-evidence-summary.txt" ||
    fail "preserved clear-only capture is invalid"
  cmp -s "$WORK/clear-only-capture-summary.txt" \
    "$WORK/clear-only-capture-evidence-summary.txt" ||
    fail "preserved clear-only capture fingerprint changed"
fi
if ((REQUIRE_SHADING_PROTOTYPE_TILE_SELF_TEST != 0)); then
  [[ "$SHADING_PROTOTYPE_TILE_CAPTURE_STATUS" == acquired ]] ||
    fail "shading prototype Tile capture was not acquired at the PASS evidence boundary"
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/ios/device-test/validate-shading-prototype-tile-self-test-log.py" \
      --capture-only --artifact "$OUT/$SHADING_PROTOTYPE_TILE_CAPTURE_NAME" \
      --summary "$WORK/shading-prototype-tile-capture-evidence-summary.txt" ||
    fail "preserved shading prototype Tile capture is invalid"
  cmp -s "$WORK/shading-prototype-tile-capture-summary.txt" \
    "$WORK/shading-prototype-tile-capture-evidence-summary.txt" ||
    fail "preserved shading prototype Tile capture fingerprint changed"
fi
if ((REQUIRE_SHADING_PROTOTYPE_FORWARD_SELF_TEST != 0)); then
  [[ "$SHADING_PROTOTYPE_FORWARD_CAPTURE_STATUS" == acquired ]] ||
    fail "shading prototype Forward capture was not acquired at the PASS evidence boundary"
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/ios/device-test/validate-shading-prototype-forward-self-test-log.py" \
      --capture-only --artifact "$OUT/$SHADING_PROTOTYPE_FORWARD_CAPTURE_NAME" \
      --summary "$WORK/shading-prototype-forward-capture-evidence-summary.txt" ||
    fail "preserved shading prototype Forward capture is invalid"
  cmp -s "$WORK/shading-prototype-forward-capture-summary.txt" \
    "$WORK/shading-prototype-forward-capture-evidence-summary.txt" ||
    fail "preserved shading prototype Forward capture fingerprint changed"
fi
for candidate in id3-protected-before.sha256 id3-protected-after.sha256 \
    id3-saves-before.json id3-saves-after.json save_slot_20.sav \
    processes.json processes-id3-window-start.json \
    processes-resource-allocator-window-start.json \
    processes-clear-only-pass-window-start.json \
    processes-shading-prototype-tile-window-start.json \
    processes-shading-prototype-forward-window-start.json \
    log-shading-prototype-forward-terminal-check.txt \
    documents-preinstall.json scripts-preinstall.json system-preinstall.json \
    documents-postinstall.json scripts-postinstall.json system-postinstall.json \
    documents-postruntime.json scripts-postruntime.json system-postruntime.json \
    shading-prototype-forward-saves-before.json \
    shading-prototype-forward-saves-after.json \
    shading-prototype-forward-saves-before.names \
    shading-prototype-forward-saves-after.names \
    shading-prototype-forward-saves-before.sha256 \
    shading-prototype-forward-saves-after.sha256 \
    log-id3-completion-check.txt; do
  [[ -f "$WORK/$candidate" ]] || continue
  copy_private_evidence_path "$WORK/$candidate" "$OUT/$candidate" ||
    fail "could not preserve private evidence: $candidate"
done
for candidate in crash-before.log crash.log crash-final.log \
    crash-listing-before.json crash-listing-after.json crash-listing-final.json; do
  [[ -f "$WORK/$candidate" ]] || continue
  copy_private_evidence_path "$WORK/$candidate" "$OUT/$candidate" ||
    fail "could not preserve private crash evidence: $candidate"
done
rm -f "$OUT"/processes-durable-zero-*.json "$OUT"/durable-zero-*.json
for candidate in "$WORK"/processes-durable-zero-*.json \
    "$WORK"/processes-resource-allocator-window-start-attempt-*.json \
    "$WORK"/processes-clear-only-pass-window-start-attempt-*.json \
    "$WORK"/processes-shading-prototype-tile-window-start-attempt-*.json \
    "$WORK"/processes-shading-prototype-forward-window-start-attempt-*.json \
    "$WORK"/processes-shading-prototype-forward-stability-*.json \
    "$WORK"/shading-prototype-forward-before-save_slot_*.sav \
    "$WORK"/shading-prototype-forward-after-save_slot_*.sav \
    "$WORK"/durable-zero-*.json; do
  [[ -f "$candidate" ]] || continue
  copy_private_evidence_path "$candidate" "$OUT/$(basename "$candidate")" ||
    fail "could not preserve private generated evidence: $(basename "$candidate")"
done
{
  echo "result=PASS"
  echo "source_sha=$EXPECTED_SHA"
  echo "expected_build=$EXPECTED_BUILD"
  echo "signed_executable_sha256=$APP_EXECUTABLE_SHA256"
  echo "expected_fault=$EXPECTED_FAULT"
  echo "device_facts_reference_a17_required=$REQUIRE_DEVICE_FACTS_REFERENCE_A17"
  echo "fault_log_validation=$FAULT_LOG_VALIDATION"
  echo "process_survived_fault_window=$PROCESS_SURVIVED_FAULT_WINDOW"
  write_resource_allocator_self_test_result_fields
  write_clear_only_pass_self_test_result_fields
  write_shading_prototype_tile_self_test_result_fields
  write_shading_prototype_forward_self_test_result_fields
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
  [[ ! -f "$WORK/device-facts-summary.txt" ]] ||
    cat "$WORK/device-facts-summary.txt"
  [[ ! -f "$WORK/runtime-compilation-summary.txt" ]] ||
    cat "$WORK/runtime-compilation-summary.txt"
  [[ ! -f "$WORK/fault-log-summary.txt" ]] ||
    cat "$WORK/fault-log-summary.txt"
  [[ ! -f "$WORK/resource-allocator-self-test-summary.txt" ]] ||
    cat "$WORK/resource-allocator-self-test-summary.txt"
  [[ ! -f "$WORK/clear-only-pass-self-test-summary.txt" ]] ||
    cat "$WORK/clear-only-pass-self-test-summary.txt"
  [[ ! -f "$WORK/shading-prototype-tile-self-test-summary.txt" ]] ||
    cat "$WORK/shading-prototype-tile-self-test-summary.txt"
  [[ ! -f "$WORK/shading-prototype-forward-self-test-summary.txt" ]] ||
    cat "$WORK/shading-prototype-forward-self-test-summary.txt"
} >"$OUT/result.txt"
chmod 600 "$OUT/result.txt" ||
  fail "could not secure PASS result permissions"
secure_private_evidence "$OUT" ||
  fail "could not secure PASS evidence permissions"
