#!/usr/bin/env python3
"""Validate the canonical RendererIOS ID4 terminal frame-fence fault log."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


FAULT_MODE = "frame-fence-error-after-terminal"
FAULT_POINT = "frame-fence-after-terminal"
FATAL_DETAIL = (
    "RendererIOS Metal frame fence failed: RendererIOS diagnostics injected "
    "a terminal frame-fence error"
)
STOPPED_DETAIL = f"RendererIOS stopped the frame loop: {FATAL_DETAIL}"

SHELL_RE = re.compile(
    r"^RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*$",
    re.MULTILINE,
)
CONFIGURED_FAULT_RE = re.compile(
    r"^RendererIOS configured fault mode=([^\s]+)$",
    re.MULTILINE,
)
DIAGNOSTICS_RE = re.compile(
    r"^RendererIOS diagnostics: ON frames-in-flight=(\d+) "
    r"context=IOSMetalContext transport=Tempest$",
    re.MULTILINE,
)
ARMED_RE = re.compile(
    r"^RendererIOS fault injection armed: mode=([^\s]+) build=([^\s]+)$",
    re.MULTILINE,
)
FIRED_RE = re.compile(
    r"^RendererIOS fault injection fired: mode=([^\s]+) "
    r"point=([^\s]+) build=([^\s]+)$",
    re.MULTILINE,
)
PRESENT_RE = re.compile(
    r"^RendererIOS runtime compilation: point=frame presents=(\d+) "
    r"available=(\d+) source=(\d+) compute=(\d+) render=(\d+)$",
    re.MULTILINE,
)
FATAL_RE = re.compile(rf"^{re.escape(FATAL_DETAIL)}$", re.MULTILINE)
SNAPSHOT_RE = re.compile(
    r"^RendererIOS fatal snapshot: submit-attempts=(\d+) "
    r"submit-accepted=(\d+) present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
STOPPED_RE = re.compile(rf"^{re.escape(STOPPED_DETAIL)}$", re.MULTILINE)
SCENE_RE = re.compile(
    r"^RendererIOS scene lifetime: reason=external-wait retained=(\d+) "
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
POST_FAULT_LIFECYCLE_RE = re.compile(
    r"^RendererIOS lifecycle counters: transition=([^\s]+) idle-confirmed=(\d+) "
    r"submit-attempts=(\d+) submit-accepted=(\d+) "
    r"present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
POST_FAULT_SHUTDOWN_RE = re.compile(
    r"^RendererIOS shutdown counters: outcome=([^\s]+) "
    r"submit-attempts=(\d+) submit-accepted=(\d+) "
    r"present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
POST_FAULT_SHUTDOWN_DELTA_RE = re.compile(
    r"^RendererIOS shutdown post-fatal delta: submit-attempts=(\d+) "
    r"submit-accepted=(\d+) present-attempts=(\d+) present-accepted=(\d+)$",
    re.MULTILINE,
)
DANGEROUS_RE = re.compile(
    r"RendererIOS (?:fatal:|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed|"
    r"resume swapchain reset failed|native Landscape encode failed|"
    r"IOSGPUScene metallib loading failed|Metal (?:save-preview )?frame fence failed)|"
    r"swapchain reset failed|reset renderer failed|"
    r"libc\+\+abi: terminating|SIGABRT|EXC_BAD_ACCESS|AddressSanitizer|"
    r"ThreadSanitizer|UndefinedBehaviorSanitizer|DeviceLostException|"
    r"DeviceHangException|device[- ]lost|out[- ]of[- ]memory|\bOOM\b|"
    r"\btimeout\b|timed out|unhandled (?:non-std/ObjC )?exception in render loop|"
    r"uncaught exception|\babort(?:ed)?\b|\bterminat(?:e|ed|ing)\b|terminate called|"
    r"terminating without C\+\+ teardown|"
    r"std::terminate|jetsam",
    re.IGNORECASE,
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def one_match(log: str, pattern: re.Pattern[str], name: str) -> re.Match[str]:
    matches = list(pattern.finditer(log))
    require(len(matches) == 1, f"expected exactly one {name}, found {len(matches)}")
    return matches[0]


def require_exact_marker_count(log: str, prefix: str, expected: int = 1) -> None:
    count = sum(line.startswith(prefix) for line in log.splitlines())
    require(count == expected, f"expected {expected} {prefix!r} marker(s), found {count}")


def scrub_expected(text: str, expected_lines: tuple[str, ...]) -> str:
    for line in sorted(expected_lines, key=len, reverse=True):
        text = text.replace(line, "")
    return text


def validate(
    log: str,
    stderr: str,
    expected_build: str,
    expected_fault: str = FAULT_MODE,
) -> dict[str, int | str]:
    require(
        re.fullmatch(r"[0-9a-f]{40}(?:-local)?", expected_build) is not None,
        "expected build must be a 40-character lowercase SHA, optionally suffixed -local",
    )
    require(expected_fault == FAULT_MODE, f"unsupported fault oracle: {expected_fault}")

    prefixes = (
        "RendererIOS configured fault mode=",
        "RendererIOS shell: version=",
        "RendererIOS diagnostics:",
        "RendererIOS fault injection armed:",
        "RendererIOS fault injection fired:",
        FATAL_DETAIL,
        "RendererIOS fatal snapshot:",
        STOPPED_DETAIL,
        "RendererIOS scene lifetime: reason=external-wait",
        "RendererIOS fatal settled:",
        "RendererIOS fatal post-delta:",
    )
    for prefix in prefixes:
        require_exact_marker_count(log, prefix)

    configured = one_match(log, CONFIGURED_FAULT_RE, "configured fault marker")
    require(configured.group(1) == expected_fault, "configured fault mode is not exact")
    shell = one_match(log, SHELL_RE, "RendererIOS shell marker")
    require(shell.group(1) == expected_build, "RendererIOS shell build is not exact")
    diagnostics = one_match(log, DIAGNOSTICS_RE, "diagnostics ON marker")
    frames_in_flight = int(diagnostics.group(1))
    require(frames_in_flight in (2, 3), "frames-in-flight must be exactly 2 or 3")
    armed = one_match(log, ARMED_RE, "fault armed marker")
    require(
        armed.groups() == (expected_fault, expected_build),
        "fault armed mode/build is not exact",
    )

    presents = [
        (match.start(),) + tuple(map(int, match.groups()))
        for match in PRESENT_RE.finditer(log)
    ]
    present_prefix_count = sum(
        line.startswith("RendererIOS runtime compilation: point=frame ")
        for line in log.splitlines()
    )
    require(len(presents) == present_prefix_count, "malformed runtime present marker")
    require(len(presents) == frames_in_flight, "present count does not match frames-in-flight")
    present_numbers = [present for _, present, *_ in presents]
    require(
        present_numbers == list(range(1, frames_in_flight + 1)),
        "pre-fault present sequence must be exactly 1..frames-in-flight",
    )
    first_totals: tuple[int, int, int] | None = None
    for _, present, available, source, compute, render in presents:
        require(available == 1, f"runtime counters unavailable at present {present}")
        require(source == 0 and compute == 0, f"runtime compilation grew at present {present}")
        require(render in (2, 3), f"unexpected render count at present {present}")
        totals = (source, compute, render)
        if first_totals is None:
            first_totals = totals
        require(totals == first_totals, f"runtime counters grew at present {present}")

    fired = one_match(log, FIRED_RE, "fault fired marker")
    require(
        fired.groups() == (expected_fault, FAULT_POINT, expected_build),
        "fault fired mode/point/build is not exact",
    )
    fatal = one_match(log, FATAL_RE, "expected frame-fence fatal")
    snapshot = one_match(log, SNAPSHOT_RE, "fatal snapshot")
    stopped = one_match(log, STOPPED_RE, "stopped-loop marker")
    scene = one_match(log, SCENE_RE, "external-wait scene lifetime")
    settled = one_match(log, SETTLED_RE, "fatal-settled marker")
    delta = one_match(log, DELTA_RE, "fatal post-delta marker")

    expected_counters = (frames_in_flight,) * 4
    require(
        tuple(map(int, snapshot.groups())) == expected_counters,
        "fatal snapshot counters do not equal frames-in-flight",
    )
    require(
        tuple(map(int, scene.groups())) == (frames_in_flight, frames_in_flight, 0),
        "scene lifetime does not prove balanced release and live=0",
    )
    require(
        tuple(map(int, settled.groups())) == (1,) + expected_counters,
        "fatal-settled does not prove idle=1 with stable counters",
    )
    require(tuple(map(int, delta.groups())) == (0, 0, 0, 0), "post-fatal delta is nonzero")

    ordered_positions = (
        configured.start(),
        shell.start(),
        diagnostics.start(),
        armed.start(),
        *(position for position, *_ in presents),
        fired.start(),
        fatal.start(),
        snapshot.start(),
        stopped.start(),
        scene.start(),
        settled.start(),
        delta.start(),
    )
    require(
        ordered_positions == tuple(sorted(ordered_positions)),
        "ID4 frame-fence markers are out of order",
    )
    require(len(set(ordered_positions)) == len(ordered_positions), "ID4 markers overlap")

    after_fired = log[fired.end() :]
    post_fault_present_count = len(list(PRESENT_RE.finditer(after_fired)))
    resume_settled_count = sum(
        line.startswith("RendererIOS lifecycle counters: transition=resume-settled ")
        for line in after_fired.splitlines()
    )
    resumed_one_count = len(re.findall(r"\bresumed=1(?:\s|$)", after_fired))
    require(post_fault_present_count == 0, "a present occurred after the fault fired")
    require(
        "RendererIOS shell: 300 present calls submitted" not in after_fired,
        "300-present healthy marker occurred after the fault fired",
    )
    require(resume_settled_count == 0, "resume-settled occurred after fatal")
    require(resumed_one_count == 0, "renderer resumed after fatal")
    lifecycle_matches = list(POST_FAULT_LIFECYCLE_RE.finditer(log))
    lifecycle_prefix_count = sum(
        line.startswith("RendererIOS lifecycle counters:")
        for line in log.splitlines()
    )
    require(
        len(lifecycle_matches) == lifecycle_prefix_count,
        "malformed post-fatal lifecycle counter marker",
    )
    for counter_match in lifecycle_matches:
        transition, idle_confirmed, *counter_groups = counter_match.groups()
        require(
            counter_match.start() > delta.end(),
            "post-fatal lifecycle counters precede the canonical fatal tail",
        )
        require(
            transition == "suspend-settled",
            f"unexpected lifecycle transition after fatal: {transition}",
        )
        require(idle_confirmed == "1", f"{transition} did not confirm device idle")
        require(
            tuple(map(int, counter_groups)) == expected_counters,
            f"absolute submission counters changed after fatal during {transition}",
        )

    shutdown_matches = list(POST_FAULT_SHUTDOWN_RE.finditer(log))
    shutdown_prefix_count = sum(
        line.startswith("RendererIOS shutdown counters:")
        for line in log.splitlines()
    )
    require(
        len(shutdown_matches) == shutdown_prefix_count,
        "malformed post-fatal shutdown counter marker",
    )
    for counter_match in shutdown_matches:
        outcome, *counter_groups = counter_match.groups()
        require(outcome == "fatal", f"unexpected post-fatal shutdown outcome: {outcome}")
        require(
            tuple(map(int, counter_groups)) == expected_counters,
            "absolute submission counters changed during post-fatal shutdown",
        )

    shutdown_delta_matches = list(POST_FAULT_SHUTDOWN_DELTA_RE.finditer(log))
    shutdown_delta_prefix_count = sum(
        line.startswith("RendererIOS shutdown post-fatal delta:")
        for line in log.splitlines()
    )
    require(
        len(shutdown_delta_matches) == shutdown_delta_prefix_count,
        "malformed shutdown post-fatal delta marker",
    )
    require(shutdown_prefix_count <= 1, "duplicate post-fatal shutdown counters")
    require(
        shutdown_delta_prefix_count == shutdown_prefix_count,
        "post-fatal shutdown counters/delta markers are incomplete",
    )
    if shutdown_matches:
        shutdown_match = shutdown_matches[0]
        shutdown_delta_match = shutdown_delta_matches[0]
        require(
            shutdown_match.start() > delta.end(),
            "shutdown counters precede the canonical fatal tail",
        )
        require(
            all(match.start() < shutdown_match.start() for match in lifecycle_matches),
            "lifecycle counters occurred after shutdown began",
        )
        require(
            shutdown_delta_match.start() > shutdown_match.end(),
            "shutdown post-fatal delta precedes shutdown counters",
        )
    for delta_match in shutdown_delta_matches:
        require(
            tuple(map(int, delta_match.groups())) == (0, 0, 0, 0),
            "shutdown post-fatal delta is nonzero",
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
    denied_log = DANGEROUS_RE.search(scrub_expected(log, expected_lines))
    require(
        denied_log is None,
        "unexpected fatal/crash signature in log"
        if denied_log is None
        else f"unexpected fatal/crash signature in log: {denied_log.group(0)!r}",
    )
    denied_stderr = DANGEROUS_RE.search(scrub_expected(stderr, expected_lines))
    require(
        denied_stderr is None,
        "unexpected fatal/crash signature in stderr"
        if denied_stderr is None
        else f"unexpected fatal/crash signature in stderr: {denied_stderr.group(0)!r}",
    )

    return {
        "id4_expected_build": expected_build,
        "id4_expected_fault": expected_fault,
        "id4_frames_in_flight": frames_in_flight,
        "id4_configured_count": 1,
        "id4_armed_count": 1,
        "id4_fired_count": 1,
        "id4_first_present": present_numbers[0],
        "id4_last_present": present_numbers[-1],
        "id4_present_count": len(present_numbers),
        "id4_post_fault_present_count": post_fault_present_count,
        "id4_fatal_count": 1,
        "id4_fatal_snapshot_submit_attempts": frames_in_flight,
        "id4_fatal_snapshot_submit_accepted": frames_in_flight,
        "id4_fatal_snapshot_present_attempts": frames_in_flight,
        "id4_fatal_snapshot_present_accepted": frames_in_flight,
        "id4_stopped_loop_count": 1,
        "id4_scene_retained": frames_in_flight,
        "id4_scene_released": frames_in_flight,
        "id4_scene_live": 0,
        "id4_fatal_settled_idle_confirmed": 1,
        "id4_fatal_settled_submit_attempts": frames_in_flight,
        "id4_fatal_settled_submit_accepted": frames_in_flight,
        "id4_fatal_settled_present_attempts": frames_in_flight,
        "id4_fatal_settled_present_accepted": frames_in_flight,
        "id4_post_delta_submit_attempts": 0,
        "id4_post_delta_submit_accepted": 0,
        "id4_post_delta_present_attempts": 0,
        "id4_post_delta_present_accepted": 0,
        "id4_resume_settled_count": resume_settled_count,
        "id4_resumed_one_count": resumed_one_count,
    }


def write_summary(path: pathlib.Path, values: dict[str, int | str]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
    )


def fixture(build: str, frames_in_flight: int) -> str:
    counter_values = f"{frames_in_flight}"
    lines = [
        f"RendererIOS configured fault mode={FAULT_MODE}",
        "RendererIOS shell: version=1 profile=Safe features=native-landscape-textured,ui "
        f"build={build} gpu=Apple deviceFamily=iPhone16,2 iOS=26.6 "
        f"faultMode={FAULT_MODE} savePreviewRoute=cpu-placeholder",
        f"RendererIOS diagnostics: ON frames-in-flight={frames_in_flight} "
        "context=IOSMetalContext transport=Tempest",
        f"RendererIOS fault injection armed: mode={FAULT_MODE} build={build}",
    ]
    for present in range(1, frames_in_flight + 1):
        lines.append(
            "RendererIOS runtime compilation: point=frame "
            f"presents={present} available=1 source=0 compute=0 render=2"
        )
    lines.extend(
        [
            f"RendererIOS fault injection fired: mode={FAULT_MODE} "
            f"point={FAULT_POINT} build={build}",
            FATAL_DETAIL,
            "RendererIOS fatal snapshot: "
            f"submit-attempts={counter_values} submit-accepted={counter_values} "
            f"present-attempts={counter_values} present-accepted={counter_values}",
            STOPPED_DETAIL,
            "RendererIOS scene lifetime: reason=external-wait "
            f"retained={counter_values} released={counter_values} live=0",
            "RendererIOS fatal settled: idle-confirmed=1 "
            f"submit-attempts={counter_values} submit-accepted={counter_values} "
            f"present-attempts={counter_values} present-accepted={counter_values}",
            "RendererIOS fatal post-delta: submit-attempts=0 submit-accepted=0 "
            "present-attempts=0 present-accepted=0",
        ]
    )
    return "\n".join(lines) + "\n"


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise AssertionError(f"self-test fixture replacement is not unique: {old!r}")
    return text.replace(old, new, 1)


def self_test() -> None:
    build = "0123456789abcdef0123456789abcdef01234567"
    local_build = f"{build}-local"
    base = fixture(build, 3)
    base_two = fixture(build, 2)
    local = fixture(local_build, 2)
    wrapped_shell = replace_once(
        base,
        f"faultMode={FAULT_MODE}",
        "faultMode=frame-fence-error-after-\nterminal",
    )
    mirrored_stderr = "\n".join(
        line
        for line in base.splitlines()
        if line.startswith(
            (
                "RendererIOS fault injection fired:",
                FATAL_DETAIL,
                "RendererIOS fatal snapshot:",
                STOPPED_DETAIL,
                "RendererIOS scene lifetime:",
                "RendererIOS fatal settled:",
                "RendererIOS fatal post-delta:",
            )
        )
    ) + "\n"

    values_three = validate(base, mirrored_stderr, build)
    values_two = validate(base_two, "", build)
    validate(local, "", local_build)
    validate(wrapped_shell, mirrored_stderr, build)
    require(values_three["id4_frames_in_flight"] == 3, "N=3 summary is wrong")
    require(values_three["id4_last_present"] == 3, "N=3 present summary is wrong")
    require(values_two["id4_frames_in_flight"] == 2, "N=2 summary is wrong")
    require(values_two["id4_scene_released"] == 2, "N=2 scene summary is wrong")

    configured = f"RendererIOS configured fault mode={FAULT_MODE}\n"
    shell = next(line for line in base.splitlines() if line.startswith("RendererIOS shell:"))
    diagnostics = (
        "RendererIOS diagnostics: ON frames-in-flight=3 "
        "context=IOSMetalContext transport=Tempest"
    )
    armed = f"RendererIOS fault injection armed: mode={FAULT_MODE} build={build}"
    fired = (
        f"RendererIOS fault injection fired: mode={FAULT_MODE} "
        f"point={FAULT_POINT} build={build}"
    )
    present_two = (
        "RendererIOS runtime compilation: point=frame presents=2 "
        "available=1 source=0 compute=0 render=2"
    )
    present_three = present_two.replace("presents=2", "presents=3")
    snapshot = (
        "RendererIOS fatal snapshot: submit-attempts=3 submit-accepted=3 "
        "present-attempts=3 present-accepted=3"
    )
    scene = "RendererIOS scene lifetime: reason=external-wait retained=3 released=3 live=0"
    settled = (
        "RendererIOS fatal settled: idle-confirmed=1 submit-attempts=3 "
        "submit-accepted=3 present-attempts=3 present-accepted=3"
    )
    delta = (
        "RendererIOS fatal post-delta: submit-attempts=0 submit-accepted=0 "
        "present-attempts=0 present-accepted=0"
    )
    lifecycle = (
        "RendererIOS lifecycle counters: transition=suspend-settled idle-confirmed=1 "
        "submit-attempts=3 submit-accepted=3 present-attempts=3 present-accepted=3"
    )
    shutdown = (
        "RendererIOS shutdown counters: outcome=fatal submit-attempts=3 "
        "submit-accepted=3 present-attempts=3 present-accepted=3"
    )
    shutdown_delta = (
        "RendererIOS shutdown post-fatal delta: submit-attempts=0 submit-accepted=0 "
        "present-attempts=0 present-accepted=0"
    )
    valid_post_fault_settle = base + lifecycle + "\n" + shutdown + "\n" + shutdown_delta + "\n"
    validate(valid_post_fault_settle, mirrored_stderr, build)

    replacements = {
        "missing-configured": replace_once(base, configured, ""),
        "duplicate-configured": replace_once(base, configured, configured * 2),
        "wrong-configured": replace_once(base, configured, "RendererIOS configured fault mode=none\n"),
        "missing-shell": replace_once(base, shell + "\n", ""),
        "duplicate-shell": replace_once(base, shell + "\n", (shell + "\n") * 2),
        "wrong-shell-build": replace_once(
            base,
            shell + "\n",
            shell.replace(f"build={build}", f"build={'f' * 40}") + "\n",
        ),
        "missing-diagnostics": replace_once(base, diagnostics + "\n", ""),
        "duplicate-diagnostics": replace_once(base, diagnostics + "\n", (diagnostics + "\n") * 2),
        "wrong-diagnostics-n": replace_once(base, "frames-in-flight=3", "frames-in-flight=4"),
        "missing-armed": replace_once(base, armed + "\n", ""),
        "duplicate-armed": replace_once(base, armed + "\n", (armed + "\n") * 2),
        "wrong-armed-mode": replace_once(base, f"armed: mode={FAULT_MODE}", "armed: mode=none"),
        "missing-fired": replace_once(base, fired + "\n", ""),
        "duplicate-fired": replace_once(base, fired + "\n", (fired + "\n") * 2),
        "wrong-fired-point": replace_once(base, f"point={FAULT_POINT}", "point=before-submit"),
        "missing-fatal": replace_once(
            base,
            fired + "\n" + FATAL_DETAIL + "\n" + snapshot,
            fired + "\n" + snapshot,
        ),
        "duplicate-fatal": replace_once(
            base,
            fired + "\n" + FATAL_DETAIL + "\n" + snapshot,
            fired + "\n" + FATAL_DETAIL + "\n" + FATAL_DETAIL + "\n" + snapshot,
        ),
        "wrong-fatal-detail": replace_once(
            base,
            fired + "\n" + FATAL_DETAIL + "\n" + snapshot,
            fired
            + "\n"
            + FATAL_DETAIL.replace(
                "a terminal frame-fence error", "a wrong frame-fence error"
            )
            + "\n"
            + snapshot,
        ),
        "missing-snapshot": replace_once(base, snapshot + "\n", ""),
        "duplicate-snapshot": replace_once(base, snapshot + "\n", (snapshot + "\n") * 2),
        "snapshot-n-plus-one": replace_once(base, "fatal snapshot: submit-attempts=3", "fatal snapshot: submit-attempts=4"),
        "snapshot-n-minus-one": replace_once(base, "present-accepted=3\n" + STOPPED_DETAIL, "present-accepted=2\n" + STOPPED_DETAIL),
        "missing-stopped": replace_once(base, STOPPED_DETAIL + "\n", ""),
        "duplicate-stopped": replace_once(base, STOPPED_DETAIL + "\n", (STOPPED_DETAIL + "\n") * 2),
        "wrong-stopped-detail": replace_once(base, STOPPED_DETAIL, STOPPED_DETAIL + " unexpected"),
        "missing-scene": replace_once(base, scene + "\n", ""),
        "duplicate-scene": replace_once(base, scene + "\n", (scene + "\n") * 2),
        "wrong-scene-reason": replace_once(base, "reason=external-wait", "reason=suspend"),
        "scene-retained-n-plus-one": replace_once(base, "retained=3 released=3", "retained=4 released=3"),
        "scene-released-n-minus-one": replace_once(base, "retained=3 released=3", "retained=3 released=2"),
        "scene-live-one": replace_once(base, "released=3 live=0", "released=3 live=1"),
        "missing-settled": replace_once(base, settled + "\n", ""),
        "duplicate-settled": replace_once(base, settled + "\n", (settled + "\n") * 2),
        "settled-idle-zero": replace_once(base, "fatal settled: idle-confirmed=1", "fatal settled: idle-confirmed=0"),
        "settled-n-plus-one": replace_once(base, "fatal settled: idle-confirmed=1 submit-attempts=3", "fatal settled: idle-confirmed=1 submit-attempts=4"),
        "missing-delta": replace_once(base, delta + "\n", ""),
        "duplicate-delta": replace_once(base, delta + "\n", (delta + "\n") * 2),
        "delta-submit-attempts-one": replace_once(base, "post-delta: submit-attempts=0", "post-delta: submit-attempts=1"),
        "delta-submit-accepted-one": replace_once(base, "post-delta: submit-attempts=0 submit-accepted=0", "post-delta: submit-attempts=0 submit-accepted=1"),
        "delta-present-attempts-one": replace_once(base, "submit-accepted=0 present-attempts=0", "submit-accepted=0 present-attempts=1"),
        "delta-present-accepted-one": replace_once(base, "present-attempts=0 present-accepted=0", "present-attempts=0 present-accepted=1"),
        "shell-before-configured": replace_once(base, configured + shell + "\n", shell + "\n" + configured),
        "armed-after-presents": replace_once(base, armed + "\n", "") .replace(present_three + "\n", present_three + "\n" + armed + "\n", 1),
        "fired-before-last-present": replace_once(base, present_three + "\n" + fired, fired + "\n" + present_three),
        "snapshot-before-fatal": replace_once(base, FATAL_DETAIL + "\n" + snapshot, snapshot + "\n" + FATAL_DETAIL),
        "scene-before-stopped": replace_once(base, STOPPED_DETAIL + "\n" + scene, scene + "\n" + STOPPED_DETAIL),
        "settled-before-scene": replace_once(base, scene + "\n" + settled, settled + "\n" + scene),
        "delta-before-settled": replace_once(base, settled + "\n" + delta, delta + "\n" + settled),
        "present-gap": replace_once(base, present_two + "\n", ""),
        "present-duplicate": replace_once(base, present_two + "\n", (present_two + "\n") * 2),
        "present-extra-before-fired": replace_once(base, fired, present_three.replace("presents=3", "presents=4") + "\n" + fired),
        "present-after-fired": replace_once(base, fired + "\n", fired + "\n" + present_three.replace("presents=3", "presents=4") + "\n"),
        "healthy-300-after-fired": replace_once(base, fired + "\n", fired + "\nRendererIOS shell: 300 present calls submitted\n"),
        "counter-growth-after-fired": replace_once(base, delta + "\n", delta + "\nRendererIOS lifecycle counters: transition=suspend-settled idle-confirmed=1 submit-attempts=4 submit-accepted=3 present-attempts=3 present-accepted=3\n"),
        "lifecycle-idle-unconfirmed-after-fired": base
        + lifecycle.replace("idle-confirmed=1", "idle-confirmed=0")
        + "\n",
        "lifecycle-before-fatal": replace_once(
            base, fired + "\n", fired + "\n" + lifecycle + "\n"
        ),
        "lifecycle-before-fired": replace_once(
            base, armed + "\n", armed + "\n" + lifecycle + "\n"
        ),
        "unknown-lifecycle-after-fired": base
        + lifecycle.replace("transition=suspend-settled", "transition=unknown-settled")
        + "\n",
        "malformed-lifecycle-after-fired": base
        + lifecycle.replace("idle-confirmed=1", "idle-confirmed=unknown")
        + "\n",
        "resume-settled-after-fired": replace_once(base, delta + "\n", delta + "\nRendererIOS lifecycle counters: transition=resume-settled idle-confirmed=1 submit-attempts=3 submit-accepted=3 present-attempts=3 present-accepted=3\n"),
        "resumed-one-after-fired": replace_once(base, delta + "\n", delta + "\nRendererIOS app lifecycle: did-become-active resumed=1 viewport=852x393\n"),
        "shutdown-idle-unconfirmed-after-fired": replace_once(
            valid_post_fault_settle, "outcome=fatal", "outcome=idle-unconfirmed"
        ),
        "shutdown-clean-after-fired": replace_once(
            valid_post_fault_settle, "outcome=fatal", "outcome=clean"
        ),
        "shutdown-counter-growth-after-fired": replace_once(
            valid_post_fault_settle,
            "outcome=fatal submit-attempts=3",
            "outcome=fatal submit-attempts=4",
        ),
        "shutdown-before-fatal": replace_once(
            base,
            fired + "\n",
            fired + "\n" + shutdown + "\n" + shutdown_delta + "\n",
        ),
        "shutdown-before-fired": replace_once(
            base,
            armed + "\n",
            armed + "\n" + shutdown + "\n" + shutdown_delta + "\n",
        ),
        "shutdown-before-canonical-delta": replace_once(
            base,
            settled + "\n" + delta,
            settled + "\n" + shutdown + "\n" + shutdown_delta + "\n" + delta,
        ),
        "shutdown-delta-before-counters": replace_once(
            valid_post_fault_settle,
            shutdown + "\n" + shutdown_delta,
            shutdown_delta + "\n" + shutdown,
        ),
        "lifecycle-after-shutdown": base
        + shutdown
        + "\n"
        + shutdown_delta
        + "\n"
        + lifecycle
        + "\n",
        "second-shutdown-after-delta": valid_post_fault_settle
        + shutdown
        + "\n"
        + shutdown_delta
        + "\n",
        "shutdown-missing-delta-after-fired": replace_once(
            valid_post_fault_settle, shutdown_delta + "\n", ""
        ),
        "shutdown-delta-without-counters-after-fired": base + shutdown_delta + "\n",
        "shutdown-delta-submit-attempts-one": replace_once(
            valid_post_fault_settle,
            "shutdown post-fatal delta: submit-attempts=0",
            "shutdown post-fatal delta: submit-attempts=1",
        ),
        "shutdown-delta-submit-accepted-one": replace_once(
            valid_post_fault_settle,
            "shutdown post-fatal delta: submit-attempts=0 submit-accepted=0",
            "shutdown post-fatal delta: submit-attempts=0 submit-accepted=1",
        ),
        "shutdown-delta-present-attempts-one": replace_once(
            valid_post_fault_settle,
            "shutdown post-fatal delta: submit-attempts=0 submit-accepted=0 present-attempts=0",
            "shutdown post-fatal delta: submit-attempts=0 submit-accepted=0 present-attempts=1",
        ),
        "shutdown-delta-present-accepted-one": replace_once(
            valid_post_fault_settle,
            "shutdown post-fatal delta: submit-attempts=0 submit-accepted=0 "
            "present-attempts=0 present-accepted=0",
            "shutdown post-fatal delta: submit-attempts=0 submit-accepted=0 "
            "present-attempts=0 present-accepted=1",
        ),
        "log-terminal-without-teardown": base
        + "RendererIOS final GPU shutdown could not confirm device idle; "
        "terminating without C++ teardown so in-flight GPU owners remain alive\n",
        "log-unexpected-fatal": base + "RendererIOS fatal: unexpected\n",
        "log-crash": base + "SIGABRT\n",
        "log-terminate": base + "terminate called after throwing an instance\n",
        "log-oom": base + "GPU out of memory\n",
        "log-timeout": base + "Metal command buffer timeout\n",
        "log-unhandled": base + "unhandled exception in render loop\n",
    }
    stderr_mutations = {
        "stderr-unexpected-fatal": mirrored_stderr + "RendererIOS fatal: unexpected\n",
        "stderr-crash": mirrored_stderr + "libc++abi: terminating due to uncaught exception\n",
        "stderr-terminate": mirrored_stderr + "std::terminate invoked\n",
        "stderr-oom": mirrored_stderr + "GPU out of memory\n",
        "stderr-timeout": mirrored_stderr + "Metal command buffer timed out\n",
        "stderr-unhandled": mirrored_stderr + "unhandled non-std/ObjC exception in render loop\n",
        "stderr-terminal-without-teardown": mirrored_stderr
        + "RendererIOS final GPU shutdown could not confirm device idle; "
        "terminating without C++ teardown so in-flight GPU owners remain alive\n",
    }

    killed = 0
    for name, mutated in replacements.items():
        try:
            validate(mutated, mirrored_stderr, build)
        except ValidationError:
            killed += 1
        else:
            raise AssertionError(f"self-test mutation survived: {name}")
    for name, mutated_stderr in stderr_mutations.items():
        try:
            validate(base, mutated_stderr, build)
        except ValidationError:
            killed += 1
        else:
            raise AssertionError(f"self-test stderr mutation survived: {name}")

    print(f"frame-fence fault log self-test passed: mutations-killed={killed}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-fault", default=FAULT_MODE)
    parser.add_argument("--summary", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        if (
            args.log is not None
            or args.stderr is not None
            or args.expected_build is not None
            or args.summary is not None
        ):
            parser.error("--self-test does not accept log/build inputs")
        return args
    if args.log is None or args.expected_build is None or args.summary is None:
        parser.error("--log, --expected-build and --summary are required")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            self_test()
        else:
            log = args.log.read_text(errors="replace")
            stderr = ""
            if args.stderr is not None and args.stderr.exists():
                stderr = args.stderr.read_text(errors="replace")
            values = validate(log, stderr, args.expected_build, args.expected_fault)
            write_summary(args.summary, values)
    except (OSError, ValidationError, AssertionError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
