#!/usr/bin/env python3
"""Validate one RendererIOS D-041 physical-device phase log.

The validator intentionally uses counters and strict archive-hit evidence, not
elapsed time.  It is host-neutral; --self-test exercises all four phase
contracts for both scenarios and proves that selected corruptions fail.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


STATE_PREFIX = "RendererIOS pipeline archive snapshot-state: "
RENDER_PREFIX = "RendererIOS pipeline archive snapshot-render: "
COMPUTE_PREFIX = "RendererIOS pipeline archive snapshot-compute: "
FLUSH_PREFIX = "RendererIOS pipeline archive snapshot-flush: "
PROVENANCE_PREFIX = "RendererIOS pipeline archive provenance-policy: "
TEST_MODE_PREFIX = "RendererIOS pipeline archive test-mode: "

STATE_KEYS = {
    "point",
    "presents",
    "abi",
    "size",
    "flags",
    "schema",
    "key",
    "metallib",
    "cfg",
    "available",
    "loaded",
    "empty",
    "dirty",
    "disabled",
    "load-fail",
    "rebuild",
}

RENDER_KEYS = {
    "point",
    "presents",
    "hit",
    "miss",
    "add",
    "fallback",
}

COMPUTE_KEYS = {
    "point",
    "presents",
    "hit",
    "miss",
    "add",
    "fallback",
}

FLUSH_KEYS = {
    "point",
    "presents",
    "attempt",
    "success",
    "fail",
    "invoked",
    "result",
    "bounded",
    "settled",
}

PROVENANCE_KEYS = {
    "configured",
    "schema",
    "key",
    "metallib",
    "digest",
    "stale-reset",
}

TEST_MODE_KEYS = {
    "mode",
    "abi",
    "applied",
    "bytes",
    "sha256",
    "removed-verified",
    "write-verified",
}

CORRUPT_PAYLOAD_SHA256 = (
    "8386a739719ee835402af74a36bef9667a5e7ad2f630b8f3d5b1a4cd2c1e54fa"
)

BRIDGE_RE = re.compile(
    r"RendererIOS runtime compilation: point=legacy-bridge available=(\d+) "
    r"source-before=(\d+) source-after=(\d+) source-delta=(\d+) "
    r"compute-before=(\d+) compute-after=(\d+) compute-delta=(\d+) "
    r"render-before=(\d+) render-after=(\d+) render-delta=(\d+)"
)

FRAME_RE = re.compile(
    r"RendererIOS runtime compilation: point=frame presents=(\d+) "
    r"available=(\d+) source=(\d+) compute=(\d+) render=(\d+)"
)

BUILTIN_FRAME_RE = re.compile(
    r"RendererIOS builtin runtime attribution: point=frame presents=(\d+) "
    r"role-abi=(\d+) available=(\d+) "
    r"source=([0-9]+(?:,[0-9]+){3}) "
    r"render=([0-9]+(?:,[0-9]+){11})"
)

SAVE_BUILTIN_RENDER = (0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0)
NEW_GAME_BUILTIN_RENDER = (0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0)
EXPECTED_BUILTIN_SOURCE = (0, 0, 0, 0)
FIRST_FLUSH_PRESENT = 300

FATAL_RE = re.compile(
    r"RendererIOS (?:fatal|GPU shutdown failed|native Landscape encode failed|"
    r"IOSGPUScene metallib loading failed)|libc\+\+abi: terminating|SIGABRT",
    re.IGNORECASE,
)

SHELL_BUILD_RE = re.compile(
    r"^RendererIOS shell: [^\r\n]* build=([^\s]+) gpu=",
    re.MULTILINE,
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def parse_key_values(line: str, prefix: str, expected: set[str]) -> dict[str, str]:
    position = line.find(prefix)
    require(position >= 0, f"marker prefix is missing: {prefix.strip()}")
    payload = line[position + len(prefix) :].strip()
    values: dict[str, str] = {}
    for token in payload.split():
        require("=" in token, f"non key=value token in marker: {token!r}")
        key, value = token.split("=", 1)
        require(key not in values, f"duplicate marker field: {key}")
        values[key] = value
    missing = expected - values.keys()
    extra = values.keys() - expected
    require(not missing, f"marker fields missing: {sorted(missing)}")
    require(not extra, f"unexpected marker fields: {sorted(extra)}")
    return values


def marker_group(
    log: str, prefix: str, keys: set[str]
) -> list[dict[str, str]]:
    return [
        parse_key_values(line, prefix, keys)
        for line in log.splitlines()
        if prefix in line
    ]


def snapshot_lines(log: str) -> list[dict[str, int | str]]:
    states = marker_group(log, STATE_PREFIX, STATE_KEYS)
    renders = marker_group(log, RENDER_PREFIX, RENDER_KEYS)
    computes = marker_group(log, COMPUTE_PREFIX, COMPUTE_KEYS)
    flushes = marker_group(log, FLUSH_PREFIX, FLUSH_KEYS)
    require(
        len(states) == 2,
        f"expected two snapshot-state markers, found {len(states)}",
    )
    require(
        len(renders) == 2,
        f"expected two snapshot-render markers, found {len(renders)}",
    )
    require(
        len(computes) == 2,
        f"expected two snapshot-compute markers, found {len(computes)}",
    )
    require(
        len(flushes) == 2,
        f"expected two snapshot-flush markers, found {len(flushes)}",
    )

    parsed: list[dict[str, int | str]] = []
    for index in range(2):
        groups = (
            states[index],
            renders[index],
            computes[index],
            flushes[index],
        )
        point = groups[0]["point"]
        presents = groups[0]["presents"]
        require(
            all(group["point"] == point for group in groups),
            "split snapshot point fields disagree",
        )
        require(
            all(group["presents"] == presents for group in groups),
            "split snapshot presents fields disagree",
        )
        item: dict[str, int | str] = {"point": point}
        for group_index, group in enumerate(groups):
            for key, value in group.items():
                if key == "point":
                    continue
                if key == "presents" and key in item:
                    continue
                normalized_key = key
                if group_index == 1 and key not in ("point", "presents"):
                    normalized_key = f"render-{key}"
                elif group_index == 2 and key not in ("point", "presents"):
                    normalized_key = f"compute-{key}"
                elif group_index == 3 and key not in ("point", "presents"):
                    normalized_key = f"flush-{key}"
                require(
                    normalized_key not in item,
                    f"duplicate split snapshot field: {normalized_key}",
                )
                try:
                    item[normalized_key] = int(value, 10)
                except ValueError as error:
                    raise ValidationError(
                        f"snapshot field {normalized_key} is not a decimal integer"
                    ) from error
        parsed.append(item)
    return parsed


def expected_snapshot(
    phase: str, scenario: str, point: str
) -> dict[str, int | str]:
    cold_like = phase in ("cold", "corrupt")
    corrupt = phase == "corrupt"
    pre = point == "pre"
    render_count = 2 if scenario == "save" else 3

    values: dict[str, int | str] = {
        "point": point,
        "presents": FIRST_FLUSH_PRESENT,
        "abi": 1,
        "size": 120,
        "flags": 27 if cold_like and pre else 11 if cold_like else 7,
        "schema": 1,
        "key": 1,
        "metallib": 4,
        "cfg": 1,
        "available": 1,
        "loaded": 0 if cold_like else 1,
        "empty": 1 if cold_like else 0,
        "dirty": 1 if cold_like and pre else 0,
        "disabled": 0,
        "load-fail": 1 if corrupt else 0,
        "rebuild": 1 if corrupt else 0,
        "render-hit": 0 if cold_like else render_count,
        "render-miss": render_count if cold_like else 0,
        "render-add": render_count if cold_like else 0,
        "render-fallback": 0,
        "compute-hit": 0,
        "compute-miss": 0,
        "compute-add": 0,
        "compute-fallback": 0,
        "flush-attempt": 1 if cold_like and not pre else 0,
        "flush-success": 1 if cold_like and not pre else 0,
        "flush-fail": 0,
        "flush-invoked": 1 if cold_like and not pre else 0,
        "flush-result": 1 if cold_like and not pre else 0,
        "flush-bounded": 1 if cold_like and not pre else 0,
        "flush-settled": 0 if pre else 1,
    }
    return values


def validate_snapshot_contract(log: str, phase: str, scenario: str) -> None:
    snapshots = snapshot_lines(log)
    require(
        len(snapshots) == 2,
        f"expected exactly PRE and POST archive snapshots, found {len(snapshots)}",
    )
    require(
        [entry["point"] for entry in snapshots] == ["pre", "post"],
        "archive snapshots must be ordered PRE then POST",
    )
    for actual in snapshots:
        point = str(actual["point"])
        expected = expected_snapshot(phase, scenario, point)
        for key, expected_value in expected.items():
            require(
                actual[key] == expected_value,
                f"{phase} {point} field {key}: "
                f"expected {expected_value}, found {actual[key]}",
            )

        flags = int(actual["flags"])
        flag_fields = (
            ("cfg", 1),
            ("available", 2),
            ("loaded", 4),
            ("empty", 8),
            ("dirty", 16),
            ("disabled", 32),
        )
        for field, bit in flag_fields:
            require(
                int(actual[field]) == (1 if flags & bit else 0),
                f"snapshot flag {field} is inconsistent with flags={flags}",
            )


def validate_provenance(log: str, metallib_sha256: str) -> None:
    markers = [
        parse_key_values(line, PROVENANCE_PREFIX, PROVENANCE_KEYS)
        for line in log.splitlines()
        if PROVENANCE_PREFIX in line
    ]
    require(
        len(markers) == 1,
        f"expected exactly one archive provenance marker, found {len(markers)}",
    )
    marker = markers[0]
    exact = {
        "configured": "1",
        "schema": "1",
        "key": "1",
        "metallib": "4",
        "digest": metallib_sha256,
        "stale-reset": "0",
    }
    for key, value in exact.items():
        require(
            marker[key] == value,
            f"archive provenance {key}: expected {value}, found {marker[key]}",
        )


def validate_test_mode(log: str, phase: str) -> None:
    markers = marker_group(log, TEST_MODE_PREFIX, TEST_MODE_KEYS)
    if phase in ("warm", "recovery-warm"):
        require(
            not markers,
            f"{phase} must not apply a pipeline archive test mode",
        )
        return

    require(
        len(markers) == 1,
        f"expected exactly one {phase} test-mode marker, found {len(markers)}",
    )
    expected = {
        "cold": {
            "mode": "cold",
            "abi": "1",
            "applied": "1",
            "bytes": "0",
            "sha256": "none",
            "removed-verified": "1",
            "write-verified": "0",
        },
        "corrupt": {
            "mode": "corrupt",
            "abi": "1",
            "applied": "1",
            "bytes": "43",
            "sha256": CORRUPT_PAYLOAD_SHA256,
            "removed-verified": "0",
            "write-verified": "1",
        },
    }[phase]
    marker = markers[0]
    for key, value in expected.items():
        require(
            marker[key] == value,
            f"{phase} test mode {key}: expected {value}, found {marker[key]}",
        )


def csv_integers(value: str) -> tuple[int, ...]:
    try:
        return tuple(int(item, 10) for item in value.split(","))
    except ValueError as error:
        raise ValidationError(f"invalid comma-separated counters: {value}") from error


def validate_runtime(
    log: str, scenario: str
) -> tuple[int, int, int, int, int]:
    bridges = [tuple(int(value) for value in match.groups()) for match in BRIDGE_RE.finditer(log)]
    require(
        len(bridges) == 1,
        f"expected one runtime bridge marker, found {len(bridges)}",
    )
    require(
        bridges[0] == (1, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        f"runtime bridge must be exact 0/0/0, found {bridges[0]}",
    )

    frames = [tuple(int(value) for value in match.groups()) for match in FRAME_RE.finditer(log)]
    require(len(frames) >= 300, "runtime frame markers do not reach present 300")
    transition_present = 0
    previous_render = 2
    for expected_present, frame in enumerate(frames, 1):
        present, available, source, compute, render = frame
        require(
            present == expected_present,
            f"runtime frame markers are not contiguous at {expected_present}: {present}",
        )
        require(available == 1, f"runtime counters unavailable at present {present}")
        require(source == 0, f"runtime source changed at present {present}: {source}")
        require(compute == 0, f"runtime compute changed at present {present}: {compute}")
        if scenario == "save":
            require(
                render == 2,
                "save runtime render total must remain exact 2 at "
                f"present {present}, found {render}",
            )
        else:
            require(
                render in (2, 3),
                "new-game runtime render total must be exact 2 or 3 at "
                f"present {present}, found {render}",
            )
            if present == 1:
                require(render == 2, "new-game runtime must start at exact render=2")
            require(
                render >= previous_render,
                f"new-game runtime render total regressed at present {present}",
            )
            if render != previous_render:
                require(
                    previous_render == 2 and render == 3 and transition_present == 0,
                    "new-game runtime must have exactly one 2-to-3 transition",
                )
                transition_present = present
            previous_render = render

    if scenario == "new-game":
        require(
            transition_present != 0,
            "new-game runtime never transitioned from exact render=2 to exact render=3",
        )
        require(
            transition_present <= FIRST_FLUSH_PRESENT,
            "new-game runtime render transition occurred after present 300: "
            f"{transition_present}",
        )

    builtin_frames = [
        (
            int(match.group(1)),
            int(match.group(2)),
            int(match.group(3)),
            csv_integers(match.group(4)),
            csv_integers(match.group(5)),
        )
        for match in BUILTIN_FRAME_RE.finditer(log)
    ]
    last_present = frames[-1][0]
    expected_builtin_presents = [1] + list(range(300, last_present + 1, 300))
    require(
        [frame[0] for frame in builtin_frames] == expected_builtin_presents,
        "Builtin attribution markers do not cover exact present 1/300 cadence",
    )
    for present, role_abi, available, source, render in builtin_frames:
        require(role_abi == 1, f"Builtin role ABI changed at present {present}")
        require(available == 1, f"Builtin counters unavailable at present {present}")
        require(
            source == EXPECTED_BUILTIN_SOURCE,
            f"Builtin source counters changed at present {present}: {source}",
        )
        expected_render = SAVE_BUILTIN_RENDER
        if scenario == "new-game" and present >= FIRST_FLUSH_PRESENT:
            expected_render = NEW_GAME_BUILTIN_RENDER
        require(
            render == expected_render,
            f"Builtin render role vector is wrong for {scenario} at "
            f"present {present}: {render}",
        )

    final_render = 2 if scenario == "save" else 3
    return 0, 0, final_render, last_present, transition_present


def validate_log(
    log: str,
    phase: str,
    scenario: str,
    source_sha: str,
    metallib_sha256: str,
) -> dict[str, int | str]:
    require(phase in ("cold", "warm", "corrupt", "recovery-warm"), "unknown phase")
    require(scenario in ("save", "new-game"), "unknown scenario")
    require(
        re.fullmatch(r"[0-9a-f]{40}", source_sha) is not None,
        "source SHA must be 40 lowercase hexadecimal characters",
    )
    require(
        re.fullmatch(r"[0-9a-f]{64}", metallib_sha256) is not None,
        "metallib SHA-256 must be 64 lowercase hexadecimal characters",
    )
    shell_builds = SHELL_BUILD_RE.findall(log)
    allowed_builds = {source_sha, f"{source_sha}-local"}
    require(
        len(shell_builds) == 1 and shell_builds[0] in allowed_builds,
        "expected exactly one RendererIOS shell marker with build equal to "
        f"{sorted(allowed_builds)}, found {shell_builds}",
    )
    require(
        "RendererIOS diagnostics: ON" in log,
        "device log is not from a diagnostics-enabled build",
    )
    require(
        "RendererIOS shader library: source=offline-metallib "
        "resource=RendererIOS.metallib abi=4" in log,
        "offline metallib ABI 4 marker is missing",
    )
    require(
        "Shader compilation took:" not in log,
        "legacy runtime shader batch ran",
    )
    require(FATAL_RE.search(log) is None, "fatal RendererIOS signature found")

    validate_test_mode(log, phase)
    validate_provenance(log, metallib_sha256)
    validate_snapshot_contract(log, phase, scenario)
    source, compute, render, last_present, transition_present = validate_runtime(
        log, scenario
    )
    final_snapshot = expected_snapshot(phase, scenario, "post")
    return {
        "phase": phase,
        "scenario": scenario,
        "runtime_source": source,
        "runtime_compute": compute,
        "runtime_render": render,
        "runtime_last_present": last_present,
        "runtime_render_transition_present": transition_present,
        "archive_load_failures": final_snapshot["load-fail"],
        "archive_rebuilds": final_snapshot["rebuild"],
        "archive_render_hits": final_snapshot["render-hit"],
        "archive_render_misses": final_snapshot["render-miss"],
        "archive_render_adds": final_snapshot["render-add"],
        "archive_render_fallbacks": final_snapshot["render-fallback"],
        "archive_flush_attempts": final_snapshot["flush-attempt"],
        "archive_flush_successes": final_snapshot["flush-success"],
        "archive_flush_failures": final_snapshot["flush-fail"],
    }


def synthetic_snapshot_lines(
    phase: str, scenario: str, point: str
) -> list[str]:
    values = expected_snapshot(phase, scenario, point)
    state_keys = [
        "point",
        "presents",
        "abi",
        "size",
        "flags",
        "schema",
        "key",
        "metallib",
        "cfg",
        "available",
        "loaded",
        "empty",
        "dirty",
        "disabled",
        "load-fail",
        "rebuild",
    ]
    common = f"point={point} presents={FIRST_FLUSH_PRESENT}"
    state_line = STATE_PREFIX + " ".join(
        f"{key}={values[key]}" for key in state_keys
    )
    render_line = (
        RENDER_PREFIX
        + common
        + " "
        + " ".join(
            f"{key}={values[f'render-{key}']}"
            for key in ("hit", "miss", "add", "fallback")
        )
    )
    compute_line = (
        COMPUTE_PREFIX
        + common
        + " "
        + " ".join(
            f"{key}={values[f'compute-{key}']}"
            for key in ("hit", "miss", "add", "fallback")
        )
    )
    flush_line = (
        FLUSH_PREFIX
        + common
        + " "
        + " ".join(
            f"{key}={values[f'flush-{key}']}"
            for key in (
                "attempt",
                "success",
                "fail",
                "invoked",
                "result",
                "bounded",
                "settled",
            )
        )
    )
    return [state_line, render_line, compute_line, flush_line]


def synthetic_log(
    phase: str,
    scenario: str,
    source_sha: str,
    metallib_sha256: str,
    *,
    transition_present: int | None = 150,
    last_present: int = FIRST_FLUSH_PRESENT,
) -> str:
    lines = [
        "RendererIOS shell: version=1 profile=Safe features=synthetic "
        f"build={source_sha}-local gpu=synthetic",
        "RendererIOS diagnostics: ON",
        "RendererIOS shader library: source=offline-metallib "
        "resource=RendererIOS.metallib abi=4",
        PROVENANCE_PREFIX
        + "configured=1 schema=1 key=1 metallib=4 "
        + f"digest={metallib_sha256} stale-reset=0",
        "RendererIOS runtime compilation: point=legacy-bridge available=1 "
        "source-before=0 source-after=0 source-delta=0 "
        "compute-before=0 compute-after=0 compute-delta=0 "
        "render-before=0 render-after=0 render-delta=0",
    ]
    if phase == "cold":
        lines.append(
            TEST_MODE_PREFIX
            + "mode=cold abi=1 applied=1 bytes=0 sha256=none "
            "removed-verified=1 write-verified=0"
        )
    elif phase == "corrupt":
        lines.append(
            TEST_MODE_PREFIX
            + "mode=corrupt abi=1 applied=1 bytes=43 "
            f"sha256={CORRUPT_PAYLOAD_SHA256} "
            "removed-verified=0 write-verified=1"
        )
    lines.extend(synthetic_snapshot_lines(phase, scenario, "pre"))
    lines.extend(synthetic_snapshot_lines(phase, scenario, "post"))
    for present in range(1, last_present + 1):
        render = 2
        if (
            scenario == "new-game"
            and transition_present is not None
            and present >= transition_present
        ):
            render = 3
        lines.append(
            "RendererIOS runtime compilation: point=frame "
            f"presents={present} available=1 source=0 compute=0 render={render}"
        )
        if present == 1 or present % 300 == 0:
            builtin_render = SAVE_BUILTIN_RENDER
            if scenario == "new-game" and render == 3:
                builtin_render = NEW_GAME_BUILTIN_RENDER
            lines.append(
                "RendererIOS builtin runtime attribution: point=frame "
                f"presents={present} role-abi=1 available=1 "
                "source=0,0,0,0 render="
                + ",".join(map(str, builtin_render))
            )
    return "\n".join(lines) + "\n"


def self_test() -> None:
    source_sha = "1" * 40
    metallib_sha256 = "a" * 64
    for scenario in ("save", "new-game"):
        for phase in ("cold", "warm", "corrupt", "recovery-warm"):
            log = synthetic_log(phase, scenario, source_sha, metallib_sha256)
            for line in log.splitlines():
                if "RendererIOS pipeline archive " in line:
                    require(
                        len(line.encode("utf-8")) < 255,
                        "synthetic archive marker exceeds Tempest log buffer: "
                        f"{len(line)}",
                    )
            validate_log(log, phase, scenario, source_sha, metallib_sha256)

    plain_sha_log = synthetic_log(
        "warm", "save", source_sha, metallib_sha256
    ).replace(
        f"build={source_sha}-local",
        f"build={source_sha}",
        1,
    )
    validate_log(plain_sha_log, "warm", "save", source_sha, metallib_sha256)

    bad_warm = synthetic_log(
        "warm", "save", source_sha, metallib_sha256
    ).replace(
        "snapshot-render: point=pre presents=300 hit=2",
        "snapshot-render: point=pre presents=300 hit=1",
        1,
    )
    try:
        validate_log(bad_warm, "warm", "save", source_sha, metallib_sha256)
    except ValidationError:
        pass
    else:
        raise ValidationError("negative warm-hit self-test unexpectedly passed")

    bad_runtime = synthetic_log(
        "cold", "save", source_sha, metallib_sha256
    ).replace(
        "presents=200 available=1 source=0 compute=0 render=2",
        "presents=200 available=1 source=1 compute=0 render=2",
        1,
    )
    try:
        validate_log(bad_runtime, "cold", "save", source_sha, metallib_sha256)
    except ValidationError:
        pass
    else:
        raise ValidationError("negative runtime-growth self-test unexpectedly passed")

    missing_cold_mode = synthetic_log(
        "cold", "save", source_sha, metallib_sha256
    ).replace(
        TEST_MODE_PREFIX
        + "mode=cold abi=1 applied=1 bytes=0 sha256=none "
        "removed-verified=1 write-verified=0\n",
        "",
        1,
    )
    try:
        validate_log(
            missing_cold_mode, "cold", "save", source_sha, metallib_sha256
        )
    except ValidationError:
        pass
    else:
        raise ValidationError("missing cold test-mode self-test unexpectedly passed")

    wrong_corrupt_digest = synthetic_log(
        "corrupt", "save", source_sha, metallib_sha256
    ).replace(CORRUPT_PAYLOAD_SHA256, "b" * 64, 1)
    try:
        validate_log(
            wrong_corrupt_digest,
            "corrupt",
            "save",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError(
            "wrong corrupt-payload digest self-test unexpectedly passed"
        )

    unexpected_warm_mode = synthetic_log(
        "warm", "save", source_sha, metallib_sha256
    ).replace(
        "RendererIOS diagnostics: ON\n",
        "RendererIOS diagnostics: ON\n"
        + TEST_MODE_PREFIX
        + "mode=cold abi=1 applied=1 bytes=0 sha256=none "
        "removed-verified=1 write-verified=0\n",
        1,
    )
    try:
        validate_log(
            unexpected_warm_mode, "warm", "save", source_sha, metallib_sha256
        )
    except ValidationError:
        pass
    else:
        raise ValidationError("unexpected warm test mode self-test passed")

    inexact_source = synthetic_log(
        "warm", "save", source_sha, metallib_sha256
    ).replace(
        f"build={source_sha}-local",
        f"build={source_sha}0-local",
        1,
    )
    try:
        validate_log(
            inexact_source, "warm", "save", source_sha, metallib_sha256
        )
    except ValidationError:
        pass
    else:
        raise ValidationError("inexact source SHA self-test unexpectedly passed")

    duplicate_source = synthetic_log(
        "warm", "save", source_sha, metallib_sha256
    ).replace(
        "RendererIOS diagnostics: ON\n",
        "RendererIOS shell: version=1 profile=Safe features=duplicate "
        f"build={source_sha}-local gpu=synthetic\n"
        "RendererIOS diagnostics: ON\n",
        1,
    )
    try:
        validate_log(
            duplicate_source, "warm", "save", source_sha, metallib_sha256
        )
    except ValidationError:
        pass
    else:
        raise ValidationError("duplicate source marker self-test unexpectedly passed")

    missing_transition = synthetic_log(
        "warm",
        "new-game",
        source_sha,
        metallib_sha256,
        transition_present=None,
    )
    try:
        validate_log(
            missing_transition,
            "warm",
            "new-game",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError("missing new-game transition self-test passed")

    late_transition = synthetic_log(
        "warm",
        "new-game",
        source_sha,
        metallib_sha256,
        transition_present=301,
        last_present=301,
    )
    try:
        validate_log(
            late_transition,
            "warm",
            "new-game",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError("post-300 new-game transition self-test passed")

    wrong_role_three = synthetic_log(
        "warm", "new-game", source_sha, metallib_sha256
    ).replace(
        "presents=300 role-abi=1 available=1 source=0,0,0,0 "
        "render=0,0,0,1,0,0,0,1,0,1,0,0",
        "presents=300 role-abi=1 available=1 source=0,0,0,0 "
        "render=0,0,1,0,0,0,0,1,0,1,0,0",
        1,
    )
    try:
        validate_log(
            wrong_role_three,
            "warm",
            "new-game",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError("wrong new-game role-3 self-test passed")

    growth_after_plateau = synthetic_log(
        "warm", "new-game", source_sha, metallib_sha256
    ).replace(
        "presents=250 available=1 source=0 compute=0 render=3",
        "presents=250 available=1 source=0 compute=0 render=4",
        1,
    )
    try:
        validate_log(
            growth_after_plateau,
            "warm",
            "new-game",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError("post-plateau growth self-test passed")


def write_summary(path: pathlib.Path, result: dict[str, int | str]) -> None:
    lines = [f"{key}={value}" for key, value in result.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--phase",
        choices=("cold", "warm", "corrupt", "recovery-warm"),
    )
    parser.add_argument("--scenario", choices=("save", "new-game"))
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--source-sha")
    parser.add_argument("--metallib-sha256")
    parser.add_argument("--summary", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    try:
        if args.self_test:
            self_test()
            print("PASS: pipeline archive log parser synthetic self-test")
            return 0
        require(args.phase is not None, "--phase is required")
        require(args.scenario is not None, "--scenario is required")
        require(args.log is not None, "--log is required")
        require(args.source_sha is not None, "--source-sha is required")
        require(args.metallib_sha256 is not None, "--metallib-sha256 is required")
        require(args.summary is not None, "--summary is required")
        log = args.log.read_text(encoding="utf-8", errors="replace")
        result = validate_log(
            log,
            args.phase,
            args.scenario,
            args.source_sha,
            args.metallib_sha256,
        )
        write_summary(args.summary, result)
        print(
            "PASS: pipeline archive "
            f"{args.phase} scenario={args.scenario} "
            f"source/compute/render=0/0/{result['runtime_render']} "
            f"last-present={result['runtime_last_present']}"
        )
        return 0
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
