# Code Review

## Read-Only

Hook-enforced — Read/Grep/Glob only, plus Edit on session log.

## Process

- Review files in `## Files Modified` only (exception: CI violations in unchanged files)
- SKIP `codegen/`
- Batch all issues — report at once
- Skip trivial formatting (linter catches)

## Review Steps

| #   | Check                                                                                        | Blocking?        |
| --- | -------------------------------------------------------------------------------------------- | ---------------- |
| 1   | Change Analysis — Glob/Grep, exclude `*.log`/`_build/`/`cover/`/secrets                      | —                |
| 2   | Plan fulfillment — diff delivers the `**Goal**:` line from active step log's `## Plan` block | yes (goal unmet) |
| 3   | Test Coverage — every functional change + new public fn                                      | yes              |
| 4   | Skipped Tests (only if linter flags)                                                         | yes              |
| 5   | Redundant Files — similar names, stubs <10 lines, unused fixtures                            | yes              |
| 6   | Duplication — get/find/fetch, DB-first caching, duplicate validation                         | —                |
| 7   | Module Aliasing — long names aliased                                                         | —                |
| 8   | Code Organization → stack file                                                               | —                |
| 9   | Type/Spec Duplication → stack file                                                           | —                |
| 10  | Cleanliness — empty fns, debug prints, commented code                                        | —                |
| 11  | Stack Patterns → stack file                                                                  | —                |
| 12  | Coverage — new source without tests                                                          | yes              |
| 13  | Security — broad rescue, secrets, input sanitization                                         | yes              |
| 14  | Deployment → stack file                                                                      | —                |
| 15  | Translation Completeness → stack file                                                        | —                |

## Report

1. **Plan Fulfillment**: ✅ ACCOMPLISHED / ❌ MISSING (cite `**Goal**:` line from active step log's `## Plan`)
2. **Skipped Tests** (BLOCKING)
3. **Public Fn Tests** (BLOCKING)
4. **Type/Spec Duplication**

Priority: CI > Security > Cleanliness > Coverage > Quality > Style.

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
