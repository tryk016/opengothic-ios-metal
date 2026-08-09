#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SMOKE_PATH = ROOT / "ios/device-test/run-smoke-test.sh"
ADAPTER_PATH = ROOT / "ios/device-test/run-linear-hdr-proof-test.sh"
A_ARGUMENT = "-renderer-ios-additive-causal-mode=additive-a-hdr"
B_ARGUMENT = "-renderer-ios-additive-causal-mode=additive-b-hdr"
LIVE_PID_LEAF = "/tmp/p21e1b-live-pid.json"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def ordered(text: str, tokens: tuple[str, ...]) -> bool:
    cursor = 0
    for token in tokens:
        position = text.find(token, cursor)
        if position < 0:
            return False
        cursor = position + len(token)
    return True


def validate_sources(candidate: dict[str, str]) -> None:
    smoke = candidate["smoke"]
    adapter = candidate["adapter"]
    parser = """--app-argument)
      (($# >= 2)) && [[ -n \"$2\" && \"$(printf '%s' \"$2\" | LC_ALL=C tr -d '[:cntrl:]')\" == \"$2\" ]] ||
        fail \"--app-argument requires one non-empty control-free literal\"
      APP_ARGUMENTS+=(\"$2\"); shift 2 ;;"""
    required_once = {
        "smoke": (
            "APP_ARGUMENTS=()",
            parser,
            'if ((${#APP_ARGUMENTS[@]})); then',
            'LAUNCH_ARGS+=("${APP_ARGUMENTS[@]}")',
            'if ! xcrun devicectl device process launch --device "$DEVICE"',
            '--terminate-existing -- "$BUNDLE_ID" "${LAUNCH_ARGS[@]}"',
            'LIVE_PID_FILE=""; LIVE_PID_FILE_SEEN=0',
            '--live-pid-file) ((LIVE_PID_FILE_SEEN == 0 && $# >= 2))',
            '"$(printf \'%s\' "$LIVE_PID_FILE" | LC_ALL=C tr -d \'[:cntrl:]\')" == "$LIVE_PID_FILE"',
            '[[ ! -e "$LIVE_PID_FILE" && ! -L "$LIVE_PID_FILE" ]]',
            '[[ -d "$(dirname "$LIVE_PID_FILE")" && ! -L "$(dirname "$LIVE_PID_FILE")" ]]',
            'LIVE_PID_VALUE="$(list_game_pids "$WORK/processes-live-pid.json")"',
            '[[ "$LIVE_PID_VALUE" =~ ^[1-9][0-9]*$ ]]',
            '"schemaVersion":1,"deviceUdid":sys.argv[2],"bundleId":sys.argv[3],"executable":sys.argv[4],"processId":int(sys.argv[5])',
            "os.link(temporary,path.name,src_dir_fd=parent,dst_dir_fd=parent,follow_symlinks=False)",
        ),
        "adapter": (
            "APP_ARGUMENTS=()",
            parser,
            '"$(printf \'%s\' "$LIVE_PID_FILE" | LC_ALL=C tr -d \'[:cntrl:]\')" == "$LIVE_PID_FILE"',
            'if ((${#APP_ARGUMENTS[@]})); then',
            'for app_argument in "${APP_ARGUMENTS[@]}"; do',
            'SMOKE_ARGS+=(--app-argument "$app_argument")',
            '[[ -z "$LIVE_PID_FILE" ]] || SMOKE_ARGS+=(--live-pid-file "$LIVE_PID_FILE")',
            '"$SMOKE" "${SMOKE_ARGS[@]}" "$APP"',
        ),
    }
    for name, snippets in required_once.items():
        for snippet in snippets:
            if candidate[name].count(snippet) != 1:
                raise ValueError(f"{name} required-once drift: {snippet}")
    if not ordered(
        smoke,
        (
            parser,
            'if ((${#APP_ARGUMENTS[@]})); then',
            'LAUNCH_ARGS+=("${APP_ARGUMENTS[@]}")',
            '--terminate-existing -- "$BUNDLE_ID" "${LAUNCH_ARGS[@]}"',
        ),
    ):
        raise ValueError("smoke literal array transport order drifted")
    if not ordered(
        smoke,
        (
            'if ! xcrun devicectl device process launch --device "$DEVICE"',
            'LIVE_PID_VALUE="$(list_game_pids "$WORK/processes-live-pid.json")"',
            '[[ "$LIVE_PID_VALUE" =~ ^[1-9][0-9]*$ ]]',
            "os.link(temporary,path.name,src_dir_fd=parent,dst_dir_fd=parent,follow_symlinks=False)",
            'sleep "$DURATION"',
        ),
    ):
        raise ValueError("live PID publication order drifted")
    if not ordered(
        adapter,
        (
            parser,
            'if ((${#APP_ARGUMENTS[@]})); then',
            'SMOKE_ARGS+=(--app-argument "$app_argument")',
            '"$SMOKE" "${SMOKE_ARGS[@]}" "$APP"',
        ),
    ):
        raise ValueError("linear-HDR adapter literal transport order drifted")
    for forbidden in (
        "additive-a-hdr",
        "additive-b-hdr",
        "renderer-ios-additive-causal-mode",
    ):
        if forbidden in smoke or forbidden in adapter:
            raise ValueError("scenario-specific Additive branch leaked: " + forbidden)
    for unsafe in (
        "eval ",
        "APP_ARGUMENTS[*]",
        "SMOKE_ARGS[*]",
        "LAUNCH_ARGS[*]",
        "APP_ARGUMENTS+=($2)",
        "SMOKE_ARGS+=(--app-argument $app_argument)",
    ):
        if unsafe in smoke or unsafe in adapter:
            raise ValueError("unsafe launch argument expansion: " + unsafe)
    if len(smoke.splitlines()) > 5978:
        raise ValueError("frozen run-smoke line ceiling exceeded")


def replace_once(text: str, old: str, new: str) -> str:
    require(text.count(old) == 1, "mutation anchor drift: " + old)
    return text.replace(old, new, 1)


def test_mutations(sources: dict[str, str]) -> int:
    parser = """--app-argument)
      (($# >= 2)) && [[ -n \"$2\" && \"$(printf '%s' \"$2\" | LC_ALL=C tr -d '[:cntrl:]')\" == \"$2\" ]] ||
        fail \"--app-argument requires one non-empty control-free literal\"
      APP_ARGUMENTS+=(\"$2\"); shift 2 ;;"""
    mutations: list[dict[str, str]] = []
    anchors = {
        "smoke": (
            parser,
            'if ((${#APP_ARGUMENTS[@]})); then',
            'LAUNCH_ARGS+=("${APP_ARGUMENTS[@]}")',
            '--terminate-existing -- "$BUNDLE_ID" "${LAUNCH_ARGS[@]}"',
        ),
        "adapter": (
            parser,
            'if ((${#APP_ARGUMENTS[@]})); then',
            'SMOKE_ARGS+=(--app-argument "$app_argument")',
            '[[ -z "$LIVE_PID_FILE" ]] || SMOKE_ARGS+=(--live-pid-file "$LIVE_PID_FILE")',
            '"$SMOKE" "${SMOKE_ARGS[@]}" "$APP"',
        ),
    }
    for name, snippets in anchors.items():
        for snippet in snippets:
            mutant = dict(sources)
            mutant[name] = replace_once(mutant[name], snippet, "")
            mutations.append(mutant)
    for name, old, new in (
        ("smoke", 'APP_ARGUMENTS+=("$2")', "APP_ARGUMENTS+=($2)"),
        (
            "smoke",
            'LAUNCH_ARGS+=("${APP_ARGUMENTS[@]}")',
            'LAUNCH_ARGS+=("${APP_ARGUMENTS[*]}")',
        ),
        (
            "adapter",
            'SMOKE_ARGS+=(--app-argument "$app_argument")',
            "SMOKE_ARGS+=(--app-argument $app_argument)",
        ),
        (
            "adapter",
            '"$SMOKE" "${SMOKE_ARGS[@]}" "$APP"',
            '"$SMOKE" "${SMOKE_ARGS[*]}" "$APP"',
        ),
        (
            "smoke",
            'LAUNCH_ARGS+=("${APP_ARGUMENTS[@]}")',
            'eval "LAUNCH_ARGS+=(${APP_ARGUMENTS[*]})"',
        ),
        (
            "adapter",
            "APP_ARGUMENTS=()",
            'APP_ARGUMENTS=()\ncase "$app_argument" in *additive-a-hdr*) : ;; esac',
        ),
        (
            "smoke",
            '[[ ! -e "$LIVE_PID_FILE" && ! -L "$LIVE_PID_FILE" ]]',
            ': # stale/collision check removed',
        ),
        (
            "smoke",
            '[[ -d "$(dirname "$LIVE_PID_FILE")" && ! -L "$(dirname "$LIVE_PID_FILE")" ]]',
            '[[ -d "$(dirname "$LIVE_PID_FILE")" ]] # symlink accepted',
        ),
        (
            "smoke",
            'os.link(temporary,path.name,src_dir_fd=parent,dst_dir_fd=parent,follow_symlinks=False)',
            'os.replace(path.parent/temporary,path)',
        ),
        (
            "smoke",
            '[[ "$LIVE_PID_VALUE" =~ ^[1-9][0-9]*$ ]]',
            '[[ "$LIVE_PID_VALUE" =~ ^[0-9[:space:]]+$ ]] # zero/two accepted',
        ),
        (
            "smoke",
            '"$(printf \'%s\' "$LIVE_PID_FILE" | LC_ALL=C tr -d \'[:cntrl:]\')" == "$LIVE_PID_FILE"',
            '"$LIVE_PID_FILE" != *[$\'\\177\']* # controls accepted',
        ),
        (
            "adapter",
            '"$(printf \'%s\' "$LIVE_PID_FILE" | LC_ALL=C tr -d \'[:cntrl:]\')" == "$LIVE_PID_FILE"',
            '[[ -n "$LIVE_PID_FILE" ]] # controls accepted',
        ),
        (
            "adapter",
            '[[ -z "$LIVE_PID_FILE" ]] || SMOKE_ARGS+=(--live-pid-file "$LIVE_PID_FILE")',
            ': # live PID pass-through removed',
        ),
    ):
        mutant = dict(sources)
        mutant[name] = replace_once(mutant[name], old, new)
        mutations.append(mutant)
    launch = 'if ! xcrun devicectl device process launch --device "$DEVICE"'
    publish = 'os.link(temporary,path.name,src_dir_fd=parent,dst_dir_fd=parent,follow_symlinks=False)'
    reordered = dict(sources)
    reordered["smoke"] = replace_once(reordered["smoke"], launch, "__LAUNCH__")
    reordered["smoke"] = replace_once(reordered["smoke"], publish, launch)
    reordered["smoke"] = reordered["smoke"].replace("__LAUNCH__", publish, 1)
    mutations.append(reordered)
    killed = 0
    for index, mutant in enumerate(mutations):
        try:
            validate_sources(mutant)
        except ValueError:
            killed += 1
        else:
            raise RuntimeError(f"launch adapter source mutation survived index={index}")
    require(killed == len(mutations), "launch adapter mutation count drifted")
    return killed


def run_parser_contract(script: Path, sentinel: Path) -> None:
    injection = f"$(/usr/bin/touch {sentinel}); two words; --flag=value"
    command = [
        str(script),
        "--self-test",
        "--app-argument",
        A_ARGUMENT,
        "--app-argument",
        injection,
        "--app-argument",
        B_ARGUMENT,
        "--live-pid-file",
        LIVE_PID_LEAF,
    ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    require(result.returncode == 0, f"{script.name} valid literal parser failed")
    require(not sentinel.exists(), f"{script.name} evaluated an injection payload")
    for invalid in ("", "line\nbreak", "control\x01byte", "delete\x7fbyte"):
        result = subprocess.run(
            [str(script), "--self-test", "--app-argument", invalid],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        require(result.returncode != 0, f"{script.name} accepted unsafe literal")
    for invalid_path in ("", "relative.json", "/tmp/line\nbreak.json",
                         "/tmp/control\x01.json", "/tmp/delete\x7f.json"):
        result = subprocess.run(
            [str(script), "--self-test", "--live-pid-file", invalid_path],
            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False,
        )
        require(result.returncode != 0,
                f"{script.name} accepted unsafe live PID path")
    try:
        subprocess.run(
            [str(script), "--self-test", "--app-argument", "nul\x00byte"],
            cwd=ROOT,
            check=False,
        )
    except ValueError:
        pass
    else:
        raise RuntimeError(f"{script.name} OS argv unexpectedly accepted NUL")


def main() -> int:
    sources = {
        "smoke": SMOKE_PATH.read_text(),
        "adapter": ADAPTER_PATH.read_text(),
    }
    validate_sources(sources)
    killed = test_mutations(sources)
    with tempfile.TemporaryDirectory(prefix="p21e1b-launch-adapter-") as temp:
        sentinel = Path(temp) / "injection-executed"
        run_parser_contract(SMOKE_PATH, sentinel)
        run_parser_contract(ADAPTER_PATH, sentinel)
    print(
        "P2.1e1b additive launch adapter: PASS "
        f"mutations-killed={killed} exact-a-b=1 injection-safe=1"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
