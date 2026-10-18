# 07 Committing

Builds edit the checkout in place. The checkout must be clean at the start and used only by the Build while it runs. Kogen commits exactly the final diff that was verified and reviewed, on the same HEAD, with the user's own Git setup; otherwise it leaves the edits uncommitted. It never pushes, rebases, merges or amends.

**GIT-1 — Clean start, Build-only use.** At start, the tree and index must equal HEAD except for the current Intent's folder and its `Acceptance:` files, and other uncommitted Intents' folders `.kogen/intents/<other>/`. Anything else, including another Intent's step files, (modified, deleted, staged, or untracked and not ignored) refuses the Build: `environment/dirty_tree: <n> changed path(s) are not part of an Intent; commit, stash or discard them first`, followed by up to 20 `  <path>` lines (exit 5). While the Build runs, the checkout is the Build's alone; the caller does not edit it. Kogen does not attribute changes to their author: whatever is in the final diff is what gets verified, reviewed and committed.

**GIT-3 — Eligibility.** Kogen commits only when all hold, checked in this order: the baseline hash equals the approved hash; HEAD equals the HEAD recorded at start (`candidate/head_moved: HEAD moved from <a8> to <b8> during the Build; nothing was committed`, exit 1); and the candidate equals the snapshot of the final pass that the review approved (otherwise the Build verifies and reviews again). Model: `build.qnt` `CommitOnlyWhenEligible`.

**GIT-4 — Contents.** The commit holds the whole final diff against the start HEAD — every non-ignored change in the checkout — except other uncommitted Intents' folders (VER-10); that diff is exactly what the final pass verified and the reviewer reviewed. Kogen stages it explicitly and checks that the staged tree equals the reviewed snapshot before committing.

**GIT-5 — Message, identity, signing.** Subject: the Intent title. Body: an empty line, then `Kogen-Intent: <slug>` as the only trailer; no AI attribution. Kogen has no signing rule of its own: it runs a plain `git commit` with the message from a file, so the user's identity, hooks and signing apply exactly as the user's Git configuration says — signed when the user signs, unsigned otherwise. It never adds or removes signing or hook options. No identity: `environment/git_identity_missing` (exit 3). A failing `git commit`: `environment/commit_failed: git commit failed (status <n>); the verified changes are left uncommitted` with Git's output (exit 3), the index restored.

**GIT-6 — After the commit.** Kogen reads the result from the repository: the new commit's parent is the start HEAD and its tree equals the reviewed snapshot; when the user's configuration signs (`commit.gpgsign=true`), the commit carries a signature. Commit hooks run as the user configured them; Kogen supports hooks that leave the staged tree as it is. If the committed tree differs from the reviewed one (a hook rewrote or staged a file), the commit has already been created, so Kogen cannot prevent it; it does not leave that unverified commit on the branch — it moves HEAD back to the start HEAD with a compare-and-swap (`git update-ref HEAD <start> <new>`; the commit stays in the reflog), leaves the hook's changes in the working tree, and prints `candidate/hook_changed_commit: a commit hook changed <paths>; the commit was undone and the changes are left in place` (exit 1).

**GIT-7 — Nothing else.** One successful Build makes exactly one commit. Kogen never pushes, fetches, rebases, merges, cherry-picks, amends, stashes or switches branches, and never moves HEAD except to commit or to undo its own just-made commit under GIT-6 (also when an interrupt arrives during `git commit`, CLI-7).

**GIT-8 — Result.** A landed Build deletes `.kogen/local/approvals/<slug>.json` and prints (exit 0):

```
building is-even
landed is-even {sha8} (Build {id8})
  checks: acceptance 3/3, model not applicable, test passed
  review: approved, 1 note(s)
  note: calc.py:12: the docstring could name TypeError
  repairs: {n} · tokens: {n} · time: {dur}
```

A Build that does not commit leaves the tree as it is, restores the index, and prints `building <slug>`, then `failed <slug>: <reason> (Build <id8>)` (or `stopped <slug>: interrupted (Build <id8>)`), the error line, `  still failing: <names>` (when any, `review` included), `  edited: <path>, <path>, …` and `  run log: <abs path>`.

Scenarios: `features/07-committing.feature`. Model: `quint/build.qnt`.
