# Latest Build: compatibility denial evidence mismatch

Source: Shaper's subsequent failed Build report and structured tracking record
`.kogen/runtime/scenario-tracking/LH0_47I16M3fvbteM3l3x5co/record.json`.
All three attempts passed Check and 7/8 live tests. Only the managed runtime
compatibility test failed. No top-level accepting Build Review was reached.

Attempts 0 and 1 failed interactive Shaping's response marker check, with cleanup
true and marker false. Attempt 2 progressed through that stage and failed the
generic incomplete_compatibility_evidence predicate.

Final fixture: Kogen's local codex/compatibility/compatibility-1789053783386-322.
An independent read-only helper traced its sole false top-level predicate to
blocked_gate. Root/helper/hook HOME/XDG, login/non-login and explicit-shell
controls, discovery isolation, exact resume and internal final Reviewer acceptance
were present. Thus the final named stdio route has real integration evidence;
this is not evidence that all twelve listed scenarios independently failed.

Current compatibility.ex blocked_gate?/1 serializes developer.events and searches
for the exact text “Kogen machinery owns verification gates”. The final live output
records an actual native PreToolUse denial at 15:23:32.302553Z for make check,
but that denial is absent from the searched Developer JSON events. The Developer's
own report and absence of executed-command events alone would not prove a block;
the separately captured native diagnostic is the stronger evidence here.

Repair the collector to retain authoritative denial evidence bound to the current
fixture/session/attempt. Do not count the model repeating expected words as proof,
accept stale receipts, or mark blocked_gate true by default. Add focused controls
for a real denial emitted outside stdout JSON, an allowed gate, missing evidence,
forged model text and stale evidence. Then exercise the current compatibility path
before recommending another full Build; preserve normal gate ownership.

Other drafts are not prerequisites for this repair. outcome-complete-shaping
addresses future shaping behavior; continue-exhausted-builds reduces future restart
friction but explicitly excludes legacy stopped-Build import and has unresolved
choices. Delegation/output-style work does not repair this collector. Preserve
parked same-build-refresh and external-repository-cli conditions.
