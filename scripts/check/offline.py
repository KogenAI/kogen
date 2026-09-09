#!/usr/bin/env python3
"""The Make check recipe: retain every gate stage and report whole-gate time."""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor


def run_stage(command, root, env):
    env = dict(env, MIX_ENV="test" if command[1] == "test" else "dev")
    print("+ " + " ".join(command), flush=True)
    started = time.monotonic()
    result = subprocess.call(command, cwd=root, env=env)
    print(f"Stage elapsed ({' '.join(command)}): {time.monotonic() - started:.3f}s", flush=True)
    return result


def main():
    started = time.monotonic()
    root = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["HEX_OFFLINE"] = "1"
    # /usr/bin/git on macOS is an Xcode launcher. Resolve it once instead of
    # paying that launcher cost for every Git operation in the fixture suite.
    git = shutil.which("git")
    if sys.platform == "darwin" and git == "/usr/bin/git":
        git = subprocess.check_output(["/usr/bin/xcrun", "--find", "git"], text=True).strip()
    if not git:
        raise RuntimeError("git executable was not found")
    env["KOGEN_CHECK_GIT"] = git
    env["PATH"] = str(root / "scripts/check/bin") + os.pathsep + env.get("PATH", "")
    print(f"Resolved Git executable: {git}", flush=True)
    build_path = env.get("MIX_BUILD_PATH")
    caches = ([Path(build_path)] if build_path else
              [root / "_build/dev", root / "_build/test"])
    warm = all((path / "lib/kogen/ebin/Elixir.Kogen.Build.beam").is_file()
               for path in caches)
    # Deny accidental default-provider resolution throughout the offline path.
    env["PATH"] = str(root / "test/support") + os.pathsep + env.get("PATH", "")
    stages = [
        ["mix", "format", "--check-formatted"],
        ["mix", "compile", "--warnings-as-errors", "--force"],
        ["mix", "credo", "--strict"],
        ["mix", "test", "--exclude", "live"],
    ]
    print(f"Offline gate: {platform.platform()}; installed dependencies; "
          f"build path={env.get('MIX_BUILD_PATH', '_build')}; warm={warm}", flush=True)
    result = 1
    support = tempfile.TemporaryDirectory(prefix="kogen-check-support-")
    env["KOGEN_TEST_PROCESS_GUARD"] = str(Path(support.name) / "process_group.dylib")
    try:
        result = subprocess.call(["elixir", "--version"], cwd=root, env=env)
        if result:
            return result
        # Format only reads sources. Compilation owns the build output; both
        # finish and propagate their status before Credo or tests can start.
        preparation = stages[:2] + [[
            "xcrun", "clang", "-dynamiclib", "-Wall", "-Werror",
            str(root / "test/support/process_group.c"),
            "-o", env["KOGEN_TEST_PROCESS_GUARD"],
        ]]
        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = [executor.submit(run_stage, command, root, env) for command in preparation]
            results = [future.result() for future in futures]
        result = next((code for code in results if code), 0)
        if result:
            return result
        if build_path:
            # An explicit build path can collapse Mix environments onto the
            # same writable directory, so keep these stages ordered there.
            for command in stages[2:]:
                result = run_stage(command, root, env)
                if result:
                    return result
        else:
            # Default Mix environments have independent dev/test build trees.
            # Credo uses the completed dev compilation; tests own _build/test.
            with ThreadPoolExecutor(max_workers=2) as executor:
                futures = [executor.submit(run_stage, command, root, env)
                           for command in stages[2:]]
                results = [future.result() for future in futures]
            result = next((code for code in results if code), 0)
            if result:
                return result
        return 0
    finally:
        support.cleanup()
        print(f"Complete offline gate: {time.monotonic() - started:.3f}s; exit={result}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
