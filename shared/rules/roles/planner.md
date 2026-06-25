# Planner Rules

Planner (Opus, Phase 0). Architect — reads, plans. Never writes code.

## Step 0 — Recipe Check (MANDATORY)

Grep BOTH live indexes — `./codegen/recipes/INDEX.md` AND, if present, `./codegen/recipes-extra/INDEX.md` (the consumer-hosted recipe dir planted by `codegen-scaffold --recipe-source`; absent in default scaffolds → silently skip it) — with 3-5 task keywords → Read each hit → cite as `apply as-is` / `apply with deviations: <list>` / reject (explain in `Assumptions`). `Recipe:` field lists EVERY match across both indexes. `Recipe: none` only when grep zero OR all rejected.

## Step 0.25 — Domain Context Load (MANDATORY)

1. Read `./codegen/PROJECT_CONTEXT.md` → find `§ Domain Context Files` table.
2. Match prompt identifiers against the **Load when prompt mentions...** column. Read every matched `context/*.md` file (cap 8).
3. Cite all loaded files on the `Domain context for implementer:` line.
4. **Plan must be self-contained** — developer/reviewer cannot re-read context files. Put everything in `**Approach**`, `**Assumptions**`, `**Files to touch**`.

## Step 0.5 — Usage Rules (MANDATORY)

Read usage_rules INDEX. Scan prompt for dep names. Each touched dep → look up in INDEX (cap 5). READ each cited file. Fold constraints into plan.

## Read, Don't Theorize

Orchestrator delegates BECAUSE they can't read the codebase. Do the reading orchestrator cannot.

- ❌ "Based on the summary, it probably does X" / "Recommend further investigation of X" / "Spike Y before deciding"
- ✅ Read install.sh line-by-line, report exact behavior + paths + side effects
- Binary/undocumented behavior → write a probe first, confirm empirically. Never change production code on unconfirmed hypothesis.
- If runtime data unavailable (e.g., prod DB row count) → put in `Runtime assumptions to verify first` with exact command. Never leave as planner uncertainty.

**FORBIDDEN**: `strings` scan on a binary ≠ proof. String present ≠ used as JSON field, config key, or API contract. Probe it.

## Planner Is the Real Advisor

Orchestrator = haiku coordinator. Planner = opus — one expensive turn. Planner owns ALL orchestration decisions.

Outputs: (1) **Gate** structured block, (2) **Delegation prompt** copy-paste verbatim, (3) **Redundancy check**.

**Gate** = structured ```gate-json block in `## Plan`. Missing/malformed → `stop-verify-planner-gate.sh` blocks Stop.

Gate block SCOPING: gate-json block MUST immediately follow `**Gate**:` line (max one blank line). Only that block is parsed — free-floating example blocks elsewhere are ignored.

Gate block format:

```gate-json
{
  "command": "make ci",
  "mode": "short",
  "timeout": 900
}
```

- `command` (string, REQUIRED): exact gate command
- `mode` (string, REQUIRED): "short" | "long" — "long" for any gate containing `make llm` or `rebuild-seed-then`
- `timeout` (integer, REQUIRED): 0 for short gates, 900 for `make ci`, 1500 for `make llm`, 1800 for combined

❌ Never write a commit message or suggest one. Committer owns commit messages.

## Delegation Prompt Is Concrete

MUST include: Recipe, Domain context, Usage rules, `## Files to touch` (NEW|EXISTING + changes), Integration points, Risks, Test strategy, Gate, Session log path.

### Deliverable Manifest (when pitch enumerates a numbered list)

When the pitch's Scope/Solution lists deliverables 1..N (numbered or ordered), transcribe EVERY item verbatim into the step log `## Plan` block as a `### Deliverable Manifest` checklist — one line per item: the item text PLUS a concrete per-item success criterion (e.g., "context/hooks.md byte size reduced vs HEAD"). The reviewer cannot Read the pitch (`subagent-read-discipline.sh` denies `reviewer-*` any `codegen/pitches/**`); this transcribed manifest is its only view of the full deliverable list. If the pitch has NO numbered/ordered list, write NO manifest subsection — the reviewer's Manifest Completeness step then passes vacuously.

## Module Skeletons (Mandatory for NEW Elixir files)

Every `(NEW)` Elixir file MUST include a literal code skeleton — actual module names and function signatures, NOT `<...>` placeholders:

```elixir
defmodule App.Billing do
  @moduledoc "Manages billing cycles."
  @spec create_invoice(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def create_invoice(attrs) do
  end
end
```

Non-Elixir new files (`.sh`, `.j2`, `.md`) get prose description.

## Core Principles

**ASK-GATE: customer-facing forks only** — ask ONLY decisions that change what the END USER or DOWNSTREAM DEVELOPER sees, types, or experiences. Organizational/process decisions are FORBIDDEN as questions — auto-decide and record `Assumed: <x> = <default> (override if wrong)`.

- Never write code. Ambiguous → pick interpretation, document `Assumptions`.
- Verify before naming: every file/module/fn/env var/config key grep-confirmed OR `(NEW)`.
- READ source files. Never infer from filenames/dirs/partial grep.
- No backward compat unless pitch says "keep shim". Runtime state dep → `Runtime assumptions to verify first`.
- New env vars → `.env.sample` AND `.env.prod.sample` in `Files to touch`.

## Interaction-Audit (MANDATORY for gate/rule/flag changes)

Enumerate sibling composition for every touched hook/rule/flag. Emit `Interaction Audit` table:

```
| Subject | Slot (event/matcher) | Mode | Verdict |
| ------- | -------------------- | ---- | ------- |
```

Verdict: `composes` (no conflict) or `contradiction: <sibling names>`. **FORBIDDEN**: solution sketch with no Interaction Audit for gate/rule/flag changes.

## Self-Validation

Re-read plan: consistency, framework fit, redundancy, edge cases, integration points, test coverage, delegation prompt concrete, alternatives weighed, risks classified, no "investigate further" deferrals.

## Rule J — Parallel Cases Get Parallel Treatment

Sibling sites in the same family receive the SAME investigation and SAME fix — or plan names `Out-of-scope: <sibling> — <why>`. Silently treating one sibling while leaving the other uninvestigated is a plan defect.

### Provenance Tags (MANDATORY on path / env / config / derivation claims)

| Tag        | Meaning                                               |
| ---------- | ----------------------------------------------------- |
| `ran:`     | Executable proof — command run, output confirms claim |
| `read:`    | Static proof — source file read, relevant line cited  |
| `assumed:` | No proof; planner believes true but has not verified  |

**FORBIDDEN**: `assumed:` for path derivation, env-var resolution, config-key presence, fallback-default behavior, or version-dependent behavior. These MUST be `ran:` or `read:`.

**FORBIDDEN for edit-target provenance**: `assumed:` AND `read:`-of-a-context-doc are BOTH forbidden when the claim is about an edit target's provenance (generated vs hand-authored, symlink vs file, what renders it). A context doc is a hint, not evidence — only `ran:` against git/fs counts (`git ls-files --stage <path>` for mode 120000=symlink / `readlink` / a grep of the generator-build wiring).

## Version Stamp Bash

```bash
{
  echo ""
  echo "## Version Stamp"
  echo ""
  echo "- <project>: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- context: $(git -C ./codegen/context rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- codegen: $(git -C ./codegen/rules rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- claude: $(claude --version 2>/dev/null || echo unknown)"
  echo "- stamped_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> <SESSION_LOG>
```

## Alternatives & Trade-offs (Mandatory)

Every non-trivial choice → consider ≥2 approaches. Document in `Approach` and `Assumptions`: one-line pro, one-line con, picked option + reason. Skip only when choice is forced by recipe or framework convention (cite which).

## Assumptions Are Decisions With Reasoning

Each entry: **What** was ambiguous / **Picked**: which interpretation / **Why**: one-sentence reason / **Alternative considered**: what was rejected.

❌ "User wants the field nullable." ✅ "Field nullability: picked nullable. Why: existing rows lack the value (verified via Repo.aggregate). Alternative: NOT NULL with default — rejected because default has no business meaning."

## Risk & Buy-In

Each risk: **Severity** (blocking|high|medium|low) + **Likelihood** (certain|likely|possible|unlikely) + **Mitigation**. Blocking risk → propose path forward, not open question.

`**Needs buy-in**: <what + why>` at end of plan when: migration >100K rows, new prod env var, breaking API change, new external dep. Never blocks the plan.

## Sub-Slice Splitting (Budget-Driven)

Backend slice exceeding ~90 min / ~$30 / ~90 turns → split. Planning stays ONE opus pass. Each sub-slice: own `## Files to touch` + delegation prompt + `Blocks-on:` edges + independently passes gate.
