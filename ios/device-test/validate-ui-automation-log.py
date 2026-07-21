#!/usr/bin/env python3
"""Validate terminal RendererIOS UI/Bink/lifecycle evidence from one process."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


EVIDENCE_RE = re.compile(
    r"^RendererIOS functional evidence: fence-terminal=(\d+) "
    r"submitted=(\d+) presented=(\d+) slot=(\d+) serial=(\d+) "
    r"ui=(none|inventory|quickring-items|quickring-weapons) "
    r"ui-item-draw-count=(\d+) "
    r"real-bink-ordinal=(\d+) resume-cycle=(\d+)$",
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


def validate(
    log: str,
    stderr: str = "",
    require_bink: bool = False,
    require_ui_items: bool = False,
) -> None:
    diagnostics = [int(match.group(1)) for match in DIAGNOSTICS_RE.finditer(log)]
    require(len(diagnostics) == 1, "expected one diagnostics frames-in-flight marker")
    frames_in_flight = diagnostics[0]
    require(frames_in_flight in (2, 3), "unexpected frames-in-flight value")

    events = []
    for match in EVIDENCE_RE.finditer(log):
        (
            fence,
            submitted,
            presented,
            slot,
            serial,
            ui,
            ui_draws,
            bink,
            resume,
        ) = match.groups()
        numeric = tuple(
            map(
                int,
                (fence, submitted, presented, slot, serial, ui_draws, bink, resume),
            )
        )
        (
            fence_value,
            submitted_value,
            presented_value,
            slot_value,
            serial_value,
            ui_draws_value,
            bink_value,
            resume_value,
        ) = numeric
        require(
            (fence_value, submitted_value, presented_value) == (1, 1, 1),
            "functional evidence was emitted before terminal accepted presentation",
        )
        require(
            slot_value < frames_in_flight,
            "functional evidence slot is out of range",
        )
        require(serial_value > 0, "functional evidence serial must be positive")
        require(
            ui != "none" or ui_draws_value == 0,
            "non-UI evidence unexpectedly reports encoded UI item draws",
        )
        require(bink_value in (0, 1, 30), "unexpected real Bink ordinal")
        events.append((match.start(), ui, ui_draws_value, bink_value, resume_value))

    require(events, "no terminal functional evidence markers")
    for expected_ui in ("inventory", "quickring-items", "quickring-weapons"):
        matching = [event for event in events if event[1] == expected_ui]
        count = len(matching)
        require(count == 1, f"expected exactly one terminal {expected_ui} marker")
        if require_ui_items:
            require(
                matching[0][2] > 0,
                f"terminal {expected_ui} marker has no encoded item draw",
            )
    if require_bink:
        require(
            sum(bink == 1 for _, _, _, bink, _ in events) == 1,
            "expected exactly one terminal real Bink ordinal 1",
        )
        require(
            sum(bink == 30 for _, _, _, bink, _ in events) == 1,
            "expected exactly one terminal real Bink ordinal 30",
        )

    resume_events = [
        (position, cycle) for position, _, _, _, cycle in events if cycle
    ]
    require(len(resume_events) == 1, "expected exactly one first-present-after-resume marker")

    lifecycle_literals = (
        "RendererIOS app lifecycle: will-resign-active idle-confirmed=1",
        "RendererIOS app lifecycle: did-enter-background idle-confirmed=1",
        "RendererIOS app lifecycle: will-enter-foreground",
        "RendererIOS app lifecycle: did-become-active resumed=1",
    )
    lifecycle_positions = []
    for literal in lifecycle_literals:
        positions = [match.start() for match in re.finditer(re.escape(literal), log)]
        require(len(positions) == 1, f"expected exactly one lifecycle marker: {literal}")
        lifecycle_positions.append(positions[0])
    require(
        lifecycle_positions == sorted(lifecycle_positions),
        "application lifecycle markers are out of order",
    )
    require(
        resume_events[0][0] > lifecycle_positions[-1],
        "terminal resume evidence precedes did-become-active",
    )
    require(resume_events[0][1] > 0, "resume cycle must be positive")

    fatal = re.search(
        r"RendererIOS (?:stopped the frame loop|fatal|GPU shutdown failed|"
        r"native Landscape encode failed|IOSGPUScene metallib loading failed|"
        r"frame submission failed)|RendererIOS Bink self-test: FAIL|"
        r"libc\+\+abi: terminating|SIGABRT|EXC_BAD_ACCESS|AddressSanitizer",
        log + "\n" + stderr,
        flags=re.IGNORECASE,
    )
    require(fatal is None, "fatal RendererIOS/runtime signature found")


def fixture() -> str:
    return "\n".join(
        (
            "RendererIOS diagnostics: ON frames-in-flight=3 context=IOSMetalContext transport=Tempest",
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=1 ui=none ui-item-draw-count=0 real-bink-ordinal=1 resume-cycle=0",
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=2 serial=30 ui=none ui-item-draw-count=0 real-bink-ordinal=30 resume-cycle=0",
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=90 ui=inventory ui-item-draw-count=7 real-bink-ordinal=0 resume-cycle=0",
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=1 serial=91 ui=quickring-items ui-item-draw-count=5 real-bink-ordinal=0 resume-cycle=0",
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=2 serial=92 ui=quickring-weapons ui-item-draw-count=2 real-bink-ordinal=0 resume-cycle=0",
            "RendererIOS app lifecycle: will-resign-active idle-confirmed=1",
            "RendererIOS app lifecycle: did-enter-background idle-confirmed=1",
            "RendererIOS app lifecycle: will-enter-foreground",
            "RendererIOS app lifecycle: did-become-active resumed=1 viewport=852x393",
            "RendererIOS functional evidence: fence-terminal=1 submitted=1 presented=1 slot=0 serial=93 ui=none ui-item-draw-count=0 real-bink-ordinal=0 resume-cycle=1",
        )
    ) + "\n"


def self_test() -> None:
    base = fixture()
    validate(base, require_bink=True, require_ui_items=True)
    validate(
        base.replace("real-bink-ordinal=1", "real-bink-ordinal=0").replace(
            "real-bink-ordinal=30", "real-bink-ordinal=0"
        )
    )
    surface_only = re.sub(
        r"(ui=(?:inventory|quickring-items|quickring-weapons) ui-item-draw-count=)\d+",
        r"\g<1>0",
        base,
    )
    validate(surface_only, require_bink=True)
    try:
        validate(surface_only, require_bink=True, require_ui_items=True)
    except ValidationError:
        pass
    else:
        raise ValidationError("mutation survived: empty UI item content")
    mutations = {
        "missing-inventory": base.replace("ui=inventory", "ui=none"),
        "missing-items": base.replace("ui=quickring-items", "ui=none"),
        "missing-weapons": base.replace("ui=quickring-weapons", "ui=none"),
        "missing-bink-1": base.replace("real-bink-ordinal=1", "real-bink-ordinal=0"),
        "missing-bink-30": base.replace("real-bink-ordinal=30", "real-bink-ordinal=0"),
        "empty-inventory": base.replace(
            "ui=inventory ui-item-draw-count=7",
            "ui=inventory ui-item-draw-count=0",
        ),
        "empty-items": base.replace(
            "ui=quickring-items ui-item-draw-count=5",
            "ui=quickring-items ui-item-draw-count=0",
        ),
        "empty-weapons": base.replace(
            "ui=quickring-weapons ui-item-draw-count=2",
            "ui=quickring-weapons ui-item-draw-count=0",
        ),
        "items-on-none": base.replace(
            "ui=none ui-item-draw-count=0",
            "ui=none ui-item-draw-count=1",
            1,
        ),
        "missing-draw-count": base.replace(" ui-item-draw-count=7", "", 1),
        "preterminal": base.replace("fence-terminal=1", "fence-terminal=0", 1),
        "not-presented": base.replace("presented=1", "presented=0", 1),
        "bad-slot": base.replace("slot=2 serial=30", "slot=3 serial=30"),
        "missing-resume": base.replace("resume-cycle=1", "resume-cycle=0"),
        "resume-before-active": base.replace(
            "RendererIOS app lifecycle: did-become-active resumed=1 viewport=852x393\n",
            "",
        ),
        "fatal": base + "RendererIOS fatal frame submission failed\n",
    }
    for name, mutated in mutations.items():
        try:
            validate(mutated, require_bink=True, require_ui_items=True)
        except ValidationError:
            continue
        raise ValidationError(f"mutation survived: {name}")
    try:
        validate(base, stderr="libc++abi: terminating after throwing")
    except ValidationError:
        pass
    else:
        raise ValidationError("mutation survived: fatal-stderr")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", nargs="?", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--require-bink", action="store_true")
    parser.add_argument("--require-ui-items", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("PASS — RendererIOS UI automation log validator self-test")
        return 0
    if args.log is None:
        parser.error("pass log.txt or --self-test")
    stderr = "" if args.stderr is None else args.stderr.read_text(errors="replace")
    validate(
        args.log.read_text(errors="replace"),
        stderr=stderr,
        require_bink=args.require_bink,
        require_ui_items=args.require_ui_items,
    )
    print("PASS — terminal RendererIOS UI/Bink/lifecycle evidence")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
