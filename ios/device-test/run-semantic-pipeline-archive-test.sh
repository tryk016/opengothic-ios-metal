#!/usr/bin/env bash
# Baseline save 1, then autonomous semantic Inventory archive cold/warm proof.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIPELINE_HARNESS="$ROOT/ios/device-test/run-pipeline-archive-test.sh"
SEMANTIC_HARNESS="$ROOT/ios/device-test/run-semantic-ui-lifecycle-test.sh"
EVIDENCE_VALIDATOR="$ROOT/ios/device-test/validate-semantic-pipeline-archive-evidence.py"
ARCHIVE_NAME="RendererIOS-abi-5.binaryarchive"
PROVENANCE_NAME="RendererIOS-abi-5.provenance"

BASELINE_DURATION=45
APP_INPUT=""
EVIDENCE_PATH_FILE=""
SELF_TEST=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 [--baseline-duration 10..600] [--evidence-path-file absolute-path] path/to/Gothic2Notr.app"
  echo "       $0 --self-test"
}

read_evidence_path() {
  local path_file="$1"
  python3 - "$path_file" <<'PY'
import pathlib
import sys

path_file = pathlib.Path(sys.argv[1])
lines = path_file.read_text().splitlines()
if len(lines) != 1:
    raise SystemExit("child evidence path file must contain exactly one line")
path = pathlib.Path(lines[0])
if not path.is_absolute() or not path.is_dir():
    raise SystemExit("child evidence path must be an existing absolute directory")
print(path)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-duration)
      BASELINE_DURATION="${2:?missing baseline duration}"
      shift 2
      ;;
    --evidence-path-file)
      [[ -z "$EVIDENCE_PATH_FILE" ]] || fail "--evidence-path-file was specified twice"
      EVIDENCE_PATH_FILE="${2:?missing evidence path file}"
      shift 2
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*) fail "unknown option: $1" ;;
    *)
      [[ -z "$APP_INPUT" ]] || fail "only one app path may be supplied"
      APP_INPUT="$1"
      shift
      ;;
  esac
done

if ((SELF_TEST != 0)); then
  [[ -z "$APP_INPUT" && -z "$EVIDENCE_PATH_FILE" ]] ||
    fail "--self-test does not accept an app or evidence path"
  python3 "$ROOT/ios/device-test/validate-pipeline-archive-log.py" --self-test
  python3 "$ROOT/ios/device-test/validate-semantic-ui-lifecycle-log.py" --self-test
  python3 "$EVIDENCE_VALIDATOR" --self-test
  echo "PASS: semantic pipeline archive wrapper host self-test"
  exit 0
fi

if [[ ! "$BASELINE_DURATION" =~ ^[0-9]+$ ]] ||
   ((BASELINE_DURATION < 10 || BASELINE_DURATION > 600)); then
  fail "baseline duration must be 10..600 seconds"
fi
[[ -n "$APP_INPUT" && -d "$APP_INPUT" ]] || fail "pass an existing .app directory"
[[ -f "$APP_INPUT/RendererIOS.metallib" ]] || fail "app has no RendererIOS.metallib"
[[ -x "$PIPELINE_HARNESS" && -x "$SEMANTIC_HARNESS" &&
   -x "$EVIDENCE_VALIDATOR" ]] || fail "semantic pipeline harness is incomplete"
if [[ -n "$EVIDENCE_PATH_FILE" ]]; then
  [[ "$EVIDENCE_PATH_FILE" == /* ]] || fail "evidence path file must be absolute"
  [[ -d "$(dirname "$EVIDENCE_PATH_FILE")" ]] ||
    fail "evidence path file parent does not exist"
fi

EXPECTED_SHA="${OPENGOTHIC_IOS_EXPECTED_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "expected source SHA is invalid"
METALLIB_SHA256="$(shasum -a 256 "$APP_INPUT/RendererIOS.metallib" | awk '{print $1}')"
[[ "$METALLIB_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "metallib SHA-256 is invalid"

WORK="$(mktemp -d -t opengothic-semantic-pipeline-wrapper)"
trap '[[ "$WORK" == /var/folders/*/T/opengothic-semantic-pipeline-wrapper.* ]] && rm -rf "$WORK"' EXIT
TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT="$ROOT/build/device-semantic-pipeline-archive/$EXPECTED_SHA/pass-$TIMESTAMP-$$"
mkdir -p "$OUT"

echo "== semantic pipeline baseline: save 1, two Builtin PSOs =="
OPENGOTHIC_IOS_EXPECTED_SHA="$EXPECTED_SHA" \
  "$PIPELINE_HARNESS" --duration "$BASELINE_DURATION" --save-slot 1 \
    --baseline-only --evidence-path-file "$WORK/baseline-path.txt" "$APP_INPUT"
BASELINE_EVIDENCE="$(read_evidence_path "$WORK/baseline-path.txt")" ||
  fail "baseline harness returned invalid evidence"

echo "== semantic pipeline inventory-cold: Inventory + Items + Weapons =="
OPENGOTHIC_IOS_EXPECTED_SHA="$EXPECTED_SHA" \
  "$SEMANTIC_HARNESS" --save-slot 1 \
    --pipeline-archive-phase inventory-cold \
    --metallib-sha256 "$METALLIB_SHA256" \
    --evidence-path-file "$WORK/inventory-cold-path.txt"
COLD_EVIDENCE="$(read_evidence_path "$WORK/inventory-cold-path.txt")" ||
  fail "inventory-cold harness returned invalid evidence"

echo "== semantic pipeline inventory-warm: strict archive hits =="
OPENGOTHIC_IOS_EXPECTED_SHA="$EXPECTED_SHA" \
  "$SEMANTIC_HARNESS" --save-slot 1 \
    --pipeline-archive-phase inventory-warm \
    --metallib-sha256 "$METALLIB_SHA256" \
    --evidence-path-file "$WORK/inventory-warm-path.txt"
WARM_EVIDENCE="$(read_evidence_path "$WORK/inventory-warm-path.txt")" ||
  fail "inventory-warm harness returned invalid evidence"

python3 "$EVIDENCE_VALIDATOR" \
  --baseline "$BASELINE_EVIDENCE" \
  --cold "$COLD_EVIDENCE" \
  --warm "$WARM_EVIDENCE" \
  --source-sha "$EXPECTED_SHA" \
  --metallib-sha256 "$METALLIB_SHA256" ||
  fail "cross-phase archive evidence validation failed"

BASELINE_ARCHIVE="$BASELINE_EVIDENCE/cold/$ARCHIVE_NAME"
COLD_ARCHIVE="$COLD_EVIDENCE/$ARCHIVE_NAME"
WARM_ARCHIVE="$WARM_EVIDENCE/$ARCHIVE_NAME"
{
  echo "result=PASS"
  echo "source_sha=$EXPECTED_SHA"
  echo "save_slot=1"
  echo "metallib_sha256=$METALLIB_SHA256"
  echo "baseline_evidence=$BASELINE_EVIDENCE"
  echo "inventory_cold_evidence=$COLD_EVIDENCE"
  echo "inventory_warm_evidence=$WARM_EVIDENCE"
  echo "baseline_archive_sha256=$(shasum -a 256 "$BASELINE_ARCHIVE" | awk '{print $1}')"
  echo "inventory_cold_archive_sha256=$(shasum -a 256 "$COLD_ARCHIVE" | awk '{print $1}')"
  echo "inventory_warm_archive_sha256=$(shasum -a 256 "$WARM_ARCHIVE" | awk '{print $1}')"
  echo "cold_changed_baseline=1"
  echo "warm_unchanged_from_cold=1"
  echo "provenance_stable=1"
  echo "device_process_stopped=1"
  echo "durable_zero_per_semantic_phase=1"
} >"$OUT/result.txt"
for path_file in baseline inventory-cold inventory-warm; do
  ditto "$WORK/$path_file-path.txt" "$OUT/$path_file-evidence-path.txt"
done
ditto "$COLD_EVIDENCE/archive-summary.txt" "$OUT/inventory-cold-summary.txt"
ditto "$WARM_EVIDENCE/archive-summary.txt" "$OUT/inventory-warm-summary.txt"
ditto "$BASELINE_EVIDENCE/cold/$PROVENANCE_NAME" "$OUT/$PROVENANCE_NAME"

if [[ -n "$EVIDENCE_PATH_FILE" ]]; then
  printf '%s\n' "$OUT" >"$EVIDENCE_PATH_FILE"
fi
echo "PASS — semantic Inventory pipeline archive cold/warm; app stopped"
echo "evidence: $OUT"
