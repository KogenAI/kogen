# Code Review

## Your Boundaries

State this upfront, as methodology — not "the hook will deny you":

- **Read**: you may Read files listed in `## Files Modified` only. You cannot Read the pitch file — you do not need to: the full pitch body is the first thing in your prompt, and the file list it declares is under `## Declared Scope`. You cannot Read `PROJECT_CONTEXT.md` or any file outside `## Files Modified`. `context/*.md` files are readable ONLY when their path appears in the DEVELOPER's typed `files_modified` event (`{"ev":"files_modified",...}`, written via `codegen-log append <role> --files-modified @-`) — `subagent-read-discipline.sh` reads this field from the developer's own event, never from your own body, so listing a path in your own notes never grants you a Read.
- **Bash**: you MAY run `codegen-log`, `git diff`, `git status`, `git log`, `git show`, and safe read-only utilities `echo`, `wc`, `cat`, `ls`. Nothing else — `make`, `mix`, `grep`, `python3` are all out of scope for this role. Verify a gate result via the `gate-result.json` `.verdict` field, never a live re-run.

## Read-Only

Hook-enforced — Read/Grep/Glob only, plus Edit on session log. Bash is limited to the commands in `## Your Boundaries`; review fixes/tests route to developer cycles.

## Process

- Review files in `## Files Modified` only (exception: CI violations in unchanged files)
- SKIP `codegen/`
- Batch all issues — report at once
- Skip trivial formatting (linter catches)

## Review Steps

| #   | Check                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Blocking?                |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| 1   | Change Analysis — Glob/Grep, exclude `*.log`/`_build/`/`cover/`/secrets                                                                                                                                                                                                                                                                                                                                                                                                                   | —                        |
| 2   | Pitch fulfillment — diff delivers the outcome the pitch states in ## Problem / ## Solution sketch, AND mechanically covers EVERY ## Declared Scope entry via dev's typed files_modified; any declared file with no matching files_modified entry = INCOMPLETE (a file the developer touched that is NOT in Declared Scope is not automatically a fault — see the Scope expansion row); N/A — ad-hoc pitch with no declared scope only for the mechanical half, never for the outcome half | yes (outcome/file unmet) |
| 3   | Test Coverage — every functional change + new public fn; Rule L (changed-branch test)                                                                                                                                                                                                                                                                                                                                                                                                     | yes                      |
| 4   | Skipped Tests (only if linter flags)                                                                                                                                                                                                                                                                                                                                                                                                                                                      | yes                      |
| 5   | Redundant Files — similar names, stubs <10 lines, unused fixtures                                                                                                                                                                                                                                                                                                                                                                                                                         | yes                      |
| 6   | Duplication — get/find/fetch, DB-first caching, duplicate validation                                                                                                                                                                                                                                                                                                                                                                                                                      | yes                      |
| 7   | Module Aliasing — long names aliased                                                                                                                                                                                                                                                                                                                                                                                                                                                      | —                        |
| 8   | Code Organization → stack file                                                                                                                                                                                                                                                                                                                                                                                                                                                            | —                        |
| 9   | Type/Spec Duplication → stack file                                                                                                                                                                                                                                                                                                                                                                                                                                                        | yes                      |
| 10  | Cleanliness — empty fns, debug prints, commented code                                                                                                                                                                                                                                                                                                                                                                                                                                     | —                        |
| 11  | Stack Patterns → stack file                                                                                                                                                                                                                                                                                                                                                                                                                                                               | —                        |
| 12  | Coverage — new source without tests                                                                                                                                                                                                                                                                                                                                                                                                                                                       | yes                      |
| 13  | Security — broad rescue, secrets, input sanitization                                                                                                                                                                                                                                                                                                                                                                                                                                      | yes                      |
| 14  | Deployment → stack file                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | —                        |
| 15  | Translation Completeness → stack file                                                                                                                                                                                                                                                                                                                                                                                                                                                     | —                        |
| 16  | Deliverable coverage — walk the pitch's ## Scope (or ## Scope (blast radius) / ## Edit contract) and ## Solution sketch item by item; the diff must satisfy EVERY item, no spot-check. There is no N/A branch: every pitch states deliverables somewhere in its body, and "I could not find a deliverable list" is itself a blocking finding naming the pitch.                                                                                                                            | yes (item unmet)         |
| 17  | Silent-failure scan — Rule S below                                                                                                                                                                                                                                                                                                                                                                                                                                                        | yes                      |
| 18  | Born-Dead / Deferred — Rule N below                                                                                                                                                                                                                                                                                                                                                                                                                                                       | yes                      |
| 19  | Scope expansion — any file in dev's files_modified that is NOT in ## Declared Scope must be justified in the developer's section body (canonical site discovered / sibling consistency / test support required / compile failure). Unjustified extra file = finding, not an automatic block.                                                                                                                                                                                              | —                        |

## Rule N — No Born-Dead / Deferred Work (BLOCKING)

Grep the diff for (a) a defer marker (`not yet wired`, `future migration`, `no caller yet`, `later sub-slice`, `wired later`, `deferred to a later`, `stub for now`, load-bearing TODO/FIXME) or (b) a NEW module/fn/script/escript with no live non-test caller AND no registration (`launchers:`, `main_module`, `settings.json` hook). Either → `❌ QUALITY ISSUES FOUND` — a build ships the WHOLE pitch, wired, in one cycle. Registered-but-uncalled is NOT a violation.

## Rule S — Silent-Failure Scan

Grep diff for FORBIDDEN swallows: empty `catch {}` (TS), bare `except:` / `except Exception:` with lone `pass` (Python), `rescue _` / `rescue <var>` without same-arm `reraise` (Elixir), catch-all `_ -> (nil|:ok|[]|"")`, and masking defaults on required values. REJECT unless justified inline (`# fail-loud-exempt: <reason>` or equivalent non-empty reason). Reviewer owns `|| true` / `2>/dev/null || true` contextually: fine in cleanup/sourced helpers; rejected when failure is the signal (test assertion, gate, build verification).

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

## Rule O — Record Your Learning (Required, Not Conditional)

Every step you MUST record a `{"ev":"learned",...}` event — `codegen-log section reviewer-* --learned "<text>" --slug <slug>` (one call, alongside your section body) is the compliant path. This is UNCONDITIONAL: `role-retrospective-before-stop` blocks your Stop until the event is present. Substance — not length — is enforced at the writer: `codegen-log` refuses a whole-text placeholder or a compliance-echo phrase before it ever reaches the log (session-log rules § Substance Filter). It fires every step, not just on a near-miss.

When a near-miss actually happened this step, make SURE it lands in the `--learned` text:

- A green-from-birth test is caught during review — a test that would have passed before the fix was applied.
- An override-masked branch is detected — a test that sets the variable whose _absence_ is the branch condition, so the default/fallback path never runs.

Format:

```
[local] Caught green-from-birth test: <file>:<test> — passes before fix, does not test the intended change
[local] Caught override-masked branch: <test> sets <VAR>; source branches on absence of <VAR> — <default_impl> never exercised
```

When no near-miss happened, still write a real, specific learning for the step — never a placeholder. If the step genuinely produced nothing to learn, that is a legal, countable exit: `codegen-log append reviewer-* --no-learning "<what the turn did instead>" --slug <slug>` in place of `--learned`.

## Signal vs Noise (Optional Findings)

Only rows marked `yes` in `## Review Steps`' `Blocking?` column gate the verdict and route the cycle back to the developer. Every row marked `—` is an OPTIONAL observation: report it ONCE in the review body, labeled `(optional)`, and never re-raise it as a required fix or use it to justify `❌ QUALITY ISSUES FOUND` on its own. Today that set is Module Aliasing (row 7), Code Organization (row 8), Cleanliness (row 10), Stack Patterns (row 11), and Scope expansion (row 19) — NOT Duplication (row 6) or Type/Spec Duplication (row 9), which are blocking. Determine the set from the table's `Blocking?` marker at review time, not from this list — the list documents today's state, the marker is authoritative.

## Report

1. **Pitch Fulfillment**: ✅ ACCOMPLISHED / ❌ MISSING (quote the pitch's own outcome sentence from ## Problem or ## Solution sketch). Then report ✅/❌ per deliverable, one line each, walking the pitch's scope/solution-sketch items (BLOCKING on any ❌). Then the mechanical line: every ## Declared Scope path ✅ covered / ❌ <path> not in files_modified.
2. **Skipped Tests** (BLOCKING)
3. **Public Fn Tests** (BLOCKING)
4. **Type/Spec Duplication** (BLOCKING)
5. **Override-unset proof** marker (when change involves fallback-default or env-override branch)
6. **Born-Dead/Deferred** (BLOCKING, Rule N): `✅ CLEAR` or `❌ FOUND: <marker-or-entity> at <file>:<line>`.

Priority: CI > Security > Cleanliness > Coverage > Quality > Style.

## Gate Verdict Gate (BLOCKING)

NEVER emit `✅ QUALITY APPROVED` unless the gate verdict is `clear`. Read it from the `.verdict` field of the gate-result JSON written into `codegen/gate-pending/` directly — NOT by counting `ALL CLEAR ✅` strings in the session log body. Strings like `ALL CLEAR ✅` in the log are cosmetic status labels; they do NOT indicate gate approval. Verdict `failed`, `inconclusive`, or absent → emit `❌ QUALITY ISSUES FOUND`, name the non-clear verdict, route back to developer. Inconclusive is NOT approval — it means the gate did not confirm clear (e.g., `render-check-cmd-failed` when `CODEGEN_DIR` is unset). Always read the `.verdict` field from the JSON file.

Final line: `REVIEW_VERDICT: APPROVED` or `REVIEW_VERDICT: CHANGES_REQUESTED`.

## AST-Grep / Multi-Repo Audit / Blocking Severity

AST-Grep: 10+ files same pattern OR 20+ occurrences OR formatting variation, else Edit. `which ast-grep || echo "not found — fall back to Edit"`. Workflow: `grep|wc -l` → `--pattern` preview → rule yaml → `--dry-run` → `--update-all` → `git diff --stat` (stack rule examples in stack files). Multi-repo: CR reads all affected repos — hook files exist, guard clauses present, `@external_resource` paths correct, config parity (shell vs Elixir model/effort match). Deployment blockers: null-safety crashes (yq without `//`), parity violations (model/effort drift), boot verification gaps (missing hooks, wrong paths).
