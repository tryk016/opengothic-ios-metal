#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/opengothic-save-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

xcrun clang++ -std=c++20 -Wall -Wextra -Werror -Wno-unused-parameter \
  -ffunction-sections -fdata-sections -Wl,-dead_strip \
  -Igame -isystem lib/miniz -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include -isystem lib/Tempest/Engine \
  ios/tests/serialize.cpp game/game/serialize.cpp \
  lib/Tempest/Engine/io/idevice.cpp lib/Tempest/Engine/io/odevice.cpp \
  lib/Tempest/Engine/io/memreader.cpp lib/Tempest/Engine/io/memwriter.cpp \
  lib/Tempest/Engine/io/wfile.cpp lib/Tempest/Engine/utility/textcodec.cpp \
  lib/Tempest/Engine/exceptions/exception.cpp \
  -o "$work/serialize"
"$work/serialize" "$work"
echo "Save-game regression tests: PASS (overwrite, write/finalize errors, reader cleanup, corrupt entry)"
