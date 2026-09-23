#!/usr/bin/env python3
"""Rebind the test-reliability ledger to reviewed test sources.

After a reviewed change edits a cataloged test file, its declarations keep
their identity, disposition and controls; only `source_sha256` is refreshed.
Usage: refresh_test_reliability_sources.py [--check]. With --check, report
stale bindings and consumer witnesses without writing.
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "priv/kogen/test-reliability.yaml"


def main(arguments):
    check = arguments == ["--check"]
    catalog = json.loads(CATALOG.read_text())
    stale, witnesses = set(), []
    for row in catalog["declarations"]:
        digest = hashlib.sha256((ROOT / row["file"]).read_bytes()).hexdigest()
        if digest != row["source_sha256"]:
            stale.add(row["file"])
            row["source_sha256"] = digest
        consumer = ROOT / row["consumer"]
        if not consumer.is_file() or row["consumer_witness"] not in consumer.read_text(errors="replace"):
            witnesses.append(row["id"] + ": " + row["consumer"] + ": " + row["consumer_witness"])
    for path in sorted(stale):
        print("stale source binding: " + path)
    for line in witnesses:
        print("missing consumer witness: " + line)
    if not check:
        CATALOG.write_text(json.dumps(catalog, sort_keys=True, separators=(",", ":")) + "\n")
    return 1 if check and (stale or witnesses) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
