# Shaper Discipline Domain

Shape mode is the investigative, readiness-gating mode for pitch authoring. The shaper's job is to drive a pitch from skeleton (raw user input) through investigation to "shaped" status (fully designed, ready for development). This document covers shaper-specific rules and decision patterns not covered elsewhere.

**Key reference**: `shared/prompt-fragments/_authoring-spine.txt` contains the executable spine rules (Rules A–J); `harnesses/shared/prompt-bodies/shape.txt` contains the readiness-check procedure and blocker templates. Both are baked into the shape system prompt at install time via `make install`.

## Core Shaper Rules

| Rule | Name                     | Behavior                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ---- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A    | Intent-guard             | Every AskUserQuestion option must preserve the pitch's core intent. FORBIDDEN: options that would nullify the stated goal. Auto-narrow coverage instead.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| B    | Plain-language           | Suppress internal shorthand in user-facing prose. Describe what something does. Exception: protected literals (code, errors, MUST/NEVER/FORBIDDEN, gate markers) stay verbatim.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| C    | Command-pairing          | A claude-X launcher auto-includes every same-change counterpart. The answer is always yes. Never ask.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| D    | Duplication-detection    | During Phase-0 blast-radius scan, grep for equivalent logic elsewhere. If found, EXTRACTION (consolidate at existing site) is the default, never duplicate. Auto-decide without asking.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| E    | Symptom-vs-target        | When user names both SYMPTOM (bad behavior) and TARGET (thing to improve), TARGET is the investigation subject. Probe symptom ONCE to confirm origin, then pivot. Never let symptom-chasing displace target investigation.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| F    | Context-drift auto-cover | When Phase-0 reveals a `context/*.md` file that disagrees with codebase state, auto-include that file in edit surface. Never ask whether to update it; including it is automatic.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| G    | Decompose-then-split     | Shaper SPLITS too-large problem into N pitches; never asks user "should I split?". "Too large" ≠ licence — before writing, rule G runs the one-clause test (rule H outcome (e)) itself: one clause names both → collapse, keep one pitch; two clauses → split, each sibling records `split_subject: A; B`. **Split tripwire**: a sibling declaring `blocks_on: [source]` additionally runs the standalone-promise test before the file exists — source's own promise unfulfilled without the sibling → fold, no file. Chat: `Decomposed: extracted <slug-1>, <slug-2> …`. Only split Qs reaching user are genuine product forks. Gate: `mix codegen.pitches.scope --check` fails a SUBSUMED pair with no `split_subject:` (structurally blind to the tripwire — a fresh sibling has no `scope:` yet). |
| H    | Derive-and-write edges   | Derive build-order (which pitch ships first) by reading code; WRITE into `blocks_on:` YAML frontmatter (e.g. `[slug]`). Outcome (e): same-purpose pieces collapse; (a)–(d): independent/dependent/obsoletes/stales. Dual-read: legacy `Blocks-on:` prose. Omitted edges silently mis-order.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| I    | Ask-vs-decide classifier | Ask ONLY when the answer changes product behavior or names something the user owns; engineering-completeness auto-decides. Full test + auto-decide list: § Ask-vs-Decide Classifier below.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| J    | Deferral-with-draft      | Every deferral MUST be backed by a real `codegen/pitches/draft/<slug>.md` file; prose-only = blocker. Security/safety deferrals additionally state the exposure assumption. Same-motivation deferrals of the pitch's OWN core promise are THESIS-DEFEATING — promote into the Solution sketch instead of parking. Full contract: § Deferral-with-Draft Contract below.                                                                                                                                                                                                                                                                                                                                                                                                                                |

## Ask-vs-Decide Classifier (Rule I)

The classifier narrowed significantly in the `shape-ask-only-ux-questions` hardening to eliminate over-escalation to user questions.

**Rule I parallel-case coupling**: Changes to ask-vs-decide discipline MUST touch both context/shaper-discipline.md (this file) AND context/harnesses.md § Shaper ask-vs-decide classifier — they are Rule-J parallel siblings carrying the same classifier logic. Editing one without the other creates silent drift that the next context-curator pass will flag.

**User decisions** (ASK):

- UX copy, flow, or behavior the user will see or interact with
- Product-intent forks where both branches are defensible and the choice depends on business priority
- Naming or identity the user controls or names

**Auto-decide** (NEVER ask; record as `Assumed:` in end-summary):

- **Install-guarantee**: Does the setup/install provide a dependency the feature requires? Always yes.
- **Fail-closed-when-guaranteed**: Fail-closed or fail-open when the requirement can be guaranteed? Always fail-closed once guaranteed — and stays auto-decided even when the requirement CANNOT be guaranteed (routes to disposition (c) `BREAKING`, never a question).
- **Probe depth/thoroughness/cost**: whether or how much to probe is never a user question — an unprobed claim has exactly one resolution (run it).
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

**Resolution — three dispositions, closed vocabulary `{Preserved, Dropped, Unchanged, REMOVED, BREAKING}`**: BLOCKED from SHAPED/ready unless (a) `Preserved` — re-wired to the new implementation and enumerated in the external-contract section, OR (b) `REMOVED` — an `AskUserQuestion` keep-vs-remove fork resolved by the operator, OR (c) `BREAKING` — a previously-working invocation now fails, admitted ONLY when ALL FIVE hold: forced by a named correctness requirement; every non-breaking alternative enumerated and shown SILENT WRONG; the row carries the literal label `BREAKING`; the new failure is LOUD with the operator's fix named; a `## Decisions` row records it. Disposition (c) takes NO operator fork and is auto-decided (fail-closed stays auto-decided even un-guaranteeable). Never auto-decide a removal as "internal wiring", never auto-decide a break unless all five (c) conditions hold. A hand-invented label is itself a blocker.

**Coverage**: enforced in `shape.txt` (readiness scan, self-contained without `_authoring-spine.txt`), `_probing.txt` (inline probe), and `ready.md.j2` (structural verify only — checks the vocabulary, never re-derives disposition) — all three carry the sentinel `User-facing surface removal/change without operator sign-off`, asserted by `prompt-content-parity_test.sh`.

## Answered-Question Memory

Before composing ANY AskUserQuestion, the shaper scans the conversation history for whether the user already answered — or DEFLECTED — this question or an equivalent one.

**Deflection = binding answer**: phrases like "who knows", "maybe many", "you decide", "why are you asking?", "doesn't matter" mean the user declined to decide → shaper auto-decides and does NOT re-ask.

**Re-ask rule**: a question already answered is NEVER re-surfaced, including on any review/confirmation screen. Only a genuinely-new, never-touched product fork qualifies for AskUserQuestion.

**Enforcement point**: this scan runs BEFORE generating question text, not after. If the conversation already contains the answer (or a deflection), the shaper auto-decides and moves on silently.

## Cold-Start Raw Multi-Source Material

When the user arrives with raw material implying MANY pitches — audio, dumped notes, brain-dump, "several/many pitches" — the shaper does NOT interrogate them about tooling. **Protocol**: state a one-line plan → read accessible text → split into distinct problem threads → write one SKELETON pitch per thread into `codegen/pitches/draft/`. Getting the material into readable text (transcription, format conversion) is the shaper's own engineering problem — pick a sane default, state `Assumed: <x> (override if wrong)`, never quiz on model/machine/pipeline. If genuinely unreadable: state in ONE sentence what's needed and where to drop it, then stop — never a multi-question interrogation.

## Deferral-with-Draft Contract (Rule J)

Every deferral creates a tracking obligation.

**What counts as a deferral**:

- Explicit phrases: "deferred", "future work", "phase 2", "out of scope", "accepted risk", "cut-1", "deferred to implementation"
- Implicit deferrals: "assume X", "TBD", "figure out later", any "Rabbit holes" entry that represents real work, not a true non-action

**Resolution path**:

1. Create `codegen/pitches/draft/<slug>.md` describing the deferred work (problem, scope, one-line rationale for deferring)
2. Update the pitch to reference the draft: "deferred — see draft `<slug>`" OR "Deferred to implementation — see draft `<slug>`"
3. For deferrals touching auth, access control, secret handling, data deletion, or anything widening exposure, the draft's rationale MUST also state the exposure assumption the deferral rests on — e.g. "Auth deferred — safe only while accessible via VPN only." Prevents the failure mode that ships incomplete features with unaddressed security surface.

**Blocker trigger**:

- A `Rabbit holes` entry that describes real deferred work with NO draft pitch = blocker
- A prose-only mention of deferral anywhere in the pitch with NO draft = blocker
- A true non-action (something that is genuinely nothing, not "small" or "later") MAY remain as prose, but only if it is not real work being pushed out

**THESIS-DEFEATING DEFERRAL**: a Rabbit-hole/No-go entry parking a mechanism the pitch's OWN `## Problem`/`summary:` names as delivering its core promise — especially one with already-PASSED probes — is never a legitimate deferral. AUTO-RESOLVE by promoting it into the Solution sketch as a move; escalate only when adoption is itself a genuine product fork.

**Bilateral-record obligation**: a concrete, path-bearing deferral also gets a `handoffs:` record in
both pitches (never prose alone) — see `context/pitch-lifecycle.md` § Frontmatter Schema.

## Decompose-then-Split and Derive-Edges (Rules G, H)

When a problem is too large for one pitch.

**Decompose-then-split decision**:

- Reading the codebase reveals that the change spans multiple independent surfaces (e.g., backend logic + UI layer + deployment config with no prerequisite ordering)
- OR reading dependencies shows the change requires prerequisites that don't exist yet (e.g., "add auth" before "protect endpoints")
- OR the pitch itself names multiple goals that don't functionally depend on each other

In any case: shaper SPLITS into N pitches. Does NOT ask the user "should I split this?" or "how should I split?". Splitting is an engineering-decomposition decision. Emit: `Decomposed: extracted pitches <slug-1>, <slug-2> …`.

**Derive-and-write edges**:

1. After splitting, shaper reads each extracted pitch and the original code to determine: which pitch must ship before which?
2. For each derived dependency, write the slug into the dependent pitch's `blocks_on:` frontmatter flow-list (e.g. `blocks_on: [other-slug]`)
3. Dashboard topo-sorts these edges but infers NOTHING on its own — omitted edges silently mis-order the build queue
4. Every split MUST leave correct, parseable `blocks_on:` lists behind. `blocks_on: []` when independent.

**Grammar**: `blocks_on:` is a YAML frontmatter flow-list of bare slugs, e.g. `blocks_on: [dep-one, dep-two]`; empty/independent is `blocks_on: []`. **Dual-read**: no-frontmatter pitches fall back to legacy prose — a `## Dependencies` body of `Blocks-on: <slug>` lines, also accepted inside `## Related pitches`.

**`scope:`** (sibling field, machine-readable edit surface) is a flow-list of repo-relative paths this pitch will edit — inline (`scope: [a, b]`) or multiline (key alone, `[`/items/`]` on following lines — the only hand-written form in the corpus). Shaper writes it alongside `status: SHAPED`. Read by `mix codegen.pitches.scope` (`LoopQueue.parse_scope/2`) — a report AND (via `--check` gate leg) the `make test` enforcer on `ready/` pitches: a `ready/` pitch with no `scope:` field fails the `pitch-scope-parity` gate leg, naming the slug.

**Multi-pitch orchestrator enforcement**: `Blocks-on:` edges are validated BEFORE any building starts. `claude-build a b c` pre-checks argv order against declared edges; a violation STOPS with a report — no auto-reorder, no silent mis-sequencing.

**Premature single-mechanism DEFER / over-split** (blocker in `shape.txt`): before DEFER-ing a residual or splitting work, classify it. **Same invariant** → sweep sibling mechanisms (hook events/stages/roles/placements) for one erasing the residual — found → dissolve, one pitch; not found → keep split, embed justification. **Different invariant** → run rule H outcome **(e) Collapse**: name the ONE PURPOSE both serve (≤50 chars, the same `commit_subject:` test the shaper runs when sealing a pitch's own commit message — `shape.txt`'s "On completion" step). One clause → COLLAPSE. Two clauses → split stands, record invariant + `split_subject: A; B` per sibling. `blocks_on: []` ≠ independence. A scope-collision pair recording no `split_subject:` is itself a blocker. Inconclusive → ask.

## Readiness Blockers with AUTO-RESOLVE Semantics

An AUTO-RESOLVE readiness blocker (auto-classify + resolve, no user question) MUST inline its complete classify-and-act logic — baked `shape.txt` ships WITHOUT `_authoring-spine.txt`, so pointer-only references to external rules are unenforceable. Pattern: scan for trigger condition → inline full classify-and-act tree (e.g., cases a/b/c/d) → emit resolution line. Rule-prose (Rule H) and blocker-class definition (`shape.txt`) are producer/verifier of the same contract — both must stay aligned; a rule generalization requires the blocker's cases to mirror it.

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

**Motivating incident**: `session-log-uniform-across-surfaces` reached READY with `shared/apps/AGENTS-phoenix.md.j2`/`AGENTS-static.md.j2` `## Session Logging` sections left out of scope — both declared the pre-strengthening contract and were never updated, leaving downstream docs teaching a stale rule.

## Completeness Contract for Dead-Code Retention Pitches

A redundant mechanism (hook/rule/path/config/doc/flag/fn) MUST be hard-deleted, never kept as deprecated/backstop/legacy-fallback/rename-shim — unless a probe proves a live consumer EXERCISES it (invokes/spawns/emits), not merely REFERENCES it. Registration/permission/reachability is a PROXY, not liveness (same bar as Unverified-empirical-claims). Carve-outs: (a) live orthogonal mechanism; (b) rename-shim for a live EXTERNAL contract only; (c) operator-facing surface → `User-facing surface removal/change` instead. AUTO-RESOLVE: hard-delete + full-vocabulary grep; ask only if inconclusive. Producers: `shape.txt` + `_probing.txt`. Verifiers: `ready.md.j2` + parity sentinel. Incident: a pitch kept 5 dead `SubagentStop` hooks as "live," backed only by registry refs not an exercise probe — corrected by `add-loop-enforcement-then-delete-dead-hooks`.

## Completeness Contract for Capability-Removal Pitches

When a pitch **adds or strengthens a full-surface deny** that closes an existing path to a resource for a set of actors and designates ONE narrower substitute path (a hook with `role: "*"`, or a full-surface Edit/Write/Bash deny plus a single replacement command/tool), the shaper MUST enumerate EVERY actor in the deny's blast radius and, per actor, probe that the substitute is REACHABLE under that actor's ACTUAL grant — the role's `tools:` frontmatter, permission set, or harness capability — not merely that the substitute mechanism works in isolation.

**AUTO-RESOLVE (mechanical, never `AskUserQuestion`)**: actors and grants are all in-repo — no product fork. Grep every affected role's `tools:` frontmatter (`grep -rn '^tools:' shared/subagents/**/*.md.j2`) and cross-check each denied actor's grant against the capability the substitute requires (a Bash-invoked replacement requires every denied actor to hold Bash). Any actor missing the required capability is a REAL lockout the pitch MUST close in the SAME build — grant the capability (scoping with an allowlist per the `reviewer-bash-allowlist.sh` precedent) or explicitly carve that actor out of the deny. A shaped pitch may never ship a deny that strands an actor with no working path.

**Distinct from `User-facing surface removal/change`**: that blocker concerns OPERATOR-typed/seen surfaces and requires operator sign-off; this concerns INTERNAL automated actors and their tool-grant reachability, resolved mechanically without asking. Missing per-actor enumeration → blocker.

**Producer/verifier**: `shape.txt` (blocker) + `_probing.txt` (probe) + `ready.md.j2` (gate) + `prompt-content-parity_test.sh` sentinel (`CAPABILITY-REMOVAL REACHABILITY:`).

**Motivating incident**: `session-log-uniform-across-surfaces` reached SHAPED with an 11-row ledger proving `codegen-log` works, but never checked every role denied `Edit`/`Write`/`MultiEdit` on `codegen/logging/*.md` could reach it — `reviewer-phoenix` lacked `Bash` and was locked out (patched in `aa6ea00`).

## Completeness Contract for Replacement Pitches

**Invariant**: a delete/replace change MUST ship a COMPLETE, WIRED replacement in the SAME change — the new code has a live production caller, the removed code's functionality is preserved (or its drop is operator-approved), and every integration point of the removed code is reconciled. A pitch that deletes Y and introduces X without proving all three is not done, even if X "looks" like a correct port.

**Three-probe detector**: triggers on any DELETE/replace move OR any `absorb|replace|subsume|supersede`-shaped claim (prose or `## Claim ledger`). BLOCKED-from-SHAPED unless the ledger carries:

- **(a) WIRED** — replacement X has a live production caller. Real-contract probe: non-test `grep -rn <new-symbol>` hit, OR `git log -S <symbol>` proving the symbol was not born-dead.
- **(b) RECONCILED** — every consumer/integration-point of removed Y is enumerated and individually probed (each updated in the same change, or explicitly carved to a tracked draft).
- **(c) PRESERVED** — Y's behavior is preserved by X, OR the drop is operator-approved via `AskUserQuestion`.

Any one of the three missing → blocker.

**Proxy-probe carve-out**: this extends the Unverified-empirical-claims proxy-probe discipline — a ledger row proving only that the removed Y existed/worked is a proxy, not a wiring probe; the real-contract probe for "X absorbs Y" is a live caller of X, not a read of Y.

**Dead-code sub-rule** (second mechanism, same class): every NEW module/function/script/launcher a pitch introduces MUST name a live production caller in the same pitch (non-test `grep -rn <symbol>` hit OR the explicit wiring move). A new symbol with no caller and no wiring move is born-dead — blocker.

**Report-tool clause**: a NEW report/advisory/`--check`/`--report`/`--json`/verdict tool counts as code here, and a human operator is NOT a live production caller. Resolve to WIRE (name the automated consumer — `make test`/`install` leg, hook, loop, CI step) or KEEP-ADVISORY (justify the human consumer in the tool's own docs; `codegen-analyze`/`codegen-propose` are the exemplar carve-outs). Neither named → born-dead, same as an uncalled module.

**Resolution template**: run the three probes now; raise ONE `AskUserQuestion` ONLY for the (c) PRESERVED drop-vs-keep fork; a born-dead X cannot self-clear by asking — build the caller in the same pitch or delete X.

**Producer/verifier layout**:

- Producers: `harnesses/shared/prompt-bodies/shape.txt` (readiness blocker) + `shared/prompt-fragments/_probing.txt` (inline probe bullet).
- Verifiers: `harnesses/claude/commands/ready.md.j2` (promotion-gate scan) + the `prompt-content-parity_test.sh` sentinel (`Incomplete replacement (dropped functionality / unwired new code)`) asserting both baked shape prompts and `/ready` carry the rule.

**Motivating incident**: commit `ee88926` shipped `LoopQueue` born-dead while deleting `--queue`/`build-queue.sh`, backed by a false "translate then delete ✅" ledger row — a proxy proving old code was read, never that new code was called. `af87ad1` corrected it.

**Sibling-section pattern**: "Completeness Contract for X Pitches" sections share a six-part shape — invariant, detector, carve-out, sub-rule, resolution template, producer/verifier+incident. New contract sections should follow it.

## Completeness Contract for Empirical-Usage-Grounding Pitches

**Invariant**: for codegen's OWN command/flag/verb/on-disk-format/teaching convention, "what should this API be" is answered by how it ACTUALLY is used and fails — session transcripts, build logs, prior-pitch record — not source-reading alone. **Detection**: a codegen self-tooling pitch decides an API/convention/naming design for a subject with usage history, no usage-mining evidence in `## References`. **Carve-out**: downstream app pitches exempt (data sources are codegen-local); a genuinely-new subject still notes all three sources "checked, found empty," never skipped. **Sub-rule**: transcript extraction is best-effort — name the GOAL (invocation signatures + error taxonomy), never a frozen jq expression; `codegen/logging/` is gitignored/ephemeral. **Resolution**: AUTO-RESOLVE — mine `~/.claude/projects/<cwd-slashes-as-dashes>/*.jsonl` (jq `tool_use` + `is_error: true`), grep `codegen/logging/*_cycle.jsonl`, list `codegen/pitches/{shipped,archive,ready,draft}/` hits, embed all three, let evidence inform the decision. **Producer/verifier**: `shape.txt` + `_probing.txt` + `ready.md.j2` + sentinel `Empirical-usage-grounding`. **Distinct from convention-claim verification**: that checks a _claim_ is source-ENCODED; this checks a _design decision_ is usage-GROUNDED — additive, both may apply.

## Completeness Contract for Format/Syntax-Change Pitches

**Invariant**: a format/schema/syntax change affects EVERY consumer incl. opaque whole-artifact readers that never parse the changed field — enumerating only field PARSERS misses the readers a structural change breaks.

**Detection + bar**: byte-level artifact changes (delimiters, leading/trailing block, field order) or serialization/file-format/API-shape/DB-column/config-key/log-line/naming changes. Structural (whole-artifact shape) → FULL bar. Semantic (field VALUE, structure unchanged) → field-parser bar suffices, no blocker.

**Carve-out**: semantic-only changes and new artifacts with no consumer are exempt — note "checked, not skipped."

**Sub-rule**: enumerate by searching READERS (path/handle/type/endpoint/`File.read`/`open`/`fetch`), NOT the field name — grepping the field misses opaque readers. Classify field-parser vs opaque; prove new format safe for both.

**Resolution**: AUTO-RESOLVE — run the enumeration now; fix any breaking opaque reader (strip/guard/migrate) same change or carve to a tracked draft (Rule J). Ask only if a migration fork.

**Producer/verifier**: `_authoring-spine.txt` + `shape.txt` (blocker+template) + `_probing.txt` (probe) + `ready.md.j2` (gate) + `prompt-content-parity_test.sh` sentinel (`Format/syntax-change consumer completeness`). Incident: pitch-frontmatter `---` broke the loop's opaque `File.read!` whole-pitch reader; fixed by `650941e8` (`strip_frontmatter/1`).

## Completeness Contract for Required-Platform Coverage Pitches

**Invariant**: `PROJECT_CONTEXT.md` § Required Platforms (`required_platforms: [...]`) is the sole support-set source, never host/fleet. **Detection**: perf/filesystem/process/shell/OS-tool claim. **Carve-out**: missing/empty/placeholder declaration blocks (name field), never auto-filled. **Sub-rule**: one matrix row per platform; `N/A` needs a genuine absent-facility reason. **Resolution**: AUTO-RESOLVE matrix; ask only on unexercisable premise. **Producer/verifier**: `shape.txt` + `_probing.txt` + `ready.md.j2` + sentinel `REQUIRED-PLATFORM COVERAGE:`. A one-box gate is never cross-platform evidence.

## Probe-Completeness — Recursive Ledger to the Leaves

Probing is a tree exhausted to its leaves, not one pass. Every probe RESULT and every "X fully probed" assertion must be re-tested: does the result make anything NEW load-bearing, and is the sub-surface fully enumerated (not one first-order probe)? Any surfaced claim becomes a new `UNPROBED` ledger row, gets probed, and recurses on its own result to leaves. Incident: a shaper probed a tool-deny, declared "fully probed" — the RESULT made two new things load-bearing (surviving `>` write path, guard-under-`--agent`), caught only by operator pushback. Inline self-pass MANDATORY always; MAY additionally fan out delegated `codegen-call` probes (different angles, findings return as leads) — additive, never a substitute (`/poke-holes` stays a separate opt-in adversarial swarm). Producer/verifier: `shape.txt` gate 2b + `_probing.txt` recursion bullet + `ready.md.j2` mirror + sentinel `PROBE-COMPLETENESS: derive second-order claims to the leaves`.

## Completeness Contract for Delegated-Enumeration Pitches

**Invariant**: a Phase-0 map spanning >1 file is delegated through `codegen-call --model=<family> --effort=off`, never the `Agent` tool — `--model`/`--effort` are required per-invocation flags there, so a spawn inherits no session thinking/model. **Detector**: multi-file enumeration/grep-sweep/naming-cross-reference with no explicit `Fanning out N codegen-call probes` / `Probing inline` line. **Carve-out**: single-grep answers and every execute-probe (feasibility spike, `claude --print` runtime probe) stay inline — never delegated. **Sub-rule**: transcribe, never interpret — a delegated prose summary/diagnosis is a LEAD, not a ledger row; `metrics.bash_count` vs returned `$ ` lines catches silent partial completion arithmetically. **Resolution**: AUTO — state the fan-out/inline decision in one line before the first probe; two consecutive partial delegations → drop to inline, say so. **Producer/verifier**: `_authoring-spine.txt` (rule) + `_probing.txt` (leads-vs-transcripts cut) + `prompt-content-parity_test.sh` sentinel (`Delegated enumeration`). **Sandbox sibling**: the mandated feasibility-spike sandbox (absolute `/tmp/`, built by `spike-builder`) is SEPARATE — see `shape.txt` § Feasibility spikes / § Spike SETS for negative-control-first design.

## Integration with `/ready` Command

`/ready` is a VERIFY-ONLY gate, not a sibling investigation loop. It re-confirms structure + re-runs the ledger's recorded probe commands + reconciles handoffs, then moves the file or refuses naming the gap — it never investigates, decides, or edits the pitch. All investigation, auto-decide, and `AskUserQuestion` logic lives in `shape.txt` alone; `/ready` inherits only the structural blocker vocabulary (sweep-class, contract-declaration-site, etc.) as things to CHECK for, not RESOLVE.

- **Sweep-class enforcement**: `/ready` refuses promotion when a sweep/purge/audit/collapse/rename/remove pitch lacks a full-vocabulary sweep transcript OR producer/verifier reconciliation in `## References` — a structural check, not a re-derivation.

## Pitfalls

- **Pitch line numbers drift** — use exact anchor text. Example blocks carry routing targets too.
- **Shape prompt two layers** — inline-probe (`_probing.txt`) checks claim-intro; readiness-check (`shape.txt`) scans completeness. `/ready` inherits `_probing.txt`.
- **Read/Edit blocked for codegen/pitches/** — `subagent-read-discipline.sh` denies both; workaround: Bash `awk`/`grep` + Python string-replace. `grep -c "header text"` false-positives on prose mentions — use `grep -n "^## ..."` (anchored H2) for "exactly one section" checks. Delegation-prompt `## ` lines get indented to `##` to prevent rank-order corruption.

## Trigger Keywords

shaper rules, ask-vs-decide, deferral-with-draft, decompose-then-split, derive-and-write edges, Rules A–J, shape mode discipline, sweep-class, completeness contract, full-vocabulary sweep, producer/verifier reconciliation, operator-owned surface, user-facing surface removal, keep-vs-remove fork, BREAKING disposition, closed vocabulary, split tripwire, standalone-promise test, THESIS-DEFEATING DEFERRAL, delegated enumeration, codegen-call, spike-builder, spike SETS, negative control, contract-declaration-site completeness, capability-removal reachability, incomplete replacement, WIRED RECONCILED PRESERVED, born-dead code, proxy probe, empirical-usage-grounding, format/syntax-change consumer completeness, opaque reader, probe-completeness, recursive ledger, sub-surface

## See Also

- `context/harnesses.md` — shape investigative disciplines, pitch-format contract, slash commands
- `context/subagents.md` — authoring spine rules (Rules A–J), deletion-safety blockers
- `shared/prompt-fragments/_authoring-spine.txt` — executable rules text
- `harnesses/shared/prompt-bodies/shape.txt` — readiness-check procedure and blocker templates
- `harnesses/claude/commands/ready.md.j2` — `/ready` skill (sibling to shape mode)
