#!/usr/bin/env python3
"""Validate cross-run evidence for the semantic Inventory archive gate."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys
import tempfile


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def key_values(path: pathlib.Path) -> dict[str, str]:
    require(
        path.is_file() and not path.is_symlink(),
        f"evidence file is missing or non-regular: {path}",
    )
    values: dict[str, str] = {}
    for line in path.read_text(errors="replace").splitlines():
        require("=" in line, f"evidence line is not key=value: {line!r}")
        key, value = line.split("=", 1)
        require(key and key not in values, f"duplicate evidence key: {key}")
        values[key] = value
    return values


def canonical_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    require(path.is_absolute(), f"{label} evidence path must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ValidationError(f"{label} evidence path cannot be resolved") from error
    require(resolved.is_dir(), f"{label} evidence path is not a directory")
    return resolved


def sha256(path: pathlib.Path) -> str:
    require(
        path.is_file() and not path.is_symlink(),
        f"cache evidence is missing or non-regular: {path}",
    )
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_provenance(metallib_sha256: str) -> bytes:
    return (
        "renderer=RendererIOS\n"
        "provenance-schema=1\n"
        "cache-schema=1\n"
        "pipeline-key-abi=1\n"
        "metallib-abi=4\n"
        f"metallib-sha256={metallib_sha256}\n"
        "archive-file=RendererIOS-abi-4.binaryarchive\n"
    ).encode()


def require_semantic_result(
    path: pathlib.Path, phase: str, source_sha: str
) -> dict[str, str]:
    values = key_values(path)
    exact = {
        "result": "PASS",
        "source_sha": source_sha,
        "save_slot": "1",
        "script_mode": "save-ui-lifecycle-v1",
        "pipeline_archive_phase": phase,
        "device_process_stopped": "1",
        "device_foreground_parked": "1",
        "durable_zero_stable": "1",
        "durable_zero_final_zero": "1",
    }
    for key, expected in exact.items():
        require(
            values.get(key) == expected,
            f"{phase} result {key}: expected {expected}, found {values.get(key)}",
        )
    try:
        stable_seconds = int(values["durable_zero_stable_seconds"], 10)
        required_seconds = int(values["durable_zero_required_stable_seconds"], 10)
    except (KeyError, ValueError) as error:
        raise ValidationError(f"{phase} durable-zero duration is invalid") from error
    require(
        stable_seconds >= required_seconds >= 90,
        f"{phase} durable-zero stable window is shorter than 90 seconds",
    )
    return values


def require_summary(path: pathlib.Path, phase: str) -> None:
    values = key_values(path)
    expected = {
        "phase": phase,
        "scenario": "save",
        "runtime_source": "0",
        "runtime_compute": "0",
        "runtime_render": "6" if phase == "inventory-cold" else "4",
        "archive_load_failures": "0",
        "archive_rebuilds": "0",
        "archive_render_hits": "2" if phase == "inventory-cold" else "4",
        "archive_render_misses": "2" if phase == "inventory-cold" else "0",
        "archive_render_adds": "2" if phase == "inventory-cold" else "0",
        "archive_render_fallbacks": "0",
        "archive_flush_attempts": "1" if phase == "inventory-cold" else "0",
        "archive_flush_successes": "1" if phase == "inventory-cold" else "0",
        "archive_flush_failures": "0",
    }
    for key, expected_value in expected.items():
        require(
            values.get(key) == expected_value,
            f"{phase} summary {key}: expected {expected_value}, "
            f"found {values.get(key)}",
        )
    try:
        last_present = int(values["runtime_last_present"], 10)
        transition_present = int(
            values["runtime_render_transition_present"], 10
        )
    except (KeyError, ValueError) as error:
        raise ValidationError(f"{phase} runtime presents are invalid") from error
    require(last_present >= 300, f"{phase} runtime did not reach present 300")
    require(
        1 <= transition_present <= 300,
        f"{phase} runtime did not reach final render by present 300",
    )


def require_cache_bundle(
    directory: pathlib.Path, metallib_sha256: str, label: str
) -> tuple[bytes, bytes]:
    archive = directory / "RendererIOS-abi-4.binaryarchive"
    provenance = directory / "RendererIOS-abi-4.provenance"
    cache = key_values(directory / "cache-after.txt")
    require(
        set(cache) == {"archive_sha256", "archive_bytes", "provenance_sha256"},
        f"{label} cache summary schema is not exact",
    )
    archive_bytes = (
        archive.read_bytes()
        if archive.is_file() and not archive.is_symlink()
        else b""
    )
    provenance_bytes = (
        provenance.read_bytes()
        if provenance.is_file() and not provenance.is_symlink()
        else b""
    )
    require(archive_bytes, f"{label} archive is empty or missing")
    require(
        provenance_bytes == expected_provenance(metallib_sha256),
        f"{label} provenance is not bound to the expected archive ABI/metallib",
    )
    try:
        recorded_bytes = int(cache["archive_bytes"], 10)
    except ValueError as error:
        raise ValidationError(f"{label} archive byte count is invalid") from error
    require(
        cache["archive_sha256"] == sha256(archive),
        f"{label} cache archive SHA-256 is stale",
    )
    require(
        recorded_bytes == len(archive_bytes) and recorded_bytes > 0,
        f"{label} cache archive byte count is stale",
    )
    require(
        cache["provenance_sha256"] == sha256(provenance),
        f"{label} cache provenance SHA-256 is stale",
    )
    return archive_bytes, provenance_bytes


def validate(
    baseline: pathlib.Path,
    cold: pathlib.Path,
    warm: pathlib.Path,
    source_sha: str,
    metallib_sha256: str,
) -> None:
    require(
        re.fullmatch(r"[0-9a-f]{40}", source_sha) is not None,
        "expected source SHA must be exact lowercase hexadecimal",
    )
    require(
        re.fullmatch(r"[0-9a-f]{64}", metallib_sha256) is not None,
        "expected metallib SHA-256 must be exact lowercase hexadecimal",
    )
    baseline = canonical_directory(baseline, "baseline")
    cold = canonical_directory(cold, "inventory-cold")
    warm = canonical_directory(warm, "inventory-warm")
    require(
        len({baseline, cold, warm}) == 3,
        "baseline/cold/warm evidence directories must be distinct",
    )

    baseline_result = key_values(baseline / "result.txt")
    baseline_exact = {
        "result": "PASS",
        "source_sha": source_sha,
        "scenario": "save",
        "save_slot": "1",
        "baseline": "PASS",
        "device_process_stopped": "1",
    }
    for key, expected in baseline_exact.items():
        require(
            baseline_result.get(key) == expected,
            f"baseline result {key}: expected {expected}, "
            f"found {baseline_result.get(key)}",
        )
    cold_result = require_semantic_result(
        cold / "result.txt", "inventory-cold", source_sha
    )
    warm_result = require_semantic_result(
        warm / "result.txt", "inventory-warm", source_sha
    )
    require(
        cold_result.get("nonce") != warm_result.get("nonce")
        and re.fullmatch(r"[0-9a-f]{32}", cold_result.get("nonce", ""))
        is not None
        and re.fullmatch(r"[0-9a-f]{32}", warm_result.get("nonce", ""))
        is not None,
        "semantic evidence nonces must be distinct and exact",
    )
    require_summary(cold / "archive-summary.txt", "inventory-cold")
    require_summary(warm / "archive-summary.txt", "inventory-warm")

    baseline_archive, baseline_provenance = require_cache_bundle(
        baseline / "cold", metallib_sha256, "baseline"
    )
    cold_archive, cold_provenance = require_cache_bundle(
        cold, metallib_sha256, "inventory-cold"
    )
    warm_archive, warm_provenance = require_cache_bundle(
        warm, metallib_sha256, "inventory-warm"
    )
    require(
        baseline_archive != cold_archive,
        "inventory-cold did not change the baseline archive",
    )
    require(
        cold_archive == warm_archive,
        "inventory-warm changed the inventory-cold archive",
    )
    require(
        baseline_provenance == cold_provenance == warm_provenance,
        "pipeline archive provenance changed across semantic phases",
    )


def write_result(
    path: pathlib.Path, phase: str, source_sha: str, nonce: str
) -> None:
    path.write_text(
        "\n".join(
            (
                "result=PASS",
                f"source_sha={source_sha}",
                "save_slot=1",
                "script_mode=save-ui-lifecycle-v1",
                f"pipeline_archive_phase={phase}",
                f"nonce={nonce}",
                "device_process_stopped=1",
                "device_foreground_parked=1",
                "durable_zero_stable=1",
                "durable_zero_final_zero=1",
                "durable_zero_stable_seconds=90",
                "durable_zero_required_stable_seconds=90",
            )
        )
        + "\n"
    )


def write_cache_fixture(directory: pathlib.Path) -> None:
    archive = directory / "RendererIOS-abi-4.binaryarchive"
    provenance = directory / "RendererIOS-abi-4.provenance"
    (directory / "cache-after.txt").write_text(
        f"archive_sha256={sha256(archive)}\n"
        f"archive_bytes={archive.stat().st_size}\n"
        f"provenance_sha256={sha256(provenance)}\n"
    )


def write_summary_fixture(path: pathlib.Path, phase: str) -> None:
    values = {
        "phase": phase,
        "scenario": "save",
        "runtime_source": "0",
        "runtime_compute": "0",
        "runtime_render": "6" if phase == "inventory-cold" else "4",
        "runtime_last_present": "600",
        "runtime_render_transition_present": "200",
        "archive_load_failures": "0",
        "archive_rebuilds": "0",
        "archive_render_hits": "2" if phase == "inventory-cold" else "4",
        "archive_render_misses": "2" if phase == "inventory-cold" else "0",
        "archive_render_adds": "2" if phase == "inventory-cold" else "0",
        "archive_render_fallbacks": "0",
        "archive_flush_attempts": "1" if phase == "inventory-cold" else "0",
        "archive_flush_successes": "1" if phase == "inventory-cold" else "0",
        "archive_flush_failures": "0",
    }
    path.write_text("".join(f"{key}={value}\n" for key, value in values.items()))


def expect_validation_failure(callback, message: str) -> None:
    try:
        callback()
    except ValidationError:
        return
    raise ValidationError(message)


def self_test() -> None:
    source_sha = "1" * 40
    mixed_source_sha = "2" * 40
    metallib_sha256 = "a" * 64
    wrong_metallib_sha256 = "b" * 64
    cold_nonce = "0" * 32
    warm_nonce = "f" * 32
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        baseline = root / "baseline"
        cold = root / "cold"
        warm = root / "warm"
        (baseline / "cold").mkdir(parents=True)
        cold.mkdir()
        warm.mkdir()
        (baseline / "result.txt").write_text(
            "result=PASS\n"
            f"source_sha={source_sha}\n"
            "scenario=save\n"
            "save_slot=1\n"
            "baseline=PASS\n"
            "device_process_stopped=1\n"
        )
        write_result(
            cold / "result.txt", "inventory-cold", source_sha, cold_nonce
        )
        write_result(
            warm / "result.txt", "inventory-warm", source_sha, warm_nonce
        )
        write_summary_fixture(cold / "archive-summary.txt", "inventory-cold")
        write_summary_fixture(warm / "archive-summary.txt", "inventory-warm")
        archive_name = "RendererIOS-abi-4.binaryarchive"
        provenance_name = "RendererIOS-abi-4.provenance"
        (baseline / "cold" / archive_name).write_bytes(b"baseline")
        (cold / archive_name).write_bytes(b"inventory")
        (warm / archive_name).write_bytes(b"inventory")
        for path in (
            baseline / "cold" / provenance_name,
            cold / provenance_name,
            warm / provenance_name,
        ):
            path.write_bytes(expected_provenance(metallib_sha256))
        for path in (baseline / "cold", cold, warm):
            write_cache_fixture(path)
        validate(baseline, cold, warm, source_sha, metallib_sha256)

        cold_summary = (cold / "archive-summary.txt").read_text()
        warm_summary = (warm / "archive-summary.txt").read_text()
        (cold / "archive-summary.txt").write_text(
            cold_summary.replace("runtime_render=6\n", "runtime_render=4\n")
        )
        (warm / "archive-summary.txt").write_text(
            warm_summary.replace("runtime_render=4\n", "runtime_render=6\n")
        )
        expect_validation_failure(
            lambda: require_summary(
                cold / "archive-summary.txt", "inventory-cold"
            ),
            "swapped inventory-cold runtime render summary self-test unexpectedly passed",
        )
        expect_validation_failure(
            lambda: require_summary(
                warm / "archive-summary.txt", "inventory-warm"
            ),
            "swapped inventory-warm runtime render summary self-test unexpectedly passed",
        )
        write_summary_fixture(cold / "archive-summary.txt", "inventory-cold")
        write_summary_fixture(warm / "archive-summary.txt", "inventory-warm")

        write_result(
            warm / "result.txt",
            "inventory-warm",
            mixed_source_sha,
            warm_nonce,
        )
        expect_validation_failure(
            lambda: validate(
                baseline, cold, warm, source_sha, metallib_sha256
            ),
            "mixed source self-test unexpectedly passed",
        )
        write_result(
            warm / "result.txt", "inventory-warm", source_sha, warm_nonce
        )

        (cold / provenance_name).write_bytes(
            expected_provenance(wrong_metallib_sha256)
        )
        write_cache_fixture(cold)
        expect_validation_failure(
            lambda: validate(
                baseline, cold, warm, source_sha, metallib_sha256
            ),
            "wrong metallib provenance self-test unexpectedly passed",
        )
        (cold / provenance_name).write_bytes(
            expected_provenance(metallib_sha256)
        )
        write_cache_fixture(cold)

        cache = (cold / "cache-after.txt").read_text()
        actual_archive_sha = sha256(cold / archive_name)
        (cold / "cache-after.txt").write_text(
            cache.replace(actual_archive_sha, "0" * 64)
        )
        expect_validation_failure(
            lambda: validate(
                baseline, cold, warm, source_sha, metallib_sha256
            ),
            "stale cache archive SHA-256 self-test unexpectedly passed",
        )
        write_cache_fixture(cold)

        cache = (warm / "cache-after.txt").read_text()
        archive_size = (warm / archive_name).stat().st_size
        (warm / "cache-after.txt").write_text(
            cache.replace(
                f"archive_bytes={archive_size}\n",
                f"archive_bytes={archive_size + 1}\n",
            )
        )
        expect_validation_failure(
            lambda: validate(
                baseline, cold, warm, source_sha, metallib_sha256
            ),
            "stale cache archive size self-test unexpectedly passed",
        )
        write_cache_fixture(warm)

        (warm / archive_name).write_bytes(b"changed-warm")
        write_cache_fixture(warm)
        expect_validation_failure(
            lambda: validate(
                baseline, cold, warm, source_sha, metallib_sha256
            ),
            "warm archive mutation self-test unexpectedly passed",
        )

        (warm / archive_name).write_bytes(b"inventory")
        write_cache_fixture(warm)
        (baseline / "cold" / archive_name).write_bytes(b"inventory")
        write_cache_fixture(baseline / "cold")
        expect_validation_failure(
            lambda: validate(
                baseline, cold, warm, source_sha, metallib_sha256
            ),
            "unchanged cold archive self-test unexpectedly passed",
        )

        (baseline / "cold" / archive_name).write_bytes(b"baseline")
        write_cache_fixture(baseline / "cold")
        (warm / provenance_name).write_bytes(b"changed-provenance")
        write_cache_fixture(warm)
        expect_validation_failure(
            lambda: validate(
                baseline, cold, warm, source_sha, metallib_sha256
            ),
            "provenance drift self-test unexpectedly passed",
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--cold", type=pathlib.Path)
    parser.add_argument("--warm", type=pathlib.Path)
    parser.add_argument("--source-sha")
    parser.add_argument("--metallib-sha256")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("PASS: semantic pipeline archive evidence self-test")
        return 0
    if any(
        value is None
        for value in (
            args.baseline,
            args.cold,
            args.warm,
            args.source_sha,
            args.metallib_sha256,
        )
    ):
        parser.error(
            "pass --baseline, --cold, --warm, --source-sha, and "
            "--metallib-sha256, or --self-test"
        )
    validate(
        args.baseline,
        args.cold,
        args.warm,
        args.source_sha,
        args.metallib_sha256,
    )
    print("PASS: semantic Inventory pipeline archive cold/warm evidence")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
