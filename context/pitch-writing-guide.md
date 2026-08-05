# Pitch Writing Guide

**Mandatory reading for anyone writing or shaping pitches.**

## What a pitch is

Atomic unit of work. One problem, one solution sketch, one appetite. Written by users directly or extracted from session logs via the `/document` skill. Not a spec — a shaped bet. Builder fills in implementation details; pitch sets boundaries.

## Frontmatter (machine-readable metadata)

A pitch opens with a YAML frontmatter block (`---`-delimited) BEFORE the `## Problem` heading, carrying typed machine fields: `status:` (SKELETON | SHAPING | SHAPED), `appetite:` (small | big), `blocks_on:` (a flow-list of dependency slugs, e.g. `blocks_on: [dep-one]`, or `blocks_on: []`), `scope:` (a flow-list of repo-relative paths this pitch will edit — inline or multiline; absent = unrouted, never guessed at), `split_subject:` (a two-clause string, `"<clause A>; <clause B>"` or `"<clause A> and <clause B>"`, recording the one-clause test's verdict when a split pitch's `scope:` is a subset of a sibling's — see § Split subject requirement below), `shipped_sha:` (the short commit hash that shipped this pitch, written by the retire machinery at ship time), `shipped_range:` (the `<before>..<after>` range of that commit, written at ship time), and `summary:` (a YAML block-scalar `>` holding the 1–3 sentence what/effect/user-impact summary, persisted at SHAPED). The body below the closing `---` stays free markdown (Problem/Scope/Solution sketch/etc.) — the frontmatter is metadata only, never re-parsed as structure.

**Dual-read**: pre-existing pitches with no frontmatter block fall back to the legacy prose conventions — a `> Status:` blockquote for status, `Blocks-on:`/`## Dependencies` prose lines for dependencies. Both `LoopQueue.parse_edges/2` (build-queue topo-sort) and the pitch-format-validators (`.sh`/`.ts`) read frontmatter first, falling back to prose when absent. New pitches should emit frontmatter.

**Ship recording**: when a pitch is retired (moved `ready/ → shipped/`), the retirer machinery writes `shipped_sha:` and `shipped_range:` into the pitch file immediately before the rename — this is the SOLE ship record. There is no second medium: `LoopQueue.record_ship/4` writes ONLY this frontmatter stamp (verified against production source — zero git-note writers exist); a died-before-mv failure never strands an already-shipped stamp on a pitch still sitting in `ready/`, which the next build's `@`-mention would misread. The frontmatter entry answers "what shipped this pitch?" at the point of contact (opening `shipped/<slug>.md`). Fails open on non-git/nil sha.

## Where to write: relative or abs-in-cwd — both accepted

**Rule: write pitches to `codegen/pitches/draft/<slug>.md`, either as a bare repo-relative path or as the full absolute path prefixed with the resolved project cwd — the write-surface hook normalizes both to the same repo-relative form. Verify the correct on-disk path by checking where existing pitches already live (`ls codegen/pitches/` or recent `git log`) before writing.**

```
# Correct — bare relative (already repo-relative, passed through unchanged)
codegen/pitches/draft/my-feature.md

# Correct — absolute, cwd-prefixed (canonicalised then stripped to repo-relative)
/Users/alice/Areas/Optimum/codegen/codegen/pitches/draft/my-feature.md   (if cwd is the codegen repo root)

# Wrong — missing the codegen/pitches/ prefix entirely
draft/my-feature.md
pitches/draft/my-feature.md
```

## Why it matters

The write-surface hook (`orchestrator-no-source-edit.sh`, used by `shape` and other launchers) calls `repo_relative()` to normalize the target path before matching `^codegen/pitches/`: a bare relative path passes through unchanged (already repo-relative), while an absolute path is canonicalised and stripped to repo-relative via the file's git toplevel — a **deliberate loosening** so both relative and abs-in-cwd forms match (see `session-log.md` § Path Discipline, which states both forms are accepted). Either correct form works on the first attempt — if rejected with `BLOCKED by orchestrator-no-source-edit`, the path was missing the `codegen/pitches/` prefix, not merely relative-vs-absolute; check the project's actual pitch directory layout rather than assuming the form was the problem.

Launchers like `shape` also auto-edit pitches via this same resolved path. If a different path was used, the launcher can't find the file.

## Probing must re-run — file measurements go stale

**When a pitch includes byte-size claims, line-count claims, or tool-invocation outcomes (e.g. "the file is X bytes", "`prettier --check` passes"), re-probe those claims when the cycle starts, not just at pitch-writing time.** Files grow between proposal and build, and a measured state can flip mid-cycle. A probe embedded in the pitch is evidence about the past; the developer re-running the two cheapest and most volatile checks (`wc -c`, `prettier --check`) on the target file as its first action will catch growth or tool-behavior shifts before the work starts. Recording both the old probe result (pitch preamble timestamp) and the new result in the developer's session-log body, with an explicit note on divergence, makes re-probing visible to the downstream reviewer.

## Scope field requirement

**Mandatory: every pitch promoted to `ready/` MUST carry a `scope:` frontmatter field.** The field is a YAML flow-list of repo-relative paths this pitch will edit (e.g. `scope: [test_harness/lib/loop_queue.ex, shared/rules/_core/]`). Write it inline when short, or multiline (key alone on one line, then `[`/items/`]` on following lines) when the list is longer. The deterministic gate is `make test` via `mix codegen.pitches.scope --check --dir=ready` (the `pitch-scope-parity` Makefile leg) — it fails loud when a `ready/` pitch has no `scope:` field or the value is unparseable, naming the offending slug; `/ready` itself surfaces readiness in prose but does not enforce this field. The gate is the authoritative check — no pitch is placed to a build without a declared scope. The `mix codegen.pitches.scope` reader (see § System Components, below) uses this field to partition parallel work and detect conflicts between pitches.

## Handoff record requirement (concrete cross-pitch deferrals only)

**A concrete, path-bearing cross-pitch deferral is recorded bilaterally, not just as a prose pointer.**
When shaping defers real work to a sibling draft AND the deferred work names an affected repo-relative
path in the CURRENT pitch, write the SAME `handoffs:` record into both pitches' frontmatter:

```
handoffs: [<delta-id>::<source-slug>::<owner-slug>::<repo-relative-path>]
```

`<delta-id>` and both slugs are lowercase kebab-case (`[a-z0-9][a-z0-9-]*`); `<source-slug>` and
`<owner-slug>` must differ; the path uses `/`-separated non-empty segments with no leading/trailing
slash, no `.`/`..` segment, no backslash, no comma, no square bracket, and no reserved `::` delimiter.
The OWNER pitch's own `scope:` must also list `<repo-relative-path>` — ownership of a path is proven by
scope, not merely claimed by the record. `handoff_receipt: sha256:<64 lowercase hex>` is NEVER
author-written — `/ready` mints/refreshes it after both sides reconcile (see `context/pitch-lifecycle.md`
§ Frontmatter Schema). A prose-only deferral (`Deferred [...] — see draft <slug>`) remains correct for
genuinely broad/unshaped extractions with no concrete path yet — see
`codegen/pitches/draft/deferred-work-has-exactly-one-owner.md` for the full contract.

## Split subject requirement

**A split pitch must prove it is two bets, not one.** When the shaper splits a pitch into siblings, it runs the one-clause test (spine rule H, outcome (e)) BEFORE writing any file: name the ONE PURPOSE both proposed siblings would serve as a single why-led imperative subject (≤50 chars). One clause names both → do not split, keep one pitch. Naming both genuinely needs two clauses → the split proceeds, and each surviving sibling records the verdict in its own frontmatter: `split_subject: <clause A>; <clause B>` (or `<clause A> and <clause B>`).

The gate is mechanical, not prose-trusting: `mix codegen.pitches.scope --check` (the `pitch-scope-parity` Makefile leg) additionally fails when one `ready/` pitch's `scope:` is a subset of (or equal to) another's and NEITHER declares `split_subject:` — the mechanical shadow of an unproven split. A pitch with a genuinely narrow scope that happens to sit inside another's clears the check by recording its two-clause subject; that recording IS the work the rule asks for. A `scope: []` pitch is excluded from this check entirely (vacuous subset of everything).

## Slug conventions

- Lowercase, hyphens only: `fix-session-log-ordering.md`
- Descriptive but short (3–5 words)
- No dates in slug — file timestamps track that

## System Components

**`mix codegen.pitches.scope [--dir=ready|draft|shipped]`** — read-only operator tool that analyzes pitches in the named directory and reports collision/disjoint/unrouted status:

- **COLLISIONS** — pairs of pitches that declare overlapping edit surfaces (shared file paths in both `scope:` lists). Identifies potential merge conflicts if both run in parallel.
- **DISJOINT** — pitches with `scope:` fields that touch no shared paths with any other scoped pitch in the batch. Safe to run in parallel without conflicts.
- **UNROUTED** — pitches with no `scope:` field (or no frontmatter block at all). Cannot be partitioned; a human must route these manually or investigate whether they have a real scope.

With `--check`, also fails on **SUBSUMED** pairs — a pitch whose `scope:` is a subset of (or equal to) a sibling's, with neither declaring `split_subject:` — the recorded proof that a split pitch is a genuinely separate bet.

With `--check --slug=<slug>`, additionally runs the **HANDOFF GAP** check for that one pitch's
`handoffs:` records (missing counterpart, mismatched record copy, or an owner not listing the path in
its own `scope:`); `--stamp-handoff-receipt` (requires `--check --slug`) mints/refreshes
`handoff_receipt:` in every draft participant once reconciliation is clean. See
`context/pitch-lifecycle.md` § Frontmatter Schema.

Run before a multi-pitch drain (`--queue`) to detect which pitches can safely run in parallel on separate machines.

## Cross-reference

`## Output Contract` in `shared/prompt-fragments/_authoring-spine.txt` (spliced into the shape system prompt per `harnesses/claude/manifest.yaml` — concatenated after `harnesses/shared/prompt-bodies/shape.txt` and `_probing.txt`; NOT present in `tools-header/shape.txt`, which only lists tool access). Current text (verify against source before quoting further — spine content evolves independently of this doc):

## Trigger Keywords

pitch, proposal, async communication, why-focused, rule rationale, launcher review, pitch path resolution, codegen/pitches, repo-relative path, abs-in-cwd path, authoring spine, output contract, split_subject, one-clause test, SUBSUMED, scope subset, bilateral deferral record, handoff gap, handoff_receipt, handoffs, stamp-handoff-receipt

> The pitch path is `codegen/pitches/draft/<slug>.md`, written as either a bare repo-relative path or the `<cwd>`-prefixed absolute form — the hook's `repo_relative()` normalizes both to the same repo-relative string before matching `^codegen/pitches/`. Verify the correct pitch path by checking where existing pitches are located in your repo (e.g., `ls codegen/pitches/` or check recent git log) — the exact on-disk location depends on your project layout. Write a correct form (relative or abs-in-cwd) on the FIRST attempt. If rejected with `BLOCKED by orchestrator-no-source-edit`, the `codegen/pitches/` prefix was missing or wrong, not merely the relative/absolute choice.

## Trigger Keywords

pitch, proposal, async communication, why-focused, rule rationale, launcher review, pitch path resolution, codegen/pitches, repo-relative path, abs-in-cwd path, authoring spine, output contract, split_subject, one-clause test, SUBSUMED, scope subset, handoffs, handoff_receipt, HANDOFF GAP, bilateral deferral record, stamp-handoff-receipt
