# Track Approved scenarios through independent Review

## Start here

Read this contract with [scenarios.yaml](scenarios.yaml), [risks.yaml](risks.yaml),
and [questions.md](questions.md). [intent.yaml](intent.yaml) owns identity,
provenance, guarded paths, appetite, and non-goals. [references.yaml](references.yaml)
links the baseline and parked feature. [The investigation](evidence/shaping-investigation.md)
records observations rather than implementation results.

The Shaper explicitly approved this package in the originating conversation with
“approved.” The directory was moved as a whole to Approved; Build has not been run.

## Outcome and boundary

Build must account for every Approved scenario throughout development, verification,
independent Review, and existing in-process rework. A passing Check or plausible
completion message cannot substitute for a complete handoff and per-scenario Review.
At acceptance, every scenario is independently assessed as satisfied for the current
Candidate, and no blocking finding remains open.

The Shaper explicitly separated Build resumption into another Intent. This feature
retains inspectable records when a Build stops, but does not reload them, resume an
exhausted Build, grant more budget, create worktrees, or change approval state on failure.
Its records are evidence, not recovery checkpoints.

## 1. The Approved contract

Retain the parsed scenarios, their order, full required behavior, wrong results,
evidence expectations, and target associations. Before provider launch, require
unique nonblank scenario IDs, nonblank existing behavior/evidence fields, and safe,
declared Make targets. Keep target execution deduplicated in first-occurrence order.

Add an optional `risks.yaml` list with `id`, `scenario_ids`, and `description`.
Every supplied risk must have a unique nonblank ID, nonblank description, and
nonempty links to existing scenario IDs. File lifecycle risks may carry `ownership`
entries with the dimensions demonstrated in this Draft's risks file. Validate the
required dimensions when that structure is supplied. Do not infer ownership or
claim that an absent risk file means the feature has no risks.

New Shaping instructions must identify important assumptions and negative controls,
link risks to scenarios, and explicitly discuss ownership whenever files are created,
installed, generated, or migrated: existing paths, immediate owner, later owner,
permitted mutation, validation, Git state, and upgrade behavior. The human settles
public behavior; unknowns remain in questions.md. Keep one owner for a shared risk
and link it to several scenarios instead of copying its prose. Existing valid
packages without risks remain buildable, with risk analysis recorded as not supplied.
Do not retrofit the parked external-repository package or historical Complete packages.

## 2. Developer handoff

Require a structured final Developer message on both initial development and exact
session rework. Use the existing JSON event stream's final completed agent message;
local validation avoids relying on a new CLI flag behaving identically on `exec`
and `exec resume`. Provider completion and session validation still happen first.
Do not turn a missing handoff into a lost session or fresh Developer launch.

The bounded handoff identifies its Build-supplied attempt token and contains:

- Exactly one entry per scenario: implementation claim, ready/incomplete status,
  implementation references, and concrete proof references or observed evidence.
- An explicit response for each supplied risk, associated with its scenario links.
- Exactly one response to every open finding: what was addressed, remains blocked,
  or is disputed, with supporting references or counterevidence.

References identify actual repository files/tests or retained evidence with a useful
locator. Structurally invalid or missing local references are not usable evidence.
Treat references as data, never commands to execute. A test name or excerpt is a
pointer for inspection, not proof that its assertions cover the whole requirement.

Build assigns Candidate, session, attempt, and package identity; the Developer must
not compute an authoritative Candidate identity or fabricate gate receipts. The
Developer can describe tests and focused observations. Check may not have run yet,
and non-check gates belong to Build, so the handoff must not require the Developer
to report successful gate execution. Build attaches actual receipts afterward.

After a matching Stop Check, validate the current handoff before Review (preferably
before expensive non-check targets). Missing, malformed, stale, incomplete, duplicate,
or unknown coverage produces scenario-addressable feedback and uses the existing
outer-resumption mechanism and budget. Do not reuse an earlier turn's message.
Every resumed attempt still needs fresh Stop settlement, a complete handoff, and
the full ordered non-check sequence before Review. No new retry allowance is added.

## 3. Build-owned record and independent Review

Use one small versioned record per Build, with attempt history, rather than a task
graph or independent planning service. Freeze the Approved package, scenario IDs,
and risks at Build start. Store claims separately from observed receipts and Review
conclusions. The record joins requirements and risk links, Developer claims and
responses, actual target outcomes, Reviewer assessments, and finding history.

Give the fresh Reviewer the full Approved package, exact current Candidate,
normalized handoff, actual verification receipts, open findings, and concise prior
dispositions. Do not give it the Developer conversation or treat claims as proof.
It reads the actual implementation, tests, and evidence, including each wrong result
and relevant ownership transitions. A schema filled with plausible text is not a
semantic pass. The Reviewer and any read-only helpers retain their existing roles.

The verdict contract requires:

- The supplied current Candidate/attempt binding.
- Exactly one assessment for each Approved scenario: satisfied or needs rework,
  with independent reasoning and concrete inspected evidence.
- Exactly one disposition for every finding open at Review start: remains open
  or closed, with evidence-based reasoning.
- New actionable blocking findings linked to scenario IDs. Build assigns their
  durable IDs after validating the response, preserving origin text, scenario,
  Candidate, attempt, and Reviewer session.

A finding may be closed because it was fixed or independently shown mistaken.
Neither route waives the Approved requirement. Developer disagreement alone cannot
close it. Nonblocking observations, if retained, are distinct from blocking findings
and cannot obscure acceptance conditions.

Validate the whole response and all bound-input integrity checks before applying
any transition. Unknown/duplicate/missing IDs, contradictory statuses, an accept
with an open/new blocking finding, or missing reasoning invalidate the verdict.
Follow the existing malformed-Reviewer failure behavior: stop visibly and preserve
state, without inventing an extra Reviewer retry loop. No partial closures occur.
Every needs-rework scenario must be explained by an open or newly opened finding.

Acceptance requires matching owned passing verification, every current scenario
satisfied, zero open blocking findings, and an unchanged Candidate and Approved
package. A top-level verdict alone is insufficient. Enforce Reviewer session
freshness relative to the Developer and all prior Reviewers in this Build.

## 4. Rework and Candidate identity

Every rework prompt carries all unresolved findings and their immutable identities,
current scenario state, and the latest handoff/Check/target/Review failure. A target
failure cannot erase findings from a prior Review. Developer claims never mutate
finding status. Preserve closed findings and their evidence as history.

Each attempt replaces current claims. Each changed Candidate invalidates previous
scenario acceptance. Every subsequent fresh Review reassesses all scenarios, so a
regression can create a new finding even if an earlier finding was closed. Even an
unchanged Candidate after a corrected handoff requires the normal fresh settlement
and Review path; no cached acceptance shortcut is added.

The Git probe found that both Candidate hashing and the Stop hook share a blind
spot: copied index flags can hide changed working-file bytes. For this bounded
feature, reject assume-unchanged and skip-worktree flags, including sparse-checkout
cases that use them, wherever Candidate identity is relied on. Apply the same rule
at initial preconditions, Stop capture, post-execution comparisons, and publication.
Refuse without clearing flags or changing the real index. Preserve deliberately
staged ignored files and existing Candidate/Approved mutation checks. Do not redesign
Git snapshotting or claim reproducibility of ignored dependencies or external services.

## 5. Retention and publication

Create a unique ignored per-Build directory under `.kogen/runtime/` exclusively,
and write the versioned record atomically at meaningful lifecycle boundaries.
Record malformed handoffs/verdicts and gate failures as failed attempts, never as
accepted findings or closure. Retain the existing owned receipts needed to explain
the history before the next attempt invalidates their active files. Do not require
`KOGEN_RAW_LOG_DIR` or publish raw conversations.

Build owns authoritative record updates. Keep expected state in controller memory
and verify the on-disk record around external role and gate execution, so ignored
record edits cannot silently manufacture acceptance. Roles read supplied snapshots;
they do not write authoritative tracking files. Persistence failure stops clearly.
This is ordinary integrity checking, not a malicious-code sandbox or crash-recovery
protocol. Runtime record lifecycle ownership is specified in risks.yaml.

On orderly exhaustion or other handled failure, leave the Candidate and Approved
package under their existing ownership. Report unresolved scenario IDs and the
record location in the failure diagnostic. Preserve prior runs rather than reusing
their directories. The record must explicitly distinguish pending, failed, and
accepted assessments so the last successful Check cannot look like completion.

On acceptance, add self-contained structured closure and concise attempt/finding
history to the Complete package, linked from its existing generated evidence.
Include the required behavior and risk descriptions or links within that package,
final implementation/evidence references, target receipts, Reviewer identities and
dispositions, and final Candidate/session identity. No required closure information
may exist only in an ignored runtime path. Use noncolliding evidence names and
preserve the existing publication/commit-failure rollback semantics for all newly
generated files. Historical user evidence is never overwritten.

## Proof and appetite

`scenarios.yaml` owns acceptance. Use the maintained async, isolated fixture
workflow in `scripts/check/README.md`; do not nest the aggregate check suite in a
lifecycle fixture or relax gate ownership to make tests convenient.

The offline matrix proves structural enforcement and transitions: missing IDs,
stale claims, omitted finding dispositions, partial repair, intervening target
failure, mistaken-finding counterevidence, Candidate regression, mutation, exhausted
budget, durable failure evidence, and final publication. Share fixtures and focused
helpers; do not build a generic planning/test framework.

Extend the existing real Shape-to-Commit and exact-session rework fixtures to
exercise structured handoffs, scenario-linked risks, fresh per-scenario Review,
and final evidence. A bounded independent real-Reviewer challenge must also reject
at least one materially incomplete but structurally complete handoff derived from
the motivating failures. The Reviewer is asked to assess the contract, not told to
reject, and the verdict is not supplied by the test. Deterministic controls cover
all three motivating failure patterns and a corrected counterpart. These may use
small controlled stand-ins; do not restore or implement the external CLI feature.

This fits one Build by extending the current parser, loop, and evidence publication;
use small modules as needed for schema/state logic. It does not require per-scenario
provider sessions, per-scenario gate reruns, recovery state loading, new public
commands, or a rewritten verification runner. A real negative control demonstrates
independent judgment on that case; structured coverage is never presented as a
guarantee against all model mistakes.
