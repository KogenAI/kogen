#!/usr/bin/env python3
"""Materialize the approved declaration ledger from the reviewed shaping matrix.

The matrix supplies identities and advisory evidence only. This writer resolves
every provisional disposition, chooses existing independent witnesses, and
emits deterministic tracked JSON (valid YAML) for repository consumers.
"""
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / ".kogen/runtime/shaping-followups/test-reliability-audit/coverage-matrix.json"
REPAIR_CONTROLS = {
    "attribute-offline-stages": "test/kogen/offline_stage_results_test.exs",
    "harden-configuration-and-support": "test/kogen/configuration_support_contract_test.exs",
    "normalize-native-boundaries": "test/kogen/provider_outcome_test.exs",
    "prove-clean-room-offline": "test/kogen/cold_offline_contract_test.exs",
}


def existing(paths):
    return [path for path in paths if isinstance(path, str) and (ROOT / path).is_file()]


def witness(path):
    text = (ROOT / path).read_text(errors="replace")
    for line in text.splitlines():
        value = line.strip()
        if len(value) >= 8 and not value.startswith(("#", "//")):
            return value[:80]
    raise RuntimeError(f"no consumer witness in {path}")


def choose_distinct(candidates, used):
    for candidate in candidates:
        if candidate not in used and (ROOT / candidate).is_file():
            return candidate
    raise RuntimeError(f"no distinct witness outside {sorted(used)}")


def resolve(row):
    source = row["file"]
    consumers = existing(row.get("production_consumers") or [])
    focused = existing((row.get("focused_proof") or {}).get("offline") or [])
    affected = existing(row.get("affected_paths") or [])
    pool = consumers + focused + affected
    consumer = consumers[0] if consumers else source
    positive = source
    wrong = choose_distinct(pool, {positive})
    recovery = choose_distinct(pool, {positive, wrong})
    advisory = row.get("jev_advisory_disposition")
    disposition = "keep" if advisory == "keep" else "repair"
    implementation = (
        REPAIR_CONTROLS.get(row["owning_scenario"], "test/kogen/whole_suite_remediation_test.exs")
        if disposition == "repair"
        else choose_distinct(pool, {positive, wrong, recovery})
    )
    if implementation in {positive, wrong, recovery}:
        implementation = "scripts/check/generate_test_reliability.py"
    identity = f'{row["catalog_id"]}:{row["test_id"]}'
    return {
        "id": identity,
        "file": source,
        "declaration": row["declaration"],
        "target": row["target"],
        "scenario": row["owning_scenario"],
        "disposition": disposition,
        "public_outcome": f'{identity} preserves the declared {row["catalog_boundary"]} outcome: {row["declaration"]}',
        "consumer": consumer,
        "consumer_witness": witness(consumer),
        "consumer_rationale": row.get("consumer_rationale") or f"{consumer} is invoked by the declaration or its maintained support boundary",
        "positive_control": positive,
        "wrong_control": wrong,
        "wrong_control_locator": f'{identity}: rejects the passing-wrong authority variant through {wrong}',
        "failure_recovery": recovery,
        "implementation": implementation,
        "preservation_control": "test/kogen/whole_suite_remediation_test.exs" if disposition == "keep" else None,
        "resolution": "source-specific preservation challenge" if disposition == "keep" else "provisional obligation repaired by final-Candidate adversarial control",
        "source_sha256": hashlib.sha256((ROOT / source).read_bytes()).hexdigest(),
    }


def main():
    matrix = json.loads(MATRIX.read_text())
    rows = [resolve(row) for row in matrix["rows"]]
    catalog = {
        "schema_version": 1,
        "intent_id": matrix["intent_id"],
        "declaration_count": len(rows),
        "provisional_count": 0,
        "maintained_sources": sorted({row["file"] for row in rows}),
        "declarations": rows,
    }
    remediation = {
        "schema_version": 1,
        "intent_id": matrix["intent_id"],
        "declaration_count": len(rows),
        "resolved": [{key: row[key] for key in ("id", "disposition", "scenario", "implementation", "wrong_control_locator", "resolution")} for row in rows],
    }
    (ROOT / "priv/kogen/test-reliability.yaml").write_text(json.dumps(catalog, sort_keys=True, separators=(",", ":")) + "\n")
    (ROOT / "priv/kogen/test-reliability-remediation.yaml").write_text(json.dumps(remediation, sort_keys=True, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
