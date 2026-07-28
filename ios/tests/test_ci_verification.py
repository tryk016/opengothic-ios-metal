#!/usr/bin/env python3
"""Contract and mutation tests for split RendererIOS CI routing."""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile


REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci_verification.py"
WORKFLOW = REPO / ".github" / "workflows" / "renderer-ios.yml"
CONTRACTS = REPO / "scripts" / "ci_contracts.command"
PROFILE = REPO / "scripts" / "ci_build_profile.command"
PRESETS = REPO / "CMakePresets.json"
GITIGNORE = REPO / ".gitignore"
LOCAL_VERIFY = REPO / "scripts" / "verify-local-build.command"


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
        "Verify pinned Tempest fork twice",
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
        ')" -eq 15',
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
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST": tile,
            "OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_FORWARD_SELF_TEST": forward,
        }
        if preset.get("cacheVariables") != expected_profile_cache:
            raise ValueError(f"{name} profile tuple drifted")
        if tile == "ON" and forward == "ON":
            raise ValueError("Tile and Forward may not be enabled together")

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
    validate_workflow(workflow)
    validate_extracted_oracles(contracts, profile)
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
    assert killed == 14


def test_bash32_candidate_arguments() -> None:
    profile = PROFILE.read_text(encoding="utf-8")
    candidate = exact_scope(
        profile,
        "# CI_PROFILE_CANDIDATE_BEGIN",
        "# CI_PROFILE_CANDIDATE_END",
        "profile candidate metallib",
    )
    exports = (
        "riosLandscapeVertex",
        "riosLandscapeFragment",
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
        flag not in metal_commands[0]
        for flag in ("-Wall", "-Wextra", "-Werror")
    )
    assert all(
        flag in metal_commands[-1]
        for flag in ("-Wall", "-Wextra", "-Werror")
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
    test_bash32_candidate_arguments()
    test_bash32_local_profile_parser()
    print(
        "RendererIOS CI verification tests passed: "
        "7 groups, Bash 3.2 candidate/profile-parser smoke, "
        "7 workflow mutations, 12 extraction/profile mutations, "
        "14 CMake presets mutations"
    )


if __name__ == "__main__":
    main()
