# Pitch Writing Guide

**Mandatory reading for anyone writing or shaping pitches.**

## What a pitch is

Atomic unit of work. One problem, one solution sketch, one appetite. Written by users directly or extracted from session logs via the `/document` skill. Not a spec — a shaped bet. Builder fills in implementation details; pitch sets boundaries.

## Frontmatter (machine-readable metadata)

A pitch opens with a YAML frontmatter block (`---`-delimited) BEFORE the `## Problem` heading, carrying typed machine fields: `status:` (SKELETON | SHAPING | SHAPED), `appetite:` (small | big), `blocks_on:` (a flow-list of dependency slugs, e.g. `blocks_on: [dep-one]`, or `blocks_on: []`), and `summary:` (a YAML block-scalar `>` holding the 1–3 sentence what/effect/user-impact summary, persisted at SHAPED). The body below the closing `---` stays free markdown (Problem/Scope/Solution sketch/etc.) — the frontmatter is metadata only, never re-parsed as structure.

**Dual-read**: pre-existing pitches with no frontmatter block fall back to the legacy prose conventions — a `> Status:` blockquote for status, `Blocks-on:`/`## Dependencies` prose lines for dependencies. Both `LoopQueue.parse_edges/2` (build-queue topo-sort) and the pitch-format-validators (`.sh`/`.ts`) read frontmatter first, falling back to prose when absent. New pitches should emit frontmatter.

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

## Slug conventions

- Lowercase, hyphens only: `fix-session-log-ordering.md`
- Descriptive but short (3–5 words)
- No dates in slug — file timestamps track that

## Cross-reference

`## Output Contract` in `shared/prompt-fragments/_authoring-spine.txt` (spliced into the shape system prompt per `harnesses/{claude,pi}/manifest.yaml` — concatenated after `harnesses/shared/prompt-bodies/shape.txt` and `_probing.txt`; NOT present in `tools-header/shape.txt`, which only lists tool access). Current text (verify against source before quoting further — spine content evolves independently of this doc):

> The pitch path is `codegen/pitches/draft/<slug>.md`, written as either a bare repo-relative path or the `<cwd>`-prefixed absolute form — the hook's `repo_relative()` normalizes both to the same repo-relative string before matching `^codegen/pitches/`. Verify the correct pitch path by checking where existing pitches are located in your repo (e.g., `ls codegen/pitches/` or check recent git log) — the exact on-disk location depends on your project layout. Write a correct form (relative or abs-in-cwd) on the FIRST attempt. If rejected with `BLOCKED by orchestrator-no-source-edit`, the `codegen/pitches/` prefix was missing or wrong, not merely the relative/absolute choice.

## Trigger Keywords

pitch, proposal, async communication, why-focused, rule rationale, launcher review, pitch path resolution, codegen/pitches, repo-relative path, abs-in-cwd path, authoring spine, output contract
