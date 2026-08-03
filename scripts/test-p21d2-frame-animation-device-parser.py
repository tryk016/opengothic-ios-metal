#!/usr/bin/env python3
"""Focused and mutation tests for the P2.1d2 device-log parser."""

from __future__ import annotations

import importlib.util
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
from types import ModuleType


ROOT = Path(__file__).resolve().parents[1]
PARSER = ROOT / "ios/device-test/validate-frame-animation-log.py"
RENDERER = ROOT / "game/graphics/rendererios.cpp"
MAIN = ROOT / "game/main.cpp"
MAINWINDOW = ROOT / "game/mainwindow.cpp"
GENERIC_SMOKE = ROOT / "ios/device-test/run-smoke-test.sh"
BUILD = "0123456789abcdef0123456789abcdef01234567"
D1_JSON = (
    '{"build":"3b22b0eb3772cde9e9d88cc28baeff43b5a7aedc",'
    '"frame-animated":38,"generation":3,"invalid-source":0,'
    '"kind-animated":1563,"kind-landscape":338,"kind-morph":1137,'
    '"kind-movable":8463,"kind-particle":0,"kind-static":22075,'
    '"kind-unknown":0,"kind-unsupported":0,"material-additive-light":183,'
    '"material-alpha-test":11001,"material-ghost":0,"material-missing":0,'
    '"material-multiply":0,"material-multiply2":1,"material-solid":21425,'
    '"material-transparent":962,"material-unknown":0,"material-water":4,'
    '"planned":29702,"sequence":1,"skipped-kind":2700,'
    '"skipped-material":1150,"skipped-texture-animation":24,'
    '"skipped-texture-frame-and-uv":2,"skipped-texture-frame-only":22,'
    '"skipped-texture-uv-only":0,"uv-animated":3,"version":2,'
    '"visited":33576}\n'
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def load_parser() -> ModuleType:
    spec = importlib.util.spec_from_file_location("p21d2_device_parser", PARSER)
    require(spec is not None and spec.loader is not None, "parser import failed")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def census_line(build: str = BUILD) -> str:
    return (
        "RendererIOS source census: v=2 "
        f"b={build} g=7 s=1 "
        "k=338,22075,8463,1563,0,1137,0,0 "
        "m=21425,11001,4,0,0,1,962,183,0,0 "
        "a=38,3 x=0,0,2 o=33576,29724,2700,1150,2,0"
    )


def native_block(generation: int, sequence: int) -> list[str]:
    return [
        "RendererIOS native scene identity: mode=production "
        f"generation={generation} sequence={sequence}",
        "RendererIOS native scene material-planned: mode=production "
        "total=29724 opaque=18723 alpha=11001",
        "RendererIOS native scene material-drawn: mode=production "
        "total=29724 opaque=18723 alpha=11001 textured=29724",
        "RendererIOS native scene kind-planned: mode=production "
        "total=29724 landscape=338 static=22075 movable=7311",
        "RendererIOS native scene kind-drawn: mode=production "
        "total=29724 landscape=338 static=22075 movable=7311",
        "RendererIOS native scene alpha: mode=production "
        "opaque-pso=18723 alpha-pso=11001 control-alpha-to-opaque=0 "
        "alpha-fallback=0",
        "RendererIOS native scene fail-contract: mode=production "
        "unknown-category=0 unknown-kind=0 invalid-cutoff=0 "
        "missing-alpha-texture=0",
        "RendererIOS native scene fail-selector: mode=production "
        "selector-mismatch=0 pso-unavailable=0",
        "RendererIOS native scene fail-execution: mode=production "
        "overflow=0 planned-drawn=0 native-encode=0",
    ]


def primary(phase: str, sequence: int) -> str:
    pair = "1111111111111111" if phase == "B" else "2222222222222222"
    nonzero = 10 if phase == "B" else 11
    return (
        "RendererIOS frame animation: v=1 "
        f"p={phase} b={BUILD} g=7 s={sequence} a=22 n={nonzero} "
        f"sd=0123456789abcdef pd={pair}"
    )


def detail(phase: str, sequence: int) -> str:
    if phase == "B":
        return (
            "RendererIOS frame animation detail: v=1 p=B g=7 s=1 d=22 "
            "dd=3333333333333333 c=0 f=0 t=0"
        )
    return (
        "RendererIOS frame animation detail: v=1 p=T g=7 s=2 d=22 "
        "dd=4444444444444444 c=9001 f=0 t=1"
    )


def valid_log() -> str:
    lines = [
        "ordinary output",
        "RendererIOS diagnostics: ON frames-in-flight=3 "
        "context=IOSMetalContext transport=Tempest",
        census_line(),
    ]
    lines.extend(native_block(7, 1))
    lines.extend((primary("B", 1), detail("B", 1), "intermediate output"))
    lines.extend(native_block(7, 2))
    lines.extend((primary("T", 2), detail("T", 2), "ordinary tail"))
    return "\n".join(lines) + "\n"


def replace_once(source: str, old: str, new: str) -> str:
    require(source.count(old) == 1, f"mutation anchor is not unique: {old!r}")
    return source.replace(old, new, 1)


def remove_line(source: str, line: str) -> str:
    return replace_once(source, line + "\n", "")


def mutate_line(source: str, line: str, old: str, new: str) -> str:
    return replace_once(source, line, replace_once(line, old, new))


def mutate_block(source: str, block: list[str], index: int, replacement: str) -> str:
    original = "\n".join(block)
    mutated = list(block)
    mutated[index] = replacement
    return replace_once(source, original, "\n".join(mutated))


def expect_invalid(module: ModuleType, log: str, d1_path: Path, name: str) -> None:
    try:
        module.validate(log, BUILD, d1_path)
    except module.ValidationError:
        return
    raise RuntimeError(f"log mutation survived: {name}")


def compiler() -> list[str]:
    configured = os.environ.get("CXX")
    if configured:
        return shlex.split(configured)
    if shutil.which("xcrun"):
        return ["xcrun", "clang++"]
    found = shutil.which("clang++")
    require(found is not None, "clang++ not found")
    return [found]


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"function signature is missing: {signature}")
    opening = source.find("{", start + len(signature))
    require(opening >= 0, f"function body is missing: {signature}")
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise RuntimeError(f"function body is unterminated: {signature}")


def ordered(body: str, anchors: tuple[str, ...], label: str) -> list[str]:
    errors: list[str] = []
    positions = [body.find(anchor) for anchor in anchors]
    if any(position < 0 for position in positions):
        errors.append(f"missing {label} step")
    elif positions != sorted(positions) or len(set(positions)) != len(positions):
        errors.append(f"{label} order differs")
    return errors


def lifecycle_source_errors(main: str, mainwindow: str, renderer: str) -> list[str]:
    errors: list[str] = []
    errors += ordered(
        main,
        ("Resources            resources{device};", "MainWindow           wx(device);"),
        "Resources/MainWindow lifetime",
    )
    bindings = (
        "Gothic::inst().onStartLoading       .bind(this,&MainWindow::onStartLoading);",
        "Gothic::inst().onBeforeWorldFinalize.bind(this,&MainWindow::onBeforeWorldFinalize);",
        "Gothic::inst().onWorldLoaded        .bind(this,&MainWindow::onWorldLoaded);",
        "Gothic::inst().onBeforeSessionExit  .bind(this,&MainWindow::onBeforeSessionExit);",
    )
    for binding in bindings:
        if mainwindow.count(binding) != 1:
            errors.append(f"lifecycle binding count differs: {binding}")

    destructor = function_body(mainwindow, "MainWindow::~MainWindow()")
    errors += ordered(
        destructor,
        ("renderer.shutdown();", "Gothic::inst().setGame(std::unique_ptr<GameSession>());"),
        "MainWindow shutdown/owner release",
    )
    for signature, owner_release in (
        ("void MainWindow::onStartLoading()", "detachWorldOwners();"),
        ("void MainWindow::onBeforeSessionExit()", "detachWorldOwners();"),
    ):
        errors += ordered(
            function_body(mainwindow, signature),
            ("renderer.prepareForOwnerRelease();", owner_release),
            signature,
        )
    before_finalize = function_body(
        mainwindow, "void MainWindow::onBeforeWorldFinalize()"
    )
    if before_finalize.count("renderer.prepareForOwnerRelease();") != 1:
        errors.append("onBeforeWorldFinalize owner-release barrier count differs")
    world_loaded = function_body(mainwindow, "void MainWindow::onWorldLoaded()")
    if world_loaded.count("renderer.onWorldChanged();") != 1:
        errors.append("onWorldLoaded world-change notification count differs")

    errors += ordered(
        function_body(renderer, "void RendererIOS::shutdown() noexcept"),
        (
            "impl->context.shutdown();",
            "impl->clearPreparedScene();",
            "impl->assets.clearAfterConfirmedIdle();",
            "impl->worldOwnersDetached = true;",
        ),
        "RendererIOS shutdown confirmed-idle clear",
    )
    errors += ordered(
        function_body(renderer, "void RendererIOS::prepareForOwnerRelease() noexcept"),
        (
            "impl->context.prepareForOwnerRelease();",
            "impl->clearPreparedScene();",
            "if(impl->worldOwnersDetached)",
            "impl->assets.clearAfterConfirmedIdle();",
            "impl->renderWorld.resetWorld();",
            "impl->resetFrameAnimationDiagnostics();",
            "impl->worldOwnersDetached = true;",
        ),
        "RendererIOS owner-release confirmed-idle reset",
    )
    errors += ordered(
        function_body(renderer, "void RendererIOS::onWorldChanged()"),
        (
            "impl->context.onWorldChanged();",
            "impl->clearPreparedScene();",
            "impl->assets.clearAfterConfirmedIdle();",
            "impl->renderWorld.resetWorld();",
            "impl->resetFrameAnimationDiagnostics();",
            "impl->assets.resetGeneration(impl->device,",
        ),
        "RendererIOS world-change confirmed-idle reset",
    )
    return errors


def mutate_function(source: str, signature: str, old: str, new: str) -> str:
    body = function_body(source, signature)
    require(body.count(old) == 1, f"function mutation anchor differs: {signature} {old}")
    return source.replace(body, body.replace(old, new, 1), 1)


def swap_unique(source: str, first: str, second: str) -> str:
    require(source.count(first) == 1 and source.count(second) == 1,
            "swap anchors are not unique")
    token = "__P21D2_SWAP_TOKEN__"
    require(token not in source, "swap token collides with source")
    return source.replace(first, token, 1).replace(second, first, 1).replace(token, second, 1)


def validate_lifecycle_source_oracle() -> None:
    main = MAIN.read_text()
    mainwindow = MAINWINDOW.read_text()
    renderer = RENDERER.read_text()
    require(not lifecycle_source_errors(main, mainwindow, renderer),
            "; ".join(lifecycle_source_errors(main, mainwindow, renderer)))
    mutations = {
        "window-before-resources": (
            swap_unique(
                main,
                "Resources            resources{device};",
                "MainWindow           wx(device);",
            ),
            mainwindow,
            renderer,
        ),
        "destructor-shutdown-after-release": (
            main,
            mutate_function(
                mainwindow,
                "MainWindow::~MainWindow()",
                "renderer.shutdown();",
                "/* renderer shutdown moved after owner release */",
            ),
            renderer,
        ),
        "start-loading-no-barrier": (
            main,
            mutate_function(mainwindow, "void MainWindow::onStartLoading()",
                            "renderer.prepareForOwnerRelease();", "/* missing barrier */"),
            renderer,
        ),
        "finalize-no-barrier": (
            main,
            mutate_function(mainwindow, "void MainWindow::onBeforeWorldFinalize()",
                            "renderer.prepareForOwnerRelease();", "/* missing barrier */"),
            renderer,
        ),
        "exit-no-barrier": (
            main,
            mutate_function(mainwindow, "void MainWindow::onBeforeSessionExit()",
                            "renderer.prepareForOwnerRelease();", "/* missing barrier */"),
            renderer,
        ),
        "world-loaded-no-notification": (
            main,
            mutate_function(mainwindow, "void MainWindow::onWorldLoaded()",
                            "renderer.onWorldChanged();", "/* missing world change */"),
            renderer,
        ),
        "owner-reset-before-idle-clear": (
            main,
            mainwindow,
            mutate_function(
                renderer,
                "void RendererIOS::prepareForOwnerRelease() noexcept",
                "impl->assets.clearAfterConfirmedIdle();\n  impl->renderWorld.resetWorld();",
                "impl->renderWorld.resetWorld();\n  impl->assets.clearAfterConfirmedIdle();",
            ),
        ),
        "world-reset-before-idle-clear": (
            main,
            mainwindow,
            mutate_function(
                renderer,
                "void RendererIOS::onWorldChanged()",
                "impl->assets.clearAfterConfirmedIdle();\n  impl->renderWorld.resetWorld();",
                "impl->renderWorld.resetWorld();\n  impl->assets.clearAfterConfirmedIdle();",
            ),
        ),
    }
    for name, (mutated_main, mutated_window, mutated_renderer) in mutations.items():
        require((mutated_main, mutated_window, mutated_renderer) !=
                (main, mainwindow, renderer), f"lifecycle mutation did not match: {name}")
        require(lifecycle_source_errors(mutated_main, mutated_window, mutated_renderer),
                f"lifecycle mutation survived: {name}")


def off_source_errors(renderer: str, generic_smoke: str) -> list[str]:
    errors: list[str] = []
    required = {
        "diagnostics-owned state": (
            "#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n"
            "  uint64_t preparedFrameAnimationSerial = 0;"
        ),
        "diagnostics-owned commit method": (
            "#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n"
            "  void acceptFrameAnimationGeneration"
        ),
        "OFF null evidence branch": (
            "#else\n"
            "  const IOSFrameAnimationEvidence* const frameAnimation = nullptr;\n"
            "  const bool forceNativeSceneMarkers = false;\n"
            "#endif"
        ),
        "accepted-submit commit guard": (
            "#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n"
            "    if(submitted && accepted) {"
        ),
    }
    for label, fragment in required.items():
        if fragment not in renderer:
            errors.append(f"missing {label}")
    if "validate-frame-animation-log.py" in generic_smoke:
        errors.append("generic smoke invokes the specialized parser")
    if "RendererIOS frame animation:" in generic_smoke:
        errors.append("generic smoke contains frame-animation scenario logic")
    return errors


def validate_off_source_oracle() -> None:
    renderer = RENDERER.read_text()
    generic = GENERIC_SMOKE.read_text()
    errors = off_source_errors(renderer, generic)
    require(not errors, "; ".join(errors))
    source_mutations = {
        "unguarded-state": renderer.replace(
            "#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n"
            "  uint64_t preparedFrameAnimationSerial = 0;",
            "  uint64_t preparedFrameAnimationSerial = 0;",
            1,
        ),
        "unguarded-method": renderer.replace(
            "#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n"
            "  void acceptFrameAnimationGeneration",
            "  void acceptFrameAnimationGeneration",
            1,
        ),
        "OFF-forces-evidence": renderer.replace(
            "  const IOSFrameAnimationEvidence* const frameAnimation = nullptr;",
            "  const IOSFrameAnimationEvidence* const frameAnimation = "
            "&impl->preparedFrameAnimation;",
            1,
        ),
        "unguarded-commit": renderer.replace(
            "#if defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)\n"
            "    if(submitted && accepted) {",
            "    if(submitted && accepted) {",
            1,
        ),
    }
    for name, mutated in source_mutations.items():
        require(mutated != renderer, f"source mutation did not match: {name}")
        require(off_source_errors(mutated, generic),
                f"OFF source mutation survived: {name}")
    generic_mutations = {
        "parser-hook": generic + "\nvalidate-frame-animation-log.py\n",
        "scenario-prefix": generic + "\nRendererIOS frame animation:\n",
    }
    for name, mutated in generic_mutations.items():
        require(off_source_errors(renderer, mutated),
                f"generic smoke mutation survived: {name}")


def preprocess_renderer(cxx: list[str], workspace: Path, diagnostics: bool) -> str:
    output = workspace / ("renderer-on.ii" if diagnostics else "renderer-off.ii")
    command = [
        *cxx,
        "-std=c++20",
        "-E",
        "-P",
        "-Igame",
        "-Igame/graphics",
        "-isystem",
        "lib/Tempest/Engine/include",
        "-isystem",
        "lib/ZenKit/include",
    ]
    if diagnostics:
        command.extend([
            "-DOPENGOTHIC_RENDERER_IOS_DIAGNOSTICS=1",
            '-DOPENGOTHIC_RENDERER_IOS_BUILD_SHA="0123456789abcdef0123456789abcdef01234567"',
        ])
    command.extend([str(RENDERER), "-o", str(output)])
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    require(result.returncode == 0,
            f"renderer {'ON' if diagnostics else 'OFF'} preprocessing failed: "
            f"{result.stdout}{result.stderr}")
    return output.read_text()


def validate_preprocessed_off_on(cxx: list[str], workspace: Path) -> None:
    off = preprocess_renderer(cxx, workspace, False)
    on = preprocess_renderer(cxx, workspace, True)
    diagnostic_tokens = (
        "RendererIOS frame animation:",
        "commitFrameAnimationDiagnostics",
        "preparedFrameAnimation",
        "frameAnimationDiagnostics",
    )
    for token in diagnostic_tokens:
        require(token not in off, f"OFF preprocessed renderer retains {token}")
        require(token in on, f"ON preprocessed renderer omits {token}")


def run_cli(arguments: list[str], expected_success: bool, name: str) -> None:
    result = subprocess.run(
        [sys.executable, str(PARSER), *arguments],
        cwd=ROOT,
        capture_output=True,
        text=True,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    require((result.returncode == 0) == expected_success,
            f"CLI {name} returned {result.returncode}: {result.stdout}{result.stderr}")


def main() -> int:
    module = load_parser()
    cxx = compiler()
    require(len(primary("B", 1).encode("ascii")) <= 254,
            "primary fixture exceeds marker budget")
    require(len(detail("T", 2).encode("ascii")) <= 254,
            "detail fixture exceeds marker budget")
    with tempfile.TemporaryDirectory(prefix="p21d2-device-parser-") as temporary:
        workspace = Path(temporary)
        d1 = workspace / "d1.json"
        d1.write_text(D1_JSON)
        good = valid_log()
        result = module.validate(good, BUILD, d1)
        require(result["result"] == "PASS", "valid fixture did not pass")
        require(result["planned"] == 29724, "D1+22 total differs")

        b_primary = primary("B", 1)
        b_detail = detail("B", 1)
        t_primary = primary("T", 2)
        t_detail = detail("T", 2)
        first_native = native_block(7, 1)
        second_native = native_block(7, 2)
        primary_before_native_counts = remove_line(good, b_primary)
        primary_before_native_counts = replace_once(
            primary_before_native_counts,
            first_native[0] + "\n",
            first_native[0] + "\n" + b_primary + "\n",
        )
        b_detail_after_transition = remove_line(good, b_detail)
        b_detail_after_transition = replace_once(
            b_detail_after_transition,
            t_detail + "\n",
            t_detail + "\n" + b_detail + "\n",
        )
        mutations = {
            "missing-primary": remove_line(good, b_primary),
            "duplicate-primary": replace_once(good, b_primary, b_primary + "\n" + b_primary),
            "missing-detail": remove_line(good, t_detail),
            "duplicate-detail": replace_once(good, t_detail, t_detail + "\n" + t_detail),
            "foreign-sha": mutate_line(good, b_primary, f"b={BUILD}", "b=" + "f" * 40),
            "primary-version": mutate_line(good, b_primary, "animation: v=1", "animation: v=2"),
            "primary-over-254": replace_once(good, b_primary, b_primary + " " + "x" * 180),
            "pair-phase": replace_once(good, "detail: v=1 p=T", "detail: v=1 p=B"),
            "pair-generation": mutate_line(good, t_detail, "g=7", "g=8"),
            "pair-sequence": mutate_line(good, t_detail, "s=2", "s=3"),
            "generation-change": mutate_line(good, t_primary, "g=7", "g=8"),
            "transition-not-later": mutate_line(good, t_primary, "s=2", "s=1"),
            "cohort-change": mutate_line(good, t_primary, "sd=0123456789abcdef", "sd=fedcba9876543210"),
            "pair-digest-static": mutate_line(good, t_primary, "pd=2222222222222222", "pd=1111111111111111"),
            "drawn-digest-static": mutate_line(good, t_detail, "dd=4444444444444444", "dd=3333333333333333"),
            "admitted": mutate_line(good, b_primary, "a=22", "a=21"),
            "nonzero-bound": mutate_line(good, b_primary, "n=10", "n=23"),
            "all-ordinals-zero": mutate_line(
                mutate_line(good, b_primary, "n=10", "n=0"),
                t_primary,
                "n=11",
                "n=0",
            ),
            "drawn": mutate_line(good, t_detail, "d=22", "d=21"),
            "baseline-change": mutate_line(good, b_detail, "c=0 f=0 t=0", "c=9 f=0 t=1"),
            "changed-source-zero": mutate_line(good, t_detail, "c=9001", "c=0"),
            "ordinal-unchanged": mutate_line(good, t_detail, "f=0 t=1", "f=1 t=1"),
            "missing-identity": remove_line(good, first_native[0]),
            "duplicate-identity": replace_once(good, first_native[0], first_native[0] + "\n" + first_native[0]),
            "wrong-native-generation": replace_once(good, first_native[0], first_native[0].replace("generation=7", "generation=8")),
            "primary-before-native-counts": primary_before_native_counts,
            "baseline-detail-after-transition-block": b_detail_after_transition,
            "missing-native-planned": mutate_block(good, first_native, 1, "ordinary missing planned"),
            "duplicate-native-drawn": mutate_block(
                good, first_native, 2, first_native[2] + "\n" + first_native[2]
            ),
            "planned-not-d1-plus-22": mutate_block(
                good,
                first_native,
                1,
                first_native[1].replace("total=29724 opaque=18723", "total=29723 opaque=18722"),
            ),
            "material-conservation": mutate_block(
                good,
                first_native,
                1,
                first_native[1].replace("opaque=18723 alpha=11001", "opaque=18722 alpha=11001"),
            ),
            "planned-drawn-material": mutate_block(
                good,
                first_native,
                2,
                first_native[2].replace("textured=29724", "textured=29723"),
            ),
            "planned-drawn-kind": mutate_block(
                good,
                second_native,
                4,
                second_native[4].replace("movable=7311", "movable=7310"),
            ),
            "alpha-count": mutate_block(
                good,
                first_native,
                5,
                first_native[5].replace("opaque-pso=18723", "opaque-pso=18722"),
            ),
            "contract-failure": mutate_block(
                good,
                first_native,
                6,
                first_native[6].replace("unknown-category=0", "unknown-category=1"),
            ),
            "selector-failure": mutate_block(
                good,
                first_native,
                7,
                first_native[7].replace("selector-mismatch=0", "selector-mismatch=1"),
            ),
            "execution-failure": mutate_block(
                good,
                first_native,
                8,
                first_native[8].replace("native-encode=0", "native-encode=1"),
            ),
            "missing-census": remove_line(good, census_line()),
            "duplicate-census": replace_once(good, census_line(), census_line() + "\n" + census_line()),
            "census-build": replace_once(good, census_line(), census_line("f" * 40)),
            "raw-animation": replace_once(good, "a=38,3 x=0,0,2", "a=37,3 x=0,0,2"),
            "mode-skips": replace_once(good, "x=0,0,2", "x=1,0,1"),
            "skip-total": replace_once(good, "1150,2,0", "1150,3,0"),
            "census-planned": replace_once(good, "33576,29724", "33576,29723"),
            "fatal": good + "RendererIOS fatal fixture\n",
            "sigabrt": good + "libc++abi: terminating after SIGABRT\n",
            "plain-fatal": good + "fatal: uncaught exception\n",
            "exc-crash": good + "Exception Type: EXC_CRASH (SIGABRT)\n",
            "terminated-signal": good + "Terminated due to signal 9\n",
            "sigsegv": good + "process received SIGSEGV\n",
            "sigkill": good + "process received SIGKILL\n",
            "segmentation-fault": good + "Segmentation fault: 11\n",
            "abort-trap": good + "Abort trap: 6\n",
            "killed": good + "Killed: 9\n",
            "exc-resource": good + "Exception Type: EXC_RESOURCE (RESOURCE_TYPE_MEMORY)\n",
            "diagnostics-short": replace_once(
                good,
                "RendererIOS diagnostics: ON frames-in-flight=3 "
                "context=IOSMetalContext transport=Tempest",
                "RendererIOS diagnostics: ON",
            ),
            "diagnostics-off": replace_once(
                good,
                "RendererIOS diagnostics: ON frames-in-flight=3 "
                "context=IOSMetalContext transport=Tempest",
                "RendererIOS diagnostics: OFF",
            ),
            "diagnostics-duplicate": replace_once(
                good,
                "RendererIOS diagnostics: ON frames-in-flight=3 "
                "context=IOSMetalContext transport=Tempest",
                "RendererIOS diagnostics: ON frames-in-flight=3 "
                "context=IOSMetalContext transport=Tempest\n"
                "RendererIOS diagnostics: ON frames-in-flight=3 "
                "context=IOSMetalContext transport=Tempest",
            ),
        }
        for name, mutated in mutations.items():
            expect_invalid(module, mutated, d1, name)

        benign_killed_lines = {
            "gameplay prose": "creature killed by player",
            "counter field": "RendererIOS encounter census: killed=0",
        }
        for name, line in benign_killed_lines.items():
            benign_result = module.validate(good + line + "\n", BUILD, d1)
            require(benign_result["result"] == "PASS",
                    f"benign killed text was rejected: {name}")

        wrong_d1 = workspace / "wrong-d1.json"
        wrong_d1.write_text(D1_JSON.replace('"planned":29702', '"planned":29701'))
        expect_invalid(module, good, wrong_d1, "D1 SHA/full breakdown")
        original_d1_hash = module.EXPECTED_D1_SHA256
        semantic_d1_mutations = {
            "D1 build provenance": D1_JSON.replace(
                "3b22b0eb3772cde9e9d88cc28baeff43b5a7aedc",
                "f" * 40,
            ),
            "D1 version provenance": D1_JSON.replace('"version":2', '"version":1'),
            "D1 full breakdown": D1_JSON.replace('"planned":29702', '"planned":29701'),
        }
        for name, content in semantic_d1_mutations.items():
            candidate = workspace / (name.replace(" ", "-") + ".json")
            candidate.write_text(content)
            module.EXPECTED_D1_SHA256 = hashlib.sha256(
                candidate.read_bytes()
            ).hexdigest()
            try:
                expect_invalid(module, good, candidate, name)
            finally:
                module.EXPECTED_D1_SHA256 = original_d1_hash
        try:
            module.validate(good, BUILD.upper(), d1)
        except module.ValidationError:
            pass
        else:
            raise RuntimeError("uppercase expected SHA survived")

        off_log = workspace / "off.log"
        off_log.write_text("ordinary OFF output\nRendererIOS diagnostics: OFF\n")
        require(module.validate_absent(off_log.read_text())["result"] == "PASS",
                "OFF absence fixture failed")
        for name, marker in (("primary", b_primary), ("detail", b_detail)):
            try:
                module.validate_absent(off_log.read_text() + marker + "\n")
            except module.ValidationError:
                pass
            else:
                raise RuntimeError(f"OFF {name} marker survived")

        good_path = workspace / "good.log"
        good_path.write_text(good)
        run_cli(
            ["--log", str(good_path), "--expected-sha", BUILD,
             "--d1-census-json", str(d1)],
            True,
            "ON valid",
        )
        run_cli(["--log", str(off_log), "--expect-absent"], True, "OFF valid")
        run_cli(["--log", str(good_path), "--expect-absent"], False, "OFF rejects ON")
        validate_preprocessed_off_on(cxx, workspace)

    validate_off_source_oracle()
    validate_lifecycle_source_oracle()
    print(
        "P2.1d2 frame-animation device parser: PASS "
        f"({len(mutations)} log mutations, {len(benign_killed_lines)} "
        "benign crash negatives, plus D1/CLI/OFF source oracles)"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"P2.1d2 frame-animation device parser: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
