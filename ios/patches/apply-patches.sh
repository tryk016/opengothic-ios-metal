#!/usr/bin/env bash
set -euo pipefail

# Historical name retained because local builds and CI already call this path.
# Tempest is now a maintained fork pinned by gitlink, so this script is a
# read-only verifier. It must never mutate the submodule working tree.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPEST_ROOT="${TEMPEST_ROOT:-$ROOT/lib/Tempest}"

EXPECTED_URL="https://github.com/tryk016/Tempest.git"
BASE_COMMIT="61b58f710b00f64d190fed2661f5762909397d1a"
EXPECTED_COMMIT="08624ab2608002c9d98fd209fe0c4b4213168175"

fail() {
  echo "ERROR: $*" >&2
  exit 1
  }

require_file() {
  local file="$1"
  [ -f "$file" ] || fail "required Tempest file is missing: $file"
  }

require_literal() {
  local file="$1"
  local text="$2"
  local label="$3"
  grep -Fq -- "$text" "$file" || fail "Tempest fork marker is missing: $label"
  }

require_regex() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  grep -Eq -- "$pattern" "$file" || fail "Tempest fork marker is missing: $label"
  }

[ -d "$TEMPEST_ROOT" ] || fail "Tempest checkout is missing: $TEMPEST_ROOT"

configured_url="$(git config -f "$ROOT/.gitmodules" --get submodule.lib/Tempest.url || true)"
[ "$configured_url" = "$EXPECTED_URL" ] ||
  fail ".gitmodules Tempest URL is '$configured_url', expected '$EXPECTED_URL'"

recorded_commit="$(git -C "$ROOT" rev-parse ':lib/Tempest')"
[ "$recorded_commit" = "$EXPECTED_COMMIT" ] ||
  fail "parent gitlink is $recorded_commit, expected $EXPECTED_COMMIT"

actual_commit="$(git -C "$TEMPEST_ROOT" rev-parse HEAD)"
[ "$actual_commit" = "$EXPECTED_COMMIT" ] ||
  fail "Tempest gitlink is $actual_commit, expected $EXPECTED_COMMIT"

git -C "$TEMPEST_ROOT" cat-file -e "$BASE_COMMIT^{commit}" ||
  fail "Tempest compatibility base is unavailable: $BASE_COMMIT"
git -C "$TEMPEST_ROOT" merge-base --is-ancestor "$BASE_COMMIT" "$actual_commit" ||
  fail "Tempest fork commit is not descended from compatibility base $BASE_COMMIT"

dirty="$(git -C "$TEMPEST_ROOT" status --porcelain --untracked-files=all)"
if [ -n "$dirty" ]; then
  echo "$dirty" >&2
  fail "Tempest checkout is dirty; the verifier never applies patches"
fi

IOS_API="$TEMPEST_ROOT/Engine/system/api/iosapi.mm"
EVENT_API="$TEMPEST_ROOT/Engine/ui/event.h"
WINDOW_API="$TEMPEST_ROOT/Engine/ui/window.h"
WINDOW_IMPL="$TEMPEST_ROOT/Engine/ui/window.cpp"
SYSTEM_API_HEADER="$TEMPEST_ROOT/Engine/system/systemapi.h"
SYSTEM_API="$TEMPEST_ROOT/Engine/system/systemapi.cpp"
RFILE="$TEMPEST_ROOT/Engine/io/rfile.mm"
SWAPCHAIN="$TEMPEST_ROOT/Engine/gapi/metal/mtswapchain.mm"
SPATIAL="$TEMPEST_ROOT/Engine/gapi/metal/mtspatialscaler.mm"
TEMPORAL="$TEMPEST_ROOT/Engine/gapi/metal/mttemporalscaler.mm"
TEMPEST_CMAKE="$TEMPEST_ROOT/Engine/CMakeLists.txt"
ASYNC_STATE="$TEMPEST_ROOT/Engine/gapi/metal/mtasyncstate.h"
ABSTRACT_API="$TEMPEST_ROOT/Engine/gapi/abstractgraphicsapi.h"
APP_STATE_TEST="$TEMPEST_ROOT/Tests/tests/appstateevent_compile_test.cpp"
METAL_API_HEADER="$TEMPEST_ROOT/Engine/gapi/metalapi.h"
METAL_API_IMPL="$TEMPEST_ROOT/Engine/gapi/metalapi.cpp"
METAL_BORROW_COMPILE_TEST="$TEMPEST_ROOT/Tests/tests/metalapi_borrowed_handle_compile_test.cpp"
METAL_TEST="$TEMPEST_ROOT/Tests/tests/gapi/metal_test.cpp"

require_file "$IOS_API"
require_file "$EVENT_API"
require_file "$WINDOW_API"
require_file "$WINDOW_IMPL"
require_file "$SYSTEM_API_HEADER"
require_file "$SYSTEM_API"
require_file "$RFILE"
require_file "$SWAPCHAIN"
require_file "$SPATIAL"
require_file "$TEMPORAL"
require_file "$TEMPEST_CMAKE"
require_file "$ASYNC_STATE"
require_file "$ABSTRACT_API"
require_file "$APP_STATE_TEST"
require_file "$METAL_API_HEADER"
require_file "$METAL_API_IMPL"
require_file "$METAL_BORROW_COMPILE_TEST"
require_file "$METAL_TEST"
require_file "$TEMPEST_ROOT/Engine/include/Tempest/SpatialScaler"
require_file "$TEMPEST_ROOT/Engine/include/Tempest/TemporalScaler"
require_file "$TEMPEST_ROOT/Engine/include/Tempest/MetalApi"

require_literal "$IOS_API" "self = [super init];" "UIViewController super init"
require_literal "$IOS_API" "touchesCancelled" "touch cancellation"
require_literal "$IOS_API" "appleStack[8*1024*1024]" "8 MB game-fiber stack"
require_literal "$IOS_API" "displayLink invalidate" "display-link teardown"
require_literal "$IOS_API" "UIInterfaceOrientationMaskLandscape" "landscape lock"
require_literal "$IOS_API" "idleTimerDisabled" "idle-timer policy"
require_literal "$IOS_API" "tempestIosSetPreferredFrameRate" "runtime frame cadence"
require_literal "$IOS_API" "uncaught exception in iOS event dispatch" "event exception guard"
require_literal "$IOS_API" "no-objc-pool" "fiber autorelease-pool guard"
require_literal "$EVENT_API" "class AppStateEvent" "typed application-state event"
require_literal "$WINDOW_API" "appStateEvent" "root application-state callback"
require_literal "$WINDOW_IMPL" "void Window::appStateEvent" "default application-state callback"
require_literal "$SYSTEM_API_HEADER" "dispatchAppState" "application-state dispatch declaration"
require_literal "$SYSTEM_API" "dispatchAppState" "root-only application-state dispatch"
require_literal "$IOS_API" "AppStateEvent::State::WillResignActive" "resign-active bridge"
require_literal "$IOS_API" "AppStateEvent::State::DidEnterBackground" "enter-background bridge"
require_literal "$IOS_API" "AppStateEvent::State::WillEnterForeground" "enter-foreground bridge"
require_literal "$IOS_API" "AppStateEvent::State::DidBecomeActive" "become-active bridge"
require_literal "$IOS_API" "case Event::AppState" "application-state event routing"
require_literal "$APP_STATE_TEST" "class AppStateWindow" "application-state API compile test"
require_literal "$RFILE" "cwd-first" "writable-file lookup"
require_regex "$SWAPCHAIN" 'maximumDrawableCount[[:space:]]*=[[:space:]]*3;' "triple buffering"
require_literal "$SWAPCHAIN" "Direct-drawable v2 experiment" "direct drawable"
require_literal "$SPATIAL" "MetalApi::createSpatialScaler" "MetalFX Spatial"
require_literal "$TEMPORAL" "MetalApi::createTemporalScaler" "MetalFX Temporal"
require_literal "$TEMPEST_CMAKE" "OPENGOTHIC_METALFX_SPATIAL" "Spatial build option"
require_literal "$TEMPEST_CMAKE" "OPENGOTHIC_METALFX_TEMPORAL" "Temporal build option"
require_literal "$ABSTRACT_API" "takePresentFailure" "asynchronous present failure API"
require_literal "$ASYNC_STATE" "SubmissionToken" "exactly-once Metal completion token"
require_literal "$ASYNC_STATE" "takePresentFailure" "present failure mailbox"
require_literal "$ASYNC_STATE" "presentFatal" "persistent post-failure submission gate"
require_literal "$SWAPCHAIN" "TEMPEST_METAL_FAULT_ASYNC_PRESENT_AFTER_TERMINAL" "async present fault seam"
require_literal "$METAL_API_HEADER" "BorrowedMetalDevice" "borrowed Metal device handle"
require_literal "$METAL_API_HEADER" "borrowDevice" "borrowed Metal device API"
require_literal "$METAL_API_HEADER" "borrowBuffer" "borrowed Metal buffer API"
require_literal "$METAL_API_HEADER" "borrowTexture" "borrowed Metal texture API"
require_literal "$METAL_API_IMPL" "nativeBuffer->dev!=nativeDevice" "foreign Metal buffer rejection"
require_literal "$METAL_API_IMPL" "&nativeTexture->dev!=nativeDevice" "foreign Metal texture rejection"
require_literal "$METAL_BORROW_COMPILE_TEST" "isBorrowedHandleContract" "borrowed Metal handle compile contract"
require_literal "$METAL_TEST" "BorrowedNativeHandles" "borrowed Metal runtime test"
require_literal "$METAL_TEST" "nativeIbo" "borrowed Metal index-buffer coverage"

echo "verified: Tempest renderer-ios fork $actual_commit (clean, async present + app-state + borrowed Metal resource bridges)"
