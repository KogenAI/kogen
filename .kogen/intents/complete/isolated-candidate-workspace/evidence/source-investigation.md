# Source investigation notes

## Current lifecycle

- `lib/kogen/build.ex` runs the entire Developer, Stop verification, Reviewer, and publication lifecycle in the control process working directory. It holds a Codex selection for the Build but has no Candidate-workspace owner.
- `lib/kogen/git.ex` computes Candidate identity from a private index but nearly all Git operations remain ambient-cwd APIs. A tree hash identifies bytes; it does not retain a distinct workspace.
- `lib/kogen/harness.ex` supplies no `cd:` to `System.cmd`. `Kogen.Codex.Environment` configures a trusted project and `KOGEN_PROJECT_ROOT`, but neither proves the native process, hooks, or helpers execute from that root.
- Current publication creates Complete and removes Approved in the control checkout, stages there, and commits the attached current branch. Pre-commit failure restores Approved; a post-commit integrity error does not roll back the commit.
- The installed verification-plan contract binds target plans and receipts to Candidate tree identity, but several paths are relative to `File.cwd!/0`; workspace routing must preserve those newer invariants rather than revive the historical pre-plan orchestration.

## Historical stranded implementation

Command:

```sh
git branch --contains 97109bf93b1db94dfab37748c6d0c203d6e320fd --all
```

Observed refs were five `kogen/build/...` branches and no `main`. Commit `97109bf9` contains a historical `Kogen.Build.Worktree` design and recovery tests, but it is not an ancestor of shaped HEAD and its diff removes the later `rehearsed-verification-plan` contract. Its valid concepts are unique owned worktree/branch identity, explicit control and Candidate roots, ownership-checked cleanup, and guarded main advancement. Its stale assumptions are the old verification orchestration, deleted target catalog/plan code, cwd-scoped routing, and old receipts. It is design evidence only and supplies no acceptance proof for this Draft.

The retained record `.kogen/runtime/scenario-tracking/KwUyGg_h3zghhdjncHkegWzG/record.json` has null top-level Candidate/verdict fields. It records historical work but cannot establish readiness of the current source.

