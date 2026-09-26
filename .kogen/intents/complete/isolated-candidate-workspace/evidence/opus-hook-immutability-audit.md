**Verdict: READY.** The installing Candidate cannot change its own Stop judge without the current controller refusing the Build, and the Draft keeps all hook paths immutable. I found no blocking contradiction. I only read files: nothing was edited, no paid target was run, and no historical receipt is counted as proof.

## 1. Can the Candidate alter its own judge?

- `.codex/hooks.json` finds `check.sh` and `verification_policy.py` through `git rev-parse --show-toplevel`; `check.sh:18` runs `stop_runner.py` from that same root.
- After each Developer turn and before verification state is read (`build.ex:393-395`, `419-421`, `446-453`), `build.ex:480-484` runs `GuardedPaths.check`. It rejects any changed path outside guarded paths, including tracked modes, untracked files, and ignored files (`guarded_paths.ex:42-70`, `147-150`). Hook/config edits, additions, deletions and mode changes therefore stop acceptance.
- `verification_plan.ex:96` independently locks target-catalog bytes after admission.
- A hostile process that changes and restores bytes within a turn remains outside this structural Intent, as disclosed by the containment non-goal.

## 2. Hook immutability in the Draft

- No `.codex` path appears in `may_change_guarded_paths` or scenario `affected_paths`.
- `admitted-hook-immutability` requires every path, type, mode, byte count and SHA-256, covering missing, added, removed, renamed, symlinked and changed entries, with checks after every role and before publication plus a malicious mutation control.
- Evidence is assigned to `exact-candidate-routing` and `control-plane-preservation` through hook-tree hashes, live-native preservation, and a mutation-that-must-stop control.

## 3. Who judges the installing Build

- `INTENT.md` and `control-plane-preservation` distinguish admitted controller/Stop authority judging installation from offline and selected live targets exercising future Candidate routing.
- The Stop runner judges target exit codes; Candidate tests producing evidence is existing behavior, not new authority.
- No wording hot-loads Candidate controller modules or lets Candidate-authored state approve installation.

## 4. Can explicit roots work without changing hooks?

Yes, through controller-owned Elixir:

- `stop_runner.py:7` derives the linked worktree Git root; `:61` resolves that worktree's index; `:163` consumes supplied absolute state/history paths.
- Its `project_root` equality check (`:43-44`) requires `Verification.initialize` to accept the explicit Candidate root instead of deriving control from tracking (`verification.ex:253-260`). That Elixir file is guarded.
- `verification_policy.py:192-199` reads `KOGEN_PROJECT_ROOT`; `environment.ex:88` supplies it and accepts a worktree `.git` file.
- `harness.ex:605` and the Codex Port launch currently inherit cwd, while `Check` already has explicit-root execution. All necessary Elixir owners are guarded.

## 5. Authority cutover

- Future Builds temporarily use unchanged Candidate-local hooks.
- Moving verification out of Stop is explicitly the next Intent.
- Compatibility behavior, dual hooks and early authority changes are excluded.

## Nonblocking notes and reconciliation

- The audit recommended removing `priv/kogen/verification_targets.yaml` from change authority because current admission makes it effectively immutable. It was removed from guarded and affected paths.
- The audit noted `same-candidate-lifecycle` did not mention hooks despite sharing the immutability risk. Its acceptance now requires the admitted hook/config manifest to stay identical across every role and attempt.

**READY**
