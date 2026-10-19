// Build, verification, repair, review and commit eligibility (chapters 04-07).
// Abstraction: the candidate is a version number that changes whenever the
// project files change (builder edits, check mutations). The checkout is the Build's alone
// while it runs (GIT-1); a change that still appears there simply changes the candidate. A pass
// is green only when every check passed and nothing changed while it ran.
// There is no time or token limit. A Build ends in exactly one of these ways (chapter 04):
// commit (landed), baseline_changed, head_moved, hook_changed_commit, commit_failed,
// context_exhausted, review_invalid, review_blocked, build_blocked, provider, interrupted.
module build {
  type Phase = Loop | Verifying | Reviewing | RepairingReview | FinalVerifying | Committing | Done | Failed | Interrupted

  var stoppedPhase: Phase
  var phase: Phase
  var rounds: int           // builder rounds so far (unbounded)
  var cand: int             // candidate version
  var passVersion: int      // candidate version of the last green pass, -1 = none
  var reviewedVersion: int  // candidate version the reviewer approved, -1 = none
  var invalidReviews: int
  var baselineIntact: bool  // acceptance baseline unchanged since approval
  var headMoved: bool
  var commits: int          // commits left on the branch
  var committedVersion: int
  var reason: str

  action init = all {
    stoppedPhase' = Loop, phase' = Loop, rounds' = 0, cand' = 0, passVersion' = -1, reviewedVersion' = -1,
    invalidReviews' = 0, baselineIntact' = true, headMoved' = false,
    commits' = 0, committedVersion' = -1, reason' = "",
  }

  def terminal(p: Phase): bool = Set(Done, Failed, Interrupted).contains(p)

  // Set the phase, candidate and pass; everything else unchanged.
  action move(p: Phase, c: int, pv: int, r: str): bool = all {
    stoppedPhase' = phase, phase' = p, cand' = c, passVersion' = pv, reason' = r,
    rounds' = rounds, reviewedVersion' = reviewedVersion, invalidReviews' = invalidReviews,
    baselineIntact' = baselineIntact, headMoved' = headMoved,
    commits' = commits, committedVersion' = committedVersion,
  }

  // LOOP-1..7: one builder round.
  action modelTurn = all {
    phase == Loop,
    nondet k = 1.to(20).oneOf()
    all {
      stoppedPhase' = phase, phase' = if (k >= 18) Failed else if (k >= 14) Verifying else Loop,
      reason' = if (k == 18) "provider" else if (k == 19) "baseline_changed" else if (k == 20) "context_exhausted" else reason,
      // VER-8: a command that changed the baseline stops the Build at once.
      baselineIntact' = if (k == 19) false else baselineIntact,
      cand' = if (k <= 8 or k == 19) cand + 1 else cand,
      rounds' = rounds + 1,
      passVersion' = passVersion, reviewedVersion' = reviewedVersion, invalidReviews' = invalidReviews,
      headMoved' = headMoved, commits' = commits, committedVersion' = committedVersion,
    },
  }

  // LOOP-7: only the builder may report a protected contradiction; validity abstracts
  // the exact envelope/current protected paths/evidence. Existing guards take priority.
  action blockerWith(valid: bool): bool = all {
    phase == Loop,
    if (not(valid)) move(Loop, cand, passVersion, reason)
    else if (not(baselineIntact)) move(Failed, cand, passVersion, "baseline_changed")
    else if (headMoved) move(Failed, cand, passVersion, "head_moved")
    else move(Failed, cand, passVersion, "build_blocked"),
  }

  action blocker = all {
    nondet valid = Set(true, false).oneOf()
    blockerWith(valid),
  }

  // VER-6/7/9: fixers ran; now the checks. VER-8: a changed baseline stops the Build at once.
  action verify = all {
    phase == Verifying,
    nondet outcome = Set("green", "red", "mutated").oneOf()
    if (not(baselineIntact)) move(Failed, cand, passVersion, "baseline_changed")
    else if (outcome == "green") move(Reviewing, cand, cand, reason)            // REV-1
    else if (outcome == "mutated") move(Loop, cand + 1, passVersion, reason)
    else move(Loop, cand, passVersion, reason),
  }

  // REV-3..5: one independent reviewer may repair the candidate itself.
  action reviewEdit = all {
    Set(Reviewing, RepairingReview).contains(phase),
    move(phase, cand + 1, passVersion, reason),
  }

  action reviewWith(verdict: str): bool = all {
    Set(Reviewing, RepairingReview).contains(phase),
    stoppedPhase' = phase, phase' = if (verdict == "approve") {
               if (phase == Reviewing and cand == passVersion) Committing else FinalVerifying
             }
             else if (verdict == "changes") Failed
             else if (invalidReviews >= 1) Failed
             else phase,
    reason' = if (verdict == "changes") "review_blocked"
              else if (verdict == "invalid" and invalidReviews >= 1) "review_invalid" else reason,
    reviewedVersion' = if (verdict == "approve") cand else reviewedVersion,
    invalidReviews' = if (verdict == "invalid") invalidReviews + 1 else 0,
    rounds' = rounds, cand' = cand, passVersion' = passVersion, baselineIntact' = baselineIntact,
    headMoved' = headMoved, commits' = commits, committedVersion' = committedVersion,
  }

  action review = all {
    nondet verdict = Set("approve", "changes", "invalid").oneOf()
    reviewWith(verdict),
  }

  // Final checks are external. Red/mutated contents stay with the same reviewer,
  // never restarting the builder or silently using an older green pass.
  action finalVerifyWith(outcome: str): bool = all {
    phase == FinalVerifying,
    if (not(baselineIntact)) move(Failed, cand, passVersion, "baseline_changed")
    else if (outcome == "green") move(if (cand == reviewedVersion) Committing else Reviewing, cand, cand, reason)
    else if (outcome == "mutated") move(RepairingReview, cand + 1, passVersion, reason)
    else move(RepairingReview, cand, passVersion, reason),
  }

  action finalVerify = all {
    nondet outcome = Set("green", "red", "mutated").oneOf()
    finalVerifyWith(outcome),
  }

  // GIT-3..6: commit only the reviewed, verified candidate on the same HEAD. If the candidate
  // no longer equals the reviewed one, the Build verifies and reviews again (GIT-3). A commit hook
  // that changed the committed tree makes Kogen undo its own commit (GIT-6); a failing `git commit`
  // ends the Build (GIT-5). `commits` counts commits left on the branch: the undone commit was
  // created but stays only in the reflog.
  action commitWith(outcome: str): bool = all {
    phase == Committing,
    if (not(baselineIntact)) move(Failed, cand, passVersion, "baseline_changed")
    else if (headMoved) move(Failed, cand, passVersion, "head_moved")
    else if (cand != passVersion or reviewedVersion != passVersion) move(Verifying, cand, passVersion, reason)
    else if (outcome == "hook_changed_commit") move(Failed, cand + 1, passVersion, "hook_changed_commit")
    else if (outcome == "commit_failed") move(Failed, cand, passVersion, "commit_failed")
    else all {
      stoppedPhase' = phase, phase' = Done, commits' = commits + 1, committedVersion' = cand, reason' = "commit",
      rounds' = rounds, cand' = cand, passVersion' = passVersion, reviewedVersion' = reviewedVersion,
      invalidReviews' = invalidReviews, baselineIntact' = baselineIntact, headMoved' = headMoved,
    },
  }

  action commit = all {
    nondet k = 1.to(10).oneOf()
    commitWith(if (k == 1) "hook_changed_commit" else if (k == 2) "commit_failed" else "ok"),
  }

  // Outside the Build: another commit, a stray edit, a baseline edit, or the
  // caller's interrupt (CLI-7). The edits are robustness the model allows on purpose
  // (GIT-1 says the checkout is the Build's alone). Weighted so that most steps are quiet.
  action world = all {
    not(terminal(phase)),
    nondet k = 1.to(40).oneOf()
    all {
      stoppedPhase' = phase, phase' = if (k == 4) Interrupted else phase,
      reason' = if (k == 4) "interrupted" else reason,
      headMoved' = (headMoved or k == 1),
      baselineIntact' = (baselineIntact and k != 3),
      cand' = if (k == 2 or k == 3) cand + 1 else cand,
      rounds' = rounds, passVersion' = passVersion, reviewedVersion' = reviewedVersion,
      invalidReviews' = invalidReviews, commits' = commits, committedVersion' = committedVersion,
    },
  }

  // LOOP-10: validated continuation preserves owner and exact evidence. Unsafe
  // checkpoints refuse observationally; no edit/tool effect is replayed here.
  action resume = all {
    Set(Failed, Interrupted).contains(phase),
    Set("provider", "interrupted").contains(reason),
    baselineIntact, not(headMoved), commits == 0,
    not(terminal(stoppedPhase)),
    move(stoppedPhase, cand, passVersion, ""),
  }

  run resumeReviewerTest = init.then(move(Reviewing, 2, 2, ""))
    .then(move(Failed, 2, 2, "provider")).then(resume)
    .expect(phase == Reviewing and passVersion == 2 and cand == 2 and commits == 0)

  run resumeBuilderTest = init.then(move(Failed, 0, -1, "provider")).then(resume)
    .expect(phase == Loop and commits == 0)

  action step = any { resume, modelTurn, blocker, verify, reviewEdit, review, finalVerify, commit, world }

  // ---- Invariants ----
  // GIT-3/6: a kept commit holds exactly the reviewed, green candidate; baseline intact; same HEAD.
  val CommitOnlyWhenEligible = phase == Done implies
    (commits == 1 and committedVersion == passVersion and committedVersion == reviewedVersion
     and baselineIntact and not(headMoved))
  // GIT-7: at most one commit; none unless Done.
  val AtMostOneCommit = commits <= 1 and (phase != Done implies commits == 0)
  // REV-1/6: the commit step is reached only with an approving review of the latest green pass.
  val ReviewNeverOverridesChecks = phase == Committing implies reviewedVersion == passVersion
  // VER-8: a changed baseline never reaches a commit.
  val BaselineChangeNeverCommits = not(baselineIntact) implies commits == 0
  // Chapter 04 / LOOP-7: a Build ends only in one of the listed ways;
  // failing checks continue with their current repair owner; unresolved review blockers stop.
  val FailureReasons = terminal(phase) implies Set(
    "commit", "baseline_changed", "head_moved", "hook_changed_commit", "commit_failed",
    "context_exhausted", "review_invalid", "review_blocked", "build_blocked", "provider", "interrupted").contains(reason)
  val Safety = CommitOnlyWhenEligible and AtMostOneCommit and ReviewNeverOverridesChecks
    and BaselineChangeNeverCommits and FailureReasons

  // ---- Tests ----
  run builderBlockerPreservesCandidateTest =
    init.then(move(Loop, 3, -1, ""))
      .then(blockerWith(true))
      .expect(phase == Failed and reason == "build_blocked" and cand == 3 and commits == 0)

  run invalidBuilderBlockerContinuesTest =
    init.then(blockerWith(false))
      .expect(phase == Loop and reason == "" and commits == 0)

  run redThenGreenReviewedCommitsTest =
    init
      .then(move(Verifying, 1, -1, ""))
      .then(move(Loop, 1, -1, ""))         // red: repair
      .then(move(Verifying, 2, -1, ""))    // edited, finished
      .then(move(Reviewing, 2, 2, ""))     // green
      .then(reviewWith("approve"))
      .then(commitWith("ok"))
      .expect(phase == Done and commits == 1 and committedVersion == 2)

  run unresolvedReviewStopsTest =
    init.then(move(Reviewing, 2, 2, "")).then(reviewWith("changes"))
      .expect(phase == Failed and reason == "review_blocked" and commits == 0)

  run reviewerRepairRequiresFinalVerificationTest =
    init.then(move(Reviewing, 2, 2, "")).then(reviewEdit).then(reviewWith("approve"))
      .expect(phase == FinalVerifying and passVersion == 2 and reviewedVersion == 3 and commits == 0)

  run reviewerRepairVerifiedThenCommittedTest =
    init.then(move(Reviewing, 2, 2, "")).then(reviewEdit).then(reviewWith("approve"))
      .then(finalVerifyWith("green")).then(commitWith("ok"))
      .expect(phase == Done and committedVersion == 3 and passVersion == 3 and reviewedVersion == 3)

  run failedFinalVerificationStaysWithReviewerTest =
    init.then(move(Reviewing, 2, 2, "")).then(reviewEdit).then(reviewWith("approve"))
      .then(finalVerifyWith("red")).then(reviewWith("approve"))
      .expect(phase == FinalVerifying and passVersion == 2 and commits == 0)

  run changedAfterApprovalNeedsReviewTest =
    init.then(move(Reviewing, 2, 2, "")).then(reviewEdit).then(reviewWith("approve"))
      .then(move(FinalVerifying, 4, 2, "")).then(finalVerifyWith("green"))
      .expect(phase == Reviewing and passVersion == 4 and reviewedVersion == 3 and commits == 0)

  run twoInvalidReviewsFailTest =
    init.then(move(Reviewing, 2, 2, "")).then(reviewWith("invalid")).then(reviewWith("invalid"))
      .expect(phase == Failed and reason == "review_invalid" and commits == 0)

  run changedBaselineStopsAtVerificationTest =
    init.then(all {
      stoppedPhase' = phase, phase' = Verifying, rounds' = 1, cand' = 1, passVersion' = -1, reviewedVersion' = -1,
      invalidReviews' = 0, baselineIntact' = false, headMoved' = false,
      commits' = 0, committedVersion' = -1, reason' = "",
    }).then(verify)
      .expect(phase == Failed and reason == "baseline_changed" and commits == 0)

  run unreviewedCandidateIsVerifiedAgainTest =
    init.then(move(Committing, 2, 2, "")).then(commitWith("ok"))
      .expect(phase == Verifying and commits == 0)

  run hookChangedCommitIsNotKeptTest =
    init.then(move(Reviewing, 2, 2, "")).then(reviewWith("approve")).then(commitWith("hook_changed_commit"))
      .expect(phase == Failed and reason == "hook_changed_commit" and commits == 0)

  run failedGitCommitLeavesNoCommitTest =
    init.then(move(Reviewing, 2, 2, "")).then(reviewWith("approve")).then(commitWith("commit_failed"))
      .expect(phase == Failed and reason == "commit_failed" and commits == 0)
}
