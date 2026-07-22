#!/usr/bin/env python3
"""Validate the canonical RendererIOS ID3 terminal preview-fence save flow."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


FAULT_MODE = "preview-fence-error-after-terminal"
FAULT_POINT = "preview-fence-after-terminal"
SCRIPT_MODE = "preview-fence-save-v1"
SAVE_SLOT = "save_slot_20.sav"
FATAL_DETAIL = (
    "RendererIOS Metal save-preview fence failed: RendererIOS diagnostics "
    "injected a terminal save-preview fence error"
)
STOPPED_DETAIL = f"RendererIOS stopped the frame loop: {FATAL_DETAIL}"

SHELL_RE = re.compile(
    r"^RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*$",
    re.MULTILINE,
)
CONFIGURED_RE = re.compile(
    r"^RendererIOS configured fault mode=([^\s]+)$", re.MULTILINE
)
DIAGNOSTICS_RE = re.compile(
    r"^RendererIOS diagnostics: ON frames-in-flight=(\d+) "
    r"context=IOSMetalContext transport=Tempest$",
    re.MULTILINE,
)
FAULT_ARMED_RE = re.compile(
    r"^RendererIOS fault injection armed: mode=([^\s]+) build=([^\s]+)$",
    re.MULTILINE,
)
SCRIPT_ARMED_RE = re.compile(
    rf"^RendererIOS preview fence save script: ARMED mode={SCRIPT_MODE} "
    rf"nonce=([0-9a-f]{{32}}) slot={re.escape(SAVE_SLOT)}$",
    re.MULTILINE,
)
REQUEST_RE = re.compile(
    r"^\[save\] RendererIOS request: request=(\d+) route=gpu-diagnostic$",
    re.MULTILINE,
)
SCRIPT_REQUESTED_RE = re.compile(
    rf"^RendererIOS preview fence save script: REQUESTED mode={SCRIPT_MODE} "
    rf"nonce=([0-9a-f]{{32}}) slot={re.escape(SAVE_SLOT)} request=(\d+)$",
    re.MULTILINE,
)
PRESENT_RE = re.compile(
    r"^RendererIOS runtime compilation: point=frame presents=(\d+) "
    r"available=(\d+) source=(\d+) compute=(\d+) render=(\d+)$",
    re.MULTILINE,
)
QUEUED_RE = re.compile(
    rf"^\[save\] RendererIOS preview queued: source=gpu-diagnostic "
    rf"slot={re.escape(SAVE_SLOT)} request=(\d+)$",
    re.MULTILINE,
)
FIRED_RE = re.compile(
    r"^RendererIOS fault injection fired: mode=([^\s]+) "
    r"point=([^\s]+) build=([^\s]+)$",
    re.MULTILINE,
)
FATAL_RE = re.compile(rf"^{re.escape(FATAL_DETAIL)}$", re.MULTILINE)
SNAPSHOT_RE = re.compile(
    r"^RendererIOS fatal snapshot: submit-attempts=(\d+) "
    r"submit-accepted=(\d+) present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
STOPPED_RE = re.compile(rf"^{re.escape(STOPPED_DETAIL)}$", re.MULTILINE)
SCENE_EXTERNAL_RE = re.compile(
    r"^RendererIOS scene lifetime: reason=external-wait retained=(\d+) "
    r"released=(\d+) live=(\d+)$",
    re.MULTILINE,
)
SCENE_ANY_RE = re.compile(
    r"^RendererIOS scene lifetime: reason=([^\s]+) retained=(\d+) "
    r"released=(\d+) live=(\d+)$",
    re.MULTILINE,
)
SETTLED_RE = re.compile(
    r"^RendererIOS fatal settled: idle-confirmed=(\d+) "
    r"submit-attempts=(\d+) submit-accepted=(\d+) "
    r"present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
DELTA_RE = re.compile(
    r"^RendererIOS fatal post-delta: submit-attempts=(\d+) "
    r"submit-accepted=(\d+) present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
ACCEPTED_RE = re.compile(
    rf"^\[save\] RendererIOS startSave accepted: source=placeholder "
    rf"slot={re.escape(SAVE_SLOT)} request=(\d+) request-to-accepted-us=(\d+)$",
    re.MULTILINE,
)
COMPLETED_RE = re.compile(
    rf"^\[save\] RendererIOS save completed: source=placeholder "
    rf"slot={re.escape(SAVE_SLOT)} request=(\d+) serialize-us=(\d+) "
    r"request-to-complete-us=(\d+)$",
    re.MULTILINE,
)
LIFECYCLE_RE = re.compile(
    r"^RendererIOS lifecycle counters: transition=([^\s]+) idle-confirmed=(\d+) "
    r"submit-attempts=(\d+) submit-accepted=(\d+) "
    r"present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
SHUTDOWN_RE = re.compile(
    r"^RendererIOS shutdown counters: outcome=([^\s]+) "
    r"submit-attempts=(\d+) submit-accepted=(\d+) "
    r"present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
SHUTDOWN_DELTA_RE = re.compile(
    r"^RendererIOS shutdown post-fatal delta: submit-attempts=(\d+) "
    r"submit-accepted=(\d+) present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
DANGEROUS_RE = re.compile(
    r"RendererIOS (?:fatal:|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed|"
    r"resume swapchain reset failed|native Landscape encode failed|"
    r"IOSGPUScene metallib loading failed|Metal (?:save-preview )?frame fence failed)|"
    r"preview fence save script: SCRIPT FAIL|save-preview readback failed|"
    r"save preview allocation failed|allocation returned an empty image|"
    r"preview readback failed|stopped before capture|"
    r"unable to write savegame file|unable to start load/save|"
    r"loading error:|loader-start-not-accepted|"
    r"Metal save-preview fence failed|swapchain reset failed|reset renderer failed|"
    r"libc\+\+abi: terminating|SIGABRT|EXC_BAD_ACCESS|AddressSanitizer|"
    r"ThreadSanitizer|UndefinedBehaviorSanitizer|DeviceLostException|"
    r"DeviceHangException|device[- ]lost|out[- ]of[- ]memory|\bOOM\b|"
    r"\btimeout\b|timed out|unhandled (?:non-std/ObjC )?exception in render loop|"
    r"uncaught exception|\babort(?:ed)?\b|\bterminat(?:e|ed|ing)\b|"
    r"terminate called|terminating without C\+\+ teardown|std::terminate|jetsam",
    re.IGNORECASE,
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def one(log: str, pattern: re.Pattern[str], name: str) -> re.Match[str]:
    matches = list(pattern.finditer(log))
    require(len(matches) == 1, f"expected exactly one {name}, found {len(matches)}")
    return matches[0]


def prefix_count(log: str, prefix: str) -> int:
    return sum(line.startswith(prefix) for line in log.splitlines())


def exact_prefix(log: str, prefix: str, expected: int = 1) -> None:
    found = prefix_count(log, prefix)
    require(found == expected, f"expected {expected} {prefix!r}, found {found}")


def scrub(text: str, expected_lines: tuple[str, ...]) -> str:
    expected = set(expected_lines)
    return "".join(
        physical
        for physical in text.splitlines(keepends=True)
        if physical.rstrip("\r\n") not in expected
    )


def validate(
    log: str,
    stderr: str,
    expected_build: str,
    expected_nonce: str,
    expected_fault: str = FAULT_MODE,
) -> dict[str, int | str]:
    require(
        re.fullmatch(r"[0-9a-f]{40}(?:-local)?", expected_build) is not None,
        "expected build must be a lowercase SHA, optionally suffixed -local",
    )
    require(re.fullmatch(r"[0-9a-f]{32}", expected_nonce) is not None, "invalid nonce")
    require(expected_fault == FAULT_MODE, f"unsupported fault oracle: {expected_fault}")

    prefixes = (
        "RendererIOS configured fault mode=",
        "RendererIOS shell: version=",
        "RendererIOS diagnostics:",
        "RendererIOS fault injection armed:",
        "RendererIOS preview fence save script: ARMED",
        "[save] RendererIOS request:",
        "RendererIOS preview fence save script: REQUESTED",
        "[save] RendererIOS preview queued:",
        "RendererIOS fault injection fired:",
        FATAL_DETAIL,
        "RendererIOS fatal snapshot:",
        STOPPED_DETAIL,
        "RendererIOS scene lifetime: reason=external-wait",
        "RendererIOS fatal settled:",
        "RendererIOS fatal post-delta:",
        "[save] RendererIOS startSave accepted:",
        "[save] RendererIOS save completed:",
    )
    for marker_prefix in prefixes:
        exact_prefix(log, marker_prefix)
    exact_prefix(log, "RendererIOS preview fence save script: SCRIPT FAIL", 0)
    exact_prefix(log, "[save] RendererIOS startSave deferred:", 0)
    require(
        log.count("savePreviewRoute=gpu-diagnostic") == 1,
        "shell does not prove exactly one GPU diagnostic preview route",
    )

    configured = one(log, CONFIGURED_RE, "configured fault")
    shell = one(log, SHELL_RE, "RendererIOS shell")
    diagnostics = one(log, DIAGNOSTICS_RE, "diagnostics")
    fault_armed = one(log, FAULT_ARMED_RE, "fault armed")
    script_armed = one(log, SCRIPT_ARMED_RE, "script armed")
    request = one(log, REQUEST_RE, "save request")
    script_requested = one(log, SCRIPT_REQUESTED_RE, "script requested")
    queued = one(log, QUEUED_RE, "preview queued")
    fired = one(log, FIRED_RE, "fault fired")
    fatal = one(log, FATAL_RE, "expected preview-fence fatal")
    snapshot = one(log, SNAPSHOT_RE, "fatal snapshot")
    stopped = one(log, STOPPED_RE, "stopped frame loop")
    scene = one(log, SCENE_EXTERNAL_RE, "external-wait scene lifetime")
    settled = one(log, SETTLED_RE, "fatal settled")
    delta = one(log, DELTA_RE, "fatal post-delta")
    accepted = one(log, ACCEPTED_RE, "placeholder save accepted")
    completed = one(log, COMPLETED_RE, "placeholder save completed")

    require(configured.group(1) == expected_fault, "configured fault mismatch")
    require(shell.group(1) == expected_build, "shell build mismatch")
    n = int(diagnostics.group(1))
    require(n in (2, 3), "frames-in-flight must be exactly 2 or 3")
    require(
        fault_armed.groups() == (expected_fault, expected_build),
        "fault armed mode/build mismatch",
    )
    require(script_armed.group(1) == expected_nonce, "script ARMED nonce mismatch")
    require(request.group(1) == "1", "save request is not request 1")
    require(
        script_requested.groups() == (expected_nonce, "1"),
        "script REQUESTED nonce/request mismatch",
    )
    require(queued.group(1) == "1", "queued preview is not request 1")
    require(
        fired.groups() == (expected_fault, FAULT_POINT, expected_build),
        "fault fired mode/point/build mismatch",
    )

    present_prefixes = prefix_count(
        log, "RendererIOS runtime compilation: point=frame "
    )
    presents = [
        (match.start(),) + tuple(map(int, match.groups()))
        for match in PRESENT_RE.finditer(log)
    ]
    require(len(presents) == present_prefixes, "malformed runtime present marker")
    require(presents, "no accepted present preceded the preview fault")
    present_numbers = [values[1] for values in presents]
    m = present_numbers[-1]
    require(present_numbers == list(range(1, m + 1)), "presents are not contiguous 1..M")
    render_counters = []
    for _, present, available, source, compute, render in presents:
        require(available == 1, f"runtime counters unavailable at present {present}")
        require(source == 0 and compute == 0, f"runtime compilation grew at {present}")
        require(render in (2, 3), f"unexpected render counter at present {present}")
        render_counters.append(render)
    require(
        render_counters == sorted(render_counters),
        "runtime render counters regressed",
    )
    k = sum(position < request.start() for position, *_ in presents)
    require(
        1 <= m - k <= n,
        "post-request present window is not bounded by frames-in-flight",
    )
    post_request_presents = presents[k:]
    first_after_request = post_request_presents[0]
    require(
        request.start() < script_requested.start() < first_after_request[0] < queued.start(),
        "request/capture-present/queued ordering is invalid",
    )
    if len(post_request_presents) > 1:
        require(
            queued.start() < post_request_presents[1][0],
            "preview queued after the second post-request present",
        )
    require(all(position < fired.start() for position, *_ in presents), "present after fault")

    counters = (m, m, m, m)
    require(tuple(map(int, snapshot.groups())) == counters, "snapshot is not M/M/M/M")
    require(tuple(map(int, scene.groups())) == (m, m, 0), "scene is not M/M/0")
    require(
        tuple(map(int, settled.groups())) == (1,) + counters,
        "settled is not idle=1 with stable M/M/M/M",
    )
    require(tuple(map(int, delta.groups())) == (0, 0, 0, 0), "fatal delta is nonzero")
    require(accepted.group(1) == "1", "accepted save request mismatch")
    require(completed.group(1) == "1", "completed save request mismatch")
    accepted_us = int(accepted.group(2))
    serialize_us = int(completed.group(2))
    complete_us = int(completed.group(3))
    require(accepted_us >= 0, "accepted timing is negative")
    require(0 <= serialize_us <= complete_us, "completion timings are inconsistent")

    ordered = (
        configured.start(),
        shell.start(),
        diagnostics.start(),
        fault_armed.start(),
        script_armed.start(),
        request.start(),
        script_requested.start(),
        queued.start(),
        fired.start(),
        fatal.start(),
        snapshot.start(),
        stopped.start(),
        scene.start(),
        settled.start(),
        delta.start(),
    )
    require(ordered == tuple(sorted(ordered)), "canonical ID3 markers are out of order")
    require(accepted.start() > delta.end(), "accepted save precedes fatal settlement")
    require(completed.start() > delta.end(), "completed save precedes fatal settlement")

    after_fired = log[fired.end() :]
    require(PRESENT_RE.search(after_fired) is None, "runtime present occurred after fault")
    require(
        "RendererIOS shell: 300 present calls submitted" not in after_fired,
        "healthy 300-present marker occurred after fault",
    )
    require(
        prefix_count(after_fired, "RendererIOS lifecycle counters: transition=resume-settled ") == 0,
        "resume-settled occurred after fatal",
    )
    require(re.search(r"\bresumed=1(?:\s|$)", after_fired) is None, "renderer resumed after fatal")

    scene_matches = list(SCENE_ANY_RE.finditer(log))
    require(
        len(scene_matches) == prefix_count(log, "RendererIOS scene lifetime:"),
        "malformed scene lifetime marker",
    )
    allowed_scene_reasons = {
        "external-wait",
        "owner-release",
        "suspend",
        "shutdown",
        "final-destruction",
    }
    for match in scene_matches:
        reason, retained, released, live = match.groups()
        if match.start() < fired.start():
            continue
        require(reason in allowed_scene_reasons, f"unexpected post-fatal scene reason {reason}")
        require(
            (int(retained), int(released), int(live)) == (m, m, 0),
            f"post-fatal scene lifetime changed during {reason}",
        )

    lifecycle_matches = list(LIFECYCLE_RE.finditer(log))
    require(
        len(lifecycle_matches) == prefix_count(log, "RendererIOS lifecycle counters:"),
        "malformed lifecycle counter marker",
    )
    for match in lifecycle_matches:
        transition, idle, *values = match.groups()
        require(match.start() > delta.end(), "lifecycle counter precedes fatal tail")
        require(transition == "suspend-settled", f"unexpected lifecycle {transition}")
        require(idle == "1", "post-fatal suspend did not confirm idle")
        require(tuple(map(int, values)) == counters, "lifecycle counters changed")

    shutdown_matches = list(SHUTDOWN_RE.finditer(log))
    shutdown_delta_matches = list(SHUTDOWN_DELTA_RE.finditer(log))
    require(
        len(shutdown_matches) == prefix_count(log, "RendererIOS shutdown counters:"),
        "malformed shutdown counter marker",
    )
    require(
        len(shutdown_delta_matches)
        == prefix_count(log, "RendererIOS shutdown post-fatal delta:"),
        "malformed shutdown delta marker",
    )
    require(len(shutdown_matches) <= 1, "duplicate shutdown counters")
    require(len(shutdown_matches) == len(shutdown_delta_matches), "incomplete shutdown pair")
    if shutdown_matches:
        shutdown = shutdown_matches[0]
        shutdown_delta = shutdown_delta_matches[0]
        outcome, *values = shutdown.groups()
        require(outcome == "fatal", "shutdown outcome is not fatal")
        require(tuple(map(int, values)) == counters, "shutdown counters changed")
        require(shutdown.start() > delta.end(), "shutdown precedes fatal tail")
        require(shutdown_delta.start() > shutdown.end(), "shutdown delta precedes counters")
        require(
            tuple(map(int, shutdown_delta.groups())) == (0, 0, 0, 0),
            "shutdown delta is nonzero",
        )

    expected_lines = (
        fired.group(0),
        fatal.group(0),
        snapshot.group(0),
        stopped.group(0),
        scene.group(0),
        settled.group(0),
        delta.group(0),
    )
    denied_log = DANGEROUS_RE.search(scrub(log, expected_lines))
    denied_stderr = DANGEROUS_RE.search(scrub(stderr, expected_lines))
    require(
        denied_log is None,
        "unexpected fatal/crash signature in log"
        if denied_log is None
        else f"unexpected fatal/crash signature in log: {denied_log.group(0)!r}",
    )
    require(
        denied_stderr is None,
        "unexpected fatal/crash signature in stderr"
        if denied_stderr is None
        else f"unexpected fatal/crash signature in stderr: {denied_stderr.group(0)!r}",
    )

    return {
        "id3_expected_build": expected_build,
        "id3_expected_fault": expected_fault,
        "id3_nonce": expected_nonce,
        "id3_frames_in_flight": n,
        "id3_pre_request_presents": k,
        "id3_fatal_present": m,
        "id3_post_request_presents": m - k,
        "id3_request": 1,
        "id3_queued_count": 1,
        "id3_fired_count": 1,
        "id3_fatal_count": 1,
        "id3_scene_retained": m,
        "id3_scene_released": m,
        "id3_scene_live": 0,
        "id3_fatal_settled_idle_confirmed": 1,
        "id3_post_delta_submit_attempts": 0,
        "id3_post_delta_submit_accepted": 0,
        "id3_post_delta_present_attempts": 0,
        "id3_post_delta_present_accepted": 0,
        "id3_placeholder_accepted_count": 1,
        "id3_placeholder_completed_count": 1,
        "id3_placeholder_accepted_us": accepted_us,
        "id3_placeholder_serialize_us": serialize_us,
        "id3_placeholder_complete_us": complete_us,
    }


def write_summary(path: pathlib.Path, values: dict[str, int | str]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
    )


def fixture(build: str, nonce: str, n: int = 2, k: int = 3) -> str:
    m = k + n
    lines = [
        f"RendererIOS configured fault mode={FAULT_MODE}",
        "RendererIOS shell: version=1 profile=Safe features=native-landscape-textured,ui "
        f"build={build} gpu=Apple deviceFamily=iPhone16,2 iOS=26.6 "
        f"faultMode={FAULT_MODE} savePreviewRoute=gpu-diagnostic",
        f"RendererIOS diagnostics: ON frames-in-flight={n} context=IOSMetalContext transport=Tempest",
        f"RendererIOS fault injection armed: mode={FAULT_MODE} build={build}",
        f"RendererIOS preview fence save script: ARMED mode={SCRIPT_MODE} nonce={nonce} slot={SAVE_SLOT}",
    ]
    for present in range(1, k + 1):
        lines.append(
            f"RendererIOS runtime compilation: point=frame presents={present} "
            "available=1 source=0 compute=0 render=2"
        )
    lines.extend(
        [
            "[save] RendererIOS request: request=1 route=gpu-diagnostic",
            f"RendererIOS preview fence save script: REQUESTED mode={SCRIPT_MODE} nonce={nonce} slot={SAVE_SLOT} request=1",
            f"RendererIOS runtime compilation: point=frame presents={k + 1} available=1 source=0 compute=0 render=3",
            f"[save] RendererIOS preview queued: source=gpu-diagnostic slot={SAVE_SLOT} request=1",
        ]
    )
    for present in range(k + 2, m + 1):
        lines.append(
            f"RendererIOS runtime compilation: point=frame presents={present} "
            "available=1 source=0 compute=0 render=3"
        )
    lines.extend(
        [
            f"RendererIOS fault injection fired: mode={FAULT_MODE} point={FAULT_POINT} build={build}",
            FATAL_DETAIL,
            f"RendererIOS fatal snapshot: submit-attempts={m} submit-accepted={m} present-attempts={m} present-accepted={m}",
            STOPPED_DETAIL,
            f"RendererIOS scene lifetime: reason=external-wait retained={m} released={m} live=0",
            f"RendererIOS fatal settled: idle-confirmed=1 submit-attempts={m} submit-accepted={m} present-attempts={m} present-accepted={m}",
            "RendererIOS fatal post-delta: submit-attempts=0 submit-accepted=0 present-attempts=0 present-accepted=0",
            f"RendererIOS scene lifetime: reason=owner-release retained={m} released={m} live=0",
            f"[save] RendererIOS startSave accepted: source=placeholder slot={SAVE_SLOT} request=1 request-to-accepted-us=5000",
            f"[save] RendererIOS save completed: source=placeholder slot={SAVE_SLOT} request=1 serialize-us=2000 request-to-complete-us=8000",
        ]
    )
    return "\n".join(lines) + "\n"


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise AssertionError(f"fixture replacement is not unique: {old!r}")
    return text.replace(old, new, 1)


def self_test() -> None:
    build = "0123456789abcdef0123456789abcdef01234567"
    nonce = "0123456789abcdef0123456789abcdef"
    base = fixture(build, nonce)
    validate(base, "", build, nonce)
    validate(fixture(f"{build}-local", nonce, 3, 4), "", f"{build}-local", nonce)

    accepted = next(
        line for line in base.splitlines() if line.startswith("[save] RendererIOS startSave accepted:")
    )
    completed = next(
        line for line in base.splitlines() if line.startswith("[save] RendererIOS save completed:")
    )
    swapped = replace_once(base, accepted + "\n" + completed, completed + "\n" + accepted)
    validate(swapped, "", build, nonce)
    independent_timestamps = base.replace(
        "request-to-accepted-us=5000", "request-to-accepted-us=9000", 1
    )
    validate(independent_timestamps, "", build, nonce)

    lifecycle = (
        "RendererIOS lifecycle counters: transition=suspend-settled idle-confirmed=1 "
        "submit-attempts=5 submit-accepted=5 present-attempts=5 present-accepted=5"
    )
    shutdown = (
        "RendererIOS shutdown counters: outcome=fatal submit-attempts=5 "
        "submit-accepted=5 present-attempts=5 present-accepted=5"
    )
    shutdown_delta = (
        "RendererIOS shutdown post-fatal delta: submit-attempts=0 submit-accepted=0 "
        "present-attempts=0 present-accepted=0"
    )
    valid_terminal = base + lifecycle + "\n" + shutdown + "\n" + shutdown_delta + "\n"
    validate(valid_terminal, "", build, nonce)

    mirrored = "\n".join(
        line
        for line in base.splitlines()
        if line.startswith(
            (
                "RendererIOS fault injection fired:",
                FATAL_DETAIL,
                "RendererIOS fatal snapshot:",
                STOPPED_DETAIL,
                "RendererIOS fatal settled:",
                "RendererIOS fatal post-delta:",
            )
        )
    )
    validate(base, mirrored, build, nonce)

    request = "[save] RendererIOS request: request=1 route=gpu-diagnostic"
    script_armed = f"RendererIOS preview fence save script: ARMED mode={SCRIPT_MODE} nonce={nonce} slot={SAVE_SLOT}"
    script_requested = f"RendererIOS preview fence save script: REQUESTED mode={SCRIPT_MODE} nonce={nonce} slot={SAVE_SLOT} request=1"
    queued = f"[save] RendererIOS preview queued: source=gpu-diagnostic slot={SAVE_SLOT} request=1"
    fired = f"RendererIOS fault injection fired: mode={FAULT_MODE} point={FAULT_POINT} build={build}"
    snapshot = "RendererIOS fatal snapshot: submit-attempts=5 submit-accepted=5 present-attempts=5 present-accepted=5"
    delta = "RendererIOS fatal post-delta: submit-attempts=0 submit-accepted=0 present-attempts=0 present-accepted=0"
    mutations = {
        "missing-configured": base.replace(f"RendererIOS configured fault mode={FAULT_MODE}\n", "", 1),
        "wrong-build": base.replace(f"build={build}", f"build={'f' * 40}", 1),
        "wrong-route": base.replace("savePreviewRoute=gpu-diagnostic", "savePreviewRoute=cpu-placeholder", 1),
        "wrong-nonce": base.replace(f"nonce={nonce}", f"nonce={'f' * 32}", 1),
        "wrong-requested-nonce-only": replace_once(base, script_requested, script_requested.replace(nonce, "f" * 32)),
        "duplicate-script-armed": replace_once(base, script_armed + "\n", (script_armed + "\n") * 2),
        "malformed-script-armed": replace_once(base, script_armed, script_armed.replace("nonce=", "nonce=x")),
        "duplicate-script-requested": replace_once(base, script_requested + "\n", (script_requested + "\n") * 2),
        "malformed-script-requested": replace_once(base, script_requested, script_requested.replace("request=1", "request=x")),
        "duplicate-request": replace_once(base, request + "\n", request + "\n" + request + "\n"),
        "request-two": base.replace("request: request=1", "request: request=2", 1),
        "missing-queued": replace_once(base, queued + "\n", ""),
        "duplicate-queued": replace_once(base, queued + "\n", (queued + "\n") * 2),
        "malformed-queued": replace_once(base, queued, queued.replace("request=1", "request=x")),
        "queued-wrong-slot": base.replace(f"queued: source=gpu-diagnostic slot={SAVE_SLOT}", "queued: source=gpu-diagnostic slot=save_slot_19.sav", 1),
        "wrong-fired-point": base.replace(f"point={FAULT_POINT}", "point=preview-before-terminal", 1),
        "duplicate-fired": replace_once(base, fired + "\n", fired + "\n" + fired + "\n"),
        "missing-fatal": replace_once(
            base,
            fired + "\n" + FATAL_DETAIL + "\n" + snapshot,
            fired + "\n" + snapshot,
        ),
        "snapshot-unequal": base.replace(snapshot, snapshot.replace("submit-attempts=5", "submit-attempts=6"), 1),
        "settled-m-not-snapshot": base.replace("fatal settled: idle-confirmed=1 submit-attempts=5", "fatal settled: idle-confirmed=1 submit-attempts=6", 1),
        "scene-leak": base.replace("reason=external-wait retained=5 released=5 live=0", "reason=external-wait retained=5 released=4 live=1", 1),
        "settled-idle-zero": base.replace("fatal settled: idle-confirmed=1", "fatal settled: idle-confirmed=0", 1),
        "delta-growth": base.replace(delta, delta.replace("present-accepted=0", "present-accepted=1"), 1),
        "accepted-preview": base.replace("startSave accepted: source=placeholder", "startSave accepted: source=preview", 1),
        "duplicate-accepted": replace_once(base, accepted + "\n", (accepted + "\n") * 2),
        "malformed-accepted": replace_once(base, accepted, accepted.replace("request-to-accepted-us=5000", "request-to-accepted-us=x")),
        "completed-preview": base.replace("save completed: source=placeholder", "save completed: source=preview", 1),
        "duplicate-completed": replace_once(base, completed + "\n", (completed + "\n") * 2),
        "malformed-completed": replace_once(base, completed, completed.replace("serialize-us=2000", "serialize-us=x")),
        "completed-wrong-request": base.replace("save completed: source=placeholder slot=save_slot_20.sav request=1", "save completed: source=placeholder slot=save_slot_20.sav request=2", 1),
        "bad-completion-timing": base.replace("serialize-us=2000 request-to-complete-us=8000", "serialize-us=9000 request-to-complete-us=8000", 1),
        "deferred": base + "[save] RendererIOS startSave deferred: source=placeholder slot=save_slot_20.sav request=1 request-elapsed-us=1 stage=ready-cpu reason=loader-start-not-accepted\n",
        "script-fail": base + f"RendererIOS preview fence save script: SCRIPT FAIL mode={SCRIPT_MODE} nonce={nonce} slot={SAVE_SLOT} state=WAIT_WORLD reason=timeout\n",
        "present-gap": base.replace("point=frame presents=4 available=1 source=0 compute=0 render=3\n", "", 1),
        "render-counter-regression": base.replace(
            "point=frame presents=5 available=1 source=0 compute=0 render=3",
            "point=frame presents=5 available=1 source=0 compute=0 render=2",
            1,
        ),
        "present-after-fired": replace_once(base, fired + "\n", fired + "\nRendererIOS runtime compilation: point=frame presents=6 available=1 source=0 compute=0 render=3\n"),
        "too-many-post-request-presents": replace_once(base, fired + "\n", "RendererIOS runtime compilation: point=frame presents=6 available=1 source=0 compute=0 render=3\n" + fired + "\n").replace("submit-attempts=5 submit-accepted=5 present-attempts=5 present-accepted=5", "submit-attempts=6 submit-accepted=6 present-attempts=6 present-accepted=6"),
        "queued-before-request": replace_once(
            replace_once(base, queued + "\n", ""),
            request + "\n",
            queued + "\n" + request + "\n",
        ),
        "queued-after-second-post-request-present": replace_once(
            replace_once(base, queued + "\n", ""),
            fired + "\n",
            queued + "\n" + fired + "\n",
        ),
        "fired-before-queued": replace_once(
            replace_once(base, fired + "\n", ""),
            queued + "\n",
            fired + "\n" + queued + "\n",
        ),
        "snapshot-before-fatal": replace_once(base, FATAL_DETAIL + "\n" + snapshot, snapshot + "\n" + FATAL_DETAIL),
        "settled-before-scene": replace_once(base, f"RendererIOS scene lifetime: reason=external-wait retained=5 released=5 live=0\nRendererIOS fatal settled:", "RendererIOS fatal settled:").replace("RendererIOS fatal post-delta:", "RendererIOS scene lifetime: reason=external-wait retained=5 released=5 live=0\nRendererIOS fatal post-delta:", 1),
        "resume-after-fatal": base + "RendererIOS app lifecycle: did-become-active resumed=1 viewport=852x393\n",
        "lifecycle-counter-growth": base + lifecycle.replace("submit-attempts=5", "submit-attempts=6") + "\n",
        "lifecycle-resume": base + lifecycle.replace("suspend-settled", "resume-settled") + "\n",
        "shutdown-clean": valid_terminal.replace("shutdown counters: outcome=fatal", "shutdown counters: outcome=clean", 1),
        "shutdown-delta-growth": valid_terminal.replace("shutdown post-fatal delta: submit-attempts=0", "shutdown post-fatal delta: submit-attempts=1", 1),
        "shutdown-missing-delta": replace_once(valid_terminal, shutdown_delta + "\n", ""),
        "loader-failure": base + "unable to start load/save: resource unavailable\n",
        "preview-allocation-failure": base + "save preview allocation failed\n",
        "empty-preview-allocation": base + "allocation returned an empty image\n",
        "dangerous-stderr": base,
        "fatal-suffix-stderr": base,
    }
    survived: list[str] = []
    for name, mutated in mutations.items():
        try:
            if name == "dangerous-stderr":
                validate(base, "SIGABRT\n", build, nonce)
            elif name == "fatal-suffix-stderr":
                validate(base, FATAL_DETAIL + " unexpected-suffix\n", build, nonce)
            else:
                validate(mutated, "", build, nonce)
        except ValidationError:
            continue
        survived.append(name)
    require(not survived, f"mutation self-test survivors: {survived}")
    print(f"preview-fence validator self-test passed: {len(mutations)} mutations killed")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-fault", default=FAULT_MODE)
    parser.add_argument("--nonce")
    parser.add_argument("--summary", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return args
    required = (args.log, args.expected_build, args.nonce, args.summary)
    if any(value is None for value in required):
        parser.error("--log, --expected-build, --nonce and --summary are required")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    assert args.log is not None
    assert args.expected_build is not None
    assert args.nonce is not None
    assert args.summary is not None
    log = args.log.read_text(errors="replace")
    stderr = args.stderr.read_text(errors="replace") if args.stderr else ""
    try:
        values = validate(log, stderr, args.expected_build, args.nonce, args.expected_fault)
    except ValidationError as error:
        print(f"ID3 preview-fence validation failed: {error}", file=sys.stderr)
        return 1
    write_summary(args.summary, values)
    print(
        "ID3 preview-fence validation passed: "
        f"M={values['id3_fatal_present']} request=1 placeholder-complete=1"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
