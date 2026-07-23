# Curator Routing Targets — Codegen

Project-specific path mapping for the context-curator role. Defines where `[local]` and `[shared]` learnings land in this repository.

**This map is NOT exhaustive.** Before routing, apply the Ownership Test in `shared/rules/roles/context-curator.md` first: does the learning's SUBJECT have a row below whose file OWNS that subject (not merely a neighbour)? No matching row → create `context/<domain>.md` + its `PROJECT_CONTEXT.md` row in the same turn, and add a row here. A missing row is a finding to fix, not a signal to force-fit into the closest existing entry.

## Local Context Routing

All `[local]` blocks (project-specific knowledge about codegen's structure, modes, hooks, manifests, subagents) route to `context/*.md` files:

- **Architecture & structure, dir→owning-file map** → `context/repo-structure.md`
- **Harness modes, dispatch, launchers** → `context/harnesses.md`
- **Build pipeline, install flow, schema** → `context/core.md`
- **Enforcement compiler, registry schema, pattern dialects** → `context/enforcement-compiler.md`
- **Hook inventory (which hooks exist, per-guard behavior, registrations)** → `context/hooks.md`
- **Hook authoring patterns (how to write/test a hook, output protocol, gate flow)** → `context/hook-authoring-patterns.md`
- **Subagents, roles, agents** → `context/subagents.md`
- **Development workflow, Make targets, testing** → `context/development.md`
- **Bash-generic pitfalls, gotchas, sed/jq/heredoc patterns, RED-then-GREEN test techniques** → `context/bash-patterns.md`
- **ExUnit/fixture/seam/flake test-harness pitfalls** → `context/test-harness-pitfalls.md`
- **Domain-specific pitfalls** → route to the matching domain file's own `## Pitfalls` section (e.g., hook gotchas → `context/hooks.md`, scaffold gotchas → `context/scaffold.md`, core/generator gotchas → `context/core.md`)
- **Recipes, workloads** → `context/recipes.md`
- **Scaffold behavior, output, symlinks** → `context/scaffold.md`
- **Scaffold mutations, guard tests, credo cleanup** → `context/scaffold-mutations.md`
- **Pi extensions, pi-specific paths** → `context/pi-extensions.md`
- **Rules distribution, rule influence** → `context/rules-core.md`, `context/rules-roles.md`, `context/rules-stacks.md`
- **Subagent DSL, template mechanics, influence stack** → `context/subagent-influence-stack.md`
- **Test coverage, test inventory** → `context/test-coverage.md`
- **Token mechanics + per-role tuning (caching, prefix, lookback, cost per role)** → `context/claude-token-mechanics.md`
- **Pitch frontmatter schema, lifecycle, dirs, ship mechanics** → `context/pitch-lifecycle.md`
- **Pitch writing/authoring conventions (prose discipline)** → `context/pitch-writing-guide.md`
- **Benchmarking prohibitions, BENCH mode, artifacts, viewer** → `context/test-benchmarking.md`
- **Deployment locations, path derivation, server topology** → `context/deployment-topology.md`
- **Document/usage-rules generation patterns, usage_rules corpus, INDEX.md** → `context/usage-rules-corpus.md`
- **Launcher ↔ hook wiring matrix** → `context/launcher-hook-matrix.md`
- **Fail-closed enforcement, anti-wedge exceptions, INCONCLUSIVE classification** → `context/fail-closed-posture.md`
- **Pi hook test fixture techniques** → `context/pi-hook-test-techniques.md`
- **Shape-mode discipline, pitch shaping** → `context/shaper-discipline.md`
- **ExUnit stack test suite, test inventory** → `context/test-harness.md`
- **Test monitoring, watch loops** → `context/test-monitoring.md`
- **The Elixir orchestration loop engine, build lock, infra abort, signal handler, budget cap, fallback rungs, warm-resume** → `context/loop.md`
- **Multi-pitch queue drain, drain process model, ship/skip/halt taxonomy, logging GC, circuit breaker, queue-wide spend ceiling** → `context/loop-queue-drain.md`
- **Cycle log (`codegen-log`, `ev` kinds, substance filter, `.active`), gate-pending artifacts, gate verdict truth table** → `context/cycle-record.md`
- **Claude/Pi call envelope, builder asymmetries, transient-error taxonomy** → `context/call-contract.md`
- **Role→model/effort/tools config, escalation ladder, fallback rungs** → `context/role-config.md`
- **Turn-waste analysis, `codegen-analyze`, `codegen-propose`, counters** → `context/turn-waste-analysis.md`
- **Port allocation, `resource_manager.sh`, `~/.ocg/resources.json`** → `context/port-allocation.md`
- **Slash commands (dual-source, dual-install)** → `context/slash-commands.md`
- **Downstream AGENTS.md/CLAUDE.md rendering, `shared/apps/`** → `context/downstream-docs.md`
- **Context-file byte cap, rule-file line caps, `prompt_size_budget.py`, size governance itself** → `context/size-governance.md`

Add new `context/*.md` files and **register them in `PROJECT_CONTEXT.md`** Domain Context Files table to maintain context-index-parity.

## Shared Rules Routing

All `[shared]` blocks (framework patterns, language idioms, style, cross-cutting concerns) route via the `codegen/rules/**` symlink path (target is `shared/rules/`). **Never edit `shared/rules/**`directly — the guard`context-curator-guard.sh`denies raw`shared/rules/`paths; only`codegen/rules/**`and`context/**` are permitted.\*\*

Route in this order (matches the baked curator role rule's decision tree):

1. Learning is about hooks, enforcement, generator, or framework mechanics (explained by agent-readable context data) → `context/*.md` first — sticks on commit, no regeneration needed.
2. Learning is a universal cross-project pattern → `codegen/rules/**` (symlink path; applies to all downstream projects on next `make install`).
3. Learning is project-specific → `context/*.md` (never `shared/rules/`).

- **Style & code conventions** → `codegen/rules/STYLE_GUIDE.md`
- **Hook design, guard layering patterns** → `context/hook-authoring-patterns.md`
- **Shell script structure/discipline** → `codegen/rules/shared/shell-script-discipline.md`
- **Rule file organization, rules distribution/composition** → `context/rules-core.md`
- **Stack-specific patterns** (Phoenix, static-site) → `codegen/rules/stacks/<stack>/`
- **Role patterns** → `codegen/rules/roles/`
- **Token mechanics, caching, prompt tuning** → `context/claude-token-mechanics.md` (project-local; no cross-project `_core` file exists for this topic; this is the SAME file as the local-routing row above — token learnings never split across two files)

Always use `codegen/rules/**` (symlink path) — never `shared/rules/**` directly. The guard `context-curator-guard.sh` denies raw `shared/rules/` paths. `make install` propagates edits to all downstream consumers.

## Write Surface Constraints

- ✅ `context/**` — project-local edits only
- ✅ `codegen/rules/**` — cross-project shared patterns (symlink path; guard denies raw shared/rules/)
- ❌ `lib/`, `priv/`, `assets/`, `test/`, `bin/` — dev territory
- ❌ `harnesses/<harness>/hooks/` — generated/validated by `hook-registrations.py`
- ❌ `templates/` — schema/templates, edited via process_template.py not hand-edits

## Retirement / Compaction

`make prompt-size-budget` (component of `make test`) fails when a `codegen/rules/**` file (rendered agent prompt or raw rule file) exceeds its committed ceiling in `templates/generator/prompt-budgets.txt`. A red verdict here routes to the curator's `retire`/compact action (`shared/rules/roles/context-curator.md` § Retire / Compact Action) — the one place the curator's normal no-re-sectioning ban is lifted, scoped to the named over-budget file. The ceiling is operator-owned — `prompt-budget-writer-only` denies every agent write path to `prompt-budgets.txt`. Curator MUST evict or compress an equal amount in the same pass, or skip the write and note the conflict; never delete a load-bearing fact to hit budget.

## Ambiguous Cases

If a block spans both local and shared:

1. Split the block — one for local routing, one for shared.
2. Reference the pair in curator self-retrospective.

Example: "discovered that the Phoenix loop gate behavior differs from static-site-build-check.sh in a way that should be documented":

- `[local]` block → `context/hooks.md` (phoenix vs static differences)
- `[shared]` block → `context/hook-authoring-patterns.md` (common hook design pattern)

## Note: Edit-Transparent Parity Checks

`context-index-parity-scan.sh` (component of `make test`) fires ONLY on `context/*.md` ADD or DELETE vs HEAD, not on content edits to existing files. Parity checks are file-operation-scoped, not content-scoped. No separate trigger-keyword↔PROJECT_CONTEXT.md row set-equality guard exists — keyword lists in both domain file and PROJECT_CONTEXT.md row can be updated in-place without triggering ADD/DELETE-level guards.

## Trigger Keywords

curator routing, context-curator targets, where learnings go, [local] vs [shared], retrospective routing, shared vs local learning, hook-layering routing, ownership test, no owner create file, cap deny is not a split trigger
