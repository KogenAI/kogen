# Rules Roles Domain — Role-Specific Behavioral Rules

Role-specific rules that define what each agent role MUST and MUST NOT do. These are distinct from core discipline rules (see `context/rules-core.md`) — they encode delegation contracts, never-implement rules, gate-reading behavior, and role boundaries.

## Components

| File                                                                                       | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `shared/rules/roles/planner.md`                                                            | Planner rules — plan structure, slice definitions, gate-json block format, `__GATE_PARSE_ERROR__` sentinel                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `shared/rules/roles/developer.md`                                                          | Universal developer rules — verify-not-declare, fix-root-cause, test with every change; **NOTE**: codegen/pitches/\*\* Read prohibition documented here; reviewer.md lacks parallel text (hook authoritative)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `shared/rules/roles/reviewer.md`                                                           | Reviewer rules — what to check, how to report, block/pass criteria                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `shared/subagents/{phoenix,static}/reviewer-{phoenix,static}.md.j2` (frontmatter `tools:`) | Reviewer tool grant — `Bash, Edit, Glob, Grep, Read`. Bash was added so reviewers can write their own session-log section body via `codegen-log section --body @-` (`codegen-log` is the sole writer of session logs — see `session-log-writer-only` in `context/hooks.md`). Bash is default-deny gated by `reviewer-bash-allowlist` (GENERATED): codegen-log plus a narrow set of safe read-only utilities only — no history-mutating git verbs, **no build/test/package-manager commands** (python3, mix, make, npm rejected). Gate confirmation for Python-only changes MUST rely on `gate-result.json` .verdict field or developer-reported test run, never a reviewer re-run. `reviewer-guard.sh` no longer denies Bash (that hard-deny was removed — it would otherwise shadow the allowlist, since a hard-deny and an allowlist cannot both govern the same tool for the same role); reviewer-guard still denies Write/MultiEdit/Monitor and gates Edit to canonical session-log paths only. |
| `shared/rules/roles/committer.md`                                                          | Committer rules — commit message format, never amend, why-focused                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `shared/rules/roles/context-curator.md`                                                    | Context curator rules — what to update, when, retrospective routing                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `context/curator-routing.md`                                                               | Project routing targets for context-curator — where [local]/[shared] learnings land in THIS repo                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

## Key Paths

```
shared/rules/roles/
  planner.md
  developer.md
  reviewer.md
  committer.md
  context-curator.md
```

## Integration Points

- **subagents**: each `.md.j2` template `{% include %}`s its role's rule file — changes require `make install`
- **hooks**: several hooks enforce role rules at runtime — e.g. `pre-commit-guard.sh` enforces committer-only commits — see `context/hooks.md`
- **rules-core**: role rules are layered on top of core discipline rules (`context/rules-core.md`); both must be satisfied
- **curator-routing**: context-curator's generic rule (`shared/rules/roles/context-curator.md`) defines the write surface and decision tree — see § Curator Write Surface below; `context/curator-routing.md` carries project-specific path targets; `codegen/rules/` is a symlink to `shared/rules/` — all curators edit via the symlink path `codegen/rules/**`, never via `shared/rules/` directly

## Loop Dual-Repo Commitment Pattern

Non-interactive builds are driven by the deterministic Elixir orchestration loop, not a self-orchestrating agent session. When curator edits touch `shared/rules/` (via symlink `codegen/rules/`), the loop's committer role disambiguates the commit scope:

- **OCG repo == current project repo** — OCG root (the directory containing real `shared/rules/`, not a symlink) equals `git rev-parse --show-toplevel`. Curator edits to `shared/rules/` + `context/` join code + test changes in **ONE commit per cycle**.
- **Distinct repos** — Downstream project has `codegen/rules/` as an out-pointing symlink. Curator edits (to `codegen/rules/`) and dev code (to local `lib/`, `test/`, etc.) require **TWO commits**: one in the consuming app repo (dev code + curator-symlink-target edits reflected in message); one in codegen repo (curator's real rule changes to `shared/rules/`).

**Detection**: Compare `shared/rules` (resolve as real dir path) to `git rev-parse --show-toplevel`. If equal → same repo → one commit. If not (downstream symlink case) → two commits.

Curator never initiates committer calls — curator is a leaf agent. The loop owns all role sequencing.

## Curator Write Surface

The guard `context-curator-guard.sh` enforces exactly three allowed path patterns (line numbers in the hook source):

- Line 46: `(^|/)context/` — allows `context/*.md` relative to any project root (all repos)
- Line 51: `(^|/)codegen/rules(/|$)` — allows `codegen/rules/**` symlink path (all repos; symlink target is `<codegen-repo>/shared/rules`)
- Line 56: `(^|/)codegen/logging/` — allows `codegen/logging/*.md` session logs (codegen-on-codegen only)

**Path-nesting note**: all curators use `codegen/rules/**` (the symlink path). Direct `shared/rules/` edits are DENIED — the guard does not allow them. Hook receives raw symlink path (not resolved target). Boundary: `codegen/recipes/` and `codegen/rulesets/` still DENIED — pattern anchors on `/rules(/|$)`.

**Propagation difference**:

- `context/*.md` — checked-in file; sticks on commit; `make install` never touches it.
- `codegen/rules/**` — symlink to `shared/rules/`; source for `{% include %}` in `.md.j2` templates; edit is inert until `make install` re-renders agent prompts and installs them to `~/.claude/`.

**Decision tree** (determines where a `[shared]` learning goes):

1. Learning is about hooks, enforcement, generator pipeline, or framework mechanics (already captured in agent-readable context data) → `context/*.md` — commit, no regeneration.
2. Learning requires a new rule or discipline edit in `shared/rules/**`:
   - Downstream repo → edit `codegen/rules/<path>` via symlink path (guard allows it); note `make install` must run in codegen repo before agents see the change.
   - Codegen-on-codegen → edit `codegen/rules/<path>` via symlink path (guard allows it); note `make install` required before agents see the change. Rule edits should be deferred to framework-focused sessions, not routine curation cycles.
3. Learning is project-specific (module names, file paths, business logic) → skip; out of curator scope.

**Clarification — Rule-prose changes vs baked-prompt changes**:

- **Rule-prose edits to auto-loaded files** (e.g., a rule imported via `@`-include in `AGENTS-phoenix.md.j2` or read at session start by Pi) take effect at the **next agent session without `make install`** — the rule is consumed at runtime, not baked into the prompt.
- **Baked-prompt edits** (`{% include %}` pull rule content into `.md.j2` templates and subagent prompts) require **`make install` to re-render** before agents see the change. The pitfall "rule changes are not live" refers to baked-prompt rules only.
- When planning rule/flag changes, confirm whether the rule is auto-loaded (runtime read, no regen needed) or baked (prompt-embedded, regen required). Check the template for `{% include %}` references and the harness launcher for `@`-imports or explicit Read calls.

**Harmonization pattern for layered rules** — When adding a new convention, mode, or constraint to an existing rule set, prefer authoring it as a positive counterpart that complements existing negatives rather than re-stating them. Example: existing rule states "Existence ≠ contract" (negative: what does NOT suffice) + "reading source is NOT execution" (negative); new convention-claim mode = "doc-citation PLUS confirming grep IS exercising the contract" (positive: what DOES suffice). The affirmative form documents the complementary truth that makes the negatives coherent — a single principle with both denial and affirmation sides. Outcome: no verbatim duplication, the rule set is more maintainable, and the positive gate is explicit for developers writing probes.

**Inline Layer-A/Layer-B contrast pattern** — When establishing two distinct classes of behavior (e.g., invisible structural discoverability vs. visible editorial content), embed the contrast INSIDE the "What You Never Do" prohibition that governs Layer B. Rather than stating the prohibition in isolation ("do NOT invent FAQ sections"), append an inline clarification naming both layers: "do NOT invent visible FAQ sections or comparison blocks (Layer B: editorial choice gates) unless the user signals intent; invisible structural discoverability (Layer A: JSON-LD, meta tags, heading discipline) is baseline craft applied default-on." This pattern prevents misreading the prohibition as blocking ALL behavior in that domain, not just the visible-layer subclass. The embedded contrast makes layer semantics concrete and disambiguates when rules interact with simplicity-first or surgical-changes constraints.

**Vacuous-pass composition pattern** — When a producer role (planner) writes content that a consumer role (reviewer) checks, and both roles must handle the case where the content is absent, state the vacuous-pass condition identically in BOTH rules using the same literal trigger string. Example: planner rule says "write `### Deliverable Manifest` subsection IF the pitch has a numbered list; omit the subsection entirely when pitch has no numbered list." Reviewer rule says "check the manifest completeness IF `## Plan` contains `### Deliverable Manifest`; this step passes vacuously when no manifest exists." Both use identical literal string `"### Deliverable Manifest"` and identical vacuous condition trigger. Result: no gating hook needed — the two rules compose automatically. Planner writing none + reviewer seeing none = mutual no-op by design, not accident. Load-bearing requirement: sentinels must match character-for-character (case-sensitive, punctuation exact) across both roles; use anchor-text grep during review to verify before commit.

Cross-reference: full guard pattern analysis and path-nesting mechanics → `context/hooks.md` § context-curator-guard Write Surface; rule text → `shared/rules/roles/context-curator.md` § Write Surface.

## Spawn Ritual (Atomic codegen-log Open + Delegation) — Interactive-Session Fallback Only

For interactive/resumable-session builds (the surviving fallback path when the Elixir loop doesn't drive the cycle), the outer session's critical hygiene rule is: `codegen-log section --role <role> --body @-` (empty stdin, opening the section) + Agent() call MUST be same turn, never separated. Named "spawn ritual" to enforce atomicity in models — a single conceptual operation preventing treat-as-separable regressions.

Pattern: For every subagent spawn (after first log creation), the outer session:

1. **Bash**: `codegen-log section --role <agent_type> --body @-` with empty stdin to open `## <agent_type> Section` header (literal name from agent's YAML `name:`) — never a raw Edit/Write.
2. **Agent()** call immediately after in same turn—no intervening chat

**Stack-prefixed planner variant header stub**: When the outer session spawns a stack-prefixed planner variant (e.g., `planner-phoenix`), `codegen-log section --role planner-phoenix` opens a literal `## planner-phoenix Section` header — not a bare `## planner Section`. `codegen-log`'s `section_header_for_agent` derives the stack-prefixed header from the `--role` value for any `planner-*`/`developer-*`/`reviewer-*` role; the bare-`planner` case only applies when the role literal is exactly `planner`.

Enforcement:

- **Prompt**: the `"subagent ritual = codegen-log section --role <role> --body @- (empty stdin) + subagent() call, atomic pair"` line in FIRST-TURN PROTOCOL in `harnesses/{claude,pi}/tools-header/build.txt` (equivalent wording, both harnesses)
- **Hook**: `session-log-writer-only` denies any raw Edit/Write/MultiEdit or raw Bash write on `codegen/logging/*.md` — `codegen-log` is structurally the only path that can open or fill a section.

**Under the loop** (non-interactive builds): the loop writes each role's session-log section body directly via `codegen-log section --body @-` after each `codegen-call` invocation completes — there is no separate spawn-time header-Edit step, and no `Agent()` matcher hook fires (each role is a main-agent invocation, not a subagent spawn).

## Committer Spawn Timing

Committer is a leaf agent with no independent decision-making power about when it runs. Under the loop, the Elixir sequencer (`OrchestrationLoop.run/1`) invokes committer only after context-curator completes — ordering is enforced structurally by the sequencer's role list, not by a spawn-time guard. In the interactive-session fallback, ordering guidance comes from the outer session's prompt, which names the full sequence `reviewer → context-curator → committer`.

## Committer Staging Scope — One Commit Per Cycle

Committer stages **ALL cycle output** in a single `git add -A` commit per cycle. Cycle-complete output includes:

- Dev code edits (`lib/`, `test/`, `src/`, config files, migrations)
- Curator context edits (`context/*.md`, `codegen/rules/**` in same-repo case)
- Session logs (appended to `codegen/logging/*.md` during the cycle)

**One commit per cycle is mandatory** — partial snapshots (staging only a subset of cycle-modified files) are forbidden. The clean-tree gate (`build-no-success-before-commit.sh`) blocks SHIPPED if any modified file remains unstaged.

**Exception: partial-readiness carve-out** — when work is genuinely blocked and incomplete (e.g., reviewer denies certain changes that must be redone), that blocked work remains unstaged for the next cycle. This is a distinct case from a partial commit of cycle-complete output. The loop re-invokes the developer role or fails the cycle based on reviewer guidance.

## Trigger Keywords

orchestrator rules, planner rules, developer rules, reviewer rules, committer rules, context-curator rules, never-implement, full-cycle, delegation, INCONCLUSIVE table

## Pitfalls

- **Rule changes are not live** — must `make install` to regenerate agent prompts
- **Dev prompt boundary** — the developer delegation prompt ends at the gate. Never fold "Commit via committer" / `make install` / deploy into the dev prompt; commit is a separate post-reviewer+curator cycle stage. Sync sites carrying this rule: `harnesses/{claude,pi}/tools-header/build.txt` (responsibilities one-liner), `shared/apps/AGENTS-{phoenix,static}.md.j2`.
- **Role identity at runtime** — hooks use two discriminators: `AGENT_TYPE` (per-subagent identity, set per-spawn) and `CLAUDE_ROLE_FAMILY` (per-launcher mode, set by outer session harness). `AGENT_TYPE` is used for per-role guards on subagents; `CLAUDE_ROLE_FAMILY` is used for `claude-debug`/`claude-shape` session-level guards. Not all hooks use both — check each hook's discriminator before assuming universal `$AGENT_TYPE` behavior
- **Session logs are authoritative for commit examples** — when rules cite a real commit hash as a worked example (e.g., c374957), reviewer can verify the commit subject against session logs (developer committer section records the hash + subject) rather than running `git show` — session logs are the durable reference that survives force-push or repo resets (cf. session `20260610_082318_commit-message-quality-audit`, the `## developer Section`)
- **Include-list-only diffs require simplified review** — when diffs touch only `.md.j2` template include lines (no rule-file body changes, no logic), the review scope narrows to three checks: (1) glob each included rule file exists, (2) grep the new token across all subagent templates for duplicate-within-file issues, (3) confirm semantic alignment between the rule's concern and the role's responsibility (e.g., `generators.md` forbidding phx.gen belongs in planner, not developer). No code logic, no prose-wording scrutiny — only path resolution, deduplication, and role fit. This pattern applies to template-only changes (e.g., adding a missing {% include %} to planner-phoenix.md.j2)
- **Developer `make test` invocation cap exhaustion via verification runs** — The `dev-no-self-gate.sh` hook limits developer to 3 `make test`/`make ci`/`mix test` invocations per session. This budget can be exhausted by pure verification re-runs (no code changes) when a prior developer pass hit the cap before completing a clean end-to-end gate run. Plan the LAST developer pass in a cycle to END with the gate `make test` as its final action, not as a follow-up re-spawn — avoid burning an extra developer turn on pure verification of already-confirmed-green results. If cap is hit mid-cycle, escalate to planner for grid-control rather than spawning another developer re-run.
- **Reviewer verification: test obligations named in plan must have direct test proof** — A plan's delegation prompt can name a specific test obligation (e.g., "assert via a captured-args seam") that the developer satisfies only partially — testing an adjacent pure helper instead of the actual integration point that calls it. Reviewers must re-check the exact function named in the plan's test-strategy line against the actual test file, not just confirm "a test exists for this general area." Template: plan says `default_codegen_call/6`, verify test file contains direct `default_codegen_call` invocation or a `:cmd_fn` seam that captures its args — not just a test of the helper function it calls.
- **Context-file Trigger Keywords must sync with PROJECT_CONTEXT.md domain-table rows** — Every `context/*.md` file's `## Trigger Keywords` section is tested against PROJECT_CONTEXT.md's Domain Context Files table via `context-index-coverage_test.sh`. Adding new keywords to a context file's Trigger Keywords section without syncing the SAME keywords (exact case + wording) into the corresponding Domain Context Files keyword cell causes `make test` RED. The parity check is byte-exact string match, not substring match — uppercase `WIRED RECONCILED PRESERVED` differs from lowercase. Always grep-check the target row in PROJECT_CONTEXT.md and edit both the context file AND its corresponding row in the same edit pass, not sequentially discovered via gate failure.

## Planning Rule/Flag Changes — Mandatory Audit Pattern

When a pitch modifies rules, enforcement registry entries, or hook dispatch flags, the plan MUST include an **Interaction Audit** table that cross-checks three dimensions:

| Subject            | Slot (event/matcher)                              | Mode                     | Verdict                                             |
| ------------------ | ------------------------------------------------- | ------------------------ | --------------------------------------------------- |
| (target file/hook) | (which lifecycle event / gate / matcher reads it) | (text, enforce, measure) | (does it compose / regress / require sentinel sync) |

Purpose: confirm the change does not break sibling systems:

- Text directives (rule prose, agent-readable context) → no regeneration needed; composition is semantic (prose correct, no contradictions).
- Enforcement hooks (registry entry, denial rules) → verify hook runs, matches the condition, and integrates with surrounding gate logic.
- Measurement hooks (parity tests, sentinel-based assertions) → confirm zero sentinels target the edited rule (so no sentinel sync is missed), or explicitly identify required sentinel updates.

Example: editing a role rule file (e.g., `shared/rules/roles/planner.md`) prose checks: (1) `{% include %}` wiring in subagent templates that consume it, (2) `prompt-content-parity_test.sh` sentinels referencing this rule (zero hits = no sentinel sync needed). A silent sentinel miss is a gate blocker — pre-completion grep of the parity test is mandatory.

## Discipline Gaps & Mechanical Backstops — Prove-and-Run

Three rules close the derivation-proof gap across roles. Rule J (planner), Rule L (reviewer), and Rule O (developer + reviewer) form a single cycle of enforcement.

**Provenance tags** (`planner.md` § Provenance Tags) — Every factual claim about path derivation, env-var resolution, config-key presence, or version-dependent behavior carries exactly one tag: `ran:` (executable proof — command run, output observed), `read:` (static proof — source line cited), or `assumed:` (no proof). `assumed:` is FORBIDDEN for derivation/env/config/version claims. Parallel sibling sites require parallel provenance — silently covering one and leaving the other untagged is a plan defect. Reading code is `read:`, not `ran:`; executable proof requires running the artifact.

**Rule J — Parallel-cases consistency** — When a task mandates identical treatment across N inline homes (e.g., "all four detection homes must generalize to consequence test", "all three landing sites must harmonize with existing discipline"), the developer MUST verify consistency before pre-completion check. Mechanism: a single-grep pre-completion check (`grep -ln '<KEYWORD>' <file1> <file2> <file3> ...`) proves the keyword appears in all N files, or the grep exits with >0 (one or more files missing). A missing keyword in any home creates a self-contradiction in the baked artifact (inconsistent rules appended side-by-side). The planner delegation prompt mandates the pre-completion check as part of the run order; developer executes it as a guard before the gate. Failure to check leaves drift in the installed agents. Documentation: when a pitch names Rule J as motivation ("all four homes get identical treatment or the baked prompt self-contradicts"), the developer reads the run-order mandate and executes the grep check; the check result is recorded in the session log command table (`exit 0` = all hit, `exit 1` = one or more missed). If a pre-completion check is omitted from a delegation prompt but a file carries multiple parallel copies of a rule (e.g., 4 prompt-source files with duplicate inline lists), developer's `## What I Learned This Step` retrospective block should name Rule J as a finding to forward to context-curator for rule strengthening.

**Test mechanism and override-masked branch** (`reviewer.md` § Rule L — Test Must Exercise the CHANGED Branch, Not a Bypass) — Rule L requires the reviewer to cross-correlate the source branch under test with the test setup to confirm the changed code path is actually exercised. A test that sets the env var whose _absence_ is the branch condition is green regardless of whether the default branch is correct. The mechanical backstop is invoking real artifacts with the override unset so genuinely-derived values are observed. The reviewer reports one of two marker lines (plain text, no fenced block): `**Override-unset proof**: ✅ VERIFIED — override unset, <site> derived <value> (cmd row HH:MM:SS, exit 0)` or `**Override-unset proof**: ❌ NOT DEMONSTRATED`. Staleness is handled by cycle ordering and gate-result verdict cross-check — no per-line SHA stamp.

**Near-miss capture and vocabulary boundary** (`developer.md` § Rule O — Curator-Capture on Near-Misses; `reviewer.md` § Rule O — Near-Miss Capture) — Rule O adds a specific trigger to the unconditional `### What I Learned This Step` block: emit when a green-from-birth test or override-masked branch is caught. The `subagent-retrospective-guard.sh` hook enforces block presence; Rule O ensures the pattern accumulates in curator routing. Rule examples use generic names (`OVERRIDE_DIR`, not any project-specific env var); vocabulary in shared rules is project-agnostic — no project-specific launcher, dispatch, or harness names belong in `shared/rules/`.
