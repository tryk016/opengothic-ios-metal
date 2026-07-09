#!/usr/bin/env bash
set -euo pipefail

# Applies local fixes to submodules that are fetched fresh from upstream.
# Idempotent and CRLF-tolerant. Fails loudly if a patch does not apply, so CI
# never silently produces a broken binary. Both CI and the Mac build call this.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

VC="$ROOT/lib/Tempest/Engine/system/api/iosapi.mm"

# Fix: ViewController -init must call [super init]. Without it the view
# controller has no initial trait collection and iOS 17/18 throws
# UIViewControllerMissingInitialTraitCollection during
# -[AppDelegate application:didFinishLaunchingWithOptions:], crashing on launch.
if [ ! -f "$VC" ]; then
  echo "ERROR: not found: $VC" >&2
  exit 1
fi

if grep -q 'self = \[super init\]' "$VC"; then
  echo "skip: iosapi.mm ViewController [super init] (already patched)"
else
  perl -0777 -pi -e \
    's/(-\(id\)init \{\r?\n)(\s*)(fullScreen = true;)/${1}${2}self = [super init];\n${2}${3}/' \
    "$VC"
  if grep -q 'self = \[super init\]' "$VC"; then
    echo "patched: iosapi.mm ViewController [super init]"
  else
    echo "ERROR: failed to patch iosapi.mm ViewController (pattern not found)" >&2
    exit 1
  fi
fi
