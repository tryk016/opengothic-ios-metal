#!/usr/bin/env bash
# Focused host-only gate for the D-084 grouped physical-device harness.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAIR_SPEC="$ROOT/ios/device-test/specs/p21e1b-static-additive-v1.json"
GROUP_SPEC="$ROOT/ios/device-test/specs/p21e1b-static-additive-group-v1.json"
PAIR_VALIDATOR="$ROOT/ios/device-test/validate-additive-gpu-pair.py"
GROUP_VALIDATOR="$ROOT/ios/device-test/validate-additive-device-group.py"
RUNNER="$ROOT/ios/device-test/run-additive-gpu-group.sh"
PERFORMANCE="$ROOT/ios/device-test/run-additive-performance-test.sh"
LAUNCH_TEST="$ROOT/scripts/test-p21e1b-additive-launch-adapter.py"
PERFORMANCE_TEST="$ROOT/scripts/test-p21e1b-additive-performance.py"
INTEGRITY_SOURCE="$ROOT/game/graphics/iosdeviceintegritymanifest.cpp"
INTEGRITY_TEST="$ROOT/ios/tests/iosdeviceintegritymanifest.cpp"
BUILD_TMP="$ROOT/build/tmp/p21e1b-additive-device-group"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for path in "$PAIR_SPEC" "$GROUP_SPEC" "$PAIR_VALIDATOR" "$GROUP_VALIDATOR" \
    "$RUNNER" "$PERFORMANCE" "$LAUNCH_TEST" "$PERFORMANCE_TEST" \
    "$INTEGRITY_SOURCE" "$INTEGRITY_TEST"; do
  [[ -f "$path" && ! -L "$path" ]] || fail "required grouped file is invalid: $path"
done

[[ ! -L "$ROOT/build" && ! -L "$ROOT/build/tmp" ]] ||
  fail "private build/tmp path is a symlink"
mkdir -p "$BUILD_TMP"
INTEGRITY_BINARY="$BUILD_TMP/iosdeviceintegritymanifest-strict"
xcrun --sdk macosx clang++ -std=c++20 \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
  -DOPENGOTHIC_RENDERER_IOS_DEVICE_INTEGRITY_HOST_TEST=1 \
  -I"$ROOT/game" -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion \
  -Werror "$INTEGRITY_SOURCE" "$INTEGRITY_TEST" -framework CoreFoundation \
  -o "$INTEGRITY_BINARY"
integrity_output="$("$INTEGRITY_BINARY")" || fail "integrity host oracle failed"
[[ "$integrity_output" == \
   "RendererIOS device integrity manifest host oracle: PASS mutations-killed=102" ]] ||
  fail "integrity host oracle terminal differs"
printf '%s\n' "$integrity_output"

bash -n "$RUNNER" "$PERFORMANCE" \
  "$ROOT/ios/device-test/run-linear-hdr-proof-test.sh" \
  "$ROOT/ios/device-test/run-smoke-test.sh"

PYTHONDONTWRITEBYTECODE=1 python3 - "$PAIR_VALIDATOR" "$GROUP_VALIDATOR" <<'PY'
import pathlib,sys
for name in sys.argv[1:]:
    source=pathlib.Path(name).read_text(encoding="utf-8")
    compile(source,name,"exec")
print("grouped Python syntax: PASS")
PY

runner_self_test_output="$(PYTHONDONTWRITEBYTECODE=1 "$RUNNER" --self-test)" ||
  fail "grouped runner self-test failed"
for terminal in \
    "paired validator self-test: PASS (20 mutations killed)" \
    "additive device group validator self-test: PASS (18 mutations killed)" \
    "additive grouped runner self-test: PASS fake-adapters=7 mutations-killed=24 order=1 cleanup=1 recovery-preflight=1 live-pid-join=1 live-pid-parser=1 a-b-literals=1 no-clobber=1"; do
  [[ "$(printf '%s\n' "$runner_self_test_output" | grep -Fxc "$terminal")" == 1 ]] ||
    fail "grouped self-test terminal count/meta differs: $terminal"
done
[[ "$(printf '%s\n' "$runner_self_test_output" | wc -l | tr -d '[:space:]')" == 3 ]] ||
  fail "grouped self-test emitted an unexpected terminal"
printf '%s\n' "$runner_self_test_output"
printf '%s\n' "$runner_self_test_output" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys
lines=sys.stdin.read().splitlines()
expected=(
    "paired validator self-test: PASS (20 mutations killed)",
    "additive device group validator self-test: PASS (18 mutations killed)",
    "additive grouped runner self-test: PASS fake-adapters=7 mutations-killed=24 order=1 cleanup=1 recovery-preflight=1 live-pid-join=1 live-pid-parser=1 a-b-literals=1 no-clobber=1",
)
def validate(value):
    if tuple(value)!=expected: raise ValueError("terminal count/meta differs")
validate(lines)
mutants=(lines+[lines[0]],lines[1:],
         [line.replace("(18 mutations killed)","(17 mutations killed)")
          for line in lines])
killed=0
for mutant in mutants:
    try: validate(mutant)
    except ValueError: killed+=1
    else: raise SystemExit("grouped terminal mutation survived")
if killed!=3: raise SystemExit("grouped terminal mutation count drifted")
print("grouped terminal count/meta mutations: PASS (3 killed)")
'

PYTHONDONTWRITEBYTECODE=1 python3 "$LAUNCH_TEST"
PYTHONDONTWRITEBYTECODE=1 python3 "$PERFORMANCE_TEST"

PYTHONDONTWRITEBYTECODE=1 python3 - "$GROUP_SPEC" "$GROUP_VALIDATOR" "$RUNNER" <<'PY'
import copy
import importlib.util
import json
import pathlib
import sys
import tempfile

spec_path, validator_path, runner_path = map(pathlib.Path, sys.argv[1:])
definition=importlib.util.spec_from_file_location("group_focused_oracle",validator_path)
if definition is None or definition.loader is None:
    raise SystemExit("cannot load grouped validator")
module=importlib.util.module_from_spec(definition)
sys.modules[definition.name]=module
definition.loader.exec_module(module)
spec,_=module.validate_spec(spec_path)
runner=runner_path.read_text(encoding="utf-8")

required=(
    ("run_integrity_boundary pre",1),
    ("run_performance base-off-performance",1),
    ("run_plain candidate-on",1),
    ("run_performance candidate-off-performance",1),
    ('run_additive a "$ADDITIVE_A_APP" "$A_ARGUMENT"',1),
    ('run_additive b "$ADDITIVE_B_APP" "$B_ARGUMENT"',1),
    ("run_integrity_boundary post",1),
    ('"--live-pid-file" "$live_pid"',1),
    ('--live-pid-file "$live_pid" --role "$role"',1),
    ('copy_performance_evidence "$role" "$performance_dir"',1),
    ('module.validate_performance_evidence(',1),
    ('"--app-argument" "$argument"',1),
    ('delete_device_leaf "$artifact_leaf"',1),
    ('require_device_leaf_absent "$artifact_leaf"',1),
    ('python3 "$GUARD" run --timeout 1200',2),
    ('ACTIVE_RECOVERY="$(dirname "$FINAL_EVIDENCE")/$RECOVERY_LEAF"',1),
    ('if ensure_cleanup_durable_zero; then',1),
    ('kill -KILL "$BACKGROUND_PID"',1),
    ("trap '' INT TERM HUP",1),
    ('if ! restore_released_recovery; then',1),
    ('RECOVERY_RELEASED=1',1),
    ('FAIL: grouped cleanup lacks durable ZERO; staging/work retained',1),
    ('rm "$ACTIVE_RECOVERY" || fail "could not remove released active recovery journal"',1),
    ('publish_directory_no_clobber "$STAGING" "$FINAL_EVIDENCE"',1),
)
production=runner.rsplit("\nif ((SELF_TEST != 0)); then",1)[1]
sequence=[token for token,_ in required[:7]]
recovery_gate='ACTIVE_RECOVERY="$(dirname "$FINAL_EVIDENCE")/$RECOVERY_LEAF"'
work_create='WORK="$(mktemp -d "${TMPDIR%/}/opengothic-additive-group.XXXXXX")"'
staging_create='mkdir -m 700 "$STAGING"'
cleanup_zero='if ensure_cleanup_durable_zero; then'
device_evidence_cleanup='cleanup_owned_device_evidence ||'
work_remove='rm -rf "$WORK"'
def source_contract(text):
    for token,count in required:
        if text.count(token)!=count:
            raise ValueError("group runner oracle drift: "+token)
    cursor=0
    for token in sequence:
        position=text.find(token,cursor)
        if position<0: raise ValueError("group runner order drift")
        cursor=position+len(token)
    if not (text.index(recovery_gate)<text.index(work_create)<
            text.index(staging_create)):
        raise ValueError("recovery admission occurs after private allocation")
    if not (text.index(cleanup_zero)<text.index(device_evidence_cleanup)<
            text.index(work_remove)):
        raise ValueError("cleanup ordering bypasses durable ZERO/evidence removal")
source_contract(production)

mutations=[]
for token,_ in required:
    mutations.append(production.replace(token,"",1))
mutations.append(production.replace(recovery_gate,"",1).replace(
    staging_create,staging_create+"\n"+recovery_gate,1))
for mutant in mutations:
    try: source_contract(mutant)
    except ValueError: pass
    else: raise SystemExit("group runner source mutation survived")

documents=[]
for change in (
    lambda x: x["sequence"].reverse(),
    lambda x: x["applications"][3].update(launchArgument="--wrong"),
    lambda x: x["performance"].update(minimumMeanFpsAbsolute=26.0),
    lambda x: x["performance"].update(maximumMeanGpuActiveMilliseconds=34.0),
    lambda x: x["performance"].update(modelerBoundaryToleranceNanoseconds=51),
    lambda x: x["performance"].update(tocDurationToleranceNanoseconds=999),
    lambda x: x["performance"].update(commitLeaf="wrong.json"),
    lambda x: x["performance"].update(evidenceSetDomain="wrong"),
    lambda x: x["integrity"].update(protectedSlots=[1,2,3]),
    lambda x: x["durableZero"].update(minimumStableSeconds=89),
):
    value=copy.deepcopy(spec)
    change(value)
    documents.append(value)
killed=0
with tempfile.TemporaryDirectory(prefix="group-spec-mutations-") as directory:
    for index,value in enumerate(documents):
        path=pathlib.Path(directory)/f"spec-{index}.json"
        path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n")
        try:
            module.validate_spec(path)
        except module.ValidationError:
            killed+=1
        else:
            raise SystemExit("group spec mutation survived")
if killed!=len(documents):
    raise SystemExit("group spec mutation count drifted")
print(f"grouped source/spec mutations: PASS ({len(mutations)+killed} killed)")
PY

echo "RendererIOS additive device group focused checks passed"
