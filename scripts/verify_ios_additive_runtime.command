#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ios-additive-runtime.XXXXXX")"
CXX="$(xcrun --find clang++)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCE="$ROOT/ios/tests/iosadditiveruntimecontract.cpp"

COMMON=(
  -std=c++20
  -Wall
  -Wextra
  -Wconversion
  -Wsign-conversion
  -Werror
  -isysroot
  "$SDK"
  -I"$ROOT/game/graphics"
)

build_and_run() {
  local name="$1"
  shift
  local binary="$BUILD_DIR/iosadditiveruntimecontract-$name"
  "$CXX" "${COMMON[@]}" "$@" "$SOURCE" -o "$binary"
  codesign -f -s - "$binary"
  "$binary" "$ROOT"
  print -- "ios additive runtime $name PASS"
}

build_and_run strict
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
  build_and_run asan -fsanitize=address -fno-omit-frame-pointer
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  build_and_run ubsan -fsanitize=undefined -fno-sanitize-recover=all

print -- "ios additive runtime focused PASS"
print -- "temporary artifacts: $BUILD_DIR"
