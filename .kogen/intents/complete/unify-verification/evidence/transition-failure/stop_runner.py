#!/usr/bin/env python3
"""Unified candidate-bound Developer Stop verification runner."""
import base64, datetime, fcntl, hashlib, json, os, subprocess, tempfile
import re
from pathlib import Path

ROOT = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
RUNTIME = ROOT / ".kogen" / "runtime"
RECORD, HISTORY = RUNTIME / "verification.json", RUNTIME / "verification-history.jsonl"
RETRIES, LOG = RUNTIME / "verification-retries.json", RUNTIME / "stop-check.log"

def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".hook.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(value); stream.flush(); os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        try: os.unlink(name)
        except FileNotFoundError: pass

def append_locked(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX); stream.write(value); stream.flush(); os.fsync(stream.fileno()); fcntl.flock(stream.fileno(), fcntl.LOCK_UN)

def load_context():
    for key, legacy in (("KOGEN_VERIFICATION_CONTEXT", False), ("KOGEN_TRACKING_CONTEXT", True)):
        value = os.environ.get(key)
        if not value: continue
        try:
            path = Path(value)
            obj = json.loads(path.read_text() if value.startswith("/") and path.is_file() else value)
            if not isinstance(obj, dict): raise ValueError("context is not an object")
            if not legacy and not (obj.get("schema_version") or obj.get("version")): raise ValueError("missing schema_version")
            targets = obj.get("targets", obj.get("verification_targets", ["check"]))
            if not isinstance(targets, list) or any(not isinstance(x, str) or not x.strip() for x in targets): raise ValueError("invalid targets")
            if not legacy and Path(obj.get("project_root", "")).resolve() != ROOT.resolve():
                raise ValueError("project_root does not match the active repository")
            obj["_unified"] = not legacy
            return obj, None
        except Exception as exc:
            return {}, f"invalid {key}: {exc}"
    return {"_unified": False}, None

def candidate():
    listing = subprocess.run(["git", "ls-files", "-v"], cwd=ROOT, text=True, capture_output=True)
    if listing.returncode: return "", listing.stderr.strip()
    if any(x[:1] == "S" or x[:1].islower() for x in listing.stdout.splitlines()): return "", "Candidate identity refused: Git index contains assume-unchanged or skip-worktree flags"
    private = tempfile.NamedTemporaryFile(prefix="kogen-index.", delete=False); private.close()
    try:
        index = subprocess.check_output(["git", "rev-parse", "--git-path", "index"], cwd=ROOT, text=True).strip()
        subprocess.run(["cp", index, private.name], check=True)
        env = {**os.environ, "GIT_INDEX_FILE": private.name}
        if subprocess.run(["git", "add", "-A"], cwd=ROOT, env=env, capture_output=True).returncode: return "", "git add -A failed"
        tree = subprocess.run(["git", "write-tree"], cwd=ROOT, env=env, text=True, capture_output=True)
        return (tree.stdout.strip(), "") if tree.returncode == 0 else ("", tree.stderr.strip())
    finally:
        try: os.unlink(private.name)
        except FileNotFoundError: pass

def sha256(value):
    return hashlib.sha256(value).hexdigest()

def safe_file(relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("unsafe target evidence path")
    parts = Path(relative).parts
    if Path(relative).is_absolute() or any(part in ("", ".", "..") for part in parts):
        raise ValueError("unsafe target evidence path")
    path = ROOT.joinpath(*parts)
    current = ROOT
    for part in parts:
        current = current / part
        if current.is_symlink(): raise ValueError("unsafe target evidence path")
    if not path.is_file(): raise ValueError("target evidence path is missing or not regular")
    return path

def snapshot(relative, expected=None):
    value = safe_file(relative).read_bytes()
    digest = sha256(value)
    if expected is not None and digest != expected: raise ValueError("target evidence digest mismatch")
    return {"path": relative, "sha256": digest, "content_base64": base64.b64encode(value).decode()}

def capture_evidence(output, target, token):
    prefix = "KOGEN_TARGET_EVIDENCE_MANIFEST\t"
    frames = [line.split(prefix, 1)[1].rstrip("\r") for line in output.splitlines() if prefix in line]
    if not frames: return None
    if len(frames) != 1: raise ValueError("target emitted duplicate evidence manifest frames")
    locator = json.loads(frames[0])
    if set(locator) != {"manifest_path", "sha256"}: raise ValueError("invalid target evidence frame")
    manifest_snapshot = snapshot(locator["manifest_path"], locator["sha256"])
    manifest = json.loads(base64.b64decode(manifest_snapshot["content_base64"]))
    if set(manifest) != {"schema_version", "required_evidence"} or manifest["schema_version"] != 1:
        raise ValueError("invalid target evidence manifest")
    entries, seen = [], set()
    if not isinstance(manifest["required_evidence"], list) or not manifest["required_evidence"]:
        raise ValueError("target evidence manifest requires evidence")
    for entry in manifest["required_evidence"]:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256"} or entry["path"] in seen:
            raise ValueError("invalid target evidence entry")
        seen.add(entry["path"]); entries.append(snapshot(entry["path"], entry["sha256"]))
    return {"target": target, "attempt_token": token, "manifest": manifest_snapshot, "required_evidence": entries}

def admit(state, history_text, ctx, context_sha, session, targets):
    required = {"schema_version", "context_sha256", "attempt_token", "outer_attempt", "developer_session_id", "candidate_id", "cycles", "failures_since_pass", "terminal_state"}
    if not isinstance(state, dict) or set(state) != required: raise ValueError("state shape is invalid")
    if (state["schema_version"], state["context_sha256"], state["attempt_token"], state["outer_attempt"]) != (1, context_sha, ctx["attempt_token"], ctx["outer_attempt"]): raise ValueError("state binding is invalid")
    try: history = [json.loads(line) for line in history_text.splitlines() if line]
    except Exception as exc: raise ValueError(f"chronology is malformed: {exc}")
    cycles = state["cycles"]
    if not history or history[-1] != state or not isinstance(cycles, list) or len(history) != len(cycles) + 1: raise ValueError("state is missing, rolled back, or chronology is incomplete")
    initial = history[0]
    if initial.get("cycles") != [] or initial.get("failures_since_pass") != 0 or initial.get("terminal_state") != "pending": raise ValueError("initial chronology is invalid")
    bound_session, failures = state["developer_session_id"], 0
    if bound_session is not None and bound_session != session: raise ValueError("session binding changed")
    for index, cycle in enumerate(cycles, 1):
        receipts = cycle.get("receipts") if isinstance(cycle, dict) else None
        names = [receipt.get("target") for receipt in receipts] if isinstance(receipts, list) and all(isinstance(receipt, dict) for receipt in receipts) else []
        status = cycle.get("status") if isinstance(cycle, dict) else None
        failed = [receipt for receipt in receipts or [] if receipt.get("status") == "failed"]
        valid = cycle.get("sequence") == index and cycle.get("attempt_token") == ctx["attempt_token"] and cycle.get("outer_attempt") == ctx["outer_attempt"] and cycle.get("developer_session_id") == bound_session and cycle.get("failures_before") == failures and receipts and names == targets[:len(names)]
        after = 0 if status == "passed" else failures + 1
        valid = valid and cycle.get("failures_after") == after and ((status == "passed" and names == targets and not failed) or (status == "failed" and len(failed) == 1 and receipts[-1] is failed[0]))
        valid = valid and all(receipt.get("candidate_id") == cycle.get("candidate_id") and receipt.get("developer_session_id") == bound_session and receipt.get("attempt_token") == ctx["attempt_token"] and receipt.get("cycle_sequence") == index and ((receipt.get("status") == "passed" and receipt.get("exit_code") == 0) or (receipt.get("status") == "failed" and isinstance(receipt.get("exit_code"), int) and receipt.get("exit_code") != 0)) for receipt in receipts or [])
        if not valid or history[index].get("cycles") != cycles[:index] or history[index].get("failures_since_pass") != after: raise ValueError(f"cycle {index} chronology is inconsistent")
        failures = after
    terminal = "passed" if cycles and cycles[-1].get("status") == "passed" else ("exhausted" if failures > int(ctx["verification_retries"]) else "pending")
    if state["failures_since_pass"] != failures or state["terminal_state"] != terminal: raise ValueError("terminal counter is inconsistent")
    return state

def main():
    try: request = json.loads(__import__("sys").stdin.read() or "{}")
    except Exception: request = {}
    ctx, context_error = load_context(); session = request.get("session_id") or os.environ.get("KOGEN_SESSION_ID", "")
    cid, candidate_error = candidate(); token = ctx.get("attempt_token", "")
    reason = context_error or candidate_error
    expected_session = ctx.get("session_id", ctx.get("developer_session_id"))
    if not reason and not session: reason = "Kogen Stop Check did not receive the Developer session id."
    if not reason and ctx.get("_unified") and not token: reason = "versioned verification context is missing attempt binding."
    if not reason and expected_session and expected_session != session: reason = "Developer session does not match the supplied verification context."
    if not session:
        print(json.dumps({"decision": "block", "reason": reason}, separators=(",", ":")))
        return
    outputs, code, status = [], 1 if reason else 0, "failed" if reason else "passed"
    targets = list(dict.fromkeys(ctx.get("targets", ctx.get("verification_targets", ["check"]))))
    if "check" not in targets: targets.insert(0, "check")
    prior = {"cycles": [], "failures_since_pass": 0}
    if not reason and ctx.get("_unified"):
        try:
            context_bytes = Path(os.environ["KOGEN_VERIFICATION_CONTEXT"]).read_bytes()
            state_path, history_path = Path(ctx["state_path"]), Path(ctx["history_path"])
            prior = admit(json.loads(state_path.read_text()), history_path.read_text(), ctx, hashlib.sha256(context_bytes).hexdigest(), session, targets)
        except Exception as exc:
            print(json.dumps({"continue":False,"stopReason":f"verification state integrity failure: {exc}"}, separators=(",", ":")))
            return
        if prior["terminal_state"] != "pending":
            print(json.dumps({"continue":False,"stopReason":f"verification already terminal: {prior['terminal_state']}"}, separators=(",", ":")))
            return
    if not reason:
        for target in targets:
            if not re.fullmatch(r"[a-z][a-z0-9_-]*", target): reason, status, code = f"invalid target: {target}", "failed", 1; break
            run = subprocess.run(["make", "-C", str(ROOT), target], capture_output=True)
            output = (run.stdout + run.stderr).decode("utf-8", errors="replace")
            item = {"target": target, "exit_code": run.returncode, "output": output, "finished_at": now()}
            try: item["target_evidence"] = capture_evidence(output, target, token)
            except Exception as exc:
                item["exit_code"] = max(run.returncode, 1); item["output"] += "\nKogen target evidence validation failed: " + str(exc) + "\n"
            outputs.append(item)
            if item["exit_code"]: reason, status, code = item["output"], "failed", item["exit_code"]; break
            current, current_error = candidate()
            if current_error or current != cid:
                reason, status, code = current_error or "Candidate mutated during verification", "failed", 1
                item["status"], item["exit_code"], item["output"] = "failed", 1, item["output"] + "\n" + reason + "\n"
                break
    if not ctx.get("_unified"):
        result = {"candidate": cid, "status": status, "target": "check", "exit_code": 0 if status == "passed" else 1, "session_id": session, "finished_at": now(), "reason": (reason or "\n".join(x["output"] for x in outputs)).rstrip("\n")}
        line = json.dumps(result, separators=(",", ":")) + "\n"; atomic(RECORD, line); append_locked(HISTORY, line); atomic(LOG, result["reason"] + "\n")
        if status == "passed": print('{"continue":true}')
        else: print(json.dumps({"decision":"block", "reason":"Kogen Stop Check failed. Read .kogen/runtime/stop-check.log, fix the Candidate, and finish only after this hook passes."}, separators=(",", ":")))
        return
    sequence = len(prior.get("cycles", [])) + 1; before = prior.get("failures_since_pass", 0); after = 0 if status == "passed" else before + 1
    receipts = [{"target": x["target"], "status": "passed" if x["exit_code"] == 0 else "failed", "exit_code": x["exit_code"], "output": x["output"], "finished_at": x["finished_at"], "candidate_id": cid, "developer_session_id": session, "attempt_token": token, "cycle_sequence": sequence, **({"target_evidence": x["target_evidence"]} if x.get("target_evidence") else {})} for x in outputs]
    cycle = {"sequence": sequence, "attempt_token": token, "outer_attempt": ctx["outer_attempt"], "developer_session_id": session, "candidate_id": cid, "failures_before": before, "failures_after": after, "status": status, "finished_at": now(), "receipts": receipts}
    state = {"schema_version": 1, "context_sha256": __import__("hashlib").sha256(context_bytes).hexdigest(), "attempt_token": token, "outer_attempt": ctx["outer_attempt"], "developer_session_id": session, "candidate_id": cid, "cycles": prior.get("cycles", []) + [cycle], "failures_since_pass": after, "terminal_state": "passed" if status == "passed" else ("exhausted" if after > int(ctx["verification_retries"]) else "pending")}
    state_bytes = json.dumps(state, separators=(",", ":")) + "\n"; atomic(state_path, state_bytes); append_locked(history_path, state_bytes)
    result = {"candidate": cid, "status": status, "target": "check", "exit_code": code, "session_id": session, "attempt_token": token, "finished_at": now(), "reason": reason or "\n".join(x["output"] for x in outputs), "state": state}
    line = json.dumps(result, separators=(",", ":")) + "\n"; atomic(RECORD, line); append_locked(HISTORY, line); atomic(LOG, result["reason"] + "\n")
    if state["terminal_state"] == "exhausted": print('{"continue":false,"stopReason":"verification retry budget exhausted"}')
    elif status == "failed":
        print('{"decision":"block","reason":"Kogen verification failed. Read .kogen/runtime/stop-check.log, fix the Candidate, and stop again."}')
    else: print('{"continue":true}')

if __name__ == "__main__":
    RUNTIME.mkdir(parents=True, exist_ok=True)
    with open(RUNTIME / "verification-hook.lock", "a", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        main()
