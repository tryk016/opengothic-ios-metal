#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEST_SOURCE="$REPO/ios/tests/iosremainingmaterialcensus.cpp"
VALIDATOR="$REPO/ios/device-test/validate-remaining-material-census-log.py"
ATTESTATION_VALIDATOR="$REPO/ios/device-test/validate-remaining-material-device-attestation.py"
DEVICE_SPEC="$REPO/ios/device-test/specs/p21e2a-remaining-material-census-device-v1.json"
SIMULATOR_SPEC="$REPO/ios/simulator-test/specs/p21e2a-remaining-material-census-v1.json"
SIMULATOR_RUNNER="$REPO/ios/simulator-test/run-remaining-material-census.sh"
COMMON_FLAGS=(
  -std=c++20 -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror
  -I"$REPO/game"
  -isystem "$REPO/lib/Tempest/Engine/include"
  -isystem "$REPO/lib/ZenKit/include"
)

cd "$REPO"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$TEST_SOURCE" ]] || fail "missing remaining-material census test"
[[ -x "$VALIDATOR" ]] || fail "remaining-material validator is not executable"
[[ -x "$ATTESTATION_VALIDATOR" ]] || fail "remaining-material attestation validator is not executable"
[[ -f "$DEVICE_SPEC" ]] || fail "remaining-material device spec is missing"
[[ -f "$SIMULATOR_SPEC" ]] || fail "remaining-material simulator spec is missing"
[[ -x "$SIMULATOR_RUNNER" ]] || fail "remaining-material simulator runner is not executable"
bash -n "$SIMULATOR_RUNNER"
"$SIMULATOR_RUNNER" --self-test

printf '\n### P2.1e2a diagnostics-OFF compile absence\n'
printf '#include "graphics/iosremainingmaterialcensus.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ "${COMMON_FLAGS[@]}" \
    -o "$RUNNER_TEMP/remaining-material-off" -
if printf '%s\n' '#include "graphics/iosremainingmaterialcensus.h"' \
    'int main() { IOSRemainingMaterialCensus value{}; return int(value.globalTotal); }' |
    xcrun clang++ -x c++ "${COMMON_FLAGS[@]}" \
      -o "$RUNNER_TEMP/remaining-material-off-mutation" - \
      >"$RUNNER_TEMP/remaining-material-off-mutation.log" 2>&1; then
  fail "diagnostics-OFF exposed remaining-material census state"
fi
if strings "$RUNNER_TEMP/remaining-material-off" |
   grep -Fq 'RendererIOS remaining material census'; then
  fail "diagnostics-OFF binary contains remaining-material markers"
fi

PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path
import re

diagnostics = "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS"
markers = (
    "RendererIOS remaining material census:",
    "RendererIOS remaining material census material:",
    "RendererIOS remaining material census row:",
)
found = []
for path in sorted(Path("game").rglob("*")):
    if path.suffix not in (".h", ".hpp", ".cpp", ".mm"):
        continue
    stack = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        directive = line.lstrip()
        if directive.startswith("#ifdef "):
            stack.append(directive.split()[1] == diagnostics or None)
            continue
        if directive.startswith("#ifndef "):
            stack.append(False if directive.split()[1] == diagnostics else None)
            continue
        if directive.startswith("#if "):
            expression = directive[4:].strip()
            if diagnostics in expression:
                positive = re.fullmatch(
                    rf"defined\s*\(\s*{diagnostics}\s*\)", expression
                ) is not None
                stack.append(True if positive else False)
            else:
                stack.append(None)
            continue
        if directive.startswith("#else"):
            if not stack:
                raise SystemExit(f"FAIL: unmatched #else {path}:{number}")
            if stack[-1] is not None:
                stack[-1] = not stack[-1]
            continue
        if directive.startswith("#elif"):
            if not stack:
                raise SystemExit(f"FAIL: unmatched #elif {path}:{number}")
            if stack[-1] is not None:
                stack[-1] = False
            continue
        if directive.startswith("#endif"):
            if not stack:
                raise SystemExit(f"FAIL: unmatched #endif {path}:{number}")
            stack.pop()
            continue
        for marker in markers:
            if marker in line:
                if True not in stack:
                    raise SystemExit(
                        f"FAIL: diagnostics-OFF marker leak {path}:{number}"
                    )
                found.append(marker)
    if stack:
        raise SystemExit(f"FAIL: unterminated conditional in {path}")
if found != list(markers):
    raise SystemExit(f"FAIL: exact marker set differs: {found!r}")
print("remaining-material diagnostics-OFF source oracle: PASS")
PY

printf '\n### P2.1e2a strict host contract\n'
xcrun clang++ "${COMMON_FLAGS[@]}" "$TEST_SOURCE" \
  -o "$RUNNER_TEMP/iosremainingmaterialcensus"
"$RUNNER_TEMP/iosremainingmaterialcensus"

printf '\n### P2.1e2a strict AppleClang iOS 16.4 compile\n'
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang++ "${COMMON_FLAGS[@]}" \
  -target arm64-apple-ios16.4 -isysroot "$IOS_SDK" \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 -fsyntax-only "$TEST_SOURCE"

printf '\n### P2.1e2a ASan\n'
xcrun clang++ "${COMMON_FLAGS[@]}" -fsanitize=address -fno-omit-frame-pointer \
  "$TEST_SOURCE" -o "$RUNNER_TEMP/iosremainingmaterialcensus-asan"
ASAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/iosremainingmaterialcensus-asan"

printf '\n### P2.1e2a UBSan\n'
xcrun clang++ "${COMMON_FLAGS[@]}" \
  -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer \
  "$TEST_SOURCE" -o "$RUNNER_TEMP/iosremainingmaterialcensus-ubsan"
UBSAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/iosremainingmaterialcensus-ubsan"

printf '\n### P2.1e2a log/artifact mutation oracle\n'
PYTHONDONTWRITEBYTECODE=1 python3 "$VALIDATOR" self-test
PYTHONDONTWRITEBYTECODE=1 python3 "$VALIDATOR" validate-device-spec \
  --spec "$DEVICE_SPEC"
PYTHONDONTWRITEBYTECODE=1 python3 "$VALIDATOR" validate-simulator-spec \
  --spec "$SIMULATOR_SPEC"
PYTHONDONTWRITEBYTECODE=1 python3 "$ATTESTATION_VALIDATOR" self-test

echo "P2.1e2a remaining-material census focused gates: PASS"
