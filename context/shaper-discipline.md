# Shaper Discipline Domain

Shape mode is the investigative, readiness-gating mode for pitch authoring. The shaper's job is to drive a pitch from skeleton (raw user input) through investigation to "shaped" status (fully designed, ready for development). This document covers shaper-specific rules and decision patterns not covered elsewhere.

**Key reference**: `shared/prompt-fragments/_authoring-spine.txt` contains the executable spine rules (Rules A–J); `harnesses/shared/prompt-bodies/shape.txt` contains the readiness-check procedure and blocker templates. Both are baked into the shape system prompt at install time via `make install`.

## Core Shaper Rules

| Rule | Name                     | Behavior                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A    | Intent-guard             | Every AskUserQuestion option must preserve the pitch's core intent. FORBIDDEN: options that would nullify the stated goal. Auto-narrow coverage instead.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| B    | Plain-language           | Suppress internal shorthand in user-facing prose. Describe what something does. Exception: protected literals (code, errors, MUST/NEVER/FORBIDDEN, gate markers) stay verbatim.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| C    | Command-pairing          | A claude-X launcher auto-includes its pi-X counterpart. Answer to "should I cover both harnesses?" is always yes. Never ask.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| D    | Duplication-detection    | During Phase-0 blast-radius scan, grep for equivalent logic elsewhere. If found, EXTRACTION (consolidate at existing site) is the default, never duplicate. Auto-decide without asking.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| E    | Symptom-vs-target        | When user names both SYMPTOM (bad behavior) and TARGET (thing to improve), TARGET is the investigation subject. Probe symptom ONCE to confirm origin, then pivot. Never let symptom-chasing displace target investigation.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| F    | Context-drift auto-cover | When Phase-0 reveals a `context/*.md` file that disagrees with codebase state, auto-include that file in edit surface. Never ask whether to update it; including it is automatic.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| G    | Decompose-then-split     | When a problem is too large for one focused build pass, shaper SPLITS into N independently-buildable pitches ITSELF. Never asks the user "should I split?" or "how?". Splitting is an engineering decision the shaper makes by reading code. Chat line: `Decomposed: extracted pitches <slug-1>, <slug-2> …`. The ONLY split question that reaches the user is a genuine product fork (feature A vs feature B).                                                                                                                                                                                                                                                                                                                 |
| H    | Derive-and-write edges   | When splitting, shaper DERIVES build-order by reading what each pitch consumes from others, and WRITES `Blocks-on: <slug>` lines into each pitch's `## Dependencies` block. Dashboard topo-sorts but NEVER infers — omitted edges silently mis-order. Never ask "what depends on what?"; read code and derive. Every split MUST have correct `## Dependencies` blocks.                                                                                                                                                                                                                                                                                                                                                          |
| I    | Ask-vs-decide classifier | Ask the user ONLY when the answer changes what they experience or names something they own. Test: "Does the answer change what the PRODUCT DOES for an end user or downstream developer — a genuine build-A-vs-build-B fork where the choice depends on intent the code cannot reveal?" If no → auto-decide from code + convention. Engineering-completeness (install-guarantee, fail-closed-when-guaranteed, internal naming, split mechanics, which tool/model/library, which machine/environment, how to transcribe/build/process input, what a pitch commits to, directory/file placement, how to split, naming) is NOT a user decision → auto-decide and record as `Assumed: <dimension> = <default> (override if wrong)`. |
| J    | Deferral-with-draft      | Every deferral (deferred, future work, phase 2, out of scope, accepted risk) MUST be backed by a real `codegen/pitches/draft/<slug>.md` file. Prose-only deferrals are blockers. Security/safety deferrals (auth, access control, secrets, data deletion) must additionally state the exposure assumption the deferral rests on.                                                                                                                                                                                                                                                                                                                                                                                                |

## Ask-vs-Decide Classifier (Rule I)

The classifier narrowed significantly in the `shape-ask-only-ux-questions` hardening to eliminate over-escalation to user questions.

**Rule I parallel-case coupling**: Changes to ask-vs-decide discipline MUST touch both context/shaper-discipline.md (this file) AND context/harnesses.md § Shaper ask-vs-decide classifier — they are Rule-J parallel siblings carrying the same classifier logic. Editing one without the other creates silent drift that the next context-curator pass will flag.

**User decisions** (ASK):

- UX copy, flow, or behavior the user will see or interact with
- Product-intent forks where both branches are defensible and the choice depends on business priority
- Naming or identity the user controls or names

**Auto-decide** (NEVER ask; record as `Assumed:` in end-summary):

- **Install-guarantee**: Does the setup/install provide a dependency the feature requires? Always yes.
- **Fail-closed-when-guaranteed**: Fail-closed or fail-open when the requirement can be guaranteed? Always fail-closed once guaranteed.
- **Internal naming convention**: Which internal naming pattern? Follow existing repo convention.
- **Split mechanics**: How should a large problem be decomposed into separate pitches? Shaper reads code and decides.
- **Which tool/model/library to use**: Shaper picks from code + convention; never ask.
- **Which machine/environment to run on**: Shaper picks from context; never ask.
- **How to transcribe/build/process input**: Getting raw material into readable form is the shaper's own engineering problem; never ask.
- **What a pitch commits to**: Pitch scope is derived from problem + code; never ask.
- **Directory/file placement**: Follow existing repo convention; never ask.
- **How to split**: Engineering decomposition decision; shaper reads code and decides.
- **Naming**: Follow existing repo convention; never ask.
- **Engineering-completeness dims**: Any dimension where code + convention reveal a sensible default and no user-visible behavior hinges on the choice.

**Decision tree for a blocker that might be a user question**:

1. Does the answer change what the user experiences (sees, hears, types, receives)?
2. Does the answer name something the user owns or controls?
3. Is there a sensible default from code + convention?

If 1 or 2 is yes AND 3 is no → ask. Otherwise → auto-decide and record the assumption.

**Standing always-ask carve-out**: user-facing surface removal/change is the single class that is ALWAYS a product fork — see § Operator-Owned Surface Changes.

## Operator-Owned Surface Changes

Removing or changing an operator-typed/seen surface — a CLI flag, subcommand, command name, prompt/output contract, or workflow step — is the operator's decision, surfaced via `AskUserQuestion`, NEVER auto-decided as "internal wiring" even when a new implementation makes the old wiring redundant. This generalizes the `--queue` incident, where the shaper auto-decided a user-facing flag removal as "internal wiring the new code replaces" without asking.

**Detector**: any DELETE/replace move naming a launcher/command file (`*-build.sh`, `ocg`, `codegen-*`, a slash-command `.md.j2`) OR a flag/subcommand token (`--<flag>`, a positional subcommand) → the `## What stays the same (external contract)` section MUST enumerate that surface's disposition.

**External-contract completeness sub-rule**: the external-contract section MUST enumerate EVERY operator-facing surface the affected launcher/command exposes (every flag, subcommand, output contract), not just the primary ones. A touched-but-omitted surface is treated as an unreviewed UX change → blocker.

**Resolution**: BLOCKED from SHAPED/ready unless (a) the surface is guaranteed re-wired to the new implementation and enumerated in the external-contract section, OR (b) an `AskUserQuestion` keep-vs-remove fork is resolved by the operator. The shaper may NEVER auto-decide the removal as "internal wiring the new code replaces."

**Coverage**: this rule is enforced at three points — the shape-mode readiness-check scan list (`harnesses/shared/prompt-bodies/shape.txt`, self-contained since shape.txt is baked without `_authoring-spine.txt`), the inline claim-introduction probe (`shared/prompt-fragments/_probing.txt`), and the `/ready` promotion gate (`harnesses/claude/commands/ready.md.j2`). All three carry the byte-identical sentinel title `User-facing surface removal/change without operator sign-off`, asserted by `harnesses/claude/hooks/prompt-content-parity_test.sh`.

## Answered-Question Memory

Before composing ANY AskUserQuestion, the shaper scans the conversation history for whether the user already answered — or DEFLECTED — this question or an equivalent one.

**Deflection = binding answer**: phrases like "who knows", "maybe many", "you decide", "why are you asking?", "doesn't matter" mean the user declined to decide → shaper auto-decides and does NOT re-ask.

**Re-ask rule**: a question already answered is NEVER re-surfaced, including on any review/confirmation screen. Only a genuinely-new, never-touched product fork qualifies for AskUserQuestion.

**Enforcement point**: this scan runs BEFORE generating question text, not after. If the conversation already contains the answer (or a deflection), the shaper auto-decides and moves on silently.

## Cold-Start Raw Multi-Source Material

When the user arrives with raw material implying MANY pitches — an audio recording, dumped notes, a brain-dump, references to "several pitches", "many pitches", "a bunch of ideas" — the shaper does NOT interrogate them about tooling.

**Protocol**:

1. State a one-line plan (e.g., "Reading the material, splitting into problem threads, writing one skeleton pitch per thread.").
2. Read whatever text is accessible.
3. Split into distinct problem threads.
4. Write one SKELETON pitch per thread into `codegen/pitches/draft/`.

**Getting the material into readable text** (transcription, format conversion, etc.) is the shaper's own engineering problem. Pick a sane default and state it as `Assumed: <x> (override if wrong)`. NEVER quiz the user on which transcription model, machine, or pipeline to use.

**If the source is genuinely unreadable**: state in ONE sentence exactly what file/text is needed and where to drop it, then stop. Never a multi-question interrogation.

## Deferral-with-Draft Contract (Rule J)

Every deferral creates a tracking obligation.

**What counts as a deferral**:

- Explicit phrases: "deferred", "future work", "phase 2", "out of scope", "accepted risk", "cut-1", "deferred to implementation"
- Implicit deferrals: "assume X", "TBD", "figure out later", any "Rabbit holes" entry that represents real work, not a true non-action

**Resolution path**:

1. Create `codegen/pitches/draft/<slug>.md` describing the deferred work (problem, scope, one-line rationale for deferring)
2. Update the pitch to reference the draft: "deferred — see draft `<slug>`" OR "Deferred to implementation — see draft `<slug>`"
3. For security/safety-relevant deferrals, the draft's rationale MUST also state the exposure assumption:
   - Example: "Auth is deferred — safe only while the dashboard is not exposed to untrusted networks"
   - Example: "Data deletion is deferred — safe only while no GDPR compliance is required"

**Blocker trigger**:

- A `Rabbit holes` entry that describes real deferred work with NO draft pitch = blocker
- A prose-only mention of deferral anywhere in the pitch with NO draft = blocker
- A true non-action (something that is genuinely nothing, not "small" or "later") MAY remain as prose, but only if it is not real work being pushed out

**Exposure assumption requirement**:
Deferrals touching auth, access control, secret handling, data deletion, or anything widening exposure must state the assumption the deferral rests on. Examples:

- "Auth deferred — safe only while accessible via VPN only"
- "Secret rotation deferred — safe only while only the box operator has access"
- "Data deletion deferred — safe only while backups are not customer-accessible"

This prevents the failure mode that shipped incomplete features with unaddressed security surface.

## Decompose-then-Split and Derive-Edges (Rules G, H)

When a problem is too large for one pitch.

**Decompose-then-split decision**:

- Reading the codebase reveals that the change spans multiple independent surfaces (e.g., backend logic + UI layer + deployment config with no prerequisite ordering)
- OR reading dependencies shows the change requires prerequisites that don't exist yet (e.g., "add auth" before "protect endpoints")
- OR the pitch itself names multiple goals that don't functionally depend on each other

In any case: shaper SPLITS into N pitches. Does NOT ask the user "should I split this?" or "how should I split?". Splitting is an engineering-decomposition decision. Emit: `Decomposed: extracted pitches <slug-1>, <slug-2> …`.

**Derive-and-write edges**:

1. After splitting, shaper reads each extracted pitch and the original code to determine: which pitch must ship before which?
2. For each derived dependency, write `Blocks-on: <slug>` into the dependent pitch's `## Dependencies` block
3. Dashboard topo-sorts these edges but infers NOTHING on its own — omitted edges silently mis-order the build queue
4. Every split MUST leave correct, parseable `## Dependencies` blocks behind. No empty blocks when dependencies exist.

**Grammar**: `## Dependencies` block body is zero-or-more lines of `Blocks-on: <slug>`. One slug per line. Matches the grammar shipped in `pitch-format-contract.md`. Back-compat: `Blocks-on:` is also accepted inside `## Related pitches`.

**Multi-pitch orchestrator enforcement**: `Blocks-on:` edges are validated by the build orchestrator BEFORE any building starts. When the user invokes `claude-build a b c` or `pi-build a b c` with multiple pitches, the orchestrator reads each pitch's `## Dependencies` block and pre-checks argv order against the declared edges. If argv order violates a `Blocks-on:` edge (e.g., a pitch that must ship after another is listed first), the orchestrator STOPS and reports the violation — it does NOT auto-reorder and does NOT proceed. This is a hard failure at pre-flight time, not a silent mis-sequencing.

## Prompt Durability (Anchor Over Line Numbers)

Prompt bodies that cite their own sections (e.g., "the escape-hatch rule", "the U1–U7 option template") should use section-name anchors rather than absolute line numbers. Line numbers become stale whenever an edit shifts positions.

**Anti-pattern**:

```
# BAD: "See the template at the options block (currently near the middle of the file)."
→ Someone edits, positions shift. That position is now something else. Silent drift.
```

**Pattern**:

```
Step c' (the escape-hatch rule) applies here.
→ Prose references the step name "c'", which doesn't move.
→ Readers can find it by searching for "step c'" even if line numbers shift.
```

When the prompt text DOES name the step or section (e.g., "step c'", "the U-template", "the auto-decide rule"), prefer the anchor. Only keep absolute numbers where:

- The pitch text itself says "correct to line N" (rare)
- A number is genuinely clearer than a section name (uncommon)

## Readiness Blockers with AUTO-RESOLVE Semantics

When adding a readiness blocker that carries AUTO-RESOLVE semantics (automatic classification + resolution without user question), the blocker description MUST inline the complete classify-and-act logic inline. Pointer-only references to external rules are insufficient because baked `shape.txt` (where the blocker lives) is included in the system prompt WITHOUT `_authoring-spine.txt` — references must be self-contained.

**Pattern**: A blocker scans for a trigger condition (e.g., "Undeclared sibling relationship" checks for shared edit-surface + ordering language without a `## Dependencies` declaration), then inlines the full classify-and-act tree (e.g., cases a/b/c/d outcomes with act-on instructions), then emits a resolution line.

**Constraint**: Rule-prose (e.g., Rule H in `_authoring-spine.txt`) and blocker-class definition (e.g., "Undeclared sibling relationship" in `shape.txt`) are producer/verifier of the same contract — both must be present and aligned or the rule is unenforced. If Rule H generalizes, the blocker's classify-and-act cases must mirror that generalization; if a new blocker is added, the corresponding rule prose (if any) must exist and agree.

## Cross-Harness Coverage (Both Claude + Pi)

Shape mode is part of both Claude Code (`claude-shape.sh`) and Pi (`pi-shape.sh`). The shape system prompts for both harnesses assemble from the same shared bodies:

- `harnesses/shared/prompt-bodies/shape.txt`
- `shared/prompt-fragments/_probing.txt`
- `shared/prompt-fragments/_authoring-spine.txt`

Editing any of these three files automatically covers both harnesses via `make install` → `generate.sh` → concatenation into `harnesses/claude/claude-shape-system-prompt.txt` and `harnesses/pi/pi-shape-system-prompt.txt`.

**Never hand-edit** the `.txt` generated system-prompt files. They are regenerated on every `make install`.

**Prompt-source edit gate**: Edits to any of the three bodies above require `make install` between test runs to rebake the system prompts. Running `make test` before install will execute against stale baked prompts. Workflow: edit → `make install` → `make test`. Some bodies (e.g., tools-header, prompt bodies) register SENTINELs in `prompt-content-parity_test.sh` for load-bearing text-change detection; new prose-only edits that are not registered need no sentinel sync.

## Completeness Contract for Sweep-Class Pitches

When a pitch's primary intent is a **purge, sweep, audit, collapse, rename, or remove** operation, two additional completeness checks are REQUIRED before the pitch may be SHAPED:

1. **Full-vocabulary sweep transcript**: every occurrence of the removed/renamed identifier must be enumerated across the entire codebase. The sweep MUST run against the current COMMITTED state (`git show HEAD:<path>` or a clean checkout), never against the dirty working tree. Evidence: a `## References` probe block with full `grep -rn` output showing zero un-addressed sites.

2. **Producer/verifier reconciliation**: when the removed/renamed artifact is PRODUCED or READ by another tool, role, or automated process, the pitch MUST show that all producers and consumers have been reconciled — either both updated in the same build, or the un-addressed side extracted to a tracked draft.

**Blocker trigger**: either requirement missing → blocker. Use the `Sweep-class completeness` option template in `shape.txt` (`## Option templates by blocker type`).

**`/ready` enforcement**: `/ready` scans `## References` structurally for the sweep transcript and the producer/verifier reconciliation. A sweep-class pitch whose `## References` lacks either → NOT ready.

## Completeness Contract for Contract-Establishing Pitches

When a pitch **establishes or strengthens a cross-cutting contract or invariant** — a write-path mandate, a commit discipline, a gate-verdict authority rule, a naming rule — the shaper MUST grep every site that DECLARES or TEACHES that contract (rule prose, prompt-bodies, `shared/apps/*.j2` downstream docs, enforcement) and fold every hit into `## Scope`, for consistency, even when that site is not broken by the change.

**Causal test is insufficient here**: the same-change auto-cover causal test ("the change causes it or the change cannot be complete without it") does NOT catch this class. A doc that merely under-states a now-strengthened contract is neither caused-by nor required-by the change, but still must be aligned — otherwise the codebase ships one strengthened source of truth alongside stale sibling docs that still teach the weaker version.

**Bound**: the test is DECLARES/INSTRUCTS — a reader would follow the text as an instruction to act — NOT mentions-in-passing. A file that references the contract in an example or footnote is out of scope; a file that teaches the contract as a rule the reader must follow is in scope.

**Producer/verifier layout**:

- Producers: `shared/prompt-fragments/_authoring-spine.txt` (Phase-0 auto-cover rule) + `harnesses/shared/prompt-bodies/shape.txt` (readiness blocker + option template).
- Verifiers: `harnesses/claude/commands/ready.md.j2` (promotion-gate scan) + the `prompt-content-parity_test.sh` sentinel (`CONTRACT-DECLARATION-SITE COMPLETENESS:`) asserting the baked prompts and `/ready` all carry the rule.

**Motivating incident**: the `session-log-uniform-across-surfaces` pitch reached READY status with `shared/apps/AGENTS-phoenix.md.j2` and `shared/apps/AGENTS-static.md.j2` `## Session Logging` sections left out of scope — both files declared the pre-strengthening session-log contract and were never updated, leaving downstream consumer docs teaching a stale rule.

## Completeness Contract for Capability-Removal Pitches

When a pitch **adds or strengthens a full-surface deny** that closes an existing path to a resource for a set of actors and designates ONE narrower substitute path (a hook with `role: "*"`, or a full-surface Edit/Write/Bash deny plus a single replacement command/tool), the shaper MUST enumerate EVERY actor in the deny's blast radius and, per actor, probe that the substitute is REACHABLE under that actor's ACTUAL grant — the role's `tools:` frontmatter, permission set, or harness capability — not merely that the substitute mechanism works in isolation.

**AUTO-RESOLVE (mechanical, never `AskUserQuestion`)**: actors and grants are all in-repo — no product fork. Grep every affected role's `tools:` frontmatter (`grep -rn '^tools:' shared/subagents/**/*.md.j2`) and cross-check each denied actor's grant against the capability the substitute requires (a Bash-invoked replacement requires every denied actor to hold Bash). Any actor missing the required capability is a REAL lockout the pitch MUST close in the SAME build — grant the capability (scoping with an allowlist per the `reviewer-bash-allowlist.sh` precedent) or explicitly carve that actor out of the deny. A shaped pitch may never ship a deny that strands an actor with no working path.

**Distinct from `User-facing surface removal/change`**: that blocker concerns OPERATOR-typed/seen surfaces and requires operator sign-off; this concerns INTERNAL automated actors and their tool-grant reachability, resolved mechanically without asking. Missing per-actor enumeration → blocker.

**Producer/verifier layout**:

- Producers: `harnesses/shared/prompt-bodies/shape.txt` (readiness blocker) + `shared/prompt-fragments/_probing.txt` (inline probe bullet).
- Verifiers: `harnesses/claude/commands/ready.md.j2` (promotion-gate scan) + the `prompt-content-parity_test.sh` sentinel (`CAPABILITY-REMOVAL REACHABILITY:`) asserting both baked shape prompts and `/ready` carry the rule.

**Motivating incident**: the `session-log-uniform-across-surfaces` pitch reached SHAPED with an 11-row claim ledger that proved the `codegen-log` mechanism works but never checked that every role denied `Edit`/`Write`/`MultiEdit` on `codegen/logging/*.md` could reach `codegen-log` — `reviewer-phoenix` had no `Bash` grant and was structurally locked out at ship time (patched hours later in commit `aa6ea00`).

## Integration with `/ready` Command

The `/ready` skill is a sibling investigation aid that gates a pitch's readiness-check loop. It carries a near-verbatim copy of the soft ask-vs-decide classifier and the deferral-with-draft contract rules. When the shape.txt rules change significantly, `/ready` may need parallel tightening to keep both tools in sync.

This is a SEPARATE pitch and change, not folded into shape-mode tightening. The two surfaces drift independently; version-matching is not automatic.

- **Sweep-class enforcement**: `/ready` blocks promotion when a sweep/purge/audit/collapse/rename/remove pitch is missing a full-vocabulary sweep transcript OR a producer/verifier reconciliation in `## References`. This enforcement is baked into the `/ready` skill body (not just context docs) via the `ready.md.j2` source.

## Trigger Keywords

shaper rules, ask-vs-decide, deferral-with-draft, decompose-then-split, derive-and-write edges, Rule G, Rule H, Rule I, Rule J, shape mode discipline, prompt durability, section-name anchors, sweep-class, completeness contract, full-vocabulary sweep, producer/verifier reconciliation, operator-owned surface, user-facing surface removal, surface preservation, keep-vs-remove fork, contract-declaration-site completeness, declaration-site sweep, contract establishment, cross-cutting contract, declares-teaches bound, capability-removal reachability, deny blast radius, stranded actor, tool-grant reachability, sole remaining path

## See Also

- `context/harnesses.md` — shape investigative disciplines, pitch-format contract, slash commands
- `context/subagents.md` — authoring spine rules (Rules A–J), deletion-safety blockers
- `shared/prompt-fragments/_authoring-spine.txt` — executable rules text
- `harnesses/shared/prompt-bodies/shape.txt` — readiness-check procedure and blocker templates
- `harnesses/claude/commands/ready.md.j2` — `/ready` skill (sibling to shape mode)
