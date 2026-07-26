#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TMP_GATE="$(mktemp -d "${TMPDIR:-/tmp}/iosfeaturepolicy.XXXXXX")"

cleanup() {
  rm -rf -- "$TMP_GATE"
}
trap cleanup EXIT

cd "$REPO"

policy_files=(
  game/graphics/iosfeaturepolicy.h
  game/graphics/iosfeaturepolicy.cpp
  ios/tests/iosfeaturepolicy.cpp
)
for file in "${policy_files[@]}"; do
  test -f "$file"
done
test "$(find game/graphics ios/tests -maxdepth 1 -type f \
    -name 'iosfeaturepolicy*' | LC_ALL=C sort)" = \
  $'game/graphics/iosfeaturepolicy.cpp\ngame/graphics/iosfeaturepolicy.h\nios/tests/iosfeaturepolicy.cpp'

directives() {
  grep -E '^[[:space:]]*(#|%:)' "$1"
}
test "$(directives game/graphics/iosfeaturepolicy.h)" = \
  $'#pragma once\n#include "iosdevicecapabilities.h"\n#include <cstddef>\n#include <cstdint>\n#include <type_traits>'
test "$(directives game/graphics/iosfeaturepolicy.cpp)" = \
  $'#include "iosfeaturepolicy.h"'
test "$(directives ios/tests/iosfeaturepolicy.cpp)" = \
  $'#include "graphics/iosfeaturepolicy.h"\n#include <cassert>\n#include <cstddef>\n#include <cstdint>\n#include <type_traits>\n#include <utility>'

POLICY_DENY='#import|<Metal/|@interface|@protocol|__OBJC__|MTL[A-Z]|Tempest|IOSMetalContext|IOSDeviceNative|iosCollectDeviceFacts|iosMapDeviceNativeSnapshot|Foundation|UIKit|QuartzCore|CAMetalLayer|hw\.machine|sysctlbyname|highestKnownAppleFamily|highestKnownMetalFamily|runtimeVersion|sdkVersion|knownLimitMask|formats\[|void[[:space:]]*\*|NativeHandle|newLibrary|newCommand|malloc|calloc|realloc|operator[[:space:]]+new'
if grep -Eni "$POLICY_DENY" \
    game/graphics/iosfeaturepolicy.h \
    game/graphics/iosfeaturepolicy.cpp; then
  echo 'P2.6c policy leaks native/runtime/family/format/limit inference'
  exit 1
fi
POLICY_NEW_DENY='(^|[^[:alnum:]_])new([[:space:]]|\[)'
POLICY_DYNAMIC_DENY='std::(vector|deque|list|forward_list|map|multimap|unordered_map|unordered_multimap|set|multiset|unordered_set|unordered_multiset|basic_string|string|wstring|u8string|u16string|u32string|unique_ptr|shared_ptr|weak_ptr|function|any)([^[:alnum:]_]|$)'
if grep -En "$POLICY_NEW_DENY|$POLICY_DYNAMIC_DENY" \
    "${policy_files[@]}"; then
  echo 'P2.6c policy uses dynamic allocation or storage'
  exit 1
fi
printf '%s\n' 'highestKnownAppleFamily >= 10u' |
  grep -Eq "$POLICY_DENY"
printf '%s\n' 'std::vector<int> policy;' |
  grep -Eq "$POLICY_DYNAMIC_DENY"

printf '#include "graphics/iosfeaturepolicy.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosfeaturepolicy.cpp \
  game/graphics/iosfeaturepolicy.cpp \
  game/graphics/iosdevicecapabilities.cpp \
  -o "$TMP_GATE/iosfeaturepolicy"
codesign -f -s - "$TMP_GATE/iosfeaturepolicy"
"$TMP_GATE/iosfeaturepolicy"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Igame \
  ios/tests/iosfeaturepolicy.cpp \
  game/graphics/iosfeaturepolicy.cpp \
  game/graphics/iosdevicecapabilities.cpp \
  -o "$TMP_GATE/iosfeaturepolicy-sanitized"
codesign -f -s - "$TMP_GATE/iosfeaturepolicy-sanitized"
"$TMP_GATE/iosfeaturepolicy-sanitized"

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun clang++ -x c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame -fsyntax-only \
  game/graphics/iosfeaturepolicy.cpp \
  ios/tests/iosfeaturepolicy.cpp

IOS_FEATURE_POLICY_MUTATION_ROOT="$TMP_GATE/mutations" python3 - <<'PY'
import os
import shutil
import subprocess
from pathlib import Path

header = Path("game/graphics/iosfeaturepolicy.h").read_text()
source = Path("game/graphics/iosfeaturepolicy.cpp").read_text()
test = Path("ios/tests/iosfeaturepolicy.cpp").read_text()
capability_header = Path(
    "game/graphics/iosdevicecapabilities.h"
).read_text()
mutation_root = Path(os.environ["IOS_FEATURE_POLICY_MUTATION_ROOT"])

def compact(value):
    return "".join(value.split())

def replace_once(value, old, new):
    if value.count(old) != 1:
        raise ValueError("mutation anchor count drifted: " + old)
    return value.replace(old, new, 1)

def validate_contract():
    compact_header = compact(header)
    compact_source = compact(source)
    compact_test = compact(test)
    fields = (
        "IOSFeatureIdfeature;boolrequested;boolactivationSucceeded;",
        "boolrequested;booleligible;boolactive;"
        "IOSFeatureFallbackReasonfallbackReason;",
    )
    for field in fields:
        if compact_header.count(field) != 1:
            raise ValueError("policy field contract changed")
    mappings = (
        "caseIOSFeatureId::MetalFxSpatial:"
        "probe=IOSDeviceProbeId::MetalFxSpatial;",
        "caseIOSFeatureId::MetalFxTemporal:"
        "probe=IOSDeviceProbeId::MetalFxTemporal;",
        "caseIOSFeatureId::MeshShading:"
        "probe=IOSDeviceProbeId::MeshShading;",
        "caseIOSFeatureId::RayTracing:"
        "probe=IOSDeviceProbeId::RayTracing;",
        "caseIOSFeatureId::Metal4Transport:"
        "probe=IOSDeviceProbeId::Metal4Transport;",
    )
    for mapping in mappings:
        if compact_source.count(mapping) != 1:
            raise ValueError("feature to probe mapping changed")
    ordered = (
        "if(!input.requested)",
        "if(!availabilityKnown)",
        "if(!availabilityPassed)",
        "if(!deviceSupportKnown)",
        "if(!deviceSupportPassed)",
        "if(!input.activationSucceeded)",
        "state.active=true;",
        "state.fallbackReason=IOSFeatureFallbackReason::None;",
    )
    positions = [compact_source.index(anchor) for anchor in ordered]
    if positions != sorted(positions):
        raise ValueError("fallback precedence changed")
    eligibility = (
        "state.eligible=availabilityKnown&&availabilityPassed&&"
        "deviceSupportKnown&&deviceSupportPassed;"
    )
    if compact_source.count(eligibility) != 1:
        raise ValueError("facts-only eligibility changed")
    forbidden = (
        "highestKnownAppleFamily",
        "highestKnownMetalFamily",
        "knownLimitMask",
        "formats[",
        "IOSDeviceNative",
        "iosCollectDeviceFacts",
    )
    if any(value in header + source for value in forbidden):
        raise ValueError("policy gained forbidden inference")
    test_anchors = (
        "IOSFeatureFallbackReason::InvalidFeature",
        "IOSFeatureFallbackReason::NotRequested",
        "IOSFeatureFallbackReason::AvailabilityUnknown",
        "IOSFeatureFallbackReason::AvailabilityUnsupported",
        "IOSFeatureFallbackReason::DeviceSupportUnknown",
        "IOSFeatureFallbackReason::DeviceSupportUnsupported",
        "IOSFeatureFallbackReason::ActivationFailed",
        "unrelatedPositive.highestKnownAppleFamily=10u;",
        "assert((state.fallbackReason==IOSFeatureFallbackReason::None)=="
        "state.active);",
    )
    for anchor in test_anchors:
        if anchor not in compact_test:
            raise ValueError("policy test oracle changed: " + anchor)

def mutation_is_killed(
    label,
    candidate_header,
    candidate_source,
):
    case_root = mutation_root / label
    graphics = case_root / "graphics"
    graphics.mkdir(parents=True)
    (graphics / "iosfeaturepolicy.h").write_text(candidate_header)
    (graphics / "iosfeaturepolicy.cpp").write_text(candidate_source)
    (graphics / "iosdevicecapabilities.h").write_text(capability_header)
    test_path = case_root / "iosfeaturepolicy.cpp"
    test_path.write_text(test)
    binary = case_root / "iosfeaturepolicy-mutant"
    compile_result = subprocess.run(
        [
            "xcrun",
            "clang++",
            "-std=c++20",
            "-Wall",
            "-Wextra",
            "-Wconversion",
            "-Wsign-conversion",
            "-Werror",
            f"-I{case_root}",
            str(test_path),
            str(graphics / "iosfeaturepolicy.cpp"),
            "game/graphics/iosdevicecapabilities.cpp",
            "-o",
            str(binary),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if compile_result.returncode != 0:
        return True
    sign_result = subprocess.run(
        ["codesign", "-f", "-s", "-", str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if sign_result.returncode != 0:
        raise SystemExit(
            "P2.6c mutation codesign failed: " + label
        )
    run_result = subprocess.run(
        [str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return run_result.returncode != 0

validate_contract()
mutations = []
mapping_pairs = (
    ("IOSDeviceProbeId::MetalFxSpatial", "IOSDeviceProbeId::MetalFxTemporal"),
    ("IOSDeviceProbeId::MetalFxTemporal", "IOSDeviceProbeId::MeshShading"),
    ("IOSDeviceProbeId::MeshShading", "IOSDeviceProbeId::RayTracing"),
    ("IOSDeviceProbeId::RayTracing", "IOSDeviceProbeId::Metal4Transport"),
    ("IOSDeviceProbeId::Metal4Transport", "IOSDeviceProbeId::MetalFxSpatial"),
)
for index, (old, new) in enumerate(mapping_pairs):
    mutations.append((
        f"mapping-{index}",
        header,
        replace_once(source, f"probe = {old};", f"probe = {new};"),
        test,
    ))
source_mutations = (
    (
        "requested-copy",
        "    input.requested,\n    false,",
        "    false,\n    false,",
    ),
    (
        "eligible-calculation",
        "availabilityKnown && availabilityPassed &&\n"
        "      deviceSupportKnown && deviceSupportPassed;",
        "availabilityKnown && availabilityPassed;",
    ),
    (
        "active-field",
        "state.active = true;",
        "state.active = false;",
    ),
    (
        "not-requested-reason",
        "IOSFeatureFallbackReason::NotRequested;",
        "IOSFeatureFallbackReason::ActivationFailed;",
    ),
    (
        "availability-unknown-reason",
        "IOSFeatureFallbackReason::AvailabilityUnknown;",
        "IOSFeatureFallbackReason::AvailabilityUnsupported;",
    ),
    (
        "availability-unsupported-reason",
        "IOSFeatureFallbackReason::AvailabilityUnsupported;",
        "IOSFeatureFallbackReason::DeviceSupportUnknown;",
    ),
    (
        "support-unknown-reason",
        "IOSFeatureFallbackReason::DeviceSupportUnknown;",
        "IOSFeatureFallbackReason::DeviceSupportUnsupported;",
    ),
    (
        "support-unsupported-reason",
        "IOSFeatureFallbackReason::DeviceSupportUnsupported;",
        "IOSFeatureFallbackReason::ActivationFailed;",
    ),
    (
        "activation-failed-reason",
        "IOSFeatureFallbackReason::ActivationFailed;",
        "IOSFeatureFallbackReason::None;",
    ),
)
for label, old, new in source_mutations:
    mutations.append((label, header, replace_once(source, old, new), test))
mutations.append(
    (
        "family-shortcut",
        header,
        replace_once(
            source,
            "state.eligible =\n"
            "      availabilityKnown && availabilityPassed &&\n"
            "      deviceSupportKnown && deviceSupportPassed;",
            "state.eligible =\n"
            "      facts.facts().highestKnownAppleFamily>=10u ||\n"
            "      (availabilityKnown && availabilityPassed &&\n"
            "       deviceSupportKnown && deviceSupportPassed);",
        ),
        test,
    )
)
killed = 0
for label, candidate_header, candidate_source, candidate_test in mutations:
    del candidate_test
    if mutation_is_killed(label,candidate_header,candidate_source):
        killed += 1
        continue
    raise SystemExit("P2.6c mutation survived: " + label)
if killed != 15:
    raise SystemExit("P2.6c mutation count drifted")
shutil.rmtree(mutation_root)
print(f"P2.6c executable mutation oracle: mutations-killed={killed}")
PY

echo "P2.6c IOSFeaturePolicy: PASS"
