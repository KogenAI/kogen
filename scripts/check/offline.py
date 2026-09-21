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
import hashlib
import json
import secrets
import signal
from concurrent.futures import ThreadPoolExecutor


SCHEMA_VERSION = 1
LOG_LIMIT = 16_384
DEFAULT_STAGE_TIMEOUT = 1_800
SOURCE_EXCLUDES = {".git", "_build", "deps"}
SOURCE_EXCLUDED_PATHS = {
    ".kogen/runtime", ".kogen/intents", ".kogen/build.lock",
}


def _bounded(text):
    encoded = text.encode("utf-8", errors="replace")
    if len(encoded) <= LOG_LIMIT:
        return text
    return encoded[-LOG_LIMIT:].decode("utf-8", errors="replace")


def _signature(command, status, output):
    head = " ".join(output.split())[:320]
    identity = " ".join(command)
    digest = hashlib.sha256(f"{identity}\n{status}\n{head}".encode()).hexdigest()
    return {"command": identity, "error_head": head, "sha256": digest}


def run_stage(command, root, env):
    env = dict(env, MIX_ENV="test" if len(command) > 1 and command[1] == "test" else "dev")
    print("+ " + " ".join(command), flush=True)
    started = time.monotonic()
    try:
        timeout = float(env.get("KOGEN_OFFLINE_STAGE_TIMEOUT", DEFAULT_STAGE_TIMEOUT))
        process = subprocess.Popen(command, cwd=root, env=env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        raw_output, _ = process.communicate(timeout=timeout)
        returncode = process.returncode
    except subprocess.TimeoutExpired as error:
        returncode = 124
        captured = error.stdout or ""
        if isinstance(captured, bytes):
            captured = captured.decode("utf-8", errors="replace")
        os.killpg(process.pid, signal.SIGTERM)
        try:
            tail, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            tail, _ = process.communicate()
        raw_output = f"{captured}{tail or ''}\nstage timed out after {timeout:.3f}s; process group reaped\n"
    except OSError as error:
        returncode, raw_output = 127, f"could not launch {' '.join(command)}: {error}\n"
    duration = time.monotonic() - started
    output = _bounded(raw_output)
    if output:
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
    print(f"Stage elapsed ({' '.join(command)}): {duration:.3f}s", flush=True)
    return {
        "command": command,
        "status": "passed" if returncode == 0 else "failed",
        "exit_code": returncode,
        "duration_ms": round(duration * 1000),
        "bounded_log": output,
        "signature": _signature(command, returncode, output),
        "cleanup": {"status": "not-required"},
    }


def settle_receipt(path, invocation, stages, cleanup, bindings=None):
    primary = next((stage for stage in stages if stage["status"] == "failed"), None)
    cleanup_failed = cleanup.get("status") == "failed"
    receipt = {
        "schema_version": SCHEMA_VERSION,
        "invocation": invocation,
        "status": "failed" if primary or cleanup_failed else "passed",
        "primary_failure": primary["signature"] if primary else None,
        "stages": stages,
        "cleanup": cleanup,
        "bindings": bindings or {},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
    temporary.write_text(json.dumps(receipt, sort_keys=True) + "\n")
    os.replace(temporary, path)


def _file_sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def source_manifest_sha256(root):
    """Digest the source bytes copied into a cold fixture, including untracked files."""
    entries = []
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(root).as_posix()
        parts = relative.split("/")
        if parts[0] in SOURCE_EXCLUDES:
            continue
        if any(relative == excluded or relative.startswith(excluded + "/")
               for excluded in SOURCE_EXCLUDED_PATHS):
            continue
        if path.is_symlink():
            entries.append(f"L\0{relative}\0{os.readlink(path)}\n".encode())
        elif path.is_file():
            entries.append(
                f"F\0{relative}\0{path.stat().st_mode & 0o777:o}\0".encode()
                + hashlib.sha256(path.read_bytes()).hexdigest().encode() + b"\n"
            )
    return hashlib.sha256(b"".join(entries)).hexdigest()


def receipt_bindings(root, env, invocation):
    """Freeze every local input that can make a settled result reusable."""
    manifest_sha256 = source_manifest_sha256(root)
    git_dir = root / ".git"
    if git_dir.exists():
        source_revision = subprocess.check_output(
            [env.get("KOGEN_CHECK_GIT", "git"), "rev-parse", "HEAD"],
            cwd=root, env=env, text=True,
        ).strip()
        candidate_sha256 = manifest_sha256
        provenance = "local-git"
    else:
        source_revision = env.get("KOGEN_OFFLINE_SOURCE_REVISION")
        candidate_sha256 = env.get("KOGEN_OFFLINE_CANDIDATE_SHA256")
        owner_manifest = env.get("KOGEN_OFFLINE_SOURCE_MANIFEST_SHA256")
        missing = [name for name, value in (
            ("KOGEN_OFFLINE_SOURCE_REVISION", source_revision),
            ("KOGEN_OFFLINE_CANDIDATE_SHA256", candidate_sha256),
            ("KOGEN_OFFLINE_SOURCE_MANIFEST_SHA256", owner_manifest),
        ) if not value]
        if missing:
            raise ValueError("Gitless receipt provenance missing: " + ", ".join(missing))
        if owner_manifest != manifest_sha256 or candidate_sha256 != manifest_sha256:
            raise ValueError(
                "Gitless copied-input manifest does not match outer-owned Candidate")
        provenance = "outer-owner"
    catalog = root / "priv/kogen/test-reliability.yaml"
    targets = root / "priv/kogen/verification_targets.yaml"
    return {
        "verification_attempt": invocation,
        "candidate_sha256": candidate_sha256,
        "source_revision": source_revision,
        "source_manifest_sha256": manifest_sha256,
        "provenance": provenance,
        "dependency_sha256": _file_sha256(root / "mix.lock"),
        "toolchain": platform.platform() + ";" + platform.python_version(),
        "catalog_sha256": _file_sha256(catalog),
        "target_plan_sha256": _file_sha256(targets),
        "provider_denied": env.get("HEX_OFFLINE") == "1" and not env.get("KOGEN_HARNESS"),
    }


def validate_cold_environment(build_path, env, provider_receipt):
    failures = []
    if not build_path:
        failures.append("MIX_BUILD_PATH is required")
    elif Path(build_path).exists():
        failures.append("cold build path already exists")
    if env.get("HEX_OFFLINE") != "1":
        failures.append("HEX_OFFLINE must be 1")
    if env.get("KOGEN_HARNESS"):
        failures.append("KOGEN_HARNESS must be absent")
    if provider_receipt and Path(provider_receipt).exists():
        failures.append("provider denial receipt already exists")
    return failures


def validate_provider_denial(provider_receipt):
    if provider_receipt and Path(provider_receipt).exists():
        return ["provider denial was bypassed during offline execution"]
    return []


def main():
    if sys.argv[1:] == ["--source-manifest-sha256"]:
        print(source_manifest_sha256(Path(__file__).resolve().parents[2]))
        return 0
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
    if env.get("KOGEN_COLD_OFFLINE") == "1":
        provider_receipt = root / ".kogen/runtime/path-shim-invoked"
        cold_failures = validate_cold_environment(
            build_path, env, provider_receipt)
        if cold_failures:
            raise RuntimeError("invalid cold-offline environment: " + "; ".join(cold_failures))
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
    invocation = os.environ.get("KOGEN_OFFLINE_INVOCATION") or secrets.token_hex(16)
    receipt_path = Path(os.environ.get(
        "KOGEN_OFFLINE_RECEIPT",
        root / ".kogen/runtime/offline-results" / f"{invocation}.json",
    ))
    stage_results = []
    bindings = None
    support = tempfile.TemporaryDirectory(prefix="kogen-check-support-")
    env["KOGEN_TEST_PROCESS_GUARD"] = str(Path(support.name) / "process_group.dylib")
    try:
        try:
            bindings = receipt_bindings(root, env, invocation)
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            message = f"receipt binding failed before offline stages: {error}"
            binding_stage = {
                "command": ["receipt-binding"], "status": "failed", "exit_code": 125,
                "duration_ms": 0, "bounded_log": message,
                "signature": _signature(["receipt-binding"], 125, message),
                "cleanup": {"status": "not-required"},
            }
            stage_results.append(binding_stage)
            result = 125
            return result
        version_result = run_stage(["elixir", "--version"], root, env)
        stage_results.append(version_result)
        result = version_result["exit_code"]
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
        stage_results.extend(results)
        result = next((entry["exit_code"] for entry in results if entry["exit_code"]), 0)
        if result:
            return result
        if build_path:
            # An explicit build path can collapse Mix environments onto the
            # same writable directory, so keep these stages ordered there.
            for command in stages[2:]:
                stage = run_stage(command, root, env)
                stage_results.append(stage)
                result = stage["exit_code"]
                if result:
                    return result
        else:
            # Default Mix environments have independent dev/test build trees.
            # Credo uses the completed dev compilation; tests own _build/test.
            with ThreadPoolExecutor(max_workers=2) as executor:
                futures = [executor.submit(run_stage, command, root, env)
                           for command in stages[2:]]
                results = [future.result() for future in futures]
            stage_results.extend(results)
            result = next((entry["exit_code"] for entry in results if entry["exit_code"]), 0)
            if result:
                return result
        rehearsal = run_stage(["mix", "run", "scripts/check/rehearsals.exs"], root, env)
        stage_results.append(rehearsal)
        result = rehearsal["exit_code"]
        if result:
            return result
        if env.get("KOGEN_COLD_OFFLINE") == "1":
            denial_failures = validate_provider_denial(provider_receipt)
            if denial_failures:
                denial = {
                    "command": ["provider-denial-audit"],
                    "status": "failed",
                    "exit_code": 126,
                    "duration_ms": 0,
                    "bounded_log": "; ".join(denial_failures),
                    "signature": _signature(
                        ["provider-denial-audit"], 126, "; ".join(denial_failures)),
                    "cleanup": {"status": "not-required"},
                }
                stage_results.append(denial)
                result = denial["exit_code"]
                return result
        return 0
    finally:
        cleanup_error = None
        try:
            support.cleanup()
        except OSError as error:
            cleanup_error = error
        cleanup = ({"status": "passed", "owner": "offline-stage-supervisor"}
                   if cleanup_error is None else
                   {"status": "failed", "owner": "offline-stage-supervisor",
                    "reason": str(cleanup_error)})
        settle_receipt(
            receipt_path,
            invocation,
            stage_results,
            cleanup,
            bindings,
        )
        print(f"Offline receipt: {receipt_path}", flush=True)
        print(f"Complete offline gate: {time.monotonic() - started:.3f}s; exit={result}", flush=True)
        if cleanup_error is not None:
            raise RuntimeError(f"offline cleanup failed after stage settlement: {cleanup_error}")


if __name__ == "__main__":
    sys.exit(main())
