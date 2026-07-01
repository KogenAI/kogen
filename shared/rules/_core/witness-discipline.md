# Witness Discipline

A gate FAILED handed to the next agent with no located cause is a defect.

## Rule

Every FAILED verdict MUST carry a **witness**: `file:line — <verbatim cause>` extracted from the gate log. Bare "it failed + 40-line tail" is insufficient — the next agent must not re-derive the location.

- Producer: the loop's gate step (`LoopGate.run_gate`, shelling `gate-select.sh`/`gate-result.sh`) writes `gate-result.json`. FAILED branches compute `extract_witness "$log_path"` (opaque exit≠0) OR pass the already-known reason (runner-missing, no-op, wiring/render FAIL) via `gate-result.sh`'s `write_gate_result` witness argument. Threaded into `gate-result.json` `witness` field + `Witness: <x>.` block-envelope prefix when non-empty.
- Contract: `extract_witness` is fall-open-empty — no located cause → empty witness, gate still proceeds, tail still present. Absence of a witness NEVER blocks; presence enriches.

## Consumers

- **Developer**: on a FAILED gate, read the `Witness:` first — it points at the exact failing location. Fix there before re-running.
- **Reviewer**: a FAILED handed onward without a witness (when the log was parseable) is a gate defect — flag it.
- **The loop**: route the witness verbatim to the next role's delegation prompt; never strip it to a bare "gate failed".

## Why

Witnesses turn an opaque red gate into an actionable pointer — the located cause travels WITH the verdict, not buried in a log the next agent must re-parse.
