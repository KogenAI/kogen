# Fix pin conditional include test on symlinked temp

Slug: k-pin-test-mac-path
Model: not applicable — a test-only fixture correction with no product state
Acceptance:
- .kogen/intents/k-pin-test-mac-path/acceptance.feature
- features/steps/k_pin_test_mac_path_steps.js

Make `TestPinExecutableConfiguration/an_included_file_and_a_conditional_include` (cli/git/pin_test.go) prove the same behaviour on macOS and Linux from any temporary directory, including one reached through a symlink. The behaviour: after a pin is taken, a change in a conditionally included configuration file (`core.pager` from `one` to `two`) is detected and named `core.pager`. Production code (cli/git/pin.go and the rest of the program) stays unchanged. No new option, limit, timeout or retry.

Cause, observed during shaping: the fixture writes `includeIf.gitdir:<f.Dir>/.git.path` with `f.Dir` exactly as `t.TempDir()` returns it. Git matches a `gitdir:` condition against its Git directory as given, which is the logical path only when the inherited `PWD` names the current directory, and also against that Git directory with symlinks resolved. Git never resolves symlinks in the pattern. The test's Git processes inherit the `go test` process's `PWD` (the package directory), so Git sees only the resolved `/private/var/...` path. A pattern written with the symlinked `/var/folders/...` path therefore never matches. On Linux the same thing happens whenever the temporary directory is reached through a symlink. Kogen never computes the Git directory itself. Both pins of one checkout use the same directory and environment, and a pin through a symlinked checkout path detects the change once the pattern names the resolved Git directory. So the test does not show Kogen mis-resolving symlinked checkout paths, and production stays unchanged.

Change, in test code only (cli/git/pin_test.go, or a cli/git `_test.go` helper file):
- Build the conditional include's `gitdir:` pattern from the fixture repository's Git directory with symlinks resolved: `filepath.EvalSymlinks(f.Dir)` joined with `.git`, so the key becomes `includeIf.gitdir:<resolved dir>/.git.path`. A small test-only helper may build it. Every other line and assertion of the subtest stays: the unconditional `include.path` file and its `core.editor` change, and the `core.pager` change expected as exactly `core.pager`. The pattern keeps naming this repository's Git directory exactly: no wildcard such as `**`, and no dropped condition.
- Add the regression test `TestPinConditionalIncludeThroughSymlinkedCheckout` in package `git`. It creates a real directory with `t.TempDir()` and a symlink to it inside another `t.TempDir()`. It runs `git init -q` at the symlink path with `testEnv()` and uses `New(<symlink path>, testEnv())` as the repository. It writes a conditional include file with `[core]` `pager = one`, adds `includeIf.gitdir:<resolved Git directory>.path` pointing to it (pattern built the same way as above), and takes a pin. It then rewrites the file with `pager = two` and requires the changes to be exactly `core.pager` (through `wantChanges`). With the old unresolved symlink-path pattern this test fails on both macOS and Linux with `changes = [], want ["core.pager"]`.

## Decisions
- The test must prove that a change in a conditionally included file is detected, on macOS and Linux, from any temp directory, including one reached through a symlink. (source: request)
- Production code stays unchanged: shaping found that Kogen does not mis-resolve symlinked checkout paths. Git's own `gitdir:` matching rule causes the failure. (source: request)
- No new option, limit, timeout or retry. (source: request)

## Source comparison
- Addressed: K-PIN-TEST-MAC-PATH, the failing `TestPinExecutableConfiguration/an_included_file_and_a_conditional_include` in cli/git/pin_test.go (added by K-SHAPE-HOOKS 221edcb). Its fixture `includeIf.gitdir:<f.Dir>/.git.path` with `f.Dir` under `/var/folders/...` is replaced by a resolved-path pattern. Acceptance runs it with TMPDIR set to a directory reached through a symlink and set to a resolved directory.
- Addressed: the reported command `go test -count=1 ./git -run '^TestPinExecutableConfiguration$'` runs from `cli` in acceptance (as `-json`), and every subtest must pass. The reported failure `pin_test.go:224: changes = [], want ["core.pager"]` was reproduced during shaping on macOS (Go 1.27.2, git 2.54.0 Apple Git-157) with GOTMPDIR unset and TMPDIR `/var/folders/58/.../T/`, and on a custom symlinked TMPDIR.
- Addressed: "any temp directory, including one reached through a symlink" means a symlinked-TMPDIR scenario and a resolved-TMPDIR scenario. The new `TestPinConditionalIncludeThroughSymlinkedCheckout` builds its own symlinked checkout, so Linux and Kogen's configured go-test check also exercise the case.
- Addressed: "Production code unchanged unless the test shows Kogen itself mis-resolves symlinked checkout paths": the investigation found no Kogen mis-resolution (see prose), so no production change.
- Historical, not re-run: the Studio runner evidence (kogen-runner, tree 298d8a8, 3 of 3 runs, 30 Oct 2026), the run with GIT_CONFIG_NOSYSTEM unset, and the passing Kogen Builds b947bd63 and 33935565. Shaping also observed that an exported GOTMPDIR moves `t.TempDir()` away from TMPDIR, which hides the failure. Acceptance therefore removes GOTMPDIR for its runs.
- Omitted: none. Superseded: only the unresolved-path `gitdir:` pattern in the test fixture.

## Tests
- A change in a conditionally included file is detected when the fixture lives in a temp directory reached through a symlink: update the `gitdir:` pattern in `TestPinExecutableConfiguration/an_included_file_and_a_conditional_include` (regression)
- A pin taken through a symlinked checkout path detects a conditionally included `core.pager` change: add `TestPinConditionalIncludeThroughSymlinkedCheckout` (regression)
- The same subtest still passes from a temp directory with no symlink in its path, and every other `TestPinExecutableConfiguration` subtest is unchanged: run them unchanged (existing)

## Feasibility
- none
