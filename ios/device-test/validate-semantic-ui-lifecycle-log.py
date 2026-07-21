#!/usr/bin/env python3
"""Validate one nonce-scoped RendererIOS semantic UI/lifecycle run."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
EVIDENCE_RE = re.compile(
    r"^RendererIOS functional evidence: fence-terminal=(\d+) "
    r"submitted=(\d+) presented=(\d+) slot=(\d+) serial=(\d+) "
    r"ui=(none|inventory|quickring-items|quickring-weapons) "
    r"ui-item-draw-count=(\d+) real-bink-ordinal=(\d+) "
    r"resume-cycle=(\d+)$",
    re.MULTILINE,
)
DIAGNOSTICS_RE = re.compile(
    r"^RendererIOS diagnostics: ON frames-in-flight=(\d+) ", re.MULTILINE
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def one_position(log: str, literal: str) -> int:
    positions = [match.start() for match in re.finditer(re.escape(literal), log)]
    require(len(positions) == 1, f"expected exactly one marker: {literal}")
    return positions[0]


def validate(log: str, nonce: str, stderr: str = "") -> None:
    require(NONCE_RE.fullmatch(nonce) is not None, "invalid expected nonce")
    diagnostics = [int(match.group(1)) for match in DIAGNOSTICS_RE.finditer(log)]
    require(len(diagnostics) == 1, "expected one diagnostics marker")
    require(diagnostics[0] in (2, 3), "unexpected frames-in-flight value")

    semantic_lines = re.findall(r"^RendererIOS semantic script:.*$", log, re.MULTILINE)
    require(semantic_lines, "semantic script emitted no markers")
    for line in semantic_lines:
        matches = re.findall(r"(?:^| )nonce=([^ ]+)", line)
        require(len(matches) == 1, f"semantic marker has invalid nonce field: {line}")
        require(matches[0] == nonce, "semantic marker belongs to another nonce")

    armed = (
        "RendererIOS semantic script: ARMED mode=save-ui-lifecycle-v1 "
        f"nonce={nonce}"
    )
    armed_position = one_position(log, armed)
    pass_literal = (
        "RendererIOS semantic script: SCRIPT PASS mode=save-ui-lifecycle-v1 "
        f"nonce={nonce}"
    )
    pass_position = one_position(log, pass_literal)
    require(pass_position > armed_position, "SCRIPT PASS precedes current ARMED")
    require(
        "RendererIOS semantic script: SCRIPT PASS" not in log[:armed_position],
        "stale complete semantic PASS precedes current ARMED",
    )
    require(
        "RendererIOS semantic script: SCRIPT FAIL" not in log,
        "semantic script reported FAIL",
    )

    states = (
        "WAIT_WORLD",
        "WAIT_INVENTORY_EVIDENCE",
        "WAIT_ITEMS_EVIDENCE",
        "WAIT_WEAPONS_EVIDENCE",
        "READY_FOR_LIFECYCLE",
        "WAIT_DID_ENTER_BACKGROUND",
        "WAIT_WILL_ENTER_FOREGROUND",
        "WAIT_DID_BECOME_ACTIVE",
        "WAIT_RESUME_EVIDENCE",
    )
    state_positions = {
        state: one_position(
            log, f"RendererIOS semantic script: state={state} nonce={nonce}"
        )
        for state in states
    }
    ordered_states = [state_positions[state] for state in states]
    require(
        armed_position < ordered_states[0]
        and ordered_states == sorted(ordered_states)
        and ordered_states[-1] < pass_position,
        "semantic states are out of order",
    )

    events = []
    for match in EVIDENCE_RE.finditer(log):
        if not (armed_position < match.start() < pass_position):
            continue
        fence, submitted, presented, slot, serial, ui, draws, bink, resume = (
            match.groups()
        )
        values = tuple(map(int, (fence, submitted, presented, slot, serial, draws, bink, resume)))
        fence_v, submitted_v, presented_v, slot_v, serial_v, draws_v, bink_v, resume_v = values
        require(
            (fence_v, submitted_v, presented_v) == (1, 1, 1),
            "evidence is not terminal accepted presentation",
        )
        require(slot_v < diagnostics[0], "functional evidence slot is out of range")
        require(serial_v > 0, "functional evidence serial must be positive")
        require(bink_v in (0, 1, 30), "unexpected Bink ordinal")
        require(ui != "none" or draws_v == 0, "non-UI evidence reports item draws")
        events.append((match.start(), serial_v, ui, draws_v, resume_v))

    ui_order = (
        ("inventory", "WAIT_INVENTORY_EVIDENCE", "WAIT_ITEMS_EVIDENCE"),
        ("quickring-items", "WAIT_ITEMS_EVIDENCE", "WAIT_WEAPONS_EVIDENCE"),
        ("quickring-weapons", "WAIT_WEAPONS_EVIDENCE", "READY_FOR_LIFECYCLE"),
    )
    ui_serials = []
    for surface, before, after in ui_order:
        matching = [event for event in events if event[2] == surface]
        require(1 <= len(matching) <= 2,
                f"expected one surface marker and at most one item retry for {surface}")
        positive = [event for event in matching if event[3] > 0]
        require(len(positive) == 1,
                f"terminal {surface} lacks one unique real item draw")
        if len(matching) == 2:
            require(matching[0][3] == 0 and matching[1][3] > 0,
                    f"terminal {surface} retry is not zero-then-positive")
        for position, _, _, _, resume in matching:
            require(resume == 0, f"terminal {surface} unexpectedly carries resume")
            require(
                state_positions[before] < position < state_positions[after],
                f"terminal {surface} evidence is out of script order",
            )
        _, serial, _, _, _ = positive[0]
        ui_serials.append(serial)
    require(ui_serials == sorted(ui_serials) and len(set(ui_serials)) == 3,
            "UI evidence serials are not strictly ordered")

    lifecycle = (
        "RendererIOS app lifecycle: will-resign-active idle-confirmed=1",
        "RendererIOS app lifecycle: did-enter-background idle-confirmed=1",
        "RendererIOS app lifecycle: will-enter-foreground",
        "RendererIOS app lifecycle: did-become-active resumed=1",
    )
    lifecycle_positions = [one_position(log, literal) for literal in lifecycle]
    require(lifecycle_positions == sorted(lifecycle_positions),
            "application lifecycle markers are out of order")
    require(
        state_positions["READY_FOR_LIFECYCLE"] < lifecycle_positions[0]
        < state_positions["WAIT_DID_ENTER_BACKGROUND"] < lifecycle_positions[1]
        < state_positions["WAIT_WILL_ENTER_FOREGROUND"] < lifecycle_positions[2]
        < state_positions["WAIT_DID_BECOME_ACTIVE"] < lifecycle_positions[3]
        < state_positions["WAIT_RESUME_EVIDENCE"],
        "semantic and application lifecycle markers disagree",
    )

    resume_events = [event for event in events if event[4] > 0]
    require(len(resume_events) == 1, "expected one terminal resume evidence")
    resume_position, resume_serial, resume_ui, resume_draws, resume_cycle = resume_events[0]
    require(resume_ui == "none" and resume_draws == 0,
            "resume evidence unexpectedly carries UI draws")
    require(resume_cycle > 0 and resume_serial > ui_serials[-1],
            "resume evidence is not newer than UI evidence")
    require(
        state_positions["WAIT_RESUME_EVIDENCE"] < resume_position < pass_position,
        "resume evidence is out of script order",
    )

    fatal = re.search(
        r"RendererIOS (?:stopped the frame loop|fatal|GPU shutdown failed|"
        r"native Landscape encode failed|IOSGPUScene metallib loading failed|"
        r"frame submission failed)|libc\+\+abi: terminating|SIGABRT|"
        r"EXC_BAD_ACCESS|AddressSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer|"
        r"device lost|out of memory|jetsam",
        log + "\n" + stderr,
        flags=re.IGNORECASE,
    )
    require(fatal is None, "fatal RendererIOS/runtime signature found")


def fixture(nonce: str) -> str:
    state = lambda value: f"RendererIOS semantic script: state={value} nonce={nonce}"
    return "\n".join(
        (
            "RendererIOS diagnostics: ON frames-in-flight=3 context=IOSMetalContext transport=Tempest",
            f"RendererIOS semantic script: ARMED mode=save-ui-lifecycle-v1 nonce={nonce}",
            state("WAIT_WORLD"),
            state("WAIT_INVENTORY_EVIDENCE"),
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=90 ui=inventory ui-item-draw-count=7 real-bink-ordinal=0 resume-cycle=0",
            state("WAIT_ITEMS_EVIDENCE"),
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=1 serial=91 ui=quickring-items ui-item-draw-count=5 real-bink-ordinal=0 resume-cycle=0",
            state("WAIT_WEAPONS_EVIDENCE"),
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=2 serial=92 ui=quickring-weapons ui-item-draw-count=2 real-bink-ordinal=0 resume-cycle=0",
            state("READY_FOR_LIFECYCLE"),
            "RendererIOS app lifecycle: will-resign-active idle-confirmed=1",
            state("WAIT_DID_ENTER_BACKGROUND"),
            "RendererIOS app lifecycle: did-enter-background idle-confirmed=1",
            state("WAIT_WILL_ENTER_FOREGROUND"),
            "RendererIOS app lifecycle: will-enter-foreground",
            state("WAIT_DID_BECOME_ACTIVE"),
            "RendererIOS app lifecycle: did-become-active resumed=1 viewport=852x393",
            state("WAIT_RESUME_EVIDENCE"),
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=93 ui=none ui-item-draw-count=0 real-bink-ordinal=0 resume-cycle=1",
            f"RendererIOS semantic script: SCRIPT PASS mode=save-ui-lifecycle-v1 nonce={nonce}",
        )
    ) + "\n"


def self_test() -> None:
    nonce = "0123456789abcdef0123456789abcdef"
    other = "fedcba9876543210fedcba9876543210"
    base = fixture(nonce)
    validate(base, nonce)
    delayed_positive = base.replace(
        "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=90 ui=inventory ui-item-draw-count=7 real-bink-ordinal=0 resume-cycle=0",
        "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=2 serial=89 ui=inventory ui-item-draw-count=0 real-bink-ordinal=0 resume-cycle=0\n"
        "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=90 ui=inventory ui-item-draw-count=7 real-bink-ordinal=0 resume-cycle=0",
    )
    validate(delayed_positive, nonce)
    mutations = {
        "missing-armed": base.replace(
            f"RendererIOS semantic script: ARMED mode=save-ui-lifecycle-v1 nonce={nonce}\n", ""
        ),
        "duplicate-armed": base.replace(
            f"RendererIOS semantic script: ARMED mode=save-ui-lifecycle-v1 nonce={nonce}\n",
            f"RendererIOS semantic script: ARMED mode=save-ui-lifecycle-v1 nonce={nonce}\n" * 2,
        ),
        "wrong-nonce": base.replace(f"nonce={nonce}", f"nonce={other}", 1),
        "stale-pass": (
            f"RendererIOS semantic script: SCRIPT PASS mode=save-ui-lifecycle-v1 nonce={nonce}\n"
            + base
        ),
        "missing-state": base.replace(
            f"RendererIOS semantic script: state=WAIT_ITEMS_EVIDENCE nonce={nonce}\n", ""
        ),
        "empty-inventory": base.replace(
            "ui=inventory ui-item-draw-count=7", "ui=inventory ui-item-draw-count=0"
        ),
        "empty-items": base.replace(
            "ui=quickring-items ui-item-draw-count=5",
            "ui=quickring-items ui-item-draw-count=0",
        ),
        "empty-weapons": base.replace(
            "ui=quickring-weapons ui-item-draw-count=2",
            "ui=quickring-weapons ui-item-draw-count=0",
        ),
        "preterminal": base.replace("fence-terminal=1", "fence-terminal=0", 1),
        "duplicate-ui": base.replace(
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=90 ui=inventory ui-item-draw-count=7 real-bink-ordinal=0 resume-cycle=0\n",
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=90 ui=inventory ui-item-draw-count=7 real-bink-ordinal=0 resume-cycle=0\n" * 2,
        ),
        "missing-lifecycle": base.replace(
            "RendererIOS app lifecycle: did-enter-background idle-confirmed=1\n", ""
        ),
        "missing-resume": base.replace("resume-cycle=1", "resume-cycle=0"),
        "pass-before-resume": base.replace(
            f"RendererIOS semantic script: SCRIPT PASS mode=save-ui-lifecycle-v1 nonce={nonce}\n",
            "",
        ).replace(
            f"RendererIOS semantic script: state=WAIT_RESUME_EVIDENCE nonce={nonce}\n",
            f"RendererIOS semantic script: state=WAIT_RESUME_EVIDENCE nonce={nonce}\n"
            f"RendererIOS semantic script: SCRIPT PASS mode=save-ui-lifecycle-v1 nonce={nonce}\n",
        ),
        "script-fail": base.replace(
            f"RendererIOS semantic script: SCRIPT PASS mode=save-ui-lifecycle-v1 nonce={nonce}",
            f"RendererIOS semantic script: SCRIPT FAIL mode=save-ui-lifecycle-v1 nonce={nonce} state=WAIT_RESUME_EVIDENCE reason=watchdog-timeout",
        ),
    }
    for name, mutated in mutations.items():
        try:
            validate(mutated, nonce)
        except ValidationError:
            continue
        raise ValidationError(f"mutation survived: {name}")
    try:
        validate(base, nonce, stderr="libc++abi: terminating after throwing")
    except ValidationError:
        pass
    else:
        raise ValidationError("mutation survived: fatal stderr")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", nargs="?", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--nonce")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("PASS — RendererIOS semantic fallback validator self-test")
        return 0
    if args.log is None or args.nonce is None:
        parser.error("pass log.txt and --nonce, or --self-test")
    stderr = "" if args.stderr is None else args.stderr.read_text(errors="replace")
    validate(args.log.read_text(errors="replace"), args.nonce, stderr)
    print("PASS — nonce-scoped RendererIOS semantic UI/lifecycle evidence")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
