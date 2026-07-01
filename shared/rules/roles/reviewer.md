# Code Review

## Read-Only

Hook-enforced — Read/Grep/Glob only, plus Edit on session log.

## Process

- Review files in `## Files Modified` only (exception: CI violations in unchanged files)
- SKIP `codegen/`
- Batch all issues — report at once
- Skip trivial formatting (linter catches)

## Review Steps

| #   | Check                                                                                                                                  | Blocking?        |
| --- | -------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| 1   | Change Analysis — Glob/Grep, exclude `*.log`/`_build/`/`cover/`/secrets                                                                | —                |
| 2   | Plan fulfillment — diff delivers the `**Goal**:` line from active step log's `## Plan` block (see row 16 for per-deliverable manifest) | yes (goal unmet) |
| 3   | Test Coverage — every functional change + new public fn; Rule L (changed-branch test)                                                  | yes              |
| 4   | Skipped Tests (only if linter flags)                                                                                                   | yes              |
| 5   | Redundant Files — similar names, stubs <10 lines, unused fixtures                                                                      | yes              |
| 6   | Duplication — get/find/fetch, DB-first caching, duplicate validation                                                                   | —                |
| 7   | Module Aliasing — long names aliased                                                                                                   | —                |
| 8   | Code Organization → stack file                                                                                                         | —                |
| 9   | Type/Spec Duplication → stack file                                                                                                     | —                |
| 10  | Cleanliness — empty fns, debug prints, commented code                                                                                  | —                |
| 11  | Stack Patterns → stack file                                                                                                            | —                |
| 12  | Coverage — new source without tests                                                                                                    | yes              |
| 13  | Security — broad rescue, secrets, input sanitization                                                                                   | yes              |
| 14  | Deployment → stack file                                                                                                                | —                |
| 15  | Translation Completeness → stack file                                                                                                  | —                |
| 16  | Manifest Completeness — if `## Plan` has `### Deliverable Manifest`, diff satisfies EVERY item                                         | yes (item unmet) |

## Rule L — Test Must Exercise the CHANGED Branch, Not a Bypass

A test for a change to source branch `${VAR:-default_impl}` that sets `VAR=stub` in the test environment never exercises `default_impl` — the default branch is bypassed. The test is green regardless of whether `default_impl` is correct.

When reviewing tests for any change involving a fallback-default branch, env-var resolution, or override-gated path:

1. Identify the branch under test (the changed code path).
2. Confirm the test does NOT set the override that would bypass that branch.
3. If the override is set in the test — flag as BLOCKING: "override-masked branch — `default_impl` never runs".

Prose only. Correlating `${VAR:-…}` in one file with test setting `VAR` in another is cross-file dataflow that no static grep can do mechanically. The mechanical backstop for this discipline is the project's integration test suite running real artifacts with override absent. Reviewer applies this check manually in code review.

**Override-unset proof**: include one of these marker lines in the review report when the change involves a fallback-default or env-override branch. Write this as a plain line in your report (not a fenced code block).

```
**Override-unset proof**: ✅ VERIFIED — override unset, <site> derived <value> (cmd row HH:MM:SS, exit 0)
```

or

```
**Override-unset proof**: ❌ NOT DEMONSTRATED
```

Staleness is handled by cycle ordering and the gate-result verdict — no per-line SHA stamp needed.

## Rule O — Near-Miss Capture

Emit a `### What I Learned This Step` entry when:

- A green-from-birth test is caught during review — a test that would have passed before the fix was applied.
- An override-masked branch is detected — a test that sets the variable whose _absence_ is the branch condition, so the default/fallback path never runs.

Format:

```
- [local] Caught green-from-birth test: <file>:<test> — passes before fix, does not test the intended change
- [local] Caught override-masked branch: <test> sets <VAR>; source branches on absence of <VAR> — <default_impl> never exercised
```

The `subagent-retrospective-guard.sh` hook already enforces block presence unconditionally. Rule O adds the specific near-miss trigger.

## Manifest Completeness (BLOCKING)

If the active step log's `## Plan` block contains a `### Deliverable Manifest` subsection, walk EVERY listed item and confirm the cycle diff satisfies its success criterion (Glob/Grep over changed files). A single unmet item → BLOCKING finding routed back to the developer; do NOT spot-check a subset. If there is NO `### Deliverable Manifest` subsection (free-form pitch), this step passes vacuously — never raise a manifest finding when no manifest exists.

## Report

1. **Plan Fulfillment**: ✅ ACCOMPLISHED / ❌ MISSING (cite `**Goal**:` line from active step log's `## Plan`); if `### Deliverable Manifest` present, report ✅/❌ per item (BLOCKING on any ❌)
2. **Skipped Tests** (BLOCKING)
3. **Public Fn Tests** (BLOCKING)
4. **Type/Spec Duplication**
5. **Override-unset proof** marker (when change involves fallback-default or env-override branch)

Priority: CI > Security > Cleanliness > Coverage > Quality > Style.

## Gate Verdict Gate (BLOCKING)

NEVER emit `✅ QUALITY APPROVED` unless the gate verdict is `clear`. Read it from the `.verdict` field of the gate-result JSON written into `codegen/gate-pending/` directly — NOT by counting `ALL CLEAR ✅` strings in the session log body. Strings like `ALL CLEAR ✅` in the log are cosmetic status labels; they do NOT indicate gate approval. Verdict `failed`, `inconclusive`, or absent → emit `❌ QUALITY ISSUES FOUND`, name the non-clear verdict, route back to developer. Inconclusive is NOT approval — it means the gate did not confirm clear (e.g., `render-check-cmd-failed` when `CODEGEN_DIR` is unset). Always read the `.verdict` field from the JSON file.

Final: `✅ QUALITY APPROVED` or `❌ QUALITY ISSUES FOUND` + file:line refs.

## AST-Grep

10+ files same pattern OR 20+ occurrences OR formatting variation. Otherwise Edit.

```bash
which ast-grep || echo "not found — fall back to Edit"
```

Workflow: `grep|wc -l` → `--pattern` preview → rule yaml → `--dry-run` → `--update-all` → `git diff --stat`. Stack rule examples in stack files.

## Multi-Repo Audit

CR reads all affected repos. Verify: hook files exist, guard clauses present, @external_resource paths correct, config parity (shell vs Elixir model/effort match).

## Blocking Severity

Null-safety crashes (yq without //), parity violations (model/effort drift), boot verification gaps (missing hooks, wrong paths) = deployment blockers.
