#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEST_SOURCE="$REPO/ios/tests/iosadditivesourcecensus.cpp"
VALIDATOR="$REPO/ios/device-test/validate-additive-source-census-log.py"
DEVICE_SPEC="$REPO/ios/device-test/specs/p21e1a-additive-census-device-v1.json"
COMMON_FLAGS=(
  -std=c++20
  -Wall
  -Wextra
  -Wpedantic
  -Wconversion
  -Wsign-conversion
  -Werror
  -I"$REPO/game"
  -isystem
  "$REPO/lib/Tempest/Engine/include"
  -isystem
  "$REPO/lib/ZenKit/include"
)

cd "$REPO"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$TEST_SOURCE" ]] || fail "missing additive census C++ contract test"
[[ -x "$VALIDATOR" ]] || fail "additive census validator is not executable"
[[ -f "$DEVICE_SPEC" ]] || fail "missing additive census device spec"

printf '\n### P2.1e1a diagnostics-OFF compile absence\n'
printf '#include "graphics/iosadditivesourcecensus.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ "${COMMON_FLAGS[@]}" -o "$RUNNER_TEMP/additive-off" -
if printf '%s\n' '#include "graphics/iosadditivesourcecensus.h"' \
    'int main() { IOSAdditiveSourceCensus value{}; return int(value.total); }' |
    xcrun clang++ -x c++ "${COMMON_FLAGS[@]}" \
      -o "$RUNNER_TEMP/additive-off-mutation" - \
      >"$RUNNER_TEMP/additive-off-mutation.log" 2>&1; then
  fail "diagnostics-OFF mutation exposed additive census state/symbols"
fi
if strings "$RUNNER_TEMP/additive-off" | grep -Fq 'RendererIOS additive source census'; then
  fail "diagnostics-OFF probe contains additive marker strings"
fi
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path
import re


diagnostics = "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS"
markers = (
    "RendererIOS additive source census:",
    "RendererIOS additive source census row:",
)
occurrences: list[tuple[Path, int, str]] = []

for path in sorted(Path("game").rglob("*")):
    if path.suffix not in (".h", ".hpp", ".cpp", ".mm"):
        continue
    stack: list[bool | None] = []
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
                raise SystemExit(f"FAIL: unmatched #else in {path}:{number}")
            if stack[-1] is not None:
                stack[-1] = not stack[-1]
            continue
        if directive.startswith("#elif"):
            if not stack:
                raise SystemExit(f"FAIL: unmatched #elif in {path}:{number}")
            if stack[-1] is not None:
                stack[-1] = False
            continue
        if directive.startswith("#endif"):
            if not stack:
                raise SystemExit(f"FAIL: unmatched #endif in {path}:{number}")
            stack.pop()
            continue
        for marker in markers:
            if marker in line:
                if True not in stack:
                    raise SystemExit(
                        f"FAIL: diagnostics-OFF product marker leak at {path}:{number}"
                    )
                occurrences.append((path, number, marker))
    if stack:
        raise SystemExit(f"FAIL: unterminated preprocessor conditional in {path}")

if [marker for _, _, marker in occurrences] != list(markers):
    rendered = ", ".join(f"{path}:{line}:{marker}" for path, line, marker in occurrences)
    raise SystemExit(
        "FAIL: exact diagnostics-only additive header/row marker set changed: " + rendered
    )
print("diagnostics-OFF product source marker oracle: PASS")
PY

printf '\n### P2.1e1a additive source census strict host contract\n'
xcrun clang++ "${COMMON_FLAGS[@]}" "$TEST_SOURCE" \
  -o "$RUNNER_TEMP/iosadditivesourcecensus"
"$RUNNER_TEMP/iosadditivesourcecensus"

printf '\n### P2.1e1a additive source census ASan\n'
xcrun clang++ "${COMMON_FLAGS[@]}" \
  -fsanitize=address -fno-omit-frame-pointer \
  "$TEST_SOURCE" -o "$RUNNER_TEMP/iosadditivesourcecensus-asan"
ASAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/iosadditivesourcecensus-asan"

printf '\n### P2.1e1a additive source census UBSan\n'
xcrun clang++ "${COMMON_FLAGS[@]}" \
  -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer \
  "$TEST_SOURCE" -o "$RUNNER_TEMP/iosadditivesourcecensus-ubsan"
UBSAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/iosadditivesourcecensus-ubsan"

printf '\n### P2.1e1a strict log/artifact/attestation mutation oracle\n'
PYTHONDONTWRITEBYTECODE=1 python3 "$VALIDATOR" self-test
PYTHONDONTWRITEBYTECODE=1 python3 - "$DEVICE_SPEC" <<'PY'
import importlib.util
import pathlib
import sys

validator_path = pathlib.Path(
    "ios/device-test/validate-additive-source-census-log.py"
).resolve()
specification = importlib.util.spec_from_file_location(
    "rios_additive_validator", validator_path
)
if specification is None or specification.loader is None:
    raise SystemExit("FAIL: cannot import additive validator")
module = importlib.util.module_from_spec(specification)
specification.loader.exec_module(module)
module.validate_device_spec(pathlib.Path(sys.argv[1]))
print("device spec parser: PASS")
PY

printf '\nP2.1e1a additive source census focused gate: PASS\n'
