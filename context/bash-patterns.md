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

## Trigger Keywords

stateful stub, counter file, test isolation, RED-then-GREEN proof, bash test patterns
