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
  game/graphics/iosmetalcontext.h
  game/graphics/iosmetalcontext.cpp
  ios/tests/iosfeaturepolicy.cpp
  scripts/verify_ios_feature_policy.command
)
policy_files=(
  game/graphics/iosfeaturepolicy.h
  game/graphics/iosfeaturepolicy.cpp
  game/graphics/iosfeaturepolicyprovenance.h
  game/graphics/iosfeaturepolicyprovenance.cpp
  ios/tests/iosfeaturepolicy.cpp
)
for file in "${scope_files[@]}"; do
  test -f "$file"
done
test "$(find game/graphics ios/tests scripts -maxdepth 1 -type f \
    \( -name 'iosfeaturepolicy*' \
       -o -name 'verify_ios_feature_policy.command' \) |
    LC_ALL=C sort)" = \
  $'game/graphics/iosfeaturepolicy.cpp\ngame/graphics/iosfeaturepolicy.h\ngame/graphics/iosfeaturepolicyprovenance.cpp\ngame/graphics/iosfeaturepolicyprovenance.h\nios/tests/iosfeaturepolicy.cpp\nscripts/verify_ios_feature_policy.command'

directives() {
  grep -E '^[[:space:]]*(#|%:)' "$1"
}
test "$(directives game/graphics/iosfeaturepolicy.h)" = \
  $'#pragma once\n#include "iosdevicecapabilities.h"\n#include <cstddef>\n#include <cstdint>\n#include <type_traits>'
test "$(directives game/graphics/iosfeaturepolicy.cpp)" = \
  $'#include "iosfeaturepolicy.h"'
test "$(directives game/graphics/iosfeaturepolicyprovenance.h)" = \
  $'#pragma once\n#include "iosfeaturepolicy.h"\n#include <cstddef>\n#include <cstdint>\n#include <type_traits>'
test "$(directives game/graphics/iosfeaturepolicyprovenance.cpp)" = \
  $'#include "iosfeaturepolicyprovenance.h"\n#include <cstdio>\n#include <cstring>'
test "$(directives ios/tests/iosfeaturepolicy.cpp)" = \
  $'#include "graphics/iosfeaturepolicy.h"\n#include "graphics/iosfeaturepolicyprovenance.h"\n#include <cassert>\n#include <cstddef>\n#include <cstdint>\n#include <cstring>\n#include <type_traits>\n#include <utility>'

POLICY_DENY='#import|<Metal/|@interface|@protocol|__OBJC__|MTL[A-Z]|Tempest|IOSMetalContext|IOSDeviceNative|iosCollectDeviceFacts|iosMapDeviceNativeSnapshot|Foundation|UIKit|QuartzCore|CAMetalLayer|hw\.machine|sysctlbyname|highestKnownAppleFamily|highestKnownMetalFamily|runtimeVersion|sdkVersion|knownLimitMask|formats\[|void[[:space:]]*\*|NativeHandle|newLibrary|newCommand|defaultsFromFacts|defaultClassFromFacts|malloc|calloc|realloc|operator[[:space:]]+new'
if grep -Eni "$POLICY_DENY" \
    game/graphics/iosfeaturepolicy.h \
    game/graphics/iosfeaturepolicy.cpp \
    game/graphics/iosfeaturepolicyprovenance.h \
    game/graphics/iosfeaturepolicyprovenance.cpp; then
  echo 'P2.6e1 policy leaks native/runtime/facts-derived behavior'
  exit 1
fi
POLICY_NEW_DENY='(^|[^[:alnum:]_])new([[:space:]]|\[)'
POLICY_DYNAMIC_DENY='std::(vector|deque|list|forward_list|map|multimap|unordered_map|unordered_multimap|set|multiset|unordered_set|unordered_multiset|basic_string|string|wstring|u8string|u16string|u32string|unique_ptr|shared_ptr|weak_ptr|function|any)([^[:alnum:]_]|$)'
if grep -En "$POLICY_NEW_DENY|$POLICY_DYNAMIC_DENY" \
    "${policy_files[@]}"; then
  echo 'P2.6e1 policy uses dynamic allocation or storage'
  exit 1
fi
printf '%s\n' 'highestKnownAppleFamily >= 10u' |
  grep -Eq "$POLICY_DENY"
printf '%s\n' 'std::vector<int> policy;' |
  grep -Eq "$POLICY_DYNAMIC_DENY"

printf '#include "graphics/iosfeaturepolicyprovenance.h"\nint main() { return 0; }\n' |
  xcrun clang++ -x c++ -std=c++20 \
    -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
    -Igame -fsyntax-only -

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  ios/tests/iosfeaturepolicy.cpp \
  game/graphics/iosfeaturepolicyprovenance.cpp \
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
  game/graphics/iosfeaturepolicyprovenance.cpp \
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
  game/graphics/iosfeaturepolicyprovenance.cpp \
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
provenance_header = Path(
    "game/graphics/iosfeaturepolicyprovenance.h"
).read_text()
provenance_source = Path(
    "game/graphics/iosfeaturepolicyprovenance.cpp"
).read_text()
test = Path("ios/tests/iosfeaturepolicy.cpp").read_text()
capability_header = Path(
    "game/graphics/iosdevicecapabilities.h"
).read_text()
context_header = Path("game/graphics/iosmetalcontext.h").read_text()
context_source = Path("game/graphics/iosmetalcontext.cpp").read_text()
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
    (graphics / "iosfeaturepolicyprovenance.h").write_text(
        provenance_header
    )
    (graphics / "iosfeaturepolicyprovenance.cpp").write_text(
        provenance_source
    )
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
            str(graphics / "iosfeaturepolicyprovenance.cpp"),
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

def validate_provenance_contract():
    compact_header = compact(provenance_header)
    compact_source = compact(provenance_source)
    compact_test = compact(test)
    header_contracts = (
        "IOSFeaturePolicyProvenanceSchemaVersion=1u",
        "IOSFeaturePolicyTelemetryCapacity=295u",
        "sizeof(IOSFeatureActivationResults)==5u",
        "alignof(IOSFeatureActivationResults)==1u",
        "sizeof(IOSFeaturePolicyDecision)==6u",
        "alignof(IOSFeaturePolicyDecision)==1u",
        "sizeof(IOSFeaturePolicyProvenanceStorage)==40u",
        "alignof(IOSFeaturePolicyProvenanceStorage)==4u",
        "sizeof(IOSFeaturePolicyProvenance)==40u",
        "alignof(IOSFeaturePolicyProvenance)==4u",
        "offsetof(IOSFeaturePolicyProvenanceStorage,decisions)==8u",
        "offsetof(IOSFeaturePolicyProvenanceStorage,defaults)==38u",
        "offsetof(IOSFeaturePolicyProvenanceStorage,reserved)==39u",
    )
    for contract in header_contracts:
        if compact_header.count(contract) != 1:
            raise ValueError(
                "P2.6e1 provenance ABI changed: " + contract
            )

    builder_begin = provenance_source.index(
        "IOSFeaturePolicyProvenance iosBuildFeaturePolicyProvenance("
    )
    telemetry_begin = provenance_source.index(
        "IOSFeatureTelemetryResult iosTakeFeaturePolicyTelemetry("
    )
    builder = compact(
        provenance_source[builder_begin:telemetry_begin]
    )
    builder_mappings = (
        "storage.decisions[0]={IOSFeatureId::MetalFxSpatial,"
        "IOSDeviceProbeId::MetalFxSpatial,"
        "iosEvaluateFeaturePolicyDefaults(facts,"
        "{IOSFeatureId::MetalFxSpatial,defaults,"
        "activation.metalFxSpatial})",
        "storage.decisions[1]={IOSFeatureId::MetalFxTemporal,"
        "IOSDeviceProbeId::MetalFxTemporal,"
        "iosEvaluateFeaturePolicyDefaults(facts,"
        "{IOSFeatureId::MetalFxTemporal,defaults,"
        "activation.metalFxTemporal})",
        "storage.decisions[2]={IOSFeatureId::MeshShading,"
        "IOSDeviceProbeId::MeshShading,"
        "iosEvaluateFeaturePolicyDefaults(facts,"
        "{IOSFeatureId::MeshShading,defaults,"
        "activation.meshShading})",
        "storage.decisions[3]={IOSFeatureId::RayTracing,"
        "IOSDeviceProbeId::RayTracing,"
        "iosEvaluateFeaturePolicyDefaults(facts,"
        "{IOSFeatureId::RayTracing,defaults,"
        "activation.rayTracing})",
        "storage.decisions[4]={IOSFeatureId::Metal4Transport,"
        "IOSDeviceProbeId::Metal4Transport,"
        "iosEvaluateFeaturePolicyDefaults(facts,"
        "{IOSFeatureId::Metal4Transport,defaults,"
        "activation.metal4Transport})",
    )
    for mapping in builder_mappings:
        if builder.count(mapping) != 1:
            raise ValueError(
                "P2.6e1 canonical decision mapping changed"
            )
    forbidden_builder = (
        "iosCollectDeviceFacts",
        "IOSDeviceNative",
        "IOSMetalContext",
        "Tempest",
    )
    if any(value in builder for value in forbidden_builder):
        raise ValueError("P2.6e1 builder gained native dependency")

    telemetry = compact(provenance_source[telemetry_begin:])
    telemetry_signature = (
        "iosTakeFeaturePolicyTelemetry("
        "IOSFeatureTelemetryGate&gate,"
        "constIOSFeaturePolicyProvenance&provenance,"
        "char*output,size_tcapacity)noexcept"
    )
    if telemetry.count(telemetry_signature) != 1:
        raise ValueError("P2.6e1 telemetry signature changed")
    if "IOSDeviceFacts" in telemetry:
        raise ValueError("telemetry accepts facts instead of snapshot")
    field_order = (
        "defaults=%sspatial=%u/%u/%u/%stemporal=%u/%u/%u/%s"
        "mesh=%u/%u/%u/%srt=%u/%u/%u/%smetal4=%u/%u/%u/%s"
    )
    if field_order not in telemetry.replace('"', ""):
        raise ValueError("P2.6e1 telemetry field order changed")

    test_anchors = (
        "testProvenanceMatrixAndMapping();",
        "testProvenanceFallbacksAndNamedActivation();",
        "testProvenanceInvalidDefaults();",
        "testProvenanceOwnsSnapshot();",
        "testTelemetryExactAndGateBoundaries();",
        "testTelemetryEnumNamesAndMaximumCapacity();",
        "facts=4294967295",
        "probes=4294967295",
        "required-1u",
        "IOSFeatureTelemetryResult::AlreadyEmitted",
    )
    for anchor in test_anchors:
        if anchor not in compact_test:
            raise ValueError(
                "P2.6e1 test oracle changed: " + anchor
            )

def provenance_mutation_is_killed(label, candidate_provenance):
    case_root = mutation_root / ("provenance-" + label)
    graphics = case_root / "graphics"
    graphics.mkdir(parents=True)
    (graphics / "iosfeaturepolicy.h").write_text(header)
    (graphics / "iosfeaturepolicy.cpp").write_text(source)
    (graphics / "iosfeaturepolicyprovenance.h").write_text(
        provenance_header
    )
    (graphics / "iosfeaturepolicyprovenance.cpp").write_text(
        candidate_provenance
    )
    (graphics / "iosdevicecapabilities.h").write_text(
        capability_header
    )
    test_path = case_root / "iosfeaturepolicy.cpp"
    test_path.write_text(test)
    binary = case_root / "iosfeaturepolicy-provenance-mutant"
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
            str(graphics / "iosfeaturepolicyprovenance.cpp"),
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
            "P2.6e1 mutant did not compile: "
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
        raise SystemExit(
            "P2.6e1 mutation codesign failed: " + label
        )
    run_result = subprocess.run(
        [str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return run_result.returncode != 0

validate_provenance_contract()
provenance_mutations = []

probe_names = (
    "MetalFxSpatial",
    "MetalFxTemporal",
    "MeshShading",
    "RayTracing",
    "Metal4Transport",
)
for index, current in enumerate(probe_names):
    following = probe_names[(index + 1) % len(probe_names)]
    anchor = f"IOSDeviceProbeId::{current},"
    provenance_mutations.append((
        f"probe-mapping-{index}",
        replace_once(
            provenance_source,
            anchor,
            f"IOSDeviceProbeId::{following},",
        ),
    ))

provenance_mutations.append((
    "omitted-feature",
    replace_once(
        provenance_source,
        "  storage.decisions[4] = {\n"
        "    IOSFeatureId::Metal4Transport,",
        "  storage.decisions[4] = {\n"
        "    IOSFeatureId::RayTracing,",
    ),
))

activation_names = (
    "metalFxSpatial",
    "metalFxTemporal",
    "meshShading",
    "rayTracing",
    "metal4Transport",
)
for index, current in enumerate(activation_names):
    following = activation_names[
        (index + 1) % len(activation_names)
    ]
    provenance_mutations.append((
        f"named-activation-{index}",
        replace_once(
            provenance_source,
            f"activation.{current}",
            f"activation.{following}",
        ),
    ))

state_mutations = (
    (
        "telemetry-requested-state",
        "flag(metal4.state.requested)",
        "flag(metal4.state.eligible)",
    ),
    (
        "telemetry-eligible-state",
        "flag(metal4.state.eligible)",
        "flag(metal4.state.requested)",
    ),
    (
        "telemetry-active-state",
        "flag(metal4.state.active)",
        "flag(metal4.state.eligible)",
    ),
    (
        "telemetry-fallback-state",
        "fallbackName(metal4.state.fallbackReason)",
        "fallbackName(spatial.state.fallbackReason)",
    ),
)
for label, old, new in state_mutations:
    provenance_mutations.append((
        label,
        replace_once(provenance_source,old,new),
    ))

provenance_mutations.extend((
    (
        "telemetry-order",
        replace_once(
            provenance_source,
            "defaults=%s spatial=%u/%u/%u/%s "
            "temporal=%u/%u/%u/%s ",
            "defaults=%s temporal=%u/%u/%u/%s "
            "spatial=%u/%u/%u/%s ",
        ),
    ),
    (
        "telemetry-string",
        replace_once(
            provenance_source,
            "RendererIOS feature policy:",
            "RendererIos feature policy:",
        ),
    ),
    (
        "telemetry-schema",
        replace_once(
            provenance_source,
            "static_cast<unsigned>(\n"
            "          IOSFeaturePolicyProvenanceSchemaVersion)",
            "0u",
        ),
    ),
    (
        "invalid-default-storage",
        replace_once(
            provenance_source,
            "  storage.defaults = defaults;",
            "  storage.defaults = IOSFeatureDefaultClass::Safe;",
        ),
    ),
))

buffer_guard = (
    "  if(output==nullptr || capacity<required)\n"
    "    return IOSFeatureTelemetryResult::BufferTooSmall;"
)
provenance_mutations.extend((
    (
        "gate-consumed-on-error",
        replace_once(
            provenance_source,
            buffer_guard,
            "  if(output==nullptr || capacity<required) {\n"
            "    gate.emitted = true;\n"
            "    return IOSFeatureTelemetryResult::BufferTooSmall;\n"
            "    }",
        ),
    ),
    (
        "partial-write-on-error",
        replace_once(
            provenance_source,
            buffer_guard,
            "  if(output==nullptr)\n"
            "    return IOSFeatureTelemetryResult::BufferTooSmall;\n"
            "  if(capacity<required) {\n"
            "    if(capacity>0u)\n"
            "      output[0] = record[0];\n"
            "    return IOSFeatureTelemetryResult::BufferTooSmall;\n"
            "    }",
        ),
    ),
    (
        "off-by-one-capacity",
        replace_once(
            provenance_source,
            "capacity<required",
            "capacity+1u<required",
        ),
    ),
    (
        "write-after-already-emitted",
        replace_once(
            provenance_source,
            "  if(gate.emitted)\n"
            "    return IOSFeatureTelemetryResult::AlreadyEmitted;",
            "  if(false)\n"
            "    return IOSFeatureTelemetryResult::AlreadyEmitted;",
        ),
    ),
    (
        "reversed-gate-buffer-precedence",
        replace_once(
            provenance_source,
            "  if(gate.emitted)\n"
            "    return IOSFeatureTelemetryResult::AlreadyEmitted;",
            "  if(gate.emitted && output!=nullptr && capacity>0u)\n"
            "    return IOSFeatureTelemetryResult::AlreadyEmitted;",
        ),
    ),
    (
        "one-shot-bypass",
        replace_once(
            provenance_source,
            "  gate.emitted = true;",
            "  gate.emitted = false;",
        ),
    ),
))

provenance_killed = 0
for label, candidate_provenance in provenance_mutations:
    if provenance_mutation_is_killed(
            label,candidate_provenance):
        provenance_killed += 1
        continue
    raise SystemExit(
        "P2.6e1 executable mutation survived: " + label
    )
if provenance_killed != 25:
    raise SystemExit(
        "P2.6e1 mutation count drifted: "
        f"{provenance_killed}/25"
    )
shutil.rmtree(mutation_root)
print(
    "P2.6e1 executable mutation oracle: "
    "compiled=25 executed=25 "
    f"mutations-killed={provenance_killed}"
)

def runtime_constructor(value):
    begin = value.index(
        "  Impl(Device& device, SystemApi::Window* window)"
    )
    end = value.index(
        "\n#if defined("
        "OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)\n"
        "  bool clearOnlyRuntimeCompilationUnchanged",
        begin,
    )
    return value[begin:end]

def validate_runtime_contract(candidate_header, candidate_source):
    compact_header = compact(candidate_header)
    compact_source = compact(candidate_source)
    constructor_source = runtime_constructor(candidate_source)
    constructor = compact(constructor_source)

    exact_counts = (
        ("iosCollectDeviceFacts(", 1),
        ("iosLogDeviceFacts(", 1),
        ("iosBuildFeaturePolicyProvenance(", 1),
        ("iosTakeFeaturePolicyTelemetry(", 1),
    )
    for anchor, expected in exact_counts:
        if candidate_source.count(anchor) != expected:
            raise ValueError(
                "P2.6e2 runtime call count changed: " + anchor
            )

    facts_fail_closed = (
        "iosLogDeviceFacts(deviceFacts);"
        "if(!deviceFacts.value)"
        "throwstd::runtime_error("
        "\"RendererIOSdevicefactsvalidationfailed\");"
    )
    if constructor.count(facts_fail_closed) != 1:
        raise ValueError(
            "P2.6e2 invalid facts guard or ordering changed"
        )

    build_anchor = (
        "featurePolicyProvenance.emplace("
        "iosBuildFeaturePolicyProvenance("
        "*deviceFacts.value,IOSFeatureDefaultClass::Safe,"
        "{false,false,false,false,false}));"
    )
    take_anchor = (
        "featurePolicyTelemetryResult="
        "iosTakeFeaturePolicyTelemetry("
        "featurePolicyTelemetryGate,*featurePolicyProvenance,"
        "featurePolicyTelemetry.data(),"
        "featurePolicyTelemetry.size());"
    )
    result_anchor = (
        "if(featurePolicyTelemetryResult!="
        "IOSFeatureTelemetryResult::Emitted)"
        "throwstd::runtime_error("
        "\"RendererIOSfeaturepolicytelemetrywasnotemitted\");"
    )
    log_anchor = (
        "Log::i(featurePolicyTelemetry.data(),"
        "\"build=\",OPENGOTHIC_RENDERER_IOS_BUILD_SHA);"
    )
    marker_call_count = compact_source.count(
        "Log::i(featurePolicyTelemetry.data(),"
    )
    marker_prefix_count = candidate_source.count(
        'Log::i("RendererIOS feature policy:'
    )
    if marker_call_count + marker_prefix_count != 1:
        raise ValueError(
            "P2.6e2 global policy marker call count changed"
        )
    for anchor in (
        "resetTargets();",
        build_anchor,
        take_anchor,
        result_anchor,
        log_anchor,
    ):
        if constructor.count(anchor) != 1:
            raise ValueError(
                "P2.6e2 runtime startup contract changed"
            )
    ordered = (
        "iosLogDeviceFacts(deviceFacts);",
        "if(!deviceFacts.value)",
        "resetTargets();",
        build_anchor,
        take_anchor,
        result_anchor,
        log_anchor,
        "constautoplatform=rendererIOSPlatformInfo();",
    )
    positions = [constructor.index(anchor) for anchor in ordered]
    if positions != sorted(positions):
        raise ValueError("P2.6e2 startup ordering changed")
    swallowed_try = constructor.index("try{",positions[-1])
    if swallowed_try<=positions[-2]:
        raise ValueError("P2.6e2 mandatory log entered swallow-all")

    raw_reset = constructor_source.index("    resetTargets();")
    raw_log = constructor_source.index(
        "    Log::i(featurePolicyTelemetry.data(),"
    )
    mandatory_block = constructor_source[raw_reset:raw_log]
    if "#if" in mandatory_block or "try {" in mandatory_block:
        raise ValueError(
            "P2.6e2 marker moved under diagnostics or swallow-all"
        )

    owner_contracts = (
        "std::optional<IOSFeaturePolicyProvenance>"
        "featurePolicyProvenance;",
        "IOSFeatureTelemetryGatefeaturePolicyTelemetryGate;",
        "constIOSFeaturePolicyProvenance&"
        "IOSMetalContext::featurePolicyProvenance()"
        "constnoexcept{return*impl->featurePolicyProvenance;}",
    )
    for contract in owner_contracts:
        if compact_source.count(contract) != 1:
            raise ValueError(
                "P2.6e2 runtime owner/accessor changed"
            )
    public_accessor = (
        "constIOSFeaturePolicyProvenance&"
        "featurePolicyProvenance()constnoexcept;"
    )
    if compact_header.count(public_accessor) != 1:
        raise ValueError("P2.6e2 public accessor ABI changed")
    if "IOSDeviceFacts" in candidate_header or \
            "iosCollectDeviceFacts" in candidate_header:
        raise ValueError("P2.6e2 public header exposes facts")

    compact_test = compact(test)
    test_anchors = (
        "testRuntimeSafePolicyMarkerContract();",
        "defaults=safespatial=0/1/0/not-requested",
        "metal4=0/1/0/not-requestedbuild=host-safe-sha",
        "IOSFeatureTelemetryResult::AlreadyEmitted",
        "IOSFeatureTelemetryResult::BufferTooSmall",
    )
    for anchor in test_anchors:
        if anchor not in compact_test:
            raise ValueError(
                "P2.6e2 host Safe oracle changed: " + anchor
            )

validate_runtime_contract(context_header,context_source)

runtime_mutations = []
facts_log = "    iosLogDeviceFacts(deviceFacts);\n"
facts_guard = (
    "    if(!deviceFacts.value)\n"
    "      throw std::runtime_error(\n"
    "        \"RendererIOS device facts validation failed\");\n"
)
build_block = (
    "    featurePolicyProvenance.emplace(\n"
    "      iosBuildFeaturePolicyProvenance(\n"
    "        *deviceFacts.value,\n"
    "        IOSFeatureDefaultClass::Safe,\n"
    "        {false,false,false,false,false}));\n"
)
take_block = (
    "    const IOSFeatureTelemetryResult featurePolicyTelemetryResult =\n"
    "      iosTakeFeaturePolicyTelemetry(\n"
    "        featurePolicyTelemetryGate,\n"
    "        *featurePolicyProvenance,\n"
    "        featurePolicyTelemetry.data(),\n"
    "        featurePolicyTelemetry.size());\n"
)
marker_log = (
    "    Log::i(featurePolicyTelemetry.data(),\n"
    "           \" build=\",OPENGOTHIC_RENDERER_IOS_BUILD_SHA);\n"
)

runtime_mutations.append((
    "second-collector",
    context_header,
    replace_once(
        context_source,
        facts_log,
        facts_log + "    (void)iosCollectDeviceFacts(device);\n",
    ),
))
runtime_mutations.append((
    "second-build",
    context_header,
    replace_once(
        context_source,
        build_block,
        build_block
        + "    (void)iosBuildFeaturePolicyProvenance(\n"
        + "      *deviceFacts.value,IOSFeatureDefaultClass::Safe,\n"
        + "      {false,false,false,false,false});\n",
    ),
))
runtime_mutations.append((
    "second-take",
    context_header,
    replace_once(
        context_source,
        take_block,
        take_block
        + "    (void)iosTakeFeaturePolicyTelemetry(\n"
        + "      featurePolicyTelemetryGate,*featurePolicyProvenance,\n"
        + "      featurePolicyTelemetry.data(),"
        + "featurePolicyTelemetry.size());\n",
    ),
))
runtime_mutations.append((
    "removed-invalid-facts-guard",
    context_header,
    replace_once(context_source,facts_guard,""),
))
runtime_mutations.append((
    "inverted-invalid-facts-guard",
    context_header,
    replace_once(
        context_source,
        "    if(!deviceFacts.value)\n",
        "    if(deviceFacts.value)\n",
    ),
))
runtime_mutations.append((
    "continue-after-invalid-facts",
    context_header,
    replace_once(
        context_source,
        "      throw std::runtime_error(\n"
        "        \"RendererIOS device facts validation failed\");",
        "      (void)std::runtime_error(\n"
        "        \"RendererIOS device facts validation failed\");",
    ),
))
runtime_mutations.append((
    "guard-before-facts-log",
    context_header,
    replace_once(
        context_source,
        facts_log + facts_guard,
        facts_guard + facts_log,
    ),
))
runtime_mutations.append((
    "build-before-reset-targets",
    context_header,
    replace_once(
        context_source,
        "    resetTargets();\n" + build_block,
        build_block + "    resetTargets();\n",
    ),
))
runtime_mutations.append((
    "accept-already-emitted",
    context_header,
    replace_once(
        context_source,
        "    if(featurePolicyTelemetryResult!="
        "IOSFeatureTelemetryResult::Emitted)\n",
        "    if(featurePolicyTelemetryResult=="
        "IOSFeatureTelemetryResult::BufferTooSmall)\n",
    ),
))
runtime_mutations.append((
    "accept-buffer-too-small",
    context_header,
    replace_once(
        context_source,
        "    if(featurePolicyTelemetryResult!="
        "IOSFeatureTelemetryResult::Emitted)\n",
        "    if(featurePolicyTelemetryResult=="
        "IOSFeatureTelemetryResult::AlreadyEmitted)\n",
    ),
))
runtime_mutations.append((
    "diagnostics-only-marker",
    context_header,
    replace_once(
        context_source,
        marker_log,
        "#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n"
        + marker_log
        + "#endif\n",
    ),
))
runtime_mutations.append((
    "marker-in-swallowed-try",
    context_header,
    replace_once(
        context_source,
        marker_log,
        "    try {\n"
        + marker_log
        + "      }\n"
        + "    catch(...) {\n"
        + "      }\n",
    ),
))
runtime_mutations.append((
    "missing-build-sha",
    context_header,
    replace_once(
        context_source,
        marker_log,
        "    Log::i(featurePolicyTelemetry.data());\n",
    ),
))
runtime_mutations.append((
    "second-policy-marker-in-resume",
    context_header,
    replace_once(
        context_source,
        "bool IOSMetalContext::resume() noexcept {\n",
        "bool IOSMetalContext::resume() noexcept {\n"
        "  Log::i(\"RendererIOS feature policy: "
        "lifecycle-reemission build=\",\n"
        "         OPENGOTHIC_RENDERER_IOS_BUILD_SHA);\n",
    ),
))
runtime_mutations.append((
    "activation-all-true",
    context_header,
    replace_once(
        context_source,
        "{false,false,false,false,false}));",
        "{true,true,true,true,true}));",
    ),
))
runtime_mutations.append((
    "defaults-from-family",
    context_header,
    replace_once(
        context_source,
        "        IOSFeatureDefaultClass::Safe,\n",
        "        deviceFacts.value->facts()."
        "highestKnownAppleFamily>=10u\n"
        "          ? IOSFeatureDefaultClass::Apple10\n"
        "          : IOSFeatureDefaultClass::Safe,\n",
    ),
))
runtime_mutations.append((
    "accessor-by-value",
    replace_once(
        context_header,
        "    const IOSFeaturePolicyProvenance&\n"
        "                     featurePolicyProvenance() const noexcept;",
        "    IOSFeaturePolicyProvenance\n"
        "                     featurePolicyProvenance() const noexcept;",
    ),
    replace_once(
        context_source,
        "const IOSFeaturePolicyProvenance&\n"
        "IOSMetalContext::featurePolicyProvenance() const noexcept {",
        "IOSFeaturePolicyProvenance\n"
        "IOSMetalContext::featurePolicyProvenance() const noexcept {",
    ),
))

runtime_killed_labels = []
for label, candidate_header, candidate_source in runtime_mutations:
    try:
        validate_runtime_contract(
            candidate_header,candidate_source
        )
    except (ValueError, KeyError):
        runtime_killed_labels.append(label)
        continue
    raise SystemExit(
        "P2.6e2 source-oracle mutation survived: " + label
    )
if len(runtime_killed_labels) != 17:
    raise SystemExit(
        "P2.6e2 source mutation count drifted: "
        f"{len(runtime_killed_labels)}/17"
    )
print(
    "P2.6e2 source mutation oracle: "
    "source-mutants-killed=17 labels="
    + ",".join(runtime_killed_labels)
)
PY

echo "P2.6e2 IOSFeaturePolicy runtime owner: PASS"
