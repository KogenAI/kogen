#!/usr/bin/env python3
"""The Make check recipe: retain every gate stage and report whole-gate time."""
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import hashlib
import json
import secrets
import signal
import threading
import codecs
import select
import tarfile
from concurrent.futures import ThreadPoolExecutor


SCHEMA_VERSION = 1
LOG_LIMIT = 16_384
# Elapsed time never fails a stage (scenario "offline gate": timings are
# diagnostic). This is only the custody hang guard: a stage that emits no
# output at all for this long is classified as stalled (exit 124) and reaped.
DEFAULT_STAGE_TIMEOUT = 1_800
_STAGE_TERM_GRACE = 0.5
_STAGE_KILL_GRACE = 0.5
_STAGE_FINAL_WAIT = 0.25
STAGES = (
    ("mix", "format", "--check-formatted"),
    ("mix", "compile", "--warnings-as-errors", "--force"),
    ("mix", "credo", "--strict"),
    # Excluded live owners still compile; a stale call must fail, not warn.
    ("mix", "test", "--exclude", "live", "--warnings-as-errors"),
)
# Scenario test-warnings-fail-first: compiles and loads every non-live test
# file with warnings as errors, running none of them (`--exclude test`
# excludes ExUnit's own implicit tag). This must run before credo, the full
# test run (STAGES[3]) and rehearsals, so a planted test-file warning fails
# `check` within about a second instead of after the whole suite.
# `--only <unused tag>` is not usable here: it exits 1 even on a clean tree
# (evidence/probe-loaders P7).
TEST_COMPILE_STAGE = ("mix", "test", "--exclude", "live", "--warnings-as-errors", "--exclude", "test")
# Scenario offline-fixture-validation: provider-denied validation of every
# generated live-target fixture through Kogen's real parsers. The three
# `prepare` targets validate their own fixtures inside rehearsals.exs's
# controlled prepare; this stage covers the compatibility fixture. It is a
# stage of this single gate (not a second suite) and has no time limit of its
# own beyond the shared process-safety stage deadline.
FIXTURE_VALIDATION_STAGE = ("mix", "run", "scripts/check/fixture_validation.exs")
# Every catalog `prepare` target must either name the fixtures it generates
# (each must appear, validated, in the rehearsal receipt) or be declared as
# generating none. An unlisted `prepare` target fails the proof rather than
# passing unvalidated.
PREPARE_FIXTURE_LABELS = {
    "live-reviewer-rework": ["live-reviewer-rework-probe"],
    "live-shaping-quality": [
        "csv-flawed", "csv-complete", "booking-flawed", "booking-complete",
        "stateful-flawed", "stateful-complete", "csv-continuation", "csv-continuation-draft",
    ],
    "live-shaping-smoke": ["smoke"],
}
PREPARE_WITHOUT_FIXTURE = ("live-native", "live-shape-to-build")
STAGE_FIXTURE_LABELS = ("compatibility-fixture",)
SOURCE_EXCLUDES = {".git", "_build", "deps"}
SOURCE_EXCLUDED_PATHS = {
    ".kogen/runtime", ".kogen/intents", ".kogen/build.lock",
}

# `KOGEN_FAILURE_SIGNATURE` frame contract (documented in scripts/check/README.md
# and lib/kogen/build/failure_signature.ex): one line, tag + TAB + JSON, for
# offline.py's own failing stage. `stage` is offline.py's internal stage
# name; `test_id` is the first failing ExUnit test's "file:line" or null;
# `assertion` is the first informative reason line after that test's header,
# or null when no ExUnit test header is found.
FAILURE_SIGNATURE_TAG = "KOGEN_FAILURE_SIGNATURE"
_EXUNIT_TEST_RE = re.compile(r"^[ \t]*\d+\)[ \t]+test .+?\(\S+\)[ \t]*\n[ \t]*(\S+\.exs?:\d+)", re.M)
_ISOLATED_SKIP_PREFIXES = ("isolated test ", "Running ExUnit", "Excluding tags", "Including tags")
# Progress lines ("E..", "..F") and rule lines ("=====", "-----") that a
# nested runner (for example Python unittest) prints before its real reason.
_NOISE_LINE_RE = re.compile(r"^(?:[.EFsx]+|[=\-]{5,})$")


class BoundedCommandFailure(RuntimeError):
    def __init__(self, message, cleanup):
        super().__init__(message)
        self.cleanup = cleanup


def _first_reason_line(output, after_idx):
    """The first informative line after `after_idx`, skipping blank lines and
    `Kogen.IsolatedCase`'s wrapper banner (and a nested repeat of the same
    "N) test ..." + location header it reproduces) to reach the real reason,
    which may be freeform text rather than one of ExUnit's own markers."""
    lines = output[after_idx:].splitlines()
    idx = 0
    while idx < len(lines):
        line = lines[idx].strip()
        if not line:
            idx += 1
            continue
        if any(line.startswith(prefix) for prefix in _ISOLATED_SKIP_PREFIXES):
            idx += 1
            continue
        break
    if idx < len(lines) and re.match(r"^\d+\)\s+test ", lines[idx].strip()):
        idx += 1
        while idx < len(lines) and not lines[idx].strip():
            idx += 1
        if idx < len(lines) and re.match(r"^\S+\.exs?:\d+", lines[idx].strip()):
            idx += 1
    while idx < len(lines) and (not lines[idx].strip() or _NOISE_LINE_RE.match(lines[idx].strip())):
        idx += 1
    return lines[idx].strip() if idx < len(lines) else None


def reproduce_command(command):
    mix_env = "test" if len(command) > 1 and command[1] == "test" else "dev"
    return "MIX_ENV=" + mix_env + " " + " ".join(command)


def failure_signature_frame(stage, output, include_reproduce=False, command=None):
    """Builds the `KOGEN_FAILURE_SIGNATURE` JSON body (without the tag/TAB)
    for `stage` from `output`, the failing stage's complete (unbounded) log."""
    match = _EXUNIT_TEST_RE.search(output)
    test_id = match.group(1) if match else None
    assertion = _first_reason_line(output, match.end() if match else 0)
    frame = {"stage": stage, "test_id": test_id, "assertion": assertion}
    if include_reproduce and command is not None:
        frame["reproduce"] = reproduce_command(command)
    return json.dumps(frame)


def _stage_name(command):
    pair = tuple(command[:2])
    names = {
        ("mix", "format"): "format",
        ("mix", "compile"): "compile",
        ("mix", "credo"): "credo",
    }
    if pair == ("mix", "test"):
        # Only the exact load-only stage is `test-compile`; every `mix test`
        # command contains "test", so a membership test would misname the
        # full test run.
        return "test-compile" if tuple(command) == TEST_COMPILE_STAGE else "test"
    if list(command) == ["mix", "run", "scripts/check/rehearsals.exs"]:
        return "rehearsals"
    if list(command) == list(FIXTURE_VALIDATION_STAGE):
        return "fixture-validation"
    return names.get(pair, command[0] if command else "unknown")


def _bounded(text):
    encoded = text.encode("utf-8", errors="replace")
    if len(encoded) <= LOG_LIMIT:
        return text
    return encoded[-LOG_LIMIT:].decode("utf-8", errors="replace")


def read_case_timings(output):
    """Parse the final ExUnit formatter summary into receipt-ready timings."""
    lines = output.splitlines()
    headings = [index for index, line in enumerate(lines)
                if line.strip() == "Slowest individual cases (includes isolated process startup):"]
    if not headings:
        return []
    timings = []
    for line in lines[headings[-1] + 1:]:
        match = re.match(r"^\s{2}(\d+(?:\.\d+)?)s\s+(\S+)\s+(.+?)\s*$", line)
        if not match:
            if timings:
                break
            continue
        timings.append({
            "duration_ms": round(float(match.group(1)) * 1000),
            "module": match.group(2),
            "name": match.group(3),
        })
    return timings


def _signature(command, status, output):
    head = " ".join(output.split())[:320]
    identity = " ".join(command)
    digest = hashlib.sha256(f"{identity}\n{status}\n{head}".encode()).hexdigest()
    return {"command": identity, "error_head": head, "sha256": digest}


def _as_text(output):
    if isinstance(output, bytes):
        return output.decode("utf-8", errors="replace")
    return output or ""


def _signal_group(process, sig):
    name = signal.Signals(sig).name
    try:
        # `communicate` can reap a leader while a descendant still holds the
        # output pipe. Its numeric PID may then be reused as an unrelated
        # group's PGID, so a group signal needs a live original leader.
        if process.poll() is not None:
            return {"scope": "process-group", "signal": name, "status": "failed",
                    "reason": "stage leader exited before group ownership could be verified"}
        if os.getpgid(process.pid) != process.pid:
            return {"scope": "process-group", "signal": name, "status": "failed",
                    "reason": "stage leader does not own the recorded process group"}
        os.killpg(process.pid, sig)
        return {"scope": "process-group", "signal": name, "status": "sent"}
    except ProcessLookupError:
        return {"scope": "process-group", "signal": name, "status": "already-exited"}
    except OSError as error:
        return {
            "scope": "process-group",
            "signal": name,
            "status": "failed",
            "reason": f"{type(error).__name__}: {error}",
        }


def _signal_leader(process, sig):
    name = signal.Signals(sig).name
    try:
        if process.poll() is not None:
            return {"scope": "direct-child", "signal": name, "status": "already-exited"}
        process.send_signal(sig)
        return {"scope": "direct-child", "signal": name, "status": "sent"}
    except ProcessLookupError:
        return {"scope": "direct-child", "signal": name, "status": "already-exited"}
    except OSError as error:
        return {
            "scope": "direct-child",
            "signal": name,
            "status": "failed",
            "reason": f"{type(error).__name__}: {error}",
        }


class _StreamCapture:
    """Streams a stage's combined output on a reader thread and tracks the
    time of the last byte, so hang protection can key on silence (not on
    total elapsed time). Exposes a `communicate`-shaped bounded wait."""

    def __init__(self, process):
        self.process = process
        self.chunks = []
        self.stop = threading.Event()
        self.last_output = time.monotonic()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        # Poll instead of blocking in read(): a descendant can hold the pipe
        # open forever, and closing a stream another thread is blocked on
        # would hang the supervisor's own cleanup.
        fd = self.process.stdout.fileno()
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        try:
            while not self.stop.is_set():
                ready, _, _ = select.select([fd], [], [], 0.05)
                if not ready:
                    continue
                data = os.read(fd, 65536)
                if not data:
                    break
                self.chunks.append(decoder.decode(data))
                self.last_output = time.monotonic()
        except (OSError, ValueError):
            pass

    def text(self):
        return "".join(self.chunks)

    def done(self):
        return self.process.poll() is not None and not self.reader.is_alive()

    def communicate(self, timeout):
        deadline = time.monotonic() + timeout
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise subprocess.TimeoutExpired(self.process.args, timeout, output=self.text())
        self.reader.join(max(0.0, deadline - time.monotonic()))
        if self.reader.is_alive():
            raise subprocess.TimeoutExpired(self.process.args, timeout, output=self.text())
        return self.text(), None


def _cleanup_timed_out_stage(process, timeout, initial_error, capture):
    """Bound timeout cleanup even when descendants keep stdout open.

    `communicate` can time out after the direct child has exited if another
    process inherited its output descriptor. Every follow-up wait here is
    bounded, and the direct-child result is reported separately from the
    process group: Python cannot prove that every descendant has exited.
    """
    output = _as_text(initial_error.stdout)
    signals = []
    errors = []
    pipe_state = "eof"

    group_term = _signal_group(process, signal.SIGTERM)
    signals.append(group_term)
    if group_term["status"] == "failed":
        errors.append(f"process-group SIGTERM failed: {group_term['reason']}")
        leader_term = _signal_leader(process, signal.SIGTERM)
        signals.append(leader_term)
        if leader_term["status"] == "failed":
            errors.append(f"direct-child SIGTERM failed: {leader_term['reason']}")

    try:
        output, _ = capture.communicate(_STAGE_TERM_GRACE)
        output = _as_text(output)
    except subprocess.TimeoutExpired as error:
        output = _as_text(error.stdout)
        group_kill = _signal_group(process, signal.SIGKILL)
        signals.append(group_kill)
        if group_kill["status"] == "failed":
            errors.append(f"process-group SIGKILL failed: {group_kill['reason']}")
            leader_kill = _signal_leader(process, signal.SIGKILL)
            signals.append(leader_kill)
            if leader_kill["status"] == "failed":
                errors.append(f"direct-child SIGKILL failed: {leader_kill['reason']}")

        try:
            output, _ = capture.communicate(_STAGE_KILL_GRACE)
            output = _as_text(output)
        except subprocess.TimeoutExpired as final_error:
            output = _as_text(final_error.stdout)
            pipe_state = "closed-by-supervisor"
            leader_kill = _signal_leader(process, signal.SIGKILL)
            if leader_kill["status"] == "failed":
                errors.append(f"direct-child SIGKILL failed: {leader_kill['reason']}")
            capture.stop.set()
            capture.reader.join(0.5)
            if process.stdout is not None:
                try:
                    process.stdout.close()
                except OSError as close_error:
                    errors.append(f"stdout close failed: {type(close_error).__name__}: {close_error}")

    # communicate() normally reaps the direct child. Keep an independent
    # bounded fallback in case pipe closure or an OS error interrupted it.
    try:
        if process.poll() is None:
            final_kill = _signal_leader(process, signal.SIGKILL)
            signals.append(final_kill)
            if final_kill["status"] == "failed":
                errors.append(f"final direct-child SIGKILL failed: {final_kill['reason']}")
            process.wait(timeout=_STAGE_FINAL_WAIT)
    except subprocess.TimeoutExpired:
        errors.append("direct child did not exit within the final wait")
        retry_kill = _signal_leader(process, signal.SIGKILL)
        signals.append(retry_kill)
        if retry_kill["status"] == "failed":
            errors.append(f"retry direct-child SIGKILL failed: {retry_kill['reason']}")
        try:
            process.wait(timeout=_STAGE_FINAL_WAIT)
        except subprocess.TimeoutExpired:
            errors.append("direct child remained alive after the final SIGKILL wait")
    except OSError as wait_error:
        errors.append(f"direct-child wait failed: {type(wait_error).__name__}: {wait_error}")

    leader_reaped = process.poll() is not None
    if not leader_reaped:
        errors.append("direct child was not reaped")
    if pipe_state != "eof":
        errors.append("output pipe did not reach EOF within bounded cleanup")
    cleanup = {
        "status": "failed" if errors else "passed",
        "owner": "offline-stage-supervisor",
        "leader_reaped": leader_reaped,
        "signals": signals,
        "output_pipe": pipe_state,
        "descendants": "not-independently-verified",
    }
    if errors:
        cleanup["reason"] = "; ".join(errors)
    output += (
        f"\nstage stalled: no output for {timeout:.3f}s (hang guard, not an elapsed-time limit); "
        f"cleanup={cleanup['status']}; "
        f"direct child reaped={leader_reaped}; descendants not independently verified\n"
    )
    return output, cleanup


def run_bounded_capture(command, root, env, timeout):
    """Run a captured command in its own group. `timeout` is the maximum
    silence (seconds without output), never a limit on total duration."""
    process = subprocess.Popen(command, cwd=root, env=env, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    capture = _StreamCapture(process)
    while not capture.done():
        time.sleep(0.05)
        if time.monotonic() - capture.last_output > timeout:
            error = subprocess.TimeoutExpired(command, timeout, output=capture.text())
            output, cleanup = _cleanup_timed_out_stage(process, timeout, error, capture)
            return 124, output, cleanup
    process.wait()
    return process.returncode, capture.text(), {"status": "not-required"}


def run_stage(command, root, env):
    """Runs one stage. The full suite also records its completion for the
    rehearsals stage, which runs beside it and reads the suite's trace only
    afterwards (`KOGEN_REHEARSAL_TRACE_READY`)."""
    ready = env.get("KOGEN_REHEARSAL_TRACE_READY")
    if not ready or tuple(command) != STAGES[3]:
        return _run_stage(command, root, env)
    outcome = "failed"
    try:
        result = _run_stage(command, root, env)
        outcome = "passed" if result["exit_code"] == 0 else "failed"
        return result
    finally:
        Path(ready).write_text(outcome)


def _run_stage(command, root, env):
    env = dict(env, MIX_ENV="test" if len(command) > 1 and command[1] == "test" else "dev")
    # The compile-only stage loads every test with --exclude test. Its
    # excluded events are not Candidate executions and must not duplicate the
    # later complete suite's proof log. Base dry-run enumeration owns a
    # separate log and does not use run_stage.
    if tuple(command) != tuple(FIXTURE_VALIDATION_STAGE):
        env.pop("KOGEN_FIXTURE_VALIDATION_RECEIPT", None)
    if tuple(command) != STAGES[3]:
        for key in ("KOGEN_TEST_EVENT_LOG", "KOGEN_TEST_EVENT_OWNER_PID",
                    "KOGEN_TEST_EVENT_OWNER_PATH", "KOGEN_TEST_TIMING_SUMMARY"):
            env.pop(key, None)
    print("+ " + " ".join(command), flush=True)
    started = time.monotonic()
    cleanup = {"status": "not-required"}
    try:
        timeout = float(env.get("KOGEN_OFFLINE_STAGE_TIMEOUT", DEFAULT_STAGE_TIMEOUT))
        returncode, raw_output, cleanup = run_bounded_capture(command, root, env, timeout)
    except OSError as error:
        returncode, raw_output = 127, f"could not launch {' '.join(command)}: {error}\n"
    duration = time.monotonic() - started
    output = _bounded(raw_output)
    if output:
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
    print(f"Stage elapsed ({' '.join(command)}): {duration:.3f}s", flush=True)
    failure_frame = (
        failure_signature_frame(_stage_name(command), raw_output, include_reproduce=True, command=command) if returncode else None
    )
    result = {
        "command": command,
        "status": "passed" if returncode == 0 else "failed",
        "exit_code": returncode,
        "duration_ms": round(duration * 1000),
        "bounded_log": output,
        "signature": _signature(command, returncode, output),
        "failure_frame": failure_frame,
        "cleanup": cleanup,
    }
    case_timings = read_case_timings(raw_output)
    if case_timings:
        result["case_timings"] = case_timings
    return result


def run_ordered(phases, root, env, stage_results):
    """Runs `phases` (each an ordered list of one or more argv commands, run
    in parallel within a phase through a bounded `ThreadPoolExecutor`) in
    order, stopping at the first phase carrying a failed stage. Appends every
    run stage's result to `stage_results` (in the order it started within its
    phase) and returns the exit code of the phase's earliest-listed failed
    command, or 0 when every phase passed. On a failure it prints the failed
    stage's `KOGEN_FAILURE_SIGNATURE` frame (scenario `signatures-identify-failures`).
    Scenario `test-warnings-fail-first`: no later phase's command starts once
    an earlier phase fails, so `TEST_COMPILE_STAGE` failing here means credo,
    the full test run and rehearsals never start.
    """
    for phase in phases:
        if len(phase) == 1:
            results = [run_stage(phase[0], root, env)]
        else:
            with ThreadPoolExecutor(max_workers=len(phase)) as executor:
                futures = [executor.submit(run_stage, command, root, env) for command in phase]
                results = [future.result() for future in futures]
        stage_results.extend(results)
        # Earliest-listed failure in the phase, not earliest-completed, so a
        # deterministic single stage's frame is always the one printed.
        primary = next((entry for entry, command in zip(results, phase) if entry["exit_code"]), None)
        if primary:
            if primary["failure_frame"]:
                print(f"{FAILURE_SIGNATURE_TAG}\t{primary['failure_frame']}", flush=True)
            return primary["exit_code"]
    return 0


def settle_receipt(path, invocation, stages, cleanup, bindings=None, proof=None, timing=None):
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
    if proof is not None:
        receipt["admission_proof"] = proof
    if timing is not None:
        receipt["timing"] = timing
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
    temporary.write_text(json.dumps(receipt, sort_keys=True) + "\n")
    os.replace(temporary, path)


def write_json_atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
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


def read_test_events(path):
    """Read formatter JSONL as canonical ExUnit test tuples."""
    records = []
    if not path or not Path(path).is_file():
        return records
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip():
            continue
        event = json.loads(line)
        records.append({
            "file": event["file"].replace("\\", "/"),
            "module": event["module"],
            "name": event["name"],
            "parameters": event.get("parameters", {}),
            "status": event["status"],
        })
    return records


def test_identity(event):
    parameters = event.get("parameters", {})
    # This fixture creates a fresh disposable Git template per Mix invocation.
    # Its path is execution state, while the case, operation and expectation
    # remain the distinct parameterized test identity.
    if event["file"] == "test/kogen/build_preconditions_test.exs" and isinstance(parameters, dict):
        template = parameters.get("template")
        if isinstance(template, str) and re.fullmatch(
                r"kogen-precondition-template-[0-9]+-[0-9]+", Path(template).name):
            parameters = dict(parameters, template="<disposable-precondition-template>")
    return (event["file"], event["module"], event["name"],
            json.dumps(parameters, sort_keys=True, separators=(",", ":")))


def _test_identity_record(event):
    file, module, name, parameters = test_identity(event)
    return {
        "file": file,
        "module": module,
        "name": name,
        "parameters": json.loads(parameters),
    }


def test_inventory_diff(base_manifest, candidate_events):
    """Describe immutable-base identities absent from or added to the current suite.

    This inventory is review context, not an acceptance condition: refactors may
    rename, merge, or remove tests while the current non-live suite still runs.
    """
    base_tests = base_manifest.get("tests", [])
    base_by_id = {test_identity(event): _test_identity_record(event) for event in base_tests}
    candidate_by_id = {
        test_identity(event): _test_identity_record(event) for event in candidate_events
    }
    baseline_only = [base_by_id[key] for key in sorted(base_by_id.keys() - candidate_by_id.keys())]
    candidate_only = [
        candidate_by_id[key] for key in sorted(candidate_by_id.keys() - base_by_id.keys())
    ]
    return {
        "baseline_count": len(base_tests),
        "candidate_count": len(candidate_events),
        "baseline_only": baseline_only,
        "candidate_only": candidate_only,
    }


def managed_runtime_pin(relative_install_path):
    """Read the pinned managed-runtime version straight out of its installer.

    Sourcing this from priv/kogen/*/install.py's INITIAL_VERSION keeps the
    admission-proof pin check from drifting out of sync with the installer it is
    meant to verify.
    """
    root = Path(__file__).resolve().parents[2]
    text = (root / relative_install_path).read_text()
    match = re.search(r'(?m)^INITIAL_VERSION\s*=\s*"([^"]+)"', text)
    if not match:
        raise RuntimeError(f"could not find INITIAL_VERSION in {relative_install_path}")
    return match.group(1)


def read_fixture_records(path):
    """The JSON-line records the fixture-validation stage appended (none: [])."""
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return []
    return [json.loads(line) for line in lines if line.strip()]


def _fixture_record_failures(where, records, labels):
    failures = []
    found = {record.get("label") for record in records}
    for label in labels:
        if label not in found:
            failures.append(f"{where}: generated fixture {label} was not validated")
    for record in records:
        digest = record.get("digest")
        if not (isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)):
            failures.append(f"{where}: fixture {record.get('label')} carries no input digest")
        if record.get("providers_denied") is not True:
            failures.append(f"{where}: fixture {record.get('label')} was not generated with providers denied")
        if not isinstance(record.get("files"), int) or record["files"] <= 0:
            failures.append(f"{where}: fixture {record.get('label')} recorded no input files")
    return failures


def validate_fixture_proof(rehearsal_receipt, stage_records):
    """Scenario offline-fixture-validation: every selected target's generated
    fixture was validated with providers denied through Kogen's real parsers,
    and its input digest was recorded. Prepare-generated fixtures arrive in
    each controlled prepare's `fixture_validations`; the compatibility fixture
    arrives from the fixture-validation stage. A prepare target unknown to
    PREPARE_FIXTURE_LABELS/PREPARE_WITHOUT_FIXTURE fails rather than passing
    unvalidated. Elapsed time is never an input."""
    failures = []
    for prepare in (rehearsal_receipt or {}).get("controlled_prepares", []):
        target = prepare.get("target")
        if target in PREPARE_WITHOUT_FIXTURE:
            continue
        labels = PREPARE_FIXTURE_LABELS.get(target)
        if labels is None:
            failures.append(f"prepare target {target} declares no generated-fixture validation")
            continue
        failures += _fixture_record_failures(
            f"prepare {target}", prepare.get("fixture_validations", []), labels)
    failures += _fixture_record_failures("fixture-validation stage", stage_records, STAGE_FIXTURE_LABELS)
    return failures


def validate_admission_proof(base_manifest, candidate_events, rehearsal_receipt,
                             runtime_readiness=None):
    """Validate the immutable base manifest, current suite results and rehearsal evidence.

    The exact base/Candidate identity difference is diagnostic only; a non-empty
    current suite must pass, but legitimate refactors may change test identities.
    Elapsed time is diagnostic only: it is recorded in the receipt and never
    a pass/fail input here.
    """
    failures = []
    if base_manifest.get("schema_version") != 1 or base_manifest.get("exclude") != ["live"]:
        failures.append("base test manifest schema or live exclusion is invalid")
    if not base_manifest.get("base_commit") or not base_manifest.get("formatter_sha256"):
        failures.append("base test manifest is missing its immutable source binding")
    manifest_body = {key: value for key, value in base_manifest.items()
                     if key not in ("manifest_sha256", "setup_duration_ms")}
    expected_manifest_digest = hashlib.sha256(
        json.dumps(manifest_body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if base_manifest.get("manifest_sha256") != expected_manifest_digest:
        failures.append("base test manifest digest does not match its contents")
    base_ids = [test_identity(event) for event in base_manifest["tests"]]
    if len(base_ids) != len(set(base_ids)):
        failures.append("base manifest contains duplicate test IDs")
    candidate_ids = [test_identity(event) for event in candidate_events]
    if len(candidate_ids) != len(set(candidate_ids)):
        failures.append("Candidate suite emitted duplicate test IDs")
    if not candidate_events:
        failures.append("Candidate non-live test suite emitted no test results")
    # Excluded and skipped tests did not run and are not failures (a role's
    # sandboxed shell excludes :unconfined tests); failed and invalid ones are.
    failed = [event for event in candidate_events
              if event["status"] not in ("passed", "excluded", "skipped")]
    if failed:
        failures.append(f"{len(failed)} Candidate non-live test(s) did not pass")
    elif candidate_events and not any(event["status"] == "passed" for event in candidate_events):
        failures.append("Candidate non-live test suite has no passing test")
    runtimes = (runtime_readiness or {}).get("runtimes", {})
    codex_pin = managed_runtime_pin("priv/kogen/codex/install.py")
    claude_code_pin = managed_runtime_pin("priv/kogen/claude_code/install.py")
    if (runtime_readiness or {}).get("status") != "passed" or \
            runtimes.get("codex", {}).get("version") != codex_pin or \
            runtimes.get("claude_code", {}).get("version") != claude_code_pin:
        failures.append("pre-staged managed runtime pins are unavailable or incorrect")

    target_evidence = rehearsal_receipt or {}
    observed_rehearsals = target_evidence.get("rehearsals", [])
    rehearsal_id_list = [item.get("rehearsal_id") for item in observed_rehearsals]
    rehearsal_ids = set(rehearsal_id_list)
    required_rehearsal_ids = set(target_evidence.get("required_rehearsals", []))
    if not required_rehearsal_ids or rehearsal_ids != required_rehearsal_ids or len(rehearsal_id_list) != len(rehearsal_ids):
        failures.append("catalog-derived rehearsal evidence is missing or duplicated")
    observed_traces = {
        identity
        for rehearsal in target_evidence.get("rehearsals", [])
        for identity in rehearsal.get("observed", [])
    }
    required_traces = sorted({
        identity
        for rehearsal in target_evidence.get("rehearsals", [])
        for identity in rehearsal.get("required_trace_assertions", [])
    })
    if any(not rehearsal.get("required_trace_assertions") for rehearsal in observed_rehearsals):
        failures.append("catalog rehearsal trace declarations are missing")
    if any(not isinstance(rehearsal.get("duration_ms"), int) or rehearsal["duration_ms"] < 0 or
           rehearsal.get("trace_source") not in ("main-test-suite", "standalone")
           for rehearsal in observed_rehearsals):
        failures.append("catalog rehearsal timing or trace-source evidence is missing")
    missing_traces = sorted(set(required_traces) - observed_traces)
    if missing_traces:
        failures.append("catalog rehearsal trace identities are missing: " + ", ".join(missing_traces))
    prepares = target_evidence.get("controlled_prepares", [])
    prepare_name_list = [item.get("target") for item in prepares]
    prepare_names = set(prepare_name_list)
    required_prepares = set(target_evidence.get("required_prepares", []))
    if not required_prepares or prepare_names != required_prepares or len(prepare_name_list) != len(prepare_names):
        failures.append("catalog-derived controlled prepare evidence is missing or duplicated")
    for prepare in prepares:
        if any(not isinstance(prepare.get(key), int) or prepare[key] < 0
               for key in ("pass_duration_ms", "fail_duration_ms")):
            failures.append(f"controlled prepare timing evidence is missing for {prepare.get('target')}")
        if prepare.get("pass_status") != 0 or prepare.get("fail_status", 0) == 0:
            failures.append(f"controlled prepare outcome is incomplete for {prepare.get('target')}")
        if not prepare.get("failure_frame") or prepare["failure_frame"].get("class") != "environment":
            failures.append(f"controlled prepare failure frame is missing for {prepare.get('target')}")
        if not set(prepare.get("required_trace_assertions", [])).issubset(set(prepare.get("pass_observed", []))):
            failures.append(f"controlled prepare did not trace its setup for {prepare.get('target')}")
    return failures


def verify_managed_runtimes(root, env):
    """Read-only exact-pin preflight, timed as proof setup rather than gate stages."""
    command = [
        "mix", "run", "--no-start", "-e",
        "Kogen.ManagedRuntimeReady.verify!() |> Jason.encode!() |> IO.puts()",
    ]
    readiness_env = dict(env, MIX_ENV="test", HEX_OFFLINE="1", KOGEN_PROVIDERS_DENIED="1")
    readiness_env.pop("KOGEN_HARNESS", None)
    started = time.monotonic()
    returncode, output, cleanup = run_bounded_capture(command, root, readiness_env, 60)
    if returncode == 124:
        raise BoundedCommandFailure(
            f"managed runtime availability timed out; cleanup={cleanup['status']}: {_bounded(output)}",
            cleanup)
    if returncode != 0:
        raise RuntimeError(f"managed runtime availability failed:\n{_bounded(output)}")
    runtime_json = None
    for line in reversed(output.splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and {"codex", "claude_code"}.issubset(value):
            runtime_json = value
            break
    if runtime_json is None:
        raise RuntimeError("managed runtime availability returned no exact-pin evidence")
    return {
        "status": "passed",
        "command": " ".join(command),
        "provider_denied": readiness_env.get("KOGEN_PROVIDERS_DENIED") == "1",
        "duration_ms": round((time.monotonic() - started) * 1000),
        "runtimes": runtime_json,
    }


def prepare_isolated_beam_cache(root, env, destination):
    """Compile child-form isolated cases before the gate stages start."""
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    manifest_path = destination / "modules.json"
    events_path = destination / "enumeration.jsonl"
    command = ["mix", "test", "--dry-run", "--exclude", "live", "--seed", "1"]
    prepare_env = dict(env)
    prepare_env.update({
        "MIX_ENV": "test",
        "HEX_OFFLINE": "1",
        "KOGEN_PROVIDERS_DENIED": "1",
        "KOGEN_ISOLATED_BEAM_PREPARE": "1",
        "KOGEN_ISOLATED_BEAM_CACHE": str(destination),
        "KOGEN_TEST_EVENT_LOG": str(events_path),
        "KOGEN_TEST_DRY_RUN": "1",
    })
    # test_helper compiles the private process guard into this cache itself.
    # The timed gate will reuse that exact file and still runs its declared
    # guard build stage against the same output path.
    prepare_env.pop("KOGEN_TEST_PROCESS_GUARD", None)
    started = time.monotonic()
    returncode, output, cleanup = run_bounded_capture(
        command, root, prepare_env,
        float(env.get("KOGEN_OFFLINE_STAGE_TIMEOUT", DEFAULT_STAGE_TIMEOUT)))
    duration_ms = round((time.monotonic() - started) * 1000)
    if returncode:
        cleanup_detail = f"; cleanup={cleanup['status']}" if returncode == 124 else ""
        message = (
            "isolated child-module cache preparation failed "
            f"({returncode}){cleanup_detail}:\n{_bounded(output)}")
        if returncode == 124:
            raise BoundedCommandFailure(message, cleanup)
        raise RuntimeError(message)
    if not manifest_path.is_file():
        raise RuntimeError("isolated child-module cache preparation returned no modules.json")
    manifest_bytes = manifest_path.read_bytes()
    try:
        manifest = json.loads(manifest_bytes)
    except ValueError as error:
        raise RuntimeError(f"isolated child-module cache manifest is invalid: {error}") from error
    modules = manifest.get("modules_by_source")
    unavailable = manifest.get("unavailable_sources", {})
    if not isinstance(modules, dict) or not modules:
        raise RuntimeError("isolated child-module cache manifest contains no cached modules")
    missing = [
        module for module in modules.values()
        if not isinstance(module, str) or not (destination / f"{module}.beam").is_file()
    ]
    if missing:
        raise RuntimeError("isolated child-module cache is missing BEAMs: " + ", ".join(missing[:8]))
    cache_files = sorted(
        (item for item in destination.iterdir() if item.is_file() and item.name != "progress"),
        key=lambda item: item.name,
    )
    digest = hashlib.sha256()
    for item in cache_files:
        data = item.read_bytes()
        digest.update(item.name.encode("utf-8") + b"\0")
        digest.update(hashlib.sha256(data).digest())
    relative_sources = sorted(
        Path(source).resolve().relative_to(Path(root).resolve()).as_posix()
        for source in modules
    )
    relative_unavailable = {
        Path(source).resolve().relative_to(Path(root).resolve()).as_posix(): reason
        for source, reason in unavailable.items()
    }
    return {
        "status": "passed",
        "command": command,
        "duration_ms": duration_ms,
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "cache_sha256": digest.hexdigest(),
        "cached_modules": len(modules),
        "cached_sources": relative_sources,
        "source_fallbacks": len(unavailable),
        "unavailable_sources": relative_unavailable,
        "bounded_log": _bounded(output),
    }


def base_enumeration_env(env, base_root, events_path):
    """Trust only the immutable exported config while enumerating base tests."""
    trusted_paths = [env.get("MISE_TRUSTED_CONFIG_PATHS"), str(base_root / "mise.toml")]
    enumeration_env = dict(
        env,
        MIX_ENV="test",
        MIX_BUILD_PATH=str(base_root / "_build"),
        KOGEN_TEST_ROOT=str(base_root),
        KOGEN_TEST_EVENT_LOG=str(events_path),
        KOGEN_TEST_DRY_RUN="1",
        HEX_OFFLINE="1",
        MISE_TRUSTED_CONFIG_PATHS=os.pathsep.join(path for path in trusted_paths if path),
    )
    # The immutable HEAD helper predates ownership binding. A dry run never
    # executes nested tests, so let its formatter record without an owner.
    enumeration_env.pop("KOGEN_TEST_EVENT_OWNER_PID", None)
    enumeration_env.pop("KOGEN_TEST_EVENT_OWNER_PATH", None)
    # Candidate build/dependency overrides must not redirect baseline loads.
    enumeration_env.pop("MIX_DEPS_PATH", None)
    return enumeration_env


def installed_dependency_libs(root, env):
    """Return the lib directory that holds this checkout's installed test builds."""
    # MIX_BUILD_PATH names the build directory itself (no MIX_ENV suffix); a
    # cold copy builds only there, never under the default _build/test.
    build_path = env.get("MIX_BUILD_PATH")
    if build_path:
        build = Path(build_path)
        return (build if build.is_absolute() else root / build) / "lib"
    return root / "_build/test/lib"


def copy_installed_dependencies(root, env, base_root):
    """Copy installed dependency sources and builds into the base export.

    Reuse only installed dependency builds. Recompiling rebar dependencies
    inside the temporary export is unreliable with an absolute MIX_BUILD_PATH
    (notably yamerl's include path), while copying Kogen's own beams would let
    Candidate code stand in for the immutable HEAD being enumerated. Links are
    materialized, and each copied build must carry its application file and
    the complete source and header trees it was compiled against.
    """
    deps = root / "deps"
    if deps.is_dir():
        shutil.copytree(deps, base_root / "deps", symlinks=False,
                        ignore=shutil.ignore_patterns("_build"))
    installed_libs = installed_dependency_libs(root, env)

    def installed_names():
        return sorted(
            installed.name for installed in installed_libs.iterdir()
            if installed.is_dir() and installed.name != "kogen" and
            (base_root / "deps" / installed.name).is_dir()
        ) if installed_libs.is_dir() else []

    names = installed_names()
    if deps.is_dir() and any(deps.iterdir()) and not names:
        # A fresh checkout has not compiled its test dependencies yet. Build
        # them where the Candidate itself would, never inside the export.
        timeout = float(env.get("KOGEN_OFFLINE_STAGE_TIMEOUT", DEFAULT_STAGE_TIMEOUT))
        returncode, output, _cleanup = run_bounded_capture(
            ["mix", "deps.compile"], root, dict(env, MIX_ENV="test", HEX_OFFLINE="1"), timeout)
        if returncode:
            raise RuntimeError(
                f"installed dependency preparation failed ({returncode}):\n" + _bounded(output))
        names = installed_names()
    if deps.is_dir() and any(deps.iterdir()) and not names:
        raise RuntimeError(
            f"installed dependency builds are missing under {installed_libs}; "
            "prepare dependencies before base enumeration instead of recompiling "
            "them inside the immutable export")
    base_libs = base_root / "_build/lib"
    base_libs.mkdir(parents=True, exist_ok=True)
    failures = []
    for name in names:
        installed = installed_libs / name
        dangling = sorted(str(path.relative_to(installed)) for path in installed.rglob("*")
                          if path.is_symlink() and not path.exists())
        if dangling:
            failures.append(f"{name}: dangling installed links {dangling}")
            continue
        copied = base_libs / name
        shutil.copytree(installed, copied, symlinks=False)
        if not (copied / "ebin" / f"{name}.app").is_file():
            failures.append(f"{name}: ebin/{name}.app is missing")
        for tree in ("include", "src"):
            if not (installed / tree).exists():
                continue
            source = base_root / "deps" / name / tree
            expected = _tree_files(source) if source.is_dir() else set()
            actual = _tree_files(copied / tree)
            if actual != expected:
                failures.append(
                    f"{name}: {tree} differs from deps/{name}/{tree} "
                    f"(missing {sorted(expected - actual)[:5]}, "
                    f"extra {sorted(actual - expected)[:5]})")
    if failures:
        raise RuntimeError(
            f"installed dependency builds under {installed_libs} are incomplete: " +
            "; ".join(failures))
    return names


def _tree_files(directory):
    return {str(path.relative_to(directory)) for path in directory.rglob("*")
            if path.is_file()}


def make_base_manifest(root, git, env, destination):
    """Export immutable HEAD, copy installed inputs, and enumerate base tests."""
    started = time.monotonic()
    base_commit = subprocess.check_output([git, "rev-parse", "HEAD"], cwd=root, env=env, text=True).strip()
    # The formatter is Candidate-owned instrumentation; tests and support
    # sources remain the exact committed HEAD export.
    formatter = (root / "test/support/timing_formatter.ex").read_bytes()
    formatter_sha256 = hashlib.sha256(formatter).hexdigest()
    base_root = Path(destination) / "base"
    base_root.mkdir(parents=True)
    archive = subprocess.Popen([git, "archive", "--format=tar", "HEAD"], cwd=root, env=env,
                               stdout=subprocess.PIPE)
    with tarfile.open(fileobj=archive.stdout, mode="r|*") as tar:
        tar.extractall(base_root)
    if archive.wait() != 0:
        raise RuntimeError("could not export immutable admission HEAD")
    (base_root / "test/support/timing_formatter.ex").write_bytes(formatter)
    copy_installed_dependencies(root, env, base_root)
    events_path = Path(destination) / "base-tests.jsonl"
    enumeration = ["mix", "test", "--dry-run", "--exclude", "live", "--seed", "1"]
    enum_env = base_enumeration_env(env, base_root, events_path)
    enum_env.pop("KOGEN_TEST_PROCESS_GUARD", None)
    timeout = float(env.get("KOGEN_OFFLINE_STAGE_TIMEOUT", DEFAULT_STAGE_TIMEOUT))
    returncode, output, cleanup = run_bounded_capture(enumeration, base_root, enum_env, timeout)
    if returncode:
        cleanup_detail = f"; cleanup={cleanup['status']}" if returncode == 124 else ""
        message = (
            f"immutable admission-base test enumeration failed ({returncode}){cleanup_detail}:\n" +
            _bounded(output))
        if returncode == 124:
            raise BoundedCommandFailure(message, cleanup)
        raise RuntimeError(message)
    tests = read_test_events(events_path)
    if not tests:
        raise RuntimeError("immutable admission-base test enumeration returned no identities")
    tests.sort(key=test_identity)
    identities = [test_identity(event) for event in tests]
    if len(identities) != len(set(identities)):
        raise RuntimeError("immutable admission-base test enumeration contains duplicate identities")
    manifest = {
        "schema_version": 1,
        "base_commit": base_commit,
        "exclude": ["live"],
        "enumeration_command": " ".join(enumeration),
        "formatter_sha256": formatter_sha256,
        "tests": [{key: event[key] for key in ("file", "module", "name", "parameters")} for event in tests],
    }
    encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    manifest["manifest_sha256"] = hashlib.sha256(encoded).hexdigest()
    manifest["setup_duration_ms"] = round((time.monotonic() - started) * 1000)
    return manifest


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


def plan_phases(root, guard, build_path):
    stages = [list(stage) for stage in STAGES]
    preparation = stages[:2] + [["xcrun", "clang", "-dynamiclib", "-Wall", "-Werror", str(root / "test/support/process_group.c"), "-o", guard]]
    rehearsals = ["mix", "run", "scripts/check/rehearsals.exs"]
    fixture_validation = list(FIXTURE_VALIDATION_STAGE)
    if build_path:
        # A caller-owned build path is shared by every Mix environment, so the
        # stages that compile or load it keep their strict order.
        credo_and_test = [[command] for command in stages[2:]] + [[rehearsals], [fixture_validation]]
        return [[["elixir", "--version"]], preparation, [list(TEST_COMPILE_STAGE)]] + credo_and_test
    # Separate _build/dev and _build/test: credo, the suite, the rehearsals and
    # the fixture validation only read the compiled build, so they overlap.
    # The rehearsals stay listed before the fixture validation.
    guard_stage = preparation[2]
    return [
        [["elixir", "--version"]],
        preparation[:2],
        [guard_stage],
        [list(TEST_COMPILE_STAGE)],
        stages[2:] + [rehearsals, fixture_validation],
    ]


# Phases planned without a caller-owned build path that may overlap the
# isolated child-module cache preparation: the version probe and the format and
# compile pair. The process-guard build writes into that cache directory, so it
# and every later phase wait for the cache.
CACHE_OVERLAP_PHASES = 2


def gate_timing(stage_results, candidate_timings, whole_gate_seconds, setup_ms, conditions):
    """Diagnostic whole-gate, per-stage and bottleneck timing for the receipt.

    Never a pass/fail input: a correct run is correct however long it took.
    """
    stages = [
        {"command": stage["command"], "status": stage["status"],
         "duration_ms": stage.get("duration_ms", 0), "phase": stage.get("phase", "gate")}
        for stage in stage_results
    ]
    slowest_stages = sorted(stages, key=lambda stage: -stage["duration_ms"])[:5]
    cases = (candidate_timings or {}).get("cases", []) if isinstance(candidate_timings, dict) else []
    modules = (candidate_timings or {}).get("modules", []) if isinstance(candidate_timings, dict) else []
    return {
        "diagnostic_only": True,
        "whole_gate_duration_ms": round(whole_gate_seconds * 1000),
        "setup_duration_ms": setup_ms,
        "stages": stages,
        "conditions": conditions,
        "bottlenecks": {
            "stages": slowest_stages,
            "test_cases": cases[:10],
            "test_modules": modules[:10],
        },
    }


def main():
    if sys.argv[1:] == ["--source-manifest-sha256"]:
        print(source_manifest_sha256(Path(__file__).resolve().parents[2]))
        return 0
    if len(sys.argv) >= 3 and sys.argv[1] == "--signature-frame":
        # CLI replay mode (scenario signatures-identify-failures): computes
        # the same frame offline.py emits for its own failing stage, over an
        # already-captured log on stdin, for another test's or tool's use.
        stage = sys.argv[2]
        log = sys.stdin.read()
        print(f"{FAILURE_SIGNATURE_TAG}\t{failure_signature_frame(stage, log, include_reproduce=False)}")
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
    # Proof controls are owned by this invocation. Never let a caller's stale
    # event/cache variables turn an ordinary check into a dry run or redirect
    # its trace and timing evidence.
    for key in (
        "KOGEN_TEST_EVENT_LOG", "KOGEN_TEST_EVENT_OWNER_PID", "KOGEN_TEST_EVENT_OWNER_PATH",
        "KOGEN_TEST_TIMING_SUMMARY",
        "KOGEN_REHEARSAL_TRACE", "KOGEN_REHEARSAL_RECEIPT", "KOGEN_REHEARSAL_SUITE_EVENTS", "KOGEN_WARM_POOL",
        "KOGEN_FIXTURE_VALIDATION_RECEIPT", "KOGEN_REHEARSAL_TRACE_READY",
        "KOGEN_ISOLATED_BEAM_PREPARE", "KOGEN_ISOLATED_BEAM_CACHE",
        "KOGEN_ISOLATED_BEAM_MANIFEST",
    ):
        env.pop(key, None)
    env["KOGEN_TEST_DRY_RUN"] = ""
    env["KOGEN_TEST_ROOT"] = str(root)
    print(f"Resolved Git executable: {git}", flush=True)
    build_path = env.get("MIX_BUILD_PATH")
    cold = env.get("KOGEN_COLD_OFFLINE") == "1"
    if cold:
        provider_receipt = root / ".kogen/runtime/path-shim-invoked"
        cold_failures = validate_cold_environment(
            build_path, env, provider_receipt)
        if cold_failures:
            raise RuntimeError("invalid cold-offline environment: " + "; ".join(cold_failures))
    # The complete check carries the immutable base inventory, current
    # Candidate-test results, diagnostic inventory diff, rehearsal,
    # controlled-prepare and runtime-pin proof in its one receipt.
    # Cold-offline is the explicit, diagnostic-only empty-cache run, not a
    # second copy of that proof and never a routine acceptance suite.
    admission_proof = not cold
    caches = ([Path(build_path)] if build_path else
              [root / "_build/dev", root / "_build/test"])
    warm = all((path / "lib/kogen/ebin/Elixir.Kogen.Build.beam").is_file()
               for path in caches)
    # Deny accidental default-provider resolution throughout the offline path.
    env["PATH"] = str(root / "test/support") + os.pathsep + env.get("PATH", "")
    print(f"Offline gate: {platform.platform()}; installed dependencies; "
          f"build path={env.get('MIX_BUILD_PATH', '_build')}; warm={warm}", flush=True)
    conditions = {
        "host": platform.platform(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "build_path": env.get("MIX_BUILD_PATH", "_build"),
        "warm_cache": warm,
        "cold_offline": cold,
    }
    result = 1
    invocation = os.environ.get("KOGEN_OFFLINE_INVOCATION") or secrets.token_hex(16)
    receipt_path = Path(os.environ.get(
        "KOGEN_OFFLINE_RECEIPT",
        root / ".kogen/runtime/offline-results" / f"{invocation}.json",
    ))
    stage_results = []
    bindings = None
    support = tempfile.TemporaryDirectory(prefix="kogen-check-support-")
    base_manifest = None
    candidate_events = []
    inventory_diff = None
    isolated_cache = None
    proof = None
    candidate_timings = None
    setup_ms = 0
    runtime_readiness = None
    gate_started = None
    cache_future = None
    overlapped_result = 0
    env["KOGEN_REHEARSAL_TRACE"] = str(Path(support.name) / "candidate-traces.txt")
    env["KOGEN_TEST_PROCESS_GUARD"] = str(Path(support.name) / "process_group.dylib")

    def proof_setup_failure(command, message, error=None, duration_ms=0):
        stage_results.append({
            "command": [command], "status": "failed", "exit_code": 125,
            "duration_ms": duration_ms, "bounded_log": _bounded(message),
            "signature": _signature([command], 125, message),
            "cleanup": getattr(error, "cleanup", {"status": "not-required"}),
            "phase": "proof-setup",
        })
        return 125

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
        if admission_proof:
            try:
                runtime_readiness = verify_managed_runtimes(root, env)
                print(
                    f"Managed runtime preflight: passed ({runtime_readiness['duration_ms'] / 1000:.3f}s); "
                    f"Codex={runtime_readiness['runtimes']['codex']['version']}; "
                    f"Claude Code={runtime_readiness['runtimes']['claude_code']['version']}",
                    flush=True,
                )
                setup_ms = runtime_readiness["duration_ms"]
            except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as error:
                runtime_readiness = {"status": "failed", "error": _bounded(str(error))}
                result = proof_setup_failure(
                    "managed-runtime-readiness", f"managed runtime availability failed: {error}", error)
                return result
            try:
                base_manifest = make_base_manifest(root, git, env, support.name)
            except (OSError, subprocess.SubprocessError, ValueError, RuntimeError, tarfile.TarError) as error:
                result = proof_setup_failure(
                    "admission-base-manifest", f"immutable admission-base setup failed: {error}",
                    error, setup_ms)
                return result
            setup_ms += base_manifest["setup_duration_ms"]
            (Path(support.name) / "base-manifest.json").write_text(
                json.dumps(base_manifest, sort_keys=True) + "\n")
            print(
                f"Admission base setup: {base_manifest['setup_duration_ms'] / 1000:.3f}s; "
                f"HEAD={base_manifest['base_commit']}; tests={len(base_manifest['tests'])}",
                flush=True,
            )
            cache_path = Path(support.name) / "isolated-beams"
            cache_setup_started = time.monotonic()
            cache_executor = None
            cache_env = dict(env)
            env["KOGEN_TEST_EVENT_LOG"] = str(Path(support.name) / "candidate-tests.jsonl")
            env["KOGEN_TEST_TIMING_SUMMARY"] = str(Path(support.name) / "candidate-timings.json")
            env["KOGEN_REHEARSAL_RECEIPT"] = str(Path(support.name) / "rehearsals.json")
            # Rehearsal receipts bind each command to the suite tests it
            # selects, so the rehearsals stage reads the suite's event log.
            env["KOGEN_REHEARSAL_SUITE_EVENTS"] = env["KOGEN_TEST_EVENT_LOG"]
            # Rehearsals run beside the suite; they read its trace only after
            # run_stage records the suite's completion here.
            env["KOGEN_REHEARSAL_TRACE_READY"] = str(Path(support.name) / "suite-finished")
            env["KOGEN_FIXTURE_VALIDATION_RECEIPT"] = str(Path(support.name) / "fixture-validation.jsonl")
            env["KOGEN_WARM_POOL"] = "1"
            env["KOGEN_ISOLATED_BEAM_CACHE"] = str(cache_path)
            env["KOGEN_ISOLATED_BEAM_MANIFEST"] = str(cache_path / "modules.json")
            env["KOGEN_TEST_PROCESS_GUARD"] = str(cache_path / "process_group.dylib")
            if not build_path:
                # The cache preparation compiles _build/test; the overlapped
                # phases touch only _build/dev and read sources.
                gate_started = time.monotonic()
                cache_executor = ThreadPoolExecutor(max_workers=1)
                cache_future = cache_executor.submit(
                    prepare_isolated_beam_cache, root, cache_env, cache_path)
                early_phases = plan_phases(
                    root, str(cache_path / "process_group.dylib"), build_path)[:CACHE_OVERLAP_PHASES]
                overlapped_result = run_ordered(early_phases, root, env, stage_results)
            try:
                if cache_future is not None:
                    try:
                        isolated_cache = cache_future.result()
                    finally:
                        cache_executor.shutdown(wait=True)
                else:
                    isolated_cache = prepare_isolated_beam_cache(root, cache_env, cache_path)
            except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as error:
                cache_setup_ms = round((time.monotonic() - cache_setup_started) * 1000)
                if not overlapped_result:
                    setup_ms += cache_setup_ms
                    result = proof_setup_failure(
                        "isolated-beam-cache-preparation",
                        f"isolated child-module cache preparation failed: {error}", error, cache_setup_ms)
                    return result
                # An earlier overlapped stage already failed; that is the
                # primary failure and the cache is not needed to report it.
                isolated_cache = None
            if isolated_cache is not None:
                setup_ms += isolated_cache["duration_ms"]
                stage_results.append({
                    "command": isolated_cache["command"], "status": "passed", "exit_code": 0,
                    "duration_ms": isolated_cache["duration_ms"],
                    "bounded_log": isolated_cache["bounded_log"],
                    "signature": _signature(isolated_cache["command"], 0, "isolated BEAM cache prepared"),
                    "cleanup": {"status": "not-required"},
                    "phase": "proof-setup",
                })
                print(
                    f"Isolated child cache setup: {isolated_cache['duration_ms'] / 1000:.3f}s; "
                    f"modules={isolated_cache['cached_modules']}; fallbacks={isolated_cache['source_fallbacks']}; "
                    f"sha256={isolated_cache['cache_sha256']}",
                    flush=True,
                )
        overlapped = cache_future is not None
        if gate_started is None:
            gate_started = time.monotonic()
        # Format only reads sources. Compilation owns the build output; both
        # finish and propagate their status before Credo or tests can start.
        phases = plan_phases(root, env["KOGEN_TEST_PROCESS_GUARD"], build_path)
        if overlapped:
            # The version, format and compile phases already ran beside the
            # isolated child-module cache preparation.
            later = phases[CACHE_OVERLAP_PHASES:]
            result = overlapped_result or (
                run_ordered(later, root, env, stage_results) if later else 0)
        else:
            result = run_ordered(phases, root, env, stage_results)
        if admission_proof:
            try:
                candidate_events = read_test_events(env["KOGEN_TEST_EVENT_LOG"])
                event_error = None
            except (OSError, ValueError, KeyError, TypeError) as error:
                candidate_events = []
                event_error = error
            if base_manifest is not None:
                inventory_diff = test_inventory_diff(base_manifest, candidate_events)
            proof = {
                "schema_version": 2,
                "status": "failed",
                "base_manifest": base_manifest,
                "test_inventory_diff": inventory_diff,
                "isolated_child_cache": isolated_cache,
                "runtime_readiness": runtime_readiness,
                "candidate_tests": candidate_events,
                "failures": ["an offline gate stage failed"] if result else [],
            }
        if admission_proof and result == 0:
            try:
                if event_error is not None:
                    raise event_error
                candidate_timings = json.loads(Path(env["KOGEN_TEST_TIMING_SUMMARY"]).read_text())
                rehearsal_receipt = json.loads(Path(env["KOGEN_REHEARSAL_RECEIPT"]).read_text())
                # The rehearsal owner must retain the catalog's declarations;
                # absence is a failed proof, never an empty requirement.
                failures = validate_admission_proof(
                    base_manifest, candidate_events, rehearsal_receipt, runtime_readiness)
                stage_fixture_records = read_fixture_records(env["KOGEN_FIXTURE_VALIDATION_RECEIPT"])
                failures += validate_fixture_proof(rehearsal_receipt, stage_fixture_records)
                fixture_digests = sorted(
                    (item.get("label"), item.get("digest"))
                    for item in stage_fixture_records + [
                        record for prepare in rehearsal_receipt.get("controlled_prepares", [])
                        for record in prepare.get("fixture_validations", [])])
            except (OSError, ValueError, KeyError, TypeError) as error:
                rehearsal_receipt = {}
                fixture_digests = []
                failures = [f"admission proof evidence could not be validated: {error}"]
            if failures:
                message = "; ".join(failures)
                stage_results.append({
                    "command": ["admission-proof-validation"], "status": "failed", "exit_code": 1,
                    "duration_ms": 0, "bounded_log": _bounded(message),
                    "signature": _signature(["admission-proof-validation"], 1, message),
                    "cleanup": {"status": "not-required"},
                })
                result = 1
            rehearsal_observed = {
                item for rehearsal in rehearsal_receipt.get("rehearsals", [])
                for item in rehearsal.get("observed", [])
            }
            proof.update({key: value for key, value in rehearsal_receipt.items()
                          if key not in proof and key != "schema_version"})
            proof.update({
                "status": "passed" if result == 0 else "failed",
                "candidate_timings": candidate_timings,
                "failures": failures,
            })
            bindings["admission_proof"] = {
                "base_commit": base_manifest["base_commit"],
                "base_manifest_sha256": base_manifest["manifest_sha256"],
                "formatter_sha256": base_manifest["formatter_sha256"],
                "candidate_test_events": len(candidate_events),
                "required_rehearsal_traces": len(rehearsal_observed),
                "controlled_prepares": len(rehearsal_receipt.get("controlled_prepares", [])),
                "isolated_cache_sha256": isolated_cache["cache_sha256"],
                "isolated_cache_modules": isolated_cache["cached_modules"],
                # Provider-denied validation of every generated fixture: the
                # count and one digest over (label, input-digest) pairs, so the
                # exact bytes a target later consumes can be compared.
                "validated_fixtures": len(fixture_digests),
                "validated_fixtures_sha256": hashlib.sha256(
                    json.dumps(fixture_digests, separators=(",", ":")).encode()).hexdigest(),
            }
            proof["validated_fixtures"] = [{"label": label, "digest": digest} for label, digest in fixture_digests]
        if result:
            return result
        if cold:
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
        if admission_proof and proof is None:
            proof = {
                "schema_version": 2,
                "status": "failed",
                "base_manifest": base_manifest,
                "test_inventory_diff": inventory_diff,
                "isolated_child_cache": isolated_cache,
                "runtime_readiness": runtime_readiness,
                "failures": [stage["bounded_log"] for stage in stage_results if stage["status"] == "failed"],
            }
        cleanup_error = None
        try:
            support.cleanup()
        except OSError as error:
            cleanup_error = error
        cleanup = ({"status": "passed", "owner": "offline-stage-supervisor"}
                   if cleanup_error is None else
                    {"status": "failed", "owner": "offline-stage-supervisor",
                    "reason": str(cleanup_error)})
        if cleanup_error is not None:
            result = 127
            if proof is not None:
                proof["status"] = "failed"
                proof.setdefault("failures", []).append(f"temporary cleanup failed: {cleanup_error}")
        elapsed = time.monotonic() - started
        timing = gate_timing(stage_results, candidate_timings, elapsed, setup_ms, conditions)
        if gate_started is not None:
            timing["gate_stages_duration_ms"] = round((time.monotonic() - gate_started) * 1000)
        settle_receipt(
            receipt_path,
            invocation,
            stage_results,
            cleanup,
            bindings,
            proof,
            timing,
        )
        print(f"Offline receipt: {receipt_path}", flush=True)
        slowest = ", ".join(
            f"{' '.join(stage['command'])}={stage['duration_ms'] / 1000:.3f}s"
            for stage in timing["bottlenecks"]["stages"][:3])
        print(f"Slowest stages (diagnostic): {slowest or 'none'}", flush=True)
        print(f"Complete offline gate: {elapsed:.3f}s; exit={result}", flush=True)
        if cleanup_error is not None:
            raise RuntimeError(f"offline cleanup failed after stage settlement: {cleanup_error}")

if __name__ == "__main__":
    sys.exit(main())
