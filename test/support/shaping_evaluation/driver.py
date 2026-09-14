#!/usr/bin/env python3
"""Evidence-local public Shape driver; run only after the coordinated START."""
import argparse, hashlib, json, os, pty, re, select, shutil, signal, subprocess, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]
RUNTIME = Path(os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"]).resolve()
def managed_root():
    return Path(os.environ.get("KOGEN_CODEX_ROOT", Path.home() / "Library/Application Support/Kogen/codex"))


def managed_runtime_context():
    root = managed_root()
    selected = json.loads((root / "default.json").read_text())["version"]
    matches = sorted((root / "runtimes").glob(selected + "-*/vendor/*/bin/codex"))
    if len(matches) != 1:
        raise RuntimeError("expected exactly one selected managed native runtime")
    return matches[0], root / "accounts/shared"


def managed_launch_context(fixture, output):
    code = '''
    {:ok, config} = Kogen.Intent.read_config()
    {:ok, runtime} = Kogen.Codex.installed()
    {:ok, scope} = Kogen.Codex.effective_scope(File.cwd!())
    operation = Kogen.Codex.State.operation!(Kogen.Codex.root())
    context = Kogen.Codex.Environment.prepare(runtime, scope, config, File.cwd!(), operation)
    IO.write(Jason.encode!(context))
    '''
    result = subprocess.run(
        ["mix", "run", "--no-compile", "--no-start", "-e", code], cwd=fixture,
        capture_output=True, text=True, timeout=30,
        env={**os.environ, "MIX_BUILD_PATH": str(fixture / "_build")},
    )
    if result.returncode:
        raise RuntimeError("could not prepare managed exact-resume context: " + result.stderr.strip())
    output.write_text(result.stdout)
    return output


DEFAULT_SESSION_ROOT = managed_root() / "accounts/shared/sessions"
SESSION_ROOT = DEFAULT_SESSION_ROOT
FIXTURES = HERE / "fixtures"
COMPACT_FIXTURES = HERE / "compact-fixtures-v2"
CASES = ("csv-flawed", "csv-complete", "booking-flawed", "booking-complete", "csv-continuation",
         "stateful-flawed", "stateful-complete")
MAX_SECONDS = 600
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
            details.append("stdout=" + bounded_output(stdout))
        if stderr:
            details.append("stderr=" + bounded_output(stderr))
        super().__init__("; ".join(details))
        self.kind = kind
        self.case = case
        self.source = str(source)
        self.command = command

class TriggerMismatch(RuntimeError):
    pass


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
BOOKING_ANSWER = 'Limit this feature to an already connected organizer with availability.read. Use the maintained synthetic capability seed to recreate a private connection per run, refuse collisions and remove only run-owned data afterward. Preserve the seed and its supplied lifecycle; these checks establish synthetic availability only, not real OAuth. This is clarification, not approval.'

CURRENT_REQUESTS = {
    "csv-flawed": CSV_FLAWED,
    "csv-complete": CSV_COMPLETE,
    "booking-flawed": BOOKING_FLAWED,
    "booking-complete": BOOKING_COMPLETE,
    "csv-continuation": "Continue the saved eval-csv-seed Draft. Resolve the outstanding invalid-row policy first, preserve the separate output-replacement question until it is explicitly answered, and save each reviewable state without approval.",
    "stateful-flawed": "Shape the stateful verification guardrail described in evidence/stateful-guardrail-flawed.md with exact slug eval-stateful-flawed. Save the Draft without approval.",
    "stateful-complete": "Shape the stateful verification guardrail described in evidence/stateful-guardrail-complete.md with exact slug eval-stateful-complete. Save the Draft without approval.",
}

def canonical_case(label):
    for case in CURRENT_REQUESTS:
        if label == case or label.startswith(case + "-"):
            return case
    return "csv-complete" if label.startswith("csv") else "booking-complete"

def current_request(label):
    return CURRENT_REQUESTS[canonical_case(label)]

# The public evaluation transport only observes completed native turns. Keep
# product prompts unchanged while making its interaction boundary explicit.
# This is deliberately test-only: production Shaping remains interactive.
TRANSPORT_COMPLETION_SUFFIX = """

Reply channel: this conversation accepts ordinary completed text turns. Do not
use question widgets or asynchronous question tools. If you need a Shaper
decision, first save the current reviewable Draft and questions.md, then state
the question in your final text and end the turn.
"""

def transport_message(text):
    return text + TRANSPORT_COMPLETION_SUFFIX

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

def configured_profiles(fixture):
    code='case Kogen.Intent.read_config(".kogen/config.yaml") do {:ok, value} -> IO.write(Jason.encode!(value)); {:error, reason} -> IO.write(:stderr, reason); System.halt(1) end'
    result=subprocess.run(["mix","run","--no-compile","--no-start","-e",code],cwd=fixture,capture_output=True,text=True,timeout=30,
                          env={**os.environ,"MIX_BUILD_PATH":str(fixture/"_build")})
    if result.returncode: raise RuntimeError(f"could not normalize tracked config: {result.stderr.strip()}")
    config=json.loads(result.stdout)
    helpers=config["helpers"]
    return {"root":(config["shaping"]["model"],config["shaping"]["effort"]),
            "scout":(helpers["scout"]["model"],helpers["scout"]["effort"]),
            "worker":(helpers["worker"]["model"],helpers["worker"]["effort"]),
            "expert":(helpers["expert"]["model"],helpers["expert"]["effort"])}, {"bytes_sha256":hashlib.sha256((fixture/".kogen/config.yaml").read_bytes()).hexdigest(),"normalized":config}


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


def setup_fixture(label, extra_files):
    fixture = RUNTIME / label
    if fixture.exists(): raise RuntimeError(f"fixture exists: {fixture}")
    fixture.mkdir(parents=True)
    subprocess.run(["rsync", "-a", "--exclude=_build", "--exclude=deps", "--exclude=.git",
                    "--exclude=.kogen/runtime", "--exclude=.kogen/intents", "--exclude=test/support/shaping_evaluation", str(PROJECT)+"/", str(fixture)+"/"], check=True)
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
    (fixture / "Makefile").write_text(f"check:\n\tpython3 -B evidence/prerequisite_control.py {label}\nlive:\n\tpython3 -B evidence/prerequisite_control.py {label}\n")
    write_fixture_readme(fixture, label)
    verify_fixture_readme_links(fixture)
    write_complete_input_receipt(fixture, label)
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
    return fixture


def write_fixture_readme(fixture, label):
    domain = ("CSV normalization" if label.startswith("csv") else
              "calendar availability" if label.startswith("booking") else "stateful verification guardrail")
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
    return ".tmp/calendar-run-17/connection.json" in text and any(
        word in text.lower() for word in ("missing", "absent", "unavailable", "deleted"))

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
    roots=[row for row in rows if "codex" in row["command"].lower() and process_cwd(row["pid"])==str(fixture)]
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


def parse_yaml_document(contents, *, case, source):
    """Parse original Draft bytes through the current compiled YAML dependency."""
    paths = parser_code_paths(case, source)
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
    kind="csv" if case.startswith("csv") else "booking" if case.startswith("booking") else "stateful"
    for relative in (Path("app")/kind,Path("test")/kind):
        source=fixture/relative
        if source.is_dir(): shutil.copytree(source,target/relative,ignore=shutil.ignore_patterns("__pycache__","*.pyc","*.pyo",".DS_Store"))

def cleanup_fixture(fixture,case):
    run=RUNTIME/"runs"/case
    run.mkdir(parents=True, exist_ok=True)
    required=[run/"receipt.json",run/"source-baseline.json",run/"source-after.json",run/"fixture-source/README.md"]
    receipt={"fixture":str(fixture),"removed":False,"reason":None}
    if all(path.exists() for path in required):
        try:
            shutil.rmtree(fixture)
            receipt["removed"]=True
        except OSError as exc:
            receipt["reason"]=f"fixture cleanup failed: {exc}"
    else:
        receipt["reason"]="required diagnostic capture incomplete; retained run-owned fixture"
    (run/"fixture-cleanup.json").write_text(json.dumps(receipt,indent=2)+"\n")
    return receipt

def require_cleanup(fixture,case,receipt):
    cleanup=cleanup_fixture(fixture,case)
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

def drive(case, fixture, slug, messages, triggers, continuation=False):
    profiles, profile_configuration = configured_profiles(fixture)
    out=RUNTIME/"runs"/case; out.mkdir(parents=True)
    if case.startswith("stateful-"):
        write_stateful_control_result(fixture, out, case)
    mailbox=out/"transport-mailbox"; mailbox.mkdir()
    baseline_status=subprocess.run(["git","status","--porcelain"],cwd=fixture,capture_output=True,text=True,check=True).stdout.splitlines()
    baseline_sources=source_snapshot(fixture)
    (out/"source-baseline.json").write_text(json.dumps(baseline_sources,indent=2,sort_keys=True)+"\n")
    request_text=(fixture/"README.md").read_text()
    request=current_request(case)
    if request not in request_text:
        raise RuntimeError(f"{case}: current user request is missing before public dispatch")
    input_delivery={"case":case,"request":request,"request_path":"README.md",
                    "readme_sha256":sha256(fixture/"README.md"),"available_before_dispatch":True,
                    "recorded_at":wall_now()}
    (out/"input-delivery.json").write_text(json.dumps(input_delivery,indent=2)+"\n")
    if case.startswith("csv"): write_csv_probe_result(fixture,out)
    if case=="booking-flawed": write_booking_setup_observation(fixture,out)
    session_root=selected_session_root(fixture)
    before=inventory(session_root); start_wall=wall_now(); start_monotonic=monotonic_now(); sent=[]; terminal_observed=[]; outcome="inconclusive"; failure=None
    transport_log=(out/"transport.log").open("w")
    cmd=["expect",str(HERE/"shape_transport.exp"),str(fixture),str(out/"pty.log"),str(mailbox),slug if continuation else ""]
    transport_argv=[cmd]; cleanup_receipts=[]
    launch_context_path = out / "managed-launch-context.json"
    proc=subprocess.Popen(cmd,cwd=fixture,stdout=transport_log,stderr=subprocess.STDOUT,text=True,env={**os.environ,"MIX_BUILD_PATH":str(fixture/"_build"),"KOGEN_CODEX_CONTEXT_RECEIPT":str(launch_context_path)})
    active_stop=mailbox/"stop"; active_kind="public-shape"
    def send(text):
        index=len(sent); temporary=mailbox/f"message-{index}.tmp"; final=mailbox/f"message-{index}.txt"
        temporary.write_text(text); temporary.replace(final); sent.append({"at":wall_now(),"text":text})
    def stop_active():
        nonlocal proc
        owned_before_stop=owned_process_tree(fixture)
        active_stop.write_text("stop\n")
        try: proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
        cleanup=reap_owned_cli(fixture,owned_before_stop); cleanup_receipts.append(cleanup)
        if not cleanup["all_reaped"]: raise RuntimeError("owned Codex CLI descendants were not reaped")
    def resume_exact(text,index,root_id):
        nonlocal proc,active_stop,active_kind
        submitted_text=transport_message(text)
        prompt=out/f"resume-{index}.txt"; prompt.write_text(submitted_text)
        active_stop=out/f"resume-stop-{index}"
        context_path = launch_context_path
        if not context_path.is_file():
            raise RuntimeError("managed public Shape did not retain its immutable launch context")
        resume_cmd=["expect",str(HERE/"resume_transport.exp"),str(fixture),root_id,str(prompt),str(active_stop),str(out/f"resume-{index}-pty.log"),profiles["root"][0],profiles["root"][1],str(context_path)]
        transport_argv.append(resume_cmd)
        proc=subprocess.Popen(resume_cmd,cwd=fixture,stdout=transport_log,stderr=subprocess.STDOUT,text=True)
        active_kind="native-exact-resume"
        sent.append({"at":wall_now(),"text":text,"submitted_text":submitted_text,"transport":active_kind})
    intermediate_draft_sha256=None
    try:
        startup_deadline=start_monotonic+MAX_SECONDS
        while monotonic_now()<startup_deadline:
            roots=exact_root_rollout(before,fixture,session_root)
            if len(roots)==1 and task_complete_count(roots[0])>=1: break
            if proc.poll() is not None: raise RuntimeError(f"Expect transport exited {proc.returncode} before startup terminal")
            time.sleep(1)
        else: raise TimeoutError("native startup turn")
        roots=exact_root_rollout(before,fixture,session_root); startup_summary=rollout_summary(roots[0]); root_id=startup_summary["id"]
        startup_turn_id=next((event.get("payload", {}).get("turn_id") for event in json.loads("[" + ",".join(Path(roots[0]).read_text().splitlines()) + "]") if event.get("type")=="turn_context"), None)
        last_digest=None; stable_since=None; intermediate_draft_sha256=None
        completed_without_draft=False; uncorrelated_user_event=False
        while monotonic_now()-start_monotonic < MAX_SECONDS:
            text=read_draft(fixture,slug); digest=hashlib.sha256(text.encode()).hexdigest()
            if digest != last_digest: last_digest=digest; stable_since=monotonic_now()
            if text and stable_since and monotonic_now()-stable_since>=3: break
            time.sleep(.25)
        else: raise TimeoutError(f"{case}: initial request turn did not save Draft")
        current_draft=draft_dir(fixture,slug)
        shutil.copytree(current_draft,out/"initial-draft",ignore=shutil.ignore_patterns("__pycache__","*.pyc","*.pyo",".DS_Store"))
        initial_terminal={"at":wall_now(),"root_rollout":roots[0],"turn_id":startup_turn_id,"draft_sha256":digest}
        if triggers and not triggers[0](text, roots[0]):
            raise TriggerMismatch(f"{case}: initial saved Draft did not match clarification trigger")
        if not messages:
            outcome="completed"
        else:
            stop_active()
            resume_exact(messages[0],0,root_id)
        next_msg=0
        while monotonic_now()-start_monotonic < MAX_SECONDS:
            if not messages:
                break
            text=read_draft(fixture,slug); digest=hashlib.sha256(text.encode()).hexdigest()
            if digest != last_digest: last_digest=digest; stable_since=monotonic_now()
            roots=exact_root_rollout(before,fixture,session_root)
            if len(roots) != 1:
                raise RuntimeError(f"{case}: expected exactly one native root rollout after startup")
            turn_id, complete=user_turn_terminal(roots[0], [{"text": entry["submitted_text"]} for entry in sent])
            # JSONL renders the multiline transport declaration with escaped
            # newlines. The exact decoded bytes above establish terminal
            # correlation; the original scripted content only detects a
            # malformed native user event that omitted its turn binding.
            if turn_id is None and rollout_contains(roots[0], messages[next_msg]):
                uncorrelated_user_event=True
            if complete and not text:
                completed_without_draft=True
            if complete and text and stable_since and monotonic_now()-stable_since>=3:
                terminal_observed.append({"at":wall_now(),"root_rollout":roots[0],"turn_id":turn_id,"draft_sha256":digest})
                current_draft=draft_dir(fixture,slug)
                if current_draft.is_dir():
                    shutil.copytree(current_draft,out/"drafts-by-turn"/str(next_msg),
                                    ignore=shutil.ignore_patterns("__pycache__","*.pyc","*.pyo",".DS_Store"))
                if case == "csv-continuation" and next_msg == 0 and len(messages) > 1:
                    intermediate = out / "drafts-by-turn" / "0" / "questions.md"
                    if not intermediate.is_file():
                        raise RuntimeError(f"{case}: partial clarification did not retain questions.md")
                    intermediate_draft_sha256 = hashlib.sha256(intermediate.read_bytes()).hexdigest()
                next_msg += 1
                if next_msg < len(messages):
                    if not triggers[next_msg](text, roots[0]):
                        failure={"type":"TriggerMismatch","message":f"{case}: saved Draft did not match clarification trigger"}
                        outcome="inconclusive"
                        break
                    stop_active()
                    resume_exact(messages[next_msg],next_msg,rollout_summary(roots[0])["id"])
                    stable_since=monotonic_now(); last_digest=digest
                else:
                    # The driver only establishes a completed, retained session.
                    # Semantic satisfaction is judged later by the independent Reviewer.
                    outcome="completed"; break
            if proc.poll() is not None: raise RuntimeError(f"Expect transport exited {proc.returncode}")
            time.sleep(1)
        else:
            if completed_without_draft:
                raise TimeoutError(f"{case}: completed user turn did not save Draft")
            if uncorrelated_user_event:
                raise RuntimeError(f"{case}: malformed or uncorrelated native event for submitted turn")
            raise TimeoutError(f"{case}: product turn did not complete before deadline")
    except Exception as exc:
        failure={"type":type(exc).__name__,"message":str(exc)}; outcome="infrastructure-error"
    finally:
        try:
            stop_active()
        except Exception as cleanup_exc:
            cleanup_receipts.append({"cleanup_error":{"type":type(cleanup_exc).__name__,"message":str(cleanup_exc)}})
            if failure is None:
                failure={"type":type(cleanup_exc).__name__,"message":str(cleanup_exc)}
                outcome="infrastructure-error"
        transport_log.close()
    deadline=monotonic_now()+10; previous=None
    while monotonic_now()<deadline:
        owned=sorted(inventory()-before); state=[(x,Path(x).stat().st_size) for x in owned]
        if state and state==previous: break
        previous=state; time.sleep(1)
    (out/"messages.json").write_text(json.dumps(sent,indent=2)+"\n")
    ignored_copy=shutil.ignore_patterns("__pycache__","*.pyc","*.pyo",".DS_Store")
    correlation={"exactly_one_root":False,"all_owned_terminal":False,"all_profiles_match":False}
    current_status=[]; current_sources={}
    # Capture each independent evidence surface even if Draft parsing fails.
    # A missing Draft is diagnostic evidence, not grounds to suppress the owned
    # native rollout or frozen fixture sources that explain the failed turn.
    capture_errors=[]
    def capture(stage, action):
        try:
            return action()
        except Exception as capture_exc:
            capture_errors.append({"stage":stage,"type":type(capture_exc).__name__,"message":str(capture_exc)})
            return None
    if draft_dir(fixture,slug).exists():
        capture("draft-copy", lambda: shutil.copytree(draft_dir(fixture,slug),out/"draft",ignore=ignored_copy))
    capture("draft-state", lambda: write_draft_state(fixture,slug,out,case))
    if (fixture / "evidence").is_dir():
        capture("fixture-evidence", lambda: shutil.copytree(fixture / "evidence", out / "evidence",ignore=ignored_copy))
    capture("fixture-sources", lambda: copy_fixture_sources(fixture,case,out))
    copied_correlation=capture("owned-sessions", lambda: copy_owned_sessions(before,fixture,out,profiles))
    if copied_correlation is not None: correlation=copied_correlation
    captured_status=capture("git-status", lambda: subprocess.run(["git","status","--porcelain"],cwd=fixture,capture_output=True,text=True,check=True).stdout.splitlines())
    if captured_status is not None: current_status=captured_status
    captured_sources=capture("source-after", lambda: source_snapshot(fixture))
    if captured_sources is not None:
        current_sources=captured_sources
        capture("source-after-write", lambda: (out/"source-after.json").write_text(json.dumps(current_sources,indent=2,sort_keys=True)+"\n"))
    if capture_errors:
        first=capture_errors[0]
        if failure is None:
            failure={"type":first["type"],"message":f"{case}: evidence capture failed: {first['message']}"}
            outcome="infrastructure-error"
        correlation={**correlation,"capture_error":first,"capture_errors":capture_errors}
    receipt={"case":case,"fixture":str(fixture),"slug":slug,"started":start_wall,"ended":wall_now(),"started_monotonic":start_monotonic,"ended_monotonic":monotonic_now(),"elapsed_seconds":monotonic_now()-start_monotonic,"transport_argv":transport_argv,"resume_environment":{"KOGEN_ROLE":"shaper"},"configured_profiles":profile_configuration,"cleanup":cleanup_receipts,"transport_exit":proc.returncode,"initial_messages":1,"scripted_replies":len(sent),"initial_terminal_event":locals().get("initial_terminal"),"outcome":outcome,"failure":failure,"terminal_events":terminal_observed,"terminal_turn_bindings":[event["turn_id"] for event in terminal_observed],"intermediate_draft_sha256":intermediate_draft_sha256,"correlation":correlation,"git_status":{"baseline":baseline_status,"after":current_status,"baseline_unchanged":current_status==baseline_status,"draft_exists":draft_dir(fixture,slug).exists()},"source_identity":{"baseline":baseline_sources,"after":current_sources,"unchanged":baseline_sources==current_sources}}
    (out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    public_receipt={
        "case":case,"slug":slug,"started":start_wall,"ended":receipt["ended"],
        "elapsed_seconds":receipt["elapsed_seconds"],"configured_profiles":profile_configuration,
        "transport_exit":proc.returncode,"initial_messages":receipt["initial_messages"],
        "scripted_replies":receipt["scripted_replies"],"outcome":outcome,"failure":failure,
        "initial_terminal_event":receipt["initial_terminal_event"],
        "terminal_events":[{key:event.get(key) for key in ("at","turn_id","draft_sha256")}
                           for event in terminal_observed],
        "terminal_turn_bindings":receipt["terminal_turn_bindings"],
        "intermediate_draft_sha256":intermediate_draft_sha256,
        "correlation":{key:correlation.get(key) for key in
                       ("exactly_one_root","all_owned_terminal","all_profiles_match","roots","owned","requested_profiles")},
        "cleanup":{"all_reaped":all(item.get("all_reaped") is True for item in cleanup_receipts),
                   "attempts":len(cleanup_receipts)},
        "git_status":{"baseline_unchanged":receipt["git_status"]["baseline_unchanged"],
                      "draft_exists":receipt["git_status"]["draft_exists"]},
        "source_identity":{"unchanged":receipt["source_identity"]["unchanged"],
                           "baseline_sha256":sha256(out/"source-baseline.json"),
                           "after_sha256":sha256(out/"source-after.json")},
    }
    (out/"review-receipt.json").write_text(json.dumps(public_receipt,indent=2)+"\n")
    return receipt

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

def write_manifest():
    entries = []
    for path in required_artifacts():
        if not path.is_relative_to(PROJECT):
            raise RuntimeError(f"evidence outside repository: {path}")
        entries.append({"path": str(path.relative_to(PROJECT)), "sha256": sha256(path)})
    counterexamples = RUNTIME / "semantic-counterexamples.json"
    if counterexamples.is_file():
        entries.append({"path": str(counterexamples.relative_to(PROJECT)), "sha256": sha256(counterexamples)})
    if not entries:
        raise RuntimeError("no shaping-evaluation evidence to manifest")
    manifest = RUNTIME / "evidence-manifest.json"
    manifest.write_text(json.dumps({"schema_version": 1, "required_evidence": entries}, indent=2) + "\n")
    try:
        integrity_module().validate_manifest(PROJECT, manifest)
    except Exception as exc:
        raise RuntimeError(f"manifest integrity validation failed: {exc}") from exc
    locator = {"manifest_path": str(manifest.relative_to(PROJECT)), "sha256": sha256(manifest)}
    print("\nKOGEN_TARGET_EVIDENCE_MANIFEST\t" + json.dumps(locator, separators=(",", ":")), flush=True)
    return locator

def write_semantic_counterexamples():
    shutil.copy2(HERE / "semantic-counterexamples.json", RUNTIME / "semantic-counterexamples.json")

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
    continuation = RUNTIME / "runs" / "csv-continuation"
    if not continuation.is_dir():
        return
    seed = parse_yaml_mapping(RUNTIME / "continuation-seed" / "intent.yaml", case="csv-continuation seed")
    final = parse_yaml_mapping(continuation / "draft" / "intent.yaml", case="csv-continuation")
    partial = parse_yaml_mapping(continuation / "drafts-by-turn" / "0" / "intent.yaml", case="csv-continuation partial")
    for stage, document in (("partial", partial), ("final", final)):
        for field in ("id", "slug", "shaping", "shaped_against"):
            if document.get(field) != seed.get(field):
                raise RuntimeError(f"csv-continuation: {stage} lost seed {field}")
        visits = document.get("shaping_continuations", [])
        previous = seed.get("shaping_continuations", [])
        if len(visits) != len(previous) + 1 or visits[:-1] != previous:
            raise RuntimeError(f"csv-continuation: {stage} lacks one fresh continuation visit")
    if partial.get("shaping_continuations") != final.get("shaping_continuations"):
        raise RuntimeError("csv-continuation: partial and final changed continuation visit")


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
    children={}; logs={}; pending=set(cases); failure=None
    try:
        for case in cases:
            log=(RUNTIME/f"{case}-output.log").open("w")
            logs[case]=log
            children[case]=subprocess.Popen(["python3", "-B", str(Path(__file__).resolve()), case], env=env, stdout=log, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        deadline = monotonic_now() + MAX_SECONDS
        while pending and failure is None:
            if monotonic_now() >= deadline:
                raise TimeoutError("parallel cases exceeded the existing case deadline")
            for case in cases:
                child=children[case]
                if case not in pending or child.poll() is None: continue
                pending.remove(case)
                if child.returncode:
                    failure=(case, f"child exited {child.returncode}; see {case}-output.log")
                    break
                required_case_capture(case)
            if pending and failure is None: time.sleep(.05)
        if failure: raise RuntimeError(f"{failure[0]}: {failure[1]}")
    except Exception as exc:
        cleanup_errors = []
        for case, child in children.items():
            try:
                cancel_case_process(case, child)
            except Exception as cleanup_exc:
                cleanup_errors.append({"case":case,"type":type(cleanup_exc).__name__,"message":str(cleanup_exc)})
        failure_record={"case": failure[0] if failure else "parallel suite", "type":type(exc).__name__,"message":str(exc),"cancelled_children":sorted(pending),"cleanup_errors":cleanup_errors}
        (RUNTIME/"suite-failure.json").write_text(json.dumps(failure_record,indent=2)+"\n")
        return 1
    finally:
        for log in logs.values(): log.close()
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

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("case",choices=[*CASES, "suite"]); args=ap.parse_args()
    if args.case == "suite":
        return run_suite()
    suite_barrier(args.case)
    if args.case=="csv-flawed":
        f=setup_fixture("csv-flawed",csv_files()); r=drive(args.case,f,"eval-csv-flawed",[CSV_ANSWER],[lambda t, root: "bom" in t.lower() and rollout_contains(root, "bom")]); require_cleanup(f,args.case,r)
    elif args.case=="csv-continuation":
        seed = RUNTIME / "continuation-seed"
        f = RUNTIME / "csv-continuation"
        if not seed.is_dir() or not draft_dir(f, "eval-csv-seed").is_dir():
            raise RuntimeError("csv-continuation seed or private fixture is missing")
        r=drive(args.case,f,"eval-csv-seed",[CSV_CONT_PARTIAL, CSV_CONT_FINAL],[lambda text, _root: "invalid" in text.lower() and "?" in text, lambda text, _root: "output" in text.lower() and any(word in text.lower() for word in ("replacement", "replace", "overwrite")) and "?" in text],True); require_cleanup(f,args.case,r)
    elif args.case=="csv-complete":
        f=setup_fixture("csv-complete",csv_files(True)); r=drive(args.case,f,"eval-csv-complete",[],[lambda _t, _root: True]); require_cleanup(f,args.case,r)
    elif args.case=="booking-flawed":
        f=setup_fixture("booking-flawed",booking_files()); msgs=[BOOKING_ANSWER]; tr=[booking_reachability_trigger]; r=drive(args.case,f,"eval-booking-flawed",msgs,tr); require_cleanup(f,args.case,r)
    else:
        if args.case == "booking-complete":
            f=setup_fixture("booking-complete",booking_files(True)); r=drive(args.case,f,"eval-booking-complete",[],[lambda _t, _root: True])
        elif args.case == "stateful-flawed":
            f=setup_fixture("stateful-flawed",stateful_files(False)); r=drive(args.case,f,"eval-stateful-flawed",[],[lambda _t, _root: True])
        else:
            f=setup_fixture("stateful-complete",stateful_files(True)); r=drive(args.case,f,"eval-stateful-complete",[],[lambda _t, _root: True])
        require_cleanup(f,args.case,r)
    # The driver deliberately stops an otherwise completed interactive root.
    # Depending on whether Codex still owns a background terminal, that bounded
    # stop may surface the TERM status even though the captured native turn and
    # owned-descendant cleanup both completed. Early/unexpected exits are
    # classified inside drive() and cannot reach outcome=completed.
    print(json.dumps(r,indent=2)); return 0 if case_succeeded(r) else 1
if __name__=="__main__": raise SystemExit(main())
