#!/usr/bin/env python3
"""Validate the isolated RendererIOS shading prototype Tile device gate."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import stat
import sys
import tempfile


CASE = "tile-prototype-v1"
PREFIX = "RendererIOS shading prototype tile self-test:"
CAPTURE_PREFIX = "RendererIOS shading prototype tile capture:"
CAPTURE_NAME = "RendererIOS-tile-prototype-v1.gputrace"
MAX_MARKER_BYTES = 250
MAX_CAPTURE_BYTES = 512 * 1024 * 1024
ARMED = (
    f"{PREFIX} ARMED case={CASE} contract=1 metallib-abi=5 minimum-apple=4 "
    "output=4x4 rgba8-private=1"
)
FACTORY_READY = (
    f"{PREFIX} FACTORY READY case={CASE} pipelines=3 forward=0 runtime-delta=0 "
    "builtin-delta=0 archive-delta=0"
)
ENCODED = (
    f"{PREFIX} ENCODED case={CASE} pass=1 encoder=1 draws=2 opaque=1 alpha=1 "
    "tdispatch=1 vb=168 output=1 mat=0 ib=4 clear-a=0 tgmem=0 size=16 "
    "dispatch=16x16x1 order=opaque,alpha,tile drawable=0 present=0"
)
SUBMITTED = f"{PREFIX} SUBMITTED case={CASE} command-buffers=1 submits=1"
PASS = (
    f"{PREFIX} PASS case={CASE} terminal=completed created=1 live=0 released=1 "
    "wait-idle=0 runtime-delta=0 builtin-delta=0 archive-delta=0"
)
UNSUPPORTED = (
    f"{PREFIX} UNSUPPORTED case={CASE} reason=apple4-required side-effects=0"
)
FAIL_REASONS = (
    "plan-contract-mismatch",
    "snapshot-unavailable",
    "factory-contract-mismatch",
    "factory-counter-mismatch",
    "unsupported-side-effect-mismatch",
    "output-allocation-or-lifetime-mismatch",
    "capture-start-failed",
    "capture-start-ambiguous",
    "command-buffer-creation-failed",
    "native-encode-rejected",
    "encoded-contract-mismatch",
    "submit-exception-ambiguous",
    "capture-acquisition-failed",
    "terminal-fence-error",
    "terminal-lifetime-or-counter-mismatch",
    "fence-nonterminal-after-wait-idle",
    "wait-idle-used",
)
CAPTURE_RE = re.compile(
    rf"^{re.escape(CAPTURE_PREFIX)} ACQUIRED case={CASE} "
    rf"file={re.escape(CAPTURE_NAME)} kind=(file|directory) "
    r"bytes=([1-9][0-9]*)$"
)
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


def only_match(pattern: re.Pattern[str], text: str, name: str) -> re.Match[str]:
    matches = list(pattern.finditer(text))
    require(len(matches) == 1, f"expected exactly one {name}, found {len(matches)}")
    return matches[0]


def marker_lines(log: str) -> tuple[list[str], list[str]]:
    lines = log.splitlines()
    return (
        [line for line in lines if line.startswith(PREFIX)],
        [line for line in lines if line.startswith(CAPTURE_PREFIX)],
    )


def validate_marker_budget() -> None:
    fixed = (ARMED, FACTORY_READY, ENCODED, SUBMITTED, PASS, UNSUPPORTED)
    for marker in fixed:
        require(
            len(marker.encode("utf-8")) <= MAX_MARKER_BYTES,
            f"Tile self-test marker exceeds {MAX_MARKER_BYTES} bytes",
        )
    longest_capture = (
        f"{CAPTURE_PREFIX} ACQUIRED case={CASE} file={CAPTURE_NAME} "
        "kind=directory bytes=18446744073709551615"
    )
    require(
        len(longest_capture.encode("utf-8")) <= MAX_MARKER_BYTES,
        "Tile capture marker exceeds the device log line budget",
    )
    for reason in FAIL_REASONS:
        marker = f"{PREFIX} FAIL case={CASE} reason={reason}"
        require(
            len(marker.encode("utf-8")) <= MAX_MARKER_BYTES,
            "Tile failure marker exceeds the device log line budget",
        )


def validate_common(
    log: str,
    stderr: str,
    expected_build: str,
    *,
    expected_failure: bool = False,
) -> list[str]:
    require(
        re.fullmatch(r"[0-9a-f]{40}(?:-local)?", expected_build) is not None,
        "expected build must be a lowercase SHA, optionally suffixed -local",
    )
    shell = only_match(SHELL_RE, log, "RendererIOS shell marker")
    require(shell.group(1) == expected_build, "RendererIOS shell build is not exact")
    configured = only_match(CONFIGURED_RE, log, "configured fault marker")
    require(
        configured.group(1) == "none",
        "shading prototype Tile self-test requires fault none",
    )
    diagnostics = [
        line for line in log.splitlines()
        if line.startswith("RendererIOS diagnostics:")
    ]
    require(len(diagnostics) == 1, "expected exactly one diagnostics marker")
    require(
        diagnostics[0].startswith("RendererIOS diagnostics: ON frames-in-flight=")
        and diagnostics[0].endswith(" context=IOSMetalContext transport=Tempest"),
        "shading prototype Tile self-test requires diagnostics ON",
    )
    shutdown_lines = [
        line for line in log.splitlines()
        if line.startswith("RendererIOS shutdown counters:")
    ]
    require(
        len(shutdown_lines) <= 1,
        "shading prototype Tile evidence contains duplicate shutdown counters",
    )
    if shutdown_lines:
        require(
            SHUTDOWN_COUNTERS_RE.fullmatch(shutdown_lines[0]) is not None,
            "shading prototype Tile shutdown counters are not exact zero",
        )
    for prefix in CONFLICT_PREFIXES:
        require(prefix not in log, f"Tile self-test ran with conflicting marker: {prefix}")
    require(
        "riosForward" not in log
        and "ForwardPlus" not in log
        and "Forward+" not in log,
        "Tile self-test evidence contains a Forward runtime marker",
    )
    ordinary = [
        line for line in log.splitlines()
        if line.startswith(ORDINARY_FRAME_PREFIXES)
    ]
    require(
        not ordinary,
        f"Tile self-test admitted ordinary frame/present work: {ordinary!r}",
    )
    deny_log = log
    if expected_failure:
        fatal_contracts = (
            ("RendererIOS fatal snapshot:", FATAL_SNAPSHOT_RE),
            ("RendererIOS fatal settled:", FATAL_SETTLED_RE),
            ("RendererIOS fatal post-delta:", FATAL_POST_DELTA_RE),
        )
        allowed_fatal_lines: set[str] = set()
        fatal_positions: list[int] = []
        for prefix, pattern in fatal_contracts:
            candidates = [
                (index, line)
                for index, line in enumerate(log.splitlines())
                if line.startswith(prefix)
            ]
            expected_minimum = 1 if prefix == "RendererIOS fatal snapshot:" else 0
            require(
                expected_minimum <= len(candidates) <= 1,
                f"Tile failure {prefix.rstrip(':')} cardinality is not exact",
            )
            if not candidates:
                continue
            index, line = candidates[0]
            require(
                pattern.fullmatch(line) is not None,
                f"Tile failure {prefix.rstrip(':')} line is malformed",
            )
            allowed_fatal_lines.add(line)
            fatal_positions.append(index)
        settled_count = sum(
            line.startswith("RendererIOS fatal settled:")
            for line in allowed_fatal_lines
        )
        post_delta_count = sum(
            line.startswith("RendererIOS fatal post-delta:")
            for line in allowed_fatal_lines
        )
        require(
            settled_count == post_delta_count,
            "Tile failure settled/post-delta lines are not a complete pair",
        )
        require(
            fatal_positions == sorted(fatal_positions),
            "Tile failure fatal counter lines are out of order",
        )
        deny_log = "\n".join(
            line for line in log.splitlines()
            if line not in allowed_fatal_lines
        )
    denied = DENY_RE.search(deny_log + "\n" + stderr)
    require(
        denied is None,
        "fatal/crash signature in Tile self-test evidence"
        if denied is None
        else f"fatal/crash signature in Tile self-test evidence: {denied.group(0)!r}",
    )
    return log.splitlines()


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
        raise ValidationError("Tile capture artifact is missing") from error
    require(path.name == CAPTURE_NAME, "Tile capture artifact has the wrong flat name")
    require(not stat.S_ISLNK(root_stat.st_mode), "Tile capture artifact is a symlink")

    if stat.S_ISREG(root_stat.st_mode):
        digest, size = _sha256_file(path)
        require(0 < size <= MAX_CAPTURE_BYTES, "Tile capture file size is invalid")
        return {
            "capture_name": CAPTURE_NAME,
            "capture_kind": "file",
            "capture_bytes": str(size),
            "capture_manifest_sha256": digest,
        }

    require(
        stat.S_ISDIR(root_stat.st_mode),
        "Tile capture artifact is neither a file nor directory",
    )

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
                "Tile capture package contains a symlink",
            )
            if stat.S_ISDIR(candidate_stat.st_mode):
                continue
            require(
                stat.S_ISREG(candidate_stat.st_mode),
                "Tile capture package contains a special node",
            )
            relative = candidate.relative_to(path).as_posix()
            require(
                "\n" not in relative and "\r" not in relative,
                "Tile capture package path contains a line break",
            )
            digest, size = _sha256_file(candidate)
            entries.append((os.fsencode(relative), relative, digest, size))
    require(entries, "Tile capture package has no regular-file content")
    entries.sort(key=lambda entry: entry[0])
    total = sum(entry[3] for entry in entries)
    require(0 < total <= MAX_CAPTURE_BYTES, "Tile capture package size is invalid")
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
    artifact: pathlib.Path,
) -> dict[str, int | str]:
    lines = validate_common(log, stderr, expected_build)
    self_test, captures = marker_lines(log)
    expected = [ARMED, FACTORY_READY, ENCODED, SUBMITTED, PASS]
    require(
        self_test == expected,
        "Tile markers are missing, malformed, duplicated, unknown, or out of order",
    )
    require(len(captures) == 1, "expected exactly one Tile capture marker")
    capture_match = CAPTURE_RE.fullmatch(captures[0])
    require(capture_match is not None, "Tile capture marker is malformed")
    positions = [
        lines.index(ARMED),
        lines.index(FACTORY_READY),
        lines.index(ENCODED),
        lines.index(SUBMITTED),
        lines.index(captures[0]),
        lines.index(PASS),
    ]
    require(positions == sorted(positions), "Tile marker sequence is out of order")
    capture = validate_capture(artifact)
    require(
        capture_match.group(1) == capture["capture_kind"],
        "Tile capture marker kind does not match the artifact",
    )
    require(
        capture_match.group(2) == capture["capture_bytes"],
        "Tile capture marker byte count does not match the artifact",
    )
    return {
        "shading_prototype_tile_expected_build": expected_build,
        "shading_prototype_tile_armed_count": 1,
        "shading_prototype_tile_factory_ready_count": 1,
        "shading_prototype_tile_encoded_count": 1,
        "shading_prototype_tile_submitted_count": 1,
        "shading_prototype_tile_capture_acquired_count": 1,
        "shading_prototype_tile_pass_count": 1,
        "shading_prototype_tile_unsupported_count": 0,
        "shading_prototype_tile_fail_count": 0,
        "shading_prototype_tile_contract": 1,
        "shading_prototype_tile_metallib_abi": 5,
        "shading_prototype_tile_pipelines": 3,
        "shading_prototype_tile_forward": 0,
        "shading_prototype_tile_passes": 1,
        "shading_prototype_tile_encoders": 1,
        "shading_prototype_tile_draws": 2,
        "shading_prototype_tile_tile_dispatches": 1,
        "shading_prototype_tile_vertex_bytes": 168,
        "shading_prototype_tile_created": 1,
        "shading_prototype_tile_live": 0,
        "shading_prototype_tile_released": 1,
        "shading_prototype_tile_wait_idle": 0,
        "shading_prototype_tile_runtime_delta": 0,
        "shading_prototype_tile_builtin_delta": 0,
        "shading_prototype_tile_archive_delta": 0,
        **capture,
    }


def validate_unsupported(log: str, stderr: str, expected_build: str) -> None:
    validate_common(log, stderr, expected_build)
    self_test, captures = marker_lines(log)
    require(
        self_test == [ARMED, UNSUPPORTED],
        "unsupported Tile path must contain exactly ARMED then UNSUPPORTED",
    )
    require(not captures, "unsupported Tile path acquired a capture")


def validate_failure(
    log: str,
    stderr: str,
    expected_build: str,
    expected_reason: str,
) -> None:
    require(expected_reason in FAIL_REASONS, "expected Tile failure reason is not frozen")
    lines = validate_common(
        log,
        stderr,
        expected_build,
        expected_failure=True,
    )
    self_test, captures = marker_lines(log)
    failure = f"{PREFIX} FAIL case={CASE} reason={expected_reason}"
    require(self_test and self_test[-1] == failure, "Tile FAIL marker is not exact terminal")
    require(self_test.count(failure) == 1, "Tile FAIL marker is duplicated")
    operation_lines = [
        line for line in lines
        if line.startswith("RendererIOS shading prototype tile self-test failed")
    ]
    require(
        len(operation_lines) == 1,
        "Tile failure must contain exactly one fail-stop operation line",
    )
    require(
        lines.index(failure) < lines.index(operation_lines[0]),
        "Tile fail-stop operation precedes its frozen FAIL marker",
    )
    fatal_counter_lines = [
        line for line in lines
        if line.startswith(
            (
                "RendererIOS fatal snapshot:",
                "RendererIOS fatal settled:",
                "RendererIOS fatal post-delta:",
            )
        )
    ]
    require(
        all(lines.index(operation_lines[0]) < lines.index(line)
            for line in fatal_counter_lines),
        "Tile fatal counters precede the fail-stop operation",
    )
    progress = self_test[:-1]
    canonical = [ARMED, FACTORY_READY, ENCODED, SUBMITTED]
    require(
        progress == canonical[: len(progress)],
        "Tile failure progress is malformed, duplicated, or out of order",
    )
    require(ARMED in progress, "Tile failure occurred before ARMED")
    require(PASS not in lines and UNSUPPORTED not in lines, "Tile failure has another terminal")
    require(len(captures) <= 1, "Tile failure contains duplicate capture markers")
    if captures:
        require(CAPTURE_RE.fullmatch(captures[0]) is not None, "failure capture is malformed")
        require(SUBMITTED in progress, "Tile failure acquired capture before SUBMITTED")
        require(
            lines.index(SUBMITTED) < lines.index(captures[0]) < lines.index(failure),
            "Tile failure capture order is invalid",
        )


def validate_absent(log: str) -> None:
    self_test, captures = marker_lines(log)
    require(not self_test, f"unrequested Tile self-test markers: {self_test!r}")
    require(not captures, f"unrequested Tile capture markers: {captures!r}")


def write_summary(path: pathlib.Path | None, values: dict[str, int | str]) -> None:
    payload = "".join(f"{key}={value}\n" for key, value in values.items())
    if path is None:
        sys.stdout.write(payload)
    else:
        path.write_text(payload, encoding="utf-8")


def fixture(build: str, capture_kind: str = "directory", capture_bytes: int = 6) -> str:
    return "\n".join(
        (
            "RendererIOS configured fault mode=none",
            "RendererIOS shell: version=1 profile=Safe features=tile-prototype "
            f"build={build} gpu=Apple deviceFamily=iPhone16,2 iOS=26.4 "
            "faultMode=none savePreviewRoute=cpu-placeholder",
            "RendererIOS diagnostics: ON frames-in-flight=3 "
            "context=IOSMetalContext transport=Tempest",
            ARMED,
            FACTORY_READY,
            ENCODED,
            SUBMITTED,
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} file={CAPTURE_NAME} "
            f"kind={capture_kind} bytes={capture_bytes}",
            PASS,
        )
    ) + "\n"


def self_test() -> None:
    build = "0123456789abcdef0123456789abcdef01234567-local"
    validate_marker_budget()
    with tempfile.TemporaryDirectory(prefix="rendererios-tile-validator-") as root_raw:
        root = pathlib.Path(root_raw)
        artifact = root / CAPTURE_NAME
        artifact.mkdir()
        (artifact / "a.bin").write_bytes(b"alpha")
        (artifact / "z.bin").write_bytes(b"z")
        valid = fixture(build)
        values = validate_pass(valid, "", build, artifact)
        require(values["capture_bytes"] == "6", "valid Tile fixture failed")
        validate_pass(
            valid
            + "RendererIOS shutdown counters: outcome=clean "
            "submit-attempts=0 submit-accepted=0 "
            "present-attempts=0 present-accepted=0\n",
            "",
            build,
            artifact,
        )
        validate_absent("plain RendererIOS smoke log\n")

        mutations = {
            "missing-armed": valid.replace(ARMED + "\n", ""),
            "missing-factory": valid.replace(FACTORY_READY + "\n", ""),
            "missing-encoded": valid.replace(ENCODED + "\n", ""),
            "missing-submitted": valid.replace(SUBMITTED + "\n", ""),
            "missing-capture": valid.replace(
                f"{CAPTURE_PREFIX} ACQUIRED case={CASE} file={CAPTURE_NAME} "
                "kind=directory bytes=6\n",
                "",
            ),
            "missing-pass": valid.replace(PASS + "\n", ""),
            "duplicate-pass": valid + PASS + "\n",
            "reordered": valid.replace(
                FACTORY_READY + "\n" + ENCODED,
                ENCODED + "\n" + FACTORY_READY,
            ),
            "unknown": valid.replace(SUBMITTED, f"{PREFIX} UNKNOWN case={CASE}"),
            "wrong-build": valid.replace(build, "f" * 40 + "-local"),
            "wrong-contract": valid.replace("contract=1", "contract=2"),
            "wrong-abi": valid.replace("metallib-abi=5", "metallib-abi=4"),
            "forward": valid.replace("forward=0", "forward=1"),
            "extra-pipeline": valid.replace("pipelines=3", "pipelines=4"),
            "extra-pass": valid.replace("pass=1", "pass=2"),
            "extra-encoder": valid.replace("encoder=1", "encoder=2"),
            "extra-draw": valid.replace("draws=2", "draws=3"),
            "wrong-tile-dispatch": valid.replace("tdispatch=1", "tdispatch=0"),
            "wrong-vertex-bytes": valid.replace("vb=168", "vb=160"),
            "material-texture": valid.replace("mat=0", "mat=1"),
            "wrong-imageblock": valid.replace("ib=4", "ib=8"),
            "nontransparent-clear": valid.replace("clear-a=0", "clear-a=1"),
            "threadgroup-memory": valid.replace("tgmem=0", "tgmem=4"),
            "wrong-tile-size": valid.replace("size=16", "size=8"),
            "wrong-order": valid.replace(
                "order=opaque,alpha,tile",
                "order=opaque,tile,alpha",
            ),
            "drawable": valid.replace("drawable=0", "drawable=1"),
            "present": valid.replace("present=0", "present=1"),
            "extra-command-buffer": valid.replace("command-buffers=1", "command-buffers=2"),
            "extra-submit": valid.replace("submits=1", "submits=2"),
            "wrong-created": valid.replace("created=1", "created=2"),
            "live-owner": valid.replace("live=0 released=1", "live=1 released=0"),
            "wait-idle": valid.replace("wait-idle=0", "wait-idle=1"),
            "runtime-delta": valid.replace("runtime-delta=0", "runtime-delta=1", 1),
            "wrong-capture-name": valid.replace(CAPTURE_NAME, "wrong.gputrace"),
            "zero-capture": valid.replace("kind=directory bytes=6", "kind=directory bytes=0"),
            "duplicate-capture": valid + (
                f"{CAPTURE_PREFIX} ACQUIRED case={CASE} file={CAPTURE_NAME} "
                "kind=directory bytes=6\n"
            ),
            "ordinary-frame": valid + "RendererIOS native Landscape: draws=1\n",
            "forward-marker": valid + "riosForwardPlusFragment\n",
            "bink-conflict": valid + "RendererIOS Bink self-test: ARMED case=x\n",
            "allocator-conflict": valid + (
                "RendererIOS resource allocator self-test: ARMED case=x\n"
            ),
            "clear-conflict": valid + "RendererIOS clear-only pass self-test: ARMED\n",
            "archive-conflict": valid + "RendererIOS pipeline archive test-mode: mode=cold\n",
            "fatal": valid + "RendererIOS fatal: tile probe failed\n",
            "nonzero-shutdown": valid + (
                "RendererIOS shutdown counters: outcome=clean "
                "submit-attempts=1 submit-accepted=1 "
                "present-attempts=0 present-accepted=0\n"
            ),
            "duplicate-shutdown": valid + (
                "RendererIOS shutdown counters: outcome=clean "
                "submit-attempts=0 submit-accepted=0 "
                "present-attempts=0 present-accepted=0\n"
                "RendererIOS shutdown counters: outcome=clean "
                "submit-attempts=0 submit-accepted=0 "
                "present-attempts=0 present-accepted=0\n"
            ),
        }
        for name, mutated in mutations.items():
            try:
                validate_pass(mutated, "", build, artifact)
            except ValidationError:
                continue
            raise ValidationError(f"Tile mutation survived: {name}")

        unsupported = fixture(build).replace(
            FACTORY_READY + "\n" + ENCODED + "\n" + SUBMITTED + "\n"
            f"{CAPTURE_PREFIX} ACQUIRED case={CASE} file={CAPTURE_NAME} "
            "kind=directory bytes=6\n" + PASS,
            UNSUPPORTED,
        )
        validate_unsupported(unsupported, "", build)
        for name, mutated in {
            "pass": unsupported + PASS + "\n",
            "capture": unsupported + (
                f"{CAPTURE_PREFIX} ACQUIRED case={CASE} file={CAPTURE_NAME} "
                "kind=directory bytes=6\n"
            ),
            "side-effect": unsupported.replace("side-effects=0", "side-effects=1"),
        }.items():
            try:
                validate_unsupported(mutated, "", build)
            except ValidationError:
                continue
            raise ValidationError(f"unsupported Tile mutation survived: {name}")

        for index, reason in enumerate(FAIL_REASONS):
            progress = [ARMED, FACTORY_READY, ENCODED, SUBMITTED][: 1 + index % 4]
            failed = fixture(build).split(ARMED, 1)[0]
            failed += "\n".join(progress) + "\n"
            if len(progress) == 4 and index % 2:
                failed += (
                    f"{CAPTURE_PREFIX} ACQUIRED case={CASE} file={CAPTURE_NAME} "
                    "kind=directory bytes=6\n"
                )
            failed += f"{PREFIX} FAIL case={CASE} reason={reason}\n"
            failed += (
                "RendererIOS shading prototype tile self-test failed: fixture-detail\n"
                "RendererIOS fatal snapshot: submit-attempts=0 submit-accepted=0 "
                "present-attempts=0 present-accepted=0\n"
                "RendererIOS fatal settled: idle-confirmed=1 submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n"
                "RendererIOS fatal post-delta: submit-attempts=0 submit-accepted=0 "
                "present-attempts=0 present-accepted=0\n"
            )
            validate_failure(failed, "", build, reason)

        without_settled_pair = "\n".join(
            line for line in failed.splitlines()
            if not line.startswith(
                (
                    "RendererIOS fatal settled:",
                    "RendererIOS fatal post-delta:",
                )
            )
        ) + "\n"
        validate_failure(without_settled_pair, "", build, FAIL_REASONS[-1])

        invalid_failure = (
            failed
            + "RendererIOS fatal unrelated-renderer-failure\n"
        )
        failure_mutations = {
            "unrelated-fatal": invalid_failure,
            "fatal-snapshot-injection": failed.replace(
                "present-accepted=0\nRendererIOS fatal settled:",
                "present-accepted=0 SIGABRT\nRendererIOS fatal settled:",
                1,
            ),
            "duplicate-fatal-snapshot": failed.replace(
                "RendererIOS fatal settled:",
                "RendererIOS fatal snapshot: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n"
                "RendererIOS fatal settled:",
                1,
            ),
            "missing-fatal-snapshot": failed.replace(
                "RendererIOS fatal snapshot: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n",
                "",
            ),
            "orphan-fatal-settled": failed.replace(
                "RendererIOS fatal post-delta: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n",
                "",
            ),
            "orphan-fatal-post-delta": failed.replace(
                "RendererIOS fatal settled: idle-confirmed=1 submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n",
                "",
            ),
            "reordered-fatal-pair": failed.replace(
                "RendererIOS fatal settled: idle-confirmed=1 submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n"
                "RendererIOS fatal post-delta: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n",
                "RendererIOS fatal post-delta: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n"
                "RendererIOS fatal settled: idle-confirmed=1 submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n",
            ),
            "snapshot-before-operation": failed.replace(
                "RendererIOS shading prototype tile self-test failed: "
                "fixture-detail\n"
                "RendererIOS fatal snapshot: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n",
                "RendererIOS fatal snapshot: submit-attempts=0 "
                "submit-accepted=0 present-attempts=0 present-accepted=0\n"
                "RendererIOS shading prototype tile self-test failed: "
                "fixture-detail\n",
            ),
            "nonzero-fatal-snapshot": failed.replace(
                "RendererIOS fatal snapshot: submit-attempts=0",
                "RendererIOS fatal snapshot: submit-attempts=1",
            ),
            "nonzero-fatal-settled": failed.replace(
                "RendererIOS fatal settled: idle-confirmed=1 submit-attempts=0",
                "RendererIOS fatal settled: idle-confirmed=1 submit-attempts=1",
            ),
            "unconfirmed-fatal-settled": failed.replace(
                "RendererIOS fatal settled: idle-confirmed=1",
                "RendererIOS fatal settled: idle-confirmed=0",
            ),
            "nonzero-fatal-post-delta": failed.replace(
                "RendererIOS fatal post-delta: submit-attempts=0",
                "RendererIOS fatal post-delta: submit-attempts=1",
            ),
            "operation-line-injection": failed.replace(
                "self-test failed: fixture-detail",
                "self-test failed: fixture-detail SIGABRT",
            ),
        }
        for name, mutated in failure_mutations.items():
            try:
                validate_failure(mutated, "", build, FAIL_REASONS[-1])
            except ValidationError:
                continue
            raise ValidationError(f"{name} Tile failure mutation survived")

        symlink = root / "symlink" / CAPTURE_NAME
        symlink.parent.mkdir()
        symlink.symlink_to(artifact)
        try:
            validate_capture(symlink)
        except ValidationError:
            pass
        else:
            raise ValidationError("symlink Tile capture mutation survived")

        original_walk = os.walk

        def failing_walk(*args: object, **kwargs: object) -> object:
            onerror = kwargs.get("onerror")
            assert callable(onerror)
            onerror(OSError("fixture traversal failure"))
            return iter(())

        os.walk = failing_walk  # type: ignore[assignment]
        try:
            try:
                validate_capture(artifact)
            except OSError:
                pass
            else:
                raise ValidationError("capture traversal failure mutation survived")
        finally:
            os.walk = original_walk

    print("shading prototype Tile self-test validator passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--expected-build")
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
        require(
            all(
                value is None
                for value in (
                    args.log,
                    args.stderr,
                    args.expected_build,
                    args.artifact,
                    args.summary,
                )
            ),
            "--self-test accepts no evidence arguments",
        )
        self_test()
        return 0
    if args.capture_only:
        require(args.artifact is not None, "--capture-only requires --artifact")
        require(
            args.log is None and args.stderr is None and args.expected_build is None,
            "--capture-only accepts no log/build arguments",
        )
        write_summary(args.summary, validate_capture(args.artifact))
        return 0
    require(args.log is not None, "--log is required")
    log = args.log.read_text(encoding="utf-8", errors="replace")
    if args.expect_absent:
        require(
            args.stderr is None
            and args.expected_build is None
            and args.artifact is None
            and args.summary is None,
            "--expect-absent accepts only --log",
        )
        validate_absent(log)
        print("shading prototype Tile self-test markers absent")
        return 0
    require(args.expected_build is not None, "--expected-build is required")
    stderr = (
        args.stderr.read_text(encoding="utf-8", errors="replace")
        if args.stderr is not None
        else ""
    )
    if args.expect_unsupported:
        require(args.artifact is None and args.summary is None, "unsupported accepts no artifact")
        validate_unsupported(log, stderr, args.expected_build)
        print("shading prototype Tile unsupported terminal passed")
        return 0
    if args.expect_failure_reason:
        require(args.artifact is None and args.summary is None, "failure accepts no artifact")
        validate_failure(log, stderr, args.expected_build, args.expect_failure_reason)
        print("shading prototype Tile failure terminal passed")
        return 0
    require(args.artifact is not None, "PASS validation requires --artifact")
    values = validate_pass(log, stderr, args.expected_build, args.artifact)
    write_summary(args.summary, values)
    print("shading prototype Tile self-test log passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
