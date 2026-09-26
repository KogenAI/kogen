# B1 worktree probe — 2026-09-24

Shaping evidence, not a verification receipt. Run by the Shaping Controller in
a disposable clone (`git clone` of this repository into the session
scratchpad), checkout `5b44ceb4`, macOS arm64 APFS, Elixir 1.20 / OTP 29. The
real repository was not modified. Single samples on a loaded machine; timings
are not bounds.

## Topology and cold compile

- `git worktree add -b kogen/build/<id> .kogen/runtime/build-workspaces/<id> HEAD`
  from the control clone: control `git status --porcelain` stayed empty,
  because `.kogen/runtime/` is ignored. The Candidate's `git rev-parse
  --show-toplevel` is the worktree path.
- With only a plain `cp -R` copy of `deps/` (2.4 MB) and no `_build/`,
  `MIX_ENV=test mix compile` in the worktree took real 3.29 s. The resulting
  `_build/test/lib/kogen/priv -> ../../../../priv` resolves inside the
  Candidate, not control. `find deps -type l` found no symlinks in `deps/`.
- `make check` run in a fresh worktree (only `deps/` copied, cold
  `_build`) exited 0 in real 168 s. The stages were format 0.3 s,
  `compile --force` 3.4 s, credo 1.0 s, `mix test --exclude live` 113.6 s and
  rehearsals 51.1 s. The control clone's status stayed clean afterwards. No
  ignored control state (`.kogen/runtime`, drafts, approved packages, the
  coverage matrix) was needed. Full output:
  `b1-make-check-in-worktree-2026-09-24.log`.

## Space in the workspace path (after the Shaper chose Kogen's own directory)

The same clone was used, with the worktree at
`<scratch>/space probe/Application Support/Kogen/build-workspaces/pid/isolated-candidate-workspace-01TEST`
on branch `kogen/isolated-candidate-workspace/01TEST` and only `deps/`
copied. `make check` **exited 2** in real 129.8 s. Format, compile (3.6 s),
credo and the other tests passed. One test failed: `Kogen.LifecycleTest`
"public Shape, explicit fixture approval, and public Build form one offline
lifecycle" (`test/kogen/lifecycle_test.exs:21`). Its fixture's
`target_evidence` Make recipe (`lifecycle_test.exs:357-367`) splices unquoted
`-pa <ebin path>` code paths, so the Stop runner's receipt reads `No file
named probe/Application` and verification exhausts its retries. The split
happened at the scratch directory's space; the real root's
`Application Support` space breaks it the same way. Full output:
`b1-make-check-space-path-2026-09-24.log`. Consequence: B1 must quote that
recipe and treat a space-containing workspace root as a required test
condition. Other space hazards may surface only in provider-backed routes.

## Publication mechanics (control clone, Candidate commit made with `--no-verify` for the probe only)

| Case | Command in control | Result |
| --- | --- | --- |
| uncommitted control edit to a file the commit changes | `git merge --ff-only kogen/build/<id>` | `Aborting`, `main` unchanged |
| uncommitted control edits to other files | same | **fast-forwarded** (so a clean-control check is needed separately) |
| `main` moved (extra commit) | same | `fatal: Not possible to fast-forward, aborting.` |
| clean, unmoved | same | `main` = Candidate commit, status clean |
| CAS wrong old value | `git update-ref refs/heads/main C <wrong>` | refused, `main` unchanged |
| CAS correct old value | `git update-ref refs/heads/main C A` | `main` moved, but control shows `M README.md` (stale index/worktree; needs explicit sync) |

## Cleanup

- `git worktree remove <path>` succeeded when the worktree held only ignored
  files (`_build/`, `deps/`) and deleted them.
- With an untracked non-ignored file it refused: `contains modified or
  untracked files, use --force to delete it`.
- `git branch -d` deleted a merged Candidate branch and refused an unmerged
  one, printing a hint to use `-D`.
- `git worktree list --porcelain` shows each Candidate as `worktree <abs
  path>` / `HEAD <sha>` / `branch refs/heads/kogen/build/<id>`.

## Source facts checked alongside (read-only)

- The hook commands in `priv/kogen/claude_code/settings.json` and
  `.codex/hooks.json` run `$(git rev-parse --show-toplevel)/.codex/hooks/...`.
  `check.sh` re-resolves the toplevel before exec'ing `stop_runner.py`, and
  `stop_runner.py:7` re-resolves it again for `make -C ROOT`
  (`stop_runner.py:180`). The unified verification context already carries
  absolute `state_path`/`history_path` and a `project_root` that must equal
  that toplevel (`stop_runner.py:45`).
- `verification_policy.py` reads `KOGEN_PROJECT_ROOT`
  (`lib/kogen/verification_policy.ex:20-25`) instead of re-resolving.
- Both harness adapters run the provider through `System.cmd("sh", ["-c",
  …])` with no `cd:` (`lib/kogen/harness/claude.ex`,
  `lib/kogen/harness/codex.ex`). `Kogen.Git` functions have no root
  parameter except `changed_paths/1`.
- Inferred from source, not probed: Codex reads project hooks from
  `.codex/hooks.json` in its working project, i.e. the Candidate's tracked
  copy (Kogen passes no hook file to Codex, and `lib/kogen/codex/state.ex`
  forbids `hooks.json` in the credential store). Claude Code gets Kogen's hook
  settings from control `priv/` through `--settings`.
- The real repository already has five stale linked worktrees from
  `97109bf9` under `.kogen/runtime/build-worktrees/checkouts/` (branches
  `kogen/build/<intent-id>/<build-id>`), plus sibling recovery worktrees.
  B1 must leave them alone.

## Limitations

This probe does not establish that Claude Code or Codex pass Kogen's
environment to hook commands in a worktree cwd, that Claude Code resume
finds sessions from a Candidate cwd, or any provider behavior. Those belong
to `live-reviewer-rework` and `live-shape-to-build`.
