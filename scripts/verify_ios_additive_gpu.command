#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SOURCE="$REPO/game/graphics/iosadditiveinputartifact.cpp"
TEST="$REPO/ios/tests/iosadditiveinputartifact.cpp"
VALIDATOR="$REPO/ios/device-test/validate-additive-gpu-pair.py"
SPEC="$REPO/ios/device-test/specs/p21e1b-static-additive-v1.json"
WORK="$RUNNER_TEMP/p21e1b-additive-gpu-$$"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$SOURCE" ]] || fail "missing additive artifact implementation"
[[ -f "$TEST" ]] || fail "missing additive artifact test"
[[ -x "$VALIDATOR" ]] || fail "paired validator is not executable"
[[ -f "$SPEC" ]] || fail "missing declarative additive pair spec"
mkdir -p "$WORK"

cleanup() {
  local leaf
  for leaf in strict asan ubsan; do
    [[ ! -e "$WORK/$leaf" ]] || unlink "$WORK/$leaf"
  done
  rmdir "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

if command -v xcrun >/dev/null 2>&1; then
  CXX=(xcrun clang++)
elif command -v clang++ >/dev/null 2>&1; then
  CXX=(clang++)
else
  CXX=(c++)
fi

FLAGS=(
  -std=c++20
  -Wall
  -Wextra
  -Wpedantic
  -Wconversion
  -Wsign-conversion
  -Werror
  -I"$REPO/game"
)

cd "$REPO"

printf '\n### P2.1e1b additive input artifact strict host contract\n'
"${CXX[@]}" "${FLAGS[@]}" "$SOURCE" "$TEST" -o "$WORK/strict"
"$WORK/strict"

printf '\n### P2.1e1b additive input artifact ASan\n'
"${CXX[@]}" "${FLAGS[@]}" -fsanitize=address -fno-omit-frame-pointer \
  "$SOURCE" "$TEST" -o "$WORK/asan"
ASAN_OPTIONS=halt_on_error=1 "$WORK/asan"

printf '\n### P2.1e1b additive input artifact UBSan\n'
"${CXX[@]}" "${FLAGS[@]}" -fsanitize=undefined \
  -fno-sanitize-recover=undefined -fno-omit-frame-pointer \
  "$SOURCE" "$TEST" -o "$WORK/ubsan"
UBSAN_OPTIONS=halt_on_error=1 "$WORK/ubsan"

printf '\n### P2.1e1b paired attestation/spec/RG11B10 mutation oracle\n'
PYTHONDONTWRITEBYTECODE=1 python3 "$VALIDATOR" self-test --spec "$SPEC"

printf '\nP2.1e1b focused host evidence-core gate: PASS\n'
printf 'DEVICE/GPU: NOT RUN (focused gate does not claim runtime evidence)\n'
