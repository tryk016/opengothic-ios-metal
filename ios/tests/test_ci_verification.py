#!/usr/bin/env python3
"""Contract and mutation tests for split RendererIOS CI routing."""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import re
import subprocess
import tempfile


REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci_verification.py"
WORKFLOW = REPO / ".github" / "workflows" / "renderer-ios.yml"
CONTRACTS = REPO / "scripts" / "ci_contracts.command"
PROFILE = REPO / "scripts" / "ci_build_profile.command"
PRESETS = REPO / "CMakePresets.json"
CMAKE = REPO / "CMakeLists.txt"
GITIGNORE = REPO / ".gitignore"
LOCAL_VERIFY = REPO / "scripts" / "verify-local-build.command"
UI_AUTOMATION_HARNESS = (
    REPO / "ios" / "device-test" / "run-ui-automation-test.sh"
)
UI_AUTOMATION_SELECTOR = (
    REPO / "ios" / "device-test" / "select-ui-automation-target.py"
)
SMOKE_HARNESS = REPO / "ios" / "device-test" / "run-smoke-test.sh"
PIPELINE_ARCHIVE_HARNESS = (
    REPO / "ios" / "device-test" / "run-pipeline-archive-test.sh"
)
IOS_METAL_CONTEXT = REPO / "game" / "graphics" / "iosmetalcontext.cpp"


def load_module():
    spec = importlib.util.spec_from_file_location("ci_verification", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load ci_verification.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CI = load_module()


def expect_error(callback) -> None:
    try:
        callback()
    except CI.CIVerificationError:
        return
    raise AssertionError("expected fail-closed CI verification error")


def exact_scope(source: str, start: str, end: str, label: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"{label} boundaries are not exact")
    start_position = source.index(start)
    end_position = source.index(end, start_position + len(start))
    if end_position <= start_position:
        raise ValueError(f"{label} boundaries are out of order")
    return source[start_position + len(start) : end_position]


def workflow_job(source: str, job: str) -> str:
    lines = source.splitlines()
    anchor = f"  {job}:"
    if lines.count(anchor) != 1:
        raise ValueError(f"workflow must contain exact job {job}")
    start = lines.index(anchor)
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.startswith("  ") and not line.startswith("    ") and line.endswith(":"):
            end = index
            break
    return "\n".join(lines[start:end])


def validate_workflow(source: str) -> None:
    required_jobs = (
        "classifier",
        "contracts",
        "build-off",
        "build-on",
        "build-tile",
        "build-forward",
        "required",
    )
    lines = source.splitlines()
    for job in required_jobs:
        anchor = f"  {job}:"
        if lines.count(anchor) != 1:
            raise ValueError(f"workflow must contain exact job {job}")
    required_fragments = (
        "EVENT_BEFORE: ${{ github.event.before }}",
        "EVENT_SHA: ${{ github.sha }}",
        "scripts/ci_verification.py classify",
        "- name: Verify fail-closed verification policy",
        "scripts/classify_verification.py --validate-policy",
        "ios/tests/test_verification_classifier.py",
        "ios/tests/test_verification_router.py",
        "ios/tests/test_ci_verification.py",
        "if: needs.classifier.outputs.build_off == 'true'",
        "if: needs.classifier.outputs.build_on == 'true'",
        "if: needs.classifier.outputs.build_tile == 'true'",
        "if: needs.classifier.outputs.build_forward == 'true'",
        "needs: [classifier, contracts, build-off, build-on, build-tile, build-forward]",
        "if: always()",
        "scripts/ci_verification.py aggregate",
        "--classifier-result \"${{ needs.classifier.result }}\"",
        "--expected-contracts \"${{ needs.classifier.outputs.contracts }}\"",
        "--result-contracts \"${{ needs.contracts.result }}\"",
        "--expected-build-off \"${{ needs.classifier.outputs.build_off }}\"",
        "--result-build-off \"${{ needs.build-off.result }}\"",
        "--expected-build-on \"${{ needs.classifier.outputs.build_on }}\"",
        "--result-build-on \"${{ needs.build-on.result }}\"",
        "--expected-build-tile \"${{ needs.classifier.outputs.build_tile }}\"",
        "--result-build-tile \"${{ needs.build-tile.result }}\"",
        "--expected-build-forward \"${{ needs.classifier.outputs.build_forward }}\"",
        "--result-build-forward \"${{ needs.build-forward.result }}\"",
    )
    for fragment in required_fragments:
        if source.count(fragment) != 1:
            raise ValueError(f"workflow contract drifted: {fragment}")
    if "matrix:" in source:
        raise ValueError("split workflow must not hide profile results in a matrix")
    for job, output, profile in (
        ("build-off", "build_off", "off"),
        ("build-on", "build_on", "on"),
        ("build-tile", "build_tile", "tile"),
        ("build-forward", "build_forward", "forward"),
    ):
        scope = workflow_job(source, job)
        required_job_lines = (
            "    needs: [classifier, contracts]",
            f"    if: needs.classifier.outputs.{output} == 'true'",
            "        uses: actions/checkout@v4",
            "          fetch-depth: 0",
            "          submodules: recursive",
            "        run: brew install cmake glslang ripgrep",
            f"        run: scripts/ci_build_profile.command {profile}",
        )
        for line in required_job_lines:
            if scope.splitlines().count(line) != 1:
                raise ValueError(f"{job} is not self-contained: {line.strip()}")


def validate_extracted_oracles(contracts: str, profile: str) -> None:
    for policy_oracle in (
        "scripts/classify_verification.py --validate-policy",
        "ios/tests/test_verification_classifier.py",
        "ios/tests/test_verification_router.py",
        "ios/tests/test_ci_verification.py",
    ):
        if policy_oracle in contracts or policy_oracle in profile:
            raise ValueError(f"policy oracle is duplicated outside classifier: {policy_oracle}")
    contract_names = (
        "Verify shared CMake presets",
        "Verify P2.1c3b3b causal build isolation",
        "Verify pinned Tempest fork twice",
        "Verify Tempest Metal 2D copy contract",
        "Verify neutral P2.1 scene boundary",
        "Verify neutral P2.2d frame plan",
        "Verify P2.6a host-neutral device facts contract",
        "Verify P2.6b1 native device facts collector",
        "Verify P2.5a shading prototype plan contract",
        "Verify P2.3b resource allocator contract",
        "Verify P2.3c clear-only pass contract",
        "Verify RendererIOS save-preview routing policy",
        "Verify RendererIOS legacy shader compilation policy",
        "Verify RendererIOS pipeline archive policy",
        "Verify P2.1 native asset registry contract",
        "Verify P2.1 Landscape extractor contract",
        "Verify RendererIOS native GPU and offline Metal contracts",
        "Verify P2.5b2a1 shading prototype Tile self-test profile",
        "Verify P2.5c1b1 shading prototype Forward self-test profile",
        "Verify P2.1c3b3 causal device harness",
        "Verify physical-device smoke cleanup contract",
        "Verify P2.6a capabilities source target membership",
        "Verify P2.6b1 collector source target membership",
        "Assert legacy renderer is not in the target",
        "Verify RendererIOS UI automation contract",
    )
    for name in contract_names:
        marker = f"### CI contract: {name}"
        if contracts.count(marker) != 1:
            raise ValueError(f"CI-only oracle is not extracted exactly once: {name}")
        if marker in profile:
            raise ValueError(f"CI-only oracle leaked into profile builds: {name}")
    for name in (
        "Build iOS Release",
        "Verify P2.6b1 final weak MetalFX dependency",
    ):
        marker = f"### CI profile {name}"
        if profile.count(marker) != 1:
            raise ValueError(f"profile build oracle drifted: {name}")
    if contracts.count("bash ios/patches/apply-patches.sh") != 2:
        raise ValueError("Tempest read-only verifier must run exactly twice")
    if "bash ios/patches/apply-patches.sh" in profile:
        raise ValueError("profile builds duplicate the contracts-only Tempest oracle")
    if ".github/workflows/renderer-ios.yml" in contracts:
        raise ValueError("extracted contracts still parse the workflow implementation")

    configure = exact_scope(
        profile,
        "# CI_PROFILE_CONFIGURE_BEGIN",
        "# CI_PROFILE_CONFIGURE_END",
        "profile configure",
    )
    configure_contract = (
        'cmake --preset "renderer-ios-$PROFILE" -B build-renderer-ios',
        '-DOPENGOTHIC_RENDERER_IOS_FAULT_MODE="$ACTIVE_FAULT_MODE"',
        '-DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE='
        '"$CAUSAL_MODE"',
        '-DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST='
        '"$SHADING_PROTOTYPE_TILE_SELF_TEST"',
        '-DOPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST='
        '"$SHADING_PROTOTYPE_FORWARD_SELF_TEST"',
        '-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="$GITHUB_SHA"',
    )
    for literal in configure_contract:
        if configure.count(literal) != 1:
            raise ValueError(f"profile configure contract drifted: {literal}")

    candidate = exact_scope(
        profile,
        "# CI_PROFILE_CANDIDATE_BEGIN",
        "# CI_PROFILE_CANDIDATE_END",
        "profile candidate metallib",
    )
    for literal in (
        "for shader in landscape bink ui inventory shading-prototypes; do",
        '"$@"',
        "xcrun --sdk iphoneos metallib",
        "xcrun --sdk iphoneos metal-nm",
        'test "$ACTUAL_RIOS_EXPORTS" = "$EXPECTED_RIOS_EXPORTS"',
        ')" -eq 18',
        "RendererIOS.candidate.sha256",
    ):
        if candidate.count(literal) != 1:
            raise ValueError(f"profile candidate contract drifted: {literal}")
    for line in (
        "  set --",
        "    set -- -Wall -Wextra -Werror",
    ):
        if candidate.splitlines().count(line) != 1:
            raise ValueError(f"profile candidate arguments drifted: {line.strip()}")
    if candidate.splitlines().count("  xcrun --sdk iphoneos metal \\") != 1:
        raise ValueError("profile candidate Metal compiler command drifted")

    build = exact_scope(
        profile,
        "printf '\\n### CI profile Build iOS Release\\n'",
        "printf '\\n### CI profile Verify P2.6b1 final weak MetalFX dependency\\n'",
        "profile build",
    )
    if build.count("cmake --build build-renderer-ios --config Release") != 1:
        raise ValueError("profile build command is not exact")
    positions = tuple(
        profile.index(anchor)
        for anchor in (
            "# CI_PROFILE_CONFIGURE_BEGIN",
            "# CI_PROFILE_CANDIDATE_BEGIN",
            "printf '\\n### CI profile Build iOS Release\\n'",
            "printf '\\n### CI profile Verify P2.6b1 final weak MetalFX dependency\\n'",
        )
    )
    if positions != tuple(sorted(positions)):
        raise ValueError("profile configure/candidate/build/weak gates are out of order")

    p23_compile = exact_scope(
        contracts,
        "printf '\\n### CI contract: Verify P2.3c clear-only pass contract\\n'",
        "# CI_CONTRACT_P23C_COMPILE_END",
        "P2.3c compile",
    )
    if p23_compile.count(
        "-DOPENGOTHIC_IOS_CAPTURE_NORMALIZER_TEST_FAULTS=1"
    ) != 1:
        raise ValueError("P2.3c host-only fault hook is not exact")
    smoke_invocation = (
        "  ios/device-test/run-smoke-test.sh --save-slot 1 --self-test"
    )
    if contracts.splitlines().count(smoke_invocation) != 1:
        raise ValueError("preview-fence save-slot smoke self-test is not exact")


def validate_clear_only_admission_contract(contracts: str, context: str) -> None:
    production_oracle = exact_scope(
        contracts,
        'if profile_gate.count("return std::nullopt;") != 1:',
        'if begin_frame.index("impl->pollClearOnlyPassSelfTest();")',
        "clear-only production admission oracle",
    )
    forbidden_calls = (
        "pollPresentFailure",
        "takePresentFailureAndLatchProof",
        "startEncoding",
        "device.submit",
        "swapchain",
        "gpuScene",
    )
    for production_call in forbidden_calls:
        if production_oracle.splitlines().count(f'    "{production_call}",') != 1:
            raise ValueError(
                "clear-only production admission oracle is not exact: "
                + production_call
            )

    begin_frame = context.split(
        "std::optional<IOSMetalContext::FrameLease> "
        "IOSMetalContext::beginFrame() {",
        1,
    )[1].split(
        "\nbool IOSMetalContext::frameAdmissionActive() const noexcept {",
        1,
    )[0]
    profile_gate = begin_frame.split(
        "#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST)",
        1,
    )[1].split("#endif", 1)[0]
    for production_call in forbidden_calls:
        if production_call in profile_gate:
            raise ValueError(
                "clear-only admission gate invokes production work: "
                + production_call
            )


def validate_ui_automation_host_contract(
    harness: str,
    selector: str,
    contracts: str,
) -> None:
    harness_contract = (
        'SELECTOR="$ROOT/ios/device-test/select-ui-automation-target.py"',
        'selection="$(python3 "$SELECTOR" device \\',
        'BUNDLE_ID="$(python3 "$SELECTOR" bundle \\',
        'echo "device_udid=$DEVICE"',
        'echo "device_transport=$DEVICE_TRANSPORT"',
        'TEAM_ID="$(resolve_team_id \\',
        "run_xcodebuild_ui_test() {",
        "run_host_self_test() {",
    )
    for literal in harness_contract:
        if harness.count(literal) != 1:
            raise ValueError(
                "UI automation harness contract is not exact: " + literal
            )

    selector_contract = (
        "def select_device_target(",
        "def _iphone_witness_records(",
        "def _select_requested(",
        "if identifier != core_udid:",
        "iphone_witnesses = _iphone_witness_records(xc_records)",
        'usb_witnesses = _transport_witnesses(iphone_witnesses, "usb")',
        "if invalid_usb or len(valid_usb) != 1:",
        "if usb_witnesses:",
        'network_witnesses = _transport_witnesses(iphone_witnesses, "network")',
        "if invalid_network or len(valid_network) != 1:",
        "if len(target_udids) != 1:",
        "if len(xc_matches) != 1:",
        "if len(core_matches) != 1:",
        "def select_product_bundle(",
        'r"^opengothic\\.gothic2\\.[A-Z0-9]{10}$"',
        "if product_pattern.fullmatch(bundle):",
        "elif runner_pattern.fullmatch(bundle):",
    )
    for literal in selector_contract:
        if selector.count(literal) != 1:
            raise ValueError(
                "UI automation selector contract is not exact: " + literal
            )
    prefilter_position = selector.index(
        "iphone_witnesses = _iphone_witness_records(xc_records)"
    )
    usb_position = selector.index(
        'usb_witnesses = _transport_witnesses(iphone_witnesses, "usb")'
    )
    network_position = selector.index(
        'network_witnesses = _transport_witnesses(iphone_witnesses, "network")'
    )
    if not prefilter_position < usb_position < network_position:
        raise ValueError(
            "UI automation platform prefilter/USB-first order drifted"
        )

    xcodebuild_scope = exact_scope(
        harness,
        "run_xcodebuild_ui_test() {",
        "\n}\n\nrun_host_self_test() {",
        "UI automation xcodebuild invocation",
    )
    diagnostics = "    -collect-test-diagnostics never \\"
    if xcodebuild_scope.splitlines().count(diagnostics) != 1:
        raise ValueError(
            "xcodebuild diagnostics pair is not exact and adjacent"
        )
    command_lines = [
        line for line in xcodebuild_scope.splitlines()
        if line.strip()
    ]
    if command_lines[-2:] != [diagnostics, "    test"]:
        raise ValueError(
            "xcodebuild diagnostics pair is not immediately before "
            "terminal test"
        )

    ui_contract_scope = exact_scope(
        contracts,
        "printf '\\n### CI contract: "
        "Verify RendererIOS UI automation contract\\n'",
        "xcodebuild \\",
        "UI automation focused host hook",
    )
    for line in (
        "test -f ios/device-test/select-ui-automation-target.py",
        "/bin/bash -n ios/device-test/run-ui-automation-test.sh",
        "  python3 -m py_compile \\",
        "    ios/device-test/select-ui-automation-target.py",
        "  python3 ios/device-test/select-ui-automation-target.py self-test",
        "/bin/bash ios/device-test/run-ui-automation-test.sh --self-test",
    ):
        if ui_contract_scope.splitlines().count(line) != 1:
            raise ValueError(
                "UI automation focused host hook drifted: " + line.strip()
            )


def validate_cmake_presets(
    presets: dict,
    gitignore: str,
    local_verify: str,
    profile: str,
    contracts: str,
) -> None:
    if presets.get("version") != 2:
        raise ValueError("CMake presets schema must be version 2")
    if presets.get("cmakeMinimumRequired") != {
        "major": 3,
        "minor": 20,
        "patch": 0,
    }:
        raise ValueError("CMake presets minimum must be exactly 3.20.0")

    configure_presets = presets.get("configurePresets")
    if not isinstance(configure_presets, list):
        raise ValueError("configurePresets must be a list")
    configure_by_name = {
        item.get("name"): item
        for item in configure_presets
        if isinstance(item, dict)
    }
    expected_configure_names = {
        "renderer-ios-base",
        "renderer-ios-off",
        "renderer-ios-on",
        "renderer-ios-tile",
        "renderer-ios-forward",
        "renderer-ios-causal-none",
        "renderer-ios-causal-a",
        "renderer-ios-causal-b",
    }
    if set(configure_by_name) != expected_configure_names:
        raise ValueError("configure preset names drifted")

    base = configure_by_name["renderer-ios-base"]
    if base.get("hidden") is not True or base.get("generator") != "Xcode":
        raise ValueError("shared iOS configure base must be hidden Xcode")
    expected_base_cache = {
        "CMAKE_SYSTEM_NAME": "iOS",
        "CMAKE_OSX_ARCHITECTURES": "arm64",
        "CMAKE_OSX_DEPLOYMENT_TARGET": "16.4",
        "OPENGOTHIC_GPU_EXPERIMENT_DIRECT_DRAWABLE_LAZY_SSAO": "OFF",
        "OPENGOTHIC_METALFX_SPATIAL": "OFF",
        "OPENGOTHIC_METALFX_TEMPORAL": "OFF",
        "OPENGOTHIC_RENDERER_IOS_FAULT_MODE": "none",
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE": "none",
        "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST": "OFF",
        "OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST": "OFF",
        "OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST": "OFF",
        "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": "OFF",
        "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": "OFF",
    }
    if base.get("cacheVariables") != expected_base_cache:
        raise ValueError("shared iOS configure base tuple drifted")

    profile_tuple = {
        "off": ("OFF", "OFF", "OFF"),
        "on": ("ON", "OFF", "OFF"),
        "tile": ("ON", "ON", "OFF"),
        "forward": ("ON", "OFF", "ON"),
    }
    for name, (diagnostics, tile, forward) in profile_tuple.items():
        preset = configure_by_name[f"renderer-ios-{name}"]
        if preset.get("inherits") != "renderer-ios-base":
            raise ValueError(f"{name} does not inherit the shared base")
        expected_binary = (
            "${sourceDir}/build/local-renderer-ios-" + name
        )
        if preset.get("binaryDir") != expected_binary:
            raise ValueError(f"{name} public binaryDir drifted")
        expected_profile_cache = {
            "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS": diagnostics,
            "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE": "none",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": tile,
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": forward,
        }
        if preset.get("cacheVariables") != expected_profile_cache:
            raise ValueError(f"{name} profile tuple drifted")
        if tile == "ON" and forward == "ON":
            raise ValueError("Tile and Forward may not be enabled together")

    causal_tuple = {
        "causal-none": "none",
        "causal-a": "causal-a",
        "causal-b": "causal-b",
    }
    for name, mode in causal_tuple.items():
        preset = configure_by_name[f"renderer-ios-{name}"]
        if preset.get("inherits") != "renderer-ios-base":
            raise ValueError(f"{name} does not inherit the shared base")
        if preset.get("binaryDir") != (
            "${sourceDir}/build/local-renderer-ios-" + name
        ):
            raise ValueError(f"{name} public binaryDir drifted")
        if preset.get("environment") != {"PACKAGE_DEVICE_IPA": "0"}:
            raise ValueError(f"{name} package tuple drifted")
        expected_causal_cache = {
            "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS": "ON",
            "OPENGOTHIC_RENDERER_IOS_FAULT_MODE": "none",
            "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE": mode,
            "OPENGOTHIC_RENDERER_IOS_BINK_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_RESOURCE_ALLOCATOR_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": "OFF",
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": "OFF",
        }
        if preset.get("cacheVariables") != expected_causal_cache:
            raise ValueError(f"{name} causal tuple drifted")

    serialized = json.dumps(presets, sort_keys=True)
    for forbidden in (
        "OPENGOTHIC_RENDERER_IOS_BUILD_SHA",
        "OPENGOTHIC_IOS_VERSION",
        "OPENGOTHIC_BUILD_ROOT",
    ):
        if forbidden in serialized:
            raise ValueError(f"dynamic/private value leaked into presets: {forbidden}")

    build_presets = presets.get("buildPresets")
    if not isinstance(build_presets, list):
        raise ValueError("buildPresets must be a list")
    if [item.get("name") for item in build_presets] != [
        "renderer-ios-off",
        "renderer-ios-on",
        "renderer-ios-tile",
        "renderer-ios-forward",
        "renderer-ios-causal-none",
        "renderer-ios-causal-a",
        "renderer-ios-causal-b",
    ]:
        raise ValueError("build preset names or order drifted")
    expected_native_options = [
        "-sdk",
        "iphoneos",
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGN_IDENTITY=",
    ]
    for item in build_presets:
        name = item["name"]
        if item.get("configurePreset") != name:
            raise ValueError(f"{name} build/configure preset mismatch")
        if item.get("configuration") != "Release":
            raise ValueError(f"{name} build is not Release")
        if item.get("nativeToolOptions") != expected_native_options:
            raise ValueError(f"{name} signing policy drifted")

    ignore_lines = gitignore.splitlines()
    if ignore_lines.count("CMakeUserPresets.json") != 1:
        raise ValueError("CMakeUserPresets.json ignore is not exact")
    if any(
        "*" in line and "Presets.json" in line
        for line in ignore_lines
    ):
        raise ValueError("broad presets ignore would hide public presets")

    script_contract = (
        (
            local_verify,
            'cmake --preset "renderer-ios-$profile" -B "$build"',
            '-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="$HEAD_SHA-local"',
            "local verifier",
        ),
        (
            profile,
            'cmake --preset "renderer-ios-$PROFILE" -B build-renderer-ios',
            '-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="$GITHUB_SHA"',
            "CI profile",
        ),
    )
    for source, configure, build_sha, label in script_contract:
        if source.count(configure) != 1:
            raise ValueError(f"{label} preset/explicit-B contract drifted")
        if source.count(build_sha) != 1:
            raise ValueError(f"{label} dynamic SHA contract drifted")
        if "cmake -S . -B" in source:
            raise ValueError(f"{label} still duplicates preset platform tuple")
    if local_verify.count(
        'BUILD_ROOT="${OPENGOTHIC_BUILD_ROOT:-$REPO/build/local-renderer-ios}"'
    ) != 1:
        raise ValueError("local custom build-root contract drifted")
    for line in (
        "cmake --list-presets",
        "cmake --build --list-presets",
    ):
        if contracts.splitlines().count(line) != 1:
            raise ValueError(f"contracts do not read actual presets: {line}")
    if "cmake -S . -B" in contracts:
        raise ValueError("contracts still duplicate preset platform tuple")


def validate_causal_build_isolation_source(
    cmake: str,
    profile: str,
    local_verify: str,
    contracts: str,
) -> None:
    cmake_literals = (
        'set(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE "none"',
        "PROPERTY STRINGS ${_renderer_ios_native_alpha_test_causal_modes}",
        "_renderer_ios_native_alpha_test_causal_mode_index EQUAL -1",
        "RendererIOS native AlphaTest causal A/B builds are available only for iOS",
        "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=ON",
        "OPENGOTHIC_RENDERER_IOS_FAULT_MODE=none",
        "exclusive with all other RendererIOS self-tests",
        'STREQUAL "causal-a")',
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1",
        'STREQUAL "causal-b")',
        "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1",
    )
    for literal in cmake_literals:
        if literal not in cmake:
            raise ValueError(f"causal CMake source contract drifted: {literal}")
    compile_definitions = re.findall(
        r"(?<![A-Za-z0-9_])"
        r"OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_(A|B)="
        r"([^)\s]+)",
        cmake,
    )
    if compile_definitions != [("A", "1"), ("B", "1")]:
        raise ValueError("causal CMake compile definitions are not exact A=1/B=1")
    if "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_HOST_TEST" in cmake:
        raise ValueError("HOST_TEST leaked into product CMake")

    profile_literals = (
        'RAW_ACTIVE_FAULT_MODE_SET="${ACTIVE_FAULT_MODE+x}"',
        "reject_causal_raw_conflict()",
        "causal profile raw input mismatch:",
        'CAUSAL_MODE "$RAW_CAUSAL_MODE_SET" "$RAW_CAUSAL_MODE" "$CAUSAL_MODE"',
        '-DOPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE="$CAUSAL_MODE"',
        r'r"(?<![A-Za-z0-9_])OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_"',
        "causal PBX global definitions drifted:",
        "RendererIOS causal binary oracle:",
    )
    for literal in profile_literals:
        if literal not in profile:
            raise ValueError(f"causal CI profile source drifted: {literal}")

    local_literals = (
        "off|on|tile|forward|causal-none|causal-a|causal-b",
        'local build="$TMP_GATE/causal-invalid-$mode-$name"',
        "for causal_mode_under_test in causal-a causal-b; do",
        "causal-invalid-non-ios-$causal_mode_under_test",
        'project.replace(expected_macro, "MUTANT_" + expected_macro, 1)',
        "RendererIOS causal binary oracle:",
    )
    for literal in local_literals:
        if literal not in local_verify:
            raise ValueError(f"causal local source drifted: {literal}")

    marker = "### CI contract: Verify P2.1c3b3b causal build isolation"
    next_marker = "### CI contract: Verify neutral P2.1 scene boundary"
    causal_contract = exact_scope(
        contracts,
        marker,
        next_marker,
        "causal CI contract",
    )
    contract_literals = (
        'local build="$CAUSAL_CONTRACT_ROOT/invalid-$mode-$name"',
        "for causal_mode_under_test in causal-a causal-b; do",
        "invalid-non-ios-$causal_mode_under_test",
        'project.replace(expected, "MUTANT_" + expected, 1)',
        "total_pbx_mutations != 17",
        "total_cache_mutations != 24",
    )
    for literal in contract_literals:
        if literal not in causal_contract:
            raise ValueError(f"causal contracts source drifted: {literal}")
    if "cmake --build" in causal_contract:
        raise ValueError("causal contracts must not serialize Release app builds")


def validate_causal_device_harness_source(
    harness: str,
    contracts: str,
) -> None:
    required = (
        "--native-alpha-test-causal-mode)",
        "--native-alpha-test-causal-sequence)",
        "NATIVE_ALPHA_TEST_CAUSAL_MODE_SEEN",
        "NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_SEEN",
        "EXPECTED_FAULT_SEEN",
        "is_canonical_positive_uint64()",
        "18446744073709551615",
        "generate_native_alpha_test_causal_nonce()",
        "validate_native_alpha_test_causal_binary_profile()",
        "validate_native_alpha_test_causal_log()",
        "write_native_alpha_test_causal_contract()",
        "install_native_alpha_test_causal_contract()",
        "commit_native_alpha_test_causal_pass_evidence()",
        "retract_native_alpha_test_causal_pass_evidence()",
        "invalidate_native_alpha_test_causal_result()",
        "finalize_native_alpha_test_causal_cleanup()",
        'if injected_fault == "copy":',
        'if injected_fault == "readback":',
        'fail "native alpha-test causal mode requires an exact-SHA build"',
        "CAUSAL_BINARY_SHA256",
        "CAUSAL_METALLIB_SHA256",
        "len(causal) != 2",
        "len(shell) != 1 or shell[0][1] != expected_build",
        'len(fault) != 1 or fault[0][1] != "none"',
        "shell[0][0] < encoded[0][0]",
        "fault[0][0] < encoded[0][0]",
        "armed[0][0] < encoded[0][0]",
        '"missing-shell": current.replace(shell_line, "")',
        '"duplicate-shell": current.replace(shell_line, shell_line + shell_line)',
        '"wrong-shell": current.replace(build, "f" * 40)',
        '"missing-fault": current.replace(fault_line, "")',
        '"duplicate-fault": current.replace(fault_line, fault_line + fault_line)',
        '"wrong-fault": current.replace("fault mode=none", "fault mode=unexpected")',
        '"shell-after-encoded": armed_line + fault_line + encoded_line + shell_line',
        '"fault-after-encoded": armed_line + shell_line + encoded_line + fault_line',
        '"encoded-before-armed": identity_lines + encoded_line + armed_line',
        '"encoded-before-identity": armed_line + encoded_line + identity_lines',
        "alpha <= 0 or draws < alpha",
        "fatal.search(segment) or fatal.search(stderr_segment)",
        "type(payload[\"targetSequence\"]) is not int",
        "run_native_alpha_test_causal_host_self_test",
        "write_native_alpha_test_causal_contract PASS passed",
        'write_native_alpha_test_causal_contract FAIL "$cleanup_result"',
        "log-native-alpha-test-causal-prelaunch.txt",
        "stderr-native-alpha-test-causal-prelaunch.log",
        "causal-log-replaced-markers-before-shell.txt",
        '"libcxxabi": "libc++abi: terminating due to exception',
        "causal-contract.json",
        "prepare_causal_finalizer_fixture publish-fail",
        "causal evidence-path publication failure returned success",
        "causal ordinary FAIL left a provisional PASS result",
        'EVIDENCE_PATH_FILE="$directory/causal-finalizer-evidence-path.txt"',
        'EVIDENCE_PATH_FILE="$caller_evidence_path_file"',
        "smoke final evidence path publication self-test failed",
    )
    for literal in required:
        if literal not in harness:
            raise ValueError(f"causal device harness source drifted: {literal}")
    requested_token_guard = (
        '[[ "$(grep -Fxc -- "$NATIVE_ALPHA_TEST_CAUSAL_MODE" \\\n'
        '    "$strings_file" || true)" -eq 1 ]] || return 1'
    )
    if harness.count(requested_token_guard) != 1:
        raise ValueError("causal requested binary token is not exact-one")
    if harness.count("((EXPECTED_FAULT_SEEN == 0))") != 1:
        raise ValueError("expected-fault duplicate/history guard drifted")
    forbidden_bash4 = (
        "declare -A",
        "mapfile ",
        "readarray ",
        "${var,,}",
        "local -n ",
    )
    for literal in forbidden_bash4:
        if literal in harness:
            raise ValueError(f"causal device harness is not Bash 3.2: {literal}")

    launch_start = harness.index("LAUNCH_ARGS=(-nomenu)")
    launch_end = harness.index(
        'if ((NEW_GAME != 0)); then\n  echo "== unattended launch:',
        launch_start,
    )
    launch = harness[launch_start:launch_end]
    ordered = (
        "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}${NATIVE_ALPHA_TEST_CAUSAL_MODE}",
        "${NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT}${NATIVE_ALPHA_TEST_CAUSAL_NONCE}",
        "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}",
    )
    positions = [launch.find(value) for value in ordered]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise ValueError("causal launch argv are missing or reordered")
    if launch.count("NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT") != 1:
        raise ValueError("causal launch contains an extra mode argument")
    if launch.count("NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT") != 1:
        raise ValueError("causal launch contains an extra nonce argument")
    if launch.count("NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT") != 1:
        raise ValueError("causal launch contains an extra sequence argument")
    expected_launch_block = (
        '  LAUNCH_ARGS+=(\n'
        '    "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}'
        '${NATIVE_ALPHA_TEST_CAUSAL_MODE}"\n'
        '    "${NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT}'
        '${NATIVE_ALPHA_TEST_CAUSAL_NONCE}"\n'
        '    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}'
        '${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"\n'
        "  )"
    )
    if launch.count(expected_launch_block) != 1:
        raise ValueError("causal launch argv are not one exact contiguous triple")
    snapshot = "pull_runtime_logs native-alpha-test-causal-prelaunch"
    launch_call = "xcrun devicectl device process launch --device"
    if harness.index(snapshot) >= harness.index(
        launch_call, harness.index(snapshot)
    ):
        raise ValueError("causal launch boundary is not captured before launch")
    attestation = "validate_native_alpha_test_causal_binary_profile"
    device_selection = 'REQUESTED_DEVICE="${OPENGOTHIC_IOS_DEVICE:-}"'
    install = "xcrun devicectl device install app"
    if not (
        harness.index(attestation, harness.index('strings "$APP_INPUT/$APP_EXECUTABLE"'))
        < harness.index(device_selection)
        < harness.index(install)
    ):
        raise ValueError("causal binary attestation no longer precedes phone mutation")

    schema_match = re.search(
        r'keys = \{\n(?P<body>.*?)\n\}',
        harness[harness.index("write_native_alpha_test_causal_contract()") :],
        re.DOTALL,
    )
    if schema_match is None:
        raise ValueError("causal contract schema is missing")
    schema = set(re.findall(r'"([A-Za-z][A-Za-z0-9]+)"', schema_match.group("body")))
    expected_schema = {
        "schemaVersion",
        "result",
        "parentSha",
        "mode",
        "nonce",
        "targetSequence",
        "launchBoundary",
        "armedLine",
        "encodedLine",
        "draws",
        "alpha",
        "binarySha256",
        "metallibSha256",
        "cleanupResult",
    }
    if schema != expected_schema:
        raise ValueError("causal contract exact key set drifted")
    finalizer_scope = exact_scope(
        harness,
        "finalize_native_alpha_test_causal_cleanup() {",
        "validate_native_alpha_test_causal_log() {",
        "causal cleanup finalizer",
    )
    for literal in (
        "if ((original_status != 0 || CAUSAL_FINALIZER_CLEANUP_STATUS != 0))",
        "write_native_alpha_test_causal_contract PASS passed",
        'write_native_alpha_test_causal_contract FAIL "$cleanup_result"',
        "commit_native_alpha_test_causal_pass_evidence",
        "CAUSAL_FINALIZER_PUBLISHED=1",
    ):
        if literal not in finalizer_scope:
            raise ValueError(f"causal cleanup finalizer drifted: {literal}")
    if finalizer_scope.count("install_native_alpha_test_causal_contract") != 2:
        raise ValueError("causal cleanup finalizer lost PASS/FAIL atomic installs")
    if finalizer_scope.count(
        'if publish_evidence_path "$PASS_EVIDENCE_DIR"; then'
    ) != 1:
        raise ValueError("causal finalizer lost checked evidence-path publication")
    if finalizer_scope.count(
        "retract_native_alpha_test_causal_pass_evidence \\"
    ) != 1:
        raise ValueError("causal finalizer lost atomic PASS retraction")
    if finalizer_scope.count(
        "invalidate_native_alpha_test_causal_result \\"
    ) != 1:
        raise ValueError("causal finalizer lost FAIL result invalidation")
    failure_install = (
        '"$PASS_EVIDENCE_DIR/causal-contract.json" FAIL "$cleanup_result" ||'
    )
    if finalizer_scope.count(failure_install) != 1:
        raise ValueError("causal cleanup finalizer lost FAIL overwrite/readback")
    cleanup_scope = exact_scope(
        harness,
        "\ncleanup() {",
        "trap cleanup EXIT",
        "smoke cleanup",
    )
    if cleanup_scope.count("finalize_native_alpha_test_causal_cleanup") != 1:
        raise ValueError("causal cleanup finalizer is not called exactly once")
    if 'publish_evidence_path "$PASS_EVIDENCE_DIR"' in cleanup_scope:
        raise ValueError("causal cleanup bypasses fail-closed publication")
    if (
        'OUT="$OUT_ROOT/.pending-pass-$timestamp-$$"' not in harness
        or 'PASS_EVIDENCE_FINAL_DIR="$OUT"' not in harness
    ):
        raise ValueError("causal PASS evidence is no longer atomically published")
    host_self_test = exact_scope(
        harness,
        "run_host_contract_self_test() {",
        "\nwhile [[ $# -gt 0 ]]; do",
        "smoke host self-test",
    )
    causal_fixture_call = "run_native_alpha_test_causal_host_self_test \\"
    final_publication = 'publish_evidence_path "$actual"'
    if (
        host_self_test.count(causal_fixture_call) != 1
        or host_self_test.count(final_publication) != 1
        or host_self_test.index(causal_fixture_call)
        >= host_self_test.index(final_publication)
    ):
        raise ValueError("causal fixture can overwrite final host evidence path")

    marker = "### CI contract: Verify P2.1c3b3 causal device harness"
    next_marker = "### CI contract: Verify physical-device smoke cleanup contract"
    section = exact_scope(contracts, marker, next_marker, "causal device harness")
    for literal in (
        '/bin/bash "$CAUSAL_HARNESS" --self-test',
        "--native-alpha-test-causal-mode causal-a",
        "--native-alpha-test-causal-sequence 18446744073709551615",
        "causal device harness parser mutation survived",
        "causal device harness source oracle",
        "causal-contract.json",
        "causal evidence-path publication failure",
        "/bin/bash ios/device-test/run-pipeline-archive-test.sh --self-test",
        "Bash 3.2",
    ):
        if literal not in section:
            raise ValueError(f"causal device harness CI contract drifted: {literal}")
    if "devicectl" in section or "xcodebuild" in section:
        raise ValueError("causal device harness host gate must not touch a device or build")


def replace_once(source: str, before: str, after: str) -> str:
    if source.count(before) != 1:
        raise AssertionError(f"mutation anchor is not unique: {before}")
    return source.replace(before, after, 1)


def replace_exact_line_once(source: str, before: str, after: str) -> str:
    lines = source.splitlines()
    if lines.count(before) != 1:
        raise AssertionError(f"mutation line anchor is not unique: {before}")
    lines[lines.index(before)] = after
    trailing_newline = "\n" if source.endswith("\n") else ""
    return "\n".join(lines) + trailing_newline


def replace_once_in_job(
    source: str,
    job: str,
    before: str,
    after: str,
) -> str:
    scope = workflow_job(source, job)
    mutated = replace_once(scope, before, after)
    if source.count(scope) != 1:
        raise AssertionError(f"workflow job scope is not unique: {job}")
    return source.replace(scope, mutated, 1)


def test_classification() -> None:
    dispatch = CI.classify_event(
        "workflow_dispatch",
        REPO,
        "",
        "1" * 40,
    )
    assert dispatch["gates"] == ["full"]
    assert CI.required_jobs(dispatch) == {
        "contracts": True,
        "build_off": True,
        "build_on": True,
        "build_tile": True,
        "build_forward": True,
    }

    narrow = {
        "schemaVersion": 1,
        "gates": ["tile-contracts", "build-tile", "build-off"],
    }
    assert CI.required_jobs(narrow) == {
        "contracts": True,
        "build_off": True,
        "build_on": False,
        "build_tile": True,
        "build_forward": False,
    }
    assert CI.required_jobs({"gates": ["policy-contracts"]}) == {
        "contracts": False,
        "build_off": False,
        "build_on": False,
        "build_tile": False,
        "build_forward": False,
    }
    expect_error(lambda: CI.required_jobs({"gates": []}))
    expect_error(lambda: CI.required_jobs({"gates": ["full", "build-off"]}))
    expect_error(lambda: CI.required_jobs({"gates": ["invented-gate"]}))

    bad_before = CI.classify_event("push", REPO, "", "1" * 40)
    assert bad_before["gates"] == ["full"]
    assert bad_before["contextError"] == "before-sha-unavailable"
    unsupported = CI.classify_event("pull_request", REPO, "0" * 40, "1" * 40)
    assert unsupported["gates"] == ["full"]
    assert unsupported["contextError"] == "unsupported-event"


def test_push_before_to_sha() -> None:
    with tempfile.TemporaryDirectory() as directory:
        repo = pathlib.Path(directory)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "config", "user.email", "ci@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(repo), "config", "user.name", "CI"],
            check=True,
        )
        (repo / "README.md").write_text("before\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-qm", "before"], check=True)
        before = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            text=True,
        ).strip()
        (repo / "README.md").write_text("after\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "commit", "-qam", "after"], check=True)
        head = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            text=True,
        ).strip()
        result = CI.classify_push(repo, before, head)
        assert result["selection"] == "push-before-to-sha"
        assert result["eventBaseSha"] == before
        assert result["eventHeadSha"] == head
        assert result["changedPaths"] == ["README.md"]
        assert result["gates"] == ["policy-contracts"]


def test_aggregation() -> None:
    expected = {
        "contracts": True,
        "build_off": True,
        "build_on": False,
        "build_tile": True,
        "build_forward": False,
    }
    passing = {
        "contracts": "success",
        "build_off": "success",
        "build_on": "skipped",
        "build_tile": "success",
        "build_forward": "skipped",
    }
    CI.aggregate("success", expected, passing)
    expect_error(lambda: CI.aggregate("failure", expected, passing))
    missing_required = dict(passing, build_tile="skipped")
    expect_error(lambda: CI.aggregate("success", expected, missing_required))
    failed_required = dict(passing, build_off="failure")
    expect_error(lambda: CI.aggregate("success", expected, failed_required))
    cancelled_required = dict(passing, contracts="cancelled")
    expect_error(lambda: CI.aggregate("success", expected, cancelled_required))
    unexpected = dict(passing, build_on="success")
    expect_error(lambda: CI.aggregate("success", expected, unexpected))


def test_workflow_contract() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    contracts = CONTRACTS.read_text(encoding="utf-8")
    profile = PROFILE.read_text(encoding="utf-8")
    context = IOS_METAL_CONTEXT.read_text(encoding="utf-8")
    validate_workflow(workflow)
    validate_extracted_oracles(contracts, profile)
    validate_clear_only_admission_contract(contracts, context)
    mailbox_mutation = replace_once(
        context,
        "  impl->pollClearOnlyPassSelfTest();\n  return std::nullopt;",
        "  impl->pollClearOnlyPassSelfTest();\n"
        "  impl->takePresentFailureAndLatchProof(\n"
        '      "RendererIOS asynchronous Metal present failed");\n'
        "  return std::nullopt;",
    )
    try:
        validate_clear_only_admission_contract(contracts, mailbox_mutation)
    except ValueError:
        pass
    else:
        raise AssertionError("clear-only mailbox mutation survived")
    mutations = (
        replace_once(
            workflow,
            "EVENT_BEFORE: ${{ github.event.before }}",
            "EVENT_BEFORE: ${{ github.sha }}",
        ),
        replace_once(
            workflow,
            "if: needs.classifier.outputs.build_tile == 'true'",
            "if: needs.classifier.outputs.build_tile != 'true'",
        ),
        replace_once(workflow, "if: always()", "if: success()"),
        replace_once(
            workflow,
            '--result-build-forward "${{ needs.build-forward.result }}"',
            '--result-build-forward "skipped"',
        ),
        replace_once(
            workflow,
            "  build-forward:",
            "  build-forward-renamed:",
        ),
        replace_once_in_job(
            workflow,
            "build-off",
            "        run: scripts/ci_build_profile.command off",
            "        run: true",
        ),
        replace_once_in_job(
            workflow,
            "build-on",
            "        uses: actions/checkout@v4",
            "        run: true",
        ),
    )
    killed = 0
    for candidate in mutations:
        try:
            validate_workflow(candidate)
        except ValueError:
            killed += 1
        else:
            raise AssertionError("workflow mutation survived")
    assert killed == 7
    extraction_mutations = (
        (
            replace_once(
                contracts,
                "### CI contract: Verify neutral P2.1 scene boundary",
                "### CI contract removed: Verify neutral P2.1 scene boundary",
            ),
            profile,
        ),
        (
            replace_once(
                contracts,
                "# CI_CONTRACT_P23C_COMPILE_END",
                "# CI_CONTRACT_P23C_COMPILE_REMOVED",
            ),
            profile,
        ),
        (
            replace_once(
                contracts,
                "printf '\\n### CI contract: Verify P2.3c clear-only pass contract\\n'",
                "printf '\\n### CI contract: P2.3c compile removed\\n'",
            ),
            profile,
        ),
        (
            replace_exact_line_once(
                contracts,
                "  ios/device-test/run-smoke-test.sh --save-slot 1 --self-test",
                "  ios/device-test/run-smoke-test.sh --self-test",
            ),
            profile,
        ),
        (
            contracts,
            replace_exact_line_once(
                profile,
                "  set --",
                "  extra=()",
            ),
        ),
        (
            contracts,
            replace_once(
                profile,
                "# CI_PROFILE_CONFIGURE_BEGIN",
                "# CI_PROFILE_CONFIGURE_REMOVED",
            ),
        ),
        (
            contracts,
            replace_once(
                profile,
                "# CI_PROFILE_CONFIGURE_END",
                "# CI_PROFILE_CONFIGURE_REMOVED",
            ),
        ),
        (
            contracts,
            replace_once(
                profile,
                "# CI_PROFILE_CANDIDATE_BEGIN",
                "# CI_PROFILE_CANDIDATE_REMOVED",
            ),
        ),
        (
            contracts,
            replace_once(
                profile,
                "# CI_PROFILE_CANDIDATE_END",
                "# CI_PROFILE_CANDIDATE_REMOVED",
            ),
        ),
        (
            contracts,
            replace_once(
                profile,
                'cmake --preset "renderer-ios-$PROFILE" -B build-renderer-ios',
                "true # configure removed",
            ),
        ),
        (
            contracts,
            replace_once(
                profile,
                "printf '\\n### CI profile Build iOS Release\\n'",
                "printf '\\n### CI profile build removed\\n'",
            ),
        ),
        (
            contracts,
            replace_once(
                profile,
                "printf '\\n### CI profile Verify P2.6b1 final weak MetalFX dependency\\n'",
                "printf '\\n### CI profile weak check removed\\n'",
            ),
        ),
    )
    extraction_killed = 0
    for candidate_contracts, candidate_profile in extraction_mutations:
        try:
            validate_extracted_oracles(candidate_contracts, candidate_profile)
        except ValueError:
            extraction_killed += 1
        else:
            raise AssertionError("extracted CI/profile mutation survived")
    assert extraction_killed == 12


def test_cmake_presets_contract() -> None:
    presets = json.loads(PRESETS.read_text(encoding="utf-8"))
    gitignore = GITIGNORE.read_text(encoding="utf-8")
    local_verify = LOCAL_VERIFY.read_text(encoding="utf-8")
    profile = PROFILE.read_text(encoding="utf-8")
    contracts = CONTRACTS.read_text(encoding="utf-8")
    validate_cmake_presets(
        presets,
        gitignore,
        local_verify,
        profile,
        contracts,
    )

    mutations = []

    def mutated_presets(callback):
        candidate = json.loads(json.dumps(presets))
        callback(candidate)
        mutations.append(
            (candidate, gitignore, local_verify, profile, contracts)
        )

    mutated_presets(lambda candidate: candidate.__setitem__("version", 3))
    mutated_presets(
        lambda candidate: candidate["cmakeMinimumRequired"].__setitem__(
            "minor", 19
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][0].__setitem__(
            "generator", "Ninja"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][0]["cacheVariables"].__setitem__(
            "CMAKE_OSX_ARCHITECTURES", "x86_64"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][0]["cacheVariables"].__setitem__(
            "CMAKE_OSX_DEPLOYMENT_TARGET", "15.0"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][3]["cacheVariables"].__setitem__(
            "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS", "OFF"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][3]["cacheVariables"].__setitem__(
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST", "ON"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][0]["cacheVariables"].__setitem__(
            "OPENGOTHIC_RENDERER_IOS_BUILD_SHA", "stale"
        )
    )
    mutated_presets(
        lambda candidate: candidate["buildPresets"][0]["nativeToolOptions"].__setitem__(
            2, "CODE_SIGNING_ALLOWED=YES"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][1]["cacheVariables"].pop(
            "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][5]["environment"].__setitem__(
            "PACKAGE_DEVICE_IPA", "1"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][6]["cacheVariables"].__setitem__(
            "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE", "none"
        )
    )
    mutated_presets(
        lambda candidate: candidate["configurePresets"][7]["cacheVariables"].__setitem__(
            "OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS", "OFF"
        )
    )
    mutated_presets(
        lambda candidate: candidate["buildPresets"].__setitem__(
            slice(5, 7),
            list(reversed(candidate["buildPresets"][5:7])),
        )
    )
    mutations.extend(
        (
            (
                presets,
                gitignore,
                local_verify.replace(
                    ' -B "$build"',
                    "",
                    1,
                ),
                profile,
                contracts,
            ),
            (
                presets,
                gitignore,
                local_verify.replace(
                    '-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="$HEAD_SHA-local"',
                    "-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA=stale",
                    1,
                ),
                profile,
                contracts,
            ),
            (
                presets,
                gitignore,
                local_verify,
                profile.replace(" -B build-renderer-ios", "", 1),
                contracts,
            ),
            (
                presets,
                gitignore.replace(
                    "CMakeUserPresets.json",
                    "*Presets.json",
                    1,
                ),
                local_verify,
                profile,
                contracts,
            ),
            (
                presets,
                gitignore,
                local_verify,
                profile,
                contracts.replace("cmake --list-presets", "true", 1),
            ),
        )
    )
    killed = 0
    for candidate in mutations:
        try:
            validate_cmake_presets(*candidate)
        except ValueError:
            killed += 1
        else:
            raise AssertionError("CMake presets mutation survived")
    assert killed == 19


def test_causal_build_isolation_source_contract() -> None:
    cmake = CMAKE.read_text(encoding="utf-8")
    profile = PROFILE.read_text(encoding="utf-8")
    local_verify = LOCAL_VERIFY.read_text(encoding="utf-8")
    contracts = CONTRACTS.read_text(encoding="utf-8")
    validate_causal_build_isolation_source(
        cmake,
        profile,
        local_verify,
        contracts,
    )
    mutations = (
        (
            replace_once(
                cmake,
                'set(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE "none"',
                'set(OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_MODE "causal-a"',
            ),
            profile,
            local_verify,
            contracts,
        ),
        (
            replace_once(
                cmake,
                "_renderer_ios_native_alpha_test_causal_mode_index EQUAL -1",
                "FALSE",
            ),
            profile,
            local_verify,
            contracts,
        ),
        (
            replace_once(
                cmake,
                "RendererIOS native AlphaTest causal A/B builds are available only for iOS",
                "RendererIOS causal platform unrestricted",
            ),
            profile,
            local_verify,
            contracts,
        ),
        (
            replace_once(
                cmake,
                "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1",
                "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=10",
            ),
            profile,
            local_verify,
            contracts,
        ),
        (
            replace_once(
                cmake,
                "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_B=1",
                "OPENGOTHIC_RENDERER_IOS_NATIVE_ALPHA_TEST_CAUSAL_A=1",
            ),
            profile,
            local_verify,
            contracts,
        ),
        (
            cmake,
            replace_once(
                profile,
                'RAW_ACTIVE_FAULT_MODE_SET="${ACTIVE_FAULT_MODE+x}"',
                "RAW_ACTIVE_FAULT_MODE_SET=",
            ),
            local_verify,
            contracts,
        ),
        (
            cmake,
            replace_once(
                profile,
                "reject_causal_raw_conflict()",
                "accept_causal_raw_conflict()",
            ),
            local_verify,
            contracts,
        ),
        (
            cmake,
            replace_once(
                profile,
                "(?<![A-Za-z0-9_])",
                "",
            ),
            local_verify,
            contracts,
        ),
        (
            cmake,
            profile,
            replace_once(
                local_verify,
                'local build="$TMP_GATE/causal-invalid-$mode-$name"',
                'local build="$TMP_GATE/causal-invalid-$mode"',
            ),
            contracts,
        ),
        (
            cmake,
            profile,
            replace_once(
                local_verify,
                'project.replace(expected_macro, "MUTANT_" + expected_macro, 1)',
                "project",
            ),
            contracts,
        ),
        (
            cmake,
            profile,
            local_verify,
            replace_once(
                contracts,
                "### CI contract: Verify P2.1c3b3b causal build isolation",
                "### CI contract: Verify P2.1c3b3b causal build isolation\n"
                "cmake --build MUTANT",
            ),
        ),
        (
            cmake,
            profile,
            local_verify,
            replace_once(
                contracts,
                'local build="$CAUSAL_CONTRACT_ROOT/invalid-$mode-$name"',
                'local build="$CAUSAL_CONTRACT_ROOT/invalid-$mode"',
            ),
        ),
        (
            cmake,
            profile,
            local_verify,
            replace_once(
                contracts,
                "total_pbx_mutations != 17",
                "total_pbx_mutations != 15",
            ),
        ),
        (
            cmake,
            profile,
            local_verify,
            replace_once(
                contracts,
                'project.replace(expected, "MUTANT_" + expected, 1)',
                "project",
            ),
        ),
    )
    killed = 0
    for candidate in mutations:
        try:
            validate_causal_build_isolation_source(*candidate)
        except ValueError:
            killed += 1
        else:
            raise AssertionError("causal build-isolation source mutation survived")
    assert killed == 14


def test_causal_device_harness_source_contract() -> None:
    harness = SMOKE_HARNESS.read_text(encoding="utf-8")
    contracts = CONTRACTS.read_text(encoding="utf-8")
    validate_causal_device_harness_source(harness, contracts)

    expected_sha = "0123456789abcdef0123456789abcdef01234567"
    expected_build = expected_sha + "-local"
    with tempfile.TemporaryDirectory() as external_directory:
        external_evidence = pathlib.Path(external_directory) / "evidence-path.txt"
        valid = subprocess.run(
            [
                "/bin/bash",
                str(SMOKE_HARNESS),
                "--self-test",
                "--native-alpha-test-causal-mode",
                "causal-a",
                "--native-alpha-test-causal-sequence",
                "18446744073709551615",
                "--evidence-path-file",
                str(external_evidence),
            ],
            cwd=REPO,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env={
                **os.environ,
                "OPENGOTHIC_IOS_EXPECTED_SHA": expected_sha,
                "OPENGOTHIC_IOS_EXPECTED_BUILD": expected_build,
                "OPENGOTHIC_IOS_EXPECTED_FAULT": "none",
                "OPENGOTHIC_IOS_EVIDENCE_TIMESTAMP": "20000101T000000Z",
                "OPENGOTHIC_IOS_EVIDENCE_PID": "4242",
            },
        )
        assert valid.returncode == 0, valid.stderr
        assert external_evidence.read_text(encoding="utf-8").splitlines() == [
            str(
                REPO
                / "build"
                / "device-fault"
                / expected_build
                / "none"
                / "pass-20000101T000000Z-4242"
            )
        ]

    pipeline_archive = subprocess.run(
        ["/bin/bash", str(PIPELINE_ARCHIVE_HARNESS), "--self-test"],
        cwd=REPO,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert pipeline_archive.returncode == 0, pipeline_archive.stderr

    common = [
        "--self-test",
        "--native-alpha-test-causal-mode",
        "causal-a",
        "--native-alpha-test-causal-sequence",
        "7",
    ]
    invalid_arguments = (
        ["--self-test", "--native-alpha-test-causal-mode", "causal-a"],
        ["--self-test", "--native-alpha-test-causal-sequence", "7"],
        [
            "--self-test",
            "--native-alpha-test-causal-mode",
            "causal-a",
            "--native-alpha-test-causal-mode",
            "causal-a",
            "--native-alpha-test-causal-sequence",
            "7",
        ],
        common + ["--native-alpha-test-causal-sequence", "8"],
        [
            "--self-test",
            "--native-alpha-test-causal-mode",
            "production",
            "--native-alpha-test-causal-sequence",
            "7",
        ],
        [
            "--self-test",
            "--native-alpha-test-causal-mode",
            "causal-a",
            "--native-alpha-test-causal-sequence",
            "0",
        ],
        [
            "--self-test",
            "--native-alpha-test-causal-mode",
            "causal-a",
            "--native-alpha-test-causal-sequence",
            "01",
        ],
        [
            "--self-test",
            "--native-alpha-test-causal-mode",
            "causal-a",
            "--native-alpha-test-causal-sequence",
            "18446744073709551616",
        ],
        common + ["--renderer-ios-native-alpha-test-causal-extra=1"],
        common + ["--require-bink-self-test"],
        common + ["--expected-fault", "post-submit-suboptimal"],
        common
        + [
            "--expected-fault",
            "post-submit-suboptimal",
            "--expected-fault",
            "none",
        ],
        common + ["--pipeline-archive-test-mode", "cold"],
    )
    for arguments in invalid_arguments:
        rejected = subprocess.run(
            ["/bin/bash", str(SMOKE_HARNESS), *arguments],
            cwd=REPO,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert rejected.returncode != 0, (
            "causal device harness parser mutation survived: "
            + repr(arguments)
        )

    mutations = (
        replace_once(harness, "len(causal) != 2", "len(causal) < 2"),
        replace_once(
            harness,
            "len(shell) != 1 or shell[0][1] != expected_build",
            "len(shell) < 1 or shell[0][1] != expected_build",
        ),
        replace_once(
            harness,
            'len(fault) != 1 or fault[0][1] != "none"',
            'len(fault) < 1 or fault[0][1] != "none"',
        ),
        replace_once(
            harness,
            "shell[0][0] < encoded[0][0]",
            "shell[0][0] > encoded[0][0]",
        ),
        replace_once(
            harness,
            "fault[0][0] < encoded[0][0]",
            "fault[0][0] > encoded[0][0]",
        ),
        replace_once(
            harness,
            "armed[0][0] < encoded[0][0]",
            "armed[0][0] > encoded[0][0]",
        ),
        replace_once(
            harness,
            "alpha <= 0 or draws < alpha",
            "alpha < 0 or draws < alpha",
        ),
        replace_once(
            harness,
            "pull_runtime_logs native-alpha-test-causal-prelaunch",
            "true # missing causal pre-launch boundary",
        ),
        replace_once(
            harness,
            (
                '[[ "$(grep -Fxc -- "$NATIVE_ALPHA_TEST_CAUSAL_MODE" \\\n'
                '    "$strings_file" || true)" -eq 1 ]] || return 1'
            ),
            (
                '[[ "$(grep -Fxc -- "$NATIVE_ALPHA_TEST_CAUSAL_MODE" \\\n'
                '    "$strings_file" || true)" -le 1 ]] || return 1'
            ),
        ),
        replace_once(
            harness,
            (
                '  LAUNCH_ARGS+=(\n'
                '    "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_MODE}"\n'
                '    "${NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_NONCE}"\n'
                '    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"\n'
                "  )"
            ),
            (
                '  LAUNCH_ARGS+=(\n'
                '    "${NATIVE_ALPHA_TEST_CAUSAL_NONCE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_NONCE}"\n'
                '    "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_MODE}"\n'
                '    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"\n'
                "  )"
            ),
        ),
        replace_once(
            harness,
            (
                '    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"\n'
                "  )"
            ),
            (
                '    "${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_SEQUENCE}"\n'
                '    "${NATIVE_ALPHA_TEST_CAUSAL_MODE_ARGUMENT}'
                '${NATIVE_ALPHA_TEST_CAUSAL_MODE}"\n'
                "  )"
            ),
        ),
        replace_once(
            harness,
            '"metallibSha256",\n    "cleanupResult",\n}',
            '"metallibSha256",\n}',
        ),
        replace_once(
            harness,
            (
                "if ((original_status != 0 || "
                "CAUSAL_FINALIZER_CLEANUP_STATUS != 0)); then"
            ),
            (
                "if ((original_status != 0 && "
                "CAUSAL_FINALIZER_CLEANUP_STATUS != 0)); then"
            ),
        ),
        replace_once(
            harness,
            (
                '      "$WORK/causal-contract.json" \\\n'
                '      "$PASS_EVIDENCE_DIR/causal-contract.json" '
                'FAIL "$cleanup_result" ||'
            ),
            (
                '      "$WORK/causal-contract.json" \\\n'
                '      "$PASS_EVIDENCE_DIR/causal-contract.json" '
                'PASS passed ||'
            ),
        ),
        replace_once(
            harness,
            'if injected_fault == "copy":',
            'if injected_fault == "disabled-copy":',
        ),
        replace_once(
            harness,
            'if injected_fault == "readback":',
            'if injected_fault == "disabled-readback":',
        ),
        replace_once(
            harness,
            "commit_native_alpha_test_causal_pass_evidence \\",
            "true # missing atomic causal PASS rename",
        ),
        replace_once(
            harness,
            'if publish_evidence_path "$PASS_EVIDENCE_DIR"; then',
            "if true; then # ignored causal evidence-path publication",
        ),
        replace_once(
            harness,
            "retract_native_alpha_test_causal_pass_evidence \\",
            "true # missing atomic causal PASS retraction",
        ),
        replace_once(
            harness,
            "invalidate_native_alpha_test_causal_result \\",
            "true # missing causal FAIL result invalidation",
        ),
        replace_once(
            harness,
            'EVIDENCE_PATH_FILE="$directory/causal-finalizer-evidence-path.txt"',
            'EVIDENCE_PATH_FILE="$caller_evidence_path_file"',
        ),
        replace_once(
            harness,
            'publish_evidence_path "$actual"',
            "true # missing final host evidence-path publication",
        ),
        replace_once(
            harness,
            "((EXPECTED_FAULT_SEEN == 0))",
            "((EXPECTED_FAULT_SEEN >= 0))",
        ),
        replace_once(
            harness,
            "fatal.search(segment) or fatal.search(stderr_segment)",
            "fatal.search(segment)",
        ),
        replace_once(
            harness,
            'fail "native alpha-test causal mode requires an exact-SHA build"',
            "true # allow local causal build",
        ),
    )
    for mutated in mutations:
        try:
            validate_causal_device_harness_source(mutated, contracts)
        except ValueError:
            continue
        raise AssertionError("causal device harness source mutation survived")


def test_ui_automation_host_contract() -> None:
    harness = UI_AUTOMATION_HARNESS.read_text()
    selector = UI_AUTOMATION_SELECTOR.read_text()
    contracts = CONTRACTS.read_text()
    validate_ui_automation_host_contract(harness, selector, contracts)

    selector_self_test = subprocess.run(
        ["python3", str(UI_AUTOMATION_SELECTOR), "self-test"],
        cwd=REPO,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    assert selector_self_test.returncode == 0, selector_self_test.stderr
    harness_self_test = subprocess.run(
        ["/bin/bash", str(UI_AUTOMATION_HARNESS), "--self-test"],
        cwd=REPO,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert harness_self_test.returncode == 0, harness_self_test.stderr

    def mutate_exact(
        source: str,
        replacements: tuple[tuple[str, str], ...],
    ) -> str:
        mutated = source
        for before, after in replacements:
            if mutated.count(before) != 1:
                raise AssertionError(
                    "UI automation mutation anchor is not exact: " + before
                )
            mutated = mutated.replace(before, after, 1)
        return mutated

    selector_mutations = (
        (
            "network-first",
            (
                (
                    "        return valid_usb[0]\n",
                    "        return next(\n"
                    "            (\n"
                    "                candidate\n"
                    "                for witness in _transport_witnesses(\n"
                    '                    xc_records, "network"\n'
                    "                )\n"
                    "                if (candidate := _validate_pair(\n"
                    "                    witness, core_records\n"
                    "                )[0]) is not None\n"
                    "            ),\n"
                    "            valid_usb[0],\n"
                    "        )\n",
                ),
            ),
        ),
        (
            "missing-platform-prefilter",
            (
                (
                    "    iphone_witnesses = "
                    "_iphone_witness_records(xc_records)\n",
                    "    iphone_witnesses = xc_records\n",
                ),
            ),
        ),
        (
            "malformed-usb-fallback",
            (("    if usb_witnesses:\n", "    if False and usb_witnesses:\n"),),
        ),
        (
            "missing-udid-cross-match",
            (
                (
                    "        if _core_udid(record) == identifier\n",
                    "        if _core_udid(record) is not None\n",
                ),
                ("    if len(matches) != 1:\n", "    if not matches:\n"),
                (
                    "    if identifier != core_udid:\n",
                    "    if False and identifier != core_udid:\n",
                ),
            ),
        ),
        (
            "missing-connected",
            (
                (
                    "    if not _core_device_is_connected(core_record):\n",
                    "    if False and not "
                    "_core_device_is_connected(core_record):\n",
                ),
            ),
        ),
        (
            "missing-physical",
            (
                (
                    '    if hardware.get("reality") != PHYSICAL_REALITY:\n',
                    '    if False and hardware.get("reality") '
                    "!= PHYSICAL_REALITY:\n",
                ),
            ),
        ),
        (
            "missing-simulator",
            (
                (
                    '    if xc_record.get("simulator") is not False:\n',
                    '    if False and xc_record.get("simulator") '
                    "is not False:\n",
                ),
            ),
        ),
        (
            "missing-available",
            (
                (
                    '    if xc_record.get("available") is not True:\n',
                    '    if False and xc_record.get("available") '
                    "is not True:\n",
                ),
            ),
        ),
        (
            "missing-xc-platform",
            (
                (
                    '    if xc_record.get("platform") != IPHONEOS_PLATFORM:\n',
                    '    if False and xc_record.get("platform") '
                    "!= IPHONEOS_PLATFORM:\n",
                ),
            ),
        ),
        (
            "missing-core-platform",
            (
                (
                    '    if hardware.get("platform") != IOS_PLATFORM:\n',
                    '    if False and hardware.get("platform") '
                    "!= IOS_PLATFORM:\n",
                ),
            ),
        ),
        (
            "first-of-many-usb",
            (
                (
                    "        if invalid_usb or len(valid_usb) != 1:\n",
                    "        if invalid_usb:\n",
                ),
            ),
        ),
        (
            "ignore-requested",
            (
                (
                    "    if requested:\n"
                    "        return _select_requested("
                    "iphone_witnesses, core_records, requested)\n",
                    "    if False and requested:\n"
                    "        return _select_requested("
                    "iphone_witnesses, core_records, requested)\n",
                ),
            ),
        ),
        (
            "first-requested",
            (("    if len(target_udids) != 1:\n", "    if not target_udids:\n"),),
        ),
        (
            "duplicate-xc-collapse",
            (("    if len(xc_matches) != 1:\n", "    if not xc_matches:\n"),),
        ),
        (
            "duplicate-core-collapse",
            (
                ("    if len(core_matches) != 1:\n", "    if not core_matches:\n"),
                ("    if len(matches) != 1:\n", "    if not matches:\n"),
            ),
        ),
        (
            "prefix-only-bundle",
            (
                (
                    "        if product_pattern.fullmatch(bundle):\n",
                    "        if bundle.startswith(base_bundle_id + \".\"):\n",
                ),
            ),
        ),
        (
            "runner-accepted",
            (
                (
                    "        elif runner_pattern.fullmatch(bundle):\n"
                    "            continue\n",
                    "        elif runner_pattern.fullmatch(bundle):\n"
                    "            products.append(bundle)\n",
                ),
            ),
        ),
    )
    selector_mutations_killed = 0
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = pathlib.Path(temporary)
        for label, replacements in selector_mutations:
            mutant = temporary_root / f"selector-{label}.py"
            mutant.write_text(mutate_exact(selector, replacements))
            result = subprocess.run(
                ["python3", str(mutant), "self-test"],
                cwd=REPO,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            assert result.returncode != 0, (
                "UI automation selector mutation survived: " + label
            )
            selector_mutations_killed += 1
    assert selector_mutations_killed == 17

    diagnostics = "    -collect-test-diagnostics never \\\n"
    harness_mutations = (
        ("diagnostics-removed", ((diagnostics, ""),)),
        (
            "diagnostics-changed",
            ((diagnostics, "    -collect-test-diagnostics always \\\n"),),
        ),
        (
            "diagnostics-duplicated",
            ((diagnostics, diagnostics + diagnostics),),
        ),
        (
            "diagnostics-non-adjacent",
            (
                (
                    diagnostics,
                    "    -collect-test-diagnostics \\\n"
                    "    -quiet \\\n"
                    "    never \\\n",
                ),
            ),
        ),
        (
            "diagnostics-after-action",
            (
                (
                    diagnostics + "    test\n",
                    "    test \\\n"
                    "    -collect-test-diagnostics never\n",
                ),
            ),
        ),
        (
            "explicit-team-id-ignored",
            (
                (
                    "  if [[ -n \"$requested\" ]]; then\n"
                    "    team=\"$requested\"\n"
                    "  else\n"
                    "    team=\"${bundle##*.}\"\n"
                    "  fi\n",
                    "  team=\"${bundle##*.}\"\n",
                ),
            ),
        ),
    )
    harness_mutations_killed = 0
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = pathlib.Path(temporary)
        for label, replacements in harness_mutations:
            mutant = temporary_root / f"harness-{label}.sh"
            mutant.write_text(mutate_exact(harness, replacements))
            result = subprocess.run(
                ["/bin/bash", str(mutant), "--self-test"],
                cwd=REPO,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            assert result.returncode != 0, (
                "UI automation harness mutation survived: " + label
            )
            harness_mutations_killed += 1
    assert harness_mutations_killed == 6


def test_bash32_candidate_arguments() -> None:
    profile = PROFILE.read_text(encoding="utf-8")
    candidate = exact_scope(
        profile,
        "# CI_PROFILE_CANDIDATE_BEGIN",
        "# CI_PROFILE_CANDIDATE_END",
        "profile candidate metallib",
    )
    export_oracle_sources = (
        ("profile", profile, 1),
        ("contracts", CONTRACTS.read_text(encoding="utf-8"), 2),
        ("local", LOCAL_VERIFY.read_text(encoding="utf-8"), 2),
    )
    tone_exports = ("riosToneResolveVertex", "riosToneResolveFragment")
    cross_script_mutations_killed = 0
    for label, source, expected_count in export_oracle_sources:
        for function in tone_exports:
            assert source.count(function) == expected_count, (
                f"{label} exact ABI8 export oracle drifted: {function}"
            )
            mutant = source.replace(function, "riosToneResolveMutant", 1)
            assert mutant.count(function) != expected_count, (
                f"{label} ABI8 export mutation survived: {function}"
            )
            cross_script_mutations_killed += 1
    assert cross_script_mutations_killed == 6
    exports = (
        "riosLandscapeVertex",
        "riosLandscapeFragment",
        "riosLandscapeAlphaTestFragment",
        "riosToneResolveVertex",
        "riosToneResolveFragment",
        "riosBinkVertex",
        "riosBinkFragment",
        "riosUiColorVertex",
        "riosUiColorFragment",
        "riosUiTextureVertex",
        "riosUiTextureFragment",
        "riosInventoryVertex",
        "riosInventoryFragment",
        "riosShadingPrototypeVertex",
        "riosTileDeferredMaterialFragment",
        "riosTileDeferredLighting",
        "riosForwardPlusBuildLightList",
        "riosForwardPlusFragment",
    )
    assert len(exports) == 18
    metal_nm_output = "".join(f"00000000 T {name}\\n" for name in exports)
    harness = f"""\
set -Eeuo pipefail
IFS=$'\\n\\t'
xcrun() {{
  {{
    printf 'call'
    for argument in "$@"; do
      printf ' <%s>' "$argument"
    done
    printf '\\n'
  }} >>"$RUNNER_TEMP/xcrun.log"
  if [ "${{3:-}}" = metal-nm ]; then
    printf '%b' {json.dumps(metal_nm_output)}
    return
  fi
  output=
  previous=
  for argument in "$@"; do
    if [ "$previous" = -o ]; then
      output="$argument"
    fi
    previous="$argument"
  done
  test -n "$output"
  : >"$output"
}}
{candidate}
"""
    with tempfile.TemporaryDirectory() as directory:
        environment = os.environ.copy()
        environment["RUNNER_TEMP"] = directory
        subprocess.run(
            ["/bin/bash"],
            input=harness,
            text=True,
            cwd=REPO,
            env=environment,
            check=True,
        )
        commands = (
            pathlib.Path(directory) / "xcrun.log"
        ).read_text(encoding="utf-8").splitlines()
    metal_commands = [
        command
        for command in commands
        if command.startswith(
            "call <--sdk> <iphoneos> <metal> <-target>"
        )
    ]
    assert len(commands) == 7
    assert len(metal_commands) == 5
    assert all(
        flag in metal_commands[0]
        for flag in ("-Wall", "-Wextra", "-Werror")
    )
    assert all(
        flag not in command
        for command in metal_commands[1:4]
        for flag in ("-Wall", "-Wextra", "-Werror")
    )
    assert all(
        flag in metal_commands[-1]
        for flag in ("-Wall", "-Wextra", "-Werror")
    )

    old_abi7_exports = tuple(
        name for name in exports
        if name not in ("riosToneResolveVertex", "riosToneResolveFragment")
    )
    assert len(old_abi7_exports) == 16
    export_mutations = (
        (
            "missing-tone-vertex",
            tuple(name for name in exports if name != "riosToneResolveVertex"),
        ),
        (
            "missing-tone-fragment",
            tuple(name for name in exports if name != "riosToneResolveFragment"),
        ),
        ("old-abi7-set", old_abi7_exports),
        ("duplicate-tone-vertex", exports + ("riosToneResolveVertex",)),
        ("unexpected-export", exports + ("riosUnexpectedRuntimeShader",)),
    )
    mutations_killed = 0
    for label, mutated_exports in export_mutations:
        mutated_nm = "".join(
            f"00000000 T {name}\\n" for name in mutated_exports
        )
        mutated_harness = f"""\
set -Eeuo pipefail
IFS=$'\\n\\t'
xcrun() {{
  if [ "${{3:-}}" = metal-nm ]; then
    printf '%b' {json.dumps(mutated_nm)}
    return
  fi
  output=
  previous=
  for argument in "$@"; do
    if [ "$previous" = -o ]; then
      output="$argument"
    fi
    previous="$argument"
  done
  test -n "$output"
  : >"$output"
}}
{candidate}
"""
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["/bin/bash"],
                input=mutated_harness,
                text=True,
                cwd=REPO,
                env={**os.environ, "RUNNER_TEMP": directory},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        assert result.returncode != 0, (
            "RendererIOS ABI8 export mutation survived: " + label
        )
        mutations_killed += 1
    assert mutations_killed == 5


def test_bash32_causal_profile_tuple() -> None:
    source = PROFILE.read_text(encoding="utf-8")
    boundary = source.find("\nfor value in \\")
    if boundary < 0:
        raise AssertionError("CI causal profile parser boundary is missing")
    parser = source[:boundary]
    raw_names = (
        "DIAGNOSTICS",
        "ACTIVE_FAULT_MODE",
        "CAUSAL_MODE",
        "BINK_SELF_TEST",
        "RESOURCE_ALLOCATOR_SELF_TEST",
        "CLEAR_ONLY_PASS_SELF_TEST",
        "SHADING_PROTOTYPE_TILE_SELF_TEST",
        "SHADING_PROTOTYPE_FORWARD_SELF_TEST",
        "TEMPEST_PROFILE",
        "PACKAGE_DEVICE_IPA",
    )
    base_environment = os.environ.copy()
    for name in raw_names:
        base_environment.pop(name, None)
    base_environment["RUNNER_TEMP"] = tempfile.gettempdir()
    base_environment["GITHUB_SHA"] = "1" * 40

    clean = subprocess.run(
        ["/bin/bash", "-s", "--", "causal-a"],
        input=parser,
        text=True,
        cwd=REPO,
        env=base_environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert clean.returncode == 0, clean.stderr

    matching_environment = dict(
        base_environment,
        DIAGNOSTICS="ON",
        ACTIVE_FAULT_MODE="none",
        CAUSAL_MODE="causal-b",
        BINK_SELF_TEST="OFF",
        RESOURCE_ALLOCATOR_SELF_TEST="OFF",
        CLEAR_ONLY_PASS_SELF_TEST="OFF",
        SHADING_PROTOTYPE_TILE_SELF_TEST="OFF",
        SHADING_PROTOTYPE_FORWARD_SELF_TEST="OFF",
        TEMPEST_PROFILE="baseline",
        PACKAGE_DEVICE_IPA="0",
    )
    matching = subprocess.run(
        ["/bin/bash", "-s", "--", "causal-b"],
        input=parser,
        text=True,
        cwd=REPO,
        env=matching_environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert matching.returncode == 0, matching.stderr

    conflicts = (
        ("DIAGNOSTICS", "OFF"),
        ("ACTIVE_FAULT_MODE", "post-submit-suboptimal"),
        ("CAUSAL_MODE", "causal-b"),
        ("BINK_SELF_TEST", "ON"),
        ("RESOURCE_ALLOCATOR_SELF_TEST", "ON"),
        ("CLEAR_ONLY_PASS_SELF_TEST", "ON"),
        ("SHADING_PROTOTYPE_TILE_SELF_TEST", "ON"),
        ("SHADING_PROTOTYPE_FORWARD_SELF_TEST", "ON"),
        ("TEMPEST_PROFILE", "metalfx-spatial"),
        ("PACKAGE_DEVICE_IPA", "1"),
    )
    for name, value in conflicts:
        environment = dict(base_environment)
        environment[name] = value
        rejected = subprocess.run(
            ["/bin/bash", "-s", "--", "causal-a"],
            input=parser,
            text=True,
            cwd=REPO,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert rejected.returncode == 2
        assert rejected.stderr.startswith(
            f"causal profile raw input mismatch: {name}="
        )


def test_bash32_local_profile_parser() -> None:
    source = LOCAL_VERIFY.read_text(encoding="utf-8")
    parser = source.split('\nSCRIPT_DIR="', 1)[0]
    if parser == source:
        raise AssertionError("local verifier parser boundary is missing")

    single = subprocess.run(
        ["/bin/bash", "-s", "--", "profiles", "on"],
        input=parser,
        text=True,
        cwd=REPO,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert single.returncode == 0, single.stderr

    causal = subprocess.run(
        ["/bin/bash", "-s", "--", "profiles", "causal-none", "causal-a", "causal-b"],
        input=parser,
        text=True,
        cwd=REPO,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert causal.returncode == 0, causal.stderr

    duplicate = subprocess.run(
        ["/bin/bash", "-s", "--", "profiles", "on", "on"],
        input=parser,
        text=True,
        cwd=REPO,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert duplicate.returncode == 2
    assert duplicate.stderr.strip() == "duplicate verification profile: on"


def main() -> None:
    test_classification()
    test_push_before_to_sha()
    test_aggregation()
    test_workflow_contract()
    test_cmake_presets_contract()
    test_causal_build_isolation_source_contract()
    test_causal_device_harness_source_contract()
    test_ui_automation_host_contract()
    test_bash32_candidate_arguments()
    test_bash32_causal_profile_tuple()
    test_bash32_local_profile_parser()
    print(
        "RendererIOS CI verification tests passed: "
        "11 groups, Bash 3.2 candidate/CI-causal/device-causal/local-profile smokes, "
        "7 workflow mutations, 12 extraction/profile mutations, "
        "19 CMake presets mutations, 14 causal source mutations, "
        "25 causal device harness mutations, "
        "17 UI selector mutations, 6 UI harness mutations, "
        "11 ABI8 export mutations"
    )


if __name__ == "__main__":
    main()
