# Identify invalid Build handoff and Review entries

Approved by the Shaper in this conversation on 2026-09-13. Start here; scenarios.yaml owns acceptance, intent.yaml owns identity, scope exclusions and allowed paths, risks.yaml owns the shared compatibility risk, and questions.md owns unresolved UX choices. evidence/ contains the baseline probe and investigation notes.

## Problem and smallest useful change

One directory reference currently produces the same full-roster coverage error as missing, duplicate and unexpected IDs. The Developer cannot tell which entry to repair. Improve the existing error strings for the five collections sharing validate_exact: handoff scenarios, risks and findings; Reviewer scenarios and dispositions. Diagnose invalid fields and reference causes within these entries. New Reviewer findings without IDs and other validation families remain outside this small slice.

## Diagnostic behavior

Collect all independently detectable errors in one response across the five in-scope collections, their entries, fields and references. Do not stop at the first bad collection, entry, field or reference. Use deterministic ordering, one-based positions, entry IDs where available, the offending field/path and a concrete explanation. Duplicate IDs also need positions so the entries are distinguishable. Preserve the existing error-string return interface; no new response schema is required.

Example diagnostic item: `handoff scenarios: entry two, evidence[1], path "lib": expected a regular file; found directory`. Coverage diagnostics distinguish missing, duplicate and unexpected IDs. Exact punctuation is an implementation detail; the specified information is required.

When malformed structure makes a dependent check impossible, explain the structural failure without inventing cascading errors. Continue checking independent siblings and other usable collections. For example, a non-object entry gets a position-based structural error, not fabricated missing-field messages; a non-list evidence field gets a shape error, not invented reference failures. A malformed collection must not become a fabricated missing-ID roster. Preserve existing binding and envelope preconditions; this scope does not require interpreting entries from an unparseable response or stale binding, or extending diagnostics to the explicitly excluded validation families. Run whole-verdict consistency checks only when their structural prerequisites are valid. Do not display arbitrary claim/evidence contents as a substitute for a reason.

The Shaper selected aggregation and one-based positions through the supplied screenshot in this conversation on 2026-09-13. This settles the diagnostic choice, not approval of the Intent.

## Delivery and verification

Contract.handoff errors already flow through Build.rework into the failed attempt, then the resumed Developer receives a record locator. Contract.verdict errors flow into the stopped Build result and attempt failure. Preserve these routes, schemas, two-resumption budget and gate ownership. Changes to build.ex are allowed only if necessary to preserve delivery of the diagnostic; no state-machine redesign.

Use the existing offline contract and scenario lifecycle fixtures under check. Require the fake resumed Developer to inspect the previous failed attempt and assert every independently detectable diagnostic before repairing; a canned successful second response is insufficient. For malformed Review, verify stopping, retained findings and no publication. No paid live gate is proposed for this deterministic diagnostic repair. Independent Review remains required by normal Build.

## Boundaries and provenance

This Draft is based on the supplied clean accepted HEAD. The older serial index's “context currently shaping” status is stale: this HEAD contains the completed file-discovered-role-context Intent. Its historical old-engine blocker does not establish a blocker for this slice. The source report was advisory inspection, not an execution receipt. This session's direct probe reproduced the diagnostic defect against the current checkout without modifying product source. No implementation or end-to-end acceptance has been claimed.

The older combined Draft and runtime evidence remain preserved. This proposal extracts the diagnostic defect from proposal 03; it does not transfer or cancel the other combined Draft requirements. Ordinary source and private fixture handling follows existing repository conventions and the proposal's explicit instruction; no new persistent file lifecycle is proposed.
