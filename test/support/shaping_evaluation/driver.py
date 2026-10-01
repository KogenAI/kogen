#!/usr/bin/env python3
"""Evidence-local headless Shape driver: speaks only the public `mix kogen.shape` engine commands."""
import argparse, datetime, hashlib, json, os, re, shutil, signal, subprocess, sys, threading, time, traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]
# The controller runs a target's `--prepare` standalone, with no runtime
# directory supplied; that mode then owns a private one for its duration.
# Every other mode still requires the caller's runtime directory.
OWNED_PREPARE_RUNTIME = None
if (__name__ == "__main__" and "--prepare" in sys.argv[1:]
        and not os.environ.get("KOGEN_SHAPING_EVALUATION_RUNTIME")):
    import tempfile
    OWNED_PREPARE_RUNTIME = tempfile.mkdtemp(prefix="kogen-shaping-prepare-")
    os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = OWNED_PREPARE_RUNTIME
RUNTIME = Path(os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"]).resolve()
FIXTURE_ROOT_ENV = "KOGEN_SHAPING_EVALUATION_FIXTURE_ROOT"


def managed_root():
    return Path(os.environ.get("KOGEN_CODEX_ROOT", Path.home() / "Library/Application Support/Kogen/codex"))


def managed_runtime_context():
    root = managed_root()
    selected = json.loads((root / "default.json").read_text())["version"]
    matches = sorted((root / "runtimes").glob(selected + "-*/vendor/*/bin/codex"))
    if len(matches) != 1:
        raise RuntimeError("expected exactly one selected managed native runtime")
    return matches[0], root / "accounts/shared"


# The driver resolves the one route whose harness is the harness under test
# (`codex` or `claude`), never `default_route`, so a run never depends on
# whichever harness `default_route` currently names.
ROUTE_ELIXIR_TEMPLATE = '''
    routes =
      case YamlElixir.read_from_file(".kogen/config.yaml") do
        {:ok, %{"routes" => routes}} when is_map(routes) -> routes
        _ -> raise "shaping-evaluation fixture config has no routes"
      end
    candidates =
      for {name, route} <- routes, is_map(route), route["harness"] == "__HARNESS__", do: name
    route_name =
      case candidates do
        [only] -> only
        other -> raise "expected exactly one __HARNESS__ route; candidates: #{inspect(other)}"
      end
    {:ok, config} = Kogen.Intent.read_config(".kogen/config.yaml", route_name)
'''


def route_elixir(harness):
    """Elixir source that binds `route_name` and `config` for the one route of `harness`."""
    return ROUTE_ELIXIR_TEMPLATE.replace("__HARNESS__", harness)


CODEX_ROUTE_ELIXIR = route_elixir("codex")


DEFAULT_SESSION_ROOT = managed_root() / "accounts/shared/sessions"
SESSION_ROOT = DEFAULT_SESSION_ROOT
FIXTURES = HERE / "fixtures"
COMPACT_FIXTURES = HERE / "compact-fixtures-v2"
CASES = ("csv-flawed", "csv-complete", "booking-flawed", "booking-complete", "csv-continuation",
         "stateful-flawed", "stateful-complete")
MAX_SECONDS = 600
# The smoke owner fails a route that is not ready within 20 minutes of start.
ROUTE_READY_SECONDS = 20 * 60
# Each provider session retains its independent ten-minute deadline. The suite
# supervisor additionally owns fixture setup, the concurrency barrier, result
# collection, and cleanup, so its deadline must include bounded orchestration
# slack rather than expiring at the same instant as the children.
SUITE_SECONDS = MAX_SECONDS + 120
PARSER_CODE_PATHS_ENV = "KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS"
PARSER_OUTPUT_LIMIT = 2_000


def wall_now():
    """Wall time is retained only for human-readable provenance timestamps."""
    return time.time()


def monotonic_now():
    """Deadlines and elapsed durations must not move with wall-clock changes."""
    return time.monotonic()


class DraftParseError(RuntimeError):
    """A retained Draft cannot be projected safely into evaluation evidence."""

    def __init__(self, kind, case, source, message, *, command=None, stdout=None, stderr=None):
        details = [f"{case}: {kind}: {message}", f"source={source}"]
        if command:
            details.append("command=" + " ".join(command))
        if stdout:
            details.append("stdout=" + (stdout.decode(errors="replace") if isinstance(stdout, bytes) else stdout))
        if stderr:
            details.append("stderr=" + (stderr.decode(errors="replace") if isinstance(stderr, bytes) else stderr))
        super().__init__("; ".join(details))
        self.kind = kind
        self.case = case
        self.source = str(source)
        self.command = command
        self.stdout = stdout
        self.stderr = stderr

class TriggerMismatch(RuntimeError):
    pass


# The minimum set of saved-Draft files that establish a reviewable end state.
# Matches the files required_case_capture() already demands of every captured
# case, so a case missing any of them is not a genuine terminal Draft.
REQUIRED_DRAFT_FILES = frozenset({"intent.yaml", "scenarios.yaml", "questions.md"})


def turn_end_decision(case, next_msg, messages, draft_files):
    """Pure fail-fast decision for a completed turn's end state.

    Called the instant a native turn completes, with no I/O of its own, so it
    is directly importable by both the driver and offline/replay tests.
    ``draft_files`` is the set of file names the caller observed directly in
    the saved Draft directory at that instant (empty if no Draft directory
    exists at all). This never inspects wall time: a turn that never
    completes is unaffected and keeps running to the caller's unchanged
    MAX_SECONDS timeout.

    Returns an ("advance" | "complete" | "fail", reason) pair:
      - "advance": scripted messages remain; the caller should send the next one.
      - "complete": no scripted message is left; the completed turn's saved
        Draft reached the expected end state (every required file present).
      - "fail": no scripted message is left, and the completed turn's Draft
        did not reach that expected end state (it is missing entirely, or is
        missing one of its required files). The caller must fail this case
        immediately, naming the case and the missing evidence, rather than
        let the suite discover the same gap only after spending its full
        deadline on every case.
    """
    if next_msg < len(messages):
        return "advance", None
    missing = sorted(REQUIRED_DRAFT_FILES - set(draft_files))
    if missing:
        return "fail", (f"{case}: completed turn's saved Draft is missing "
                        f"{', '.join(missing)} and no scripted answer remains")
    return "complete", None


def bounded_output(value):
    if isinstance(value, bytes):
        value = value.decode(errors="replace")
    value = (value or "").strip()
    return value[:PARSER_OUTPUT_LIMIT] + ("…" if len(value) > PARSER_OUTPUT_LIMIT else "")

CSV_FLAWED = 'Shape the CSV normalization feature described in README.md. Use slug eval-csv-flawed. Save the Draft without approval.'
CSV_COMPLETE = 'Shape the CSV normalization feature described in README.md. Use slug eval-csv-complete. Save the Draft without approval.'
BOOKING_FLAWED = 'Shape the availability lookup described in README.md. Use slug eval-booking-flawed. Save the Draft without approval.'
BOOKING_COMPLETE = 'Shape the availability lookup described in README.md. Use slug eval-booking-complete. Save the Draft without approval.'
CSV_ANSWER = 'Support UTF-8 with or without BOM by format, preserve inputs. Leave invalid-row handling and existing-output replacement behavior undecided. Save the Draft and pause without approval.'
CSV_CONT_PARTIAL = 'Reject the whole input on any invalid row with actionable feedback; do not export a subset.'
CSV_CONT_FINAL = 'After successful complete validation, replace an existing regular output or create a missing output. On failure preserve the old output bytes, or leave it absent. Report success only after the final output is written. Clean only temporary files created by this invocation. This is clarification, not approval.'
CSV_CONTINUATION = 'Shape the CSV normalization feature described in README.md. Use slug eval-csv-continuation. Format and input ownership are settled in evidence/facts.json. Invalid-row handling and existing-output replacement are two separate consequential choices that facts.json does not settle: ask the Shaper about each as its own question, resolve the invalid-row policy first, and do not assume either. Save the Draft without approval.'
BOOKING_ANSWER = 'Limit this feature to an already connected organizer with availability.read. Use the maintained synthetic capability seed to recreate a private connection per run, refuse collisions and remove only run-owned data afterward. Preserve the seed and its supplied lifecycle; these checks establish synthetic availability only, not real OAuth. This is clarification, not approval.'

CURRENT_REQUESTS = {
    "csv-flawed": CSV_FLAWED,
    "csv-complete": CSV_COMPLETE,
    "booking-flawed": BOOKING_FLAWED,
    "booking-complete": BOOKING_COMPLETE,
    "csv-continuation": CSV_CONTINUATION,
    "stateful-flawed": "Shape the stateful verification guardrail described in evidence/stateful-guardrail-flawed.md with exact slug eval-stateful-flawed. Save the Draft without approval.",
    "stateful-complete": "Shape the stateful verification guardrail described in evidence/stateful-guardrail-complete.md with exact slug eval-stateful-complete. Save the Draft without approval.",
}

def canonical_case(label):
    for case in CURRENT_REQUESTS:
        if label == case or label.startswith(case + "-"):
            return case
    return "csv-complete" if label.startswith("csv") else "booking-complete"

def current_request(label):
    if label == "smoke":
        return SMOKE_REQUEST
    return CURRENT_REQUESTS[canonical_case(label)]

def selected_session_root(fixture):
    if SESSION_ROOT != DEFAULT_SESSION_ROOT:
        return SESSION_ROOT
    root = managed_root()
    project_id = hashlib.sha256(str(Path(fixture).resolve()).encode()).hexdigest()
    selector = root / "preferences" / project_id
    if selector.exists():
        selected = selector.read_text()
        if selected not in {"shared\n", "project\n"}:
            raise RuntimeError(f"unrecognized Kogen account selector: {selector}")
        scope = selected.strip()
    else:
        scope = "shared"
    account = root / "accounts/shared" if scope == "shared" else root / "accounts/projects" / project_id
    return account / "sessions"


def inventory(session_root=None):
    root = Path(session_root or SESSION_ROOT)
    return {str(p) for p in root.rglob("rollout-*.jsonl")} if root.exists() else set()

def first_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.loads(handle.readline())

def exact_root_rollout(before, fixture, session_root=None):
    matches=[]
    for name in inventory(session_root)-before:
        try: meta=first_json(name).get("payload",{})
        except Exception: continue
        if meta.get("cwd")==str(fixture): matches.append(name)
    roots=[]
    for name in matches:
        source=first_json(name).get("payload",{}).get("source")
        if not (isinstance(source,dict) and "subagent" in source): roots.append(name)
    return roots

def task_complete_count(path):
    count=0
    try:
        with open(path,encoding="utf-8") as handle:
            for line in handle:
                event=json.loads(line)
                if event.get("type")=="event_msg" and event.get("payload",{}).get("type")=="task_complete": count+=1
    except (OSError,json.JSONDecodeError): pass
    return count

def user_turn_terminal(path, submitted_messages):
    """Use the shared ordered native-binding validator for the full sent ledger."""
    try:
        events=[json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]
        bindings=integrity_module().ordered_turn_bindings(events, submitted_messages)
    except (OSError, json.JSONDecodeError, ValueError):
        return None, False
    if not bindings: return None, False
    return bindings[-1]["turn_id"], True

def rollout_summary(path):
    summary = {"id": None, "cwd": None, "source": None, "models": [], "efforts": [], "task_complete_count": 0, "last_token_count": None}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            item = json.loads(line); payload = item.get("payload", {})
            if item.get("type") == "session_meta":
                summary.update({key: payload.get(key) for key in ("id", "cwd", "source")})
            if item.get("type") == "turn_context":
                model = payload.get("model"); effort = payload.get("effort") or payload.get("reasoning_effort")
                if model and model not in summary["models"]: summary["models"].append(model)
                if effort and effort not in summary["efforts"]: summary["efforts"].append(effort)
            if item.get("type") == "event_msg" and payload.get("type") == "task_complete": summary["task_complete_count"] += 1
            if item.get("type") == "event_msg" and payload.get("type") == "token_count": summary["last_token_count"] = payload
    return summary

def configured_profiles(fixture, harness="codex"):
    code=route_elixir(harness) + 'IO.write(Jason.encode!(config))'
    result=subprocess.run(eval_argv(code),cwd=fixture,capture_output=True,text=True,timeout=30,
                          env={**os.environ,"MIX_BUILD_PATH":str(fixture/"_build")})
    if result.returncode: raise RuntimeError(f"could not normalize tracked config: {result.stderr.strip()}")
    config=json.loads(result.stdout)
    helpers=config["helpers"]
    return {"root":(config["shaping"]["model"],config["shaping"]["effort"]),
            "scout":(helpers["scout"]["model"],helpers["scout"]["effort"]),
            "worker":(helpers["worker"]["model"],helpers["worker"]["effort"]),
            "expert":(helpers["expert"]["model"],helpers["expert"]["effort"])}, {"bytes_sha256":hashlib.sha256((fixture/".kogen/config.yaml").read_bytes()).hexdigest(),"normalized":config}


def resolved_route(fixture, harness="codex"):
    """The one route whose harness is `harness`, resolved from the fixture's own
    config and never from default_route. Passed explicitly to
    `mix kogen.shape --route` so the driver never depends on whichever harness
    default_route names."""
    code = route_elixir(harness) + 'IO.write(route_name)'
    result = subprocess.run(eval_argv(code), cwd=fixture,
                            capture_output=True, text=True, timeout=30,
                            env={**os.environ, "MIX_BUILD_PATH": str(fixture / "_build")})
    if result.returncode:
        raise RuntimeError(f"could not resolve {harness} route: {result.stderr.strip()}")
    return result.stdout.strip()



def observed_role(summary):
    source = summary.get("source")
    if not isinstance(source, dict) or "subagent" not in source: return "root"
    spawn = source.get("subagent", {}).get("thread_spawn", {})
    role = (spawn.get("agent_role") or spawn.get("agent_type") or "").lower()
    native_to_profile = {"explorer": "scout", "worker": "worker", "default": "expert"}
    return next((profile for native, profile in native_to_profile.items() if native in role), None)

def profile_match(summary, profiles):
    role = observed_role(summary)
    expected = profiles.get(role)
    observed = (summary.get("models", [None])[0] if len(summary.get("models", [])) == 1 else None, summary.get("efforts", [None])[0] if len(summary.get("efforts", [])) == 1 else None)
    return expected is not None and observed == expected

def copy_owned_sessions(before, fixture, out, profiles):
    new = sorted(inventory() - before)
    metas = []
    for name in new:
        try:
            meta = first_json(name).get("payload", {})
        except Exception:
            continue
        metas.append({"path": name, "id": meta.get("id"), "cwd": meta.get("cwd"), "source": meta.get("source")})
    exact = [m for m in metas if m.get("cwd") == str(fixture)]
    ids = {m.get("id") for m in exact}
    changed = True
    while changed:
        changed = False
        for m in metas:
            source = m.get("source")
            parent = source.get("subagent", {}).get("thread_spawn", {}).get("parent_thread_id") if isinstance(source, dict) else None
            if parent in ids and m.get("id") not in ids:
                exact.append(m); ids.add(m.get("id")); changed = True
    owned = out / "owned-rollouts"; owned.mkdir()
    private = out / "private-raw-rollouts"; private.mkdir()
    for m in exact:
        concise_lines = []
        shutil.copy2(m["path"], private / Path(m["path"]).name)
        with open(m["path"], encoding="utf-8") as source:
            for line in source:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                payload = event.get("payload", {})
                item_type = payload.get("type") if isinstance(payload, dict) else None
                if event.get("type") == "session_meta":
                    keep={key:payload.get(key) for key in ("id","cwd","source","timestamp","cli_version","model","effort") if key in payload}
                    concise_lines.append(json.dumps({"type":"session_meta","payload":keep},separators=(",",":"))+"\n")
                elif event.get("type") == "turn_context":
                    keep={key:payload.get(key) for key in ("turn_id","model","effort","reasoning_effort","timestamp") if key in payload}
                    concise_lines.append(json.dumps({"type":"turn_context","payload":keep},separators=(",",":"))+"\n")
                elif event.get("type") == "event_msg" and item_type in {"task_started","task_complete","task_aborted","task_interrupted","turn_interrupted","token_count"}:
                    concise_lines.append(line)
                elif event.get("type") == "response_item" and item_type in {"function_call","function_call_output","custom_tool_call","custom_tool_call_output"}:
                    concise_lines.append(line)
                elif event.get("type") == "response_item" and item_type == "message":
                    channel=payload.get("channel") if isinstance(payload,dict) else None
                    content=payload.get("content",[]) if isinstance(payload,dict) else []
                    private_assistant=payload.get("role")=="assistant" and (channel=="analysis" or any(isinstance(part,dict) and part.get("channel")=="analysis" for part in content if isinstance(content,list)))
                    if not private_assistant: concise_lines.append(line)
        (owned / Path(m["path"]).name).write_text("".join(concise_lines))
    # Complete needs inspectable public model outputs without indexing private
    # native streams. Preserve visible messages and relevant tool evidence with
    # source-file hash and native session/turn mapping.
    transcript=[]
    for source in sorted(owned.glob("*.jsonl")):
        source_hash = sha256(source)
        for index,line in enumerate(source.read_text().splitlines()):
            event=json.loads(line); payload=event.get("payload", {})
            if event.get("type")=="response_item" and payload.get("type") in {"message","function_call","function_call_output","custom_tool_call","custom_tool_call_output"}:
                transcript.append({"source":source.name,"source_sha256":source_hash,"event_index":index,"event":event})
    (out / "public-transcript.json").write_text(json.dumps({"schema_version":1,"native_sources":[{"path":p.name,"sha256":sha256(p)} for p in sorted(owned.glob("*.jsonl"))],"visible_events":transcript}, indent=2)+"\n")
    roots = [m for m in exact if not (isinstance(m.get("source"), dict) and "subagent" in m["source"])]
    summaries = [rollout_summary(m["path"]) for m in exact]
    (out / "owned-session-metadata.json").write_text(json.dumps(summaries, indent=2) + "\n")
    return {"new_count": len(new), "unmatched_count": len(new)-len(exact),
            "owned": summaries, "roots": [r.get("id") for r in roots],
            "exactly_one_root": len(roots) == 1,
            "all_owned_terminal": bool(summaries) and all(x["task_complete_count"] > 0 for x in summaries),
            "all_profiles_match": bool(summaries) and all(profile_match(x, profiles) for x in summaries),
            "requested_profiles": profiles}

def fixture_status(fixture, slug):
    lines = subprocess.run(["git", "status", "--porcelain"], cwd=fixture,
                           capture_output=True, text=True, check=True).stdout.splitlines()
    allowed_prefix = f".kogen/intents/drafts/{slug}/"
    paths = [line[3:] for line in lines]
    return {"lines": lines, "only_expected_draft_changes":
            bool(lines) and all(path == allowed_prefix[:-1] or path.startswith(allowed_prefix)
                                for path in paths)}

def copy_dependency_sources(source, target):
    """Materialize writable dependency sources, never cached build products."""
    ignored = shutil.ignore_patterns("_build", "ebin", ".git")
    shutil.copytree(source, target, symlinks=False, ignore=ignored)
    for path in target.rglob("*"):
        if path.is_symlink():
            raise RuntimeError(f"dependency copy retained symlink: {path}")


# Kept in sync with the @volatile list in lib/kogen/build/guarded_paths.ex.
# A fixture copy is a fresh Candidate-like checkout: it must never inherit the
# controller's own volatile state (lockfiles, runtime caches, harness/native
# session homes, build artifacts), only tracked and other genuine sources.
GUARDED_PATHS_VOLATILE = (".kogen/runtime", ".kogen/build.lock", ".kogen/codex", ".codex/sessions",
                          "_build", "deps", "cover", ".elixir_ls")


def copy_fixture_source_tree(project, fixture, label):
    """rsync a fresh writable fixture tree, excluding every GuardedPaths
    volatile path plus the fixture-only exclusions below. Isolated so it is
    directly testable with a small planted tree, without also exercising
    setup_fixture's git/mix bootstrap."""
    excludes = [f"--exclude={path}" for path in GUARDED_PATHS_VOLATILE]
    subprocess.run(["rsync", "-a", *excludes, "--exclude=.git",
                    "--exclude=.kogen/intents", "--exclude=test/support/shaping_evaluation", str(project)+"/", str(fixture)+"/"], check=True)
    volatile_copied = [path for path in GUARDED_PATHS_VOLATILE if (fixture / path).exists()]
    if volatile_copied:
        raise RuntimeError(f"{label}: fixture copy retained volatile GuardedPaths state: {volatile_copied}")


def append_rehearsal_trace(name):
    trace_path = os.environ.get("KOGEN_REHEARSAL_TRACE")
    if trace_path:
        with open(trace_path, "a", encoding="utf-8") as handle:
            handle.write(name + "\n")


FIXTURE_VALIDATION = HERE.parent / "fixture_validation.ex"


def validate_generated_fixture(fixture, label, extra_files, draft=None):
    """Validate the generated fixture, as the target will consume it, through
    Kogen's real parsers (`Kogen.FixtureValidation`, run under `mix run`), and
    return the record (including the input digest). Runs with providers denied
    when the caller is a `--prepare`; fails closed on any invalid input, so a
    malformed fixture is an offline failure before provider dispatch."""
    spec = {"root": str(fixture), "kind": "shaping-evaluation", "label": label,
            "require_denied": os.environ.get("KOGEN_PROVIDERS_DENIED") in ("1", "true"),
            "required": ["README.md", "Makefile", "evidence/prerequisite_control.py",
                         "evidence/current-prerequisite-receipt.json",
                         "evidence/complete-input-receipt.json", *extra_files],
            "json": ["evidence/current-prerequisite-receipt.json", "evidence/complete-input-receipt.json",
                     *[name for name in extra_files if name.endswith(".json")]],
            "yaml": [name for name in extra_files if name.endswith((".yaml", ".yml"))],
            "makefile_targets": ["check", "live"], "readme_links": "README.md",
            "input_receipt": "evidence/complete-input-receipt.json"}
    if draft:
        spec["draft"] = draft
    spec_path = RUNTIME / f"{label}-fixture-validation-spec.json"
    if os.environ.get(PARSER_CODE_PATHS_ENV):
        # A live owner runs inside an isolated child whose private, empty
        # MIX_BUILD_PATH would make `mix run` recompile every dependency;
        # like the YAML parser, use the owner's current compiled paths in a
        # bare BEAM instead of starting Mix.
        command = ["elixir"]
        for path in parser_code_paths(label, spec_path):
            command.extend(["-pa", path])
        command += ["-r", str(FIXTURE_VALIDATION), "-e", "Kogen.FixtureValidation.main()", "--", str(spec_path)]
    else:
        command = ["mix", "run", "--no-start", "-r", str(FIXTURE_VALIDATION), "-e",
                   "Kogen.FixtureValidation.main()", "--", str(spec_path)]
    spec_path.write_text(json.dumps(spec))
    try:
        result = subprocess.run(command, cwd=PROJECT, env={**os.environ, "MIX_ENV": "test"},
                                capture_output=True, text=True, timeout=180)
    finally:
        spec_path.unlink(missing_ok=True)
    if result.returncode:
        raise RuntimeError(f"{label}: generated fixture failed validation:\n"
                           f"{result.stderr or result.stdout}")
    frames = [line for line in result.stdout.splitlines() if line.startswith("KOGEN_FIXTURE_VALIDATION\t")]
    if len(frames) != 1:
        raise RuntimeError(f"{label}: fixture validation reported {len(frames)} records")
    return json.loads(frames[0].split("\t", 1)[1])


def catalog_placeholder_rules(fixture):
    """No-op Make rules for the copied verification catalog's other targets.
    The fixture Makefile replaces the project's, and the Shaping audit's real
    Deterministic layer refuses a catalog target without an ordinary Make rule,
    so without these a headless session in the fixture could never be ready."""
    catalog = fixture / "priv/kogen/verification_targets.yaml"
    try:
        text = catalog.read_text(encoding="utf-8")
    except OSError:
        return ""
    names = re.findall(r'^\s*-\s*name:\s*"?([A-Za-z0-9._-]+)"?\s*$|"name"\s*:\s*"([A-Za-z0-9._-]+)"', text, re.M)
    rules = []
    for name in dict.fromkeys(a or b for a, b in names):
        if name not in ("check", "live"):
            rules.append(f"{name}:\n\t@true\n")
    return "".join(rules)


def fixture_location(label, name=None):
    fixture_parent = (
        Path(os.environ[FIXTURE_ROOT_ENV]).resolve()
        if os.environ.get(FIXTURE_ROOT_ENV)
        else RUNTIME
    )
    fixture = fixture_parent / (name or label)
    if os.environ.get(FIXTURE_ROOT_ENV) and fixture.resolve().is_relative_to(PROJECT.resolve()):
        raise RuntimeError(f"{label}: live fixture root must be outside the publishable project: {fixture}")
    return fixture


def setup_fixture(label, extra_files, *, name=None, bootstrap=True, owned_fixture=None):
    """Generate the fixture for `label` and validate it. With `bootstrap=False`
    only the input files are materialized (no git baseline, no compile) under
    `name`, so `--prepare` can validate every case's inputs cheaply while the
    prepared case still gets its complete setup."""
    append_rehearsal_trace("driver.setup_fixture")
    fixture_parent = fixture_location(label, name).parent
    fixture_parent.mkdir(parents=True, exist_ok=True)
    fixture = Path(owned_fixture).resolve() if owned_fixture is not None else fixture_location(label, name)
    if owned_fixture is None:
        if fixture.exists(): raise RuntimeError(f"fixture exists: {fixture}")
        fixture.mkdir()
    elif fixture != fixture_location(label, name).resolve() or not fixture.is_dir() or fixture.is_symlink():
        raise RuntimeError(f"{label}: expected the pre-established owned fixture directory: {fixture}")
    copy_fixture_source_tree(PROJECT, fixture, label)
    if (PROJECT/"deps").exists(): copy_dependency_sources(PROJECT / "deps", fixture / "deps")
    for rel, data in extra_files.items():
        path=fixture/rel; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data if isinstance(data,bytes) else data.encode())
    controls = (HERE / "compact_prerequisites.py").read_bytes()
    (fixture / "evidence/prerequisite_control.py").write_bytes(controls)
    control = subprocess.run(["python3", "-B", "evidence/prerequisite_control.py", label], cwd=fixture,
                             capture_output=True, text=True, timeout=60)
    if control.returncode:
        raise RuntimeError(f"{label}: current CLI prerequisite failed: {control.stderr}")
    (fixture / "evidence/current-prerequisite-receipt.json").write_text(control.stdout)
    check = ("mix test test/fixture_greeting_contract_test.exs"
             if label == "smoke" else f"python3 -B evidence/prerequisite_control.py {label}")
    if label == "smoke":
        proof = fixture / "test/fixture_greeting_contract_test.exs"
        # The selected fixture test stays separate from Kogen's larger engine
        # rehearsal. It calls the named product producer and checks the artifact.
        proof.write_text(SMOKE_GREETING_PROOF)
    (fixture / "Makefile").write_text(f"check:\n\t{check}\nlive:\n\tpython3 -B evidence/prerequisite_control.py {label}\n"
                                      + catalog_placeholder_rules(fixture))
    write_fixture_readme(fixture, label)
    verify_fixture_readme_links(fixture)
    write_complete_input_receipt(fixture, label)
    if not bootstrap:
        validate_generated_fixture(fixture, label, extra_files)
        return fixture
    env={**os.environ,"GIT_AUTHOR_NAME":"Kogen Evaluation","GIT_AUTHOR_EMAIL":"eval@example.invalid","GIT_COMMITTER_NAME":"Kogen Evaluation","GIT_COMMITTER_EMAIL":"eval@example.invalid"}
    subprocess.run(["git","init","-q","-b","main"],cwd=fixture,check=True,env=env)
    subprocess.run(["git","add","-A"],cwd=fixture,check=True,env=env)
    subprocess.run(["git","commit","-q","-m","evaluation baseline"],cwd=fixture,check=True,env=env)
    compiled = subprocess.run(["mix", "compile", "--warnings-as-errors"], cwd=fixture,
                              env={**env, "MIX_BUILD_PATH": str(fixture / "_build")},
                              capture_output=True, text=True, timeout=120)
    (RUNTIME / f"{label}-precompile.log").write_text(compiled.stdout + compiled.stderr)
    if compiled.returncode:
        raise RuntimeError(f"fixture precompile failed: {compiled.returncode}")
    record = validate_generated_fixture(fixture, label, extra_files)
    (RUNTIME / f"{label}-fixture-inputs.json").write_text(json.dumps(record) + "\n")
    return fixture


def write_fixture_readme(fixture, label):
    domain = ("CSV normalization" if label.startswith("csv") else
              "calendar availability" if label.startswith("booking") else
              "headless-flow greeting" if label == "smoke" else "stateful verification guardrail")
    if label == "smoke":
        fixture.joinpath("README.md").write_text(f"""# {domain}

## Current user request

{current_request(label)}

This is a headless-flow smoke fixture. [The brief](evidence/brief.md),
[artifact facts](evidence/greeting.md), [settled facts](evidence/facts.json),
and [fixture contract](evidence/fixture-contract.md) name the producer and its
focused test. The product scope is the future greeting artifact; the outer
driver observes Shaping-engine progress separately.
""")
        return
    fixture.joinpath("README.md").write_text(f"""# {domain}

## Current user request

{current_request(label)}

Shape the feature specified in [the brief](evidence/fixture-contract.md) and
[settled facts](evidence/facts.json). Inspect the linked prerequisite reader,
adapter, or stateful control and receipts in evidence/. These sources establish
parsing, synthetic access, or fixture behavior only; the requested CLI feature
is not implemented. Proposed verification
must exercise the actual CLI output and failures. Current Kogen source under
lib/ and priv/ supplies the public Shaping command. Add future feature sources
under app/ and focused feature checks under test/; the verification target bodies
must be updated to reach them.
""")

def verify_fixture_readme_links(fixture):
    text=(fixture/"README.md").read_text()
    for relative in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
        if "://" not in relative and not (fixture/relative).is_file():
            raise RuntimeError(f"fixture README link is missing: {relative}")

def write_complete_input_receipt(fixture, label):
    candidates = [path for path in sorted(fixture.rglob("*")) if path.is_file() and not path.is_symlink()]
    inputs = []
    for path in candidates:
        relative = path.relative_to(fixture).as_posix()
        if relative == "evidence/complete-input-receipt.json":
            continue
        if relative.startswith((".git/", "_build/", "deps/")):
            continue
        inputs.append({"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    receipt = {"kind": "current fixture bootstrap and source inputs", "case": label,
               "inputs": inputs,
               "limits": "Hashes establish the supplied synthetic fixture inputs only; they do not prove the proposed feature or external-provider availability."}
    (fixture / "evidence/complete-input-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

def compact_files(*names):
    return {f"evidence/{name}": (COMPACT_FIXTURES / name).read_bytes() for name in names}

def csv_files(complete=False, continuation=False):
    facts = json.loads((COMPACT_FIXTURES / "facts.json").read_text())
    selected = {key: facts["csv"][key] for key in ("feature", "format", "ownership", "output_contract")}
    if not complete and not continuation:
        selected["format"] = selected["format"].replace("UTF-8 with optional leading BOM;", "UTF-8;")
    if complete:
        selected.update({key: facts["csv"][key] for key in ("invalid_policy", "replacement_policy")})
    selected["source_ownership"] = facts["shared"]["source_ownership"]
    files = compact_files("plain.csv", "bom.csv", "invalid-date.csv", "naive_reader.py", "reader_control.py")
    files["evidence/facts.json"] = json.dumps(selected, indent=2) + "\n"
    files["evidence/fixture-contract.md"] = ("Implement normalize INPUT OUTPUT using the settled facts. "
        + ("The compatible reader has a current plain/BOM/invalid-date receipt; preserve its limited proof."
           if complete or continuation else "The proposed reader is naive_reader.py; its plain-file receipt succeeded. Supplied examples may expose a material format gap.")
        + " Input files remain read-only. Reader controls are prerequisites, not proof of complete normalized export.\n")
    return files

def booking_files(complete=False):
    facts = json.loads((COMPACT_FIXTURES / "facts.json").read_text())
    selected = {key: facts["calendar"][key] for key in ("feature", "data", "failure", "setup", "output_contract")}
    selected["actors"] = ("Already connected organizer org-1 with availability.read." if complete
                          else "Proposed organizer org-1 has no connection; connection setup is proposed out of scope.")
    selected["source_ownership"] = facts["shared"]["source_ownership"]
    files = compact_files("capability-seed.json", "calendar_adapter.py")
    files["evidence/facts.json"] = json.dumps(selected, indent=2) + "\n"
    files["evidence/old-receipt.md"] = "Historical slots success used .tmp/calendar-run-17/connection.json for org-1 with availability.read. That temporary run has ended.\n"
    files["evidence/inventory.txt"] = "Current inventory: .tmp/calendar-run-17/connection.json is absent. capability-seed.json is a maintained synthetic source; the adapter is separately available.\n"
    files["evidence/fixture-contract.md"] = ("Implement slots CONNECTION as a read-only synthetic CLI. "
        + ("The audience is already connected organizers. Use the supplied maintained setup lifecycle and current adapter controls."
           if complete else "The proposed audience has no connection and setup is proposed a non-goal. A previous success receipt is linked in old-receipt.md; determine actual present reachability.")
        + " Missing authority is unavailable, not an empty success. Synthetic proof establishes no real credentials or OAuth.\n")
    return files

def stateful_files(complete=False):
    brief = "stateful-guardrail-complete.md" if complete else "stateful-guardrail-flawed.md"
    files = {f"evidence/{name}": (HERE / name).read_bytes() for name in
             ("stateful_guardrail.py", "stateful_guardrail_control.py", brief)}
    files["evidence/stateful-mode.txt"] = ("complete\n" if complete else "flawed\n").encode()
    files["evidence/facts.json"] = (json.dumps({
        "feature": "stateful verification admission before observable dispatch",
        "mode": "complete" if complete else "flawed",
        "ownership": "fixture sources are read-only; Shaping may write only its Draft",
        "evidence_limit": "deterministic controls establish fixture behavior, not full-route correctness"
    }, indent=2) + "\n").encode()
    files["evidence/fixture-contract.md"] = (
        "Use stateful_guardrail_control.py to run the deterministic two-failure, "
        "corruption, exhaustion replay, valid repair, and receipt-consumer controls. "
        "The source and action marker are fixture-owned and must remain unchanged.\n"
    ).encode()
    return files

# The smoke case `headless-flow` (cases/headless-flow/) is the headless live
# check: one paragraph brief that yields one question, one answer sent while the
# first turn still runs, and one message after the turn. It is deliberately not
# a CASES member and grades no product feature; it proves the engine mechanics
# against a real Shaping Controller on each route.
SMOKE_CASE = "headless-flow"
SMOKE_REQUEST = (HERE / "cases/headless-flow/brief.md").read_text()
SMOKE_GREETING_PROOF = (HERE / "cases/headless-flow/greeting-proof.exs.txt").read_text()
SMOKE_ANSWER = (HERE / "cases/headless-flow/message-1.md").read_text().strip()
SMOKE_FOLLOWUP = (HERE / "cases/headless-flow/message-2.md").read_text().strip()
# The smoke fixture pins the shaping effort of the route under test to low and
# its worker and expert helpers to the route's cheap helper model; the auditor
# stays as configured, because the answer-not-applied check needs the real one.
SMOKE_EFFORT = "low"
SMOKE_HELPER_MODELS = {"codex": "gpt-6-luna", "claude": "claude-sonnet-5"}
SMOKE_SHAPING_LINE = re.compile(r"^(    shaping:\s*\{[^}\n]*\beffort:\s*)([\w-]+)", re.M)
SMOKE_WORKER_LINE = re.compile(r"^      worker:\s*\{[^}\n]*\}\n", re.M)
SMOKE_EXPERT_LINE = re.compile(r"^      expert:\s*\{[^}\n]*\}\n", re.M)
SMOKE_MAX_SECONDS = ROUTE_READY_SECONDS
SMOKE_SUITE_SECONDS = 45 * 60


def pinned_smoke_config(config, harness="codex"):
    """Pin the given route's Shaping effort and cheap helpers to low."""
    routes = re.split(r"^(?=  \S[^\n]*:\s*$)", config, flags=re.M)
    matching = [index for index, block in enumerate(routes)
                if index and re.search(rf"^    harness:\s*{re.escape(harness)}\s*$", block, re.M)]
    if len(matching) != 1:
        raise RuntimeError(f"smoke: expected exactly one block-style {harness} route, found {len(matching)}")
    block, count = SMOKE_SHAPING_LINE.subn(lambda m: m.group(1) + SMOKE_EFFORT, routes[matching[0]])
    if count != 1:
        raise RuntimeError(f"smoke: the {harness} route has no single flow-map shaping line to pin")

    def pin_helper(pattern, name):
        nonlocal block
        block, changed = pattern.subn(
            f"      {name}: {{model: {SMOKE_HELPER_MODELS[harness]}, effort: {SMOKE_EFFORT}}}\n", block)
        if changed != 1:
            raise RuntimeError(f"smoke: the {harness} route has no single flow-map {name} helper line to pin")

    pin_helper(SMOKE_WORKER_LINE, "worker")
    pin_helper(SMOKE_EXPERT_LINE, "expert")
    routes[matching[0]] = block
    return "".join(routes)


def require_smoke_effort(receipt):
    """The pinned effort reached the launched session: configured, and (on the
    codex route, whose native rollouts are captured) observed on its turns."""
    configured = (((receipt.get("configured_profiles") or {}).get("normalized") or {}).get("shaping") or {}).get("effort")
    if configured != SMOKE_EFFORT:
        raise RuntimeError(f"smoke: Shaping effort not applied; configured {configured!r}, expected {SMOKE_EFFORT!r}")


def smoke_files(harness="codex"):
    config = pinned_smoke_config(pinned_smoke_config((PROJECT / ".kogen/config.yaml").read_text(), "codex"), "claude")
    return {".kogen/config.yaml": config,
            "app/greeting_writer.ex": (HERE / "cases/headless-flow/greeting-writer.exs.txt").read_text(),
            "test/fixture_greeting_contract_test.exs": SMOKE_GREETING_PROOF,
            "evidence/brief.md": SMOKE_REQUEST,
            "evidence/greeting.md": (HERE / "cases/headless-flow/evidence/greeting.md").read_text(),
            "evidence/facts.json": (HERE / "cases/headless-flow/evidence/facts.json").read_text(),
            "evidence/fixture-contract.md": (HERE / "cases/headless-flow/evidence/fixture-contract.md").read_text()}


def draft_dir(fixture, slug): return fixture/".kogen/intents/drafts"/slug

def source_snapshot(fixture):
    snapshot = {}
    result=subprocess.run(["git","ls-files","--cached","--others","--exclude-standard","-z"],cwd=fixture,capture_output=True,check=True)
    for raw in result.stdout.split(b"\0"):
        if not raw: continue
        relative=raw.decode(); path=fixture/relative
        if path.is_file() and not path.is_symlink(): snapshot[relative]=hashlib.sha256(path.read_bytes()).hexdigest()
    return snapshot

def rollout_contains(path, text):
    try:
        return text.lower() in Path(path).read_text(errors="replace").lower()
    except OSError:
        return False

def booking_reachability_trigger(text, _root):
    lowered = text.lower()
    unavailable = any(word in lowered for word in ("missing", "absent", "unavailable", "deleted"))
    exact_fixture = ".tmp/calendar-run-17/connection.json" in text
    semantic_fixture = "historical" in lowered and "temporary" in lowered and any(
        word in lowered for word in ("receipt", "run", "connection"))
    return unavailable and (exact_fixture or semantic_fixture)

def read_draft(fixture, slug):
    root=draft_dir(fixture,slug)
    return "\n".join(p.read_text(errors="replace") for p in root.rglob("*") if p.is_file()) if root.exists() else ""

def process_rows():
    rows=[]
    ps=subprocess.run(["ps","-axo","pid=,ppid=,lstart=,command="],capture_output=True,text=True,check=True)
    for line in ps.stdout.splitlines():
        parts=line.strip().split(None,7)
        if len(parts)>=8:
            rows.append({"pid":int(parts[0]),"ppid":int(parts[1]),"started":" ".join(parts[2:7]),"command":parts[7]})
    return rows

def process_cwd(pid):
    output=subprocess.run(["lsof","-a","-p",str(pid),"-d","cwd","-Fn"],capture_output=True,text=True).stdout
    paths=[line[1:] for line in output.splitlines() if line.startswith("n")]
    return paths[0] if len(paths)==1 else None

def owned_process_tree(fixture):
    rows=process_rows(); by_parent={}
    for row in rows: by_parent.setdefault(row["ppid"],[]).append(row)
    roots=[row for row in rows if any(name in row["command"].lower() for name in ("codex", "claude")) and process_cwd(row["pid"])==str(fixture)]
    owned=[]; pending=[(row,row["pid"]) for row in roots]
    while pending:
        row,root_pid=pending.pop()
        owned.append({**row,"cwd":process_cwd(row["pid"]),"root_pid":root_pid})
        pending.extend((child,root_pid) for child in by_parent.get(row["pid"],[]))
    return owned

def reap_owned_cli(fixture, frozen=None):
    before=frozen if frozen is not None else owned_process_tree(fixture); actions=[]; remaining={row["pid"] for row in before}
    for signal_name,grace in ((signal.SIGTERM,8),(signal.SIGKILL,3)):
        current={row["pid"]:row for row in process_rows()}
        for row in sorted(before,key=lambda item:item["pid"],reverse=True):
            if row["pid"] not in remaining: continue
            observed=current.get(row["pid"])
            if observed is None or observed["started"]!=row["started"] or process_cwd(row["pid"])!=row["cwd"]:
                remaining.discard(row["pid"]); continue
            try: os.kill(row["pid"],signal_name); actions.append({**row,"signal":signal_name.name.removeprefix("SIG")})
            except ProcessLookupError: remaining.discard(row["pid"])
        deadline=monotonic_now()+grace
        while monotonic_now()<deadline and remaining:
            for pid in list(remaining):
                try: os.kill(pid,0)
                except ProcessLookupError: remaining.discard(pid)
            if remaining: time.sleep(.2)
    return {"roots":[row for row in before if row["pid"]==row["root_pid"]],"before":before,"actions":actions,
            "remaining_pids":sorted(remaining),"all_reaped":not remaining}

def parser_code_paths(case, source):
    encoded = os.environ.get(PARSER_CODE_PATHS_ENV)
    if not encoded:
        raise DraftParseError("parser dependency unavailable", case, source,
                              f"{PARSER_CODE_PATHS_ENV} is not supplied")
    try:
        paths = json.loads(encoded)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise DraftParseError("parser dependency unavailable", case, source,
                              f"{PARSER_CODE_PATHS_ENV} is malformed: {exc}") from exc
    if not isinstance(paths, list) or not paths or any(not isinstance(path, str) for path in paths):
        raise DraftParseError("parser dependency unavailable", case, source,
                              f"{PARSER_CODE_PATHS_ENV} must be a nonempty JSON array of paths")
    invalid = [path for path in paths if not Path(path).is_absolute() or not Path(path).is_dir()]
    if invalid:
        raise DraftParseError("parser dependency unavailable", case, source,
                              "compiled code paths are unavailable: " + ", ".join(invalid))
    return list(dict.fromkeys(paths))


# Successful parses keyed by the exact bytes and compiled code paths. The
# parser is a pure function of both, so re-reading unchanged Draft bytes
# (every turn check and the final projection) never re-spawns a BEAM.
# Failures are never cached; each one re-runs and keeps its own evidence.
#
# The memo is process-wide, not per loaded copy of this file: the integrity
# and audit consumers each load their own driver module, and a per-module
# memo made each of them re-boot a BEAM for bytes already parsed.
import types as _types
_MEMO = sys.modules.setdefault("kogen_shaping_yaml_memo", _types.ModuleType("kogen_shaping_yaml_memo"))
if not hasattr(_MEMO, "parsed"):
    _MEMO.parsed, _MEMO.locks, _MEMO.guard = {}, {}, threading.Lock()
PARSED_YAML = _MEMO.parsed


# Cases run concurrently, so identical bytes are parsed single-flight: the
# first caller spawns the BEAM and the others wait for its cached result
# instead of each booting their own.
PARSE_LOCKS = _MEMO.locks
PARSE_LOCKS_GUARD = _MEMO.guard


def parse_yaml_document(contents, *, case, source):
    """Parse original Draft bytes through the current compiled YAML dependency."""
    paths = parser_code_paths(case, source)
    key = (tuple(paths), bytes(contents))
    with PARSE_LOCKS_GUARD:
        lock = PARSE_LOCKS.setdefault(key, threading.Lock())
    with lock:
        return _parse_yaml_document(contents, paths, key, case=case, source=source)


def _parse_yaml_document(contents, paths, key, *, case, source):
    if key in PARSED_YAML:
        return json.loads(PARSED_YAML[key])
    code=("try do case YamlElixir.read_from_string(IO.binread(:stdio, :eof)) do "
          "{:ok, value} when is_map(value) -> IO.write(Jason.encode!(value)); "
          "{:ok, _} -> IO.write(:stderr, \"KOGEN_YAML_NON_MAP\\n\"); System.halt(23); "
          "{:error, reason} -> IO.write(:stderr, \"KOGEN_YAML_MALFORMED \" <> inspect(reason)); System.halt(22); "
          "other -> IO.write(:stderr, \"KOGEN_YAML_MALFORMED \" <> inspect(other)); System.halt(22) "
          "end rescue error in UndefinedFunctionError -> IO.write(:stderr, \"KOGEN_YAML_DEPENDENCY_UNAVAILABLE\\n\"); "
          "IO.write(:stderr, inspect(error)); System.halt(21); error -> IO.write(:stderr, \"KOGEN_YAML_MALFORMED \" <> inspect(error)); System.halt(22) end")
    command = ["elixir", "--erl", "+S 2:2 +SDcpu 1 +SDio 1"]
    for path in paths:
        command.extend(["-pa", path])
    # Do not start Mix here: with the isolated child's private MIX_BUILD_PATH,
    # Mix resets dependency paths before parsing.  This bare BEAM receives the
    # exact current compiled paths above and cannot populate that private cache.
    command.extend(["-e", code])
    try:
        result=subprocess.run(command, cwd=PROJECT, input=contents, capture_output=True,
                              timeout=30)
    except subprocess.TimeoutExpired as exc:
        raise DraftParseError("parser subprocess timeout", case, source,
                              "supported YAML parser exceeded 30 seconds", command=command,
                              stdout=exc.stdout, stderr=exc.stderr) from exc
    except OSError as exc:
        raise DraftParseError("parser dependency unavailable", case, source, str(exc),
                              command=command) from exc
    if result.returncode:
        stderr = bounded_output(result.stderr)
        markers = {
            21: ("KOGEN_YAML_DEPENDENCY_UNAVAILABLE", "parser dependency unavailable"),
            22: ("KOGEN_YAML_MALFORMED", "malformed YAML"),
            23: ("KOGEN_YAML_NON_MAP", "non-map YAML"),
        }
        marker, expected_kind = markers.get(result.returncode, (None, None))
        kind = expected_kind if marker and stderr.startswith(marker) else "parser subprocess nonzero"
        raise DraftParseError(kind, case, source, f"supported YAML parser exited {result.returncode}",
                              command=command, stdout=result.stdout, stderr=result.stderr)
    try:
        decoded=json.loads(result.stdout)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise DraftParseError("malformed parser JSON", case, source, str(exc),
                              command=command, stdout=result.stdout, stderr=result.stderr) from exc
    if not isinstance(decoded,dict):
        raise DraftParseError("non-map YAML", case, source,
                              "supported YAML parser did not return a mapping", command=command,
                              stdout=result.stdout, stderr=result.stderr)
    PARSED_YAML[key] = json.dumps(decoded)
    return decoded


def parse_yaml_mapping(path, *, case="unknown case"):
    """Return a YAML map without replacing malformed Draft evidence with nulls."""
    path = Path(path)
    if not path.is_file():
        raise DraftParseError("missing Draft input", case, path, "intent.yaml is absent")
    try:
        contents = path.read_bytes()
    except OSError as exc:
        raise DraftParseError("missing Draft input", case, path, str(exc)) from exc
    return parse_yaml_document(contents, case=case, source=path)

def write_draft_state(fixture,slug,out,case="unknown case"):
    path=draft_dir(fixture,slug)/"intent.yaml"
    decoded=parse_yaml_mapping(path, case=case)
    state=project_draft_state(decoded, fixture, slug, case)
    (out/"draft-state.json").write_text(json.dumps(state,indent=2)+"\n")
    return state


def project_draft_state(decoded, fixture, slug, case):
    baseline=decoded.get("shaped_against") if isinstance(decoded.get("shaped_against"),dict) else {}
    visits=decoded.get("shaping_continuations")
    latest=visits[-1] if isinstance(visits,list) and visits else decoded.get("shaping", {})
    state={"intent_id":decoded.get("id"),
           "baseline":{"branch":baseline.get("branch"),"head":baseline.get("head")},
           "visit_id":latest.get("started") if isinstance(latest,dict) else None,
           "unapproved":draft_dir(fixture,slug).is_dir() and not (fixture/".kogen/intents/approved"/slug).exists()}
    nonblank = lambda value: isinstance(value, str) and bool(value.strip())
    missing = [key for key in ("intent_id", "visit_id") if not nonblank(state[key])]
    if not all(nonblank(state["baseline"][key]) for key in ("branch", "head")):
        missing.append("baseline")
    if decoded.get("status") != "draft" or not state["unapproved"]:
        raise DraftParseError("Draft is approved or incomplete", case, draft_dir(fixture,slug)/"intent.yaml",
                              "captured Draft must retain explicit draft status")
    if missing:
        raise DraftParseError("Draft provenance incomplete", case, draft_dir(fixture,slug)/"intent.yaml",
                              "missing " + ", ".join(missing))
    return state

def write_csv_probe_result(fixture,out):
    evidence=fixture/"evidence"; inputs=[evidence/name for name in ("plain.csv","bom.csv","invalid-date.csv","naive_reader.py","reader_control.py")]
    command=["python3","-B","naive_reader.py"]
    plain=subprocess.run(command+["plain.csv"],cwd=evidence,capture_output=True,text=True,timeout=30)
    bom=subprocess.run(command+["bom.csv"],cwd=evidence,capture_output=True,text=True,timeout=30)
    invalid_command=["python3","-B","reader_control.py","invalid-date.csv"]
    invalid=subprocess.run(invalid_command,cwd=evidence,capture_output=True,text=True,timeout=30)
    payload={"runner":"local compact reader controls", "command":command, "input_sha256":{path.name:sha256(path) for path in inputs},
             "plain_result":{"exit":plain.returncode,"stdout":plain.stdout,"stderr":plain.stderr},
             "bom_result":{"exit":bom.returncode,"stdout":bom.stdout,"stderr":bom.stderr},
             "plain_vs_bom":{"plain_exit":plain.returncode,"bom_exit":bom.returncode,"same_output":plain.stdout==bom.stdout},
             "invalid_date_control":{"command":invalid_command,"exit":invalid.returncode,"stdout":invalid.stdout,"stderr":invalid.stderr}}
    (out/"csv-probe-result.json").write_text(json.dumps(payload,indent=2)+"\n")

def write_booking_setup_observation(fixture,out):
    evidence=fixture/"evidence"; old=evidence/"old-receipt.md"; inventory=evidence/"inventory.txt"
    payload={"old_receipt_path":"evidence/old-receipt.md","old_receipt_sha256":sha256(old),"old_receipt":old.read_text(),
             "inventory_path":"evidence/inventory.txt","inventory_sha256":sha256(inventory),"inventory":inventory.read_text(),
             "missing_connection":".tmp/calendar-run-17/connection.json"}
    (out/"booking-setup-observation.json").write_text(json.dumps(payload,indent=2)+"\n")

def write_stateful_control_result(fixture, out, case):
    mode = "complete" if case.endswith("complete") else "flawed"
    result = subprocess.run(
        ["python3", "-B", "stateful_guardrail_control.py", mode,
         "--output", str(out / "stateful-control-result.json")],
        cwd=fixture / "evidence", capture_output=True, text=True, timeout=30)
    if result.returncode not in (0, 1):
        raise RuntimeError(f"{case}: stateful deterministic controls failed to run: {result.stderr}")

def copy_fixture_sources(fixture,case,out):
    target=out/"fixture-source"; target.mkdir()
    shutil.copy2(fixture/"README.md",target/"README.md")
    kind=("csv" if case.startswith("csv") else "booking" if case.startswith("booking") else
          "smoke" if case == "smoke" else "stateful")
    for relative in (Path("app")/kind,Path("test")/kind):
        source=fixture/relative
        if source.is_dir(): shutil.copytree(source,target/relative,ignore=shutil.ignore_patterns("__pycache__","*.pyc","*.pyo",".DS_Store"))

def cleanup_fixture(fixture,case,*,failure=None,owned_fixture=False,allow_partial_failure=False):
    run=RUNTIME/"runs"/case
    run.mkdir(parents=True, exist_ok=True)
    receipt_path=run/"fixture-cleanup.json"
    required=[run/"receipt.json",run/"source-baseline.json",run/"source-after.json",run/"fixture-source/README.md"]
    fixture=Path(fixture)
    receipt={"fixture":str(fixture),"removed":False,"reason":None,"failure":failure}
    if not fixture.exists():
        receipt["removed"]=True
        receipt["reason"]="fixture already absent"
    elif owned_fixture:
        try:
            before=owned_process_tree(fixture)
            settled=reap_owned_cli(fixture,before) if before else {"before":[],"actions":[],"remaining_pids":[],"all_reaped":True}
            receipt["owned_processes"]={key:settled.get(key) for key in ("before","actions","remaining_pids","all_reaped")}
        except Exception as exc:
            settled={"all_reaped":False}
            receipt["owned_process_error"]={"type":type(exc).__name__,"message":str(exc)}
        diagnostics_complete=all(path.exists() for path in required)
        if settled.get("all_reaped") is True and (diagnostics_complete or (failure is not None and allow_partial_failure)):
            receipt["removal_pending"]=True
            try:
                receipt_path.write_text(json.dumps(receipt,indent=2)+"\n")
            except OSError as exc:
                receipt["reason"]=f"cleanup receipt could not be retained before deletion: {exc}"
            else:
                try:
                    shutil.rmtree(fixture)
                    receipt["removed"]=True
                    receipt["removal_pending"]=False
                except OSError as exc:
                    receipt["reason"]=f"fixture cleanup failed: {exc}"
        elif not settled.get("all_reaped"):
            receipt["reason"]="owned processes could not be confirmed settled; fixture retained"
        else:
            receipt["reason"]="required diagnostic capture incomplete; retained run-owned fixture"
    elif all(path.exists() for path in required):
        try:
            shutil.rmtree(fixture)
            receipt["removed"]=True
        except OSError as exc:
            receipt["reason"]=f"fixture cleanup failed: {exc}"
    else:
        receipt["reason"]="required diagnostic capture incomplete; retained run-owned fixture"
    receipt_path.write_text(json.dumps(receipt,indent=2)+"\n")
    return receipt

def require_cleanup(fixture,case,receipt,*,owned_fixture=False):
    cleanup=cleanup_fixture(fixture,case,owned_fixture=owned_fixture)
    if cleanup["removed"]:
        return
    receipt["outcome"]="infrastructure-error"
    cleanup_failure={"type":"CleanupFailure","message":f"{case}: {cleanup['reason']}"}
    if receipt.get("failure") is None:
        receipt["failure"]=cleanup_failure
    else:
        receipt["cleanup_failure"]=cleanup_failure
    run=RUNTIME/"runs"/case
    (run/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")


def write_authored_smoke_case(spec):
    """Freeze the authored smoke message sequence beside the captured run.

    The independent evidence consumer uses this small source snapshot to bind
    every sent message, request ID, and recorded text to the case as authored.
    """
    run = RUNTIME / "runs" / "smoke"
    messages = []
    for step in spec["steps"]:
        if step["step"] != "message":
            continue
        text = (Path(spec["dir"]) / step["file"]).read_text()
        messages.append({"file": step["file"], "when": step.get("when", "awaiting_answers"),
                         "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest()})
    start = next(step for step in spec["steps"] if step["step"] == "start")
    brief = (Path(spec["dir"]) / start["brief"]).read_bytes()
    payload = {"schema_version": 1, "name": spec.get("name"), "end": spec.get("end", "settled"),
               "brief": start["brief"], "brief_sha256": hashlib.sha256(brief).hexdigest(),
               "messages": messages}
    (run / "authored-case.json").write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def retain_smoke_driver_failure(stage, exc):
    run = RUNTIME / "runs" / "smoke"
    run.mkdir(parents=True, exist_ok=True)
    failure = {"stage": stage, "type": type(exc).__name__, "message": str(exc),
               "traceback": "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))}
    (run / "driver-failure.json").write_text(json.dumps(failure, indent=2) + "\n")
    return failure

# ---------------------------------------------------------------------------
# Headless engine transport.
#
# drive() speaks only the public commands of `mix kogen.shape`:
#   start    mix kogen.shape --brief FILE --request-id RID [--route ROUTE]
#   status   mix kogen.shape ID
#   message  mix kogen.shape ID --brief FILE --request-id RID
#   approve  mix kogen.shape ID --approve PRESENTATION --request-id RID
#   cancel   mix kogen.shape ID --cancel --request-id RID
# There is no terminal, expect or mailbox transport: the detached engine
# runner carries the provider turns, and this driver only polls its status.
# ---------------------------------------------------------------------------
ENGINE_STEPS = ("start", "message", "approve", "cancel")
MESSAGE_WHEN = ("awaiting_answers", "mid_turn", "turn_ended")
CASES_DIR = HERE / "cases"
# A rehearsal points this at a compiled fixture launcher; live runs use `mix`.
MIX_COMMAND = ["mix"]
# Evaluates Elixir in the fixture (route and profile lookup). None runs it with
# `mix run`; a rehearsal supplies a bare `elixir -pa ...` prefix instead.
EVAL_COMMAND = None
# Extra child environment for the engine (after external-driver stripping);
# rehearsals select the offline fake provider here.
ENGINE_ENV = {}
POLL_SECONDS = 2.0
MID_TURN_POLL_SECONDS = 0.5
COMMAND_SECONDS = 180
ENGINE_INTERFACE = "shaping-evaluation"
SETTLED_STATES = frozenset({"awaiting_answers", "ready"})
DEAD_STATES = frozenset({"blocked", "interrupted", "cancelled", "failed"})



class EngineError(RuntimeError):
    """The engine refused a command or printed something other than one JSON line."""

    def __init__(self, message, *, argv=None, exit_code=None, payload=None):
        super().__init__(message)
        self.argv = argv
        self.exit_code = exit_code
        self.payload = payload


class SessionFailure(RuntimeError):
    """The engine session reached a state the case script cannot continue from."""


class FailFast(RuntimeError):
    """The last scripted step ended in a state that cannot reach the expected end."""


def external_driver_env(fixture, extra=None, base=None):
    """The environment of an external driver: never a managed role. A driver that
    itself runs inside a Kogen role would otherwise be refused as `managed_role`."""
    env = {key: value for key, value in (os.environ if base is None else base).items()
           if key != "KOGEN_ROLE" and not key.startswith("KOGEN_SHAPING_")}
    env["MIX_BUILD_PATH"] = str(Path(fixture) / "_build")
    env.update(extra or {})
    return env


def eval_argv(code):
    if EVAL_COMMAND:
        return [*EVAL_COMMAND, "-e", code]
    return [*MIX_COMMAND, "run", "--no-compile", "--no-start", "-e", code]


def engine_argv(args):
    return [*MIX_COMMAND, "kogen.shape", *[str(arg) for arg in args]]


def run_engine(fixture, args, *, timeout=None):
    """Run one `mix kogen.shape` command and return (exit_code, status_json)."""
    argv = engine_argv(args)
    try:
        result = subprocess.run(argv, cwd=fixture, capture_output=True, text=True,
                                timeout=timeout or COMMAND_SECONDS,
                                env=external_driver_env(fixture, ENGINE_ENV))
    except subprocess.TimeoutExpired as exc:
        raise EngineError(f"engine command timed out: {' '.join(str(a) for a in args)}",
                          argv=argv) from exc
    lines = [line for line in (result.stdout or "").splitlines() if line.strip()]
    payload = None
    if len(lines) == 1:
        try:
            payload = json.loads(lines[0])
        except json.JSONDecodeError:
            payload = None
    if not isinstance(payload, dict):
        raise EngineError("engine stdout is not exactly one JSON object line: "
                          f"{bounded_output(result.stdout)!r} stderr={bounded_output(result.stderr)!r}",
                          argv=argv, exit_code=result.returncode)
    return result.returncode, payload


class EngineSession:
    """One engine session driven by the public commands, with a command ledger."""

    def __init__(self, fixture, case):
        self.fixture = Path(fixture)
        self.case = case
        self.session = None
        self.commands = []
        self.request_ids = []
        self.states = []
        self.last = None
        self.first_questions = None

    def call(self, args, *, request_id=None, tolerate=()):
        started = wall_now()
        exit_code, payload = run_engine(self.fixture, args)
        entry = {"argv": ["mix", "kogen.shape", *[str(arg) for arg in args]],
                 "request_id": request_id, "at": started, "exit": exit_code,
                 "state": payload.get("state"), "session": payload.get("session")}
        error = payload.get("error")
        if error:
            entry["error"] = error
        self.commands.append(entry)
        if request_id:
            self.request_ids.append(request_id)
        # Keep the engine's received status even when the command reports an
        # error payload. In particular, blocked/not_ready is settled evidence,
        # and must remain available to the caller and the pre-cleanup snapshot.
        self.observe(payload)
        refused = exit_code != 0 or (isinstance(error, dict) and error.get("code"))
        if refused and not (isinstance(error, dict) and error.get("code") in tolerate):
            code = error.get("code") if isinstance(error, dict) else None
            raise EngineError(f"engine refused `{' '.join(str(a) for a in args)}` "
                              f"(exit {exit_code}, {code}): {error}",
                              argv=entry["argv"], exit_code=exit_code, payload=payload)
        return payload

    def observe(self, payload):
        self.session = self.session or payload.get("session")
        self.last = payload
        state = payload.get("state")
        if not self.states or self.states[-1]["state"] != state:
            self.states.append({"state": state, "at": wall_now(), "monotonic": monotonic_now()})
        if self.first_questions is None and payload.get("questions"):
            self.first_questions = {"count": len(payload["questions"]), "state": state,
                                    "at": wall_now(), "questions": payload["questions"]}

    def start(self, brief, request_id, route=None):
        args = ["--brief", brief, "--request-id", request_id, "--interface", ENGINE_INTERFACE]
        if route:
            args += ["--route", route]
        return self.call(args, request_id=request_id)

    def status(self):
        return self.call([self.session])

    def message(self, path, request_id):
        return self.call([self.session, "--brief", path, "--request-id", request_id,
                          "--interface", ENGINE_INTERFACE], request_id=request_id)

    def approve(self, presentation, request_id):
        return self.call([self.session, "--approve", presentation, "--request-id", request_id,
                          "--interface", ENGINE_INTERFACE], request_id=request_id)

    def cancel(self, request_id):
        return self.call([self.session, "--cancel", "--request-id", request_id], request_id=request_id)


def no_pending(status):
    return not status.get("pending_inputs")


def wait_status(session, accept, *, deadline, label, fail_states=DEAD_STATES, poll=None):
    """Poll status until `accept(status)`. A state the script cannot continue
    from (dead, or a settled state the step did not expect) fails at once."""
    poll = POLL_SECONDS if poll is None else poll
    while True:
        status = session.status()
        if accept(status):
            return status
        state = status.get("state")
        if state in fail_states:
            detail = status.get("error") or ""
            raise SessionFailure(f"{session.case}: waiting for {label}, the session is {state} {detail}".strip())
        if monotonic_now() >= deadline:
            raise TimeoutError(f"{session.case}: {label} not reached before the deadline (last state {state})")
        time.sleep(poll)


def settled(status):
    return status.get("state") in SETTLED_STATES and no_pending(status)


def validate_case_spec(spec):
    """A case is a list of engine steps only: start, message, approve, cancel."""
    steps = spec.get("steps")
    if not isinstance(steps, list) or not steps:
        raise ValueError(f"{spec.get('name')}: a case needs at least a start step")
    for index, step in enumerate(steps):
        kind = step.get("step") if isinstance(step, dict) else None
        if kind not in ENGINE_STEPS:
            raise ValueError(f"{spec.get('name')}: step {index} is not an engine step: {step!r}")
        if (kind == "start") != (index == 0):
            raise ValueError(f"{spec.get('name')}: start must be the first and only start step")
        if kind == "start" and not step.get("brief"):
            raise ValueError(f"{spec.get('name')}: start needs a brief file")
        if kind == "message":
            if not step.get("file"):
                raise ValueError(f"{spec.get('name')}: message step {index} needs a file")
            if step.get("when", "awaiting_answers") not in MESSAGE_WHEN:
                raise ValueError(f"{spec.get('name')}: message step {index} has unknown when")
    if any(step["step"] in ("approve", "cancel") for step in steps[:-1]):
        raise ValueError(f"{spec.get('name')}: approve and cancel must be the last step")
    return spec


def load_case(name, cases_dir=None):
    base = Path(cases_dir or CASES_DIR) / name
    spec = json.loads((base / "case.json").read_text())
    spec["name"] = spec.get("name", name)
    spec["dir"] = str(base)
    return validate_case_spec(spec)


def case_names(cases_dir=None):
    base = Path(cases_dir or CASES_DIR)
    return sorted(path.parent.name for path in base.glob("*/case.json"))


def case_messages(spec):
    """The scripted message texts, in order."""
    return [(Path(spec["dir"]) / step["file"]).read_text()
            for step in spec["steps"] if step["step"] == "message"]


def contains_all(*needles):
    return lambda text: all(needle in text.lower() for needle in needles)


# Optional per-message checks on the visible Draft text and questions, kept from
# the earlier scripted evaluation: a message is only sent when the Draft raised
# the choice it answers.
TRIGGERS = {
    "csv-bom": lambda text: "bom" in text.lower(),
    "booking-reachability": lambda text: booking_reachability_trigger(text, None),
    "csv-invalid-rows": lambda text: "invalid" in text.lower() and "?" in text,
    "csv-output-replacement": lambda text: "output" in text.lower() and any(
        word in text.lower() for word in ("replacement", "replace", "overwrite")) and "?" in text,
}


def package_dir(fixture, status, slug=None):
    """Where the session's package lives: the status `package` path when it names
    one, else the conventional Draft directory."""
    package = (status or {}).get("package")
    if isinstance(package, str) and package:
        path = Path(package)
        path = path if path.is_absolute() else Path(fixture) / path
        if path.is_file():
            path = path.parent
        if path.is_dir():
            return path
    slug = slug or (status or {}).get("slug")
    return draft_dir(Path(fixture), slug) if slug else None


def read_package_text(fixture, status):
    root = package_dir(fixture, status)
    if root is None or not root.is_dir():
        return ""
    return "\n".join(p.read_text(errors="replace") for p in sorted(root.rglob("*")) if p.is_file())


def read_events(fixture, session_id):
    path = Path(fixture) / ".kogen/runtime/shaping" / str(session_id) / "events.jsonl"
    events = []
    if path.is_file():
        for line in path.read_text(errors="replace").splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                events.append(item)
    return events


def turn_records(events):
    """Per-turn provider id, kind, route, exit and usage from events.jsonl."""
    turns = {}
    order = []
    for event in events:
        turn = event.get("turn")
        if turn is None:
            continue
        record = turns.get(turn)
        if record is None:
            record = turns[turn] = {"turn": turn, "kind": None, "provider_session_id": None, "route": None,
                                    "exit": None, "usage": None, "events": [], "first_at": event.get("at"),
                                    "last_at": event.get("at")}
            order.append(turn)
        for key in ("kind", "provider_session_id", "route", "exit", "usage"):
            if event.get(key) is not None:
                record[key] = event[key]
        record["events"].append(event.get("event"))
        record["last_at"] = event.get("at") or record["last_at"]
    return [turns[turn] for turn in order]


def open_turn(events):
    """The newest turn_started (turn, launch id, start time) with no turn_ended yet, or None."""
    ended = {event.get("turn") for event in events if event.get("event") == "turn_ended"}
    for event in reversed(events):
        if event.get("event") == "turn_started" and event.get("turn") not in ended:
            return {"turn": event.get("turn"), "launch_id": event.get("launch_id"),
                    "kind": event.get("kind"), "started_at": event.get("at")}
    return None


def provider_session_ids(events):
    ids = []
    for event in events:
        value = event.get("provider_session_id")
        if value and value not in ids:
            ids.append(value)
    return ids


def kogen_commit():
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=PROJECT, capture_output=True, text=True,
                              timeout=20, check=True).stdout.strip() or None
    except Exception:
        return None


def harness_version(harness):
    """Best-effort `--version` of the harness binary; an offline fake is named, not run."""
    override = ENGINE_ENV.get("KOGEN_HARNESS") or os.environ.get("KOGEN_HARNESS")
    if override:
        return {"binary": override, "version": None, "note": "KOGEN_HARNESS override"}
    try:
        binary = str(managed_runtime_context()[0]) if harness == "codex" else (shutil.which(harness) or harness)
    except Exception:
        binary = shutil.which(harness) or harness
    try:
        result = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=20,
                                stdin=subprocess.DEVNULL)
        return {"binary": binary, "version": (result.stdout or result.stderr).strip() or None}
    except Exception as exc:
        return {"binary": binary, "version": None, "error": f"{type(exc).__name__}: {exc}"}


def write_config_record(out, *, case, harness, route, profiles, session, events, started, ended, fixture_root):
    root = (profiles or {}).get("root") or (None, None)
    turns = turn_records(events)
    record = {"schema_version": 1, "case": case, "route": route, "harness": harness,
              "model": root[0], "effort": root[1], "kogen_commit": kogen_commit(),
              "harness_version": harness_version(harness),
              "request_ids": list(session.request_ids), "session": session.session,
              "shaping_root": os.path.realpath(fixture_root), "shaping_intent_id": session.session,
              "started_at": started, "ended_at": ended,
              "provider_session_ids": provider_session_ids(events),
              "turns": [{key: turn[key] for key in ("turn", "kind", "provider_session_id", "route",
                                                    "exit", "usage", "first_at", "last_at")}
                        for turn in turns],
              "commands": session.commands}
    (out / "config-record.json").write_text(json.dumps(record, indent=2) + "\n")
    return record


def copy_engine_evidence(fixture, session_id, status, out):
    """Retain the session's engine state, reports and package beside the receipt,
    so evidence survives fixture cleanup. Raw provider streams stay behind."""
    ignore = shutil.ignore_patterns("__pycache__", "*.pyc", "turns", ".DS_Store")
    runtime = Path(fixture) / ".kogen/runtime/shaping" / str(session_id)
    if runtime.is_dir():
        shutil.copytree(runtime, out / "engine-runtime", ignore=ignore, dirs_exist_ok=True)
        feedback = runtime / "feedback-delivery" / "receipts.jsonl"
        if feedback.is_file():
            target = out / "feedback-delivery" / "receipts.jsonl"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(feedback, target)
    slug = (status or {}).get("slug")
    audits = Path(fixture) / ".kogen/runtime/shaping-audits" / str(slug or "")
    if slug and audits.is_dir():
        shutil.copytree(audits, out / "shaping-audits", ignore=shutil.ignore_patterns("auditor", "__pycache__"),
                        dirs_exist_ok=True)
    presented = (status or {}).get("presented") or {}
    proposal = presented.get("proposal_dir")
    if proposal:
        proposal = Path(proposal) if Path(proposal).is_absolute() else Path(fixture) / proposal
        if proposal.is_dir():
            shutil.copytree(proposal, out / "presented", ignore=ignore, dirs_exist_ok=True)
        for key in ("report_json", "report_md"):
            source = presented.get(key)
            if source:
                source = Path(source) if Path(source).is_absolute() else Path(fixture) / source
                if source.is_file():
                    shutil.copy2(source, out / f"presented-{Path(source).name}")


def bind_native_turns(before, fixture, session_root, sent, digests):
    """Bind each scripted message to its native user turn in the one root rollout.

    The engine wraps a message into the resume prompt, so the native user event
    carries the message text inside a longer text; the exact native text becomes
    the message's `submitted_text`, and the shared ordered-binding validator
    then certifies user turn and terminal completion."""
    roots = exact_root_rollout(before, fixture, session_root)
    if len(roots) != 1:
        raise RuntimeError(f"expected exactly one native root rollout, found {len(roots)}")
    events = [json.loads(line) for line in Path(roots[0]).read_text().splitlines() if line.strip()]
    cursor = 0
    for entry in sent:
        found = None
        for index in range(cursor, len(events)):
            event = events[index]; payload = event.get("payload", {})
            if event.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "user":
                text = "".join(part.get("text", "") for part in payload.get("content", []) if isinstance(part, dict))
                if entry["text"] in text:
                    found = (index, text)
                    break
        if found is None:
            raise RuntimeError("scripted message absent from the native root rollout")
        entry["submitted_text"] = found[1]
        cursor = found[0] + 1
    bindings = integrity_module().ordered_turn_bindings(events, sent)
    terminals = [{"at": wall_now(), "root_rollout": roots[0], "turn_id": binding["turn_id"],
                  "draft_sha256": digests[index]} for index, binding in enumerate(bindings)]
    return terminals


def drive(case, fixture, spec, *, harness="codex", route=None, max_seconds=None, native_binding=None,
          slug=None):
    """Run one case through the public engine commands and capture its evidence.

    `spec` is a validated case (see load_case). Returns the receipt; the run's
    evidence, including config-record.json, is written under RUNTIME/runs/<case>.
    """
    validate_case_spec(spec)
    max_seconds = MAX_SECONDS if max_seconds is None else max_seconds
    native_binding = (harness == "codex" and case in CASES) if native_binding is None else native_binding
    profiles, profile_configuration = configured_profiles(fixture, harness)
    route = route or resolved_route(fixture, harness)
    out = RUNTIME / "runs" / case; out.mkdir(parents=True)
    if case.startswith("stateful-"):
        write_stateful_control_result(fixture, out, case)
    baseline_status = subprocess.run(["git", "status", "--porcelain"], cwd=fixture, capture_output=True, text=True, check=True).stdout.splitlines()
    baseline_sources = source_snapshot(fixture)
    (out / "source-baseline.json").write_text(json.dumps(baseline_sources, indent=2, sort_keys=True) + "\n")
    request_text = (fixture / "README.md").read_text()
    brief_path = Path(spec["dir"]) / next(step for step in spec["steps"] if step["step"] == "start")["brief"]
    request = brief_path.read_text().strip()
    if request not in request_text:
        raise RuntimeError(f"{case}: current user request is missing before public dispatch")
    input_delivery = {"case": case, "request": request, "request_path": "README.md",
                      "readme_sha256": sha256(fixture / "README.md"), "available_before_dispatch": True,
                      "recorded_at": wall_now()}
    (out / "input-delivery.json").write_text(json.dumps(input_delivery, indent=2) + "\n")
    if case.startswith("csv"): write_csv_probe_result(fixture, out)
    if case == "booking-flawed": write_booking_setup_observation(fixture, out)
    session_root = selected_session_root(fixture) if native_binding else None
    before = inventory(session_root) if native_binding else set()
    start_wall = wall_now(); start_monotonic = monotonic_now()
    deadline = start_monotonic + max_seconds
    session = EngineSession(fixture, case)
    sent, digests, run_log = [], [], {"start": None, "messages": [], "approval": None, "cancel": None}
    outcome = "inconclusive"; failure = None; status = None; terminal_observed = []
    intermediate_draft_sha256 = None; cleanup_receipts = []; initial_terminal = None
    messages_dir = out / "messages"; messages_dir.mkdir()
    steps = spec["steps"]; message_index = 0
    message_total = sum(1 for step in steps if step["step"] == "message")
    try:
        for step in steps:
            kind = step["step"]
            if kind == "start":
                brief_copy = messages_dir / "start-brief.md"
                brief_copy.write_text(brief_path.read_text())
                begun = monotonic_now()
                payload = session.start(str(brief_copy), case, route=route)
                run_log["start"] = {"state": payload.get("state"), "seconds": monotonic_now() - begun,
                                    "session": payload.get("session"), "returned_at": wall_now(),
                                    "request_id": case}
                status = payload
                following = steps[1] if len(steps) > 1 else None
                if not (following and following["step"] == "message" and following.get("when") == "mid_turn"):
                    # A mid-turn message is sent while this first turn still runs;
                    # every other script lets the first turn settle first.
                    status = wait_status(session, settled, deadline=deadline, label="the first turn to settle")
                    first_draft = package_dir(fixture, status)
                    if first_draft is not None and first_draft.is_dir():
                        shutil.copytree(first_draft, out / "initial-draft", ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".DS_Store"))
                    initial_terminal = {"at": wall_now(), "state": status.get("state"), "session": session.session,
                                        "draft_sha256": hashlib.sha256(read_package_text(fixture, status).encode()).hexdigest()}
            elif kind == "message":
                when = step.get("when", "awaiting_answers")
                mid_turn_missed = False
                if when == "awaiting_answers":
                    status = wait_status(session, lambda s: s.get("state") == "awaiting_answers" and no_pending(s),
                                         deadline=deadline, label="awaiting_answers",
                                         fail_states=DEAD_STATES | {"ready", "approved"})
                elif when == "turn_ended":
                    status = wait_status(session, settled, deadline=deadline, label="the turn to end",
                                         fail_states=DEAD_STATES | {"approved"})
                else:
                    def mid_turn_open(s):
                        return s.get("state") == "running" and bool(s.get("questions"))
                    status = wait_status(session, lambda s: mid_turn_open(s) or settled(s), deadline=deadline,
                                         label="an open question while the turn is running",
                                         poll=MID_TURN_POLL_SECONDS)
                    mid_turn_missed = not mid_turn_open(status)
                trigger = step.get("trigger")
                if trigger:
                    visible = "\n".join([json.dumps(status.get("questions") or []), read_package_text(fixture, status)])
                    if not TRIGGERS[trigger](visible):
                        raise TriggerMismatch(f"{case}: the Draft did not raise the choice the message answers ({trigger})")
                text = (Path(spec["dir"]) / step["file"]).read_text()
                rid = f"{case}-m{message_index + 1}"
                message_copy = messages_dir / f"message-{message_index + 1}.md"
                message_copy.write_text(text)
                sent_state = status.get("state")
                # The launch running when a mid-turn message is sent is the ORIGINAL
                # turn the answer must reach; it is read from the engine's own events
                # before the message is submitted.
                running_turn = (open_turn(read_events(fixture, session.session))
                                if when == "mid_turn" and session.session else None)
                requested_at = wall_now()
                payload = session.message(str(message_copy), rid)
                sent.append({"at": wall_now(), "requested_at": requested_at, "running_turn": running_turn, "text": text, "file": step["file"], "request_id": rid,
                             "when": when, "state_before": sent_state, "state_after": payload.get("state"),
                             "mid_turn": when == "mid_turn" and not mid_turn_missed,
                             "transport": "engine-brief"})
                run_log["messages"].append(sent[-1])
                status = wait_status(session, settled, deadline=deadline, label="the turn after the message to settle")
                snapshot = package_dir(fixture, status)
                if snapshot is not None and snapshot.is_dir():
                    shutil.copytree(snapshot, out / "drafts-by-turn" / str(message_index),
                                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".DS_Store"))
                digests.append(hashlib.sha256(read_package_text(fixture, status).encode()).hexdigest())
                if spec["name"] == "csv-continuation" and message_index == 0 and message_total > 1:
                    intermediate = out / "drafts-by-turn" / "0" / "questions.md"
                    if not intermediate.is_file():
                        raise RuntimeError(f"{case}: partial clarification did not retain questions.md")
                    intermediate_draft_sha256 = hashlib.sha256(intermediate.read_bytes()).hexdigest()
                message_index += 1
            elif kind == "approve":
                status = wait_status(session, lambda s: s.get("state") == "ready" and no_pending(s), deadline=deadline,
                                     label="ready before approval",
                                     fail_states=DEAD_STATES | {"approved", "awaiting_answers"})
                presented = status.get("presented") or {}
                if not presented.get("id"):
                    raise SessionFailure(f"{case}: the session is ready without a presentation id")
                payload = session.approve(presented["id"], f"{case}-approve")
                run_log["approval"] = {"presentation": presented["id"], "state": payload.get("state"), "at": wall_now()}
                status = wait_status(session, lambda s: s.get("state") == "approved", deadline=deadline, label="approved")
            elif kind == "cancel":
                payload = session.cancel(f"{case}-cancel")
                run_log["cancel"] = {"state": payload.get("state"), "at": wall_now()}
                status = wait_status(session, lambda s: s.get("state") == "cancelled", deadline=deadline,
                                     label="cancelled", fail_states=frozenset())
        last_kind = steps[-1]["step"]
        end = spec.get("end", "settled")
        if end == "approved" and last_kind != "approve":
            raise FailFast(f"{case}: the case ends approved but no approve step ran (the session is {status.get('state')})")
        if last_kind not in ("approve", "cancel"):
            state = status.get("state")
            if end == "ready" and state != "ready":
                if state == "awaiting_answers":
                    raise FailFast(f"{case}: the session is awaiting_answers with {len(status.get('questions') or [])} open "
                                   "question(s) and no scripted message remains")
                raise FailFast(f"{case}: expected ready, the session is {state}")
            package = package_dir(fixture, status)
            draft_files = ({path.name for path in package.iterdir() if path.is_file()}
                           if package is not None and package.is_dir() else set())
            decision, reason = turn_end_decision(case, message_total, [None] * message_total, draft_files)
            if decision == "fail":
                raise FailFast(reason)
        outcome = "completed"
    except FailFast as exc:
        failure = {"type": "TurnEndFailFast", "message": str(exc)}; outcome = "inconclusive"
    except Exception as exc:
        failure = {"type": type(exc).__name__, "message": str(exc)}; outcome = "infrastructure-error"
    finally:
        # A settled payload is evidence: retain its status, Draft and reports
        # before cleanup can change the engine's final status or remove fixture.
        try:
            observed = session.last or {}
            if session.session and observed.get("state") != "running":
                snapshot = out / "before-cleanup"
                snapshot.mkdir(exist_ok=True)
                (snapshot / "status-final.json").write_text(json.dumps(observed, indent=2) + "\n")
                observed_slug = slug or observed.get("slug") or spec.get("slug")
                observed_package = package_dir(fixture, observed, observed_slug)
                if observed_package is not None and observed_package.is_dir():
                    shutil.copytree(observed_package, snapshot / "draft", dirs_exist_ok=True,
                                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".DS_Store"))
                snapshot_status = {**observed, "slug": observed_slug}
                copy_engine_evidence(fixture, session.session, snapshot_status, snapshot)
            # Only a live session needs cancellation; never cancel a settled
            # blocked/not_ready session just to make cleanup appear successful.
            if session.session and (session.last or {}).get("state") == "running":
                try:
                    session.cancel(f"{case}-cleanup-cancel")
                except EngineError:
                    pass
                settle_deadline = monotonic_now() + 60
                while monotonic_now() < settle_deadline:
                    try:
                        if session.status().get("state") != "running":
                            break
                    except EngineError:
                        break
                    time.sleep(1)
            owned = owned_process_tree(fixture)
            if owned:
                cleanup = reap_owned_cli(fixture, owned); cleanup_receipts.append(cleanup)
                if not cleanup["all_reaped"]:
                    raise RuntimeError("owned provider CLI descendants were not reaped")
        except Exception as cleanup_exc:
            cleanup_receipts.append({"cleanup_error": {"type": type(cleanup_exc).__name__, "message": str(cleanup_exc)}})
            if failure is None:
                failure = {"type": type(cleanup_exc).__name__, "message": str(cleanup_exc)}
                outcome = "infrastructure-error"
    if native_binding and outcome == "completed" and sent:
        try:
            terminal_observed = bind_native_turns(before, fixture, session_root, sent, digests)
        except Exception as exc:
            failure = {"type": type(exc).__name__, "message": f"{case}: {exc}"}; outcome = "infrastructure-error"
    if native_binding:
        deadline_settle = monotonic_now() + 10; previous = None
        while monotonic_now() < deadline_settle:
            owned_files = sorted(inventory() - before); state = [(x, Path(x).stat().st_size) for x in owned_files]
            if state and state == previous: break
            previous = state; time.sleep(1)
    (out / "messages.json").write_text(json.dumps(sent, indent=2) + "\n")
    ignored_copy = shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".DS_Store")
    correlation = {"exactly_one_root": False, "all_owned_terminal": False, "all_profiles_match": False}
    current_status = []; current_sources = {}
    capture_errors = []
    def capture(stage, action):
        try:
            return action()
        except Exception as capture_exc:
            capture_errors.append({"stage": stage, "type": type(capture_exc).__name__, "message": str(capture_exc)})
            return None
    final_status = session.last or {}
    slug = slug or final_status.get("slug") or spec.get("slug")
    package = package_dir(fixture, final_status, slug)
    if package is not None and package.exists():
        capture("draft-copy", lambda: shutil.copytree(package, out / "draft", ignore=ignored_copy))
    if native_binding:
        capture("draft-state", lambda: write_draft_state_from(package, fixture, slug, out, case))
    if (fixture / "evidence").is_dir():
        capture("fixture-evidence", lambda: shutil.copytree(fixture / "evidence", out / "evidence", ignore=ignored_copy))
    capture("fixture-sources", lambda: copy_fixture_sources(fixture, case, out))
    if native_binding:
        copied_correlation = capture("owned-sessions", lambda: copy_owned_sessions(before, fixture, out, profiles))
        if copied_correlation is not None: correlation = copied_correlation
    if session.session:
        capture("engine-evidence", lambda: copy_engine_evidence(fixture, session.session, final_status, out))
    captured_status = capture("git-status", lambda: subprocess.run(["git", "status", "--porcelain"], cwd=fixture, capture_output=True, text=True, check=True).stdout.splitlines())
    if captured_status is not None: current_status = captured_status
    captured_sources = capture("source-after", lambda: source_snapshot(fixture))
    if captured_sources is not None:
        current_sources = captured_sources
        capture("source-after-write", lambda: (out / "source-after.json").write_text(json.dumps(current_sources, indent=2, sort_keys=True) + "\n"))
    if capture_errors:
        first = capture_errors[0]
        if failure is None:
            failure = {"type": first["type"], "message": f"{case}: evidence capture failed: {first['message']}"}
            outcome = "infrastructure-error"
        correlation = {**correlation, "capture_error": first, "capture_errors": capture_errors}
    events = read_events(fixture, session.session) if session.session else []
    ended_wall = wall_now()
    (out / "status-final.json").write_text(json.dumps(final_status, indent=2) + "\n")
    (out / "engine-run.json").write_text(json.dumps({**run_log, "session": session.session, "states": session.states,
                                                     "first_questions": session.first_questions,
                                                     "commands": session.commands}, indent=2) + "\n")
    config_record = capture("config-record", lambda: write_config_record(
        out, case=case, harness=harness, route=route, profiles=profiles, session=session, events=events,
        fixture_root=fixture,
        started=start_wall, ended=ended_wall))
    elapsed = monotonic_now() - start_monotonic
    transport_exit = session.commands[-1]["exit"] if session.commands else None
    receipt = {"case": case, "fixture": str(fixture), "slug": slug, "session": session.session, "harness": harness,
               "route": route, "started": start_wall, "ended": ended_wall, "started_monotonic": start_monotonic,
               "ended_monotonic": monotonic_now(), "elapsed_seconds": elapsed,
               "transport_argv": [entry["argv"] for entry in session.commands], "resume_environment": {},
               "configured_profiles": profile_configuration, "cleanup": cleanup_receipts,
               "transport_exit": transport_exit, "initial_messages": 1, "scripted_replies": len(sent),
               "initial_terminal_event": initial_terminal, "outcome": outcome, "failure": failure,
               "terminal_events": terminal_observed,
               "terminal_turn_bindings": [event["turn_id"] for event in terminal_observed],
               "intermediate_draft_sha256": intermediate_draft_sha256, "correlation": correlation,
               "final_state": final_status.get("state"), "request_ids": list(session.request_ids),
               "git_status": {"baseline": baseline_status, "after": current_status,
                              "baseline_unchanged": current_status == baseline_status,
                              "draft_exists": bool(package is not None and package.exists())},
               "source_identity": {"baseline": baseline_sources, "after": current_sources,
                                   "unchanged": baseline_sources == current_sources}}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    public_receipt = {
        "case": case, "slug": slug, "started": start_wall, "ended": receipt["ended"],
        "elapsed_seconds": receipt["elapsed_seconds"], "configured_profiles": profile_configuration,
        "transport_exit": transport_exit, "initial_messages": receipt["initial_messages"],
        "scripted_replies": receipt["scripted_replies"], "outcome": outcome, "failure": failure,
        "initial_terminal_event": receipt["initial_terminal_event"],
        "terminal_events": [{key: event.get(key) for key in ("at", "turn_id", "draft_sha256")}
                            for event in terminal_observed],
        "terminal_turn_bindings": receipt["terminal_turn_bindings"],
        "intermediate_draft_sha256": intermediate_draft_sha256,
        "correlation": {key: correlation.get(key) for key in
                        ("exactly_one_root", "all_owned_terminal", "all_profiles_match", "roots", "owned", "requested_profiles")},
        "cleanup": {"all_reaped": all(item.get("all_reaped") is True for item in cleanup_receipts),
                    "attempts": len(cleanup_receipts)},
        "git_status": {"baseline_unchanged": receipt["git_status"]["baseline_unchanged"],
                       "draft_exists": receipt["git_status"]["draft_exists"]},
        "source_identity": {"unchanged": receipt["source_identity"]["unchanged"],
                            "baseline_sha256": sha256(out / "source-baseline.json"),
                            "after_sha256": sha256(out / "source-after.json")},
    }
    (out / "review-receipt.json").write_text(json.dumps(public_receipt, indent=2) + "\n")
    return receipt


def write_draft_state_from(package, fixture, slug, out, case):
    """write_draft_state for a package the engine reported, wherever it lives."""
    if package is None or Path(package) == draft_dir(Path(fixture), slug):
        return write_draft_state(fixture, slug, out, case)
    decoded = parse_yaml_mapping(Path(package) / "intent.yaml", case=case)
    state = project_draft_state(decoded, fixture, slug, case)
    (out / "draft-state.json").write_text(json.dumps(state, indent=2) + "\n")
    return state


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def required_artifacts():
    # This is an explicit semantic-review bundle, not a recursive runtime dump.
    # Detailed receipts, PTY/transport logs, and immutable native streams remain
    # private run data used by validate_case() and are never manifested.
    required = []
    for case in CASES:
        run = RUNTIME / "runs" / case
        public_names=("review-receipt.json","messages.json","input-delivery.json","owned-session-metadata.json","public-transcript.json","draft-state.json",
                      "csv-probe-result.json","booking-setup-observation.json","stateful-control-result.json","fixture-cleanup.json")
        for name in public_names:
            path=run/name
            if path.is_file(): required.append(path)
        for base in (run/"draft",run/"fixture-source"):
            for path in sorted(base.rglob("*")) if base.exists() else ():
                if path.is_file() and not path.is_symlink() and path.name not in {".DS_Store"} and "__pycache__" not in path.parts and path.suffix not in {".pyc",".pyo"}: required.append(path)
        if case == "csv-continuation":
            partial=run/"drafts-by-turn"/"0"
            for path in sorted(partial.rglob("*")) if partial.is_dir() else ():
                if path.is_file() and not path.is_symlink(): required.append(path)
        initial=run/"initial-draft"
        for path in sorted(initial.rglob("*")) if initial.is_dir() else ():
            if path.is_file() and not path.is_symlink(): required.append(path)
        evidence_names=("facts.json","protocol.json","prerequisite-results.json","plain.csv","bom.csv","invalid-date.csv",
                        "naive_reader.py","reader_control.py","calendar_adapter.py","capability-seed.json","CORRECTION.md",
                        "old-receipt.md","inventory.txt","fixture-contract.md","complete-input-receipt.json","current-prerequisite-receipt.json","prerequisite_control.py",
                        "stateful_guardrail.py","stateful_guardrail_control.py","stateful-guardrail-flawed.md","stateful-guardrail-complete.md","stateful-mode.txt","stateful-control-result.json")
        for name in evidence_names:
            path=run/"evidence"/name
            if path.is_file(): required.append(path)
    seed_metadata = RUNTIME / "continuation-seed-metadata.json"
    if seed_metadata.is_file():
        required.append(seed_metadata)
    seed_root = RUNTIME / "continuation-seed"
    for path in sorted(seed_root.rglob("*")) if seed_root.is_dir() else ():
        if path.is_file() and not path.is_symlink() and ".git" not in path.parts and "_build" not in path.parts and "deps" not in path.parts:
            required.append(path)
    return list(dict.fromkeys(required))

def write_manifest(failure=False):
    # In the no-cancel suite contract a failed dispatch still leaves every
    # already-produced case artifact on disk; required_artifacts() only lists
    # paths that currently exist, so the manifest frame is well-formed either
    # way. On failure we additionally manifest suite-failure.json itself and
    # validate under the failure-mode contract, which requires every listed
    # entry to exist rather than requiring full per-case coverage.
    entries = []
    for path in required_artifacts():
        if not path.is_relative_to(PROJECT):
            raise RuntimeError(f"evidence outside repository: {path}")
        entries.append({"path": str(path.relative_to(PROJECT)), "sha256": sha256(path)})
    counterexamples = RUNTIME / "semantic-counterexamples.json"
    if counterexamples.is_file():
        entries.append({"path": str(counterexamples.relative_to(PROJECT)), "sha256": sha256(counterexamples)})
    if failure:
        suite_failure = RUNTIME / "suite-failure.json"
        if suite_failure.is_file():
            entries.append({"path": str(suite_failure.relative_to(PROJECT)), "sha256": sha256(suite_failure)})
    if not entries:
        raise RuntimeError("no shaping-evaluation evidence to manifest")
    manifest = RUNTIME / "evidence-manifest.json"
    manifest.write_text(json.dumps({"schema_version": 1, "required_evidence": entries}, indent=2) + "\n")
    try:
        if failure:
            integrity_module().validate_failure_manifest(PROJECT, manifest)
        else:
            integrity_module().validate_manifest(PROJECT, manifest)
    except Exception as exc:
        raise RuntimeError(f"manifest integrity validation failed: {exc}") from exc
    locator = {"manifest_path": str(manifest.relative_to(PROJECT)), "sha256": sha256(manifest)}
    print("\nKOGEN_TARGET_EVIDENCE_MANIFEST\t" + json.dumps(locator, separators=(",", ":")), flush=True)
    return locator

def write_semantic_counterexamples():
    shutil.copy2(HERE / "semantic-counterexamples.json", RUNTIME / "semantic-counterexamples.json")

PRESENTATION_ID = re.compile(r"^p-[0-9]+-[0-9a-f]{12}$")
INPUT_TOKEN = re.compile(r"\[input (in-[A-Za-z0-9._-]+)\]")


def _normalized(text):
    return re.sub(r"\s+", " ", re.sub(r"(?m)^\s*>\s?", "", text)).strip()


def shaper_answers_section(questions_md):
    match = re.search(r"(?m)^## Shaper answers[ \t]*\n(.*?)(?=^## |\Z)", questions_md, re.S)
    return match.group(1) if match else ""


def _json_file(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _iso_seconds(value):
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _jsonl(path):
    records = []
    if Path(path).is_file():
        for line in Path(path).read_text(errors="replace").splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                records.append(item)
    return records


def first_answer_delivery(run, first, events, final_answers):
    """Where the first (mid-turn) answer went, from the engine's own retained evidence:
    events.jsonl (turn_started/turn_ended with launch ids and times), the input journal
    engine-runtime/inputs/NNNN.{md,json} and its offer log NNNN.offers.jsonl (written
    by the steer hook before it prints, and by the runner for a turn-prompt resend),
    and the final Draft's `## Shaper answers`. Returns {check name: (ok, detail)}."""
    run = Path(run)
    original = (first or {}).get("running_turn") or {}
    launch = original.get("launch_id")
    started = next((e for e in events if e.get("event") == "turn_started" and launch and e.get("launch_id") == launch), None)
    ended = next((e for e in events if e.get("event") == "turn_ended" and started and e.get("turn") == started.get("turn")), None)
    requested = (first or {}).get("requested_at")
    ended_at = _iso_seconds((ended or {}).get("at"))
    identified = bool(started and ended and isinstance(requested, (int, float)) and ended_at is not None
                      and ended_at >= requested)
    out = {"first-answer-original-turn-identified": (
        identified, f"running turn at send {original}; its events: started={bool(started)} ended={bool(ended)}; "
                    f"turn ended at {(ended or {}).get('at')} vs message requested at {requested}")}
    input_id = number = None
    text = _normalized((first or {}).get("text") or "")
    for meta_path in sorted((run / "engine-runtime" / "inputs").glob("[0-9][0-9][0-9][0-9].json")):
        meta = _json_file(meta_path) or {}
        body = meta_path.with_suffix(".md")
        if meta.get("kind") == "message" and body.is_file() and text and _normalized(body.read_text(errors="replace")) == text:
            input_id, number = meta.get("id"), meta_path.stem
            break
    offers = _jsonl(run / "engine-runtime" / "inputs" / f"{number}.offers.jsonl") if number else []
    steer = [o for o in offers if o.get("via") == "steer" and o.get("launch_id") == launch and o.get("id") == input_id]
    steer_at = [_iso_seconds(o.get("at")) for o in steer]
    started_at = _iso_seconds((started or {}).get("at"))
    inside = bool(steer) and started_at is not None and ended_at is not None and any(
        t is not None and started_at <= t <= ended_at for t in steer_at)
    out["first-answer-steered-into-original-turn"] = (
        bool(launch and input_id and identified and inside),
        f"input {input_id!r}; offers {[(o.get('via'), o.get('launch_id'), o.get('at')) for o in offers]}; "
        f"original launch {launch!r} ran {(started or {}).get('at')} .. {(ended or {}).get('at')}")
    # The runner re-sends, at turn end, every input still absent from `## Shaper answers`;
    # so an input with no other launch's offer was recorded by the original turn's end.
    others = [o for o in offers if o.get("launch_id") != launch or o.get("via") != "steer"]
    recorded = bool(input_id) and f"[input {input_id}]" in final_answers
    out["first-answer-recorded-in-original-turn"] = (
        bool(input_id and identified and steer and not others and recorded),
        f"input {input_id!r} recorded in the final Draft={recorded}; offers by any other launch or route {others}")
    return out


def smoke_assertions(run, messages):
    """The headless-flow checks over one route's retained evidence. Returns
    {"failures": [...], "checks": {...}}; an empty failure list is a pass."""
    run = Path(run)
    failures, checks = [], {}

    def check(name, ok, detail=None):
        checks[name] = {"ok": bool(ok), "detail": detail}
        if not ok:
            failures.append(f"{name}: {detail}" if detail is not None else name)

    engine = _json_file(run / "engine-run.json") or {}
    final = _json_file(run / "status-final.json") or {}
    record = _json_file(run / "config-record.json") or {}
    receipt = _json_file(run / "receipt.json") or {}
    start = engine.get("start") or {}
    check("start-returns-running", start.get("state") == "running" and (start.get("seconds") or 0) < COMMAND_SECONDS,
          f"start returned state {start.get('state')!r} after {start.get('seconds')}s")
    states = [entry.get("state") for entry in engine.get("states", [])]
    check("running-then-settled",
          "running" in states and any(s in SETTLED_STATES for s in states[states.index("running"):]),
          f"states seen: {states}")
    check("first-question-seen", bool((engine.get("first_questions") or {}).get("count")),
          "no open question was ever reported by status")
    sent = engine.get("messages", [])
    check("all-explicit-messages-sent", len(sent) == len(messages) and len(sent) >= 2,
          f"sent {len(sent)} of {len(messages)} explicit scripted messages; at least two are required")
    # Keep the historical alias, but bind it to the authored case count. A
    # later explicitly written message remains valid without weakening the
    # one-to-one producer/consumer count check.
    check("two-messages-sent", len(sent) == len(messages) and len(messages) >= 2,
          f"sent {len(sent)} of {len(messages)} authored scripted messages; at least two are required")
    if sent:
        check("first-answer-sent-mid-turn", sent[0].get("mid_turn") is True and sent[0].get("state_before") == "running",
              f"the first answer was sent in state {sent[0].get('state_before')!r}, not while the turn ran")
        later_settled = [entry for entry in sent[1:] if entry.get("state_before") in SETTLED_STATES]
        check("follow-up-message-sent-after-turn", bool(later_settled),
              f"later message states: {[entry.get('state_before') for entry in sent[1:]]}")
        second_state = sent[1].get("state_before") if len(sent) >= 2 else None
        check("second-message-sent-after-turn", second_state in SETTLED_STATES,
              f"second message state: {second_state!r}")
    check("final-state-ready", final.get("state") == "ready", f"final state {final.get('state')!r}")

    questions_md = ""
    for candidate in (run / "presented" / "questions.md", run / "draft" / "questions.md"):
        if candidate.is_file():
            questions_md = candidate.read_text(errors="replace"); break
    section = shaper_answers_section(questions_md)
    tokens = INPUT_TOKEN.findall(section)
    check("answers-recorded-verbatim-with-input-tokens",
          bool(section) and all(_normalized(text) in _normalized(section) for text in messages) and len(set(tokens)) >= len(messages),
          f"section present={bool(section)}, verbatim={[ _normalized(t) in _normalized(section) for t in messages]}, tokens={tokens}")

    events = read_events_file(run / "engine-runtime" / "events.jsonl")
    for name, (ok, detail) in first_answer_delivery(run, sent[0] if sent else None, events, section).items():
        check(name, ok, detail)
    ids = provider_session_ids(events)
    turns = turn_records(events)
    provider = final.get("provider") or {}
    check("resumed-provider-ids-match",
          len(ids) == 1 and len(turns) >= 2 and any(t.get("kind") == "resume" for t in turns)
          and provider.get("session_id") == ids[0] and record.get("provider_session_ids") == ids,
          f"provider ids {ids}, turns {[t.get('kind') for t in turns]}, status provider {provider.get('session_id')!r}")

    presented = final.get("presented") or {}
    check("status-presented-id", isinstance(presented.get("id"), str) and bool(PRESENTATION_ID.match(presented["id"])),
          f"presented.id {presented.get('id')!r}")
    revision = presented.get("revision")
    reports = []
    for path in sorted((run / "shaping-audits").glob("*/report.json")) + sorted((run / "shaping-audits").glob("*/checkpoint.json")):
        report = _json_file(path)
        if isinstance(report, dict):
            reports.append({"path": str(path.relative_to(run)), **{k: report.get(k) for k in ("revision", "scope", "readiness")},
                            "findings": report.get("findings") or []})
    earlier = [r for r in reports if r["revision"] != revision and r["findings"]]
    check("earlier-revision-report-has-findings", bool(revision) and bool(earlier),
          f"reports: {[(r['revision'], r['scope'], len(r['findings'])) for r in reports]}")
    ok, detail = integrity_module().audit_feedback_delivery(run, revision, events)
    check("audit-feedback-delivered-before-repair", ok, detail)
    presented_report = _json_file(run / "presented-report.json") or {}
    later = [r for r in reports if r["revision"] == revision and r["scope"] == "full"]
    check("later-full-report-ready-for-final-revision",
          bool(later) and later[0]["readiness"] == "ready" and presented_report.get("revision") == revision
          and presented_report.get("scope") == "full" and presented_report.get("readiness") == "ready",
          f"final revision {revision!r}; presented report {[presented_report.get(k) for k in ('revision', 'scope', 'readiness')]}")
    stale = [f for f in (presented_report.get("findings") or [])
             if str(f.get("rule") or f.get("id") or "").startswith("answer-not-applied")]
    check("no-answer-not-applied", bool(presented_report) and not stale, f"findings: {[f.get('id') for f in stale]}")
    check("route-bound", (receipt.get("elapsed_seconds") or 0) <= ROUTE_READY_SECONDS,
          f"elapsed {receipt.get('elapsed_seconds')}s exceeds {ROUTE_READY_SECONDS}s")
    check("run-completed", receipt.get("outcome") == "completed" and receipt.get("failure") is None,
          f"outcome {receipt.get('outcome')!r} failure {receipt.get('failure')!r}")
    result = {"case": run.name, "harness": record.get("harness"), "route": record.get("route"),
              "failures": failures, "checks": checks, "provider_session_ids": ids,
              "presentation": presented.get("id"), "elapsed_seconds": receipt.get("elapsed_seconds")}
    (run / "smoke-result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def read_events_file(path):
    events = []
    if Path(path).is_file():
        for line in Path(path).read_text(errors="replace").splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                events.append(item)
    return events


def write_smoke_manifest():
    """The smoke's evidence bundle: the per-run engine evidence a Reviewer reads,
    with hashes. No native rollouts or provider streams are included."""
    root = PROJECT.resolve()
    run = RUNTIME / "runs" / "smoke"
    names = ("config-record.json", "engine-run.json", "status-final.json", "messages.json", "authored-case.json", "smoke-result.json",
             "review-receipt.json", "input-delivery.json", "presented-report.json", "presented-report.md",
             "feedback-delivery/receipts.jsonl")
    paths = [run / name for name in names if (run / name).is_file()]
    for base in ("draft", "presented", "shaping-audits", "engine-runtime"):
        for path in sorted((run / base).rglob("*")) if (run / base).exists() else ():
            if path.is_file() and not path.is_symlink() and path.name != ".DS_Store" and "__pycache__" not in path.parts:
                paths.append(path)
    entries = []
    for path in dict.fromkeys(paths):
        path = path.resolve()
        if not path.is_relative_to(root):
            raise RuntimeError(f"evidence outside repository: {path} (root {root})")
        entries.append({"path": str(path.relative_to(root)), "sha256": sha256(path)})
    if not entries:
        raise RuntimeError("no smoke evidence to manifest")
    manifest = RUNTIME.resolve() / "evidence-manifest.json"
    manifest.write_text(json.dumps({"schema_version": 1, "required_evidence": entries}, indent=2) + "\n")
    try:
        integrity_module().validate_smoke_manifest(root, manifest)
    except Exception as exc:
        manifest.unlink()
        raise RuntimeError(f"smoke manifest integrity validation failed: {exc}") from exc
    locator = {"manifest_path": str(manifest.relative_to(root)), "sha256": sha256(manifest)}
    print("\nKOGEN_TARGET_EVIDENCE_MANIFEST\t" + json.dumps(locator, separators=(",", ":")), flush=True)
    return locator


def run_smoke(harness="codex"):
    """The headless-flow case on one route: one real engine session started with
    --brief, an answer sent while its first turn runs, a later message after a
    turn ends, an audit finding repaired to a ready presentation. Bounded at
    SMOKE_MAX_SECONDS; prints one manifest frame when every check passes."""
    stage = "fixture-location"
    fixture = fixture_location("smoke")
    fixture_owned = False
    try:
        append_rehearsal_trace("driver.run_smoke")
        fixture.parent.mkdir(parents=True, exist_ok=True)
        if fixture.exists():
            raise RuntimeError(f"fixture exists: {fixture}")
        # Claim the exact smoke path before any copy/setup work. This lets the
        # exceptional-exit handler distinguish our partial fixture from a
        # path that belongs to another process.
        fixture.mkdir()
        fixture_owned = True
        stage = "fixture-setup"
        setup_fixture("smoke", smoke_files(), owned_fixture=fixture)
        stage = "case-load"
        spec = load_case(SMOKE_CASE)
        stage = "drive"
        receipt = drive("smoke", fixture, spec, harness=harness, max_seconds=SMOKE_MAX_SECONDS, native_binding=False)
        write_authored_smoke_case(spec)
        require_cleanup(fixture, "smoke", receipt, owned_fixture=True)
        print(json.dumps(receipt, indent=2))
        stage = "smoke-assertions"
        result = smoke_assertions(RUNTIME / "runs" / "smoke", case_messages(spec))
        print(json.dumps(result, indent=2))
        try:
            require_smoke_effort(receipt)
        except RuntimeError as exc:
            print(str(exc))
            return 1
        if receipt["outcome"] != "completed" or result["failures"]:
            return 1
        try:
            write_smoke_manifest()
        except RuntimeError as exc:
            print(str(exc))
            return 1
        return 0
    except BaseException as exc:
        try:
            failure = retain_smoke_driver_failure(stage, exc)
        except Exception as report_exc:
            failure = None
            print(f"could not retain smoke failure report after {type(exc).__name__}: {report_exc}")
        if fixture_owned and failure is not None:
            try:
                cleanup = cleanup_fixture(fixture, "smoke", failure=failure, owned_fixture=True,
                                          allow_partial_failure=stage in ("fixture-setup", "case-load", "drive"))
                if not cleanup["removed"]:
                    print(f"smoke fixture retained for diagnostics: {cleanup['reason']} ({fixture})")
            except Exception as cleanup_exc:
                print(f"smoke fixture cleanup failed after {type(exc).__name__}: {cleanup_exc}; retained at {fixture}")
        raise


def validate_captured_provenance(case, run):
    source = run / "draft" / "intent.yaml"
    original = parse_yaml_mapping(source, case=case)
    try:
        state = json.loads((run / "draft-state.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"{case}: malformed captured draft state: {exc}") from exc
    baseline = original.get("shaped_against") if isinstance(original.get("shaped_against"), dict) else {}
    visits = original.get("shaping_continuations")
    latest = visits[-1] if isinstance(visits, list) and visits else original.get("shaping", {})
    expected = {
        "intent_id": original.get("id"),
        "baseline": {"branch": baseline.get("branch"), "head": baseline.get("head")},
        "visit_id": latest.get("started") if isinstance(latest, dict) else None,
        "unapproved": True,
    }
    if state != expected:
        raise RuntimeError(f"{case}: captured provenance differs from original Draft; expected {expected!r}, got {state!r}")


def integrity_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("kogen_shaping_integrity", HERE / "integrity.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_cross_case_continuation():
    """The continuation case is one engine session with three scripted inputs. Its
    final Draft must keep the identity of the session (rebound into the frozen seed
    record by rebind_continuation_seed) and the partial snapshot's identity and slug."""
    continuation = RUNTIME / "runs" / "csv-continuation"
    if not continuation.is_dir():
        return
    seed = parse_yaml_mapping(RUNTIME / "continuation-seed" / "intent.yaml", case="csv-continuation seed")
    final = parse_yaml_mapping(continuation / "draft" / "intent.yaml", case="csv-continuation")
    partial = parse_yaml_mapping(continuation / "drafts-by-turn" / "0" / "intent.yaml", case="csv-continuation partial")
    for stage, document in (("partial", partial), ("final", final)):
        if document.get("id") != seed.get("id"):
            raise RuntimeError(f"csv-continuation: {stage} lost the session identity")
    if partial.get("slug") != final.get("slug"):
        raise RuntimeError("csv-continuation: partial and final changed slug")


def rebind_continuation_seed(session_id):
    """The seed is the frozen, test-authored unfinished Draft the continuation is
    measured against. The engine mints the Intent ID of the one continuation
    session, so the seed record is rebound to that ID (bytes, hash inventory and
    metadata all rewritten together) instead of pretending to a foreign identity."""
    seed = RUNTIME / "continuation-seed"
    intent = json.loads((seed / "intent.yaml").read_text())
    intent["id"] = session_id
    (seed / "intent.yaml").write_text(json.dumps(intent, indent=2) + "\n")
    frozen = seed / "frozen-hashes.json"
    hashes = {str(path.relative_to(seed)): sha256(path) for path in sorted(seed.rglob("*"))
              if path.is_file() and path != frozen}
    frozen.write_text(json.dumps(hashes, indent=2, sort_keys=True) + "\n")
    metadata = RUNTIME / "continuation-seed-metadata.json"
    record = json.loads(metadata.read_text())
    record["rebound_to_engine_session"] = session_id
    metadata.write_text(json.dumps(record, indent=2) + "\n")


def required_case_capture(case):
    run=RUNTIME/"runs"/case
    required=("receipt.json","messages.json","draft-state.json","source-baseline.json","source-after.json","owned-session-metadata.json")
    missing=[name for name in required if not (run/name).is_file()]
    required_draft=("intent.yaml","scenarios.yaml","questions.md")
    missing.extend(f"draft/{name}" for name in required_draft if not (run/"draft"/name).is_file())
    if not (run/"evidence").is_dir() or not any((run/"evidence").rglob("*")):
        missing.append("captured evidence")
    if missing:
        raise RuntimeError(f"{case}: required evaluation evidence missing: {', '.join(missing)}")
    try:
        receipt=json.loads((run/"receipt.json").read_text())
    except (OSError,json.JSONDecodeError) as exc:
        raise RuntimeError(f"{case}: malformed receipt evidence: {exc}") from exc
    if receipt.get("outcome") != "completed" or receipt.get("failure") is not None:
        raise RuntimeError(f"{case}: receipt is not a completed captured case")
    validate_captured_provenance(case, run)
    try:
        integrity_module().validate_case(RUNTIME, case)
        if case == "csv-continuation":
            validate_cross_case_continuation()
    except Exception as exc:
        raise RuntimeError(f"{case}: captured evidence integrity failed: {exc}") from exc


def preflight_yaml_parser():
    parsed = parse_yaml_document(b"id: parser-preflight\n", case="suite preflight",
                                 source="<suite parser preflight>")
    if parsed != {"id": "parser-preflight"}:
        raise DraftParseError("parser preflight mismatch", "suite preflight", "<suite parser preflight>",
                              f"expected exact parser control map, got {parsed!r}")

def setup_continuation_seed():
    """Freeze a compact test-authored Draft against its own committed fixture."""
    append_rehearsal_trace("driver.setup_continuation_seed")
    fixture = setup_fixture("csv-continuation", csv_files(continuation=True))
    profiles, _configuration = configured_profiles(fixture)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=fixture, capture_output=True, text=True, check=True).stdout.strip()
    slug = "eval-csv-seed"
    draft = draft_dir(fixture, slug); draft.mkdir(parents=True)
    intent = {"id":"01990000-0000-7000-8000-00000000c501", "slug":slug, "title":"CSV normalization", "status":"draft",
              "shaped_against":{"branch":"main", "head":head},
              "shaping":{"harness":"codex", "model":profiles["root"][0], "effort":profiles["root"][1], "started":"2026-09-01T00:00:00Z"},
              "shaping_continuations":[], "may_change_guarded_paths":["app/**", "test/**", "Makefile"]}
    (draft / "intent.yaml").write_text(json.dumps(intent, indent=2) + "\n")
    (draft / "INTENT.md").write_text("# CSV normalization\nTest-authored unfinished seed. Read decisions.md, questions.md and evidence/facts.json. Format and input ownership are settled; invalid-row handling and existing-output replacement remain consequential unanswered choices. No approval has been given.\n")
    (draft / "questions.md").write_text("How should invalid rows be handled? What should happen when the output already exists, including failure recovery and temporary-file cleanup?\n")
    (draft / "decisions.md").write_text("Accepted seed facts: UTF-8 with optional BOM; preserve input bytes, row order and duplicates. Preserve exact format and ownership facts in evidence/facts.json. Reader evidence proves parsing only, not normalized export.\n")
    (draft / "scenarios.yaml").write_text("- id: normalize\n  given: a valid CSV with the settled format and source ownership\n  when: normalize INPUT OUTPUT runs\n  then: preserve source bytes and emit normalized CSV in row order; invalid-row and replacement policies remain unresolved in questions.md\n  wrong_result: silently choose an unanswered policy or mutate the input\n  evidence: source-bound reader prerequisite receipt and future actual CLI checks\n  verified_by: [check]\n")
    shutil.copytree(fixture / "evidence", draft / "evidence")
    seed = RUNTIME / "continuation-seed"
    shutil.copytree(draft, seed)
    expanded = {str(path.relative_to(seed)): sha256(path) for path in sorted(seed.rglob("*")) if path.is_file()}
    (seed / "frozen-hashes.json").write_text(json.dumps(expanded, indent=2, sort_keys=True) + "\n")
    (RUNTIME / "continuation-seed-metadata.json").write_text(json.dumps({"kind":"test-authored frozen unfinished Draft seed; not a native visit", "baseline_head":head, "profiles":profiles, "fixture":"csv-continuation", "slug":slug}, indent=2) + "\n")
    validate_generated_fixture(fixture, "csv-continuation-draft", csv_files(continuation=True),
                               draft={"slug": slug, "frozen": str(seed)})
    return seed

def run_suite():
    runs=RUNTIME/"runs"
    if (RUNTIME/"semantic-counterexamples.json").exists() or (runs.exists() and any(runs.iterdir())):
        raise RuntimeError("evaluation runtime already contains evidence; refusing overwrite")
    with open(RUNTIME/"suite-started.json","x") as marker:
        json.dump({"started":wall_now(),"started_monotonic":monotonic_now()},marker)
    write_semantic_counterexamples()
    # This uses the same isolated child environment and parser subprocess as
    # actual Draft capture, before any public Shaping transport is started.
    try:
        preflight_yaml_parser()
    except Exception as exc:
        failure={"case":"suite preflight","type":type(exc).__name__,"message":str(exc)}
        (RUNTIME/"suite-failure.json").write_text(json.dumps(failure,indent=2)+"\n")
        return 1
    try:
        setup_continuation_seed()
    except Exception as exc:
        (RUNTIME / "suite-failure.json").write_text(json.dumps({"case":"continuation seed","type":type(exc).__name__,"message":str(exc)},indent=2)+"\n")
        return 1
    # Dispatch all independent roots first. Stream each child to its retained
    # log so a verbose native transport cannot deadlock a PIPE.
    cases=CASES
    env={**os.environ, "KOGEN_SHAPING_EVALUATION_SUITE_BARRIER":"1"}
    children={}; logs={}; pending=set(cases); failures={}
    for case in cases:
        log=(RUNTIME/f"{case}-output.log").open("w")
        logs[case]=log
        children[case]=subprocess.Popen(["python3", "-B", str(Path(__file__).resolve()), case], env=env, stdout=log, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    # Every dispatched case runs to completion within the same deadline: a
    # failing case no longer cancels its still-running siblings, so every
    # case keeps a complete, inspectable evidence trail.
    deadline = monotonic_now() + SUITE_SECONDS
    while pending and monotonic_now() < deadline:
        for case in cases:
            if case not in pending: continue
            child=children[case]
            if child.poll() is None: continue
            pending.discard(case)
            if child.returncode:
                failures[case]=f"child exited {child.returncode}; see {case}-output.log"
                continue
            try:
                required_case_capture(case)
            except Exception as exc:
                failures[case]=f"{type(exc).__name__}: {exc}"
        if pending: time.sleep(.05)
    cleanup_errors=[]
    for case in sorted(pending):
        failures[case]="parallel cases exceeded the existing case deadline"
        try:
            cancel_case_process(case, children[case])
        except Exception as cleanup_exc:
            cleanup_errors.append({"case":case,"type":type(cleanup_exc).__name__,"message":str(cleanup_exc)})
    for log in logs.values(): log.close()
    if failures:
        for case in cases:
            if case in failures:
                print(f"FAILED: {case}: {failures[case]}", flush=True)
        failure_record={"failed_cases":failures,"cleanup_errors":cleanup_errors}
        (RUNTIME/"suite-failure.json").write_text(json.dumps(failure_record,indent=2)+"\n")
        write_manifest(failure=True)
        return 1
    try:
        write_manifest()
    except Exception as exc:
        failure={"case":"manifest","type":type(exc).__name__,"message":str(exc)}
        (RUNTIME/"suite-failure.json").write_text(json.dumps(failure,indent=2)+"\n")
        return 1
    return 0

def cancel_case_process(case, child):
    """Cancel only this freshly spawned process group and cwd-owned CLIs."""
    fixture = RUNTIME / case
    owned = owned_process_tree(fixture) if fixture.exists() else []
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=5)
    result = reap_owned_cli(fixture, owned)
    if not result["all_reaped"]:
        raise RuntimeError(f"{case}: owned descendants remain after cancellation: {result['remaining_pids']}")
    return result

def suite_barrier(case):
    if os.environ.get("KOGEN_SHAPING_EVALUATION_SUITE_BARRIER") != "1":
        return
    barrier=RUNTIME/"barrier"; barrier.mkdir(exist_ok=True)
    (barrier/f"{case}.ready").write_text(str(wall_now()))
    deadline=monotonic_now()+60
    while monotonic_now()<deadline:
        if len(list(barrier.glob("*.ready"))) == len(CASES): return
        time.sleep(.05)
    raise TimeoutError(f"{case}: concurrent suite barrier timed out")

def case_succeeded(receipt):
    """Judge the captured case, not the status of its deliberate UI shutdown."""
    return (receipt["scripted_replies"] <= 6 and
            receipt["git_status"]["baseline_unchanged"] and
            receipt["source_identity"]["unchanged"] and
            receipt["git_status"]["draft_exists"] and
            receipt["outcome"] == "completed" and
            receipt["correlation"]["exactly_one_root"] and
            receipt["correlation"]["all_owned_terminal"] and
            receipt["correlation"]["all_profiles_match"] and
            all(item.get("all_reaped") is True for item in receipt["cleanup"]))

def prepare_login_scope_ok(force=None):
    """Resolve the Codex login scope for --prepare, with no provider call of
    its own. `force` ("pass"/"fail") substitutes a controlled input so `check`
    can rehearse both outcomes without a real login."""
    append_rehearsal_trace("driver.prepare_login_scope_ok")
    if force == "pass":
        return True, None
    if force == "fail":
        return False, "no Codex login scope is available (forced failing scope)"
    code = CODEX_ROUTE_ELIXIR + '''
    {:ok, runtime} = Kogen.Codex.installed()
    case Kogen.Codex.effective_scope(File.cwd!()) do
      {:ok, _scope} -> IO.write("ok")
      {:error, reason} -> IO.write(:stderr, inspect(reason)); System.halt(1)
    end
    '''
    result = subprocess.run(["mix", "run", "--no-compile", "--no-start", "-e", code], cwd=PROJECT,
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        return False, f"no Codex login scope is available: {bounded_output(result.stderr)}"
    return True, None


def prepare_toolchain_ok(force=None):
    """Resolve the installed Codex hook toolchain for --prepare, with no
    provider call of its own. `force` ("pass"/"fail") substitutes a
    controlled input so `check` can rehearse both outcomes offline."""
    append_rehearsal_trace("driver.prepare_toolchain_ok")
    if force == "pass":
        return True, None
    if force == "fail":
        return False, "installed Codex toolchain is below the required version (forced failing toolchain)"
    code = '{:ok, _runtime} = Kogen.Codex.installed(); IO.write("ok")'
    result = subprocess.run(["mix", "run", "--no-compile", "--no-start", "-e", code], cwd=PROJECT,
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        return False, f"installed Codex toolchain is below the required version: {bounded_output(result.stderr)}"
    return True, None


def run_prepare(mode):
    """`--prepare suite|smoke`: runs the driver's own setup functions (login
    scope, hook toolchain, fixture copy, warm seed / isolated compile) with no
    provider call, then cleans up. Exit 0 on success. On a Candidate failure,
    exit nonzero with no special frame. On an environment failure (logged-out
    or missing scope, or a toolchain below the required version), print one
    line `KOGEN_PREPARE_RESULT\\t{"class":"environment","reason":"..."}` and
    exit nonzero."""
    ok, reason = prepare_login_scope_ok(os.environ.get("KOGEN_PREPARE_FORCE_SCOPE"))
    if not ok:
        print("KOGEN_PREPARE_RESULT\t" + json.dumps({"class": "environment", "reason": reason}, separators=(",", ":")))
        return 1
    ok, reason = prepare_toolchain_ok(os.environ.get("KOGEN_PREPARE_FORCE_TOOLCHAIN"))
    if not ok:
        print("KOGEN_PREPARE_RESULT\t" + json.dumps({"class": "environment", "reason": reason}, separators=(",", ":")))
        return 1
    fixture = None
    try:
        if mode == "suite":
            # Every other suite case's generated inputs, exactly as its run
            # will generate them (`setup_fixture` without git/compile).
            for case, files in (("csv-flawed", csv_files()), ("csv-complete", csv_files(True)),
                                ("booking-flawed", booking_files()), ("booking-complete", booking_files(True)),
                                ("stateful-flawed", stateful_files(False)), ("stateful-complete", stateful_files(True))):
                inputs = setup_fixture(case, files, name=f"validate-{case}", bootstrap=False)
                shutil.rmtree(inputs, ignore_errors=True)
            setup_continuation_seed()
            fixture = RUNTIME / "csv-continuation"
        elif mode == "smoke":
            fixture = setup_fixture("smoke", smoke_files())
            pinned_smoke_config(smoke_files()[".kogen/config.yaml"], "claude")
        else:
            raise RuntimeError(f"unknown --prepare mode: {mode}")
    except Exception as exc:
        print(f"prepare failed: {exc}", file=sys.stderr)
        # A standalone --prepare may own and remove RUNTIME in main()'s
        # finally block. Surface complete fixture compiler logs before that
        # cleanup so setup failures retain their original diagnostics.
        for diagnostic in sorted(RUNTIME.glob("*-precompile.log")):
            try:
                print(f"--- {diagnostic.name} ---\n{diagnostic.read_text(errors='replace')}",
                      file=sys.stderr)
            except OSError as read_error:
                print(f"could not read {diagnostic}: {read_error}", file=sys.stderr)
        return 1
    finally:
        if fixture is not None and fixture.exists():
            shutil.rmtree(fixture, ignore_errors=True)
        if mode == "suite":
            for extra in (RUNTIME / "continuation-seed", ):
                if extra.exists(): shutil.rmtree(extra, ignore_errors=True)
            metadata = RUNTIME / "continuation-seed-metadata.json"
            if metadata.exists(): metadata.unlink()
    return 0


def case_fixture(case):
    """The fixture a quality case runs in: generated fresh, except the
    continuation case, which uses the private fixture the suite froze."""
    if case == "csv-flawed": return setup_fixture(case, csv_files())
    if case == "csv-complete": return setup_fixture(case, csv_files(True))
    if case == "booking-flawed": return setup_fixture(case, booking_files())
    if case == "booking-complete": return setup_fixture(case, booking_files(True))
    if case == "stateful-flawed": return setup_fixture(case, stateful_files(False))
    if case == "stateful-complete": return setup_fixture(case, stateful_files(True))
    seed = RUNTIME / "continuation-seed"
    fixture = RUNTIME / "csv-continuation"
    if not seed.is_dir() or not draft_dir(fixture, "eval-csv-seed").is_dir():
        raise RuntimeError("csv-continuation seed or private fixture is missing")
    return fixture


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("case", nargs="?", choices=[*CASES, "suite"])
    ap.add_argument("--prepare", choices=["suite", "smoke"])
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--harness", choices=["codex", "claude"], default="codex")
    args=ap.parse_args()
    if args.prepare:
        try:
            return run_prepare(args.prepare)
        finally:
            if OWNED_PREPARE_RUNTIME is not None:
                shutil.rmtree(OWNED_PREPARE_RUNTIME, ignore_errors=True)
    if args.smoke:
        return run_smoke(args.harness)
    if args.case is None:
        ap.error("case is required unless --prepare is given")
    if args.case == "suite":
        return run_suite()
    suite_barrier(args.case)
    spec = load_case(args.case)
    f = case_fixture(args.case)
    r = drive(args.case, f, spec)
    if args.case == "csv-continuation" and r.get("session"):
        rebind_continuation_seed(r["session"])
    require_cleanup(f, args.case, r)
    # The engine runner is detached and the driver cancels a still-running
    # session in drive()'s cleanup, so no interactive root is left to stop.
    # Early or unexpected failures are classified inside drive() and cannot
    # reach outcome=completed.
    print(json.dumps(r,indent=2)); return 0 if case_succeeded(r) else 1
if __name__=="__main__": raise SystemExit(main())
