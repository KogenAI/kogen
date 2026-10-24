# Production-transition replay

`sh test/migration/replay.sh <kogen> <out>` runs four real production journeys with the given installed `kogen`,
turns what happened into Quint `run` tests over `spec/quint/build.qnt`, and requires `quint test` to pass on them. It
then builds production mutants from an isolated copy of `cli/`, runs the matching journey with each, and requires the
trace generated from that run to fail `quint test`. Files: `test/migration/replay.sh`, `test/migration/replay/`
(`run.js` orchestration, `journeys.js`, `lab.js` harness and observations, `fake.js` scripted provider, `trace.js`
generator, `mutants/*.json`).

## What runs

Everything is local. HOME, the Git repository and the Git configuration are temporary (the caller's global Git
configuration is never read); the credential is a fake ChatGPT token; `KOGEN_PROVIDER_URL` and `KOGEN_AUTH_URL` name a
loopback fake that answers each request from a script. The project is the `add-greeting` fixture
(`test/migration/fixtures/lab-project`) with the installed Cucumber as its acceptance runner, so verification passes are
real.

| Case | Journey (all through the installed program) |
|---|---|
| `approval` | `kogen intent shape` (scripted shaper) and `kogen intent approve`; the Intent is edited and `kogen intent build` must refuse (no run, no provider request); the edit is undone; a Build starts (first builder request: approved baseline, untouched HEAD), the builder reports an invalid blocker (feedback only) and then a valid one, the Build stops `build_blocked`, nothing is committed. |
| `verification-review` | The builder writes a wrong file (red pass), repairs it (green pass), the reviewer blocks (`changes`), `kogen intent resume` reopens the blocker, fresh verification is green, the same reviewer approves, the commit lands. |
| `interruption-resume` | SIGINT while the builder's request is outstanding (exit 130, HEAD unchanged); the approval file is edited and `kogen intent resume` must refuse; the edit is undone; resume continues the conversation, verifies, reviews and lands once. |
| `commit-recovery` | A post-commit hook holds `git commit` open once; kogen is killed with SIGKILL right after the commit exists; `kogen intent resume` must leave HEAD alone, make no second commit and name the commit. |

In the run of the installed kogen the harness also asserts what the journey itself promises (exit codes, HEAD, refusals).
With a mutant it only records deviations in `observations.json`: a mutant may behave differently.

## What is observed

Observations are taken while kogen is blocked: when a request reaches the scripted provider (kogen waits for the
answer), after kogen exits, after it was killed. Each snapshot holds the Build's own records and the harness's own
view: the run log events since the last snapshot of that run, `facts/<id>.json` (trees of the verification passes),
`checkpoint.json` (stage, candidate tree, saved approval), `result.json` (outcome), and Git (HEAD, the commits since
the chain began and whether they carry the `Kogen-Intent:` trailer). The harness recomputes the candidate tree in a
private index and requires it to equal the checkpoint's. Resumed Builds continue the chain of their parent. The
records of every run (`log.jsonl`, `result.json`) are copied under `<out>/cases/<case>/runs/`.

## From observation to Quint

The generator never decides what the model should answer. It maps each observed event to the model action it names and
writes the observed state after it as `.expect(...)`; the model either agrees or `quint test` fails. Candidate
versions are numbers given to trees in the order they were first observed (the start candidate is 0, as in `init`).

| Observation | Model step |
|---|---|
| run log `start` | `init` |
| `pass` n, green / red (tree from `facts`) | `move(Reviewing, v, v, "")` / `move(Loop, v, clean, "")`; after a reopened blocker `retryVerifyWith("green" / "red")` |
| `review` verdict approve / changes | `reviewWith("approve")` / `reviewWith("changes")` |
| `commit` and a Kogen commit on the branch | `commitWith("ok")` (`"commit_failed"` when none is there) |
| `tool_call report_blocker` whose result is only a fingerprint (invalid), `builder_blocker` (valid) | `blockerWith(false)`, `blockerWith(true)` |
| `resume` of a Build that stopped `review_blocked` / any other | `reopenBlocked` / `resume` |
| outcome `interrupted`, any other failure | `move(Interrupted, v, clean, "interrupted")`, `move(Failed, v, clean, <outcome>)` |
| candidate tree changed with no pass (the builder edited files), or nothing happened | `move(<observed phase>, v, clean, <reason>)` |
| anything after a Kogen commit exists | `move(Done, v, clean, "commit")` (the model has no transition after a commit; the expectation is that nothing changed) |

`move` is used as `build.qnt`'s own tests use it: the builder's edits and the outcome of a verification pass are inputs.
Decision steps (`reviewWith`, `commitWith`, `resume`, `reopenBlocked`, `retryVerifyWith`, `blockerWith`) are the
model's own actions.

The expectation after a step is built only from observations:

| Variable | Observed from |
|---|---|
| `phase` | after an event: the next thing the Build was seen doing (a builder or reviewer request, a pass, a commit, the outcome); at the end of a window: the checkpoint stage, the outcome, or `Done` when the commit is on the branch |
| `cand` | the version of the candidate tree (checkpoint), of a pass tree or of a review tree |
| `cleanPassVersion`, `reviewedVersion` | the trees of the last green pass and the last approving review in the chain (both reset by a reopened blocker) |
| `commits`, `committedVersion` | Kogen commits on the branch since the chain began, and the tree of the last one |
| `baselineIntact` | the baseline files hash to what was approved and the approval file is the one the checkpoint saved (absent only after the commit) |
| `headMoved` | commits on the branch without the Kogen trailer |
| `reason` | the outcome (`commit` when a Kogen commit exists) |
| invariant | `Safety` of `build.qnt` is part of every expectation |

Each trace file is a Quint module with one `run <journey><Chain>Test` per Build chain, importing the copy of
`spec/quint/build.qnt` in `<out>/model/`. `quint test` also runs the tests of `build.qnt` itself, which the module
imports: a passing file reports 24 passing (23 of the model and the trace's own test).

## Results

Installed kogen packaged from the working tree (`packaging/package.sh`, `dev+fd3aecea`, darwin-arm64), run with
`sh test/migration/replay.sh`: 86 seconds, exit 0, and the acceptance scenario "Production transitions replay through
Quint and production mutants are refuted" passes against the same archive. `quint test` on every trace, run
separately:

| Case | Trace of the installed kogen | Mutant | Trace of the mutant | First failing step |
|---|---|---|---|---|
| `approval` | 24 passing | `skip-approval-check` | 23 passing, 1 failed, expectation | step 1 of 4, `init`: the Build started although the Intent no longer matches its approval (`baselineIntact == false` observed) |
| `verification-review` | 24 passing | `commit-on-red-pass` | 23 passing, 1 failed, expectation | step 2 of 24, `move(Loop, 1, -1, "")`: after a red pass the Build was seen reviewing |
| `verification-review` | (same trace) | `commit-without-approving-review` | 23 passing, 1 failed, expectation | step 4 of 6, `reviewWith("changes")`: after a blocking verdict the Build was seen committing |
| `interruption-resume` | 24 passing | `resume-ignores-approval-change` | 23 passing, 1 failed, expectation | step 4 of 8, `resume`: the resumed Build ran with an approval file that is not the saved one |
| `commit-recovery` | 24 passing | `resume-commits-again` | 23 passing, 1 failed, expectation | step 5 of 5, the stutter after the resume: two commits on the branch where the model has one |

The first failing step is found by running `quint test` on prefixes of the trace and is recorded in each mutant's
`status.json`; `quint.txt` beside every trace is the full `quint test` output.

## Mutants

Each is a list of exact text replacements in `mutants/<id>.json`, applied to a copy of `cli/` under
`<out>/mutants/<id>/` (a replacement whose text is not found exactly once stops the replay: production code moved).
`mutant.patch` is the diff, `build.log` the `go build`, `status.json` the verdict, `observations.json` and
`trace.qnt` what the mutant did. The mutant program sits in an install-shaped folder that shares `lib/` (Node, Quint,
Cucumber) with the installed kogen.

| Mutant | Change |
|---|---|
| `skip-approval-check` (`build/build.go`) | `intent build` can never refuse an Intent changed after approval. |
| `commit-on-red-pass` (`build/builder.go`, `build/commit.go`) | A red pass is treated as green for review, and the commit no longer requires a green pass. |
| `commit-without-approving-review` (`build/review.go`) | A `changes` verdict is treated like an approval. |
| `resume-ignores-approval-change` (`build/resume.go`) | A resume does not compare the approval file with the one the checkpoint saved. |
| `resume-commits-again` (`build/resume.go`, `build/builder.go`, `git/commit.go`) | A Build stopped inside its commit step resumes by committing the reviewed tree again (as an empty commit), with the HEAD and index checks for that stage removed. |

That is five mutants for four cases: each case needs at least one, and the review gate has two.

## Limits

- The model is abstract. Verification passes and builder edits enter as `move` steps, as in `build.qnt`'s own tests, so
  the replay checks the decisions made on top of them (review, commit, resume, reopen, blocker) and the observed state,
  not the verification itself or the builder.
- Refusals (an Intent edited after approval, an approval file edited before a resume) are not transitions of the model.
  The harness asserts them in the run of the installed kogen and records them in `observations.json`; the trace only sees
  them when a mutant lets the Build go on.
- After a commit exists the model has no transitions, so `commit-recovery` can only check that the resume left every
  observed variable as it was (and the harness asserts that HEAD did not move and that the commit is named).
- A snapshot exists only where kogen is blocked (a request reaching the scripted provider, exit, kill). Between them
  the run log supplies the events, so states inside a step of a Build are not observed.
- Traces are cut after 24 steps (a looping mutant would otherwise exceed what the Quint evaluator can nest); in every
  mutant here the first failing step is far earlier. The provider also refuses after 16 requests, so a looping mutant
  ends.
- One provider (the ChatGPT wire) and one fixture project; SuperGrok, signing, hooks that change the commit and
  `context_exhausted` are covered by the acceptance suites, not by the replay.
- The replay needs Go and Node 22 on `PATH` (or through mise), Git, and Quint in `spec/node_modules`.

## Final run on the 76109e1a-based candidate (24 October, MacBook)

Installed candidate `kogen dev+5fdbd286` (no Elixir in source or archive): `sh test/migration/replay.sh <prefix>/bin/kogen <out>`, exit 0. Four journeys pass their Quint traces (24 passing, 0 failed each), and all five production mutants are refuted:

```
replay: journey approval
replay:   quint test: 24 passing, 0 failed (exit 0)
replay: mutant skip-approval-check
replay:   quint test: 23 passing, 1 failed (exit 1); refuted: true (expectation; QNT508); first failing step: 1/4 init
replay: journey verification-review
replay:   quint test: 24 passing, 0 failed (exit 0)
replay: mutant commit-on-red-pass
replay:   quint test: 23 passing, 1 failed (exit 1); refuted: true (expectation; QNT508); first failing step: 2/24 move(Loop, 1, -1, "")
replay: mutant commit-without-approving-review
replay:   quint test: 23 passing, 1 failed (exit 1); refuted: true (expectation; QNT508); first failing step: 4/6 reviewWith("changes")
replay: journey interruption-resume
replay:   quint test: 24 passing, 0 failed (exit 0)
replay: mutant resume-ignores-approval-change
replay:   quint test: 23 passing, 1 failed (exit 1); refuted: true (expectation; QNT508); first failing step: 4/8 resume
replay: journey commit-recovery
replay:   quint test: 24 passing, 0 failed (exit 0)
replay: mutant resume-commits-again
replay:   quint test: 23 passing, 1 failed (exit 1); refuted: true (expectation; QNT508); first failing step: 5/5 move(Done, 1, 1, "commit")
replay: every trace of the installed kogen passes and every mutant is refuted
```

Two test-input updates were needed, both because main changed after this harness was written. The approval journey's scripted shaper reads README.md before submitting, as main 2ca0e06 requires. The `commit-on-red-pass` mutant anchor names the non-staged `verifyAndReview` site, because main db0c02e added a second `if !pass.Green` for staged gates. Every mutant edit anchor is checked to occur exactly once.

## Current completion replay, 24 October 2026

The frozen installed `dev+5c71ebe7` runtime passes all four production journeys
(each trace:24 Quint tests passed) and refutes all five production mutants. This
rerun follows the current caching/Refine reconciliation; the older5fdbd286 proof
above remains historical. Exact observations, mutant patches, traces and first
failing transitions remain in the root takeover execution record.
