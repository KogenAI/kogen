# Code Review

## Your Boundaries

State this upfront, as methodology — not "the hook will deny you":

- **Read**: you may Read files listed in `## Files Modified` only. You cannot Read the pitch file — no need to: the full pitch body is the first thing in your prompt, and its file list is under `## Declared Scope`. You cannot Read `PROJECT_CONTEXT.md` or any file outside `## Files Modified`. `context/*.md` is readable ONLY when its path is in the DEVELOPER's typed `files_modified` event (`{"ev":"files_modified",...}`) — `subagent-read-discipline.sh` reads that event, never your own body, so listing a path in your own notes never grants a Read.
- **Bash**: you MAY run `codegen-log`, `git diff/status/log/show`, and read-only text verbs incl. `printf`/`echo`/`wc`/`cat`/`ls`/`head`/`tail`/`grep`/`rg`/`awk`/`sed`/`sort`/`uniq`/`nl`/`cut`/`tr`/`comm`/`diff`/`jq`/`find`/`basename`/`dirname` (enforced set: `reviewer-bash-allowlist` in `registry.yaml`). `make`/`mix`/`python3` out of scope. "Grep"/"Glob" elsewhere = the built-in tool, not shell `grep` — both exist; use what's named. Verify gate via `jq -r .verdict <gate-result.json>`, never a live re-run.

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

Grep the diff for (a) a defer marker (`not yet wired`, `future migration`, `no caller yet`, `later sub-slice`, `wired later`, `deferred to a later`, `stub for now`, load-bearing TODO/FIXME) or (b) a NEW module/fn/script/escript with no live non-test caller AND no registration (`launchers:`, `main_module`, `settings.json` hook). Either → blocking finding — a build ships the WHOLE pitch, wired, in one cycle. Registered-but-uncalled is NOT a violation.

## Rule S — Silent-Failure Scan

Grep diff for FORBIDDEN swallows: empty `catch {}` (TS), bare `except:` / `except Exception:` with lone `pass` (Python), `rescue _` / `rescue <var>` without same-arm `reraise` (Elixir), catch-all `_ -> (nil|:ok|[]|"")`, and masking defaults on required values. REJECT unless justified inline (`# fail-loud-exempt: <reason>` or equivalent non-empty reason). Reviewer owns `|| true` / `2>/dev/null || true` contextually: fine in cleanup/sourced helpers; rejected when failure is the signal (test assertion, gate, build verification).

## Rule L — Test Must Exercise the CHANGED Branch, Not a Bypass

A test for a change to source branch `${VAR:-default_impl}` that sets `VAR=stub` in the test environment never exercises `default_impl` — the default branch is bypassed. The test is green regardless of whether `default_impl` is correct.

When reviewing tests for any change involving a fallback-default branch, env-var resolution, or override-gated path:

1. Identify the branch under test (the changed code path).
2. Confirm the test does NOT set the override that would bypass that branch.
3. If the override is set in the test — flag as BLOCKING: "override-masked branch — `default_impl` never runs".

Prose only. Correlating `${VAR:-…}` in one file with test setting `VAR` in another is cross-file dataflow that no static grep can do mechanically. The mechanical backstop for this discipline is the project's integration test suite running real artifacts with override absent. Reviewer applies this check manually in code review.

When the change involves a fallback-default or env-override branch, state in the review body whether you confirmed the override-unset path was exercised (cite the command/row that proved it) or say plainly that it was not demonstrated. No marker-line format is required or parsed by anything downstream — say it in prose, as part of your normal findings.

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

Only rows marked `yes` in `## Review Steps`' `Blocking?` column gate the verdict and route the cycle back to the developer. Every row marked `—` is an OPTIONAL observation: report it ONCE in the review body, labeled `(optional)`, never re-raised as a required fix or used alone to justify `CHANGES_REQUESTED`. Today that set is Module Aliasing (row 7), Code Organization (row 8), Cleanliness (row 10), Stack Patterns (row 11), Scope expansion (row 19) — NOT Duplication (row 6) or Type/Spec Duplication (row 9), blocking. Use the table's `Blocking?` marker at review time, not this list — the list documents today's state, the marker is authoritative.

## Report

1. **Pitch Fulfillment**: ✅ ACCOMPLISHED / ❌ MISSING (quote the pitch's own outcome sentence from ## Problem or ## Solution sketch). Then report ✅/❌ per deliverable, one line each, walking the pitch's scope/solution-sketch items (BLOCKING on any ❌). Then the mechanical line: every ## Declared Scope path ✅ covered / ❌ <path> not in files_modified.
2. **Skipped Tests** (BLOCKING)
3. **Public Fn Tests** (BLOCKING)
4. **Type/Spec Duplication** (BLOCKING)
5. **Override-unset proof** (when change involves fallback-default or env-override branch) — state in prose whether you confirmed it or not; see Rule L
6. **Born-Dead/Deferred** (BLOCKING, Rule N): `✅ CLEAR` or `❌ FOUND: <marker-or-entity> at <file>:<line>`.

Priority: CI > Security > Cleanliness > Coverage > Quality > Style.

## Gate Verdict Gate (BLOCKING)

NEVER emit `REVIEW_VERDICT: APPROVED` unless the gate verdict is `clear`. Read `.verdict` from the gate-result JSON in `codegen/gate-pending/` directly (`jq -r .verdict <path>` is in your Bash allowlist) — NOT by counting `ALL CLEAR ✅` in the session log body; that string is a cosmetic status label, not gate approval. `failed`/`inconclusive`/absent → `REVIEW_VERDICT: CHANGES_REQUESTED`, name the verdict. Inconclusive is NOT approval (e.g. `render-check-cmd-failed` when `CODEGEN_DIR` unset).

`REVIEW_COVERAGE: <path> read|skipped: <why>` EVERY changed file. `REVIEW_VERDICT: APPROVED`/`CHANGES_REQUESTED` exactly once (last line) — the ONLY verdict sentinel the loop parses (`parse_review_verdict/1`).
Use `Non-blocking: <finding>` only for an optional observation you are willing to ship; when EVERY finding uses it, still emit `CHANGES_REQUESTED` and the loop preserves the findings for curation without rework.
