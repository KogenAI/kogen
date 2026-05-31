# Curator Routing Targets — Codegen

Project-specific path mapping for the context-curator role. Defines where `[local]` and `[shared]` learnings land in this repository.

## Local Context Routing

All `[local]` blocks (project-specific knowledge about codegen's structure, modes, hooks, manifests, subagents) route to `context/*.md` files:

- **Architecture & structure** → `context/repo-structure.md`
- **Harness modes, dispatch, launchers** → `context/harnesses.md`
- **Build pipeline, install flow, schema** → `context/core.md`
- **Hooks, guard scripts, registrations** → `context/hooks.md`
- **Subagents, roles, agents** → `context/subagents.md` or `context/roles.md`
- **Development workflow, Make targets, testing** → `context/development.md`
- **Token tuning, model config, roles** → `context/claude-token-tuning.md`
- **Recipes, workloads** → `context/recipes.md`
- **Scaffold behavior, output, symlinks** → `context/scaffold.md`
- **Pi extensions, pi-specific paths** → `context/pi-extensions.md`
- **Rules distribution, rule influence** → `context/rules-core.md`, `context/rules-roles.md`, `context/rules-stacks.md`
- **Subagent DSL, template mechanics, influence stack** → `context/subagent-influence-stack.md`
- **Test coverage, test inventory** → `context/test-coverage.md`
- **Token mechanics (caching, prefix, lookback)** → `context/claude-token-mechanics.md`
- **Pitch writing conventions** → `context/pitch-writing-guide.md`
- **Benchmarking prohibitions** → `context/bench-prohibition.md`

Add new `context/*.md` files and **register them in `PROJECT_CONTEXT.md`** Domain Context Files table to maintain context-index-parity.

## Shared Rules Routing

All `[shared]` blocks (framework patterns, language idioms, style, cross-cutting concerns) route to `shared/rules/**` (on-disk source). Note: `codegen/rules/` is a symlink to `shared/rules/` created post-install — edits always land in `shared/rules/`.

- **Style & code conventions** → `shared/rules/STYLE_GUIDE.md`
- **Hook design, guard patterns, script structure** → `shared/rules/_core/hooks.md` or `shared/rules/_core/guards.md`
- **Subagent DSL, template patterns** → `shared/rules/_core/subagent-dsl.md` or `shared/rules/_core/templates.md`
- **Rules distribution, rule composition** → `shared/rules/_core/rules-distribution.md`
- **Stack-specific patterns** (Phoenix, static-site) → `shared/rules/stacks/<stack>/`
- **Role patterns** → `shared/rules/roles/`
- **Token mechanics, caching, prompt tuning** → `shared/rules/_core/token-mechanics.md`

Always edit `shared/rules/**` directly. `codegen/rules/` is a symlink to `shared/rules/` created by `make install` — do NOT edit through the symlink path as path-resolution varies; edit the `shared/rules/` source directly.

## Write Surface Constraints

- ✅ `context/**` — project-local edits only
- ✅ `shared/rules/**` — cross-project shared patterns
- ❌ `lib/`, `priv/`, `assets/`, `test/`, `bin/` — dev territory
- ❌ `harnesses/<harness>/hooks/` — generated/validated by `hook-registrations.py`
- ❌ `templates/` — schema/templates, edited via process_template.py not hand-edits

## Ambiguous Cases

If a block spans both local and shared:

1. Split the block — one for local routing, one for shared.
2. Reference the pair in curator self-retrospective.

Example: "discovered that phoenix-dev-gate.sh hook behavior differs from static-site-build-check.sh in a way that should be documented":

- `[local]` block → `context/hooks.md` (phoenix vs static differences)
- `[shared]` block → `shared/rules/_core/hooks.md` (common hook design pattern)
