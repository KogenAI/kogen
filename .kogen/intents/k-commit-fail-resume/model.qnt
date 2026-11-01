// K-COMMIT-FAIL-RESUME: a Build whose only failure is its git commit can finish that commit
// through `kogen intent resume`, and only on the exact verified and reviewed tree and start HEAD.
module commitFailResume {
  // "committing": the commit step is running (checkpoint stage commit)
  // "commit_failed": git commit exited nonzero and HEAD is still the start (resumable)
  // "uncertain": the commit step ended without a definite result (interrupt, crash; refused)
  // "landed": Kogen's one commit exists
  var stage: str
  var tree: str           // the candidate: "reviewed" (verified and approved) or "edited"
  var headRef: str        // "start", "moved" (someone else's commit) or "kogen" (Kogen's commit)
  var approvalSame: bool  // the approval and its inputs are as saved
  var signing: bool       // the commit environment (signing program, key) works
  var committedTree: str  // what Kogen's commit holds ("" when none)
  var wasUncertain: bool
  var refusals: int

  val stopped = stage == "commit_failed" or stage == "uncertain"

  action init = all {
    stage' = "committing", tree' = "reviewed", headRef' = "start", approvalSame' = true,
    signing' = false, committedTree' = "", wasUncertain' = false, refusals' = 0,
  }

  action unchangedRest = all {
    approvalSame' = approvalSame, committedTree' = committedTree, wasUncertain' = wasUncertain,
    refusals' = refusals,
  }

  // The commit step itself: a working environment lands the reviewed tree on the start HEAD;
  // a failing git commit leaves HEAD at the start; an interrupt leaves the boundary uncertain.
  action commitLands = all {
    stage == "committing", signing, tree == "reviewed", headRef == "start",
    stage' = "landed", headRef' = "kogen", committedTree' = tree,
    tree' = tree, signing' = signing, approvalSame' = approvalSame, wasUncertain' = wasUncertain,
    refusals' = refusals,
  }
  action commitFails = all {
    stage == "committing", not(signing),
    stage' = "commit_failed", tree' = tree, headRef' = headRef, signing' = signing, unchangedRest,
  }
  action commitInterrupted = all {
    stage == "committing",
    stage' = "uncertain", tree' = tree, headRef' = headRef, signing' = signing,
    approvalSame' = approvalSame, committedTree' = committedTree, wasUncertain' = true,
    refusals' = refusals,
  }

  // The caller between stop and resume.
  action fixEnvironment = all { stopped, signing' = true, stage' = stage, tree' = tree, headRef' = headRef, unchangedRest }
  action editTree = all { stopped, tree' = "edited", stage' = stage, headRef' = headRef, signing' = signing, unchangedRest }
  action restoreTree = all { stopped, tree' = "reviewed", stage' = stage, headRef' = headRef, signing' = signing, unchangedRest }
  action moveHead = all { stopped, headRef == "start", headRef' = "moved", stage' = stage, tree' = tree, signing' = signing, unchangedRest }
  action changeApproval = all {
    stopped, approvalSame' = false, stage' = stage, tree' = tree, headRef' = headRef, signing' = signing,
    committedTree' = committedTree, wasUncertain' = wasUncertain, refusals' = refusals,
  }

  // `kogen intent resume`: only a definite commit failure on the exact reviewed tree, start
  // HEAD and saved approval goes back to the commit step, with no builder, review or pass.
  val resumable = stage == "commit_failed" and tree == "reviewed" and headRef == "start" and approvalSame
  action resumeCommit = all {
    resumable,
    stage' = "committing", tree' = tree, headRef' = headRef, signing' = signing, unchangedRest,
  }
  action resumeRefused = all {
    stopped, not(resumable),
    refusals' = refusals + 1,
    stage' = stage, tree' = tree, headRef' = headRef, signing' = signing, approvalSame' = approvalSame,
    committedTree' = committedTree, wasUncertain' = wasUncertain,
  }

  action step = any {
    commitLands, commitFails, commitInterrupted, fixEnvironment, editTree, restoreTree,
    moveHead, changeApproval, resumeCommit, resumeRefused,
  }

  // Kogen's commit holds exactly the reviewed tree, made on the start HEAD.
  val LandedReviewed = stage == "landed" implies (committedTree == "reviewed" and headRef == "kogen")
  // A failed commit leaves no Kogen commit.
  val FailedNoCommit = stage == "commit_failed" implies (committedTree == "" and headRef != "kogen")
  // An uncertain commit boundary is never continued.
  val UncertainStays = wasUncertain implies stage == "uncertain"
}
