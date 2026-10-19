module resume_failed_builds {
  // Candidate/evidence are versions. valid abstracts exact checkpoint, repository,
  // HEAD, approval/baseline/configuration, candidate and index custody validation.
  // A pending side effect may be refused, never automatically replayed.
  var s: { phase: str, owner: str, stopped: bool, valid: bool, live: bool,
    pending: bool, executed: bool, issued: int, effects: int, cand: int,
    green: int, reviewed: int, commits: int, eligible: bool, resumed: bool }
  action init = s' = { phase: "build", owner: "builder", stopped: false,
    valid: true, live: false, pending: false, executed: false, issued: 0,
    effects: 0, cand: 0, green: -1, reviewed: -1, commits: 0,
    eligible: false, resumed: false }
  action issue = all { not(s.stopped), s.phase != "done", s.phase != "commit",
    not(s.pending), s' = { ...s, pending: true, executed: false, issued: s.issued + 1 } }
  action effect = all { not(s.stopped), s.pending, not(s.executed),
    s' = { ...s, executed: true, effects: s.effects + 1, cand: s.cand + 1 } }
  action complete = all { not(s.stopped), s.pending, s.executed,
    s' = { ...s, pending: false } }
  action verify = all { not(s.stopped), not(s.pending), s.phase != "done", s.phase != "commit",
    s' = { ...s, green: s.cand, phase: "review", owner: "reviewer" } }
  action approve = all { not(s.stopped), not(s.pending), s.phase == "review",
    s' = { ...s, reviewed: s.cand } }
  action prepareCommit = all { not(s.stopped), s.phase == "review", not(s.pending),
    s.green == s.cand, s.reviewed == s.cand, s.valid,
    s' = { ...s, phase: "commit", eligible: true } }
  action commit = all { not(s.stopped), s.phase == "commit", s.commits == 0,
    s' = { ...s, commits: 1 } }
  action land = all { not(s.stopped), s.phase == "commit", s.commits == 1,
    s' = { ...s, phase: "done" } }
  action stop = all { not(s.stopped), s.phase != "done", s' = { ...s, stopped: true } }
  action drift = all { s.stopped, s.commits == 0, s' = { ...s, valid: false } }
  action liveOwner = all { s.stopped, s' = { ...s, live: true } }
  action resume = all { s.stopped, s.valid, not(s.live), not(s.pending),
    s' = { ...s, stopped: false, resumed: true,
      phase: if (s.commits == 1) "done" else s.phase } }
  // Invalid/legacy/uncertain checkpoints and live owners are observational refusals.
  action refuse = all { s.stopped, not(s.valid) or s.live or s.pending, s' = s }
  action idle = all { s.phase == "done", s' = s }
  action step = any { issue, effect, complete, verify, approve, prepareCommit,
    commit, land, stop, drift, liveOwner, resume, refuse, idle }
  val SafeCommit = s.commits <= 1 and (s.commits == 1 implies
    (s.eligible and s.green == s.cand and s.reviewed == s.cand))
  val NoReplay = s.effects <= s.issued
  val SameReviewer = s.phase != "build" implies s.owner == "reviewer"
  val GuardedResume = (not(s.valid) or s.live) implies s.stopped
  run reviewResumeTest = init.then(verify).then(stop).then(resume)
    .expect(s.phase == "review" and s.owner == "reviewer" and s.green == 0)
  run executedUncertainToolRefusesTest = init.then(issue).then(effect).then(stop).then(refuse)
    .expect(s.stopped and s.effects == 1 and s.cand == 1)
  run commitCrashNeverCommitsTwiceTest = init.then(verify).then(approve)
    .then(prepareCommit).then(commit).then(stop).then(resume).then(idle)
    .expect(s.phase == "done" and s.commits == 1)
  run reviewEditRequiresVerificationTest = init.then(verify).then(issue).then(effect)
    .then(complete).then(approve)
    .expect(s.cand == 1 and s.green == 0 and s.reviewed == 1 and s.commits == 0)
}
