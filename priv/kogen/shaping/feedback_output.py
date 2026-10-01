#!/usr/bin/env python3
"""Relay native Shaping hook output and retain bytes after host-facing flush.

The hook producer runs behind this process. Its stdout is captured through a
pipe, then these exact bytes are written to the provider-facing stdout. A
receipt is appended only after that write and flush succeeds.
"""

import argparse
import base64
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SCHEMA = "kogen.feedback-delivery/v1"
MAX_RECEIPT_BYTES = 256 * 1024


def _revision_for_posttool(payload, session_dir, launch_id):
    try:
        context = payload["hookSpecificOutput"]["additionalContext"]
    except (KeyError, TypeError):
        return None
    match = re.search(r"KOGEN AUDIT\s+\S+\s+([0-9a-f]{12})", context)
    if not match:
        return None
    prefix = match.group(1)
    notices = Path(session_dir) / "notices"
    for notice_path in sorted(notices.glob("au-*.json")):
        try:
            notice = json.loads(notice_path.read_text(encoding="utf-8"))
            offers = (notices / (notice_path.stem + ".offers.jsonl")).read_text(encoding="utf-8")
        except (OSError, ValueError):
            continue
        revision = notice.get("revision") if isinstance(notice, dict) else None
        if isinstance(revision, str) and revision.startswith(prefix) and len(revision) == 64:
            if any(_json_record(line).get("launch_id") == launch_id for line in offers.splitlines()):
                return revision
    return None


def _json_record(line):
    try:
        value = json.loads(line)
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _revision_for_stop(payload):
    if not isinstance(payload, dict) or payload.get("decision") != "block":
        return None
    reason = payload.get("reason")
    if not isinstance(reason, str):
        return None
    match = re.search(r"(?:^|/)([0-9a-f]{64})/report\.json(?:\s|$)", reason)
    return match.group(1) if match else None


def _receipt(payload_bytes, boundary, revision):
    if not payload_bytes or len(payload_bytes) > MAX_RECEIPT_BYTES:
        return None
    try:
        payload = json.loads(payload_bytes.decode("utf-8"))
    except (UnicodeError, ValueError):
        return None
    session_dir = os.environ.get("KOGEN_SHAPING_SESSION_DIR", "")
    intent_id = os.environ.get("KOGEN_SHAPING_INTENT_ID", "")
    launch_id = os.environ.get("KOGEN_SHAPING_LAUNCH_ID", "")
    root_value = os.environ.get("KOGEN_SHAPING_ROOT") or os.getcwd()
    if not all((session_dir, intent_id, launch_id)):
        return None
    root = os.path.realpath(root_value)
    session_dir = os.path.realpath(session_dir)
    expected = os.path.realpath(os.path.join(root, ".kogen", "runtime", "shaping", intent_id))
    if session_dir != expected or not os.path.isfile(os.path.join(session_dir, "session.json")):
        return None
    try:
        session = json.loads(Path(session_dir, "session.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        return None
    if not isinstance(session, dict) or session.get("intent_id") != intent_id:
        return None
    provider = session.get("harness")
    route = session.get("route")
    if provider not in ("codex", "claude") or not isinstance(route, str) or not route.strip():
        return None
    if "KOGEN_SHAPING_ROUTE" in os.environ and os.environ["KOGEN_SHAPING_ROUTE"] != route:
        return None
    actual_revision = revision(payload, session_dir, launch_id) if callable(revision) else revision
    if not isinstance(actual_revision, str) or not re.fullmatch(r"[0-9a-f]{64}", actual_revision):
        return None
    return {
        "schema": SCHEMA,
        "root": root,
        "session_dir": session_dir,
        "intent_id": intent_id,
        "launch_id": launch_id,
        "revision": actual_revision,
        "boundary": boundary,
        "provider": provider,
        "route": route,
        "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "byte_count": len(payload_bytes),
        "payload_sha256": hashlib.sha256(payload_bytes).hexdigest(),
        "payload_base64": base64.b64encode(payload_bytes).decode("ascii"),
    }


def _write_receipt(receipt):
    if receipt is None:
        return
    path = Path(receipt["session_dir"]) / "feedback-delivery" / "receipts.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    line = (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        with os.fdopen(descriptor, "ab", closefd=False) as handle:
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(descriptor)


def relay(payload_bytes, boundary):
    if os.environ.get("KOGEN_SHAPING_SUPPRESS_FEEDBACK_OUTPUT") == "1":
        # The wrong control removes audit feedback alone. Accepted Shaper
        # answers and non-blocking Stop decisions still reach the provider.
        try:
            payload = json.loads(payload_bytes.decode("utf-8"))
            if boundary == "stop-output" and _revision_for_stop(payload):
                return 0
            if boundary == "posttooluse-output":
                output = payload.get("hookSpecificOutput", {})
                context = output.get("additionalContext", "")
                match = re.search(r"(?:^|\n\n)KOGEN AUDIT ", context)
                if match:
                    context = context[:match.start()]
                    if not context:
                        return 0
                    output["additionalContext"] = context
                    payload_bytes = (json.dumps(payload) + "\n").encode("utf-8")
        except (UnicodeError, ValueError, TypeError, AttributeError):
            pass
    try:
        written = sys.stdout.buffer.write(payload_bytes)
        sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError):
        return 0
    if written != len(payload_bytes):
        return 0
    try:
        parsed = json.loads(payload_bytes.decode("utf-8"))
    except (UnicodeError, ValueError):
        return 0
    revision = _revision_for_posttool if boundary == "posttooluse-output" else _revision_for_stop(parsed)
    receipt = _receipt(payload_bytes, boundary, revision)
    _write_receipt(receipt)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("boundary", choices=("posttooluse-output", "stop-output"))
    parser.add_argument("--producer", help="Python hook producer for PostToolUse")
    args = parser.parse_args(argv)
    if args.producer:
        if args.boundary != "posttooluse-output":
            parser.error("--producer is only valid for PostToolUse")
        completed = subprocess.run(
            [sys.executable, args.producer], input=sys.stdin.buffer.read(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if completed.stderr:
            sys.stderr.buffer.write(completed.stderr)
            sys.stderr.buffer.flush()
        return relay(completed.stdout, args.boundary)
    return relay(sys.stdin.buffer.read(), args.boundary)


if __name__ == "__main__":
    sys.exit(main())
