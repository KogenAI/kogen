# Build 9TbQ: current repair amendment

Authority: in the same conversation after approval, the Shaper reported this
failed Build and explicitly requested “be quick / fix Intent and then let's build
again”. This amendment clarifies existing requirements only; it does not bypass
clean-worktree admission, change retry budgets, authorize production edits in
Shaping or claim acceptance. Prior approval and provenance are preserved.

## Observed settlement

Source: .kogen/runtime/scenario-tracking/9TbQ-AZ3C1qfOjhn-yZOZLIZ/record.json,
attempt 0 verification.cycles. Three Stop cycles each passed check; final check
reports 307 passed. Live results were 8/9, 7/9, 7/9. Verification exhausted before
outer Review; twelve unresolved scenarios are unaccepted coverage, not twelve
separate failed assertions. MCP startup and failed patch messages supplied by the
Shaper are not the recorded terminal cause.

Cycle 1: compatibility interactive marker true but cleanup false.
Cycle 2: compatibility Developer timed out (exit 124); shaping evaluation rejected
csv-continuation because partial assent failed to preserve the remaining output
replacement question (suite-failure.json in shaping-evaluation-1789414724164-578).
Cycle 3: compatibility failed missing_check_history / enoent. Connected Shape
fixture timed out waiting for its Draft. The seven-case evaluation passed in that
cycle, as did native helper, semantic Review and Build-only rework owners; these
are historical results for their Candidate, not cached acceptance for a repair.
Final Candidate: 43c1c318de26f530c47a98158b431c395f897075.

## Required focused repairs before full live verification

1. Compatibility fixture must own its verification context and history. Current
   compatibility.ex copies the new stop_runner.py but check_history/1 still reads
   fixture/.kogen/runtime/verification-history.jsonl. stop_runner.py load_context
   gives inherited KOGEN_VERIFICATION_CONTEXT precedence and refuses a foreign
   project_root before writing that history. Inspect and eliminate outer-Build
   context leakage at the fixture boundary, not by disabling integrity checks.
   Explicitly select the bounded fixture's own verification mode/state and pass
   the same identity to its Stop, resume and history consumer. Never clear context
   in the actual production Developer or fabricate passing history. Demonstrate
   through the actual fixture owner with a hostile inherited outer context and
   a valid private context control; assert failed then passed same-session history,
   no outer-state mutation and no recursive live target. This is source-supported
   cause investigation; the exact missing-file cause has not yet been reproduced.
2. Connected Shape input delivery must be acknowledged, not inferred from send.
   shape_to_build_probe.exp sends the directive, pumps one second, then sends CR
   while startup can still be working. The retained final failure displays the
   directive as “[Pasted Content 1773 chars]” in the composer, then the Shaper asks
   which feature to shape. This supports an unsubmitted-input race; it does not
   prove every timeout has that cause. Bind readiness/submission to the actual
   native input turn before waiting for Draft files. Use deterministic delayed
   startup/large-paste controls, preserve exactly-once input, no accidental approval,
   bounded cleanup and real public Shape/continuation. Do not merely raise timeout.
3. Preserve the observed cycle-2 partial-assent semantic failure and the earlier
   cleanup failure. Do not weaken either oracle or call a later pass proof that
   the failure cannot recur. Existing shaping partial-answer requirements and PTY
   cleanup obligations apply; retain actionable current case-level diagnostics.

Current Stop owns all declared verification; the outer fixture driver owns
interaction auditing, not target scheduling. Current schema-bound handoffs,
seven-case evaluation and bounded publication remain mandatory. Prior old split
Stop/outer wording in historical repair notes must not restore obsolete behavior.
No gate rerun or production repair was performed by this inspection.

## Next Build starting state

Keep the clean-worktree admission check. Preserve the failed implementation as a
new named stash or other user-owned snapshot before a fresh Build; the latest
working implementation is newer than the previously recorded e3d993f3 stash.
The Developer should reuse that preserved implementation selectively against current
main, with these focused repairs and unchanged gates. Do not apply a stash into an
active Build externally or overwrite the current tree with the older stash. This
note does not perform stash, reset, restart or source writes.

## Authorized retry input

The Shaper stashed the failed implementation and directed “stashed / let's go”.
Read-only inspection confirms clean main/d3a1582cd937c884589cf72d1264f5e9c5305827
and exact new stash e3aa30baa8397c6f05bc842c5cbee67db004ea46 (stash@{0} at
inspection). This supersedes e3d993f3 as the implementation reuse input. The
Developer is authorized to restore and adapt this exact failed-work snapshot
within approved paths, preserving current-main verification and handoff contracts,
and complete the focused repairs above before normal Stop verification. It is
unaccepted implementation, not passing evidence. Do not select by mutable stash
index, drop the stash, use the separate Reconnect stash, or bypass admission.
The controller interpreted “let's go” as launch authority, but the Shaper
immediately clarified: do not start Build; only record the situation and code
source in the Intent. That correction controls. The accidentally launched Build
was terminated with its owned descendants; the worktree remained clean. No
acceptance is claimed and no further Build is authorized here.
