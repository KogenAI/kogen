# Shaping evidence and limits

## Incident and completed repair

[Cleanup receipt](cleanup-receipt.json) records the two exact original record sizes/hashes, commit mappings and changed paths. [Outgoing size check](outgoing-size-check.json) records the repaired two-commit pack: 1,158,672 bytes; largest remaining outgoing blob 2,641,509 bytes. This reused successful observation concerns the authorized historical repair only. No push occurred. Full originals remain outside Git at the local archive referenced by references.yaml; do not import them here. The archive is not required for the later Build tests.

The original HEAD was 8ec5495872e92b6e1313b1565221d170303e59e1; current inspected HEAD is aef8b98a1c9356516f914bd649dd6ecdae956f4d. Source/config/tests are identical across the repair. Source hashes bind the inspected maintained inputs.

## Source-linked probes actually executed

Inputs/tools: installed Elixir and Jason bytecode, current tracking.ex source, Python 3 and local Git. From the repository root, `python3 .kogen/intents/drafts/bound-build-evidence/evidence/run-probes.py` executed [probe.exs](probe.exs), compiling current Tracking in memory only. No Mix compilation, gate, provider or source/config change occurred.

[Tracking receipt](tracking-probe.json) includes exact argv/cwd/source digest, stdout, stderr and exit. Actual Tracking.new/start_attempt/update/apply_verdict persisted three bounded synthetic attempts with record citations: 5,772 → 71,757 → 870,914 bytes. Fixed-artifact control: 912 → 1,501 → 2,090 bytes. Both rejected outside record mutation. The probe models Build's observed two-field snapshot update and calls actual Tracking; it does not execute private Build.snapshot_references, publication, provider behavior or the proposed solution. It establishes a concrete growth mechanism, not the precise composition of the historical 1.86 GB record. No claim is made that the future publication fix reduces runtime growth.

[Git receipt](git-probe.json) demonstrates in an owned real Git fixture that normal staging excludes ignored runtime bytes, but `git add -f` places a 4,096-byte runtime blob in the staged tree. Actual `write-tree`/`ls-tree -rlz` exposes its path and full uncompressed length. This is a valid paired control for why ignore rules are insufficient; it does not prove a not-yet-implemented Kogen size guard. Both probes passed first execution; no failed/invalid run was replaced.

All disposable probe trees were removed after success; inputs and small receipts remain. The script uses an exclusive work path and bounded subprocess timeouts. For a new authorized experiment, copy scripts into a fresh owned package, adjust its root resolution if needed, run once and retain new failures before considering correction. Do not overwrite these source-bound receipts for a fresh success. On failure, inspect the retained receipt and owned probe-work tree; clean up only that experiment's paths after investigation. Complete means observations and limitations are retained, not future scenarios passed.

## Reading coverage and consumer correction

Root read README/config/Makefile, publication and rollback, Candidate/staging, exact tracking authority, Reviewer evidence instructions, the parked proposal and critical lifecycle assertions. A configured native read-only scout (gpt-5.6-luna, low) mapped offline/live full-record consumers. Its initial inference that evidence must remain committed was checked and rejected: deleting original target artifacts does not delete the self-contained runtime record. Its bounded follow-up traced actual live retention; root checked relevant source bytes.

Observed consumers: scenario_lifecycle_test.exs:210–305 inspects role snapshots and uncited artifacts through full Complete records; live_rework_audit.ex:121–151 parses attempts/schemas; live_shape_to_build_test.exs:554–564 copies Complete and full runtime records to per-run logs before fixture deletion. These require coordinated locator/digest and retention updates. Related lifecycle, settlement, commit-failure and live audit fixtures belong in affected check coverage even if their filenames do not change.

Evidence ownership: Build owns current record/receipt integrity; target owner retains required artifacts; outer live driver alone observes ephemeral sequence and exports evidence before cleanup; independent Review reads retained artifacts and actual Candidate. A summary is not independent evidence of behavior.

No check/live target was run during Shaping. Root/helper token accounting is unavailable, not zero. No changes to maintained files were made while authoring this Draft.
