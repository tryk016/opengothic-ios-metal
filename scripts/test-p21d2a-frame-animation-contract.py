#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "game/graphics/iossceneextractorplan.h"


DRIVER = r'''
#include "graphics/iossceneextractorplan.h"

#include <cassert>
#include <cstdint>
#include <limits>

int main() {
  using Result = IOSSceneFrameSelectionResult;
  uint64_t ordinal = 0xA5A5A5A5A5A5A5A5u;

  assert(selectIOSSceneTextureFrame(100u,10u,0u,ordinal)==
         Result::InvalidFrameCount);
  assert(ordinal==0xA5A5A5A5A5A5A5A5u);
  assert(selectIOSSceneTextureFrame(100u,0u,4u,ordinal)==
         Result::InvalidFramePeriod);
  assert(ordinal==0xA5A5A5A5A5A5A5A5u);
  assert(selectIOSSceneTextureFrame(100u,0u,0u,ordinal)==
         Result::InvalidFrameCount);
  assert(ordinal==0xA5A5A5A5A5A5A5A5u);

  assert(selectIOSSceneTextureFrame(0u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==0u);
  assert(selectIOSSceneTextureFrame(9u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==0u);
  assert(selectIOSSceneTextureFrame(10u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==1u);
  assert(selectIOSSceneTextureFrame(29u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==2u);
  assert(selectIOSSceneTextureFrame(30u,10u,3u,ordinal)==Result::Selected);
  assert(ordinal==0u);

  const uint64_t maximum = std::numeric_limits<uint64_t>::max();
  assert(selectIOSSceneTextureFrame(maximum,maximum,7u,ordinal)==
         Result::Selected);
  assert(ordinal==1u);
  assert(selectIOSSceneTextureFrame(maximum,2u,maximum,ordinal)==
         Result::Selected);
  assert(ordinal==maximum/2u);
  assert(selectIOSSceneTextureFrame(maximum,1u,maximum,ordinal)==
         Result::Selected);
  assert(ordinal==0u);
  return 0;
}
'''


def compiler() -> list[str]:
    configured = os.environ.get("CXX")
    if configured:
        return shlex.split(configured)
    if shutil.which("xcrun"):
        return ["xcrun", "clang++"]
    found = shutil.which("clang++")
    if found:
        return [found]
    raise RuntimeError("clang++ not found")


def compile_and_run(
    cxx: list[str],
    workspace: Path,
    plan_source: str,
    name: str,
    sanitizer: str | None = None,
) -> subprocess.CompletedProcess[str]:
    include_dir = workspace / name / "game/graphics"
    include_dir.mkdir(parents=True)
    (include_dir / "iossceneextractorplan.h").write_text(plan_source)
    driver = workspace / name / "driver.cpp"
    driver.write_text(DRIVER)
    executable = workspace / name / "driver"

    command = [
        *cxx,
        "-std=c++20",
        "-Wall",
        "-Wextra",
        "-Wconversion",
        "-Wsign-conversion",
        "-Werror",
        "-I",
        str(workspace / name / "game"),
        "-I",
        str(ROOT / "game/graphics"),
        str(driver),
        "-o",
        str(executable),
    ]
    if sanitizer:
        command.extend([f"-fsanitize={sanitizer}", "-fno-omit-frame-pointer"])
    compiled = subprocess.run(command, capture_output=True, text=True)
    if compiled.returncode != 0:
        return compiled
    if sys.platform == "darwin" and shutil.which("codesign"):
        signed = subprocess.run(
            ["codesign", "-f", "-s", "-", str(executable)],
            capture_output=True,
            text=True,
        )
        if signed.returncode != 0:
            return signed
    return subprocess.run([str(executable)], capture_output=True, text=True)


def require_selector_gates(plan_source: str) -> None:
    cxx = compiler()
    with tempfile.TemporaryDirectory(prefix="p21d2a-") as temporary:
        workspace = Path(temporary)
        for name, sanitizer in (
            ("strict", None),
            ("asan", "address"),
            ("ubsan", "undefined"),
        ):
            result = compile_and_run(cxx, workspace, plan_source, name, sanitizer)
            if result.returncode != 0:
                raise RuntimeError(
                    f"selector {name} gate failed:\n{result.stdout}{result.stderr}"
                )

        canonical = "outFrameOrdinal = (sceneTimeMs/framePeriodMs)%frameCount;"
        if canonical not in plan_source:
            raise RuntimeError("selector canonical checked formula not found")
        mutations = {
            "constant-ordinal": plan_source.replace(
                canonical, "outFrameOrdinal = 0;", 1
            ),
            "removed-modulo": plan_source.replace(
                canonical, "outFrameOrdinal = sceneTimeMs/framePeriodMs;", 1
            ),
            "multiplication-overflow": plan_source.replace(
                canonical,
                "outFrameOrdinal = (sceneTimeMs*frameCount/framePeriodMs)%frameCount;",
                1,
            ),
            "accepted-zero-count": plan_source.replace(
                "if(frameCount==0)", "if(false)", 1
            ),
            "accepted-zero-period": plan_source.replace(
                "if(framePeriodMs==0)", "if(false)", 1
            ),
            "changed-failure-output": plan_source.replace(
                "if(frameCount==0)\n"
                "    return IOSSceneFrameSelectionResult::InvalidFrameCount;",
                "if(frameCount==0) {\n"
                "    outFrameOrdinal = 0;\n"
                "    return IOSSceneFrameSelectionResult::InvalidFrameCount;\n"
                "    }",
                1,
            ),
            "collapsed-error-result": plan_source.replace(
                "return IOSSceneFrameSelectionResult::InvalidFramePeriod;",
                "return IOSSceneFrameSelectionResult::InvalidFrameCount;",
                1,
            ),
        }
        for name, mutated in mutations.items():
            if mutated == plan_source:
                raise RuntimeError(f"selector mutation {name} did not match source")
            result = compile_and_run(cxx, workspace, mutated, f"mutation-{name}")
            if result.returncode == 0:
                raise RuntimeError(f"selector mutation survived: {name}")


def main() -> int:
    plan_source = PLAN.read_text()

    require_selector_gates(plan_source)
    print("P2.1d2a frame-animation contract: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"P2.1d2a frame-animation contract: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
