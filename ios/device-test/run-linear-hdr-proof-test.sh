#!/usr/bin/env bash
#
# Run the diagnostics-only, one-shot SceneHDR producer and validate its exact
# artifact/log join. Device mutation is limited to the app install performed by
# run-smoke-test.sh and allowlisted deletion of producer-owned temporary leaves.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$ROOT/ios/device-test/run-smoke-test.sh"
VALIDATOR="$ROOT/ios/device-test/validate-linear-hdr-proof-artifact.py"
GPU_VALIDATOR="$ROOT/ios/device-test/validate-linear-hdr-gpu-evidence.py"
PLIST_VALIDATOR="$ROOT/ios/device-test/validate-plist-contract.py"
GUARD="$HOME/OpenGothic-RendererIOS-Handoff/current/private-tools/device_guard.py"
BASE_BUNDLE_ID="opengothic.gothic2"
APP_EXECUTABLE="Gothic2Notr"
FINAL_LEAF="RendererIOS-linear-hdr-proof-v1.bin"
CAPTURE_LEAF="RendererIOS-linear-hdr-proof-v1.gputrace"
CAPTURE_SUMMARY_LEAF="capture-copy-summary-v1.json"
EXPECTED_SHA="${OPENGOTHIC_IOS_EXPECTED_SHA:-}"
DURATION=45
SAVE_SLOT=20
SAVE_SLOT_SEEN=0
NEW_GAME=0
NEW_GAME_SEEN=0
GPU_TRIPLE=0
EVIDENCE_PATH_FILE=""
APP=""
DEVICE=""
DEVICE_UDID=""
BUNDLE_ID=""
WORK=""
POST_BOUNDARY_DONE=0
SELF_TEST=0
SELF_TEST_AFC_TYPE=""
SELF_TEST_DELETE_CALLED=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --expected-sha)
      EXPECTED_SHA="${2:?missing expected SHA}"
      shift 2
      ;;
    --duration)
      DURATION="${2:?missing duration}"
      shift 2
      ;;
    --save-slot)
      ((SAVE_SLOT_SEEN == 0)) || fail "duplicate --save-slot"
      SAVE_SLOT="${2:?missing save slot}"
      SAVE_SLOT_SEEN=1
      NEW_GAME=0
      shift 2
      ;;
    --new-game)
      ((NEW_GAME_SEEN == 0)) || fail "duplicate --new-game"
      NEW_GAME_SEEN=1
      NEW_GAME=1
      shift
      ;;
    --gpu-triple)
      ((GPU_TRIPLE == 0)) || fail "duplicate --gpu-triple"
      GPU_TRIPLE=1
      shift
      ;;
    --evidence-path-file)
      EVIDENCE_PATH_FILE="${2:?missing evidence path file}"
      shift 2
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -*)
      fail "usage: $0 --expected-sha 40-lowercase-hex [--duration 10..600] [--save-slot number|--new-game] [--gpu-triple] [--evidence-path-file absolute-path] path/to/Gothic2Notr.app"
      ;;
    *)
      [[ -z "$APP" ]] || fail "only one app path may be supplied"
      APP="$1"
      shift
      ;;
  esac
done

if ((SELF_TEST == 0)); then
  if ((GPU_TRIPLE != 0)); then
    ((NEW_GAME_SEEN == 0)) || fail "--gpu-triple rejects --new-game"
    if ((SAVE_SLOT_SEEN == 0)); then
      SAVE_SLOT=4
    fi
    [[ "$SAVE_SLOT" == 4 ]] || fail "--gpu-triple requires exact save slot 4"
  fi
  [[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] ||
    fail "expected SHA must be exactly 40 lowercase hexadecimal characters"
  if [[ ! "$DURATION" =~ ^[0-9]+$ ]] ||
     ((DURATION < 10 || DURATION > 600)); then
    fail "duration must be 10..600 seconds"
  fi
  [[ "$SAVE_SLOT" =~ ^[0-9]+$ ]] || fail "save slot must be non-negative"
  [[ -n "$APP" && -d "$APP" && ! -L "$APP" ]] || fail "app path is invalid"
  [[ -x "$APP/$APP_EXECUTABLE" ]] || fail "app executable is missing"
  [[ -x "$SMOKE" && -x "$GUARD" && -f "$VALIDATOR" &&
     -f "$GPU_VALIDATOR" && -f "$PLIST_VALIDATOR" ]] ||
    fail "required guarded-runner tools are missing"
  if [[ -n "$EVIDENCE_PATH_FILE" ]]; then
    [[ "$EVIDENCE_PATH_FILE" == /* &&
       -d "$(dirname "$EVIDENCE_PATH_FILE")" ]] ||
      fail "evidence path file must be absolute with an existing parent"
  fi

  if [[ -x /opt/homebrew/bin/uv && -x /opt/homebrew/bin/uvx ]]; then
    UV=/opt/homebrew/bin/uv
    UVX=/opt/homebrew/bin/uvx
  elif command -v uv >/dev/null 2>&1 && command -v uvx >/dev/null 2>&1; then
    UV="$(command -v uv)"
    UVX="$(command -v uvx)"
  else
    fail "uv and uvx are required for fail-closed app-container inspection/cleanup"
  fi

  WORK="$(mktemp -d "${TMPDIR%/}/opengothic-linear-hdr-proof.XXXXXX")" ||
    fail "could not create private work directory"
  chmod 700 "$WORK" || fail "could not secure private work directory"
  strings "$APP/$APP_EXECUTABLE" >"$WORK/app.strings" ||
    fail "could not inspect app Mach-O markers"
  if ((GPU_TRIPLE != 0)); then
    python3 "$PLIST_VALIDATOR" --plist "$APP/Info.plist" \
      --require-true RendererIOSLinearHDRGPUTripleCapture \
      --require-true MetalCaptureEnabled ||
      fail "--gpu-triple app requires both capture keys as exact CFBoolean true"
    [[ "$(grep -Fxc 'RendererIOS HDR capture profile: v=1 mode=one-shot' "$WORK/app.strings" || true)" -eq 1 ]] ||
      fail "--gpu-triple app lacks the exact one-shot Mach-O marker"
  else
    python3 "$PLIST_VALIDATOR" --plist "$APP/Info.plist" \
      --require-absent RendererIOSLinearHDRGPUTripleCapture \
      --require-absent MetalCaptureEnabled ||
      fail "producer-only app contains a capture plist key"
    ! grep -Fq 'RendererIOS HDR capture profile: v=1 mode=one-shot' "$WORK/app.strings" ||
      fail "producer-only app contains the capture profile marker"
  fi
fi

select_device() {
  local requested="${OPENGOTHIC_IOS_DEVICE:-}"
  xcrun devicectl list devices --json-output "$WORK/devices.json" \
    >/dev/null 2>"$WORK/devices.stderr" || return 1
  python3 - "$WORK/devices.json" "$requested" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("devices")
if not isinstance(devices, list):
    raise SystemExit("device provider returned no devices array")
requested = sys.argv[2]
matches = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    identifiers = (device.get("identifier"), hardware.get("udid"))
    if hardware.get("platform") != "iOS" or hardware.get("reality") != "physical":
        continue
    if requested:
        if requested not in identifiers:
            continue
    elif connection.get("tunnelState") != "connected":
        continue
    matches.append(device)
if len(matches) != 1:
    raise SystemExit(f"expected exactly one selectable physical iOS device, found {len(matches)}")
device = matches[0]
identifier = device.get("identifier")
udid = device.get("hardwareProperties", {}).get("udid")
if not isinstance(identifier, str) or not identifier or not isinstance(udid, str) or not udid:
    raise SystemExit("selected device has no exact identifier/UDID")
print(identifier + "\t" + udid)
PY
}

select_bundle() {
  xcrun devicectl device info apps --device "$DEVICE" \
    --json-output "$WORK/apps.json" >/dev/null 2>"$WORK/apps.stderr" || return 1
  python3 - "$WORK/apps.json" "$BASE_BUNDLE_ID" \
      "${OPENGOTHIC_IOS_BUNDLE_ID:-}" <<'PY'
import json
import sys

apps = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("apps")
if not isinstance(apps, list):
    raise SystemExit("installed app provider returned no apps array")
prefix = sys.argv[2] + "."
requested = sys.argv[3]
matches = []
for app in apps:
    bundle = app.get("bundleIdentifier") if isinstance(app, dict) else None
    if not isinstance(bundle, str):
        continue
    if bundle.startswith(prefix) and not bundle.endswith(".xctrunner"):
        if not requested or bundle == requested:
            matches.append(bundle)
if len(matches) != 1:
    raise SystemExit(f"expected exactly one installed non-xctrunner {prefix}* app, found {len(matches)}")
print(matches[0])
PY
}

require_game_zero() {
  local label="$1"
  local output="$WORK/processes-$label.json"
  xcrun devicectl device info processes --device "$DEVICE" \
    --json-output "$output" >/dev/null 2>"$WORK/processes-$label.stderr" || return 1
  python3 - "$output" "$APP_EXECUTABLE" <<'PY'
import json
import pathlib
import sys

processes = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("runningProcesses")
if not isinstance(processes, list):
    raise SystemExit("process provider returned no runningProcesses array")
name = sys.argv[2]
matches = [process for process in processes
           if pathlib.PurePosixPath(process.get("executable", "")).name == name]
if matches:
    raise SystemExit(f"game ZERO not established; found {len(matches)} {name} process(es)")
PY
}

enumerate_owned_temps() {
  local label="$1"
  local output="$WORK/documents-$label.json"
  if ((SELF_TEST != 0)); then
    [[ "$label" != self-after ]] || return 1
    return 0
  fi
  xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$output" >/dev/null 2>"$WORK/documents-$label.stderr" || return 1
  python3 - "$output" <<'PY'
import json
import re
import sys

files = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("files")
if not isinstance(files, list):
    raise SystemExit("file provider returned no files array")
prefix = ".RendererIOS-linear-hdr-proof-v1."
pattern = re.compile(r"^\.RendererIOS-linear-hdr-proof-v1\.[0-9a-f]{32}\.tmp$")
for entry in files:
    if not isinstance(entry, dict):
        raise SystemExit("file provider returned a non-object entry")
    name = entry.get("name")
    if not isinstance(name, str) or not name.startswith(prefix):
        continue
    if pattern.fullmatch(name) is None:
        raise SystemExit(f"unmatched producer-prefixed leaf remains untouched: {name!r}")
    resources = entry.get("resources", {})
    if resources.get("isDirectory") is not False or resources.get("isSymbolicLink") is not False:
        raise SystemExit(f"producer temp is a directory/symlink or lacks exact type booleans and remains untouched: {name!r}")
    print(name)
PY
}

afc_file_type() {
  local leaf="$1"
  "$UV" run --python python3.11 --with pymobiledevice3 python - \
      "$DEVICE_UDID" "$BUNDLE_ID" "$leaf" \
      2>>"$WORK/afc-stat.log" <<'PY'
import asyncio
import sys

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService


async def main() -> None:
    udid, bundle_id, leaf = sys.argv[1:]
    documents_path = f"Documents/{leaf}"
    async with await create_using_usbmux(
        serial=udid, autopair=False
    ) as lockdown:
        async with await HouseArrestService.create(
            lockdown=lockdown, bundle_id=bundle_id, documents_only=True
        ) as service:
            value = (await service.stat(documents_path)).get("st_ifmt")
    if not isinstance(value, str) or not value:
        raise RuntimeError("AFC stat returned no explicit st_ifmt")
    print(value)


asyncio.run(main())
PY
}

require_afc_regular_leaf() {
  local leaf="$1"
  local file_type
  file_type="$(afc_file_type "$leaf")" || return 1
  [[ "$file_type" == S_IFREG ]]
}

require_afc_capture_leaf() {
  local leaf="$1"
  local file_type
  file_type="$(afc_file_type "$leaf")" || return 1
  [[ "$file_type" == S_IFREG || "$file_type" == S_IFDIR ]]
}

delete_exact_device_leaf() {
  local leaf="$1"
  require_afc_capture_leaf "$leaf" || return 1
  "$UVX" --python python3.11 pymobiledevice3 apps rm \
    --udid "$DEVICE_UDID" --documents "$BUNDLE_ID" "$leaf" \
    >>"$WORK/device-owned-delete.log" 2>&1
}

cleanup_owned_temps() {
  local label="$1"
  local leaf leaves remaining
  leaves="$(enumerate_owned_temps "$label-before")" || return 1
  while IFS= read -r leaf; do
    [[ -n "$leaf" ]] || continue
    require_afc_regular_leaf "$leaf" || return 1
    "$UVX" --python python3.11 pymobiledevice3 apps rm \
      --udid "$DEVICE_UDID" --documents "$BUNDLE_ID" "$leaf" \
      >>"$WORK/temp-cleanup-$label.log" 2>&1 || return 1
  done <<<"$leaves"
  remaining="$(enumerate_owned_temps "$label-after")" || return 1
  [[ -z "$remaining" ]] || return 1
}

run_host_contract_self_test() {
  local candidate
  local cleanup_label="type-$$"
  WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  [[ -d "$WORK" ]] || fail "self-test work directory is missing"
  if cleanup_owned_temps self; then
    fail "second enumeration failure was ignored"
  fi
  afc_file_type() {
    printf '%s\n' "$SELF_TEST_AFC_TYPE"
  }
  enumerate_owned_temps() {
    if [[ "$1" == "${cleanup_label}-before" ]]; then
      echo ".RendererIOS-linear-hdr-proof-v1.0123456789abcdef0123456789abcdef.tmp"
    fi
  }
  # Invoked indirectly through UVX by cleanup_owned_temps.
  # shellcheck disable=SC2329
  self_test_uvx() {
    SELF_TEST_DELETE_CALLED=1
  }
  UVX=self_test_uvx
  for candidate in S_IFDIR S_IFCHR S_IFBLK S_IFIFO S_IFLNK S_IFSOCK UNKNOWN ""; do
    SELF_TEST_AFC_TYPE="$candidate"
    if require_afc_regular_leaf fixture; then
      fail "non-regular AFC type was accepted: ${candidate:-empty}"
    fi
  done
  for candidate in S_IFIFO S_IFSOCK UNKNOWN; do
    SELF_TEST_AFC_TYPE="$candidate"
    SELF_TEST_DELETE_CALLED=0
    if cleanup_owned_temps "$cleanup_label"; then
      fail "non-regular AFC type reached cleanup success: $candidate"
    fi
    ((SELF_TEST_DELETE_CALLED == 0)) ||
      fail "non-regular AFC type reached delete: $candidate"
  done
  SELF_TEST_AFC_TYPE=S_IFREG
  require_afc_regular_leaf fixture || fail "explicit AFC S_IFREG was rejected"
  SELF_TEST_DELETE_CALLED=0
  cleanup_owned_temps "$cleanup_label" ||
    fail "explicit AFC S_IFREG cleanup failed"
  ((SELF_TEST_DELETE_CALLED == 1)) ||
    fail "explicit AFC S_IFREG did not reach exact delete"
  unlink "$WORK/temp-cleanup-$cleanup_label.log" ||
    fail "self-test cleanup log could not be removed"
  echo "SELF-TEST PASS"
}

if ((SELF_TEST != 0)); then
  [[ -z "$APP" ]] || fail "--self-test accepts no app path"
  ((GPU_TRIPLE == 0 && SAVE_SLOT_SEEN == 0 && NEW_GAME_SEEN == 0)) ||
    fail "--self-test rejects device-run mode arguments"
  run_host_contract_self_test
  exit 0
fi

post_boundary() {
  local status=0
  ((POST_BOUNDARY_DONE == 0)) || return 0
  POST_BOUNDARY_DONE=1
  [[ -n "$DEVICE" && -n "$BUNDLE_ID" ]] || return 0
  require_game_zero post || status=1
  if ((status == 0)); then
    cleanup_owned_temps post || status=1
  fi
  return "$status"
}

cleanup() {
  local original_status="$?"
  local cleanup_status=0
  trap - EXIT INT TERM HUP
  post_boundary || cleanup_status=1
  [[ -z "$WORK" || "$WORK" != "${TMPDIR%/}"/opengothic-linear-hdr-proof.* ]] ||
    rm -rf "$WORK"
  if ((original_status == 0 && cleanup_status != 0)); then
    echo "FAIL: post-run game ZERO or allowlisted temp cleanup failed" >&2
    exit 1
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

DEVICE_RECORD="$(select_device)" ||
  fail "could not select one physical iOS device"
IFS=$'\t' read -r DEVICE DEVICE_UDID <<<"$DEVICE_RECORD"
[[ -n "$DEVICE" && -n "$DEVICE_UDID" ]] ||
  fail "selected physical device identity is incomplete"
BUNDLE_ID="$(select_bundle)" || fail "could not select the existing suffixed app container"
require_game_zero pre || fail "pre-run game ZERO was not established"
cleanup_owned_temps pre || fail "pre-run allowlisted temp cleanup failed"

SMOKE_EVIDENCE_FILE="$WORK/smoke-evidence-path.txt"
SMOKE_ARGS=(--duration "$DURATION" --evidence-path-file "$SMOKE_EVIDENCE_FILE")
if ((GPU_TRIPLE != 0)); then
  SMOKE_ARGS+=(--require-programmatic-metal-capture)
fi
if ((NEW_GAME != 0)); then
  SMOKE_ARGS+=(--new-game)
else
  SMOKE_ARGS+=(--save-slot "$SAVE_SLOT")
fi

if ! OPENGOTHIC_IOS_DEVICE="$DEVICE" \
    OPENGOTHIC_IOS_BUNDLE_ID="$BUNDLE_ID" \
    OPENGOTHIC_IOS_EXPECTED_SHA="$EXPECTED_SHA" \
    OPENGOTHIC_IOS_EXPECTED_BUILD="$EXPECTED_SHA" \
    python3 "$GUARD" run --timeout "$((DURATION + 900))" -- \
      "$SMOKE" "${SMOKE_ARGS[@]}" "$APP" \
      >"$WORK/smoke.stdout" 2>"$WORK/smoke.stderr"; then
  tail -80 "$WORK/smoke.stdout" >&2 || true
  tail -80 "$WORK/smoke.stderr" >&2 || true
  fail "guarded base smoke run failed"
fi

require_game_zero proof || fail "game ZERO was not established before proof extraction"
[[ -s "$SMOKE_EVIDENCE_FILE" ]] || fail "base smoke did not publish its evidence path"
EVIDENCE_DIR="$(sed -n '1p' "$SMOKE_EVIDENCE_FILE")"
[[ "$EVIDENCE_DIR" == /* && -d "$EVIDENCE_DIR" && ! -L "$EVIDENCE_DIR" ]] ||
  fail "base smoke evidence path is invalid"
[[ "$EVIDENCE_DIR" != "$WORK" && "$EVIDENCE_DIR" != "$WORK/"* ]] ||
  fail "base smoke evidence path is inside ephemeral work"
[[ -f "$EVIDENCE_DIR/log.txt" && ! -L "$EVIDENCE_DIR/log.txt" ]] ||
  fail "base smoke runtime log is invalid"

xcrun devicectl device info files --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --username mobile --subdirectory Documents --no-recurse \
  --json-output "$WORK/documents-artifact.json" >/dev/null ||
  fail "could not enumerate the proof artifact"
python3 - "$WORK/documents-artifact.json" "$FINAL_LEAF" "$CAPTURE_LEAF" "$GPU_TRIPLE" <<'PY' ||
import json
import sys

files = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("files")
if not isinstance(files, list):
    raise SystemExit("file provider returned no files array")
matches = [entry for entry in files if isinstance(entry, dict) and entry.get("name") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one final proof artifact, found {len(matches)}")
resources = matches[0].get("resources", {})
if resources.get("isDirectory") is not False or resources.get("isSymbolicLink") is not False:
    raise SystemExit("final proof artifact is a directory/symlink or lacks exact type booleans")
if sys.argv[4] == "1":
    captures = [entry for entry in files if isinstance(entry, dict) and entry.get("name") == sys.argv[3]]
    if len(captures) != 1:
        raise SystemExit(f"expected exactly one fixed capture leaf, found {len(captures)}")
    resources = captures[0].get("resources", {})
    if resources.get("isSymbolicLink") is not False or resources.get("isDirectory") not in (True, False):
        raise SystemExit("capture leaf is a symlink or lacks exact kind booleans")
PY
  fail "final proof artifact type check failed"
require_afc_regular_leaf "$FINAL_LEAF" ||
  fail "final proof artifact has no explicit AFC S_IFREG type"

ARTIFACT="$EVIDENCE_DIR/$FINAL_LEAF"
[[ ! -e "$ARTIFACT" && ! -L "$ARTIFACT" ]] ||
  fail "proof evidence destination already exists"
xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
  --source "Documents/$FINAL_LEAF" --destination "$ARTIFACT" >/dev/null ||
  fail "could not copy the proof artifact"
[[ -f "$ARTIFACT" && ! -L "$ARTIFACT" ]] ||
  fail "copied proof artifact is not regular"
chmod 600 "$ARTIFACT" || fail "could not secure proof evidence"

if ((GPU_TRIPLE != 0)); then
  DEVICE_CAPTURE_TYPE="$(afc_file_type "$CAPTURE_LEAF")" ||
    fail "capture leaf has no explicit AFC regular/directory type"
  case "$DEVICE_CAPTURE_TYPE" in
    S_IFREG) DEVICE_CAPTURE_KIND="file" ;;
    S_IFDIR) DEVICE_CAPTURE_KIND="directory" ;;
    *) fail "capture leaf has no explicit AFC regular/directory type" ;;
  esac
  CAPTURE_FINAL="$EVIDENCE_DIR/$CAPTURE_LEAF"
  CAPTURE_STAGING_PARENT="$EVIDENCE_DIR/gpudebug-capture-staging"
  CAPTURE_STAGING="$CAPTURE_STAGING_PARENT/$CAPTURE_LEAF"
  CAPTURE_SUMMARY="$EVIDENCE_DIR/$CAPTURE_SUMMARY_LEAF"
  TRANSCRIPT_DIR="$EVIDENCE_DIR/gpudebug-transcripts-v1"
  GPU_EVIDENCE="$EVIDENCE_DIR/linear-hdr-gpu-evidence-v2.json"
  [[ ! -e "$CAPTURE_FINAL" && ! -L "$CAPTURE_FINAL" &&
     ! -e "$CAPTURE_STAGING_PARENT" && ! -L "$CAPTURE_STAGING_PARENT" &&
     ! -e "$CAPTURE_SUMMARY" && ! -L "$CAPTURE_SUMMARY" &&
     ! -e "$TRANSCRIPT_DIR" && ! -L "$TRANSCRIPT_DIR" &&
     ! -e "$GPU_EVIDENCE" && ! -L "$GPU_EVIDENCE" ]] ||
    fail "GPU evidence destination already exists"
  mkdir -m 700 "$CAPTURE_STAGING_PARENT" ||
    fail "could not create private capture staging directory"
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "Documents/$CAPTURE_LEAF" --destination "$CAPTURE_STAGING" >/dev/null ||
    fail "could not copy the fixed GPU trace"
  PYTHONDONTWRITEBYTECODE=1 python3 "$GPU_VALIDATOR" --commit-capture-copy \
    --capture-staging "$CAPTURE_STAGING" --capture "$CAPTURE_FINAL" \
    --capture-summary "$CAPTURE_SUMMARY" --runtime-log "$EVIDENCE_DIR/log.txt" \
    --expected-capture-kind "$DEVICE_CAPTURE_KIND" ||
    fail "capture copy/summary commit failed"
  [[ -f "$CAPTURE_SUMMARY" && ! -L "$CAPTURE_SUMMARY" ]] ||
    fail "capture evidenceCommitted summary was not published"
  delete_exact_device_leaf "$CAPTURE_LEAF" ||
    fail "committed fixed device capture could not be deleted exactly"
  if require_afc_capture_leaf "$CAPTURE_LEAF" >/dev/null 2>&1; then
    fail "fixed device capture remains after committed exact delete"
  fi
  mkdir -m 700 "$TRANSCRIPT_DIR" ||
    fail "could not create private transcript directory"
  GPU_RESULT="$EVIDENCE_DIR/linear-hdr-gpu-result.txt"
  if ! PYTHONDONTWRITEBYTECODE=1 python3 "$GPU_VALIDATOR" --collect \
      --evidence "$GPU_EVIDENCE" --capture "$CAPTURE_FINAL" \
      --capture-summary "$CAPTURE_SUMMARY" --artifact "$ARTIFACT" \
      --runtime-log "$EVIDENCE_DIR/log.txt" --transcript-dir "$TRANSCRIPT_DIR" \
      --expected-sha "$EXPECTED_SHA" >"$GPU_RESULT"; then
    fail "owned gpudebug collection or exact v2 join failed"
  fi
  [[ "$(grep -Fxc 'GPU PASS' "$GPU_RESULT" || true)" -eq 1 &&
     "$(wc -l <"$GPU_RESULT" | tr -d '[:space:]')" -eq 1 ]] ||
    fail "GPU collector emitted an unexpected result"
  chmod 600 "$GPU_RESULT" || fail "could not secure GPU result evidence"
fi

post_boundary || fail "post-run game ZERO or allowlisted temp cleanup failed"
RESULT_FILE="$EVIDENCE_DIR/linear-hdr-proof-result.txt"
if ! PYTHONDONTWRITEBYTECODE=1 python3 "$VALIDATOR" \
    --artifact "$ARTIFACT" --runtime-log "$EVIDENCE_DIR/log.txt" \
    --expected-sha "$EXPECTED_SHA" >"$RESULT_FILE"; then
  fail "proof artifact/log join failed"
fi
[[ "$(grep -Fxc 'PRODUCER PASS' "$RESULT_FILE" || true)" -eq 1 &&
   "$(wc -l <"$RESULT_FILE" | tr -d '[:space:]')" -eq 1 ]] ||
  fail "proof validator emitted an unexpected result"
chmod 600 "$RESULT_FILE" ||
  fail "could not secure proof result evidence"
if [[ -n "$EVIDENCE_PATH_FILE" ]]; then
  printf '%s\n' "$EVIDENCE_DIR" >"$EVIDENCE_PATH_FILE" ||
    fail "could not publish proof evidence path"
fi
if ((GPU_TRIPLE != 0)); then
  cat "$GPU_RESULT"
else
  cat "$RESULT_FILE"
fi
