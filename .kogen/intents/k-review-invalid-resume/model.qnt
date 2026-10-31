// K-REVIEW-INVALID-RESUME: an independent review, native or external, that ends without a valid
// verdict after its candidate passed every check leaves a review-only checkpoint of that green
// candidate (the reviewer's uncommitted edits left in place); an explicit resume discards those
// edits and starts one fresh review of the green tree. Allowances and the one automatic fresh
// review are unchanged; a reopened blocker and a moved HEAD stay unresumable.
module reviewInvalidResume {
  // "reviewing", "review_only" (resumable stop), "unsupported" (stop that cannot resume),
  // "blocked" (review_blocked) or "landed"
  var stage: str
  // the review tree: "green" (the tree of the complete green pass the review started from) or
  // "edited" (the reviewer's uncommitted edits on top of it)
  var tree: str
  var headMoved: bool
  // this review already had a verdict judged and sent back (it repaired)
  var repaired: bool
  // the reopened conversation of a blocked review
  var reopened: bool
  var autoSpent: bool
  // the edited tree passed verification
  var editsVerified: bool
  var approvedTree: str
  var landedTree: str

  action init = all {
    stage' = "reviewing", tree' = "green", headMoved' = false, repaired' = false, reopened' = false,
    autoSpent' = false, editsVerified' = false, approvedTree' = "none", landedTree' = "none",
  }

  action keep(st: str, tr: str, hm: bool, rp: bool, ro: bool, au: bool, ev: bool, ap: str, ld: str): bool = all {
    stage' = st, tree' = tr, headMoved' = hm, repaired' = rp, reopened' = ro, autoSpent' = au,
    editsVerified' = ev, approvedTree' = ap, landedTree' = ld,
  }

  // The reviewer edits the checkout without committing.
  action edit = all {
    stage == "reviewing",
    keep(stage, "edited", headMoved, repaired, reopened, autoSpent, false, approvedTree, landedTree),
  }

  // The reviewer commits its own change: HEAD moved.
  action reviewerCommits = all {
    stage == "reviewing",
    keep(stage, tree, true, repaired, reopened, autoSpent, editsVerified, approvedTree, landedTree),
  }

  // An approval of the unchanged green tree lands it (a moved HEAD refuses the commit).
  action approveGreen = all {
    stage == "reviewing", tree == "green",
    if (headMoved) keep("unsupported", tree, headMoved, repaired, reopened, autoSpent, editsVerified, approvedTree, landedTree)
    else keep("landed", tree, headMoved, repaired, reopened, autoSpent, editsVerified, "green", "green"),
  }

  // An approval of edits is verified: green lands the approved edits, red goes back to the
  // same reviewer, which has then repaired.
  action approveEdits(green: bool): bool = all {
    stage == "reviewing", tree == "edited",
    if (green and not(headMoved)) keep("landed", tree, headMoved, repaired, reopened, autoSpent, true, "edited", "edited")
    else keep(stage, tree, headMoved, true, reopened, autoSpent, false, approvedTree, landedTree),
  }

  action changes = all {
    stage == "reviewing",
    keep("blocked", tree, headMoved, repaired, reopened, autoSpent, editsVerified, approvedTree, landedTree),
  }

  // The review ends without a valid verdict.
  action invalid = all {
    stage == "reviewing",
    if (reopened or headMoved)
      keep("unsupported", tree, headMoved, repaired, reopened, autoSpent, editsVerified, approvedTree, landedTree)
    else if (not(autoSpent) and not(repaired))
      // the one automatic fresh review, unchanged: edits discarded first
      keep("reviewing", "green", headMoved, false, false, true, false, approvedTree, landedTree)
    else
      // the review-only stop of the green candidate, the reviewer's edits left in place
      keep("review_only", tree, headMoved, repaired, reopened, autoSpent, editsVerified, approvedTree, landedTree),
  }

  // Explicit resume of the review-only checkpoint: the edits are discarded and one fresh review
  // of the green tree starts; the automatic retry stays spent.
  action resume = all {
    stage == "review_only", not(headMoved),
    keep("reviewing", "green", headMoved, false, false, true, false, approvedTree, landedTree),
  }

  // Explicit resume of a blocked review reopens it with the same reviewer.
  action resumeBlocked = all {
    stage == "blocked", not(headMoved),
    keep("reviewing", tree, headMoved, repaired, true, autoSpent, editsVerified, approvedTree, landedTree),
  }

  action stutter = all {
    stage == "landed" or stage == "unsupported" or (stage == "review_only" and headMoved) or (stage == "blocked" and headMoved),
    keep(stage, tree, headMoved, repaired, reopened, autoSpent, editsVerified, approvedTree, landedTree),
  }

  action step = any {
    edit, reviewerCommits, approveGreen, nondet g = Set(true, false).oneOf() approveEdits(g), changes, invalid, resume,
    resumeBlocked, stutter,
  }

  // Only an approved tree lands, approved edits only after they passed verification, and never
  // after HEAD moved.
  val LandedApprovedVerified = stage == "landed" implies
    (landedTree == approvedTree and not(headMoved) and (landedTree == "green" or editsVerified))
  // An invalid ending of a green candidate is never stranded: only a reopened blocker or a
  // moved HEAD stops without a resumable review-only checkpoint.
  val InvalidGreenStopResumable = stage == "unsupported" implies (reopened or headMoved)
  // A review-only stop never stands in for a blocker's own decision.
  val ReviewOnlyNotBlocker = stage == "review_only" implies not(reopened)
}
