# Run readiness stand-ins under a test origin

Slug: k-consumes-executor-runtime-checks
Model: not applicable — one test helper sets an environment variable; kogen gains no state or interacting rules
Acceptance:
- .kogen/intents/k-consumes-executor-runtime-checks/acceptance.feature
- features/steps/k-consumes-executor-runtime-checks__readiness.js

This Intent is the paired consumer row for kogen-executor's candidate `kogen-runs-unverified-claude-code-runtime` (626c4649). That candidate makes the executor check the managed Claude Code runtime at `claudecode.RuntimePath(home)` (`<home>/.kogen/claude-code/2.1.312/claude`) before every start, including `claudecode.Probe`. Its rules:

- The runtime must be a regular, executable, non-empty file.
- Its size must equal the pinned size for the platform: 275988512 on darwin/arm64, 293592432 on linux/amd64. The size check is skipped when the test download origin `KOGEN_CLAUDE_CODE_URL` (`claudecode.SeamEnv`) is set.
- The runtime, its version folder and `<home>/.kogen/claude-code` must be owned by the current user and not writable by group or others.

The producer's consumer contract check (6 Nov) refuses this repo with:

```
kogen TestClaudeChecks/another_sign-in_route_is_no_subscription  readiness_test.go:86: claude-code: Kogen's Claude Code at claude reports executor/unavailable: Kogen's Claude Code at claude is 158 bytes, expected 275988512; remove 2.1.312 and run again
kogen TestClaudeChecks/another_version_names_the_path_and_the_fix readiness_test.go:65: (same, 160 bytes)
kogen TestClaudeChecks/not_signed_in, pinned_with_subscription_sign-in, stored_token_replaces_sign-in: the same refusal
```

The cause is `managedClaude` in `cli/readiness/readiness_test.go`. It writes a stand-in Claude Code of a few hundred bytes at `claudecode.RuntimePath(home)`. `checkClaude` (`cli/readiness/readiness.go`) runs it through `claudecode.Probe`, and the new size check refuses it before the version or sign-in question the subtest is about.

The pinned kogen-executor (`github.com/KogenAI/kogen-executor v0.0.0-20261106043540-c7382270875a`) exports no pinned size and no test helper. The producer's own fake is unexported test code in another module, and the producer's tests use the test origin. What the pinned executor already provides is the test origin `claudecode.SeamEnv` = `KOGEN_CLAUDE_CODE_URL`, which accepts `http://127.0.0.1:<port>` or `http://localhost:<port>`. The pinned executor reads it only when it installs a missing runtime, and `claudecode.Probe` installs nothing. Setting it therefore changes nothing in the pinned executor while a stand-in is installed, and it skips the size check in the new one. The subtest `not installed yet is no problem with a token and never downloads` already sets `t.Setenv(claudecode.SeamEnv, "http://127.0.0.1:1")`.

The product should be:

1. **managedClaude.** `managedClaude(t, home, version, auth)` in `cli/readiness/readiness_test.go` calls `t.Setenv(claudecode.SeamEnv, "http://127.0.0.1:1")`. A one-line comment says why: the stand-in is not the pinned size, and readiness never installs, so the origin is never contacted. Everything else in the helper stays as it is:
   - the stand-in script, which answers `--version` with the given version and anything else with the given `auth` line;
   - the version folder created with `0o700` and the file written with `0o755` (a umask can only remove bits, so neither is ever group- or other-writable, and the current user owns both);
   - the decoy `claude` first on `PATH`, which must never run.
2. **TestClaudeChecks.** Its seven subtests and every assertion stay unchanged, with the same exact messages:
   - `another version names the path and the fix`: the problem `claude-code: Kogen's Claude Code at <path> reports 2.1.314 (Claude Code), not the pinned 2.1.312`, the fix `rm -rf <RuntimeDir>`, and the decoy did not run;
   - `pinned with subscription sign-in`: no problems or fixes, and the decoy did not run;
   - `not signed in`: the problem `claude-code: no stored token and no claude.ai subscription sign-in` and the fix `kogen provider login claude-code`;
   - `another sign-in route is no subscription`: the same problem;
   - `stored token replaces sign-in`: no problems or fixes;
   - `not installed yet is no problem with a token and never downloads`: unchanged;
   - `not installed and no token`: unchanged.

   No subtest is skipped, added or removed.
3. **Unchanged.** Nothing else changes:
   - `cli/go.mod` and `cli/go.sum` keep every pin, including the kogen-executor pin above (both are protected paths);
   - `cli/readiness/readiness.go` and every other test and file under `cli/`;
   - all behaviour.

   Only `cli/readiness/readiness_test.go` changes.

The acceptance step `features/steps/k-consumes-executor-runtime-checks__readiness.js` runs `go test -count=1 -v -run '^TestClaudeChecks$' ./readiness/` in `cli/`, four times:

- **`pinned`:** against the pinned module. Every subtest must pass.
- **`checked`:** against a temporary copy of the pinned module (`go mod download -json`, then `cp -R`), used through `GOFLAGS=-modfile=<tmp>/go.mod` with a `replace` directive. The checkout's `cli/go.mod` and `cli/go.sum` are never touched. In the copy, `runtimeUsable` in `executor/claudecode/runtime.go` gains the producer's rules: the size rule (skipped when `KOGEN_CLAUDE_CODE_URL` is set), with the message `Kogen's Claude Code at <path> is <n> bytes, expected <size>; remove <RuntimeDir> and run again`, and the ownership and group/other-write rules for the file, its version folder and `<home>/.kogen/claude-code`. Every subtest must pass.
- **`versionblind`:** the `checked` copy in which `claudecode.Pinned` accepts every version. Exactly `another_version_names_the_path_and_the_fix` must fail.
- **`signinblind`:** the `checked` copy in which `claudecode.Probe` answers every `auth ...` call with a claude.ai sign-in. Exactly `not_signed_in` and `another_sign-in_route_is_no_subscription` must fail.

The step removes `KOGEN_CLAUDE_CODE_URL`, `GOFLAGS` and the acceptance report variables from the environment it passes, and sets `GOWORK=off`, so only the test itself can supply the test origin. Run directly as a script (`node features/steps/k-consumes-executor-runtime-checks__readiness.js [--keep-test-origin]`), it prints one line per run and exits 0 only when every run has its expected outcome. This is the observer control in Feasibility.

## Decisions
- TestClaudeChecks passes both against the kogen-executor this repo pins today and against a kogen-executor with the new runtime checks. (source: request)
- The stand-in satisfies the new rules through the test origin the pinned executor already provides: `managedClaude` sets `KOGEN_CLAUDE_CODE_URL=http://127.0.0.1:1` with `t.Setenv(claudecode.SeamEnv, ...)`. The stand-in is not padded to the pinned size, and no size constant is copied into this repo. (source: request)
- Each subtest still proves what it proves today: the version, sign-in and stored-token messages, with unchanged assertions. (source: request)
- No other test, pin (`cli/go.mod`/`cli/go.sum`), behaviour or file under `cli/` changes besides the readiness tests and their helpers. (source: request)
- Every existing test stays green. (source: request)

## Source comparison
- Reported failures `TestClaudeChecks/another_sign-in_route_is_no_subscription` (readiness_test.go:86), `another_version_names_the_path_and_the_fix` (readiness_test.go:65), `not_signed_in`, `pinned_with_subscription_sign-in` and `stored_token_replaces_sign-in`, each with `... is <n> bytes, expected 275988512; remove 2.1.312 and run again`: addressed by rule 1. The acceptance `checked` run reproduces exactly these five failing subtests on the unchanged tree; the two `not installed` subtests already pass.
- "The stand-in must satisfy the new rules the way the pinned executor's own test helper does, or use a test origin that supplies its own manifest so the size is unknown and that check is skipped. Use whichever the pinned executor already provides": the pinned executor provides only the test origin `claudecode.SeamEnv` (rule 1). Readiness never installs, so no manifest is ever requested from the origin.
- "Each test still proves what it proves today: the version, sign-in and stored-token messages": rule 2. Acceptance requires `versionblind` to fail only the version subtest and `signinblind` to fail only the two sign-in subtests. It also requires `stored_token_replaces_sign-in` to pass against `checked`, which reaches its no-problem assertion past the runtime checks.
- "No other test, pin (go.mod/go.sum), behaviour or file under cli/ besides the readiness tests and their helpers changes": rule 3. `cli/go.mod` and `cli/go.sum` are protected paths, so the Build cannot change them.
- Other stand-ins of the managed runtime under `cli/` (`consumes/kogen-executor/helper_test.go`, `claude_runtime_test.go`, `usage_limit_installed_test.go`): omitted. The request names only TestClaudeChecks as refused and forbids other test changes.
- "Keep every existing test green": the configured checks, including `go-test`, run against the pinned executor.

## Tests
- The readiness stand-in is accepted by both the pinned executor and one with the runtime checks: update `managedClaude` in `cli/readiness/readiness_test.go`. The acceptance `pinned` and `checked` runs of TestClaudeChecks check it. (regression)
- TestClaudeChecks still tells another version and a missing claude.ai sign-in apart under the runtime checks: its unchanged assertions. The acceptance `versionblind` and `signinblind` runs check them. (existing)
- The stored token still replaces sign-in: the unchanged `stored token replaces sign-in` subtest, which passes in the acceptance `checked` run. (existing)
- The rest of the suite stays green: the configured go-test check. (existing)

## Feasibility
- Scratch observation (a harness-only run of the same script from outside the checkout, not a Kogen probe record). On the unchanged tree, TestClaudeChecks passes all seven subtests against the pinned module. Against the `checked` copy, five subtests fail with the size refusal. With `KOGEN_CLAUDE_CODE_URL=http://127.0.0.1:1` kept in the environment, standing in for rule 1:
  - `checked` passes;
  - `versionblind` fails only `another_version_names_the_path_and_the_fix`;
  - `signinblind` fails only `not_signed_in` and `another_sign-in_route_is_no_subscription`.

  Each control run took about 7 s, and the checkout stayed clean.
- evidence: {"id":"readiness-runtime-checks-observer","kind":"observer","inputs":["cli/go.mod","cli/go.sum"],"observers":["features/steps/k-consumes-executor-runtime-checks__readiness.js"],"checks":[{"name":"good","command":"KOGEN_CLAUDE_CODE_URL=http://127.0.0.1:1 \"${KOGEN_NODE:-node}\" features/steps/k-consumes-executor-runtime-checks__readiness.js --keep-test-origin","exit":0,"output":"pinned kogen-executor: TestClaudeChecks passed\nkogen-executor with the runtime checks: TestClaudeChecks passed\nruntime checks that accept every version: TestClaudeChecks failed in another_version_names_the_path_and_the_fix\nruntime checks that report every runtime signed in: TestClaudeChecks failed in not_signed_in, another_sign-in_route_is_no_subscription\n"},{"name":"bad","command":"\"${KOGEN_NODE:-node}\" features/steps/k-consumes-executor-runtime-checks__readiness.js","exit":1,"output":"pinned kogen-executor: TestClaudeChecks passed\nkogen-executor with the runtime checks: TestClaudeChecks failed in another_version_names_the_path_and_the_fix, pinned_with_subscription_sign-in, not_signed_in, another_sign-in_route_is_no_subscription, stored_token_replaces_sign-in\nruntime checks that accept every version: TestClaudeChecks failed in another_version_names_the_path_and_the_fix, pinned_with_subscription_sign-in, not_signed_in, another_sign-in_route_is_no_subscription, stored_token_replaces_sign-in\nruntime checks that report every runtime signed in: TestClaudeChecks failed in another_version_names_the_path_and_the_fix, pinned_with_subscription_sign-in, not_signed_in, another_sign-in_route_is_no_subscription, stored_token_replaces_sign-in\n"}]}
