# Current failed-Build audit and repair requirements

This is the current entry point. It updates September 13's operation-lifecycle
plan with actual evidence from Build `2xt-TMNZy1whWx2BaSUeGw0y`. The Shaper
supplied the failure and requested a more thorough investigation. This is an
in-scope repair amendment, not scope expansion or new approval. Original identity,
provenance, continuation history, scenarios, risks and gates remain unchanged.

## Attempt history matters

The controller record under `.kogen/runtime/scenario-tracking/` records:

- Attempt 0, Candidate b4cde5807eb21a92bf3078a364c163aa28f97b18: Check passed,
  286 offline tests; live 7/9. Helper receipt validation and semantic Review failed.
  Five-case shaping and the bounded compatibility case passed in that attempt.
- Attempt 1, Candidate 2e82759b4fee33a5f2b2a1a55931daa1cabbddf9: Check passed;
  invalid handoff statuses consumed a resumption without live execution.
- Attempt 2, same Candidate: Check passed, live 4/9; budget exhausted. No
  accepting outer Review. A schema-valid ready claim does not establish readiness.

The target record retains only an output tail. The five failure explanations below
combine it with current source and owned case artifacts; the rework and
compatibility explanations are reconstructed from those artifacts, not quoted
from an unavailable complete ExUnit report. Nested acceptance is not outer-test
acceptance. The command timing list alone does not identify failing tests.

## Five failure paths

### Semantic Reviewer: missing hook dependency, not slow generation

`test/kogen/live_test.exs` setup_fixture copies hooks.json, check.sh and the gate
guard but omits the new environment.py dependency. check.sh invokes environment.py
when restoration is pending, before its non-Developer role bypass. Both retained
semantic runs contain many completed verdict messages and no terminal turn.
The latest native session contains 40 repeated Stop hook prompts reporting the
missing fixture-local environment.py. This explains the 600-second loop; the
first attempt's 900-second allowance also failed. Tool executions had completed.
Do not raise timeout again or blame provider capacity for this observation.

Repair fixture materialization of the complete hook dependency set. Exercise the
actual copied hook under managed Reviewer and Shaper environments before provider
work, asserting successful bypass, no Check execution and no output mutation.
Keep Developer hook/Check restoration controls. Audit other selective fixture
copy lists for the same dependency. Do not disable hooks to make the fixture pass.

Evidence roots: live-evidence/primitives-83058-771-1789331786838428000 and
live-evidence/primitives-33069-858-1789333004380344375 under `.kogen/runtime/`.
Private raw conversations remain there; only the diagnostic observation is retained here.

### Five-case continuation: midnight environment update breaks correlation

The final suite root `.kogen/runtime/shaping-evaluation-1789333004295-578` retained
four completed case receipts; csv-continuation exceeded the deadline. Its first
scripted reply exactly matches a native user message, and that turn completed.
A native midnight environment-context message intervened before completion.
The actual integrity validator rejects this with `native user intervenes before
completion`, which driver.user_turn_terminal converts into a wait until timeout.
This is not evidence of an unfinished model response or the old receipt collision.

Repair native event classification with source-supported transport metadata and
retained cases. Preserve exact submitted-text/turn/completion binding, rejection of
real intervening human turns, duplicates, reordered events and forged/misbound
terminals. Do not broadly discard arbitrary user text containing environment tags
or weaken correlation to completion counts. Distinguish known invalid correlation
from an incomplete stream so a permanent failure can emit an actionable receipt.
Rehearse the midnight update against the actual consumer plus genuine intervening
user negative controls. The existing failure and controls remain evidence.

### Native helper: actual spawn calls omit required kinds

The final native-helper receipt retains correct task answers and models/efforts,
but requested_kind is null for all three children. Inspection of actual spawn call
argument keys confirms agent_type was absent; this is not merely collector lookup
of an existing field. Restored assertions correctly reject it. The prompt requests
explorer/worker/default, but prompt text is not executed routing evidence.

Resolve the exact managed runtime's exposed spawn schema/configuration and collect
a bounded real routing proof before claiming readiness. Missing arguments alone
do not prove unsupported capability. If the exact runtime cannot express the
accepted kinds, this is a consequential compatibility conflict for the Shaper,
not permission to infer kinds from task names, synthesize fields or drop assertions.
This capability question remains unresolved by this audit; no paid probe was run.
Evidence: `.kogen/runtime/live-evidence/native-helper-33071-818-1789333004339889125/`.

### Compatibility: control evidence is ambiguous to its Reviewer

Latest `~/Library/Application Support/Kogen/codex/compatibility/compatibility-1789333004647-2/evidence.json`
reports failure because its final internal Reviewer interpreted the hostile control
as an isolation violation. Actual discovery.json includes hostile_* true alongside
safe_* absence/visibility controls and ok=true; the outer hostile_discovery summary
also reports personal_marker=false and project_marker=true. The prior attempt's
compatibility run passed. Do not treat this as proven personal configuration leakage.

Give hostile-positive and isolated-negative observations explicit separate ownership
and labels, with tested field semantics and a Reviewer contract explaining which
execution each observation describes. Bind each to its source/runtime invocation.
Preserve independent judgment and controls which make an actually contaminated
isolated run fail. Do not instruct Review to accept or hide the hostile evidence.

### Reviewer-rework fixture: accepted nested Build, wrong controlled sequence

The retained nested record under live-evidence/shape-to-build-32942-2634-1789333003245289250
shows an invalid initial handoff referencing nonexistent reviewer-notes.md, followed
by actual Review rework and acceptance. This used two resumptions. The existing
LiveReworkAudit requires exactly one for the intentionally controlled first-Review
then same-Developer repair sequence and rejects this evidence before profile audit.
The fixture explicitly already tells the Developer to cite existing files while
reporting the intentional omission. Inspect generated handoff construction and
preserve a negative control for nonexistent references; strengthen the bounded
fixture's concrete first-phase evidence guidance. Do not relax the sequence or
budget simply because its nested Build eventually accepted.

## Why the previous repair plan was still insufficient

It correctly identified earlier integration defects but did not audit the complete
copied hook artifact, native injected-message behavior and positive/negative receipt
meaning. An offline rehearsal that fabricates only the expected native event shape
cannot catch these producer/consumer mismatches. Preserve the observed native shapes
as minimal nonprivate fixtures, with contradictory controls. Repeated full Builds
must not substitute for these deterministic checks. Current source repairs need
focused evidence, not handoff claims that merely restate requirements.

## Executed proof and next acceptance

[Focused probe](prototypes/final-attempt-audit/README.md) reproduces missing hook
exit 2 and proves copying its dependency yields successful Reviewer bypass with no
Check. It feeds the real retained continuation into the actual integrity consumer;
the original rejects, while a synthetic removal of environment updates binds the
reply to its completed turn. That removal is diagnostic, not a proposed production
filter. The first import attempt lacked required KOGEN_SHAPING_EVALUATION_RUNTIME
and failed before execution; the corrected invocation supplied the actual run root.
No provider or aggregate gate was invoked, and no source/test/configuration changed.

Next Developer work must first repair and demonstrate these deterministic paths
using focused non-gate tests, resolve native kind capability with actual evidence,
and retain case-level failure receipts. Then the unchanged Stop-owned Check,
outer-owned live sequence and independent Review establish acceptance. Prior
passing cases are historical source-bound evidence, not substitutions for current
required gates. No extra resumptions, generic provider recovery or public command
is added. The September 13 lifecycle plan remains applicable where not superseded.
