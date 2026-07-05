# Bash Stub Testing Patterns

Patterns for writing deterministic bash test stubs, especially stateful stubs with per-invocation behavior variation.

## Stateful Counter Stubs: Fresh Root Per Logically-Distinct Assertion

A bash test stub that uses a stateful counter file (incrementing on each invocation to return different values/codes per call) must get its own fresh stub root directory if the test case uses the stub in multiple, logically-distinct assertions. Reusing a stateful stub root across two assertions causes state leakage: the counter has already advanced past the "fails on first call" branch from an earlier assertion in the same case, so a later RED-then-GREEN probe won't see the same per-call behavior sequence.

**Fix**: Isolate stateful stubs via separate `make_stub_bin` calls per assertion, giving each a fresh stub root (e.g., `$BASE_TMP/assert1_bin`, `$BASE_TMP/assert2_bin`). The counter file resets to 0 when a new stub root is created, and each logically-distinct assertion (including RED probes) exercises the stub's call sequence from the start, proving the behavior independently.

**Example**: When proving a continue-past-failure guard, a RED probe must use its own stub root so the stateful counter begins at 0 and the first call fails as intended (not skipped because the counter has already advanced from an earlier assertion in the same case).

## RED-then-GREEN Proof Isolation for Stateful Stubs

When validating that a guard correctly handles failure (e.g., a `set +e/rc/set -e` sandwich that isolates a command's failure from the enclosing `set -euo pipefail` shell), the RED-then-GREEN proof must be fully isolated from prior assertions in the test case:

1. GREEN path (main assertion): tests that the guard works correctly (batch continues despite a cluster failure).
2. RED proof: demonstrates that WITHOUT the guard a bare failing command would abort the enclosing shell.

The RED proof must NOT reuse the stateful stub from the GREEN assertion — the counter has already advanced. Instead:

- Use a fresh stub root for the RED probe.
- Invoke the stub with the same stub configuration (counter begins at 0, fails on first call).
- Prove that without the guard (no `set +e` sandwich), a failing stub under `set -euo pipefail` causes the subshell to abort (rc=1).
- Prove that WITH the guard (with sandwich), the batch continues (rc=0) and subsequent clusters are still processed.

This isolates RED and GREEN at the stub level, ensuring the RED probe actually exercises the failure path rather than hitting a skipped branch because the counter advanced in an earlier assertion.

## Test Environment Isolation: Ambient Env-Var Leakage

Bash hook `_test.sh` files run directly (not via `run-tests.sh`) inherit ambient shell env vars. If the developer's own agent shell sets `CLAUDE_ROLE` or `PI_ROLE`, direct test invocations see the leakage and may hit unintended code paths. Example: Test 45 in `orchestrator-no-source-edit_test.sh` uses `run_test` (not `run_test_role`), so it reads the ambient env directly; if `CLAUDE_ROLE=build` is set, the test wrongly selects the build-role path and fails for an unrelated reason.

**Fix**: When running hook `_test.sh` files interactively (outside the CI clean shell), strip inherited role vars before invocation:

```bash
env -u CLAUDE_ROLE -u PI_ROLE bash <test>.sh
```

This is NOT needed when tests run via `harnesses/claude/hooks/run-tests.sh` in a clean CI environment — only when invoking directly from within an agent session. The issue is test-invocation discipline (direct runs), not the tests themselves (run-tests.sh context cleans the env).

## git show Redirect Source-Sourcing Trap

When creating a RED-then-GREEN proof by redirecting a hook script via `git show HEAD:<path> > /tmp/copy.sh`, the copied script may use relative sourcing (e.g., `source "$(dirname "$0")/lib/hooks-lib.sh"`). The `dirname` of `/tmp/copy.sh` is `/tmp/`, not the original source directory, so the relative path breaks and the sourced file is not found.

**Fix**: Perform RED-then-GREEN swaps IN-PLACE rather than copying the hook to a temp location:

1. Save the original: `git show HEAD:<hook.sh> > /tmp/pre-fix.sh`
2. Swap in the pre-fix: `cp /tmp/pre-fix.sh <real-hook-path>`
3. Run the test (RED phase): verify it fails/blocks as expected
4. Restore from a backup of the post-fix version or re-edit in-place
5. Run the test again (GREEN phase): verify it passes

This keeps both `dirname "$0"` resolutions in the real source directory where relative sourcing works correctly.

## Trigger Keywords

stateful stub, counter file, test isolation, RED-then-GREEN proof, bash test patterns, ambient env leakage, CLAUDE_ROLE, PI_ROLE, git show, dirname sourcing
