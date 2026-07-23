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
# The semantic script reaches p1 before opening UI, then exercises Inventory,
# Items and Weapons.  By p300 both archive phases have requested the exact
# ColorTrianglesAlpha (index 3) role in addition to the two baseline texture
# roles, TextureTrianglesOpaque (7) and TextureTrianglesAlpha (9).
INVENTORY_POST_UI_BUILTIN_RENDER = (
    0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0
)
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
    marker_specs = (
        (STATE_PREFIX, STATE_KEYS),
        (RENDER_PREFIX, RENDER_KEYS),
        (COMPUTE_PREFIX, COMPUTE_KEYS),
        (FLUSH_PREFIX, FLUSH_KEYS),
    )
    marker_lines = [
        line
        for line in log.splitlines()
        if any(prefix in line for prefix, _ in marker_specs)
    ]
    require(
        len(marker_lines) >= 8,
        "expected at least one complete PRE/POST archive snapshot pair",
    )
    require(
        len(marker_lines) % 8 == 0,
        "archive snapshot markers do not form complete PRE/POST pairs: "
        f"found {len(marker_lines)} split markers",
    )

    parsed: list[dict[str, int | str]] = []
    for marker_offset in range(0, len(marker_lines), len(marker_specs)):
        groups: list[dict[str, str]] = []
        for group_index, (prefix, keys) in enumerate(marker_specs):
            line = marker_lines[marker_offset + group_index]
            require(
                prefix in line,
                "split snapshot marker order must be "
                "state/render/compute/flush",
            )
            groups.append(parse_key_values(line, prefix, keys))
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
    inventory_cold = phase == "inventory-cold"
    inventory_warm = phase == "inventory-warm"
    corrupt = phase == "corrupt"
    pre = point == "pre"
    render_count = 2 if scenario == "save" else 3
    if inventory_cold:
        render_hits = 2
        render_misses = 2
        render_adds = 2
    elif inventory_warm:
        render_hits = 4
        render_misses = 0
        render_adds = 0
    else:
        render_hits = 0 if cold_like else render_count
        render_misses = render_count if cold_like else 0
        render_adds = render_count if cold_like else 0
    flushes_dirty = (cold_like or inventory_cold) and pre
    flushed_dirty = (cold_like or inventory_cold) and not pre

    values: dict[str, int | str] = {
        "point": point,
        "presents": FIRST_FLUSH_PRESENT,
        "abi": 1,
        "size": 120,
        "flags": (
            23 if inventory_cold and pre
            else 27 if cold_like and pre
            else 11 if cold_like
            else 7
        ),
        "schema": 1,
        "key": 1,
        "metallib": 5,
        "cfg": 1,
        "available": 1,
        "loaded": 0 if cold_like else 1,
        "empty": 1 if cold_like else 0,
        "dirty": 1 if flushes_dirty else 0,
        "disabled": 0,
        "load-fail": 1 if corrupt else 0,
        "rebuild": 1 if corrupt else 0,
        "render-hit": render_hits,
        "render-miss": render_misses,
        "render-add": render_adds,
        "render-fallback": 0,
        "compute-hit": 0,
        "compute-miss": 0,
        "compute-add": 0,
        "compute-fallback": 0,
        "flush-attempt": 1 if flushed_dirty else 0,
        "flush-success": 1 if flushed_dirty else 0,
        "flush-fail": 0,
        "flush-invoked": 1 if flushed_dirty else 0,
        "flush-result": 1 if flushed_dirty else 0,
        "flush-bounded": 1 if flushed_dirty else 0,
        "flush-settled": 0 if pre else 1,
    }
    return values


def validate_snapshot_flags(actual: dict[str, int | str]) -> None:
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


def validate_late_snapshot_pair(
    pre: dict[str, int | str], post: dict[str, int | str]
) -> None:
    stable_keys = (
        "abi",
        "size",
        "schema",
        "key",
        "metallib",
        "cfg",
        "available",
        "loaded",
        "empty",
        "load-fail",
        "rebuild",
        "render-hit",
        "render-miss",
        "render-add",
        "render-fallback",
        "compute-hit",
        "compute-miss",
        "compute-add",
        "compute-fallback",
    )
    for key in stable_keys:
        require(
            post[key] == pre[key],
            f"late snapshot pair changed {key} during archive flush",
        )

    require(int(pre["dirty"]) == 1, "late PRE snapshot must be dirty")
    require(
        int(pre["flush-invoked"]) == 0
        and int(pre["flush-result"]) == 0,
        "late PRE snapshot must precede the flush invocation",
    )
    require(
        int(post["flush-invoked"]) == 1,
        "late POST snapshot must follow a flush invocation",
    )
    result = int(post["flush-result"])
    require(result in (0, 1), "late POST flush result must be boolean")
    disabled_before = int(pre["disabled"])
    disabled_after = int(post["disabled"])
    if result == 0:
        require(
            int(post["dirty"]) == 1 and disabled_after == 1,
            "late failed flush must remain dirty and disable the archive",
        )
    else:
        require(
            disabled_before == 0 and disabled_after == 0,
            "late successful flush cannot use a disabled archive",
        )
    require(
        int(post["flush-attempt"]) == int(pre["flush-attempt"]) + 1,
        "late snapshot flush-attempt counter must advance exactly once",
    )
    require(
        int(post["flush-success"]) ==
        int(pre["flush-success"]) + result,
        "late snapshot flush-success counter disagrees with result",
    )
    require(
        int(post["flush-fail"]) ==
        int(pre["flush-fail"]) + (1 - result),
        "late snapshot flush-fail counter disagrees with result",
    )
    bounded_before = int(pre["flush-bounded"])
    bounded_after = int(post["flush-bounded"])
    require(
        0 <= bounded_before < 3 and bounded_after == bounded_before + 1,
        "late snapshot bounded attempt must advance within 1..3",
    )
    require(
        int(pre["flush-settled"]) == 0,
        "late PRE snapshot must have an active unsettled episode",
    )
    dirty_after = int(post["dirty"])
    require(dirty_after in (0, 1), "late POST dirty field must be boolean")
    expected_settled = 1 if dirty_after == 0 or bounded_after == 3 else 0
    require(
        int(post["flush-settled"]) == expected_settled,
        "late POST settled state disagrees with dirty/bounded state",
    )


def validate_snapshot_contract(
    log: str, phase: str, scenario: str
) -> dict[str, int | str]:
    snapshots = snapshot_lines(log)
    require(
        len(snapshots) >= 2 and len(snapshots) % 2 == 0,
        "archive snapshots must form complete PRE/POST pairs",
    )
    previous_present = -1
    monotonic_keys = (
        "load-fail",
        "rebuild",
        "render-hit",
        "render-miss",
        "render-add",
        "render-fallback",
        "compute-hit",
        "compute-miss",
        "compute-add",
        "compute-fallback",
        "flush-attempt",
        "flush-success",
        "flush-fail",
    )
    stable_metadata_keys = (
        "abi",
        "size",
        "schema",
        "key",
        "metallib",
        "cfg",
        "available",
        "loaded",
        "empty",
    )
    for pair_offset in range(0, len(snapshots), 2):
        pre = snapshots[pair_offset]
        post = snapshots[pair_offset + 1]
        require(
            [pre["point"], post["point"]] == ["pre", "post"],
            "archive snapshot attempts must be ordered PRE then POST",
        )
        present = int(pre["presents"])
        require(
            int(post["presents"]) == present,
            "archive PRE/POST snapshots must share a present",
        )
        require(
            present > previous_present,
            "archive snapshot attempt presents must increase strictly",
        )
        previous_present = present
        if pair_offset > 0:
            validate_late_snapshot_pair(pre, post)

    for index, actual in enumerate(snapshots):
        validate_snapshot_flags(actual)
        for key in stable_metadata_keys:
            require(
                actual[key] == snapshots[0][key],
                f"archive snapshot stable metadata changed: {key}",
            )
        if index > 0:
            previous = snapshots[index - 1]
            for key in monotonic_keys:
                require(
                    int(actual[key]) >= int(previous[key]),
                    f"archive snapshot counter regressed: {key}",
                )

    for actual in snapshots[:2]:
        point = str(actual["point"])
        expected = expected_snapshot(phase, scenario, point)
        for key, expected_value in expected.items():
            require(
                actual[key] == expected_value,
                f"{phase} {point} field {key}: "
                f"expected {expected_value}, found {actual[key]}",
            )
    return snapshots[-1]


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
        "metallib": "5",
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
    if phase in ("warm", "recovery-warm", "inventory-cold", "inventory-warm"):
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
    log: str, scenario: str, phase: str
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
    inventory_transitions: list[int] = []
    inventory_phase = phase in ("inventory-cold", "inventory-warm")
    inventory_render_sequence = {
        "inventory-cold": (2, 4, 6),
        "inventory-warm": (2, 3, 4),
    }.get(phase, ())
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
        if inventory_phase:
            require(
                render in inventory_render_sequence,
                f"{phase} runtime render total must be one of exact "
                f"{inventory_render_sequence} at present {present}, "
                f"found {render}",
            )
            if present == 1:
                require(
                    render == inventory_render_sequence[0],
                    f"{phase} runtime must start at exact render=2",
                )
            require(
                render >= previous_render,
                f"{phase} runtime render total regressed at present {present}",
            )
            if render != previous_render:
                transition_index = len(inventory_transitions)
                require(
                    transition_index < len(inventory_render_sequence) - 1
                    and previous_render
                    == inventory_render_sequence[transition_index]
                    and render
                    == inventory_render_sequence[transition_index + 1],
                    f"{phase} runtime must transition exactly "
                    + "-to-".join(map(str, inventory_render_sequence)),
                )
                inventory_transitions.append(present)
            previous_render = render
        elif scenario == "save":
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

    if inventory_phase:
        final_inventory_render = inventory_render_sequence[-1]
        require(
            len(inventory_transitions) == 2,
            f"{phase} runtime must contain exactly two render transitions",
        )
        require(
            inventory_transitions[-1] <= FIRST_FLUSH_PRESENT,
            f"{phase} runtime did not reach exact "
            f"render={final_inventory_render} by present 300",
        )
        require(
            frames[FIRST_FLUSH_PRESENT - 1][4] == final_inventory_render
            and previous_render == final_inventory_render,
            f"{phase} runtime render total did not plateau at exact "
            f"{final_inventory_render}",
        )
        transition_present = inventory_transitions[-1]
    elif scenario == "new-game":
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
        if inventory_phase and present >= FIRST_FLUSH_PRESENT:
            expected_render = INVENTORY_POST_UI_BUILTIN_RENDER
        elif scenario == "new-game" and present >= FIRST_FLUSH_PRESENT:
            expected_render = NEW_GAME_BUILTIN_RENDER
        require(
            render == expected_render,
            f"Builtin render role vector is wrong for {scenario} at "
            f"present {present}: {render}",
        )

    final_render = (
        inventory_render_sequence[-1]
        if inventory_phase
        else 2 if scenario == "save" else 3
    )
    return 0, 0, final_render, last_present, transition_present


def validate_log(
    log: str,
    phase: str,
    scenario: str,
    source_sha: str,
    metallib_sha256: str,
) -> dict[str, int | str]:
    require(
        phase in (
            "cold",
            "warm",
            "corrupt",
            "recovery-warm",
            "inventory-cold",
            "inventory-warm",
        ),
        "unknown phase",
    )
    require(scenario in ("save", "new-game"), "unknown scenario")
    require(
        phase not in ("inventory-cold", "inventory-warm") or scenario == "save",
        "inventory archive phases require the save scenario",
    )
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
        "resource=RendererIOS.metallib abi=5" in log,
        "offline metallib ABI 5 marker is missing",
    )
    require(
        "Shader compilation took:" not in log,
        "legacy runtime shader batch ran",
    )
    require(FATAL_RE.search(log) is None, "fatal RendererIOS signature found")

    validate_test_mode(log, phase)
    validate_provenance(log, metallib_sha256)
    final_snapshot = validate_snapshot_contract(log, phase, scenario)
    source, compute, render, last_present, transition_present = validate_runtime(
        log, scenario, phase
    )
    require(
        int(final_snapshot["presents"]) <= last_present,
        "last archive snapshot present exceeds the runtime frame range",
    )
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


def snapshot_marker_lines(values: dict[str, int | str]) -> list[str]:
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
    common = f"point={values['point']} presents={values['presents']}"
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


def synthetic_snapshot_lines(
    phase: str, scenario: str, point: str
) -> list[str]:
    return snapshot_marker_lines(expected_snapshot(phase, scenario, point))


def synthetic_late_attempt_lines(
    phase: str,
    scenario: str,
    present: int,
    *,
    attempt_before: int,
    success_before: int,
    fail_before: int,
    bounded_before: int,
    succeeded: bool,
    dirty_after: bool,
) -> list[str]:
    pre = expected_snapshot(phase, scenario, "post")
    pre.update(
        {
            "point": "pre",
            "presents": present,
            "flags": int(pre["flags"]) | 16,
            "dirty": 1,
            "render-miss": int(pre["render-miss"]) + 1,
            "render-add": int(pre["render-add"]) + 1,
            "flush-attempt": attempt_before,
            "flush-success": success_before,
            "flush-fail": fail_before,
            "flush-invoked": 0,
            "flush-result": 0,
            "flush-bounded": bounded_before,
            "flush-settled": 0,
        }
    )
    post = dict(pre)
    post.update(
        {
            "point": "post",
            "flags": int(pre["flags"]) if dirty_after else int(pre["flags"]) & ~16,
            "dirty": 1 if dirty_after else 0,
            "flush-attempt": attempt_before + 1,
            "flush-success": success_before + (1 if succeeded else 0),
            "flush-fail": fail_before + (0 if succeeded else 1),
            "flush-invoked": 1,
            "flush-result": 1 if succeeded else 0,
            "flush-bounded": bounded_before + 1,
            "flush-settled":
                1 if not dirty_after or bounded_before + 1 == 3 else 0,
        }
    )
    return snapshot_marker_lines(pre) + snapshot_marker_lines(post)


def synthetic_log(
    phase: str,
    scenario: str,
    source_sha: str,
    metallib_sha256: str,
    *,
    transition_present: int | None = 150,
    inventory_final_transition_present: int = 200,
    last_present: int = FIRST_FLUSH_PRESENT,
    extra_snapshot_lines: list[str] | None = None,
) -> str:
    lines = [
        "RendererIOS shell: version=1 profile=Safe features=synthetic "
        f"build={source_sha}-local gpu=synthetic",
        "RendererIOS diagnostics: ON",
        "RendererIOS shader library: source=offline-metallib "
        "resource=RendererIOS.metallib abi=5",
        PROVENANCE_PREFIX
        + "configured=1 schema=1 key=1 metallib=5 "
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
    if extra_snapshot_lines is not None:
        lines.extend(extra_snapshot_lines)
    for present in range(1, last_present + 1):
        render = 2
        if phase in ("inventory-cold", "inventory-warm"):
            if transition_present is not None and present >= transition_present:
                render = 4 if phase == "inventory-cold" else 3
            if present >= inventory_final_transition_present:
                render = 6 if phase == "inventory-cold" else 4
        elif (
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
            if (
                phase in ("inventory-cold", "inventory-warm")
                and present >= FIRST_FLUSH_PRESENT
            ):
                builtin_render = INVENTORY_POST_UI_BUILTIN_RENDER
            elif scenario == "new-game" and render == 3:
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

    for phase, final_render in (
        ("inventory-cold", 6),
        ("inventory-warm", 4),
    ):
        inventory_log = synthetic_log(
            phase,
            "save",
            source_sha,
            metallib_sha256,
            last_present=600,
        )
        inventory_result = validate_log(
            inventory_log,
            phase,
            "save",
            source_sha,
            metallib_sha256,
        )
        require(
            inventory_result["runtime_render"] == final_render,
            f"{phase} synthetic runtime did not finish at "
            f"render={final_render}",
        )

    def expect_inventory_runtime_failure(
        log: str, phase: str, message: str
    ) -> None:
        try:
            validate_log(
                log,
                phase,
                "save",
                source_sha,
                metallib_sha256,
            )
        except ValidationError:
            return
        raise ValidationError(message)

    def builtin_frame_marker(
        present: int, render: tuple[int, ...]
    ) -> str:
        return (
            "RendererIOS builtin runtime attribution: point=frame "
            f"presents={present} role-abi=1 available=1 "
            "source=0,0,0,0 render="
            + ",".join(map(str, render))
        )

    for phase, intermediate_render, final_render in (
        ("inventory-cold", 4, 6),
        ("inventory-warm", 3, 4),
    ):
        skipped_transition = synthetic_log(
            phase,
            "save",
            source_sha,
            metallib_sha256,
            inventory_final_transition_present=301,
        )
        expect_inventory_runtime_failure(
            skipped_transition,
            phase,
            f"{phase} skipped render transition self-test unexpectedly passed",
        )

        jumped_transition = synthetic_log(
            phase,
            "save",
            source_sha,
            metallib_sha256,
            transition_present=200,
            inventory_final_transition_present=200,
        )
        expect_inventory_runtime_failure(
            jumped_transition,
            phase,
            f"{phase} jumped render transition self-test unexpectedly passed",
        )

        wrong_step_render = 3 if phase == "inventory-cold" else 4
        wrong_step = synthetic_log(
            phase,
            "save",
            source_sha,
            metallib_sha256,
        ).replace(
            "presents=150 available=1 source=0 compute=0 "
            f"render={intermediate_render}",
            "presents=150 available=1 source=0 compute=0 "
            f"render={wrong_step_render}",
            1,
        )
        expect_inventory_runtime_failure(
            wrong_step,
            phase,
            f"{phase} wrong render step self-test unexpectedly passed",
        )

        late_transition = synthetic_log(
            phase,
            "save",
            source_sha,
            metallib_sha256,
            inventory_final_transition_present=301,
            last_present=600,
        )
        expect_inventory_runtime_failure(
            late_transition,
            phase,
            f"{phase} late render transition self-test unexpectedly passed",
        )

        broken_plateau = synthetic_log(
            phase,
            "save",
            source_sha,
            metallib_sha256,
            last_present=600,
        ).replace(
            "presents=301 available=1 source=0 compute=0 "
            f"render={final_render}",
            "presents=301 available=1 source=0 compute=0 "
            f"render={intermediate_render}",
            1,
        )
        expect_inventory_runtime_failure(
            broken_plateau,
            phase,
            f"{phase} broken render plateau self-test unexpectedly passed",
        )

        role_log = synthetic_log(
            phase,
            "save",
            source_sha,
            metallib_sha256,
            last_present=600,
        )
        p1_baseline = builtin_frame_marker(1, SAVE_BUILTIN_RENDER)
        p300_inventory = builtin_frame_marker(
            FIRST_FLUSH_PRESENT, INVENTORY_POST_UI_BUILTIN_RENDER
        )
        missing_role = role_log.replace(
            p300_inventory,
            builtin_frame_marker(
                FIRST_FLUSH_PRESENT, SAVE_BUILTIN_RENDER
            ),
            1,
        )
        expect_inventory_runtime_failure(
            missing_role,
            phase,
            f"{phase} missing ColorTrianglesAlpha role self-test unexpectedly passed",
        )

        extra_render = list(INVENTORY_POST_UI_BUILTIN_RENDER)
        extra_render[1] = 1
        extra_role = role_log.replace(
            p300_inventory,
            builtin_frame_marker(
                FIRST_FLUSH_PRESENT, tuple(extra_render)
            ),
            1,
        )
        expect_inventory_runtime_failure(
            extra_role,
            phase,
            f"{phase} extra ColorTrianglesOpaque role self-test unexpectedly passed",
        )

        wrong_render = list(SAVE_BUILTIN_RENDER)
        wrong_render[1] = 1
        wrong_role = role_log.replace(
            p300_inventory,
            builtin_frame_marker(
                FIRST_FLUSH_PRESENT, tuple(wrong_render)
            ),
            1,
        )
        expect_inventory_runtime_failure(
            wrong_role,
            phase,
            f"{phase} wrong builtin render role self-test unexpectedly passed",
        )

        early_inventory_role = role_log.replace(
            p1_baseline,
            builtin_frame_marker(1, INVENTORY_POST_UI_BUILTIN_RENDER),
            1,
        )
        expect_inventory_runtime_failure(
            early_inventory_role,
            phase,
            f"{phase} wrong builtin role phase timing self-test unexpectedly passed",
        )

    plain_sha_log = synthetic_log(
        "warm", "save", source_sha, metallib_sha256
    ).replace(
        f"build={source_sha}-local",
        f"build={source_sha}",
        1,
    )
    validate_log(plain_sha_log, "warm", "save", source_sha, metallib_sha256)

    late_markers = synthetic_late_attempt_lines(
        "warm",
        "save",
        600,
        attempt_before=0,
        success_before=0,
        fail_before=0,
        bounded_before=0,
        succeeded=True,
        dirty_after=True,
    ) + synthetic_late_attempt_lines(
        "warm",
        "save",
        601,
        attempt_before=1,
        success_before=1,
        fail_before=0,
        bounded_before=1,
        succeeded=True,
        dirty_after=False,
    )
    late_log = synthetic_log(
        "warm",
        "save",
        source_sha,
        metallib_sha256,
        last_present=601,
        extra_snapshot_lines=late_markers,
    )
    late_result = validate_log(
        late_log, "warm", "save", source_sha, metallib_sha256
    )
    require(
        late_result["archive_render_misses"] == 1
        and late_result["archive_render_adds"] == 1
        and late_result["archive_flush_attempts"] == 2
        and late_result["archive_flush_successes"] == 2
        and late_result["archive_flush_failures"] == 0,
        "late archive summary does not use the final POST snapshot",
    )

    incomplete_late_log = late_log.replace(late_markers[-2] + "\n", "", 1)
    try:
        validate_log(
            incomplete_late_log,
            "warm",
            "save",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError(
            "incomplete late snapshot pair self-test unexpectedly passed"
        )

    reordered_late_log = synthetic_log(
        "warm",
        "save",
        source_sha,
        metallib_sha256,
        last_present=601,
        extra_snapshot_lines=late_markers[8:] + late_markers[:8],
    )
    try:
        validate_log(
            reordered_late_log,
            "warm",
            "save",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError(
            "reordered late snapshot pair self-test unexpectedly passed"
        )

    future_late_log = synthetic_log(
        "warm",
        "save",
        source_sha,
        metallib_sha256,
        last_present=600,
        extra_snapshot_lines=late_markers,
    )
    try:
        validate_log(
            future_late_log,
            "warm",
            "save",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError(
            "future late snapshot present self-test unexpectedly passed"
        )

    changed_metadata_markers = [
        line.replace("schema=1", "schema=2", 1)
        if "snapshot-state:" in line and "presents=600" in line
        else line
        for line in late_markers
    ]
    changed_metadata_log = synthetic_log(
        "warm",
        "save",
        source_sha,
        metallib_sha256,
        last_present=601,
        extra_snapshot_lines=changed_metadata_markers,
    )
    try:
        validate_log(
            changed_metadata_log,
            "warm",
            "save",
            source_sha,
            metallib_sha256,
        )
    except ValidationError:
        pass
    else:
        raise ValidationError(
            "changed late snapshot metadata self-test unexpectedly passed"
        )

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
        choices=(
            "cold",
            "warm",
            "corrupt",
            "recovery-warm",
            "inventory-cold",
            "inventory-warm",
        ),
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
