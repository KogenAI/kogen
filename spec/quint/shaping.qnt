// Shaping readiness and authorization for one Intent (chapters 02 and 03).
// Abstraction: Intent content is a version number (`digest`); every write or
// edit makes a new version. Readiness is the result of the readiness checks
// for the current version. Only the caller approves and only the caller starts
// a Build; the shaper can ask questions or write files, nothing else.
module shaping {
  type IntentState = Absent | Asking | Shaped | Approved | Building | Built

  var st: IntentState
  var digest: int          // current content version (0 = no files)
  var ready: bool          // readiness of the current version
  var approval: int        // approved version, -1 = none
  var prevApproval: int    // approval before the last action
  var startedDigest: int   // version a running Build started from, -1 = none
  var lastAction: str
  var attempts: int        // submissions written by the current shaping command (SHP-4)

  action setVars(s, d, r, a, sd, act, at) = all {
    st' = s, digest' = d, ready' = r, approval' = a,
    prevApproval' = approval, startedDigest' = sd, lastAction' = act, attempts' = at,
  }

  action init = all {
    st' = Absent, digest' = 0, ready' = false, approval' = -1,
    prevApproval' = -1, startedDigest' = -1, lastAction' = "init", attempts' = 0,
  }

  // SHP-6: the shaper asks questions; nothing is written, nothing approved. After a not-ready
  // attempt (SHP-4) it may ask too; the files of that attempt stay.
  action shapeAsk = all {
    Set(Absent, Asking).contains(st) or (st == Shaped and not(ready) and attempts < 3),
    setVars(Asking, digest, ready, approval, startedDigest, "ask", attempts),
  }

  // SHP-4: the shaper writes the Intent files; readiness is whatever the checks say. A not-ready
  // attempt goes back to the shaper (SHP-8), whose next attempt overwrites the files: at most 3 in a row.
  action shapeWrite = all {
    Set(Absent, Asking).contains(st) or (st == Shaped and not(ready) and attempts < 3),
    nondet r = Set(true, false).oneOf()
    setVars(Shaped, digest + 1, r, approval, startedDigest, "write", if (st == Shaped) attempts + 1 else 1),
  }

  // A manual edit of the Intent or its acceptance files (allowed before a Build).
  action edit = all {
    Set(Shaped, Approved).contains(st),
    nondet r = Set(true, false).oneOf()
    setVars(st, digest + 1, r, approval, startedDigest, "edit", 3),
  }

  // SHP-11: scratch corrections publish only ready, hash-bound changes to an
  // unapproved ready draft. Failure/staleness leaves the original untouched.
  action refineWith(expected: int, succeeds: bool): bool = all {
    st == Shaped and ready and approval == -1,
    if (expected == digest and succeeds)
      setVars(Shaped, digest + 1, true, -1, startedDigest, "refine", attempts)
    else
      setVars(st, digest, ready, approval, startedDigest, "refine_refused", attempts),
  }

  action refine = all {
    nondet expected = 0.to(digest + 1).oneOf()
    nondet succeeds = Set(true, false).oneOf()
    refineWith(expected, succeeds),
  }

  // AUT-2: the caller approves with a hash; only the current, ready version.
  action approve = all {
    Set(Shaped, Approved).contains(st),
    nondet h = 0.to(digest + 1).oneOf()
    if (h == digest and ready)
      setVars(Approved, digest, ready, digest, startedDigest, "approve", attempts)
    else
      setVars(st, digest, ready, approval, startedDigest, "approve_refused", attempts),
  }

  // AUT-3: the caller explicitly builds (kogen intent build).
  action start = all {
    st != Building,
    st != Built,
    if (st == Approved and approval == digest and ready)
      setVars(Building, digest, ready, approval, digest, "start", attempts)
    else
      setVars(st, digest, ready, approval, startedDigest, "start_refused", attempts),
  }

  // A Build ends: committed (the approval is deleted, AUT-6 and GIT-8), or not (edits left, approval kept).
  action buildEnds = all {
    st == Building,
    nondet committed = Set(true, false).oneOf()
    if (committed)
      setVars(Built, digest, ready, -1, -1, "built", attempts)
    else
      setVars(Approved, digest, ready, approval, -1, "build_failed", attempts),
  }

  action step = any { shapeAsk, shapeWrite, edit, refine, approve, start, buildEnds }

  // ---- Invariants ----
  // SHP-6: while questions are pending, nothing is approved.
  val NoApprovalWhileAsking = st == Asking implies approval == -1
  // AUT-2: a current approval implies the approved version passed readiness.
  val CurrentApprovalIsReady = (approval != -1 and approval == digest) implies ready
  // AUT-2 / SHP-7: only the caller's approve (or a committed Build) changes the approval.
  // A regression guard on these actions; the evidence for AUT-2 and SHP-7 is their scenarios.
  val ApprovalOnlyByCaller =
    approval != prevApproval implies Set("approve", "built").contains(lastAction)
  // AUT-3: a Build runs only on the approved, current version.
  val BuildOnlyOnCurrentApproval =
    st == Building implies (startedDigest == approval and approval == digest and ready)
  // AUT-2: neither shaping nor approval starts a Build; only an explicit start does.
  // A regression guard as well; no action lets the shaper start one.
  val OnlyExplicitStartBuilds = (st == Building and lastAction != "start") implies false
  // AUT-6 / GIT-8: a landed Build deletes the approval, so the Intent cannot be built again.
  val LandedHasNoApproval = st == Built implies (approval == -1 and startedDigest == -1)
  val Safety = NoApprovalWhileAsking and CurrentApprovalIsReady
    and ApprovalOnlyByCaller and BuildOnlyOnCurrentApproval and OnlyExplicitStartBuilds
    and LandedHasNoApproval

  // ---- Tests (fixed traces) ----
  run refinementStillNeedsExplicitApprovalTest =
    init.then(setVars(Shaped, 1, true, -1, -1, "write", 1))
      .then(refineWith(1, true)).then(start)
      .expect(st == Shaped and digest == 2 and approval == -1 and lastAction == "start_refused")

  run failedAndStaleRefinementPreserveDraftTest =
    init.then(setVars(Shaped, 1, true, -1, -1, "write", 1))
      .then(refineWith(0, true)).then(refineWith(1, false))
      .expect(st == Shaped and digest == 1 and ready and approval == -1)

  run askThenWriteThenApproveTest =
    init.then(shapeAsk).then(
      all { st == Asking, setVars(Shaped, 1, true, -1, -1, "write", 1) }
    ).then(
      all { st == Shaped, setVars(Approved, 1, true, 1, -1, "approve", 1) }
    ).then(start).expect(st == Building and startedDigest == 1)

  run editAfterApprovalBlocksStartTest =
    init.then(all { setVars(Shaped, 1, true, -1, -1, "write", 1) })
      .then(all { setVars(Approved, 1, true, 1, -1, "approve", 1) })
      .then(all { setVars(Approved, 2, true, 1, -1, "edit", 3) })
      .then(start)
      .expect(st == Approved and lastAction == "start_refused")

  run notReadyAttemptMayBeFollowedByQuestionsTest =
    init.then(all { setVars(Shaped, 1, false, -1, -1, "write", 1) })
      .then(shapeAsk)
      .expect(st == Asking and digest == 1 and approval == -1)

  run notReadyAttemptIsOverwrittenTest =
    init.then(all { setVars(Shaped, 1, false, -1, -1, "write", 1) })
      .then(shapeWrite)
      .expect(st == Shaped and digest == 2 and attempts == 2)

  run landedIntentCannotBeBuiltAgainTest =
    init.then(all { setVars(Built, 1, true, -1, -1, "built", 1) })
      .then(start)
      .fail()

  run notReadyCannotBeApprovedTest =
    init.then(all { setVars(Shaped, 1, false, -1, -1, "write", 1) })
      .then(approve)
      .expect(approval == -1)
}
