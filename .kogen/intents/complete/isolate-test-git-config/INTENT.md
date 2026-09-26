# Isolate git test fixtures from global ignores

## Why

`test/kogen/tracked_ignored_files_test.exs` builds throwaway git repos with `git_fixture!/0` and commits trash files with
`git add -A`. On a machine whose global `core.excludesFile` lists `.DS_Store` (the Mac Studio's `~/.gitignore`), git never
adds `.DS_Store`, so "a tracked file matching a hard-coded trash pattern fails, naming that file" (line 81) fails and `check`
is red on that machine for every Build (lesson 23). The MacBook has no global excludes, which is why it passed there.

## Outcome

`git_fixture!/0` gives each fixture repo a local `core.excludesFile` pointing at an empty file inside the fixture's `.git`, so
no global or user ignore rule reaches the fixture repos (the real-repository tests at `@repository_root` and the
WorkspaceFixture test are intentionally unaffected: they must keep seeing the real repository's ignore rules). A new
regression test in the same file reproduces the defect on ANY machine: inside its Kogen.IsolatedCase test body it points
`GIT_CONFIG_GLOBAL` at a temporary gitconfig whose `core.excludesFile` lists `.DS_Store`, builds a fixture with
`git_fixture!/0`, commits `.DS_Store` with `git add -A`, and asserts `git ls-files` lists it. The existing assertions are
unchanged. Nothing outside this test file changes; the user's global git config is never touched.

## Non-goals

- Changing any other test (the full `make check` on the Studio with this fix showed no other global-config dependence —
  evidence/probe-2026-09-27.md).
