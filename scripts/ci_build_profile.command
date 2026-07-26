#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

PROFILE="${1:-}"
case "$PROFILE" in
  off)
    DIAGNOSTICS=OFF
    ACTIVE_FAULT_MODE=none
    BINK_SELF_TEST=OFF
    RESOURCE_ALLOCATOR_SELF_TEST=OFF
    CLEAR_ONLY_PASS_SELF_TEST=OFF
    SHADING_PROTOTYPE_TILE_SELF_TEST=OFF
    SHADING_PROTOTYPE_FORWARD_SELF_TEST=OFF
    ;;
  on)
    DIAGNOSTICS=ON
    ACTIVE_FAULT_MODE="${ACTIVE_FAULT_MODE:-none}"
    BINK_SELF_TEST="${BINK_SELF_TEST:-OFF}"
    RESOURCE_ALLOCATOR_SELF_TEST="${RESOURCE_ALLOCATOR_SELF_TEST:-OFF}"
    CLEAR_ONLY_PASS_SELF_TEST="${CLEAR_ONLY_PASS_SELF_TEST:-OFF}"
    SHADING_PROTOTYPE_TILE_SELF_TEST="${SHADING_PROTOTYPE_TILE_SELF_TEST:-OFF}"
    SHADING_PROTOTYPE_FORWARD_SELF_TEST="${SHADING_PROTOTYPE_FORWARD_SELF_TEST:-OFF}"
    ;;
  tile)
    DIAGNOSTICS=ON
    ACTIVE_FAULT_MODE=none
    BINK_SELF_TEST=OFF
    RESOURCE_ALLOCATOR_SELF_TEST=OFF
    CLEAR_ONLY_PASS_SELF_TEST=OFF
    SHADING_PROTOTYPE_TILE_SELF_TEST=ON
    SHADING_PROTOTYPE_FORWARD_SELF_TEST=OFF
    TEMPEST_PROFILE=baseline
    PACKAGE_DEVICE_IPA=0
    ;;
  forward)
    DIAGNOSTICS=ON
    ACTIVE_FAULT_MODE=none
    BINK_SELF_TEST=OFF
    RESOURCE_ALLOCATOR_SELF_TEST=OFF
    CLEAR_ONLY_PASS_SELF_TEST=OFF
    SHADING_PROTOTYPE_TILE_SELF_TEST=OFF
    SHADING_PROTOTYPE_FORWARD_SELF_TEST=ON
    TEMPEST_PROFILE=baseline
    PACKAGE_DEVICE_IPA=0
    ;;
  *)
    echo "usage: $0 off|on|tile|forward" >&2
    exit 2
    ;;
esac

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${GITHUB_SHA:?GITHUB_SHA must be set}"
IOS_VERSION="${IOS_VERSION:-1.0.0}"
TEMPEST_PROFILE="${TEMPEST_PROFILE:-baseline}"
PACKAGE_DEVICE_IPA="${PACKAGE_DEVICE_IPA:-0}"

case "$TEMPEST_PROFILE" in
  baseline)
    DIRECT_DRAWABLE=OFF
    METALFX_SPATIAL=OFF
    METALFX_TEMPORAL=OFF
    ;;
  direct-drawable)
    DIRECT_DRAWABLE=ON
    METALFX_SPATIAL=OFF
    METALFX_TEMPORAL=OFF
    ;;
  metalfx-spatial)
    DIRECT_DRAWABLE=OFF
    METALFX_SPATIAL=ON
    METALFX_TEMPORAL=OFF
    ;;
  metalfx-temporal)
    DIRECT_DRAWABLE=OFF
    METALFX_SPATIAL=ON
    METALFX_TEMPORAL=ON
    ;;
  *)
    echo "unknown Tempest profile: $TEMPEST_PROFILE" >&2
    exit 2
    ;;
esac

for value in \
    "$BINK_SELF_TEST" \
    "$RESOURCE_ALLOCATOR_SELF_TEST" \
    "$CLEAR_ONLY_PASS_SELF_TEST" \
    "$SHADING_PROTOTYPE_TILE_SELF_TEST" \
    "$SHADING_PROTOTYPE_FORWARD_SELF_TEST"; do
  case "$value" in
    ON|OFF) ;;
    *)
      echo "invalid ON/OFF input: $value" >&2
      exit 2
      ;;
  esac
done

# CI_PROFILE_CONFIGURE_BEGIN
cmake -S . -B build-renderer-ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 \
  -DOPENGOTHIC_IOS_VERSION="$IOS_VERSION" \
  -DOPENGOTHIC_GPU_EXPERIMENT_DIRECT_DRAWABLE_LAZY_SSAO="$DIRECT_DRAWABLE" \
  -DOPENGOTHIC_METALFX_SPATIAL="$METALFX_SPATIAL" \
  -DOPENGOTHIC_METALFX_TEMPORAL="$METALFX_TEMPORAL" \
  -DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS="$DIAGNOSTICS" \
  -DOPENGOTHIC_RENDERER_IOS_FAULT_MODE="$ACTIVE_FAULT_MODE" \
  -DOPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST="$BINK_SELF_TEST" \
  -DOPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST="$RESOURCE_ALLOCATOR_SELF_TEST" \
  -DOPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST="$CLEAR_ONLY_PASS_SELF_TEST" \
  -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST="$SHADING_PROTOTYPE_TILE_SELF_TEST" \
  -DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST="$SHADING_PROTOTYPE_FORWARD_SELF_TEST" \
  -DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="$GITHUB_SHA"
# CI_PROFILE_CONFIGURE_END

# CI_PROFILE_CANDIDATE_BEGIN
for shader in landscape bink ui inventory shading-prototypes; do
  set --
  if [ "$shader" = shading-prototypes ]; then
    set -- -Wall -Wextra -Werror
  fi
  xcrun --sdk iphoneos metal \
    -target air64-apple-ios16.4 \
    "$@" \
    -c "shader/ios-metal/$shader.metal" \
    -o "$RUNNER_TEMP/ios-$shader.air"
done
xcrun --sdk iphoneos metallib \
  "$RUNNER_TEMP/ios-landscape.air" \
  "$RUNNER_TEMP/ios-bink.air" \
  "$RUNNER_TEMP/ios-ui.air" \
  "$RUNNER_TEMP/ios-inventory.air" \
  "$RUNNER_TEMP/ios-shading-prototypes.air" \
  -o "$RUNNER_TEMP/RendererIOS.candidate.metallib"
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
ACTUAL_RIOS_EXPORTS="$(xcrun --sdk iphoneos metal-nm \
  "$RUNNER_TEMP/RendererIOS.candidate.metallib" |
  awk '$2 == "T" { print $3 }' | LC_ALL=C sort)"
test "$ACTUAL_RIOS_EXPORTS" = "$EXPECTED_RIOS_EXPORTS"
test "$(printf '%s\n' "$ACTUAL_RIOS_EXPORTS" | wc -l | tr -d ' ')" -eq 15
shasum -a 256 "$RUNNER_TEMP/RendererIOS.candidate.metallib" |
  awk '{print $1}' >"$RUNNER_TEMP/RendererIOS.candidate.sha256"
# CI_PROFILE_CANDIDATE_END

printf '\n### CI profile Build iOS Release\n'
set -euo pipefail
cmake --build build-renderer-ios --config Release -- \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
APP_BINARY='build-renderer-ios/opengothic/Release/Gothic2Notr.app/Gothic2Notr'
APP_INFO='build-renderer-ios/opengothic/Release/Gothic2Notr.app/Info.plist'
APP_METALLIB='build-renderer-ios/opengothic/Release/Gothic2Notr.app/RendererIOS.metallib'
APP_STRINGS="$RUNNER_TEMP/Gothic2Notr-$DIAGNOSTICS.strings"
test -f "$APP_BINARY"
test -f "$APP_INFO"
test -f "$APP_METALLIB"
test -f "$RUNNER_TEMP/RendererIOS.candidate.sha256"
test "$(wc -l <"$RUNNER_TEMP/RendererIOS.candidate.sha256" |
  tr -d ' ')" -eq 1
P25C1A_CANDIDATE_DIGEST="$(
  sed -n '1p' "$RUNNER_TEMP/RendererIOS.candidate.sha256"
)"
printf '%s\n' "$P25C1A_CANDIDATE_DIGEST" |
  grep -Eq '^[0-9a-f]{64}$'
APP_METALLIB_DIGEST="$(
  shasum -a 256 "$APP_METALLIB" | awk '{print $1}'
)"
test "$APP_METALLIB_DIGEST" = "$P25C1A_CANDIDATE_DIGEST"
printf 'RendererIOS %s app metallib matches P2.5c1a candidate: %s\n' \
  "$DIAGNOSTICS" "$APP_METALLIB_DIGEST"
strings "$APP_BINARY" >"$APP_STRINGS"
if [ "$DIAGNOSTICS" = ON ]; then
  grep -Fxq 'RendererIOS pipeline archive test-mode: mode=' \
    "$APP_STRINGS"
  grep -Fxq 'RendererIOS-D041-invalid-binary-archive-v1' \
    "$APP_STRINGS"
  grep -Fxq 'RendererIOS functional evidence: fence-terminal=1' \
    "$APP_STRINGS"
  grep -Fxq ' ui-item-draw-count=' "$APP_STRINGS"
  grep -Fxq 'quickring-items' "$APP_STRINGS"
  grep -Fxq 'quickring-weapons' "$APP_STRINGS"
  grep -Fxq -- '-renderer-ios-semantic-nonce=' \
    "$APP_STRINGS"
  grep -Fxq ' mode=save-ui-lifecycle-v1' \
    "$APP_STRINGS"
  grep -Fxq 'RendererIOS semantic script: ARMED mode=save-ui-lifecycle-v1' \
    "$APP_STRINGS"
  grep -Fxq 'RendererIOS semantic script: SCRIPT PASS' \
    "$APP_STRINGS"
  grep -Fxq 'WAIT_RESUME_EVIDENCE' "$APP_STRINGS"
else
  ! grep -Fxq 'RendererIOS pipeline archive test-mode: mode=' \
    "$APP_STRINGS"
  ! grep -Fxq 'RendererIOS-D041-invalid-binary-archive-v1' \
    "$APP_STRINGS"
  ! grep -Fxq 'RendererIOS functional evidence: fence-terminal=1' \
    "$APP_STRINGS"
  ! grep -Fxq ' ui-item-draw-count=' "$APP_STRINGS"
  ! grep -Fxq 'quickring-items' "$APP_STRINGS"
  ! grep -Fxq 'quickring-weapons' "$APP_STRINGS"
  ! grep -Fxq -- '-renderer-ios-semantic-nonce=' \
    "$APP_STRINGS"
  ! grep -Fxq ' mode=save-ui-lifecycle-v1' \
    "$APP_STRINGS"
  ! grep -Fxq 'RendererIOS semantic script: ARMED mode=save-ui-lifecycle-v1' \
    "$APP_STRINGS"
  ! grep -Fxq 'RendererIOS semantic script: SCRIPT PASS' \
    "$APP_STRINGS"
  ! grep -Fxq 'WAIT_RESUME_EVIDENCE' "$APP_STRINGS"
fi
if [ "$RESOURCE_ALLOCATOR_SELF_TEST" = ON ]; then
  grep -Fxq 'RendererIOS resource allocator self-test: ARMED case=private-memoryless-4x4-rgba8-v1' \
    "$APP_STRINGS"
  grep -Fxq 'RendererIOS resource allocator self-test: PASS case=private-memoryless-4x4-rgba8-v1 allocation-only=1 encoded=0 render-pass=0 submitted=0 created=2 live=0 released=2' \
    "$APP_STRINGS"
else
  ! grep -Fq 'RendererIOS resource allocator self-test:' \
    "$APP_STRINGS"
fi
if [ "$CLEAR_ONLY_PASS_SELF_TEST" = ON ]; then
  test "$(grep -Fxc -- 'RendererIOS clear-only pass self-test: ARMED case=pm-clear-v1 abi=4 resources=3 logical-passes=3 private=1 memoryless=1' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS clear-only pass self-test: ENCODED case=pm-clear-v1 physical-passes=2 command-buffers=1 render-encoders=2 private-load=clear private-store=store memoryless-load=clear memoryless-store=dont-care draws=0 pipelines=0 drawable=0 present=0' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS clear-only pass self-test: SUBMITTED case=pm-clear-v1 command-buffers=1 submits=1' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS clear-only pass self-test: PASS case=pm-clear-v1 terminal=completed created=2 live=0 released=2 wait-idle=0' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS clear-only capture: ACQUIRED' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
    "$APP_INFO")" = true
else
  ! grep -Fq 'RendererIOS clear-only pass self-test:' \
    "$APP_STRINGS"
  ! grep -Fq 'RendererIOS clear-only capture:' \
    "$APP_STRINGS"
fi
if [ "$SHADING_PROTOTYPE_TILE_SELF_TEST" = ON ]; then
  test "$(grep -Fxc -- 'RendererIOS shading prototype tile self-test: ARMED case=tile-prototype-v1 contract=1 metallib-abi=5 minimum-apple=4 output=4x4 rgba8-private=1' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS shading prototype tile self-test: FACTORY READY case=tile-prototype-v1 pipelines=3 forward=0 runtime-delta=0 builtin-delta=0 archive-delta=0' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS shading prototype tile self-test: ENCODED case=tile-prototype-v1 pass=1 encoder=1 draws=2 opaque=1 alpha=1 tdispatch=1 vb=168 output=1 mat=0 ib=4 clear-a=0 tgmem=0 size=16 dispatch=16x16x1 order=opaque,alpha,tile drawable=0 present=0' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS shading prototype tile self-test: SUBMITTED case=tile-prototype-v1 command-buffers=1 submits=1' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS shading prototype tile self-test: PASS case=tile-prototype-v1 terminal=completed created=1 live=0 released=1 wait-idle=0 runtime-delta=0 builtin-delta=0 archive-delta=0' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS shading prototype tile self-test: UNSUPPORTED case=tile-prototype-v1 reason=apple4-required side-effects=0' \
    "$APP_STRINGS" || true)" -eq 1
  test "$(grep -Fxc -- 'RendererIOS shading prototype tile capture: ACQUIRED' \
    "$APP_STRINGS" || true)" -eq 1
else
  ! grep -Fq 'RendererIOS shading prototype tile self-test:' \
    "$APP_STRINGS"
  ! grep -Fq 'RendererIOS shading prototype tile capture:' \
    "$APP_STRINGS"
fi
if [ "$SHADING_PROTOTYPE_FORWARD_SELF_TEST" = ON ]; then
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
    test "$(grep -Fxc -- "$marker" "$APP_STRINGS" || true)" -eq 1
  done
else
  ! grep -Fq 'RendererIOS shading prototype forward self-test:' \
    "$APP_STRINGS"
  ! grep -Fq 'RendererIOS shading prototype forward capture:' \
    "$APP_STRINGS"
  ! grep -Fq -- '-renderer-ios-forward-self-test-nonce=' \
    "$APP_STRINGS"
fi
if [ "$CLEAR_ONLY_PASS_SELF_TEST" = ON ] ||
   [ "$SHADING_PROTOTYPE_TILE_SELF_TEST" = ON ] ||
   [ "$SHADING_PROTOTYPE_FORWARD_SELF_TEST" = ON ]; then
  test "$(/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
    "$APP_INFO")" = true
else
  ! /usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
    "$APP_INFO" >/dev/null 2>&1
fi

printf '\n### CI profile Verify P2.6b1 final weak MetalFX dependency\n'
set -euo pipefail

APP_BINARY='build-renderer-ios/opengothic/Release/Gothic2Notr.app/Gothic2Notr'
test -f "$APP_BINARY"
xcrun otool -l "$APP_BINARY" \
  >"$RUNNER_TEMP/Gothic2Notr-load-commands.txt"
python3 - "$RUNNER_TEMP/Gothic2Notr-load-commands.txt" <<'PY'
from pathlib import Path
import re
import sys

load_commands = Path(sys.argv[1]).read_text()
framework_suffix = "/MetalFX.framework/MetalFX"

def parse(text):
    result = []
    command = None
    name = None
    for line in text.splitlines() + ["Load command END"]:
        if line.startswith("Load command "):
            if command is not None and name is not None:
                result.append((command, name))
            command = None
            name = None
            continue
        command_match = re.fullmatch(
            r"\s*cmd (LC_[A-Z0-9_]+)", line
        )
        if command_match is not None:
            command = command_match.group(1)
            continue
        name_match = re.fullmatch(
            r"\s*name (.+) \(offset [0-9]+\)", line
        )
        if name_match is not None:
            name = name_match.group(1)
    return result

def validate(commands):
    metalfx = [
        (command, name)
        for command, name in commands
        if name.endswith(framework_suffix)
    ]
    weak = [
        item for item in metalfx
        if item[0] == "LC_LOAD_WEAK_DYLIB"
    ]
    strong = [
        item for item in metalfx
        if item[0] == "LC_LOAD_DYLIB"
    ]
    if len(metalfx) != 1 or len(weak) != 1 or strong:
        raise ValueError(
            "final app must contain exactly one weak MetalFX "
            "dependency and zero strong MetalFX dependencies"
        )
    return weak[0]

commands = parse(load_commands)
try:
    weak = validate(commands)
except ValueError as error:
    raise SystemExit(str(error)) from error

weak_index = commands.index(weak)
mutations = (
    (
        "weakened-to-strong",
        commands[:weak_index]
        + [("LC_LOAD_DYLIB", weak[1])]
        + commands[weak_index + 1 :],
    ),
    (
        "missing",
        commands[:weak_index] + commands[weak_index + 1 :],
    ),
    (
        "duplicate-weak",
        commands[:weak_index + 1]
        + [weak]
        + commands[weak_index + 1 :],
    ),
    (
        "reexported",
        commands[:weak_index]
        + [("LC_REEXPORT_DYLIB", weak[1])]
        + commands[weak_index + 1 :],
    ),
)
mutations_killed = 0
for label, candidate in mutations:
    try:
        validate(candidate)
    except ValueError:
        mutations_killed += 1
    else:
        raise SystemExit(
            "P2.6b1 Mach-O mutation survived: " + label
        )
if mutations_killed != 4:
    raise SystemExit(
        "P2.6b1 Mach-O mutation count drifted"
    )
print(
    "P2.6b1 Mach-O oracle: weak=1 strong=0 "
    "mutations-killed=4 path=" + weak[1]
)
PY

package_device_ipa() {
HEAD_SHA="$(git rev-parse HEAD)"
if [ "$HEAD_SHA" != "$GITHUB_SHA" ]; then
  echo "checkout SHA $HEAD_SHA does not match workflow SHA $GITHUB_SHA"
  exit 1
fi

APP_LIST="$(find build-renderer-ios -type d -name 'Gothic2Notr.app' -print)"
APP_COUNT="$(printf '%s\n' "$APP_LIST" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$APP_COUNT" -ne 1 ]; then
  echo "expected exactly one Gothic2Notr.app, found $APP_COUNT"
  printf '%s\n' "$APP_LIST"
  exit 1
fi
APP="$APP_LIST"
if [ "$APP" != 'build-renderer-ios/opengothic/Release/Gothic2Notr.app' ]; then
  echo "unexpected Release app path: $APP"
  exit 1
fi
INFO_PLIST="$APP/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
  echo "missing app Info.plist: $INFO_PLIST"
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
PLATFORM_NAME="$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$INFO_PLIST")"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$INFO_PLIST")"
if [ "$BUNDLE_ID" != 'opengothic.gothic2' ]; then
  echo "unexpected bundle identifier: $BUNDLE_ID"
  exit 1
fi
if [ "$BUNDLE_VERSION" != "$IOS_VERSION" ]; then
  echo "unexpected bundle version: $BUNDLE_VERSION (expected $IOS_VERSION)"
  exit 1
fi
if [ "$PLATFORM_NAME" != 'iphoneos' ]; then
  echo "unexpected bundle platform: $PLATFORM_NAME"
  exit 1
fi
if [ "$MINIMUM_OS" != '16.4' ]; then
  echo "unexpected minimum iOS version: $MINIMUM_OS (expected 16.4)"
  exit 1
fi
if [ "$CLEAR_ONLY_PASS_SELF_TEST" = ON ] ||
   [ "$SHADING_PROTOTYPE_TILE_SELF_TEST" = ON ] ||
   [ "$SHADING_PROTOTYPE_FORWARD_SELF_TEST" = ON ]; then
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
      "$INFO_PLIST")" != true ]; then
    echo 'capture self-test package does not enable Metal capture'
    exit 1
  fi
elif /usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' \
    "$INFO_PLIST" >/dev/null 2>&1; then
  echo 'unrequested package enables Metal capture'
  exit 1
fi
if [ ! -f "$APP/$EXECUTABLE" ]; then
  echo "missing app executable: $APP/$EXECUTABLE"
  exit 1
fi
PACKAGE_STRINGS="$RUNNER_TEMP/Gothic2Notr-package.strings"
strings "$APP/$EXECUTABLE" >"$PACKAGE_STRINGS"
if [ "$SHADING_PROTOTYPE_FORWARD_SELF_TEST" = ON ]; then
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
    test "$(grep -Fxc -- "$marker" "$PACKAGE_STRINGS" || true)" -eq 1
  done
else
  ! grep -Fq 'RendererIOS shading prototype forward self-test:' \
    "$PACKAGE_STRINGS"
  ! grep -Fq 'RendererIOS shading prototype forward capture:' \
    "$PACKAGE_STRINGS"
  ! grep -Fq -- '-renderer-ios-forward-self-test-nonce=' \
    "$PACKAGE_STRINGS"
fi
if ! file "$APP/$EXECUTABLE" | grep -Eq 'arm64'; then
  echo "app executable is not arm64"
  file "$APP/$EXECUTABLE"
  exit 1
fi
if [ -e "$APP/embedded.mobileprovision" ]; then
  echo 'device-test artifact unexpectedly contains a provisioning profile'
  exit 1
fi
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo 'device-test artifact unexpectedly contains a valid code signature'
  exit 1
fi

SHORT_SHA="${GITHUB_SHA:0:12}"
BASENAME="OpenGothic-RendererIOS-${SHORT_SHA}-run${GITHUB_RUN_ID}-attempt${GITHUB_RUN_ATTEMPT}-${TEMPEST_PROFILE}-${DIAGNOSTICS}-${ACTIVE_FAULT_MODE}-bink-self-test-${BINK_SELF_TEST}-resource-allocator-self-test-${RESOURCE_ALLOCATOR_SELF_TEST}-clear-only-pass-self-test-${CLEAR_ONLY_PASS_SELF_TEST}-shading-prototype-tile-self-test-${SHADING_PROTOTYPE_TILE_SELF_TEST}-shading-prototype-forward-self-test-${SHADING_PROTOTYPE_FORWARD_SELF_TEST}"
ARTIFACT_DIR="$GITHUB_WORKSPACE/device-artifact"
PACKAGE_ROOT="$RUNNER_TEMP/renderer-ios-device-package"
rm -rf "$ARTIFACT_DIR" "$PACKAGE_ROOT"
mkdir -p "$ARTIFACT_DIR" "$PACKAGE_ROOT/Payload"
cp -R "$APP" "$PACKAGE_ROOT/Payload/"
(cd "$PACKAGE_ROOT" && /usr/bin/zip -qry "$ARTIFACT_DIR/$BASENAME.ipa" Payload)

TEMPEST_SHA="$(git -C lib/Tempest rev-parse HEAD)"
IPA_SHA256="$(shasum -a 256 "$ARTIFACT_DIR/$BASENAME.ipa" | awk '{print $1}')"
SAVE_PREVIEW_ROUTE='cpu-placeholder'
if [ "$DIAGNOSTICS" = 'ON' ]; then
  case "$ACTIVE_FAULT_MODE" in
    preview-attachment-missing|preview-readback-error|preview-fence-error-after-terminal)
      SAVE_PREVIEW_ROUTE='gpu-diagnostic'
      ;;
  esac
fi
cat > "$ARTIFACT_DIR/$BASENAME-provenance.txt" <<EOF
repository=$GITHUB_REPOSITORY
workflow_run_id=$GITHUB_RUN_ID
workflow_run_attempt=$GITHUB_RUN_ATTEMPT
commit_sha=$GITHUB_SHA
tempest_sha=$TEMPEST_SHA
tempest_profile=$TEMPEST_PROFILE
diagnostics=$DIAGNOSTICS
fault_mode=$ACTIVE_FAULT_MODE
bink_self_test=$BINK_SELF_TEST
resource_allocator_self_test=$RESOURCE_ALLOCATOR_SELF_TEST
clear_only_pass_self_test=$CLEAR_ONLY_PASS_SELF_TEST
shading_prototype_tile_self_test=$SHADING_PROTOTYPE_TILE_SELF_TEST
shading_prototype_forward_self_test=$SHADING_PROTOTYPE_FORWARD_SELF_TEST
save_preview_route=$SAVE_PREVIEW_ROUTE
bundle_id=$BUNDLE_ID
bundle_version=$BUNDLE_VERSION
minimum_ios_version=$MINIMUM_OS
signed=false
ipa_sha256=$IPA_SHA256
runtime_evidence_required=true
EOF
}

if [ "$PACKAGE_DEVICE_IPA" = 1 ]; then
  if [ "$PROFILE" != off ] && [ "$PROFILE" != on ]; then
    echo "only OFF/ON profiles may package device IPA" >&2
    exit 2
  fi
  package_device_ipa
fi

printf 'RendererIOS CI profile passed: %s\n' "$PROFILE"
