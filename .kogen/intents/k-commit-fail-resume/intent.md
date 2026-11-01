# Resume a Build whose only failure was its commit

Slug: k-commit-fail-resume
Model: .kogen/intents/k-commit-fail-resume/model.qnt invariants=LandedReviewed,FailedNoCommit,UncertainStays seed=1 samples=500 steps=10
Acceptance:
- .kogen/intents/k-commit-fail-resume/acceptance.feature
- features/steps/k_commit_fail_resume_steps.js

Fix K-COMMIT-FAIL-RESUME (change_type: fix). A Build can pass every configured check and get review approval, then have `git commit` fail for an environment reason, such as a signing program that is missing or cannot find its key. Today it stops as `environment/commit_failed` and leaves the verified changes uncommitted. HEAD does not move. Its checkpoint stays at continuation stage `commit` (`cli/build/commit.go` saves it before `git commit`). Because of that, `kogen intent resume` refuses with `Build <id>: uncertain commit boundary; inspect effects before starting a freshly approved Build` (`cli/build/resume.go`). `kogen intent inspect` reports `resume_status` `unsupported` with blocker `unsafe_boundary` (`uncertain commit boundary; inspect effects and obtain fresh exact approval for a new Build`, `cli/build/facts.go`). The only way forward is a complete new Build.

After this change, once the environment is fixed, the existing `kogen intent resume <build-id> [--project <checkout>]` finishes the commit. It runs no builder round, review, verification pass or provider request. There is no new command, flag, option or setting, and no timeout, retry or limit changes. Nothing else about building, review or commit changes.

1. **A definite commit failure is recorded as resumable.** In the Build's commit step, `git commit` can exit nonzero (`environment/commit_failed`, exit 3, Git's output as lines, index restored as today). If HEAD is then still the Build's start HEAD, the Build's final checkpoint gets continuation stage `commit_failed` with `tree` set to the reviewed tree it was committing. A `commit_failed` continuation is valid only with a nonempty `tree`. For staged-plan phase validation it is valid where stage `commit` is (the review phase). Every other ending of the commit step keeps stage `commit` and stays refused exactly as today:
   - an interrupt or crash during `git commit`;
   - `candidate/hook_changed_commit` (commit undone);
   - a nonzero exit after which HEAD is not the start HEAD.
   Only definite failures move to `commit_failed`.
2. **The stop says how to continue.** For a `commit_failed` stop, the existing stop output keeps all its lines. Directly before its final `  kogen intent inspect <id> --project <root>` line, it adds one line. `<root>` is shell-quoted as in the neighbouring lines:
   `  commit checkpoint kept: kogen intent resume <id> --project '<root>' commits this verified and reviewed candidate once the commit environment is fixed`
3. **Inspect offers the resume.** For such a Build, `kogen intent inspect <id> [--json]` reports:
   - `resume_status` `potentially_available` (human: `resume: potentially_available (not authorization)`);
   - `next_command` `kogen intent resume <id> --project '<root>'`;
   - exactly one blocker, the recorded failure itself: `class` `environment`, `reason` `commit_failed`, `detail` `git commit failed (status <n>); the verified changes are left uncommitted`, with Git's output lines as `paths`. That is the existing generic failure blocker; there is no `unsafe_boundary` blocker.
   Stages `startup`, `tool` and `commit` keep `unsupported` and `unsafe_boundary`.
4. **Resume validates exactly as today.** The existing checks run unchanged, in their existing order and with their existing messages: identity, run and index paths, HEAD, blocker, approval, baseline, configuration, Intent, index custody, original index backup, and a candidate identical to the checkpoint's. Stage `commit_failed` is simply no longer refused at the uncertain-boundary check; `tool`, `commit` and `startup` still are. Anything changed after verification is refused with the existing reason, before any new run and with nothing changed. Examples:
   - an edited file: `candidate/resume_refused: Build <id>: candidate contents/modes or unrelated paths changed: <paths>; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build`;
   - a moved HEAD: `HEAD moved or uncertain commit; inspect git log`;
   - changed approval inputs: `approval changed`, `baseline changed: <path>`, `baseline/configuration changed`, `saved Intent differs from exact approved contract`.
   The checkpoint must also record, under `last_pass` and `last_review`, a green clean pass and an `approve` review whose trees both equal `continuation.tree`. If it does not, the resume is refused as `malformed required checkpoint fields`. Both builder kinds resume this way, native and external (claude-code), with both reviewer kinds. Only builder stages refuse external builders, and only review stages consult the external-review rules.
5. **Resume commits only.** After validation, the resume starts its new run with the ordinary lineage line `resuming Build <id> as <new> (root <root>)`. It then prints on stdout:
   `finishing the commit of the candidate verified in pass <last_pass.n> and approved in review <last_review.n>, with no builder round, no review and no rerun of its checks`
   It then runs the ordinary commit step on the saved approved pass and review: `kogen: committing`, the same baseline, HEAD and tree guards, and the same plain `git commit` with the user's signing and hooks. That makes one commit of `continuation.tree` on the start HEAD and deletes the approval. It prints the ordinary landed output `landed <slug> <sha8> (Build <new>)` and its following lines, and writes `result.json` with outcome `landed`, `commit`, `resumed_from`, `root_build`, and the unchanged cumulative `passes` and `reviews`. Setup, fixers, checks, acceptance, model check, builder and reviewer do not run, and no provider request is made. The existing login precondition of resume is unchanged. If the commit step finds the candidate is no longer the reviewed tree, the resumed Build stops without a commit and without starting verification or review. It must never fall back to a new verify/review cycle. If `git commit` fails again, the resumed run stops as `environment/commit_failed` with a `commit_failed` checkpoint and the hint line of rule 2. Another explicit resume may try again; nothing retries automatically.
6. **Documentation.** Update the statements that a failed commit cannot be continued:
   - README's resume paragraph (`Unsafe drift or uncertain executed tools/commits are refused ...`);
   - `spec/prose/07-committing.md` GIT-5 (the failing `git commit` sentence);
   - `spec/prose/04-building.md` (the resume paragraph's `uncertain tool or commit execution may be refused`).
   Each must say that a definite `environment/commit_failed` stop with HEAD unchanged is finished by `kogen intent resume`, committing only. Uncertain commit boundaries stay refused.

## Decisions
- Finish a definitely failed commit through the existing `kogen intent resume`, with no builder, review, check rerun or provider request, and no new command, flag, option, timeout, retry or limit (source: request)
- Refuse with the existing clear reasons when the tree, HEAD or approval inputs changed after verification (source: request)
- Keep every other build, review and commit behavior, including the refusal of uncertain commit boundaries (interrupts, crashes, undone hook commits) (source: request)

## Source comparison
- Addressed Problem (`environment/commit_failed` after green verification and approved review; resume refused with `uncertain commit boundary`; inspect `resume: unsupported`, blocker `unsafe_boundary`): rules 1-5; acceptance scenario 1 reproduces it with a failing signing program on the shipped binary.
- Addressed Evidence f283e43f, 4668db51 and a5c382af (signing program missing, or its key not found under the executor HOME; tree exactly the verified changes; HEAD unmoved): rule 1 records exactly that state as resumable; rule 4 accepts native and claude-code Builds alike. The fixture's failing program prints `fixture signing program: no signing key under this HOME` and exits 1, so git exits nonzero.
- Addressed Need 1 (finish through existing commands once the environment is fixed, without re-running builder or review): rules 2, 3 and 5; scenario 1.
- Addressed Need 2 (refuse with a clear reason when tree, HEAD or approval inputs changed, as today): rule 4; scenario 2 covers the tree edit, Go tests cover HEAD and approval.
- Addressed Need 3 (nothing else changes): uncertain boundaries stay refused; commit, review and verification code paths are unchanged.
- Addressed acceptance evidence (fixture Build whose commit fails once, then succeeds after the fix through resume with the shipped binary; refusal after an edit): scenarios 1 and 2 through `features/steps/go_driver_support.js` and the packaged archive.
- Added, not in the request: the stop hint line (rule 2) and the resume line (rule 5), which make the existing command discoverable and state what the resume skips.
- Omitted: the historical Builds' preserved candidates are evidence only, not inputs.

## Tests
- A definite commit failure with HEAD unchanged records a resumable checkpoint, prints the resume hint and inspect offers resume with the commit_failed blocker: acceptance scenario 1, plus a Go test in cli/build asserting the `commit_failed` continuation with the reviewed tree (regression)
- Resume of that checkpoint makes one commit of the reviewed tree on the start HEAD with no builder round, review, check or provider request: acceptance scenario 1, plus a Go test (regression)
- Resume after the verified tree was edited is refused with the existing drift reason and changes nothing: acceptance scenario 2 (regression)
- Resume of a `commit_failed` checkpoint after HEAD moved or the approval changed is refused with the existing reasons: Go test in cli/build (integration)
- A second commit failure on resume leaves a resumable `commit_failed` checkpoint again: Go test in cli/build (integration)
- Interrupted or hook-undone commits keep stage `commit` and stay refused as `uncertain commit boundary`: the existing resume_test case `uncertain commit boundary` and the GIT-6 spec scenario (existing)
- Only the reviewed tree lands on the start HEAD; failed commits leave no commit; uncertain boundaries never continue: model.qnt invariants (unit)

## Feasibility
- Reproduced on the shipped archive dist/kogen-cb88e830-darwin-arm64.tar.gz (HEAD cb88e83) with the harness in a scratch copy. The fixture Build takes about 2.5 s: pass 1 green, review 1 approve, then `environment/commit_failed: git commit failed (status 128)` with Git's output `error: fixture signing program: no signing key under this HOME`. HEAD was unchanged and checkpoint continuation stayed `{stage: commit, tree}` with last_pass.tree == last_review.tree. Inspect `--json` showed `resume_status` `unsupported` and blocker `unsafe_boundary`. After unsetting `gpg.ssh.program`, resume was refused with `uncertain commit boundary` (exit 1, no new run, 0 provider requests); after also editing app.txt it gave the same refusal. (probe: exit 0)
- The submitted feature, run against that binary, fails both scenarios at the missing resume hint, about 23 s in total. A scratch variant without the hint assertion fails at inspect `resume_status`. Without both, scenario 1 fails because resume exits 1 at `uncertain commit boundary`, and scenario 2 fails on the missing drift reason. Every other stop assertion passed on real data. (probe: exit 1, missing-feature red)
- Cucumber dry run of the feature with every existing `features/steps/*.js` plus the new step file: 2 scenarios bound, no undefined or ambiguous steps. (probe: exit 0)
- Quint 0.33.0: the model typechecked, and `quint run --backend=typescript --invariant='LandedReviewed and FailedNoCommit and UncertainStays' --seed=1 --max-samples=500 --max-steps=10` found no violation. Reachability controls found landing and landing after a refusal. (probe: exit 0, 0.1 s)
- evidence: {"id":"k-commit-fail-resume-observer","kind":"observer","inputs":["features/steps/k_commit_fail_resume_steps.js"],"observers":["features/steps/k_commit_fail_resume_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_commit_fail_resume_steps.js --control good","exit":0,"output":"k-commit-fail-resume observer good\n"},{"name":"bad","command":"node features/steps/k_commit_fail_resume_steps.js --control bad","exit":1,"output":"k-commit-fail-resume observer rejected bad fixtures\n"}]}
