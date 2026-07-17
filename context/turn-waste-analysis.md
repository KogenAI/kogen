# Turn-Waste Analysis — `codegen-analyze` / `codegen-propose`

Stdlib-Python analysis package (`analysis/`) that scans Claude transcripts for wasted-turn patterns and
optionally drafts a proposed-change record. Read-only, no LLM calls in the counters/selection layer.

## Counters (`analysis/counters/`, 7 active + 1 dropped-by-default)

`forbidden_bash`, `user_correction`, `context_missed`, `re_read`, `delegation_churn`,
`hook_intervention`, `tool_failure` — each a standalone module scanning transcript JSONL for one waste
pattern. `subagent_interruption` exists but is dropped by default (see below).

## Confidence Priors (`COUNTER_CONFIDENCE_PRIOR`, `analysis/proposer/__init__.py`)

| Counter                                                    | Prior  |
| ---------------------------------------------------------- | ------ |
| forbidden_bash, user_correction, context_missed            | high   |
| re_read, delegation_churn, hook_intervention, tool_failure | medium |
| subagent_interruption                                      | low    |

`DROP_COUNTERS = {"subagent_interruption"}` — filtered out of proposals by default (infra/low-confidence
signal, rarely points at an actionable, groundable fix).

## Fix-Type Playbook (`COUNTER_FIX_TYPE`)

Carried into the per-cluster LLM prompt so the model knows where to look:

| Counter                 | Target files                                            |
| ----------------------- | ------------------------------------------------------- |
| forbidden_bash          | `harnesses/*/tools-header/*.txt`, `prompt-bodies/*.txt` |
| user_correction         | `shared/rules/**`                                       |
| re_read, context_missed | `context/*.md`, `PROJECT_CONTEXT.md`                    |
| delegation_churn        | orchestrator prompt / role routing                      |
| hook_intervention       | `shared/enforcement/registry.yaml` or launcher prompt   |
| tool_failure            | role prompt bodies                                      |

## `codegen-analyze` (read-only)

Flags: `--since`, `--json`, `--raw`, `--window`, `--threshold-reread`, `--project-dir`. Scans
`~/.claude/projects/<encoded-cwd>/*.jsonl` transcripts. Prints a ranked report; `--json` emits
machine-readable clusters consumed by `codegen-propose`.

## `codegen-propose` (deterministic selection + LLM expansion)

`select.py` is pure/deterministic (no LLM) — filters+ranks `codegen-analyze --json` clusters by
`COUNTER_CONFIDENCE_PRIOR` weight × wasted-turn count, drops `DROP_COUNTERS`, drops clusters below
`--min-wasted-turns` (default 4), caps at `--max` (default 5). The per-cluster LLM expansion into a full
proposed-change record (one `codegen-call` per surviving cluster) happens in the bash launcher, NOT in
`select.py` — keep the pure-selection/LLM-expansion boundary distinct when modifying either.

Output: `codegen/analysis-proposals/<from>_<to>.md` — ephemeral, overwritten each run, gitignored.

## Trigger Keywords

codegen-analyze, codegen-propose, turn-waste, wasted turns, COUNTER_CONFIDENCE_PRIOR, DROP_COUNTERS, COUNTER_FIX_TYPE, analysis-proposals, forbidden_bash counter, re_read counter, context_missed counter, subagent_interruption dropped
