#!/usr/bin/env bash
# One no-clobber D-084 group: integrity-pre, exact five runs, integrity-post.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="$ROOT/ios/device-test/specs/p21e1b-static-additive-group-v1.json"
PAIR_SPEC="$ROOT/ios/device-test/specs/p21e1b-static-additive-v1.json"
GROUP_VALIDATOR="$ROOT/ios/device-test/validate-additive-device-group.py"
PAIR_VALIDATOR="$ROOT/ios/device-test/validate-additive-gpu-pair.py"
SMOKE="$ROOT/ios/device-test/run-smoke-test.sh"
LINEAR="$ROOT/ios/device-test/run-linear-hdr-proof-test.sh"
PERFORMANCE="$ROOT/ios/device-test/run-additive-performance-test.sh"
GUARD="$HOME/OpenGothic-RendererIOS-Handoff/current/private-tools/device_guard.py"
APP_EXECUTABLE=Gothic2Notr
RESOURCE_LEAF=resource-manifest-v1.jsonl
SAVE_LEAF=protected-save-manifest-v1.jsonl
RECOVERY_LEAF=device-integrity-recovery-journal-v1.json
INTEGRITY_ARGUMENT=-renderer-ios-device-integrity-manifest-v1
A_ARGUMENT=-renderer-ios-additive-causal-mode=additive-a-hdr
B_ARGUMENT=-renderer-ios-additive-causal-mode=additive-b-hdr

DEVICE=""
BASE_APP=""
CANDIDATE_ON_APP=""
CANDIDATE_OFF_APP=""
ADDITIVE_A_APP=""
ADDITIVE_B_APP=""
MASTER_MANIFEST=""
FINAL_EVIDENCE=""
SELF_TEST=0
WORK=""
STAGING=""
ACTIVE_RECOVERY=""
BACKGROUND_PID=""
BASE_PERFORMANCE_LEAF=""
CANDIDATE_PERFORMANCE_LEAF=""
RECOVERY_RELEASED=0
PUBLISHED=0
OWNED_DEVICE_LEAVES=()
OWNED_ADDITIVE_LABELS=()

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --spec) SPEC="${2:?missing spec}"; shift 2 ;;
    --device) DEVICE="${2:?missing device UDID}"; shift 2 ;;
    --base-off-app) BASE_APP="${2:?missing base OFF app}"; shift 2 ;;
    --candidate-on-app) CANDIDATE_ON_APP="${2:?missing candidate ON app}"; shift 2 ;;
    --candidate-off-app) CANDIDATE_OFF_APP="${2:?missing candidate OFF app}"; shift 2 ;;
    --additive-a-app) ADDITIVE_A_APP="${2:?missing Additive A app}"; shift 2 ;;
    --additive-b-app) ADDITIVE_B_APP="${2:?missing Additive B app}"; shift 2 ;;
    --master-resource-manifest) MASTER_MANIFEST="${2:?missing master manifest}"; shift 2 ;;
    --evidence-dir) FINAL_EVIDENCE="${2:?missing evidence directory}"; shift 2 ;;
    --smoke-adapter) SMOKE="${2:?missing smoke adapter}"; shift 2 ;;
    --linear-hdr-adapter) LINEAR="${2:?missing linear-HDR adapter}"; shift 2 ;;
    --performance-adapter) PERFORMANCE="${2:?missing performance adapter}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

run_self_test() {
  local parser_root parser_output
  local -a parser_args
  PYTHONDONTWRITEBYTECODE=1 python3 "$PAIR_VALIDATOR" self-test --spec "$PAIR_SPEC"
  PYTHONDONTWRITEBYTECODE=1 python3 "$GROUP_VALIDATOR" self-test --spec "$SPEC"
  parser_root="$(mktemp -d "${TMPDIR%/}/additive-group-performance-parser.XXXXXX")" ||
    fail "could not create performance parser fixture"
  chmod 700 "$parser_root" || fail "could not secure performance parser fixture"
  parser_args=(
    --device TEST-DEVICE-0001 --pid 1234 --role base-off-performance
    --expected-sha 0000000000000000000000000000000000000000
    --tempest-sha 1111111111111111111111111111111111111111
    --bundle-id opengothic.gothic2.RMJWWPF379 --team-id RMJWWPF379
    --save-slot 4 --fps-limit 30 --settle-seconds 12 --trace-seconds 30
    --evidence-dir "$parser_root/evidence"
    --live-pid-file "$parser_root/live-pid.json"
    --self-test "$parser_root/Gothic2Notr.app"
  )
  parser_output="$("$PERFORMANCE" "${parser_args[@]}")" || {
    rm -rf "$parser_root"
    fail "grouped performance argv was rejected by the real parser"
  }
  [[ "$parser_output" == \
    "SELF-TEST PASS device=TEST-DEVICE-0001 pid=1234 role=base-off-performance trace=30" ]] || {
    rm -rf "$parser_root"
    fail "grouped performance parser terminal differs"
  }
  if "$PERFORMANCE" \
      --device TEST-DEVICE-0001 --pid 1234 --role base-off-performance \
      --expected-sha 0000000000000000000000000000000000000000 \
      --tempest-sha 1111111111111111111111111111111111111111 \
      --bundle-id opengothic.gothic2.RMJWWPF379 --team-id RMJWWPF379 \
      --save-slot 4 --fps-limit 30 --settle-seconds 12 --trace-seconds 30 \
      --evidence-dir "$parser_root/evidence" --self-test \
      "$parser_root/Gothic2Notr.app" >"$parser_root/mutant.stdout" \
      2>"$parser_root/mutant.stderr"; then
    rm -rf "$parser_root"
    fail "missing live-PID grouped argv mutation survived"
  fi
  [[ "$(cat "$parser_root/mutant.stderr")" == \
    "FAIL: absolute evidence/live-PID paths and app path are required" ]] || {
    rm -rf "$parser_root"
    fail "missing live-PID grouped argv mutation failed for another reason"
  }
  rm -rf "$parser_root"
  python3 - "$0" <<'PY'
import os
import pathlib
import subprocess
import tempfile
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
production = source.rsplit("\nif ((SELF_TEST != 0)); then", 1)[1]
tokens = (
    "run_integrity_boundary pre",
    "run_performance base-off-performance",
    "run_plain candidate-on",
    "run_performance candidate-off-performance",
    'run_additive a "$ADDITIVE_A_APP" "$A_ARGUMENT"',
    'run_additive b "$ADDITIVE_B_APP" "$B_ARGUMENT"',
    "run_integrity_boundary post",
)
cursor = 0
for token in tokens:
    position = source.find(token, cursor)
    if position < 0:
        raise SystemExit("runner exact sequence/source anchor missing: " + token)
    cursor = position + len(token)
for token, expected_count in (
    ('"--live-pid-file" "$live_pid"', 1),
    ('--live-pid-file "$live_pid" --role "$role"', 1),
    ('copy_performance_evidence "$role" "$performance_dir"', 1),
    ('module.validate_performance_evidence(', 1),
    ('"--app-argument" "$argument"', 1),
    ('copy_additive_artifact "$label"', 1),
    ('delete_device_leaf "$artifact_leaf"', 1),
    ('require_device_leaf_absent "$artifact_leaf"', 1),
    ('capture_guard_zero "$role"', 2),
    ('ACTIVE_RECOVERY="$(dirname "$FINAL_EVIDENCE")/$RECOVERY_LEAF"', 1),
    ('if ensure_cleanup_durable_zero; then', 1),
    ('kill -KILL "$BACKGROUND_PID"', 1),
    ("trap '' INT TERM HUP", 1),
    ('if ! restore_released_recovery; then', 1),
    ('RECOVERY_RELEASED=1', 1),
    ('FAIL: grouped cleanup lacks durable ZERO; staging/work retained', 1),
    ('rm "$ACTIVE_RECOVERY" || fail "could not remove released active recovery journal"', 1),
    ('publish_directory_no_clobber "$STAGING" "$FINAL_EVIDENCE"', 1),
):
    if production.count(token) != expected_count:
        raise SystemExit("runner required-once anchor drift: " + token)

recovery_gate='ACTIVE_RECOVERY="$(dirname "$FINAL_EVIDENCE")/$RECOVERY_LEAF"'
work_create='WORK="$(mktemp -d "${TMPDIR%/}/opengothic-additive-group.XXXXXX")"'
staging_create='mkdir -m 700 "$STAGING"'
cleanup_zero='if ensure_cleanup_durable_zero; then'
device_evidence_cleanup='cleanup_owned_device_evidence ||'
work_remove='rm -rf "$WORK"'
def meta_contract(text):
    if not (text.index(recovery_gate)<text.index(work_create)<
            text.index(staging_create)):
        raise ValueError("active recovery admission is after private allocation")
    if not (text.index(cleanup_zero)<text.index(device_evidence_cleanup)<
            text.index(work_remove)):
        raise ValueError("cleanup ordering bypasses durable ZERO/evidence removal")
    if '--live-pid-file "$live_pid" --role "$role"' not in text:
        raise ValueError("collector live-PID join is absent")
meta_contract(production)
for mutant in (
        production.replace('--live-pid-file "$live_pid" --role "$role"','',1),
        production.replace(recovery_gate,'',1).replace(
            staging_create,staging_create+'\n'+recovery_gate,1),
        production.replace(cleanup_zero,'if false; then',1)):
    try: meta_contract(mutant)
    except (ValueError,IndexError): pass
    else: raise SystemExit("runner collector/recovery/cleanup mutation survived")

with tempfile.TemporaryDirectory(prefix="additive-group-recovery-preflight-") as temporary:
    root=pathlib.Path(temporary); destination=root/"final-evidence"
    work=root/"private-tmp"; work.mkdir()
    (root/"device-integrity-recovery-journal-v1.json").write_text("retained\n")
    missing=[str(root/name) for name in
             ("base.app","on.app","off.app","a.app","b.app")]
    command=[str(pathlib.Path(sys.argv[1]).resolve()),
             "--device","00008120-0011223344556677",
             "--base-off-app",missing[0],"--candidate-on-app",missing[1],
             "--candidate-off-app",missing[2],"--additive-a-app",missing[3],
             "--additive-b-app",missing[4],"--master-resource-manifest",
             str(root/"missing-master.jsonl"),"--evidence-dir",str(destination)]
    environment=os.environ.copy(); environment["TMPDIR"]=str(work)
    result=subprocess.run(command,env=environment,stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE,text=True,timeout=10,check=False)
    if (result.returncode==0 or
            "an active recovery journal already exists" not in result.stderr or
            tuple(work.iterdir()) or tuple(root.glob(".final-evidence.pending.*"))):
        raise SystemExit("existing recovery admission allocated private work/staging")

class FakeAdapter:
    def __init__(self, fail_role=None, crash_role=None, fatal_role=None,
                 cleanup_zero_fail=False):
        self.events=[]; self.leaves=set(); self.fail_role=fail_role
        self.crash_role=crash_role; self.fatal_role=fatal_role
        self.cleanup_zero_fail=cleanup_zero_fail; self.retained=False
    def run(self, role, argument=None, artifact=None):
        self.events.append(("run", role, argument))
        if artifact:
            if artifact in self.leaves:
                raise RuntimeError("artifact clobber")
            self.leaves.add(artifact)
            self.events.append(("copy", artifact))
        if role == self.crash_role or role == self.fatal_role or role == self.fail_role:
            raise RuntimeError(role)
        if artifact:
            self.leaves.remove(artifact)
            self.events.append(("delete", artifact))
        self.events.append(("zero", role))

roles = (
    ("integrity-pre", "-renderer-ios-device-integrity-manifest-v1", None),
    ("base-off-performance", None, None),
    ("candidate-on", None, None),
    ("candidate-off-performance", None, None),
    ("additive-a", "-renderer-ios-additive-causal-mode=additive-a-hdr", "input-a"),
    ("additive-b", "-renderer-ios-additive-causal-mode=additive-b-hdr", "input-b"),
    ("integrity-post", "-renderer-ios-device-integrity-manifest-v1", None),
)
class CleanupZeroError(RuntimeError): pass
def execute(adapter):
    try:
        for role,argument,artifact in roles:
            adapter.run(role,argument,artifact)
    except RuntimeError:
        for leaf in tuple(adapter.leaves):
            adapter.events.append(("cleanup-delete",leaf))
            adapter.leaves.remove(leaf)
        adapter.events.append(("cleanup-terminate",))
        adapter.events.append(("cleanup-park",))
        for scan in range(1,11):
            adapter.events.append(("cleanup-zero-scan",scan))
        if adapter.cleanup_zero_fail:
            adapter.retained=True
            adapter.events.append(("cleanup-hard-fail-retained",))
            raise CleanupZeroError("durable ZERO unavailable")
        adapter.events.append(("cleanup-zero",90,1))
        raise

adapter=FakeAdapter()
execute(adapter)
if [event[1] for event in adapter.events if event[0] == "run"] != [r[0] for r in roles]:
    raise SystemExit("fake adapter order differs")
if adapter.leaves:
    raise SystemExit("fake additive artifact cleanup differs")
if not any(event == ("run", "additive-a", roles[4][1]) for event in adapter.events):
    raise SystemExit("fake A literal argument missing")
if not any(event == ("run", "additive-b", roles[5][1]) for event in adapter.events):
    raise SystemExit("fake B literal argument missing")
mutations=0
for kind in ("fail_role", "crash_role", "fatal_role"):
    for role, argument, artifact in roles:
        broken=FakeAdapter(**{kind: role})
        try:
            execute(broken)
        except CleanupZeroError:
            raise SystemExit("fake ordinary failure became cleanup hard failure")
        except RuntimeError:
            if (broken.leaves or broken.retained or
                    sum(event[0]=="cleanup-zero-scan" for event in broken.events)!=10 or
                    not any(event==("cleanup-zero",90,1) for event in broken.events) or
                    not any(event[0]=="cleanup-terminate" for event in broken.events)):
                raise SystemExit("fake failure cleanup/zero differs")
            mutations += 1
        else:
            raise SystemExit("fake failure/crash/fatal survived")
broken=FakeAdapter(fail_role="candidate-on",cleanup_zero_fail=True)
try:
    execute(broken)
except CleanupZeroError:
    if (not broken.retained or broken.leaves or
            not any(event[0]=="cleanup-hard-fail-retained" for event in broken.events) or
            any(event[0]=="cleanup-zero" for event in broken.events)):
        raise SystemExit("fake cleanup-zero failure was not hard/retained")
    mutations += 1
else:
    raise SystemExit("fake cleanup-zero failure produced a clean outcome")
with tempfile.TemporaryDirectory(prefix="additive-group-no-clobber-") as directory:
    destination=pathlib.Path(directory)/"evidence"
    destination.mkdir()
    try:
        destination.mkdir()
    except FileExistsError:
        mutations += 1
    else:
        raise SystemExit("fake no-clobber collision survived")
if mutations != 23:
    raise SystemExit("fake adapter mutation count drifted")
print("additive grouped runner self-test: PASS fake-adapters=7 mutations-killed=24 order=1 cleanup=1 recovery-preflight=1 live-pid-join=1 live-pid-parser=1 a-b-literals=1 no-clobber=1")
PY
}

if ((SELF_TEST != 0)); then
  [[ -z "$DEVICE$BASE_APP$CANDIDATE_ON_APP$CANDIDATE_OFF_APP$ADDITIVE_A_APP$ADDITIVE_B_APP$MASTER_MANIFEST$FINAL_EVIDENCE" ]] ||
    fail "--self-test rejects device/app/evidence arguments"
  run_self_test
  exit 0
fi

[[ "$DEVICE" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$ ]] ||
  fail "--device must be one explicit physical-device UDID"
[[ "$FINAL_EVIDENCE" == /* && "$MASTER_MANIFEST" == /* ]] ||
  fail "evidence and master manifest paths must be absolute"
[[ ! -e "$FINAL_EVIDENCE" && ! -L "$FINAL_EVIDENCE" &&
   -d "$(dirname "$FINAL_EVIDENCE")" && ! -L "$(dirname "$FINAL_EVIDENCE")" ]] ||
  fail "final evidence destination is not an absent leaf in a real directory"
ACTIVE_RECOVERY="$(dirname "$FINAL_EVIDENCE")/$RECOVERY_LEAF"
[[ ! -e "$ACTIVE_RECOVERY" && ! -L "$ACTIVE_RECOVERY" ]] ||
  fail "an active recovery journal already exists"
[[ -f "$MASTER_MANIFEST" && ! -L "$MASTER_MANIFEST" ]] ||
  fail "master resource manifest is not regular"
for tool in "$GROUP_VALIDATOR" "$PAIR_VALIDATOR" "$SMOKE" "$LINEAR" \
    "$PERFORMANCE" "$GUARD"; do
  [[ -f "$tool" && ! -L "$tool" ]] || fail "required tool is invalid: $tool"
done
for app in "$BASE_APP" "$CANDIDATE_ON_APP" "$CANDIDATE_OFF_APP" \
    "$ADDITIVE_A_APP" "$ADDITIVE_B_APP"; do
  [[ "$app" == /* && -d "$app" && ! -L "$app" ]] ||
    fail "all five app paths must be absolute non-symlink directories"
done

if [[ -x /opt/homebrew/bin/uv && -x /opt/homebrew/bin/uvx ]]; then
  UV=/opt/homebrew/bin/uv
  UVX=/opt/homebrew/bin/uvx
elif command -v uv >/dev/null 2>&1 && command -v uvx >/dev/null 2>&1; then
  UV="$(command -v uv)"
  UVX="$(command -v uvx)"
else
  fail "uv and uvx are required for container identity and exact deletion"
fi

IFS=$'\t' read -r BASE_SHA CANDIDATE_SHA TEMPEST_SHA BUNDLE_ID TEAM_ID < <(
  PYTHONDONTWRITEBYTECODE=1 python3 - "$GROUP_VALIDATOR" "$SPEC" <<'PY'
import importlib.util, pathlib, sys
module_path, spec_path = map(pathlib.Path, sys.argv[1:])
definition = importlib.util.spec_from_file_location("group_runner_spec", module_path)
if definition is None or definition.loader is None:
    raise SystemExit("cannot load grouped validator")
module = importlib.util.module_from_spec(definition)
sys.modules[definition.name] = module
definition.loader.exec_module(module)
spec, _ = module.validate_spec(spec_path)
i = spec["identities"]
print("\t".join((i["baseParentSha"], i["candidateParentSha"], i["tempestSha"],
                 i["bundleId"], i["teamId"])))
PY
) || fail "group spec validation failed"
[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ && "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ &&
   "$TEMPEST_SHA" =~ ^[0-9a-f]{40}$ && "$BUNDLE_ID" == "opengothic.gothic2.$TEAM_ID" ]] ||
  fail "frozen group identities are malformed"

WORK="$(mktemp -d "${TMPDIR%/}/opengothic-additive-group.XXXXXX")" ||
  fail "could not create private work directory"
chmod 700 "$WORK"
STAGING="$(dirname "$FINAL_EVIDENCE")/.${FINAL_EVIDENCE##*/}.pending.$$"
mkdir -m 700 "$STAGING" || fail "could not create exclusive evidence staging"

run_cleanup_bounded() {
  local timeout="$1"
  shift
  python3 - "$timeout" "$@" <<'PY'
import os,signal,subprocess,sys
timeout=int(sys.argv[1])
process=subprocess.Popen(sys.argv[2:],start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    os.killpg(process.pid,signal.SIGTERM)
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL); process.wait()
    raise SystemExit(124)
PY
}

cleanup_game_pids() {
  local output="$1"
  run_cleanup_bounded 30 xcrun devicectl device info processes \
    --device "$DEVICE" --timeout 15 --json-output "$output" \
    >/dev/null 2>>"$WORK/group-cleanup-zero.log" || return 1
  python3 - "$output" "$APP_EXECUTABLE" <<'PY'
import json,pathlib,sys
with open(sys.argv[1],encoding="utf-8") as source:
    processes=json.load(source).get("result",{}).get("runningProcesses")
if not isinstance(processes,list): raise SystemExit(1)
seen=set()
for process in processes:
    if not isinstance(process,dict): raise SystemExit(1)
    if pathlib.PurePosixPath(process.get("executable","")).name!=sys.argv[2]:
        continue
    pid=process.get("processIdentifier")
    if type(pid) is not int or pid<=0 or pid in seen: raise SystemExit(1)
    seen.add(pid); print(pid)
PY
}

cleanup_stop_game() {
  local cycle="$1" attempt mode pid pids query
  for attempt in 1 2 3 4 5; do
    query="$WORK/cleanup-stop-$cycle-$attempt.json"
    pids="$(cleanup_game_pids "$query")" || return 1
    [[ -n "$pids" ]] || return 0
    ((attempt < 5)) || break
    mode=terminate
    ((attempt < 4)) || mode=kill
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if [[ "$mode" == kill ]]; then
        run_cleanup_bounded 30 xcrun devicectl device process terminate \
          --device "$DEVICE" --pid "$pid" --kill --quiet \
          >>"$WORK/group-cleanup-zero.log" 2>&1 || true
      else
        run_cleanup_bounded 30 xcrun devicectl device process terminate \
          --device "$DEVICE" --pid "$pid" --quiet \
          >>"$WORK/group-cleanup-zero.log" 2>&1 || true
      fi
    done <<<"$pids"
    sleep 1
  done
  return 1
}

cleanup_guard_reports_zero() {
  local output="$WORK/guard-cleanup-final.json"
  python3 "$GUARD" status --json >"$output" 2>>"$WORK/group-cleanup-zero.log" ||
    return 1
  python3 - "$output" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as source: value=json.load(source)
expected={"daemon","device","game","last_update_utc","lease","ready","state"}
if (set(value)!=expected or value["daemon"]!="RUNNING" or
        value["device"]!="CONFIGURED" or value["game"]!="ZERO" or
        value["ready"]!="YES" or value["state"]!="FRESH"):
    raise SystemExit(1)
PY
}

ensure_cleanup_durable_zero() {
  local cycle scan scheduled wait_seconds started elapsed pids stable query
  for cycle in 1 2 3; do
    cleanup_stop_game "$cycle" || continue
    run_cleanup_bounded 30 xcrun devicectl device process launch \
      --device "$DEVICE" --terminate-existing --activate com.apple.Preferences \
      >>"$WORK/group-cleanup-zero.log" 2>&1 || continue
    started=$SECONDS
    stable=1
    for scan in 1 2 3 4 5 6 7 8 9 10; do
      scheduled=$(((scan-1)*10))
      wait_seconds=$((scheduled-(SECONDS-started)))
      ((wait_seconds <= 0)) || sleep "$wait_seconds"
      query="$WORK/cleanup-zero-cycle-$cycle-scan-$scan.json"
      pids="$(cleanup_game_pids "$query")" || { stable=0; break; }
      if [[ -n "$pids" ]]; then
        stable=0
        break
      fi
      printf 'cleanup-zero cycle=%s scan=%s scheduled=%s result=zero\n' \
        "$cycle" "$scan" "$scheduled" >>"$WORK/group-cleanup-zero.log"
    done
    ((stable != 0)) || continue
    elapsed=$((SECONDS-started))
    ((elapsed >= 90)) || continue
    query="$WORK/cleanup-zero-cycle-$cycle-final.json"
    pids="$(cleanup_game_pids "$query")" || continue
    [[ -z "$pids" ]] || continue
    cleanup_guard_reports_zero || continue
    printf 'cleanup-zero cycle=%s stable-seconds=%s final-zero=1 result=pass\n' \
      "$cycle" "$elapsed" >>"$WORK/group-cleanup-zero.log"
    return 0
  done
  cleanup_stop_game emergency || true
  return 1
}

restore_released_recovery() {
  local source="$STAGING/recovery-journal-final.json"
  ((RECOVERY_RELEASED != 0)) || return 0
  [[ -f "$source" && ! -L "$source" && ! -e "$ACTIVE_RECOVERY" &&
     ! -L "$ACTIVE_RECOVERY" ]] || return 1
  python3 - "$source" "$ACTIVE_RECOVERY" <<'PY'
import os,pathlib,stat,sys
source,destination=map(pathlib.Path,sys.argv[1:])
descriptor=os.open(source,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
    before=os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or not 0<before.st_size<=1024*1024:
        raise SystemExit(1)
    raw=b""
    while len(raw)<before.st_size:
        chunk=os.read(descriptor,before.st_size-len(raw))
        if not chunk: raise SystemExit(1)
        raw+=chunk
    after=os.fstat(descriptor)
    identity=lambda value:(value.st_dev,value.st_ino,value.st_mode,value.st_size,
                           value.st_mtime_ns,value.st_ctime_ns)
    if os.read(descriptor,1) or identity(after)!=identity(before):
        raise SystemExit(1)
finally: os.close(descriptor)
parent=os.open(destination.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
temporary=f".{destination.name}.{os.getpid()}.restore.tmp"
try:
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,
               0o600,dir_fd=parent)
    try:
        view=memoryview(raw)
        while view:
            written=os.write(fd,view)
            if written<=0: raise SystemExit(1)
            view=view[written:]
        os.fsync(fd)
    finally: os.close(fd)
    os.link(temporary,destination.name,src_dir_fd=parent,dst_dir_fd=parent,
            follow_symlinks=False)
    os.unlink(temporary,dir_fd=parent)
    os.fsync(parent)
finally:
    try: os.unlink(temporary,dir_fd=parent)
    except FileNotFoundError: pass
    os.close(parent)
PY
}

cleanup() {
  local status="${1:-1}" cleanup_failed=0 zero_proven=0 attempt
  local recovery_state=retained
  trap - EXIT
  trap '' INT TERM HUP
  if [[ -n "$BACKGROUND_PID" ]]; then
    kill "$BACKGROUND_PID" 2>/dev/null || true
    for attempt in {1..40}; do
      kill -0 "$BACKGROUND_PID" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$BACKGROUND_PID" 2>/dev/null; then
      kill -KILL "$BACKGROUND_PID" 2>/dev/null || true
    fi
    wait "$BACKGROUND_PID" 2>/dev/null || true
    BACKGROUND_PID=""
  fi
  if ((PUBLISHED == 0)); then
    if ensure_cleanup_durable_zero; then
      zero_proven=1
    else
      cleanup_failed=1
    fi
  else
    zero_proven=1
  fi
  if declare -F cleanup_owned_device_evidence >/dev/null; then
    cleanup_owned_device_evidence ||
      cleanup_failed=1
  fi
  if ((cleanup_failed != 0 || zero_proven == 0)); then
    ((status != 0)) || status=1
    if ! restore_released_recovery; then
      recovery_state=restore-failed
      echo "FAIL: grouped cleanup could not restore released recovery journal" >&2
    fi
    echo "FAIL: grouped cleanup lacks durable ZERO; staging/work retained recovery-state=$recovery_state recovery=$ACTIVE_RECOVERY staging=$STAGING work=$WORK" >&2
  else
    [[ -z "$WORK" || ! -d "$WORK" ]] || rm -rf "$WORK"
  fi
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

copy_regular() {
  local source="$1" destination="$2"
  [[ -f "$source" && ! -L "$source" && ! -e "$destination" && ! -L "$destination" ]] ||
    return 1
  cp -p "$source" "$destination" || return 1
  chmod 600 "$destination" || return 1
  [[ -f "$destination" && ! -L "$destination" ]]
}

capture_guard_zero() {
  local role="$1" output="$STAGING/guard-status-$role.json"
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  python3 "$GUARD" status --json >"$output" || return 1
  chmod 600 "$output" || return 1
  python3 - "$output" <<'PY'
import json,sys
with open(sys.argv[1], encoding="utf-8") as source:
    x=json.load(source)
expected={"daemon","device","game","last_update_utc","lease","ready","state"}
if set(x)!=expected or x["daemon"]!="RUNNING" or x["state"]!="FRESH" or \
   x["device"]!="CONFIGURED" or x["game"]!="ZERO" or x["ready"]!="YES":
    raise SystemExit("device_guard does not report fresh game=ZERO")
PY
}

preserve_app() {
  local role="$1" app="$2" parent="$3" executable bundle team
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" 2>/dev/null)" || return 1
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist" 2>/dev/null)" || return 1
  [[ "$bundle" == "$BUNDLE_ID" && "$executable" == "$APP_EXECUTABLE" &&
     -f "$app/$executable" && ! -L "$app/$executable" &&
     -f "$app/RendererIOS.metallib" && ! -L "$app/RendererIOS.metallib" ]] || return 1
  /usr/bin/codesign --verify --strict --verbose=2 "$app" >/dev/null 2>&1 || return 1
  local description
  description="$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)" || return 1
  [[ "$(printf '%s\n' "$description" | awk -F= '$1=="Identifier"{print $2}')" == "$BUNDLE_ID" &&
     "$(printf '%s\n' "$description" | awk -F= '$1=="TeamIdentifier"{print $2}')" == "$TEAM_ID" ]] || return 1
  strings "$app/$executable" | grep -Fxq "$parent" || return 1
  copy_regular "$app/$executable" "$STAGING/Gothic2Notr-$role" || return 1
  copy_regular "$app/RendererIOS.metallib" "$STAGING/RendererIOS-$role.metallib"
}

preserve_app base-off-performance "$BASE_APP" "$BASE_SHA" || fail "base OFF signed app admission failed"
preserve_app candidate-on "$CANDIDATE_ON_APP" "$CANDIDATE_SHA" || fail "candidate ON signed app admission failed"
preserve_app candidate-off-performance "$CANDIDATE_OFF_APP" "$CANDIDATE_SHA" || fail "candidate OFF signed app admission failed"
preserve_app additive-a "$ADDITIVE_A_APP" "$CANDIDATE_SHA" || fail "Additive A signed app admission failed"
preserve_app additive-b "$ADDITIVE_B_APP" "$CANDIDATE_SHA" || fail "Additive B signed app admission failed"
copy_regular "$MASTER_MANIFEST" "$STAGING/resource-master.jsonl" ||
  fail "could not preserve master resource manifest"

container_uuid() {
  "$UV" run --python python3.11 --with pymobiledevice3 python - \
      "$DEVICE" "$BUNDLE_ID" <<'PY'
import asyncio,re,sys
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService
async def main():
    udid,bundle=sys.argv[1:]
    async with await create_using_usbmux(serial=udid,autopair=False) as lockdown:
        async with await InstallationProxyService.create(lockdown=lockdown) as service:
            apps=await service.get_apps(bundle_identifiers=[bundle])
    if list(apps)!=[bundle]:
        raise RuntimeError("installation proxy did not return exact bundle")
    value=apps[bundle].get("Container")
    match=re.fullmatch(r"(?:file://)?/private/var/mobile/Containers/Data/Application/([0-9A-Fa-f-]{36})/?", value or "")
    if not match:
        raise RuntimeError("data-container UUID is unavailable")
    print(match.group(1).upper())
asyncio.run(main())
PY
}

device_listing() {
  local output="$1"
  xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --username mobile --subdirectory Documents --no-recurse \
    --json-output "$output" >/dev/null
}

require_device_leaf_absent() {
  local leaf="$1" listing="$WORK/listing-absent-${leaf//[^A-Za-z0-9]/_}.json"
  device_listing "$listing" || return 1
  python3 - "$listing" "$leaf" <<'PY'
import json,sys
files=json.load(open(sys.argv[1])).get("result",{}).get("files")
if not isinstance(files,list): raise SystemExit(1)
matches=[x for x in files if isinstance(x,dict) and x.get("name")==sys.argv[2]]
raise SystemExit(0 if not matches else 1)
PY
}

require_device_regular_leaf() {
  local leaf="$1" listing="$WORK/listing-present-${leaf//[^A-Za-z0-9]/_}.json"
  device_listing "$listing" || return 1
  python3 - "$listing" "$leaf" <<'PY'
import json,sys
files=json.load(open(sys.argv[1])).get("result",{}).get("files")
if not isinstance(files,list): raise SystemExit(1)
matches=[x for x in files if isinstance(x,dict) and x.get("name")==sys.argv[2]]
if len(matches)!=1: raise SystemExit(1)
r=matches[0].get("resources",{})
if r.get("isDirectory") is not False or r.get("isSymbolicLink") is not False:
    raise SystemExit(1)
PY
}

delete_device_leaf() {
  local leaf="$1"
  "$UVX" --python python3.11 pymobiledevice3 apps rm --udid "$DEVICE" \
    --documents "$BUNDLE_ID" "Documents/$leaf" >/dev/null 2>&1
}

track_device_leaf() {
  local leaf="$1" current
  for current in "${OWNED_DEVICE_LEAVES[@]}"; do
    [[ "$current" != "$leaf" ]] || return 0
  done
  OWNED_DEVICE_LEAVES+=("$leaf")
}

untrack_device_leaf() {
  local leaf="$1" current replacement=()
  for current in "${OWNED_DEVICE_LEAVES[@]}"; do
    [[ "$current" == "$leaf" ]] || replacement+=("$current")
  done
  OWNED_DEVICE_LEAVES=("${replacement[@]}")
}

additive_device_leaves() {
  local label="$1" listing="$WORK/cleanup-additive-$label.json"
  device_listing "$listing" || return 1
  python3 - "$listing" "$label" <<'PY'
import json,re,sys
files=json.load(open(sys.argv[1])).get("result",{}).get("files")
if not isinstance(files,list): raise SystemExit(1)
p=re.compile(rf"RendererIOS-additive-input-v1-{re.escape(sys.argv[2])}-g[1-9][0-9]*-s[1-9][0-9]*\.bin")
for item in files:
    if not isinstance(item,dict): raise SystemExit(1)
    name=item.get("name")
    if isinstance(name,str) and p.fullmatch(name):
        resources=item.get("resources",{})
        if resources.get("isDirectory") is not False or resources.get("isSymbolicLink") is not False:
            raise SystemExit(1)
        print(name)
PY
}

require_no_additive_leaves() {
  local label="$1" leaves
  leaves="$(additive_device_leaves "$label")" || return 1
  [[ -z "$leaves" ]]
}

track_additive_label() {
  local label="$1" current
  for current in "${OWNED_ADDITIVE_LABELS[@]}"; do
    [[ "$current" != "$label" ]] || return 0
  done
  OWNED_ADDITIVE_LABELS+=("$label")
}

untrack_additive_label() {
  local label="$1" current replacement=()
  for current in "${OWNED_ADDITIVE_LABELS[@]}"; do
    [[ "$current" == "$label" ]] || replacement+=("$current")
  done
  OWNED_ADDITIVE_LABELS=("${replacement[@]}")
}

cleanup_owned_device_evidence() {
  local leaf label leaves result=0
  for leaf in "${OWNED_DEVICE_LEAVES[@]}"; do
    if require_device_regular_leaf "$leaf" 2>/dev/null; then
      delete_device_leaf "$leaf" || result=1
    elif ! require_device_leaf_absent "$leaf"; then
      result=1
    fi
  done
  for label in "${OWNED_ADDITIVE_LABELS[@]}"; do
    leaves="$(additive_device_leaves "$label")" || { result=1; continue; }
    while IFS= read -r leaf; do
      [[ -z "$leaf" ]] || delete_device_leaf "$leaf" || result=1
    done <<<"$leaves"
  done
  return "$result"
}

pull_device_leaf() {
  local leaf="$1" destination="$2"
  require_device_regular_leaf "$leaf" || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "Documents/$leaf" --destination "$destination" >/dev/null || return 1
  chmod 600 "$destination" || return 1
  [[ -f "$destination" && ! -L "$destination" ]]
}

evidence_path_from_file() {
  local path_file="$1" value
  [[ -f "$path_file" && ! -L "$path_file" ]] || return 1
  [[ "$(wc -l <"$path_file" | tr -d '[:space:]')" == 1 ]] || return 1
  value="$(sed -n '1p' "$path_file")"
  [[ "$value" == /* && -d "$value" && ! -L "$value" ]] || return 1
  printf '%s\n' "$value"
}

build_summary() {
  local role="$1" source_evidence="$2" macho="$3" metallib="$4"
  local result_dest="$STAGING/adapter-result-$role.txt"
  local log_dest="$STAGING/runtime-$role.log"
  copy_regular "$source_evidence/result.txt" "$result_dest" || return 1
  copy_regular "$source_evidence/log.txt" "$log_dest" || return 1
  capture_guard_zero "$role" || return 1
  PYTHONDONTWRITEBYTECODE=1 python3 "$GROUP_VALIDATOR" build-run-summary \
    --spec "$SPEC" --role "$role" --adapter-result "$result_dest" \
    --runtime-log "$log_dest" --signed-macho "$macho" --metallib "$metallib" \
    --guard-status "$STAGING/guard-status-$role.json" \
    --output "$STAGING/run-summary-$role.json" >/dev/null
}

run_plain() {
  local role="$1" app="$2" parent="$3" argument="${4:-}"
  local path_file="$WORK/evidence-$role.path" stdout="$WORK/$role.stdout" stderr="$WORK/$role.stderr"
  local args=(--duration 45 --save-slot 4 --evidence-path-file "$path_file")
  [[ -z "$argument" ]] || args+=(--app-argument "$argument")
  printf 'run=%s\n' "$role" >>"$STAGING/runner-events.log"
  if ! OPENGOTHIC_IOS_DEVICE="$DEVICE" OPENGOTHIC_IOS_BUNDLE_ID="$BUNDLE_ID" \
      OPENGOTHIC_IOS_TEAM_ID="$TEAM_ID" OPENGOTHIC_IOS_EXPECTED_SHA="$parent" \
      OPENGOTHIC_IOS_EXPECTED_BUILD="$parent" \
      python3 "$GUARD" run --timeout 1200 -- \
      "$SMOKE" "${args[@]}" "$app" >"$stdout" 2>"$stderr"; then
    return 1
  fi
  local evidence
  evidence="$(evidence_path_from_file "$path_file")" || return 1
  local macho="$STAGING/Gothic2Notr-$role" metallib="$STAGING/RendererIOS-$role.metallib"
  if [[ "$role" == integrity-pre || "$role" == integrity-post ]]; then
    macho="$STAGING/Gothic2Notr-candidate-on"
    metallib="$STAGING/RendererIOS-candidate-on.metallib"
  fi
  build_summary "$role" "$evidence" "$macho" "$metallib"
}

run_integrity_boundary() {
  local phase="$1" role="integrity-$phase"
  require_device_leaf_absent "$RESOURCE_LEAF" && require_device_leaf_absent "$SAVE_LEAF" ||
    return 1
  track_device_leaf "$RESOURCE_LEAF"
  track_device_leaf "$SAVE_LEAF"
  run_plain "$role" "$CANDIDATE_ON_APP" "$CANDIDATE_SHA" "$INTEGRITY_ARGUMENT" || return 1
  pull_device_leaf "$RESOURCE_LEAF" "$STAGING/resource-$phase.jsonl" || return 1
  pull_device_leaf "$SAVE_LEAF" "$STAGING/saves-$phase.jsonl" || return 1
  delete_device_leaf "$RESOURCE_LEAF" && delete_device_leaf "$SAVE_LEAF" || return 1
  require_device_leaf_absent "$RESOURCE_LEAF" && require_device_leaf_absent "$SAVE_LEAF" ||
    return 1
  untrack_device_leaf "$RESOURCE_LEAF"
  untrack_device_leaf "$SAVE_LEAF"
}

wait_live_pid() {
  local path="$1" attempts
  for attempts in {1..480}; do
    [[ -f "$path" && ! -L "$path" ]] && break
    kill -0 "$BACKGROUND_PID" 2>/dev/null || return 1
    sleep 0.25
  done
  [[ -f "$path" && ! -L "$path" ]] || return 1
  python3 - "$path" "$DEVICE" "$BUNDLE_ID" <<'PY'
import json,sys
raw=open(sys.argv[1],'rb').read()
def pairs(items):
    d={}
    for k,v in items:
        if k in d: raise ValueError("duplicate")
        d[k]=v
    return d
x=json.loads(raw.decode(),object_pairs_hook=pairs)
canonical=(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n').encode()
if raw!=canonical or tuple(x)!=("schemaVersion","deviceUdid","bundleId","executable","processId"):
    raise SystemExit(1)
if x!={"schemaVersion":1,"deviceUdid":sys.argv[2],"bundleId":sys.argv[3],
       "executable":"Gothic2Notr","processId":x["processId"]} or \
   type(x["processId"]) is not int or x["processId"]<=0:
    raise SystemExit(1)
print(x["processId"])
PY
}

copy_performance_evidence() {
  local role="$1" source="$2" leaf parent="$CANDIDATE_SHA"
  [[ "$role" != base-off-performance ]] || parent="$BASE_SHA"
  leaf="$(python3 - "$source" "$role" <<'PY'
import os,pathlib,re,stat,sys
root=pathlib.Path(sys.argv[1]); role=sys.argv[2]
before=root.lstat()
if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode): raise SystemExit(1)
entries=list(os.scandir(root))
pattern=re.compile(rf"performance-evidence-{re.escape(role)}-[0-9a-f]{{32}}")
matches=[]
for entry in entries:
    metadata=entry.stat(follow_symlinks=False)
    if not stat.S_ISDIR(metadata.st_mode) or entry.is_symlink() or not pattern.fullmatch(entry.name):
        raise SystemExit(1)
    matches.append(entry.name)
if len(matches)!=1: raise SystemExit(1)
print(matches[0])
PY
  )" || return 1
  [[ ! -e "$STAGING/$leaf" && ! -L "$STAGING/$leaf" ]] || return 1
  ditto "$source/$leaf" "$STAGING/$leaf" || return 1
  chmod -R u=rwX,go= "$STAGING/$leaf" || return 1
  PYTHONDONTWRITEBYTECODE=1 python3 - "$GROUP_VALIDATOR" "$SPEC" "$role" \
      "$DEVICE" "$BUNDLE_ID" "$TEAM_ID" "$TEMPEST_SHA" \
      "$parent" "$STAGING/$leaf" <<'PY' || return 1
import importlib.util,pathlib,sys
module_path,spec_path,role,device,bundle,team,tempest,parent,directory=sys.argv[1:]
definition=importlib.util.spec_from_file_location("group_performance_admission",module_path)
if definition is None or definition.loader is None: raise SystemExit(1)
module=importlib.util.module_from_spec(definition); sys.modules[definition.name]=module
definition.loader.exec_module(module)
spec,_=module.validate_spec(pathlib.Path(spec_path))
module.validate_performance_evidence(
    pathlib.Path(directory),spec,role,
    {"deviceUdid":device,"bundleId":bundle,"teamId":team,
     "tempestSha":tempest,"parentSha":parent},verify_semantics=True)
PY
  if [[ "$role" == base-off-performance ]]; then
    BASE_PERFORMANCE_LEAF="$leaf"
  else
    CANDIDATE_PERFORMANCE_LEAF="$leaf"
  fi
}

run_performance() {
  local role="$1" app="$2" parent="$3"
  local path_file="$WORK/evidence-$role.path" live_pid="$WORK/live-pid-$role.json"
  local performance_dir="$WORK/performance-$role" collector_status smoke_status pid
  mkdir -m 700 "$performance_dir" || return 1
  printf 'run=%s\n' "$role" >>"$STAGING/runner-events.log"
  OPENGOTHIC_IOS_DEVICE="$DEVICE" OPENGOTHIC_IOS_BUNDLE_ID="$BUNDLE_ID" \
    OPENGOTHIC_IOS_TEAM_ID="$TEAM_ID" OPENGOTHIC_IOS_EXPECTED_SHA="$parent" \
    OPENGOTHIC_IOS_EXPECTED_BUILD="$parent" \
    python3 "$GUARD" run --timeout 1200 -- "$SMOKE" --duration 70 --save-slot 4 \
      "--live-pid-file" "$live_pid" --evidence-path-file "$path_file" "$app" \
      >"$WORK/$role.stdout" 2>"$WORK/$role.stderr" &
  BACKGROUND_PID=$!
  pid="$(wait_live_pid "$live_pid")" || {
    wait "$BACKGROUND_PID" || true; BACKGROUND_PID=""; return 1; }
  set +e
  "$PERFORMANCE" --device "$DEVICE" --pid "$pid" \
    --live-pid-file "$live_pid" --role "$role" \
    --expected-sha "$parent" --tempest-sha "$TEMPEST_SHA" \
    --bundle-id "$BUNDLE_ID" --team-id "$TEAM_ID" --save-slot 4 --fps-limit 30 \
    --settle-seconds 12 --trace-seconds 30 --evidence-dir "$performance_dir" "$app" \
    >"$WORK/performance-$role.stdout" 2>"$WORK/performance-$role.stderr"
  collector_status=$?
  wait "$BACKGROUND_PID"
  smoke_status=$?
  BACKGROUND_PID=""
  set -e
  ((collector_status == 0 && smoke_status == 0)) || return 1
  [[ "$(cat "$WORK/performance-$role.stdout")" == "PERFORMANCE PASS" ]] || return 1
  local evidence
  evidence="$(evidence_path_from_file "$path_file")" || return 1
  copy_performance_evidence "$role" "$performance_dir" || return 1
  build_summary "$role" "$evidence" "$STAGING/Gothic2Notr-$role" \
    "$STAGING/RendererIOS-$role.metallib"
}

copy_additive_artifact() {
  local label="$1" listing="$WORK/additive-$label-listing.json" record artifact_leaf
  device_listing "$listing" || return 1
  record="$(python3 - "$listing" "$label" <<'PY'
import json,re,sys
files=json.load(open(sys.argv[1])).get("result",{}).get("files")
if not isinstance(files,list): raise SystemExit(1)
p=re.compile(rf"RendererIOS-additive-input-v1-{re.escape(sys.argv[2])}-g[1-9][0-9]*-s[1-9][0-9]*\.bin")
matches=[]
for x in files:
    if not isinstance(x,dict): raise SystemExit(1)
    name=x.get("name")
    if isinstance(name,str) and p.fullmatch(name):
        r=x.get("resources",{})
        if r.get("isDirectory") is not False or r.get("isSymbolicLink") is not False:
            raise SystemExit(1)
        matches.append(name)
if len(matches)!=1: raise SystemExit(1)
print(matches[0])
PY
  )" || return 1
  artifact_leaf="$record"
  pull_device_leaf "$artifact_leaf" "$STAGING/$artifact_leaf" || return 1
  delete_device_leaf "$artifact_leaf" || return 1
  require_device_leaf_absent "$artifact_leaf" || return 1
  printf '%s\n' "$artifact_leaf"
}

write_pair_run_manifest() {
  local label="$1" artifact_leaf="$2"
  python3 - "$STAGING/pair-run-$label.json" "$label" "$CANDIDATE_SHA" \
      "$TEMPEST_SHA" "$BUNDLE_ID" "$TEAM_ID" "$artifact_leaf" <<'PY'
import json,os,pathlib,sys
out,label,parent,tempest,bundle,team,artifact=sys.argv[1:]
x={"schemaVersion":1,"label":label,
   "identity":{"parentSha":parent,"tempestSha":tempest,"bundleId":bundle,"teamId":team},
   "signedMachOFile":f"Gothic2Notr-additive-{label}",
   "metallibFile":f"RendererIOS-additive-{label}.metallib",
   "exportManifestFile":f"RendererIOS-additive-{label}.exports",
   "inputArtifactFile":artifact,"runtimeLogFile":f"runtime-additive-{label}.log",
   "hdrProofFile":f"linear-hdr-{label}.bin",
   "captureIdentityFile":f"capture-identity-{label}.json"}
raw=(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n').encode()
fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,"wb") as sink:
    sink.write(raw); sink.flush(); os.fsync(sink.fileno())
PY
}

run_additive() {
  local label="$1" app="$2" argument="$3" role="additive-$label"
  local path_file="$WORK/evidence-$role.path" evidence artifact_leaf
  require_no_additive_leaves "$label" || return 1
  track_additive_label "$label"
  printf 'run=%s argument=%s\n' "$role" "$argument" >>"$STAGING/runner-events.log"
  OPENGOTHIC_IOS_DEVICE="$DEVICE" OPENGOTHIC_IOS_BUNDLE_ID="$BUNDLE_ID" \
    OPENGOTHIC_IOS_TEAM_ID="$TEAM_ID" \
    "$LINEAR" --expected-sha "$CANDIDATE_SHA" --duration 70 --save-slot 4 \
      --gpu-triple "--app-argument" "$argument" --evidence-path-file "$path_file" \
      "$app" >"$WORK/$role.stdout" 2>"$WORK/$role.stderr" || return 1
  evidence="$(evidence_path_from_file "$path_file")" || return 1
  copy_regular "$evidence/result.txt" "$STAGING/adapter-result-$role.txt" || return 1
  copy_regular "$evidence/log.txt" "$STAGING/runtime-$role.log" || return 1
  copy_regular "$evidence/RendererIOS-linear-hdr-proof-v1.bin" \
    "$STAGING/linear-hdr-$label.bin" || return 1
  copy_regular "$evidence/linear-hdr-gpu-evidence-v2.json" \
    "$STAGING/linear-hdr-gpu-evidence-$label.json" || return 1
  capture_guard_zero "$role" || return 1
  PYTHONDONTWRITEBYTECODE=1 python3 "$GROUP_VALIDATOR" build-run-summary \
    --spec "$SPEC" --role "$role" --adapter-result "$STAGING/adapter-result-$role.txt" \
    --runtime-log "$STAGING/runtime-$role.log" \
    --signed-macho "$STAGING/Gothic2Notr-$role" \
    --metallib "$STAGING/RendererIOS-$role.metallib" \
    --guard-status "$STAGING/guard-status-$role.json" \
    --output "$STAGING/run-summary-$role.json" >/dev/null || return 1
  artifact_leaf="$(copy_additive_artifact "$label")" || return 1
  untrack_additive_label "$label"
  PYTHONDONTWRITEBYTECODE=1 python3 "$PAIR_VALIDATOR" build-capture-identity \
    --gpu-evidence "$STAGING/linear-hdr-gpu-evidence-$label.json" \
    --output "$STAGING/capture-identity-$label.json" >/dev/null || return 1
  python3 - "$PAIR_SPEC" "$STAGING/RendererIOS-additive-$label.exports" <<'PY'
import json,os,sys
exports=json.load(open(sys.argv[1]))["metallib"]["exports"]
raw=("\n".join(exports)+"\n").encode("ascii")
fd=os.open(sys.argv[2],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,"wb") as sink:
    sink.write(raw); sink.flush(); os.fsync(sink.fileno())
PY
  write_pair_run_manifest "$label" "$artifact_leaf"
}

publish_directory_no_clobber() {
  local source="$1" destination="$2"
  python3 - "$source" "$destination" <<'PY'
import ctypes,errno,os,sys
source,destination=sys.argv[1:]
if not os.path.isabs(source) or not os.path.isabs(destination): raise SystemExit(1)
libc=ctypes.CDLL(None,use_errno=True)
fn=getattr(libc,"renameatx_np",None)
if fn is None: raise SystemExit("renameatx_np unavailable")
fn.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
fn.restype=ctypes.c_int
sfd=os.open(os.path.dirname(source),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
dfd=os.open(os.path.dirname(destination),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
    if fn(sfd,os.path.basename(source).encode(),dfd,os.path.basename(destination).encode(),0x4)!=0:
        raise OSError(ctypes.get_errno(),"exclusive evidence rename failed")
    os.fsync(dfd)
finally:
    os.close(dfd); os.close(sfd)
PY
}

OLD_CONTAINER_UUID="$(container_uuid)" || fail "could not establish old data-container UUID"
python3 - "$ACTIVE_RECOVERY" "$DEVICE" "$BUNDLE_ID" "$TEAM_ID" "$CANDIDATE_SHA" \
    "$OLD_CONTAINER_UUID" "$STAGING/resource-master.jsonl" <<'PY' ||
import hashlib,json,os,pathlib,sys
out,device,bundle,team,parent,old,master=sys.argv[1:]
h=lambda p:hashlib.sha256(open(p,'rb').read()).hexdigest()
x={"schemaVersion":1,"deviceUdid":device,"bundleId":bundle,"teamId":team,
   "parentSha":parent,"oldContainerUuid":old,"newContainerUuid":old,
   "masterResourceManifestSha256":h(master),"preResourceManifestSha256":"0"*64,
   "postResourceManifestSha256":"0"*64,"preProtectedSaveManifestSha256":"0"*64,
   "postProtectedSaveManifestSha256":"0"*64,"state":"pre-boundary-armed"}
raw=(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n').encode()
fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,"wb") as sink:
    sink.write(raw); sink.flush(); os.fsync(sink.fileno())
dfd=os.open(str(pathlib.Path(out).parent),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
  fail "could not arm recovery journal before the first install"
run_integrity_boundary pre || fail "integrity pre boundary failed"
NEW_CONTAINER_UUID="$(container_uuid)" || fail "could not establish pre-run data-container UUID"

python3 - "$ACTIVE_RECOVERY" "$DEVICE" "$BUNDLE_ID" "$TEAM_ID" "$CANDIDATE_SHA" \
    "$OLD_CONTAINER_UUID" "$NEW_CONTAINER_UUID" "$STAGING/resource-master.jsonl" \
    "$STAGING/resource-pre.jsonl" "$STAGING/saves-pre.jsonl" <<'PY' ||
import hashlib,json,os,pathlib,sys
out,device,bundle,team,parent,old,new,master,pre,saves=sys.argv[1:]
h=lambda p:hashlib.sha256(open(p,'rb').read()).hexdigest()
x={"schemaVersion":1,"deviceUdid":device,"bundleId":bundle,"teamId":team,
   "parentSha":parent,"oldContainerUuid":old,"newContainerUuid":new,
   "masterResourceManifestSha256":h(master),"preResourceManifestSha256":h(pre),
   "postResourceManifestSha256":"0"*64,"preProtectedSaveManifestSha256":h(saves),
   "postProtectedSaveManifestSha256":"0"*64,"state":"group-armed"}
raw=(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n').encode()
temporary=out+".group-armed.tmp"
fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,"wb") as sink:
    sink.write(raw); sink.flush(); os.fsync(sink.fileno())
os.replace(temporary,out)
dfd=os.open(str(pathlib.Path(out).parent),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
  fail "could not advance recovery journal after pre-boundary"

run_performance base-off-performance "$BASE_APP" "$BASE_SHA" ||
  fail "base OFF performance run failed"
run_plain candidate-on "$CANDIDATE_ON_APP" "$CANDIDATE_SHA" ||
  fail "candidate ON run failed"
run_performance candidate-off-performance "$CANDIDATE_OFF_APP" "$CANDIDATE_SHA" ||
  fail "candidate OFF performance run failed"
run_additive a "$ADDITIVE_A_APP" "$A_ARGUMENT" || fail "Additive A run failed"
run_additive b "$ADDITIVE_B_APP" "$B_ARGUMENT" || fail "Additive B run failed"

PYTHONDONTWRITEBYTECODE=1 python3 "$PAIR_VALIDATOR" build-attestation \
  --spec "$PAIR_SPEC" --evidence-dir "$STAGING" \
  --run-a-manifest "$STAGING/pair-run-a.json" \
  --run-b-manifest "$STAGING/pair-run-b.json" \
  --output "$STAGING/additive-gpu-pair-attestation-v1.json" >/dev/null ||
  fail "paired A/B attestation build/validation failed"

run_integrity_boundary post || fail "integrity post boundary failed"
FINAL_CONTAINER_UUID="$(container_uuid)" || fail "could not establish final data-container UUID"
[[ "$FINAL_CONTAINER_UUID" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] ||
  fail "final data-container UUID is invalid"
[[ "$BASE_PERFORMANCE_LEAF" =~ ^performance-evidence-base-off-performance-[0-9a-f]{32}$ &&
   "$CANDIDATE_PERFORMANCE_LEAF" =~ ^performance-evidence-candidate-off-performance-[0-9a-f]{32}$ ]] ||
  fail "performance evidence directory identities are incomplete"

python3 - "$ACTIVE_RECOVERY" "$STAGING/recovery-journal-final.json" "$DEVICE" \
    "$BUNDLE_ID" "$TEAM_ID" "$CANDIDATE_SHA" "$OLD_CONTAINER_UUID" \
    "$FINAL_CONTAINER_UUID" "$STAGING/resource-master.jsonl" \
    "$STAGING/resource-pre.jsonl" "$STAGING/resource-post.jsonl" \
    "$STAGING/saves-pre.jsonl" "$STAGING/saves-post.jsonl" <<'PY' ||
import hashlib,json,os,pathlib,sys,tempfile
active,out,device,bundle,team,parent,old,new,master,pre,post,spre,spost=sys.argv[1:]
h=lambda p:hashlib.sha256(open(p,'rb').read()).hexdigest()
x={"schemaVersion":1,"deviceUdid":device,"bundleId":bundle,"teamId":team,
   "parentSha":parent,"oldContainerUuid":old,"newContainerUuid":new,
   "masterResourceManifestSha256":h(master),"preResourceManifestSha256":h(pre),
   "postResourceManifestSha256":h(post),"preProtectedSaveManifestSha256":h(spre),
   "postProtectedSaveManifestSha256":h(spost),"state":"released"}
raw=(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n').encode()
fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,"wb") as sink:
    sink.write(raw); sink.flush(); os.fsync(sink.fileno())
temporary=active+".released.tmp"
fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,"wb") as sink:
    sink.write(raw); sink.flush(); os.fsync(sink.fileno())
os.replace(temporary,active)
dfd=os.open(str(pathlib.Path(active).parent),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
  fail "could not finalize recovery journal"

python3 - "$STAGING/group-builder.json" "$DEVICE" "$BASE_PERFORMANCE_LEAF" \
    "$CANDIDATE_PERFORMANCE_LEAF" <<'PY' ||
import json,os,sys
out,device,base_performance,candidate_performance=sys.argv[1:]
roles=("base-off-performance","candidate-on","candidate-off-performance","additive-a","additive-b")
runs=[]
for role in roles:
    label=role[-1] if role in ("additive-a","additive-b") else None
    runs.append({"role":role,"summaryFile":f"run-summary-{role}.json",
                 "signedMachOFile":f"Gothic2Notr-{role}",
                 "metallibFile":f"RendererIOS-{role}.metallib",
                 "performanceEvidenceDirectory":base_performance if role=="base-off-performance" else candidate_performance if role=="candidate-off-performance" else None,
                 "gpuEvidenceFile":f"linear-hdr-gpu-evidence-{label}.json" if label else None,
                 "captureIdentityFile":f"capture-identity-{label}.json" if label else None})
x={"schemaVersion":1,"deviceUdid":device,
   "integrity":{"masterResourceManifestFile":"resource-master.jsonl",
                "preResourceManifestFile":"resource-pre.jsonl",
                "postResourceManifestFile":"resource-post.jsonl",
                "preProtectedSaveManifestFile":"saves-pre.jsonl",
                "postProtectedSaveManifestFile":"saves-post.jsonl",
                "preRunSummaryFile":"run-summary-integrity-pre.json",
                "postRunSummaryFile":"run-summary-integrity-post.json"},
   "runs":runs,"additivePairFile":"additive-gpu-pair-attestation-v1.json",
   "recoveryJournalFile":"recovery-journal-final.json","activeJournalRemoved":True}
raw=(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n').encode()
fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,"wb") as sink:
    sink.write(raw); sink.flush(); os.fsync(sink.fileno())
PY
  fail "could not build grouped builder manifest"

PYTHONDONTWRITEBYTECODE=1 python3 "$GROUP_VALIDATOR" build-attestation \
  --spec "$SPEC" --builder "$STAGING/group-builder.json" --evidence-dir "$STAGING" \
  --output "$STAGING/additive-device-group-attestation-v1.json" >/dev/null ||
  fail "group attestation build/validation failed"

rm "$ACTIVE_RECOVERY" || fail "could not remove released active recovery journal"
[[ ! -e "$ACTIVE_RECOVERY" && ! -L "$ACTIVE_RECOVERY" ]] ||
  fail "released active recovery journal still exists"
python3 - "$(dirname "$ACTIVE_RECOVERY")" <<'PY' ||
import os,sys
descriptor=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try: os.fsync(descriptor)
finally: os.close(descriptor)
PY
  fail "could not durably release active recovery journal"
RECOVERY_RELEASED=1
PYTHONDONTWRITEBYTECODE=1 python3 "$GROUP_VALIDATOR" validate \
  --spec "$SPEC" --attestation "$STAGING/additive-device-group-attestation-v1.json" \
  --evidence-dir "$STAGING" >"$STAGING/group-result.txt" ||
  fail "final grouped validation failed after recovery release"
chmod 600 "$STAGING/group-result.txt" "$STAGING/runner-events.log"

python3 - "$STAGING" <<'PY' || fail "could not fsync grouped evidence tree"
import os,pathlib,stat,sys
root=pathlib.Path(sys.argv[1])
if not root.is_absolute() or root.is_symlink() or not root.is_dir(): raise SystemExit(1)
directories=[]
for directory,names,files in os.walk(root,topdown=True,followlinks=False):
    current=pathlib.Path(directory); directories.append(current)
    for name in names:
        child=current/name; value=child.lstat()
        if not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode): raise SystemExit(1)
    for name in files:
        child=current/name
        fd=os.open(child,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode): raise SystemExit(1)
            os.fsync(fd)
        finally: os.close(fd)
for directory in reversed(directories):
    fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)
PY

publish_directory_no_clobber "$STAGING" "$FINAL_EVIDENCE" ||
  fail "final grouped evidence publication collided"
PUBLISHED=1
STAGING=""
trap - EXIT INT TERM HUP
rm -rf "$WORK"
WORK=""
printf '%s\n' "ADDITIVE DEVICE GROUP PASS evidence=$FINAL_EVIDENCE"
