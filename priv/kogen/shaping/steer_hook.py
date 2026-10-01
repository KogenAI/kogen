#!/usr/bin/env python3
"""The headless Shaping steer hook (PostToolUse on Claude Code and Codex).

It delivers the Shaper's accepted, not yet recorded messages, and current
checkpoint-audit notices, to the root Shaping Controller session that is
running now, as `additionalContext`.

Every delivery state is computed from files, never from a marker that
suppresses redelivery:

- accepted: `inputs/NNNN.md` and `inputs/NNNN.json` exist (kind `message`);
- offered: `inputs/NNNN.offers.jsonl` has a record for this launch id;
- recorded: the Draft's `## Shaper answers` carries `[input <id>]`.

The offer record is appended before anything is printed, so a crash only
delays an answer: the runner re-sends every unrecorded input at turn end
under a new launch id. Helper sessions never receive anything: Claude Code
marks helper tool calls with `agent_id`/`agent_type`, and a Codex helper
thread's rollout starts with a `session_meta` whose `payload.source` is
`{"subagent": {"thread_spawn": {...}}}` (the same test as
`Kogen.ShapingAudit.StopHook`).
"""

import datetime
import base64
import hashlib
import json
import os
import re
import sys
import time

TOKEN = re.compile(r"\[input (in-\d{4}-[0-9a-f]{8})\]")
RECORDING_FRAME = re.compile(r"```kogen-recorded-input-v1\s+(\{.*?\})\s+```", re.S)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def read_json(path):
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def read_bytes(path):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError:
        return None


def helper_call(payload, cwd):
    if not isinstance(payload, dict):
        return False
    if "agent_id" in payload or "agent_type" in payload:
        return True
    transcript = payload.get("transcript_path")
    if not isinstance(transcript, str) or not transcript:
        return False
    if not os.path.isabs(transcript):
        transcript = os.path.join(cwd, transcript)
    try:
        with open(transcript, "rb") as handle:
            first = handle.readline().decode("utf-8")
        meta = json.loads(first)
    except (OSError, ValueError):
        return False
    source = (meta.get("payload") or {}).get("source") if isinstance(meta, dict) else None
    if isinstance(source, dict):
        subagent = source.get("subagent")
        if isinstance(subagent, dict) and isinstance(subagent.get("thread_spawn"), dict):
            return True
    return False


def find_package(root, intent_id):
    for kind in ("drafts", "approved"):
        base = os.path.join(root, ".kogen", "intents", kind)
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        pattern = re.compile(r"^id:\s*" + re.escape(intent_id) + r"\s*$", re.M)
        for name in names:
            data = read_bytes(os.path.join(base, name, "intent.yaml"))
            if data is not None and pattern.search(data.decode("utf-8", "replace")):
                return os.path.join(base, name), kind
    return None, None


def shaper_answers(package):
    if package is None:
        return ""
    data = read_bytes(os.path.join(package, "questions.md"))
    if data is None:
        return ""
    text = data.decode("utf-8", "replace")
    match = re.search(r"^## Shaper answers[ \t]*$", text, re.M)
    if not match:
        return ""
    rest = text[match.end():]
    following = re.search(r"^## ", rest, re.M)
    return rest[: following.start()] if following else rest


def answer_entries(package):
    lines = shaper_answers(package).splitlines()
    entries = []
    current = None
    for line in lines:
        if re.match(r"^(?:\d+\.|[-*])\s+", line):
            if current is not None:
                entries.append(" ".join(current))
            current = [re.sub(r"^(?:\d+\.|[-*])\s+", "", line)]
        elif current is not None and re.match(r"^\s+\S", line):
            current.append(line.strip())
    if current is not None:
        entries.append(" ".join(current))
    return entries


def exact_recording(entry, input_id, canonical):
    visible = RECORDING_FRAME.sub("", entry)
    if input_id not in TOKEN.findall(visible):
        return False
    frames = RECORDING_FRAME.findall(entry)
    if len(frames) != 1:
        return False
    try:
        frame = json.loads(frames[0])
        decoded = base64.b64decode(frame["bytes_base64"], validate=True)
        return (
            frame.get("schema") == "kogen.recorded-input/v1"
            and frame.get("input_id") == input_id
            and frame.get("byte_length") == len(canonical)
            and frame.get("sha256") == hashlib.sha256(canonical).hexdigest()
            and frame.get("verbatim_text", "").encode("utf-8") == canonical
            and decoded == canonical
        )
    except (KeyError, TypeError, ValueError, UnicodeError):
        return False


def recorded_ids(package, canonical_inputs):
    entries = answer_entries(package)
    token_counts = {}
    exact_counts = {}
    for entry in entries:
        visible = RECORDING_FRAME.sub("", entry)
        ids = set(TOKEN.findall(visible))
        for input_id in ids:
            token_counts[input_id] = token_counts.get(input_id, 0) + 1
            match = re.fullmatch(r"in-(\d{4})-[0-9a-f]{8}", input_id)
            canonical = canonical_inputs.get(match.group(1)) if match else None
            if canonical is not None and exact_recording(entry, input_id, canonical):
                exact_counts[input_id] = exact_counts.get(input_id, 0) + 1
    return {input_id for input_id, count in exact_counts.items()
            if count == 1 and token_counts.get(input_id) == 1}


def open_question_numbers(meta):
    numbers = [str(q.get("number")) for q in meta.get("open_questions") or [] if isinstance(q, dict)]
    return ", ".join(numbers) if numbers else "none"


def offered(path, launch_id):
    data = read_bytes(path)
    if data is None:
        return False
    for line in data.decode("utf-8", "replace").splitlines():
        try:
            if json.loads(line).get("launch_id") == launch_id:
                return True
        except ValueError:
            continue
    return False


def append_offer(path, record):
    with open(path, "ab") as handle:
        handle.write((json.dumps(record, sort_keys=True) + "\n").encode("utf-8"))
        handle.flush()
        os.fsync(handle.fileno())


def copy_into(package, relative, data):
    if package is None:
        return
    destination = os.path.join(package, relative)
    if read_bytes(destination) == data:
        return
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    tmp = destination + ".tmp-%d" % os.getpid()
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, destination)


def copy_immutable_brief(package, data):
    destination = os.path.join(package, "evidence", "brief.md")
    current = read_bytes(destination)
    if current is not None:
        return current == data
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    temporary = destination + ".admission-%d-%d" % (os.getpid(), time.time_ns())
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, destination)
        except FileExistsError:
            return read_bytes(destination) == data
        return True
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def answer_block(nonce, number, input_id, open_numbers, text):
    data = text.encode("utf-8")
    frame = json.dumps(
        {
            "schema": "kogen.recorded-input/v1",
            "input_id": input_id,
            "byte_length": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "verbatim_text": text,
            "bytes_base64": base64.b64encode(data).decode("ascii"),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return (
        "KOGEN SHAPER ANSWER %s [input %s]\n"
        "Package copy: evidence/inputs/%s.md\n"
        "Open questions at receipt: %s\n"
        "If [input %s] has an exact recording frame under ## Shaper answers, do not record it again.\n"
        "Record one numbered Shaper answer by copying this exact token and indented frame; keep the verbatim_text and bytes_base64 values intact:\n"
        "N. [input %s]\n  ```kogen-recorded-input-v1\n  %s\n  ```\n"
        "Visible verbatim accepted input follows:\n%s"
        % (nonce, input_id, number, open_numbers, input_id, input_id, frame, text)
    )


def package_revision(package):
    """`Kogen.ShapingAudit.Package.revision/1`: sha256 over sorted paths and bytes."""
    files = []
    for directory, dirnames, filenames in os.walk(package, followlinks=False):
        for name in dirnames:
            if os.path.islink(os.path.join(directory, name)):
                return None
        for name in filenames:
            path = os.path.join(directory, name)
            if os.path.islink(path) or not os.path.isfile(path):
                return None
            files.append(os.path.relpath(path, package).encode("utf-8"))
    digest = hashlib.sha256()
    for relative in sorted(files):
        digest.update(relative + b"\0")
        digest.update(read_bytes(os.path.join(package, relative.decode("utf-8"))) + b"\0")
    return digest.hexdigest()


def input_blocks(session_dir, package, nonce, launch_id):
    inputs = os.path.join(session_dir, "inputs")
    try:
        names = sorted(n for n in os.listdir(inputs) if re.match(r"^\d{4}\.json$", n))
    except OSError:
        return []
    accepted = []
    for name in names:
        number = name[:4]
        meta = read_json(os.path.join(inputs, name))
        data = read_bytes(os.path.join(inputs, number + ".md"))
        if isinstance(meta, dict) and data is not None:
            accepted.append((name, number, meta, data))

    canonical_inputs = {
        number: data for _name, number, meta, data in accepted if meta.get("kind") != "brief"
    }
    recorded = recorded_ids(package, canonical_inputs)
    blocks = []
    for name, number, meta, data in accepted:
        if meta.get("kind") == "brief":
            if package is not None:
                copy_immutable_brief(package, data)
            continue
        input_id = "in-%s-%s" % (number, hashlib.sha256(data).hexdigest()[:8])
        offers = os.path.join(inputs, number + ".offers.jsonl")
        copy_into(package, os.path.join("evidence", "inputs", number + ".md"), data)
        if input_id in recorded or offered(offers, launch_id):
            continue
        append_offer(offers, {"launch_id": launch_id, "via": "steer", "at": now(), "id": input_id})
        text = data.decode("utf-8")
        blocks.append(answer_block(nonce, number, input_id, open_question_numbers(meta), text))
    return blocks


def audit_blocks(session_dir, package, nonce, launch_id):
    notices = os.path.join(session_dir, "notices")
    try:
        names = sorted(n for n in os.listdir(notices) if re.match(r"^au-[0-9a-f]{12}\.json$", n))
    except OSError:
        return []
    if package is None:
        return []
    current = None
    blocks = []
    for name in names:
        notice = read_json(os.path.join(notices, name))
        if not isinstance(notice, dict):
            continue
        offers = os.path.join(notices, name[:-5] + ".offers.jsonl")
        if offered(offers, launch_id):
            continue
        if current is None:
            current = package_revision(package)
        if notice.get("revision") != current:
            continue
        append_offer(offers, {"launch_id": launch_id, "via": "steer", "at": now(), "id": name[:-5]})
        blocks.append(
            "KOGEN AUDIT %s %s\nReport: %s\n%s"
            % (nonce, notice["revision"][:12], notice.get("report", ""), notice.get("summary", ""))
        )
    return blocks


def main():
    session_dir = os.environ.get("KOGEN_SHAPING_SESSION_DIR", "")
    launch_id = os.environ.get("KOGEN_SHAPING_LAUNCH_ID", "")
    raw = sys.stdin.read()
    if not session_dir or not launch_id:
        return 0
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except ValueError:
        payload = {}
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(session_dir))))
    if helper_call(payload, root):
        return 0
    session = read_json(os.path.join(session_dir, "session.json"))
    if not isinstance(session, dict):
        return 0
    package, kind = find_package(root, session.get("intent_id", ""))
    if kind != "drafts":
        package = None
    nonce = session.get("nonce", "")
    blocks = input_blocks(session_dir, package, nonce, launch_id)
    blocks += audit_blocks(session_dir, package, nonce, launch_id)
    if blocks:
        sys.stdout.write(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PostToolUse",
                        "additionalContext": "\n\n".join(blocks),
                    }
                }
            )
            + "\n"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
