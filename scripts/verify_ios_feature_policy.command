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

scope_files=(
  game/graphics/iosfeaturepolicy.h
  game/graphics/iosfeaturepolicy.cpp
  ios/tests/iosfeaturepolicy.cpp
  scripts/verify_ios_feature_policy.command
)
policy_files=(
  game/graphics/iosfeaturepolicy.h
  game/graphics/iosfeaturepolicy.cpp
  ios/tests/iosfeaturepolicy.cpp
)
for file in "${scope_files[@]}"; do
  test -f "$file"
done
test "$(find game/graphics ios/tests scripts -maxdepth 1 -type f \
    \( -name 'iosfeaturepolicy*' \
       -o -name 'verify_ios_feature_policy.command' \) |
    LC_ALL=C sort)" = \
  $'game/graphics/iosfeaturepolicy.cpp\ngame/graphics/iosfeaturepolicy.h\nios/tests/iosfeaturepolicy.cpp\nscripts/verify_ios_feature_policy.command'

directives() {
  grep -E '^[[:space:]]*(#|%:)' "$1"
}
test "$(directives game/graphics/iosfeaturepolicy.h)" = \
  $'#pragma once\n#include "iosdevicecapabilities.h"\n#include <cstddef>\n#include <cstdint>\n#include <type_traits>'
test "$(directives game/graphics/iosfeaturepolicy.cpp)" = \
  $'#include "iosfeaturepolicy.h"'
test "$(directives ios/tests/iosfeaturepolicy.cpp)" = \
  $'#include "graphics/iosfeaturepolicy.h"\n#include <cassert>\n#include <cstddef>\n#include <cstdint>\n#include <type_traits>\n#include <utility>'

POLICY_DENY='#import|<Metal/|@interface|@protocol|__OBJC__|MTL[A-Z]|Tempest|IOSMetalContext|IOSDeviceNative|iosCollectDeviceFacts|iosMapDeviceNativeSnapshot|Foundation|UIKit|QuartzCore|CAMetalLayer|hw\.machine|sysctlbyname|highestKnownAppleFamily|highestKnownMetalFamily|runtimeVersion|sdkVersion|knownLimitMask|formats\[|void[[:space:]]*\*|NativeHandle|newLibrary|newCommand|defaultsFromFacts|defaultClassFromFacts|malloc|calloc|realloc|operator[[:space:]]+new'
if grep -Eni "$POLICY_DENY" \
    game/graphics/iosfeaturepolicy.h \
    game/graphics/iosfeaturepolicy.cpp; then
  echo 'P2.6d policy leaks native/runtime/facts-derived defaults'
  exit 1
fi
POLICY_NEW_DENY='(^|[^[:alnum:]_])new([[:space:]]|\[)'
POLICY_DYNAMIC_DENY='std::(vector|deque|list|forward_list|map|multimap|unordered_map|unordered_multimap|set|multiset|unordered_set|unordered_multiset|basic_string|string|wstring|u8string|u16string|u32string|unique_ptr|shared_ptr|weak_ptr|function|any)([^[:alnum:]_]|$)'
if grep -En "$POLICY_NEW_DENY|$POLICY_DYNAMIC_DENY" \
    "${policy_files[@]}"; then
  echo 'P2.6d policy uses dynamic allocation or storage'
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
ASAN_OPTIONS=halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
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
import re
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

expected_matrix = (
    False, False, False, False, False,
    True,  True,  False, False, False,
    True,  True,  True,  True,  False,
    True,  True,  True,  True,  True,
)
matrix_labels = tuple(
    f"matrix-{defaults}-{feature}"
    for defaults in ("safe", "apple8", "apple9", "apple10")
    for feature in ("spatial", "temporal", "mesh", "rt", "metal4")
)

def compact(value):
    return "".join(value.split())

def replace_once(value, old, new):
    if value.count(old) != 1:
        raise ValueError("mutation anchor count drifted: " + old)
    return value.replace(old, new, 1)

def resolver_segment(value):
    begin = value.index(
        "IOSFeatureDefaultRequest iosResolveFeatureDefaultRequest("
    )
    end = value.index(
        "IOSFeaturePolicyState iosEvaluateFeaturePolicyDefaults(",
        begin,
    )
    return value[begin:end]

def wrapper_segment(value):
    begin = value.index(
        "IOSFeaturePolicyState iosEvaluateFeaturePolicyDefaults("
    )
    return value[begin:]

def table_matches(value):
    resolver = resolver_segment(value)
    return list(re.finditer(
        r"return \{(true|false),"
        r"IOSFeatureFallbackReason::None\};",
        resolver,
    ))

def validate_contract():
    compact_header = compact(header)
    compact_source = compact(source)
    compact_test = compact(test)
    header_contracts = (
        "IOSFeatureIdfeature;IOSFeatureDefaultClassdefaults;"
        "boolactivationSucceeded;",
        "boolrequested;IOSFeatureFallbackReasonfallbackReason;",
        "InvalidDefaultClass=8u",
        "Safe=0u,Apple8=1u,Apple9=2u,Apple10=3u,Count=4u",
        "sizeof(IOSFeaturePolicyDefaultsInput)==3u",
        "alignof(IOSFeaturePolicyDefaultsInput)==1u",
        "sizeof(IOSFeatureDefaultRequest)==2u",
        "alignof(IOSFeatureDefaultRequest)==1u",
    )
    for contract in header_contracts:
        if compact_header.count(contract) != 1:
            raise ValueError("P2.6d header contract changed: " + contract)

    resolver = resolver_segment(source)
    compact_resolver = compact(resolver)
    if "IOSDeviceFacts" in resolver or "facts." in resolver:
        raise ValueError("pure defaults resolver depends on facts")
    signature = (
        "iosResolveFeatureDefaultRequest("
        "IOSFeatureIdfeature,IOSFeatureDefaultClassdefaults)noexcept"
    )
    if signature not in compact_resolver:
        raise ValueError("pure defaults resolver signature changed")
    feature_guard = (
        "if(!featureProbe(feature,unusedProbe))"
        "return{false,IOSFeatureFallbackReason::InvalidFeature};"
    )
    default_guard = (
        "if(!validDefaultClass(defaults))"
        "return{false,IOSFeatureFallbackReason::InvalidDefaultClass};"
    )
    if compact_resolver.index(feature_guard) >= \
            compact_resolver.index(default_guard):
        raise ValueError("invalid feature/default precedence changed")

    matches = table_matches(source)
    actual_matrix = tuple(
        match.group(1) == "true" for match in matches
    )
    if actual_matrix != expected_matrix:
        raise ValueError("explicit 4x5 defaults matrix changed")

    wrapper = compact(wrapper_segment(source))
    if "facts.facts()" in wrapper:
        raise ValueError("defaults wrapper reads facts directly")
    delegation = (
        "iosEvaluateFeaturePolicy(facts,"
        "{input.feature,request.requested,input.activationSucceeded})"
    )
    if wrapper.count(delegation) != 1:
        raise ValueError("defaults wrapper delegation changed")
    invalid_override = (
        "if(request.fallbackReason!="
        "IOSFeatureFallbackReason::None)"
        "state.fallbackReason=request.fallbackReason;"
    )
    if wrapper.count(invalid_override) != 1:
        raise ValueError("invalid defaults propagation changed")

    existing_eligibility = (
        "state.eligible=availabilityKnown&&availabilityPassed&&"
        "deviceSupportKnown&&deviceSupportPassed;"
    )
    if compact_source.count(existing_eligibility) != 1:
        raise ValueError("P2.6c facts-only eligibility changed")
    existing_order = (
        "if(!input.requested)",
        "if(!availabilityKnown)",
        "if(!availabilityPassed)",
        "if(!deviceSupportKnown)",
        "if(!deviceSupportPassed)",
        "if(!input.activationSucceeded)",
        "state.active=true;",
    )
    positions = [compact_source.index(anchor) for anchor in existing_order]
    if positions != sorted(positions):
        raise ValueError("P2.6c fallback precedence changed")

    test_anchors = (
        "ExpectedRequests[DefaultClassCount][ProbeCount]",
        "testExactDefaultMatrix();",
        "testCapabilityFallbacksForEveryFeature();",
        "testActivationFailureForEveryFeature();",
        "testInvalidInputsAndPrecedence();",
        "testFactsNeverChooseOrBypassDefaults();",
        "testExplicitRequestRegression();",
        "IOSFeatureFallbackReason::InvalidDefaultClass",
        "IOSFeatureDefaultClass::Count,InvalidDefaults",
        "highData.highestKnownAppleFamily=10u;",
        "highData.runtimeVersion={99u,1u,2u,0u};",
    )
    for anchor in test_anchors:
        if anchor not in compact_test:
            raise ValueError("P2.6d test oracle changed: " + anchor)

def mutation_is_killed(label, candidate_source):
    case_root = mutation_root / label
    graphics = case_root / "graphics"
    graphics.mkdir(parents=True)
    (graphics / "iosfeaturepolicy.h").write_text(header)
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
        raise SystemExit(
            "P2.6d mutant did not compile: "
            + label
            + "\n"
            + compile_result.stderr.decode(errors="replace")
        )
    sign_result = subprocess.run(
        ["codesign", "-f", "-s", "-", str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if sign_result.returncode != 0:
        raise SystemExit("P2.6d mutation codesign failed: " + label)
    run_result = subprocess.run(
        [str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return run_result.returncode != 0

validate_contract()
mutations = []

matches = table_matches(source)
if len(matches) != 20:
    raise SystemExit("P2.6d defaults matrix anchor count drifted")
for index, match in enumerate(matches):
    old = match.group(1)
    new = "false" if old == "true" else "true"
    start = (
        source.index(
            "IOSFeatureDefaultRequest iosResolveFeatureDefaultRequest("
        )
        + match.start(1)
    )
    candidate = source[:start] + new + source[start + len(old):]
    mutations.append((matrix_labels[index], candidate))

feature_guard = (
    "  IOSDeviceProbeId unusedProbe = IOSDeviceProbeId::Count;\n"
    "  if(!featureProbe(feature,unusedProbe))\n"
    "    return {false,IOSFeatureFallbackReason::InvalidFeature};\n"
)
default_guard = (
    "  if(!validDefaultClass(defaults))\n"
    "    return {false,IOSFeatureFallbackReason::InvalidDefaultClass};\n"
)
mutations.append((
    "invalid-enum-precedence",
    replace_once(
        source,
        feature_guard + default_guard,
        default_guard + feature_guard,
    ),
))

delegation = (
    "      {input.feature,request.requested,input.activationSucceeded});"
)
request_dependencies = (
    (
        "probe-dependent-request",
        "      {input.feature,\n"
        "       request.requested &&\n"
        "           (facts.facts().probes[0].passedStages &\n"
        "            DeviceSupport)!=0u,\n"
        "       input.activationSucceeded});",
    ),
    (
        "family-dependent-request",
        "      {input.feature,\n"
        "       request.requested &&\n"
        "           facts.facts().highestKnownAppleFamily>=10u,\n"
        "       input.activationSucceeded});",
    ),
    (
        "format-dependent-request",
        "      {input.feature,\n"
        "       request.requested &&\n"
        "           facts.facts().formats[0].supportedUsages!=0u,\n"
        "       input.activationSucceeded});",
    ),
    (
        "limit-dependent-request",
        "      {input.feature,\n"
        "       request.requested &&\n"
        "           facts.facts().knownLimitMask!=0u,\n"
        "       input.activationSucceeded});",
    ),
    (
        "version-dependent-request",
        "      {input.feature,\n"
        "       request.requested &&\n"
        "           facts.facts().runtimeVersion.major!=0u,\n"
        "       input.activationSucceeded});",
    ),
)
for label, replacement in request_dependencies:
    mutations.append((
        label,
        replace_once(source,delegation,replacement),
    ))

mutations.append((
    "capability-bypass",
    replace_once(
        source,
        "  state.eligible =\n"
        "      availabilityKnown && availabilityPassed &&\n"
        "      deviceSupportKnown && deviceSupportPassed;",
        "  state.eligible = true;",
    ),
))
mutations.append((
    "activation-bypass",
    replace_once(
        source,
        "  if(!input.activationSucceeded) {",
        "  if(false) {",
    ),
))
mutations.append((
    "invalid-default-handling",
    replace_once(
        source,
        "  if(request.fallbackReason!=IOSFeatureFallbackReason::None)",
        "  if(false)",
    ),
))

killed = 0
for label, candidate_source in mutations:
    if mutation_is_killed(label,candidate_source):
        killed += 1
        continue
    raise SystemExit("P2.6d executable mutation survived: " + label)
if killed != 29:
    raise SystemExit(
        f"P2.6d mutation count drifted: {killed}/29"
    )
shutil.rmtree(mutation_root)
print(
    "P2.6d executable mutation oracle: "
    f"compiled=29 executed=29 mutations-killed={killed}"
)
PY

echo "P2.6d IOSFeaturePolicy defaults: PASS"
