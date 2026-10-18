module ready_evidence {
  // baseline abstracts the existing protected-baseline hash; revision abstracts HEAD.
  var baseline: int
  var revision: int
  var evidenceBaseline: int
  var evidenceRevision: int
  var valid: bool
  var shown: bool
  var reused: bool
  var approved: bool
  var prevApproved: bool
  var last: str
  action init = all {
    baseline' = 0, revision' = 0, evidenceBaseline' = -1, evidenceRevision' = -1,
    valid' = false, shown' = false, reused' = false,
    approved' = false, prevApproved' = false, last' = "init",
  }
  val matches = valid and evidenceBaseline == baseline and evidenceRevision == revision
  // Successful stable shaping or publication of a checked refinement.
  action publish = all {
    baseline' = baseline + 1, revision' = revision,
    evidenceBaseline' = baseline + 1, evidenceRevision' = revision, valid' = true,
    shown' = false, reused' = false,
    approved' = approved, prevApproved' = approved, last' = "publish",
  }
  action change = {
    nondet which = Set("baseline", "revision", "invalid").oneOf()
    all {
      baseline' = if (which == "baseline") baseline + 1 else baseline,
      revision' = if (which == "revision") revision + 1 else revision,
      evidenceBaseline' = evidenceBaseline, evidenceRevision' = evidenceRevision,
      valid' = (valid and which != "invalid"), shown' = false, reused' = false,
      approved' = approved, prevApproved' = approved, last' = "change",
    }
  }
  // A readiness failure differs from a normally accounted failing acceptance scenario.
  // ExplicitHash abstracts an already matching, explicitly supplied approval hash.
  action review = {
    nondet freshPass = Set(true, false).oneOf()
    nondet explicitHash = Set(true, false).oneOf()
    val success = matches or freshPass
    all {
      baseline' = baseline, revision' = revision,
      evidenceBaseline' = if (success) baseline else evidenceBaseline,
      evidenceRevision' = if (success) revision else evidenceRevision,
      valid' = success, shown' = success, reused' = matches,
      approved' = (approved or (explicitHash and success)), prevApproved' = approved,
      last' = if (explicitHash) "approve" else "card",
    }
  }
  action step = any { publish, change, review }
  val EvidenceIsCurrent = shown implies matches
  val ReuseHasEvidence = reused implies (shown and valid)
  val OnlyExplicitHashApproves = approved != prevApproved implies last == "approve"
  val Safety = EvidenceIsCurrent and ReuseHasEvidence and OnlyExplicitHashApproves
}
