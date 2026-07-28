#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

MODE="${1:-full}"
if (($# > 0)); then
  shift
fi
REQUESTED_PROFILES=()
REQUESTED_PROFILE_COUNT=0
case "$MODE" in
  quick)
    (($# == 0)) || {
      echo "usage: $0 [quick|full|contracts|profiles PROFILE...]" >&2
      exit 2
    }
    REQUESTED_PROFILES=(on)
    REQUESTED_PROFILE_COUNT=1
    ;;
  full)
    (($# == 0)) || {
      echo "usage: $0 [quick|full|contracts|profiles PROFILE...]" >&2
      exit 2
    }
    REQUESTED_PROFILES=(off on tile forward)
    REQUESTED_PROFILE_COUNT=4
    ;;
  contracts)
    (($# == 0)) || {
      echo "usage: $0 [quick|full|contracts|profiles PROFILE...]" >&2
      exit 2
    }
    ;;
  profiles)
    (($# > 0)) || {
      echo "usage: $0 profiles PROFILE..." >&2
      exit 2
    }
    for profile in "$@"; do
      case "$profile" in
        off|on|tile|forward) ;;
        *)
          echo "unknown verification profile: $profile" >&2
          exit 2
          ;;
      esac
      if ((REQUESTED_PROFILE_COUNT > 0)); then
        for existing in "${REQUESTED_PROFILES[@]}"; do
          if [[ "$existing" == "$profile" ]]; then
            echo "duplicate verification profile: $profile" >&2
            exit 2
          fi
        done
      fi
      REQUESTED_PROFILES+=("$profile")
      REQUESTED_PROFILE_COUNT=$((REQUESTED_PROFILE_COUNT + 1))
    done
    ;;
  *)
    echo "usage: $0 [quick|full|contracts|profiles PROFILE...]" >&2
    exit 2
    ;;
esac

wants_profile() {
  local expected="$1"
  local profile
  ((REQUESTED_PROFILE_COUNT > 0)) || return 1
  for profile in "${REQUESTED_PROFILES[@]}"; do
    [[ "$profile" == "$expected" ]] && return 0
  done
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="${OPENGOTHIC_REPO:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
BUILD_ROOT="${OPENGOTHIC_BUILD_ROOT:-$REPO/build/local-renderer-ios}"
CPUS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
TMP_GATE="$(mktemp -d "${TMPDIR:-/tmp}/rendererios-local-gates.XXXXXX")"

cleanup() {
  rm -rf -- "$TMP_GATE"
}
trap cleanup EXIT

fail() {
  printf 'LOCAL BUILD FAILED: %s\n' "$*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "ten skrypt wymaga macOS"
[ "$(git -C "$REPO" rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] ||
  fail "brak repo: $REPO"
INITIAL_STATUS="$TMP_GATE/initial-status"
FINAL_STATUS="$TMP_GATE/final-status"
git -C "$REPO" status --porcelain=v1 -z --untracked-files=all >"$INITIAL_STATUS"
if [[ "${OPENGOTHIC_VERIFY_ALLOW_DIRTY:-0}" != 1 && -s "$INITIAL_STATUS" ]]; then
  fail "parent ma tracked lub obce untracked pliki"
fi
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

cd "$REPO"

echo "### Fail-closed verification policy"
PYTHONDONTWRITEBYTECODE=1 python3 \
  scripts/classify_verification.py --validate-policy
PYTHONDONTWRITEBYTECODE=1 python3 \
  ios/tests/test_verification_classifier.py
PYTHONDONTWRITEBYTECODE=1 python3 \
  ios/tests/test_verification_router.py

echo "### P2.6c host-neutral feature policy"
scripts/verify_ios_feature_policy.command

echo "### Tempest verifier (2x)"
bash ios/patches/apply-patches.sh
bash ios/patches/apply-patches.sh

echo "### Neutral P2.1 scene boundary"
headers=(
  game/graphics/iosframeinput.h
  game/graphics/iosrenderworld.h
  game/graphics/iosscenesnapshot.h
)
sources=(
  game/graphics/iosframeinput.cpp
  game/graphics/iosrenderworld.cpp
  game/graphics/iosscenesnapshot.cpp
)
for file in "${headers[@]}" "${sources[@]}"; do
  [ -f "$file" ] || fail "brak pliku granicy P2.1: $file"
done
obsolete="$(
  find game -type f \( -name '*.h' -o -name '*.cpp' \) \
    -exec grep -nHF 'RendererIOS::FrameInput' {} + || true
)"
[ -z "$obsolete" ] || {
  printf '%s\n' "$obsolete"
  fail "obsolete RendererIOS::FrameInput pozostaje w kodzie produktu"
}
if grep -nE \
    'Tempest|WorldView|DrawCommands|Shaders|VectorImage|InventoryMenu|VideoWidget' \
    "${headers[@]}"; then
  fail "neutralne nagłówki P2.1 przeciekają typami legacy/transport/UI"
fi
for header in iosframeinput.h iosrenderworld.h iosscenesnapshot.h; do
  printf '#include "graphics/%s"\nint main() { return 0; }\n' "$header" |
    xcrun clang++ -x c++ -std=c++20 \
      -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
      -Igame -fsyntax-only -
done
for source in "${sources[@]}"; do
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only "$source"
done
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosscenecontract.cpp \
  game/graphics/iosframeinput.cpp \
  game/graphics/iosrenderworld.cpp \
  game/graphics/iosscenesnapshot.cpp \
  -o "$TMP_GATE/iosscenecontract"
codesign -f -s - "$TMP_GATE/iosscenecontract"
"$TMP_GATE/iosscenecontract"
[ -f game/graphics/iossceneconversion.h ]
[ -f game/graphics/iossceneconversion.cpp ]
[ -f ios/tests/iossceneconversion.cpp ]
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -Ilib/Tempest/Engine/include \
  ios/tests/iossceneconversion.cpp \
  game/graphics/iossceneconversion.cpp \
  -o "$TMP_GATE/iossceneconversion"
codesign -f -s - "$TMP_GATE/iossceneconversion"
"$TMP_GATE/iossceneconversion"
[ -f lib/Tempest/Tests/tests/metalapi_borrowed_handle_compile_test.cpp ]
xcrun clang++ -std=c++17 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Ilib/Tempest/Engine/include -fsyntax-only \
  lib/Tempest/Tests/tests/metalapi_borrowed_handle_compile_test.cpp

echo "### RendererIOS save-preview routing policy"
[ -f game/graphics/iossavepreviewpolicy.h ]
[ -f ios/tests/iossavepreviewpolicy.cpp ]
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iossavepreviewpolicy.cpp \
  -o "$TMP_GATE/iossavepreviewpolicy"
codesign -f -s - "$TMP_GATE/iossavepreviewpolicy"
"$TMP_GATE/iossavepreviewpolicy"
grep -Fq 'requiresGpuSavePreviewCapture()' game/graphics/iosmetalcontext.cpp
grep -Fq 'if(!renderer.requiresGpuSavePreviewCapture())' game/mainwindow.cpp
grep -Fq 'save-cpu-fastpath' game/graphics/iosmetalcontext.cpp
grep -Fq 'savePreviewRoute=' game/graphics/iosmetalcontext.cpp
grep -Fq 'route=cpu-placeholder' game/mainwindow.cpp
grep -Fq 'route=gpu-diagnostic' game/mainwindow.cpp
grep -Fq 'pixels[i*4u+3u] = 255u;' game/mainwindow.cpp
grep -Fq 'request-to-accepted-us=' game/mainwindow.cpp
grep -Fq 'serialize-us=' game/mainwindow.cpp
grep -Fq 'request-to-complete-us=' game/mainwindow.cpp
grep -Fq 'wait-idle-us=' game/graphics/iosmetalcontext.cpp
grep -Fq 'RendererIOS save preview diagnostic capture' game/graphics/iosmetalcontext.cpp
if grep -Fq 'RendererIOS save preview placeholder' \
    game/graphics/iosmetalcontext.cpp; then
  fail "obsolete RendererIOS save preview placeholder pozostaje w kodzie"
fi
[ "$(grep -Fc '!configuredSavePreviewNeedsGpuCapture() ||' game/graphics/iosmetalcontext.cpp)" -eq 1 ]
[ "$(grep -Fc 'impl->device.attachment(TextureFormat::RGBA8,dstW,dstH)' game/graphics/iosmetalcontext.cpp)" -eq 1 ]
[ "$(grep -Fc 'device.readPixels(savePreview)' game/graphics/iosmetalcontext.cpp)" -eq 1 ]
grep -Fq 'previewFenceErrorAfterTerminal()' game/graphics/iosmetalcontext.cpp

echo "### P2.1 native asset registry and source contracts"
[ -f game/graphics/iossceneassetregistry.h ]
[ -f game/graphics/iossceneassetregistry.cpp ]
[ -f ios/tests/iossceneassetregistry.cpp ]
printf '#include "graphics/iossceneassetregistry.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -isystem lib/Tempest/Engine/include -fsyntax-only -
xcrun clang++ -x c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include -fsyntax-only \
  game/graphics/iossceneassetregistry.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -isystem lib/Tempest/Engine/include \
  ios/tests/iossceneassetregistry.cpp \
  -o "$TMP_GATE/iossceneassetregistry"
codesign -f -s - "$TMP_GATE/iossceneassetregistry"
"$TMP_GATE/iossceneassetregistry"
[ -f game/graphics/iosscenesource.h ]
[ -f ios/tests/iosscenesourcecontract.cpp ]
if grep -Eq 'DrawCommands|DrawBuckets|cmdId|clusterId|std::function' \
    game/graphics/iosscenesource.h; then
  fail "granica source RendererIOS przecieka detalami legacy renderera"
fi
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  ios/tests/iosscenesourcecontract.cpp \
  game/graphics/bounds.cpp \
  -o "$TMP_GATE/iosscenesourcecontract"
codesign -f -s - "$TMP_GATE/iosscenesourcecontract"
"$TMP_GATE/iosscenesourcecontract"

echo "### P2.1 Landscape extractor contract"
[ -f game/graphics/iossceneextractorplan.h ]
[ -f game/graphics/iossceneextractor.h ]
[ -f game/graphics/iossceneextractor.cpp ]
[ -f ios/tests/iossceneextractorplan.cpp ]
printf '#include "graphics/iossceneextractorplan.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -x c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iossceneextractor.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  ios/tests/iossceneextractorplan.cpp \
  -o "$TMP_GATE/iossceneextractorplan"
codesign -f -s - "$TMP_GATE/iossceneextractorplan"
"$TMP_GATE/iossceneextractorplan"
if grep -Eq 'DrawCommands|DrawBuckets|cmdId|clusterId|std::function' \
    game/graphics/iossceneextractorplan.h \
    game/graphics/iossceneextractor.h; then
  fail "kontrakt extractora RendererIOS przecieka detalami legacy renderera"
fi

echo "### RendererIOS native GPU and offline Metal contracts"
[ -x ios/device-test/run-smoke-test.sh ]
grep -Fq 'the first presented frame must have exact offline shader totals' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'select_device_record()' ios/device-test/run-smoke-test.sh
grep -Fq 'attempt=%d result=retry' ios/device-test/run-smoke-test.sh
grep -Fq '((attempt < 5)) && sleep 1' ios/device-test/run-smoke-test.sh
grep -Fq 'OPENGOTHIC_IOS_DEVICE_SELECTION_TEST_FAIL_FIRST' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'device_selection_attempts=' ios/device-test/run-smoke-test.sh
grep -Fq 'device_selection_method=' ios/device-test/run-smoke-test.sh
# shellcheck disable=SC2016 # exact source literal, not a shell expansion
grep -Fq 'copy_private_evidence_path "$WORK/device-selection.log"' \
  ios/device-test/run-smoke-test.sh
grep -Fq 'd.get("interface") == "usb"' ios/device-test/run-smoke-test.sh
grep -Fq 'd.get("hardwareProperties", {}).get("udid") in usb_udids' \
  ios/device-test/run-smoke-test.sh
[ -f game/graphics/iosgpusceneplan.h ]
[ -f game/graphics/iosgpuscene.h ]
[ -f game/graphics/iosgpuscene.mm ]
[ -f game/graphics/ioslandscapeshaderabi.h ]
[ -f game/graphics/iosshadingprototypeshaderabi.h ]
[ -f game/graphics/iosshadingprototypepipeline.h ]
[ -f game/graphics/iosshadingprototypepipeline.cpp ]
[ -f game/graphics/iosshadingprototypepipeline.mm ]
[ -f game/graphics/iosshadingprototypepipelinenative.h ]
[ -f game/graphics/iosshadingprototypetileprobe.h ]
[ -f game/graphics/iosshadingprototypetileprobe.cpp ]
[ -f game/graphics/iosshadingprototypetileprobe.mm ]
[ -f game/graphics/iosshadingprototypeforwardpipeline.h ]
[ -f game/graphics/iosshadingprototypeforwardpipeline.cpp ]
[ -f game/graphics/iosshadingprototypeforwardpipeline.mm ]
[ -f game/graphics/iosshadingprototypeforwardpipelinenative.h ]
[ -f game/graphics/iosshadingprototypeforwardprobe.h ]
[ -f game/graphics/iosshadingprototypeforwardprobe.cpp ]
[ -f game/graphics/iosshadingprototypeforwardprobe.mm ]
[ -f game/graphics/iosmetalcapturesession.h ]
[ -f game/graphics/iosmetalcapturesession.mm ]
[ -f game/graphics/iosbuiltinshaderabi.h ]
[ -f game/graphics/iosinventoryshaderabi.h ]
[ -f game/graphics/iosbinkshaderabi.h ]
[ -f game/graphics/iosbinkselftest.h ]
[ -f game/graphics/iosgpubink.h ]
[ -f game/graphics/iosgpubink.mm ]
[ -f shader/ios-metal/landscape.metal ]
[ -f shader/ios-metal/bink.metal ]
[ -f shader/ios-metal/ui.metal ]
[ -f shader/ios-metal/inventory.metal ]
[ -f shader/ios-metal/shading-prototypes.metal ]
[ -f ios/tests/iosgpusceneplan.cpp ]
[ -f ios/tests/ioslandscapeshader.cpp ]
[ -f ios/tests/iosbuiltinshader.cpp ]
[ -f ios/tests/iosinventoryshader.cpp ]
[ -f ios/tests/iosshadingprototypeshader.cpp ]
[ -f ios/tests/iosshadingprototypepipeline.cpp ]
[ -f ios/tests/iosshadingprototypetileprobe.cpp ]
[ -x ios/device-test/validate-shading-prototype-tile-self-test-log.py ]
[ -f ios/tests/iosshadingprototypeforwardpipeline.cpp ]
[ -f ios/tests/iosshadingprototypeforwardprobe.cpp ]
[ -x ios/device-test/validate-shading-prototype-forward-self-test-log.py ]
[ -x ios/device-test/validate-shading-prototype-forward-gpudebug-trace.py ]
[ -f ios/tests/iosbinkshader.cpp ]
[ -f ios/tests/iosbinkselftest.cpp ]
printf '#include "graphics/iosgpusceneplan.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
printf '#include "graphics/iosgpuscene.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosgpusceneplan.cpp \
  -o "$TMP_GATE/iosgpusceneplan"
codesign -f -s - "$TMP_GATE/iosgpusceneplan"
"$TMP_GATE/iosgpusceneplan"
printf '#include "graphics/iosshadingprototypepipeline.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypepipeline.cpp \
  game/graphics/iosshadingprototypepipeline.cpp \
  -o "$TMP_GATE/iosshadingprototypepipeline"
codesign -f -s - "$TMP_GATE/iosshadingprototypepipeline"
"$TMP_GATE/iosshadingprototypepipeline"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypepipeline.cpp \
  game/graphics/iosshadingprototypepipeline.cpp \
  -o "$TMP_GATE/iosshadingprototypepipeline-sanitized"
codesign -f -s - "$TMP_GATE/iosshadingprototypepipeline-sanitized"
"$TMP_GATE/iosshadingprototypepipeline-sanitized"
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/iosshadingprototypepipeline.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -c game/graphics/iosshadingprototypepipeline.mm \
  -o "$TMP_GATE/iosshadingprototypepipeline.o"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -fsyntax-only ios/tests/iosshadingprototypepipeline.cpp
printf '#include "graphics/iosshadingprototypetileprobe.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypetileprobe.cpp \
  game/graphics/iosshadingprototypetileprobe.cpp \
  -o "$TMP_GATE/iosshadingprototypetileprobe"
codesign -f -s - "$TMP_GATE/iosshadingprototypetileprobe"
"$TMP_GATE/iosshadingprototypetileprobe"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypetileprobe.cpp \
  game/graphics/iosshadingprototypetileprobe.cpp \
  -o "$TMP_GATE/iosshadingprototypetileprobe-sanitized"
codesign -f -s - "$TMP_GATE/iosshadingprototypetileprobe-sanitized"
"$TMP_GATE/iosshadingprototypetileprobe-sanitized"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -fsyntax-only ios/tests/iosshadingprototypetileprobe.cpp
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/iosshadingprototypetileprobe.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -c game/graphics/iosshadingprototypetileprobe.mm \
  -o "$TMP_GATE/iosshadingprototypetileprobe.o"

echo "### P2.5c1b0+c1b1 Forward factory/report host and iPhoneOS gates"
printf '#include "graphics/iosshadingprototypeforwardpipeline.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeforwardpipeline.cpp \
  game/graphics/iosshadingprototypeforwardpipeline.cpp \
  -o "$TMP_GATE/iosshadingprototypeforwardpipeline"
codesign -f -s - "$TMP_GATE/iosshadingprototypeforwardpipeline"
"$TMP_GATE/iosshadingprototypeforwardpipeline"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypeforwardpipeline.cpp \
  game/graphics/iosshadingprototypeforwardpipeline.cpp \
  -o "$TMP_GATE/iosshadingprototypeforwardpipeline-sanitized"
codesign -f -s - "$TMP_GATE/iosshadingprototypeforwardpipeline-sanitized"
"$TMP_GATE/iosshadingprototypeforwardpipeline-sanitized"
printf '#include "graphics/iosshadingprototypeforwardprobe.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeforwardprobe.cpp \
  game/graphics/iosshadingprototypeforwardprobe.cpp \
  -o "$TMP_GATE/iosshadingprototypeforwardprobe"
codesign -f -s - "$TMP_GATE/iosshadingprototypeforwardprobe"
"$TMP_GATE/iosshadingprototypeforwardprobe"
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypeforwardprobe.cpp \
  game/graphics/iosshadingprototypeforwardprobe.cpp \
  -o "$TMP_GATE/iosshadingprototypeforwardprobe-sanitized"
codesign -f -s - "$TMP_GATE/iosshadingprototypeforwardprobe-sanitized"
"$TMP_GATE/iosshadingprototypeforwardprobe-sanitized"
for source in \
    game/graphics/iosshadingprototypeforwardpipeline.cpp \
    game/graphics/iosshadingprototypeforwardprobe.cpp \
    ios/tests/iosshadingprototypeforwardpipeline.cpp \
    ios/tests/iosshadingprototypeforwardprobe.cpp; do
  role=report
  [[ "$source" != ios/tests/* ]] || role="test"
  object="$TMP_GATE/$role-$(basename "${source%.cpp}")-iphoneos.o"
  xcrun clang++ -x c++ -std=c++20 \
    -target arm64-apple-ios16.4 \
    -isysroot "$SDK" \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame \
    -c "$source" -o "$object"
  [ -s "$object" ] ||
    fail "P2.5c1b0+c1b1 AppleClang nie utworzyl obiektu: $source"
done
for source in \
    game/graphics/iosshadingprototypeforwardpipeline.mm \
    game/graphics/iosshadingprototypeforwardprobe.mm; do
  object="$TMP_GATE/native-$(basename "${source%.mm}")-iphoneos.o"
  xcrun clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 \
    -isysroot "$SDK" \
    -fno-objc-arc \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
    -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame \
    -isystem lib/Tempest/Engine/include \
    -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
    -fsyntax-only "$source"
  xcrun clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 \
    -isysroot "$SDK" \
    -fno-objc-arc \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
    -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame \
    -isystem lib/Tempest/Engine/include \
    -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
    -c "$source" -o "$object"
  [ -s "$object" ] ||
    fail "P2.5c1b0+c1b1 AppleClang nie utworzyl obiektu: $source"
done
for component in pipeline probe; do
  xcrun clang++ -target arm64-apple-ios16.4 -isysroot "$SDK" -r \
    "$TMP_GATE/report-iosshadingprototypeforward${component}-iphoneos.o" \
    "$TMP_GATE/native-iosshadingprototypeforward${component}-iphoneos.o" \
    -o "$TMP_GATE/iosshadingprototypeforward${component}-link.o"
  [ -s "$TMP_GATE/iosshadingprototypeforward${component}-link.o" ] ||
    fail "P2.5c1b0+c1b1 relocatable iPhoneOS link nie utworzyl: $component"
done
for source in \
    game/graphics/iosmetalcapturesession.mm \
    game/graphics/iosmetalresourceallocator.mm \
    game/graphics/iosmetalresourceclearpassprobe.mm \
    game/graphics/iosshadingprototypepipeline.mm \
    game/graphics/iosshadingprototypetileprobe.mm; do
  object="$TMP_GATE/$(basename "${source%.mm}")-tile.o"
  xcrun clang++ -x objective-c++ -std=c++20 \
    -target arm64-apple-ios16.4 \
    -isysroot "$SDK" \
    -fno-objc-arc \
    -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST=1 \
    -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame \
    -isystem lib/Tempest/Engine/include \
    -isystem lib/Tempest/Engine/thirdparty/metal-cpp \
    -c "$source" -o "$object"
  [ -s "$object" ] ||
    fail "P2.5b2a1 AppleClang nie utworzyl obiektu: $source"
done
PYTHONDONTWRITEBYTECODE=1 \
  python3 ios/device-test/validate-shading-prototype-tile-self-test-log.py \
    --self-test
PYTHONPYCACHEPREFIX="$TMP_GATE/python-cache" \
  python3 -m py_compile \
    ios/device-test/validate-shading-prototype-tile-self-test-log.py
/bin/bash -n ios/device-test/run-smoke-test.sh
PYTHONDONTWRITEBYTECODE=1 /bin/bash \
  ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test --self-test
for conflict in \
    '--require-bink-self-test' \
    '--require-resource-allocator-self-test' \
    '--require-clear-only-pass-self-test'; do
  if /bin/bash ios/device-test/run-smoke-test.sh \
      --require-shading-prototype-tile-self-test \
      "$conflict" --self-test >/dev/null 2>&1; then
    fail "P2.5b2a1 harness zaakceptowal konflikt: $conflict"
  fi
done
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test \
    --pipeline-archive-test-mode cold --self-test >/dev/null 2>&1; then
  fail "P2.5b2a1 harness zaakceptowal konflikt archive"
fi
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-tile-self-test \
    --expected-fault post-submit-suboptimal \
    --self-test >/dev/null 2>&1; then
  fail "P2.5b2a1 harness zaakceptowal fault"
fi
PYTHONDONTWRITEBYTECODE=1 \
  python3 ios/device-test/validate-shading-prototype-forward-self-test-log.py \
    --self-test
PYTHONDONTWRITEBYTECODE=1 \
  python3 ios/device-test/validate-shading-prototype-forward-gpudebug-trace.py \
    --self-test
PYTHONPYCACHEPREFIX="$TMP_GATE/python-cache" \
  python3 -m py_compile \
    ios/device-test/validate-shading-prototype-forward-self-test-log.py \
    ios/device-test/validate-shading-prototype-forward-gpudebug-trace.py
PYTHONDONTWRITEBYTECODE=1 /bin/bash \
  ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-forward-self-test --self-test
for conflict in \
    '--require-bink-self-test' \
    '--require-resource-allocator-self-test' \
    '--require-clear-only-pass-self-test' \
    '--require-shading-prototype-tile-self-test'; do
  if /bin/bash ios/device-test/run-smoke-test.sh \
      --require-shading-prototype-forward-self-test \
      "$conflict" --self-test >/dev/null 2>&1; then
    fail "P2.5c1b1 Forward harness zaakceptowal konflikt: $conflict"
  fi
done
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-forward-self-test \
    --pipeline-archive-test-mode cold --self-test >/dev/null 2>&1; then
  fail "P2.5c1b1 Forward harness zaakceptowal konflikt archive"
fi
if /bin/bash ios/device-test/run-smoke-test.sh \
    --require-shading-prototype-forward-self-test \
    --expected-fault post-submit-suboptimal \
    --self-test >/dev/null 2>&1; then
  fail "P2.5c1b1 Forward harness zaakceptowal fault"
fi
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iosgpuscene.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/iosgpubink.mm
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -fsyntax-only game/graphics/rendereriosplatform.mm
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/ioslandscapeshader.cpp \
  -o "$TMP_GATE/ioslandscapeshader"
codesign -f -s - "$TMP_GATE/ioslandscapeshader"
"$TMP_GATE/ioslandscapeshader" shader/ios-metal/landscape.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosbinkshader.cpp \
  -o "$TMP_GATE/iosbinkshader"
codesign -f -s - "$TMP_GATE/iosbinkshader"
"$TMP_GATE/iosbinkshader" shader/ios-metal/bink.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosbuiltinshader.cpp \
  -o "$TMP_GATE/iosbuiltinshader"
codesign -f -s - "$TMP_GATE/iosbuiltinshader"
"$TMP_GATE/iosbuiltinshader" shader/ios-metal/ui.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosinventoryshader.cpp \
  -o "$TMP_GATE/iosinventoryshader"
codesign -f -s - "$TMP_GATE/iosinventoryshader"
"$TMP_GATE/iosinventoryshader" shader/ios-metal/inventory.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeshader.cpp \
  -o "$TMP_GATE/iosshadingprototypeshader"
codesign -f -s - "$TMP_GATE/iosshadingprototypeshader"
"$TMP_GATE/iosshadingprototypeshader" \
  shader/ios-metal/shading-prototypes.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosshadingprototypeshader.cpp \
  -o "$TMP_GATE/iosshadingprototypeshader-sanitized"
codesign -f -s - "$TMP_GATE/iosshadingprototypeshader-sanitized"
"$TMP_GATE/iosshadingprototypeshader-sanitized" \
  shader/ios-metal/shading-prototypes.metal
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosbinkselftest.cpp \
  -o "$TMP_GATE/iosbinkselftest"
codesign -f -s - "$TMP_GATE/iosbinkselftest"
"$TMP_GATE/iosbinkselftest"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -c shader/ios-metal/landscape.metal \
  -o "$TMP_GATE/ios-landscape.air"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -c shader/ios-metal/bink.metal \
  -o "$TMP_GATE/ios-bink.air"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -c shader/ios-metal/ui.metal \
  -o "$TMP_GATE/ios-ui.air"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -c shader/ios-metal/inventory.metal \
  -o "$TMP_GATE/ios-inventory.air"
xcrun --sdk iphoneos metal \
  -target air64-apple-ios16.4 \
  -Wall -Wextra -Werror \
  -c shader/ios-metal/shading-prototypes.metal \
  -o "$TMP_GATE/ios-shading-prototypes.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$TMP_GATE/ios-landscape.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$TMP_GATE/ios-bink.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$TMP_GATE/ios-ui.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$TMP_GATE/ios-inventory.air"
LC_ALL=C grep -aFq \
  'apple-ios16.4.0' \
  "$TMP_GATE/ios-shading-prototypes.air"
xcrun --sdk iphoneos metallib \
  "$TMP_GATE/ios-landscape.air" \
  "$TMP_GATE/ios-bink.air" \
  "$TMP_GATE/ios-ui.air" \
  "$TMP_GATE/ios-inventory.air" \
  "$TMP_GATE/ios-shading-prototypes.air" \
  -o "$TMP_GATE/RendererIOS.metallib"
for function in \
    riosLandscapeVertex riosLandscapeFragment \
    riosBinkVertex riosBinkFragment \
    riosUiColorVertex riosUiColorFragment \
    riosUiTextureVertex riosUiTextureFragment \
    riosInventoryVertex riosInventoryFragment \
    riosShadingPrototypeVertex \
    riosTileDeferredMaterialFragment \
    riosTileDeferredLighting \
    riosForwardPlusBuildLightList \
    riosForwardPlusFragment; do
  LC_ALL=C grep -aFq "$function" \
    "$TMP_GATE/RendererIOS.metallib"
done
RIOS_EXPORTS="$(xcrun --sdk iphoneos metal-nm \
  "$TMP_GATE/RendererIOS.metallib" |
  awk '$2 == "T" { print $3 }' | LC_ALL=C sort)"
EXPECTED_RIOS_EXPORTS="$(printf '%s\n' \
  riosLandscapeVertex riosLandscapeFragment \
  riosBinkVertex riosBinkFragment \
  riosUiColorVertex riosUiColorFragment \
  riosUiTextureVertex riosUiTextureFragment \
  riosInventoryVertex riosInventoryFragment \
  riosShadingPrototypeVertex \
  riosTileDeferredMaterialFragment \
  riosTileDeferredLighting \
  riosForwardPlusBuildLightList \
  riosForwardPlusFragment | LC_ALL=C sort)"
[ "$RIOS_EXPORTS" = "$EXPECTED_RIOS_EXPORTS" ] ||
  fail "RendererIOS.metallib nie ma exact 15-export ABI5"
[ "$(printf '%s\n' "$RIOS_EXPORTS" | wc -l | tr -d ' ')" -eq 15 ] ||
  fail "RendererIOS.metallib export count nie wynosi 15"
CANONICAL_RENDERER_IOS_METALLIB_SHA256="$(
  shasum -a 256 "$TMP_GATE/RendererIOS.metallib" | awk '{print $1}'
)"
[[ "$CANONICAL_RENDERER_IOS_METALLIB_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "canonical RendererIOS.metallib nie ma poprawnego SHA-256"
if grep -Eq \
    'newLibraryWithSource|compileSource|MTLCompileOptions|newCommandQueue|commandBufferWith|presentDrawable' \
    shader/ios-metal/shading-prototypes.metal \
    game/graphics/iosshadingprototypeshaderabi.h; then
  fail "P2.5b0 offline ABI zawiera runtime compilation lub command ownership"
fi
if rg -n \
    'riosForwardPlusBuildLightList|riosForwardPlusFragment' \
    game --glob '!iosshadingprototypeshaderabi.h'; then
  fail "P2.5b1 podpina compile-only Forward+ export do produkcji"
fi
if grep -Eq \
    'ForwardLightListFunction|ForwardFragmentFunction|riosForwardPlus|FunctionNames\[' \
    game/graphics/iosshadingprototypepipeline.h \
    game/graphics/iosshadingprototypepipeline.cpp \
    game/graphics/iosshadingprototypepipeline.mm; then
  fail "P2.5b1 Tile-only factory odwoluje sie do reserved Forward+ ABI"
fi
P25B2_FACTORY_CALLERS="$(
  rg -n 'iosCreateShadingPrototypePipeline' game \
    --glob '!iosshadingprototypepipeline.h' \
    --glob '!iosshadingprototypepipeline.mm' || true
)"
[ "$(printf '%s\n' "$P25B2_FACTORY_CALLERS" |
    grep -c '^game/graphics/iosmetalcontext\.cpp:' || true)" -eq 1 ] ||
  fail "P2.5b2a1 factory nie ma exact jednego opt-in context callera"
[ "$(printf '%s\n' "$P25B2_FACTORY_CALLERS" |
    grep -c . || true)" -eq 1 ] ||
  fail "P2.5b2a1 factory ma caller poza IOSMetalContext"
P25B2_ENCODE_CALLERS="$(
  rg -n 'iosEncodeShadingPrototypeTileProbe' game \
    --glob '!iosshadingprototypetileprobe.h' \
    --glob '!iosshadingprototypetileprobe.mm' || true
)"
[ "$(printf '%s\n' "$P25B2_ENCODE_CALLERS" |
    grep -c '^game/graphics/iosmetalcontext\.cpp:' || true)" -eq 1 ] ||
  fail "P2.5b2a1 encode nie ma exact jednego opt-in context callera"
[ "$(printf '%s\n' "$P25B2_ENCODE_CALLERS" |
    grep -c . || true)" -eq 1 ] ||
  fail "P2.5b2a1 encode ma caller poza IOSMetalContext"
P25C1_FORWARD_FACTORY_CALLERS="$(
  rg -n 'iosCreateShadingPrototypeForwardPipeline' game \
    --glob '!iosshadingprototypeforwardpipeline.h' \
    --glob '!iosshadingprototypeforwardpipeline.mm' || true
)"
[ "$(printf '%s\n' "$P25C1_FORWARD_FACTORY_CALLERS" |
    grep -c '^game/graphics/iosmetalcontext\.cpp:' || true)" -eq 1 ] ||
  fail "P2.5c1b1 Forward factory nie ma exact jednego context callera"
[ "$(printf '%s\n' "$P25C1_FORWARD_FACTORY_CALLERS" |
    grep -c . || true)" -eq 1 ] ||
  fail "P2.5c1b1 Forward factory ma caller poza IOSMetalContext"
P25C1_FORWARD_ENCODE_CALLERS="$(
  rg -n 'iosEncodeShadingPrototypeForwardProbe' game \
    --glob '!iosshadingprototypeforwardprobe.h' \
    --glob '!iosshadingprototypeforwardprobe.mm' || true
)"
[ "$(printf '%s\n' "$P25C1_FORWARD_ENCODE_CALLERS" |
    grep -c '^game/graphics/iosmetalcontext\.cpp:' || true)" -eq 1 ] ||
  fail "P2.5c1b1 Forward encode nie ma exact jednego context callera"
[ "$(printf '%s\n' "$P25C1_FORWARD_ENCODE_CALLERS" |
    grep -c . || true)" -eq 1 ] ||
  fail "P2.5c1b1 Forward encode ma caller poza IOSMetalContext"
HOST_NEUTRAL_METAL_LEAK_RE='#import|<Metal/|@interface|id[[:space:]]*<MTL|__OBJC__|(^|[^[:alnum:]_])MTL([A-Z][A-Za-z0-9_]*|::[A-Z][A-Za-z0-9_:]*)'
for mutation in \
    'MTLDevice* device' \
    'MTLSize grid' \
    'using D = MTLDevice;' \
    'void f(MTLSize);' \
    'sizeof(MTLSize)' \
    'std::optional<MTLSize>' \
    'MTLSize{}' \
    'MTLSize::Make()' \
    'MTL::Device* device' \
    'id <MTLDevice> device'; do
  printf '%s\n' "$mutation" | grep -Eq "$HOST_NEUTRAL_METAL_LEAK_RE" ||
    fail "host-neutral Metal denylist nie wykryl synthetic mutation: $mutation"
done
for neutral_name in \
    ForbiddenMTLFence \
    helperMTLFenceUses \
    callerMTLFenceUses \
    IOSMetalResourceTexture; do
  if printf '%s\n' "$neutral_name" |
      grep -Eq "$HOST_NEUTRAL_METAL_LEAK_RE"; then
    fail "host-neutral Metal denylist odrzucil neutralna nazwe: $neutral_name"
  fi
done
if grep -Eq "$HOST_NEUTRAL_METAL_LEAK_RE" \
    game/graphics/iosshadingprototypeforwardpipeline.h \
    game/graphics/iosshadingprototypeforwardpipeline.cpp \
    game/graphics/iosshadingprototypeforwardprobe.h \
    game/graphics/iosshadingprototypeforwardprobe.cpp; then
  fail "P2.5c1b0+c1b1 Forward host report/validator przecieka Objective-C lub Metal"
fi
if grep -Eq \
    'newCommandQueue|commandBufferWith|newCommandBuffer|nextDrawable|presentDrawable|commit\]|enqueue\]|waitUntilCompleted|waitIdle|readPixels|newLibraryWithSource|newDefaultLibrary|MTLCompileOptions|MTLCapture|MetalFX' \
    game/graphics/iosshadingprototypeforwardpipeline.mm \
    game/graphics/iosshadingprototypeforwardprobe.mm; then
  fail "P2.5c1b0+c1b1 Forward helper przejal queue/submit/present/capture/source ownership"
fi
[ "$(grep -Fc 'Tempest::MetalApi::withActiveCommandBuffer(' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'computeCommandEncoder' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'renderCommandEncoderWithDescriptor:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'dispatchThreads:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'setVertexBytes:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'setFragmentBuffer:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'setComputePipelineState:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'setRenderPipelineState:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 2 ]
[ "$(grep -Fc 'drawPrimitives:' \
    game/graphics/iosshadingprototypeforwardprobe.mm)" -eq 2 ]
if grep -Eq "$HOST_NEUTRAL_METAL_LEAK_RE" \
    game/graphics/iosshadingprototypepipeline.h \
    game/graphics/iosshadingprototypepipeline.cpp; then
  fail "P2.5b1 host-neutral contract przecieka Objective-C lub Metal"
fi
if grep -Eq \
    'MTLCreateSystemDefaultDevice|newCommandQueue|MTLCommandQueue|MTLCommandBuffer|newCommandBuffer|commandBufferWith|commandBuffer\]|CommandEncoder|setRenderPipelineState|drawPrimitives|drawIndexedPrimitives|dispatchThreadgroups|dispatchThreads|presentDrawable|commit\]|enqueue\]|waitUntilCompleted|newLibraryWithSource|newDefaultLibrary|MTLCompileOptions|newComputePipelineState|MTLComputePipeline|newBufferWith|newTextureWith|newHeap|makeAliasable|MTLBinaryArchive|addRenderPipelineFunctions|serializeToURL|MetalFX' \
    game/graphics/iosshadingprototypepipeline.mm; then
  fail "P2.5b1 factory posiada runtime work/resource/source/archive ownership"
fi
grep -Fq 'Tempest::MetalApi::borrowDevice(owner)' \
  game/graphics/iosshadingprototypepipeline.mm
grep -Fq 'supportsFamily:MTLGPUFamilyApple4' \
  game/graphics/iosshadingprototypepipeline.mm
grep -Fq 'newLibraryWithURL:libraryUrl error:&libraryError' \
  game/graphics/iosshadingprototypepipeline.mm
grep -Fq 'newFunctionWithName:(NSString*)materialName.get()' \
  game/graphics/iosshadingprototypepipeline.mm
[ "$(grep -Fc 'setConstantValue:&alphaTest' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 2 ]
[ "$(grep -Fc 'alphaTest = false;' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 1 ]
[ "$(grep -Fc 'alphaTest = true;' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 1 ]
[ "$(grep -Fc 'constantValues:' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 2 ]
grep -Fq 'MTLPipelineOptionBindingInfo' \
  game/graphics/iosshadingprototypepipeline.mm
[ "$(grep -Fc \
    'newRenderPipelineStateWithDescriptor:descriptor' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 1 ]
[ "$(grep -Fc \
    'newRenderPipelineStateWithTileDescriptor:descriptor' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 1 ]
[ "$(grep -Fc 'descriptor.binaryArchives = nil;' \
    game/graphics/iosshadingprototypepipeline.mm)" -eq 2 ]
if rg -n 'descriptor\.binaryArchives[[:space:]]+=[[:space:]]+' \
    game/graphics/iosshadingprototypepipeline.mm |
    grep -Fv 'descriptor.binaryArchives = nil;'; then
  fail "P2.5b1 factory dolacza mutowalny pipeline archive"
fi
if grep -Eq "$HOST_NEUTRAL_METAL_LEAK_RE" \
    game/graphics/iosshadingprototypetileprobe.h \
    game/graphics/iosshadingprototypetileprobe.cpp; then
  fail "P2.5b2a0 host report przecieka Objective-C lub Metal"
fi
P25B2_RUNTIME_DENY='Forward|riosForward|newLibraryWithSource|newDefaultLibrary|MTLCompileOptions|newCommandQueue|commandBufferWith|newCommandBuffer|commandBuffer[[:space:]]*(\(|\])|newBufferWith|newTextureWith|newHeap|newFence|MTLFence|makeAliasable|MTLCapture|newComputePipelineState|computeCommandEncoder|blitCommandEncoder|nextDrawable|presentDrawable|readPixels|(^|[^[:alnum:]_])submit[[:space:]]*\(|commit\]|enqueue\]|waitIdle|[.]wait[[:space:]]*\(|waitUntilCompleted|addCompletedHandler|MTLBinaryArchive|addRenderPipelineFunctions|serializeToURL|MetalFX'
for fixture in \
    'device.submit(command,fence)' \
    '[queue commandBuffer]' \
    'queue.commandBuffer()' \
    '[command commit]' \
    '[command enqueue]' \
    'device.waitIdle()' \
    'fence.wait()' \
    '[command addCompletedHandler:handler]'; do
  printf '%s\n' "$fixture" |
    grep -Eq "$P25B2_RUNTIME_DENY"
done
if grep -Eq "$P25B2_RUNTIME_DENY" \
    game/graphics/iosshadingprototypetileprobe.h \
    game/graphics/iosshadingprototypetileprobe.cpp \
    game/graphics/iosshadingprototypetileprobe.mm \
    game/graphics/iosshadingprototypepipelinenative.h; then
  fail "P2.5b2a0 posiada forbidden runtime work albo referencje Forward"
fi
[ "$(grep -Fc 'Tempest::MetalApi::withActiveCommandBuffer(' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'renderCommandEncoderWithDescriptor:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'setVertexBytes:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'setRenderPipelineState:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 3 ]
[ "$(grep -Fc 'drawPrimitives:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 2 ]
[ "$(grep -Fc 'dispatchThreadsPerTile:' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1 ]
grep -Fq 'MTLClearColorMake(0.0,0.0,0.0,0.0)' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'descriptor.get().imageblockSampleLength =' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'descriptor.get().threadgroupMemoryLength =' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'descriptor.get().tileWidth =' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'descriptor.get().tileHeight =' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'report.materialTextures = 0u;' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'static_assert(sizeof(Vertices)==VertexBytes);' \
  game/graphics/iosshadingprototypetileprobe.mm
grep -Fq 'MaximumEndAttempts = 2u;' \
  game/graphics/iosshadingprototypetileprobe.mm
[ "$(grep -Fc '(void)attemptEnd();' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1 ]
[ "$(grep -Fc 'std::terminate();' \
    game/graphics/iosshadingprototypetileprobe.mm)" -eq 1 ]
grep -Fq 'static_assert(Mutators.size()==52u);' \
  ios/tests/iosshadingprototypetileprobe.cpp
grep -Fq 'static_assert(sizeof(Report)==172u);' \
  ios/tests/iosshadingprototypetileprobe.cpp
grep -Fq 'static_assert(offsetof(Report,operations)==168u);' \
  ios/tests/iosshadingprototypetileprobe.cpp
python3 - <<'PY'
from pathlib import Path

source = Path("game/graphics/iosshadingprototypepipeline.mm").read_text()
factory = source.split(
    "IOSShadingPrototypePipeline iosCreateShadingPrototypePipeline(", 1
)[1]

for token, count in (
    ("@try {", 1),
    ("@catch(NSException* exception)", 1),
    ("\n    try {", 1),
    ("catch(...) {", 1),
):
    if factory.count(token) != count:
        raise SystemExit(f"P2.5b1 exception fail-closed token mismatch: {token}")

cpp_catch = factory.split("catch(...) {", 1)[1].split("}", 1)[0]
objc_catch = factory.split("@catch(NSException* exception)", 1)[1]
for body, kind in ((cpp_catch, "C++"), (objc_catch, "Objective-C")):
    if "IOSShadingPrototypePipelineStatus::InternalFailure" not in body:
        raise SystemExit(f"P2.5b1 {kind} exception is not fail-closed")

native_bridge = source.split(
    "bool IOSShadingPrototypePipelineNativeAccess::borrow(", 1
)[1].split(
    "IOSShadingPrototypePipeline::IOSShadingPrototypePipeline()", 1
)[0]
for token, count in (
    ("@try {", 1),
    ("@catch(NSException*)", 1),
):
    if native_bridge.count(token) != count:
        raise SystemExit(f"P2.5b2a0 native bridge exception token mismatch: {token}")
native_bridge_catch = native_bridge.split("@catch(NSException*)", 1)[1]
for token in ("view = {};", "return false;"):
    if token not in native_bridge_catch:
        raise SystemExit(
            f"P2.5b2a0 native bridge exception is not fail-closed: {token}"
        )

material = source.split(
    "NativePipelineBuild buildMaterialPipeline(", 1
)[1].split("NativePipelineBuild buildLightingPipeline(", 1)[0]
lighting = source.split(
    "NativePipelineBuild buildLightingPipeline(", 1
)[1].split("IOSShadingPrototypePipelineStatus statusFor(", 1)[0]

for token in (
    "MTLPixelFormatRGBA8Unorm",
    "MTLColorWriteMaskAll",
    "blendingEnabled = NO",
    "MTLPixelFormatInvalid",
    "rasterSampleCount = NSUInteger(1u)",
    "MTLPrimitiveTopologyClassTriangle",
    "alphaToCoverageEnabled = NO",
    "alphaToOneEnabled = NO",
    "descriptor.binaryArchives = nil",
    "MTLPipelineOptionBindingInfo",
):
    if token not in material:
        raise SystemExit(f"P2.5b1 material descriptor is not hardened: {token}")
for token in (
    "MTLPixelFormatRGBA8Unorm",
    "MTLPixelFormatInvalid",
    "rasterSampleCount = NSUInteger(1u)",
    "threadgroupSizeMatchesTileSize = YES",
    "descriptor.binaryArchives = nil",
    "MTLPipelineOptionBindingInfo",
):
    if token not in lighting:
        raise SystemExit(f"P2.5b1 tile descriptor is not hardened: {token}")
PY
grep -Fq '#include "iosmetalcapturesession.h"' \
  game/graphics/iosmetalresourceclearpassprobe.h
grep -Fq 'IOSMetalCaptureSession session;' \
  game/graphics/iosmetalresourceclearpassprobe.h
grep -Fq 'return session.start(' \
  game/graphics/iosmetalresourceclearpassprobe.mm
grep -Fq 'return session.stopAndInspect(artifact,reason);' \
  game/graphics/iosmetalresourceclearpassprobe.mm
grep -Fq 'session.cancel();' \
  game/graphics/iosmetalresourceclearpassprobe.mm
grep -Fq 'return session.active();' \
  game/graphics/iosmetalresourceclearpassprobe.mm
grep -Fq 'Tempest::MetalApi::borrowDevice(device)' \
  game/graphics/iosmetalcapturesession.mm
grep -Fq 'MTLCaptureDestinationGPUTraceDocument' \
  game/graphics/iosmetalcapturesession.mm
grep -Fq 'iosMetalNormalizeAndInspectCaptureArtifact(' \
  game/graphics/iosmetalcapturesession.mm
if grep -Eq \
    'newCommandQueue|MTLCommandQueue|commandBufferWith|newCommandBuffer|nextDrawable|presentDrawable|newLibraryWithSource|MTLCompileOptions|MetalFX' \
    game/graphics/iosmetalcapturesession.h \
    game/graphics/iosmetalcapturesession.mm; then
  fail "P2.5b2a1 common capture przejal command/present/source ownership"
fi
grep -Fq \
  'defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)' \
  game/graphics/iosmetalcapturesession.h
grep -Fq \
  'defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)' \
  game/graphics/iosmetalcapturesession.mm
grep -Fq \
  'defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)' \
  game/graphics/iosmetalcapturesession.h
grep -Fq \
  'defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST)' \
  game/graphics/iosmetalcapturesession.mm
python3 - <<'PY'
from pathlib import Path
import runpy

context = Path("game/graphics/iosmetalcontext.cpp").read_text()
cmake = Path("CMakeLists.txt").read_text()
harness = Path("ios/device-test/run-smoke-test.sh").read_text()
validator_path = (
    "ios/device-test/validate-shading-prototype-tile-self-test-log.py"
)
validator = Path(validator_path).read_text()
module = runpy.run_path(validator_path)

markers = {
    "ARMED": (
        "RendererIOS shading prototype tile self-test: ARMED "
        "case=tile-prototype-v1 contract=1 metallib-abi=5 minimum-apple=4 "
        "output=4x4 rgba8-private=1"
    ),
    "FACTORY_READY": (
        "RendererIOS shading prototype tile self-test: FACTORY READY "
        "case=tile-prototype-v1 pipelines=3 forward=0 runtime-delta=0 "
        "builtin-delta=0 archive-delta=0"
    ),
    "ENCODED": (
        "RendererIOS shading prototype tile self-test: ENCODED "
        "case=tile-prototype-v1 pass=1 encoder=1 draws=2 opaque=1 alpha=1 "
        "tdispatch=1 vb=168 output=1 mat=0 ib=4 clear-a=0 tgmem=0 size=16 "
        "dispatch=16x16x1 order=opaque,alpha,tile drawable=0 present=0"
    ),
    "SUBMITTED": (
        "RendererIOS shading prototype tile self-test: SUBMITTED "
        "case=tile-prototype-v1 command-buffers=1 submits=1"
    ),
    "PASS": (
        "RendererIOS shading prototype tile self-test: PASS "
        "case=tile-prototype-v1 terminal=completed created=1 live=0 "
        "released=1 wait-idle=0 runtime-delta=0 builtin-delta=0 "
        "archive-delta=0"
    ),
    "UNSUPPORTED": (
        "RendererIOS shading prototype tile self-test: UNSUPPORTED "
        "case=tile-prototype-v1 reason=apple4-required side-effects=0"
    ),
}
if tuple(len(value.encode()) for value in markers.values()) != (
    143, 152, 245, 106, 180, 118
):
    raise SystemExit("P2.5b2a1 marker byte budget changed")
marker_scope = context.split(
    "constexpr char RendererIOSShadingPrototypeTileSelfTestArmed[]", 1
)[1].split("\n#endif", 1)[0]
for name, marker in markers.items():
    if marker_scope.count(marker) != 1:
        raise SystemExit(f"P2.5b2a1 context marker is not exact: {name}")
    if module.get(name) != marker:
        raise SystemExit(f"P2.5b2a1 validator marker mismatch: {name}")
    if harness.count(marker) != 1:
        raise SystemExit(f"P2.5b2a1 harness marker mismatch: {name}")
if context.count(
    '"\\x01RendererIOS shading prototype tile capture: ACQUIRED"'
) != 1:
    raise SystemExit("P2.5b2a1 dynamic ACQUIRED marker is not exact")
if "RendererIOS-tile-prototype-v1.gputrace" not in context:
    raise SystemExit("P2.5b2a1 capture basename is not frozen")

reasons = (
    "plan-contract-mismatch",
    "snapshot-unavailable",
    "factory-contract-mismatch",
    "factory-counter-mismatch",
    "unsupported-side-effect-mismatch",
    "output-allocation-or-lifetime-mismatch",
    "capture-start-failed",
    "capture-start-ambiguous",
    "command-buffer-creation-failed",
    "native-encode-rejected",
    "encoded-contract-mismatch",
    "submit-exception-ambiguous",
    "capture-acquisition-failed",
    "terminal-fence-error",
    "terminal-lifetime-or-counter-mismatch",
    "fence-nonterminal-after-wait-idle",
    "wait-idle-used",
)
for reason in reasons:
    if reason not in context or reason not in validator:
        raise SystemExit(f"P2.5b2a1 failure reason is not end-to-end: {reason}")

runtime = context.split(
    "void startShadingPrototypeTileSelfTest() noexcept", 1
)[1].split(
    "void settleShadingPrototypeTileAfterConfirmedIdle() noexcept", 1
)[0]
if runtime.count("device.commandBuffer()") != 1:
    raise SystemExit("P2.5b2a1 does not create exact one context CB")
if runtime.count("device.submit(shadingPrototypeTileCommand)") != 1:
    raise SystemExit("P2.5b2a1 does not submit exact once")
for forbidden in (
    "waitIdle(",
    "nextDrawable",
    "present(",
    "newLibraryWithSource",
    "riosForward",
    "ForwardPlus",
    "addRenderPipelineFunctions",
):
    if forbidden in runtime:
        raise SystemExit(f"P2.5b2a1 runtime contains forbidden token: {forbidden}")
if context.count("shadingPrototypeTileFence.wait(0u)") != 2:
    raise SystemExit("P2.5b2a1 terminal fence polling is not exact")
if context.count(
    "iosCreateShadingPrototypePipeline(device)"
) != 1 or context.count(
    "iosEncodeShadingPrototypeTileProbe("
) != 1:
    raise SystemExit("P2.5b2a1 opt-in native call sites are not exact")

required_cmake = (
    "option(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST",
    "RendererIOS shading prototype Tile self-test requires "
    "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON",
    "RendererIOS shading prototype Tile self-test requires "
    "OPENGOTHIC_RENDERER_IOS_FAULT_MODE=none",
    "IOS AND OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST",
    "OPENGOTHIC_RENDERER_IOS_METAL_CAPTURE_PLIST_ENTRY",
)
for token in required_cmake:
    if token not in cmake:
        raise SystemExit(f"P2.5b2a1 CMake gate missing: {token}")
if (
    cmake.count(
        "target_sources(${PROJECT_NAME} PRIVATE\n"
        '    "${CMAKE_CURRENT_SOURCE_DIR}/game/graphics/'
        'iosshadingprototypeplan.cpp")'
    )
    != 1
):
    raise SystemExit("P2.5b2a1 plan does not have exact TILE target gate")
for token in (
    "--require-shading-prototype-tile-self-test",
    "validate_shading_prototype_tile_binary_profile()",
    "self_test_profile=shading-prototype-tile",
    "processes-shading-prototype-tile-window-start.json",
    "capture_shading_prototype_tile_artifact()",
):
    if token not in harness:
        raise SystemExit(f"P2.5b2a1 harness gate missing: {token}")
PY
python3 - <<'PY'
from pathlib import Path
import runpy

context = Path("game/graphics/iosmetalcontext.cpp").read_text()
cmake = Path("CMakeLists.txt").read_text()
harness = Path("ios/device-test/run-smoke-test.sh").read_text()
validator_path = (
    "ios/device-test/validate-shading-prototype-forward-self-test-log.py"
)
validator = Path(validator_path).read_text()
gpudebug = Path(
    "ios/device-test/validate-shading-prototype-forward-gpudebug-trace.py"
).read_text()
module = runpy.run_path(validator_path)

templates = (
    "RendererIOS shading prototype forward self-test: ARMED "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward self-test: FACTORY READY "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward self-test: ENCODED "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward self-test: SUBMITTED "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward self-test: TERMINAL "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward self-test: READBACK "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward self-test: PASS "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward self-test: UNSUPPORTED "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward self-test: FAIL "
    "case=forward-prototype-v1 nonce=",
    "RendererIOS shading prototype forward capture: ACQUIRED "
    "case=forward-prototype-v1 nonce=",
)
scope = context.split(
    "constexpr char RendererIOSShadingPrototypeForwardSelfTestArmed[]", 1
)[1].split("\n#endif", 1)[0]
for template in templates:
    if scope.count(template) != 1:
        raise SystemExit(
            "P2.5c1b1 Forward context marker template is not exact: "
            + template
        )
    if harness.count(template) != 1:
        raise SystemExit(
            "P2.5c1b1 Forward harness marker template is not exact: "
            + template
        )
for token in (
    "RendererIOS-forward-prototype-v1.gputrace",
    "-renderer-ios-forward-self-test-nonce=",
):
    if scope.count(token) != 1:
        raise SystemExit(f"P2.5c1b1 Forward context token is not exact: {token}")

for reason in module["FAIL_REASONS"]:
    if reason not in context or reason not in validator:
        raise SystemExit(
            f"P2.5c1b1 Forward failure reason is not end-to-end: {reason}"
        )
if "fence-nonterminal-after-wait-idle" in module["FAIL_REASONS"]:
    raise SystemExit("P2.5c1b1 unreachable Forward failure reason returned")

runtime = context.split(
    "void startShadingPrototypeForwardSelfTest() noexcept", 1
)[1].split(
    "void settleShadingPrototypeForwardAfterConfirmedIdle() noexcept", 1
)[0]
if runtime.count("device.commandBuffer()") != 1:
    raise SystemExit("P2.5c1b1 Forward does not create exact one context CB")
if runtime.count("device.submit(shadingPrototypeForwardCommand)") != 1:
    raise SystemExit("P2.5c1b1 Forward does not submit exact once")
for forbidden in (
    "waitIdle(",
    "nextDrawable",
    "present(",
    "newLibraryWithSource",
):
    if forbidden in runtime:
        raise SystemExit(
            f"P2.5c1b1 Forward runtime contains forbidden token: {forbidden}"
        )

for token in (
    "option(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST",
    "RendererIOS shading prototype Forward self-test requires "
    "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON",
    "RendererIOS shading prototype Forward self-test requires "
    "OPENGOTHIC_RENDERER_IOS_FAULT_MODE=none",
    "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST OR",
    "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST",
    "OPENGOTHIC_RENDERER_IOS_METAL_CAPTURE_PLIST_ENTRY",
):
    if token not in cmake:
        raise SystemExit(f"P2.5c1b1 Forward CMake gate missing: {token}")
for token in (
    "--require-shading-prototype-forward-self-test",
    "validate_shading_prototype_forward_binary_profile()",
    "wait_for_shading_prototype_forward_terminal()",
    "verify_shading_prototype_forward_same_pid_stability()",
    "capture_shading_prototype_forward_artifact()",
    "verify_shading_prototype_forward_save_integrity()",
    "game_container_postruntime_validation=",
):
    if token not in harness:
        raise SystemExit(f"P2.5c1b1 Forward harness gate missing: {token}")
for token in (
    "--gpudebug",
    "--trace",
    "--terminate",
    'f"go commands/cb0/{compute_encoder_id}"',
    'f"go commands/cb0/{render_encoder_id}"',
    "go api_calls",
):
    if token not in gpudebug:
        raise SystemExit(f"P2.5c1b1 gpudebug collector gate missing: {token}")
PY
if grep -Eq \
    'newCommandQueue|commandBufferWith|commandBuffer\]|presentDrawable|endEncoding|commit\]|enqueue\]|waitUntilCompleted|MTLCommandQueue|MTLCommandBuffer|gapi/metal/mt' \
    game/graphics/iosgpuscene.mm \
    game/graphics/iosgpubink.mm; then
  fail "native RendererIOS path omija scoped Tempest Metal encoder bridge"
fi
if grep -Eq \
    'WorldView|DrawCommands|DrawBuckets|Shaders|InventoryMenu|VideoWidget' \
    game/graphics/iosgpusceneplan.h \
    game/graphics/iosgpuscene.h; then
  fail "publiczny kontrakt IOSGPUScene przecieka detalami legacy renderera"
fi
if grep -Eq 'newLibraryWithSource|compileOptions|IOSLandscapeMetalSource' \
    game/graphics/iosgpuscene.mm \
    game/graphics/iosgpubink.mm; then
  fail "native RendererIOS path nadal kompiluje shader w runtime"
fi

echo "### P2.5a host-neutral shading prototype plans"
[ -f game/graphics/iosshadingprototypeplan.h ]
[ -f game/graphics/iosshadingprototypeplan.cpp ]
[ -f ios/tests/iosshadingprototypeplan.cpp ]
python3 - <<'PY'
from pathlib import Path

source = Path("game/graphics/iosshadingprototypeplan.cpp").read_text()
include = '#include "iosshadingprototypeshaderabi.h"'
byte_size = (
    "RendererIOSShadingPrototypeShader::"
    "ForwardLightListByteSize"
)
if source.count(include) != 1:
    raise SystemExit("P2.5c1a shader ABI include is not exact")
if source.count(byte_size) != 1:
    raise SystemExit("P2.5c1a light-list byte-size use is not exact")
residual = source.replace(include, "").replace(byte_size, "")
if "iosshadingprototypeshaderabi" in residual or "RendererIOS" in residual:
    raise SystemExit("P2.5c1a plan escaped its exact shader ABI allowlist")
PY
if grep -nEi \
    "$HOST_NEUTRAL_METAL_LEAK_RE|Tempest|IOSMetalContext|RendererIOS|CAMetalLayer|newCommandQueue|newCommandBuffer|nextDrawable|presentDrawable|waitIdle|MetalFX|runtime[ -]shader|supportsFamily|supportsTextureSampleCount|MTLHeap|newHeap|sizeAndAlign|makeAliasable|NativeHandle|void[[:space:]]*\*" \
    game/graphics/iosshadingprototypeplan.h \
    ios/tests/iosshadingprototypeplan.cpp; then
  fail "P2.5a host-neutral contract przecieka runtime/native policy"
fi
if sed \
    -e '/^#include "iosshadingprototypeshaderabi.h"$/d' \
    -e 's/RendererIOSShadingPrototypeShader::ForwardLightListByteSize//g' \
  game/graphics/iosshadingprototypeplan.cpp |
    grep -nEi \
      "$HOST_NEUTRAL_METAL_LEAK_RE|Tempest|IOSMetalContext|RendererIOS|CAMetalLayer|newCommandQueue|newCommandBuffer|nextDrawable|presentDrawable|waitIdle|MetalFX|runtime[ -]shader|supportsFamily|supportsTextureSampleCount|MTLHeap|newHeap|sizeAndAlign|makeAliasable|NativeHandle|void[[:space:]]*\*"; then
  fail "P2.5c1a plan escaped its exact neutral ABI allowlist"
fi
python3 - <<'PY'
from pathlib import Path

cmake = Path("CMakeLists.txt").read_text()
remove = cmake.split("list(REMOVE_ITEM OPENGOTHIC_SOURCES", 1)[1].split(")", 1)[0]
source = '"${CMAKE_CURRENT_SOURCE_DIR}/game/graphics/iosshadingprototypeplan.cpp"'
if remove.count(source) != 1:
    raise SystemExit("P2.5a source nie jest dokladnie raz usuniety z targetu")
if remove.index('"${CMAKE_CURRENT_SOURCE_DIR}/game/graphics/renderer.cpp"') > remove.index(source):
    raise SystemExit("P2.5a source exclusion nie jest obok renderer.cpp")
PY
printf '#include "graphics/iosshadingprototypeplan.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -
xcrun clang++ -x c++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -fsyntax-only game/graphics/iosshadingprototypeplan.cpp
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosshadingprototypeplan.cpp \
  game/graphics/iosshadingprototypeplan.cpp \
  game/graphics/iosframeplan.cpp \
  -o "$TMP_GATE/iosshadingprototypeplan"
codesign -f -s - "$TMP_GATE/iosshadingprototypeplan"
"$TMP_GATE/iosshadingprototypeplan"
xcrun --sdk iphoneos clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -fsyntax-only \
  game/graphics/iosshadingprototypeplan.cpp \
  ios/tests/iosshadingprototypeplan.cpp

build_variant() {
  local diagnostics="$1"
  local tile="$2"
  local forward="$3"
  local profile="$4"
  local build
  build="$BUILD_ROOT-$profile"
  rm -rf -- "$build"

  echo "### Configure diagnostics=$diagnostics tile=$tile forward=$forward"
  cmake --preset "renderer-ios-$profile" -B "$build" \
    -DOPENGOTHIC_IOS_VERSION=1.0.9000 \
    -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="$HEAD_SHA-local"

  local project="$build/Gothic2Notr.xcodeproj/project.pbxproj"
  [ -f "$project" ] || fail "brak wygenerowanego project.pbxproj"
  ! grep -Eq '(^|[^[:alnum:]_])renderer\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "legacy renderer.cpp jest w celu RendererIOS"
  grep -Eq '(^|[^[:alnum:]_])rendererios\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak rendererios.cpp w celu"
  grep -Eq '(^|[^[:alnum:]_])iosmetalcontext\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak iosmetalcontext.cpp w celu"
  grep -Eq '(^|[^[:alnum:]_])iosgpuscene\.mm([^[:alnum:]_]|$)' "$project" ||
    fail "brak iosgpuscene.mm w celu"
  grep -Eq '(^|[^[:alnum:]_])iosgpubink\.mm([^[:alnum:]_]|$)' "$project" ||
    fail "brak iosgpubink.mm w celu"
  grep -Eq '(^|[^[:alnum:]_])iosshadingprototypepipeline\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5b1 host contract w celu"
  grep -Eq '(^|[^[:alnum:]_])iosshadingprototypepipeline\.mm([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5b1 native factory w celu"
  grep -Eq '(^|[^[:alnum:]_])iosshadingprototypetileprobe\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5b2a0 host report w celu"
  grep -Eq '(^|[^[:alnum:]_])iosshadingprototypetileprobe\.mm([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5b2a0 native encode helper w celu"
  grep -Eq '(^|[^[:alnum:]_])iosshadingprototypeforwardpipeline\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5c1b0 Forward host factory report w celu"
  grep -Eq '(^|[^[:alnum:]_])iosshadingprototypeforwardpipeline\.mm([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5c1b0 Forward native factory w celu"
  grep -Eq '(^|[^[:alnum:]_])iosshadingprototypeforwardprobe\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5c1b1 Forward host probe report w celu"
  grep -Eq '(^|[^[:alnum:]_])iosshadingprototypeforwardprobe\.mm([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5c1b1 Forward native probe w celu"
  grep -Eq '(^|[^[:alnum:]_])iosmetalcapturesession\.mm([^[:alnum:]_]|$)' "$project" ||
    fail "brak P2.5b2a1 common capture w celu"
  for source in \
      iosshadingprototypepipeline.cpp \
      iosshadingprototypepipeline.mm \
      iosshadingprototypetileprobe.cpp \
      iosshadingprototypetileprobe.mm \
      iosshadingprototypeforwardpipeline.cpp \
      iosshadingprototypeforwardpipeline.mm \
      iosshadingprototypeforwardprobe.cpp \
      iosshadingprototypeforwardprobe.mm \
      iosmetalcapturesession.mm; do
    [ "$(grep -Fc \
      "game/graphics/${source} */ = {isa = PBXBuildFile; fileRef =" \
      "$project")" -eq 1 ] ||
      fail "$source nie ma exact jednego PBXBuildFile"
  done
  python3 - "$project" "$diagnostics" "$tile" "$forward" <<'PY'
from pathlib import Path
import re
import sys

project = Path(sys.argv[1]).read_text()
diagnostics = sys.argv[2]
tile = sys.argv[3]
forward = sys.argv[4]
targets = re.findall(
    r"\b([A-F0-9]{24}) /\* [^*]+ \*/ = \{\n"
    r"\s*isa = PBXNativeTarget;(.*?)\n\s*\};",
    project,
    re.S,
)
gothic = [
    body for _, body in targets
    if re.search(r"^\s*name = Gothic2Notr;$", body, re.M)
]
if len(gothic) != 1:
    raise SystemExit("P2.5b1 nie znajduje exact targetu Gothic2Notr")
source_phase = re.search(
    r"([A-F0-9]{24}) /\* Sources \*/", gothic[0]
)
if source_phase is None:
    raise SystemExit("P2.5b1 Gothic2Notr nie ma Sources phase")
phase = re.search(
    rf"\b{source_phase.group(1)} /\* Sources \*/ = \{{\n"
    r"\s*isa = PBXSourcesBuildPhase;(.*?)\n\s*\};",
    project,
    re.S,
)
if phase is None:
    raise SystemExit("P2.5b1 nie czyta Gothic2Notr Sources phase")
for source in (
    "iosshadingprototypepipeline.cpp",
    "iosshadingprototypepipeline.mm",
    "iosshadingprototypetileprobe.cpp",
    "iosshadingprototypetileprobe.mm",
    "iosshadingprototypeforwardpipeline.cpp",
    "iosshadingprototypeforwardpipeline.mm",
    "iosshadingprototypeforwardprobe.cpp",
    "iosshadingprototypeforwardprobe.mm",
    "iosmetalcapturesession.mm",
):
    if phase.group(1).count(source) != 1:
        raise SystemExit(
            f"P2.5b2a1 {source} nie jest exact raz w Gothic2Notr Sources"
        )
plan = "iosshadingprototypeplan.cpp"
expected = 1 if tile == "ON" or forward == "ON" else 0
if phase.group(1).count(plan) != expected:
    raise SystemExit("P2.5b2a1 plan PBX gate nie zgadza sie z profilem")
build_files = project.split(
    "/* Begin PBXBuildFile section */", 1
)[1].split("/* End PBXBuildFile section */", 1)[0]
if build_files.count(plan) != expected * 2:
    raise SystemExit("P2.5c1b1 plan PBXBuildFile gate nie jest exact")
forward_definition = (
    "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=1"
)
expected_forward_definitions = 4 if forward == "ON" else 0
if project.count(forward_definition) != expected_forward_definitions:
    raise SystemExit(
        "P2.5c1b1 Forward PBX compile-definition gate nie jest exact"
    )
tile_definition = (
    "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST=1"
)
expected_tile_definitions = 4 if tile == "ON" else 0
if project.count(tile_definition) != expected_tile_definitions:
    raise SystemExit(
        "P2.5c1b1 Tile PBX compile-definition gate nie jest exact"
    )
diagnostics_definition = "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1"
expected_diagnostics_definitions = 4 if diagnostics == "ON" else 0
if project.count(diagnostics_definition) != expected_diagnostics_definitions:
    raise SystemExit(
        "RendererIOS diagnostics PBX compile-definition gate nie jest exact"
    )
PY
  grep -Eq '(^|[^[:alnum:]_])iosframeinput\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak iosframeinput.cpp w celu"
  grep -Eq '(^|[^[:alnum:]_])iosrenderworld\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak iosrenderworld.cpp w celu"
  grep -Eq '(^|[^[:alnum:]_])iosscenesnapshot\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak iosscenesnapshot.cpp w celu"
  grep -Eq '(^|[^[:alnum:]_])iossceneconversion\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak iossceneconversion.cpp w celu"
  grep -Eq '(^|[^[:alnum:]_])iossceneassetregistry\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak iossceneassetregistry.cpp w celu"
  grep -Eq '(^|[^[:alnum:]_])iossceneextractor\.cpp([^[:alnum:]_]|$)' "$project" ||
    fail "brak iossceneextractor.cpp w celu"
  grep -Fq 'legacyShaders(Shaders::CompilationProfile::RendererIOSBridge)' \
    game/graphics/iosmetalcontext.cpp ||
    fail "IOSMetalContext nie wybiera bridge-only shader profile"
grep -Fq 'profile=bridge-only eager-bridge-pipelines=inventory offline-native-pipelines=builtin,bink legacy-batch=disabled' \
  game/graphics/shaders.cpp ||
    fail "brak stabilnego markera bridge-only shader policy"
! grep -Fq 'Shaders::inst().bink' game/ui/videowidget.cpp ||
  fail "VideoWidget zachował runtime-compiled Bink fallback"

  echo "### Build diagnostics=$diagnostics tile=$tile forward=$forward"
  cmake --build "$build" --config Release --parallel "$CPUS" -- \
    -sdk iphoneos \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=""

  local app="$build/opengothic/Release/Gothic2Notr.app"
  local binary="$app/Gothic2Notr"
  local plist="$app/Info.plist"
  local metallib="$app/RendererIOS.metallib"
  local metallib_sha256
  local strings_file="$TMP_GATE/Gothic2Notr-$profile.strings"
  [ -f "$binary" ] || fail "brak Gothic2Notr binary dla $profile"
  [ -f "$plist" ] || fail "brak Info.plist dla $profile"
  [ -f "$metallib" ] || fail "brak RendererIOS.metallib dla $profile"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist")" = 16.4 ] ||
    fail "profil $profile nie ma minimum iOS 16.4"
  metallib_sha256="$(shasum -a 256 "$metallib" | awk '{print $1}')"
  [ "$metallib_sha256" = "$CANONICAL_RENDERER_IOS_METALLIB_SHA256" ] ||
    fail "profil $profile ma RendererIOS.metallib inny niz canonical exact15"
  strings "$binary" >"$strings_file"
  [ "$(grep -Fxc "$HEAD_SHA-local" "$strings_file" || true)" -eq 1 ] ||
    fail "profil $profile nie ma exact binarnego build SHA $HEAD_SHA-local"
  [ "$(grep -Ec '^RendererIOS configured fault mode=' \
    "$strings_file" || true)" -eq 1 ] ||
    fail "profil $profile nie ma exact jednego configured fault markera"
  grep -Fxq 'RendererIOS configured fault mode=none' "$strings_file" ||
    fail "profil $profile nie ma configured fault mode=none"
  if [ "$diagnostics" = ON ]; then
    [ "$(grep -Fxc 'RendererIOS diagnostics: ON frames-in-flight=' \
      "$strings_file" || true)" -eq 1 ] ||
      fail "profil $profile nie ma exact diagnostics ON binarnego markera"
    ! grep -Fxq 'RendererIOS diagnostics: OFF' "$strings_file" ||
      fail "profil $profile zawiera diagnostics OFF binarny marker"
  else
    [ "$(grep -Fxc 'RendererIOS diagnostics: OFF' \
      "$strings_file" || true)" -eq 1 ] ||
      fail "profil $profile nie ma exact diagnostics OFF binarnego markera"
    ! grep -Fxq 'RendererIOS diagnostics: ON frames-in-flight=' \
      "$strings_file" ||
      fail "profil $profile zawiera diagnostics ON binarny marker"
  fi
  if [ "$forward" = ON ]; then
    [ "$(/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' "$plist")" = true ] ||
      fail "profil FORWARD nie ma MetalCaptureEnabled=true"
    for marker in \
        'RendererIOS shading prototype forward self-test: ARMED case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward self-test: FACTORY READY case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward self-test: ENCODED case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward self-test: SUBMITTED case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward self-test: TERMINAL case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward self-test: READBACK case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward self-test: PASS case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward self-test: UNSUPPORTED case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward self-test: FAIL case=forward-prototype-v1 nonce=' \
        'RendererIOS shading prototype forward capture: ACQUIRED case=forward-prototype-v1 nonce=' \
        '-renderer-ios-forward-self-test-nonce='; do
      [ "$(grep -Fxc -- "$marker" "$strings_file" || true)" -eq 1 ] ||
        fail "profil FORWARD nie ma exact binarnego markera: $marker"
    done
    [ "$(grep -Fxc 'RendererIOS-forward-prototype-v1.gputrace' \
      "$strings_file" || true)" -eq 1 ] ||
      fail "profil FORWARD nie ma exact capture basename"
    ! grep -Fq 'RendererIOS shading prototype tile self-test:' \
      "$strings_file" ||
      fail "profil FORWARD zawiera TILE self-test markers"
    ! grep -Fq 'RendererIOS-tile-prototype-v1.gputrace' "$strings_file" ||
      fail "profil FORWARD zawiera TILE capture basename"
  elif [ "$tile" = ON ]; then
    [ "$(/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' "$plist")" = true ] ||
      fail "profil TILE nie ma MetalCaptureEnabled=true"
    for marker in \
        'RendererIOS shading prototype tile self-test: ARMED case=tile-prototype-v1 contract=1 metallib-abi=5 minimum-apple=4 output=4x4 rgba8-private=1' \
        'RendererIOS shading prototype tile self-test: FACTORY READY case=tile-prototype-v1 pipelines=3 forward=0 runtime-delta=0 builtin-delta=0 archive-delta=0' \
        'RendererIOS shading prototype tile self-test: ENCODED case=tile-prototype-v1 pass=1 encoder=1 draws=2 opaque=1 alpha=1 tdispatch=1 vb=168 output=1 mat=0 ib=4 clear-a=0 tgmem=0 size=16 dispatch=16x16x1 order=opaque,alpha,tile drawable=0 present=0' \
        'RendererIOS shading prototype tile self-test: SUBMITTED case=tile-prototype-v1 command-buffers=1 submits=1' \
        'RendererIOS shading prototype tile self-test: PASS case=tile-prototype-v1 terminal=completed created=1 live=0 released=1 wait-idle=0 runtime-delta=0 builtin-delta=0 archive-delta=0' \
        'RendererIOS shading prototype tile self-test: UNSUPPORTED case=tile-prototype-v1 reason=apple4-required side-effects=0'; do
      [ "$(grep -Fxc "$marker" "$strings_file" || true)" -eq 1 ] ||
        fail "profil TILE nie ma exact binarnego markera: $marker"
    done
    [ "$(grep -Fxc \
      'RendererIOS shading prototype tile capture: ACQUIRED' \
      "$strings_file" || true)" -eq 1 ] ||
      fail "profil TILE nie ma exact binarnego ACQUIRED"
    ! grep -Fq 'RendererIOS shading prototype forward self-test:' \
      "$strings_file" ||
      fail "profil TILE zawiera FORWARD self-test markers"
    ! grep -Fq 'RendererIOS-forward-prototype-v1.gputrace' "$strings_file" ||
      fail "profil TILE zawiera FORWARD capture basename"
    ! grep -Fq -- '-renderer-ios-forward-self-test-nonce=' "$strings_file" ||
      fail "profil TILE zawiera FORWARD nonce argument"
  else
    if /usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
        "$plist" >/dev/null 2>&1; then
      fail "profil $profile nie powinien miec MetalCaptureEnabled"
    fi
    ! grep -Fq 'RendererIOS shading prototype tile self-test:' \
      "$strings_file" ||
      fail "profil $profile zawiera TILE self-test markers"
    ! grep -Fq 'RendererIOS-tile-prototype-v1.gputrace' "$strings_file" ||
      fail "profil $profile zawiera TILE capture basename"
    ! grep -Fq 'RendererIOS shading prototype forward self-test:' \
      "$strings_file" ||
      fail "profil $profile zawiera FORWARD self-test markers"
    ! grep -Fq 'RendererIOS-forward-prototype-v1.gputrace' "$strings_file" ||
      fail "profil $profile zawiera FORWARD capture basename"
    ! grep -Fq -- '-renderer-ios-forward-self-test-nonce=' "$strings_file" ||
      fail "profil $profile zawiera FORWARD nonce argument"
  fi
}

expect_tile_configure_failure() {
  local name="$1"
  shift
  local build="$TMP_GATE/tile-invalid-$name"
  if cmake --preset renderer-ios-tile -B "$build" \
      "$@" >/dev/null 2>&1; then
    fail "P2.5b2a1 invalid CMake profile przetrwal: $name"
  fi
}

expect_tile_configure_failure diagnostics-off \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=OFF
expect_tile_configure_failure fault \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_FAULT_MODE=post-submit-suboptimal
expect_tile_configure_failure bink \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST=ON
expect_tile_configure_failure allocator \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST=ON
expect_tile_configure_failure clear \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=ON
expect_tile_configure_failure forward \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST=ON

expect_forward_configure_failure() {
  local name="$1"
  shift
  local build="$TMP_GATE/forward-invalid-$name"
  if cmake --preset renderer-ios-forward -B "$build" \
      "$@" >/dev/null 2>&1; then
    fail "P2.5c1b1 invalid Forward CMake profile przetrwal: $name"
  fi
}

expect_forward_configure_failure diagnostics-off \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=OFF
expect_forward_configure_failure fault \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_FAULT_MODE=post-submit-suboptimal
expect_forward_configure_failure bink \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST=ON
expect_forward_configure_failure allocator \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST=ON
expect_forward_configure_failure clear \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST=ON
expect_forward_configure_failure tile \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON \
  -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST=ON

if wants_profile off; then
  build_variant OFF OFF OFF off
fi
if wants_profile on; then
  build_variant ON OFF OFF on
fi
if wants_profile tile; then
  build_variant ON ON OFF tile
fi
if wants_profile forward; then
  build_variant ON OFF ON forward
fi

[ "$(git -C "$REPO" rev-parse HEAD)" = "$HEAD_SHA" ] ||
  fail "parent HEAD zmienil sie podczas lokalnej weryfikacji"
git -C "$REPO" status --porcelain=v1 -z --untracked-files=all >"$FINAL_STATUS"
cmp -s "$INITIAL_STATUS" "$FINAL_STATUS" ||
  fail "parent zmienil stan working tree podczas lokalnej weryfikacji"

if ((REQUESTED_PROFILE_COUNT > 0)); then
  echo "LOCAL BUILD PASSED"
  PROFILES_CSV="$(IFS=,; echo "${REQUESTED_PROFILES[*]}")"
else
  echo "LOCAL VERIFICATION PASSED"
  PROFILES_CSV=""
fi
echo "mode=$MODE"
echo "profiles=$PROFILES_CSV"
echo "parent_sha=$HEAD_SHA"
echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
echo "ios_sdk=$(xcrun --sdk iphoneos --show-sdk-version)"
