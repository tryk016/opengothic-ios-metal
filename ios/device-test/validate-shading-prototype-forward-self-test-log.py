#!/usr/bin/env python3
"""Validate the nonce-bound RendererIOS Forward+ device self-test evidence."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import stat
import struct
import sys
import tempfile


CASE = "forward-prototype-v1"
PREFIX = "RendererIOS shading prototype forward self-test:"
CAPTURE_PREFIX = "RendererIOS shading prototype forward capture:"
CAPTURE_NAME = "RendererIOS-forward-prototype-v1.gputrace"
MAX_MARKER_BYTES = 250
MAX_CAPTURE_BYTES = 512 * 1024 * 1024
NONCE_RE = re.compile(r"[0-9a-f]{32}\Z")
EXPECTED_READBACK_SHA256 = hashlib.sha256(
    struct.pack("<64I", 1, *([0] * 63))
).hexdigest()
FAIL_REASONS = (
    "plan-contract-mismatch",
    "snapshot-unavailable",
    "factory-contract-mismatch",
    "factory-reflection-mismatch",
    "factory-counter-mismatch",
    "output-allocation-or-lifetime-mismatch",
    "light-list-allocation-or-contract-mismatch",
    "capture-start-failed",
    "capture-start-ambiguous",
    "command-buffer-creation-failed",
    "native-encode-rejected",
    "encoded-contract-mismatch",
    "submit-exception-ambiguous",
    "capture-acquisition-failed",
    "terminal-fence-error",
    "terminal-fence-timeout",
    "readback-unavailable",
    "readback-mismatch",
    "terminal-lifetime-or-counter-mismatch",
    "wait-idle-used",
)
FAIL_STAGE_CONTRACTS = {
    "plan-contract-mismatch": ((1, False),),
    "snapshot-unavailable": ((1, False),),
    "factory-contract-mismatch": ((1, False),),
    "factory-reflection-mismatch": ((1, False),),
    "factory-counter-mismatch": ((1, False),),
    "output-allocation-or-lifetime-mismatch": ((2, False),),
    "light-list-allocation-or-contract-mismatch": ((2, False),),
    "capture-start-failed": ((2, False),),
    "capture-start-ambiguous": ((2, False),),
    "command-buffer-creation-failed": ((2, False),),
    "native-encode-rejected": ((2, False),),
    "encoded-contract-mismatch": ((2, False),),
    "submit-exception-ambiguous": ((3, False),),
    "capture-acquisition-failed": ((4, False),),
    "terminal-fence-error": ((4, True),),
    "terminal-fence-timeout": ((4, True),),
    "readback-unavailable": ((5, True),),
    "readback-mismatch": ((5, True),),
    "terminal-lifetime-or-counter-mismatch": ((4, True), (6, True)),
    "wait-idle-used": ((4, True),),
}
SHELL_RE = re.compile(
    r"^RendererIOS shell: version=[^\r\n]* build=([^\s]+) gpu=[^\r\n]*$",
    re.MULTILINE,
)
CONFIGURED_RE = re.compile(
    r"^RendererIOS configured fault mode=([^\s]+)$",
    re.MULTILINE,
)
SHUTDOWN_COUNTERS_RE = re.compile(
    r"^RendererIOS shutdown counters: outcome=[^\s]+ submit-attempts=0 "
    r"submit-accepted=0 present-attempts=0 present-accepted=0$"
)
FATAL_SNAPSHOT_RE = re.compile(
    r"^RendererIOS fatal snapshot: submit-attempts=0 submit-accepted=0 "
    r"present-attempts=0 present-accepted=0$"
)
FATAL_SETTLED_RE = re.compile(
    r"^RendererIOS fatal settled: idle-confirmed=1 submit-attempts=0 "
    r"submit-accepted=0 present-attempts=0 present-accepted=0$"
)
FATAL_POST_DELTA_RE = re.compile(
    r"^RendererIOS fatal post-delta: submit-attempts=0 submit-accepted=0 "
    r"present-attempts=0 present-accepted=0$"
)
ORDINARY_FRAME_PREFIXES = (
    "RendererIOS native Landscape:",
    "RendererIOS runtime compilation: point=frame presents=",
    "RendererIOS builtin runtime attribution: point=frame presents=",
    "RendererIOS functional evidence:",
    "RendererIOS shell: 300 present calls submitted",
    "RendererIOS lifecycle: presents=",
)
CONFLICT_PREFIXES = (
    "RendererIOS Bink self-test:",
    "RendererIOS resource allocator self-test:",
    "RendererIOS clear-only pass self-test:",
    "RendererIOS clear-only capture:",
    "RendererIOS shading prototype tile self-test:",
    "RendererIOS shading prototype tile capture:",
    "RendererIOS fault injection armed:",
    "RendererIOS fault injection fired:",
    "RendererIOS pipeline archive test-mode:",
    "RendererIOS semantic script:",
)
DENY_RE = re.compile(
    r"RendererIOS (?:fatal|stopped the frame loop|GPU shutdown failed|"
    r"frame submission failed|asynchronous Metal present failed|resize failed)|"
    r"libc\+\+abi: terminating|SIGABRT|SIGSEGV|EXC_BAD_ACCESS|"
    r"AddressSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer|"
    r"uncaught exception|terminate called|std::terminate|jetsam|crash",
    re.IGNORECASE,
)


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def require_nonce(nonce: str) -> None:
    require(NONCE_RE.fullmatch(nonce) is not None, "nonce must be 32 lowercase hex")


def armed(nonce: str) -> str:
    return (
        f"{PREFIX} ARMED case={CASE} nonce={nonce} contract=1 metallib-abi=9 "
        "minimum-apple=4"
    )


def factory_ready(nonce: str) -> str:
    return (
        f"{PREFIX} FACTORY READY case={CASE} nonce={nonce} pipelines=3 "
        "reflection=1 runtime-delta=0 builtin-delta=0 archive-delta=0"
    )


def encoded(nonce: str) -> str:
    return (
        f"{PREFIX} ENCODED case={CASE} nonce={nonce} cb=1 compute=1 render=1 "
        "dispatch=1 draws=2 opaque=1 alpha=1 output=4x4 light-list=256 "
        "drawable=0 present=0"
    )


def submitted(nonce: str) -> str:
    return (
        f"{PREFIX} SUBMITTED case={CASE} nonce={nonce} "
        "command-buffers=1 submits=1"
    )


def terminal(nonce: str, waits: int) -> str:
    return (
        f"{PREFIX} TERMINAL case={CASE} nonce={nonce} terminal=completed "
        f"wait-calls={waits} zero-timeout={waits} nonterminal={waits - 1} "
        "wait-idle=0"
    )


def readback(nonce: str) -> str:
    return (
        f"{PREFIX} READBACK case={CASE} nonce={nonce} "
        f"bytes=256 words=64 exact=1 h={EXPECTED_READBACK_SHA256}"
    )


def passed(nonce: str) -> str:
    return (
        f"{PREFIX} PASS case={CASE} nonce={nonce} wait-idle=0 "
        "output=1/0/1 light-list=1/0/1 capture=1/0/1"
    )


def unsupported(nonce: str) -> str:
    return (
        f"{PREFIX} UNSUPPORTED case={CASE} nonce={nonce} "
        "reason=apple4-required side-effects=0"
    )


def failure(nonce: str, reason: str) -> str:
    return f"{PREFIX} FAIL case={CASE} nonce={nonce} reason={reason}"


def capture_re(nonce: str) -> re.Pattern[str]:
    return re.compile(
        rf"^{re.escape(CAPTURE_PREFIX)} ACQUIRED case={CASE} nonce={nonce} "
        rf"file={re.escape(CAPTURE_NAME)} kind=(file|directory) "
        r"bytes=([1-9][0-9]*)$"
    )


def parse_terminal_marker(line: str, nonce: str) -> int | None:
    pattern = re.compile(
        rf"^{re.escape(PREFIX)} TERMINAL case={CASE} nonce={nonce} "
        r"terminal=completed wait-calls=([1-9][0-9]{0,2}) "
        r"zero-timeout=([1-9][0-9]{0,2}) nonterminal=([0-9]{1,3}) wait-idle=0$"
    )
    match = pattern.fullmatch(line)
    if match is None:
        return None
    waits, zero_timeout, nonterminal = map(int, match.groups())
    require(1 <= waits <= 120, "Forward terminal wait count is out of bounds")
    require(zero_timeout == waits, "every Forward fence poll must use zero timeout")
    require(nonterminal == waits - 1, "Forward fence poll progression is not monotonic")
    return waits


def only_match(pattern: re.Pattern[str], text: str, name: str) -> re.Match[str]:
    matches = list(pattern.finditer(text))
    require(len(matches) == 1, f"expected exactly one {name}, found {len(matches)}")
    return matches[0]


def validate_marker_budget(nonce: str) -> None:
    require_nonce(nonce)
    markers = (
        armed(nonce),
        factory_ready(nonce),
        encoded(nonce),
        submitted(nonce),
        terminal(nonce, 120),
        readback(nonce),
        passed(nonce),
        unsupported(nonce),
        (
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} nonce={nonce} "
            f"file={CAPTURE_NAME} kind=directory bytes=18446744073709551615"
        ),
        *(failure(nonce, reason) for reason in FAIL_REASONS),
    )
    for marker in markers:
        require(
            len(marker.encode("utf-8")) < MAX_MARKER_BYTES,
            f"Forward marker exceeds the strict <{MAX_MARKER_BYTES} byte budget",
        )


def marker_lines(log: str) -> tuple[list[str], list[str]]:
    lines = log.splitlines()
    return (
        [line for line in lines if line.startswith(PREFIX)],
        [line for line in lines if line.startswith(CAPTURE_PREFIX)],
    )


def validate_common(
    log: str,
    stderr: str,
    expected_build: str,
) -> list[str]:
    require(
        re.fullmatch(r"[0-9a-f]{40}(?:-local)?", expected_build) is not None,
        "expected build must be a lowercase SHA, optionally suffixed -local",
    )
    shell = only_match(SHELL_RE, log, "RendererIOS shell marker")
    require(shell.group(1) == expected_build, "RendererIOS shell build is not exact")
    configured = only_match(CONFIGURED_RE, log, "configured fault marker")
    require(configured.group(1) == "none", "Forward self-test requires fault none")
    diagnostics = [
        line for line in log.splitlines()
        if line.startswith("RendererIOS diagnostics:")
    ]
    require(len(diagnostics) == 1, "expected exactly one diagnostics marker")
    require(
        diagnostics[0].startswith("RendererIOS diagnostics: ON frames-in-flight=")
        and diagnostics[0].endswith(" context=IOSMetalContext transport=Tempest"),
        "Forward self-test requires diagnostics ON",
    )
    shutdown_lines = [
        line for line in log.splitlines()
        if line.startswith("RendererIOS shutdown counters:")
    ]
    require(
        len(shutdown_lines) <= 1,
        "Forward evidence contains duplicate shutdown counters",
    )
    if shutdown_lines:
        require(
            SHUTDOWN_COUNTERS_RE.fullmatch(shutdown_lines[0]) is not None,
            "Forward shutdown counters are not exact zero",
        )
    for prefix in CONFLICT_PREFIXES:
        require(prefix not in log, f"Forward self-test conflict marker: {prefix}")
    ordinary = [
        line for line in log.splitlines()
        if line.startswith(ORDINARY_FRAME_PREFIXES)
    ]
    require(not ordinary, f"Forward self-test admitted ordinary work: {ordinary!r}")
    denied = DENY_RE.search(log + "\n" + stderr)
    require(
        denied is None,
        "fatal/crash signature in Forward evidence"
        if denied is None
        else f"fatal/crash signature in Forward evidence: {denied.group(0)!r}",
    )
    return log.splitlines()


def _sanitize_failure_stream(
    text: str,
    nonce: str,
    reason: str,
    *,
    primary: bool,
) -> str:
    lines = text.splitlines()
    error_line = f"RendererIOS shading prototype forward self-test failed: {reason}"
    stopped_line = f"RendererIOS stopped the frame loop: {error_line}"
    allowed: set[int] = set()
    for expected, role in ((error_line, "core error"), (stopped_line, "stopped-frame-loop")):
        positions = [index for index, line in enumerate(lines) if line == expected]
        require(
            len(positions) == (1 if primary else min(len(positions), 1)),
            f"Forward failure {role} cardinality is not exact",
        )
        if not primary:
            require(len(positions) <= 1, f"Forward failure {role} is duplicated")
        allowed.update(positions)

    fatal_contracts = (
        ("RendererIOS fatal snapshot:", FATAL_SNAPSHOT_RE),
        ("RendererIOS fatal settled:", FATAL_SETTLED_RE),
        ("RendererIOS fatal post-delta:", FATAL_POST_DELTA_RE),
    )
    fatal_positions: list[int] = []
    fatal_counts: list[int] = []
    for prefix, pattern in fatal_contracts:
        positions = [
            index for index, line in enumerate(lines)
            if line.startswith(prefix)
        ]
        minimum = 1 if primary and prefix == "RendererIOS fatal snapshot:" else 0
        require(
            minimum <= len(positions) <= 1,
            f"Forward failure {prefix.rstrip(':')} cardinality is not exact",
        )
        if positions:
            require(
                pattern.fullmatch(lines[positions[0]]) is not None,
                f"Forward failure {prefix.rstrip(':')} line is malformed",
            )
            allowed.add(positions[0])
            fatal_positions.append(positions[0])
        fatal_counts.append(len(positions))
    require(
        fatal_counts[1] == fatal_counts[2],
        "Forward failure settled/post-delta lines are not a complete pair",
    )
    require(
        fatal_positions == sorted(fatal_positions),
        "Forward failure fatal counter lines are out of order",
    )

    factory_positions = [
        index for index, line in enumerate(lines)
        if line.startswith("RendererIOS Forward factory diag:")
    ]
    if reason not in ("factory-contract-mismatch", "factory-reflection-mismatch"):
        require(not factory_positions, "unexpected Forward factory diagnostics")
    elif factory_positions:
        require(len(factory_positions) == 4, "Forward factory diagnostic cardinality is not exact")
        status = (
            r"(?:ready|device-unavailable|unsupported-capability|library-unavailable|"
            r"function-mismatch|pipeline-creation-failed|pipeline-mismatch|"
            r"reflection-mismatch|internal-failure)"
        )
        schemas = (
            re.compile(
                rf"^RendererIOS Forward factory diag: nonce={nonce} part=top "
                rf"factory={status} validation={status} owner=[01] delta=[0-9]+ "
                r"fn=[0-9]+/[0-9]+/[0-9]+ spec=[0-9]+/[0-9]+$"
            ),
            re.compile(
                rf"^RendererIOS Forward factory diag: nonce={nonce} part=compute "
                r"delta=[0-9]+ bindings=[0-9]+$"
            ),
            re.compile(
                rf"^RendererIOS Forward factory diag: nonce={nonce} part=render0 "
                r"delta=[0-9]+ bindings=[0-9]+/[0-9]+/[0-9]+/[0-9]+/[0-9]+$"
            ),
            re.compile(
                rf"^RendererIOS Forward factory diag: nonce={nonce} part=render1 "
                r"delta=[0-9]+ bindings=[0-9]+/[0-9]+/[0-9]+/[0-9]+/[0-9]+$"
            ),
        )
        for position, schema in zip(factory_positions, schemas):
            require(schema.fullmatch(lines[position]) is not None, "Forward factory diagnostic schema/order is invalid")
            allowed.add(position)
    return "\n".join(
        line for index, line in enumerate(lines) if index not in allowed
    ) + ("\n" if text.endswith("\n") else "")


def _sha256_file(path: pathlib.Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def validate_capture(path: pathlib.Path) -> dict[str, str]:
    try:
        root_stat = path.lstat()
    except FileNotFoundError as error:
        raise ValidationError("Forward capture artifact is missing") from error
    require(path.name == CAPTURE_NAME, "Forward capture has the wrong flat name")
    require(not stat.S_ISLNK(root_stat.st_mode), "Forward capture is a symlink")
    if stat.S_ISREG(root_stat.st_mode):
        digest, size = _sha256_file(path)
        require(0 < size <= MAX_CAPTURE_BYTES, "Forward capture file size is invalid")
        return {
            "capture_name": CAPTURE_NAME,
            "capture_kind": "file",
            "capture_bytes": str(size),
            "capture_manifest_sha256": digest,
        }
    require(stat.S_ISDIR(root_stat.st_mode), "Forward capture has an invalid kind")
    def walk_error(error: OSError) -> None:
        raise error

    entries: list[tuple[bytes, str, str, int]] = []
    for current, directories, files in os.walk(
        path,
        followlinks=False,
        onerror=walk_error,
    ):
        current_path = pathlib.Path(current)
        for name in directories + files:
            candidate = current_path / name
            candidate_stat = candidate.lstat()
            require(
                not stat.S_ISLNK(candidate_stat.st_mode),
                "Forward capture package contains a symlink",
            )
            if stat.S_ISDIR(candidate_stat.st_mode):
                continue
            require(
                stat.S_ISREG(candidate_stat.st_mode),
                "Forward capture package contains a special node",
            )
            relative = candidate.relative_to(path).as_posix()
            require(
                "\n" not in relative and "\r" not in relative,
                "Forward capture package path contains a line break",
            )
            digest, size = _sha256_file(candidate)
            entries.append((os.fsencode(relative), relative, digest, size))
    require(entries, "Forward capture package has no regular-file content")
    entries.sort(key=lambda entry: entry[0])
    total = sum(entry[3] for entry in entries)
    require(0 < total <= MAX_CAPTURE_BYTES, "Forward capture package size is invalid")
    manifest = "".join(
        f"{digest}  {relative}\n" for _, relative, digest, _ in entries
    ).encode("utf-8", errors="surrogateescape")
    return {
        "capture_name": CAPTURE_NAME,
        "capture_kind": "directory",
        "capture_bytes": str(total),
        "capture_manifest_sha256": hashlib.sha256(manifest).hexdigest(),
    }


def validate_pass(
    log: str,
    stderr: str,
    expected_build: str,
    nonce: str,
    artifact: pathlib.Path,
) -> dict[str, int | str]:
    require_nonce(nonce)
    validate_marker_budget(nonce)
    lines = validate_common(log, stderr, expected_build)
    self_test, captures = marker_lines(log)
    terminals = [
        line for line in self_test
        if line.startswith(f"{PREFIX} TERMINAL ")
    ]
    require(len(terminals) == 1, "Forward TERMINAL marker cardinality is not exact")
    waits = parse_terminal_marker(terminals[0], nonce)
    require(waits is not None, "Forward TERMINAL marker is malformed")
    expected = [
        armed(nonce),
        factory_ready(nonce),
        encoded(nonce),
        submitted(nonce),
        terminals[0],
        readback(nonce),
        passed(nonce),
    ]
    require(
        self_test == expected,
        "Forward markers are malformed, duplicated, unknown, or out of order",
    )
    require(len(captures) == 1, "expected exactly one Forward capture marker")
    capture_match = capture_re(nonce).fullmatch(captures[0])
    require(capture_match is not None, "Forward capture marker is malformed")
    positions = [
        lines.index(armed(nonce)),
        lines.index(factory_ready(nonce)),
        lines.index(encoded(nonce)),
        lines.index(submitted(nonce)),
        lines.index(captures[0]),
        lines.index(terminals[0]),
        lines.index(readback(nonce)),
        lines.index(passed(nonce)),
    ]
    require(positions == sorted(positions), "Forward marker sequence is out of order")
    capture = validate_capture(artifact)
    require(
        capture_match.group(1) == capture["capture_kind"],
        "Forward capture kind does not match artifact",
    )
    require(
        capture_match.group(2) == capture["capture_bytes"],
        "Forward capture byte count does not match artifact",
    )
    return {
        "shading_prototype_forward_expected_build": expected_build,
        "shading_prototype_forward_nonce": nonce,
        "shading_prototype_forward_armed_count": 1,
        "shading_prototype_forward_factory_ready_count": 1,
        "shading_prototype_forward_encoded_count": 1,
        "shading_prototype_forward_submitted_count": 1,
        "shading_prototype_forward_capture_acquired_count": 1,
        "shading_prototype_forward_terminal_count": 1,
        "shading_prototype_forward_readback_count": 1,
        "shading_prototype_forward_pass_count": 1,
        "shading_prototype_forward_unsupported_count": 0,
        "shading_prototype_forward_fail_count": 0,
        "shading_prototype_forward_wait_calls": waits,
        "shading_prototype_forward_wait_idle": 0,
        "shading_prototype_forward_readback_bytes": 256,
        "shading_prototype_forward_readback_words": 64,
        "shading_prototype_forward_readback_sha256": EXPECTED_READBACK_SHA256,
        **capture,
    }


def validate_unsupported(
    log: str, stderr: str, expected_build: str, nonce: str
) -> None:
    require_nonce(nonce)
    validate_common(log, stderr, expected_build)
    self_test, captures = marker_lines(log)
    require(
        self_test == [armed(nonce), unsupported(nonce)],
        "unsupported Forward path must be exact ARMED then UNSUPPORTED",
    )
    require(not captures, "unsupported Forward path acquired a capture")


def validate_failure(
    log: str,
    stderr: str,
    expected_build: str,
    nonce: str,
    expected_reason: str,
) -> None:
    require_nonce(nonce)
    require(expected_reason in FAIL_REASONS, "unknown Forward failure reason")
    sanitized_log = _sanitize_failure_stream(
        log, nonce, expected_reason, primary=True
    )
    sanitized_stderr = _sanitize_failure_stream(
        stderr, nonce, expected_reason, primary=False
    )
    validate_common(sanitized_log, sanitized_stderr, expected_build)
    lines = log.splitlines()
    self_test, captures = marker_lines(log)
    expected_failure = failure(nonce, expected_reason)
    require(
        self_test and self_test[-1] == expected_failure,
        "Forward FAIL marker is not exact terminal",
    )
    require(self_test.count(expected_failure) == 1, "Forward FAIL is duplicated")
    require(passed(nonce) not in self_test, "Forward failure also reported PASS")
    require(unsupported(nonce) not in self_test, "Forward failure also reported UNSUPPORTED")
    progress = self_test[:-1]
    canonical_static = [
        armed(nonce),
        factory_ready(nonce),
        encoded(nonce),
        submitted(nonce),
    ]
    static_progress = progress[: min(len(progress), len(canonical_static))]
    require(
        static_progress == canonical_static[: len(static_progress)],
        "Forward failure progress is malformed or out of order",
    )
    require(progress and progress[0] == armed(nonce), "Forward failure preceded ARMED")
    require(len(progress) <= 6, "Forward failure progress contains extra markers")
    if len(progress) >= 5:
        require(
            parse_terminal_marker(progress[4], nonce) is not None,
            "Forward failure TERMINAL marker is malformed",
        )
    if len(progress) == 6:
        require(
            progress[5] == readback(nonce),
            "Forward failure READBACK marker is malformed or out of order",
        )
    require(len(captures) <= 1, "Forward failure has duplicate capture markers")
    require(
        (len(progress), bool(captures)) in FAIL_STAGE_CONTRACTS[expected_reason],
        "Forward failure reason is impossible at the observed progress/capture stage",
    )
    if captures:
        require(capture_re(nonce).fullmatch(captures[0]) is not None, "failure capture malformed")
        require(submitted(nonce) in progress, "Forward capture preceded submit")
        require(
            lines.index(submitted(nonce))
            < lines.index(captures[0])
            < lines.index(expected_failure),
            "Forward failure capture order is not submitted<capture<FAIL",
        )
        if len(progress) >= 5:
            require(
                lines.index(captures[0]) < lines.index(progress[4]),
                "Forward failure capture did not precede TERMINAL",
            )


def validate_absent(log: str) -> None:
    self_test, captures = marker_lines(log)
    require(not self_test, f"unrequested Forward self-test markers: {self_test!r}")
    require(not captures, f"unrequested Forward capture markers: {captures!r}")


def write_summary(path: pathlib.Path | None, values: dict[str, int | str]) -> None:
    payload = "".join(f"{key}={value}\n" for key, value in values.items())
    if path is None:
        sys.stdout.write(payload)
    else:
        path.write_text(payload, encoding="utf-8")


def fixture(
    build: str,
    nonce: str,
    *,
    waits: int = 3,
    capture_kind: str = "directory",
    capture_bytes: int = 6,
) -> str:
    return "\n".join(
        (
            "RendererIOS configured fault mode=none",
            "RendererIOS shell: version=1 profile=Safe features=forward-prototype "
            f"build={build} gpu=Apple deviceFamily=iPhone16,2 iOS=27.0 "
            "faultMode=none savePreviewRoute=cpu-placeholder",
            "RendererIOS diagnostics: ON frames-in-flight=3 "
            "context=IOSMetalContext transport=Tempest",
            armed(nonce),
            factory_ready(nonce),
            encoded(nonce),
            submitted(nonce),
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} nonce={nonce} "
            f"file={CAPTURE_NAME} kind={capture_kind} bytes={capture_bytes}",
            terminal(nonce, waits),
            readback(nonce),
            passed(nonce),
        )
    ) + "\n"


def self_test() -> None:
    build = "0123456789abcdef0123456789abcdef01234567-local"
    nonce = "f25c1b1f0a11ce001badc0de00000001"
    other_nonce = "f25c1b1f0a11ce001badc0de00000002"
    validate_marker_budget(nonce)
    with tempfile.TemporaryDirectory(prefix="rendererios-forward-validator-") as raw:
        root = pathlib.Path(raw)
        artifact = root / CAPTURE_NAME
        artifact.mkdir()
        (artifact / "a.bin").write_bytes(b"alpha")
        (artifact / "z.bin").write_bytes(b"z")
        valid = fixture(build, nonce)
        values = validate_pass(valid, "", build, nonce, artifact)
        require(values["capture_bytes"] == "6", "valid Forward fixture failed")
        require(
            values["shading_prototype_forward_readback_sha256"]
            == EXPECTED_READBACK_SHA256,
            "full 64-word readback digest fixture failed",
        )
        validate_absent("plain RendererIOS smoke log\n")

        capture = (
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} nonce={nonce} "
            f"file={CAPTURE_NAME} kind=directory bytes=6"
        )
        mutations = {
            "missing-armed": valid.replace(armed(nonce) + "\n", ""),
            "missing-factory": valid.replace(factory_ready(nonce) + "\n", ""),
            "missing-encoded": valid.replace(encoded(nonce) + "\n", ""),
            "missing-submit": valid.replace(submitted(nonce) + "\n", ""),
            "missing-capture": valid.replace(capture + "\n", ""),
            "missing-terminal": valid.replace(terminal(nonce, 3) + "\n", ""),
            "missing-readback": valid.replace(readback(nonce) + "\n", ""),
            "missing-pass": valid.replace(passed(nonce) + "\n", ""),
            "duplicate-pass": valid + passed(nonce) + "\n",
            "unknown-prefix": valid.replace(
                encoded(nonce), f"{PREFIX} UNKNOWN case={CASE} nonce={nonce}"
            ),
            "reordered": valid.replace(
                factory_ready(nonce) + "\n" + encoded(nonce),
                encoded(nonce) + "\n" + factory_ready(nonce),
            ),
            "wrong-nonce-one-marker": valid.replace(
                encoded(nonce), encoded(other_nonce)
            ),
            "wrong-nonce-capture": valid.replace(
                f"capture: ACQUIRED case={CASE} nonce={nonce}",
                f"capture: ACQUIRED case={CASE} nonce={other_nonce}",
            ),
            "wrong-build": valid.replace(build, "f" * 40 + "-local"),
            "wrong-abi": valid.replace("metallib-abi=9", "metallib-abi=8"),
            "extra-command-buffer": valid.replace("cb=1", "cb=2"),
            "extra-compute": valid.replace("compute=1", "compute=2"),
            "extra-render": valid.replace("render=1", "render=2"),
            "extra-dispatch": valid.replace("dispatch=1", "dispatch=2"),
            "extra-draw": valid.replace("draws=2", "draws=3"),
            "drawable": valid.replace("drawable=0", "drawable=1"),
            "present": valid.replace("present=0", "present=1"),
            "extra-submit": valid.replace("submits=1", "submits=2"),
            "zero-waits": valid.replace("wait-calls=3", "wait-calls=0"),
            "too-many-waits": valid.replace(
                "wait-calls=3 zero-timeout=3 nonterminal=2",
                "wait-calls=121 zero-timeout=121 nonterminal=120",
            ),
            "nonzero-timeout": valid.replace("zero-timeout=3", "zero-timeout=2"),
            "nonmonotonic": valid.replace("nonterminal=2", "nonterminal=1"),
            "wrong-readback-size": valid.replace("bytes=256", "bytes=252"),
            "wrong-word-count": valid.replace("words=64", "words=63"),
            "not-exact": valid.replace("exact=1", "exact=0"),
            "wrong-readback-sha": valid.replace(
                EXPECTED_READBACK_SHA256, "f" * 64
            ),
            "live-output": valid.replace("output=1/0/1", "output=1/1/0"),
            "live-light-list": valid.replace(
                "light-list=1/0/1", "light-list=1/1/0"
            ),
            "active-capture": valid.replace("capture=1/0/1", "capture=1/1/0"),
            "ordinary-frame": valid + "RendererIOS native Landscape: draws=1\n",
            "tile-conflict": valid
            + "RendererIOS shading prototype tile self-test: ARMED case=x\n",
            "fatal": valid + "RendererIOS fatal: forward probe failed\n",
            "duplicate-capture": valid + capture + "\n",
        }
        survived = []
        for name, mutated in mutations.items():
            try:
                validate_pass(mutated, "", build, nonce, artifact)
            except ValidationError:
                continue
            survived.append(name)
        require(not survived, f"Forward mutation survivors: {survived}")

        unsupported_log = "\n".join(
            valid.splitlines()[:3]
            + [armed(nonce), unsupported(nonce)]
        ) + "\n"
        validate_unsupported(unsupported_log, "", build, nonce)
        for reason in FAIL_REASONS:
            progress_length, acquired = FAIL_STAGE_CONTRACTS[reason][0]
            progress = [
                armed(nonce),
                factory_ready(nonce),
                encoded(nonce),
                submitted(nonce),
                terminal(nonce, 3),
                readback(nonce),
            ][:progress_length]
            failure_lines = valid.splitlines()[:3] + progress[:4]
            if acquired:
                failure_lines.append(capture)
            failure_lines.extend(progress[4:])
            failure_lines.extend(
                (
                    failure(nonce, reason),
                    f"RendererIOS shading prototype forward self-test failed: {reason}",
                    "RendererIOS fatal snapshot: submit-attempts=0 "
                    "submit-accepted=0 present-attempts=0 present-accepted=0",
                    "RendererIOS stopped the frame loop: RendererIOS shading "
                    f"prototype forward self-test failed: {reason}",
                )
            )
            failed = "\n".join(failure_lines) + "\n"
            validate_failure(failed, "", build, nonce, reason)

        factory_diagnostics = [
            f"RendererIOS Forward factory diag: nonce={nonce} part=top "
            "factory=pipeline-mismatch validation=pipeline-mismatch owner=1 "
            "delta=1 fn=0/0/0 spec=0/0",
            f"RendererIOS Forward factory diag: nonce={nonce} part=compute "
            "delta=1 bindings=0",
            f"RendererIOS Forward factory diag: nonce={nonce} part=render0 "
            "delta=0 bindings=0/0/0/0/0",
            f"RendererIOS Forward factory diag: nonce={nonce} part=render1 "
            "delta=0 bindings=0/0/0/0/0",
        ]
        factory_failure = "\n".join(
            valid.splitlines()[:3]
            + [armed(nonce)]
            + factory_diagnostics
            + [
                failure(nonce, "factory-contract-mismatch"),
                "RendererIOS shading prototype forward self-test failed: "
                "factory-contract-mismatch",
                "RendererIOS fatal snapshot: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0",
                "RendererIOS stopped the frame loop: RendererIOS shading "
                "prototype forward self-test failed: factory-contract-mismatch",
            ]
        ) + "\n"
        validate_failure(
            factory_failure,
            "",
            build,
            nonce,
            "factory-contract-mismatch",
        )
        try:
            validate_failure(
                factory_failure.replace(
                    f"factory diag: nonce={nonce}",
                    f"factory diag: nonce={other_nonce}",
                    1,
                ),
                "",
                build,
                nonce,
                "factory-contract-mismatch",
            )
        except ValidationError:
            pass
        else:
            raise ValidationError("foreign-nonce factory diagnostic survived")

        impossible_plan = "\n".join(
            valid.splitlines()[:3]
            + [
                armed(nonce),
                factory_ready(nonce),
                encoded(nonce),
                submitted(nonce),
                capture,
                terminal(nonce, 3),
                readback(nonce),
                failure(nonce, "plan-contract-mismatch"),
                "RendererIOS shading prototype forward self-test failed: "
                "plan-contract-mismatch",
                "RendererIOS fatal snapshot: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0",
                "RendererIOS stopped the frame loop: RendererIOS shading "
                "prototype forward self-test failed: plan-contract-mismatch",
            ]
        ) + "\n"
        try:
            validate_failure(
                impossible_plan,
                "",
                build,
                nonce,
                "plan-contract-mismatch",
            )
        except ValidationError:
            pass
        else:
            raise ValidationError("impossible plan-contract failure stage survived")

        symlink = root / "symlink" / CAPTURE_NAME
        symlink.parent.mkdir()
        symlink.symlink_to(artifact)
        try:
            validate_capture(symlink)
        except ValidationError:
            pass
        else:
            raise ValidationError("symlink Forward capture mutation survived")
    print(f"shading prototype Forward validator self-test passed: {len(mutations)} mutations killed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--expected-build")
    parser.add_argument("--nonce")
    parser.add_argument("--artifact", type=pathlib.Path)
    parser.add_argument("--summary", type=pathlib.Path)
    parser.add_argument("--expect-absent", action="store_true")
    parser.add_argument("--expect-unsupported", action="store_true")
    parser.add_argument("--expect-failure-reason", choices=FAIL_REASONS)
    parser.add_argument("--capture-only", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    modes = sum(
        bool(value)
        for value in (
            args.self_test,
            args.capture_only,
            args.expect_absent,
            args.expect_unsupported,
            args.expect_failure_reason,
        )
    )
    require(modes <= 1, "validator modes are mutually exclusive")
    if args.self_test:
        self_test()
        return 0
    if args.capture_only:
        require(args.artifact is not None, "--capture-only requires --artifact")
        write_summary(args.summary, validate_capture(args.artifact))
        return 0
    require(args.log is not None, "--log is required")
    log = args.log.read_text(encoding="utf-8", errors="replace")
    if args.expect_absent:
        validate_absent(log)
        print("shading prototype Forward markers absent")
        return 0
    require(args.expected_build is not None, "--expected-build is required")
    require(args.nonce is not None, "--nonce is required")
    stderr = (
        args.stderr.read_text(encoding="utf-8", errors="replace")
        if args.stderr is not None
        else ""
    )
    if args.expect_unsupported:
        validate_unsupported(log, stderr, args.expected_build, args.nonce)
        print("shading prototype Forward unsupported terminal passed")
        return 0
    if args.expect_failure_reason:
        validate_failure(
            log, stderr, args.expected_build, args.nonce, args.expect_failure_reason
        )
        print("shading prototype Forward failure terminal passed")
        return 0
    require(args.artifact is not None, "PASS validation requires --artifact")
    values = validate_pass(
        log, stderr, args.expected_build, args.nonce, args.artifact
    )
    write_summary(args.summary, values)
    print("shading prototype Forward self-test log passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
