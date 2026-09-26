# Engine stability probe — 2026-09-23

Shaping evidence, not a verification receipt. Question from the Shaper: how does
a running Build's controller stay on the engine it started with while another
concurrent Build publishes a new Kogen commit to `main`? Checkout `6cdb2912`,
Elixir 1.20.2 / OTP 29, macOS APFS. All probe paths were disposable scratchpad
copies; the control checkout was not modified (`git status` clean afterwards).

## Runtime reads of the live control checkout (source inspection, scout)

- BEAM modules load lazily from control `_build`: `mix run --no-start` in the
  control checkout showed 0/36 Kogen modules and 0 yamerl/jason modules loaded
  at start (interactive code mode).
- Prompts are re-read per attempt via cwd-relative paths:
  `lib/kogen/build.ex:1228-1229,1283-1284` (developer/reviewer.md),
  `lib/kogen/execution_policy.ex:6,30`.
- `priv/kogen/verification_targets.yaml` is re-read and byte-compared per
  attempt (`lib/kogen/build/verification_plan.ex:97`, `build.ex:284,481`): a
  concurrent change fails the running Build closed.
- Compile-time absolute paths (`Path.expand(..., __DIR__)`):
  `lib/kogen/harness/claude.ex:25` settings.json, `lib/kogen/claude_code.ex:15`
  install.py, `lib/kogen/intent.ex:14` models.yaml. Location is baked; bytes
  are read live.
- Hooks: `priv/kogen/claude_code/settings.json` runs
  `$(git rev-parse --show-toplevel)/.codex/hooks/{verification_policy.py,check.sh}`;
  `check.sh:14,18` and `stop_runner.py:7` re-resolve the toplevel per event and
  run `make -C ROOT <target>` (`stop_runner.py:180`). Inside a Candidate worktree
  that toplevel is the Candidate, so the hooks judging a Kogen Build would be the
  Candidate's own editable copy.

## Probe 1: lazy loading under a concurrent recompile

Disposable Mix project; a running `mix run` waits, a second process edits
`lib/b.ex` and `priv/asset.txt` and runs `mix compile` in the same `_build`.

| Variant | B loaded at start | After recompile |
| --- | --- | --- |
| no preload (run twice) | false | `B=b_v2 asset=v2` (switched mid-run) |
| preload all app modules + asset in memory | true | `B=b_v1 asset=v1` |

Invalid first attempt retained as a limitation: an earlier script referenced
`Probe.B` literally, which loaded it at script compile time and masked the
hazard; the dynamic-call rerun above is the valid control.

Conclusion: an unpinned running controller can execute another Build's newly
published code or priv bytes partway through.

## Probe 2: pinned engine copy cost and correctness

`git archive HEAD | tar -x` into a scratch dir, `cp -c -R _build deps`
(APFS clone), `mix compile` there: archive 0.7s, clone 0.2s, compile 0.6s
(36 files recompiled because extracted mtimes differ). `_build` is 24M, `deps`
2.4M. From the copy, `:code.which(Kogen.Build)`, `File.cwd!()`, the priv symlink
(`../../../../priv`) and `Kogen.Harness.Claude` compile source all resolve inside
the copy, so compile-time `__DIR__` paths are re-baked to the engine. Limit: the
recompile is required; reusing uncompiled cloned BEAMs would keep control paths.
Single timing sample on a warm machine; not a latency bound.

## Decision (controller-picked at the Shaper's request)

Pinned engine per Build, not selective preloading. Preloading plus snapshotting
must enumerate every runtime read (modules, prompts, settings, hooks, scripts)
and silently regresses whenever a new read is added; the pinned copy makes every
cwd-relative, `__DIR__`-baked and toplevel-resolved engine read admitted-commit
bytes by construction, at about 1.5s and ~27M per Build.
