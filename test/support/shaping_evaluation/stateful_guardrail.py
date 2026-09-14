#!/usr/bin/env python3
"""Tiny source-owned stateful guardrail fixture used by shaping evaluation."""
import argparse
import json
from pathlib import Path
from datetime import datetime, timezone


def _read(path):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _write(path, value):
    Path(path).write_text(json.dumps(value, sort_keys=True) + "\n")


def dispatch(state_path, action_path, receipt_path, *, passed=False, complete=False):
    state = _read(state_path)
    # Complete control rejects malformed and exhausted state before dispatch.
    if complete and (not isinstance(state, dict) or state.get("failures") is None or
                     state.get("failures", 0) >= 3):
        return {"ok": False, "continue": False, "dispatched": False,
                "reason": "invalid-or-exhausted-state"}
    # Flawed control treats damaged state as a new state and checks exhaustion
    # only after its observable action.
    if not isinstance(state, dict):
        state = {"failures": 0}
    action = _read(action_path) or {"count": 0}
    action["count"] = int(action.get("count", 0)) + 1
    _write(action_path, action)
    failures = int(state.get("failures", 0))
    if passed:
        _write(state_path, {"version": 1, "failures": 0, "history": state.get("history", [])})
        emit_receipt(receipt_path, complete=complete)
        return {"ok": True, "continue": False, "dispatched": True, "failures": failures}
    failures += 1
    history = list(state.get("history", []))
    history.append({"result": "failed", "failures": failures})
    _write(state_path, {"version": 1, "failures": failures, "history": history})
    emit_receipt(receipt_path, complete=complete)
    return {"ok": False, "continue": failures < 3, "dispatched": True, "failures": failures}


def emit_receipt(path, *, complete=False):
    receipt = {"ok": True, "result": "passed"}
    if complete:
        receipt["finished_at"] = datetime.now(timezone.utc).isoformat()
    _write(path, receipt)


def consume_receipt(path):
    value = _read(path)
    if not isinstance(value, dict) or not isinstance(value.get("finished_at"), str):
        return {"accepted": False, "reason": "missing-finished_at"}
    try:
        datetime.fromisoformat(value["finished_at"].replace("Z", "+00:00"))
    except ValueError:
        return {"accepted": False, "reason": "invalid-finished_at"}
    return {"accepted": True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("flawed", "complete"))
    parser.add_argument("state", type=Path)
    parser.add_argument("action", type=Path)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--passed", action="store_true")
    parser.add_argument("--consume", action="store_true")
    args = parser.parse_args()
    if args.consume:
        result = consume_receipt(args.receipt)
    else:
        result = dispatch(args.state, args.action, args.receipt, passed=args.passed,
                          complete=args.mode == "complete")
    print(json.dumps(result, sort_keys=True))
    return 0 if result.get("ok") or result.get("accepted") else 1


if __name__ == "__main__":
    raise SystemExit(main())
