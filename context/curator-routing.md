# Curator Routing Targets — Codegen

Project-specific path mapping for the context-curator role. Defines where `[local]` and `[shared]` learnings land in this repository.

## Local Context Routing

All `[local]` blocks (project-specific knowledge about codegen's structure, modes, hooks, manifests, subagents) route to `context/*.md` files:

- **Architecture & structure** → `context/repo-structure.md`
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
- **Token tuning, model config, roles** → `context/claude-token-tuning.md`
- **Recipes, workloads** → `context/recipes.md`
- **Scaffold behavior, output, symlinks** → `context/scaffold.md`
- **Scaffold mutations, guard tests, credo cleanup** → `context/scaffold-mutations.md`
- **Pi extensions, pi-specific paths** → `context/pi-extensions.md`
- **Rules distribution, rule influence** → `context/rules-core.md`, `context/rules-roles.md`, `context/rules-stacks.md`
- **Subagent DSL, template mechanics, influence stack** → `context/subagent-influence-stack.md`
- **Test coverage, test inventory** → `context/test-coverage.md`
- **Token mechanics (caching, prefix, lookback)** → `context/claude-token-mechanics.md`
- **Pitch writing conventions** → `context/pitch-writing-guide.md`
- **Benchmarking prohibitions, BENCH mode, artifacts, viewer** → `context/test-benchmarking.md`
- **Deployment locations, path derivation, server topology** → `context/deployment-topology.md`
- **Document/usage-rules generation patterns** → `context/codegen-document-patterns.md`
- **Launcher ↔ hook wiring matrix** → `context/launcher-hook-matrix.md`
- **Shape-mode discipline, pitch shaping** → `context/shaper-discipline.md`
- **ExUnit stack test suite, test inventory** → `context/test-harness.md`
- **Test monitoring, watch loops** → `context/test-monitoring.md`

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
- **Token mechanics, caching, prompt tuning** → `context/claude-token-mechanics.md` (project-local; no cross-project `_core` file exists for this topic)

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

## Trigger Keywords

curator routing, context-curator targets, where learnings go, [local] vs [shared], retrospective routing, shared vs local learning, hook-layering routing
