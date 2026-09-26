#!/usr/bin/env python3
"""Offline fake Reviewer helper for per-launch verdict schemas.

Usage: fake_ledger.py SCHEMA_FILE < verdict.json > verdict.json

When the launch schema requires a verification-surface `ledger`, adds one
disposition per ledger path. FAKE_REVIEW_LEDGER is a JSON object mapping a
path to its disposition; any other path gets FAKE_REVIEW_LEDGER_DEFAULT, or
`justified: <first scenario id>`. FAKE_REVIEW_LEDGER_SKIP=1 omits the first
item (a malformed verdict control). Without a ledger the verdict is unchanged.
"""
import json
import os
import sys

schema = json.load(open(sys.argv[1]))
verdict = json.load(sys.stdin)
ledger = schema.get("properties", {}).get("ledger")
if ledger:
    paths = ledger["items"]["properties"]["path"]["enum"]
    chosen = json.loads(os.environ.get("FAKE_REVIEW_LEDGER") or "{}")
    scenario = (verdict.get("scenarios") or [{}])[0].get("id", "unknown")
    default = os.environ.get("FAKE_REVIEW_LEDGER_DEFAULT") or "justified: " + scenario
    entries = [{"path": path, "disposition": chosen.get(path, default)} for path in paths]
    if os.environ.get("FAKE_REVIEW_LEDGER_SKIP") == "1":
        entries = entries[1:]
    verdict["ledger"] = entries
print(json.dumps(verdict))
