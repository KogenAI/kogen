# Size Governance — Byte Caps, Line Caps, Budget Gates

The reflexive owner: size governance itself is a domain, and its absence as a stated domain was
directly causal to `context/`'s size-partition-wearing-domain-partition failure (see
`context/curator-routing.md`'s Ownership Test for the fix). This file states the constraints; it does
not itself decide whether the cap mechanism is the right shape long-term — that is a separate,
deliberately-deferred question (per-domain budget vs. per-file, summary+detail two-tier read, etc.).

## `context/*.md` Byte Cap — 40,960 Bytes, Per-File, Hard Gate

`curator-context-size-gate.sh` denies ANY role's Edit/Write/MultiEdit to `context/<file>.md`,
`PROJECT_CONTEXT.md`, or `codegen/PROJECT_CONTEXT.md` when the PROJECTED post-write byte size exceeds
40,960 B — computed as `on_disk - old_bytes + new_bytes` for an Edit, or the literal content size for a
Write. Role-agnostic (fires for any role, not just curator). Fixed in the writer's OWN turn — a denied
write must be resolved before the cycle continues; it cannot be deferred to commit time. `CLAUDE.md`/
`AGENTS.md` are deliberately NOT gated — in downstream repos those are rendered symlinks whose bytes are
decided by a `.j2` template, not by the editing agent.

**This cap knows nothing about domain size.** A domain can legitimately exceed 40,960 bytes (hooks:
~122,805 B measured; tests: ~117,656 B measured) — when it does, the cap is a per-FILE constraint, not a
per-DOMAIN constraint, and the correct response is a named-seam file SET, never a forced merge or a
misattributed "overflow" file. See `shared/rules/roles/context-curator.md` § Cap Deny Is Not a Split
Trigger for the full decision procedure.

## STYLE_GUIDE Line Caps (`codegen/rules/**`, advisory, NOT byte-cap-enforced)

`_core`/shared rule files: <50 lines. `roles`/`stacks` rule files: <150 lines. Several files already
exceed these as pre-existing scar tissue — the caps are advisory targets for new content, not a
retroactive gate. `context-curator-guard.sh`'s edit-time `warn_if_over_cap` no longer warns off these
tier numbers — it predicts the committed `prompt-budgets.txt` row instead (see below), so a file at
its full committed budget (even one that already exceeds its STYLE_GUIDE target) stays silent, and a
file under its tier target but at its committed budget still warns correctly.

## `prompt-size-budget` Gate (hard, freezes current size as ceiling)

Component of `make test`. `templates/generator/prompt_size_budget.py --check` measures every
`shared/rules/{_core,roles,stacks}/**/*.md` line count AND every rendered agent system prompt's byte
size (rendered fresh from repo source — no dependency on `~/.claude` or a prior `make install`), fails
when either exceeds its committed ceiling in `templates/generator/prompt-budgets.txt`. Unlike
STYLE_GUIDE's advisory targets, this gate freezes CURRENT measured size as a hard ceiling — it does not
retroactively fail on pre-existing debt, only on further growth past the committed baseline.

`prompt-budgets.txt` is operator-owned: `prompt-budget-writer-only` denies every agent write path to it
(Edit/Write/MultiEdit, `--write` flag, Bash write-vocab) — for every role, including orchestrator. A red
verdict means shrink the file or evict its lowest-value content and name what was evicted — never raise
the cap. Routes to context-curator's `retire`/compact action (`shared/rules/roles/context-curator.md`
§ Retire / Compact Action).

**A file with no committed row is not a deadlock.** Because the only writer of `prompt-budgets.txt` is
an operator, "no row" must never be a verdict whose sole remedy is a write the agent is denied. So:

- **New rule file, no row** — the ceiling is DERIVED from the STYLE_GUIDE targets (`_core` 50 lines,
  `roles`/`stacks` 150) rather than seeded. A new file is therefore held to a STRICTER bar than the
  grandfathered ceilings beside it, and an overflow has a remedy the author can perform: shrink it.
- **New rendered agent prompt, no row** — still a hard fail. There is no STYLE_GUIDE target to derive
  from and a new subagent template is an operator action anyway; the message names `--write` and says
  it is the operator's to run.
- **Stale row (the file it names is gone)** — reported on stderr, NOT fatal. A deleted file cannot
  overflow anything, and failing on it deadlocked whoever deleted or renamed the file. Until the
  operator prunes it, any file later taking that name is governed by the derived ceiling above, which
  is stricter than the orphaned row.

## Curator Retire/Compact Action

The one place the curator's normal no-re-sectioning ban is lifted — scoped to the named over-budget
file. Every retirement names what it evicts in its own `--learned` text (superseded/duplicate/stale —
never silent). A promotion pushing a file over budget MUST evict or compress an equal amount in the same
pass, or skip the write and note the conflict.

## Editor Pre-Check Discipline

Before editing any `context/*.md` file, run `wc -c <file>` to confirm headroom. A file already over the 40,960-byte cap requires compressing or relocating unrelated content BEFORE the edit can proceed — add-only edits to an already-over-cap file fail at gate time with no escape. Workflow: (1) `wc -c` measure, (2) if over cap, identify an unrelated dense paragraph elsewhere in the same file to compress, (3) apply both edits in parallel, (4) re-measure to confirm under cap before proceeding. Headroom-less edits block the gate and force rework in-cycle; pre-flight discipline prevents cycle-blocking gate denials.

## Open Question (Deliberately Deferred, Not This File's Job to Resolve)

Whether a per-file byte cap is the right mechanism for a corpus with domains larger than any single
file's cap is a genuinely different bet — its own mechanism, its own failure modes. This file makes the
tension STATABLE (a file-set member the curator cannot give a nameable seam is recorded here as
evidence), it does not resolve it.

## Trigger Keywords

40960 byte cap, context file cap, curator-context-size-gate, prompt-size-budget, prompt_size_budget.py, prompt-budgets.txt, STYLE_GUIDE line cap, size governance, retire compact action, cap deny not split trigger, per-domain budget
