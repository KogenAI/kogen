# Pi Hook Test Techniques — Fixture Patterns for Anomaly Testing

Techniques for constructing test fixtures that trigger anomalous code paths in Pi enforcement hooks after presence has been verified. These patterns enable deny-on-anomaly testing without requiring chmod tricks or system-level setup, and work reliably under root.

## Directory-Named File for Present-But-Unreadable Fixtures

**Pattern**: Create a directory with a `.md` extension in place of the expected file.

Example: Create a directory with a `.md` extension in a location where the test expects to find a `.md` file (e.g., a temporary directory under a path like `codegen/logging/`). This directory-as-file substitution occurs only in test setup, never persisted in the repo.

**Behavior**:

- Passes `fs.existsSync(path)` — returns `true` because the directory exists
- Passes `.md` glob filter in `getActiveStepLog()` — `readdirSync(...).filter(f => f.endsWith(".md"))`
- Throws `EISDIR` (errno -21) when `fs.readFileSync()` attempts to read the directory

**Advantages**:

- No `chmod 000` tricks required — works even when running as root (chmod 000 is a no-op under root)
- Dependency-free — uses only standard FS APIs
- Clean separation of "presence check" (passes) from "read check" (fails)

**Hooks using this pattern**:

- `curator-before-committer` (enforcement hook) — directory named `*.md` under `codegen/logging/` to simulate present-but-unreadable log file
- `step-log-section-before-spawn` (enforcement hook) — same technique for `getActiveStepLog()`'s resolved path
- `step-log-completeness` (enforcement hook) — directory-as-file at both activeLog and gate-result.json paths for observe-only diagnostic testing

**Test files**:

- `curator-before-committer.test` — "blocks committer when log resolves but read throws (present-but-unreadable)" case
- `step-log-section-before-spawn.test` — "blocks on unreadable but existing log" case
- `step-log-completeness.test` — two observe-only cases for activeLog and gate-result.json unreadable paths

## `.git/index` Corruption for Repo-Presence-Then-Failure Scenarios

**Pattern**: Delete `.git/index`, then `mkdir` a directory in its place.

**Behavior**:

- `git log -1 --format=%ct` (reads refs/ and objects/, not the index) — succeeds normally
- `git status --porcelain` (depends on the index) — throws
- `git diff --cached --name-status` (depends on the index) — throws
- Any subsequent git call depending on the index fails

**Advantages**:

- Enables "first git call succeeds (proves repo), second git call fails" scenarios
- Corrupted state still recognizable as a repo (`.git/` dir exists, refs and objects intact)
- Clean isolation without touching the working tree

**Restrictions**:

- Only works when BOTH git calls don't depend on the index, or when you want the SECOND to fail. If the first git call depends on the index, both will fail together.
- Example: `git diff --cached --name-only` works (name-only, no index read), but `git status --porcelain` fails (index-dependent)

**Hooks using this pattern**:

- `build-no-success-before-commit` (enforcement hook) — corrupt index AFTER `git log -1 --format=%ct` (commit-timestamp check) succeeds, forcing `git status --porcelain` to throw
- `clean-tree-before-ship` (enforcement hook) — corrupt index AFTER `git rev-parse --show-toplevel` succeeds, forcing `git status --porcelain` to throw

**Test files**:

- `build-no-success-before-commit.test` — new case "blocks build when git status fails after repo-presence check"
- `clean-tree-before-ship.test` — new case "blocks ship when git status fails after repo-presence check"

## `.gitattributes` External Diff-Driver for Per-Call-Failure Injection

**Pattern**: Configure `.gitattributes` with a `diff=<name>` pointing to a nonexistent binary, such as:

```
* diff=badexs
[diff "badexs"]
  textconv = /nonexistent
```

**Behavior**:

- `git diff --cached --name-only` (name-only, no content read) — succeeds, unaffected
- `git diff --cached -- <pathspec>` (with textconv filter, reads content) — throws when textconv binary is invoked

**Advantages**:

- Precise per-call-failure injection — first git call succeeds (repo-presence check), second git call fails (anomaly check)
- Leaves repo structure intact — no file corruption, no index manipulation
- Works in multi-call hooks where you want to isolate exactly which call fails

**Hooks using this pattern**:

- `env-var-sample-consistency` (enforcement hook) — first `git diff --cached --name-only` (repo-absence check) succeeds, second scoped `git diff --cached -- <files>` (content-read for sample consistency) fails with textconv error

**Test files**:

- `env-var-sample-consistency.test` — new anomaly case "blocks when sample diff throws after repo-presence check succeeds"

## Test Isolation Rules

- **Always create fresh tmpDir for each test case** — reusing a tmpDir across cases can leak state
- **Run `npm run build` before test** — Pi extension tests run against compiled `dist/`, not TypeScript source
- **Restore console streams in finally blocks on both paths** — success and error paths must both restore stderr/stdout

## Related Pitfalls

- **`env-var-sample-consistency.ts` whole-string regex bug (FIXED)** — the condition `/^\+/.test(exDiff)` tested the first character of the entire diff string (always `"diff --git..."`, never `+`), making the missing-`.env.sample` deny branch permanently unreachable. Fixed by removing the dead guard and replacing the filter with per-line `l.startsWith("+")` + literal-arg regex. Test assertions updated to exercise the now-reachable deny branch. Related: bash sibling was already correct (`grep -E '^+...'` per-line only, not `^[+-]`); twin unification completed as part of the fix.

## Trigger Keywords

pi hook test, fixture, present-but-unreadable, directory-as-file, git index corruption, textconv driver, per-call-failure, anomaly testing, EISDIR, assertion coverage, hook test technique
