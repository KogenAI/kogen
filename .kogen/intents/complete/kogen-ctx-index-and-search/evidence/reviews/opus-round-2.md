Verdict: ready

Both blocking findings from round 1 and all six notes are fixed, and the fixes agree across INTENT.md, scenarios.yaml, references.yaml, risks.yaml, questions.md and intent.yaml. I found no new first-try blocker.

**Blocking 1 (missed Candidate files and doc hunks): fixed.**
- `ctx_mcp_test.exs` and `ctx_tool_test.exs` are now under **Delete** (INTENT.md:52-55). They are still not in `may_change_guarded_paths`, which is correct since they get deleted (intent.yaml:24-36).
- **Rewrite** now covers both doc hunks (INTENT.md:56-63 and "Docs" at 294-316).
- The anchors are right at fa48e817: README.md:28 is the prerequisites line and README.md:928 is `## Run the checks`. In scripts/check/README.md, line 3 is the prerequisites sentence, lines 23-27 are step 1 of the check order, and line 56 is the `deps.get` line.
- The Candidate's README hunk only appends at line 979, so "add the prerequisites change" is correct.
- The same items appear in the references.yaml:7-13 note, risks.yaml:46-56 and Assumed 25.

**Blocking 2 (untested CLI behaviour): fixed.**
- "CLI surface" now states the full grammar and the usage line, and says usage is checked before the root is resolved (INTENT.md:221-243). The same fix is on the fix list (INTENT.md:83-86) and in Assumed 20-21.
- Tests A5 (v)-(viii) add 14 usage-error runs (2 + 6 + 6), two of them outside a checkout, and then assert that `KOGEN_CTX_HOME` is still empty.

**Notes: all six adopted.**
- **Hashing:** only files that pass the filters are hashed (INTENT.md:73-75 and 188-190, Assumed 23).
- **Became-skipped:** such a file is reported as `removed` (Assumed 22, test B5).
- **Write errors:** every one uses the `KOGEN_CTX_HOME` wording (INTENT.md:78-80 and 159-162, test A6 (ii)).
- **No HOME:** it is now an error (INTENT.md:156-157, test A6 (i)).
- **`app.start`:** dropped (INTENT.md:47 and 264, Assumed 26). The diff at line 98 shows the line to remove.
- **rustfmt:** P10 is recorded in the probe file.

**New expected outputs: correct.**
- **B5:** 11 files minus the one that becomes non-UTF-8 → `removed lib/shop/format.ex` | `files 10 reindexed 0 removed 1`, and a later `index` shows nothing to do.
- **B4, second half:** after the draft is deleted, `search shipping` prints nothing and the next `index` prints `files 10 reindexed 0 removed 0`. The search's own refresh already removed the draft, so no `removed` line is expected.
- **C3:** `stray` has 5 hits, so `--limit 1` → the first hit then `... 4 more`.
- **A5 (v)-(vii):** every case is a usage error under the stated grammar. `-1` does not start with `--`, so it is taken as the value of `--limit` and rejected as a bad `N`.
- **A6 (ii):** with the index file at 0444 and its directory at 0500, SQLite opens the file read-only, so the first write step (`BEGIN IMMEDIATE`) fails and gets the required wording. `search the` fails the same way because the edit is still pending.

**Non-blocking:**
- **A6 (i) ordering:** the spec doesn't say whether the `HOME` check comes before or after root resolution. If the Developer resolves the root first, `/usr/bin/git` runs with `HOME` unset or empty. That should work, but no probe covers it. Checking `HOME` before resolving the root would take it off the table.
- **A5 wording:** "u = a fresh empty temp dir" per run conflicts slightly with "(viii) … File.ls!(u) == []". Either reading gives a correct test.
